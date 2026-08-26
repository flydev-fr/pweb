{
  pweb.script.quickjs - CAP-9A QuickJS engine host + source-generic
  invocation adapter (one unit by ratified decision: adapter/host
  separation adds nothing at this size).

  ARCHITECTURE (frozen by the CAP-9A spec):
  - One shared app-lifetime TThreadSafeManager(TQuickJSEngine) mints
    caller-owned engines via NewEngine (NeverExpire, fManager=nil, no
    pool/expiry/Destroy-raise hazards - the pooled ThreadSafeEngine()
    path is deliberately NOT used).
  - TPWebQuickJSPlugin is a dedicated TThread that creates AND frees its
    own TQuickJSEngine on itself: strict thread affinity, one runtime +
    context per plugin, no shared-context boundary. Every QuickJS
    conversion happens on this owning thread; scheduler workers never
    touch JSContext/JSValue.
  - Invocation chain, exactly: QuickJS plugin thread -> this adapter ->
    IInvocationSource.TryEnqueue -> frozen scheduler/policy/decorators/
    bridge -> completion sink -> owning plugin thread -> script result
    or thrown PWebError. One scheduler, one policy, one bridge, one
    error taxonomy - no direct QuickJS->bridge/mORMot path exists here.
  - The script-facing API is the ratified SYNCHRONOUS model: the native
    __pweb_invoke_json callback validates, enqueues through the frozen
    TryEnqueue gate, blocks the plugin thread on a per-invocation event
    the completion sink signals, and returns ONE JSON envelope string
      {"ok":true,"value":<verbatim-json>}
      {"ok":false,"error":{"code":...,"status":...,"message":...,"data":...}}
    which the bootstrap shim JSON.parse's - so exact key case/order,
    null vs undefined, and success-shaped-like-error survive without any
    DocVariant round-trip. The bounded wait is legal because the plugin
    thread is a dedicated non-scheduler thread, and it always terminates
    because accepted enqueues complete exactly once (result/error/
    cancelled) through the frozen lifecycle; the defensive cap maps to
    internal_error and is normally unreachable.
  - TInvocationContext is built natively (pkQuickJS, native PrincipalId/
    PluginId, WindowId=''); script metadata has zero identity authority.
    The per-invocation capabilities snapshot is refreshed through the
    host-supplied OnSnapshotCapabilities callback (the CAP-8 policy's
    SnapshotCapabilities), so runtime-grant changes affect the NEXT
    invocation while an in-flight one keeps its captured snapshot.
  - Per-engine limits: CPU via the pinned TimeoutValue interrupt
    (applies per Evaluate call), memory via JS_SetMemoryLimit, stack via
    the correctly-typed PRIVATE re-declaration of JS_SetMaxStackSize
    below - the pinned mormot.lib.quickjs binding mistypes its first
    parameter as JSContext where the pinned C header (quickjs.h:464)
    takes JSRuntime*; calling the mistyped binding corrupts the context
    (measured AV under allocation pressure). Do NOT call the pinned
    binding anywhere; the pin itself stays byte-unchanged (workaround
    lives PWeb-side, per the ratified Ask-First boundary).
  - Lifecycle: the transport (this plugin) drives Quiesce -> Close on
    its source; Unload then stops the thread and the engine is destroyed
    ON ITS OWNING THREAD in Execute's epilogue. A late worker completion
    dies at the frozen exactly-once gate and never touches the engine.

  CAP-9B2 adds, around that unchanged shape:
  - ONE GENERATION PER INSTANCE. This class is now explicitly a single
    plugin generation - thread + engine + context + module cache + graph
    + source + export surface. It never reloads itself and never owns a
    second engine. pweb.script.plugin owns generations; nothing here
    knows that a previous or next generation exists.
  - THE EXPORT SURFACE. A native, NULL-PROTOTYPE table is defined as
    globalThis.pwebExports before the entry module compiles; package
    modules register callables on it during load. At the load commit
    point native code re-imposes the null prototype, makes the object
    non-extensible, snapshots the names and deletes the global. There is
    NO way to reach a module's ES named exports in this pin
    (js_get_module_ns is static in quickjs.c and quickjs.h exports only
    JS_GetModuleName), and the one route that does work - a synthetic
    `import * as ns` module - costs an extra normalize call and a graph
    edge, which would move the FROZEN CAP-9B1 corpus digest. Measured,
    ratified at Checkpoint 1.
  - CallExport: one exact export name, one JSON argument, one JSON
    result, executed only on the owning thread through the same
    single-slot mailbox. A concurrent second call is refused with
    peccBusy, synchronously and without blocking - the same shape as the
    frozen TryEnqueue/perBusy rule, and the reason a lifecycle lock
    never waits on a QuickJS call.
  - FAIL-CLOSED ASYNC. After every export call JS_IsJobPending is
    checked and a thenable result is refused: nothing drains the job
    queue, so a queued microtask would never run and the call would only
    LOOK complete. Both taint the generation.
  - BOUNDED TEARDOWN. Unload's join is bounded by FExited (set as the
    thread's very last act). On timeout the generation is QUARANTINED:
    nothing it may still touch is freed and the instance is leaked by
    choice. No thread is ever forcibly terminated.

  Darwin note: mormot.defines.inc auto-defines LIBQUICKJSSTATIC only for
  FPC Linux-Intel and Windows-Intel, and mormot.lib.quickjs's static
  {$L} table has no OSDARWIN clause. Both macOS targets therefore build
  with -dLIBQUICKJSSTATIC and this unit links the CI-built object
  (tools/build_quickjs_darwin.sh compiles the pinned amalgamation from
  deps/mormot2/res/static/libquickjs; the runner passes -Fo with its
  output directory). On aarch64-darwin mormot.defines.inc additionally
  defines NOLIBCSTATIC, which removes the pas_malloc family from
  mormot.lib.static - this unit exports them there, mirroring the
  mormot.lib.static declarations byte-for-byte in semantics.
}
unit pweb.script.quickjs;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Classes,
  Variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.variants,
  mormot.lib.quickjs,
  mormot.script.core,
  mormot.script.quickjs,
  pweb.assets.intf,
  pweb.script.package,
  pweb.rpc.intf,
  pweb.rpc.support;

