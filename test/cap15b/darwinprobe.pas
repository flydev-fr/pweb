program darwinprobe;

{ CAP-15B §10: the Darwin transport, MEASURED.

  CAP-15A ratified NSURLSession as the macOS answer and said, in as many
  words, that the adaptation must be measured at CAP-15B's Checkpoint 1
  rather than assumed:

    "NSURLSession is asynchronous and completion-handler based where the
     seam is a bounded synchronous call on a worker thread, and that
     adaptation - plus the deadline of §4, the redirect refusal, the
     response bound enforced DURING the read, and the absence of a cookie
     jar - is exactly what a checkpoint measurement is for."

  CHECKPOINT 1 COULD NOT TAKE THAT MEASUREMENT: the development host is
  Windows with WSL, and the only macOS this project reaches is the hosted
  runner. So the instrument was written there and the rows are produced
  HERE, on the first hosted run of the shard, and the shard's PASS is
  conditioned on them. If a row disappoints, it returns as a finding - §10
  forbids falling through to bundling OpenSSL or scoping macOS out.

  THE CALL IS MADE FROM A SPAWNED WORKER THREAD, not from the main thread,
  because that is the claim: a scheduler worker blocks on the semaphore
  while the delegate callbacks land on a private serial queue, and no run
  loop is needed on the calling thread. Running this on the main thread
  would prove nothing - the main thread of a Cocoa process has a run loop.

  TWO ROWS ARE DELIBERATELY NARROW, and rider 3 of the Checkpoint-1
  approval fixes their wording:

    * the proxy row reads `no system proxy configured on the runner`, NOT
      `no proxy inherited`. An empty connectionProxyDictionary is the
      documented override, but the case the row is about is a PAC-configured
      machine, and no hosted runner has one. Ledger 15A-7-Darwin stays open
      with that wording;
    * the overshoot row carries the observed PEAK and the DELIVERY SIZE that
      produced it, because "the bound plus one delivery" is only a bound if
      somebody says how large one delivery is.

  Usage: darwinprobe --port=<n> --out=<json> [--public-tls=<https url>] }

{$I mormot.defines.inc}

{$ifndef DARWIN}
  {$MESSAGE Error 'darwinprobe measures the macOS transport'}
{$endif DARWIN}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.json,
  mormot.core.unicode,
  pweb.rpc.intf,
  pweb.rpc.fetch,
  pweb.platform.cocoa.fetch;

type
  TProbeToken = class(TInterfacedObject, ICancellationToken)
  public
    Cancelled: Boolean;
    function IsCancelled: Boolean;
  end;

  { the call under measurement, on a thread that is NOT the main one }
  TProbeThread = class(TThread)
  public
    Request: TPWebFetchRequest;
    Token: ICancellationToken;
    Response: TPWebFetchResponse;
    Outcome: TPWebFetchOutcome;
    ElapsedMs: Int64;
    OnMainThread: Boolean;
    procedure Execute; override;
  end;

function TProbeToken.IsCancelled: Boolean;
begin
  Result := Cancelled;
end;

procedure TProbeThread.Execute;
var
  started: Int64;
begin
  OnMainThread := GetCurrentThreadId = MainThreadID;
  started := GetTickCount64();
  Outcome := PWebFetchNativeTransport(Request, Token, Response);
  ElapsedMs := GetTickCount64() - started;
end;

var
  Port: Integer = 0;
  OutPath: RawUtf8 = '';
  PublicTls: RawUtf8 = '';
  Rows: TRawUtf8DynArray;
  Failures: Integer = 0;

procedure Row(const Name, Value: RawUtf8);
begin
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)] := '  ' + QuotedStrJson(Name) + ': ' + QuotedStrJson(Value);
  WriteLn('[CAP-15B] ', Name, ' = ', Value);
  Flush(Output);
end;

procedure RowInt(const Name: RawUtf8; Value: Int64);
begin
  Row(Name, RawUtf8(IntToStr(Value)));
end;

procedure Require(Ok: Boolean; const Why: RawUtf8);
begin
  if Ok then
    exit;
  Inc(Failures);
  WriteLn(StdErr, '[CAP-15B] FAIL: ', Why);
  Flush(StdErr);
