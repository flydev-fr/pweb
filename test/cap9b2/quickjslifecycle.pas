program quickjslifecycle;

{ CAP-9B2: the QuickJS plugin LIFECYCLE + transactional reload harness.
  Headless and deterministic on all four targets - every line it writes
  to build/cap9b2/quickjs-lifecycle-corpus.txt is a decision, a native
  code, a generation id or a counter this program produced itself. No
  timing, no pointer, no engine text and no host path ever reaches the
  corpus, so the file bytes (and the sha256 the CAP-7F emitters record
  as quickjs_lifecycle_digest) are identical on windows-x86_64 /
  linux-x86_64 / macos-x86_64 / macos-arm64 by construction.

  WHAT RUNS: the UNCHANGED production runtime - frozen scheduler +
  CAP-8A policy + the REAL TMormotInvocationBridge (TRestServer.Uri)
  behind a counting/rendezvous decorator - with CAP-9B2 plugin HOSTS
  driving CAP-9B1 package generations as invocation sources.

  FIXTURES ARE GENERATED, NEVER COMMITTED (the CAP-9B1 discipline): the
  hostile corpus contains invalid UTF-8 and deliberately broken source,
  and a committed file would be at the mercy of core.autocrlf.

  DETERMINISM WITHOUT SLEEPS: every cross-thread ordering in this
  harness is a rendezvous - the bridge decorator parks a named method
  until the test releases it - never a delay. The only bounded waits
  are the ratified lifecycle budgets themselves.

  L1-L40 matrix (the numbers referenced by the CAP-9B2 spec):
    L1  Created -> Loading -> Running   L21 reload id mismatch preserves old
    L2  load failure -> no generation   L22 reload source failure preserves old
    L3  CallExport only in Running      L23 reload changes generation
    L4  missing export rejected         L24 reload changes behaviour
    L5  non-callable export rejected    L25 old global state cannot cross
    L6  JSON argument/result round-trip L26 old completion cannot reach new
    L7  ordinary JS exception contained L27 old and new never both accept
    L8  PWebError semantics preserved   L28 runtime grants keyed by principal
    L9  Promise return rejected         L29 denied stays denied across reload
    L10 pending job rejected            L30 any package version accepted
    L11 CPU limit taints and closes     L31 CallExport/Reload deterministic
    L12 memory limit closes safely      L32 CallExport/Unload deterministic
    L13 stack limit closes safely       L33 Reload/Reload serialised
    L14 clean Unload                    L34 Reload/Unload no deadlock
    L15 repeated Unload idempotent      L35 two plugins isolated
    L16 unload during pweb.invoke       L36 A reload leaves B operational
    L17 late completion harmless        L37 A unload leaves B operational
    L18 unload during infinite loop     L38 quarantine frees nothing
    L19 reload bad manifest preserves   L39 100 load/reload/unload cycles
    L20 reload syntax error preserves   L40 CAP-9B1 packages load unchanged

  Markers:
      quickjslifecycle: QUICKJS LIFECYCLE PASS
      quickjslifecycle: QUICKJS LIFECYCLE FAIL (<reason>)
  Writes build/cap9b2/quickjslifecycle-<target>.json (schema 1,
  overall PASS|FAIL) and build/cap9b2/quickjs-lifecycle-corpus.txt. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.json,
  mormot.core.variants,
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  mormot.script.core,
  mormot.script.quickjs,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.folder,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.script.package,
  pweb.script.quickjs,
  pweb.script.plugin;

const
  LOG_PREFIX = 'quickjslifecycle';
  MARKER_PASS = 'quickjslifecycle: QUICKJS LIFECYCLE PASS';
  MARKER_FAIL = 'quickjslifecycle: QUICKJS LIFECYCLE FAIL';
  {$ifdef OSDARWIN}
    {$ifdef CPUAARCH64}
    TARGET_ID = 'macos-arm64';
    {$else}
    TARGET_ID = 'macos-x86_64';
    {$endif CPUAARCH64}
  {$else}
  {$ifdef OSLINUX}
  TARGET_ID = 'linux-x86_64';
  {$else}
  TARGET_ID = 'windows-x86_64';
  {$endif OSLINUX}
  {$endif OSDARWIN}

  CORPUS_FILE = 'build/cap9b2/quickjs-lifecycle-corpus.txt';
  READY_WAIT_MS = 20000;
  EXPORT_WAIT_MS = 20000;
  JOIN_MS = 30000;
  DRAIN_MS = 25000;
  RENDEZVOUS_MS = 20000;

  ID_CALC: RawUtf8 = 'plugin:calculator';
  ID_REP: RawUtf8 = 'plugin:reporting';
  PKG_ID: RawUtf8 = 'quickjs.calculator';
  ENTRY: RawUtf8 = 'main.js';

  CAP_CALC = 'calculator.add';
  CAP_OPEN = 'external.open';
  M_ADD = 'CalculatorService.Add';
  M_OPEN = 'pweb.openExternal';

  { The ratified set of answers a version() call may produce while a
    lifecycle operation runs underneath it. Anything else - a crash, a
    code the contract does not allow at that moment, an answer from a
    generation that should no longer be serving - fails the row by
    NAME rather than by an opaque digest mismatch. }
  ACCEPT_RUNNING: RawUtf8 =
    '|ok:1|ok:2|ok:3|unavailable|busy|';

type
  ICalculatorService = interface(IInvokable)
    ['{4B0E2C31-58D9-4A0C-9B7E-6A1F0D3C82E4}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Counting + RENDEZVOUS bridge decorator. When Hold is armed, the
    first Add that arrives signals Arrived and parks until Release is
    set - which is how every cross-generation ordering in this harness
    is made deterministic without a single sleep. }
  TRendezvousBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TSnapshotAdapter = class
  public
    function Snapshot(const APrincipalId: Utf8String): TPWebCapabilities;
  end;

  { The per-generation invocation-source factory a host is registered
    with. FFail makes RegisterSource "fail" without touching the frozen
    scheduler - the injectable row L22 needs. }
  TSourceFactory = class
  private
    FFail: Boolean;
    FPreClosed: Boolean;
    FMade: LongInt;
  public
    function Make: IInvocationSource;
    property Fail: Boolean read FFail write FFail;
    { hand back a real, registered source that is already pssClosed - the
      shape RegisterSource returns once the scheduler is shutting down.
      A generation published over one would look Running and answer
      runtime_closed to everything. }
    property PreClosed: Boolean read FPreClosed write FPreClosed;
    function Made: LongInt;
  end;

  TPkgFile = record
    Name: RawUtf8;
    Content: RawByteString;
  end;
  TPkgFiles = array of TPkgFile;

  { Worker used by the concurrency rows (L31-L34). It runs ONE named
    lifecycle or call operation on its own thread and records the
    outcome as a token, so the corpus records what happened rather than
    when. }
  TOpKind = (okCallExport, okReload, okUnload);

  TOpThread = class(TThread)
  private
    FHost: TPWebQuickJSPluginHost;
    FKind: TOpKind;
    FStore: IAssetStore;
    FStart: PRTLEvent;
    FDoneEv: PRTLEvent;
    FToken: RawUtf8;
    FRepeat: Integer;
    FExport: RawUtf8;
    FArgs: TPWebJson;
    FAccept: RawUtf8;  // '|tok|tok|' set; '' records the raw token
  public
    constructor Create(AHost: TPWebQuickJSPluginHost; AKind: TOpKind;
      const AStore: IAssetStore; ARepeat: Integer;
      const AExport: RawUtf8 = 'version'; const AArgs: TPWebJson = 'null';
      const AAccept: RawUtf8 = '');
    destructor Destroy; override;
    procedure Execute; override;
    procedure Go;
    function WaitToken: RawUtf8;
  end;

var
  CorpusLines: RawUtf8;
  FailReasons: RawUtf8;
  // ledgers (the ones the aggregator cross-checks)
  TwoActiveGenerations: LongInt;   // MUST stay 0
  StaleCompletion: LongInt;        // MUST stay 0
  QuarantineInjected: LongInt;     // exactly 1 (the deliberate L38 row)
  QuarantineUnexpected: LongInt;   // MUST stay 0
  ReloadLostOld: LongInt;          // MUST stay 0
  ExportWrongThread: LongInt;      // MUST stay 0
  DeniedBridgeAdd: LongInt;        // MUST stay 0
  OpenerReached: LongInt;          // MUST stay 0
  NativeServiceAdd: LongInt;
  CommitCount: LongInt;
  // rendezvous
  HoldArmed: LongInt;
  HoldArrived: PRTLEvent;
  HoldRelease: PRTLEvent;
  HoldFinished: PRTLEvent;  // the held worker has RETURNED from the bridge
  HoldFinishedFlag: LongInt;
  HoldHits: LongInt;
  NeverEv: PRTLEvent;  // never set: the one legitimate bounded slice
  // runtime under test
  gScheduler: TInvocationScheduler;
  gSchedulerRef: IInvocationScheduler;
  gPolicy: TPWebCapabilityPolicy;
  gPolicyRef: ICapabilityPolicy;
  gBridge: IInvocationBridge;
  gServer: TRestServerFullMemory;
  gRealBridge: IInvocationBridge;
  gSnap: TSnapshotAdapter;
  gSnapCb: TPWebQuickJSSnapshotEvent;
  root: TFileName;
  workDir: TFileName;
  fixtureSeq: Integer;

{ ---- corpus + failure helpers ------------------------------------------- }

procedure Emit(const ALine: RawUtf8);
begin
  CorpusLines := CorpusLines + ALine + #10;
end;

procedure Fail(const AReason: RawUtf8);
begin
  if FailReasons <> '' then
    FailReasons := FailReasons + '; ';
  FailReasons := FailReasons + AReason;
end;

procedure Expect(ACond: Boolean; const AReason: RawUtf8);
begin
  if not ACond then
    Fail(AReason);
end;

function YesNo(ACond: Boolean): RawUtf8;
begin
  if ACond then
    Result := 'yes'
  else
    Result := 'no';
end;

function IntStr(AValue: Int64): RawUtf8;
begin
  Result := Utf8String(IntToStr(AValue));
end;

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := AValue;
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or (Result[i] < #$20) then
      Result[i] := '''';
end;

function Bytes(const AValues: array of Byte): RawByteString;
var
  i: PtrInt;
begin
  SetLength(Result, Length(AValues));
  for i := 0 to High(AValues) do
    Result[i + 1] := AnsiChar(AValues[i]);
end;

procedure RmTree(const Dir: TFileName);
var
  sr: TSearchRec;
begin
  if (Dir = '') or
     not DirectoryExists(Dir) then
    exit;
  if FindFirst(Dir + PathDelim + '*', faAnyFile{%H-}, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') then
        continue;
      if (sr.Attr and faDirectory{%H-}) <> 0 then
      begin
        if (sr.Attr and $00000400) <> 0 then // junction: do not recurse
          RemoveDir(Dir + PathDelim + sr.Name)
        else
          RmTree(Dir + PathDelim + sr.Name);
      end
      else
        SysUtils.DeleteFile(Dir + PathDelim + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  RemoveDir(Dir);
end;

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
  dir := Executable.ProgramFilePath;
  for i := 1 to 8 do
  begin
    if FileExists(dir + 'webview.lock') then
      exit(dir);
    parent := ExtractFilePath(ExcludeTrailingPathDelimiter(dir));
    if (parent = '') or (parent = dir) then
      break;
    dir := parent;
  end;
  Result := '';
end;

{ ---- service, bridge, policy (CAP-9A/B1 shapes, unchanged) --------------- }

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedIncrement(NativeServiceAdd);
  Result := a + b;
end;

constructor TRendezvousBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function TRendezvousBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  held: Boolean;
begin
  held := False;
  if Method = M_OPEN then
  begin
    // must never be reached: neither principal holds external.open, so
    // the CAP-8A policy refuses before routing
    InterlockedIncrement(OpenerReached);
    exit(PWebDefaultErrorResult(pecMethodNotFound));
  end;
  if Method = M_ADD then
  begin
    if Context.PrincipalId = ID_REP then
      // a denied principal must never reach the bridge at all
      InterlockedIncrement(DeniedBridgeAdd);
    if InterlockedCompareExchange(HoldArmed, 0, 1) = 1 then
    begin
      // the FIRST arrival claims the rendezvous (the CAS disarms it),
      // parks, and lets the test drive the lifecycle underneath it
      held := True;
      InterlockedIncrement(HoldHits);
      RTLEventSetEvent(HoldArrived);
      RTLEventWaitFor(HoldRelease, RENDEZVOUS_MS);
    end;
  end;
  Result := FInner.Invoke(Context, Method, Args, Token);
  if held then
  begin
    // the released worker has now really been through the whole bridge.
    // Without this barrier a test reading the service ledger straight
    // after the release would race the worker and record whatever it
    // happened to see - which is exactly how a corpus stops being
    // identical on four targets.
    InterlockedExchange(HoldFinishedFlag, 1);
    RTLEventSetEvent(HoldFinished);
  end;
end;

function TSnapshotAdapter.Snapshot(
  const APrincipalId: Utf8String): TPWebCapabilities;
begin
  Result := gPolicy.SnapshotCapabilities(APrincipalId);
end;

function TSourceFactory.Make: IInvocationSource;
var
  lim: TPWebSourceLimits;
begin
  InterlockedIncrement(FMade);
  if FFail then
    // the injectable source-registration failure. Deliberately NOT a
    // mutated scheduler: the frozen RegisterSource contract is not this
    // shard's to bend, and a host that cannot obtain a source must
    // refuse the staging either way.
    exit(nil);
  lim := Default(TPWebSourceLimits);
  lim.MaxConcurrent := 4;
  lim.MaxQueueSize := 16;
  Result := gScheduler.RegisterSource(lim);
  if FPreClosed then
  begin
    Result.Quiesce;
    Result.Close;
  end;
end;

function TSourceFactory.Made: LongInt;
begin
  Result := InterlockedCompareExchange(FMade, 0, 0);
end;

function BuildPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALC, CAP_OPEN]);
    b.SetPrincipalCapabilities(ID_CALC, [CAP_CALC]);
    b.SetPrincipalCapabilities(ID_REP, []); // explicit empty = no rights
    b.MapMethod(M_ADD, [CAP_CALC]);
    b.MapMethod(M_OPEN, [CAP_OPEN]);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ ---- fixtures ------------------------------------------------------------ }

procedure AddFile(var AFiles: TPkgFiles; const AName: RawUtf8;
  const AContent: RawByteString);
var
  n: PtrInt;
begin
  n := Length(AFiles);
  SetLength(AFiles, n + 1);
  AFiles[n].Name := AName;
  AFiles[n].Content := AContent;
end;

procedure ReplaceFile(var AFiles: TPkgFiles; const AName: RawUtf8;
  const AContent: RawByteString);
var
  i: PtrInt;
begin
  for i := 0 to High(AFiles) do
    if AFiles[i].Name = AName then
    begin
      AFiles[i].Content := AContent;
      exit;
    end;
  AddFile(AFiles, AName, AContent);
end;

procedure RemoveFile(var AFiles: TPkgFiles; const AName: RawUtf8);
var
  i, j: PtrInt;
begin
  for i := 0 to High(AFiles) do
    if AFiles[i].Name = AName then
    begin
      for j := i to High(AFiles) - 1 do
        AFiles[j] := AFiles[j + 1];
      SetLength(AFiles, Length(AFiles) - 1);
      exit;
    end;
end;

function ManifestFor(const AVersion: RawUtf8): RawUtf8;
begin
  Result := '{"schema":1,"id":"quickjs.calculator","version":"' + AVersion +
    '","entry":"main.js"}';
end;

const
  UNIT_JS: RawUtf8 = 'export const unit = 1;'#10;

  { The one plugin body, parameterised by version. Everything the host
    calls is registered on the NATIVE pwebExports table; nothing here
    can touch its own lifecycle. }
  MAIN_TEMPLATE: RawUtf8 =
    'import { unit } from "./lib/unit.js";'#10 +
    'globalThis.__gen = %V;'#10 +
    'pwebExports.version = function () { return %V; };'#10 +
    'pwebExports.add = function (a) { return a.x + a.y + unit; };'#10 +
    'pwebExports.echo = function (a) { return a; };'#10 +
    'pwebExports.boom = function () { throw new Error("plugin boom"); };'#10 +
    'pwebExports.svcAdd = function (a) {'#10 +
    '  return pweb.invoke("CalculatorService.Add", { a: a.a, b: a.b });'#10 +
    '};'#10 +
    'pwebExports.svcErr = function () {'#10 +
    '  try {'#10 +
    '    pweb.invoke("CalculatorService.Add", { a: 1, b: 1 });'#10 +
    '    return { code: "allowed", name: "none" };'#10 +
    '  } catch (e) { return { code: String(e.code), name: String(e.name) }; }'#10 +
    '};'#10 +
    'pwebExports.openErr = function () {'#10 +
    '  try {'#10 +
    '    pweb.invoke("pweb.openExternal", { url: "https://x" });'#10 +
    '    return "allowed";'#10 +
    '  } catch (e) { return String(e.code); }'#10 +
    '};'#10 +
    'pwebExports.leak = function () { globalThis.__leak = "here"; return "set"; };'#10 +
    'pwebExports.seen = function () { return typeof globalThis.__leak; };'#10 +
    'pwebExports.prom = function () { return Promise.resolve(1); };'#10 +
    'pwebExports.job = function () {'#10 +
    '  Promise.resolve().then(function () { globalThis.__ran = 1; });'#10 +
    '  return 1;'#10 +
    '};'#10 +
    'pwebExports.spin = function () { for (;;) {} };'#10 +
    // the rendezvous anchor: park in the bridge so the harness KNOWS
    // this call is in flight, then run away. The catch is deliberate -
    // an Unload racing the park would otherwise cancel the invocation
    // and the runaway half would never start.
    'pwebExports.holdThenSpin = function () {'#10 +
    '  try { pweb.invoke("CalculatorService.Add", { a: 1, b: 1 }); }'#10 +
    '  catch (e) { }'#10 +
    '  for (;;) {}'#10 +
    '};'#10 +
    'pwebExports.deep = function () {'#10 +
    '  function r(n) { return r(n + 1); } return r(0);'#10 +
    '};'#10 +
    'pwebExports.hog = function () {'#10 +
    '  var a = []; for (;;) { a.push(new Array(200000).join("x")); }'#10 +
    '};'#10 +
    'pwebExports.cyc = function () { var o = {}; o.self = o; return o; };'#10 +
    'pwebExports.undef = function () { return undefined; };'#10 +
    'pwebExports.notFn = 7;'#10 +
    // NON-ENUMERABLE, deliberately: the native snapshot must be the
    // table's own-property set, not just its enumerable half, or an
    // export would sit visibly in the table and answer no_export
    'Object.defineProperty(pwebExports, "hidden",'#10 +
    '  { value: function () { return "hidden"; } });'#10;

function MainJs(AVersion: Integer): RawUtf8;
begin
  Result := StringReplaceAll(MAIN_TEMPLATE, '%V', IntStr(AVersion));
end;

function PackageV(AVersion: Integer; const AManifestVersion: RawUtf8): TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', ManifestFor(AManifestVersion));
  AddFile(Result, 'main.js', MainJs(AVersion));
  AddFile(Result, 'lib/unit.js', UNIT_JS);
end;

procedure WriteFolderPackage(const ADir: TFileName; const AFiles: TPkgFiles);
var
  i, j: PtrInt;
  full: TFileName;
begin
  if not ForceDirectories(ADir) then
    raise Exception.CreateFmt('cannot create %s', [ADir]);
  for i := 0 to High(AFiles) do
  begin
    full := IncludeTrailingPathDelimiter(ADir);
    for j := 1 to Length(AFiles[i].Name) do
      if AFiles[i].Name[j] = '/' then
        full := full + PathDelim
      else
        full := full + AFiles[i].Name[j];
    ForceDirectories(ExtractFileDir(full));
    if not FileFromString(AFiles[i].Content, full) then
      raise Exception.CreateFmt('cannot write %s', [full]);
  end;
end;

function StoreOf(const AFiles: TPkgFiles): IAssetStore;
var
  dir: TFileName;
begin
  Inc(fixtureSeq);
  dir := IncludeTrailingPathDelimiter(workDir) +
    TFileName('pkg' + IntToStr(fixtureSeq));
  WriteFolderPackage(dir, AFiles);
  Result := TFolderAssetStore.Create(dir);
end;

{ ---- host construction --------------------------------------------------- }

var
  gFactory: TSourceFactory;

function DescriptorFor(APrincipal: Integer;
  const AStore: IAssetStore): TPWebQuickJSPackageDescriptor;
begin
  Result := Default(TPWebQuickJSPackageDescriptor);
  if APrincipal = 0 then
  begin
    Result.PrincipalId := ID_CALC;
    Result.PluginId := 'calculator';
  end
  else
  begin
    Result.PrincipalId := ID_REP;
    Result.PluginId := 'reporting';
  end;
  // the construction-time capabilities are host configuration, captured
  // ONCE: a reload may never move them, and every invocation refreshes
  // its own snapshot through the frozen CAP-8 policy anyway
  Result.Capabilities := gPolicy.SnapshotCapabilities(Result.PrincipalId);
  Result.PackageStore := AStore;
  Result.ExpectedPackageId := PKG_ID;
  Result.ExpectedEntryPoint := ENTRY;
  Result.Engine := PWEB_QUICKJS_DEFAULT_LIMITS;
  Result.Package := PWEB_PACKAGE_DEFAULT_LIMITS;
end;

function NewHost(APrincipal: Integer; const AStore: IAssetStore;
  AJoinMs: Integer = JOIN_MS): TPWebQuickJSPluginHost;
var
  reg: TPWebPluginRegistration;
begin
  reg := Default(TPWebPluginRegistration);
  reg.Descriptor := DescriptorFor(APrincipal, AStore);
  reg.OnSnapshot := gSnapCb;
  reg.SourceFactory := gFactory.Make; // Delphi-mode event assignment
  reg.ReadyWaitMs := READY_WAIT_MS;
  reg.ExportWaitMs := EXPORT_WAIT_MS;
  reg.UnloadJoinMs := AJoinMs;
  reg.DrainMs := DRAIN_MS;
  Result := TPWebQuickJSPluginHost.Create(reg);
end;

{ ---- one call, reduced to a corpus token --------------------------------- }

function CallToken(AHost: TPWebQuickJSPluginHost; const AName: RawUtf8;
  const AArgs: TPWebJson): RawUtf8;
var
  res: TPWebJson;
  detail: RawUtf8;
  code: TPWebExportCallCode;
begin
  code := AHost.CallExport(AName, AArgs, res, detail);
  if AHost.ExportWrongThreadCalls > 0 then
    // an export that executed off its generation's owning thread is the
    // finding, whatever the call itself returned
    InterlockedExchange(ExportWrongThread, 1);
  if code = peccOk then
    Result := 'ok:' + RawUtf8(res)
  else
    // NEVER the detail: it can carry engine-phrased text, which would
    // turn a target hiccup into an opaque digest mismatch instead of a
    // named failure
    Result := PWEB_EXPORT_CALL_TEXT[code];
end;

function LoadToken(AHost: TPWebQuickJSPluginHost): RawUtf8;
var
  code: TPWebPackageLoadCode;
  detail: RawUtf8;
  life: TPWebPluginLifecycleCode;
begin
  life := AHost.Load(code, detail);
  Result := PWEB_PLUGIN_LIFECYCLE_TEXT[life];
  // only a real package-load code is appended: a state or identity
  // refusal never produced one, and '/ok' would read as a contradiction
  if code <> plcNone then
    Result := Result + '/' + PWEB_PACKAGE_LOAD_TEXT[code];
end;

function ReloadToken(AHost: TPWebQuickJSPluginHost;
  const AStore: IAssetStore): RawUtf8;
var
  desc: TPWebQuickJSPackageDescriptor;
  code: TPWebPackageLoadCode;
  detail: RawUtf8;
  life: TPWebPluginLifecycleCode;
begin
  desc := AHost.ReloadTemplate;
  desc.PackageStore := AStore;
  life := AHost.Reload(desc, code, detail);
  Result := PWEB_PLUGIN_LIFECYCLE_TEXT[life];
  if code <> plcNone then
    Result := Result + '/' + PWEB_PACKAGE_LOAD_TEXT[code];
end;

function StateToken(AHost: TPWebQuickJSPluginHost): RawUtf8;
begin
  Result := PWEB_PLUGIN_STATE_TEXT[AHost.State];
end;

{ Bounded wait for a state the harness has ARRANGED to persist (the
  reload's Committing window lasts until the held call is released, by
  construction). NeverEv is never set: this is a bounded slice, not a
  wait on a flag that could be missed. }
function WaitState(AHost: TPWebQuickJSPluginHost; AState: TPWebPluginState;
  AMs: Integer): Boolean;
var
  i: Integer;
begin
  for i := 1 to AMs div 5 do
  begin
    if AHost.State = AState then
      exit(True);
    RTLEventWaitFor(NeverEv, 5);
  end;
  Result := AHost.State = AState;
end;

{ ---- the concurrency worker ---------------------------------------------- }

constructor TOpThread.Create(AHost: TPWebQuickJSPluginHost; AKind: TOpKind;
  const AStore: IAssetStore; ARepeat: Integer;
  const AExport: RawUtf8; const AArgs: TPWebJson; const AAccept: RawUtf8);
begin
  inherited Create({suspended=}True);
  FHost := AHost;
  FKind := AKind;
  FStore := AStore;
  FRepeat := ARepeat;
  FExport := AExport;
  FArgs := AArgs;
  FAccept := AAccept;
  FStart := RTLEventCreate;
  FDoneEv := RTLEventCreate;
  Start;
end;

destructor TOpThread.Destroy;
begin
  inherited Destroy;
  if FStart <> nil then
    RTLEventDestroy(FStart);
  if FDoneEv <> nil then
    RTLEventDestroy(FDoneEv);
end;

procedure TOpThread.Go;
begin
  RTLEventSetEvent(FStart);
end;

function TOpThread.WaitToken: RawUtf8;
begin
  RTLEventWaitFor(FDoneEv, 120000);
  Result := FToken;
end;

procedure TOpThread.Execute;
var
  i: Integer;
  t: RawUtf8;
begin
  RTLEventWaitFor(FStart, 120000);
  try
    case FKind of
      okCallExport:
        if FAccept = '' then
          // one call, recorded verbatim
          FToken := CallToken(FHost, FExport, FArgs)
        else
        begin
          // many calls, each of which must land in the ratified set of
          // deterministic answers - never a crash, never a code the
          // lifecycle contract does not allow at that moment
          FToken := '';
          for i := 1 to FRepeat do
          begin
            t := CallToken(FHost, FExport, FArgs);
            if Pos('|' + t + '|', FAccept) = 0 then
              FToken := FToken + '!' + t;
          end;
          if FToken = '' then
            FToken := 'all-deterministic';
        end;
      okReload:
        FToken := ReloadToken(FHost, FStore);
      okUnload:
        FToken := PWEB_PLUGIN_LIFECYCLE_TEXT[FHost.Unload];
    end;
  except
    on E: Exception do
      FToken := 'raised';
  end;
  RTLEventSetEvent(FDoneEv);
end;

{ ---- L-matrix ------------------------------------------------------------ }

procedure LBasics;
var
  h: TPWebQuickJSPluginHost;
  s: IAssetStore;
  files: TPkgFiles;
begin
  files := PackageV(1, '1.0.0');
  s := StoreOf(files);
  h := NewHost(0, s);
  try
    // L1 Created -> Loading -> Running
    Emit('L1 state0=' + StateToken(h) + ' gen0=' + IntStr(h.GenerationId));
    Expect(h.State = ppsCreated, 'L1 a fresh host is not Created');
    // L3 (first half): no call is accepted before Running
    Emit('L3 before_load=' + CallToken(h, 'version', 'null'));
    Expect(CallToken(h, 'version', 'null') = 'unavailable',
      'L3 CallExport was accepted before Running');
    Emit('L1 load=' + LoadToken(h) + ' state=' + StateToken(h) +
      ' gen=' + IntStr(h.GenerationId));
    Expect(h.State = ppsRunning, 'L1 the host is not Running after Load');
    Expect(h.GenerationId = 1, 'L1 the first generation id is not 1');
    // the sealed export snapshot, in registration order
    Emit('L1 exports=' + h.ExportNames);
    Expect(h.ExportNames <> '', 'L1 the export snapshot is empty');

    // L4 / L5 the two negative lookups
    Emit('L4 missing=' + CallToken(h, 'nope', 'null'));
    Expect(CallToken(h, 'nope', 'null') = 'no_export',
      'L4 a missing export was not rejected');
    Emit('L4 prototype=' + CallToken(h, 'toString', 'null'));
    Expect(CallToken(h, 'toString', 'null') = 'no_export',
      'L4 a prototype member resolved as an export');
    Emit('L4 badname=' + CallToken(h, 'a.b', 'null'));
    Expect(CallToken(h, 'a.b', 'null') = 'bad_name',
      'L4 a dotted name was not refused by the grammar');
    Emit('L5 notcallable=' + CallToken(h, 'notFn', 'null'));
    Expect(CallToken(h, 'notFn', 'null') = 'not_callable',
      'L5 a non-callable export was not rejected');
    // a NON-ENUMERABLE own export is still a real export: the snapshot is
    // the table's own-property set, so it must be reachable
    Emit('L5 nonenumerable=' + CallToken(h, 'hidden', 'null'));
    Expect(CallToken(h, 'hidden', 'null') = 'ok:"hidden"',
      'L5 a non-enumerable own export was not reachable');

    // L6 JSON argument/result round-trip
    Emit('L6 add=' + CallToken(h, 'add', '{"x":40,"y":1}'));
    Expect(CallToken(h, 'add', '{"x":40,"y":1}') = 'ok:42',
      'L6 the JSON argument did not round-trip');
    // ASCII only, deliberately: a high-byte literal in Pascal source is
    // re-encoded through the unit's code page, which would make the
    // corpus depend on the compiler's idea of the source encoding
    Emit('L6 echo=' + CallToken(h, 'echo',
      '{"a":[1,2,{"b":null}],"c":"text","d":true}'));
    Emit('L6 undef=' + CallToken(h, 'undef', 'null'));
    Expect(CallToken(h, 'undef', 'null') = 'ok:null',
      'L6 an undefined return did not become JSON null');
    Emit('L6 badargs=' + CallToken(h, 'add', '{not json'));
    Expect(CallToken(h, 'add', '{not json') = 'bad_args',
      'L6 a malformed JSON argument was accepted');
    Emit('L6 badresult=' + CallToken(h, 'cyc', 'null'));
    Expect(CallToken(h, 'cyc', 'null') = 'bad_result',
      'L6 a circular result was accepted');

    // L7 an ordinary exception is CONTAINED: the generation survives
    Emit('L7 threw=' + CallToken(h, 'boom', 'null') +
      ' state=' + StateToken(h));
    Expect(CallToken(h, 'boom', 'null') = 'threw',
      'L7 an ordinary plugin exception was not contained');
    Expect(h.State = ppsRunning, 'L7 an ordinary exception closed the generation');
    Emit('L7 after=' + CallToken(h, 'add', '{"x":1,"y":1}'));
    Expect(CallToken(h, 'add', '{"x":1,"y":1}') = 'ok:3',
      'L7 the generation stopped working after a contained exception');

    // L8 PWebError semantics survive inside the plugin
    Emit('L8 allowed=' + CallToken(h, 'svcErr', 'null'));
    Emit('L8 denied_open=' + CallToken(h, 'openErr', 'null'));
    Expect(CallToken(h, 'openErr', 'null') = 'ok:"forbidden"',
      'L8 the plugin did not observe a PWebError-shaped forbidden');
    Emit('L8 svcadd=' + CallToken(h, 'svcAdd', '{"a":20,"b":22}'));
    Expect(CallToken(h, 'svcAdd', '{"a":20,"b":22}') = 'ok:42',
      'L8 Add did not travel scheduler -> policy -> mORMot');

    // L14 clean unload, L15 idempotence, L3 (second half)
    Emit('L14 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload] +
      ' state=' + StateToken(h));
    Expect(h.State = ppsClosed, 'L14 the host is not Closed after Unload');
    Emit('L15 unload2=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload] +
      ' state=' + StateToken(h));
    Expect(h.State = ppsClosed, 'L15 a repeated Unload moved the state');
    Emit('L3 after_unload=' + CallToken(h, 'version', 'null'));
    Expect(CallToken(h, 'version', 'null') = 'unavailable',
      'L3 CallExport was accepted after Unload');
    Emit('L15 reload_after_close=' + ReloadToken(h, s));
    Emit('L15 load_after_close=' + LoadToken(h));
  finally
    h.Free;
  end;
end;

procedure LLoadFailure;
var
  h: TPWebQuickJSPluginHost;
  files: TPkgFiles;
  s: IAssetStore;
begin
  // L2 a failed FIRST load leaves no generation and no Running state
  files := PackageV(1, '1.0.0');
  ReplaceFile(files, 'main.js', 'import { unit } from "./lib/unit.js"; syntax ~~ error');
  s := StoreOf(files);
  h := NewHost(0, s);
  try
    Emit('L2 load=' + LoadToken(h) + ' state=' + StateToken(h) +
      ' gen=' + IntStr(h.GenerationId));
    Expect(h.State = ppsFailed, 'L2 a failed load did not land in Failed');
    Expect(h.GenerationId = 0, 'L2 a failed load published a generation');
    Emit('L2 call=' + CallToken(h, 'version', 'null'));
    Expect(CallToken(h, 'version', 'null') = 'unavailable',
      'L2 a Failed host accepted an export call');
    // a Failed host NEVER silently becomes Running
    Emit('L2 reload=' + ReloadToken(h, s) + ' state=' + StateToken(h));
    Expect(h.State = ppsFailed, 'L2 Reload moved a Failed host');
    Emit('L2 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload] +
      ' state=' + StateToken(h));
    Expect(h.State = ppsClosed, 'L2 a Failed host did not close');
  finally
    h.Free;
  end;
  // L40 a CAP-9B1-shaped package - one that never touches pwebExports -
  // still loads, with an EMPTY export set. The export table is purely
  // additive; nothing in the frozen B1 corpus can see it.
  files := nil;
  AddFile(files, 'plugin.json', ManifestFor('1.0.0'));
  AddFile(files, 'main.js',
    'import { unit } from "./lib/unit.js";'#10 +
    'globalThis.pluginAdd = function (a, b) { return a + b + unit - 1; };'#10);
  AddFile(files, 'lib/unit.js', UNIT_JS);
  h := NewHost(0, StoreOf(files));
  try
    Emit('L40 load=' + LoadToken(h) + ' exports=[' + h.ExportNames + ']' +
      ' count=' + IntStr(Length(h.ExportNames)));
    Expect(h.State = ppsRunning, 'L40 a B1-shaped package did not load');
    Expect(h.ExportNames = '', 'L40 a B1-shaped package published exports');
    Emit('L40 call=' + CallToken(h, 'anything', 'null'));
    Expect(CallToken(h, 'anything', 'null') = 'no_export',
      'L40 an export was resolvable with an empty snapshot');
  finally
    h.Free;
  end;
end;

procedure LTaints;

  procedure OneTaint(const ATag, AExport: RawUtf8; ALimit: Boolean);
  var
    h: TPWebQuickJSPluginHost;
    desc: TPWebQuickJSPackageDescriptor;
    reg: TPWebPluginRegistration;
    s: IAssetStore;
    tok: RawUtf8;
  begin
    s := StoreOf(PackageV(1, '1.0.0'));
    reg := Default(TPWebPluginRegistration);
    desc := DescriptorFor(0, s);
    if ALimit then
    begin
      // tight bounds so the limit fires fast and deterministically; the
      // CPU bound stays >= 1s because zero is refused for a package load
      desc.Engine.TimeoutSeconds := 1;
      desc.Engine.MemoryLimitBytes := 8 shl 20;
      desc.Engine.StackLimitBytes := 128 shl 10;
    end;
    reg.Descriptor := desc;
    reg.OnSnapshot := gSnapCb;
    reg.SourceFactory := gFactory.Make; // Delphi-mode event assignment
    reg.ReadyWaitMs := READY_WAIT_MS;
    reg.ExportWaitMs := EXPORT_WAIT_MS;
    reg.UnloadJoinMs := JOIN_MS;
    reg.DrainMs := DRAIN_MS;
    h := TPWebQuickJSPluginHost.Create(reg);
    try
      Expect(LoadToken(h) = 'ok', ATag + ' the fixture did not load');
      tok := CallToken(h, AExport, 'null');
      Emit(ATag + ' call=' + tok + ' state=' + StateToken(h) +
        ' gen=' + IntStr(h.GenerationId));
      Expect(h.State = ppsFailed,
        ATag + ' a tainting call left the host in ' + StateToken(h));
      Expect(h.GenerationId = 0,
        ATag + ' a tainting call left a generation published');
      Emit(ATag + ' after=' + CallToken(h, 'version', 'null'));
      Expect(CallToken(h, 'version', 'null') = 'unavailable',
        ATag + ' a tainted host still accepted calls');
      Emit(ATag + ' unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload] +
        ' state=' + StateToken(h));
      Expect(h.State = ppsClosed, ATag + ' a tainted host did not close');
    finally
      h.Free;
    end;
  end;

begin
  OneTaint('L9', 'prom', False);   // Promise result
  OneTaint('L10', 'job', False);   // queued microtask
  OneTaint('L11', 'spin', True);   // CPU bound
  OneTaint('L12', 'hog', True);    // memory bound
  OneTaint('L13', 'deep', True);   // stack bound
end;

procedure LUnloadRaces;
var
  h: TPWebQuickJSPluginHost;
  s: IAssetStore;
  caller: TOpThread;
  unloader: TOpThread;
  tok, utok: RawUtf8;
  sinkBefore: LongInt;
begin
  // L16 / L17: an export blocked inside synchronous pweb.invoke while
  // the host unloads. Close is what releases it (frozen source
  // lifecycle), and the late worker result dies at the exactly-once
  // gate. Driven by the bridge rendezvous - no sleeps.
  s := StoreOf(PackageV(1, '1.0.0'));
  h := NewHost(0, s);
  try
    Expect(LoadToken(h) = 'ok', 'L16 the fixture did not load');
    RTLEventResetEvent(HoldArrived);
    RTLEventResetEvent(HoldRelease);
    InterlockedExchange(HoldArmed, 1);
    sinkBefore := InterlockedCompareExchange(NativeServiceAdd, 0, 0);
    RTLEventResetEvent(HoldFinished);
    InterlockedExchange(HoldFinishedFlag, 0);
    caller := TOpThread.Create(h, okCallExport, nil, 1, 'svcAdd',
      '{"a":20,"b":22}');
    try
      caller.Go;
      // the plugin thread is now parked INSIDE the bridge, in the
      // middle of a synchronous pweb.invoke
      RTLEventWaitFor(HoldArrived, RENDEZVOUS_MS);
      // unload UNDER it: Quiesce cancels the queued work and Close
      // cancels the in-flight invocation, which is what releases the
      // plugin thread's bounded wait - without Close it would sit
      // there until InvokeWaitMs
      utok := PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload];
      tok := caller.WaitToken;
      Emit('L16 caller=' + tok + ' unload=' + utok + ' state=' + StateToken(h));
      Expect(utok = 'ok', 'L16 the unload did not report clean');
      Expect(h.State = ppsClosed, 'L16 the host did not close');
      Expect(tok = 'threw',
        'L16 the held invocation did not surface as a contained throw: ' + tok);
      // L17: the worker is STILL parked in the bridge, and its source
      // is closed and its engine destroyed. Releasing it now makes it
      // run the service and deliver a LATE result, which must die at
      // the frozen exactly-once gate: the service IS reached (the
      // worker really ran) and nothing else happens - no crash, no
      // second delivery, no touch of a destroyed engine. HoldFinished
      // is what makes the ledger read deterministic instead of a race.
      RTLEventSetEvent(HoldRelease);
      RTLEventWaitFor(HoldFinished, RENDEZVOUS_MS);
    finally
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease);
      caller.WaitFor;
      caller.Free;
    end;
    Emit('L17 worker_returned=' +
      YesNo(InterlockedCompareExchange(HoldFinishedFlag, 0, 0) = 1) +
      ' service_delta=' +
      IntStr(InterlockedCompareExchange(NativeServiceAdd, 0, 0) - sinkBefore) +
      ' state=' + StateToken(h));
    Expect(InterlockedCompareExchange(HoldFinishedFlag, 0, 0) = 1,
      'L17 the released worker never came back through the bridge');
    // ZERO, and that is the stronger result: the frozen mORMot bridge
    // re-checks the cancellation token on entry, so a worker released
    // after its source closed never reaches the service at all - the
    // exactly-once gate is the SECOND line of defence, not the first.
    Expect(InterlockedCompareExchange(NativeServiceAdd, 0, 0) - sinkBefore = 0,
      'L17 a cancelled late worker still reached the service');
    Expect(h.State = ppsClosed, 'L17 a late completion moved the host');
  finally
    h.Free;
  end;

  // L18: unload while an export is in an infinite loop. The rendezvous
  // guarantees the call is really in flight before the unload starts.
  // The CPU bound ends the runaway call, the thread joins, and the
  // unload is CLEAN - no quarantine, no forceful termination.
  s := StoreOf(PackageV(1, '1.0.0'));
  h := nil;
  try
    h := NewHost(0, s);
    Expect(LoadToken(h) = 'ok', 'L18 the fixture did not load');
    RTLEventResetEvent(HoldArrived);
    RTLEventResetEvent(HoldRelease);
    InterlockedExchange(HoldArmed, 1);
    caller := TOpThread.Create(h, okCallExport, nil, 1, 'holdThenSpin', 'null');
    unloader := nil;
    try
      caller.Go;
      RTLEventWaitFor(HoldArrived, RENDEZVOUS_MS);
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease); // the export now runs away
      unloader := TOpThread.Create(h, okUnload, nil, 0);
      unloader.Go;
      tok := caller.WaitToken;
      utok := unloader.WaitToken;
    finally
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease);
      caller.WaitFor;
      caller.Free;
      if unloader <> nil then
      begin
        unloader.WaitFor;
        unloader.Free;
      end;
    end;
    Emit('L18 caller=' + tok + ' unload=' + utok + ' state=' + StateToken(h));
    Expect(utok = 'ok',
      'L18 an infinite-loop export was not bounded into a clean unload: ' + utok);
    Expect(tok = 'resource_limit',
      'L18 the runaway export did not hit the CPU bound: ' + tok);
    Expect(h.State = ppsClosed, 'L18 the host did not close');
  finally
    h.Free;
  end;
end;

procedure LReloadFailures;
var
  h: TPWebQuickJSPluginHost;
  good: IAssetStore;
  files: TPkgFiles;
  desc: TPWebQuickJSPackageDescriptor;
  code: TPWebPackageLoadCode;
  detail: RawUtf8;
  life: TPWebPluginLifecycleCode;

  procedure Row(const ATag: RawUtf8; const ABroken: TPkgFiles);
  var
    tok: RawUtf8;
    gen: Int64;
  begin
    gen := h.GenerationId;
    tok := ReloadToken(h, StoreOf(ABroken));
    Emit(ATag + ' reload=' + tok + ' state=' + StateToken(h) +
      ' gen=' + IntStr(h.GenerationId));
    if (h.State <> ppsRunning) or (h.GenerationId <> gen) then
      InterlockedIncrement(ReloadLostOld);
    Expect(h.State = ppsRunning,
      ATag + ' a failed staging left the host in ' + StateToken(h));
    Expect(h.GenerationId = gen,
      ATag + ' a failed staging changed the published generation');
    // the OLD generation still works, byte for byte
    Emit(ATag + ' old_still=' + CallToken(h, 'version', 'null') +
      ' add=' + CallToken(h, 'add', '{"x":40,"y":1}'));
    Expect(CallToken(h, 'version', 'null') = 'ok:1',
      ATag + ' the old generation stopped answering');
  end;

  function Broken: TPkgFiles;
  begin
    Result := PackageV(2, '2.0.0');
  end;

begin
  good := StoreOf(PackageV(1, '1.0.0'));
  h := NewHost(0, good);
  try
    Expect(LoadToken(h) = 'ok', 'L19 the base fixture did not load');

    // L19 malformed manifest
    files := Broken;
    ReplaceFile(files, 'plugin.json', '{"schema":1,"id":,}');
    Row('L19', files);

    // manifest carrying a security-authority field
    files := Broken;
    ReplaceFile(files, 'plugin.json',
      '{"schema":1,"id":"quickjs.calculator","version":"2.0.0",' +
      '"entry":"main.js","capabilities":["external.open"]}');
    Row('L19b', files);

    // L20 syntax error in the entry
    files := Broken;
    ReplaceFile(files, 'main.js', 'import { unit } from "./lib/unit.js"; ~~~');
    Row('L20', files);

    // missing entry
    files := Broken;
    RemoveFile(files, 'main.js');
    Row('L20b', files);

    // missing imported module
    files := Broken;
    RemoveFile(files, 'lib/unit.js');
    Row('L20c', files);

    // invalid UTF-8 in a module
    files := Broken;
    ReplaceFile(files, 'lib/unit.js',
      'export const unit = 1; //' + Bytes([$C3, $28]) + #10);
    Row('L20d', files);

    // an embedded NUL
    files := Broken;
    ReplaceFile(files, 'lib/unit.js',
      'export const unit = 1; //' + Bytes([$00]) + #10);
    Row('L20e', files);

    // L21 the package id inside the manifest disagrees with the native
    // ExpectedPackageId
    files := Broken;
    ReplaceFile(files, 'plugin.json',
      '{"schema":1,"id":"quickjs.other","version":"2.0.0","entry":"main.js"}');
    Row('L21', files);

    // a package whose export name cannot be named by the host grammar
    files := Broken;
    ReplaceFile(files, 'main.js',
      'import { unit } from "./lib/unit.js";'#10 +
      'pwebExports["bad-name"] = function () { return unit; };'#10);
    Row('L21b', files);

    // An export name carrying an EMBEDDED NUL, built with
    // String.fromCharCode(0) so the MODULE SOURCE stays pure ASCII and
    // passes CAP-9B1's embedded-NUL refusal. Read through
    // JS_AtomToCString alone the name would truncate to 'add' and alias
    // a real export's spelling; the snapshot compares the atom's true
    // byte length and refuses the load instead.
    files := Broken;
    ReplaceFile(files, 'main.js',
      'import { unit } from "./lib/unit.js";'#10 +
      'pwebExports["add" + String.fromCharCode(0) + "x"] =' +
      ' function () { return unit; };'#10);
    Row('L21g', files);

    // a source that is registered but already CLOSED - the shape
    // RegisterSource returns once the scheduler is shutting down. A
    // generation published over one would look Running and answer
    // runtime_closed to everything, so the staging is refused.
    gFactory.PreClosed := True;
    try
      Row('L22b', PackageV(2, '2.0.0'));
    finally
      gFactory.PreClosed := False;
    end;

    // L21c the DESCRIPTOR itself would move native identity - refused
    // before a thread, an engine or a source is ever created
    desc := h.ReloadTemplate;
    desc.PackageStore := StoreOf(PackageV(2, '2.0.0'));
    desc.PrincipalId := ID_REP;
    life := h.Reload(desc, code, detail);
    Emit('L21c principal=' + PWEB_PLUGIN_LIFECYCLE_TEXT[life] +
      ' state=' + StateToken(h) + ' gen=' + IntStr(h.GenerationId));
    Expect(life = plfIdentity, 'L21c a reload changed the native PrincipalId');
    Expect(h.State = ppsRunning, 'L21c an identity refusal moved the host');

    desc := h.ReloadTemplate;
    desc.PackageStore := StoreOf(PackageV(2, '2.0.0'));
    desc.Capabilities := [CAP_CALC, CAP_OPEN];
    life := h.Reload(desc, code, detail);
    Emit('L21d caps=' + PWEB_PLUGIN_LIFECYCLE_TEXT[life] +
      ' state=' + StateToken(h));
    Expect(life = plfIdentity, 'L21d a reload raised the capability set');

    desc := h.ReloadTemplate;
    desc.PackageStore := StoreOf(PackageV(2, '2.0.0'));
    desc.ExpectedPackageId := 'quickjs.other';
    life := h.Reload(desc, code, detail);
    Emit('L21e pkgid=' + PWEB_PLUGIN_LIFECYCLE_TEXT[life] +
      ' state=' + StateToken(h));
    Expect(life = plfIdentity, 'L21e a reload changed ExpectedPackageId');

    desc := h.ReloadTemplate;
    desc.PackageStore := StoreOf(PackageV(2, '2.0.0'));
    desc.Engine.MemoryLimitBytes := 512 shl 20;
    life := h.Reload(desc, code, detail);
    Emit('L21f limits=' + PWEB_PLUGIN_LIFECYCLE_TEXT[life] +
      ' state=' + StateToken(h));
    Expect(life = plfIdentity, 'L21f a reload raised the engine limits');

    // L22 the source factory produces nothing
    gFactory.Fail := True;
    try
      Row('L22', PackageV(2, '2.0.0'));
    finally
      gFactory.Fail := False;
    end;

    Emit('L19-22 old_generation=' + IntStr(h.GenerationId) +
      ' staging_failures=' + IntStr(h.StagingFailures) +
      ' commits=' + IntStr(h.Commits) +
      ' reload_lost_old=' + IntStr(ReloadLostOld));
    Expect(h.Commits = 0, 'L19-22 a failed staging committed a generation');
    Expect(h.GenerationId = 1, 'L19-22 the old generation id moved');
    Emit('L19-22 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload]);
  finally
    h.Free;
  end;
end;

procedure LReloadSuccess;
var
  h: TPWebQuickJSPluginHost;
  s1, s2: IAssetStore;
  before: RawUtf8;
begin
  s1 := StoreOf(PackageV(1, '1.0.0'));
  s2 := StoreOf(PackageV(2, '2.0.0'));
  h := NewHost(0, s1);
  try
    Expect(LoadToken(h) = 'ok', 'L23 the base fixture did not load');
    Emit('L23 gen1=' + IntStr(h.GenerationId) +
      ' version=' + CallToken(h, 'version', 'null'));
    // L25 leave state behind in the old generation's globals
    Emit('L25 leak=' + CallToken(h, 'leak', 'null') +
      ' seen_before=' + CallToken(h, 'seen', 'null'));
    Expect(CallToken(h, 'seen', 'null') = 'ok:"string"',
      'L25 the old generation did not record its own global');
    before := IntStr(h.GenerationId);

    Emit('L23 reload=' + ReloadToken(h, s2) + ' state=' + StateToken(h) +
      ' gen2=' + IntStr(h.GenerationId) + ' commits=' + IntStr(h.Commits));
    Expect(h.State = ppsRunning, 'L23 the host is not Running after a reload');
    Expect(h.GenerationId = 2, 'L23 the generation id did not change');
    Expect(before <> IntStr(h.GenerationId), 'L23 the generation id was reused');
    Expect(h.Commits = 1, 'L23 the commit was not counted exactly once');

    // L24 behaviour changed
    Emit('L24 version=' + CallToken(h, 'version', 'null'));
    Expect(CallToken(h, 'version', 'null') = 'ok:2',
      'L24 the new generation still runs the old code');
    // L25 the old globals did NOT cross: a fresh context, a fresh module
    // cache, no state migration of any kind
    Emit('L25 seen_after=' + CallToken(h, 'seen', 'null'));
    Expect(CallToken(h, 'seen', 'null') = 'ok:"undefined"',
      'L25 a global from the old generation crossed the commit');
    // the module cache reset too: lib/unit.js executed again in the new
    // context, so `add` still resolves through it
    Emit('L25 add=' + CallToken(h, 'add', '{"x":40,"y":1}'));
    Expect(CallToken(h, 'add', '{"x":40,"y":1}') = 'ok:42',
      'L25 the new generation did not re-evaluate its module graph');
    // the whole invocation chain still works after the swap
    Emit('L24 svcadd=' + CallToken(h, 'svcAdd', '{"a":20,"b":22}'));
    Expect(CallToken(h, 'svcAdd', '{"a":20,"b":22}') = 'ok:42',
      'L24 Add stopped travelling scheduler -> policy -> mORMot');
    Emit('L24 openerr=' + CallToken(h, 'openErr', 'null'));
    Expect(CallToken(h, 'openErr', 'null') = 'ok:"forbidden"',
      'L24 the reload changed what the plugin may do');

    // L30 version is DESCRIPTIVE: same, lower and higher all reload
    Emit('L30 same=' + ReloadToken(h, StoreOf(PackageV(2, '2.0.0'))) +
      ' gen=' + IntStr(h.GenerationId));
    Emit('L30 lower=' + ReloadToken(h, StoreOf(PackageV(3, '0.9.0'))) +
      ' gen=' + IntStr(h.GenerationId) +
      ' version=' + CallToken(h, 'version', 'null'));
    Expect(CallToken(h, 'version', 'null') = 'ok:3',
      'L30 a lower manifest version was refused or ignored');
    Emit('L30 higher=' + ReloadToken(h, StoreOf(PackageV(1, '9.9.9'))) +
      ' gen=' + IntStr(h.GenerationId) +
      ' version=' + CallToken(h, 'version', 'null'));
    Emit('L30 commits=' + IntStr(h.Commits) + ' gen=' + IntStr(h.GenerationId));
    Expect(h.Commits = 4, 'L30 the commit count does not match the reloads');
    Expect(h.GenerationId = 5, 'L30 generation ids are not monotonic');
    InterlockedExchangeAdd(CommitCount, h.Commits);
    Emit('L23-30 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload]);
  finally
    h.Free;
  end;
end;

procedure LCrossGeneration;
var
  h: TPWebQuickJSPluginHost;
  s1, s2: IAssetStore;
  caller, reloader: TOpThread;
  ctok, rtok, mid: RawUtf8;
  addsBefore: LongInt;
  reg: TPWebPluginRegistration;
  desc: TPWebQuickJSPackageDescriptor;
begin
  // L26 / L27: an invocation from generation 1 is parked in the bridge
  // while generation 2 is staged and committed. The old completion must
  // settle into the OLD sink (or die at the exactly-once gate) and can
  // never reach the new engine; and while the commit is in flight, NO
  // call may be accepted by either generation.
  // The window is made OBSERVABLE on purpose. A call that merely parks
  // in the bridge is released by the source Close, so the drain - and
  // therefore ppsCommitting - lasts microseconds and could only be
  // sampled by luck. holdThenSpin instead runs away AFTER its
  // invocation returns, so the host's in-flight count stays 1 until the
  // CPU bound fires and the commit window lasts a bounded, real amount
  // of time that a single sample cannot miss.
  s1 := StoreOf(PackageV(1, '1.0.0'));
  s2 := StoreOf(PackageV(2, '2.0.0'));
  reg := Default(TPWebPluginRegistration);
  desc := DescriptorFor(0, s1);
  desc.Engine.TimeoutSeconds := 2; // the length of the commit window
  reg.Descriptor := desc;
  reg.OnSnapshot := gSnapCb;
  reg.SourceFactory := gFactory.Make;
  reg.ReadyWaitMs := READY_WAIT_MS;
  reg.ExportWaitMs := EXPORT_WAIT_MS;
  reg.UnloadJoinMs := JOIN_MS;
  reg.DrainMs := DRAIN_MS;
  h := TPWebQuickJSPluginHost.Create(reg);
  try
    Expect(LoadToken(h) = 'ok', 'L26 the base fixture did not load');
    addsBefore := InterlockedCompareExchange(NativeServiceAdd, 0, 0);
    RTLEventResetEvent(HoldArrived);
    RTLEventResetEvent(HoldRelease);
    InterlockedExchange(HoldArmed, 1);
    caller := TOpThread.Create(h, okCallExport, nil, 1, 'holdThenSpin', 'null');
    reloader := TOpThread.Create(h, okReload, s2, 0);
    try
      caller.Go;
      // generation 1's plugin thread is parked INSIDE the bridge
      RTLEventWaitFor(HoldArrived, RENDEZVOUS_MS);
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease); // it now runs away, still in flight
      // with that call in flight, reload: stage generation 2 fully,
      // unpublish generation 1, then BLOCK in the drain
      reloader.Go;
      Expect(WaitState(h, ppsCommitting, RENDEZVOUS_MS),
        'L27 the reload never entered its Committing window');
      // L27, the invariant itself: in that window the old generation no
      // longer accepts and the new one is not published, so a call MUST
      // be refused. Anything else means two generations were live.
      mid := CallToken(h, 'version', 'null');
      if mid <> 'unavailable' then
        InterlockedIncrement(TwoActiveGenerations);
      ctok := caller.WaitToken;
      rtok := reloader.WaitToken;
    finally
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease);
      caller.WaitFor;
      reloader.WaitFor;
      caller.Free;
      reloader.Free;
    end;
    Emit('L26 caller=' + ctok + ' reload=' + rtok + ' mid=' + mid);
    Expect(mid = 'unavailable',
      'L27 a call was accepted inside the commit window: ' + mid);
    // the runaway call ended on generation 1's CPU bound. That TAINTS
    // generation 1 - and the taint reap must then discover that its
    // generation has already been replaced and do nothing, which is
    // exactly the id-not-pointer identification the host relies on.
    Expect(ctok = 'resource_limit',
      'L26 the in-flight call did not end on the CPU bound: ' + ctok);
    Emit('L26 state=' + StateToken(h) + ' gen=' + IntStr(h.GenerationId) +
      ' commits=' + IntStr(h.Commits));
    Expect(rtok = 'ok', 'L26 the reload did not commit while a call was held');
    Expect(h.GenerationId = 2, 'L26 the generation did not advance');
    // the NEW generation is clean and answers as generation 2
    Emit('L26 new=' + CallToken(h, 'version', 'null'));
    Expect(CallToken(h, 'version', 'null') = 'ok:2',
      'L26 the new generation is not the one serving');
    Emit('L26 new_seen=' + CallToken(h, 'seen', 'null'));
    Expect(CallToken(h, 'seen', 'null') = 'ok:"undefined"',
      'L26 old state reached the new engine');
    // The held worker has now been released and has delivered its late
    // result. It belonged to generation 1's source and sink, both of
    // which are closed, so it must have died at the frozen exactly-once
    // gate. What that has to mean, observably, is that the NEW engine is
    // untouched by it - re-checked here rather than assumed, and any
    // divergence is counted as a stale completion reaching a live
    // generation.
    if (CallToken(h, 'version', 'null') <> 'ok:2') or
       (CallToken(h, 'seen', 'null') <> 'ok:"undefined"') or
       (CallToken(h, 'add', '{"x":40,"y":1}') <> 'ok:42') then
      InterlockedIncrement(StaleCompletion);
    // the in-flight invocation ran BEFORE the commit, so it reached the
    // service exactly once and nothing after the commit added to it
    Emit('L27 held_service_calls=' +
      IntStr(InterlockedCompareExchange(NativeServiceAdd, 0, 0) - addsBefore) +
      ' hold_hits=' + IntStr(HoldHits));
    Emit('L27 two_active=' + IntStr(TwoActiveGenerations) +
      ' stale=' + IntStr(StaleCompletion));
    Emit('L26-27 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload]);
  finally
    h.Free;
  end;
end;

procedure LGrants;
var
  h: TPWebQuickJSPluginHost;
  hd: TPWebQuickJSPluginHost;
  s1, s2: IAssetStore;
begin
  // L28 grants are keyed by the native PrincipalId and reload neither
  // grants nor revokes anything by itself.
  s1 := StoreOf(PackageV(1, '1.0.0'));
  s2 := StoreOf(PackageV(2, '2.0.0'));
  h := NewHost(0, s1);
  try
    Expect(LoadToken(h) = 'ok', 'L28 the base fixture did not load');
    Emit('L28 before=' + CallToken(h, 'svcErr', 'null'));
    Expect(CallToken(h, 'svcErr', 'null') = 'ok:{"code":"allowed","name":"none"}',
      'L28 the granted principal was refused before the revoke');
    // revoke, WITHOUT touching the descriptor: the next invocation
    // captures a fresh snapshot through the frozen CAP-8 policy
    gPolicy.RevokeRuntimeGrant(ID_CALC, CAP_CALC);
    Emit('L28 revoked=' + CallToken(h, 'svcErr', 'null'));
    Expect(CallToken(h, 'svcErr', 'null') =
      'ok:{"code":"forbidden","name":"PWebError"}',
      'L28 a revoke did not reach the next invocation');
    // reload while revoked: the new generation is denied too, because
    // identity - not the package - decides
    Emit('L28 reload=' + ReloadToken(h, s2) + ' gen=' + IntStr(h.GenerationId));
    Emit('L28 after_reload=' + CallToken(h, 'svcErr', 'null'));
    Expect(CallToken(h, 'svcErr', 'null') =
      'ok:{"code":"forbidden","name":"PWebError"}',
      'L28 a reload restored a revoked capability');
    // restore, and the SAME generation regains it on its next call:
    // clearing the grant entry returns the principal to its static
    // configuration alone
    gPolicy.ClearRuntimeGrants(ID_CALC);
    Emit('L28 restored=' + CallToken(h, 'svcErr', 'null') +
      ' gen=' + IntStr(h.GenerationId));
    Expect(CallToken(h, 'svcErr', 'null') = 'ok:{"code":"allowed","name":"none"}',
      'L28 a restored capability did not reach the next invocation');
    Emit('L28 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload]);
  finally
    h.Free;
  end;

  // L29 a principal with the explicit empty set stays denied across a
  // reload - and never reaches the bridge at all
  hd := NewHost(1, StoreOf(PackageV(1, '1.0.0')));
  try
    Expect(LoadToken(hd) = 'ok', 'L29 the denied fixture did not load');
    Emit('L29 before=' + CallToken(hd, 'svcErr', 'null'));
    Expect(CallToken(hd, 'svcErr', 'null') =
      'ok:{"code":"forbidden","name":"PWebError"}',
      'L29 the denied principal was allowed');
    Emit('L29 reload=' + ReloadToken(hd, StoreOf(PackageV(2, '2.0.0'))) +
      ' gen=' + IntStr(hd.GenerationId));
    Emit('L29 after=' + CallToken(hd, 'svcErr', 'null'));
    Expect(CallToken(hd, 'svcErr', 'null') =
      'ok:{"code":"forbidden","name":"PWebError"}',
      'L29 a reload granted the denied principal');
    Emit('L29 openerr=' + CallToken(hd, 'openErr', 'null'));
    Emit('L29 denied_bridge=' + IntStr(DeniedBridgeAdd) +
      ' opener_reached=' + IntStr(OpenerReached));
    Expect(DeniedBridgeAdd = 0, 'L29 a denied principal reached the bridge');
    Emit('L29 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[hd.Unload]);
  finally
    hd.Free;
  end;
end;

procedure LConcurrency;
var
  h: TPWebQuickJSPluginHost;
  s1, s2: IAssetStore;
  c, r, r2, u: TOpThread;
  ct, rt1, rt2, ut: RawUtf8;
begin
  s1 := StoreOf(PackageV(1, '1.0.0'));
  s2 := StoreOf(PackageV(2, '2.0.0'));

  // L31 CallExport vs Reload
  h := NewHost(0, s1);
  try
    Expect(LoadToken(h) = 'ok', 'L31 the base fixture did not load');
    c := TOpThread.Create(h, okCallExport, nil, 200, 'version', 'null',
      ACCEPT_RUNNING);
    r := TOpThread.Create(h, okReload, s2, 0);
    try
      c.Go;
      r.Go;
      ct := c.WaitToken;
      rt1 := r.WaitToken;
    finally
      c.WaitFor; r.WaitFor; c.Free; r.Free;
    end;
    Emit('L31 calls=' + ct + ' reload=' + rt1 + ' state=' + StateToken(h) +
      ' gen=' + IntStr(h.GenerationId));
    Expect(ct = 'all-deterministic',
      'L31 a concurrent CallExport produced a non-deterministic outcome: ' + ct);
    Expect(rt1 = 'ok', 'L31 the concurrent reload did not commit');
    Expect(h.State = ppsRunning, 'L31 the host is not Running afterwards');

    // L33 Reload vs Reload - serialised by the operation lock
    r := TOpThread.Create(h, okReload, s1, 0);
    r2 := TOpThread.Create(h, okReload, s2, 0);
    try
      r.Go;
      r2.Go;
      rt1 := r.WaitToken;
      rt2 := r2.WaitToken;
    finally
      r.WaitFor; r2.WaitFor; r.Free; r2.Free;
    end;
    Emit('L33 a=' + rt1 + ' b=' + rt2 + ' commits=' + IntStr(h.Commits) +
      ' gen=' + IntStr(h.GenerationId) + ' state=' + StateToken(h));
    Expect((rt1 = 'ok') and (rt2 = 'ok'),
      'L33 two concurrent reloads did not both serialise through');
    Expect(h.Commits = 3, 'L33 the commit count is not one per reload');
    Expect(h.GenerationId = 4, 'L33 generation ids are not monotonic');
    Emit('L31-33 unload=' + PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload]);
  finally
    h.Free;
  end;

  // L32 CallExport vs Unload
  h := NewHost(0, StoreOf(PackageV(1, '1.0.0')));
  try
    Expect(LoadToken(h) = 'ok', 'L32 the base fixture did not load');
    c := TOpThread.Create(h, okCallExport, nil, 200, 'version', 'null',
      ACCEPT_RUNNING);
    u := TOpThread.Create(h, okUnload, nil, 0);
    try
      c.Go;
      u.Go;
      ct := c.WaitToken;
      ut := u.WaitToken;
    finally
      c.WaitFor; u.WaitFor; c.Free; u.Free;
    end;
    Emit('L32 calls=' + ct + ' unload=' + ut + ' state=' + StateToken(h));
    Expect(ct = 'all-deterministic',
      'L32 a concurrent CallExport produced a non-deterministic outcome: ' + ct);
    Expect(ut = 'ok', 'L32 the concurrent unload did not report clean');
    Expect(h.State = ppsClosed, 'L32 the host did not close');
  finally
    h.Free;
  end;

  // L34 Reload vs Unload - no deadlock, deterministic end state
  h := NewHost(0, StoreOf(PackageV(1, '1.0.0')));
  try
    Expect(LoadToken(h) = 'ok', 'L34 the base fixture did not load');
    r := TOpThread.Create(h, okReload, StoreOf(PackageV(2, '2.0.0')), 0);
    u := TOpThread.Create(h, okUnload, nil, 0);
    try
      r.Go;
      u.Go;
      rt1 := r.WaitToken;
      ut := u.WaitToken;
    finally
      r.WaitFor; u.WaitFor; r.Free; u.Free;
    end;
    // Whichever order the operation lock granted, the END STATE is
    // Closed and neither call raised or hung. The reload's own token is
    // NORMALISED rather than recorded: which of the two won the lock is
    // a scheduling detail, and writing it into the corpus would make
    // the digest differ between targets for no semantic reason.
    Emit('L34 reload_in_ratified_set=' +
      YesNo((rt1 = 'ok') or (rt1 = 'bad_state')) +
      ' unload=' + ut + ' state=' + StateToken(h));
    Expect((rt1 = 'ok') or (rt1 = 'bad_state'),
      'L34 the concurrent reload produced an unexpected outcome: ' + rt1);
    Expect(ut = 'ok', 'L34 the concurrent unload did not report clean');
    Expect(h.State = ppsClosed, 'L34 the host did not close');
  finally
    h.Free;
  end;
end;

procedure LMultiPlugin;
var
  a, b: TPWebQuickJSPluginHost;
begin
  a := NewHost(0, StoreOf(PackageV(1, '1.0.0')));
  b := nil;
  try
    b := NewHost(0, StoreOf(PackageV(2, '2.0.0')));
    Expect(LoadToken(a) = 'ok', 'L35 plugin A did not load');
    Expect(LoadToken(b) = 'ok', 'L35 plugin B did not load');
    // L35 per-HOST generation counters: both start at 1 and never see
    // each other. A process-global counter would show up here at once.
    Emit('L35 genA=' + IntStr(a.GenerationId) +
      ' genB=' + IntStr(b.GenerationId) +
      ' verA=' + CallToken(a, 'version', 'null') +
      ' verB=' + CallToken(b, 'version', 'null'));
    Expect((a.GenerationId = 1) and (b.GenerationId = 1),
      'L35 generation counters are not per host');
    // globals cannot cross between plugins: separate runtimes
    Emit('L35 leakA=' + CallToken(a, 'leak', 'null') +
      ' seenA=' + CallToken(a, 'seen', 'null') +
      ' seenB=' + CallToken(b, 'seen', 'null'));
    Expect(CallToken(b, 'seen', 'null') = 'ok:"undefined"',
      'L35 plugin A state was visible inside plugin B');

    // L36 reloading A three times leaves B untouched
    Emit('L36 reloadA=' + ReloadToken(a, StoreOf(PackageV(3, '3.0.0'))) +
      ' ' + ReloadToken(a, StoreOf(PackageV(1, '1.0.0'))) +
      ' ' + ReloadToken(a, StoreOf(PackageV(3, '3.0.0'))));
    Emit('L36 genA=' + IntStr(a.GenerationId) +
      ' genB=' + IntStr(b.GenerationId) +
      ' verB=' + CallToken(b, 'version', 'null') +
      ' addB=' + CallToken(b, 'add', '{"x":40,"y":1}'));
    Expect(b.GenerationId = 1, 'L36 plugin A reload moved plugin B');
    Expect(CallToken(b, 'version', 'null') = 'ok:2',
      'L36 plugin B stopped working while A reloaded');

    // an A-side error never leaks into B
    Emit('L36 boomA=' + CallToken(a, 'boom', 'null') +
      ' verB=' + CallToken(b, 'version', 'null'));

    // L37 unloading A leaves B fully functional
    Emit('L37 unloadA=' + PWEB_PLUGIN_LIFECYCLE_TEXT[a.Unload] +
      ' stateA=' + StateToken(a) + ' stateB=' + StateToken(b));
    Emit('L37 verB=' + CallToken(b, 'version', 'null') +
      ' svcB=' + CallToken(b, 'svcAdd', '{"a":20,"b":22}') +
      ' genB=' + IntStr(b.GenerationId));
    Expect(CallToken(b, 'version', 'null') = 'ok:2',
      'L37 unloading plugin A broke plugin B');
    Expect(CallToken(b, 'svcAdd', '{"a":20,"b":22}') = 'ok:42',
      'L37 plugin B lost its invocation path when A unloaded');
    Emit('L37 unloadB=' + PWEB_PLUGIN_LIFECYCLE_TEXT[b.Unload]);
  finally
    a.Free;
    if b <> nil then
      b.Free;
  end;
end;

procedure LQuarantine;
var
  h: TPWebQuickJSPluginHost;
  desc: TPWebQuickJSPackageDescriptor;
  reg: TPWebPluginRegistration;
  c: TOpThread;
  before, i: Integer;
  tok: RawUtf8;
begin
  // L38 the LAST-RESORT path, injected without any production test
  // hook: a real infinite-loop export under a 5s CPU bound, unloaded
  // with a 50ms join budget. The thread genuinely cannot be joined in
  // time, so the generation must be quarantined - nothing freed - and
  // the host must NOT report a clean close.
  before := PWebQuickJSQuarantineCount;
  desc := DescriptorFor(0, StoreOf(PackageV(1, '1.0.0')));
  desc.Engine.TimeoutSeconds := 5;
  reg := Default(TPWebPluginRegistration);
  reg.Descriptor := desc;
  reg.OnSnapshot := gSnapCb;
  reg.SourceFactory := gFactory.Make; // Delphi-mode event assignment
  reg.ReadyWaitMs := READY_WAIT_MS;
  reg.ExportWaitMs := EXPORT_WAIT_MS;
  reg.UnloadJoinMs := 50;  // deliberately far below the CPU bound
  reg.DrainMs := 50;
  h := TPWebQuickJSPluginHost.Create(reg);
  try
    Expect(LoadToken(h) = 'ok', 'L38 the fixture did not load');
    RTLEventResetEvent(HoldArrived);
    RTLEventResetEvent(HoldRelease);
    InterlockedExchange(HoldArmed, 1);
    c := TOpThread.Create(h, okCallExport, nil, 1, 'holdThenSpin', 'null');
    try
      c.Go;
      // the rendezvous makes the runaway deterministic: the call is
      // provably in flight before the unload starts
      RTLEventWaitFor(HoldArrived, RENDEZVOUS_MS);
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease);
      tok := PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload];
      Emit('L38 unload=' + tok + ' state=' + StateToken(h) +
        ' quarantined=' + IntStr(h.QuarantinedGenerations) +
        ' drain_timeouts=' + IntStr(h.DrainTimeouts));
      Expect(tok = 'quarantined',
        'L38 an unjoinable thread was reported as a clean close');
      Expect(h.QuarantinedGenerations = 1, 'L38 the quarantine was not counted');
      Expect(h.State = ppsClosed, 'L38 the host did not reach Closed');
      InterlockedIncrement(QuarantineInjected);
      c.WaitToken;
    finally
      InterlockedExchange(HoldArmed, 0);
      RTLEventSetEvent(HoldRelease);
      c.WaitFor;
      c.Free;
    end;
  finally
    // NOTE: h.Free runs the host destructor, which Unloads again -
    // idempotent, and it must NOT try to free the quarantined
    // generation (the host already handed it to the ledger)
    h.Free;
  end;
  Emit('L38 ledger_before=' + IntStr(before) +
    ' ledger_after=' + IntStr(PWebQuickJSQuarantineCount));
  Expect(PWebQuickJSQuarantineCount = before + 1,
    'L38 the process quarantine ledger did not grow by exactly one');
  // the quarantined generation is NEVER freed; it is only observed. Its
  // CPU bound ends the runaway call, so it eventually exits on its own -
  // which is what proves the leak was of live state, not of dead state.
  for i := 1 to 300 do
  begin
    if PWebQuickJSQuarantineExited >= before + 1 then
      break;
    // a bounded slice on an event nothing ever sets: there is no
    // barrier available here BY DESIGN - the only field of a
    // quarantined generation this harness may touch is HasExited, and
    // touching anything else is exactly what the quarantine forbids
    RTLEventWaitFor(NeverEv, 50);
  end;
  Emit('L38 exited_later=' + YesNo(PWebQuickJSQuarantineExited >= before + 1) +
    ' still_leaked=' + IntStr(PWebQuickJSQuarantineCount));
  Expect(PWebQuickJSQuarantineExited >= before + 1,
    'L38 the quarantined thread never finished - the leak may be permanent');
end;

procedure LCycles;
var
  h: TPWebQuickJSPluginHost;
  s1, s2: IAssetStore;
  i, bad: Integer;
begin
  // L39 a hundred load / reload / unload cycles, all clean
  s1 := StoreOf(PackageV(1, '1.0.0'));
  s2 := StoreOf(PackageV(2, '2.0.0'));
  bad := 0;
  for i := 1 to 100 do
  begin
    h := NewHost(0, s1);
    try
      if LoadToken(h) <> 'ok' then
        Inc(bad);
      if CallToken(h, 'version', 'null') <> 'ok:1' then
        Inc(bad);
      if ReloadToken(h, s2) <> 'ok' then
        Inc(bad);
      if CallToken(h, 'version', 'null') <> 'ok:2' then
        Inc(bad);
      if h.GenerationId <> 2 then
        Inc(bad);
      if PWEB_PLUGIN_LIFECYCLE_TEXT[h.Unload] <> 'ok' then
        Inc(bad);
      if h.QuarantinedGenerations <> 0 then
        InterlockedIncrement(QuarantineUnexpected);
    finally
      h.Free;
    end;
  end;
  Emit('L39 cycles=100 bad=' + IntStr(bad) +
    ' quarantine_unexpected=' + IntStr(QuarantineUnexpected));
  Expect(bad = 0, 'L39 a load/reload/unload cycle was not clean');
  Expect(QuarantineUnexpected = 0,
    'L39 a routine cycle needed a quarantine');
end;

procedure LLedger;
begin
  Emit('ledger service_add=' + IntStr(NativeServiceAdd));
  Emit('ledger two_active_generations=' + IntStr(TwoActiveGenerations));
  Emit('ledger stale_completion=' + IntStr(StaleCompletion));
  Emit('ledger reload_lost_old=' + IntStr(ReloadLostOld));
  Emit('ledger export_wrong_thread=' + IntStr(ExportWrongThread));
  Emit('ledger denied_bridge_add=' + IntStr(DeniedBridgeAdd));
  Emit('ledger opener_reached=' + IntStr(OpenerReached));
  Emit('ledger quarantine_injected=' + IntStr(QuarantineInjected));
  Emit('ledger quarantine_unexpected=' + IntStr(QuarantineUnexpected));
  Emit('ledger sources_made=' + IntStr(gFactory.Made));
  Expect(TwoActiveGenerations = 0, 'two generations accepted invocations');
  Expect(StaleCompletion = 0, 'a stale completion reached a live generation');
  Expect(ReloadLostOld = 0, 'a failed staging lost the old generation');
  Expect(ExportWrongThread = 0, 'an export call ran off the owning thread');
  Expect(DeniedBridgeAdd = 0, 'a denied principal reached the bridge');
  Expect(OpenerReached = 0, 'pweb.openExternal reached the bridge');
  Expect(QuarantineInjected = 1, 'the injected quarantine row did not run');
  Expect(QuarantineUnexpected = 0, 'an unexpected quarantine happened');
end;

{ ---- main ---------------------------------------------------------------- }

var
  corpusFile, outFile: TFileName;
  overall: RawUtf8;
  json: RawUtf8;

procedure WriteCorpusFile;
var
  s: TFileStream;
begin
  if root = '' then
    exit;
  corpusFile := root + TFileName(StringReplace(CORPUS_FILE, '/', PathDelim,
    [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(corpusFile)) then
    exit;
  s := TFileStream.Create(corpusFile, fmCreate);
  try
    if CorpusLines <> '' then
      s.WriteBuffer(CorpusLines[1], Length(CorpusLines));
  finally
    s.Free;
  end;
end;

begin
  ExitCode := 0;
  CorpusLines := '';
  FailReasons := '';
  overall := 'FAIL';
  HoldArrived := RTLEventCreate;
  HoldRelease := RTLEventCreate;
  HoldFinished := RTLEventCreate;
  NeverEv := RTLEventCreate;
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock) not found from ' +
          string(Executable.ProgramFilePath));
      outFile := root + 'build' + PathDelim + 'cap9b2' + PathDelim +
        'quickjslifecycle-' + TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));
      workDir := GetTempDir + 'pweb-cap9b2-' +
        TFileName(IntToStr(GetCurrentProcessId));
      RmTree(workDir);
      if not ForceDirectories(workDir) then
        raise Exception.Create('unable to create the fixture work directory');

      gServer := TRestServerFullMemory.CreateWithOwnModel([]);
      if gServer.ServiceRegister(TCalculatorService,
           [TypeInfo(ICalculatorService)], sicShared) = nil then
        raise Exception.Create('unable to register CalculatorService');
      gRealBridge := TMormotInvocationBridge.Create(gServer, True);
      gServer := nil; // owned by the bridge now
      gBridge := TRendezvousBridge.Create(gRealBridge);
      gPolicy := BuildPolicy;
      gPolicyRef := gPolicy;
      gScheduler := TInvocationScheduler.Create(gPolicyRef, gBridge, 4);
      gSchedulerRef := gScheduler;
      gSnap := TSnapshotAdapter.Create;
      gSnapCb := gSnap.Snapshot;
      gFactory := TSourceFactory.Create;

      Emit('schema=1');
      Emit('pin quickjs=2021-03-27 nanboxing=strict libc=none');
      Emit('export table=' + PWEB_EXPORT_TABLE +
        ' name_max=' + IntStr(PWEB_EXPORT_NAME_MAX_BYTES) +
        ' arg_max=' + IntStr(PWEB_EXPORT_ARG_MAX_BYTES) +
        ' result_max=' + IntStr(PWEB_EXPORT_RESULT_MAX_BYTES) +
        ' count_max=' + IntStr(PWEB_EXPORT_MAX_COUNT));
      Emit('states=' + PWEB_PLUGIN_STATE_TEXT[ppsCreated] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsLoading] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsRunning] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsStaging] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsCommitting] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsQuiescing] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsFailed] + ',' +
        PWEB_PLUGIN_STATE_TEXT[ppsClosed]);

      LBasics;
      LLoadFailure;
      LTaints;
      LUnloadRaces;
      LReloadFailures;
      LReloadSuccess;
      LCrossGeneration;
      LGrants;
      LConcurrency;
      LMultiPlugin;
      LQuarantine;
      LCycles;
      LLedger;

      gSchedulerRef.Shutdown;

      if FailReasons = '' then
      begin
        Emit('verdict=PASS');
        overall := 'PASS';
      end
      else
      begin
        Emit('verdict=FAIL');
        overall := 'FAIL';
      end;
      WriteCorpusFile;
    except
      on E: Exception do
      begin
        Fail(RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message));
        overall := 'FAIL';
        WriteLn(StdErr, LOG_PREFIX, ': FATAL ', E.ClassName, ': ', E.Message);
        // a corpus already carrying verdict=PASS must be REWRITTEN: a
        // PASS line beside overall=FAIL would be hashed into the digest
        // and sail through the emitters (CAP-9B1 finding)
        CorpusLines := StringReplaceAll(CorpusLines,
          'verdict=PASS'#10, 'verdict=FAIL'#10);
        if Pos('verdict=', CorpusLines) = 0 then
          Emit('verdict=FAIL');
        WriteCorpusFile;
      end;
    end;
  finally
    try
      gSchedulerRef := nil; gScheduler := nil;
      gPolicyRef := nil; gPolicy := nil;
      gBridge := nil; gRealBridge := nil;
      FreeAndNil(gSnap);
      FreeAndNil(gFactory);
      if workDir <> '' then
        RmTree(workDir);
    except
    end;
  end;

  json := '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "target": "' + TARGET_ID + '",' + #10 +
    '  "overall": "' + overall + '",' + #10 +
    '  "service_add_count": ' + IntStr(NativeServiceAdd) + ',' + #10 +
    '  "commits": ' + IntStr(CommitCount) + ',' + #10 +
    '  "two_active_generations": ' + IntStr(TwoActiveGenerations) + ',' + #10 +
    '  "stale_completion": ' + IntStr(StaleCompletion) + ',' + #10 +
    '  "reload_lost_old": ' + IntStr(ReloadLostOld) + ',' + #10 +
    '  "export_wrong_thread": ' + IntStr(ExportWrongThread) + ',' + #10 +
    '  "denied_bridge_add": ' + IntStr(DeniedBridgeAdd) + ',' + #10 +
    '  "opener_reached": ' + IntStr(OpenerReached) + ',' + #10 +
    '  "quarantine_injected": ' + IntStr(QuarantineInjected) + ',' + #10 +
    '  "quarantine_unexpected": ' + IntStr(QuarantineUnexpected) + ',' + #10;
  if FailReasons <> '' then
    json := json + '  "failures": "' + JsonSafeText(FailReasons) + '"' + #10
  else
    json := json + '  "failures": null' + #10;
  json := json + '}' + #10;
  if outFile <> '' then
    FileFromString(json, outFile);

  if HoldArrived <> nil then
    RTLEventDestroy(HoldArrived);
  if HoldFinished <> nil then
    RTLEventDestroy(HoldFinished);
  if HoldRelease <> nil then
    RTLEventDestroy(HoldRelease);
  if NeverEv <> nil then
    RTLEventDestroy(NeverEv);

  if FailReasons = '' then
    WriteLn(MARKER_PASS)
  else
  begin
    WriteLn(MARKER_FAIL, ' (', FailReasons, ')');
    ExitCode := 1;
  end;
end.
