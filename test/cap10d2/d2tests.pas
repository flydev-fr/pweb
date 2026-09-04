program d2tests;

{ CAP-10D2 SDK distribution test suite runner (mormot.core.test).

  Headless on all four targets, and deliberately so: the escape rule and the
  canonical document are pure functions, and the verifier reads a fixture
  tree of a dozen small files this suite writes itself. That is what lets a
  Linux runner assert the whole integrity model, and what makes the
  four-target sdk_digest a fact about the RULES rather than about four
  machines.

  What is NOT here, and belongs to the gate: the real packager over the real
  staged SDK root, the real archive, the real extraction onto a clean
  machine with the checkout renamed aside, the real doctor rows, the real
  build refusal at exit 4 and the real 42.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.sdk;

type
  TPWebD2Tests = class(TSynTests)
  published
    procedure TheCanonicalJsonRule;
    procedure TheDistributionManifest;
    procedure TheIntegrityVerifier;
  end;

procedure TPWebD2Tests.TheCanonicalJsonRule;
begin
  AddCase([TTestPWebSdkCanonical]);
end;

procedure TPWebD2Tests.TheDistributionManifest;
begin
  AddCase([TTestPWebSdkManifest]);
end;

procedure TPWebD2Tests.TheIntegrityVerifier;
begin
  AddCase([TTestPWebSdkVerify]);
end;

begin
  TPWebD2Tests.RunAsConsole('PWeb CAP-10D2 tests (the canonical JSON escape ' +
    'rule and C1-11 (c) + the SDK distribution manifest + the full ' +
    'integrity verifier and every way an installation can be wrong)');
  PWebCap10d2Flush;

end.
