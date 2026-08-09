{
  pweb.test.rpc - mormot.core.test cases for the CAP-2 invocation
  pipeline: scheduler, policy call site, dummy bridge, WebView binding.

  Everything here is HEADLESS: the scheduler cases never touch any
  pweb.webview.* unit (proving source-genericity at runtime, on top of
  the CI webview-free compile of pweb.rpc.scheduler.pas), and the
  binding cases drive real enqueue/complete/close/destroy races against
  injectable recording fake native functions - no window, and no real
  native entry point is ever CALLED by these cases. Note the loader
  still requires webview.dll BESIDE the test executable: this unit
  statically imports pweb.lib.webview (the binding's production
  defaults), so the DLL must be staged even though it stays idle - CI
  copies it next to pwebtests.exe.

  The twenty mandated CAP-2 tests map onto the published methods below;
  each method's header comment carries its number(s). }

{$I mormot.defines.inc}

unit pweb.test.rpc;

interface

uses
  {$ifdef OSWINDOWS}
  windows, // VirtualAlloc/VirtualProtect for the guard-page scan test
  {$endif OSWINDOWS}
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.bridge.dummy,
  pweb.capabilities,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.lib.webview,
  pweb.lib.webview.errors; // EWebViewError for the bind-rollback case

type
  /// allow-all policy that records the canonical method and a deep copy
  // of the native context it received, for pipeline-integrity checks
  TRecordingAllowPolicy = class(TInterfacedObject, ICapabilityPolicy)
  private
    FLock: TCriticalSection;
    FMethods: array of Utf8String;
    FContexts: array of TInvocationContext; // deep copies
  public
    constructor Create;
    destructor Destroy; override;
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
    function SeenCount: Integer;
    function Seen(AIndex: Integer): Utf8String;
    function SeenContext(AIndex: Integer): TInvocationContext;
  end;

  /// scheduler + policy call site + dummy bridge, over a plain
  // non-WebView test source (mandated tests 2..16 and 20)
  TTestInvocationScheduler = class(TSynTestCase)
  private
    FBridge: TDummyInvocationBridge;
    FBridgeRef: IInvocationBridge;
    FPolicyRef: ICapabilityPolicy;
    FScheduler: TInvocationScheduler;
    FSchedulerRef: IInvocationScheduler;
    FSource: IInvocationSource;
    procedure NewPipeline(AMaxConcurrent, AMaxQueue: Integer;
      const APolicy: ICapabilityPolicy = nil);
    procedure EndPipeline;
    function Ctx: TInvocationContext;
    function WaitBridgeCurrent(AValue, ATimeoutMs: Integer): Boolean;
  published
    procedure ValidRequestEnqueues;
    procedure MethodCanonicalizationGate;
    procedure SameCanonicalMethodAtPolicyAndBridge;
    procedure AllowAllPolicyPermits;
    procedure DenyAndRaisingPolicy;
    procedure QueueLimitBusy;
    procedure ConcurrencyLimitRespected;
    procedure FreedSlotStartsQueuedWork;
    procedure ExactlyOnceCompletion;
    procedure DoubleCompletionCannotDoubleReleaseSlot;
    procedure BridgeExceptionInternalError;
    procedure CooperativeCancellation;
    procedure QuiesceRefusesNew;
    procedure QuiesceCancelsQueued;
    procedure CloseWhileRunningQuiescesFirst;
    procedure NonWebViewTestSource;
    procedure ContextSnapshotIndependence;
  end;

  /// TWebViewBinding over injectable fake native functions
  // (mandated tests 1, 17, 18, 19 + pre-queue rejection mapping)
  TTestWebViewBinding = class(TSynTestCase)
  private
    FBridge: TDummyInvocationBridge;
    FBridgeRef: IInvocationBridge;
    FRecPolicy: TRecordingAllowPolicy;
    FPolicyRef: ICapabilityPolicy;
    FScheduler: TInvocationScheduler;
    FSchedulerRef: IInvocationScheduler;
    FSource: IInvocationSource;
    FBinding: TWebViewBinding;
    FBindingRef: IWebViewBinding;
    procedure NewBindingPipeline(AMaxConcurrent, AMaxQueue,
      AMaxRequestBytes: Integer);
    procedure EndBindingPipeline;
    function WaitBridgeCurrent(AValue, ATimeoutMs: Integer): Boolean;
    function WaitReturnCount(const AId: RawUtf8;
      AValue, ATimeoutMs: Integer): Boolean;
  published
    procedure MalformedEnvelopeRejectedPreEnqueue;
    procedure PreQueueSyncRejectionMapping;
    procedure BindRefusals;
    procedure UnbindLifecycle;
    procedure RaisingHandlerBarrier;
    procedure ContextReachesPolicyAndBridge;
    procedure CallbackDoesNoSynchronousServiceExecution;
    procedure LateCompletionAfterClosedTouchesNothing;
    procedure LeasePreventsDestroyReturnRace;
    // corrective-review fault-injection cases (scenarios A-D + size)
    procedure UnbindFailureKeepsUserdataSafe;
    procedure CloseRetryAfterUnbindFailure;
    procedure DestroyQuarantinesUndetachedEntry;
    procedure BindRollbackOnNativeFailure;
    procedure RequestSizeLimitsAndCeiling;
    procedure BoundedScanGuardPage;
  end;

implementation

{ ---------------- shared helpers (no assertions in here) ---------------- }

type
  { NOTE: no FPC syncobjs event anywhere in this unit - TEventObject/
    TSimpleEvent.WaitFor returns wrError immediately on the pinned FPC
    3.2.2 Windows toolchain (measured); waits are short polled loops }
  TTestCompletion = class(TInterfacedObject, IInvocationCompletion)
  private
    FLock: TCriticalSection;
    FCount: Integer;
    FFirst: TPWebInvocationResult;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Complete(const AResult: TPWebInvocationResult);
    function WaitDone(ATimeoutMs: Integer): Boolean;
    function CompleteCount: Integer;
    function First: TPWebInvocationResult;
  end;

  TDenyAllPolicy = class(TInterfacedObject, ICapabilityPolicy)
  public
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
  end;

  TRaisingPolicy = class(TInterfacedObject, ICapabilityPolicy)
  public
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
  end;

  { deviant handlers for the C-callback exception-barrier tests }
  TRaisingHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  public
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

  TCompleteThenRaiseHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  public
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

  { deliberately deviant handler for the lease race test: captures the
    per-invocation sink and neither enqueues nor rejects }
  TCapturingHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  public
    Captured: IInvocationCompletion;
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

constructor TTestCompletion.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TTestCompletion.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TTestCompletion.Complete(const AResult: TPWebInvocationResult);
begin
  FLock.Enter;
  try
    Inc(FCount);
    if FCount = 1 then
      FFirst := AResult;
  finally
    FLock.Leave;
  end;
end;

function TTestCompletion.WaitDone(ATimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while (CompleteCount = 0) and (waited < ATimeoutMs) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  Result := CompleteCount > 0;
end;

function TTestCompletion.CompleteCount: Integer;
begin
  FLock.Enter;
  Result := FCount;
  FLock.Leave;
end;

function TTestCompletion.First: TPWebInvocationResult;
begin
  FLock.Enter;
  Result := FFirst;
  FLock.Leave;
end;

function TDenyAllPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
begin
  Result := False;
end;

function TRaisingPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
begin
  Result := False; // never reached: the raise below is the point
  raise Exception.Create('policy exception marker');
end;

constructor TRecordingAllowPolicy.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TRecordingAllowPolicy.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TRecordingAllowPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
var
  n: Integer;
begin
  FLock.Enter;
  try
    n := Length(FMethods);
    SetLength(FMethods, n + 1);
    FMethods[n] := Method;
    UniqueString(FMethods[n]);
    SetLength(FContexts, n + 1);
    FContexts[n] := PWebCopyContext(Context);
  finally
    FLock.Leave;
  end;
  Result := True;
end;

function TRecordingAllowPolicy.SeenCount: Integer;
begin
  FLock.Enter;
  Result := Length(FMethods);
  FLock.Leave;
end;

function TRecordingAllowPolicy.Seen(AIndex: Integer): Utf8String;
begin
  FLock.Enter;
  try
    if (AIndex >= 0) and (AIndex < Length(FMethods)) then
      Result := FMethods[AIndex]
    else
      Result := '';
  finally
    FLock.Leave;
  end;
end;

function TRecordingAllowPolicy.SeenContext(AIndex: Integer): TInvocationContext;
begin
  FLock.Enter;
  try
    if (AIndex >= 0) and (AIndex < Length(FContexts)) then
      Result := PWebCopyContext(FContexts[AIndex])
    else
      Result := Default(TInvocationContext);
  finally
    FLock.Leave;
  end;
end;

procedure TRaisingHandler.HandleInvocation(const Context: TInvocationContext;
  const Request: TPWebJson; const Completion: IInvocationCompletion);
begin
  raise Exception.Create('handler raise marker');
end;

procedure TCompleteThenRaiseHandler.HandleInvocation(
  const Context: TInvocationContext; const Request: TPWebJson;
  const Completion: IInvocationCompletion);
begin
  Completion.Complete(PWebSuccessResult('{"first":"delivery"}'));
  raise Exception.Create('handler raise-after-complete marker');
end;

procedure TCapturingHandler.HandleInvocation(const Context: TInvocationContext;
  const Request: TPWebJson; const Completion: IInvocationCompletion);
begin
  Captured := Completion;
end;

{ ---------------- fake native functions (recording) ---------------- }

type
  TFakeReturnRec = record
    Id: RawUtf8;
    Status: Integer;
    Payload: RawUtf8;
    Seq: Integer;
  end;

  TFakeBindingRec = record
    Name: RawUtf8;
    Fn: webview_bind_fn;
    Arg: Pointer;
  end;

var
  FakeLock: TCriticalSection;
  FakeReturns: array of TFakeReturnRec;
  FakeSeq: Integer;
  FakeBindings: array of TFakeBindingRec;
  FakeUnbinds: Integer;
  FakeReturnBlock: Boolean;
  FakeReturnGateOpen: LongInt;  // released by the test (polled flag)
  FakeReturnEntered: LongInt;   // set when a blocked return is inside
  { scriptable native results for the corrective fault-injection cases.
    Unbind failures are keyed by NAME (never by call order, so tests do
    not depend on registry iteration order) and are persistent until
    cleared; a scripted unbind result ALWAYS leaves the fake registry
    untouched - a failure means the native side still holds the
    callback userdata, and a non-failure code (e.g. NOT_FOUND) merely
    claims a state without performing any registry effect. To simulate
    a genuinely-absent native binding use RemoveFakeBinding, which
    detaches the fake registry record itself - a later unbind then
    reports NOT_FOUND naturally. Bind results are a FIFO queue: a
    scripted non-OK bind registers nothing and retains nothing. }
  FakeUnbindFailName: RawUtf8;              // '' = no scripted unbind result
  FakeUnbindFailCode: webview_error_t;
  FakeBindScript: array of webview_error_t;
  FakeBindScriptIdx: Integer;

procedure ResetFakes;
begin
  FakeLock.Enter;
  try
    SetLength(FakeReturns, 0);
    SetLength(FakeBindings, 0);
    FakeSeq := 0;
    FakeUnbinds := 0;
    FakeReturnBlock := False;
    FakeUnbindFailName := '';
    FakeUnbindFailCode := WEBVIEW_ERROR_OK;
    SetLength(FakeBindScript, 0);
    FakeBindScriptIdx := 0;
  finally
    FakeLock.Leave;
  end;
  InterlockedExchange(FakeReturnGateOpen, 0);
  InterlockedExchange(FakeReturnEntered, 0);
end;

procedure ScriptUnbindFailureFor(const AName: RawUtf8;
  ACode: webview_error_t);
begin
  FakeLock.Enter;
  try
    FakeUnbindFailName := AName;
    FakeUnbindFailCode := ACode;
  finally
    FakeLock.Leave;
  end;
end;

procedure ClearUnbindFailure;
begin
  ScriptUnbindFailureFor('', WEBVIEW_ERROR_OK);
end;

{ simulate a native side that genuinely no longer holds AName (e.g. it
  was dropped upstream): the fake registry record disappears WITHOUT
  any Pascal-side effect, so the next unbind reports NOT_FOUND }
procedure RemoveFakeBinding(const AName: RawUtf8);
var
  i, j: Integer;
begin
  FakeLock.Enter;
  try
    for i := 0 to High(FakeBindings) do
      if FakeBindings[i].Name = AName then
      begin
        for j := i to High(FakeBindings) - 1 do
          FakeBindings[j] := FakeBindings[j + 1];
        SetLength(FakeBindings, Length(FakeBindings) - 1);
        break;
      end;
  finally
    FakeLock.Leave;
  end;
end;

procedure ScriptBindResults(const ACodes: array of webview_error_t);
var
  i: Integer;
begin
  FakeLock.Enter;
  try
    SetLength(FakeBindScript, Length(ACodes));
    for i := 0 to High(ACodes) do
      FakeBindScript[i] := ACodes[i];
    FakeBindScriptIdx := 0;
  finally
    FakeLock.Leave;
  end;
end;

function FakeNativeBind(w: webview_t; const name: PAnsiChar;
  fn: webview_bind_fn; arg: Pointer): webview_error_t; cdecl;
var
  n, i: Integer;
  nm: RawUtf8;
begin
  FastSetString(nm, name, StrLen(name));
  FakeLock.Enter;
  try
    if FakeBindScriptIdx < Length(FakeBindScript) then
    begin
      Result := FakeBindScript[FakeBindScriptIdx];
      Inc(FakeBindScriptIdx);
      if Result <> WEBVIEW_ERROR_OK then
        exit; // scripted refusal: nothing registered, arg NOT retained
    end;
    for i := 0 to High(FakeBindings) do
      if FakeBindings[i].Name = nm then
        exit(WEBVIEW_ERROR_DUPLICATE);
    n := Length(FakeBindings);
    SetLength(FakeBindings, n + 1);
    FakeBindings[n].Name := nm;
    FakeBindings[n].Fn := fn;
    FakeBindings[n].Arg := arg;
    Result := WEBVIEW_ERROR_OK;
  finally
    FakeLock.Leave;
  end;
end;

function FakeNativeUnbind(w: webview_t;
  const name: PAnsiChar): webview_error_t; cdecl;
var
  i, j: Integer;
  nm: RawUtf8;
begin
  FastSetString(nm, name, StrLen(name));
  FakeLock.Enter;
  try
    Inc(FakeUnbinds);
    if (FakeUnbindFailName <> '') and (nm = FakeUnbindFailName) then
      // scripted result for THIS name: report the code and leave the
      // registry untouched - the native side keeps the callback (a
      // genuinely-absent binding is simulated via RemoveFakeBinding)
      exit(FakeUnbindFailCode);
    for i := 0 to High(FakeBindings) do
      if FakeBindings[i].Name = nm then
      begin
        for j := i to High(FakeBindings) - 1 do
          FakeBindings[j] := FakeBindings[j + 1];
        SetLength(FakeBindings, Length(FakeBindings) - 1);
        exit(WEBVIEW_ERROR_OK);
      end;
    Result := WEBVIEW_ERROR_NOT_FOUND;
  finally
    FakeLock.Leave;
  end;
end;

function FakeNativeReturn(w: webview_t; const id: PAnsiChar; status: Integer;
  const res: PAnsiChar): webview_error_t; cdecl;
var
  block: Boolean;
  n: Integer;
begin
  FakeLock.Enter;
  block := FakeReturnBlock;
  FakeLock.Leave;
  if block then
  begin
    // simulate a slow native operation while the lease is held
    InterlockedExchange(FakeReturnEntered, 1);
    n := 0;
    while (FakeReturnGateOpen = 0) and (n < 10000) do
    begin
      Sleep(5);
      Inc(n, 5);
    end;
  end;
  FakeLock.Enter;
  try
    n := Length(FakeReturns);
    SetLength(FakeReturns, n + 1);
    Inc(FakeSeq);
    FakeReturns[n].Seq := FakeSeq;
    FakeReturns[n].Status := status;
    FastSetString(FakeReturns[n].Id, id, StrLen(id));
    FastSetString(FakeReturns[n].Payload, res, StrLen(res));
  finally
    FakeLock.Leave;
  end;
  Result := WEBVIEW_ERROR_OK;
end;

function FakeReturnCount(const AId: RawUtf8): Integer;
var
  i: Integer;
begin
  Result := 0;
  FakeLock.Enter;
  try
    for i := 0 to High(FakeReturns) do
      if FakeReturns[i].Id = AId then
        Inc(Result);
  finally
    FakeLock.Leave;
  end;
end;

function FakeLastReturn(const AId: RawUtf8; out AStatus: Integer;
  out APayload: RawUtf8): Boolean;
var
  i: Integer;
begin
  Result := False;
  AStatus := 0;
  APayload := '';
  FakeLock.Enter;
  try
    for i := High(FakeReturns) downto 0 do
      if FakeReturns[i].Id = AId then
      begin
        AStatus := FakeReturns[i].Status;
        APayload := FakeReturns[i].Payload;
        exit(True);
      end;
  finally
    FakeLock.Leave;
  end;
end;

function FakeMaxSeq: Integer;
begin
  FakeLock.Enter;
  Result := FakeSeq;
  FakeLock.Leave;
end;

function FakeHasBinding(const AName: RawUtf8): Boolean;
var
  i: Integer;
begin
  Result := False;
  FakeLock.Enter;
  try
    for i := 0 to High(FakeBindings) do
      if FakeBindings[i].Name = AName then
        exit(True);
  finally
    FakeLock.Leave;
  end;
end;

procedure SetFakeReturnBlock(AValue: Boolean);
begin
  FakeLock.Enter;
  FakeReturnBlock := AValue;
  FakeLock.Leave;
end;

{ invoke a recorded bound callback with a RAW request pointer - the
  guard-page test needs full control over the request memory layout }
procedure FireBoundPtr(const AName, AId: RawUtf8; AReq: PAnsiChar);
var
  i: Integer;
  fn: webview_bind_fn;
  arg: Pointer;
begin
  fn := nil;
  arg := nil;
  FakeLock.Enter;
  try
    for i := 0 to High(FakeBindings) do
      if FakeBindings[i].Name = AName then
      begin
        fn := FakeBindings[i].Fn;
        arg := FakeBindings[i].Arg;
        break;
      end;
  finally
    FakeLock.Leave;
  end;
  if Assigned(fn) then
    fn(PAnsiChar(pointer(AId)), AReq, arg);
end;

{ invoke a recorded bound callback exactly as upstream JS would }
procedure FireBound(const AName, AId, AReq: RawUtf8);
begin
  FireBoundPtr(AName, AId, PAnsiChar(pointer(AReq)));
end;

{ crude "code" member extractor for envelope assertions }
function PayloadCode(const APayload: RawUtf8): RawUtf8;
var
  p, e: Integer;
begin
  Result := '';
  p := Pos(RawUtf8('"code":"'), APayload);
  if p = 0 then
    exit;
  Inc(p, 8);
  e := p;
  while (e <= Length(APayload)) and (APayload[e] <> '"') do
    Inc(e);
  Result := Copy(APayload, p, e - p);
end;

function TestContext: TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := 'w1';
  Result.PrincipalId := 'window:w1';
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
end;

{ ---------------- TTestInvocationScheduler ---------------- }

procedure TTestInvocationScheduler.NewPipeline(AMaxConcurrent,
  AMaxQueue: Integer; const APolicy: ICapabilityPolicy);
var
  lim: TPWebSourceLimits;
begin
  FBridge := TDummyInvocationBridge.Create;
  FBridgeRef := FBridge;
  if APolicy <> nil then
    FPolicyRef := APolicy
  else
    FPolicyRef := TAllowAllCapabilityPolicy.Create;
  FScheduler := TInvocationScheduler.Create(FPolicyRef, FBridgeRef, 4);
  FSchedulerRef := FScheduler;
  lim.MaxConcurrent := AMaxConcurrent;
  lim.MaxQueueSize := AMaxQueue;
  FSource := FScheduler.RegisterSource(lim);
end;

procedure TTestInvocationScheduler.EndPipeline;
begin
  if FBridge <> nil then
    FBridge.OpenGate; // never let Shutdown wait on a test gate
  if FScheduler <> nil then
    FScheduler.Shutdown;
  FSource := nil;
  FSchedulerRef := nil;
  FScheduler := nil;
  FPolicyRef := nil;
  FBridgeRef := nil;
  FBridge := nil;
end;

function TTestInvocationScheduler.Ctx: TInvocationContext;
begin
  Result := TestContext;
end;

function TTestInvocationScheduler.WaitBridgeCurrent(AValue,
  ATimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while (FBridge.CurrentConcurrent <> AValue) and (waited < ATimeoutMs) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  Result := FBridge.CurrentConcurrent = AValue;
end;

procedure TTestInvocationScheduler.ValidRequestEnqueues; // mandated test 2
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  r: TPWebInvocationResult;
begin
  NewPipeline(2, 8);
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{"a":1,"b":"x"}', sinkRef) = perAccepted,
    'valid Method + named Args object enqueues');
  Check(sink.WaitDone(5000), 'accepted invocation completes');
  r := sink.First;
  Check(r.Kind = prkSuccess, 'echo resolves the success arm');
  CheckEqual(r.Value, '{"a":1,"b":"x"}', 'echoed args verbatim');
  // null args are the PWEB_JSON_NULL literal, also valid
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', PWEB_JSON_NULL, sinkRef) = perAccepted,
    'null Args (as literal) enqueues');
  Check(sink.WaitDone(5000), 'null-args invocation completes');
  Check(sink.First.Kind = prkSuccess, 'null-args echo succeeds');
  CheckEqual(sink.First.Value, PWEB_JSON_NULL, 'JSON null is null, never empty');
  EndPipeline;
end;

procedure TTestInvocationScheduler.MethodCanonicalizationGate; // mandated test 3
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  longMethod: Utf8String;
begin
  NewPipeline(2, 8);
  // the exact grammar predicate (corrective Item 3): EXACTLY two
  // non-empty case-preserved segments - never more, never fewer
  Check(PWebValidMethod('A.B'), 'A.B is canonical');
  Check(PWebValidMethod('pweb.echo'), 'pweb.echo is canonical');
  Check(not PWebValidMethod('A.B.C'), 'A.B.C rejected: dots must equal 1');
  Check(not PWebValidMethod('a.b.c.d'), 'a.b.c.d rejected');
  Check(not PWebValidMethod('.A'), '.A rejected');
  Check(not PWebValidMethod('A.'), 'A. rejected');
  Check(not PWebValidMethod('A..B'), 'A..B rejected');
  Check(not PWebValidMethod('A/B'), 'A/B rejected');
  Check(not PWebValidMethod('A B'), 'A B rejected');
  Check(not PWebValidMethod(''), 'empty rejected');
  sink := TTestCompletion.Create;
  sinkRef := sink;
  // TryEnqueue is the single method grammar gate: every rejection is
  // synchronous perInvalidRequest and the sink is never touched
  Check(FSource.TryEnqueue(Ctx, '', '{}', sinkRef) = perInvalidRequest, 'empty method');
  Check(FSource.TryEnqueue(Ctx, 'nodots', '{}', sinkRef) = perInvalidRequest, 'no Service.Method shape');
  Check(FSource.TryEnqueue(Ctx, '.echo', '{}', sinkRef) = perInvalidRequest, 'leading dot');
  Check(FSource.TryEnqueue(Ctx, 'pweb.', '{}', sinkRef) = perInvalidRequest, 'trailing dot');
  Check(FSource.TryEnqueue(Ctx, 'a..b', '{}', sinkRef) = perInvalidRequest, 'empty segment');
  Check(FSource.TryEnqueue(Ctx, 'A.B.C', '{}', sinkRef) = perInvalidRequest,
    'three segments rejected at the gate: exactly Service.Method');
  Check(FSource.TryEnqueue(Ctx, 'a.b.c.d', '{}', sinkRef) = perInvalidRequest,
    'four segments rejected at the gate');
  Check(FSource.TryEnqueue(Ctx, '/root/UserService.Get', '{}', sinkRef) = perInvalidRequest,
    'raw mORMot route form is rejected');
  Check(FSource.TryEnqueue(Ctx, 'user service.get', '{}', sinkRef) = perInvalidRequest, 'space');
  Check(FSource.TryEnqueue(Ctx, 'pweb.ec'#0'ho', '{}', sinkRef) = perInvalidRequest, 'embedded NUL');
  SetLength(longMethod, PWEB_METHOD_MAX_BYTES + 10);
  FillChar(pointer(longMethod)^, Length(longMethod), Ord('a'));
  longMethod[10] := '.';
  Check(FSource.TryEnqueue(Ctx, longMethod, '{}', sinkRef) = perInvalidRequest, 'over bound length');
  // args grammar: object or the null literal only, never '' or arrays
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '', sinkRef) = perInvalidRequest, 'empty args string');
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '[1,2]', sinkRef) = perInvalidRequest, 'positional array args');
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '"s"', sinkRef) = perInvalidRequest, 'scalar args');
  // nothing above may have reached policy, bridge or sink
  CheckEqual(FBridge.InvokeCount, 0, 'no rejected request reached the bridge');
  CheckEqual(sink.CompleteCount, 0, 'no rejected request touched the sink');
  // the canonical value is the exact spelling - no case folding ever
  Check(FSource.TryEnqueue(Ctx, 'MixedCase.Method_1', '{}', sinkRef) = perAccepted,
    'exact-case Service.Method accepted');
  Check(sink.WaitDone(5000), 'mixed-case invocation completes');
  CheckEqual(FBridge.RecordedInvoke(0).Method, 'MixedCase.Method_1',
    'exact spelling preserved unchanged through the gate');
  // minimal two-segment form travels intact as well
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'A.B', '{}', sinkRef) = perAccepted,
    'minimal A.B accepted at the gate');
  Check(sink.WaitDone(5000), 'A.B invocation completes');
  CheckEqual(FBridge.RecordedInvoke(1).Method, 'A.B',
    'A.B spelling preserved through the gate');
  // whitespace-padded spellings are treated consistently (trim first):
  // ' null ' and '{ }' are as valid as their unpadded forms
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', ' null ', sinkRef) = perAccepted,
    'padded null args accepted');
  Check(sink.WaitDone(5000), 'padded-null invocation completes');
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{ }', sinkRef) = perAccepted,
    'padded empty object args accepted');
  Check(sink.WaitDone(5000), 'padded-object invocation completes');
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '   ', sinkRef) = perInvalidRequest,
    'whitespace-only args still rejected');
  EndPipeline;
