program d0tests;

{ CAP-10D0 public-build test suite runner (mormot.core.test).

  Headless on all four targets, and deliberately so: everything the public
  `build` owns that is not a spawn is either a pure function of its inputs or
  a question about a fixture directory this suite builds itself. That is what
  lets a Linux runner assert the macOS arm64 release layout and the
  replacement rule's failure table, and what makes the four-target
  build_digest a fact about the RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real `pweb build` end to
  end on a real generated project, the real interrupt mid-compile, the two
  builds whose app.pwb must be identical, the network sampling, the race
  with a running `pweb run`, and the Windows long path. Those need real
  tools, a real signal and a real runner, and a suite that pretended to have
  them would be the vacuous measurement this repository refuses.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.build;

type
  TPWebD0Tests = class(TSynTests)
  published
    procedure PureRules;
    procedure TheReplacementRule;
  end;

procedure TPWebD0Tests.PureRules;
begin
  AddCase([TTestPWebBuildPure]);
end;

procedure TPWebD0Tests.TheReplacementRule;
begin
  AddCase([TTestPWebBuildFs]);
end;

begin
  TPWebD0Tests.RunAsConsole('PWeb CAP-10D0 tests (exit mapping + ten stages ' +
    '+ mutation set + release layout + the release replacement rule and its ' +
    'failure table)');
  PWebCap10d0Flush;

end.