type
  EPWebQuickJSPlugin = class(Exception);

  { CAP-9B1 package load state. Loading is the window in which the
    module graph is compiled and evaluated; it is also the window in
    which pweb.invoke is REFUSED (see the Loading gate in InvokeJson):
    top-level module code must not produce backend side effects before
    the package has been accepted. }
  TPWebQuickJSLoadState = (
    qlsIdle,      // no package configured (the CAP-9A shape)
    qlsLoading,
    qlsRunning,
    qlsFailed);

  { CAP-9B2 outcome of ONE host-to-plugin export call. Deliberately NOT
    the nine-code RPC taxonomy (wire-semantics.md): an export call is a
    private native lifecycle operation, not an invocation, and nothing
    here ever reaches the wire.

    Which codes TAINT the generation (the host closes it, bounded, and
    never lets it serve again) is stated beside each one: a contained
    plugin exception leaves a valid engine, a broken asynchronous
    contract or a blown resource bound does not. }
  TPWebExportCallCode = (
    peccOk,
    peccUnavailable,    // not Running / closing / already tainted
    peccBusy,           // another export call is in flight on this generation
    peccBadName,        // the name fails PWebExportNameValid
    peccNoExport,       // no such export in the sealed native snapshot
    peccNotCallable,    // the export exists but is not a function
    peccBadArgs,        // the argument is not valid JSON, or oversized
    peccThrew,          // ordinary contained plugin exception - NO taint
    peccBadResult,      // not JSON-serializable, circular, or oversized
    peccAsyncResult,    // a Promise/thenable came back        - TAINTS
    peccPendingJobs,    // the call left queued jobs            - TAINTS
    peccResourceLimit,  // CPU / stack / memory bound fired     - TAINTS
    peccInternal);      // engine or marshalling failure        - TAINTS

  { CAP-9B2 outcome of a bounded plugin teardown. puoQuarantined means
    the owning thread could NOT be joined inside the ratified budget:
    nothing the thread might still touch has been freed, and the caller
    must leak the plugin by choice rather than produce a use-after-free
    (see TPWebQuickJSPlugin.Unload). }
  TPWebUnloadOutcome = (
    puoClean,
    puoQuarantined);

  { Per-engine resource bounds, applied on the plugin thread right after
    engine creation. Zero disables the corresponding limit. }
  TPWebQuickJSLimits = record
    TimeoutSeconds: Cardinal;   // default CPU bound per Evaluate (interrupt)
    MemoryLimitBytes: PtrUInt;  // JS_SetMemoryLimit on the runtime
    StackLimitBytes: PtrUInt;   // runtime-typed JS_SetMaxStackSize
    InvokeWaitMs: Integer;      // defensive cap of the bounded native wait
  end;

  { The NATIVE authoritative plugin descriptor - the only place plugin
    identity and rights come from. It is a private record, not a public
    interface: CAP-9B1 adds no kernel interface.

    PrincipalKind is not a field because it is not a choice: a QuickJS
    plugin is always pkQuickJS. Neither plugin.json nor any JavaScript
    can influence any field here, and no field is ever derived from the
    current working directory. }
  TPWebQuickJSPackageDescriptor = record
    PrincipalId: Utf8String;         // native; '' is refused
    PluginId: Utf8String;            // native; '' is refused
    PackageStore: IAssetStore;       // ONE store per package, already scoped
    ExpectedPackageId: Utf8String;   // plugin.json "id" must match exactly
    ExpectedEntryPoint: Utf8String;  // plugin.json "entry" must match exactly
    Capabilities: TPWebCapabilities; // CAP-8 native/trusted configuration
    Engine: TPWebQuickJSLimits;      // CAP-9A per-engine bounds
    Package: TPWebPackageLimits;     // CAP-9B1 package/graph bounds
  end;

  { Host-supplied per-invocation capabilities snapshot (the CAP-8
    policy's SnapshotCapabilities). Called on the plugin thread just
    before TryEnqueue; the returned array is captured immutably by the
    frozen scheduler. When nil, the construction-time context
    capabilities are used unchanged. }
  TPWebQuickJSSnapshotEvent = function(
    const APrincipalId: Utf8String): TPWebCapabilities of object;

  { One QuickJS plugin: a dedicated thread owning one caller-owned
    engine and speaking to the runtime exclusively through the one
    registered IInvocationSource it was given. The mailbox (Post/Wait)
    lets a host run scripts ON the owning thread without ever moving a
    JSValue across threads: results are serialized to UTF-8 JSON text on
    the plugin thread before the completion event is signalled. }
  TPWebQuickJSPlugin = class(TThread)
  private
    FSource: IInvocationSource;
    FBaseContext: TInvocationContext;      // immutable native identity
    FLimits: TPWebQuickJSLimits;
    FOnSnapshot: TPWebQuickJSSnapshotEvent;
    FEngine: TQuickJSEngine;               // owned by the plugin thread
    // mailbox (single producer = the host; single consumer = this thread)
    FWork: PRTLEvent;
    FDone: PRTLEvent;
    FReady: PRTLEvent;
    FExited: PRTLEvent;                    // CAP-9B2: set LAST in Execute
    FExitedFlag: LongInt;                  // 1 once the thread body is over
    FJobKind: LongInt;                     // PWEB_JOB_SCRIPT | PWEB_JOB_EXPORT
    FScript: RawUtf8;
    FScriptTimeoutSec: Cardinal;
    FResultJson: RawUtf8;
    FErrorMsg: RawUtf8;
    FTimeoutAborted: Boolean;
    FBusy: LongInt;                        // 1 while a script is posted/running
    FPending: LongInt;                     // 1 while a posted script awaits pickup
    FDoneFlag: LongInt;                    // 1 once the result fields are final
    FStop: LongInt;
    FInitError: RawUtf8;
    FUnloaded: Boolean;
    // measured facts for the CAP-9A harness
    FCallbackCalls: LongInt;               // __pweb_invoke_json invocations
    FCallbackWrongThread: LongInt;         // calls NOT on the owning thread
    FLastSink: TObject;                    // the last sink (TPluginCompletion)
    FLastSinkRef: IInvocationCompletion;   // keeps that sink alive/readable
    FEngineDestroyedOnOwnThread: LongInt;  // 1 once freed on this thread
    // ---- CAP-9B1 package / module loader (owning thread only) ----
    FHasPackage: Boolean;
    FPackage: TPWebQuickJSPackageDescriptor;
    FPackageLimits: TPWebPackageLimits;
    FManifest: TPWebPackageManifest;
    FGraph: TPWebModuleGraph;
    FLoadState: LongInt;                   // TPWebQuickJSLoadState ordinal
    FPackageCode: TPWebPackageLoadCode;    // FIRST failure wins
    FPackageDetail: RawUtf8;               // native-only, sanitized
    FPackageError: RawUtf8;                // QuickJS diagnostic, bounded
    FNormalizeCalls: LongInt;
    FLoaderCalls: LongInt;
    FLoaderWrongThread: LongInt;           // MUST stay 0
    FLoadTimeInvokes: LongInt;             // pweb.invoke refused while Loading
    // ---- CAP-9B2 export surface / lifecycle (owning thread only) ----
    FExportTable: JSValue;                 // owned reference, freed on the thread
    FHasExportTable: Boolean;
    FExportNames: TRawUtf8DynArray;        // the sealed native snapshot
    FExportWrongThread: LongInt;           // MUST stay 0
    FTainted: LongInt;                     // 1 once the generation is unusable
    FGenerationId: Int64;                  // host lifecycle metadata only
    FUnloadOutcome: TPWebUnloadOutcome;
    // export-call mailbox slot (single producer = the host)
    FExportName: RawUtf8;
    FExportArg: TPWebJson;
    FExportCode: TPWebExportCallCode;
    FExportJson: TPWebJson;
    FExportDetail: RawUtf8;
    function InvokeJson(const This: variant;
      const Args: array of variant): variant;
    procedure ApplyLimits;
    function BuildContext: TInvocationContext;
    procedure InitCommon(const ASource: IInvocationSource;
      const AContext: TInvocationContext; const ALimits: TPWebQuickJSLimits;
      const AOnSnapshot: TPWebQuickJSSnapshotEvent);
    procedure RecordPackageFailure(ACode: TPWebPackageLoadCode;
      const ADetail: RawUtf8);
    function NormalizeModule(ctx: JSContext;
      const ABase, ASpecifier: PAnsiChar): PAnsiChar;
    function LoadModule(ctx: JSContext; AName: PAnsiChar): JSModuleDef;
    procedure LoadPackageOnOwnThread;
    procedure InstallExportTable;
    function SealExportTable(out ACode: TPWebPackageLoadCode;
      out ADetail: RawUtf8): Boolean;
    function IndexOfExport(const AName: RawUtf8): PtrInt;
    function TakeExceptionText: RawUtf8;
    procedure CallExportOnOwnThread;
  protected
    procedure Execute; override;
  public
    { AContext must be a native pkQuickJS identity: PrincipalId <> '',
      WindowId = ''. It is deep-copied (PWebCopyContext). }
    constructor Create(const ASource: IInvocationSource;
      const AContext: TInvocationContext; const ALimits: TPWebQuickJSLimits;
      const AOnSnapshot: TPWebQuickJSSnapshotEvent);
    { CAP-9B1: the same thread/engine/source shape, plus a package loaded
      from ADescriptor.PackageStore on the owning thread before the
      plugin is ever reported ready. The invocation context is built
      NATIVELY here from the descriptor - pkQuickJS, WindowId = '' -
      so no package content can reach identity.
      Prefer PWebLoadQuickJSPackage: it gives atomic load semantics. }
    constructor CreatePackage(const ASource: IInvocationSource;
      const ADescriptor: TPWebQuickJSPackageDescriptor;
      const AOnSnapshot: TPWebQuickJSSnapshotEvent);
    destructor Destroy; override;

    { Wait until the engine is created and the pweb shim bootstrapped on
      the plugin thread. False on timeout or bootstrap failure (see
      InitError). }
    function WaitReady(ATimeoutMs: Integer): Boolean;

    { Asynchronous script execution on the owning thread. Post returns
      False when a script is already in flight or the plugin stopped. }
    function PostScript(const AScript: RawUtf8;
      ATimeoutSec: Cardinal = 0): Boolean;
    { Bounded wait for the posted script. On True, AJson is the result
      serialized as JSON text ('' for a void result) and AError = '';
      a raised EQuickJSEngine surfaces as AError with AJson = ''. }
    function WaitScript(out AJson, AError: RawUtf8;
      ATimeoutMs: Integer): Boolean;
    { Post + Wait convenience. }
    function Eval(const AScript: RawUtf8; out AJson, AError: RawUtf8;
      ATimeoutSec: Cardinal = 0; AWaitMs: Integer = 15000): Boolean;

    { CAP-9B2 host-to-plugin export call. Serialized onto the OWNING
      plugin thread through the same single-slot mailbox as PostScript,
      so no caller thread ever touches JSContext, JSValue, the export
      table or the global object.

      Non-blocking with respect to other calls: a concurrent second call
      returns peccBusy synchronously, exactly like the frozen
      TryEnqueue/perBusy backpressure rule - which is also why no
      lifecycle lock is ever held waiting for a QuickJS call.

      AArgsJson is one JSON-compatible value or PWEB_JSON_NULL ('null');
      the empty string is normalized to 'null' and never spliced.
      On peccOk, AResultJson is the JSON serialization of the returned
      value ('null' for undefined). ADetail is a short sanitized native
      diagnostic, never engine stack-trace text and never a host path.
      After a code that taints (see TPWebExportCallCode) the generation
      is unusable and the host must unload it. }
    function CallExport(const AName: RawUtf8; const AArgsJson: TPWebJson;
      out AResultJson: TPWebJson; out ADetail: RawUtf8;
      AWaitMs: Integer = 0): TPWebExportCallCode;

    { Frozen teardown order: Quiesce -> Close the source, then stop the
      mailbox loop and join - the engine is destroyed on its own thread
      in Execute's epilogue. Idempotent.

      CAP-9B2: the join is BOUNDED. AJoinMs <= 0 uses
      PWEB_QUICKJS_UNLOAD_JOIN_MS. On puoQuarantined the thread could not
      be joined inside the budget: NOTHING has been freed - not this
      object, not its events, not its source reference, not its graph -
      and the caller MUST leak it by choice (never Free it) rather than
      hand a live thread freed memory. No thread is ever forcibly
      terminated. }
    function Unload(AJoinMs: Integer = 0): TPWebUnloadOutcome;

    property Source: IInvocationSource read FSource;
    property InitError: RawUtf8 read FInitError;
    property TimeoutAborted: Boolean read FTimeoutAborted;
    { measured, for the harness }
    function CallbackCalls: LongInt;
    function CallbackWrongThreadCalls: LongInt;
    function EngineDestroyedOnOwnThread: Boolean;
    { Complete-attempt count of the MOST RECENT invocation's sink: the
      frozen exactly-once gate means deliveries beyond the first are
      swallowed scheduler-side, but the sink still counts every attempt
      that reached it - the CAP-9A lifecycle matrix asserts it stays 1.
      Read only after the owning script completed (WaitScript). }
    function LastSinkDeliveries: LongInt;

    { ---- CAP-9B1 package surface (read after WaitReady) ---- }
    function LoadState: TPWebQuickJSLoadState;
    { The projected manifest. Descriptive only - it never carried any
      authority, and by the time it is readable it has already been
      checked against the native ExpectedPackageId/ExpectedEntryPoint. }
    property Manifest: TPWebPackageManifest read FManifest;
    { The module graph of the last load attempt (nil when no package was
      configured). Owned by the plugin; valid until it is destroyed. }
    property ModuleGraph: TPWebModuleGraph read FGraph;
    { Why the package failed. plcNone when it did not. }
    property PackageCode: TPWebPackageLoadCode read FPackageCode;
    { Short sanitized NATIVE detail - a module name, a manifest key.
      Never handed to script and never an absolute host path. }
    property PackageDetail: RawUtf8 read FPackageDetail;
    { The QuickJS diagnostic for a compile/evaluate failure: carries the
      package-relative module name and line/column, bounded in length.
      Never contains a host path, CWD or a native address. }
    property PackageError: RawUtf8 read FPackageError;
    { measured, for the CAP-9B1 harness }
    function NormalizeCalls: LongInt;
    function LoaderCalls: LongInt;
    function LoaderWrongThreadCalls: LongInt;
    function LoadTimeInvokes: LongInt;

    { ---- CAP-9B2 generation surface (read after a successful load) ---- }
    { The sealed export-name snapshot, in the order the package
      registered them - a NATIVE fact taken once at the load commit
      point, not a property of the live object. An empty set is legal:
      a package need not export anything. }
    function ExportCount: Integer;
    function ExportName(AIndex: Integer): RawUtf8;
    { True once a call broke the synchronous contract or blew a resource
      bound. A tainted generation refuses every further export call and
      the host must unload it. }
    function Tainted: Boolean;
    { MUST stay 0: an export call that ran off the owning thread. }
    function ExportWrongThreadCalls: LongInt;
    { The outcome of the (idempotent) Unload that already ran. }
    property UnloadOutcome: TPWebUnloadOutcome read FUnloadOutcome;
    { True once the thread body is completely over. The ONLY field of a
      quarantined plugin that is safe to read: it is an interlocked flag
      the thread writes last, and reading it never frees anything. }
    function HasExited: Boolean;
    { Host lifecycle metadata, assigned once by the lifecycle owner
      before this generation is ever published and never read by the
      plugin thread. It is NOT a capability identity: runtime grants
      stay keyed by the native PrincipalId (CAP-8, frozen). }
    property GenerationId: Int64 read FGenerationId write FGenerationId;
  end;

{ The ONE shared app-lifetime engine manager: mints caller-owned engines
  through NewEngine. Never use ThreadSafeEngine() here - the expiry pool
  is the wrong ownership shape for plugin threads (measured: pooled
  TThreadSafeManager.Destroy raises on unreleased engines). }
function PWebQuickJSManager: TThreadSafeManager;

{ Validate a native plugin descriptor WITHOUT raising and without
  constructing anything. PWebLoadQuickJSPackage calls this before it
  builds a plugin, so a malformed descriptor never reaches a
  constructor; a host calling CreatePackage directly should call it too
  (that constructor still raises, for callers who prefer exceptions). }
function PWebValidateQuickJSPackageDescriptor(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8): Boolean;

{ ATOMIC package load - the entry point hosts should use.
  On True: APlugin is a Running plugin owned by the caller.
  On False: APlugin is nil, the engine has been destroyed on its owning
  thread, ASource has been Quiesced and Closed, no invocation is
  pending and nothing ever became visible as Running. ACode/ADetail say
  why (see also the freed plugin's PackageError for the QuickJS text,
  which is copied into ADetail when there is no more specific reason). }
function PWebLoadQuickJSPackage(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  const ASource: IInvocationSource;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent;
  AReadyWaitMs: Integer;
  out APlugin: TPWebQuickJSPlugin;
  out ACode: TPWebPackageLoadCode;
  out ADetail: RawUtf8): Boolean;

const
  { Defaults chosen for plugin isolation; hosts override per plugin. }
  PWEB_QUICKJS_DEFAULT_LIMITS: TPWebQuickJSLimits = (
    TimeoutSeconds: 10;
    MemoryLimitBytes: 64 shl 20;   // 64 MB
    StackLimitBytes: 1 shl 20;     // 1 MB
    InvokeWaitMs: 15000
  );

  { CAP-9B2 default bound on ONE host-to-plugin export call. It must
    exceed InvokeWaitMs, because an export that calls pweb.invoke blocks
    for up to that long inside the frozen bounded wait. }
  PWEB_QUICKJS_EXPORT_WAIT_MS = 30000;

  { CAP-9B2 default bound on the plugin-thread join during Unload. It
    must exceed the worst legitimate case - an export blocked in
    pweb.invoke (InvokeWaitMs) plus the CPU bound that ends a runaway
    call - or a healthy plugin would be quarantined for being slow. }
  PWEB_QUICKJS_UNLOAD_JOIN_MS = 45000;

  PWEB_EXPORT_CALL_TEXT: array[TPWebExportCallCode] of RawUtf8 = (
    'ok',
    'unavailable',
    'busy',
    'bad_name',
    'no_export',
    'not_callable',
    'bad_args',
    'threw',
    'bad_result',
    'async_result',
    'pending_jobs',
    'resource_limit',
    'internal');

  PWEB_UNLOAD_OUTCOME_TEXT: array[TPWebUnloadOutcome] of RawUtf8 = (
    'clean',
    'quarantined');

{ True for the codes that make the generation unusable: the host closes
  it, bounded, and never lets it serve another call. A contained plugin
  exception is deliberately NOT one of them - the engine is still
  valid, measured. }
function PWebExportCallTaints(ACode: TPWebExportCallCode): Boolean;

{ ---------------- CAP-9B2 quarantine ledger ---------------- }

{ Take permanent custody of a plugin whose owning thread could not be
  joined. The instance is NEVER freed and never reused - a deliberate,
  counted, loud leak, because the alternative is handing a live thread
  freed memory. There is no un-quarantine: that is the point. }
procedure PWebQuarantineQuickJSPlugin(APlugin: TPWebQuickJSPlugin);
/// how many generations have ever been quarantined in this process
function PWebQuickJSQuarantineCount: Integer;
/// how many of them have since finished their thread body
// - lets a harness prove the leak was safe (the thread really was still
// live at quarantine time and ended later) WITHOUT freeing anything
function PWebQuickJSQuarantineExited: Integer;

implementation

{$ifdef DARWIN}
  // CI-built from the pinned deps/mormot2/res/static/libquickjs
  // amalgamation by tools/build_quickjs_darwin.sh; the build runner
  // passes -Fo<dir> so this bare name resolves. The pinned
  // mormot.lib.quickjs {$L} table has no OSDARWIN clause, so this is
  // the only link of QuickJS on both macOS targets.
  {$L quickjs.o}
  {$ifdef CPUAARCH64}
  // aarch64-darwin defines NOLIBCSTATIC (mormot.defines.inc), which
  // strips the pas_* heap family from mormot.lib.static - the pinned
  // QuickJS sources route every allocation and assert through them
  // (cutils.h), so this unit exports them here, mirroring
  // mormot.lib.static's declarations. Darwin C symbols carry the '_'
  // prefix.

{ size is PtrUInt, deliberately WIDER than the pinned mormot.lib.static
  declaration (cardinal): the C side passes size_t, and truncating a
  >4 GiB request to 32 bits would return an undersized buffer to the
  engine. The pinned declaration carries that defect on the targets that
  link mormot.lib.static; recorded in the deferred-work ledger as part
  of the upstream report. }
function pas_malloc(size: PtrUInt): pointer; cdecl;
  public name '_pas_malloc';
begin
  GetMem(result, size);
end;

function pas_calloc(n, size: PtrUInt): pointer; cdecl;
  public name '_pas_calloc';
begin
  if (n <> 0) and (size > High(PtrUInt) div n) then
    exit(nil); // n*size overflow: fail the allocation, never undersize it
  result := AllocMem(size * n);
end;

procedure pas_free(P: pointer); cdecl;
  public name '_pas_free';
begin
  FreeMem(P);
end;

function pas_realloc(P: pointer; Size: PtrInt): pointer; cdecl;
  public name '_pas_realloc';
begin
  ReallocMem(P, Size);
  result := P;
end;

function pas_malloc_usable_size(P: pointer): integer; cdecl;
  public name '_pas_malloc_usable_size';
begin
  result := MemSize(P);
end;

procedure pas_assertfailed(cond, fn: PAnsiChar; line: integer); cdecl;
  public name '_pas_assertfailed';
begin
  raise EPWebQuickJSPlugin.CreateFmt('Panic in %s:%d: assert(%s)',
    [fn, line, cond]);
end;
  {$endif CPUAARCH64}
{$endif DARWIN}

{ The correctly-typed private re-declaration of the pinned C entry point
  (quickjs.h:464 takes JSRuntime*). The unit-local name shadows the
  mistyped import from mormot.lib.quickjs inside this unit, so the
  mistyped binding cannot be called from here even by accident. }
procedure JS_SetMaxStackSize(rt: JSRuntime; stack_size: PtrUInt);
  cdecl; external;

{ ---------------- the shared manager ---------------- }

var
  GManager: TThreadSafeManager;

function PWebQuickJSManager: TThreadSafeManager;
begin
  Result := GManager;
end;

type
  { JS_GetOwnPropertyNames hands back a js_malloc'd C array; the pinned
    binding types it as a single PJSPropertyEnum, so indexing it needs
    this array view rather than pointer arithmetic. }
  TJSPropertyEnumArray =
    array[0..(MaxInt div SizeOf(JSPropertyEnum)) - 1] of JSPropertyEnum;
  PJSPropertyEnumArray = ^TJSPropertyEnumArray;

const
  { the two mailbox job kinds - one slot, one consumer (the plugin thread) }
  PWEB_JOB_SCRIPT = 0;
  PWEB_JOB_EXPORT = 1;

function PWebExportCallTaints(ACode: TPWebExportCallCode): Boolean;
begin
  Result := ACode in [peccAsyncResult, peccPendingJobs, peccResourceLimit,
                      peccInternal];
end;

{ ---------------- the quarantine ledger ---------------- }

var
  GQuarantineLock: TRTLCriticalSection;
  GQuarantine: TList;  // of TPWebQuickJSPlugin - NEVER freed, by design

procedure PWebQuarantineQuickJSPlugin(APlugin: TPWebQuickJSPlugin);
begin
  if APlugin = nil then
    exit;
  EnterCriticalSection(GQuarantineLock);
  try
    if GQuarantine.IndexOf(APlugin) < 0 then
      GQuarantine.Add(APlugin);
  finally
    LeaveCriticalSection(GQuarantineLock);
  end;
end;

function PWebQuickJSQuarantineCount: Integer;
begin
  EnterCriticalSection(GQuarantineLock);
  try
    Result := GQuarantine.Count;
  finally
    LeaveCriticalSection(GQuarantineLock);
  end;
end;

function PWebQuickJSQuarantineExited: Integer;
var
  i: Integer;
begin
  Result := 0;
  EnterCriticalSection(GQuarantineLock);
  try
    for i := 0 to GQuarantine.Count - 1 do
      // HasExited is an interlocked flag read - the one field of a
      // quarantined plugin that is safe to touch
      if TPWebQuickJSPlugin(GQuarantine[i]).HasExited then
        Inc(Result);
  finally
    LeaveCriticalSection(GQuarantineLock);
  end;
end;

{ ---------------- JSON helpers ---------------- }

function JsonEscape(const AText: Utf8String): Utf8String;
var
  i: PtrInt;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if c < #$20 then
        Result := Result + '\u00' +
          Utf8String(IntToHex(Ord(c), 2))
      else
        Result := Result + c;
    end;
  end;
end;

{ Data and (in ResultEnvelope) Value are spliced VERBATIM: TPWebJson's
  frozen contract (pweb.rpc.intf) is that a value of that type holds
  serialized VALID JSON with null spelled 'null', and the scheduler
  normalizes the empty string before completion - so a malformed splice
  here would mean a frozen-contract violation upstream, not a case this
  layer papers over. Message goes through JsonEscape because it is plain
  text, not JSON. }
function ErrorEnvelope(const AError: TPWebError): RawUtf8;
var
  data: RawUtf8;
begin
  data := AError.Data;
  if data = '' then
    data := PWEB_JSON_NULL;
  Result := '{"ok":false,"error":{"code":"' +
    PWEB_ERROR_CODE_TEXT[AError.Code] + '","status":' +
    RawUtf8(IntToStr(PWEB_ERROR_STATUS[AError.Code])) + ',"message":"' +
    JsonEscape(AError.Message) + '","data":' + data + '}}';
end;

function ErrorEnvelopeOf(ACode: TPWebErrorCode): RawUtf8;
var
  res: TPWebInvocationResult;
begin
  res := PWebDefaultErrorResult(ACode);
  Result := ErrorEnvelope(res.Error);
end;

function ResultEnvelope(const AResult: TPWebInvocationResult): RawUtf8;
var
  value: RawUtf8;
begin
  if AResult.Kind = prkSuccess then
  begin
    value := AResult.Value;
    if value = '' then
      value := PWEB_JSON_NULL; // '' would splice invalid JSON
    Result := '{"ok":true,"value":' + value + '}';
  end
  else
    Result := ErrorEnvelope(AResult.Error);
end;

{ ---------------- per-invocation completion sink ---------------- }

type
  { Event-signalling sink: the scheduler worker copies the discriminated
    result into native-owned data and signals; every QuickJS conversion
    stays on the plugin thread. Counts every delivery ATTEMPT so the
    exactly-once gate can be measured, not assumed. }
  TPluginCompletion = class(TInterfacedObject, IInvocationCompletion)
  private
    FEvent: PRTLEvent;
    FResult: TPWebInvocationResult;
    FClaimed: LongInt;  // exactly-once claim of the right to write FResult
    FDone: LongInt;     // published ONLY AFTER FResult is fully written
    FCalls: LongInt;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Complete(const AResult: TPWebInvocationResult);
    function WaitResult(out AResult: TPWebInvocationResult;
      ATimeoutMs: Integer): Boolean;
    function CompleteCalls: LongInt;
  end;

constructor TPluginCompletion.Create;
begin
  inherited Create;
  FEvent := RTLEventCreate;
end;

destructor TPluginCompletion.Destroy;
begin
  if FEvent <> nil then
    RTLEventDestroy(FEvent);
  inherited Destroy;
end;

procedure TPluginCompletion.Complete(const AResult: TPWebInvocationResult);
begin
  InterlockedIncrement(FCalls);
  if InterlockedExchange(FClaimed, 1) <> 0 then
    exit; // idempotent - the frozen gate upstream makes this unreachable
  // FResult (a managed record) is fully written BEFORE FDone publishes it:
  // a waiter that times out of the event and then reads FDone must never
  // observe a torn record. InterlockedExchange is a full barrier on every
  // supported target.
  FResult := AResult;
  InterlockedExchange(FDone, 1);
  RTLEventSetEvent(FEvent);
end;

function TPluginCompletion.CompleteCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FCalls, 0, 0);
end;