end;

procedure TTestInvocationScheduler.SameCanonicalMethodAtPolicyAndBridge; // mandated test 4
var
  pol: TRecordingAllowPolicy;
  polRef: ICapabilityPolicy;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  pol := TRecordingAllowPolicy.Create;
  polRef := pol;
  NewPipeline(2, 8, polRef);
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{"k":true}', sinkRef) = perAccepted);
  Check(sink.WaitDone(5000), 'invocation completes');
  CheckEqual(pol.SeenCount, 1, 'policy called exactly once');
  CheckEqual(FBridge.InvokeCount, 1, 'bridge called exactly once');
  CheckEqual(pol.Seen(0), 'pweb.echo', 'policy received the canonical method');
  CheckEqual(FBridge.RecordedInvoke(0).Method, 'pweb.echo',
    'bridge received the canonical method');
  CheckEqual(pol.Seen(0), FBridge.RecordedInvoke(0).Method,
    'IDENTICAL canonical value at policy and bridge');
  EndPipeline;
end;

procedure TTestInvocationScheduler.AllowAllPolicyPermits; // mandated test 5
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  NewPipeline(2, 8); // TAllowAllCapabilityPolicy is the default pipeline policy
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{"ok":1}', sinkRef) = perAccepted);
  Check(sink.WaitDone(5000), 'completes under allow-all');
  Check(sink.First.Kind = prkSuccess, 'allow-all permits: bridge executed');
  CheckEqual(FBridge.InvokeCount, 1, 'bridge reached exactly once');
  EndPipeline;
