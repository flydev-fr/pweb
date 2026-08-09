{
  pweb.test.rpc - mormot.core.test cases for the CAP-2 invocation
  pipeline: scheduler, policy call site, dummy bridge, WebView binding.

  Everything here is HEADLESS: the scheduler cases never touch any
  pweb.webview.* unit (proving source-genericity at runtime, on top of
  the CI webview-free compile of pweb.rpc.scheduler.pas), and the
  binding cases drive real enqueue/complete/close/destroy races against
  injectable recording fake native functions - no window, no
  webview.dll needed.

  The twenty mandated CAP-2 tests map onto the published methods below;
  each method's header comment carries its number(s). }

{$I mormot.defines.inc}

unit pweb.test.rpc;

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.scheduler,
  pweb.rpc.bridge.dummy,
  pweb.capabilities,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.lib.webview;

type
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
  end;

  /// TWebViewBinding over injectable fake native functions
  // (mandated tests 1, 17, 18, 19 + pre-queue rejection mapping)
  TTestWebViewBinding = class(TSynTestCase)
  private
    FBridge: TDummyInvocationBridge;
    FBridgeRef: IInvocationBridge;
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
    procedure CallbackDoesNoSynchronousServiceExecution;
    procedure LateCompletionAfterClosedTouchesNothing;
    procedure LeasePreventsDestroyReturnRace;
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

  TRecordingAllowPolicy = class(TInterfacedObject, ICapabilityPolicy)
  private
    FLock: TCriticalSection;
    FMethods: array of Utf8String;
  public
    constructor Create;
    destructor Destroy; override;
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
    function SeenCount: Integer;
    function Seen(AIndex: Integer): Utf8String;
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

procedure ResetFakes;
begin
  FakeLock.Enter;
  try
    SetLength(FakeReturns, 0);
    SetLength(FakeBindings, 0);
    FakeSeq := 0;
    FakeUnbinds := 0;
    FakeReturnBlock := False;
  finally
    FakeLock.Leave;
  end;
  InterlockedExchange(FakeReturnGateOpen, 0);
  InterlockedExchange(FakeReturnEntered, 0);
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

procedure SetFakeReturnBlock(AValue: Boolean);
begin
  FakeLock.Enter;
  FakeReturnBlock := AValue;
  FakeLock.Leave;
end;

{ invoke a recorded bound callback exactly as upstream JS would }
procedure FireBound(const AName, AId, AReq: RawUtf8);
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
    fn(PAnsiChar(pointer(AId)), PAnsiChar(pointer(AReq)), arg);
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
  sink := TTestCompletion.Create;
  sinkRef := sink;
  // TryEnqueue is the single method grammar gate: every rejection is
  // synchronous perInvalidRequest and the sink is never touched
  Check(FSource.TryEnqueue(Ctx, '', '{}', sinkRef) = perInvalidRequest, 'empty method');
  Check(FSource.TryEnqueue(Ctx, 'nodots', '{}', sinkRef) = perInvalidRequest, 'no Service.Method shape');
  Check(FSource.TryEnqueue(Ctx, '.echo', '{}', sinkRef) = perInvalidRequest, 'leading dot');
  Check(FSource.TryEnqueue(Ctx, 'pweb.', '{}', sinkRef) = perInvalidRequest, 'trailing dot');
  Check(FSource.TryEnqueue(Ctx, 'a..b', '{}', sinkRef) = perInvalidRequest, 'empty segment');
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
  FSource.Close; // completes the in-flight invocation as cancelled NOW
  Check(sink.WaitDone(5000), 'cancelled completion delivered');
  Check(sink.First.Kind = prkError);
  Check(sink.First.Error.Code = pecCancelled, 'close cancels in-flight');
  Check(FScheduler.TryGetSourceCounts(FSource, q, act), 'counts available');
  CheckEqual(q, 0, 'no queued after close');
  CheckEqual(act, 0, 'slot released exactly once at completion');
  // now let the blocked bridge finish: its late completion attempt must
  // die at the gate WITHOUT touching the already-released slot
  FBridge.OpenGate;
  Sleep(200);
  CheckEqual(sink.CompleteCount, 1, 'late result died at the gate');
  Check(FScheduler.TryGetSourceCounts(FSource, q, act));
  CheckEqual(q, 0, 'queued count still consistent');
  CheckEqual(act, 0, 'active count not double-released (never negative)');
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
  Check(FScheduler.TryGetSourceCounts(FSource, q, act));
  CheckEqual(q + act, 0, 'no slots leaked');
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
  FPolicyRef := TAllowAllCapabilityPolicy.Create;
  FScheduler := TInvocationScheduler.Create(FPolicyRef, FBridgeRef, 4);
  FSchedulerRef := FScheduler;
  lim.MaxConcurrent := AMaxConcurrent;
  lim.MaxQueueSize := AMaxQueue;
  FSource := FScheduler.RegisterSource(lim);
  opts := Default(TPWebWebViewBindingOptions);
  opts.ContextTemplate := TestContext;
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
  status: Integer;
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

initialization
  FakeLock := TCriticalSection.Create;

finalization
  FakeLock.Free;

end.