function TPluginCompletion.WaitResult(out AResult: TPWebInvocationResult;
  ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FEvent, ATimeoutMs);
  if InterlockedCompareExchange(FDone, 0, 0) <> 0 then
  begin
    AResult := FResult;
    Result := True;
  end
  else
  begin
    AResult := Default(TPWebInvocationResult);
    Result := False;
  end;
end;

{ ---------------- the bootstrap shim ---------------- }

const
  { Defines the frozen script-facing surface: pweb.invoke(method, args)
    and pweb.handshake(). The raw native callback is removed from the
    global object so scripts reach the runtime only through the shim;
    on ok:false a PWebError-shaped object (name/code/status/message/
    data) is thrown - QuickJS syntax/runtime errors stay distinct. }
  PWEB_QUICKJS_BOOTSTRAP: RawUtf8 =
    '(function () {' + #10 +
    '  "use strict";' + #10 +
    '  var native = globalThis.__pweb_invoke_json;' + #10 +
    '  delete globalThis.__pweb_invoke_json;' + #10 +
    '  function call(method, args) {' + #10 +
    '    var argsJson;' + #10 +
    '    if (args === null || args === undefined) argsJson = "null";' + #10 +
    '    else argsJson = JSON.stringify(args);' + #10 +
    '    if (argsJson === undefined) argsJson = "null";' + #10 +
    '    var envelope = JSON.parse(native(String(method), String(argsJson)));' + #10 +
    '    if (envelope.ok) return envelope.value;' + #10 +
    '    var err = envelope.error;' + #10 +
    '    var e = new Error(err.message);' + #10 +
    '    e.name = "PWebError";' + #10 +
    '    e.code = err.code;' + #10 +
    '    e.status = err.status;' + #10 +
    '    e.data = err.data;' + #10 +
    '    throw e;' + #10 +
    '  }' + #10 +
    '  var pweb = {' + #10 +
    '    invoke: function (method, args) {' + #10 +
    '      if (args === undefined) args = null;' + #10 +
    '      return call(method, args);' + #10 +
    '    },' + #10 +
    '    handshake: function () { return call("pweb.handshake", null); }' + #10 +
    '  };' + #10 +
    '  Object.freeze(pweb);' + #10 +
    '  Object.defineProperty(globalThis, "pweb",' + #10 +
    '    { value: pweb, writable: false, configurable: false });' + #10 +
    '})();';