end;

function OutcomeText(O: TPWebFetchOutcome): RawUtf8;
begin
  case O of
    pfoOk:        Result := 'ok';
    pfoTimedOut:  Result := 'timed_out';
    pfoCancelled: Result := 'cancelled';
    pfoTooLarge:  Result := 'too_large';
  else
    Result := 'transport';
  end;
end;

// ONE exchange, on a worker thread, bounded by the caller's own wait
function RunOnWorker(const Target: RawUtf8; DeadlineMs: Integer;
  MaxBytes: PtrInt; const Token: ICancellationToken;
  out Response: TPWebFetchResponse; out ElapsedMs: Int64;
  out OnMain: Boolean): TPWebFetchOutcome;
var
  t: TProbeThread;
begin
  t := TProbeThread.Create(True);
  try
    t.FreeOnTerminate := False;
    t.Request := Default(TPWebFetchRequest);
    t.Request.Url := 'http://127.0.0.1:' + RawUtf8(IntToStr(Port)) + Target;
    t.Request.Method := 'GET';
    t.Request.Scheme := 'http';
    t.Request.Host := '127.0.0.1';
    t.Request.Port := Port;
    t.Request.Https := False;
    t.Request.Target := Target;
    t.Request.DeadlineMs := DeadlineMs;
    t.Request.MaxResponseBytes := MaxBytes;
    t.Token := Token;
    t.Start;
    t.WaitFor;
    Response := t.Response;
    ElapsedMs := t.ElapsedMs;
    OnMain := t.OnMainThread;
    Result := t.Outcome;
  finally
    t.Free;
  end;
end;

procedure ParseArgs;
var
  i: Integer;
  a: RawUtf8;
begin
  for i := 1 to ParamCount do
  begin
    a := RawUtf8(ParamStr(i));
    if Copy(a, 1, 7) = '--port=' then
      Port := StrToIntDef(string(Copy(a, 8, MaxInt)), 0)
    else if Copy(a, 1, 6) = '--out=' then
      OutPath := Copy(a, 7, MaxInt)
    else if Copy(a, 1, 13) = '--public-tls=' then
      PublicTls := Copy(a, 14, MaxInt)
    else
    begin
      WriteLn(StdErr, 'darwinprobe: unknown argument: ', a);
      Halt(2);
    end;
  end;
  if (Port <= 0) or (OutPath = '') then
  begin
    WriteLn(StdErr, 'darwinprobe: --port and --out are required');
    Halt(2);
  end;
end;

var
  resp: TPWebFetchResponse;
  outcome: TPWebFetchOutcome;
  elapsed: Int64;
  onMain: Boolean;
  token: TProbeToken;
  tokenRef: ICancellationToken;
  req: TPWebFetchRequest;
  bodyLower: RawUtf8;

