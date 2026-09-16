program blobprobe;

{ CAP-12A: the blob data-plane measurement host. A SPIKE, not a product.

  ONE instrumented window per engine. It puts a THROWAWAY store behind the
  pweb://app scheme seam - the real TFolderAssetStore for the fixture's own
  assets, a synthetic producer for the reserved `_pweb/blob/` prefix - and
  asks the five questions CAP-12A was named to answer:

    M1  can the handler deliver a body in CHUNKS the page observes before
        the body ends, and does text/event-stream deliver live;
    M2  is a Range request header surfaced to the handler, and is a 206 with
        Content-Range honoured by fetch() and by a media element;
    M3  does a fetch() POST body reach the handler, as bytes or as a stream,
        at 1 / 16 / 256 MiB;
    M4  what a 256 MiB body costs in RSS streamed versus whole, how many
        scheme requests the engine runs at once, and what a slow producer
        does to the page's other requests and to the GUI thread;
    M5  is answered by the artifact, from what M1-M4 measured.

  WHAT IS PRODUCTION HERE, unchanged and linked from src/: PWebParseAppUri
  and the canonical asset-path rules, TFolderAssetStore behind the frozen
  IAssetStore, PWEB_NATIVE_CSP and PWebNativeSecurityHeaders on every
  response, and the platform unit whose initialization masks the FPU traps
  the engine cannot survive.

  WHAT IS THE SPIKE: the per-engine handler under test/cap12a/, because the
  PRODUCTION handler cannot answer M1-M3 by construction - it serves whole,
  already-materialised bytes from a frozen TryRead. Measuring streaming
  through it would measure the adapter rather than the engine.

  NOTHING HERE MAY BECOME A CI STEP. It puts a throwaway store behind the
  production seam, and a gate that does that is a gate that can normalise
  it. }

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
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.assets.intf,
  pweb.assets.folder,
  pweb.assets.support,
  pweb.navigation.policy,
  {$ifdef LINUX}
  // the production Linux adapter is linked for its initialization, which
  // masks the six FPU exceptions GTK cannot survive; nothing constructs it
  pweb.platform.webkitgtk,
  spikegtk,
  {$else}
  spikewv2,
  {$endif LINUX}
  blobsource,
  pweb.test.reporoot;

const
  LOG_PREFIX = 'blobprobe';
  MARKER_PASS = 'blobprobe: CAP-12A MEASUREMENT COMPLETE';
  MARKER_FAIL = 'blobprobe: CAP-12A MEASUREMENT FAIL';
  {$ifdef LINUX}
  TARGET_ID = 'linux-x86_64';
  {$else}
  TARGET_ID = 'windows-x86_64';
  {$endif LINUX}

  // the page's own rows are individually bounded; this is the backstop for a
  // window that never reports at all
  DEFAULT_TIMEOUT_MS = 600000;
  MAX_TIMEOUT_MS = 1200000;
  CLOSER_WAIT_MARGIN_MS = 15000;

type
  {$ifdef LINUX}
  TSpikeHandler = TSpikeGtkHandler;
  {$else}
  TSpikeHandler = TSpikeWv2Handler;
  {$endif LINUX}

var
  ReportLatch: LongInt;
  ReportJson: RawUtf8;
  AutoCloseHandle: Pointer;
  WatchdogEvent: PRTLEvent;
  MarkCount: LongInt;
  RssPhases: RawUtf8;
  RssPhaseSep: RawUtf8;
  CurrentPhase: RawUtf8;
  CurrentPhaseBase: Int64;

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
  end;
end;

procedure RequestTerminate;
var
  handle: Pointer;
begin
  handle := InterlockedExchange(AutoCloseHandle, nil);
  if handle <> nil then
    webview_dispatch(webview_t(handle), @TerminateOnGuiThread, nil);
end;

function WatchdogThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  RTLEventWaitFor(WatchdogEvent, PtrInt(Param));
  RequestTerminate;
end;

{ Extract the first JSON string of a webview_bind request array. The bind
  argument is always ["...."] here, so a full parser would be surface with
  no measurement behind it; anything that is not that shape yields ''. }
function FirstJsonString(const Req: RawUtf8): RawUtf8;
var
  i, n: PtrInt;
  c: AnsiChar;
begin
  Result := '';
  n := Length(Req);
  i := 1;
  while (i <= n) and (Req[i] <> '"') do
    Inc(i);
  if i > n then
    exit;
  Inc(i);
  while i <= n do
  begin
    c := Req[i];
    if c = '"' then
      exit;
    if c = '\' then
    begin
      Inc(i);
      if i > n then
        exit;
      case Req[i] of
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        't': Result := Result + #9;
        'u':
          begin
            // the labels this probe sends are ASCII by construction; a \u
            // escape means the page sent something this instrument does not
            // define, and swallowing it silently would hide that
            Result := Result + '?';
            Inc(i, 4);
          end;
      else
        Result := Result + Req[i];
      end;
    end
    else
      Result := Result + c;
    Inc(i);
  end;
end;

