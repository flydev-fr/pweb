{
  pweb.test.build - the CAP-10D0 suite over the public `pweb build`
  (mormot.core.test).

  Two subjects, one file, all four targets:

    PURE    the rules that are pure functions of their inputs - the exit
            mapping `build` REUSES rather than redefines, the ten stage
            names and their per-UI applicability, the ratified
            project-mutation set, the two replacement sibling names, the
            logical run layout for all four targets, and the two names
            CAP-10C1's ledger recorded as being spelled in two units.

    FS      THE REPLACEMENT RULE, measured rather than described. This is
            the shard's own claim and the one thing a public `build`
            re-opens: what happens to an existing release/ while a new one
            is committed, and what is on the disk after every way the commit
            can fail. Every case runs the PRODUCTION function,
            PWebCliAssembleRelease, over a real fixture tree - there is no
            re-implementation of the sequence here, because a test that
            re-implements a rule measures the test.

  WHY THE FS CASES ARE HEADLESS AND STILL REAL. The commit is three renames
  and a guarded remove over directories this suite creates; it needs no
  compiler, no display and no network, so it runs on every leg of every job
  rather than only where a full build is affordable. What it deliberately
  does NOT cover, and the gate does: the real `pweb build` end to end on a
  real generated project, the real interrupt, determinism across two real
  builds, the network sampling, and the race with a running `pweb run`.

  IT CLOSES C1-11 (b) AS FAR AS A SUITE CAN. The layout's `plrCommit`
  refusal is exercised here for the first time, by seeding `release` as a
  FILE so the committing rename - which never replaces, on either family -
  has to fail. The `hadOld` ROLLBACK inside that refusal still is not: it
  needs a fault injected BETWEEN the two renames, which would mean a
  fault-injection seam in production code that the CAP-10D0 freeze forbids.
  That half is recorded, and assigned, rather than quietly claimed.

  It emits build/cap10d0/build-corpus.txt: every DECISION this suite made,
  one LF line each, hashed into build_digest and required equal on four
  targets. Anything legitimately platform-shaped goes to
  build/cap10d0/build-observed.txt as key=value and is recorded per target,
  never compared.
}

{$I mormot.defines.inc}

unit pweb.test.build;

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.test,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.toolchain,
  pweb.cli.process,
  pweb.cli.project,
  pweb.cli.run,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.toolset,
  pweb.cli.frontend,
  pweb.cli.pack,
  pweb.cli.native,
  pweb.cli.layout,
  pweb.cli.pipeline,
  pweb.cli.build;

type
  TTestPWebBuildPure = class(TSynTestCase)
  published
    procedure TheExitMappingIsTheC1One;
    procedure TheTenStagesAndTheirApplicability;
    procedure TheMutationSetIsTheRatifiedFour;
    procedure TheReplacementSiblingsAreDotLeading;
    procedure TheLogicalLayoutForFourTargets;
    procedure TheTwiceSpelledNamesAgree;
  end;

  TTestPWebBuildFs = class(TSynTestCase)
  published
    procedure ACommitWithNoPreviousRelease;
    procedure ACommitOverAPreviousReleaseReplacesItWhole;
    procedure AFileNamedReleaseRefusesTheCommit;
    procedure AFileNamedOldRefusesTheReclaim;
    procedure AMissingInputRefusesBeforeAnythingIsStaged;
  end;

const
  PWEB_CAP10D0_CORPUS_FILE = 'build/cap10d0/build-corpus.txt';
  PWEB_CAP10D0_OBSERVED_FILE = 'build/cap10d0/build-observed.txt';
  PWEB_CAP10D0_FIXTURE = 'build/cap10d0/fixture';

/// write both evidence files
procedure PWebCap10d0Flush;


implementation

var
  Corpus: TRawUtf8DynArray;
  Observed: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

procedure Observe(const Key, Value: RawUtf8);
begin
  SetLength(Observed, Length(Observed) + 1);
  Observed[High(Observed)] := Key + '=' + Value;
