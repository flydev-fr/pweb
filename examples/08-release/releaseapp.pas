program releaseapp;

{ CAP-6 release runtime proof (Windows x64):

    MyApp.exe + app.pwb - the release layout, nothing else.

    app.pwb (deterministic bundle built by pwebbundle from the CAP-5
    React dist) beside the executable
      -> production bundle loader (archive validation -> manifest ->
         ratified compat predicate -> index.html) BEFORE any webview
         exists - a refused bundle can never execute one byte of JS
      -> WebView2 WebResourceRequested handler (CAP-4W seam)
      -> TZipAssetStore over app.pwb, no extraction, no loose files
      -> React -> TypeScript SDK -> scheduler -> allow-all policy
      -> in-process mORMot -> 42

  The bundle is located beside the executable (never the CWD) and
  there is deliberately NO fallback of any kind here: no folder
  store, no fixture archive, no injected HTML. A missing or invalid
  bundle prints a typed refusal marker on stderr and exits nonzero
  before webview creation - headless-testable fail-closed behaviour.

  The backend below is IDENTICAL to the CAP-5 hosts apart from the
  bundle loading, window title and log prefix: no backend file
  branches on frontend kind.

  CAP-6b3 adds ONE compile-time variant, the fixed-runtime profile,
  behind the PWEB_FIXED_RUNTIME define: the pre-create seam then
  resolves, validates and SELECTS the WebView2 Fixed Version Runtime
  bundled beside the executable instead of diagnosing the machine's
  Evergreen runtime, and a post-create check refuses unless the
  WebView that actually opened OBSERVES the pinned version. Without
  the define this file compiles exactly as before - the Evergreen
  profiles are byte-untouched.

  CAP-7L adds Linux x64. This is the SAME release app, not a Linux
  demo: bundle loading, backend, scheduler, binding, teardown order and
  the runtime verdict are shared source. Exactly two things differ, both
  at the platform seam:
    - the pweb://app handler is TWebKitGtkAssetHandler instead of
      TWebView2AssetHandler, attached at the same point between
      webview_set_size and webview_navigate;
    - the WebView2 runtime pre-check has no counterpart on Linux. There
      is nothing to provision: WebKitGTK is a distro package and its
      absence is a LOADER failure that names the missing soname before
      main() runs. An unusable display still collapses into
      webview_create returning nil, which WebViewCheckCreated turns into
      the same typed PWeb diagnostic on both platforms.

    releaseapp            (no arguments) }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.bundle,
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2,
  pweb.platform.webview2.runtime
  {$ifdef PWEB_FIXED_RUNTIME}
  ,
  pweb.platform.webview2.fixed
  {$endif PWEB_FIXED_RUNTIME}
  {$endif LINUX}
  ;

type
  { The one platform-selected name in this file. Both handlers expose the
    identical surface - Create(webview_t, IAssetStore), Detach, Destroy -
    so every other line below is shared source. }
  {$ifdef LINUX}
  TPWebAssetHandler = TWebKitGtkAssetHandler;
  {$else}
  TPWebAssetHandler = TWebView2AssetHandler;
  {$endif LINUX}

const
  MAX_AUTOCLOSE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;
  APP_TITLE = 'PWeb CAP-6 Release';
  LOG_PREFIX = 'releaseapp';

type
  ICalculatorService = interface(IInvokable)
    ['{F2D880F7-0EE4-4EBE-8371-FBB16467BE41}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Test-only decorator for the page's machine verdict. All application
    and runtime methods still pass to the real bridge on workers. }
  TReportingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

var
  AutoCloseHandle: Pointer;
  ReportState: LongInt;
  ServiceThreadId: LongInt;
  GuiThreadId: LongInt;

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedExchange(ServiceThreadId, LongInt(GetCurrentThreadId));
  Result := a + b;
end;

constructor TReportingBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function TReportingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = 'example.report' then
  begin
    WriteLn(LOG_PREFIX, ' report: ', Args); // raw page verdict for the log
    // the page reports handshake/secure/rendered/rpc through the SDK;
    // require every flag plus the worker-thread proof before declaring
    // the runtime verdict PASS. Only the FIRST report latches.
    if (Pos('"ok":true', Args) > 0) and
       (Pos('"handshake":true', Args) > 0) and
       (Pos('"secure":true', Args) > 0) and
       (Pos('"rendered":true', Args) > 0) and
       (Pos('"rpc":true', Args) > 0) and
       (Pos('"errmap":true', Args) > 0) and
       ((Pos('"value":42}', Args) > 0) or (Pos('"value":42,', Args) > 0)) and
       (InterlockedCompareExchange(ServiceThreadId, 0, 0) <> 0) and
       (InterlockedCompareExchange(ServiceThreadId, 0, 0) <>
        InterlockedCompareExchange(GuiThreadId, 0, 0)) then
      InterlockedCompareExchange(ReportState, 1, 0)
    else
      InterlockedCompareExchange(ReportState, 2, 0);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