{ ---------------- TPWebQuickJSPlugin ---------------- }

procedure TPWebQuickJSPlugin.InitCommon(const ASource: IInvocationSource;
  const AContext: TInvocationContext; const ALimits: TPWebQuickJSLimits;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent);
begin
  if ASource = nil then
    raise EPWebQuickJSPlugin.Create('TPWebQuickJSPlugin requires a source');
  if AContext.PrincipalKind <> pkQuickJS then
    raise EPWebQuickJSPlugin.Create(
      'TPWebQuickJSPlugin requires a pkQuickJS context');
  if AContext.PrincipalId = '' then
    raise EPWebQuickJSPlugin.Create(
      'TPWebQuickJSPlugin requires a native PrincipalId');
  if AContext.WindowId <> '' then
    raise EPWebQuickJSPlugin.Create(
      'a QuickJS principal has no WindowId (must be empty)');
  FSource := ASource;
  FBaseContext := PWebCopyContext(AContext);
  FLimits := ALimits;
  if FLimits.InvokeWaitMs <= 0 then
    FLimits.InvokeWaitMs := PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs;
  FOnSnapshot := AOnSnapshot;
  FExportTable := JSValue(JS_UNDEFINED);
  FWork := RTLEventCreate;
  FDone := RTLEventCreate;
  FReady := RTLEventCreate;
  FExited := RTLEventCreate;
end;

constructor TPWebQuickJSPlugin.Create(const ASource: IInvocationSource;
  const AContext: TInvocationContext; const ALimits: TPWebQuickJSLimits;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent);
begin
  // The TThread base is constructed FIRST, suspended. When an exception
  // escapes a constructor, Object Pascal runs the destructor - and
  // TThread.Destroy on a base whose Create never ran dereferences
  // uninitialised handles (measured: EAccessViolation, reproducible from
  // any descriptor-validation raise). Constructing suspended keeps the
  // old ordering guarantee too: the thread cannot observe a field
  // InitCommon has not assigned yet, because it does not run until Start.
  inherited Create({suspended=}True);
  InitCommon(ASource, AContext, ALimits, AOnSnapshot);
  // no package: qlsIdle, and Execute keeps the exact CAP-9A shape
  Start;
end;

constructor TPWebQuickJSPlugin.CreatePackage(const ASource: IInvocationSource;
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent);
var
  ctx: TInvocationContext;
  code: TPWebPackageLoadCode;
  detail: RawUtf8;
begin
  // TThread base first and suspended - see the note in Create. Every
  // raise below would otherwise send the destructor into an
  // unconstructed TThread.
  inherited Create({suspended=}True);
  if not PWebValidateQuickJSPackageDescriptor(ADescriptor, code, detail) then
    raise EPWebQuickJSPlugin.CreateFmt('plugin descriptor rejected: %s (%s)',
      [PWEB_PACKAGE_LOAD_TEXT[code], detail]);
  // the context is built HERE, natively, from the descriptor alone -
  // pkQuickJS is not a choice, and WindowId is always empty for a
  // plugin principal (security-model.md)
  ctx := Default(TInvocationContext);
  ctx.PrincipalKind := pkQuickJS;
  ctx.PrincipalId := ADescriptor.PrincipalId;
  ctx.PluginId := ADescriptor.PluginId;
  ctx.WindowId := '';
  ctx.Capabilities := ADescriptor.Capabilities;
  ctx.TrustedContent := False;
  // EVERYTHING that can raise happens BEFORE InitCommon allocates the
  // events: once FWork is non-nil, Unload no longer takes its
  // never-started guard, so a raise between here and inherited Create
  // would send the destructor into WaitFor on a thread that does not
  // exist. Create the graph first and that window does not exist.
  FPackage := ADescriptor;
  FHasPackage := True;
  FPackageLimits := PWebClampPackageLimits(ADescriptor.Package);
  FGraph := TPWebModuleGraph.Create(FPackageLimits);
  InterlockedExchange(FLoadState, Ord(qlsLoading));
  InitCommon(ASource, ctx, ADescriptor.Engine, AOnSnapshot);
  Start;
end;

destructor TPWebQuickJSPlugin.Destroy;
begin
  // idempotent; the BOUNDED join makes the events unobserved
  if Unload = puoQuarantined then
    // The owning thread could not be joined. Every field below is
    // something that thread may still read or write, so freeing any of
    // it - including this instance - would be a use-after-free. Raising
    // here aborts the destructor before FreeInstance runs, so the object
    // leaks by choice, which is the ratified last-resort behaviour.
    // A correct host never reaches this: it moves a quarantined
    // generation to the quarantine ledger instead of freeing it.
    raise EPWebQuickJSPlugin.Create(
      'TPWebQuickJSPlugin.Free on a QUARANTINED plugin: the owning ' +
      'thread was not joined; the instance must be leaked, not freed');
  inherited Destroy; // TThread.Destroy joins again (no-op when finished)
  if FWork <> nil then
    RTLEventDestroy(FWork);
  if FDone <> nil then
    RTLEventDestroy(FDone);
  if FReady <> nil then
    RTLEventDestroy(FReady);
  if FExited <> nil then
    RTLEventDestroy(FExited);
  FreeAndNil(FGraph);
end;

procedure TPWebQuickJSPlugin.ApplyLimits;
begin
  // CPU: the pinned interrupt handler polls GetTickSec against
  // TimeoutValue; it applies per Evaluate call (Execute sets it before
  // each script from the mailbox request).
  FEngine.TimeoutValue := FLimits.TimeoutSeconds;
  // memory: correctly-typed pinned binding, safe to use as-is
  if FLimits.MemoryLimitBytes <> 0 then
    JS_SetMemoryLimit(FEngine.rt, FLimits.MemoryLimitBytes);
  // stack: the runtime-typed private external above - NEVER the pinned
  // mistyped mormot binding (measured 0xC0000005 under allocation
  // pressure when the context is passed where the C side reads a
  // JSRuntime*)
  if FLimits.StackLimitBytes <> 0 then
    JS_SetMaxStackSize(FEngine.rt, FLimits.StackLimitBytes);
end;

function TPWebQuickJSPlugin.BuildContext: TInvocationContext;
begin
  Result := PWebCopyContext(FBaseContext);
  if Assigned(FOnSnapshot) then
    Result.Capabilities := FOnSnapshot(Result.PrincipalId);
end;

function TPWebQuickJSPlugin.InvokeJson(const This: variant;
  const Args: array of variant): variant;
var
  method: Utf8String;
  argsJson: TPWebJson;
  ctx: TInvocationContext;
  comp: TPluginCompletion;
  compRef: IInvocationCompletion;
  enq: TPWebEnqueueResult;
  res: TPWebInvocationResult;
  envelope: RawUtf8;
begin
  InterlockedIncrement(FCallbackCalls);
  // explicit call parentheses: on POSIX TThreadID is pointer-sized, so a
  // bare ObjFPC function reference in the comparison would be taken as a
  // function POINTER, not a call (measured red on the hosted linux job)
  if GetCurrentThreadId() <> ThreadID then
    InterlockedIncrement(FCallbackWrongThread);
  if InterlockedCompareExchange(FLoadState, 0, 0) = Ord(qlsLoading) then
  begin
    // RATIFIED (CAP-9B1): no invocation of any kind - pweb.handshake
    // included, since it is an ordinary bridge-routed method - leaves a
    // package that has not yet been accepted. Top-level module
    // evaluation must not produce backend side effects, so a failed
    // load can never leave partial service operations behind. This is
    // the ONE gate; the frozen scheduler/policy path is untouched.
    InterlockedIncrement(FLoadTimeInvokes);
    envelope := ErrorEnvelopeOf(pecRuntimeClosed);
  end
  else if (Length(Args) <> 2) or
     (not VarIsStr(Args[0])) or (not VarIsStr(Args[1])) then
    envelope := ErrorEnvelopeOf(pecInvalidRequest)
  else
  begin
    method := Utf8String(VariantToUtf8(Args[0]));
    argsJson := TPWebJson(VariantToUtf8(Args[1]));
    ctx := BuildContext;
    comp := TPluginCompletion.Create;
    compRef := comp;
    FLastSink := comp;       // harness-visible exactly-once evidence
    FLastSinkRef := compRef; // keeps it alive past the invocation
    // the frozen single canonicalization/validation gate - malformed
    // method or args grammar rejects synchronously, pre-queue
    enq := FSource.TryEnqueue(ctx, method, argsJson, compRef);
    if enq <> perAccepted then
      envelope := ErrorEnvelopeOf(PWEB_ENQUEUE_ERROR[enq])
    else if comp.WaitResult(res, FLimits.InvokeWaitMs) then
      envelope := ResultEnvelope(res)
    else
      // defensive cap only: exactly-once completion through the frozen
      // lifecycle makes this unreachable in a correct runtime
      envelope := ErrorEnvelopeOf(pecInternalError);
  end;
  RawUtf8ToVariant(envelope, Result);
end;

{ ---------------- CAP-9B1 module loader ---------------- }

const
  { Script-visible throw texts. FIXED LITERALS, never interpolated: the
    pinned JS_ThrowReferenceError is `int JS_ThrowReferenceError(ctx,
    const char *fmt, ...)` in C but is declared `(ctx; fmt: PAnsiChar)`
    in mormot.lib.quickjs, so a '%' reaching it would consume a vararg
    that was never pushed. The precise reason goes to the NATIVE
    PackageCode/PackageDetail instead - which is where a host wants it
    anyway, and which script can never read. }
  PWEB_THROW_SPECIFIER: PAnsiChar = 'pweb: invalid module specifier';
  PWEB_THROW_MISSING: PAnsiChar   = 'pweb: module not found';
  PWEB_THROW_SOURCE: PAnsiChar    = 'pweb: invalid module source';
  PWEB_THROW_LIMIT: PAnsiChar     = 'pweb: module graph limit exceeded';
  PWEB_THROW_CLOSED: PAnsiChar    = 'pweb: module loading is closed';
  PWEB_THROW_INTERNAL: PAnsiChar  = 'pweb: module loader error';

  { An empty module is legal, but JS_Eval needs a zero-terminated
    buffer and pointer('') is nil in FPC - so an empty source compiles
    from this one static NUL instead of a null pointer. }
  PWEB_EMPTY_SOURCE: AnsiChar = #0;

  PWEB_PACKAGE_DETAIL_MAX = 120;
  PWEB_PACKAGE_ERROR_MAX = 2048;

{ Reduce attacker-influenced text to printable ASCII and bound it, so a
  module name, specifier or engine diagnostic recorded natively can never
  carry control bytes into a host's log, never grows without limit, and
  can never be truncated into invalid UTF-8 (every retained byte is
  ASCII, so there is no multi-byte sequence left to cut). }
function SafeText(const AText: RawUtf8; AMax: PtrInt): RawUtf8;
var
  i, n: PtrInt;
  c: AnsiChar;