end;

procedure PWebCap10d0Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10D0 public-build decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10D0_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10D0_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10D0_OBSERVED_FILE);
end;

function Bool(B: Boolean): RawUtf8;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

function IntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

const
  TARGETS: array[0 .. 3] of record
    Os: TPWebCliOs;
    Arch: TPWebCliArch;
  end = (
    (Os: pcoWindows; Arch: pcaX86_64),
    (Os: pcoLinux;   Arch: pcaX86_64),
    (Os: pcoMacos;   Arch: pcaX86_64),
    (Os: pcoMacos;   Arch: pcaArm64));


{ ---------------------------------------------------------------------------
  the pure rules
  --------------------------------------------------------------------------- }

{ THE EXIT MAPPING IS NOT CAP-10D0'S. `pweb build` answers with the same six
  categories docs/pipeline-contract.md section 9 ratified at CAP-10C1, and
  the whole of what this case measures is that nothing was added and nothing
  moved - because a public command is exactly the moment somebody proposes a
  seventh code for "built but with warnings". }
procedure TTestPWebBuildPure.TheExitMappingIsTheC1One;
var
  c: TPWebCliPipeCode;
  seen: RawUtf8;
begin
  CheckEqual(PWebCliPipeExitCode(ppcOk), 0, 'built and verified');
  CheckEqual(PWebCliPipeExitCode(ppcUsage), 2, 'usage');
  CheckEqual(PWebCliPipeExitCode(ppcProject), 3, 'project');
  CheckEqual(PWebCliPipeExitCode(ppcUnavailable), 4, 'cannot build');
  CheckEqual(PWebCliPipeExitCode(ppcStageFailed), 5, 'a stage child failed');
  CheckEqual(PWebCliPipeExitCode(ppcInternal), 6, 'invariant');
  seen := '';
  for c := Low(TPWebCliPipeCode) to High(TPWebCliPipeCode) do
  begin
    if seen <> '' then
      seen := seen + ',';
    seen := seen + IntText(PWebCliPipeExitCode(c));
  end;
  CheckEqual(seen, '0,2,3,4,5,6',
    'the six categories, in order, and no seventh');
  Record_('exit|categories|' + seen);
  // ordinal 0 is the accepted state, which is what lets a caller test one
  // field rather than remember which value means success
  Check(ppcOk = Low(TPWebCliPipeCode), 'ok is the zero ordinal');
  Record_('exit|ok_is_zero_ordinal|true');
end;

{ The ten stages, their ORDER and which of them a UI has. CAP-10D0 adds no
  stage and reorders none, so this case is a freeze anchor: the day somebody
  inserts one, the corpus digest moves on four targets at once. }
procedure TTestPWebBuildPure.TheTenStagesAndTheirApplicability;
var
  k: TPWebCliStageKind;
  names, reactOnly: RawUtf8;
begin
  names := '';
  for k := Low(TPWebCliStageKind) to High(TPWebCliStageKind) do
  begin
    if names <> '' then
      names := names + ',';
    names := names + PWebCliStageName(k);
  end;
  CheckEqual(names,
    'open,toolchain,stage_sdk,install,typecheck,build,pack,compile,layout,' +
    'verify', 'the CAP-10C1 ten, in order');
  Record_('stages|names|' + names);
  CheckEqual(Ord(High(TPWebCliStageKind)) - Ord(Low(TPWebCliStageKind)) + 1,
    10, 'ten stages, and CAP-10D0 adds none');
  // the three a pas2js build does not have, stated as a SET rather than as
  // three separate facts, so a shard that moved one of them moves this line
  reactOnly := '';
  for k := Low(TPWebCliStageKind) to High(TPWebCliStageKind) do
    if k in [pskStageSdk, pskInstall, pskTypecheck] then
    begin
      if reactOnly <> '' then
        reactOnly := reactOnly + ',';
      reactOnly := reactOnly + PWebCliStageName(k);
    end;
  CheckEqual(reactOnly, 'stage_sdk,install,typecheck',
    'the three node stages, which only a react build has');
  Record_('stages|react_only|' + reactOnly);