end;

procedure TTestInvocationScheduler.DenyAndRaisingPolicy; // mandated test 6
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  // deny path: policy returns False -> forbidden, bridge NEVER called
  NewPipeline(2, 8, TDenyAllPolicy.Create);
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{}', sinkRef) = perAccepted);
  Check(sink.WaitDone(5000), 'denied invocation still completes terminally');
  Check(sink.First.Kind = prkError, 'deny is the error arm');
  Check(sink.First.Error.Code = pecForbidden, 'deny maps to forbidden');
  CheckEqual(FBridge.InvokeCount, 0, 'bridge never called on deny');
  EndPipeline;
  // exception path: policy raising = DENY + internal_error, never open
  NewPipeline(2, 8, TRaisingPolicy.Create);
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{}', sinkRef) = perAccepted);
  Check(sink.WaitDone(5000), 'raising-policy invocation completes terminally');
  Check(sink.First.Kind = prkError);
  Check(sink.First.Error.Code = pecInternalError,
    'policy exception maps to internal_error');
  CheckEqual(Pos(RawUtf8('marker'), RawUtf8(sink.First.Error.Message)), 0,
    'no exception detail leaks');
  CheckEqual(FBridge.InvokeCount, 0, 'bridge never called when policy raises');
  EndPipeline;
end;

