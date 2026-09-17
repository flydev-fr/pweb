program socketstarve;

{ CAP-15C: THE STARVATION, MEASURED AND NOT FIXED.

  `pweb.socketReceive` is a bounded long-poll, and it waits ON THE SCHEDULER
  WORKER that runs it (TPWebSocketBridge.Receive, 20 ms slices up to waitMs).
  A reading of the code says that under the ratified host defaults - four
  workers, four simultaneous invocations, a queue of 32 - four quiet sockets
  with their receive loops parked hold every worker, and any other invocation
  of the page waits in the queue until one poll returns. This program measures
  that claim instead of repeating it. It changes nothing: no default, no extra
  worker, no workaround. Raising the worker count, which the network template
  does (ledger 15C-6), would hide the shape this program exists to show.

  WHAT IS REAL. Every component on the path is the shipped one, composed the
  way a host composes it, minus the window:

    TInvocationScheduler           the frozen pool, at the host's numbers
      -> TPWebCapabilityPolicy     authoritative, before the bridge
      -> TPWebSocketBridge         the decorator, over
           PWebSocketNativeTransport against test/cap15c/ws_server.js /idle
      -> TMormotInvocationBridge   -> CalculatorService.Add(20, 22) = 42

  The worker count, the slot count and the queue bound are NOT typed here.
  test/cap15c/run_cap15c_gates.ps1 reads them out of PWebDefaultHostOptions
  in src/webview/pweb.webview.host.pas and passes them in, so the numbers are
  always the ones the host ships. That unit is not linked: it pulls in the
  platform WebView library, which no claim here needs. The N set is fixed and
  brackets TODAY's four workers, four slots and four sockets; a host that
  moved those numbers would want the set moved with them.

  WORKERS AND SLOTS COINCIDE at the defaults, and the parked receives and the
  Add share one source, so a delay here shows the pool and the window's slots
  held together. This program does not separate the two bounds; FR-M1's reading
  of the code names both.

  ONE ROW PER N, for N = 0, 3, 4 and 5, each on a FRESH composition:

    1. open N sockets through the scheduler, one after another. The fifth is
       refused `socket_limit` by the ratified four-socket host bound, and the
       row says so rather than pretending five parked;
    2. drain each socket's `open` event, exactly as the SDK's first receive
       does, so the next receive has nothing to return;
    3. PARK one receive per socket, `waitMs` = PWEB_SOCKET_MAX_WAIT_MS, and
       wait until the scheduler holds every one of them (active + queued);
    4. enqueue `CalculatorService.Add` with a = 20 and b = 22, and time it from its own
       enqueue to its completion, with the queue sampled right after the
       enqueue;
    5. tear down in the host's order - the socket door's BeforeDrain, then the
       scheduler's Shutdown - which releases every parked poll at once.

  THE TYPE IS ORDER, NOT A THRESHOLD. A starved Add can only be claimed after
  a parked poll has given its slot back, so its completion follows the first
  parked completion. Latency is measured from the Add's own enqueue while the
  polls were already parked, so a starved Add is answered at about the bound
  minus `parked_for_ms`, plus at most one 20 ms wait slice and the claim.
  `within_long_poll_bound` compares that latency with 25 000 ms exactly, so it
  can read false by that slice when the polls were parked for less than it.

  NOTHING HERE GATES THE ANSWER. A not-answered or refused Add is a row, not a
  failure; the failures are the instrument's own - the control, the sockets
  that should have opened, the polls that should have parked, a served Add
  that did not answer 42.

    served_beside_parked_polls           Add completed while every parked poll
                                         was still parked
    served_after_a_parked_poll_returned  Add completed only after a parked
                                         poll returned
    not_answered                         Add still outstanding after two whole
                                         long-poll bounds
    refused_<code>                       the enqueue or the call was refused

  The Add waits at most 2 x PWEB_SOCKET_MAX_WAIT_MS. The contract says every
  parked poll returns within one bound plus one 20 ms slice, so a starved Add
  is claimed by then; the second bound is there so a poll that overran by a
  whole bound is observed rather than cut off.

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
  pweb.rpc.socket,
  pweb.rpc.socket.mormot,
  pweb.capabilities.policy;

const
  APP_METHOD_ADD = 'CalculatorService.Add';
  APP_CAP_ADD = 'calculator.add';
  /// how long an open or a drain may take before the instrument gives up;
  // the connect deadline is the door's own wall-clock bound on an open
  STEP_BOUND_MS = PWEB_SOCKET_CONNECT_DEADLINE_MS + 5000;
  /// how long the parked polls may take to show up in the scheduler
  PARK_BOUND_MS = 5000;
  /// how long the Add may stay outstanding: two whole long-poll bounds
  ADD_BOUND_MS = 2 * PWEB_SOCKET_MAX_WAIT_MS;

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
  policyObj: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  limits: TPWebSourceLimits;
  ctx: TInvocationContext;
  ids: TRawUtf8DynArray;
  parked: array of TCompletion;
  parkedRefs: array of IInvocationCompletion;
  c: TCompletion;
  cRef: IInvocationCompletion;
  add: TCompletion;
  addRef: IInvocationCompletion;
  i, queued, active, parkedCount: Integer;
  refusal, kind, resultText: RawUtf8;
  deadline, parkUs, enqueueUs, firstParkedUs, latencyUs: Int64;
  e: TPWebEnqueueResult;
  answered, sawAll: Boolean;

  function Call(const Method, Args: RawUtf8; out Sink: TCompletion;
    out SinkRef: IInvocationCompletion): TPWebEnqueueResult;
  begin
    Sink := TCompletion.Create;
    SinkRef := Sink;
    Result := source.TryEnqueue(ctx, Method, TPWebJson(Args), SinkRef);
  end;

begin
  Result := '';
  server := TRestServerFullMemory.CreateWithOwnModel([]);
  if server.ServiceRegister(TCalculatorService,
       [TypeInfo(ICalculatorService)], sicShared) = nil then
    raise Exception.Create('unable to register CalculatorService');
  realBridge := TMormotInvocationBridge.Create(server, True);
  server := nil; // owned by the bridge from here
  door := TPWebSocketBridge.Create(realBridge, PWebSocketNativeTransport,
    ['http://127.0.0.1:' + RawUtf8(IntToStr(Port))]);
  doorRef := door;
  policyObj := Policy;
  policyRef := policyObj;
  door.AttachPolicy(policyObj);
  // THE HOST'S NUMBERS, AS GIVEN. Nothing is added for the sockets.
  scheduler := TInvocationScheduler.Create(policyRef, doorRef, Workers);
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
  parked := nil;
  parkedRefs := nil;
  refusal := 'none';
  try
    // 1. open N sockets, one after another
    for i := 1 to N do
    begin
      e := Call(PWEB_METHOD_SOCKET_OPEN,
        '{"url":' + QuotedStrJson('ws://127.0.0.1:' + RawUtf8(IntToStr(Port)) +
        '/idle?row=starve_n' + RawUtf8(IntToStr(N)) + '_' + RawUtf8(IntToStr(i))) + '}',
        c, cRef);
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
    // 2. drain each socket's open event, as the SDK's first receive does
    for i := 0 to High(ids) do
    begin
      e := Call(PWEB_METHOD_SOCKET_RECEIVE,
        '{"id":' + QuotedStrJson(ids[i]) + ',"waitMs":5000}', c, cRef);
      Require((e = perAccepted) and c.WaitDone(STEP_BOUND_MS) and
        (EventTypes(c.Outcome) = 'open'),
        'a socket did not deliver exactly its open event before it was parked');
    end;
    // 3. park one receive per socket, and see every one of them held
    SetLength(parked, Length(ids));
    SetLength(parkedRefs, Length(ids));
    for i := 0 to High(ids) do
    begin
      e := Call(PWEB_METHOD_SOCKET_RECEIVE, '{"id":' + QuotedStrJson(ids[i]) +
        ',"waitMs":' + RawUtf8(IntToStr(PWEB_SOCKET_MAX_WAIT_MS)) + '}',
        parked[i], parkedRefs[i]);
      Require(e = perAccepted, 'a parked receive was not accepted by the scheduler');
    end;
    parkUs := NowUs;
    parkedCount := 0;
    sawAll := Length(ids) = 0;
    deadline := GetTickCount64 + PARK_BOUND_MS;
    while not sawAll and (GetTickCount64 < deadline) do
    begin
      if scheduler.TryGetSourceCounts(source, queued, active) and
         (active + queued = Length(ids)) and
         (active = MinPtrInt(Length(ids), MinPtrInt(Slots, Workers))) then
        sawAll := True
      else
        Sleep(1);
    end;
    if sawAll then
      parkedCount := Length(ids);
    Require(sawAll, 'the parked receives never all showed up in the scheduler');
    for i := 0 to High(parked) do
      Require(not parked[i].Done, 'a parked receive returned before the Add was enqueued');
    // 4. the unrelated invoke
    enqueueUs := NowUs;
    e := Call(APP_METHOD_ADD, '{"a":20,"b":22}', add, addRef);
    if not scheduler.TryGetSourceCounts(source, queued, active) then
    begin
      queued := -1;
      active := -1;
    end;
    answered := (e = perAccepted) and add.WaitDone(ADD_BOUND_MS);
    firstParkedUs := 0;
    for i := 0 to High(parked) do
      if parked[i].Done and
         ((firstParkedUs = 0) or (parked[i].AtUs < firstParkedUs)) then
        firstParkedUs := parked[i].AtUs;
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
        resultText := Trim(RawUtf8(add.Outcome.Value));
        if (firstParkedUs <> 0) and (firstParkedUs <= add.AtUs) then
          kind := 'served_after_a_parked_poll_returned'
        else
          kind := 'served_beside_parked_polls';
      end;
    end;
    Result := kind +
      ' latency_ms=' + Ms3(latencyUs) +
      ' within_long_poll_bound=' +
        RawUtf8(BoolToStr(answered and (latencyUs <= Int64(PWEB_SOCKET_MAX_WAIT_MS) * 1000), 'true', 'false')) +
      ' result=' + resultText +
      ' opened=' + RawUtf8(IntToStr(Length(ids))) + '/' + RawUtf8(IntToStr(N)) +
      ' open_refused=' + refusal +
      ' parked=' + RawUtf8(IntToStr(parkedCount)) +
      ' parked_for_ms=' + Ms3(enqueueUs - parkUs) +
      ' active=' + RawUtf8(IntToStr(active)) +
      ' queued=' + RawUtf8(IntToStr(queued));
    if firstParkedUs <> 0 then
      WriteLn('[CAP-15C] n=', N, ' first parked poll returned ',
        Ms3(firstParkedUs - enqueueUs), ' ms after the Add was enqueued')
    else
      WriteLn('[CAP-15C] n=', N, ' no parked poll returned before the Add completed');
    // the instrument's own validity - never the verdict
    if answered and (add.Outcome.Kind = prkSuccess) then
      Require(resultText = '42', 'CalculatorService.Add(20, 22) did not answer 42');
    Require(Length(ids) = MinPtrInt(N, PWEB_SOCKET_MAX_SOCKETS),
      'the number of sockets that opened is not min(N, the host bound)');
    if N > PWEB_SOCKET_MAX_SOCKETS then
      Require(refusal = 'service_error:' + PWEB_SOCKET_CAT_LIMIT,
        'the socket past the host bound was not refused socket_limit');
    if N = 0 then
      Require(kind = 'served_beside_parked_polls',
        'the control (no socket at all) was not served at once');
  finally
    // 5. the host's order: the door releases every socket, then the pool
    // drains. MEASURED on the first run of this program: BeforeDrain alone
    // does not end a parked receive - the socket it waits on is made
    // invisible, not given a close event - so the poll would sit out its
    // whole waitMs. What ends it is the scheduler's shutdown, which closes
    // the source and cancels the token the receive checks every slice. That
    // is the order the host already uses, so it is the order used here.
    door.BeforeDrain;
    source := nil;
    schedulerRef.Shutdown;
    for i := 0 to High(parked) do
      if parked[i] <> nil then
        Require(parked[i].Done,
          'a parked receive was still outstanding after the scheduler shut down');
    schedulerRef := nil;
    scheduler := nil;
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
  NS: array[0..3] of Integer = (0, 3, 4, 5);

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
  Row('socket_starvation_failures', RawUtf8(IntToStr(Failures)));
  WriteOut;
  if Failures > 0 then
    Halt(1);
end.
