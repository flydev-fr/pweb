program navmatrix;

{ CAP-8B: the real-window privileged-navigation matrix host.

  One instrumented host, four targets, zero mocked layers on the enforcement
  path: the PRODUCTION asset handler serves the fixture corpus over
  pweb://app, the PRODUCTION navigation guard classifies every engine event
  through PWebClassifyNavigation, the PRODUCTION scheduler + CAP-8A policy
  authorize every invocation, and the PRODUCTION per-platform external
  opener is reached only through pweb.openExternal - with the one injectable
  seam each adapter provides swapped for a COUNTING fake, so "called exactly
  twice" and "never called by a navigation" are measured, not inferred.

  WHAT IS DELIBERATELY NOT PRODUCTION: the invocation bridge. The release
  smoke already proves the mORMot SOA path on all four targets with the
  navsec block required; this host substitutes a counting bridge so that
  every native arrival is attributed BY METHOD and the bridge-isolation
  claim becomes arithmetic: after the run, the per-method ledger must hold
  exactly the driver's own calls and nothing else. An untrusted context
  that executed anywhere would either invoke matrix.childExecuted (the
  fixture children do, over the LOWEST transport they can reach) or add an
  unexplained arrival - both turn the verdict red. That is the "native
  invocation counter = 0, SOA counter = 0 for untrusted contexts" row,
  expressed as an equality over the whole ledger rather than a pair of
  zeroes nobody cross-checks.

  THE DRIVER is test/cap8b/fixture/assets/driver.js: the trusted page
  performs the whole B-matrix in a real window (external location /
  window.open / anchor / form / meta-refresh / javascript: navigations,
  trusted and untrusted iframes, the download attempt, the CSP subresource
  probes, the raw-transport control, the capability-authorized external
  opens and the RPC/navigation race) and reports observed facts through
  matrix.report. The host then joins the page's rows with the native ledger,
  the guard counters and the opener spy, writes
  build/cap8b/nav-matrix.json and prints exactly one canonical marker:

      navmatrix: NAV MATRIX PASS
      navmatrix: NAV MATRIX FAIL (<reason>)

  Construction and teardown mirror examples/08-release/releaseapp.pas
  line for line where the platforms differ (Cocoa two-phase handler,
  guard-before-navigate, reverse-order Detach), because the matrix must
  prove the PRODUCT's construction order, not a friendlier one. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.json, // JsonDecode, for the pweb.openExternal argument
  mormot.core.os,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.capabilities.policy,
  pweb.navigation.policy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.folder,
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2
  {$endif LINUX}
  {$endif DARWIN}
  ;

type
  { the same platform-alias mechanism the release host uses: one name per
    surface, everything else shared source }
  {$ifdef DARWIN}
  TPWebAssetHandler = TCocoaAssetHandler;
  TPWebNavigationGuard = TCocoaNavigationGuard;
  {$else}
  {$ifdef LINUX}
  TPWebAssetHandler = TWebKitGtkAssetHandler;
  TPWebNavigationGuard = TWebKitGtkNavigationGuard;
  {$else}
  TPWebAssetHandler = TWebView2AssetHandler;
  TPWebNavigationGuard = TWebView2NavigationGuard;
  {$endif LINUX}
  {$endif DARWIN}

const
  LOG_PREFIX = 'navmatrix';
  MARKER_PASS = 'navmatrix: NAV MATRIX PASS';
  MARKER_FAIL = 'navmatrix: NAV MATRIX FAIL';
  {$ifdef DARWIN}
    {$ifdef CPUAARCH64}
    TARGET_ID = 'macos-arm64';
    {$else}
    TARGET_ID = 'macos-x86_64';
    {$endif CPUAARCH64}
  {$else}
  {$ifdef LINUX}
  TARGET_ID = 'linux-x86_64';
  {$else}
  TARGET_ID = 'windows-x86_64';
  {$endif LINUX}
  {$endif DARWIN}
  { watchdog: the driver terminates the window itself the moment its report
    is acknowledged; this bound only exists so a wedged engine cannot idle
    out a CI step. The env override exists for slow local machines. }
  DEFAULT_TIMEOUT_MS = 45000;
  MAX_TIMEOUT_MS = 120000;
  CLOSER_WAIT_MARGIN_MS = 10000;
  METHOD_OPEN_EXTERNAL = 'pweb.openExternal';
  CAP_EXTERNAL_OPEN = 'external.open';
  CAP_CALCULATOR_ADD = 'calculator.add';
  { the two URIs the driver asks the runtime to open; the spy compares
    against these exact bytes so "the opener saw what was authorized" is a
    measured equality, never an inference (and never a log line) }
  EXPECTED_OPEN_HTTPS: RawUtf8 = 'https://example.invalid/cap8b-open';
  EXPECTED_OPEN_MAILTO: RawUtf8 = 'mailto:cap8b@example.invalid';

var
  // ---- the native ledger: every bridge arrival, attributed by method ----
  CountReport: LongInt;
  CountRawControl: LongInt;
  CountAdd: LongInt;
  CountSlow: LongInt;
  CountChildExecuted: LongInt;
  CountOpenOk: LongInt;
  CountOpenRefused: LongInt;
  CountOpenFailed: LongInt;
  CountEcho: LongInt;
  CountHandshake: LongInt;
  CountUnexpected: LongInt;
  // ---- the opener spy ----
  OpenerCalls: LongInt;
  OpenerUnexpectedUri: LongInt;
  // ---- report latch + window handle for terminate-on-report ----
  // the CAS winner is the only writer of ReportJson, and the main thread
  // reads it only after the scheduler drained - no lock needed, no lock API
  // to disagree about between the RTL and mormot.core.os
  ReportLatch: LongInt;
  ReportJson: RawUtf8;
  AutoCloseHandle: Pointer;

{ ---- the counting opener spy, injected through each adapter's seam ------- }

function SpyOpenerCore(const AUri: RawUtf8): Boolean;
begin
  InterlockedIncrement(OpenerCalls);
  // the spy re-checks the two exact URIs the driver was scripted to open:
  // anything else reaching the seam - a navigation, a smuggled scheme, a
  // rewritten string - is recorded and fails the run
  if (AUri <> EXPECTED_OPEN_HTTPS) and
     (AUri <> EXPECTED_OPEN_MAILTO) then
    InterlockedIncrement(OpenerUnexpectedUri);
  Result := True;
end;

{$ifdef DARWIN}
function SpyOpenerCocoa(AUri: PAnsiChar): LongInt; cdecl;
var
  uri: RawUtf8;
begin
  if AUri = nil then
    uri := ''
  else
    FastSetString(uri, AUri, StrLen(AUri));
  if SpyOpenerCore(uri) then
    Result := 1
  else
    Result := 0;
end;
{$else}
function SpyOpener(const AUri: RawUtf8): Boolean;
begin
  Result := SpyOpenerCore(AUri);
end;
{$endif DARWIN}

procedure InstallOpenerSpy;
begin
  {$ifdef DARWIN}
  PWebCocoaSetExternalOpener(@SpyOpenerCocoa);
  {$else}
  {$ifdef LINUX}
  PWebGtkSetExternalOpener(@SpyOpener);
  {$else}
  PWebWv2SetExternalOpener(@SpyOpener);
  {$endif LINUX}
  {$endif DARWIN}
end;

procedure RemoveOpenerSpy;
begin
  {$ifdef DARWIN}
  PWebCocoaSetExternalOpener(nil);
  {$else}
  {$ifdef LINUX}
  PWebGtkSetExternalOpener(nil);
  {$else}
  PWebWv2SetExternalOpener(nil);
  {$endif LINUX}
  {$endif DARWIN}
end;

function CallPlatformOpener(const AUri: RawUtf8): Boolean;
begin
  // the PRODUCTION per-platform entry, exactly as the release host calls
  // it: the gate re-runs inside, and the seam is consulted inside the gate
  {$ifdef DARWIN}
  Result := PWebCocoaOpenExternal(AUri);
  {$else}
  {$ifdef LINUX}
  Result := PWebGtkOpenExternalUri(AUri);
  {$else}
  Result := PWebWv2OpenExternal(AUri);
  {$endif LINUX}
  {$endif DARWIN}
end;

{ ---- the counting bridge ------------------------------------------------- }

type
  TCountingMatrixBridge = class(TInterfacedObject, IInvocationBridge)
  public
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { identical to the release host's D9 wrapper: the per-invocation
    effective snapshot is computed on the callback thread and nothing else
    of the native context is touched }
  TPolicyContextHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FInner: IWebViewInvocationHandler;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy;
  public
    constructor Create(const AInner: IWebViewInvocationHandler;
      const APolicy: TPWebCapabilityPolicy);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

constructor TPolicyContextHandler.Create(
  const AInner: IWebViewInvocationHandler;
  const APolicy: TPWebCapabilityPolicy);
begin
  inherited Create;
  if (AInner = nil) or (APolicy = nil) then
    raise Exception.Create('TPolicyContextHandler requires handler + policy');
  FInner := AInner;
  FPolicy := APolicy;
  FPolicyRef := APolicy;
end;

procedure TPolicyContextHandler.HandleInvocation(
  const Context: TInvocationContext; const Request: TPWebJson;
  const Completion: IInvocationCompletion);
var
  ctx: TInvocationContext;
begin
  ctx := Context;
  ctx.Capabilities := FPolicy.SnapshotCapabilities(
    ctx.PrincipalId, ctx.WindowId);
  FInner.HandleInvocation(ctx, Request, Completion);
end;

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
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

function EncodeCapabilities(const ACaps: TPWebCapabilities): RawUtf8;
var
  i: PtrInt;
begin
  // capability names obey the CAP-8A grammar (no quotes, no escapes), so
  // plain joining is exact
  Result := '[';
  for i := 0 to High(ACaps) do
  begin
    if i > 0 then
      Result := Result + ',';
    Result := Result + '"' + RawUtf8(ACaps[i]) + '"';
  end;
  Result := Result + ']';
end;

function OpenExternalResult(const Args: TPWebJson): TPWebInvocationResult;
var
  payload, uri: RawUtf8;
  opened: Boolean;
begin
  // byte-identical logic to the release host's interception: JsonDecode on
  // a private copy, the shared validator as the ONLY gate, no URI logging
  payload := Args;
  UniqueRawUtf8(payload);
  uri := JsonDecode(payload, 'url');
  if not PWebValidExternalUri(uri) then
  begin
    InterlockedIncrement(CountOpenRefused);
    exit(PWebDefaultErrorResult(pecInvalidRequest));
  end;
  opened := False;
  try
    opened := CallPlatformOpener(uri);
  except
    opened := False;
  end;
  if not opened then
  begin
    InterlockedIncrement(CountOpenFailed);
    exit(PWebDefaultErrorResult(pecInternalError));
  end;
  InterlockedIncrement(CountOpenOk);
  Result := PWebSuccessResult(PWEB_JSON_NULL);
end;

function TCountingMatrixBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = PWEB_METHOD_ECHO then
  begin
    InterlockedIncrement(CountEcho);
    exit(PWebSuccessResult(Args));
  end;
  if Method = PWEB_METHOD_HANDSHAKE then
  begin
    InterlockedIncrement(CountHandshake);
    exit(PWebSuccessResult('{"protocol":' +
      Utf8String(IntToStr(PWEB_PROTOCOL_VERSION)) + ',"runtime":"' +
      PWEB_RUNTIME_VERSION + '","capabilities":' +
      Utf8String(EncodeCapabilities(Context.Capabilities)) + '}'));
  end;
  if Method = METHOD_OPEN_EXTERNAL then
    exit(OpenExternalResult(Args));
  if Method = 'matrix.add' then
  begin
    InterlockedIncrement(CountAdd);
    // fixed operands by design: the driver sends {a:20,b:22} and asserts
    // 42 - the value proves the whole invocation path answered, which is
    // all this host needs from an RPC
    exit(PWebSuccessResult('42'));
  end;
  if Method = 'matrix.slow' then
  begin
    // the RPC/navigation race: the driver starts this invocation, then
    // immediately attempts an external navigation. This sleep runs on a
    // scheduler WORKER, exactly like a slow service call, so the cancelled
    // navigation and the in-flight invocation genuinely overlap.
    Sleep(400);
    InterlockedIncrement(CountSlow);
    exit(PWebSuccessResult('{"done":true}'));
  end;
  if Method = 'matrix.rawControl' then
  begin
    // the lowest-transport control: the driver posts this bypassing the
    // SDK shim, straight into the engine's message channel
    InterlockedIncrement(CountRawControl);
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  if Method = 'matrix.childExecuted' then
  begin
    // the tripwire: only fixture CHILD documents call this, and no child
    // document may ever execute in the privileged WebView. Any arrival
    // fails the run.
    InterlockedIncrement(CountChildExecuted);
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  if Method = 'matrix.report' then
  begin
    // first report latches, exactly like the smoke: the CAS winner is the
    // only thread that ever writes ReportJson
    if InterlockedCompareExchange(ReportLatch, 1, 0) = 0 then
      ReportJson := Args;
    InterlockedIncrement(CountReport);
    RequestTerminate;
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  InterlockedIncrement(CountUnexpected);
  Result := PWebDefaultErrorResult(pecMethodNotFound);
end;

{ ---- policy, watchdog, plumbing ------------------------------------------ }

function BuildMatrixPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  // the same shape as the release policy: external.open is MAPPED, so the
  // CAP-8A engine authorizes the open before the bridge ever sees it
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALCULATOR_ADD, CAP_EXTERNAL_OPEN]);
    b.SetWindowCapabilities('main', [CAP_CALCULATOR_ADD, CAP_EXTERNAL_OPEN]);
    b.SetPrincipalCapabilities('window:main',
      [CAP_CALCULATOR_ADD, CAP_EXTERNAL_OPEN]);
    b.MapMethod('matrix.add', [CAP_CALCULATOR_ADD]);
    b.MapMethod(METHOD_OPEN_EXTERNAL, [CAP_EXTERNAL_OPEN]);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(PWEB_METHOD_ECHO);
    b.RegisterZeroCapMethod('matrix.report');
    b.RegisterZeroCapMethod('matrix.slow');
    b.RegisterZeroCapMethod('matrix.rawControl');
    // deliberately allowed, never denied: a child context that executed
    // must be COUNTED, and a policy deny would hide the very arrival the
    // tripwire exists to record
    b.RegisterZeroCapMethod('matrix.childExecuted');
    Result := b.Build;
  finally
    b.Free;
  end;