end;

{ The four writable prefixes, computed by the production function for a
  fixture descriptor. A public build writes here and nowhere else, and the
  pipeline itself digests the rest of the tree before the first stage and
  after every one of them. }
procedure TTestPWebBuildPure.TheMutationSetIsTheRatifiedFour;
var
  p: TPWebCliProject;
  set_: TRawUtf8DynArray;
  joined: RawUtf8;
  i: PtrInt;
begin
  p := Default(TPWebCliProject);
  p.Refusal := pcrNone;
  p.FrontendRoot := 'frontend';
  p.Output := 'dist';
  set_ := PWebCliMutationSet(p);
  CheckEqual(Length(set_), 4, 'four writable prefixes, no more');
  joined := '';
  for i := 0 to High(set_) do
  begin
    if joined <> '' then
      joined := joined + ',';
    joined := joined + set_[i];
  end;
  CheckEqual(joined,
    'frontend/.pweb,frontend/node_modules,frontend/dist,dist',
    'the ratified mutation set, unchanged by CAP-10D0');
  Record_('mutation|set|' + joined);
end;

{ Both replacement siblings live under <output>/<target>, beside the release
  they stand in for, and both are dot-leading. Neither is under the project
  root's own directories, and neither is a temporary directory of the
  operating system's - a commit that renamed across a filesystem boundary
  would not be a rename at all. }
procedure TTestPWebBuildPure.TheReplacementSiblingsAreDotLeading;
begin
  CheckEqual(PWEB_LAYOUT_STAGE, '.pweb-release.tmp', 'the staging sibling');
  CheckEqual(PWEB_LAYOUT_OLD, '.pweb-old.tmp', 'the retired sibling');
  Check(Copy(PWEB_LAYOUT_STAGE, 1, 1) = '.', 'the staging name is dot-leading');
  Check(Copy(PWEB_LAYOUT_OLD, 1, 1) = '.', 'the retired name is dot-leading');
  Check(PWEB_LAYOUT_STAGE <> PWEB_LAYOUT_OLD,
    'two names, because the two trees exist at the same instant');
  Check(PWEB_LAYOUT_STAGE <> PWEB_CLI_RUN_RELEASE,
    'and neither of them is the release itself');
  Check(PWEB_LAYOUT_OLD <> PWEB_CLI_RUN_RELEASE, 'nor is the retired one');
  Record_('replace|stage|' + PWEB_LAYOUT_STAGE);
  Record_('replace|old|' + PWEB_LAYOUT_OLD);
  Record_('replace|release|' + PWEB_CLI_RUN_RELEASE);
  // the ratified sequence, recorded as a decision so four targets agree on
  // WHAT the rule is and not merely on what happened to run
  Record_('replace|sequence|stage_aside_rename_reclaim');
  // and the one honest consequence: between the two renames there is an
  // instant with NO release, which `pweb run` answers not_built. It cannot
  // be removed - no portable primitive swaps two populated directories -
  // and it is never an instant with a PARTIAL or a MIXED one
  Record_('replace|window|one_rename_no_release');
  Record_('replace|partial_possible|false');
end;

{ The logical run layout for all four targets, computed on whichever target
  is running. This is the CAP-10C0 rule and CAP-10D0 produces exactly it: a
  Linux runner asserting the macOS arm64 bundle shape is the same
  four-target property the CAP-10C1 command matrix has. }
procedure TTestPWebBuildPure.TheLogicalLayoutForFourTargets;
var
  p: TPWebCliProject;
  exeL, bundleL, plistL, line: RawUtf8;
  i: PtrInt;
