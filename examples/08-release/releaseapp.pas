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
      -> React -> TypeScript SDK -> scheduler -> CAP-8A contextual
         capability policy (production builder config, per-invocation
         effective snapshot) -> in-process mORMot -> 42

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

  CAP-7M2 adds macOS (both native architectures). Still the SAME release
  app; three things differ, all at the platform seam:
    - the pweb://app handler is TCocoaAssetHandler, and it is TWO-PHASE
      because Cocoa leaves no choice: upstream builds the
      WKWebViewConfiguration and the WKWebView both inside
      webview_create, so the handler is constructed (arming the
      pre-create seam) BEFORE webview_create and Attach - which raises
      unless the seam actually ran for THIS view - immediately after.
      The construction site the other platforms use between
      webview_set_size and webview_navigate is byte-unchanged for them;
    - the pre-create check is CheckCocoaRuntimeUsable over
      PWebCocoaFpuTrapsMasked: FPC starts with the FPU traps enabled and
      WebKit computes on NaNs, so an unmasked FPU is refused loudly
      before a window can exist instead of dying as EInvalidOp mid-render;
    - inside a .app the executable lives in Contents/MacOS and the
      bundle in Contents/Resources, so app.pwb resolves as
      <exedir>/../Resources/app.pwb - from the EXECUTABLE location only,
      never the CWD, exactly as on the other platforms.

  CAP-7M2 also adds TWO optional command-line arguments, on ALL
  platforms, because LaunchServices delivers argv but neither
  environment variables nor stdout (`open -W` forwards neither the exit
  code nor a byte of output):
    --pweb-verdict=<file>    write the canonical PASS/FAIL verdict line
                             to <file> atomically (temp + rename) on
                             every exit path - the one deterministic
                             evidence channel a LaunchServices launch
                             leaves behind;
    --pweb-autoclose-ms=<N>  auto-close bound; the argument WINS over
                             the PWEB_SMOKE_AUTOCLOSE_MS environment
                             variable, which LaunchServices cannot
                             deliver.
  Unknown arguments are still refused - there is no argument the release
  host silently ignores.

  CAP-8B adds privileged-navigation enforcement, and adds it in exactly
  two places, both platform-neutral:
    - ONE navigation guard, selected by the same alias mechanism as the
      asset handler, constructed between the handler and
      webview_navigate so that no document can commit unclassified. The
      guard adapts its engine's native events; the decision itself comes
      from PWebClassifyNavigation in src/security - there is no policy
      table in this file and no platform branch that decides anything;
    - ONE host-owned runtime method, pweb.openExternal, mapped to the
      capability 'external.open'. Every raw external navigation is
      cancelled inside the privileged WebView (https: and mailto:
      included) and NO navigation callback ever reaches an opener,
      because CAP-8B MEASURED that no engine can distinguish a real
      click from a navigation issued in the continuation of a binding
      promise (WebView2 IsUserInitiated and WebKitGTK is_user_gesture
      both report true for it; WKWebView exposes no public flag at all).
      Handing a URI to the operating system is therefore an ordinary
      authorized invocation, checked by the CAP-8A policy before the
      bridge ever sees it.

    releaseapp [--pweb-verdict=<file>] [--pweb-autoclose-ms=<N>] }

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
  pweb.rpc.command, // CAP-10A: the reusable runtime-command decorator
  pweb.capabilities.policy,
  pweb.navigation.policy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.bundle,
  pweb.imagepath, // CAP-10E: the kernel-resolved trusted location
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
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
  {$endif DARWIN}
  ;

