program c2tests;

{ CAP-10C2 development-loop test suite runner (mormot.core.test).

  Headless on all four targets, and deliberately so: every rule the dev loop
  owns that is not a spawn is a PURE FUNCTION of its inputs or a question
  about a fixture directory this suite builds itself. That is what lets a
  Linux runner assert the macOS arm64 development link line and the
  publish-by-rename refusal, and what makes the four-target dev_digest a fact
  about the RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real `pweb dev` on the real
  generated project, the running host, the generation switch with the host
  pid unchanged, the broken rebuild that must not stop the loop, the
  interrupt, and the two binaries' CSP bytes. Those need real tools, a real
  display and a real signal, and a suite that pretended to have them would be
  the vacuous measurement this repository refuses.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.dev;

type
  TPWebC2Tests = class(TSynTests)
  published
    procedure PureRules;
    procedure FilesystemRules;
  end;

procedure TPWebC2Tests.PureRules;
begin
  AddCase([TTestPWebDevPure]);
end;

procedure TPWebC2Tests.FilesystemRules;
begin
  AddCase([TTestPWebDevFs]);
end;

begin
  TPWebC2Tests.RunAsConsole('PWeb CAP-10C2 tests (dev command table + ' +
    'generations + publish-by-rename + acknowledgement + conditional install)');
  PWebCap10c2Flush;

end.