begin
  p := Default(TPWebCliProject);
  p.Refusal := pcrNone;
  p.Name := 'demo';
  p.Output := 'dist';
  p.ProgramIdent := 'demo';
  for i := 0 to High(TARGETS) do
  begin
    PWebCliRunLogicalLayout(p, TARGETS[i].Os, TARGETS[i].Arch,
      exeL, bundleL, plistL);
    line := PWebCliRunTargetName(TARGETS[i].Os, TARGETS[i].Arch) + '|' +
      exeL + '|' + bundleL + '|' + plistL;
    Record_('layout|' + line);
    Check(Pos('dist/', exeL) = 1, 'the executable path starts at the output');
    Check(Pos('dist/', bundleL) = 1, 'and so does the bundle''s');
    Check(Pos('\', line) = 0, 'logical paths are forward-slashed');
    Check(Pos(PWEB_CLI_RUN_RELEASE + '/', exeL) > 0,
      'and every one of them is under release/');
  end;
  // the macOS bundle carries an Info.plist and the flat platforms do not,
  // which is the only shape difference between the four
  PWebCliRunLogicalLayout(p, pcoLinux, pcaX86_64, exeL, bundleL, plistL);
  CheckEqual(plistL, '', 'a flat layout has no Info.plist');
  PWebCliRunLogicalLayout(p, pcoMacos, pcaArm64, exeL, bundleL, plistL);
  Check(plistL <> '', 'a macOS bundle has one');
  Record_('layout|plist_only_on_macos|true');
end;

{ CAP-10C1's ledger recorded that `app.pwb` and `node_modules` are each
  spelled in two units with nothing asserting the pairs equal (C1-11 (d)).
  This is that assertion. It is cheap, it is here rather than in a script
  because a VALUE comparison is stronger than a source-text one, and
  check_cap10d0_contracts.ps1 makes the same claim at the source so a unit
  that stopped being linked could not make it vacuous. }
procedure TTestPWebBuildPure.TheTwiceSpelledNamesAgree;
begin
  CheckEqual(PWEB_PACK_BUNDLE, PWEB_CLI_RUN_BUNDLE,
    'the bundler writes what the run layout resolves');
  CheckEqual(PWEB_FE_NODE_MODULES, PWEB_NPM_NODE_MODULES,
    'the frontend plan and the npm resolver mean one directory');
  Record_('names|app_pwb|' + PWEB_PACK_BUNDLE);
  Record_('names|node_modules|' + PWEB_FE_NODE_MODULES);
end;


{ ---------------------------------------------------------------------------
  the replacement rule, over a real fixture tree
  --------------------------------------------------------------------------- }

type
  /// one fixture: a project root, its <output>/<target> and the three
  // inputs an assembly consumes
  TReleaseFixture = record
    Root: RawUtf8;
    TargetDir: RawUtf8;
    ExePath: RawUtf8;
    BundlePath: RawUtf8;
    Project: TPWebCliProject;
    Sdk: TPWebSdkLayout;
  end;

function FixtureProjectAt(const Root: RawUtf8): TPWebCliProject;
begin
  Result := Default(TPWebCliProject);
  Result.Refusal := pcrNone;
  Result.Root := Root;
  Result.Schema := PWEB_CLI_SCHEMA;
  Result.Name := 'demo';
  Result.Version := '0.1.0';
  Result.BundleId := 'com.example.demo';
  Result.Ui := puiPas2js;
  Result.NativeProgram := 'src/demo.lpr';
  Result.FrontendRoot := 'frontend';
  Result.Output := 'dist';
  Result.ProgramIdent := 'demo';
  Result.NativeProgramPath.Refusal := pprNone;
  Result.NativeProgramPath.Full :=
    PWebCliJoin(PWebCliJoin(Root, 'src'), 'demo.lpr');
  Result.FrontendRootPath.Refusal := pprNone;
  Result.FrontendRootPath.Full := PWebCliJoin(Root, 'frontend');
  Result.OutputPath.Refusal := pprNone;
  Result.OutputPath.Full := PWebCliJoin(Root, 'dist');
end;

// a fresh fixture, reclaimed through the GUARDED remover and never by a
// recursive delete this suite aims itself
function FreshFixture(const Name: RawUtf8; out Fx: TReleaseFixture): Boolean;
var
  parent, outDir, inputs: RawUtf8;
  stage: TPWebCliStageRefusal;
begin
  Result := False;
  Fx := Default(TReleaseFixture);
  ForceDirectories(ExpandFileName(PWEB_CAP10D0_FIXTURE));
  if not PWebCliCanonicalDir(RawUtf8(ExpandFileName(PWEB_CAP10D0_FIXTURE)),
       parent) then
    exit;
  if not PWebCliPipeRemoveTree(parent, Name, stage) then
    exit;
  if not PWebCliPipeEnsureDir(parent, Name, Fx.Root, stage) then
    exit;
  if not PWebCliPipeEnsureDir(Fx.Root, 'dist', outDir, stage) then
    exit;
  Fx.Project := FixtureProjectAt(Fx.Root);
  if not PWebCliPipeEnsureDir(outDir,
       PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch),
       Fx.TargetDir, stage) then
    exit;
  // the three inputs, in a sibling the assembly never touches
  if not PWebCliPipeEnsureDir(Fx.Root, 'inputs', inputs, stage) then
    exit;
  Fx.ExePath := PWebCliJoin(inputs,
    PWebCliNativeExeName('demo', PWebCliHostOs));
  Fx.BundlePath := PWebCliJoin(inputs, PWEB_PACK_BUNDLE);
  Fx.Sdk := Default(TPWebSdkLayout);
  Fx.Sdk.WebviewLib := PWebCliJoin(inputs,
    PWebCliWebviewLibName(PWebCliHostOs));
  Result := True;
end;

// the executable carries the execute bit where the platform has one: the
// run layout refuses a release whose executable lost it, three stages later
function WriteInput(const Path, Content: RawUtf8; Exec: Boolean): Boolean;
begin
  Result := PWebCliWriteNewFile(Path, RawByteString(Content),
    Exec and PWebCliHasFileModes);
end;

function SeedInputs(const Fx: TReleaseFixture; const Mark: RawUtf8): Boolean;
begin
  Result := WriteInput(Fx.ExePath, 'exe-' + Mark, {Exec=}True) and
            WriteInput(Fx.BundlePath, 'pwb-' + Mark, False) and
            WriteInput(Fx.Sdk.WebviewLib, 'lib-' + Mark, False);
end;

function ClearInputs(const Fx: TReleaseFixture): Boolean;
begin
  Result := PWebCliDeleteFile(Fx.ExePath) and
            PWebCliDeleteFile(Fx.BundlePath) and
            PWebCliDeleteFile(Fx.Sdk.WebviewLib);
end;

// what the committed release holds, as the `<rel>|<size>|<sha256>`
// projection the pipeline itself uses; '' when there is no release
function ReleaseInventory(const Fx: TReleaseFixture; out Files: Integer): RawUtf8;
var
  refusal: TPWebCliStageRefusal;
  dir: RawUtf8;
begin
  Result := '';
  Files := 0;
  dir := PWebCliJoin(Fx.TargetDir, PWEB_CLI_RUN_RELEASE);
  if PWebCliNodeKind(dir) <> pcnDirectory then
    exit;
  if not PWebCliPipeTreeLines(dir, nil, Result, Files, refusal) then
    Result := '';
end;

function Assemble(const Fx: TReleaseFixture): TPWebCliLayoutResult;
begin
  Result := PWebCliAssembleRelease(Fx.Project, Fx.Sdk, PWebCliHostOs,
    PWebCliHostArch, Fx.TargetDir, Fx.ExePath, Fx.BundlePath);
end;

function StageLeft(const Fx: TReleaseFixture): Boolean;
begin
  Result := PWebCliEntry(Fx.TargetDir, PWEB_LAYOUT_STAGE) <> pcnMissing;
end;

function OldLeft(const Fx: TReleaseFixture): Boolean;
begin
  Result := PWebCliEntry(Fx.TargetDir, PWEB_LAYOUT_OLD) <> pcnMissing;
end;

{ THE ORDINARY CASE: no previous release. The staging sibling is created,
  populated and renamed into place, the run resolver accepts it, and neither
  temporary name survives. }
procedure TTestPWebBuildFs.ACommitWithNoPreviousRelease;
var
  fx: TReleaseFixture;
  r: TPWebCliLayoutResult;
  inv: RawUtf8;
  files: Integer;
begin
  Check(FreshFixture('commit-fresh', fx), 'the fixture');
  Check(SeedInputs(fx, 'one'), 'the three inputs');
  Check(PWebCliEntry(fx.TargetDir, PWEB_CLI_RUN_RELEASE) = pcnMissing,
    'no release before the first commit');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'ok',
    'a first commit is accepted');
  Check(r.ReleaseDir <> '', 'and it names the committed release');
  Check(PWebCliEntry(fx.TargetDir, PWEB_CLI_RUN_RELEASE) = pcnDirectory,
    'the release is a directory now');
  Check(not StageLeft(fx), 'the staging sibling was renamed, not copied');
  Check(not OldLeft(fx), 'and nothing was retired, because nothing was there');
  inv := ReleaseInventory(fx, files);
  Check(Pos('exe-one', inv) = 0, 'the inventory is digests, not contents');
  CheckEqual(files, r.Files, 'the file count the assembly reported');
  Record_('commit|fresh|ok|' + IntText(r.Files));
  Observe('commit_fresh_files', IntText(files));