type
  { The platform-selected NAMES in this file, and the only ones. The
    Windows and Linux handlers expose the identical surface -
    Create(webview_t, IAssetStore), Detach, Destroy - and the Cocoa one is
    the same surface split in two (Create(IAssetStore) before
    webview_create, Attach(webview_t) after, then the same
    Detach/Destroy), because upstream builds the WKWebView's
    configuration inside webview_create and a post-create seam does not
    exist there.

    CAP-8B adds the navigation guard to the same block, deliberately: an
    alias is how this host stays ONE program on four targets. The
    Windows and Linux guards are Create(webview_t)/Detach/Destroy and the
    Cocoa one is Create/Attach(webview_t)/Detach/Destroy, mirroring its
    own asset handler - but unlike that handler BOTH halves belong at the
    one construction site below, because a WKNavigationDelegate is
    installed on a view that already exists. Upstream leaves the needed
    hooks free on every engine: NavigationStarting,
    FrameNavigationStarting, NewWindowRequested and DownloadStarting on
    WebView2, decide-policy and create on WebKitGTK, and
    navigationDelegate on WKWebView (upstream owns only setUIDelegate:).

    What the guards do NOT expose is a decision: they translate their
    native event into a TPWebNavRequest and hand it to the one shared
    classifier. Every other line below is shared source. }
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
  MAX_AUTOCLOSE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;
  APP_TITLE = 'PWeb CAP-6 Release';
  LOG_PREFIX = 'releaseapp';
  { The canonical runtime verdict, spelled ONCE: it is printed to stdout and
    written to the --pweb-verdict file, and two spellings of one marker is
    how a gate ends up grepping for a line nobody emits. The leading ': '
    is part of the literal ON PURPOSE: the CAP-6b1 marker-contract check
    (test/cap6b1/check_cap6b1_contracts.ps1) requires this file to carry the
    exact producer substring beginning ': app.pwb', so the separator lives
    inside the constant rather than at each use site. }
  VERDICT_PASS = ': app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS';
  { CAP-7M2 optional arguments (all platforms; see the header comment) }
  ARG_VERDICT = '--pweb-verdict=';
  ARG_AUTOCLOSE = '--pweb-autoclose-ms=';
  { CAP-10A: the canonical external-open method and the capability that
    authorizes it are no longer spelled here at all. They live in
    pweb.rpc.command as PWEB_METHOD_OPEN_EXTERNAL / PWEB_CAP_EXTERNAL_OPEN,
    together with the ONE implementation of the command, because CAP-8B's
    host-local placement had produced four private copies of the same
    decision by the close of CAP-9. What stays host-private is the two
    things that genuinely are: which platform opener to call
    (OpenExternalUri below) and what to log about the outcome. }
  CAP_CALCULATOR_ADD = 'calculator.add';

type
  ICalculatorService = interface(IInvokable)
    ['{F2D880F7-0EE4-4EBE-8371-FBB16467BE41}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Host-owned decorator over the FROZEN bridge, carrying the two
    methods this host implements itself: example.report (the page's
    machine verdict) and, since CAP-8B, pweb.openExternal - which the
    bridge answers method_not_found for, by design, because pweb.* is
    the runtime's namespace and the runtime is where it belongs. Every
    application method still passes straight to the real bridge on
    workers. }
  TReportingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { CAP-8A (ratified D9): host-private IWebViewInvocationHandler wrapper
    that populates Context.Capabilities with the policy's PER-INVOCATION
    effective snapshot (AppMaximum INTERSECT Principal INTERSECT Window
    INTERSECT RuntimeGrants) before delegating to the standard envelope
    handler. The snapshot is computed on the callback thread - cheap
    lock + copy, within the ratified callback duties - so every enqueued
    invocation captures the effective set that was true AT ENQUEUE and a
    later native grant change never mutates an in-flight context. The
    handshake then advertises this true effective set with zero bridge
    changes. }
  TPolicyContextHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FInner: IWebViewInvocationHandler;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy; // keeps the policy object alive
  public
    constructor Create(const AInner: IWebViewInvocationHandler;
      const APolicy: TPWebCapabilityPolicy);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
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
  // the ONLY field this wrapper touches: the per-invocation effective
  // snapshot. Everything else stays the binding-built native context -
  // nothing here ever reads the JS payload.
  ctx := Context;
  ctx.Capabilities := FPolicy.SnapshotCapabilities(
    ctx.PrincipalId, ctx.WindowId);
  FInner.HandleInvocation(ctx, Request, Completion);
end;

{ CAP-8A: the production policy, built ONLY from native Pascal builder
  code at the trust level of the executable - never from app.pwb, a
  manifest, JS, the environment or any file. Any malformed row raises
  EPWebCapabilityConfig and the host fails to start (fail-closed
  construction, atomically). }
function BuildReleasePolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    // the explicit mandatory ceiling of this application
    b.SetAppMaximum([CAP_CALCULATOR_ADD, PWEB_CAP_EXTERNAL_OPEN]);
    // the single production window and its principal: the full ceiling
    b.SetWindowCapabilities('main', [CAP_CALCULATOR_ADD, PWEB_CAP_EXTERNAL_OPEN]);
    b.SetPrincipalCapabilities('window:main',
      [CAP_CALCULATOR_ADD, PWEB_CAP_EXTERNAL_OPEN]);
    // the sole application service
    b.MapMethod('CalculatorService.Add', [CAP_CALCULATOR_ADD]);
    // CAP-8B: handing a URI to the operating system is an AUTHORIZATION
    // decision, never an inference from a gesture flag - so the method is
    // MAPPED, deliberately not zero-cap. The policy runs at the scheduler
    // BEFORE the bridge, so a principal without 'external.open' is
    // answered forbidden/403 with no opener activity of any kind, and the
    // interception below is never even reached.
    b.MapMethod(PWEB_METHOD_OPEN_EXTERNAL, [PWEB_CAP_EXTERNAL_OPEN]);
    // runtime-owned methods: explicitly capability-free (context is
    // still validated; distinct from unmapped, which is denied)
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(PWEB_METHOD_ECHO);
    // the page's machine-verdict channel, intercepted by
    // TReportingBridge - policy runs BEFORE the bridge, so the report
    // must be a registered method or no verdict could ever latch
    b.RegisterZeroCapMethod('example.report');
    // the SDK acceptance pages probe an UNREGISTERED method and require
    // the bridge's typed method_not_found (errmap). Registering the
    // probe zero-cap preserves that frozen contract through the
    // production policy: allowed here, then the bridge catalog miss
    // answers 404 - the ratified mapped-but-unregistered shape (I7).
    // Every OTHER unknown method is now forbidden pre-bridge, by design.
    b.RegisterZeroCapMethod('No.SuchMethod');
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ CAP-8B: the second and last platform-selected name in this file (the
  guard alias above is the first). Each adapter hands the URI to its OS
  as DATA through one public API - ShellExecuteExW on Windows,
  g_app_info_launch_default_for_uri on Linux, -[NSWorkspace openURL:] on
  macOS - with no shell string, no cmd.exe, no /bin/sh and no
  subprocess interpolation anywhere. None of them decides anything: the
  scheme allowlist, the length bound and the control-byte rejection all
  live in PWebValidExternalUri, which has already run when this is
  called.

  Called on a scheduler WORKER thread, never the GUI thread - a bridge
  is always invoked on a worker. Each adapter satisfies its own OS
  affinity requirements: Windows initializes COM (STA) around
  ShellExecuteExW because SEE_MASK_NOASYNC documents it as a
  precondition; macOS dispatch_sync's the AppKit -[NSWorkspace openURL:]
  message onto the main queue; Linux calls
  g_app_info_launch_default_for_uri, which GIO documents as
  thread-safe, directly on the worker. }
function OpenExternalUri(const AUri: RawUtf8): Boolean;
begin
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

{ CAP-10A: the host's OBSERVATION of an external open, and the whole of
  what this host still owns about the command.

  The decision - validate through PWebValidExternalUri, reach the opener at
  most once, map the three outcomes onto the frozen taxonomy - now lives in
  ONE place, pweb.rpc.command, because by the close of CAP-9 it existed as
  four byte-similar private copies that no gate could tell apart. What is
  genuinely this host's is the platform opener above and the redacted log
  line below.

  REDACTION, unchanged from CAP-8B: the URI is never written to the log -
  not the query string, not a mailto body, not even the host. Only its byte
  length and the outcome category. The decorator hands over exactly that. }
procedure ObserveExternalOpen(const Context: TInvocationContext;
  Outcome: TPWebOpenOutcome; UriBytes: PtrInt);
begin
  case Outcome of
    pooRefused:
      WriteLn(LOG_PREFIX, ': openExternal REFUSED (uri bytes=',
        UriBytes, ')');
    pooFailed:
      WriteLn(StdErr, LOG_PREFIX, ': openExternal FAILED (uri bytes=',
        UriBytes, ')');
    pooOpened:
      WriteLn(LOG_PREFIX, ': openExternal OK (uri bytes=', UriBytes, ')');
  end;
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
       // CAP-8B: the navigation-security block is REQUIRED here, not
       // merely reported. The page's own `ok` deliberately excludes it -
       // the same corpus runs under the allow-all example hosts, which
       // install no guard - so the release runtime is where a regression
       // has to turn red, on all four targets, in the smoke itself.
       (Pos('"navExternalBlocked":true', Args) > 0) and
       (Pos('"navAuthorityBlocked":true', Args) > 0) and
       (Pos('"navCspBlocked":true', Args) > 0) and
       (Pos('"navOpenExternal":true', Args) > 0) and
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