begin
  n := Length(AText);
  if n > AMax then
    n := AMax;
  SetLength(Result, n);
  for i := 1 to n do
  begin
    c := AText[i];
    if (c < #$20) or (c >= #$7F) then
      Result[i] := '?'
    else
      Result[i] := c;
  end;
end;

function SafeDetail(const AText: RawUtf8): RawUtf8;
begin
  Result := SafeText(AText, PWEB_PACKAGE_DETAIL_MAX);
end;

{ The two cdecl trampolines registered with JS_SetModuleLoaderFunc. The
  plugin arrives through the loader opaque, so no global lookup and no
  shared state is involved. Both are exception barriers: a Pascal
  exception must never cross a C callback (threading-model.md). }
function PWebQuickJSNormalize(ctx: JSContext; const module_base_name,
  module_name: PAnsiChar; opaque: pointer): PAnsiChar; cdecl;
begin
  try
    Result := TPWebQuickJSPlugin(opaque).NormalizeModule(
      ctx, module_base_name, module_name);
  except
    Result := nil;
    JS_ThrowReferenceError(ctx, PWEB_THROW_INTERNAL);
  end;
end;

function PWebQuickJSLoad(ctx: JSContext; module_name: PAnsiChar;
  opaque: pointer): JSModuleDef; cdecl;
begin
  try
    Result := TPWebQuickJSPlugin(opaque).LoadModule(ctx, module_name);
  except
    Result := nil;
    JS_ThrowReferenceError(ctx, PWEB_THROW_INTERNAL);
  end;
end;

procedure TPWebQuickJSPlugin.RecordPackageFailure(
  ACode: TPWebPackageLoadCode; const ADetail: RawUtf8);
begin
  // FIRST failure wins: later cascading failures (the entry's evaluate
  // failing because one import could not be resolved) must not bury the
  // root cause
  if FPackageCode <> plcNone then
    exit;
  FPackageCode := ACode;
  FPackageDetail := SafeDetail(ADetail);
end;

function TPWebQuickJSPlugin.NormalizeModule(ctx: JSContext;
  const ABase, ASpecifier: PAnsiChar): PAnsiChar;
var
  base, spec, canonical: RawUtf8;
  code: TPWebPackageLoadCode;
  p: PAnsiChar;
begin
  Result := nil;
  InterlockedIncrement(FNormalizeCalls);
  // engine-thread affinity, asserted rather than assumed: no scheduler
  // worker may ever resolve, read or compile a module
  if GetCurrentThreadId() <> ThreadID then
  begin
    InterlockedIncrement(FLoaderWrongThread);
    RecordPackageFailure(plcThread, 'normalize');
    JS_ThrowReferenceError(ctx, PWEB_THROW_INTERNAL);
    exit;
  end;
  if InterlockedCompareExchange(FLoadState, 0, 0) <> Ord(qlsLoading) then
  begin
    // the graph is sealed once the package is accepted: nothing may add
    // a module after load (and a dynamic import, were a job pump ever
    // added, would land here rather than in the store)
    JS_ThrowReferenceError(ctx, PWEB_THROW_CLOSED);
    exit;
  end;
  // FastSetString, never RawUtf8(PAnsiChar): the cast goes through the
  // string's code page, and it is byte-verbatim here only because mORMot
  // happens to have switched the RTL default to UTF-8 at startup. This
  // is the same trap StripBom's byte-literal comparison and the harness
  // Bytes() helper exist to avoid; a module specifier is bytes, and the
  // resolver must see the bytes QuickJS handed it.
  FastSetString(base, ABase, StrLen(ABase));
  FastSetString(spec, ASpecifier, StrLen(ASpecifier));
  // ALL resolution happens here: QuickJS joins nothing and hands the
  // specifier through verbatim
  if not PWebResolveModuleSpecifier(base, spec,
      FPackageLimits.MaxSpecifierBytes, canonical) then
  begin
    RecordPackageFailure(plcSpecifier, base + ' -> ' + spec);
    JS_ThrowReferenceError(ctx, PWEB_THROW_SPECIFIER);
    exit;
  end;
  if not FGraph.AddEdge(base, canonical, code) then
  begin
    RecordPackageFailure(code, canonical);
    JS_ThrowReferenceError(ctx, PWEB_THROW_LIMIT);
    exit;
  end;
  // QuickJS takes ownership of this buffer and js_free()s it
  p := js_malloc(ctx, Length(canonical) + 1);
  if p = nil then
  begin
    RecordPackageFailure(plcEngine, 'js_malloc');
    exit; // QuickJS already threw its own out-of-memory
  end;
  if Length(canonical) > 0 then
    Move(canonical[1], p^, Length(canonical));
  p[Length(canonical)] := #0;
  Result := p;
end;

function TPWebQuickJSPlugin.LoadModule(ctx: JSContext;
  AName: PAnsiChar): JSModuleDef;
var
  name, src: RawUtf8;
  asset: TAssetResponse;
  code: TPWebPackageLoadCode;
  v: JSValue;
  p: PAnsiChar;
begin
  Result := nil;
  InterlockedIncrement(FLoaderCalls);
  if GetCurrentThreadId() <> ThreadID then
  begin
    InterlockedIncrement(FLoaderWrongThread);
    RecordPackageFailure(plcThread, 'load');
    JS_ThrowReferenceError(ctx, PWEB_THROW_INTERNAL);
    exit;
  end;
  if InterlockedCompareExchange(FLoadState, 0, 0) <> Ord(qlsLoading) then
  begin
    JS_ThrowReferenceError(ctx, PWEB_THROW_CLOSED);
    exit;
  end;
  FastSetString(name, AName, StrLen(AName)); // bytes, not a code page
  // defence in depth: NormalizeModule produced this name, but a module
  // name reaching a store read unvalidated is precisely the hole this
  // layer exists to close
  if not PWebPackageEntryValid(name) then
  begin
    RecordPackageFailure(plcSpecifier, name);
    JS_ThrowReferenceError(ctx, PWEB_THROW_SPECIFIER);
    exit;
  end;
  // the ONE store call, with the ONE canonical logical path
  if not FPackage.PackageStore.TryRead(name, asset) then
  begin
    RecordPackageFailure(plcModuleMissing, name);
    JS_ThrowReferenceError(ctx, PWEB_THROW_MISSING);
    exit;
  end;
  // bound the RAW asset first: IAssetStore is frozen with no size form,
  // so this is the earliest point the length is observable - and it
  // refuses before PWebPrepareModuleSource copies the whole thing again
  if PtrUInt(Length(asset.Content)) > FPackageLimits.ModuleMaxBytes then
  begin
    RecordPackageFailure(plcModuleTooLarge, name);
    JS_ThrowReferenceError(ctx, PWEB_THROW_LIMIT);
    exit;
  end;
  if not PWebPrepareModuleSource(asset.Content, src, code) then
  begin
    RecordPackageFailure(code, name);
    JS_ThrowReferenceError(ctx, PWEB_THROW_SOURCE);
    exit;
  end;
  // charged BEFORE compiling: the graph is bounded while it is still
  // bytes, not after the engine has allocated it
  if not FGraph.Charge(name, Length(src), code) then
  begin
    RecordPackageFailure(code, name);
    JS_ThrowReferenceError(ctx, PWEB_THROW_LIMIT);
    exit;
  end;
  if src = '' then
    p := @PWEB_EMPTY_SOURCE
  else
    p := pointer(src);
  v := JSValue(JS_Eval(ctx, p, Length(src), pointer(name),
    JS_EVAL_TYPE_MODULE or JS_EVAL_FLAG_COMPILE_ONLY));
  // QuickJS COPIES the source here (measured), so src may die with this
  // frame; nothing keeps the store buffer alive past the compile
  if v.IsException then
  begin
    RecordPackageFailure(plcCompile, name);
    // deliberately leave QuickJS's own SyntaxError pending: it already
    // carries the package-relative module name and line/column, and the
    // caller reads it once at the top of the load
    exit;
  end;
  Result := v.Ptr;
  ctx^.Free(v); // the module is already referenced by the context
  // NOTE: js_module_set_import_meta is deliberately NOT called - it is
  // unnecessary and its use_realpath branch touches the filesystem
end;

{ ---------------- CAP-9B2 export surface ---------------- }

procedure TPWebQuickJSPlugin.InstallExportTable;
var
  tbl: JSValueRaw;
begin
  // A NULL-PROTOTYPE object, deliberately. With a plain {} the
  // prototype chain is live, so CallExport('toString') resolves
  // Object.prototype.toString and SUCCEEDS - measured at Checkpoint 1,
  // which is why the container is native rather than a convention.
  tbl := JS_NewObjectProto(FEngine.cx, JS_NULL);
  if JSValue(tbl).IsException then
  begin
    RecordPackageFailure(plcEngine, 'export table');
    exit;
  end;
  // CONFIGURABLE (so native can delete it once the package is accepted)
  // but NOT writable: module code is always strict, so replacing the
  // table raises "'pwebExports' is read-only" rather than shadowing it,
  // and a sloppy write is a silent no-op. Measured both ways.
  JS_DefinePropertyValueStr(FEngine.cx, FEngine.GlobalObj.Raw,
    pointer(PWEB_EXPORT_TABLE), tbl, JS_PROP_CONFIGURABLE);
  // DefinePropertyValue CONSUMED tbl; re-read to hold an OWNED
  // reference. It is freed on this thread in Execute's epilogue - a
  // JSValue still alive at JS_FreeRuntime trips the pinned
  // assert(list_empty(&rt->gc_obj_list)) and kills the process with no
  // catchable Pascal exception (measured).
  FExportTable := JSValue(JS_GetPropertyStr(FEngine.cx,
    FEngine.GlobalObj.Raw, pointer(PWEB_EXPORT_TABLE)));
  FHasExportTable := FExportTable.IsObject;
  if not FHasExportTable then
    RecordPackageFailure(plcEngine, 'export table');
end;

function TPWebQuickJSPlugin.SealExportTable(
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8): Boolean;
var
  tab: PJSPropertyEnum;
  n: Cardinal;
  // SIGNED, deliberately: JS_GetOwnPropertyNames reports a Cardinal
  // count, and `for i := 0 to n - 1` with n = 0 underflows to 4 billion
  // iterations over freed memory. An export set of zero is the NORMAL
  // case (every CAP-9B1 package has one), so this is the common path.
  count, i: Integer;
  len: PtrUInt;
  truncated: Boolean;
  p: PAnsiChar;
  name: RawUtf8;
  sv: JSValue;
  atom: JSAtom;
begin
  Result := False;
  ACode := plcNone;
  ADetail := '';
  FExportNames := nil;
  if not FHasExportTable then
  begin
    ACode := plcEngine;
    ADetail := 'export table';
    exit;
  end;
  // 1. RE-IMPOSE the null prototype. A package can call
  //    Object.setPrototypeOf(pwebExports, Object.prototype) during load
  //    and it works (measured), which puts toString/constructor back in
  //    reach. The prototype is therefore forced, never trusted.
  JS_SetPrototype(FEngine.cx, JSValueRaw(FExportTable), JS_NULL);
  // 2. Freeze the SHAPE: no export can appear after the package is
  //    accepted, and a non-extensible object also refuses any further
  //    setPrototypeOf. Values may still be reassigned by the plugin -
  //    that is the plugin's own business, and the NAME set is what the
  //    host resolves against.
  JS_PreventExtensions(FEngine.cx, JSValueRaw(FExportTable));
  // 3. Snapshot the names natively, in registration order. ALL own string
  //    properties, NOT just the enumerable ones: with JS_GPN_ENUM_ONLY a
  //    package that used Object.defineProperty would put an export in the
  //    table that the snapshot never listed, and the host would answer
  //    no_export for something visibly present. The snapshot must BE the
  //    table's own-property set.
  tab := nil;
  n := 0;
  if JS_GetOwnPropertyNames(FEngine.cx, @tab, @n, JSValueRaw(FExportTable),
       JS_GPN_STRING_MASK) <> 0 then
  begin
    ACode := plcEngine;
    ADetail := 'export names';
    exit;
  end;
  // compare as CARDINAL before narrowing: Integer(n) of a huge count would
  // go negative and slip past the bound below
  if n > Cardinal(PWEB_EXPORT_MAX_COUNT) then
    count := PWEB_EXPORT_MAX_COUNT + 1
  else
    count := Integer(n);
  try
    if count > PWEB_EXPORT_MAX_COUNT then
    begin
      ACode := plcExportCount;
      ADetail := 'exports=' + RawUtf8(IntToStr(n));
      count := Integer(n); // so the finally still frees every atom
      exit;
    end;
    SetLength(FExportNames, count);
    for i := 0 to count - 1 do
    begin
      // via the atom's STRING, so the true byte length is observable.
      // JS_AtomToCString alone would hand back a NUL-terminated buffer,
      // and a property name containing an embedded U+0000 would silently
      // truncate - aliasing one export onto another's spelling.
      sv := JSValue(JS_AtomToString(FEngine.cx,
        PJSPropertyEnumArray(tab)^[i].atom));
      if sv.IsException then
      begin
        ACode := plcEngine;
        ADetail := 'export name';
        exit;
      end;
      len := 0;
      p := JS_ToCStringLen2(FEngine.cx, @len, JSValueRaw(sv), {cesu8=}False);
      if p = nil then
      begin
        FEngine.cx^.Free(sv);
        ACode := plcEngine;
        ADetail := 'export name';
        exit;
      end;
      truncated := PtrUInt(StrLen(p)) <> len;
      // bytes, never RawUtf8(PAnsiChar): the cast goes through the
      // string's code page (the CAP-9B1 trap)
      FastSetString(name, p, StrLen(p));
      JS_FreeCString(FEngine.cx, p);
      FEngine.cx^.Free(sv);
      if truncated or not PWebExportNameValid(name) then
      begin
        // LOUD, not skipped: a package whose export the host can never
        // name is a packaging mistake, and silently dropping it would
        // surface much later as an unexplained no_export
        ACode := plcExportName;
        ADetail := name;
        exit;
      end;
      FExportNames[i] := name;
    end;
    Result := True;
  finally
    for i := 0 to count - 1 do
      JS_FreeAtom(FEngine.cx, PJSPropertyEnumArray(tab)^[i].atom);
    js_free(FEngine.cx, tab);
    if not Result then
      FExportNames := nil;
    // 4. Whatever happened, take the table off the global object: from
    //    here nothing script-visible names it, so no export can be added
    //    or replaced through the global. A reference a module stashed
    //    during load still points at the object - which is exactly why
    //    step 2, not this step, is the security property.
    atom := JS_NewAtom(FEngine.cx, pointer(PWEB_EXPORT_TABLE));
    JS_DeleteProperty(FEngine.cx, FEngine.GlobalObj.Raw, atom, 0);
    JS_FreeAtom(FEngine.cx, atom);
  end;
end;

function TPWebQuickJSPlugin.IndexOfExport(const AName: RawUtf8): PtrInt;
var
  i: PtrInt;
begin
  for i := 0 to High(FExportNames) do
    if FExportNames[i] = AName then // byte-exact, no case folding
      exit(i);
  Result := -1;
end;

{ Take the pending exception and reduce it to bounded, sanitized
  'Name: message' text. Deliberately NOT cx^.ErrorMessage(stacktrace) -
  a stack-overflow diagnostic there is ~20 KB of repeated frames
  (measured), and a host lifecycle failure has no use for a stack. }
function TPWebQuickJSPlugin.TakeExceptionText: RawUtf8;
var
  exc: JSValue;
  name, msg: RawUtf8;

  { read one string property, and never leave a getter's own throw
    pending on the context - the next call would inherit it }
  function StrProp(const AProp: PAnsiChar): RawUtf8;
  var
    v, e: JSValue;
  begin
    Result := '';
    v := JSValue(JS_GetPropertyStr(FEngine.cx, JSValueRaw(exc), AProp));
    if v.IsException then
    begin
      e := JSValue(JS_GetException(FEngine.cx));
      FEngine.cx^.Free(e);
      exit;
    end;
    if v.IsString then
      Result := FEngine.cx^.ToUtf8(v);
    FEngine.cx^.Free(v);
  end;

begin
  Result := '';
  exc := JSValue(JS_GetException(FEngine.cx));
  if exc.IsUndefined or exc.IsNull then
  begin
    FEngine.cx^.Free(exc);
    exit;
  end;
  try
    if exc.IsObject then
    begin
      name := StrProp('name');
      msg := StrProp('message');
    end
    else
      msg := FEngine.cx^.ToUtf8(exc, {noJson=}True);
  finally
    FEngine.cx^.Free(exc);
  end;
  if name = '' then
    Result := msg
  else if msg = '' then
    Result := name
  else
    Result := name + ': ' + msg;
  Result := SafeDetail(Result);
end;

procedure TPWebQuickJSPlugin.CallExportOnOwnThread;
var
  fn, arg, res, js, thenv: JSValue;
  argv: array[0..0] of JSValueConst;
  text: RawUtf8;
  isLimit: Boolean;
begin
  FExportCode := peccInternal;
  FExportJson := '';
  FExportDetail := '';
  // engine-thread affinity, asserted rather than assumed
  if GetCurrentThreadId() <> ThreadID then
  begin
    InterlockedIncrement(FExportWrongThread);
    FExportDetail := 'wrong thread';
    exit;
  end;
  if not FHasExportTable then
  begin
    FExportCode := peccNoExport;
    exit;
  end;
  if not PWebExportNameValid(FExportName) then
  begin
    FExportCode := peccBadName;
    exit;
  end;
  // membership in the SEALED NATIVE snapshot decides existence. The
  // null prototype already makes Object.prototype members unreachable;
  // this makes the export set a native fact, so a value the plugin
  // reassigned to a name it never registered still cannot be reached.
  if IndexOfExport(FExportName) < 0 then
  begin
    FExportCode := peccNoExport;
    exit;
  end;
  if Length(FExportArg) > PWEB_EXPORT_ARG_MAX_BYTES then
  begin
    FExportCode := peccBadArgs;
    FExportDetail := 'argument too large';
    exit;
  end;
  fn := JSValue(JS_GetPropertyStr(FEngine.cx, JSValueRaw(FExportTable),
    pointer(FExportName)));
  if fn.IsException then
  begin
    FExportDetail := TakeExceptionText;
    exit;
  end;
  if not JS_IsFunction(FEngine.cx, JSValueRaw(fn)) then
  begin
    FEngine.cx^.Free(fn);
    FExportCode := peccNotCallable;
    exit;
  end;
  arg := JSValue(JS_ParseJSON(FEngine.cx, pointer(FExportArg),
    Length(FExportArg), 'pweb-export-arg.json'));
  if arg.IsException then
  begin
    FExportDetail := TakeExceptionText;
    FEngine.cx^.Free(fn);
    FExportCode := peccBadArgs;
    exit;
  end;
  argv[0] := JSValueRaw(arg);
  try
    // ARM the CPU window. Measured mandatory: TQuickJSEngine.Evaluate is
    // the only public API that sets the interrupt's start tick, and
    // WITHOUT this call a long JS_Call aborts on its very first
    // interrupt poll ('THREW after 0ms timeoutAborted=yes'). One armed
    // window covers exactly this one export call.
    FEngine.TimeoutValue := FLimits.TimeoutSeconds;
    FEngine.Evaluate('0', 'pweb-arm.js');
  except
    on E: Exception do
    begin
      FEngine.cx^.Free(arg);
      FEngine.cx^.Free(fn);
      FExportDetail := SafeDetail(RawUtf8(E.Message));
      exit; // peccInternal - the engine could not even be armed
    end;
  end;
  res := JSValue(JS_Call(FEngine.cx, JSValueRaw(fn), JS_UNDEFINED, 1, @argv[0]));
  FEngine.cx^.Free(arg);
  FEngine.cx^.Free(fn);
  if res.IsException then
  begin
    text := TakeExceptionText;
    FExportDetail := text;
    // TimeoutAborted is an ENGINE fact and outranks any text. The other
    // two bounds have no API in this pin, so they are recognised by the
    // exact literals the pinned C throws (quickjs.c JS_ThrowStackOverflow
    // / JS_ThrowOutOfMemory). Ambiguity resolves TOWARDS the limit: a
    // plugin that fakes the text only gets its own generation unloaded,
    // whereas mistaking a real bound for an ordinary throw would keep a
    // degraded engine serving.
    isLimit := FEngine.TimeoutAborted or
               (text = 'InternalError: interrupted') or
               (text = 'InternalError: stack overflow') or
               (text = 'InternalError: out of memory');
    if isLimit then
      FExportCode := peccResourceLimit
    else
      FExportCode := peccThrew;
  end
  else
  begin
    FExportCode := peccOk;
    // Promise / thenable: this pin has NO JS_PromiseState, and
    // JSON.stringify(promise) is '{}' (measured), so the structural
    // thenable probe is the only detection that works.
    if res.IsObject then
    begin
      thenv := JSValue(JS_GetPropertyStr(FEngine.cx, JSValueRaw(res), 'then'));
      if thenv.IsException then
      begin
        FExportDetail := TakeExceptionText;
        FExportCode := peccBadResult;
      end
      else
      begin
        if JS_IsFunction(FEngine.cx, JSValueRaw(thenv)) then
        begin
          FExportCode := peccAsyncResult;
          FExportDetail := 'thenable result';
        end;
        FEngine.cx^.Free(thenv);
      end;
    end;
    if FExportCode = peccOk then
    begin
      js := JSValue(JS_JSONStringify(FEngine.cx, JSValueRaw(res),
        JS_UNDEFINED, JS_UNDEFINED));
      if js.IsException then
      begin
        // circular, or a throwing toJSON - measured as a real TypeError
        FExportDetail := TakeExceptionText;
        FExportCode := peccBadResult;
      end
      else
      begin
        // JSON.stringify(undefined) returns JS undefined, NOT an
        // exception (measured); the frozen TPWebJson contract spells
        // null 'null' and never the empty string
        if js.IsUndefined then
          FExportJson := PWEB_JSON_NULL
        else
          FExportJson := FEngine.cx^.ToUtf8(js);
        FEngine.cx^.Free(js);
        if Length(FExportJson) > PWEB_EXPORT_RESULT_MAX_BYTES then
        begin
          FExportJson := '';
          FExportDetail := 'result too large';
          FExportCode := peccBadResult;
        end;
      end;
    end;
    FEngine.cx^.Free(res);
  end;
  // AFTER every call, including one that threw: nothing in PWeb drains
  // the QuickJS job queue, so a queued microtask would never run and the
  // call only LOOKS complete. Fail closed and let the host unload.
  if JS_IsJobPending(FEngine.rt) then
  begin
    FExportJson := '';
    FExportCode := peccPendingJobs;
    if FExportDetail = '' then
      FExportDetail := 'queued job after a synchronous call';
  end;
  if PWebExportCallTaints(FExportCode) then
    InterlockedExchange(FTainted, 1);
end;

procedure TPWebQuickJSPlugin.LoadPackageOnOwnThread;
var
  asset: TAssetResponse;
  detail, src: RawUtf8;
  code: TPWebPackageLoadCode;
  v, r: JSValue;

  procedure Fail(ACode: TPWebPackageLoadCode; const ADetail: RawUtf8);
  begin
    RecordPackageFailure(ACode, ADetail);
    InterlockedExchange(FLoadState, Ord(qlsFailed));
    FInitError := 'package ' + PWEB_PACKAGE_LOAD_TEXT[FPackageCode];
    if FPackageDetail <> '' then
      FInitError := FInitError + ' (' + FPackageDetail + ')';
  end;

  { The ONE armed CPU window spans manifest -> entry -> whole graph,
    which is the property that makes the bound meaningful (re-arming per
    module would hand a 256-module graph 256x the budget). But it means
    a slow-I/O abort arrives as a compile or evaluate exception, and
    reporting THAT as plcCompile misdiagnoses a timeout as a syntax
    error. Fix the diagnosis, never the bound. }
  function TimeoutOr(ACode: TPWebPackageLoadCode): TPWebPackageLoadCode;
  begin
    if (FEngine <> nil) and FEngine.TimeoutAborted then
      Result := plcTimeout
    else
      Result := ACode;
  end;

  procedure CaptureEngineError;
  var
    raw: RawUtf8;
  begin
    FEngine.cx^.ErrorMessage({stacktrace=}True, raw);
    // through the SAME sanitizer as PackageDetail: a blind
    // SetLength(..., MAX) can cut a multi-byte sequence in half and hand
    // a host invalid UTF-8 to log, and the property's own contract
    // promises bounded, path-free text. Printable ASCII satisfies both
    // unconditionally - QuickJS's diagnostics are ASCII in practice, and
    // anything else in them is not something to forward verbatim.
    FPackageError := SafeText(raw, PWEB_PACKAGE_ERROR_MAX);
  end;

begin
  // 1. the manifest, from the package root of the plugin's own store
  if not FPackage.PackageStore.TryRead(PWEB_PACKAGE_MANIFEST, asset) then
  begin
    Fail(plcManifestMissing, PWEB_PACKAGE_MANIFEST);
    exit;
  end;
  // bound the raw bytes at the earliest observable point, before the
  // scanner copies or walks them (see the limits record's honest-scope
  // note about the frozen IAssetStore having no size form)
  if PtrUInt(Length(asset.Content)) > FPackageLimits.ManifestMaxBytes then
  begin
    Fail(plcManifestTooLarge, PWEB_PACKAGE_MANIFEST);
    exit;
  end;
  // 2. strict parse
  if not PWebParsePluginManifest(asset.Content, FPackageLimits,
      FManifest, code, detail) then
  begin
    Fail(code, detail);
    exit;
  end;
  // 3. the manifest must AGREE with native registration - agreement is a
  // consistency check, never a transfer of authority
  if FManifest.Id <> FPackage.ExpectedPackageId then
  begin
    Fail(plcManifestId, FManifest.Id);
    exit;
  end;
  if FManifest.Entry <> FPackage.ExpectedEntryPoint then
  begin
    Fail(plcEntryMismatch, FManifest.Entry);
    exit;
  end;
  // 4. the entry module itself
  if not FGraph.AddEntry(FManifest.Entry, code) then
  begin
    Fail(code, FManifest.Entry);
    exit;
  end;
  if not FPackage.PackageStore.TryRead(FManifest.Entry, asset) then
  begin
    Fail(plcEntryMissing, FManifest.Entry);
    exit;
  end;
  if not PWebPrepareModuleSource(asset.Content, src, code) then
  begin
    Fail(code, FManifest.Entry);
    exit;
  end;
  if not FGraph.Charge(FManifest.Entry, Length(src), code) then
  begin
    Fail(code, FManifest.Entry);
    exit;
  end;
  // 5. install the private loader on THIS runtime, for this plugin only
  // the casts are the ObjFPC spelling of "these ARE the pinned callback
  // types": JSModuleDef is an untyped pointer alias, so FPC will not
  // silently accept the raw address in mode ObjFPC the way mode Delphi
  // does. The signatures above match mormot.lib.quickjs:733-740 exactly.
  JS_SetModuleLoaderFunc(FEngine.rt,
    PJSModuleNormalizeFunc(@PWebQuickJSNormalize),
    PJSModuleLoaderFunc(@PWebQuickJSLoad), self);
  // 5b. CAP-9B2: the native export table, created BEFORE any package
  // code runs so modules can register callables on it during load. An
  // EMPTY export set is legal - a package need not export anything, and
  // the whole CAP-9B1 corpus loads without touching it. Nothing about
  // the module graph, the store or the resolver is involved, so the
  // frozen CAP-9B1 package corpus is unaffected by construction.
  InstallExportTable;
  if not FHasExportTable then
  begin
    Fail(plcEngine, 'export table');
    exit;
  end;
  // 6. arm the CPU bound. TQuickJSEngine.Evaluate is the only public API
  // that sets the interrupt's start tick (fTimeoutStartTickSec is
  // protected and starts at 0), so without this one trivial global eval
  // the very first module opcode aborts with 'interrupted' - measured.
  // One armed window then covers the entry AND its whole graph.
  FEngine.Evaluate('0', 'pweb-arm.js');
  // 7. compile the entry as a module, then evaluate it: the loader
  // callbacks run inside step 8, on this thread, inside this window
  if Length(src) = 0 then
    v := JSValue(JS_Eval(FEngine.cx, @PWEB_EMPTY_SOURCE, 0,
      pointer(FManifest.Entry),
      JS_EVAL_TYPE_MODULE or JS_EVAL_FLAG_COMPILE_ONLY))
  else
    v := JSValue(JS_Eval(FEngine.cx, pointer(src), Length(src),
      pointer(FManifest.Entry),
      JS_EVAL_TYPE_MODULE or JS_EVAL_FLAG_COMPILE_ONLY));
  if v.IsException then
  begin
    CaptureEngineError;
    Fail(TimeoutOr(plcCompile), FManifest.Entry);
    exit;
  end;
  // 8. evaluate: resolves and evaluates the whole static graph
  r := JSValue(JS_EvalFunction(FEngine.cx, JSValueRaw(v)));
  if r.IsException then
  begin
    CaptureEngineError;
    // the loader may already have recorded a precise reason; Fail keeps
    // the first one and only falls back to the generic code
    Fail(TimeoutOr(plcEvaluate), FManifest.Entry);
    exit;
  end;
  FEngine.cx^.Free(r);
  // 9. nothing in PWeb drains the QuickJS job queue, so top-level code
  // that queued work - a bare Promise.reject(), a .then(), a dynamic
  // import() - has queued something that will NEVER run. Accepting such
  // a package would report Running for a plugin whose asynchronous half
  // is silently dead. Adding a pump is out of scope (it would also
  // enable dynamic import), so refuse LOUDLY instead: deterministic,
  // fail-closed, and a startup error rather than a silent trap.
  if JS_IsJobPending(FEngine.rt) then
  begin
    Fail(plcPendingJobs, FManifest.Entry);
    exit;
  end;
  // 10. CAP-9B2 load commit point: force the export table's prototype
  // back to null, freeze its shape, snapshot the names natively and
  // take it off the global object. From here the export set is a fixed
  // native fact; nothing a later call adds can become an export.
  if not SealExportTable(code, detail) then
  begin
    Fail(code, detail);
    exit;
  end;
  // 11. accepted: the graph is sealed and pweb.invoke opens
  InterlockedExchange(FLoadState, Ord(qlsRunning));
end;

procedure TPWebQuickJSPlugin.Execute;
var
  v: variant;
begin
  try
    try
      FEngine := TQuickJSEngine(GManager.NewEngine); // created on THIS thread
      ApplyLimits;
      if not FEngine.RegisterMethod(FEngine.GlobalObj, '__pweb_invoke_json',
          @InvokeJson, 2) then
        raise EPWebQuickJSPlugin.Create('unable to register __pweb_invoke_json');
      FEngine.Evaluate(PWEB_QUICKJS_BOOTSTRAP, 'pweb-bootstrap.js');
      // CAP-9B1: the package is loaded HERE - on the owning thread,
      // after the CAP-9A sandbox/shim bootstrap and before the plugin
      // is ever reported ready. With no descriptor this is skipped and
      // the CAP-9A shape is byte-for-byte what it was.
      if FHasPackage then
        LoadPackageOnOwnThread;
    except
      on E: Exception do
      begin
        FInitError := RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message);
        if FHasPackage then
        begin
          RecordPackageFailure(plcEngine, RawUtf8(E.ClassName));
          InterlockedExchange(FLoadState, Ord(qlsFailed));
        end;
      end;
    end;
    RTLEventSetEvent(FReady);
    if FInitError <> '' then
      exit;
    while InterlockedCompareExchange(FStop, 0, 0) = 0 do
    begin
      RTLEventWaitFor(FWork, 200);
      if InterlockedCompareExchange(FStop, 0, 0) <> 0 then
        break;
      if InterlockedCompareExchange(FPending, 0, 1) <> 1 then
        continue; // spurious wake or no fresh job
      if InterlockedCompareExchange(FJobKind, 0, 0) = PWEB_JOB_EXPORT then
      begin
        // CAP-9B2: a host export call, executed HERE and only here
        try
          CallExportOnOwnThread;
        except
          on E: Exception do
          begin
            FExportCode := peccInternal;
            FExportJson := '';
            FExportDetail := SafeDetail(RawUtf8(E.Message));
            InterlockedExchange(FTainted, 1);
          end;
        end;
        InterlockedExchange(FDoneFlag, 1);
        RTLEventSetEvent(FDone);
        continue;
      end;
      FResultJson := '';
      FErrorMsg := '';
      FTimeoutAborted := False;
      try
        // per-Evaluate CPU bound: a request without its own bound keeps
        // the plugin's configured limit - 0 must never silently disable
        // the interrupt (only FLimits.TimeoutSeconds = 0 does, globally)
        if FScriptTimeoutSec = 0 then
          FEngine.TimeoutValue := FLimits.TimeoutSeconds
        else
          FEngine.TimeoutValue := FScriptTimeoutSec;
        v := FEngine.Evaluate(FScript, 'cap9a-script.js');
        if VarIsStr(v) then
          FResultJson := RawUtf8(VariantToUtf8(v))
        else if VarIsEmpty(v) or VarIsNull(v) then
          FResultJson := ''
        else
          FResultJson := VariantSaveJson(v);
      except
        on E: Exception do
        begin
          FErrorMsg := RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message);
          FTimeoutAborted := (FEngine <> nil) and FEngine.TimeoutAborted;
        end;
      end;
      InterlockedExchange(FDoneFlag, 1); // result fields are final now
      RTLEventSetEvent(FDone);
    end;
  finally
    // the frozen ownership rule: the engine dies on its owning thread
    try
      // CAP-9B2: the captured export table FIRST. A JSValue still alive
      // when JS_FreeRuntime runs trips the pinned
      // assert(list_empty(&rt->gc_obj_list)) and kills the process with
      // no catchable Pascal exception - measured, so this ordering is
      // not a tidiness preference.
      if FHasExportTable and (FEngine <> nil) then
      begin
        FEngine.cx^.Free(FExportTable);
        FHasExportTable := False;
      end;
      FreeAndNil(FEngine);
      if GetCurrentThreadId() = ThreadID then // explicit call: see InvokeJson note
        InterlockedExchange(FEngineDestroyedOnOwnThread, 1);
    except
      // never leak an exception out of the thread epilogue
    end;
    RTLEventSetEvent(FReady); // unblock WaitReady on early failure paths
    RTLEventSetEvent(FDone);  // unblock a waiter racing Unload
    // CAP-9B2: LAST, and after everything this thread will ever touch.
    // Unload's bounded join waits on exactly this, and treats its
    // absence as "the thread may still be running" - which is what makes
    // quarantine safe instead of a use-after-free.
    InterlockedExchange(FExitedFlag, 1);
    RTLEventSetEvent(FExited);
  end;
