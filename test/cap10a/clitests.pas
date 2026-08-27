program clitests;

{ CAP-10A CLI test suite runner (mormot.core.test).

  Headless on all four targets: the parser and the doctor engine are pure
  logic over injected inputs, the project cases build real directories in the
  system temporary area, and the probe cases drive one deliberately badly
  behaved child (test/cap10a/probechild.pas) that must be built beside this
  executable.

  It is a SEPARATE program from test/core/pwebtests.pas on purpose: the CLI
  units live under tools/pweb and have no business on the runtime suite's
  unit path. The runtime half of CAP-10A - the reusable runtime-command
  decorator and the production trust profile - stays inside pwebtests, where
  it re-runs with every existing four-target leg.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.cli;

type
  TPWebCliTests = class(TSynTests)
  published
    procedure CommandLine;
    procedure ProjectContract;
    procedure DoctorEngine;
    procedure ProcessProbe;
  end;

procedure TPWebCliTests.CommandLine;
begin
  // C1-C6: the whole parser refusal matrix, over an argument ARRAY, so the
  // same rows run byte-identically on four platforms and nothing depends on
  // how a shell would have split them
  AddCase([TTestPWebCliArgs]);
end;

procedure TPWebCliTests.ProjectContract;
begin
  // P1-P16: the strict descriptor reader and the confinement walk, against
  // REAL directories - a confinement rule tested against a mock is a rule
  // about the mock
  AddCase([TTestPWebCliProject]);
end;

procedure TPWebCliTests.DoctorEngine;
begin
  // D1-D5, D10-D11, C7-C9: the requirement graph and both emitters over a
  // fully injected environment
  AddCase([TTestPWebCliDoctor]);
end;

procedure TPWebCliTests.ProcessProbe;
begin
  // D6-D9: the bounded, shell-free runner against a real child that times
  // out, floods both streams, and echoes its own argv
  AddCase([TTestPWebCliProbe]);
end;

begin
  TPWebCliTests.RunAsConsole('PWeb CLI tests (CAP-10A parser + project ' +
    'contract + doctor engine + bounded process probe)');
end.