procedure TTestInvocationScheduler.QueueLimitBusy; // mandated test 7
var
  a, b, c, d: TTestCompletion;
  ra, rb, rc, rd: IInvocationCompletion;
begin
  NewPipeline(1, 2);
  FBridge.CloseGate;
  a := TTestCompletion.Create; ra := a;
  b := TTestCompletion.Create; rb := b;
  c := TTestCompletion.Create; rc := c;
  d := TTestCompletion.Create; rd := d;
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', ra) = perAccepted, 'A accepted');
  Check(WaitBridgeCurrent(1, 5000), 'A claimed the single slot');
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rb) = perAccepted, 'B queued');
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rc) = perAccepted, 'C queued');
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rd) = perBusy,
    'MaxQueueSize reached: synchronous busy, never blocks');
  CheckEqual(d.CompleteCount, 0, 'rejected enqueue never touches the sink');
  FBridge.OpenGate;
  Check(a.WaitDone(5000) and b.WaitDone(5000) and c.WaitDone(5000),
    'accepted invocations all complete');
  Check((a.First.Kind = prkSuccess) and (b.First.Kind = prkSuccess) and
    (c.First.Kind = prkSuccess), 'accepted invocations succeed');
  CheckEqual(d.CompleteCount, 0, 'busy-rejected sink still untouched');
  EndPipeline;
end;

procedure TTestInvocationScheduler.ConcurrencyLimitRespected; // mandated test 8
var
  sinks: array[0..5] of TTestCompletion;
  refs: array[0..5] of IInvocationCompletion;
  i: Integer;
begin
  NewPipeline(2, 10);
  FBridge.CloseGate;
  for i := 0 to 5 do
  begin
    sinks[i] := TTestCompletion.Create;
    refs[i] := sinks[i];
    Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', refs[i]) = perAccepted);
  end;
  Check(WaitBridgeCurrent(2, 5000), 'two invocations run simultaneously');
  Sleep(100); // give an over-eager scheduler time to break the limit
  CheckEqual(FBridge.CurrentConcurrent, 2, 'never more than MaxConcurrent in flight');
  FBridge.OpenGate;
  for i := 0 to 5 do
    Check(sinks[i].WaitDone(5000), 'every accepted invocation completes');
  CheckEqual(FBridge.PeakConcurrent, 2, 'high-water mark equals MaxConcurrent');
  CheckEqual(FBridge.InvokeCount, 6, 'all six reached the bridge');
  EndPipeline;
end;

procedure TTestInvocationScheduler.FreedSlotStartsQueuedWork; // mandated test 9
var
  a, b: TTestCompletion;
  ra, rb: IInvocationCompletion;
begin
  NewPipeline(1, 5);
  FBridge.CloseGate;
  a := TTestCompletion.Create; ra := a;
  b := TTestCompletion.Create; rb := b;
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', ra) = perAccepted);
  Check(WaitBridgeCurrent(1, 5000), 'A holds the only slot');
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rb) = perAccepted, 'B waits queued');
  Sleep(50);
  CheckEqual(b.CompleteCount, 0, 'B cannot start while the slot is held');
  CheckEqual(FBridge.InvokeCount, 1, 'B has not reached the bridge yet');
  FBridge.OpenGate; // A completes -> slot frees -> B must start
  Check(a.WaitDone(5000), 'A completes');
  Check(b.WaitDone(5000), 'B starts on the freed slot and completes');
  Check(b.First.Kind = prkSuccess);
  CheckEqual(FBridge.InvokeCount, 2, 'B executed after the slot freed');
  EndPipeline;
end;

procedure TTestInvocationScheduler.ExactlyOnceCompletion; // mandated test 10
var
  i: Integer;
  lim: TPWebSourceLimits;
  src: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  // race/mutation style: many iterations of enqueue vs quiesce/close
  // with varying delays; whatever wins, the sink completes EXACTLY once
  NewPipeline(2, 4);
  lim.MaxConcurrent := 2;
  lim.MaxQueueSize := 4;
  for i := 1 to 60 do
  begin
    src := FScheduler.RegisterSource(lim);
    FBridge.DelayMs := (i mod 4) * 3;
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(src.TryEnqueue(Ctx, 'test.delay', '{}', sinkRef) = perAccepted);
    if i mod 3 = 0 then
      Sleep(i mod 5);
    if i mod 2 = 0 then
      src.Quiesce
    else
      src.Close;
    Check(sink.WaitDone(5000), 'terminal completion always arrives');
    Sleep(10); // settle: let any racing late completion hit the gate
    CheckEqual(sink.CompleteCount, 1, 'exactly one completion, never more');
    sinkRef := nil;
    src := nil;
  end;
  EndPipeline;
end;

procedure TTestInvocationScheduler.DoubleCompletionCannotDoubleReleaseSlot; // mandated test 11
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  q, act: Integer;
begin
  NewPipeline(1, 1);
  FBridge.CloseGate;
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', sinkRef) = perAccepted);
  Check(WaitBridgeCurrent(1, 5000), 'invocation in flight');
  Check(FScheduler.TryGetSourceCounts(FSource, q, act), 'counts available');
  CheckEqual(q, 0, 'nothing queued while blocked');
  CheckEqual(act, 1, 'one active slot occupied');
  FSource.Close; // completes the in-flight invocation as cancelled NOW
  Check(sink.WaitDone(5000), 'cancelled completion delivered');
  Check(sink.First.Kind = prkError);
  Check(sink.First.Error.Code = pecCancelled, 'close cancels in-flight');
  // tracking ends at pssClosed: the scheduler released its references
  Check(not FScheduler.TryGetSourceCounts(FSource, q, act),
    'closed source no longer tracked (cycle broken at Close)');
  // now let the blocked bridge finish: its late completion attempt must
  // die at the gate WITHOUT double-releasing anything
  FBridge.OpenGate;
  Sleep(200);
  CheckEqual(sink.CompleteCount, 1, 'late result died at the gate');
  EndPipeline;
end;

procedure TTestInvocationScheduler.BridgeExceptionInternalError; // mandated test 12
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  NewPipeline(2, 8);
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'test.raise', '{}', sinkRef) = perAccepted);
  Check(sink.WaitDone(5000), 'raising bridge still completes terminally');
  Check(sink.First.Kind = prkError);
  Check(sink.First.Error.Code = pecInternalError,
    'bridge exception maps to internal_error');
  CheckEqual(Pos(RawUtf8('marker'), RawUtf8(sink.First.Error.Message)), 0,
    'exception text does not leak');
  CheckEqual(Pos(RawUtf8('Exception'), RawUtf8(sink.First.Error.Message)), 0,
    'exception class name does not leak');
  CheckEqual(sink.First.Error.Data, PWEB_JSON_NULL, 'internal_error data is null');
  EndPipeline;
end;

procedure TTestInvocationScheduler.CooperativeCancellation; // mandated test 13
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  t0: Int64;
begin
  NewPipeline(2, 8);
  FBridge.DelayMs := 10000; // would run 10s if cancellation were ignored
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'test.delay', '{}', sinkRef) = perAccepted);
  Check(WaitBridgeCurrent(1, 5000), 'delay bridge in flight');
  t0 := GetTickCount64;
  FSource.Quiesce; // signals the cooperative token; work observes it
  Check(sink.WaitDone(5000), 'token-observing bridge completes early');
  Check(GetTickCount64 - t0 < 4000, 'cancellation was cooperative and prompt');
  Check(sink.First.Kind = prkError);
  Check(sink.First.Error.Code = pecCancelled, 'completes as cancelled');
  Sleep(20);
  CheckEqual(sink.CompleteCount, 1, 'slot/sink released exactly once');
  EndPipeline;
end;

procedure TTestInvocationScheduler.QuiesceRefusesNew; // mandated test 14
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  NewPipeline(2, 8);
  FSource.Quiesce;
  Check(FSource.State = pssQuiescing, 'source is quiescing');
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{}', sinkRef) = perClosed,
    'quiescing source synchronously refuses new invocations');
  CheckEqual(sink.CompleteCount, 0, 'refused enqueue never touches the sink');
  CheckEqual(FBridge.InvokeCount, 0, 'nothing reached the bridge');
  FSource.Quiesce; // idempotent
  Check(FSource.State = pssQuiescing, 'quiesce is idempotent');
  EndPipeline;
end;

procedure TTestInvocationScheduler.QuiesceCancelsQueued; // mandated test 15
var
  a, b, c: TTestCompletion;
  ra, rb, rc: IInvocationCompletion;
begin
  NewPipeline(1, 5);
  FBridge.CloseGate;
  a := TTestCompletion.Create; ra := a;
  b := TTestCompletion.Create; rb := b;
  c := TTestCompletion.Create; rc := c;
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', ra) = perAccepted, 'A in flight');
  Check(WaitBridgeCurrent(1, 5000));
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rb) = perAccepted, 'B queued');
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rc) = perAccepted, 'C queued');
  FSource.Quiesce;
  Check(b.WaitDone(5000), 'queued B gets a terminal completion');
  Check(c.WaitDone(5000), 'queued C gets a terminal completion');
  Check(b.First.Error.Code = pecCancelled, 'B completed as cancelled');
  Check(c.First.Error.Code = pecCancelled, 'C completed as cancelled');
  CheckEqual(FBridge.InvokeCount, 1, 'queued invocations never reached the bridge');
  // in-flight A observes the token cooperatively and finishes cancelled
  Check(a.WaitDone(5000), 'in-flight A completes');
  Check(a.First.Error.Code = pecCancelled, 'A observed cooperative cancellation');
  EndPipeline;
end;

procedure TTestInvocationScheduler.CloseWhileRunningQuiescesFirst; // mandated test 16
var
  a, b: TTestCompletion;
  ra, rb: IInvocationCompletion;
  q, act: Integer;
