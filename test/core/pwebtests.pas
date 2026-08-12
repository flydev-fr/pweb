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
    'CAP-6 bundle)');
end.
