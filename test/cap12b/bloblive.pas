program bloblive;

{ CAP-12B: the blob data plane through the PRODUCTION handlers, in a real
  window, on four targets.

  WHAT IS PRODUCTION HERE, and it is everything that answers a request: the
  platform adapter for this engine, `PWebParseAppUri` and the canonical
  asset-path rules, `TFolderAssetStore` behind the frozen `IAssetStore`,
  `TPWebMemoryBlobStore` behind `IBlobStore`, `pweb.blobs.protocol` deciding
  every status and header, `PWEB_NATIVE_CSP` and `PWebNativeSecurityHeaders`
  on every response, and the navigation guard whose trusted-document hook
  ends a window's blobs. Nothing is simulated. This differs from CAP-12A's
  instrument in exactly that respect: that one put a THROWAWAY store behind
  the seam to measure an engine, and this one puts the SHIPPED store behind
  the shipped handler to measure the product.

  The rows are the engine facts pweb.test.blobs cannot reach headless:

    whole      a blob read by URL - bytes and Content-Type, offset-verified
    range      a single range and a suffix range answered 206, read back by
               fetch(), with Content-Range and Accept-Ranges exact
    declined   a Range the handler declines answered 200 with the whole body
    image      <img src=blob URL> decoded by the engine
    upload     typed-array PUT and POST bodies at 1, 16 and 256 MiB reaching
               the handler byte-exact - proven by the typed refusal's own
               receipt, which names the count and the crc32c of what arrived
    foreign    another principal's token, and an unknown token, refused
               identically
    released   a token the host released mid-run
    navigate   EVERY blob of the window gone after a document replacement -
               the page reloads itself and checks its own phase-1 tokens
    window     the 8 MiB window against the REAL store: production plus
               drain, with an ordinary asset requested while it is in flight
               (CAP-12A entry condition 6.3.3)
    concurrent 32 simultaneous blob requests, all completed
    beside     an asset request answered beside a blob request, unchanged

  It writes build/cap12b/live-<target>.json and prints one marker line. The
  page's own report is the evidence; the host adds what only it can see.

  Usage: bloblive [env PWEB_CAP12B_TIMEOUT_MS] }

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
  pweb.assets.support,
  pweb.blobs.intf,
  pweb.blobs.memory,
  pweb.blobs.protocol,
  pweb.navigation.policy,
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
  LOG_PREFIX = 'bloblive';
  MARKER_PASS = 'bloblive: CAP-12B LIVE PASS';
  MARKER_FAIL = 'bloblive: CAP-12B LIVE FAIL';
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

  OWNER = 'window:main';
  FOREIGN_OWNER = 'plugin:other';

  DEFAULT_TIMEOUT_MS = 600000;
  MAX_TIMEOUT_MS = 1200000;
  CLOSER_WAIT_MARGIN_MS = 30000;

  // the seeded bodies. 8 MiB is the window CAP-12A §5.3 bounds a response
  // to and the size entry condition 6.3.3 re-measures against a real store.
  SMALL_BYTES = 1024;
  MID_BYTES = 1048576;
  WINDOW_BYTES = 8 * 1024 * 1024;

  /// the two verdicts summarize.js and the gates read
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
  Blobs: IBlobStore;
  BlobsRuntime: IBlobStoreRuntime;
  AutoCloseHandle: Pointer = nil;
  WatchdogEvent: PRTLEvent = nil;
  PageReport: RawUtf8 = '';
  PagePhases: LongInt = 0;
  SeedLatch: LongInt = 0;
  DocumentReplacements: Integer = 0;
  ReleasedByHost: RawUtf8 = '';
  SeedJson: RawUtf8 = '';
  TokenSmall, TokenPng, TokenMid, TokenWindow: RawUtf8;
  TokenForeign, TokenReleasable: RawUtf8;