begin
  NewPipeline(1, 5);
  FBridge.CloseGate;
  a := TTestCompletion.Create; ra := a;
  b := TTestCompletion.Create; rb := b;
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', ra) = perAccepted, 'A in flight');
  Check(WaitBridgeCurrent(1, 5000));
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', rb) = perAccepted, 'B queued');
  Check(FSource.State = pssRunning, 'still running');
  FSource.Close; // Running -> full quiesce semantics -> Closed
  Check(FSource.State = pssClosed, 'closed');
  Check(b.WaitDone(5000), 'queued B was cancelled by the implicit quiesce');
  Check(b.First.Error.Code = pecCancelled);
  Check(a.WaitDone(5000), 'in-flight A completed by close');
  Check(a.First.Error.Code = pecCancelled);
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{}', ra) = perClosed,
    'closed source refuses enqueues');
  FBridge.OpenGate;
  Sleep(200); // late bridge results die at the gate
  CheckEqual(a.CompleteCount, 1, 'A completed exactly once');
  CheckEqual(b.CompleteCount, 1, 'B completed exactly once');
  Check(not FScheduler.TryGetSourceCounts(FSource, q, act),
    'tracking released once Closed');
  FSource.Close; // idempotent
  Check(FSource.State = pssClosed);
  EndPipeline;
end;

procedure TTestInvocationScheduler.NonWebViewTestSource; // mandated test 20
var
  lim: TPWebSourceLimits;
  raised: Boolean;
  src: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  // this whole test case never references a pweb.webview.* unit: the
  // scheduler works against a plain test source and test sinks -
  // sources are generic, the WebView binding is only one of them
  NewPipeline(2, 8);
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(Ctx, 'pweb.echo', '{"src":"generic"}', sinkRef) = perAccepted);
  Check(sink.WaitDone(5000), 'non-WebView source completes through the pool');
  CheckEqual(sink.First.Value, '{"src":"generic"}');
  // RegisterSource refuses invalid limits with a Pascal exception
  raised := False;
  lim.MaxConcurrent := 0;
  lim.MaxQueueSize := 5;
  try
    FScheduler.RegisterSource(lim);
  except
    on E: EPWebSchedulerError do
      raised := True;
  end;
  Check(raised, 'MaxConcurrent < 1 refused at the call site');
  raised := False;
  lim.MaxConcurrent := 1;
  lim.MaxQueueSize := 0;
  try
    FScheduler.RegisterSource(lim);
  except
    on E: EPWebSchedulerError do
      raised := True;
  end;
  Check(raised, 'MaxQueueSize < 1 refused at the call site');
  // shutdown: idempotent; afterwards sources are born closed
  FScheduler.Shutdown;
  FScheduler.Shutdown; // second call is a no-op
  lim.MaxConcurrent := 1;
  lim.MaxQueueSize := 1;
  src := FScheduler.RegisterSource(lim);
  Check(src.State = pssClosed, 'post-shutdown source is born closed');
  Check(src.TryEnqueue(Ctx, 'pweb.echo', '{}', sinkRef) = perClosed,
    'fail-closed: enqueue reports perClosed, nothing raises');
  EndPipeline;
end;

procedure TTestInvocationScheduler.ContextSnapshotIndependence;
var
  pol: TRecordingAllowPolicy;
  polRef: ICapabilityPolicy;
  blocker, sink: TTestCompletion;
  blockerRef, sinkRef: IInvocationCompletion;
  snapCtx, seen: TInvocationContext;
  rec: TPWebDummyInvokeRecord;
begin
  pol := TRecordingAllowPolicy.Create;
  polRef := pol;
  NewPipeline(1, 5, polRef);
  FBridge.CloseGate;
  blocker := TTestCompletion.Create;
  blockerRef := blocker;
  Check(FSource.TryEnqueue(Ctx, 'test.block', '{}', blockerRef) = perAccepted);
  Check(WaitBridgeCurrent(1, 5000), 'blocker holds the only slot');
  // caller-owned context, enqueued BEHIND the blocker so it is still
  // queued when the caller mutates its own record afterwards
  snapCtx := Default(TInvocationContext);
  snapCtx.WindowId := 'w-snap';
  snapCtx.PrincipalId := 'window:w-snap';
  snapCtx.PrincipalKind := pkWindow;
  snapCtx.TrustedContent := True;
  SetLength(snapCtx.Capabilities, 2);
  snapCtx.Capabilities[0] := 'cap.alpha';
  snapCtx.Capabilities[1] := 'cap.beta';
  sink := TTestCompletion.Create;
  sinkRef := sink;
  Check(FSource.TryEnqueue(snapCtx, 'pweb.echo', '{"snap":1}', sinkRef) = perAccepted);
  // mutate the caller's record AND its Capabilities array in place: the
  // worker must still observe the immutable deep-copied snapshot
  snapCtx.WindowId := 'mutated';
  snapCtx.PrincipalId := 'mutated';
  snapCtx.TrustedContent := False;
  snapCtx.Capabilities[0] := 'cap.evil';
  SetLength(snapCtx.Capabilities, 1);
  FBridge.OpenGate;
  Check(blocker.WaitDone(5000), 'blocker completed');
  Check(sink.WaitDone(5000), 'snapshot invocation completed');
  // policy saw the original values (record 0 is the blocker)
  CheckEqual(pol.SeenCount, 2, 'policy called for both invocations');
  seen := pol.SeenContext(1);
  CheckEqual(seen.WindowId, 'w-snap', 'policy saw the snapshot WindowId');
  CheckEqual(seen.PrincipalId, 'window:w-snap', 'snapshot PrincipalId');
  Check(seen.PrincipalKind = pkWindow, 'kind intact at the policy');
  Check(seen.TrustedContent, 'TrustedContent intact at the policy');
  CheckEqual(Length(seen.Capabilities), 2, 'capabilities were deep-copied');
  CheckEqual(seen.Capabilities[0], 'cap.alpha', 'array mutation did not leak');
  CheckEqual(seen.Capabilities[1], 'cap.beta');
  // the bridge saw the identical snapshot
  CheckEqual(FBridge.InvokeCount, 2);
  rec := FBridge.RecordedInvoke(1);
  CheckEqual(rec.Context.WindowId, 'w-snap', 'bridge saw the snapshot');
  CheckEqual(rec.Context.PrincipalId, 'window:w-snap');
  Check(rec.Context.PrincipalKind = pkWindow, 'kind intact at the bridge');
  Check(rec.Context.TrustedContent, 'TrustedContent intact at the bridge');
  CheckEqual(Length(rec.Context.Capabilities), 2);
  CheckEqual(rec.Context.Capabilities[0], 'cap.alpha');
  CheckEqual(rec.Context.Capabilities[1], 'cap.beta');
  EndPipeline;
end;

{ ---------------- TTestWebViewBinding ---------------- }

procedure TTestWebViewBinding.NewBindingPipeline(AMaxConcurrent, AMaxQueue,
  AMaxRequestBytes: Integer);
var
  lim: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
begin
  ResetFakes;
  FBridge := TDummyInvocationBridge.Create;
  FBridgeRef := FBridge;
  // a recording allow-policy: behaves as allow-all AND lets the tests
  // verify the native context/canonical method that reached it
  FRecPolicy := TRecordingAllowPolicy.Create;
  FPolicyRef := FRecPolicy;
  FScheduler := TInvocationScheduler.Create(FPolicyRef, FBridgeRef, 4);
  FSchedulerRef := FScheduler;
  lim.MaxConcurrent := AMaxConcurrent;
  lim.MaxQueueSize := AMaxQueue;
  FSource := FScheduler.RegisterSource(lim);
  opts := Default(TPWebWebViewBindingOptions);
  opts.ContextTemplate := TestContext;
  SetLength(opts.ContextTemplate.Capabilities, 2);
  opts.ContextTemplate.Capabilities[0] := 'cap.read';
  opts.ContextTemplate.Capabilities[1] := 'cap.write';
  opts.MaxRequestBytes := AMaxRequestBytes;
  opts.NativeBind := FakeNativeBind;
  opts.NativeUnbind := FakeNativeUnbind;
  opts.NativeReturn := FakeNativeReturn;
  FBinding := TWebViewBinding.Create(nil, FSource, opts);
  FBindingRef := FBinding;
  FBinding.Bind('__pweb_invoke', TPWebEnvelopeHandler.Create(FSource));
end;

procedure TTestWebViewBinding.EndBindingPipeline;
begin
  if FBridge <> nil then
    FBridge.OpenGate;
  InterlockedExchange(FakeReturnGateOpen, 1); // never leave a fake return blocked
  if FScheduler <> nil then
    FScheduler.Shutdown;
  FBindingRef := nil;
  FBinding := nil;
  FSource := nil;
  FSchedulerRef := nil;
  FScheduler := nil;
  FPolicyRef := nil;
  FRecPolicy := nil;
  FBridgeRef := nil;
  FBridge := nil;
end;