end;

{ THE CLAIM THIS SHARD RATIFIES: a second build replaces the first WHOLE.
  The committed release holds the second build's bytes and none of the
  first's, the retired tree is gone, and at no point was there a directory
  holding some of each - which is what the two renames buy and what a
  copy-over-the-top would lose. }
procedure TTestPWebBuildFs.ACommitOverAPreviousReleaseReplacesItWhole;
var
  fx: TReleaseFixture;
  r: TPWebCliLayoutResult;
  first, second: RawUtf8;
  f1, f2: Integer;
begin
  Check(FreshFixture('commit-replace', fx), 'the fixture');
  Check(SeedInputs(fx, 'one'), 'the first build''s inputs');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'ok', 'the first commit');
  first := ReleaseInventory(fx, f1);
  Check(first <> '', 'the first release is on the disk');

  Check(ClearInputs(fx), 'the first build''s inputs are consumed');
  Check(SeedInputs(fx, 'two'), 'the second build''s inputs');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'ok', 'the second commit');
  second := ReleaseInventory(fx, f2);
  Check(second <> '', 'and a release is still there');
  CheckEqual(f2, f1, 'the same shape');
  Check(second <> first,
    'holding the SECOND build''s bytes: a replacement, not a merge');
  Check(not OldLeft(fx), 'the retired tree was reclaimed');
  Check(not StageLeft(fx), 'and the staging sibling with it');
  Record_('commit|replace|ok|whole');
  Record_('commit|retired_reclaimed|true');
