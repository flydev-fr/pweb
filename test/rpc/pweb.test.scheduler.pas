{
  pweb.test.scheduler - mormot.core.test cases for the CAP-2 scheduler
  domain: enqueue/canonicalization gate, policy -> bridge order,
  backpressure/concurrency, exactly-once completion and slot release,
  non-WebView source genericity, context snapshot at scheduler level.

  This unit is deliberately WEBVIEW-FREE: it never references any
  pweb.webview.* or pweb.lib.webview* unit, proving source-genericity
  at runtime on top of the CI webview-free compile of
  pweb.rpc.scheduler.pas.

  It is also the ONE home of the scheduler-side shared fixtures
  (TTestCompletion, the test policies, TestContext and the
  TPWebSchedulerFixture base class), exported from the interface for
  the binding and lifecycle test units - no duplication.

  The mandated CAP-2 tests map onto the published methods below; each
  method's header comment carries its number(s). }

{$I mormot.defines.inc}

unit pweb.test.scheduler;

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
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.bridge.dummy,
  pweb.capabilities;

type
  { NOTE: no FPC syncobjs event anywhere in these test units -
    TEventObject/TSimpleEvent.WaitFor returns wrError immediately on
    the pinned FPC 3.2.2 Windows toolchain (measured); waits are short
    polled loops }
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

  /// shared scheduler-side pipeline fixture: scheduler + policy call
  // site + dummy bridge over a plain non-WebView test source. Derived
  // by the scheduler cases here and the source-lifecycle cases in
  // pweb.test.lifecycle - the ONE home of this fixture.
  TPWebSchedulerFixture = class(TSynTestCase)
  protected
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
  end;

  /// scheduler + policy call site + dummy bridge, over a plain
  // non-WebView test source (mandated tests 2..13 and 20)
  TTestInvocationScheduler = class(TPWebSchedulerFixture)
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
    procedure NonWebViewTestSource;
    procedure ContextSnapshotIndependence;
  end;

/// the standard native-built test context (never from any JS payload)
function TestContext: TInvocationContext;

implementation

{ ---------------- shared helpers (no assertions in here) ---------------- }

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

function TestContext: TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := 'w1';
  Result.PrincipalId := 'window:w1';
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
end;

{ ---------------- TPWebSchedulerFixture ---------------- }

procedure TPWebSchedulerFixture.NewPipeline(AMaxConcurrent,
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

procedure TPWebSchedulerFixture.EndPipeline;
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

function TPWebSchedulerFixture.Ctx: TInvocationContext;
begin
  Result := TestContext;
end;

function TPWebSchedulerFixture.WaitBridgeCurrent(AValue,
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

{ ---------------- TTestInvocationScheduler ---------------- }

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

end.