function TTestWebViewBinding.WaitBridgeCurrent(AValue,
  ATimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while (FBridge.CurrentConcurrent <> AValue) and (waited < ATimeoutMs) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  Result := FBridge.CurrentConcurrent = AValue;
end;

function TTestWebViewBinding.WaitReturnCount(const AId: RawUtf8;
  AValue, ATimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while (FakeReturnCount(AId) <> AValue) and (waited < ATimeoutMs) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  Result := FakeReturnCount(AId) = AValue;
end;

procedure TTestWebViewBinding.MalformedEnvelopeRejectedPreEnqueue; // mandated test 1
var
  status, seqBefore, countBefore: Integer;
  payload: RawUtf8;
  big: RawUtf8;
begin
  NewBindingPipeline(2, 8, 0);
  // every malformed shape is rejected synchronously, pre-queue, on the
  // callback thread - it never reaches TryEnqueue nor the bridge
  FireBound('__pweb_invoke', 'm1', 'not json at all');
  FireBound('__pweb_invoke', 'm2', '{}');            // not an array
  FireBound('__pweb_invoke', 'm3', '[]');            // no method
  FireBound('__pweb_invoke', 'm4', '[42,{}]');       // method not a string
  FireBound('__pweb_invoke', 'm5', '["pweb.echo"]'); // args element missing
  FireBound('__pweb_invoke', 'm6', '["pweb.echo",[1,2]]'); // positional args
  FireBound('__pweb_invoke', 'm7', '["pweb.echo",{},3]');  // extra element
  FireBound('__pweb_invoke', 'm8', '["pweb.echo",{');      // truncated JSON
  CheckEqual(FakeReturnCount('m1'), 1, 'sync rejection m1');
  CheckEqual(FakeReturnCount('m2'), 1, 'sync rejection m2');
  CheckEqual(FakeReturnCount('m3'), 1, 'sync rejection m3');
  CheckEqual(FakeReturnCount('m4'), 1, 'sync rejection m4');
  CheckEqual(FakeReturnCount('m5'), 1, 'sync rejection m5');
  CheckEqual(FakeReturnCount('m6'), 1, 'sync rejection m6');
  CheckEqual(FakeReturnCount('m7'), 1, 'sync rejection m7');
  CheckEqual(FakeReturnCount('m8'), 1, 'sync rejection m8');
  Check(FakeLastReturn('m1', status, payload));
  CheckNotEqual(status, 0, 'rejection uses the reject arm');
  CheckEqual(PayloadCode(payload), 'invalid_request');
  Check(Pos(RawUtf8('"status":400'), payload) > 0, 'frozen status table applied');
  CheckEqual(FBridge.InvokeCount, 0, 'nothing malformed reached the bridge');
  // bad method grammar travels callback -> TryEnqueue -> sync rejection
  FireBound('__pweb_invoke', 'm9', '["not_service_method",{}]');
  CheckEqual(FakeReturnCount('m9'), 1, 'grammar rejection is synchronous');
  Check(FakeLastReturn('m9', status, payload));
  CheckEqual(PayloadCode(payload), 'invalid_request');
  // control: a valid envelope resolves with the echoed args
  FireBound('__pweb_invoke', 'ok1', '["pweb.echo",{"k":1}]');
  Check(WaitReturnCount('ok1', 1, 5000), 'valid invocation returned');
  Check(FakeLastReturn('ok1', status, payload));
  CheckEqual(status, 0, 'success arm');
  CheckEqual(payload, '{"k":1}', 'echoed payload verbatim');
  // an empty/absent native id means no correlation: dropped BEFORE any
  // enqueue - nothing new reaches the bridge, nothing is returned
  seqBefore := FakeMaxSeq;
  countBefore := FBridge.InvokeCount;
  FireBound('__pweb_invoke', '', '["pweb.echo",{"k":2}]');
  Sleep(100);
  CheckEqual(FakeMaxSeq, seqBefore, 'no native return for an id-less call');
  CheckEqual(FBridge.InvokeCount, countBefore,
    'id-less call was never enqueued');
  EndBindingPipeline;
  // oversize request: size validated in the callback, pre-queue
  NewBindingPipeline(2, 8, 64);
  SetLength(big, 100);
  FillChar(pointer(big)^, 100, Ord('x'));
  FireBound('__pweb_invoke', 'big1', '["pweb.echo",{"p":"' + big + '"}]');
  CheckEqual(FakeReturnCount('big1'), 1, 'oversize rejected synchronously');
  Check(FakeLastReturn('big1', status, payload));
  CheckEqual(PayloadCode(payload), 'invalid_request');
  CheckEqual(FBridge.InvokeCount, 0, 'oversize never reached the bridge');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.PreQueueSyncRejectionMapping;
var
  status: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(1, 1, 0);
  FBridge.CloseGate;
  FireBound('__pweb_invoke', 'a1', '["test.block",{}]');
  Check(WaitBridgeCurrent(1, 5000), 'A in flight');
  FireBound('__pweb_invoke', 'b1', '["test.block",{}]'); // fills the queue
  // queue full -> synchronous busy on the callback thread
  FireBound('__pweb_invoke', 'c1', '["test.block",{}]');
  CheckEqual(FakeReturnCount('c1'), 1, 'busy rejection is synchronous');
  Check(FakeLastReturn('c1', status, payload));
  CheckEqual(PayloadCode(payload), 'busy');
  Check(Pos(RawUtf8('"status":429'), payload) > 0, 'busy status from frozen table');
  // quiescing -> runtime_closed
  FBinding.Quiesce;
  Check(FBinding.State = pssQuiescing, 'binding state mirrors its source');
  FireBound('__pweb_invoke', 'd1', '["pweb.echo",{}]');
  CheckEqual(FakeReturnCount('d1'), 1, 'runtime_closed rejection is synchronous');
  Check(FakeLastReturn('d1', status, payload));
  CheckEqual(PayloadCode(payload), 'runtime_closed');
  Check(Pos(RawUtf8('"status":503'), payload) > 0);
  // queued b1 was cancelled by the quiesce, through the same sink path
  Check(WaitReturnCount('b1', 1, 5000), 'queued invocation cancelled');
  Check(FakeLastReturn('b1', status, payload));
  CheckEqual(PayloadCode(payload), 'cancelled');
  FBridge.OpenGate;
  Check(WaitReturnCount('a1', 1, 5000), 'in-flight completed');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.BindRefusals;
var
  raised: Boolean;
  h: IWebViewInvocationHandler;
begin
  NewBindingPipeline(2, 8, 0);
  h := TPWebEnvelopeHandler.Create(FSource);
  raised := False;
  try
    FBinding.Bind('', h);
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'empty name refused at the call site');
  raised := False;
  try
    FBinding.Bind('other', nil);
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'nil handler refused');
  raised := False;
  try
    FBinding.Bind('__pweb_invoke', h); // duplicate
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'duplicate name refused');
  FBinding.Unbind('never_bound'); // unknown name is a no-op, no exception
  FBinding.Quiesce;
  raised := False;
  try
    FBinding.Bind('late', h);
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'bind outside pssRunning refused');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.UnbindLifecycle;
var
  unbindsBefore, seqBefore, status: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(2, 8, 0);
  FBinding.Bind('temp', TPWebEnvelopeHandler.Create(FSource));
  FireBound('temp', 'u1', '["pweb.echo",{"via":"temp"}]');
  Check(WaitReturnCount('u1', 1, 5000), 'bound name works before unbind');
  unbindsBefore := FakeUnbinds;
  FBinding.Unbind('temp');
  CheckEqual(FakeUnbinds, unbindsBefore + 1, 'native unbind was performed');
  Check(not FakeHasBinding('temp'), 'name is gone from the native side');
  // firing the old (unbound) callback is inert
  seqBefore := FakeMaxSeq;
  FireBound('temp', 'u2', '["pweb.echo",{}]');
  Sleep(100);
  CheckEqual(FakeMaxSeq, seqBefore, 'unbound name produced no native call');
  CheckEqual(FakeReturnCount('u2'), 0, 'no return for the unbound name');
  // re-bind of the same name succeeds after unbind
  FBinding.Bind('temp', TPWebEnvelopeHandler.Create(FSource));
  FireBound('temp', 'u3', '["pweb.echo",{"again":true}]');
  Check(WaitReturnCount('u3', 1, 5000), 're-bound name works');
  Check(FakeLastReturn('u3', status, payload));
  CheckEqual(status, 0, 're-bound invocation resolved');
  CheckEqual(payload, '{"again":true}');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.RaisingHandlerBarrier;
var
  status: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(2, 8, 0);
  FBinding.Bind('raiser', TRaisingHandler.Create);
  FBinding.Bind('completethenraise', TCompleteThenRaiseHandler.Create);
  // a raising handler: the C-callback barrier maps the failure to
  // EXACTLY ONE internal_error return; nothing crosses the C frame
  FireBound('raiser', 'rh1', '["pweb.echo",{}]');
  CheckEqual(FakeReturnCount('rh1'), 1, 'exactly one return for the raise');
  Check(FakeLastReturn('rh1', status, payload));
  CheckNotEqual(status, 0, 'reject arm');
  CheckEqual(PayloadCode(payload), 'internal_error');
  CheckEqual(Pos(RawUtf8('marker'), payload), 0, 'no exception detail leaks');
  Sleep(100);
  CheckEqual(FakeReturnCount('rh1'), 1, 'still exactly one return');
  // the handler completes the sink FIRST and then raises: the sink's
  // idempotent gate must drop the barrier's internal_error attempt -
  // the first delivery stands alone (double-return regression test)
  FireBound('completethenraise', 'rh2', '["pweb.echo",{}]');
  CheckEqual(FakeReturnCount('rh2'), 1,
    'exactly one return despite raise-after-complete');
  Check(FakeLastReturn('rh2', status, payload));
  CheckEqual(status, 0, 'the first (success) delivery won');
  CheckEqual(payload, '{"first":"delivery"}');
  Sleep(100);
  CheckEqual(FakeReturnCount('rh2'), 1, 'no second return ever arrives');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.ContextReachesPolicyAndBridge;
var
  seen: TInvocationContext;
  rec: TPWebDummyInvokeRecord;
begin
  NewBindingPipeline(2, 8, 0);
  FireBound('__pweb_invoke', 'ctx1', '["pweb.echo",{"q":1}]');
  Check(WaitReturnCount('ctx1', 1, 5000), 'invocation completed');
  // the native template context - never anything JS-supplied - reached
  // the policy call site field by field, capabilities included
  CheckEqual(FRecPolicy.SeenCount, 1, 'policy called exactly once');
  seen := FRecPolicy.SeenContext(0);
  CheckEqual(seen.WindowId, 'w1', 'template WindowId at the policy');
  CheckEqual(seen.PrincipalId, 'window:w1', 'template PrincipalId at the policy');
  Check(seen.PrincipalKind = pkWindow, 'principal kind intact at the policy');
  Check(seen.TrustedContent, 'TrustedContent intact at the policy');
  CheckEqual(Length(seen.Capabilities), 2, 'capabilities travelled to the policy');
  CheckEqual(seen.Capabilities[0], 'cap.read');
  CheckEqual(seen.Capabilities[1], 'cap.write');
  // ... and the identical snapshot reached the bridge
  rec := FBridge.RecordedInvoke(0);
  CheckEqual(rec.Context.WindowId, 'w1', 'template WindowId at the bridge');
  CheckEqual(rec.Context.PrincipalId, 'window:w1');
  Check(rec.Context.PrincipalKind = pkWindow, 'principal kind intact at the bridge');
  Check(rec.Context.TrustedContent, 'TrustedContent intact at the bridge');
  CheckEqual(Length(rec.Context.Capabilities), 2, 'capabilities at the bridge');
  CheckEqual(rec.Context.Capabilities[0], 'cap.read');
  CheckEqual(rec.Context.Capabilities[1], 'cap.write');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.CallbackDoesNoSynchronousServiceExecution; // mandated test 19