// the 1x1 PNG the image row loads, as raw bytes
function TinyPng: RawByteString;
const
  B: array[0 .. 69] of Byte = (
    $89, $50, $4E, $47, $0D, $0A, $1A, $0A, $00, $00, $00, $0D, $49, $48,
    $44, $52, $00, $00, $00, $01, $00, $00, $00, $01, $08, $06, $00, $00,
    $00, $1F, $15, $C4, $89, $00, $00, $00, $0D, $49, $44, $41, $54, $78,
    $DA, $63, $FC, $CF, $C0, $50, $0F, $00, $04, $85, $01, $80, $84, $A9,
    $8C, $21, $00, $00, $00, $00, $49, $45, $4E, $44, $AE, $42, $60, $82);
begin
  SetLength(Result, Length(B));
  Move(B[0], pointer(Result)^, Length(B));
end;

// the SAME deterministic pattern the page rebuilds, so every byte check is
// an OFFSET check: a handler that answered the first N bytes of a window
// would pass a length-only comparison and fail this one
function Pattern(Size: PtrInt): RawByteString;
var
  i: PtrInt;
begin
  SetLength(Result, Size);
  for i := 0 to Size - 1 do
    Result[i + 1] := AnsiChar(i mod 251);
end;

procedure Seed;
var
  ceiling: TPWebBlobCeiling;
begin
  PWebBlobPut(Blobs, OWNER, Pattern(SMALL_BYTES), 'text/plain; charset=utf-8',
    TokenSmall, ceiling);
  PWebBlobPut(Blobs, OWNER, TinyPng, 'image/png', TokenPng, ceiling);
  PWebBlobPut(Blobs, OWNER, Pattern(MID_BYTES), 'application/octet-stream',
    TokenMid, ceiling);
  PWebBlobPut(Blobs, OWNER, Pattern(WINDOW_BYTES), 'application/octet-stream',
    TokenWindow, ceiling);
  PWebBlobPut(Blobs, OWNER, Pattern(64), 'text/plain; charset=utf-8',
    TokenReleasable, ceiling);
  // A BLOB OF ANOTHER PRINCIPAL, seeded so that the foreign row asks for a
  // token that REALLY EXISTS. Asking for one that does not would prove only
  // that a random string is not a blob.
  PWebBlobPut(Blobs, FOREIGN_OWNER, Pattern(64), 'text/plain; charset=utf-8',
    TokenForeign, ceiling);
  SeedJson :=
    '{"small":"' + TokenSmall + '","png":"' + TokenPng +
    '","mid":"' + TokenMid + '","window":"' + TokenWindow +
    '","releasable":"' + TokenReleasable + '","foreign":"' + TokenForeign +
    '","unknown":"0123456789abcdef0123456789abcdef"' +
    ',"smallBytes":' + RawUtf8(IntToStr(SMALL_BYTES)) +
    ',"midBytes":' + RawUtf8(IntToStr(MID_BYTES)) +
    ',"windowBytes":' + RawUtf8(IntToStr(WINDOW_BYTES)) +
    ',"prefix":"' + PWEB_BLOB_URL_PREFIX + '"}';
end;

{ ---- the trusted-document hook, exactly as the host arms it ---- }

// CAP-12B: this is the production wiring, not a stand-in. The host sets
// PWebNavTrustedDocumentHook to a routine that releases the window's blobs
// before anything else learns the document is changing, and this harness
// arms the same hook with the same call so that the navigation row measures
// the product rather than a rehearsal of it.
procedure OnTrustedDocument;
begin
  try
    Inc(DocumentReplacements);
    if Blobs <> nil then
      Blobs.ReleaseOwner(OWNER);
  except
  end;
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

