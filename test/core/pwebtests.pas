program pwebtests;

{ PWeb test suite runner (mormot.core.test).

  Aggregates the runtime test cases of the project; compile-level gates
  (abi_probe.pas paired byte-diff, signature_pin.pas) stay as dedicated
  programs.

  Exit code 0 = every assertion of every case passed; 1 otherwise. }

{$I mormot.defines.inc}

{ CAP-8A: the capability integration gates drive the REAL mORMot
  interface-service path, so they need the mORMot ORM/REST/SOA unit paths.
  The POSIX suites hand this program the full set and it registers them
  here; the Windows compile deliberately does not, and runs them through
  cap3tests instead, which the CAP-3U step asserts by name. That is what
  puts the I1-I10 gates on all four CI targets.

  Until the 2026-09-08 mORMot pin move this condition also carried
  PWEB_CALLMETHOD_UNWIND_PROBE, which named the CAP-3U patch window. The
  define was never set for THIS program on any target, so it contributed
  nothing to the truth value; it is gone with the patch, and the condition
  now says the one thing it actually means. }
{$ifndef OSWINDOWS}
  {$define PWEB_CAP8A_INTEGRATION}
{$endif}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.core,
  pweb.test.scheduler,
  pweb.test.binding,
  pweb.test.lifecycle,
  pweb.test.assets,
  pweb.test.bundle,
  pweb.test.htmlpolicy,
  pweb.test.devconsole,
  pweb.test.capabilities,
  pweb.test.command,
  pweb.test.navigation
  {$ifdef PWEB_CAP8A_INTEGRATION}
  ,
  pweb.test.capabilities.integration
  {$endif PWEB_CAP8A_INTEGRATION}
  {$ifdef OSWINDOWS}
  ,
  pweb.test.webview2runtime,
  pweb.test.wv2provision,
  pweb.test.wv2fixed
  {$endif OSWINDOWS}
  {$ifdef LINUX}
  ,
  pweb.test.webkitgtk
  {$endif LINUX}
  {$ifdef DARWIN}
  ,
  pweb.test.cocoa
  {$endif DARWIN}
  ;

type
  TPWebTests = class(TSynTests)
  published
    procedure CoreBinding;
    procedure InvocationPipeline;
    procedure AssetSystem;
    procedure BundleSystem;
    procedure HtmlPolicy;
    procedure DevConsole;
    procedure CapabilityPolicy;
    procedure NavigationPolicy;
    procedure RuntimeCommand;
    {$ifdef PWEB_CAP8A_INTEGRATION}
    procedure CapabilityPolicyIntegration;
    {$endif PWEB_CAP8A_INTEGRATION}
    {$ifdef OSWINDOWS}
    procedure WebView2Runtime;
    procedure WebView2Provisioning;
    procedure WebView2FixedRuntime;
    {$endif OSWINDOWS}
    {$ifdef LINUX}
    procedure WebKitGtkAdapter;
    {$endif LINUX}
    {$ifdef DARWIN}
    procedure CocoaAdapter;
    {$endif DARWIN}
  end;

procedure TPWebTests.CoreBinding;
begin
  AddCase([TTestPWebCoreBinding]);
end;

procedure TPWebTests.AssetSystem;
begin
  // CAP-4, headless: shared canonical-path validation and MIME, then
  // Folder/ZIP store parity over one generated fixture corpus - no
  // window, no webview.dll and no WebView2 runtime required
  AddCase([TTestAssetStores]);
end;

procedure TPWebTests.BundleSystem;
begin
  // CAP-6, headless: manifest schema + strict SemVer + the injected
  // compat predicate, the deterministic validating bundler and the
  // production app.pwb loader with typed refusals - no window, no
  // webview.dll and no WebView2 runtime required
  AddCase([TTestBundleSystem]);
end;

procedure TPWebTests.HtmlPolicy;
begin
  // CAP-14A, headless on every target: what the native CSP will not run.
  // A pure scan of bytes - the four refusal classes, the accepted data
  // blocks and inline style, and the adversarial tokenizer shapes that
  // could hide an executable script from a naive scanner. Also emits the
  // CAP-7F decision corpus (build/cap7f/html-policy.txt), whose digest
  // four targets must agree on.
  AddCase([TTestHtmlPolicy]);
end;

procedure TPWebTests.DevConsole;
begin
  // CAP-14B, headless on every target: the development console surface
  // below the engine. The parameter decode, the record grammar, the level
  // table, the sanitiser that keeps one record to one line, the two
  // truncations, and the AUTHORITATIVE ring bound driven through the real
  // ring and the real writer path. Also emits the CAP-7F decision corpus
  // (build/cap7f/dev-console.txt), whose digest four targets must agree on.
  AddCase([TTestDevConsole]);
end;

procedure TPWebTests.NavigationPolicy;
begin
  // CAP-8B, headless on every target: the shared privileged-navigation
  // classifier - the B-matrix as decisions, the authority-confusion
  // vectors, the external-open validator and the native CSP profile - over
  // a pure function, so no window, no webview and no engine is required.
  // Also emits the CAP-7F navigation-decision corpus
  // (build/cap7f/navigation-policy.txt).
  //
  // ActivationIsNotAnInput is the load-bearing case: it replays the whole
  // corpus with the user-activation flag inverted and requires identical
  // decisions, because CAP-8B MEASURED that no engine reports activation
  // honestly and the ratified model makes it diagnostic only.
  AddCase([TTestNavigationPolicy]);
end;