var
  myThread: TThreadID;
  status: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(2, 8, 0);
  FBridge.CloseGate;
  myThread := GetCurrentThreadId;
  // the callback returns synchronously here even though the bridge
  // cannot run yet: enqueue-only duties, nothing blocking
  FireBound('__pweb_invoke', 't1', '["test.block",{}]');
  CheckEqual(FakeReturnCount('t1'), 0,
    'callback returned without completing: no synchronous execution');
  // the bridge executes later, on a pool worker - never on the
  // (GUI-affine) callback thread
  Check(WaitBridgeCurrent(1, 5000), 'bridge started asynchronously');
  CheckEqual(FBridge.InvokeCount, 1);
  CheckNotEqual(FBridge.RecordedInvoke(0).ThreadId, myThread,
    'bridge ran off the callback thread');
  FBridge.OpenGate;
  Check(WaitReturnCount('t1', 1, 5000), 'completion via webview_return');
  Check(FakeLastReturn('t1', status, payload));
  CheckEqual(status, 0);
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.LateCompletionAfterClosedTouchesNothing; // mandated test 17
var
  status, seqAtClose: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(1, 4, 0);
  FBridge.CloseGate;
  FireBound('__pweb_invoke', 'late1', '["test.block",{}]');
  Check(WaitBridgeCurrent(1, 5000), 'invocation in flight');
  FBinding.Close; // quiesce -> unbind -> source close -> lease shutter
  Check(FBinding.State = pssClosed, 'binding closed');
  Check(FakeUnbinds > 0, 'JS-side unbind happened during teardown');
  // the in-flight invocation was completed (cancelled) on the way to
  // Closed, while the sink could still deliver
  CheckEqual(FakeReturnCount('late1'), 1, 'terminal cancelled return delivered');
  Check(FakeLastReturn('late1', status, payload));
  CheckEqual(PayloadCode(payload), 'cancelled');
  seqAtClose := FakeMaxSeq;
  // now release the still-running bridge: its late completion attempt
  // must not touch the native handle in any way
  FBridge.OpenGate;
  Sleep(300);
  CheckEqual(FakeMaxSeq, seqAtClose,
    'no native call of any kind after Closed');
  CheckEqual(FakeReturnCount('late1'), 1, 'still exactly one return');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.LeasePreventsDestroyReturnRace; // mandated test 18
var
  cap: TCapturingHandler;
  capRef: IWebViewInvocationHandler;
  waited: Integer;
  status: Integer;
  payload: RawUtf8;
begin
  // part 1: a completion attempt AFTER close acquires no lease and
  // performs no native return at all
  NewBindingPipeline(2, 8, 0);
  cap := TCapturingHandler.Create;
  capRef := cap;
  FBinding.Bind('capture', capRef);
  FireBound('capture', 'cap1', '["pweb.echo",{}]');
  Check(cap.Captured <> nil, 'sink captured before close');
  FBinding.Close;
  cap.Captured.Complete(PWebSuccessResult('{"too":"late"}'));
  CheckEqual(FakeReturnCount('cap1'), 0,
    'lease denied: the handle was never touched after close');
  EndBindingPipeline;
  // part 2: a return in progress holds a lease; Close does not block on
  // it, and the owner can observe the drain before destroying
  NewBindingPipeline(2, 8, 0);
  SetFakeReturnBlock(True);
  FireBound('__pweb_invoke', 'r1', '["pweb.echo",{"x":1}]');
  waited := 0;
  while (FakeReturnEntered = 0) and (waited < 5000) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  Check(FakeReturnEntered <> 0, 'worker completion entered the native return');
  CheckEqual(FBinding.ActiveLeases, 1, 'handle-use lease held during the return');
  FBinding.Close; // must return promptly without waiting for the lease
  Check(FBinding.State = pssClosed, 'close completed while a lease was live');
  CheckEqual(FBinding.ActiveLeases, 1,
    'destroy would be deferred: lease still outstanding after Close');
  SetFakeReturnBlock(False);
  InterlockedExchange(FakeReturnGateOpen, 1); // release the slow native call
  waited := 0;
  while (FBinding.ActiveLeases <> 0) and (waited < 5000) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  CheckEqual(FBinding.ActiveLeases, 0, 'leases drained after release');
  Check(WaitReturnCount('r1', 1, 5000), 'the in-progress return completed');
  Check(FakeLastReturn('r1', status, payload));
  CheckEqual(status, 0);
  CheckEqual(payload, '{"x":1}');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.UnbindFailureKeepsUserdataSafe; // corrective A + B
var
  status, unbindsBefore: Integer;
  payload: RawUtf8;
  raised: Boolean;
begin
  NewBindingPipeline(2, 8, 0);
  FBinding.Bind('temp', TPWebEnvelopeHandler.Create(FSource));
  // scenario A: the native unbind FAILS - the Pascal call must fail at
  // the GUI boundary, the entry must stay owned and tracked, and the
  // callback native C still holds must stay fully memory-safe
  ScriptUnbindFailureFor('temp', WEBVIEW_ERROR_INVALID_STATE);
  unbindsBefore := FakeUnbinds;
  raised := False;
  try
    FBinding.Unbind('temp');
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'failed native unbind surfaces at the GUI call site');
  CheckEqual(FakeUnbinds, unbindsBefore + 1, 'native unbind was attempted');
  Check(FakeHasBinding('temp'), 'native side still holds the binding');
  // fire the callback through the retained userdata: it must work end
  // to end - the entry was never freed
  FireBound('temp', 'uf1', '["pweb.echo",{"alive":true}]');
  Check(WaitReturnCount('uf1', 1, 5000), 'callback on retained entry still works');
  Check(FakeLastReturn('uf1', status, payload));
  CheckEqual(status, 0, 'retained entry resolves normally');
  CheckEqual(payload, '{"alive":true}');
  // retry after the fault clears: detaches and frees exactly once
  ClearUnbindFailure;
  FBinding.Unbind('temp');
  Check(not FakeHasBinding('temp'), 'retried Unbind detached the binding');
  // an unbound name is a synchronous no-op: assert immediately
  FireBound('temp', 'uf2', '["pweb.echo",{}]');
  CheckEqual(FakeReturnCount('uf2'), 0, 'detached name is inert');
  // scenario B: a genuinely-absent native binding (registry record
  // dropped upstream) reports NOT_FOUND - a CONFIRMED detach: no
  // error, entry freed exactly once, name released Pascal-side
  FBinding.Bind('nf', TPWebEnvelopeHandler.Create(FSource));
  RemoveFakeBinding('nf'); // native no longer holds it
  FBinding.Unbind('nf');   // fake reports NOT_FOUND naturally; no raise
  Check(not FakeHasBinding('nf'), 'nothing native-side after the detach');
  // the registry released the name: a re-bind works cleanly
  FBinding.Bind('nf', TPWebEnvelopeHandler.Create(FSource));
  FireBound('nf', 'nf1', '["pweb.echo",{"n":1}]');
  Check(WaitReturnCount('nf1', 1, 5000), 're-bound after NOT_FOUND detach works');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.CloseRetryAfterUnbindFailure; // corrective C
var
  raised: Boolean;
  status: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(2, 8, 0);
  FBinding.Bind('other', TPWebEnvelopeHandler.Create(FSource));
  // the failure is aimed BY NAME (not by call order, so the test does
  // not depend on registry iteration order): '__pweb_invoke' cannot
  // detach, 'other' can
  ScriptUnbindFailureFor('__pweb_invoke', WEBVIEW_ERROR_INVALID_STATE);
  raised := False;
  try
    FBinding.Close;
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'failed unbind fails Close at the call site');
  Check(FBinding.State = pssQuiescing, 'no falsely successful Closed');
  Check(FakeHasBinding('__pweb_invoke'), 'undetached entry stays native-side');
  Check(not FakeHasBinding('other'), 'the confirmable entry WAS detached');
  Check(FBinding.TryAcquireLease, 'lease NOT shuttered past a failed unbind');
  FBinding.ReleaseLease;
  // the still-bound callback stays memory-safe while quiescing: fired,
  // it is rejected runtime_closed pre-queue - never a crash
  FireBound('__pweb_invoke', 'cq1', '["pweb.echo",{}]');
  CheckEqual(FakeReturnCount('cq1'), 1, 'quiescing rejection still delivered');
  Check(FakeLastReturn('cq1', status, payload));
  CheckEqual(PayloadCode(payload), 'runtime_closed');
  // retry completes the teardown once the fault clears; Closed is
  // reached exactly once
  ClearUnbindFailure;
  FBinding.Close;
  Check(FBinding.State = pssClosed, 'retried Close reached Closed');
  Check(not FakeHasBinding('__pweb_invoke'), 'remaining entry detached on retry');
  Check(not FBinding.TryAcquireLease, 'lease shuttered after successful Close');
  FBinding.Close; // idempotent once Closed
  Check(FBinding.State = pssClosed, 'Close stays idempotent');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.DestroyQuarantinesUndetachedEntry; // corrective: release after failed detach
var
  qBefore, seqBefore: Integer;