function AutoCloseThread(Param: Pointer): PtrInt;
var
  handle: Pointer;
begin
  Result := 0;
  Sleep(PtrInt(Param));
  handle := InterlockedExchange(AutoCloseHandle, nil);
  if handle <> nil then
    webview_dispatch(webview_t(handle), @TerminateOnGuiThread, nil);
end;

{$ifdef LINUX}
{ CAP-7L: the Linux pre-create check. There is no runtime to PROVISION -
  WebKitGTK is a distro package the application never installs, and a
  missing one is a loader failure naming the exact soname before main()
  runs - but provisioning is not the only thing worth diagnosing. A host
  with no display is the ordinary Linux failure (a server, a cron job, a
  CI step that forgot xvfb-run), and MEASURED, it collapses into
  webview_create returning nil, which the FROZEN raw layer reports as
  'missing WebView2 runtime or window creation failure'. Naming a
  Windows runtime on a machine that has never had one is a false lead,
  so the knowable cause is named here first. }
procedure CheckGtkDisplayUsable;
var
  reason: RawUtf8;
begin
  reason := PWebGtkDisplayUnavailableReason;
  if reason = '' then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': GTK DISPLAY UNAVAILABLE (', reason, ')');
  raise Exception.Create(
    'no usable display - no WebView was created; a GTK/WebKitGTK ' +
    'WebView needs an X or Wayland session');
end;
{$endif LINUX}

{$ifndef LINUX}
{ Everything from here to the matching endif is the WINDOWS
  runtime-provisioning pre-check, whose Linux counterpart is the display
  check above.

  Note for editors: a compiler directive may not be written inside this
  comment. FPC reads a nested brace as a directive and ends the comment
  at the next closing brace, which silently mangles the block below on
  the platform where it is ACTIVE - so it compiles on Linux, where the
  block is skipped, and fails on Windows. }
{$ifdef PWEB_FIXED_RUNTIME}
{ CAP-6b3 FIXED-RUNTIME profile: this build runs on the WebView2 Fixed
  Version Runtime deployed BESIDE the executable, on a runtime the
  deployment pins - never on whatever Evergreen the machine happens to
  own. The Evergreen detector is deliberately NOT consulted here: its
  verdict is irrelevant to this profile in both directions (an absent
  Evergreen must not stop us, a present one must never rescue us).

  Everything happens strictly before webview_create: the bundled tree
  is resolved from the executable path only, validated (shape, local
  drive, required files, pinned version, AMD64, AppContainer ACL by
  SID) and then SELECTED - the bundled loader preloaded by absolute
  path, its module identity asserted, and the documented override set
  and read back. Any refusal prints a typed marker on stderr and exits
  nonzero with no WebView created and no network activity of any kind;
  there is no fallback to Evergreen, ever. }
var
  // the pre-create verdict, carried to the post-create identity check
  // so both halves report one typed result
  FixedRuntime: TPWebWv2FixedResult;

procedure CheckWebView2RuntimeUsable;
begin
  FixedRuntime := PWebWv2FixedPrepare;
  if FixedRuntime.Status = wv2fxSelected then
  begin
    WriteLn(LOG_PREFIX, ': FIXED RUNTIME SELECTED (version=',
      FixedRuntime.TreeVersion, ', tree=', FixedRuntime.TreeDir, ')');
    WriteLn(LOG_PREFIX, ': FIXED RUNTIME DIAG ', FixedRuntime.Diagnostic);
    exit;
  end;
  // distinct marker, greppable by the CAP-6b3 gates
  WriteLn(StdErr, LOG_PREFIX, ': FIXED RUNTIME REFUSED (status=',
    PWebWv2FixedStatusText(FixedRuntime.Status), ', step=',
    PWebWv2FixedStepText(FixedRuntime.FailedStep), ', pin=',
    PWEB_WV2_FIXED_VERSION, ')');
  WriteLn(StdErr, LOG_PREFIX, ': FIXED RUNTIME DIAG ',
    FixedRuntime.Diagnostic);
  raise Exception.Create(
    'bundled WebView2 fixed runtime refused - no WebView was created ' +
    'and the machine Evergreen runtime was never used as a fallback');
end;

{ CAP-6b3 OBSERVED identity: pre-create validation can not see a
  registry-policy BrowserExecutableFolder redirection, so the WebView
  that actually opened is asked which browser version it is - after
  webview_create and BEFORE webview_navigate, so a mismatch refuses
  before one byte of application content loads. }