{$ifdef DARWIN}
{ CAP-7M2: the macOS pre-create check. Like Linux there is no runtime to
  PROVISION - WebKit ships with the OS - but there is one process state that
  is knowable BEFORE webview_create and fatal after it: FPC starts every
  process with the invalid-operation/divide-by-zero/overflow FPU traps
  ENABLED, and WebKit, CoreGraphics and AppKit compute with NaNs as ordinary
  intermediate values, so the first such computation would kill the process
  with EInvalidOp from inside a C frame. pweb.platform.cocoa's unit
  initialization masks the traps through libc (fesetenv) and RECORDS whether
  that worked; this check turns that record into a typed refusal before any
  window can exist. TCocoaAssetHandler.Create re-applies the mask on its own
  thread and raises on failure, so the check here is the loud early half,
  not the only line of defence. }
procedure CheckCocoaRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, LOG_PREFIX,
    ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create(
    'the FPU could not be put in its non-trapping default state - WebKit ' +
    'would kill this process on its first NaN; no WebView was created');
end;
{$endif DARWIN}

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

{$ifndef DARWIN}
{$ifndef LINUX}
{ Everything from here to the matching endif is the WINDOWS
  runtime-provisioning pre-check, whose Linux counterpart is the display
  check above and whose macOS counterpart is the FPU-trap check above
  (CAP-7M2: before that check existed, the LINUX/else split alone selected
  this Windows block on Darwin, which is why this file had never compiled
  there).

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
{$endif DARWIN}

{ Locate app.pwb from the EXECUTABLE location (never the CWD), then run the
  full production gate BEFORE anything webview-related exists. On
  refusal the typed marker goes to stderr and the raised exception
  makes the process exit nonzero - zero bundle JS can ever execute. }
function LoadReleaseBundle: IAssetStore;
var
  imageDir, bundleFile: TFileName;
  refusal: TPWebBundleRefusal;
begin
  // CAP-10E: the KERNEL's answer for the running image, never the RTL's
  // argv - see pweb.imagepath. '' is a refusal, never a bare file name.
  imageDir := PWebImageDir;
  if imageDir = '' then
  begin
    WriteLn(StdErr, LOG_PREFIX, ': app.pwb REFUSED (image path unavailable)');
    raise Exception.Create(
      'image path unavailable - no WebView was created');
  end;
  {$ifdef DARWIN}
  // CAP-7M2: inside a .app the executable lives in Contents/MacOS and the
  // bundle in Contents/Resources. ExpandFileName only folds the '..' out of
  // an already-absolute path here - PWebImageDir is absolute - so the
  // resolution never consults the working directory.
  bundleFile := ExpandFileName(imageDir + '..' +
    PathDelim + 'Resources' + PathDelim + 'app.pwb');
  {$else}
  bundleFile := imageDir + 'app.pwb';
  {$endif DARWIN}
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

{ CAP-7M2: the two optional arguments, parsed strictly in TWO PASSES.

  Pass 1 only captures the verdict path, wherever it appears, and raises
  nothing: the whole point of the verdict file is to carry evidence out of a
  launch whose stdout nobody can see, and a refusal that fired BEFORE the
  path was known would leave exactly the missing-file outcome the gate
  cannot tell from a crash. Pass 2 then validates and refuses - unknown,
  malformed, empty and REPEATED options all refuse alike, because an option
  silently resolved last-one-wins is an argument the host half-ignores. So
  even a refused command line still writes a FAIL verdict when a verdict
  path was supplied anywhere on it.

  AAutoCloseMs stays -1 when the argument is absent so the caller can tell
  "not given" (fall back to the environment) from "given as 0". }
procedure ParseArguments(out AVerdictFile: TFileName;
  out AAutoCloseMs: Integer);
var
  i: Integer;
  arg, value: string;
  verdictSeen, autoCloseSeen: Boolean;
begin
  AVerdictFile := '';
  AAutoCloseMs := -1;
  verdictSeen := False;
  autoCloseSeen := False;
  // PASS 1: capture only. A duplicated verdict option is refused by pass 2,
  // but the LAST path seen is where that refusal's FAIL verdict lands.
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, Length(ARG_VERDICT)) = ARG_VERDICT then
    begin
      value := Copy(arg, Length(ARG_VERDICT) + 1, MaxInt);
      if value <> '' then
        // Expanded ONCE, here, before anything can change the working
        // directory - so a relative path from the caller stays anchored to
        // the CWD the process was started with, deterministically.
        AVerdictFile := ExpandFileName(value);
    end;
  end;
  // PASS 2: validate and refuse.
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, Length(ARG_VERDICT)) = ARG_VERDICT then
    begin
      if verdictSeen then
        raise Exception.Create('duplicate argument refused: ' + ARG_VERDICT);
      verdictSeen := True;
      value := Copy(arg, Length(ARG_VERDICT) + 1, MaxInt);
      if value = '' then
        raise Exception.Create(ARG_VERDICT + ' requires a file path');
    end
    else if Copy(arg, 1, Length(ARG_AUTOCLOSE)) = ARG_AUTOCLOSE then
    begin
      if autoCloseSeen then
        raise Exception.Create('duplicate argument refused: ' + ARG_AUTOCLOSE);
      autoCloseSeen := True;
      value := Copy(arg, Length(ARG_AUTOCLOSE) + 1, MaxInt);
      AAutoCloseMs := StrToIntDef(value, -1);
      if AAutoCloseMs < 0 then
        raise Exception.Create(
          ARG_AUTOCLOSE + ' requires a non-negative integer, got: ' + value);
    end
    else
      raise Exception.Create('usage: ' + LOG_PREFIX +
        ' [' + ARG_VERDICT + '<file>] [' + ARG_AUTOCLOSE + '<ms>]' +
        ' -- unknown argument: ' + arg);
  end;