begin
  NewBindingPipeline(2, 8, 0);
  qBefore := PWebQuarantinedEntryCount;
  // '__pweb_invoke' can never confirm its detach (persistent, keyed by
  // name): the destructor's Close safety net fails, so releasing the
  // binding must QUARANTINE the entry (leak-by-choice) - never free
  // memory that native C still hands back as callback userdata
  ScriptUnbindFailureFor('__pweb_invoke', WEBVIEW_ERROR_INVALID_STATE);
  EndBindingPipeline; // shutdown + release: destructor quarantines
  CheckEqual(PWebQuarantinedEntryCount, qBefore + 1,
    'undetached entry was quarantined, not freed');
  Check(FakeHasBinding('__pweb_invoke'),
    'native side still holds the never-detached binding');
  seqBefore := FakeMaxSeq;
  // native C can still fire the callback with the quarantined entry as
  // userdata: it must be perfectly inert - no UAF, no native call (the
  // fire is synchronous, so the assertions follow immediately)
  FireBound('__pweb_invoke', 'q1', '["pweb.echo",{}]');
  CheckEqual(FakeMaxSeq, seqBefore, 'quarantined callback made no native call');
  CheckEqual(FakeReturnCount('q1'), 0, 'quarantined callback returned nothing');
end;

procedure TTestWebViewBinding.BindRollbackOnNativeFailure; // corrective D
var
  raised: Boolean;
  status: Integer;
  payload: RawUtf8;
begin
  NewBindingPipeline(2, 8, 0);
  // native bind refusal: the registry (which acquired the entry BEFORE
  // the native call) rolls back and Bind raises at the call site; a
  // refused bind retains nothing native-side, so nothing C can see is
  // ever freed
  ScriptBindResults([WEBVIEW_ERROR_INVALID_STATE]);
  raised := False;
  try
    FBinding.Bind('roll', TPWebEnvelopeHandler.Create(FSource));
  except
    on E: EWebViewError do
      raised := True;
  end;
  Check(raised, 'failed native bind raises at the call site');
  Check(not FakeHasBinding('roll'), 'nothing registered native-side');
  // the registry rolled back: the same name binds cleanly afterwards
  FBinding.Bind('roll', TPWebEnvelopeHandler.Create(FSource));
  FireBound('roll', 'rb1', '["pweb.echo",{"r":1}]');
  Check(WaitReturnCount('rb1', 1, 5000), 'rolled-back name rebinds and works');
  Check(FakeLastReturn('rb1', status, payload));
  CheckEqual(status, 0);
  CheckEqual(payload, '{"r":1}');
  // upstream duplicate refusal rolls back identically
  ScriptBindResults([WEBVIEW_ERROR_DUPLICATE]);
  raised := False;
  try
    FBinding.Bind('dup2', TPWebEnvelopeHandler.Create(FSource));
  except
    on E: EPWebBindingError do
      raised := True;
  end;
  Check(raised, 'upstream duplicate refusal raises EPWebBindingError');
  Check(not FakeHasBinding('dup2'), 'duplicate refusal registered nothing');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.RequestSizeLimitsAndCeiling; // corrective size matrix
var
  req, big, payload: RawUtf8;
  limit, status, invokesBefore: Integer;
begin
  // the bounded scan primitive itself: never reads past its bound
  CheckEqual(PWebBoundedStrLen(nil, 10), 0, 'nil scans to 0');
  CheckEqual(PWebBoundedStrLen(PAnsiChar(RawUtf8('abc')), 10), 3, 'plain length');
  CheckEqual(PWebBoundedStrLen(PAnsiChar(RawUtf8('abc')), 4), 3,
    'NUL found exactly at the last scanned byte');
  CheckEqual(PWebBoundedStrLen(PAnsiChar(RawUtf8('abc')), 3), -1,
    'no NUL within the bound reports oversize (-1)');
  CheckEqual(PWebBoundedStrLen(PAnsiChar(RawUtf8('abc')), 1), -1);
  CheckEqual(PWebBoundedStrLen(PAnsiChar(RawUtf8('abc')), 0), -1,
    'degenerate bound 0 reports -1, never a false validity');
  CheckEqual(PWebBoundedStrLen(nil, 0), 0, 'nil wins over the bound');
  // the default path of the size clamp: MaxRequestBytes = 0 falls back
  // to the documented default cap
  NewBindingPipeline(2, 8, 0);
  CheckEqual(FBinding.EffectiveMaxRequestBytes,
    PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES,
    'MaxRequestBytes=0 yields the default cap');
  EndBindingPipeline;
  // a request exactly AT the effective limit is accepted and enqueued
  req := '["pweb.echo",{"p":"xy"}]';
  limit := Length(req);
  NewBindingPipeline(2, 8, limit);
  CheckEqual(FBinding.EffectiveMaxRequestBytes, limit,
    'small configured limit is the effective limit');
  FireBound('__pweb_invoke', 's1', req);
  Check(WaitReturnCount('s1', 1, 5000), 'request AT the limit accepted');
  Check(FakeLastReturn('s1', status, payload));
  CheckEqual(status, 0, 'at-limit request resolved');
  CheckEqual(payload, '{"p":"xy"}');
  CheckEqual(FBridge.InvokeCount, 1, 'at-limit request reached the bridge');
  invokesBefore := FBridge.InvokeCount;
  // one byte over: rejected synchronously in the raw callback - before
  // the handler, before TryEnqueue, without a full copy (the bounded
  // scan stops at limit + 1 bytes)
  FireBound('__pweb_invoke', 's2', '["pweb.echo",{"p":"xyz"}]');
  CheckEqual(FakeReturnCount('s2'), 1, 'limit+1 rejected synchronously');
  Check(FakeLastReturn('s2', status, payload));
  CheckNotEqual(status, 0, 'reject arm');
  CheckEqual(PayloadCode(payload), 'invalid_request');
  CheckEqual(FBridge.InvokeCount, invokesBefore, 'oversize never reached the bridge');
  CheckEqual(FRecPolicy.SeenCount, 1, 'oversize never reached the policy');
  EndBindingPipeline;
  // configuration CANNOT bypass the 16 MiB implementation ceiling
  NewBindingPipeline(2, 8, PWEB_BINDING_HARD_MAX_REQUEST_BYTES * 2);
  CheckEqual(FBinding.EffectiveMaxRequestBytes,
    PWEB_BINDING_HARD_MAX_REQUEST_BYTES,
    'effective limit clamped to the hard ceiling');
  SetLength(big, PWEB_BINDING_HARD_MAX_REQUEST_BYTES + 64);
  FillChar(pointer(big)^, Length(big), Ord('x'));
  big[1] := '['; // plausible prefix; bytes past the scan bound never read
  FireBound('__pweb_invoke', 'c1', big);
  CheckEqual(FakeReturnCount('c1'), 1, 'over-ceiling rejected synchronously');
  Check(FakeLastReturn('c1', status, payload));
  CheckEqual(PayloadCode(payload), 'invalid_request');
  CheckEqual(FBridge.InvokeCount, 0, 'over-ceiling never reached the bridge');
  EndBindingPipeline;
end;

procedure TTestWebViewBinding.BoundedScanGuardPage; // corrective re-review C1 + C2
var
  si: TSystemInfo;
  base: Pointer;
  pageSize: PtrUInt;
  req: PAnsiChar;
  window: PtrInt;
  status, seqBefore: Integer;
  payload: RawUtf8;
  old: DWORD;
  bigId: RawUtf8;
begin
  NewBindingPipeline(2, 8, 64); // effective limit 64 -> scan window 65
  // C2: an id over the implementation cap carries no correlation and
  // must be dropped inertly by the bounded id scan - no enqueue, no
  // native call of any kind (the fire is synchronous)
  SetLength(bigId, PWEB_BINDING_MAX_ID_BYTES + 10);
  FillChar(pointer(bigId)^, Length(bigId), Ord('i'));
  seqBefore := FakeMaxSeq;
  FireBound('__pweb_invoke', bigId, '["pweb.echo",{}]');
  CheckEqual(FakeMaxSeq, seqBefore, 'oversize id produced no native call');
  CheckEqual(FBridge.InvokeCount, 0, 'oversize id was never enqueued');
  // C1: guard-page proof of the bounded-scan/copy-after-check property.
  // The request bytes end flush against a PAGE_NOACCESS page with no
  // NUL anywhere accessible: an unbounded StrLen - or a full copy
  // before the size check - reads into the guard page and faults
  // loudly (surfacing as internal_error at best, a crash at worst);
  // ONLY the bounded scan (limit + 1 bytes, all accessible) passes
  // and rejects invalid_request without ever touching the guard.
  GetSystemInfo(si);
  pageSize := si.dwPageSize;
  window := 65; // exactly limit + 1 accessible bytes, none of them NUL
  base := VirtualAlloc(nil, pageSize * 2, MEM_COMMIT or MEM_RESERVE,
    PAGE_READWRITE);
  Check(base <> nil, 'VirtualAlloc succeeded');
  if base <> nil then
  try
    Check(VirtualProtect(Pointer(PtrUInt(base) + pageSize), pageSize,
      PAGE_NOACCESS, @old), 'guard page protected');
    req := PAnsiChar(PtrUInt(base) + pageSize - PtrUInt(window));
    FillChar(req^, window, Ord('x'));
    FireBoundPtr('__pweb_invoke', 'gp1', req);
    CheckEqual(FakeReturnCount('gp1'), 1, 'guarded oversize rejected synchronously');
    Check(FakeLastReturn('gp1', status, payload));
    CheckEqual(PayloadCode(payload), 'invalid_request',
      'bounded scan rejected without touching the guard page');
    CheckEqual(FBridge.InvokeCount, 0, 'guarded request never reached the bridge');
  finally
    VirtualFree(base, 0, MEM_RELEASE);
  end;
  EndBindingPipeline;
end;

initialization
  FakeLock := TCriticalSection.Create;

finalization
  FakeLock.Free;

end.
