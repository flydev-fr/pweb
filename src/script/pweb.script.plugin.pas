{
  pweb.script.plugin - CAP-9B2 QuickJS plugin lifecycle owner:
  generations, explicit Load / CallExport / Reload / Unload, and one
  transactional generation swap.

  WHAT THIS UNIT OWNS, AND ONLY THIS: the plugin's *identity* (the
  frozen native registration), the *generation counter*, the *published
  generation slot*, and the *lifecycle state machine*. It owns no
  thread, no engine, no JSContext, no module cache and no scheduler
  source - a TPWebQuickJSPlugin owns exactly one of each of those and
  IS one generation. This unit never touches a JSValue and never
  references mormot.lib.quickjs: everything it does to a generation goes
  through that class's public, thread-affine surface.

  That split is deliberate. CAP-9B1 already had a correct engine owner;
  building a second one beside it would have produced two objects each
  believing it owned the thread. So the B1 owner was PROMOTED to a
  generation, and this is the only new owner - of generations, not of
  engines.

  THE CONCEPTUAL MODEL (CAP-9B2 spec):

    native descriptor + package store
        -> stage/load an isolated generation
        -> Running
        -> explicit host calls into exported plugin functions
        -> Quiesce
        -> Close / Unload

    Running generation + explicit Reload(new package store)
        -> stage a NEW isolated generation
        -> validate it completely
        -> ONE generation-switch commit point
        -> close and destroy the previous generation

  There is NO discovery, NO directory scanning, NO file watcher, NO
  implicit reload and NO updater anywhere in this unit or below it.
  Every transition is a native call made by trusted host code.

  WHAT JAVASCRIPT CAN DO TO ITS OWN LIFECYCLE: nothing. There is no
  script-visible surface here at all. A plugin cannot reload itself,
  unload itself, replace its package store, change its descriptor, its
  PrincipalId or its capabilities. The export table it fills during load
  is plain data (pweb.script.quickjs), and the frozen `pweb` object
  still carries exactly invoke + handshake.

  LOCK ORDER, documented because it is tested:

    FOpLock  ->  FLifeLock        (never the reverse)

  - FOpLock serialises Load / Reload / Unload / a tainting call's
    reap with each other. It MAY be held across blocking work (that is
    its whole job: two concurrent Reloads must not both stage).
  - FLifeLock protects the state ordinal and the published-generation
    slot and NOTHING else. It is never held across a package load, an
    export call, a source Quiesce/Close, a drain or a thread join.
  - CallExport takes FLifeLock only, and only to read the state and pin
    the generation - so it can never deadlock against a staging Reload.
  - The plugin thread never takes either lock: calls only ever go
    host -> generation, never back.

  GENERATIONS ARE NEVER REUSED. Each successful load mints a NEW
  monotonic generation id (PER HOST, so plugin A's counter can never
  perturb plugin B), a new thread, engine, JSContext, module cache,
  module graph, scheduler source and completion-sink set. Nothing -
  no global, no module cache entry, no JSValue, no pending job, no
  closure, no native pointer - is carried across. GenerationId is
  lifecycle safety metadata and carries NO authority: runtime grants
  stay keyed by the native PrincipalId through the frozen CAP-8 policy,
  snapshotted per invocation.

  Canonical sources: security-model.md (native trust anchor),
  threading-model.md (ownership at the C boundary, exactly-once
  completion), wire-semantics.md (source lifecycle).
}
unit pweb.script.plugin;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Classes,
  mormot.core.base,
  mormot.core.os,
  pweb.assets.intf,
  pweb.rpc.intf,
  pweb.script.package,
  pweb.script.quickjs;