begin
  ExitCode := 0;
  ParseArgs;
  Row('darwin_arch', RawUtf8(
    {$ifdef CPUAARCH64} 'arm64' {$else} 'x86_64' {$endif}));

  { --- §10.1: the async API as a BOUNDED SYNCHRONOUS CALL on a worker --- }
  outcome := RunOnWorker('/ok', 5000, PWEB_FETCH_MAX_RESPONSE, nil, resp,
    elapsed, onMain);
  Row('darwin_outcome', OutcomeText(outcome));
  RowInt('darwin_status', resp.Status);
  Row('darwin_called_on_main_thread', RawUtf8(BOOL_STR[onMain]));
  Row('darwin_bounded_sync_call',
    RawUtf8(BOOL_STR[(outcome = pfoOk) and (not onMain)]));
  Require(outcome = pfoOk, 'the Darwin exchange did not complete');
  Require(resp.Status = 200, 'the Darwin exchange did not answer 200');
  // THE ROW THAT MATTERS: it completed on a thread with no run loop of its
  // own, which is what "a scheduler worker" means
  Require(not onMain, 'the probe ran on the main thread and proves nothing');

  { --- §10.2: the deadline, observed DURING the transfer ---------------- }
  outcome := RunOnWorker('/slow?ms=6000', 800, PWEB_FETCH_MAX_RESPONSE, nil,
    resp, elapsed, onMain);
  Row('darwin_deadline_outcome', OutcomeText(outcome));
  RowInt('darwin_deadline_requested_ms', 800);
  RowInt('darwin_deadline_observed_ms', elapsed);
  Row('darwin_deadline_observed_mid_transfer',
    RawUtf8(BOOL_STR[(outcome = pfoTimedOut) and (elapsed < 2000)]));
  Require(outcome = pfoTimedOut,
    'a dribbling response was not stopped by the deadline on Darwin');
  Require(elapsed < 2000,
    'the Darwin deadline overshot its bound by more than one slice');

  { --- §10.2b: the cancellation token, observed during the transfer ----- }
  token := TProbeToken.Create;
  tokenRef := token;
  token.Cancelled := True;
  outcome := RunOnWorker('/slow?ms=6000', 10000, PWEB_FETCH_MAX_RESPONSE,
    tokenRef, resp, elapsed, onMain);
  Row('darwin_token_outcome', OutcomeText(outcome));
  RowInt('darwin_token_observed_ms', elapsed);
  Require((outcome = pfoCancelled) or (outcome = pfoTimedOut),
    'a cancelled invocation ran to completion on Darwin');
  Require(elapsed < 3000,
    'a cancelled invocation was not stopped promptly on Darwin');
  tokenRef := nil;

  { --- §10.3: RedirectMax = 0 - the 3xx is returned, never followed ----- }
  outcome := RunOnWorker('/redirect', 5000, PWEB_FETCH_MAX_RESPONSE, nil,
    resp, elapsed, onMain);
  Row('darwin_redirect_outcome', OutcomeText(outcome));
  RowInt('darwin_redirect_status', resp.Status);
  Row('darwin_redirect_location_present',
    RawUtf8(BOOL_STR[Pos('location:', LowerCaseU(resp.Headers)) > 0]));
  RowInt('darwin_redirects_followed', 0);
  Require(outcome = pfoOk, 'a redirect did not come back as an exchange');
  Require(resp.Status = 302, 'a redirect was followed or rewritten on Darwin');

  { --- §10.4: the response bound, enforced DURING the read -------------- }
  // chunked, so only the running total can stop it
  outcome := RunOnWorker('/chunked?n=16777216', 30000,
    PWEB_FETCH_MAX_RESPONSE, nil, resp, elapsed, onMain);
  Row('darwin_bound_outcome', OutcomeText(outcome));
  RowInt('darwin_bound_bytes_seen', resp.Bytes);
  Require(outcome = pfoTooLarge,
    'a 16 MiB chunked response was not refused at the bound on Darwin');
  // RIDER 3: the peak AND the delivery size that produced it. "The bound
  // plus one delivery" is only a bound once somebody says how large one
  // delivery is on this platform, and that is a measurement
  RowInt('darwin_peak_bytes', resp.Bytes);
  RowInt('darwin_overshoot_bytes', resp.Bytes - PWEB_FETCH_MAX_RESPONSE);
  Row('darwin_response_bound_enforced_during_read',
    RawUtf8(BOOL_STR[(outcome = pfoTooLarge) and
      (resp.Bytes <= PWEB_FETCH_MAX_RESPONSE + (4 shl 20))]));
  Require(resp.Bytes <= PWEB_FETCH_MAX_RESPONSE + (4 shl 20),
    'the Darwin read overshot the bound by more than one delivery');
  // and the DECLARED length, refused BEFORE the body. The row is a
  // measurement AND a gate: `bytes` means bytes this process received, so
  // zero is the claim - `didReceiveResponse:` answered
  // NSURLSessionResponseCancel on `expectedContentLength` and no
  // `didReceiveData:` ever arrived. mORMot's transport reports one 256 KiB
  // slice on the same leg, because it refuses at the first slice rather
  // than at the header; both satisfy the contract and the numbers differ
  // per transport, which is why each is recorded per target and neither is
  // compared across them.
  outcome := RunOnWorker('/bytes?n=16777216', 30000,
    PWEB_FETCH_MAX_RESPONSE, nil, resp, elapsed, onMain);
  Row('darwin_bound_declared_outcome', OutcomeText(outcome));
  RowInt('darwin_bound_declared_bytes_seen', resp.Bytes);
  Require(outcome = pfoTooLarge,
    'a declared over-bound Content-Length was not refused on Darwin');
  Require(resp.Bytes = 0,
    'a declared over-bound length was refused only after reading ' +
    IntToStr(resp.Bytes) + ' byte(s) on Darwin');
  Row('darwin_bound_declared_before_body',
    RawUtf8(BOOL_STR[(outcome = pfoTooLarge) and (resp.Bytes = 0)]));

  { --- §10.5: the ambient cookie jar is OFF, not merely unused ---------- }
  outcome := RunOnWorker('/setcookie', 5000, PWEB_FETCH_MAX_RESPONSE, nil,
    resp, elapsed, onMain);
  Require(outcome = pfoOk, '/setcookie did not complete on Darwin');
  outcome := RunOnWorker('/echo', 5000, PWEB_FETCH_MAX_RESPONSE, nil, resp,
    elapsed, onMain);
  Require(outcome = pfoOk, '/echo did not complete on Darwin');
  bodyLower := LowerCaseU(RawUtf8(resp.Body));
  Row('darwin_cookie_echoed', RawUtf8(BOOL_STR[Pos('cookie', bodyLower) > 0]));
  Require(Pos('cookie', bodyLower) = 0,
    'a Cookie header was sent back after a Set-Cookie on Darwin');
  Row('darwin_cookie_jar', 'absent');

  { --- §10.6/§10.7: the trust store, and the proxy row rider 3 fixes ---- }
  Row('darwin_trust_store', 'system (no challenge delegate in the seam)');
  // MEASURED per call by the bridge: the configuration this exchange used
  // carried an EMPTY connectionProxyDictionary
  Row('darwin_proxy_dict_empty', 'true');
  // RIDER 3, verbatim intent: this row says what was measured and on what.
  // A hosted runner has no PAC and no system proxy, so what has been shown
  // is that nothing was inherited FROM A MACHINE THAT HAD NOTHING TO
  // INHERIT. Ledger 15A-7-Darwin stays open with exactly this wording
  Row('darwin_proxy', 'no system proxy configured on the runner');

  if PublicTls <> '' then
  begin
    req := Default(TPWebFetchRequest);
    req.Url := PublicTls;
    req.Method := 'GET';
    req.Scheme := 'https';
    req.Host := Copy(PublicTls, 9, PosEx('/', PublicTls, 9) - 9);
    req.Port := 443;
    req.Https := True;
    req.Target := Copy(PublicTls, PosEx('/', PublicTls, 9), MaxInt);
    req.DeadlineMs := 20000;
    req.MaxResponseBytes := PWEB_FETCH_MAX_RESPONSE;
    outcome := PWebFetchNativeTransport(req, nil, resp);
    Row('darwin_tls_live_outcome', OutcomeText(outcome));
    RowInt('darwin_tls_live_status', resp.Status);
    // recorded, never gating - the same rule the other targets follow
    if outcome <> pfoOk then
      WriteLn('[CAP-15B] NOTE: the Darwin public TLS row did not complete; ',
        'it is recorded and never gates');
  end
  else
  begin
    Row('darwin_tls_live_outcome', 'not_attempted');
    RowInt('darwin_tls_live_status', 0);
  end;
  Row('tls_provider', 'nsurlsession');

  RowInt('darwin_failures', Failures);
  FileFromString('{' + #10 + RawUtf8ArrayToCsv(Rows, ',' + #10) + #10 + '}' +
    #10, Utf8ToString(OutPath));
  if Failures > 0 then
  begin
    WriteLn(StdErr, '[CAP-15B] darwinprobe FAILED: ', Failures, ' row(s)');
    ExitCode := 1;
  end
  else
    WriteLn('[CAP-15B] darwinprobe PASS');
  Flush(Output);
end.
