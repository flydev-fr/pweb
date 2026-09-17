program socketstarve;

{ CAP-15C MEASURED THE STARVATION; CAP-16 CLOSES IT, AND THIS PROVES IT.

  CAP-15C's `pweb.socketReceive` was a bounded long-poll that waited ON THE
  SCHEDULER WORKER running it, and this program measured what that meant
  under the ratified host defaults - four workers, four simultaneous
  invocations, a queue of 32: with four quiet sockets parked, an unrelated
  invocation waited 24 984.7 ms on Windows and 24 999.1 ms on Linux for a
  poll to give its worker back (ledger 15CS-1). CAP-16 Checkpoint 1 measured
  further, with this same program before it changed, that raising EITHER the
  workers or the slots alone to eight leaves N = 4 starved - both bounds bind.

  CAP-16 retired the wait. A receive answers what is queued at once, a
  nonzero `waitMs` is refused, and a page learns that something is queued
  from the signal channel's window-scoped `pweb.socket` topic. So this
  program keeps its composition, its host numbers and its N set - one more
  N, eight - and changes only the loop it drives, which is now the SDK's:

    1. open N sockets through the scheduler, one after another - the first
       on the witness's /echo route, the rest on /idle. The SOCKET bound is
       raised to eight through TPWebSocketBounds so that N = 8 is eight real
       sockets; the host bound stays four (PWEB_SOCKET_MAX_SOCKETS);
    2. take each socket's `open` event with one receive, as the SDK's first
       receive does - it is there at once, because nothing waits;
    3. subscribe the window to `pweb.socket` through the signal channel and
       leave every socket QUIET: the scheduler must hold NOTHING in flight
       and nothing queued - a quiet socket is no invocation at all;
    4. enqueue `CalculatorService.Add` with a = 20 and b = 22, and time it
       from its own enqueue to its completion;
    5. the loop still delivers: send one text on the /echo socket, wait for
       the channel to ask for a drain (the page's signal), drain it, and
       receive the echo - the round trip a page makes;
    6. a receive with `waitMs` 25000 is refused invalid_request;
    7. tear down in the host's order - the channel's BeforeDrain, which hands
       the door its own, then the scheduler's Shutdown.

  The worker count, the slot count and the queue bound are NOT typed here.
  test/cap15c/run_cap15c_gates.ps1 reads them out of PWebDefaultHostOptions
  and passes them in, exactly as before.

  ONE ROW PER N, for N = 0, 3, 4, 5 and 8, each on a FRESH composition:

    served latency_ms=<ms> result=<r> opened=<o>/<N> open_refused=<cat>
      in_flight=<active+queued> socket_bound=8 waitms=<verdict>
      echo=<signalled|missing|not_applicable>

  The runner GATES the answer now: every N served in under 5 ms with
  nothing in flight. The instrument's own validity - sockets that should have
  opened, the control, 42 - is still its own exit code.

  Usage:
    socketstarve --port=<plain ws port> --workers=<n> --slots=<n>
                 --queue=<n> --out=<json> }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
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
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.rpc.signal,
  pweb.rpc.socket,
  pweb.rpc.socket.mormot,
  pweb.capabilities.policy;

const
  APP_METHOD_ADD = 'CalculatorService.Add';
  APP_CAP_ADD = 'calculator.add';
  /// the socket bound this instrument runs with, so N = 8 is eight sockets
  STARVE_SOCKET_BOUND = 8;
  /// how long an open or a receive may take before the instrument gives up;
  // the connect deadline is the door's own wall-clock bound on an open
  STEP_BOUND_MS = PWEB_SOCKET_CONNECT_DEADLINE_MS + 5000;
  /// how long the Add may stay outstanding before it is typed not_answered -
  // far past anything a served Add takes, far short of CAP-15C's 25 s park
  ADD_BOUND_MS = 10000;
  /// how long the echo may take to be signalled
  ECHO_BOUND_MS = 5000;
  /// the retired long-poll bound, sent once to see it refused
  RETIRED_WAIT_MS = 25000;

type
  ICalculatorService = interface(IInvokable)
    ['{3A1F6C52-7B0E-4E3D-9A55-2C8D4F17B6A1}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { One invocation's sink: the result, and the instant it arrived. The wait
    POLLS the flag rather than blocking on an event object: the scheduler's
    own notes record FPC 3.2.2's event WaitFor returning early on this
    toolchain, and the instant that matters is taken inside Complete, so the
    polling cadence cannot move a measurement. }
  TCompletion = class(TInterfacedObject, IInvocationCompletion)
  private
    FResult: TPWebInvocationResult;
    FAtUs: Int64;
    FSet: LongInt;
  public
    procedure Complete(const AResult: TPWebInvocationResult);
    function WaitDone(Ms: Integer): Boolean;
    function Done: Boolean;
    property Outcome: TPWebInvocationResult read FResult;
    property AtUs: Int64 read FAtUs;
  end;

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  Result := a + b;
end;

function NowUs: Int64;
begin
  QueryPerformanceMicroSeconds(Result);
end;

procedure TCompletion.Complete(const AResult: TPWebInvocationResult);
begin
  if InterlockedCompareExchange(FSet, 1, 0) <> 0 then
    exit;
  FAtUs := NowUs;
  FResult := AResult;
  // published LAST: a reader that sees the flag sees the result
  InterlockedExchange(FSet, 2);
end;

function TCompletion.WaitDone(Ms: Integer): Boolean;
var
  deadline: Int64;
begin
  deadline := GetTickCount64 + Ms;
  repeat
    if Done then
      exit(True);
    Sleep(1);
  until GetTickCount64 > deadline;
  Result := Done;
end;

function TCompletion.Done: Boolean;
begin
  Result := PWebAtomicRead(FSet) = 2;
end;

var
  Port: Integer = 0;
  Workers: Integer = 0;
  Slots: Integer = 0;
  QueueBound: Integer = 0;
  OutPath: RawUtf8 = '';
  Rows: TRawUtf8DynArray;
  Failures: Integer = 0;
  /// the channel's view, played by this program: a drain request is the
  // page's signal
  DrainAsked: LongInt = 0;
  Scripts: LongInt = 0;

function ViewDispatch(const Window: RawUtf8): Boolean;
begin
  InterlockedIncrement(DrainAsked);
  Result := True;
end;

procedure ViewEval(const Window: RawUtf8; const Script: RawUtf8);
begin
  InterlockedIncrement(Scripts);
end;

procedure Row(const Name, Value: RawUtf8);
begin
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)] := '  ' + QuotedStrJson(Name) + ': ' + QuotedStrJson(Value);
  WriteLn('[CAP-15C] ', Name, ' = ', Value);
  Flush(Output);
