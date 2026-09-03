program c3tests;

{ CAP-10C3 Pas2JS development-loop test suite runner (mormot.core.test).

  Headless on all four targets, and deliberately so: every rule the Pas2JS
  loop owns that is not a spawn is a PURE FUNCTION of its inputs or a
  question about a fixture directory this suite builds itself. That is what
  lets a Linux runner assert the macOS arm64 Pas2JS generation command line
  and the input-set bounds, and what makes the four-target
  dev_pas2js_digest a fact about the RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real `pweb dev` on the real
  generated Pas2JS project, the running host, the generation switch with the
  host pid unchanged, the compile error that must not stop the loop, the
  interrupt, the link and bound refusals of the REAL CLI, the archive parity
  with the CAP-10C1 pipeline and the two binaries' CSP bytes. Those need real
  tools, a real display and a real signal, and a suite that pretended to have
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
  pweb.test.devpas2js;

type
  TPWebC3Tests = class(TSynTests)
  published
    procedure PureRules;
    procedure FilesystemRules;
  end;

procedure TPWebC3Tests.PureRules;
begin
  AddCase([TTestPWebDevPas2jsPure]);
end;

procedure TPWebC3Tests.FilesystemRules;
begin
  AddCase([TTestPWebDevPas2jsFs]);
end;

begin
  TPWebC3Tests.RunAsConsole('PWeb CAP-10C3 tests (pas2js generation argv + ' +
    'supported UI + change detection + input set + content fingerprint + ' +
    'bounds)');
  PWebCap10c3Flush;

end.