procedure CheckObservedFixedIdentity(AWebView: webview_t;
  const Prepared: TPWebWv2FixedResult);
var
  observed: RawUtf8;
  verdict: TPWebWv2FixedResult;
begin
  observed := PWebWv2ObservedBrowserVersion(AWebView);
  // the SAME typed verdict shape as every pre-create refusal, so the
  // status=/step= marker grammar never forks between the two halves
  verdict := PWebWv2FixedConfirmIdentity(Prepared, observed);
  if verdict.Status = wv2fxSelected then
  begin
    WriteLn(LOG_PREFIX, ': FIXED RUNTIME IDENTITY OK ',
      PWEB_WV2_FIXED_VERSION, ' (observed=', observed, ')');
    exit;
  end;
  WriteLn(StdErr, LOG_PREFIX,
    ': FIXED RUNTIME IDENTITY REFUSED (status=',
    PWebWv2FixedStatusText(verdict.Status), ', step=',
    PWebWv2FixedStepText(verdict.FailedStep), ', observed=', observed,
    ', pin=', PWEB_WV2_FIXED_VERSION, ')');
  WriteLn(StdErr, LOG_PREFIX, ': FIXED RUNTIME DIAG ', verdict.Diagnostic);
  raise Exception.Create(
    'the WebView that opened is not the pinned fixed runtime - ' +
    'refused before any content was loaded');
end;
{$else}
{ CAP-6b1 defensive fail-early check: the CAP-6b0 detector runs BEFORE
  webview_create, so an absent/too-old/undetectable WebView2 runtime
  produces a distinct diagnosable stderr marker and a nonzero exit
  instead of the collapsed webview_create nil. The app itself NEVER
  downloads or installs anything - provisioning belongs solely to the
  setup (normal profile); this is diagnosis, not remediation. }
procedure CheckWebView2RuntimeUsable;
var
  detection: TPWebWv2DetectionResult;
begin
  detection := PWebWv2Detect;
  if PWebWv2ProvisioningDecide(detection) = wv2pdAlreadyUsable then
    exit;
  // distinct marker, greppable by the smoke SKIP conventions
  WriteLn(StdErr, LOG_PREFIX, ': WEBVIEW2 RUNTIME UNUSABLE (status=',
    PWebWv2StatusText(detection.Status), ', raw=',
    detection.RawVersion, ', minbuild=', PWEB_WV2_MIN_BUILD,
    ', decision=', PWebWv2DecisionText(
      PWebWv2ProvisioningDecide(detection)), ')');
  WriteLn(StdErr, LOG_PREFIX, ': WEBVIEW2 DIAG ', detection.Diagnostic);
  raise Exception.Create(
    'WebView2 runtime unusable - no WebView was created; ' +
    'install the runtime via the application setup');
end;
{$endif PWEB_FIXED_RUNTIME}
{$endif LINUX}

{ Locate app.pwb beside the executable (never the CWD), then run the
  full production gate BEFORE anything webview-related exists. On
  refusal the typed marker goes to stderr and the raised exception
  makes the process exit nonzero - zero bundle JS can ever execute. }
function LoadReleaseBundle: IAssetStore;
var
  bundleFile: TFileName;
  refusal: TPWebBundleRefusal;
begin
  bundleFile := Executable.ProgramFilePath + 'app.pwb';
  if not PWebBundleLoadFile(bundleFile, PWEB_SUPPORTED_PROTOCOLS,
       PWEB_RUNTIME_VERSION, Result, refusal) then
  begin
    // native-controlled typed diagnostic: reason category only, no
    // parser internals, and never any content from the rejected bundle
    WriteLn(StdErr, LOG_PREFIX, ': app.pwb REFUSED (',
      PWebBundleRefusalText(refusal), ')');
    raise Exception.Create('bundle refused - no WebView was created');
  end;
end;

var
  w: webview_t;
  store: IAssetStore;
  assetHandler: TPWebAssetHandler;
  server: TRestServerFullMemory;
  factory: TServiceFactoryServerAbstract;
  realBridge, bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  autoCloseMs: Integer;
  closerId, closerHandle: system.TThreadID; // mormot.core.os shadows it
  closerStarted, safeToDestroy, schedulerDrained: Boolean;