{ The RSS accounting. A row that says "peak RSS" must say peak OVER WHAT, so
  each phase is opened with a baseline and closed with the sampler's running
  maximum since that baseline. The phases are named by the page. }
procedure PhaseBegin(const Name: RawUtf8);
begin
  CurrentPhase := Name;
  CurrentPhaseBase := RssMarkBaseline;
end;

procedure PhaseEnd(const Name: RawUtf8);
var
  peak: Int64;
begin
  if CurrentPhase = '' then
    exit;
  peak := RssPeakBytes;
  RssPhases := RssPhases + RssPhaseSep + '{"phase":' + JsonQuote(CurrentPhase) +
    ',"baseline_bytes":' + RawUtf8(IntToStr(CurrentPhaseBase)) +
    ',"peak_bytes":' + RawUtf8(IntToStr(peak)) +
    ',"delta_bytes":' + RawUtf8(IntToStr(peak - CurrentPhaseBase)) + '}';
  RssPhaseSep := ',';
  CurrentPhase := '';
end;

procedure OnMark(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  label_: RawUtf8;
  n: PtrInt;
begin
  try
    InterlockedIncrement(MarkCount);
    label_ := FirstJsonString(RawUtf8(req));
    Mark(label_);
    // the memory phases are opened and closed by the page's own marks, so a
    // peak is always attributed to the row that caused it
    n := Length(label_);
    if (n > 6) and (Copy(label_, n - 5, 6) = '.begin') then
      PhaseBegin(Copy(label_, 1, n - 6))
    else if (n > 4) and (Copy(label_, n - 3, 4) = '.end') then
      PhaseEnd(Copy(label_, 1, n - 4));
  except
  end;
  try
    webview_return(webview_t(arg), id, 0, 'null');
  except
  end;
end;

procedure OnReport(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
begin
  try
    if InterlockedIncrement(ReportLatch) = 1 then
    begin
      ReportJson := FirstJsonString(RawUtf8(req));
      Mark('page.report', '', Length(ReportJson));
    end;
  except
  end;
  try
    webview_return(webview_t(arg), id, 0, 'null');
  except
  end;
  RequestTerminate;
end;

{$ifdef LINUX}
procedure CheckGtkDisplayUsable;
var
  reason: RawUtf8;
begin
  reason := PWebGtkDisplayUnavailableReason;
  if reason = '' then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': GTK DISPLAY UNAVAILABLE (', reason, ')');
  raise Exception.Create('no usable display - no WebView was created');
end;
{$endif LINUX}

function EnvInt(const AName: string; ADefault, AMax: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(AName), ADefault);
  if (Result <= 0) or (Result > AMax) then
    Result := ADefault;
end;

var
  w: webview_t;
  store: IAssetStore;
  handler: TSpikeHandler;
  root, fixtureDir: TFileName;
  outFile: TFileName;
  timeoutMs: Integer;
  closerId, closerHandle: system.TThreadID;
  closerStarted, safeToDestroy: Boolean;
  failReasons: RawUtf8;
  json, pageReport: RawUtf8;
  stream: TFileStream;

procedure Fail(const AReason: RawUtf8);
begin
  if failReasons <> '' then
    failReasons := failReasons + '; ';
  failReasons := failReasons + AReason;
end;

begin
  ExitCode := 0;
  handler := nil;
  closerStarted := False;
  safeToDestroy := True;
  failReasons := '';
  RssPhases := '';
  RssPhaseSep := '';
  CurrentPhase := '';
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock marker) not found');
      fixtureDir := root + 'test' + PathDelim + 'cap12a' + PathDelim + 'fixture';
      if not FileExists(fixtureDir + PathDelim + 'index.html') then
        raise Exception.Create('fixture missing: ' + string(fixtureDir));

      outFile := root + 'build' + PathDelim + 'cap12a' + PathDelim +
        TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));

      timeoutMs := EnvInt('PWEB_CAP12A_TIMEOUT_MS', DEFAULT_TIMEOUT_MS,
        MAX_TIMEOUT_MS);

      WriteLn(LOG_PREFIX, ': target=', TARGET_ID);
      WriteLn(LOG_PREFIX, ': csp=', PWEB_NATIVE_CSP);
      WriteLn(LOG_PREFIX, ': fixture=', fixtureDir);

      TimelineReset;
      RssSamplerStart(10);
      Mark('host.start', TARGET_ID, ProcessRssBytes);

      store := TFolderAssetStore.Create(fixtureDir);

      {$ifdef LINUX}
      CheckGtkDisplayUsable;
      {$endif LINUX}

      if GetEnvironmentVariable('PWEB_CAP12A_DEBUG') = '1' then
        w := WebViewCheckCreated(webview_create(1, nil))
      else
        w := WebViewCheckCreated(webview_create(0, nil));
      try
        AutoCloseHandle := Pointer(w);
        WebViewCheck(webview_set_title(w, 'PWeb CAP-12A blob probe'),
          'webview_set_title');
        WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
          'webview_set_size');
        // the bind callbacks answer synchronously with a constant `null`.
        // They enqueue nothing and compute nothing: their ONLY job is to put
        // a host-clock timestamp on a page event, and a round trip through a
        // scheduler would put the scheduler's latency into every M1 row.
        WebViewCheck(webview_bind(w, '__cap12a_mark', @OnMark, Pointer(w)),
          'webview_bind __cap12a_mark');
        WebViewCheck(webview_bind(w, '__cap12a_report', @OnReport, Pointer(w)),
          'webview_bind __cap12a_report');

        WriteLn(LOG_PREFIX, ': attaching the spike handler');
        handler := TSpikeHandler.Create(w, store);
        WriteLn(LOG_PREFIX, ': handler attached');

        WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

        WatchdogEvent := RTLEventCreate;
        closerHandle := BeginThread(@WatchdogThread,
          Pointer(PtrInt(timeoutMs)), closerId);
        closerStarted := closerHandle <> system.TThreadID(0);
        if not closerStarted then
          raise Exception.Create('unable to start the watchdog thread');
        WebViewCheck(webview_run(w), 'webview_run');
      finally
        if closerStarted then
        begin
          InterlockedExchange(AutoCloseHandle, nil);
          RTLEventSetEvent(WatchdogEvent);
          if WaitForThreadTerminate(closerHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL watchdog did not terminate');
            safeToDestroy := False;
            ExitCode := 1;
          end;
          CloseThread(closerHandle);
        end;
        if WatchdogEvent <> nil then
        begin
          if safeToDestroy then
            RTLEventDestroy(WatchdogEvent);
          WatchdogEvent := nil;
        end;
        InterlockedExchange(AutoCloseHandle, nil);
        if handler <> nil then
        begin
          try
            handler.Detach;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL handler Detach: ', E.Message);
              ExitCode := 1;
            end;
          end;
          FreeAndNil(handler);
        end;
        if safeToDestroy then
          try
            WebViewCheck(webview_destroy(w), 'webview_destroy');
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL webview_destroy: ', E.Message);
              ExitCode := 1;
            end;
          end;
      end;

      Mark('host.stop', '', ProcessRssBytes);
      RssSamplerStop;

      pageReport := ReportJson;
      if pageReport = '' then
      begin
        Fail('no page report arrived (watchdog or crash)');
        pageReport := 'null';
      end;
      if MarkCount = 0 then
        Fail('no page mark arrived - the bound seam never worked');
      if TimelineDropped > 0 then
        Fail('the timeline overflowed by ' +
          RawUtf8(IntToStr(TimelineDropped)) + ' events - every M1 verdict ' +
          'that rests on a production timestamp is unsafe');

      json := '{' + #10 +
        '  "schema": 1,' + #10 +
        '  "target": "' + TARGET_ID + '",' + #10 +
        '  "csp": ' + JsonQuote(PWEB_NATIVE_CSP) + ',' + #10 +
        '  "security_headers": ' + JsonQuote(PWebNativeSecurityHeaders) + ',' + #10 +
        '  "blob_prefix": ' + JsonQuote(CAP12A_BLOB_PREFIX) + ',' + #10 +
        '  "overall": "';
      if failReasons = '' then
        json := json + 'COMPLETE'
      else
        json := json + 'INCOMPLETE';
      json := json + '",' + #10;
      if failReasons <> '' then
        json := json + '  "failures": ' + JsonQuote(failReasons) + ',' + #10;
      json := json +
        '  "engine_facts": {' + #10 +
        '    ' + SpikeFactsJson + #10 +
        '  },' + #10 +
        '  "marks": ' + RawUtf8(IntToStr(MarkCount)) + ',' + #10 +
        '  "timeline_events": ' + RawUtf8(IntToStr(TimelineCount)) + ',' + #10 +
        '  "timeline_dropped": ' + RawUtf8(IntToStr(TimelineDropped)) + ',' + #10 +
        '  "rss_samples": ' + RawUtf8(IntToStr(RssSamples)) + ',' + #10 +
        '  "rss_phases": [' + RssPhases + '],' + #10 +
        '  "timeline": ' + TimelineJson + ',' + #10 +
        '  "page": ' + pageReport + #10 +
        '}' + #10;

      stream := TFileStream.Create(outFile, fmCreate);
      try
        if json <> '' then
          stream.WriteBuffer(json[1], Length(json));
      finally
        stream.Free;
      end;
      WriteLn(LOG_PREFIX, ': wrote ', outFile);

      if failReasons = '' then
        WriteLn(MARKER_PASS)
      else
      begin
        WriteLn(StdErr, MARKER_FAIL, ' (', failReasons, ')');
        ExitCode := 1;
      end;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL ', E.ClassName, ': ', E.Message);
        WriteLn(StdErr, MARKER_FAIL, ' (', E.Message, ')');
        ExitCode := 1;
      end;
    end;
  finally
    try
      RssSamplerStop;
      store := nil;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL final teardown: ', E.Message);
        ExitCode := 1;
      end;
    end;
  end;
end.
