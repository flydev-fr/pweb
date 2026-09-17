program evalprobe;

{ CAP-16: THE ENGINE FACTS BEHIND THE ONE INJECTED SCRIPT.

  CAP-16 adds the first script the RUNTIME writes into a page. Three facts
  about each engine decide whether that is sound, and none of them is a
  property of PWeb's own code, so they are measured here with the engine
  and nothing of the channel but its encoder:

    csp       a script evaluated natively RUNS under PWEB_NATIVE_CSP - no
              'unsafe-inline', no 'unsafe-eval' - while the page's own
              eval, Function and inline script are refused by that CSP
    ordering  K scripts evaluated from K separate GUI dispatches, and K
              evaluated back to back inside ONE dispatch, arrive in the
              order they were issued - or they do not, and the row says so;
              the channel's sequence numbers are what the SDK trusts either
              way
    hostile   PWebSignalScript, THE PRODUCTION ENCODER, given topics no
              declared topic could ever be - quotes, a backslash, a closing
              script tag, U+2028, U+2029, a NUL, invalid UTF-8, template
              syntax - produces scripts that deliver exactly those strings
              and run nothing they spell

  WHAT IS PRODUCTION HERE: the platform asset handler, the navigation guard,
  PWEB_NATIVE_CSP on every response, the folder store behind the frozen
  IAssetStore, and PWebSignalScript. The webview_eval calls are THIS
  harness's: it is an instrument, never a host, and test/cap16's source
  gate counts eval sites in src/** only.

  It writes build/cap16/evalprobe-<target>.json and prints one marker line.

  Usage: evalprobe [env PWEB_CAP16_TIMEOUT_MS] }

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
  mormot.core.json,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.assets.intf,
  pweb.assets.folder,
  pweb.navigation.policy,
  pweb.rpc.signal,
  {$ifdef DARWIN}
  pweb.platform.cocoa,
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk,
  {$else}
  pweb.platform.webview2,
  {$endif LINUX}
  {$endif DARWIN}
  pweb.test.reporoot;

const
  LOG_PREFIX = 'evalprobe';
  MARKER_PASS = 'evalprobe: CAP-16 ENGINE PROBE PASS';
  MARKER_FAIL = 'evalprobe: CAP-16 ENGINE PROBE FAIL';
  {$ifdef DARWIN}
    {$ifdef CPUAARCH64}
  TARGET_ID = 'macos-arm64';
    {$else}
  TARGET_ID = 'macos-x64';
    {$endif CPUAARCH64}
  ENGINE_ID = 'wkwebview';
  {$else}
  {$ifdef LINUX}
  TARGET_ID = 'linux';
  ENGINE_ID = 'webkitgtk';
  {$else}
  TARGET_ID = 'windows';
  ENGINE_ID = 'webview2';
  {$endif LINUX}
  {$endif DARWIN}

  OWNER = 'window:main';
  K = 100;
  HOSTILE_BASE = 10000;
  HOSTILE_COUNT = 18;

  DEFAULT_TIMEOUT_MS = 120000;
  MAX_TIMEOUT_MS = 600000;
  CLOSER_WAIT_MARGIN_MS = 30000;

  OVERALL: array[Boolean] of RawUtf8 = ('INCOMPLETE', 'COMPLETE');

type
  {$ifdef DARWIN}
  TLiveHandler = TCocoaAssetHandler;
  TLiveGuard = TCocoaNavigationGuard;
  {$else}
  {$ifdef LINUX}
  TLiveHandler = TWebKitGtkAssetHandler;
  TLiveGuard = TWebKitGtkNavigationGuard;
  {$else}
  TLiveHandler = TWebView2AssetHandler;
  TLiveGuard = TWebView2NavigationGuard;
  {$endif LINUX}
  {$endif DARWIN}

var
  AutoCloseHandle: Pointer = nil;
  ViewHandle: Pointer = nil;
  WatchdogEvent: PRTLEvent = nil;
  PageReport: RawUtf8 = '';
  NativeEvals: LongInt = 0;
  DriverStarted: LongInt = 0;
  DriverHandle: system.TThreadID = system.TThreadID(0);
  DriverId: system.TThreadID;
  Hostile: array[0 .. HOSTILE_COUNT - 1] of RawUtf8;

procedure BuildHostile;
begin
  Hostile[0] := '"';
  Hostile[1] := '\';
  Hostile[2] := '</script><script>window.__cap16_pwned=1</script>';
  Hostile[3] := #$E2#$80#$A8;
  Hostile[4] := #$E2#$80#$A9;
  Hostile[5] := '''';
  Hostile[6] := '"]);window.__cap16_pwned=1;//';
  Hostile[7] := #10;
  Hostile[8] := '${window.__cap16_pwned=1}';
  Hostile[9] := #$F0#$9F#$98#$80;
  Hostile[10] := #$C3#$28;
  Hostile[11] := #0;
  Hostile[12] := '<!--';
  Hostile[13] := '-->';
  Hostile[14] := #$EF#$BB#$BF;
  Hostile[15] := #$C2#$85;
  Hostile[16] := '`);window.__cap16_pwned=1;`';
  Hostile[17] := #$ED#$A0#$80'x';
end;

function OnePair(const Topic: RawUtf8; Seq: Int64): TPWebSignalPairs;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Topic := Topic;
  Result[0].Seq := Seq;
end;

procedure EvalScript(w: webview_t; const Script: RawUtf8);
begin
  InterlockedIncrement(NativeEvals);
  webview_eval(w, PAnsiChar(pointer(Script)));
end;

procedure EvalDispatchOne(w: webview_t; arg: Pointer); cdecl;
begin
  try
    EvalScript(w, PWebSignalScript(OnePair('cap16.dispatch', PtrInt(arg))));
  except
  end;
end;

procedure EvalBurst(w: webview_t; arg: Pointer); cdecl;
var
  i: Integer;
begin
  try
    for i := 1 to K do
      EvalScript(w, PWebSignalScript(OnePair('cap16.burst', i)));
  except
  end;
end;

procedure EvalHostile(w: webview_t; arg: Pointer); cdecl;
var
  i: Integer;
begin
  try
    for i := 0 to HOSTILE_COUNT - 1 do
      EvalScript(w, PWebSignalScript(OnePair(Hostile[i], HOSTILE_BASE + i)));
  except
  end;
end;

procedure EvalDone(w: webview_t; arg: Pointer); cdecl;
begin
  try
    EvalScript(w, PWebSignalScript(OnePair('cap16.done', 1)));
  except
  end;
end;

function DriverThread(Param: Pointer): PtrInt;
var
  i: Integer;
  h: webview_t;
begin
  Result := 0;
  h := webview_t(ViewHandle);
  // K SEPARATE dispatches, from a worker, as the channel's pacer issues them
  for i := 1 to K do
    webview_dispatch(h, @EvalDispatchOne, Pointer(PtrInt(i)));
  webview_dispatch(h, @EvalBurst, nil);
  webview_dispatch(h, @EvalHostile, nil);
  webview_dispatch(h, @EvalDone, nil);
end;

{ ---- the watchdog ---- }

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

{ ---- the page bindings ---- }

// the first argument, verbatim, as JSON (see test/cap12b/bloblive.pas)
function FirstJsonArgument(req: PAnsiChar): RawUtf8;
var
  all: RawUtf8;
  i, j: PtrInt;
begin
  Result := '';
  if req = nil then
    exit;
  FastSetString(all, req, StrLen(req));
  i := 1;
  while (i <= Length(all)) and (all[i] <= ' ') do
    Inc(i);
  if (i > Length(all)) or (all[i] <> '[') then
    exit;
  j := Length(all);
  while (j > i) and (all[j] <= ' ') do
    Dec(j);
  if (j <= i) or (all[j] <> ']') then
    exit;
  Result := Copy(all, i + 1, j - i - 1);
  // a two-argument call: keep the first only
  if (Result <> '') and (Result[1] <> '{') and (Pos(',', Result) > 0) then
    Result := Copy(Result, 1, Pos(',', Result) - 1);
  Result := Trim(Result);
end;

procedure OnReady(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
begin
  try
    if InterlockedIncrement(DriverStarted) = 1 then
      DriverHandle := BeginThread(@DriverThread, nil, DriverId);
    webview_return(webview_t(arg), id, 0, 'null');
  except
  end;
end;

procedure OnReport(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
begin
  try
    if PageReport = '' then
      PageReport := FirstJsonArgument(req);
  except
  end;
  try
    webview_return(webview_t(arg), id, 0, 'null');
  except
  end;
  RequestTerminate;
end;

function EnvInt(const AName: string; ADefault, AMax: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(AName), ADefault);
  if (Result <= 0) or (Result > AMax) then
    Result := ADefault;
end;

{$ifdef DARWIN}
procedure CheckCocoaRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create('FPU traps could not be masked - no WebView created');
end;
{$endif DARWIN}

var
  w: webview_t;
  store: IAssetStore;
  handler: TLiveHandler;
  guard: TLiveGuard;
  root, fixtureDir, outFile: TFileName;
  timeoutMs: Integer;
  closerId, closerHandle: system.TThreadID;
  closerStarted, safeToDestroy: Boolean;
  failReasons, json: RawUtf8;

procedure Fail(const AReason: RawUtf8);
begin
  if failReasons <> '' then
    failReasons := failReasons + '; ';
  failReasons := failReasons + AReason;
end;

begin
  ExitCode := 0;
  handler := nil;
  guard := nil;
  closerStarted := False;
  safeToDestroy := True;
  failReasons := '';
  BuildHostile;
  try
    root := RepoRootFromExecutable;
    if root = '' then
      raise Exception.Create('repository root (webview.lock marker) not found');
    fixtureDir := root + 'test' + PathDelim + 'cap16' + PathDelim +
      'fixture' + PathDelim + 'probe';
    if not FileExists(fixtureDir + PathDelim + 'index.html') then
      raise Exception.Create('fixture missing: ' + string(fixtureDir));
    outFile := root + 'build' + PathDelim + 'cap16' + PathDelim +
      'evalprobe-' + TARGET_ID + '.json';
    if not ForceDirectories(ExtractFilePath(outFile)) then
      raise Exception.Create('unable to create ' +
        string(ExtractFilePath(outFile)));
    timeoutMs := EnvInt('PWEB_CAP16_TIMEOUT_MS', DEFAULT_TIMEOUT_MS,
      MAX_TIMEOUT_MS);
    WriteLn(LOG_PREFIX, ': target=', TARGET_ID, ' engine=', ENGINE_ID);
    WriteLn(LOG_PREFIX, ': csp=', PWEB_NATIVE_CSP);

    store := TFolderAssetStore.Create(fixtureDir);
    {$ifdef DARWIN}
    CheckCocoaRuntimeUsable;
    handler := TLiveHandler.Create(store, nil, OWNER);
    {$endif DARWIN}

    w := WebViewCheckCreated(webview_create(0, nil));
    try
      {$ifdef DARWIN}
      handler.Attach(w);
      {$endif DARWIN}
      AutoCloseHandle := Pointer(w);
      ViewHandle := Pointer(w);
      WebViewCheck(webview_set_title(w, 'PWeb CAP-16 engine probe'),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      WebViewCheck(webview_bind(w, '__cap16_probe_ready', @OnReady,
        Pointer(w)), 'webview_bind __cap16_probe_ready');
      WebViewCheck(webview_bind(w, '__cap16_probe_report', @OnReport,
        Pointer(w)), 'webview_bind __cap16_probe_report');
      {$ifndef DARWIN}
      handler := TLiveHandler.Create(w, store, nil, OWNER);
      {$endif DARWIN}
      {$ifdef DARWIN}
      guard := TLiveGuard.Create;
      guard.Attach(w);
      {$else}
      guard := TLiveGuard.Create(w);
      {$endif DARWIN}
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
      if DriverHandle <> system.TThreadID(0) then
      begin
        if WaitForThreadTerminate(DriverHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          Fail('the driver thread did not terminate');
          safeToDestroy := False;
        end;
        CloseThread(DriverHandle);
      end;
      if WatchdogEvent <> nil then
      begin
        if safeToDestroy then
          RTLEventDestroy(WatchdogEvent);
        WatchdogEvent := nil;
      end;
      InterlockedExchange(AutoCloseHandle, nil);
      ViewHandle := nil;
      if guard <> nil then
      begin
        try
          guard.Detach;
        except
          on E: Exception do
            Fail('guard Detach: ' + RawUtf8(E.Message));
        end;
        FreeAndNil(guard);
      end;
      if handler <> nil then
      begin
        try
          handler.Detach;
        except
          on E: Exception do
            Fail('handler Detach: ' + RawUtf8(E.Message));
        end;
        FreeAndNil(handler);
      end;
      if safeToDestroy then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
        except
          on E: Exception do
            Fail('webview_destroy: ' + RawUtf8(E.Message));
        end;
    end;

    if PageReport = '' then
    begin
      Fail('no page report arrived');
      PageReport := 'null';
    end;
    if NativeEvals <> 2 * K + HOSTILE_COUNT + 1 then
      Fail('the driver issued ' + RawUtf8(IntToStr(NativeEvals)) +
        ' scripts, expected ' + RawUtf8(IntToStr(2 * K + HOSTILE_COUNT + 1)));

    json := '{' + #13#10 +
      '  "schema": 1,' + #13#10 +
      '  "target": "' + TARGET_ID + '",' + #13#10 +
      '  "engine": "' + ENGINE_ID + '",' + #13#10 +
      '  "csp": ' + QuotedStrJson(PWEB_NATIVE_CSP) + ',' + #13#10 +
      '  "template": ' + QuotedStrJson(PWEB_SIGNAL_EVAL_TEMPLATE) + ',' + #13#10 +
      '  "native_evals": ' + RawUtf8(IntToStr(NativeEvals)) + ',' + #13#10 +
      '  "k": ' + RawUtf8(IntToStr(K)) + ',' + #13#10 +
      '  "hostile_cases": ' + RawUtf8(IntToStr(HOSTILE_COUNT)) + ',' + #13#10 +
      '  "overall": "' + OVERALL[failReasons = ''] + '",' + #13#10 +
      '  "failures": ' + QuotedStrJson(failReasons) + ',' + #13#10 +
      '  "page": ' + PageReport + #13#10 + '}' + #13#10;
    FileFromString(json, outFile);
    WriteLn(LOG_PREFIX, ': wrote ', outFile);
  except
    on E: Exception do
    begin
      Fail(RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message));
      ExitCode := 1;
    end;
  end;
  if failReasons <> '' then
  begin
    WriteLn(StdErr, MARKER_FAIL, ' ', failReasons);
    ExitCode := 1;
  end
  else
    WriteLn(MARKER_PASS, ' target=', TARGET_ID);
end.