end;

function TPWebQuickJSPlugin.WaitReady(ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FReady, ATimeoutMs);
  Result := (FInitError = '') and (not Finished);
end;

function TPWebQuickJSPlugin.PostScript(const AScript: RawUtf8;
  ATimeoutSec: Cardinal): Boolean;
begin
  if (InterlockedCompareExchange(FStop, 0, 0) <> 0) or Finished then
    exit(False);
  if InterlockedCompareExchange(FBusy, 1, 0) <> 0 then
    exit(False); // one job at a time - the mailbox has a single slot
  FScript := AScript;
  FScriptTimeoutSec := ATimeoutSec;
  InterlockedExchange(FJobKind, PWEB_JOB_SCRIPT);
  InterlockedExchange(FDoneFlag, 0);
  RTLEventResetEvent(FDone);
  InterlockedExchange(FPending, 1);
  RTLEventSetEvent(FWork);
  Result := True;
end;

function TPWebQuickJSPlugin.CallExport(const AName: RawUtf8;
  const AArgsJson: TPWebJson; out AResultJson: TPWebJson;
  out ADetail: RawUtf8; AWaitMs: Integer): TPWebExportCallCode;
begin
  AResultJson := '';
  ADetail := '';
  // Every gate below is an explicit STATE test - never "the thread is
  // alive" or "a pointer is non-nil" (the lifecycle invariant).
  if (InterlockedCompareExchange(FStop, 0, 0) <> 0) or
     Finished or
     (InterlockedCompareExchange(FLoadState, 0, 0) <> Ord(qlsRunning)) then
    exit(peccUnavailable);
  if InterlockedCompareExchange(FTainted, 0, 0) <> 0 then
    exit(peccUnavailable);
  // grammar first, so a hostile name never even claims the mailbox slot
  if not PWebExportNameValid(AName) then
    exit(peccBadName);
  if InterlockedCompareExchange(FBusy, 1, 0) <> 0 then
    // deterministic, synchronous, NON-BLOCKING - the same shape as the
    // frozen TryEnqueue/perBusy rule, and the reason a lifecycle lock
    // never has to wait on a QuickJS call
    exit(peccBusy);
  try
    FExportName := AName;
    UniqueString(FExportName);
    if AArgsJson = '' then
      FExportArg := PWEB_JSON_NULL // '' is not a valid TPWebJson value
    else
      FExportArg := AArgsJson;
    UniqueString(FExportArg);
    FExportCode := peccInternal;
    FExportJson := '';
    FExportDetail := '';
    InterlockedExchange(FJobKind, PWEB_JOB_EXPORT);
    InterlockedExchange(FDoneFlag, 0);
    RTLEventResetEvent(FDone);
    InterlockedExchange(FPending, 1);
    RTLEventSetEvent(FWork);
    if AWaitMs <= 0 then
      AWaitMs := PWEB_QUICKJS_EXPORT_WAIT_MS;
    RTLEventWaitFor(FDone, AWaitMs);
    if InterlockedCompareExchange(FDoneFlag, 0, 1) <> 1 then
    begin
      // The call is STILL RUNNING: the slot is deliberately NOT released
      // (the plugin thread still owns the request fields), the
      // generation is tainted, and the host unloads it - the bounded
      // shutdown path, not a retry.
      InterlockedExchange(FTainted, 1);
      ADetail := 'export call did not complete within the bound';
      exit(peccResourceLimit);
    end;
    Result := FExportCode;
    AResultJson := FExportJson;
    ADetail := FExportDetail;
    InterlockedExchange(FBusy, 0); // release the slot last
  except
    on E: Exception do
    begin
      InterlockedExchange(FTainted, 1);
      ADetail := SafeDetail(RawUtf8(E.Message));
      Result := peccInternal;
    end;
  end;