end;

{ C1-11 (b), the half a suite can close: the COMMITTING RENAME refused.
  `release` is seeded as a FILE, so the rename that must not replace cannot
  succeed on either family - Windows because MoveFileExW is called without
  MOVEFILE_REPLACE_EXISTING, POSIX because the destination is lstat'ed
  first. The refusal is typed, the staging sibling is reclaimed, and the
  thing that was already there is untouched. }
procedure TTestPWebBuildFs.AFileNamedReleaseRefusesTheCommit;
var
  fx: TReleaseFixture;
  r: TPWebCliLayoutResult;
  seeded, after: RawByteString;
  tooBig: Boolean;
begin
  Check(FreshFixture('commit-file', fx), 'the fixture');
  Check(SeedInputs(fx, 'one'), 'the three inputs');
  Check(WriteInput(PWebCliJoin(fx.TargetDir, PWEB_CLI_RUN_RELEASE),
    'not-a-release', False), 'release seeded as a FILE');
  Check(PWebCliReadSmallFile(
    PWebCliJoin(fx.TargetDir, PWEB_CLI_RUN_RELEASE), 4096, seeded, tooBig),
    'and read back before the attempt');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'layout_commit_failed',
    'the committing rename is refused, and says so by name');
  CheckEqual(r.ReleaseDir, '', 'no release directory is claimed');
  Check(not StageLeft(fx),
    'and the staged tree is reclaimed rather than left behind');
  Check(PWebCliReadSmallFile(
    PWebCliJoin(fx.TargetDir, PWEB_CLI_RUN_RELEASE), 4096, after, tooBig),
    'what was there is still there');
  Check(after = seeded, 'byte for byte');
  Record_('commit|release_is_a_file|layout_commit_failed');
  Record_('commit|refusal_leaves_existing_untouched|true');