end;

{ CAP-7M2: the verdict FILE - the one deterministic evidence channel a
  LaunchServices launch leaves behind (`open -W` forwards neither stdout nor
  the exit code, and LaunchServices does not inherit the caller's
  environment). The full line goes to a per-process temp sibling first and
  is then moved into place. On POSIX the move is rename(), which replaces
  atomically: a reader sees the previous state or the complete line, never
  a half-written one and never a missing file. On Windows RenameFile does
  not replace an existing target, so an existing file is deleted first -
  a short no-file window that exists on Windows only, accepted and stated
  rather than dressed up as atomicity. }
procedure WriteVerdictFile(const AFile: TFileName; const ALine: string);
var
  tmp: TFileName;
  t: Text;
begin
  // per-process unique: two concurrent instances aimed at one verdict path
  // must never write through a shared temp sibling - each renames its own,
  // and the target ends up as ONE complete line from one of them
  tmp := AFile + '.' + IntToStr(GetProcessID) + '.tmp';
  AssignFile(t, tmp);
  Rewrite(t);
  try
    WriteLn(t, ALine);
  finally
    CloseFile(t);
  end;
  {$ifdef OSWINDOWS}
  // Windows-only: RenameFile fails on an existing target there. POSIX
  // rename() replaces atomically, so no delete - and no window - exists
  // off Windows.
  if FileExists(AFile) then
    DeleteFile(AFile);
  {$endif OSWINDOWS}
  if not RenameFile(tmp, AFile) then
    raise Exception.Create('unable to move the verdict file into place: ' +
      string(AFile));
end;

var
  w: webview_t;
  store: IAssetStore;
  assetHandler: TPWebAssetHandler;
  navGuard: TPWebNavigationGuard;
  server: TRestServerFullMemory;
  factory: TServiceFactoryServerAbstract;
  realBridge, bridge: IInvocationBridge;
  capPolicy: TPWebCapabilityPolicy;
  capPolicyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  autoCloseMs, argAutoCloseMs: Integer;
  verdictFile: TFileName;
  closerId, closerHandle: system.TThreadID; // mormot.core.os shadows it
  closerStarted, safeToDestroy, schedulerDrained: Boolean;