end;

procedure Require(Ok: Boolean; const Why: RawUtf8);
begin
  if Ok then
    exit;
  Inc(Failures);
  WriteLn(StdErr, '[CAP-15C] FAIL: ', Why);
  Flush(StdErr);
end;

function Verdict(const R: TPWebInvocationResult): RawUtf8;
var
  doc: variant;
begin
  if R.Kind = prkSuccess then
    exit('success');
  Result := RawUtf8(PWEB_ERROR_CODE_TEXT[R.Error.Code]);
  if (R.Error.Code = pecServiceError) and (R.Error.Data <> '') then
  begin
    doc := _JsonFast(RawUtf8(R.Error.Data));
    if _Safe(doc)^.U['category'] <> '' then
      Result := Result + ':' + _Safe(doc)^.U['category'];
  end;
end;

function IdOf(const R: TPWebInvocationResult): RawUtf8;
var
  doc: variant;
begin
  Result := '';
  if R.Kind <> prkSuccess then
    exit;
  doc := _JsonFast(RawUtf8(R.Value));
  Result := _Safe(doc)^.U['id'];
end;

function EventTypes(const R: TPWebInvocationResult): RawUtf8;
var
  doc: variant;
  list: PDocVariantData;
  i: Integer;
begin
  Result := '';
  if R.Kind <> prkSuccess then
    exit;
  doc := _JsonFast(RawUtf8(R.Value));
  list := _Safe(doc)^.A['events'];
  if list = nil then
    exit;
  for i := 0 to list^.Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + _Safe(list^.Values[i])^.U['type'];
  end;
end;

function Ms3(Us: Int64): RawUtf8;
begin
  // milliseconds with three decimals, from microseconds, locale-free
  if Us < 0 then
    Us := 0;
  Result := RawUtf8(IntToStr(Us div 1000)) + '.' +
    RawUtf8(Format('%.3d', [Us mod 1000]));
end;