end;

function TPWebQuickJSPlugin.WaitScript(out AJson, AError: RawUtf8;
  ATimeoutMs: Integer): Boolean;
begin
  AJson := '';
  AError := '';
  if InterlockedCompareExchange(FBusy, 0, 0) = 0 then
    exit(False); // nothing posted
  RTLEventWaitFor(FDone, ATimeoutMs);
  if InterlockedCompareExchange(FDoneFlag, 0, 1) <> 1 then
    exit(False); // still running (timeout) - the slot is NOT released
  AJson := FResultJson;
  AError := FErrorMsg;
  InterlockedExchange(FBusy, 0); // release the mailbox slot last
  Result := True;
end;

function TPWebQuickJSPlugin.Eval(const AScript: RawUtf8;
  out AJson, AError: RawUtf8; ATimeoutSec: Cardinal;
  AWaitMs: Integer): Boolean;
begin
  Result := PostScript(AScript, ATimeoutSec) and
    WaitScript(AJson, AError, AWaitMs);
end;

function TPWebQuickJSPlugin.Unload(AJoinMs: Integer): TPWebUnloadOutcome;
begin
  if FUnloaded then
    exit(FUnloadOutcome); // idempotent, and repeats the same verdict
  FUnloaded := True;
  FUnloadOutcome := puoClean;
  if FWork = nil then
    exit(puoClean); // the constructor raised before the events/thread
                    // existed: nothing started, nothing to quiesce/join
  // frozen source lifecycle first: refuse new invocations, cancel
  // queued ones, cooperatively cancel in-flight work (whose completion
  // - result or cancelled - releases any plugin-thread wait, including
  // one inside an export call blocked in pweb.invoke), then close. Both
  // are non-blocking and idempotent.
  try
    FSource.Quiesce;
    FSource.Close;
  except
    // a closed/shutdown source must never abort teardown
  end;
  InterlockedExchange(FStop, 1);
  RTLEventSetEvent(FWork);
  if AJoinMs <= 0 then
    AJoinMs := PWEB_QUICKJS_UNLOAD_JOIN_MS;
  // BOUNDED join. FExited is set as the very last act of the thread
  // body, after the engine has been destroyed on this thread, so
  // observing it means WaitFor cannot block for meaningful time.
  RTLEventWaitFor(FExited, AJoinMs);
  if InterlockedCompareExchange(FExitedFlag, 0, 0) = 0 then
  begin
    // The thread is still somewhere we cannot bound - a runaway native
    // frame, a wedged call. NOTHING is freed here: not the engine (the
    // thread owns it), not the events, not the source reference, not
    // the graph, not this instance. The caller must leak it by choice.
    // Forcible termination is never an option: killing a thread inside
    // QuickJS leaves the runtime's allocator and object list corrupt.
    FUnloadOutcome := puoQuarantined;
    exit(puoQuarantined);
  end;
  WaitFor; // returns promptly; the engine died in Execute's epilogue
  Result := puoClean;