end;

{ The other half of the sequence: the RETIRING rename cannot even start,
  because the retired name is taken by something the guarded remover refuses
  to remove. The previous release is untouched - it has not been moved yet -
  and the refusal is `layout_reclaim_failed` rather than the commit's. }
procedure TTestPWebBuildFs.AFileNamedOldRefusesTheReclaim;
var
  fx: TReleaseFixture;
  r: TPWebCliLayoutResult;
  before, after: RawUtf8;
  f1, f2: Integer;
begin
  Check(FreshFixture('reclaim-file', fx), 'the fixture');
  Check(SeedInputs(fx, 'one'), 'the first build''s inputs');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'ok', 'the first commit');
  before := ReleaseInventory(fx, f1);

  Check(WriteInput(PWebCliJoin(fx.TargetDir, PWEB_LAYOUT_OLD),
    'in-the-way', False), 'the retired name is taken by a FILE');
  Check(ClearInputs(fx), 'the first build''s inputs are consumed');
  Check(SeedInputs(fx, 'two'), 'the second build''s inputs');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'layout_reclaim_failed',
    'the previous release cannot be moved aside, and says so by name');
  after := ReleaseInventory(fx, f2);
  CheckEqual(f2, f1, 'the previous release is still whole');
  Check(after = before, 'and byte-identical to what it was');
  Check(not StageLeft(fx), 'the staged tree is reclaimed');
  Record_('commit|old_is_a_file|layout_reclaim_failed');
  Record_('commit|failure_leaves_old_release|true');
end;

{ Refused BEFORE anything is created. The three inputs are checked first, so
  a build that lost its executable does not get as far as touching the
  release that is already there. }
procedure TTestPWebBuildFs.AMissingInputRefusesBeforeAnythingIsStaged;
var
  fx: TReleaseFixture;
  r: TPWebCliLayoutResult;
  before, after: RawUtf8;
  f1, f2: Integer;
begin
  Check(FreshFixture('input-missing', fx), 'the fixture');
  Check(SeedInputs(fx, 'one'), 'the first build''s inputs');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'ok', 'the first commit');
  before := ReleaseInventory(fx, f1);

  // the bundle alone goes missing: the executable and the library are there
  Check(PWebCliDeleteFile(fx.BundlePath), 'app.pwb removed');
  r := Assemble(fx);
  CheckEqual(PWebCliLayoutRefusalText(r.Refusal), 'layout_input_missing',
    'an absent input is refused by name');
  Check(not StageLeft(fx), 'and nothing was staged');
  after := ReleaseInventory(fx, f2);
  CheckEqual(f2, f1, 'the previous release is untouched');
  Check(after = before, 'byte for byte');
  Record_('commit|input_missing|layout_input_missing');
  Record_('commit|refused_before_any_write|true');
end;

end.
