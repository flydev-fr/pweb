program tpltests;

{ CAP-10B0 scaffold-engine test suite runner (mormot.core.test).

  Headless on all four targets. Most of it touches no filesystem at all -
  the trusted list, the renderer and the creation plan are pure logic over
  injected inputs - and the part that does uses real directories in the
  system temporary area, including a real NTFS junction on Windows and a
  real symlink on POSIX, because a confinement rule tested against a mock is
  a rule about the mock.

  It is a SEPARATE program from test/cap10a/clitests.pas on purpose. The
  CAP-10A suite proves the PUBLIC CLI; this one proves an engine that is
  deliberately NOT linked into it, and keeping the two apart is what lets
  test/cap10b0/check_cap10b0_contracts.ps1 measure that absence rather than
  assert it.

  It needs, beside its executable:
    ../share/pweb/pweb-templates.zip   the pack the builder produced
  and, compiled in with -Fi:
    pweb.templates.registry.inc        the registry the builder generated

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.template;

type
  TPWebTplTests = class(TSynTests)
  published
    procedure TemplatePack;
    procedure PlaceholderRenderer;
    procedure CreationPlan;
    procedure AtomicCreation;
    procedure GeneratedSecurity;
  end;

procedure TPWebTplTests.TemplatePack;
begin
  // T1-T12: the trusted list, the deterministic writer, the generated
  // registry, and the verifier against the REAL pack the builder produced
  AddCase([TTestPWebTplPack]);
end;

procedure TPWebTplTests.PlaceholderRenderer;
begin
  // R1-R10: six tokens, one pass, and the text contract that makes a
  // generated file's bytes independent of who checked the repository out
  AddCase([TTestPWebTplRender]);
end;

procedure TPWebTplTests.CreationPlan;
begin
  // P1-P10: the complete plan, decided in memory, with every collision and
  // every bound resolved before a destination is so much as named
  AddCase([TTestPWebTplPlan]);
end;

procedure TPWebTplTests.AtomicCreation;
begin
  // A1-A12: the transaction against real directories - and the proof that
  // every failure leaves the destination absent and the staging reclaimed
  AddCase([TTestPWebTplAtomic]);
end;

procedure TPWebTplTests.GeneratedSecurity;
begin
  // S1-S8 and the SDK resolver: what a generated project may contain, and
  // where the trusted template pack is allowed to be found
  AddCase([TTestPWebTplSecurity]);
end;

begin
  TPWebTplTests.RunAsConsole('PWeb scaffold engine tests (CAP-10B0 ' +
    'template pack + placeholder renderer + creation plan + atomic ' +
    'filesystem transaction)');
end.