type
  EPWebPluginHost = class(Exception);

  { The lifecycle state of ONE plugin host. Exactly one object performs
    every transition (this host, under FLifeLock); no state is ever
    inferred from a live thread or a non-nil pointer.

      ppsCreated     no generation yet; only Load or Unload are legal.
      ppsLoading     the FIRST generation is being staged.
      ppsRunning     one generation is published and accepting calls.
      ppsStaging     Running, plus a replacement being built in
                     isolation. The old generation still serves.
      ppsCommitting  the controlled unavailable window of a reload: the
                     old generation no longer accepts calls and the new
                     one is not published yet. Bounded and deterministic.
      ppsQuiescing   no new calls; the published generation is closing.
      ppsFailed      no usable generation. ONLY Unload is legal - a
                     Failed host never silently becomes Running again.
      ppsClosed      terminal and idempotent. }
  TPWebPluginState = (
    ppsCreated,
    ppsLoading,
    ppsRunning,
    ppsStaging,
    ppsCommitting,
    ppsQuiescing,
    ppsFailed,
    ppsClosed);

  { Outcome of a lifecycle operation. Private native codes: an operation
    here is not an invocation, so the frozen nine-code RPC taxonomy
    (wire-semantics.md) is deliberately NOT reused or extended. }
  TPWebPluginLifecycleCode = (
    plfOk,
    plfBadState,      // illegal in the current state (never a silent no-op)
    plfIdentity,      // the descriptor would change native identity
    plfSource,        // the host source factory produced no source
    plfLoad,          // the package failed to stage (see ACode/ADetail)
    plfQuarantined);  // a generation's thread could not be joined

  { The host asks its owner for ONE fresh invocation source per
    generation. A callback rather than an IInvocationScheduler
    reference, so this unit needs no scheduler dependency AND a
    source-registration failure is a real, injectable row of the reload
    failure matrix (return nil). }
  TPWebPluginSourceFactory = function: IInvocationSource of object;

  { Everything a host is registered with, ONCE. Descriptor carries the
    frozen native identity, capabilities and both limit sets; a reload
    may replace only PackageStore and ExpectedEntryPoint and is refused
    outright if it would change anything else. }
  TPWebPluginRegistration = record
    Descriptor: TPWebQuickJSPackageDescriptor;
    OnSnapshot: TPWebQuickJSSnapshotEvent;
    SourceFactory: TPWebPluginSourceFactory;
    ReadyWaitMs: Integer;    // bound on staging a generation
    ExportWaitMs: Integer;   // bound on ONE export call
    UnloadJoinMs: Integer;   // bound on joining a generation's thread
    DrainMs: Integer;        // bound on draining in-flight export calls
  end;

  TPWebQuickJSPluginHost = class
  private
    FReg: TPWebPluginRegistration;
    FOpLock: TRTLCriticalSection;
    FLifeLock: TRTLCriticalSection;
    FDrained: PRTLEvent;
    FState: LongInt;                 // TPWebPluginState ordinal
    FCurrent: TPWebQuickJSPlugin;    // the PUBLISHED generation, or nil
    FGenSeq: Int64;                  // per-host, monotonic, never reused
    FGenerationId: Int64;            // id of the published generation
    FInFlight: LongInt;              // export calls running on FCurrent
    FUnloadRequested: LongInt;
    FQuarantined: LongInt;
    FCommits: LongInt;
    FStagingFailures: LongInt;
    FDrainTimeouts: LongInt;
    FRetiredWrongThread: LongInt;    // accumulated from retired generations
    procedure SetState(AState: TPWebPluginState);
    function SameIdentity(const ADescriptor: TPWebQuickJSPackageDescriptor;
      out ADetail: RawUtf8): Boolean;
    function StageGeneration(const ADescriptor: TPWebQuickJSPackageDescriptor;
      out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8;
      out ALife: TPWebPluginLifecycleCode): TPWebQuickJSPlugin;
    function DrainInFlight: Boolean;
    procedure RetireGeneration(APlugin: TPWebQuickJSPlugin; ADrained: Boolean);
    procedure ReapTaintedGeneration(AGenerationId: Int64);
  public
    { ARegistration.Descriptor is validated eagerly, so a host with a
      malformed native identity never exists. Zero bounds take the
      ratified defaults. }
    constructor Create(const ARegistration: TPWebPluginRegistration);
    { Unloads first (bounded, idempotent). A generation that had to be
      quarantined is NOT freed - it stays in the process-level ledger. }
    destructor Destroy; override;

    { Created -> Loading -> Running, or Created -> Failed. On plfOk one
      generation is published and CallExport is open. On failure nothing
      is published, nothing is left queueable and no thread survives -
      CAP-9B1's atomic load guarantees that, unchanged. }
    function Load(out ACode: TPWebPackageLoadCode;
      out ADetail: RawUtf8): TPWebPluginLifecycleCode;

    { One synchronous call into one exported plugin function, accepted
      ONLY in ppsRunning. See TPWebQuickJSPlugin.CallExport for the
      contract; a code that taints the generation additionally makes the
      host close that generation, bounded, and land in ppsFailed. }
    function CallExport(const AName: RawUtf8; const AArgs: TPWebJson;
      out AResult: TPWebJson; out ADetail: RawUtf8): TPWebExportCallCode;

    { The transactional reload. Refused unless ppsRunning. ADescriptor
      must carry the SAME PrincipalId, PluginId, ExpectedPackageId,
      capabilities and both limit sets as the registration; only
      PackageStore and ExpectedEntryPoint may differ. Manifest version
      is descriptive - same, higher and lower are all accepted, because
      update policy is not this shard's responsibility.

      Any failure while staging leaves the OLD generation Running and
      completely untouched: no source was published, the staged engine
      and thread are already gone, and the host returns to ppsRunning. }
    function Reload(const ADescriptor: TPWebQuickJSPackageDescriptor;
      out ACode: TPWebPackageLoadCode;
      out ADetail: RawUtf8): TPWebPluginLifecycleCode;

    { Bounded, idempotent, terminal. Order: unpublish -> Quiescing ->
      refuse new calls -> source Quiesce -> source Close (which releases
      a plugin thread blocked in synchronous pweb.invoke) -> drain
      in-flight calls -> stop and JOIN the thread (the engine dies in
      its own epilogue) -> Closed. A thread that cannot be joined inside
      the budget is quarantined, never terminated. }
    function Unload: TPWebPluginLifecycleCode;

    { A reload descriptor pre-filled from the registration: the caller
      substitutes PackageStore (and, if it must, ExpectedEntryPoint) and
      nothing else. }
    function ReloadTemplate: TPWebQuickJSPackageDescriptor;

    function State: TPWebPluginState;
    { The published generation's id, or 0 when nothing is published. }
    function GenerationId: Int64;
    { The published generation's sealed export names, comma-joined, or
      '' when nothing is published. Evidence, not a call surface. }
    function ExportNames: RawUtf8;
    function PrincipalId: Utf8String;
    function PluginId: Utf8String;
    { counters, for the CAP-9B2 corpus }
    function Commits: LongInt;
    function StagingFailures: LongInt;
    function QuarantinedGenerations: LongInt;
    function DrainTimeouts: LongInt;
    { MUST stay 0: an export call that ran off a generation's owning
      thread, summed over the published generation and every retired
      one. }
    function ExportWrongThreadCalls: LongInt;
  end;

const
  PWEB_PLUGIN_STATE_TEXT: array[TPWebPluginState] of RawUtf8 = (
    'created',
    'loading',
    'running',
    'staging',
    'committing',
    'quiescing',
    'failed',
    'closed');

  PWEB_PLUGIN_LIFECYCLE_TEXT: array[TPWebPluginLifecycleCode] of RawUtf8 = (
    'ok',
    'bad_state',
    'identity',
    'source',
    'load',
    'quarantined');

  /// ratified default bound on draining in-flight export calls before a
  // generation is retired - it must exceed one export call's own bound
  PWEB_PLUGIN_DEFAULT_DRAIN_MS = 40000;

implementation

{ ---------------- TPWebQuickJSPluginHost ---------------- }

constructor TPWebQuickJSPluginHost.Create(
  const ARegistration: TPWebPluginRegistration);
var
  code: TPWebPackageLoadCode;
  detail: RawUtf8;
begin
  inherited Create;
  FReg := ARegistration;
  // a host with a malformed native identity must never exist: validate
  // through the NON-RAISING CAP-9B1 validator and raise here, where the
  // caller is, rather than at the first Load
  if not PWebValidateQuickJSPackageDescriptor(FReg.Descriptor, code, detail) then
    raise EPWebPluginHost.CreateFmt(
      'plugin registration rejected: %s (%s)',
      [PWEB_PACKAGE_LOAD_TEXT[code], detail]);
  if not Assigned(FReg.SourceFactory) then
    raise EPWebPluginHost.Create(
      'plugin registration requires an invocation-source factory');
  if FReg.ReadyWaitMs <= 0 then
    FReg.ReadyWaitMs := 15000;
  if FReg.ExportWaitMs <= 0 then
    FReg.ExportWaitMs := PWEB_QUICKJS_EXPORT_WAIT_MS;
  if FReg.UnloadJoinMs <= 0 then
    FReg.UnloadJoinMs := PWEB_QUICKJS_UNLOAD_JOIN_MS;
  if FReg.DrainMs <= 0 then
    FReg.DrainMs := PWEB_PLUGIN_DEFAULT_DRAIN_MS;
  InitCriticalSection(FOpLock);
  InitCriticalSection(FLifeLock);
  FDrained := RTLEventCreate;
  FState := Ord(ppsCreated);
end;

destructor TPWebQuickJSPluginHost.Destroy;
begin
  Unload; // bounded and idempotent
  DoneCriticalSection(FOpLock);
  DoneCriticalSection(FLifeLock);
  if FDrained <> nil then
    RTLEventDestroy(FDrained);
  inherited Destroy;
end;

procedure TPWebQuickJSPluginHost.SetState(AState: TPWebPluginState);
begin
  EnterCriticalSection(FLifeLock);
  try
    FState := Ord(AState);
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

function TPWebQuickJSPluginHost.SameIdentity(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  out ADetail: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  // Reload replaces CODE, never native security identity. Every field
  // below is host configuration; letting a reload move any of them
  // would make "reload" a privilege-escalation primitive.
  if ADescriptor.PackageStore = nil then
    ADetail := 'no package store'
  else if ADescriptor.PrincipalId <> FReg.Descriptor.PrincipalId then
    ADetail := 'PrincipalId'
  else if ADescriptor.PluginId <> FReg.Descriptor.PluginId then
    ADetail := 'PluginId'
  else if ADescriptor.ExpectedPackageId <> FReg.Descriptor.ExpectedPackageId then
    ADetail := 'ExpectedPackageId'
  else if not PWebPackageEntryValid(ADescriptor.ExpectedEntryPoint) then
    ADetail := 'ExpectedEntryPoint'
  else if Length(ADescriptor.Capabilities) <>
          Length(FReg.Descriptor.Capabilities) then
    ADetail := 'Capabilities'
  else if (ADescriptor.Engine.TimeoutSeconds <>
             FReg.Descriptor.Engine.TimeoutSeconds) or
          (ADescriptor.Engine.MemoryLimitBytes <>
             FReg.Descriptor.Engine.MemoryLimitBytes) or
          (ADescriptor.Engine.StackLimitBytes <>
             FReg.Descriptor.Engine.StackLimitBytes) or
          (ADescriptor.Engine.InvokeWaitMs <>
             FReg.Descriptor.Engine.InvokeWaitMs) then
    ADetail := 'Engine limits'
  else if (ADescriptor.Package.ManifestMaxBytes <>
             FReg.Descriptor.Package.ManifestMaxBytes) or
          (ADescriptor.Package.ModuleMaxBytes <>
             FReg.Descriptor.Package.ModuleMaxBytes) or
          (ADescriptor.Package.TotalSourceMaxBytes <>
             FReg.Descriptor.Package.TotalSourceMaxBytes) or
          (ADescriptor.Package.MaxModules <>
             FReg.Descriptor.Package.MaxModules) or
          (ADescriptor.Package.MaxSpecifierBytes <>
             FReg.Descriptor.Package.MaxSpecifierBytes) or
          (ADescriptor.Package.MaxGraphDepth <>
             FReg.Descriptor.Package.MaxGraphDepth) then
    ADetail := 'Package limits'
  else
  begin
    for i := 0 to High(ADescriptor.Capabilities) do
      if ADescriptor.Capabilities[i] <> FReg.Descriptor.Capabilities[i] then
      begin
        ADetail := 'Capabilities';
        exit;
      end;
    ADetail := '';
    Result := True;
  end;
end;

function TPWebQuickJSPluginHost.StageGeneration(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8;
  out ALife: TPWebPluginLifecycleCode): TPWebQuickJSPlugin;
var
  src: IInvocationSource;
  plugin: TPWebQuickJSPlugin;
begin
  // called ONLY under FOpLock, and never under FLifeLock
  Result := nil;
  ACode := plcNone;
  ADetail := '';
  ALife := plfLoad;
  plugin := nil;
  src := nil;
  try
    src := FReg.SourceFactory();
  except
    on E: Exception do
      src := nil;
  end;
  if src = nil then
  begin
    InterlockedIncrement(FStagingFailures);
    ADetail := 'no invocation source';
    ALife := plfSource;
    exit;
  end;
  // The staged generation gets its OWN source, thread, engine, context,
  // module cache and graph. pweb.invoke stays refused for the whole of
  // its load (the frozen CAP-9B1 Loading gate), so staging can produce
  // no backend side effect while the old generation is still serving.
  if not PWebLoadQuickJSPackage(ADescriptor, src, FReg.OnSnapshot,
      FReg.ReadyWaitMs, plugin, ACode, ADetail) then
  begin
    // CAP-9B1 already destroyed the engine on its own thread, Quiesced
    // and Closed the source, and returned nil - there is nothing to
    // undo here, which is exactly why staging cannot damage the old
    // generation.
    InterlockedIncrement(FStagingFailures);
    exit;
  end;
  Inc(FGenSeq); // per host: plugin A's counter never perturbs plugin B
  plugin.GenerationId := FGenSeq;
  Result := plugin;
  ALife := plfOk;
end;

function TPWebQuickJSPluginHost.DrainInFlight: Boolean;
var
  deadline: Int64;
begin
  // never called under FLifeLock; FCurrent is already nil, so no new
  // call can take a reference and the count only falls
  deadline := GetTickCount64() + FReg.DrainMs;
  while InterlockedCompareExchange(FInFlight, 0, 0) <> 0 do
  begin
    RTLEventResetEvent(FDrained);
    if InterlockedCompareExchange(FInFlight, 0, 0) = 0 then
      break; // re-checked AFTER the reset: no lost wake-up
    RTLEventWaitFor(FDrained, 25); // bounded slices, so a missed signal
                                   // costs latency and never a hang
    if GetTickCount64() > deadline then
      break;
  end;
  Result := InterlockedCompareExchange(FInFlight, 0, 0) = 0;
  if not Result then
    InterlockedIncrement(FDrainTimeouts);
end;

procedure TPWebQuickJSPluginHost.RetireGeneration(
  APlugin: TPWebQuickJSPlugin; ADrained: Boolean);
begin
  if APlugin = nil then
    exit;
  // read the affinity counter BEFORE anything is unloaded or leaked:
  // it MUST be 0, and a retired generation is the last chance to see it
  InterlockedExchangeAdd(FRetiredWrongThread, APlugin.ExportWrongThreadCalls);
  // ADrained = False means a caller may STILL be inside
  // TPWebQuickJSPlugin.CallExport reading that object's result fields.
  // Freeing it would be a use-after-free even if the thread itself
  // joined cleanly, so an undrained generation is quarantined
  // unconditionally - the same leak-by-choice rule as an unjoinable
  // thread.
  if (APlugin.Unload(FReg.UnloadJoinMs) = puoQuarantined) or
     (not ADrained) then
  begin
    PWebQuarantineQuickJSPlugin(APlugin);
    InterlockedIncrement(FQuarantined);
  end
  else
    APlugin.Free;
end;

procedure TPWebQuickJSPluginHost.ReapTaintedGeneration(AGenerationId: Int64);
var
  gen: TPWebQuickJSPlugin;
  drained: Boolean;
begin
  // Identify the generation by ID, never by pointer: by the time a
  // tainting call gets here a concurrent Reload may already have retired
  // and freed that object, and a recycled allocation could make a
  // pointer comparison match the WRONG generation. Ids are monotonic
  // per host and never reused.
  EnterCriticalSection(FOpLock);
  try
    EnterCriticalSection(FLifeLock);
    try
      if (FCurrent = nil) or
         (FGenerationId <> AGenerationId) or
         (FState <> Ord(ppsRunning)) then
        exit; // already replaced or already closing - nothing to do
      gen := FCurrent;
      FCurrent := nil;
      FGenerationId := 0;
      FState := Ord(ppsQuiescing);
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    try
      gen.Source.Quiesce;
      gen.Source.Close;
    except
      // a closed/shutdown source must never abort teardown
    end;
    drained := DrainInFlight;
    RetireGeneration(gen, drained);
    // a tainted generation leaves the host with NO usable generation:
    // ppsFailed, from which only Unload is legal. It never silently
    // becomes Running again.
    SetState(ppsFailed);
  finally
    LeaveCriticalSection(FOpLock);
  end;
end;

function TPWebQuickJSPluginHost.Load(out ACode: TPWebPackageLoadCode;
  out ADetail: RawUtf8): TPWebPluginLifecycleCode;
var
  gen: TPWebQuickJSPlugin;
  life: TPWebPluginLifecycleCode;
begin
  ACode := plcNone;
  ADetail := '';
  EnterCriticalSection(FOpLock);
  try
    EnterCriticalSection(FLifeLock);
    try
      if FState <> Ord(ppsCreated) then
      begin
        ADetail := PWEB_PLUGIN_STATE_TEXT[TPWebPluginState(FState)];
        exit(plfBadState);
      end;
      FState := Ord(ppsLoading);
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    gen := StageGeneration(FReg.Descriptor, ACode, ADetail, life);
    if gen = nil then
    begin
      SetState(ppsFailed);
      exit(life);
    end;
    if InterlockedCompareExchange(FUnloadRequested, 0, 0) <> 0 then
    begin
      // an Unload arrived while this first generation was staging: it
      // is never published, and it is closed here rather than handed to
      // a host that is going away
      RetireGeneration(gen, {drained=}True);
      SetState(ppsFailed);
      ADetail := 'unload requested during load';
      exit(plfBadState);
    end;
    EnterCriticalSection(FLifeLock);
    try
      FCurrent := gen;
      FGenerationId := gen.GenerationId;
      FState := Ord(ppsRunning);
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    Result := plfOk;
  finally
    LeaveCriticalSection(FOpLock);
  end;
end;

function TPWebQuickJSPluginHost.CallExport(const AName: RawUtf8;
  const AArgs: TPWebJson; out AResult: TPWebJson;
  out ADetail: RawUtf8): TPWebExportCallCode;
var
  gen: TPWebQuickJSPlugin;
  genId: Int64;
begin
  AResult := '';
  ADetail := '';
  // pin the published generation under FLifeLock. The state test and
  // the in-flight increment happen together, so once a lifecycle
  // operation has set the state under the same lock, no NEW call can
  // ever take a reference to that generation.
  EnterCriticalSection(FLifeLock);
  try
    if (FState <> Ord(ppsRunning)) or (FCurrent = nil) then
      exit(peccUnavailable);
    gen := FCurrent;
    genId := FGenerationId;
    InterlockedIncrement(FInFlight);
  finally
    LeaveCriticalSection(FLifeLock);
  end;
  try
    // NO lock is held here: the call runs on the plugin thread and may
    // block there for up to ExportWaitMs, and a lifecycle lock held
    // across it would deadlock every reload.
    Result := gen.CallExport(AName, AArgs, AResult, ADetail,
      FReg.ExportWaitMs);
  finally
    if InterlockedDecrement(FInFlight) = 0 then
      RTLEventSetEvent(FDrained);
  end;
  if PWebExportCallTaints(Result) then
    // the generation broke the synchronous contract or blew a bound:
    // close it, bounded, before anything else can call it again
    ReapTaintedGeneration(genId);
end;

function TPWebQuickJSPluginHost.Reload(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  out ACode: TPWebPackageLoadCode;
  out ADetail: RawUtf8): TPWebPluginLifecycleCode;
var
  staged, old: TPWebQuickJSPlugin;
  life: TPWebPluginLifecycleCode;
  drained: Boolean;
begin
  ACode := plcNone;
  ADetail := '';
  EnterCriticalSection(FOpLock);
  try
    EnterCriticalSection(FLifeLock);
    try
      // Reload requires a Running generation, by ratified contract: a
      // Failed host has nothing to preserve, so restarting it would be
      // a new Load, not a reload.
      if (FState <> Ord(ppsRunning)) or (FCurrent = nil) then
      begin
        ADetail := PWEB_PLUGIN_STATE_TEXT[TPWebPluginState(FState)];
        exit(plfBadState);
      end;
      FState := Ord(ppsStaging);
    finally
      LeaveCriticalSection(FLifeLock);
    end;

    // ---- A. stage, with the old generation still serving ------------
    if not SameIdentity(ADescriptor, ADetail) then
    begin
      SetState(ppsRunning); // untouched
      ACode := plcDescriptor;
      exit(plfIdentity);
    end;
    staged := StageGeneration(ADescriptor, ACode, ADetail, life);
    if staged = nil then
    begin
      // EVERY staging failure lands here, and the old generation is
      // still published, still Running and completely unaltered.
      SetState(ppsRunning);
      exit(life);
    end;
    if InterlockedCompareExchange(FUnloadRequested, 0, 0) <> 0 then
    begin
      RetireGeneration(staged, {drained=}True);
      SetState(ppsRunning); // Unload is next in line on FOpLock
      ADetail := 'unload requested during staging';
      exit(plfBadState);
    end;

    // ---- B. commit --------------------------------------------------
    // B1. unpublish the old generation. From this instant CallExport
    //     sees ppsCommitting and is refused: the old generation accepts
    //     nothing more, and the new one is not published yet. That
    //     window is the ratified brief unavailable interval.
    EnterCriticalSection(FLifeLock);
    try
      old := FCurrent;
      FCurrent := nil;
      FGenerationId := 0;
      FState := Ord(ppsCommitting);
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    // NOTHING between here and the commit point can fail. Quiesce and
    // Close are non-blocking, idempotent and exception-guarded by the
    // frozen source contract, and a drain timeout only decides whether
    // the old generation is freed or quarantined - it can never stop
    // the new one from being published. Every operation that CAN fail
    // (descriptor, manifest, modules, engine, thread, source) already
    // happened during staging, which is why no rollback exists past
    // this line and none is needed.
    try
      old.Source.Quiesce;
      old.Source.Close;
    except
      // a closed/shutdown source must never abort a commit
    end;
    drained := DrainInFlight;
    // B2. THE COMMIT POINT - one atomic swap under one lock. Before it
    //     the old generation was authoritative; after it the new one is
    //     and the old one can never become authoritative again. At no
    //     instant do two generations accept invocations.
    EnterCriticalSection(FLifeLock);
    try
      FCurrent := staged;
      FGenerationId := staged.GenerationId;
      FState := Ord(ppsRunning);
      InterlockedIncrement(FCommits);
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    // B3. the old generation dies AFTER the swap, on its own thread.
    //     Its late completions settle into its OWN closed source and
    //     die at the frozen exactly-once gate; nothing it can still do
    //     reaches the new engine.
    RetireGeneration(old, drained);
    Result := plfOk;
  finally
    LeaveCriticalSection(FOpLock);
  end;
end;

function TPWebQuickJSPluginHost.Unload: TPWebPluginLifecycleCode;
var
  gen: TPWebQuickJSPlugin;
  drained: Boolean;
  before: LongInt;
begin
  // set BEFORE contending for FOpLock, so a Load or Reload already
  // staging can see it and refuse to publish what it built
  InterlockedExchange(FUnloadRequested, 1);
  before := InterlockedCompareExchange(FQuarantined, 0, 0);
  EnterCriticalSection(FOpLock);
  try
    EnterCriticalSection(FLifeLock);
    try
      if FState = Ord(ppsClosed) then
        exit(plfOk); // terminal and idempotent
      gen := FCurrent;
      FCurrent := nil;
      FGenerationId := 0;
      FState := Ord(ppsQuiescing); // new calls refused from here
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    if gen <> nil then
    begin
      // frozen source lifecycle: Quiesce cancels queued invocations,
      // Close cancels in-flight ones - and Close is what releases a
      // plugin thread blocked inside synchronous pweb.invoke, which is
      // why it comes BEFORE the drain rather than after it
      try
        gen.Source.Quiesce;
        gen.Source.Close;
      except
        // a closed/shutdown source must never abort teardown
      end;
      drained := DrainInFlight;
      RetireGeneration(gen, drained);
    end;
    EnterCriticalSection(FLifeLock);
    try
      FState := Ord(ppsClosed);
    finally
      LeaveCriticalSection(FLifeLock);
    end;
    if InterlockedCompareExchange(FQuarantined, 0, 0) <> before then
      // never report a clean close when quarantine was required
      Result := plfQuarantined
    else
      Result := plfOk;
  finally
    LeaveCriticalSection(FOpLock);
  end;
end;

function TPWebQuickJSPluginHost.ReloadTemplate: TPWebQuickJSPackageDescriptor;
begin
  Result := FReg.Descriptor;
end;

function TPWebQuickJSPluginHost.State: TPWebPluginState;
begin
  EnterCriticalSection(FLifeLock);
  try
    Result := TPWebPluginState(FState);
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

function TPWebQuickJSPluginHost.GenerationId: Int64;
begin
  EnterCriticalSection(FLifeLock);
  try
    Result := FGenerationId;
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

function TPWebQuickJSPluginHost.ExportNames: RawUtf8;
var
  i: Integer;
begin
  Result := '';
  // read under FLifeLock: outside it, FCurrent is either nil or a
  // generation no retire can have started on (a retire always nils the
  // slot under this lock first)
  EnterCriticalSection(FLifeLock);
  try
    if FCurrent = nil then
      exit;
    for i := 0 to FCurrent.ExportCount - 1 do
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + FCurrent.ExportName(i);
    end;
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

function TPWebQuickJSPluginHost.PrincipalId: Utf8String;
begin
  Result := FReg.Descriptor.PrincipalId;
end;

function TPWebQuickJSPluginHost.PluginId: Utf8String;
begin
  Result := FReg.Descriptor.PluginId;
end;

function TPWebQuickJSPluginHost.Commits: LongInt;
begin
  Result := InterlockedCompareExchange(FCommits, 0, 0);
end;

function TPWebQuickJSPluginHost.StagingFailures: LongInt;
begin
  Result := InterlockedCompareExchange(FStagingFailures, 0, 0);
end;

function TPWebQuickJSPluginHost.QuarantinedGenerations: LongInt;
begin
  Result := InterlockedCompareExchange(FQuarantined, 0, 0);
end;

function TPWebQuickJSPluginHost.DrainTimeouts: LongInt;
begin
  Result := InterlockedCompareExchange(FDrainTimeouts, 0, 0);
end;

function TPWebQuickJSPluginHost.ExportWrongThreadCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FRetiredWrongThread, 0, 0);
  EnterCriticalSection(FLifeLock);
  try
    if FCurrent <> nil then
      Inc(Result, FCurrent.ExportWrongThreadCalls);
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

end.
