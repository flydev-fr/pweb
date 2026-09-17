program signallive;

{ CAP-16: THE SIGNAL CHANNEL IN THE PRODUCTION HOST, on four targets.

  WHAT IS PRODUCTION HERE is everything that decides: PWebHostRun itself -
  its binding, its scheduler, its policy wrapper, its asset handler, its
  navigation guard, its blob plane and THE ONE webview_eval CALL SITE of the
  product - the capability policy, the signal channel, the socket door and
  its transport, the mORMot bridge with the caller principal, and the REAL
  @pweb/runtime the page imports (staged beside the fixture by
  build_cap16.ps1). What is this harness's is a bridge decorator answering
  `Cap16.*`, which drives native signals and reads the channel's counters,
  and one service, `Live.Snapshot`, that returns a 2 MiB log as a blob for
  its caller (ledger 12-5).

  The page (test/cap16/fixture/live/live.js) runs two documents:

    phase 1   the handshake feature; a topic the window may not read,
              refused with zero scripts; one signal and its latency; a
              10 000 signals-a-second flood for three seconds with the page's
              own 10 ms timer watched; a revocation followed by fifty
              signals nobody may hear; then a reload with signals emitted
              while the document is being replaced
    phase 2   the subscriptions the replacement dropped; the recovery by
              re-read; a socket echo through the migrated receive loop
              (when PWEB_CAP16_WS_PORT names a witness); the service's blob
              read by URL

  The page reports through `Cap16.Report`, and this program stops its own
  host the way a supervisor does: WM_CLOSE on Windows, SIGTERM on POSIX.

  It writes build/cap16/live-<target>.json and prints one marker line.

  Usage: signallive --pweb-verdict=<file> --pweb-autoclose-ms=<ms>
         [env PWEB_CAP16_WS_PORT] }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  {$ifdef OSWINDOWS}
  windows,
  {$else}
  baseunix,
  {$endif OSWINDOWS}
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.json,
  mormot.core.variants,
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.mormot,
  pweb.rpc.caller,
  pweb.rpc.signal,
  pweb.rpc.socket,
  {$ifdef DARWIN}
  pweb.platform.cocoa.socket,
  {$else}
  pweb.rpc.socket.mormot,
  {$endif DARWIN}
  pweb.capabilities.policy,
  pweb.assets.intf,
  pweb.assets.folder,
  pweb.blobs.intf,
  pweb.blobs.memory,
  pweb.webview.host,
  pweb.test.reporoot;

const
  LOG_PREFIX = 'signallive';
  WINDOW_TITLE = 'PWeb CAP-16 signal channel';
  MARKER_PASS = 'signallive: CAP-16 LIVE PASS';
  MARKER_FAIL = 'signallive: CAP-16 LIVE FAIL';
  {$ifdef DARWIN}
    {$ifdef CPUAARCH64}
  TARGET_ID = 'macos-arm64';
    {$else}
  TARGET_ID = 'macos-x64';
    {$endif CPUAARCH64}
  {$else}
  {$ifdef LINUX}
  TARGET_ID = 'linux';
  {$else}
  TARGET_ID = 'windows';
  {$endif LINUX}
  {$endif DARWIN}

  CAP_TICK = 'signal.cap16.tick';
  CAP_FLOOD = 'signal.cap16.flood';
  CAP_DENIED = 'signal.cap16.denied';
  BLOB_BYTES = 2 * 1024 * 1024;
  BLOB_TYPE = 'text/plain; charset=utf-8';

type
  ILive = interface(IInvokable)
    ['{0D8A2C4E-71B3-4F6A-9C05-3E8B1D7F2A64}']
    function Snapshot(since: Int64): RawJson;
  end;

  TLive = class(TInterfacedObject, ILive)
  public
    function Snapshot(since: Int64): RawJson;
  end;

  TLiveBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TEmitter = class(TThread)
  protected
    procedure Execute; override;
  public
    Topic: RawUtf8;
    Count, DelayMs, DurationMs, PerSecond: Integer;
    Sent: LongInt;
    /// the window's script count when the flood began and when it ended:
    // the HALF-OPEN window the rate bound is stated over
    EvalsAtStart, EvalsAtEnd: Int64;
  end;

