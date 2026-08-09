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
  pweb.test.lifecycle;

type
  TPWebTests = class(TSynTests)
  published
    procedure CoreBinding;
    procedure InvocationPipeline;
  end;

procedure TPWebTests.CoreBinding;
begin
  AddCase([TTestPWebCoreBinding]);
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

begin
  // sets ExitCode = 1 on any failed assertion; pass /noenter switch in
  // scripts/CI so no ENTER key is awaited on exit
  TPWebTests.RunAsConsole('PWeb tests (CAP-1 raw binding + CAP-2 invocation pipeline)');
end.
