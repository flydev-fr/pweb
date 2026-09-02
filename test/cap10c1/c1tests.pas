program c1tests;

{ CAP-10C1 lifecycle-pipeline test suite runner (mormot.core.test).

  Headless on all four targets, and deliberately so: every rule the pipeline
  owns that is not a spawn is a PURE FUNCTION of its inputs or a question
  about a fixture directory this suite builds itself. That is what lets a
  Linux runner assert the macOS arm64 link line and the Windows npm entry
  point, and what makes the four-target pipeline_digest a fact about the
  RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real pipeline on the real
  generated projects, app.pwb byte parity against the CAP-10B1 and CAP-10B2
  harnesses, `pweb run` on what it assembled, the interrupt driver, and the
  membership-scoped listener sampler. Those need real tools, a real display
  and a real signal, and a suite that pretended to have them would be the
  vacuous measurement this repository refuses.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.pipeline;

type
  TPWebC1Tests = class(TSynTests)
  published
    procedure PureRules;
    procedure FilesystemRules;
  end;

procedure TPWebC1Tests.PureRules;
begin
  AddCase([TTestPWebPipePure]);
end;

procedure TPWebC1Tests.FilesystemRules;
begin
  AddCase([TTestPWebPipeFs]);
end;

begin
  TPWebC1Tests.RunAsConsole('PWeb CAP-10C1 tests (command tables + SDK ' +
    'layout + staging + normalisation + mutation set)');
  PWebCap10c1Flush;

end.