var
  Port: Integer = 0;
  Signals: TPWebSignalChannel;
  Policy: TPWebCapabilityPolicy;
  Blobs: IBlobStore;
  PageReport: RawUtf8 = '';
  PhaseOne: RawUtf8 = 'null';
  Phases: LongInt = 0;
  Flood: TEmitter = nil;
  FloodEvalsAtStart: Int64 = 0;
  FloodStartMs: Int64 = 0;
  Later: array of TEmitter;
  LogBytes: RawByteString;

function BuildLog: RawByteString;
var
  line: RawUtf8;
  n: Integer;
begin
  Result := '';
  SetLength(Result, BLOB_BYTES);
  n := 0;
  while n < BLOB_BYTES do
  begin
    line := FormatUtf8('cap16 live job line %'#10, [n]);
    if n + Length(line) > BLOB_BYTES then
      SetLength(line, BLOB_BYTES - n);
    Move(pointer(line)^, PByteArray(pointer(Result))[n], Length(line));
    Inc(n, Length(line));
  end;
end;

// the page computes the same, over the bytes it read by URL
function Fnv1a(const S: RawByteString): Cardinal;
var
  i: PtrInt;
begin
  Result := $811C9DC5;
  for i := 1 to Length(S) do
  begin
    Result := Result xor Ord(S[i]);
    Result := Cardinal(Int64(Result) * $01000193);
  end;
end;

function TLive.Snapshot(since: Int64): RawJson;
var
  handle: RawUtf8;
  ceiling: TPWebBlobCeiling;
begin
  // THE CALLER'S BLOB: no owner is named here, the bridge knows it
  if PWebCallerBlobPut(Blobs, LogBytes, BLOB_TYPE, handle, ceiling) then
    Result := RawJson(handle)
  else
    Result := RawJson('{"refused":"' + PWebBlobCeilingCategory(ceiling) + '"}');
end;

procedure TEmitter.Execute;
var
  start, now: Int64;
  i: Integer;
begin
  if DelayMs > 0 then
    Sleep(DelayMs);
  if DurationMs > 0 then
  begin
    EvalsAtStart := Signals.WindowEvalCount('main');
    QueryPerformanceMicroSeconds(start);
    repeat
      QueryPerformanceMicroSeconds(now);
      if now - start >= Int64(DurationMs) * 1000 then
        break;
      if now - start >= (Int64(Sent) * 1000000) div PerSecond then
      begin
        PWebSignal(Topic);
        InterlockedIncrement(Sent);
      end
      else
        SleepHiRes(0);
    until False;
    EvalsAtEnd := Signals.WindowEvalCount('main');
  end
  else
    for i := 1 to Count do
    begin
      PWebSignal(Topic);
      InterlockedIncrement(Sent);
    end;
end;

function StartEmitter(const Topic: RawUtf8; Count, DelayMs, DurationMs,
  PerSecond: Integer): TEmitter;
begin
  Result := TEmitter.Create(True);
  Result.FreeOnTerminate := False;
  Result.Topic := Topic;
  Result.Count := Count;
  Result.DelayMs := DelayMs;
  Result.DurationMs := DurationMs;
  Result.PerSecond := PerSecond;
  Result.Start;
end;

procedure RequestStop;
begin
  {$ifdef OSWINDOWS}
  // what a supervisor does: the top-level window is asked to close, and the
  // upstream backend turns that into webview_terminate
  PostMessageW(FindWindowW(nil, PWideChar(WideString(WINDOW_TITLE))),
    WM_CLOSE, 0, 0);
  {$else}
  // what a supervisor does: the host's stop helper turns it into the same
  // terminate dispatch the auto-close thread uses
  FpKill(FpGetpid, SIGTERM);
  {$endif OSWINDOWS}
end;

constructor TLiveBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

// one string member of the arguments, through the typed accessor
function ArgText(const Args: TPWebJson; const Name: RawUtf8): RawUtf8;
var
  v: variant;
begin
  v := _JsonFast(RawUtf8(Args));
  Result := _Safe(v)^.U[Name];
end;

// one integer member of the arguments, 0 when absent
function ArgInt(const Args: TPWebJson; const Name: RawUtf8): Int64;
var
  v: variant;
begin
  v := _JsonFast(RawUtf8(Args));
  Result := _Safe(v)^.I[Name];
end;

function Ok(const Json: RawUtf8): TPWebInvocationResult;
begin
  Result := PWebSuccessResult(TPWebJson(Json));
end;

function TLiveBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  i, n, signalled: Integer;
  evals: Int64;
  doc: variant;
  topic: RawUtf8;
begin
  if Copy(Method, 1, 6) <> 'Cap16.' then
    exit(FInner.Invoke(Context, Method, Args, Token));
  if Method = 'Cap16.Config' then
    Result := Ok(FormatUtf8('{"port":%,"blobBytes":%,"blobFnv":%,"target":"%"}',
      [Port, BLOB_BYTES, Fnv1a(LogBytes), TARGET_ID]))
  else if Method = 'Cap16.Evals' then
    Result := Ok(FormatUtf8('{"evals":%}', [Signals.WindowEvalCount('main')]))
  else if Method = 'Cap16.Emit' then
  begin
    n := ArgInt(Args, 'count');
    topic := ArgText(Args, 'topic');
    signalled := 0;
    for i := 1 to n do
      if PWebSignal(topic) then
        Inc(signalled);
    Result := Ok(FormatUtf8('{"signalled":%}', [signalled]));
  end
  else if Method = 'Cap16.EmitLater' then
  begin
    SetLength(Later, Length(Later) + 1);
    Later[High(Later)] := StartEmitter(ArgText(Args, 'topic'),
      ArgInt(Args, 'count'), ArgInt(Args, 'delayMs'), 0, 1);
    Result := Ok('{}');
  end
  else if Method = 'Cap16.Flood' then
  begin
    FloodEvalsAtStart := Signals.WindowEvalCount('main');
    FloodStartMs := GetTickCount64;
    Flood := StartEmitter('cap16.flood', 0, 0, ArgInt(Args, 'ms'),
      ArgInt(Args, 'perSecond'));
    Result := Ok('{}');
  end
  else if Method = 'Cap16.FloodResult' then
  begin
    if Flood = nil then
      exit(PWebDefaultErrorResult(pecInvalidRequest));
    Flood.WaitFor;
    // one tick more, so a pair still pending is counted where it lands
    Sleep(2 * PWEB_SIGNAL_TICK_MS);
    // the scripts issued WHILE the flood ran - the half-open window the bound
    // R per second is stated over - and, apart, the ones after it ended
    evals := Flood.EvalsAtEnd - Flood.EvalsAtStart;
    Result := Ok(FormatUtf8('{"sent":%,"durationMs":%,"evals":%,"evalsTail":%,' +
      '"evalsPerSecond":%,"seq":%,"ticksPerSecond":%}',
      [Flood.Sent, Flood.DurationMs, evals,
       Signals.WindowEvalCount('main') - Flood.EvalsAtEnd,
       evals / (Flood.DurationMs / 1000), Signals.TopicSeq('cap16.flood'),
       PWEB_SIGNAL_TICKS_PER_SECOND]));
  end
  else if Method = 'Cap16.Revoke' then
  begin
    Policy.SetRuntimeGrants('window:main', [CAP_FLOOD, PWEB_CAP_NETWORK_SOCKET]);
    // BEFORE anything else runs: what the revoking call left behind
    Result := Ok(FormatUtf8('{"subsAfter":%,"pendingAfter":%}',
      [Signals.SubscriptionCount('main'), Signals.PendingCount('main')]));
  end
  else if Method = 'Cap16.Restore' then
  begin
    Policy.ClearRuntimeGrants('window:main');
    Result := Ok('{}');
  end
  else if Method = 'Cap16.Subs' then
    Result := Ok(FormatUtf8('{"subscriptions":%}',
      [Signals.SubscriptionCount('main')]))
  else if Method = 'Cap16.TickCount' then
    // "everything since N": what a page re-reads after it lost signals
    Result := Ok(FormatUtf8('{"seq":%,"since":%,"missed":%}',
      [Signals.TopicSeq('cap16.tick'), ArgInt(Args, 'since'),
       Signals.TopicSeq('cap16.tick') - ArgInt(Args, 'since')]))
  else if Method = 'Cap16.Phase' then
  begin
    InterlockedIncrement(Phases);
    // FLOAT-aware: the plain fast parser keeps only currency-precision
    // numbers and would turn a measured rate into a string
    doc := _JsonFastFloat(RawUtf8(Args));
    PhaseOne := _Safe(doc)^.O['report']^.ToJson;
    Result := Ok('{}');
  end
  else if Method = 'Cap16.Carried' then
  begin
    InterlockedIncrement(Phases);
    Result := Ok(PhaseOne);
  end
  else if Method = 'Cap16.Report' then
  begin
    doc := _JsonFastFloat(RawUtf8(Args));
    if PageReport = '' then
      PageReport := _Safe(doc)^.O['report']^.ToJson;
    Result := Ok('{}');
    RequestStop;
  end
  else
    Result := PWebDefaultErrorResult(pecMethodNotFound);
end;

function BuildPolicy: TPWebCapabilityPolicy;
const
  METHODS: array[0 .. 12] of RawUtf8 = ('Cap16.Config', 'Cap16.Evals',
    'Cap16.Emit', 'Cap16.EmitLater', 'Cap16.Flood', 'Cap16.FloodResult',
    'Cap16.Revoke', 'Cap16.Restore', 'Cap16.Subs', 'Cap16.TickCount',
    'Cap16.Phase', 'Cap16.Carried', 'Cap16.Report');
var
  b: TPWebCapabilityPolicyBuilder;
  i: Integer;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_TICK, CAP_FLOOD, CAP_DENIED, PWEB_CAP_NETWORK_SOCKET]);
    // the WINDOW may not read cap16.denied, though the ceiling holds it
    b.SetWindowCapabilities('main', [CAP_TICK, CAP_FLOOD, PWEB_CAP_NETWORK_SOCKET]);
    b.SetPrincipalCapabilities('window:main',
      [CAP_TICK, CAP_FLOOD, CAP_DENIED, PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_OPEN, [PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_SEND, [PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_RECEIVE, [PWEB_CAP_NETWORK_SOCKET]);
    b.MapMethod(PWEB_METHOD_SOCKET_CLOSE, [PWEB_CAP_NETWORK_SOCKET]);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_SUBSCRIBE);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_UNSUBSCRIBE);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod('Live.Snapshot');
    for i := 0 to High(METHODS) do
      b.RegisterZeroCapMethod(METHODS[i]);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

var
  root, fixture, outFile: TFileName;
  server: TRestServerFullMemory;
  realBridge, chain, bridge: IInvocationBridge;
  socketBridge: TPWebSocketBridge;
  policyRef: ICapabilityPolicy;
  store: IAssetStore;
  options: TPWebHostOptions;
  failures, json, origin: RawUtf8;
  i, hostExit: Integer;
  evalsTotal: Int64;

begin
  ExitCode := 0;
  failures := '';
  hostExit := -1;
  evalsTotal := 0;
  try
    root := RepoRootFromExecutable;
    if root = '' then
      raise Exception.Create('repository root (webview.lock marker) not found');
    fixture := root + 'build' + PathDelim + 'cap16' + PathDelim + 'fixture-live';
    if not FileExists(fixture + PathDelim + 'sdk' + PathDelim + 'index.js') then
      raise Exception.Create('the staged fixture is missing - run build_cap16.ps1: ' +
        string(fixture));
    outFile := root + 'build' + PathDelim + 'cap16' + PathDelim + 'live-' +
      TARGET_ID + '.json';
    // qualified: the Windows unit declares a function of the same name
    Port := StrToIntDef(sysutils.GetEnvironmentVariable('PWEB_CAP16_WS_PORT'), 0);
    LogBytes := BuildLog;
    Blobs := TPWebMemoryBlobStore.Create;

    server := TRestServerFullMemory.CreateWithOwnModel([]);
    if server.ServiceRegister(TLive, [TypeInfo(ILive)], sicShared) = nil then
      raise Exception.Create('unable to register Live');
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    // THE TEMPLATE'S CHAIN: runtime commands, the socket door, the channel
    chain := PWebHostRuntimeBridge(realBridge);
    // the witness's loopback origin when there is one; otherwise an origin
    // nothing answers, so the door is composed exactly as a network host's
    if Port > 0 then
      origin := 'http://127.0.0.1:' + RawUtf8(IntToStr(Port))
    else
      origin := 'https://cap16.invalid';
    socketBridge := TPWebSocketBridge.Create(chain, PWebSocketNativeTransport,
      [origin]);
    chain := socketBridge;
    Signals := TPWebSignalChannel.Create(chain,
      ['cap16.tick', 'cap16.flood', 'cap16.denied']);
    chain := Signals;
    socketBridge.AttachSignals(Signals);
    bridge := TLiveBridge.Create(chain);
    Policy := BuildPolicy;
    policyRef := Policy;

    options := PWebDefaultHostOptions(WINDOW_TITLE, LOG_PREFIX);
    options.Signals := Signals;
    options.Blobs := Blobs;
    store := TFolderAssetStore.Create(fixture);
    WriteLn(LOG_PREFIX, ': target=', TARGET_ID, ' port=', Port);
    Flush(Output);
    hostExit := PWebHostRun(options, Policy, bridge, store);
    WriteLn(LOG_PREFIX, ': host exit ', hostExit);

    if Flood <> nil then
    begin
      Flood.WaitFor;
      FreeAndNil(Flood);
    end;
    for i := 0 to High(Later) do
    begin
      Later[i].WaitFor;
      Later[i].Free;
    end;
    evalsTotal := Signals.EvalCount;
    if hostExit <> 0 then
      failures := failures + 'the host exited ' + RawUtf8(IntToStr(hostExit)) + '; ';
    if PageReport = '' then
    begin
      failures := failures + 'no page report arrived; ';
      PageReport := 'null';
    end;
    if Phases < 2 then
      failures := failures + 'the page never reached its second document; ';
    json := '{' + #10 +
      '  "schema": 1,' + #10 +
      '  "target": "' + TARGET_ID + '",' + #10 +
      '  "host_exit": ' + RawUtf8(IntToStr(hostExit)) + ',' + #10 +
      '  "port": ' + RawUtf8(IntToStr(Port)) + ',' + #10 +
      '  "evals_total": ' + RawUtf8(IntToStr(evalsTotal)) + ',' + #10 +
      '  "signals_total": ' + RawUtf8(IntToStr(Signals.SignalCount)) + ',' + #10 +
      '  "dispatches_total": ' + RawUtf8(IntToStr(Signals.DispatchCount)) + ',' + #10 +
      '  "ticks_per_second": ' + RawUtf8(IntToStr(PWEB_SIGNAL_TICKS_PER_SECOND)) + ',' + #10 +
      '  "blob_bytes": ' + RawUtf8(IntToStr(BLOB_BYTES)) + ',' + #10 +
      '  "blob_fnv": ' + RawUtf8(IntToStr(Fnv1a(LogBytes))) + ',' + #10 +
      '  "grants_slot_released": ' +
        RawUtf8(BoolToStr(not Assigned(Policy.OnGrantsChanged), 'true', 'false')) + ',' + #10 +
      '  "failures": ' + QuotedStrJson(failures) + ',' + #10 +
      '  "page": ' + PageReport + #10 + '}' + #10;
    ForceDirectories(ExtractFilePath(outFile));
    FileFromString(json, outFile);
    WriteLn(LOG_PREFIX, ': wrote ', outFile);
  except
    on E: Exception do
    begin
      failures := failures + RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message);
      ExitCode := 1;
    end;
  end;
  bridge := nil;
  chain := nil;
  realBridge := nil;
  policyRef := nil;
  Blobs := nil;
  if failures <> '' then
  begin
    WriteLn(StdErr, MARKER_FAIL, ' ', failures);
    ExitCode := 1;
  end
  else
    WriteLn(MARKER_PASS, ' target=', TARGET_ID);
end.