end;

function TPWebQuickJSPlugin.CallbackCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FCallbackCalls, 0, 0);
end;

function TPWebQuickJSPlugin.CallbackWrongThreadCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FCallbackWrongThread, 0, 0);
end;

function TPWebQuickJSPlugin.EngineDestroyedOnOwnThread: Boolean;
begin
  Result := InterlockedCompareExchange(FEngineDestroyedOnOwnThread, 0, 0) <> 0;
end;

function TPWebQuickJSPlugin.LastSinkDeliveries: LongInt;
begin
  if FLastSink = nil then
    Result := 0
  else
    Result := TPluginCompletion(FLastSink).CompleteCalls;
end;

function TPWebQuickJSPlugin.LoadState: TPWebQuickJSLoadState;
begin
  Result := TPWebQuickJSLoadState(
    InterlockedCompareExchange(FLoadState, 0, 0));
end;

function TPWebQuickJSPlugin.NormalizeCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FNormalizeCalls, 0, 0);
end;

function TPWebQuickJSPlugin.LoaderCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FLoaderCalls, 0, 0);
end;

function TPWebQuickJSPlugin.LoaderWrongThreadCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FLoaderWrongThread, 0, 0);
end;

function TPWebQuickJSPlugin.LoadTimeInvokes: LongInt;
begin
  Result := InterlockedCompareExchange(FLoadTimeInvokes, 0, 0);
end;

function TPWebQuickJSPlugin.ExportCount: Integer;
begin
  Result := Length(FExportNames);
end;

function TPWebQuickJSPlugin.ExportName(AIndex: Integer): RawUtf8;
begin
  if (AIndex < 0) or (AIndex >= Length(FExportNames)) then
    Result := ''
  else
    Result := FExportNames[AIndex];
end;

function TPWebQuickJSPlugin.Tainted: Boolean;
begin
  Result := InterlockedCompareExchange(FTainted, 0, 0) <> 0;
end;

function TPWebQuickJSPlugin.ExportWrongThreadCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FExportWrongThread, 0, 0);
end;

function TPWebQuickJSPlugin.HasExited: Boolean;
begin
  Result := InterlockedCompareExchange(FExitedFlag, 0, 0) <> 0;
end;

{ ---------------- atomic package load ---------------- }

function PWebValidateQuickJSPackageDescriptor(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8): Boolean;
begin
  ACode := plcDescriptor;
  Result := False;
  if ADescriptor.PackageStore = nil then
    ADetail := 'no package store'
  else if ADescriptor.PrincipalId = '' then
    ADetail := 'no native PrincipalId'
  else if ADescriptor.PluginId = '' then
    ADetail := 'no native PluginId'
  else if not PWebPackageIdValid(ADescriptor.ExpectedPackageId) then
    ADetail := 'invalid ExpectedPackageId'
  else if not PWebPackageEntryValid(ADescriptor.ExpectedEntryPoint) then
    ADetail := 'non-canonical ExpectedEntryPoint'
  else if ADescriptor.Engine.TimeoutSeconds = 0 then
    // A package load evaluates ARBITRARY plugin top-level code before
    // the plugin is ever reported ready, so CAP-9A's allowance that
    // TimeoutSeconds = 0 disables the interrupt cannot carry over: with
    // it off, a `while (true) {}` entry module is never interrupted,
    // WaitReady times out, and the atomic-failure path's join then
    // blocks forever - one bad package would wedge host startup with no
    // recovery. Package plugins are deliberately stricter than the
    // CAP-9A post-script path, which only ever runs code the host chose
    // to post AFTER readiness.
    ADetail := 'TimeoutSeconds must be nonzero for a package load'
  else
  begin
    ACode := plcNone;
    ADetail := '';
    Result := True;
  end;
end;

function PWebLoadQuickJSPackage(
  const ADescriptor: TPWebQuickJSPackageDescriptor;
  const ASource: IInvocationSource;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent;
  AReadyWaitMs: Integer;
  out APlugin: TPWebQuickJSPlugin;
  out ACode: TPWebPackageLoadCode;
  out ADetail: RawUtf8): Boolean;
var
  plugin: TPWebQuickJSPlugin;
  ready: Boolean;
begin
  APlugin := nil;
  ACode := plcNone;
  ADetail := '';
  Result := False;
  if AReadyWaitMs <= 0 then
    AReadyWaitMs := 15000;
  // validate BEFORE constructing: a doomed object is never built, so the
  // constructor-raise path (and everything a partially built TThread
  // implies) is simply not on this route
  if not PWebValidateQuickJSPackageDescriptor(ADescriptor, ACode, ADetail) then
  begin
    // no thread, no engine - but still close the source, so a rejected
    // descriptor leaves nothing queueable behind
    if ASource <> nil then
      try
        ASource.Quiesce;
        ASource.Close;
      except
        // a closed/shutdown source must never abort teardown
      end;
    exit;
  end;
  try
    plugin := TPWebQuickJSPlugin.CreatePackage(
      ASource, ADescriptor, AOnSnapshot);
  except
    on E: Exception do
    begin
      // defence in depth: the validator above already covers every
      // descriptor rejection, so reaching here means the thread or the
      // graph could not be created at all
      ACode := plcEngine;
      ADetail := SafeDetail(RawUtf8(E.Message));
      if ASource <> nil then
        try
          ASource.Quiesce;
          ASource.Close;
        except
        end;
      exit;
    end;
  end;
  ready := plugin.WaitReady(AReadyWaitMs);
  if ready and (plugin.LoadState = qlsRunning) then
  begin
    APlugin := plugin;
    exit(True);
  end;
  // ATOMIC FAILURE: Quiesce -> Close -> JOIN first, and only then read
  // the plugin's fields. On the ready-TIMEOUT path the plugin thread may
  // still be inside LoadPackageOnOwnThread assigning the refcounted
  // FPackageDetail/FPackageError, so reading them before the join is an
  // unsynchronised read of a managed string. Every non-timeout read is
  // ordered by the FReady event; joining first makes all of them so.
  // The join is bounded because CreatePackage refuses a descriptor with
  // TimeoutSeconds = 0, so the interrupt always ends the evaluation.
  if plugin.Unload = puoQuarantined then
  begin
    // the load itself wedged the owning thread. Nothing on the plugin
    // may be read (the thread may still be writing its refcounted error
    // strings) and nothing may be freed, so the verdict comes from
    // constants alone and the instance is leaked by choice.
    PWebQuarantineQuickJSPlugin(plugin);
    ACode := plcTimeout;
    ADetail := 'plugin thread quarantined during load';
    exit;
  end;
  ACode := plugin.PackageCode;
  if plugin.LoaderWrongThreadCalls > 0 then
    // the thread-affinity gate must not be reachable only through a
    // SUCCESSFUL load: if a callback ran off the owning thread, that is
    // the finding, whatever else also went wrong
    ACode := plcThread
  else if ACode = plcNone then
    if ready then
      ACode := plcEngine  // the engine never came up
    else
      ACode := plcTimeout; // WaitReady itself timed out
  ADetail := plugin.PackageDetail;
  if ADetail = '' then
    ADetail := SafeDetail(plugin.PackageError);
  // the engine was destroyed on its owning thread in Execute's epilogue;
  // nothing stays Running, no invocation stays pending, APlugin is nil
  plugin.Free;
end;

initialization
  GManager := TThreadSafeManager.Create(TQuickJSEngine, nil, 256);
  InitCriticalSection(GQuarantineLock);
  GQuarantine := TList.Create;

finalization
  FreeAndNil(GManager);
  // GQuarantine's ENTRIES are deliberately not freed - each one may
  // still own a running thread. The list itself goes; the plugins stay
  // leaked, which is the whole contract.
  FreeAndNil(GQuarantine);
  DoneCriticalSection(GQuarantineLock);

end.
