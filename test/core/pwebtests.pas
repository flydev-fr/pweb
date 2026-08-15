program pwebtests;

{ PWeb test suite runner (mormot.core.test).

  Aggregates the runtime test cases of the project; compile-level gates
  (abi_probe.pas paired byte-diff, signature_pin.pas) stay as dedicated
  programs.

  Exit code 0 = every assertion of every case passed; 1 otherwise. }

{$I mormot.defines.inc}

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
  pweb.test.bundle
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
  {$ifdef PWEB_CALLMETHOD_UNWIND_PROBE}
  ,
  pweb.test.mormot.bridge,
  pweb.test.mormot.routing,
  pweb.test.mormot.integration
  {$endif PWEB_CALLMETHOD_UNWIND_PROBE}
  ;

type
  TPWebTests = class(TSynTests)
  published
    procedure CoreBinding;
    procedure InvocationPipeline;
    procedure AssetSystem;
    procedure BundleSystem;
    {$ifdef OSWINDOWS}
    procedure WebView2Runtime;
    procedure WebView2Provisioning;
    procedure WebView2FixedRuntime;
    {$endif OSWINDOWS}
    {$ifdef LINUX}
    procedure WebKitGtkAdapter;
    {$endif LINUX}
    {$ifdef PWEB_CALLMETHOD_UNWIND_PROBE}
    procedure MormotBridge;
    {$endif PWEB_CALLMETHOD_UNWIND_PROBE}
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

procedure TPWebTests.InvocationPipeline;
begin
  // CAP-2, sharded by domain: scheduler + policy call site + dummy
  // bridge (headless, non-WebView source), the WebView binding over
  // fake native functions, then the lifecycle/teardown cases of both
  // domains - no window, no webview.dll required for these cases
  AddCase([TTestInvocationScheduler, TTestWebViewBinding,
    TTestSourceLifecycle, TTestBindingLifecycle]);
end;

{$ifdef PWEB_CALLMETHOD_UNWIND_PROBE}
procedure TPWebTests.MormotBridge;
begin
  AddCase([TTestMormotBridge, TTestMormotRouting,
    TTestMormotIntegration]);
end;
{$endif PWEB_CALLMETHOD_UNWIND_PROBE}

begin
  // sets ExitCode = 1 on any failed assertion; pass /noenter switch in
  // scripts/CI so no ENTER key is awaited on exit
  TPWebTests.RunAsConsole('PWeb tests (CAP-1 raw binding + ' +
    'CAP-2 invocation pipeline + CAP-3 bridge + CAP-4 assets + ' +
    'CAP-6 bundle + CAP-6b0 WebView2 runtime detection + ' +
    'CAP-6b1 WebView2 provisioning + CAP-6b3 fixed runtime)');
end.
