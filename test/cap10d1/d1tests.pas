program d1tests;

{ CAP-10D1 packaging test suite runner (mormot.core.test).

  Headless on all four targets, and deliberately so: everything
  `pweb build --profile` owns that is not a spawn is either a pure function
  of its inputs or a question about a fixture directory this suite builds
  itself. That is what lets a Linux runner assert the Windows AppId rule,
  the macOS bundle's archive modes and the rollback that puts a previous
  release back - and what makes the four-target pack_digest a fact about the
  RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real `pweb build --profile`
  on a real generated project, the three real Inno Setup compiles, the real
  silent install / launch / uninstall, the extracted archive that answers 42,
  the codesign observation, the network sampling, the real interrupt and the
  Windows long-path bisection. Those need real tools, a real signal and a
  real runner, and a suite that pretended to have them would be the vacuous
  measurement this repository refuses.

  IT IS COMPILED WITH -dPWEB_LAYOUT_FAULTS and is the only program in this
  repository that is: that define arms the rollback fault seam ledger item
  C1-11 (b) needs, and check_cap10d1_contracts.ps1 sweeps every other build
  command for the spelling so it can never reach a shipped binary.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.pack;

type
  TPWebD1Tests = class(TSynTests)
  published
    procedure PureRules;
    procedure TheDeterministicArchive;
    procedure TheCommitRollback;
  end;

procedure TPWebD1Tests.PureRules;
begin
  AddCase([TTestPWebPackPure]);
end;

procedure TPWebD1Tests.TheDeterministicArchive;
begin
  AddCase([TTestPWebPackArchive]);
end;

procedure TPWebD1Tests.TheCommitRollback;
begin
  AddCase([TTestPWebPackRollback]);
end;

begin
  TPWebD1Tests.RunAsConsole('PWeb CAP-10D1 tests (the profile allowlist + ' +
    'the identity derivation and its refusals + the deterministic archive ' +
    'writer + the hadOld commit rollback)');
  PWebCap10d1Flush;

end.
