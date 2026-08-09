{
  pweb.test.lifecycle - mormot.core.test cases for the CAP-2
  lifecycle/teardown domain, from both the scheduler side (quiesce
  refuses/cancels, close-while-running) and the binding side (unbind
  lifecycle and failure retention, close retry after a failed unbind,
  late completion after Closed, lease/destroy race, destroy
  quarantine).

  All cases are HEADLESS and reuse the shared fixtures from their
  single homes: TPWebSchedulerFixture (+ sinks/policies/TestContext)
  from pweb.test.scheduler and TPWebBindingFixture (+ recording fake
  natives and scripting helpers) from pweb.test.binding - nothing is
  duplicated here.

  The mandated CAP-2 tests map onto the published methods below; each
  method's header comment carries its number(s). }

{$I mormot.defines.inc}

unit pweb.test.lifecycle;

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.bridge.dummy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.lib.webview,
  pweb.test.scheduler,
  pweb.test.binding;

type
  /// source-lifecycle semantics over a plain non-WebView test source
  // (mandated tests 14, 15, 16)
  TTestSourceLifecycle = class(TPWebSchedulerFixture)
  published
    procedure QuiesceRefusesNew;
    procedure QuiesceCancelsQueued;
    procedure CloseWhileRunningQuiescesFirst;
  end;

  /// binding-side teardown: unbind ownership, close retry, late
  // completion, lease/destroy race, destructor quarantine
  // (mandated tests 17, 18 + corrective scenarios A-C and the
  // release-after-failed-detach case)
  TTestBindingLifecycle = class(TPWebBindingFixture)
  published
    procedure UnbindLifecycle;
    procedure UnbindFailureKeepsUserdataSafe;
    procedure CloseRetryAfterUnbindFailure;
    procedure LateCompletionAfterClosedTouchesNothing;
    procedure LeasePreventsDestroyReturnRace;
    procedure DestroyQuarantinesUndetachedEntry;
  end;

implementation

{ ---------------- TTestSourceLifecycle ---------------- }

procedure TTestSourceLifecycle.QuiesceRefusesNew; // mandated test 14
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

procedure TTestSourceLifecycle.QuiesceCancelsQueued; // mandated test 15
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

procedure TTestSourceLifecycle.CloseWhileRunningQuiescesFirst; // mandated test 16
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

{ ---------------- TTestBindingLifecycle ---------------- }

procedure TTestBindingLifecycle.UnbindLifecycle;
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

procedure TTestBindingLifecycle.UnbindFailureKeepsUserdataSafe; // corrective A + B
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

procedure TTestBindingLifecycle.CloseRetryAfterUnbindFailure; // corrective C
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

procedure TTestBindingLifecycle.LateCompletionAfterClosedTouchesNothing; // mandated test 17
var
  status, seqAtClose: Integer;
  payload: RawUtf8;
  lim: TPWebSourceLimits;
  sentinelSrc: IInvocationSource;
  sentinel: TTestCompletion;
  sentinelRef: IInvocationCompletion;
begin
  // ONE worker: the sentinel invocation below can then only execute
  // after that worker has fully finished the late1 item - INCLUDING
  // its late CompleteOnce attempt, the last step of ExecuteItem -
  // giving the trailing negative assertions positive synchronization
  // instead of a sleep
  NewBindingPipeline(1, 4, 0, {AWorkers=}1);
  FBridge.CloseGate;
  // test.blockhard deliberately IGNORES the cancellation token: the
  // in-flight bridge call must NOT complete early on Quiesce, so the
  // terminal cancelled completion is deterministically delivered by
  // Close itself (lease still open) and the worker's own completion
  // attempt is deterministically LATE. (The token-observing test.block
  // raced Close here: the worker's early-cancelled completion could
  // win the exactly-once gate first, and its delivery then died -
  // correctly, per the documented post-close lease rule - at the
  // shutter, leaving no return at all: the scenario premise diverged.)
  FireBound('__pweb_invoke', 'late1', '["test.blockhard",{}]');
  Check(WaitBridgeCurrent(1, 5000), 'invocation in flight');
  FBinding.Close; // quiesce -> unbind -> source close -> lease shutter
  Check(FBinding.State = pssClosed, 'binding closed');
  Check(FakeUnbinds > 0, 'JS-side unbind happened during teardown');
  // the in-flight invocation was completed (cancelled) on the way to
  // Closed, while the sink could still deliver - deterministic: the
  // worker is still gated inside the bridge and cannot compete
  CheckEqual(FakeReturnCount('late1'), 1, 'terminal cancelled return delivered');
  Check(FakeLastReturn('late1', status, payload));
  CheckEqual(PayloadCode(payload), 'cancelled');
  seqAtClose := FakeMaxSeq;
  // sentinel fence on a SECOND, still-running source of the same
  // scheduler: enqueued while the single worker is still blocked, it
  // can only complete after the worker finished late1's ExecuteItem -
  // whose final step is exactly the late completion attempt under test
  lim.MaxConcurrent := 1;
  lim.MaxQueueSize := 4;
  sentinelSrc := FScheduler.RegisterSource(lim);
  sentinel := TTestCompletion.Create;
  sentinelRef := sentinel;
  Check(sentinelSrc.TryEnqueue(TestContext, 'pweb.echo', '{}', sentinelRef) = perAccepted,
    'sentinel enqueued behind the blocked worker');
  // release the still-running bridge: its late completion attempt must
  // die at the exactly-once gate without touching the native handle
  FBridge.OpenGate;
  Check(sentinel.WaitDone(5000), 'sentinel completed: the late attempt already ran');
  CheckEqual(FakeMaxSeq, seqAtClose, 'no native call of any kind after Closed');
  CheckEqual(FakeReturnCount('late1'), 1, 'still exactly one return');
  sentinelSrc.Close;
  EndBindingPipeline;
end;

procedure TTestBindingLifecycle.LeasePreventsDestroyReturnRace; // mandated test 18
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

procedure TTestBindingLifecycle.DestroyQuarantinesUndetachedEntry; // corrective: release after failed detach
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

end.