end;

function WatchdogThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  Sleep(PtrInt(Param));
  RequestTerminate;
end;

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
  dir := Executable.ProgramFilePath;
  for i := 1 to 8 do
  begin
    if FileExists(dir + 'webview.lock') then
      exit(dir);
    parent := ExtractFilePath(ExcludeTrailingPathDelimiter(dir));
    if (parent = '') or (parent = dir) then
      break;
    dir := parent;
  end;
  Result := '';
end;

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  // the failure summary goes into a JSON string: quotes, backslashes and
  // control bytes are flattened rather than escaped - it is a diagnostic,
  // not data anyone parses back
  Result := AValue;
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or (Result[i] < #$20) then
      Result[i] := '''';
end;

{$ifdef DARWIN}
procedure CheckCocoaRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, LOG_PREFIX,
    ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create('FPU traps could not be masked - no WebView created');
end;
{$endif DARWIN}

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

var
  w: webview_t;
  store: IAssetStore;
  assetHandler: TPWebAssetHandler;
  navGuard: TPWebNavigationGuard;
  bridge: IInvocationBridge;
  capPolicy: TPWebCapabilityPolicy;
  capPolicyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  root, fixtureDir, outFile: TFileName;
  timeoutMs: Integer;
  closerId, closerHandle: system.TThreadID;
  closerStarted, safeToDestroy, schedulerDrained: Boolean;
  guardAllowed, guardCancelled: Int64;
  {$ifdef DARWIN}
  cocoaCounters: TPWebCocoaNavCounters;
  {$endif DARWIN}
  failReasons: RawUtf8;
  pageReport, json: RawUtf8;
  stream: TFileStream;

procedure Fail(const AReason: RawUtf8);
begin
  if failReasons <> '' then
    failReasons := failReasons + '; ';
  failReasons := failReasons + AReason;
end;

procedure RequireCount(const AName: RawUtf8; AActual, AExpected: LongInt);
begin
  if AActual <> AExpected then
    Fail(AName + '=' + RawUtf8(IntToStr(AActual)) + ' expected ' +
      RawUtf8(IntToStr(AExpected)));
end;

begin
  ExitCode := 0;
  scheduler := nil;
  assetHandler := nil;
  navGuard := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  guardAllowed := 0;
  guardCancelled := 0;
  failReasons := '';
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create(
          'repository root (webview.lock marker) not found from ' +
          string(Executable.ProgramFilePath));
      fixtureDir := root + 'test' + PathDelim + 'cap8b' + PathDelim +
        'fixture';
      if not FileExists(fixtureDir + PathDelim + 'index.html') then
        raise Exception.Create('fixture corpus missing: ' +
          string(fixtureDir));
      outFile := root + 'build' + PathDelim + 'cap8b' + PathDelim +
        'nav-matrix.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));

      timeoutMs := StrToIntDef(
        GetEnvironmentVariable('PWEB_NAVMATRIX_TIMEOUT_MS'),
        DEFAULT_TIMEOUT_MS);
      if (timeoutMs <= 0) or (timeoutMs > MAX_TIMEOUT_MS) then
        timeoutMs := DEFAULT_TIMEOUT_MS;

      // the spy BEFORE any WebView exists: from the first event the real
      // OS opener is unreachable, so a defective navigation path cannot
      // open a browser even while failing the run
      InstallOpenerSpy;

      store := TFolderAssetStore.Create(fixtureDir);
      bridge := TCountingMatrixBridge.Create;
      capPolicy := BuildMatrixPolicy;
      capPolicyRef := capPolicy;
      scheduler := TInvocationScheduler.Create(capPolicyRef, bridge, 4);
      schedulerRef := scheduler;
      limits := Default(TPWebSourceLimits);
      limits.MaxConcurrent := 4;
      limits.MaxQueueSize := 32;
      source := scheduler.RegisterSource(limits);

      {$ifdef DARWIN}
      CheckCocoaRuntimeUsable;
      // Cocoa's pweb://app seam is armed by CONSTRUCTION, before
      // webview_create - the platform's shape, exactly as in the release
      // host
      assetHandler := TCocoaAssetHandler.Create(store);
      {$else}
      {$ifdef LINUX}
      CheckGtkDisplayUsable;
      {$endif LINUX}
      {$endif DARWIN}

      w := WebViewCheckCreated(webview_create(0, nil));
      try
        {$ifdef DARWIN}
        assetHandler.Attach(w);
        {$endif DARWIN}
        AutoCloseHandle := Pointer(w);
        context := Default(TInvocationContext);
        context.WindowId := 'main';
        context.PrincipalId := 'window:main';
        context.PrincipalKind := pkWindow;
        context.TrustedContent := True;
        opts := PWebDefaultBindingOptions(context);
        binding := TWebViewBinding.Create(w, source, opts);
        binding.Bind('__pweb_invoke', TPolicyContextHandler.Create(
          TPWebEnvelopeHandler.Create(source), capPolicy));
        WebViewCheck(webview_set_title(w, 'PWeb CAP-8B nav matrix'),
          'webview_set_title');
        WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
          'webview_set_size');
        {$ifndef DARWIN}
        {$ifdef LINUX}
        assetHandler := TWebKitGtkAssetHandler.Create(w, store);
        {$else}
        assetHandler := TWebView2AssetHandler.Create(w, store);
        {$endif LINUX}
        {$endif DARWIN}
        // the guard between the handler and the first navigation, exactly
        // as the release host installs it: no document commits unclassified
        {$ifdef DARWIN}
        navGuard := TPWebNavigationGuard.Create;
        navGuard.Attach(w);
        {$else}
        navGuard := TPWebNavigationGuard.Create(w);
        {$endif DARWIN}
        WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

        closerHandle := BeginThread(@WatchdogThread,
          Pointer(PtrInt(timeoutMs)), closerId);
        closerStarted := closerHandle <> system.TThreadID(0);
        if not closerStarted then
          raise Exception.Create('unable to start the watchdog thread');
        WebViewCheck(webview_run(w), 'webview_run');
      finally
        if closerStarted then
        begin
          // the watchdog holds no lock and terminates through dispatch, so
          // after webview_run returns it either already fired or will wake
          // and find the handle gone
          InterlockedExchange(AutoCloseHandle, nil);
          if WaitForThreadTerminate(closerHandle,
               timeoutMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL watchdog did not terminate');
            safeToDestroy := False;
            ExitCode := 1;
          end;
          CloseThread(closerHandle);
        end;
        InterlockedExchange(AutoCloseHandle, nil);
        if binding <> nil then
          try
            binding.Close;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL binding Close: ', E.Message);
              ExitCode := 1;
            end;
          end;
        if schedulerRef <> nil then
          try
            schedulerRef.Shutdown;
            schedulerDrained := True;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL scheduler Shutdown: ',
                E.Message);
              ExitCode := 1;
            end;
          end;
        // reverse construction order, exactly as the release host: the
        // guard stops deciding, then the handler stops serving, then the
        // webview dies - and the counters are read BEFORE Detach only
        // through the properties, which survive it by design
        if navGuard <> nil then
        begin
          try
            {$ifdef DARWIN}
            cocoaCounters := navGuard.Counters;
            guardAllowed := Int64(cocoaCounters.Allowed);
            guardCancelled := Int64(cocoaCounters.Cancelled);
            {$else}
            {$ifdef LINUX}
            guardAllowed := navGuard.AllowedCount;
            guardCancelled := navGuard.CancelledCount;
            {$else}
            guardAllowed := navGuard.AllowedTrusted;
            guardCancelled := navGuard.Cancelled;
            {$endif LINUX}
            {$endif DARWIN}
            navGuard.Detach;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL guard Detach: ', E.Message);
              ExitCode := 1;
            end;
          end;
          FreeAndNil(navGuard);
        end;
        if assetHandler <> nil then
        begin
          try
            assetHandler.Detach;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL handler Detach: ',
                E.Message);
              ExitCode := 1;
            end;
          end;
          FreeAndNil(assetHandler);
        end;
        if safeToDestroy then
          try
            WebViewCheck(webview_destroy(w), 'webview_destroy');
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL webview_destroy: ',
                E.Message);
              ExitCode := 1;
            end;
          end;
      end;

      // ---- join the page's rows with the native ledger ----
      // safe to read plainly: the scheduler drained above, so the one
      // writer (the CAS winner) finished before this line
      pageReport := ReportJson;
      if pageReport = '' then
        Fail('no matrix.report arrived (watchdog or crash)')
      else if Pos('"allPass":true', pageReport) = 0 then
        Fail('the page reports a failed row (allPass is not true)');
      RequireCount('report', CountReport, 1);
      RequireCount('raw_control', CountRawControl, 1);
      RequireCount('add', CountAdd, 1);
      RequireCount('slow', CountSlow, 1);
      RequireCount('child_executed', CountChildExecuted, 0);
      RequireCount('open_ok', CountOpenOk, 2);
      RequireCount('open_refused', CountOpenRefused, 1);
      RequireCount('open_failed', CountOpenFailed, 0);
      RequireCount('opener_calls', OpenerCalls, 2);
      RequireCount('opener_unexpected_uri', OpenerUnexpectedUri, 0);
      RequireCount('unexpected_methods', CountUnexpected, 0);
      if guardAllowed < 1 then
        Fail('the guard allowed no trusted navigation at all');
      if guardCancelled < 1 then
        Fail('the guard cancelled nothing - the hostile corpus never ' +
          'reached it');
      if ExitCode <> 0 then
        Fail('a teardown step failed (see stderr)');

      if pageReport = '' then
        pageReport := 'null';
      json := '{' + #10 +
        '  "schema": 1,' + #10 +
        '  "target": "' + TARGET_ID + '",' + #10 +
        '  "overall": "';
      if failReasons = '' then
        json := json + 'PASS'
      else
        json := json + 'FAIL';
      json := json + '",' + #10;
      if failReasons <> '' then
        json := json + '  "failures": "' + JsonSafeText(failReasons) +
          '",' + #10;
      json := json +
        '  "native": {' + #10 +
        '    "report": ' + RawUtf8(IntToStr(CountReport)) + ',' + #10 +
        '    "raw_control": ' + RawUtf8(IntToStr(CountRawControl)) + ',' + #10 +
        '    "add": ' + RawUtf8(IntToStr(CountAdd)) + ',' + #10 +
        '    "slow": ' + RawUtf8(IntToStr(CountSlow)) + ',' + #10 +
        '    "child_executed": ' + RawUtf8(IntToStr(CountChildExecuted)) + ',' + #10 +
        '    "open_ok": ' + RawUtf8(IntToStr(CountOpenOk)) + ',' + #10 +
        '    "open_refused": ' + RawUtf8(IntToStr(CountOpenRefused)) + ',' + #10 +
        '    "open_failed": ' + RawUtf8(IntToStr(CountOpenFailed)) + ',' + #10 +
        '    "opener_calls": ' + RawUtf8(IntToStr(OpenerCalls)) + ',' + #10 +
        '    "opener_unexpected_uri": ' + RawUtf8(IntToStr(OpenerUnexpectedUri)) + ',' + #10 +
        '    "echo": ' + RawUtf8(IntToStr(CountEcho)) + ',' + #10 +
        '    "handshake": ' + RawUtf8(IntToStr(CountHandshake)) + ',' + #10 +
        '    "unexpected_methods": ' + RawUtf8(IntToStr(CountUnexpected)) + ',' + #10 +
        '    "guard_allowed": ' + RawUtf8(IntToStr(guardAllowed)) + ',' + #10 +
        '    "guard_cancelled": ' + RawUtf8(IntToStr(guardCancelled)) + #10 +
        '  },' + #10 +
        '  "page": ' + pageReport + #10 +
        '}' + #10;
      stream := TFileStream.Create(outFile, fmCreate);
      try
        if json <> '' then
          stream.WriteBuffer(json[1], Length(json));
      finally
        stream.Free;
      end;

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
    if (scheduler <> nil) and not schedulerDrained then
      try
        scheduler.Shutdown;
      except
        on E: Exception do
        begin
          WriteLn(StdErr, LOG_PREFIX, ': FAIL final Shutdown: ', E.Message);
          ExitCode := 1;
        end;
      end;
    try
      binding := nil;
      source := nil;
      schedulerRef := nil;
      scheduler := nil;
      capPolicyRef := nil;
      capPolicy := nil;
      bridge := nil;
      store := nil;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL final teardown: ', E.Message);
        ExitCode := 1;
      end;
    end;
    RemoveOpenerSpy;
  end;
end.