function Policy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([APP_CAP_ADD, PWEB_CAP_NETWORK_SOCKET]);
    b.SetWindowCapabilities('main', [APP_CAP_ADD, PWEB_CAP_NETWORK_SOCKET]);
    b.SetPrincipalCapabilities('window:main', [APP_CAP_ADD, PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(APP_METHOD_ADD, [APP_CAP_ADD]);
    b.MapMethod(PWEB_METHOD_SOCKET_OPEN, [PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_SEND, [PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_RECEIVE, [PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_CLOSE, [PWEB_CAP_NETWORK_SOCKET]);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_SUBSCRIBE);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_UNSUBSCRIBE);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ One N, on a fresh composition. Returns the row value. }
function MeasureOne(N: Integer): RawUtf8;
var
  server: TRestServerFullMemory;
  realBridge: IInvocationBridge;
  door: TPWebSocketBridge;
  doorRef: IInvocationBridge;
  signals: TPWebSignalChannel;
  chain: IInvocationBridge;
  policyObj: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  limits: TPWebSourceLimits;
  bounds: TPWebSocketBounds;
  view: TPWebSignalView;
  ctx: TInvocationContext;
  ids: TRawUtf8DynArray;
  c, add: TCompletion;
  cRef, addRef: IInvocationCompletion;
  i, queued, active, inFlight: Integer;
  refusal, kind, resultText, waitVerdict, echo, route: RawUtf8;
  enqueueUs, latencyUs: Int64;
  e: TPWebEnqueueResult;
  answered: Boolean;
  deadline: Int64;

  function Call(const Method, Args: RawUtf8; out Sink: TCompletion;
    out SinkRef: IInvocationCompletion): TPWebEnqueueResult;
  begin
    Sink := TCompletion.Create;
    SinkRef := Sink;
    Result := source.TryEnqueue(ctx, Method, TPWebJson(Args), SinkRef);
  end;

  // one invocation, run to its answer
  function Run(const Method, Args: RawUtf8): TPWebInvocationResult;
  var
    s: TCompletion;
    sRef: IInvocationCompletion;
  begin
    Result := Default(TPWebInvocationResult);
    if (Call(Method, Args, s, sRef) = perAccepted) and
       s.WaitDone(STEP_BOUND_MS) then
      Result := s.Outcome
    else
      Result := PWebDefaultErrorResult(pecInternalError);
  end;

begin
  Result := '';
  server := TRestServerFullMemory.CreateWithOwnModel([]);
  if server.ServiceRegister(TCalculatorService,
       [TypeInfo(ICalculatorService)], sicShared) = nil then
    raise Exception.Create('unable to register CalculatorService');
  realBridge := TMormotInvocationBridge.Create(server, True);
  server := nil; // owned by the bridge from here
  bounds := PWebSocketDefaultBounds;
  bounds.MaxSockets := STARVE_SOCKET_BOUND;
  door := TPWebSocketBridge.Create(realBridge, PWebSocketNativeTransport,
    ['http://127.0.0.1:' + RawUtf8(IntToStr(Port))], bounds);
  doorRef := door;
  // THE HOST'S COMPOSITION: the channel over the door, the door on the
  // channel, the channel holding the policy's grants slot and a view
  signals := TPWebSignalChannel.Create(doorRef, []);
  chain := signals;
  door.AttachSignals(signals);
  policyObj := Policy;
  policyRef := policyObj;
  signals.AttachPolicy(policyObj);
  view.Dispatch := @ViewDispatch;
  view.Eval := @ViewEval;
  signals.AttachView(view);
  // THE HOST'S NUMBERS, AS GIVEN. Nothing is added for the sockets.
  scheduler := TInvocationScheduler.Create(policyRef, chain, Workers);
  schedulerRef := scheduler;
  limits := Default(TPWebSourceLimits);
  limits.MaxConcurrent := Slots;
  limits.MaxQueueSize := QueueBound;
  source := scheduler.RegisterSource(limits);
  // the context a host's binding builds natively, with the capability
  // snapshot the host's policy wrapper puts on it before the enqueue
  ctx := Default(TInvocationContext);
  ctx.WindowId := 'main';
  ctx.PrincipalId := 'window:main';
  ctx.PrincipalKind := pkWindow;
  ctx.TrustedContent := True;
  ctx.Capabilities := policyObj.SnapshotCapabilities('window:main', 'main');
  ids := nil;
  refusal := 'none';
  echo := 'not_applicable';
  waitVerdict := 'none';
  InterlockedExchange(DrainAsked, 0);
  try
    // 1. open N sockets, one after another
    for i := 1 to N do
    begin
      if i = 1 then
        route := '/echo'
      else
        route := '/idle';
      e := Call(PWEB_METHOD_SOCKET_OPEN,
        '{"url":' + QuotedStrJson('ws://127.0.0.1:' + RawUtf8(IntToStr(Port)) +
        route + '?row=starve_n' + RawUtf8(IntToStr(N)) + '_' +
        RawUtf8(IntToStr(i))) + '}', c, cRef);
      Require(e = perAccepted, 'an open was not accepted by the scheduler');
      if (e <> perAccepted) or not c.WaitDone(STEP_BOUND_MS) then
      begin
        Require(False, 'an open did not complete inside its bound');
        refusal := 'unanswered';
        break;
      end;
      if c.Outcome.Kind = prkSuccess then
      begin
        SetLength(ids, Length(ids) + 1);
        ids[High(ids)] := IdOf(c.Outcome);
      end
      else if refusal = 'none' then
        refusal := Verdict(c.Outcome);
    end;
    // 2. each socket's open event, there at once
    for i := 0 to High(ids) do
      Require(EventTypes(Run(PWEB_METHOD_SOCKET_RECEIVE,
        '{"id":' + QuotedStrJson(ids[i]) + '}')) = 'open',
        'a socket did not deliver exactly its open event at once');
    // 3. the migrated loop at rest: subscribed, and NOTHING in flight
    Require(Verdict(Run(PWEB_METHOD_SIGNAL_SUBSCRIBE,
      '{"topic":"' + PWEB_SIGNAL_TOPIC_SOCKET + '"}')) = 'success',
      'the window could not subscribe to its socket topic');
    inFlight := -1;
    deadline := GetTickCount64 + 2000;
    repeat
      if scheduler.TryGetSourceCounts(source, queued, active) then
        inFlight := queued + active;
      if inFlight = 0 then
        break;
      Sleep(1);
    until GetTickCount64 > deadline;
    Require(inFlight = 0, 'a quiet socket left an invocation in flight');
    // 4. the unrelated invoke
    enqueueUs := NowUs;
    e := Call(APP_METHOD_ADD, '{"a":20,"b":22}', add, addRef);
    answered := (e = perAccepted) and add.WaitDone(ADD_BOUND_MS);
    if e <> perAccepted then
    begin
      case e of
        perInvalidRequest: kind := 'refused_enqueue_invalid_request';
        perBusy: kind := 'refused_enqueue_busy';
      else
        kind := 'refused_enqueue_closed';
      end;
      latencyUs := 0;
      resultText := 'none';
    end
    else if not answered then
    begin
      kind := 'not_answered';
      latencyUs := Int64(ADD_BOUND_MS) * 1000;
      resultText := 'none';
    end
    else
    begin
      latencyUs := add.AtUs - enqueueUs;
      if add.Outcome.Kind <> prkSuccess then
      begin
        kind := 'refused_' + Verdict(add.Outcome);
        resultText := 'none';
      end
      else
      begin
        kind := 'served';
        resultText := Trim(RawUtf8(add.Outcome.Value));
      end;
    end;
    // 5. the loop still delivers: send, be signalled, drain, receive
    if Length(ids) > 0 then
    begin
      echo := 'missing';
      InterlockedExchange(DrainAsked, 0);
      if Verdict(Run(PWEB_METHOD_SOCKET_SEND, '{"id":' + QuotedStrJson(ids[0]) +
           ',"text":"cap16-starve-echo"}')) = 'success' then
      begin
        deadline := GetTickCount64 + ECHO_BOUND_MS;
        while (PWebAtomicRead(DrainAsked) = 0) and
              (GetTickCount64 < deadline) do
          Sleep(1);
        if PWebAtomicRead(DrainAsked) > 0 then
        begin
          // the page's side of the tick: the GUI drain, then the read
          signals.Drain('main');
          if Pos('cap16-starve-echo', RawUtf8(Run(PWEB_METHOD_SOCKET_RECEIVE,
               '{"id":' + QuotedStrJson(ids[0]) + '}').Value)) > 0 then
            echo := 'signalled';
        end;
      end;
      Require(echo = 'signalled',
        'an echo did not come back through signal then receive');
    end;
    // 6. the retired wait, refused
    if Length(ids) > 0 then
      waitVerdict := Verdict(Run(PWEB_METHOD_SOCKET_RECEIVE,
        '{"id":' + QuotedStrJson(ids[0]) + ',"waitMs":' +
        RawUtf8(IntToStr(RETIRED_WAIT_MS)) + '}'))
    else
      waitVerdict := 'not_applicable';
    Result := kind +
      ' latency_ms=' + Ms3(latencyUs) +
      ' result=' + resultText +
      ' opened=' + RawUtf8(IntToStr(Length(ids))) + '/' + RawUtf8(IntToStr(N)) +
      ' open_refused=' + refusal +
      ' in_flight=' + RawUtf8(IntToStr(inFlight)) +
      ' socket_bound=' + RawUtf8(IntToStr(STARVE_SOCKET_BOUND)) +
      ' waitms=' + waitVerdict +
      ' echo=' + echo;
    // the instrument's own validity - never the verdict
    if answered and (add.Outcome.Kind = prkSuccess) then
      Require(resultText = '42', 'CalculatorService.Add(20, 22) did not answer 42');
    Require(Length(ids) = N,
      'the number of sockets that opened is not N');
    if N > 0 then
      Require(waitVerdict = 'invalid_request',
        'a receive with a nonzero waitMs was not refused');
    if N = 0 then
      Require(kind = 'served', 'the control (no socket at all) was not served');
  finally
    // 7. the host's order: the channel's drain seam - which hands the door
    // its own and releases every socket - then the pool drains
    signals.BeforeDrain;
    signals.DetachView;
    source := nil;
    schedulerRef.Shutdown;
    schedulerRef := nil;
    scheduler := nil;
    chain := nil;
    signals := nil;
    doorRef := nil;
    door := nil;
    realBridge := nil;
    policyRef := nil;
    policyObj := nil;
  end;
end;

procedure ParseArgs;
var
  i: Integer;
  a: string;
begin
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if Copy(a, 1, 7) = '--port=' then
      Port := StrToIntDef(Copy(a, 8, 16), 0)
    else if Copy(a, 1, 10) = '--workers=' then
      Workers := StrToIntDef(Copy(a, 11, 16), 0)
    else if Copy(a, 1, 8) = '--slots=' then
      Slots := StrToIntDef(Copy(a, 9, 16), 0)
    else if Copy(a, 1, 8) = '--queue=' then
      QueueBound := StrToIntDef(Copy(a, 9, 16), 0)
    else if Copy(a, 1, 6) = '--out=' then
      OutPath := RawUtf8(Copy(a, 7, MaxInt));
  end;
end;

procedure WriteOut;
var
  i: Integer;
  json: RawUtf8;
begin
  json := '{'#10;
  for i := 0 to High(Rows) do
  begin
    json := json + Rows[i];
    if i < High(Rows) then
      json := json + ','#10
    else
      json := json + #10;
  end;
  json := json + '}'#10;
  if OutPath <> '' then
    FileFromString(json, TFileName(OutPath));
end;

const
  NS: array[0..4] of Integer = (0, 3, 4, 5, 8);

var
  k: Integer;

begin
  ParseArgs;
  if (Port <= 0) or (Workers <= 0) or (Slots <= 0) or (QueueBound <= 0) or
     (OutPath = '') then
  begin
    WriteLn(StdErr, 'socketstarve: --port, --workers, --slots, --queue and ' +
      '--out are all required');
    Halt(2);
  end;
  Row('socket_starvation_host_defaults', RawUtf8(Format(
    'workers=%d slots=%d queue=%d', [Workers, Slots, QueueBound])));
  for k := Low(NS) to High(NS) do
    try
      Row('socket_starvation_n' + RawUtf8(IntToStr(NS[k])), MeasureOne(NS[k]));
    except
      on E: Exception do
      begin
        Require(False, 'n=' + RawUtf8(IntToStr(NS[k])) + ' raised ' +
          RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message));
        Row('socket_starvation_n' + RawUtf8(IntToStr(NS[k])), 'instrument_failed');
      end;
    end;
  Row('socket_starvation_scripts', RawUtf8(IntToStr(Scripts)));
  Row('socket_starvation_failures', RawUtf8(IntToStr(Failures)));
  WriteOut;
  if Failures > 0 then
    Halt(1);
end.