begin
  ExitCode := 0;
  server := nil;
  scheduler := nil;
  assetHandler := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  InterlockedExchange(GuiThreadId, LongInt(GetCurrentThreadId));
  try
    if ParamCount <> 0 then
      raise Exception.Create('usage: ' + LOG_PREFIX +
        ' (loads app.pwb from beside the executable)');
    store := LoadReleaseBundle;

    server := TRestServerFullMemory.CreateWithOwnModel([]);
    factory := server.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register CalculatorService');
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    bridge := TReportingBridge.Create(realBridge);
    scheduler := TInvocationScheduler.Create(
      TAllowAllCapabilityPolicy.Create, bridge, 4);
    schedulerRef := scheduler;
    limits := Default(TPWebSourceLimits);
    limits.MaxConcurrent := 4;
    limits.MaxQueueSize := 32;
    source := scheduler.RegisterSource(limits);

    {$ifdef LINUX}
    // CAP-7L: the same call site, for the same reason. There is no
    // runtime to provision on Linux, but there is still one cause that
    // is knowable BEFORE webview_create collapses every bad state into
    // one nil - and if it is left to collapse, the frozen raw layer
    // names a WebView2 runtime on a machine that has never had one.
    CheckGtkDisplayUsable;
    {$else}
    // CAP-6b1: fail early with a distinct diagnosable marker before
    // webview_create can collapse every bad state into one nil
    CheckWebView2RuntimeUsable;
    {$endif LINUX}

    w := WebViewCheckCreated(webview_create(0, nil));
    try
      {$ifdef PWEB_FIXED_RUNTIME}
      // CAP-6b3: identity is OBSERVED, not inferred - and it is
      // observed here, before webview_navigate can load anything
      CheckObservedFixedIdentity(w, FixedRuntime);
      {$endif PWEB_FIXED_RUNTIME}
      AutoCloseHandle := Pointer(w);
      context := Default(TInvocationContext);
      context.WindowId := 'main';
      context.PrincipalId := 'window:main';
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, source, opts);
      binding.Bind('__pweb_invoke', TPWebEnvelopeHandler.Create(source));
      WebViewCheck(webview_set_title(w, PAnsiChar(AnsiString(APP_TITLE))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      // production asset path: attach the pweb://app handler on the
      // proven native seam, then navigate - never any injected HTML.
      // CAP-4W borrowed-controller seam on Windows, CAP-7L
      // BROWSER_CONTROLLER -> WebKitWebContext seam on Linux; the
      // attach point itself is unchanged on both
      {$ifdef LINUX}
      assetHandler := TWebKitGtkAssetHandler.Create(w, store);
      {$else}
      assetHandler := TWebView2AssetHandler.Create(w, store);
      {$endif LINUX}
      WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

      autoCloseMs := StrToIntDef(
        GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if autoCloseMs > MAX_AUTOCLOSE_MS then
        autoCloseMs := MAX_AUTOCLOSE_MS;
      if autoCloseMs > 0 then
      begin
        closerHandle := BeginThread(@AutoCloseThread,
          Pointer(PtrInt(autoCloseMs)), closerId);
        closerStarted := closerHandle <> system.TThreadID(0);
        if not closerStarted then
          raise Exception.Create('unable to start auto-close thread');
      end;
      WebViewCheck(webview_run(w), 'webview_run');
    finally
      if closerStarted then
      begin
        if WaitForThreadTerminate(closerHandle,
             autoCloseMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          WriteLn(StdErr, 'FAIL: auto-close thread did not terminate');
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
            WriteLn(StdErr, 'FAIL: binding Close: ', E.Message);
            ExitCode := 1;
          end;
        end;
      if schedulerRef <> nil then
        try
          schedulerRef.Shutdown; // drain before bridge/server release
          schedulerDrained := True;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: scheduler Shutdown: ', E.Message);
            ExitCode := 1;
          end;
        end;
      // CAP-4W ordering: unregister the resource handler and release
      // its owned COM references before the webview is destroyed
      if assetHandler <> nil then
        try
          assetHandler.Detach;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: asset handler Detach: ', E.Message);
            ExitCode := 1;
          end;
        end;
      FreeAndNil(assetHandler);
      if safeToDestroy then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: webview_destroy: ', E.Message);
            ExitCode := 1;
          end;
        end;
    end;

    if ReportState = 1 then
      WriteLn(LOG_PREFIX,
        ': app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS')
    else
    begin
      WriteLn(StdErr, 'FAIL: page/runtime verdict was not successful ',
        '(state=', ReportState, '; 0=no report received)');
      ExitCode := 1;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  if (scheduler <> nil) and not schedulerDrained then
    try
      scheduler.Shutdown;
      schedulerDrained := True;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'FAIL: final scheduler Shutdown: ', E.Message);
        ExitCode := 1;
      end;
    end;
  binding := nil;
  source := nil;
  schedulerRef := nil;
  scheduler := nil;
  bridge := nil;
  realBridge := nil; // frees owned server after worker drain
  store := nil;
  server.Free;
  if ExitCode = 0 then
    WriteLn(LOG_PREFIX, ': clean exit');
end.