procedure TPWebTests.RuntimeCommand;
begin
  // CAP-10A, headless on every target: the reusable runtime-command
  // decorator (the ONE pweb.openExternal implementation, its opener-count
  // measurements and its fail-closed construction) plus the ratified
  // production trust profile - no window, no webview, no bridge required
  AddCase([TTestRuntimeCommand]);
end;

procedure TPWebTests.CapabilityPolicy;
begin
  // CAP-8A, headless on every target: the production capability engine
  // (grammar A1-A6, sets/builder A7-A15, mapping A16-A22, context
  // identity A23-A26, exception barrier A27, runtime grants A28-A30,
  // advisory zero-cap A31-A32, deny envelope A33-A35) over the real
  // scheduler with the counting dummy bridge - no window, no webview,
  // no mORMot bridge required. Also emits the CAP-7F policy-decision
  // corpus (build/cap7f/capability-policy.txt).
  AddCase([TTestCapabilityPolicy]);
end;

{$ifdef PWEB_CAP8A_INTEGRATION}
procedure TPWebTests.CapabilityPolicyIntegration;
begin
  // CAP-8A gates I1-I10: the reference configuration through the REAL
  // pipeline (scheduler workers -> production policy ->
  // TMormotInvocationBridge -> in-process Uri()) with counting spies on
  // the SOA layer and every service - headless, no window
  AddCase([TTestCapabilityPolicyIntegration]);
end;
{$endif PWEB_CAP8A_INTEGRATION}

{$ifdef OSWINDOWS}
procedure TPWebTests.WebView2Runtime;
begin
  // CAP-6b0, Windows-private: strict 4-part version policy pinned to
  // the CAP-4W loader minimum (build >= 1587), provisioning decisions
  // over injected detection records, the frozen post-install re-probe
  // invariant, and one real registry probe smoke - no window, no
  // webview.dll and no WebView2 runtime required (the probe only
  // reads registry state and reports it)
  AddCase([TTestWebView2Runtime]);
end;

procedure TPWebTests.WebView2Provisioning;
begin
  // CAP-6b1, Windows-private: the normal-profile provisioning
  // orchestration (detect -> verify sha256 + authenticode -> bounded
  // execute -> mandatory re-probe) over the full injected N1-N12
  // matrix, plus real hasher/WinVerifyTrust/bounded-runner smokes -
  // no window, no webview.dll, no WebView2 runtime and no Microsoft
  // binary required (nothing is ever downloaded or installed here)
  AddCase([TTestWv2Provision]);
end;

procedure TPWebTests.WebView2FixedRuntime;
begin
  // CAP-6b3, Windows-private: the fixed-runtime profile's pure path
  // and observed-identity policies, the full tree validation matrix
  // over a FABRICATED on-disk tree (fake drive-type/file-version
  // seams, hand-built PE images), the real Windows AppContainer ACL
  // apply/verify BY SID in both directions over an isolated DACL, the
  // deterministic tree manifest, and the ratified selection order
  // (loader preload -> module identity -> env var + read-back) - no
  // window, no webview.dll, no WebView2 runtime and no Microsoft
  // binary required (nothing is downloaded, installed or executed)
  AddCase([TTestWv2Fixed]);
end;
{$endif OSWINDOWS}

{$ifdef LINUX}
procedure TPWebTests.WebKitGtkAdapter;
begin
  // CAP-7L, Linux-private: the pweb://app adapter's own routines - the
  // URI gate over the CAP-4 hostile vectors (with a counting store
  // proving a refused URI never costs a lookup), deterministic MIME
  // parity, and the response-lifetime regression that requires the
  // GIO-owned body to be an independent heap copy - no window, no
  // display, no GTK initialisation and no libwebview.so needed
  AddCase([TTestWebKitGtkAdapter]);
end;
{$endif LINUX}

{$ifdef DARWIN}
procedure TPWebTests.CocoaAdapter;
begin
  // CAP-7M1, macOS-private: the pweb://app adapter's own routines and its
  // REAL Objective-C++ bridge - the URI gate over the CAP-4 hostile vectors
  // (with a counting store proving a refused URI never costs a lookup),
  // deterministic MIME parity, the bridge-owned response body, the
  // generation-checked handle registry, and the WKURLSchemeTask state
  // machine driven deterministically over a stub task (claim-once terminals,
  // post-stop suppression, idempotent cancel, teardown drain, disowned
  // handler) - no window, no NSApplication, no display and no
  // webview_create needed
  AddCase([TTestCocoaAdapter]);
end;
{$endif DARWIN}

procedure TPWebTests.InvocationPipeline;
begin
  // CAP-2, sharded by domain: scheduler + policy call site + dummy
  // bridge (headless, non-WebView source), the WebView binding over
  // fake native functions, then the lifecycle/teardown cases of both
  // domains - no window, no webview.dll required for these cases
  AddCase([TTestInvocationScheduler, TTestWebViewBinding,
    TTestSourceLifecycle, TTestBindingLifecycle]);
end;


begin
  // sets ExitCode = 1 on any failed assertion; pass /noenter switch in
  // scripts/CI so no ENTER key is awaited on exit
  TPWebTests.RunAsConsole('PWeb tests (CAP-1 raw binding + ' +
    'CAP-2 invocation pipeline + CAP-3 bridge + CAP-4 assets + ' +
    'CAP-6 bundle + CAP-6b0 WebView2 runtime detection + ' +
    'CAP-6b1 WebView2 provisioning + CAP-6b3 fixed runtime + ' +
    'CAP-8A capability policy)');
end.
