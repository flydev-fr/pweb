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
  pweb.rpc.intf,
  pweb.rpc.support;

type
  EPWebQuickJSPlugin = class(Exception);

  { Per-engine resource bounds, applied on the plugin thread right after
    engine creation. Zero disables the corresponding limit. }
  TPWebQuickJSLimits = record
    TimeoutSeconds: Cardinal;   // default CPU bound per Evaluate (interrupt)
    MemoryLimitBytes: PtrUInt;  // JS_SetMemoryLimit on the runtime
    StackLimitBytes: PtrUInt;   // runtime-typed JS_SetMaxStackSize
    InvokeWaitMs: Integer;      // defensive cap of the bounded native wait
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
    function InvokeJson(const This: variant;
      const Args: array of variant): variant;
    procedure ApplyLimits;
    function BuildContext: TInvocationContext;
  protected
    procedure Execute; override;
  public
    { AContext must be a native pkQuickJS identity: PrincipalId <> '',
      WindowId = ''. It is deep-copied (PWebCopyContext). }
    constructor Create(const ASource: IInvocationSource;
      const AContext: TInvocationContext; const ALimits: TPWebQuickJSLimits;
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

    { Frozen teardown order: Quiesce -> Close the source, then stop the
      mailbox loop and join - the engine is destroyed on its own thread
      in Execute's epilogue. Idempotent. }
    procedure Unload;

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
  end;

{ The ONE shared app-lifetime engine manager: mints caller-owned engines
  through NewEngine. Never use ThreadSafeEngine() here - the expiry pool
  is the wrong ownership shape for plugin threads (measured: pooled
  TThreadSafeManager.Destroy raises on unreleased engines). }
function PWebQuickJSManager: TThreadSafeManager;

const
  { Defaults chosen for plugin isolation; hosts override per plugin. }
  PWEB_QUICKJS_DEFAULT_LIMITS: TPWebQuickJSLimits = (
    TimeoutSeconds: 10;
    MemoryLimitBytes: 64 shl 20;   // 64 MB
    StackLimitBytes: 1 shl 20;     // 1 MB
    InvokeWaitMs: 15000
  );

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

function pas_malloc(size: cardinal): pointer; cdecl;
  public name '_pas_malloc';
begin
  GetMem(result, size);
end;

function pas_calloc(n, size: PtrInt): pointer; cdecl;
  public name '_pas_calloc';
begin
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
    FDone: LongInt;
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
  if InterlockedExchange(FDone, 1) <> 0 then
    exit; // idempotent - the frozen gate upstream makes this unreachable
  FResult := AResult;
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

constructor TPWebQuickJSPlugin.Create(const ASource: IInvocationSource;
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
  FWork := RTLEventCreate;
  FDone := RTLEventCreate;
  FReady := RTLEventCreate;
  inherited Create({suspended=}False);
end;

destructor TPWebQuickJSPlugin.Destroy;
begin
  Unload; // idempotent; joins the thread so the events are unobserved
  inherited Destroy; // TThread.Destroy joins again (no-op when finished)
  if FWork <> nil then
    RTLEventDestroy(FWork);
  if FDone <> nil then
    RTLEventDestroy(FDone);
  if FReady <> nil then
    RTLEventDestroy(FReady);
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
  if GetCurrentThreadId <> ThreadID then
    InterlockedIncrement(FCallbackWrongThread);
  if (Length(Args) <> 2) or
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
    except
      on E: Exception do
        FInitError := RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message);
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
        continue; // spurious wake or no fresh script
      FResultJson := '';
      FErrorMsg := '';
      FTimeoutAborted := False;
      try
        FEngine.TimeoutValue := FScriptTimeoutSec; // per-Evaluate bound
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
      FreeAndNil(FEngine);
      if GetCurrentThreadId = ThreadID then
        InterlockedExchange(FEngineDestroyedOnOwnThread, 1);
    except
      // never leak an exception out of the thread epilogue
    end;
    RTLEventSetEvent(FReady); // unblock WaitReady on early failure paths
    RTLEventSetEvent(FDone);  // unblock a waiter racing Unload
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
    exit(False); // one script at a time - the mailbox has a single slot
  FScript := AScript;
  FScriptTimeoutSec := ATimeoutSec;
  RTLEventResetEvent(FDone);
  InterlockedExchange(FPending, 1);
  RTLEventSetEvent(FWork);
  Result := True;
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

procedure TPWebQuickJSPlugin.Unload;
begin
  if FUnloaded then
    exit;
  FUnloaded := True;
  // frozen source lifecycle first: refuse new invocations, cancel
  // queued ones, cooperatively cancel in-flight work (whose completion
  // - result or cancelled - releases any plugin-thread wait), then
  // close. Both are non-blocking and idempotent.
  try
    FSource.Quiesce;
    FSource.Close;
  except
    // a closed/shutdown source must never abort teardown
  end;
  InterlockedExchange(FStop, 1);
  RTLEventSetEvent(FWork);
  WaitFor; // joins; the engine was destroyed in Execute's epilogue
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

initialization
  GManager := TThreadSafeManager.Create(TQuickJSEngine, nil, 256);

finalization
  FreeAndNil(GManager);

end.
