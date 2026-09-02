program c0tests;

{ CAP-10C0 supervision test suite runner (mormot.core.test).

  Headless on all four targets for the PURE and ENGINE subjects: the quoting
  rule and the drain are pure logic over injected inputs, and the engine
  cases drive one deliberately badly behaved child
  (test/cap10c0/pwebchild.pas) that must be built beside this executable.

  The RUN subject's last two cases need what only the gate can provide: a
  built React project staged beneath its own `output`, named by
  PWEB_C0_STAGE_REACT, and the real CLI, named by PWEB_C0_PWEB. Without them
  those two cases FAIL rather than skip - a stop-signal test that quietly
  passed with nothing to signal would be the exact vacuous measurement this
  repository refuses.

  It is a SEPARATE program from test/cap10a/clitests.pas on purpose: that
  suite is a frozen CAP-10A closure artifact and this one measures what
  CAP-10C0 added underneath it. The CAP-10A suite keeps running unchanged
  beside it, which is how "the probe semantics did not move" is proven.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.supervise;

type
  TPWebC0Tests = class(TSynTests)
  published
    procedure PureRules;
    procedure SupervisionEngine;
    procedure RunCommand;
  end;

procedure TPWebC0Tests.PureRules;
begin
  AddCase([TTestPWebCliPure]);
end;

procedure TPWebC0Tests.SupervisionEngine;
begin
  AddCase([TTestPWebCliSupervise]);
end;

procedure TPWebC0Tests.RunCommand;
begin
  AddCase([TTestPWebCliRunCommand]);
end;

begin
  TPWebC0Tests.RunAsConsole('PWeb CAP-10C0 tests (quoting + drain + ' +
    'supervision engine + run layout + stop signal)');

end.
