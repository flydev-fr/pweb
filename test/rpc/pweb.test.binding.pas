{
  pweb.test.binding - mormot.core.test cases for the CAP-2 binding
  domain: envelope parsing/malformed rejection, pre-queue rejection
  mapping, size limits + hard ceiling + guard-page bounded-scan proof,
  bind refusals/rollback, raising-handler barrier, id handling, and
  context propagation through the binding pipeline.

  Everything here is HEADLESS: the binding cases drive real
  enqueue/complete/close/destroy behavior against injectable recording
  fake native functions - no window, and no real native entry point is
  ever CALLED by these cases. Note the loader still requires
  webview.dll BESIDE the test executable: this unit statically imports
  pweb.lib.webview (the binding's production defaults), so the DLL
  must be staged even though it stays idle - CI copies it next to
  pwebtests.exe.

  This unit is also the ONE home of the binding-side shared fixtures -
  the recording fake native functions with their scripting helpers,
  the deviant test handlers, and the TPWebBindingFixture base class -
  exported from the interface for the lifecycle test unit; no
  duplication anywhere.

  The mandated CAP-2 tests map onto the published methods below; each
  method's header comment carries its number(s). }

{$I mormot.defines.inc}

unit pweb.test.binding;

interface

uses
  {$ifdef OSWINDOWS}
  windows, // VirtualAlloc/VirtualProtect for the guard-page scan test
  {$endif OSWINDOWS}
  {$ifdef UNIX}
  // mmap/mprotect: the same guard-page proof on every POSIX target.
  //
  // CAP-7M1: this guard was {$ifdef LINUX} and therefore gave Darwin nothing,
  // so the unit failed to compile there with eight "Identifier not found"
  // errors the moment the suite was first built for macOS. Nothing about the
  // branch below is Linux-specific: FPC declares FpMMap/FpMProtect/FpMUnmap
  // in the BaseUnix interface for all POSIX targets (rtl/unix/bunxh.inc) and
  // implements them for BSD/Darwin (rtl/bsd/ossysc.inc), and MAP_PRIVATE,
  // MAP_ANONYMOUS and the PROT_* set are defined in rtl/bsd/ostypes.inc. The
  // symbol was simply too narrow.
  baseunix,
  {$endif UNIX}
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
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.lib.webview,
  pweb.lib.webview.errors, // EWebViewError for the bind-rollback case
  pweb.test.scheduler;     // shared sinks/policies/TestContext fixture home

type
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

  /// shared binding-side pipeline fixture: TWebViewBinding over the
  // injectable fake native functions, fronting a scheduler source with
  // a recording allow-policy. Derived by the binding cases here and
  // the binding-lifecycle cases in pweb.test.lifecycle - the ONE home
  // of this fixture.
  TPWebBindingFixture = class(TSynTestCase)
  protected
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
      AMaxRequestBytes: Integer; AWorkers: Integer = 4);
    procedure EndBindingPipeline;
    function WaitBridgeCurrent(AValue, ATimeoutMs: Integer): Boolean;
    function WaitReturnCount(const AId: RawUtf8;
      AValue, ATimeoutMs: Integer): Boolean;
  end;

  /// TWebViewBinding over injectable fake native functions
  // (mandated tests 1, 19 + pre-queue rejection mapping and the
  // corrective bind-rollback/size/guard-page cases)
  TTestWebViewBinding = class(TPWebBindingFixture)
  published
    procedure MalformedEnvelopeRejectedPreEnqueue;
    procedure PreQueueSyncRejectionMapping;
    procedure BindRefusals;
    procedure RaisingHandlerBarrier;
    procedure ContextReachesPolicyAndBridge;
    procedure CallbackDoesNoSynchronousServiceExecution;
    procedure BindRollbackOnNativeFailure;
    procedure RequestSizeLimitsAndCeiling;
    procedure BoundedScanGuardPage;
  end;

{ ------- recording fake native functions + scripting helpers -------
  Shared with pweb.test.lifecycle; state is unit-global and reset by
  every NewBindingPipeline. }

var
  { total native unbind attempts recorded by the fake }
  FakeUnbinds: Integer;
  FakeReturnGateOpen: LongInt;  // released by the test (polled flag)
  FakeReturnEntered: LongInt;   // set when a blocked return is inside

{ scriptable native results for the corrective fault-injection cases.
  Unbind failures are keyed by NAME (never by call order, so tests do
  not depend on registry iteration order) and are persistent until
  cleared; a scripted unbind result ALWAYS leaves the fake registry
  untouched - a failure means the native side still holds the
  callback userdata. To simulate a genuinely-absent native binding use
  RemoveFakeBinding, which detaches the fake registry record itself -
  a later unbind then reports NOT_FOUND naturally. Bind results are a
  FIFO queue: a scripted non-OK bind registers nothing and retains
  nothing. }
procedure ScriptUnbindFailureFor(const AName: RawUtf8;
  ACode: webview_error_t);
procedure ClearUnbindFailure;
procedure RemoveFakeBinding(const AName: RawUtf8);
procedure ScriptBindResults(const ACodes: array of webview_error_t);
procedure SetFakeReturnBlock(AValue: Boolean);

function FakeReturnCount(const AId: RawUtf8): Integer;
function FakeLastReturn(const AId: RawUtf8; out AStatus: Integer;
  out APayload: RawUtf8): Boolean;
function FakeMaxSeq: Integer;
function FakeHasBinding(const AName: RawUtf8): Boolean;

{ invoke a recorded bound callback with a RAW request pointer - the
  guard-page test needs full control over the request memory layout }
procedure FireBoundPtr(const AName, AId: RawUtf8; AReq: PAnsiChar);
{ invoke a recorded bound callback exactly as upstream JS would }
procedure FireBound(const AName, AId, AReq: RawUtf8);

{ crude "code" member extractor for envelope assertions }
function PayloadCode(const APayload: RawUtf8): RawUtf8;

implementation

{ ---------------- shared handler helpers (no assertions) ---------------- }

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
  FakeReturnBlock: Boolean;
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

procedure FireBound(const AName, AId, AReq: RawUtf8);
begin
  FireBoundPtr(AName, AId, PAnsiChar(pointer(AReq)));
end;

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

{ ---------------- TPWebBindingFixture ---------------- }

procedure TPWebBindingFixture.NewBindingPipeline(AMaxConcurrent, AMaxQueue,
  AMaxRequestBytes: Integer; AWorkers: Integer);
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
  FScheduler := TInvocationScheduler.Create(FPolicyRef, FBridgeRef, AWorkers);
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

procedure TPWebBindingFixture.EndBindingPipeline;
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

function TPWebBindingFixture.WaitBridgeCurrent(AValue,
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

function TPWebBindingFixture.WaitReturnCount(const AId: RawUtf8;
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

{ ---------------- TTestWebViewBinding ---------------- }

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

{ Guard-page plumbing. The PROOF below is one piece of platform-neutral
  test logic; only the three primitives it needs - reserve two pages, make
  the second one inaccessible, release - are per-OS. CAP-7L adds the POSIX
  implementation rather than skipping the case on Linux: a bounded-scan
  regression would be just as fatal there, and mmap/mprotect(PROT_NONE)
  faults exactly as loudly as PAGE_NOACCESS. }

{$ifdef OSWINDOWS}

function GuardPageSize: PtrUInt;
var
  si: TSystemInfo;
begin
  GetSystemInfo(si{%H-});
  Result := si.dwPageSize;
end;

function GuardPageAlloc(ASize: PtrUInt): Pointer;
begin
  Result := VirtualAlloc(nil, ASize, MEM_COMMIT or MEM_RESERVE,
    PAGE_READWRITE);
end;

function GuardPageProtect(AAt: Pointer; ASize: PtrUInt): Boolean;
var
  old: DWORD;
begin
  Result := VirtualProtect(AAt, ASize, PAGE_NOACCESS, @old{%H-});
end;

procedure GuardPageFree(ABase: Pointer; ASize: PtrUInt);
begin
  VirtualFree(ABase, 0, MEM_RELEASE);
end;

{$else}

function GuardPageSize: PtrUInt;
begin
  // mORMot resolves this from libc getpagesize()/AT_PAGESZ at startup, so
  // no extra libc declaration is needed for the POSIX branch
  Result := mormot.core.os.SystemInfo.dwPageSize;
end;

function GuardPageAlloc(ASize: PtrUInt): Pointer;
begin
  Result := FpMMap(nil, ASize, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Result = Pointer(-1) then
    Result := nil;
end;

function GuardPageProtect(AAt: Pointer; ASize: PtrUInt): Boolean;
begin
  Result := FpMProtect(AAt, ASize, PROT_NONE) = 0;
end;

procedure GuardPageFree(ABase: Pointer; ASize: PtrUInt);
begin
  FpMUnmap(ABase, ASize);
end;

{$endif OSWINDOWS}

procedure TTestWebViewBinding.BoundedScanGuardPage; // corrective re-review C1 + C2
var
  base: Pointer;
  pageSize: PtrUInt;
  req: PAnsiChar;
  window: PtrInt;
  status, seqBefore: Integer;
  payload: RawUtf8;
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
  // The request bytes end flush against an INACCESSIBLE page with no
  // NUL anywhere accessible: an unbounded StrLen - or a full copy
  // before the size check - reads into the guard page and faults
  // loudly (surfacing as internal_error at best, a crash at worst);
  // ONLY the bounded scan (limit + 1 bytes, all accessible) passes
  // and rejects invalid_request without ever touching the guard.
  pageSize := GuardPageSize;
  Check(pageSize > 0, 'page size resolved');
  window := 65; // exactly limit + 1 accessible bytes, none of them NUL
  base := GuardPageAlloc(pageSize * 2);
  Check(base <> nil, 'two-page reservation succeeded');
  if base <> nil then
  try
    Check(GuardPageProtect(Pointer(PtrUInt(base) + pageSize), pageSize),
      'guard page protected');
    req := PAnsiChar(PtrUInt(base) + pageSize - PtrUInt(window));
    FillChar(req^, window, Ord('x'));
    FireBoundPtr('__pweb_invoke', 'gp1', req);
    CheckEqual(FakeReturnCount('gp1'), 1, 'guarded oversize rejected synchronously');
    Check(FakeLastReturn('gp1', status, payload));
    CheckEqual(PayloadCode(payload), 'invalid_request',
      'bounded scan rejected without touching the guard page');
    CheckEqual(FBridge.InvokeCount, 0, 'guarded request never reached the bridge');
  finally
    GuardPageFree(base, pageSize * 2);
  end;
  EndBindingPipeline;
end;

initialization
  FakeLock := TCriticalSection.Create;

finalization
  FakeLock.Free;

end.