{ THE FIRST ARGUMENT, VERBATIM, AS JSON.

  Every bind here takes exactly one argument, so the request is `[<value>]`
  and the value is what is between the brackets. Taking it verbatim rather
  than parsing it is the point: the page's report is a JSON OBJECT, and a
  hand-rolled string decoder in the middle of the one channel the evidence
  travels on is a decoder that can quietly corrupt the evidence. }
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
  while (Result <> '') and (Result[1] <= ' ') do
    Delete(Result, 1, 1);
  while (Result <> '') and (Result[Length(Result)] <= ' ') do
    SetLength(Result, Length(Result) - 1);
end;

// the same value with its JSON quotes removed, for the one argument that is
// a bare token: 32 hex characters carry no escape by construction
function FirstToken(req: PAnsiChar): RawUtf8;
begin
  Result := FirstJsonArgument(req);
  if (Length(Result) >= 2) and
     (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
  if not PWebBlobValidToken(Result) then
    Result := '';
end;

{ SEEDED ON FIRST ASK, NOT AT STARTUP, and the first run of this harness is
  why. Blobs were created before `webview_navigate`, and the production
  trusted-document hook - correctly - released every one of them when the
  FIRST document committed, so every row 404'd. That is not a defect in the
  plane: it is the plane doing exactly what it promises, and an application
  cannot create a blob before its own first document exists either. Seeding
  here puts the creation where a real producer's is, inside a live document.

  The latch matters as much as the move: after the reload the page must ask
  about the tokens PHASE ONE held, so the second ask returns the same
  strings and the store no longer resolves them. }
procedure OnSeed(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
begin
  try
    if InterlockedIncrement(SeedLatch) = 1 then
    begin
      Seed;
      WriteLn(LOG_PREFIX, ': seeded ', BlobsRuntime.LiveCount, ' blob(s)');
    end;
    webview_return(webview_t(arg), id, 0, PAnsiChar(SeedJson));
  except
  end;
end;

procedure OnPhase(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
begin
  try
    InterlockedIncrement(PagePhases);
    webview_return(webview_t(arg), id, 0,
      PAnsiChar(RawUtf8(IntToStr(PagePhases))));
  except
  end;
end;

procedure OnRelease(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  token: RawUtf8;
  ok: Boolean;
begin
  ok := False;
  try
    token := FirstToken(req);
    if (token <> '') and (Blobs <> nil) then
      ok := Blobs.Release(OWNER, token);
    if ok then
      ReleasedByHost := token;
  except
  end;
  try
    if ok then
      webview_return(webview_t(arg), id, 0, 'true')
    else
      webview_return(webview_t(arg), id, 0, 'false');
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
// the same refusal every other Cocoa live harness makes: WebKit's own
// floating-point work traps under FPC's default FPU mask, so no WebView is
// created unless the seam reports the traps masked
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
  heldCount: Integer;
  heldBytes: Int64;

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
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock marker) not found');
      fixtureDir := root + 'test' + PathDelim + 'cap12b' + PathDelim +
        'fixture';
      if not FileExists(fixtureDir + PathDelim + 'index.html') then
        raise Exception.Create('fixture missing: ' + string(fixtureDir));
      outFile := root + 'build' + PathDelim + 'cap12b' + PathDelim +
        'live-' + TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));
      timeoutMs := EnvInt('PWEB_CAP12B_TIMEOUT_MS', DEFAULT_TIMEOUT_MS,
        MAX_TIMEOUT_MS);

      WriteLn(LOG_PREFIX, ': target=', TARGET_ID);
      WriteLn(LOG_PREFIX, ': csp=', PWEB_NATIVE_CSP);
      WriteLn(LOG_PREFIX, ': prefix=', PWEB_BLOB_URL_PREFIX);

      store := TFolderAssetStore.Create(fixtureDir);
      Blobs := TPWebMemoryBlobStore.Create;
      BlobsRuntime := Blobs as IBlobStoreRuntime;
      {$ifdef DARWIN}
      CheckCocoaRuntimeUsable;
      // the ONE forced ordering difference: the Cocoa seam is armed by
      // CONSTRUCTION, so the handler exists before the webview does
      handler := TLiveHandler.Create(store, Blobs, OWNER);
      {$endif DARWIN}

      w := WebViewCheckCreated(webview_create(0, nil));
      try
        {$ifdef DARWIN}
        handler.Attach(w);
        {$endif DARWIN}
        AutoCloseHandle := Pointer(w);
        WebViewCheck(webview_set_title(w, 'PWeb CAP-12B blob plane'),
          'webview_set_title');
        WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
          'webview_set_size');
        WebViewCheck(webview_bind(w, '__pweb_blob_seed', @OnSeed, Pointer(w)),
          'webview_bind __pweb_blob_seed');
        WebViewCheck(webview_bind(w, '__pweb_blob_phase', @OnPhase, Pointer(w)),
          'webview_bind __pweb_blob_phase');
        WebViewCheck(webview_bind(w, '__pweb_blob_release', @OnRelease,
          Pointer(w)), 'webview_bind __pweb_blob_release');
        WebViewCheck(webview_bind(w, '__pweb_blob_report', @OnReport,
          Pointer(w)), 'webview_bind __pweb_blob_report');
        {$ifndef DARWIN}
        handler := TLiveHandler.Create(w, store, Blobs, OWNER);
        {$endif DARWIN}
        // the document seam is armed BEFORE the guard, so the very first
        // navigation already passes through it - the host's own order
        PWebNavTrustedDocumentHook := @OnTrustedDocument;
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
        if WatchdogEvent <> nil then
        begin
          if safeToDestroy then
            RTLEventDestroy(WatchdogEvent);
          WatchdogEvent := nil;
        end;
        InterlockedExchange(AutoCloseHandle, nil);
        // THE CAP-9 ORDER, and this harness owes it exactly as the host
        // does: the document seam is disarmed, the plane is CLOSED, the
        // guard stops deciding, the handler stops serving, and only then
        // is the store reference dropped.
        PWebNavTrustedDocumentHook := nil;
        BlobsRuntime.Close;
        heldCount := BlobsRuntime.LiveCount;
        if heldCount <> 0 then
          Fail('the plane still resolves ' + RawUtf8(IntToStr(heldCount)) +
            ' blob(s) after Close');
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
        Fail('no page report arrived');
      if PagePhases < 2 then
        Fail('the page did not reach its second document (phases=' +
          RawUtf8(IntToStr(PagePhases)) + ')');
      if DocumentReplacements < 1 then
        Fail('the trusted-document hook never fired');
      if ReleasedByHost = '' then
        Fail('the page never asked the host to release a blob');
      Blobs.Stats(heldCount, heldBytes);
      if heldCount <> 0 then
        Fail('the store still holds ' + RawUtf8(IntToStr(heldCount)) +
          ' entrie(s) after every reader went');

      json := '{' + #13#10 +
        '  "schema": 1,' + #13#10 +
        '  "target": "' + TARGET_ID + '",' + #13#10 +
        '  "prefix": "' + PWEB_BLOB_URL_PREFIX + '",' + #13#10 +
        '  "csp": ' + QuotedStrJson(PWEB_NATIVE_CSP) + ',' + #13#10 +
        '  "document_replacements": ' + RawUtf8(IntToStr(DocumentReplacements)) +
          ',' + #13#10 +
        '  "page_phases": ' + RawUtf8(IntToStr(PagePhases)) + ',' + #13#10 +
        '  "released_by_host": "' + ReleasedByHost + '",' + #13#10 +
        '  "store_entries_after_close": ' + RawUtf8(IntToStr(heldCount)) +
          ',' + #13#10 +
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
  finally
    Blobs := nil;
    BlobsRuntime := nil;
  end;
  if failReasons <> '' then
  begin
    WriteLn(StdErr, MARKER_FAIL, ' ', failReasons);
    ExitCode := 1;
  end
  else
    WriteLn(MARKER_PASS, ' target=', TARGET_ID);
end.