begin
  ExitCode := 0;
  server := nil;
  scheduler := nil;
  assetHandler := nil;
  navGuard := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  verdictFile := '';
  argAutoCloseMs := -1;
  InterlockedExchange(GuiThreadId, LongInt(GetCurrentThreadId));
  try
    // CAP-7M2: parsed FIRST, so the verdict file is known before anything
    // can fail - a refused bundle still leaves a FAIL verdict behind when a
    // verdict file was asked for. Unknown arguments are refused exactly as
    // the old "no arguments" rule refused everything.
    ParseArguments(verdictFile, argAutoCloseMs);
    store := LoadReleaseBundle;

    server := TRestServerFullMemory.CreateWithOwnModel([]);
    factory := server.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register CalculatorService');
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    // CAP-10A: the reusable runtime-command layer sits between this
    // host's own decorator and the real bridge, which is the SAME order
    // every PWeb host uses. The application decorator therefore still
    // sees every arrival (its accounting is unchanged), example.report is
    // still answered by it, and everything it does not implement -
    // pweb.openExternal included - falls through to the shared runtime
    // command layer and then to the real bridge. The opener and the
    // redacted log line are all this host still supplies.
    bridge := TReportingBridge.Create(
      TPWebRuntimeCommandBridge.Create(realBridge, @OpenExternalUri,
        @ObserveExternalOpen));
    // CAP-8A: the production contextual policy replaces the Phase-2
    // allow-all at the SAME single call site - the plumbing is untouched
    capPolicy := BuildReleasePolicy;
    capPolicyRef := capPolicy;
    scheduler := TInvocationScheduler.Create(capPolicyRef, bridge, 4);
    schedulerRef := scheduler;
    limits := Default(TPWebSourceLimits);
    limits.MaxConcurrent := 4;
    limits.MaxQueueSize := 32;
    source := scheduler.RegisterSource(limits);

    {$ifdef DARWIN}
    // CAP-7M2: the same call site, for the same reason as its siblings -
    // one cause that is knowable BEFORE webview_create, refused with a
    // typed marker instead of dying mid-render.
    CheckCocoaRuntimeUsable;
    // THE ONE FORCED ORDERING DIFFERENCE: Cocoa's pweb://app seam is armed
    // by CONSTRUCTION, and only a webview created after it can be served -
    // upstream builds the WKWebViewConfiguration inside webview_create and
    // exposes no post-create seam. Attach below proves the seam actually
    // ran for the view that came back.
    assetHandler := TCocoaAssetHandler.Create(store);
    {$else}
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
    {$endif DARWIN}

    w := WebViewCheckCreated(webview_create(0, nil));
    try
      {$ifdef DARWIN}
      // raises unless the pre-create seam RAN and THIS view's own
      // configuration reports OUR handler for pweb:// - a seam that
      // silently stopped running can never again present as success
      assetHandler.Attach(w);
      {$endif DARWIN}
      {$ifdef PWEB_FIXED_RUNTIME}
      // CAP-6b3: identity is OBSERVED, not inferred - and it is
      // observed here, before webview_navigate can load anything
      CheckObservedFixedIdentity(w, FixedRuntime);
      {$endif PWEB_FIXED_RUNTIME}
      AutoCloseHandle := Pointer(w);
      // the native context TEMPLATE deliberately carries NO capability
      // list: the D9 wrapper below computes the per-invocation
      // effective snapshot, so a template list could only ever go stale
      context := Default(TInvocationContext);
      context.WindowId := 'main';
      context.PrincipalId := 'window:main';
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, source, opts);
      binding.Bind('__pweb_invoke', TPolicyContextHandler.Create(
        TPWebEnvelopeHandler.Create(source), capPolicy));
      WebViewCheck(webview_set_title(w, PAnsiChar(AnsiString(APP_TITLE))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      // production asset path: attach the pweb://app handler on the
      // proven native seam, then navigate - never any injected HTML.
      // CAP-4W borrowed-controller seam on Windows, CAP-7L
      // BROWSER_CONTROLLER -> WebKitWebContext seam on Linux; the
      // attach point itself is unchanged on both. On Darwin the handler
      // already exists (created BEFORE webview_create, Attach-proven just
      // after it) - the two-phase seam is the platform's shape, not a
      // frontend branch, and there is nothing to construct here.
      {$ifndef DARWIN}
      {$ifdef LINUX}
      assetHandler := TWebKitGtkAssetHandler.Create(w, store);
      {$else}
      assetHandler := TWebView2AssetHandler.Create(w, store);
      {$endif LINUX}
      {$endif DARWIN}
      // CAP-8B: the privileged-navigation guard, installed HERE - after
      // the handler that can serve trusted content, before the first
      // navigation that could load any - so no document, trusted or not,
      // ever commits unclassified. MEASURED on all four targets: no
      // engine raises a navigation event for its own initial
      // about:blank (Windows reports it only as a source, Linux and
      // macOS report none), so there is deliberately no bootstrap
      // exception and no armed state to get wrong.
      //
      // What arrives at the guard is a native event; what leaves it is
      // TPWebNavRequest, and PWebClassifyNavigation - the ONE classifier
      // in src/security, shared byte-for-byte by every target - answers.
      // This file therefore carries no navigation policy at all.
      {$ifdef DARWIN}
      // Cocoa's guard is two-phase like its handler, but BOTH halves
      // belong here: a WKNavigationDelegate goes on a view that already
      // exists, and Attach raises unless the view reports OUR delegate
      // afterwards - "installed" is a property of the view, never the
      // absence of an exception.
      navGuard := TPWebNavigationGuard.Create;
      navGuard.Attach(w);
      {$else}
      navGuard := TPWebNavigationGuard.Create(w);
      {$endif DARWIN}
      WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

      // CAP-7M2: the argument WINS over the environment - LaunchServices
      // delivers argv but no environment, so argv is the channel a
      // machine-checked launch actually controls.
      if argAutoCloseMs >= 0 then
        autoCloseMs := argAutoCloseMs
      else
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
      // CAP-8B ordering: teardown is the exact reverse of construction,
      // so the guard stops deciding before the handler stops serving and
      // both are disowned before webview_destroy. Detach is what makes a
      // late engine callback unable to reach a freed object - the same
      // disown/generation discipline the asset handler already uses -
      // and a Detach that raises must not skip the ones after it.
      if navGuard <> nil then
        try
          navGuard.Detach;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: navigation guard Detach: ', E.Message);
            ExitCode := 1;
          end;
        end;
      // guarded separately: Destroy calls Detach again as a safety net, and
      // an exception escaping here would abort THIS finally block - skipping
      // the asset handler Detach and webview_destroy below, which must run
      // no matter what state the guard died in
      try
        FreeAndNil(navGuard);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'FAIL: navigation guard Free: ', E.Message);
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
      WriteLn(LOG_PREFIX, VERDICT_PASS)
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
  // CAP-7M2: the trailing release chain runs under its own guard so that
  // control ALWAYS reaches the verdict write below - an exception raised by
  // an interface release or by server.Free must become a FAIL verdict, not
  // a missing file the LaunchServices gate cannot tell from a crash.
  try
    binding := nil;
    source := nil;
    schedulerRef := nil;
    scheduler := nil;
    capPolicyRef := nil; // policy object released through its refcount
    capPolicy := nil;
    bridge := nil;
    realBridge := nil; // frees owned server after worker drain
    store := nil;
    server.Free;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: final teardown: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  // CAP-7M2: EVERY exit path ends here - the success path, the runtime FAIL
  // path and every exception path above all fall through to this line - so a
  // requested verdict file always exists when the process is gone, carrying
  // either the canonical PASS marker or a typed FAIL line. A failure to
  // write it is itself a failure: a gate reading a missing file must find a
  // nonzero exit behind it, never a silently green one. The one exit shape
  // no user code can write a verdict for is death by SIGNAL (a kill, a
  // loader abort): the file is then simply absent, which the gate reads as
  // failure - fail-closed in the only direction available.
  if verdictFile <> '' then
    try
      if ExitCode = 0 then
        WriteVerdictFile(verdictFile, LOG_PREFIX + VERDICT_PASS)
      else
        WriteVerdictFile(verdictFile, LOG_PREFIX + ': FAIL (exit=' +
          IntToStr(ExitCode) + ')');
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'FAIL: verdict file write: ', E.Message);
        ExitCode := 1;
      end;
    end;
  if ExitCode = 0 then
    WriteLn(LOG_PREFIX, ': clean exit');
end.
