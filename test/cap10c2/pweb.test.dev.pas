{
  pweb.test.dev - the CAP-10C2 suite over the development loop
  (mormot.core.test).

  Two subjects, one file, all four targets:

    PURE    the rules that are pure functions of their inputs - the
            DEV COMPILE COMMAND TABLE for all four targets and its exact
            relationship to the release one (the release vector plus ONE
            element, -dPWEB_DEV, and nothing else moved), the exit mapping,
            the stage names, the generation directory rule, the sentinel and
            install-record paths, the acknowledgement grammar and the ANSI
            stripper. Every one is computed for ALL FOUR targets on
            whichever target is running - the CAP-10C1 property, which is
            what lets a Linux runner prove the macOS arm64 development link
            line.

    FS      the rules that are about a real filesystem - the development
            layout and its refusals, that a `.gen.tmp` left behind is
            reclaimed at start, that PUBLISH IS ONE RENAME AND MUST NOT
            REPLACE, that the bounded cleanup only ever removes BACKWARDS,
            and the conditional-install decision over a fixture frontend.
            Fixtures are built under build/cap10c2/fixture and reclaimed by
            the guarded remover, never by a recursive delete this suite aims
            itself.

  It emits build/cap10c2/dev-corpus.txt: every DECISION this suite made, one
  LF line each, hashed into dev_digest and required equal on four targets -
  so a line carries no absolute path, no timing and no host fact. Anything
  legitimately platform-shaped goes to build/cap10c2/dev-observed.txt as
  key=value and is recorded per target, never compared.

  WHAT IS NOT HERE, and belongs to the gate: the real `pweb dev` on the real
  generated project, the running host, the generation switch, the interrupt
  and the two binaries' CSP bytes. Those need real tools, a real display and
  a real signal, and a suite that pretended to have them would be the vacuous
  measurement this repository refuses.
}

{$I mormot.defines.inc}

unit pweb.test.dev;

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
  pweb.cli.sdk,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.toolset,
  pweb.cli.frontend,
  pweb.cli.pack,
  pweb.cli.native,
  pweb.cli.layout,
  pweb.cli.pipeline,
  pweb.cli.devlayout,
  pweb.cli.dev;

type
  TTestPWebDevPure = class(TSynTestCase)
  published
    procedure DevCommandTable;
    procedure DevCommandIsTheReleaseVectorInDevMode;
    procedure ExitMappingAndStageNames;
    procedure GenerationAndSentinelPaths;
    procedure AcknowledgementGrammar;
    procedure AnsiStripping;
    procedure MutationSetUnchanged;
  end;

  TTestPWebDevFs = class(TSynTestCase)
  published
    procedure LayoutAndTmpReclaim;
    procedure PublishIsOneRenameThatCannotReplace;
    procedure CleanupOnlyGoesBackwards;
    procedure AStartReclaimsAPreviousSessionsGenerations;
    procedure ConditionalInstallDecision;
  end;

const
  PWEB_CAP10C2_CORPUS_FILE = 'build/cap10c2/dev-corpus.txt';
  PWEB_CAP10C2_OBSERVED_FILE = 'build/cap10c2/dev-observed.txt';
  PWEB_CAP10C2_FIXTURE = 'build/cap10c2/fixture';

/// write both evidence files
procedure PWebCap10c2Flush;


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

procedure PWebCap10c2Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10C2 development-loop decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10C2_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10C2_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10C2_OBSERVED_FILE);
end;

{ ---------------------------------------------------------------------------
  fixture plumbing - synthetic paths, so the corpus is a fact about the RULE
  and never about the machine that ran it
  --------------------------------------------------------------------------- }

const
  TARGETS: array[0 .. 3] of record
    Os: TPWebCliOs;
    Arch: TPWebCliArch;
  end = (
    (Os: pcoWindows; Arch: pcaX86_64),
    (Os: pcoLinux;   Arch: pcaX86_64),
    (Os: pcoMacos;   Arch: pcaX86_64),
    (Os: pcoMacos;   Arch: pcaArm64));

function AbsRoot(const Name: RawUtf8): RawUtf8;
begin
  if PWebCliHostOs = pcoWindows then
    Result := 'C:\' + Name
  else
    Result := '/' + Name;
end;

function FixtureProject: TPWebCliProject;
begin
  Result := Default(TPWebCliProject);
  Result.Refusal := pcrNone;
  Result.Root := AbsRoot('fixture-root');
  Result.Schema := PWEB_CLI_SCHEMA;
  Result.Name := 'demo';
  Result.Version := '0.1.0';
  Result.BundleId := 'com.example.demo';
  Result.Ui := puiReact;
  Result.NativeProgram := 'src/demo.lpr';
  Result.FrontendRoot := 'frontend';
  Result.Output := 'dist';
  Result.ProgramIdent := 'demo';
  Result.NativeProgramPath.Refusal := pprNone;
  Result.NativeProgramPath.Full :=
    PWebCliJoin(PWebCliJoin(Result.Root, 'src'), 'demo.lpr');
  Result.FrontendRootPath.Refusal := pprNone;
  Result.FrontendRootPath.Full := PWebCliJoin(Result.Root, 'frontend');
  Result.OutputPath.Refusal := pprNone;
  Result.OutputPath.Full := PWebCliJoin(Result.Root, 'dist');
end;

function FixtureSdk(Os: TPWebCliOs; Arch: TPWebCliArch): TPWebSdkLayout;
var
  share, srcRoot: RawUtf8;
  i: PtrInt;
begin
  Result := Default(TPWebSdkLayout);
  Result.Refusal := pslNone;
  Result.Root := AbsRoot('fixture-sdk');
  Result.Target := PWebCliRunTargetName(Os, Arch);
  Result.FpcTarget := PWebCliFpcTargetName(Os, Arch);
  share := PWebCliJoin(PWebCliJoin(Result.Root, PWEB_SDK_SHARE),
    PWEB_SDK_SHARE_PWEB);
  Result.ShareTree := share;
  srcRoot := PWebCliJoin(share, PWEB_SDK_SRC);
  Result.SourceRoot := srcRoot;
  SetLength(Result.UnitDirs, Length(PWEB_SDK_UNIT_DIRS) + 1);
  for i := 0 to High(PWEB_SDK_UNIT_DIRS) do
    Result.UnitDirs[i] := PWebCliJoin(srcRoot, PWEB_SDK_UNIT_DIRS[i]);
  case Os of
    pcoWindows:
      Result.UnitDirs[High(Result.UnitDirs)] :=
        PWebCliJoin(PWebCliJoin(srcRoot, PWEB_SDK_PLATFORM), 'windows');
    pcoMacos:
      Result.UnitDirs[High(Result.UnitDirs)] :=
        PWebCliJoin(PWebCliJoin(srcRoot, PWEB_SDK_PLATFORM), 'macos');
  else
    Result.UnitDirs[High(Result.UnitDirs)] :=
      PWebCliJoin(PWebCliJoin(srcRoot, PWEB_SDK_PLATFORM), 'linux');
  end;
  Result.TypeScriptSdk := PWebCliJoin(PWebCliJoin(share, PWEB_SDK_SDK),
    PWEB_SDK_TYPESCRIPT);
  Result.MormotSource := PWebCliJoin(PWebCliJoin(PWebCliJoin(share,
    PWEB_SDK_DEPS), PWEB_SDK_MORMOT), PWEB_SDK_SRC);
  Result.MormotStatic := PWebCliJoin(PWebCliJoin(PWebCliJoin(
    PWebCliJoin(share, PWEB_SDK_DEPS), PWEB_SDK_MORMOT), PWEB_SDK_STATIC),
    Result.FpcTarget);
  Result.PlatformLib := PWebCliJoin(PWebCliJoin(share, PWEB_SDK_LIB),
    Result.Target);
  Result.WebviewLib := PWebCliJoin(Result.PlatformLib,
    PWebCliWebviewLibName(Os));
  if Os = pcoMacos then
    Result.MacosBridge := PWebCliJoin(Result.PlatformLib,
      PWEB_CLI_MACOS_BRIDGE_OBJ);
  Result.Bundler := PWebCliJoin(PWebCliJoin(Result.Root, PWEB_SDK_BIN),
    PWEB_SDK_BUNDLER);
end;

// the logical projection of one command, exactly as the driver records it -
// so the corpus is byte-comparable on four targets whose real paths differ
function CommandLine(const Cmd: TPWebCliCommand;
  const Project: TPWebCliProject; const Sdk: TPWebSdkLayout): RawUtf8;
var
  prefixes, tokens: TRawUtf8DynArray;
  tools: TPWebCliToolset;
begin
  tools := Default(TPWebCliToolset);
  tools.Fpc.Path := AbsRoot('fixture-tools') + PathDelim + 'fpc';
  PWebCliPipeRedactions(Project, Sdk, tools, prefixes, tokens);
  Result := PWebCliCommandText(Cmd, prefixes, tokens);
end;

{ ---------------------------------------------------------------------------
  TTestPWebDevPure
  --------------------------------------------------------------------------- }

procedure TTestPWebDevPure.DevCommandTable;
var
  t: Integer;
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  cmd: TPWebCliCommand;
  target, unitDir, objDir, devDir: RawUtf8;
begin
  project := FixtureProject;
  for t := 0 to High(TARGETS) do
  begin
    sdk := FixtureSdk(TARGETS[t].Os, TARGETS[t].Arch);
    target := PWebCliRunTargetName(TARGETS[t].Os, TARGETS[t].Arch);
    // the DEV output directories, spelled exactly as devlayout builds them
    devDir := PWebCliJoin(PWebCliJoin(PWebCliJoin(project.Root, 'dist'),
      target), PWEB_CLI_DEV_DIR);
    unitDir := PWebCliJoin(devDir, PWEB_CLI_DEV_UNIT_DIR);
    objDir := PWebCliJoin(devDir, PWEB_CLI_DEV_OBJ_DIR);
    cmd := PWebCliFpcDevCommand(AbsRoot('fixture-tools') + PathDelim + 'fpc',
      project, sdk, TARGETS[t].Os, TARGETS[t].Arch, unitDir, objDir,
      project.NativeProgramPath.Full);
    Record_('devfpc|' + target + '|' + CommandLine(cmd, project, sdk));
    // THE DEFINE IS PRESENT, EXACTLY ONCE, AND IS THE ONLY -d.
    // The two vectors are the same LENGTH: development mode adds -dPWEB_DEV
    // and drops -B, which DevCommandIsTheReleaseVectorInDevMode pins element
    // by element
    CheckEqual(Length(cmd.Args) -
      Length(PWebCliFpcCommand(AbsRoot('fixture-tools') + PathDelim + 'fpc',
        project, sdk, TARGETS[t].Os, TARGETS[t].Arch, unitDir, objDir,
        project.NativeProgramPath.Full).Args), 0,
      'the dev vector is the release vector with one element in and one out');
  end;
end;

procedure TTestPWebDevPure.DevCommandIsTheReleaseVectorInDevMode;
var
  t, i, j, defines: Integer;
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  rel, dev: TPWebCliCommand;
  fpc, target: RawUtf8;
  matched: Boolean;
begin
  // THE CLAIM THIS SHARD HAS TO MAKE ABOUT pweb.cli.native, and it is made
  // here rather than inferred from pipeline_digest: the release vector did
  // not move, and the dev vector is that same vector in DEVELOPMENT MODE -
  // which is exactly two differences and no others:
  //
  //   +  -dPWEB_DEV   the mode, selected by the compiler and by nothing else
  //   -  -B           a release must be a function of its sources alone and
  //                   rebuilds everything; a development compile runs on
  //                   every `pweb dev` start into unit directories no
  //                   release build reads, and the define never varies
  //                   inside them, so there is nothing for a full rebuild
  //                   to protect against and minutes for it to cost
  //
  // Everything else survives, in order.
  project := FixtureProject;
  fpc := AbsRoot('fixture-tools') + PathDelim + 'fpc';
  for t := 0 to High(TARGETS) do
  begin
    sdk := FixtureSdk(TARGETS[t].Os, TARGETS[t].Arch);
    target := PWebCliRunTargetName(TARGETS[t].Os, TARGETS[t].Arch);
    rel := PWebCliFpcCommand(fpc, project, sdk, TARGETS[t].Os,
      TARGETS[t].Arch, 'U', 'B', project.NativeProgramPath.Full);
    dev := PWebCliFpcDevCommand(fpc, project, sdk, TARGETS[t].Os,
      TARGETS[t].Arch, 'U', 'B', project.NativeProgramPath.Full);
    CheckEqual(dev.Exe, rel.Exe, 'the executable is the same compiler');
    CheckEqual(dev.WorkDir, rel.WorkDir, 'the working directory is the same');
    // one in, one out
    CheckEqual(Length(dev.Args), Length(rel.Args),
      'one element in and one out leaves the length alone');
    defines := 0;
    for i := 0 to High(dev.Args) do
      if dev.Args[i] = '-d' + PWEB_CLI_DEV_DEFINE then
        Inc(defines);
    CheckEqual(defines, 1, 'the mode is -dPWEB_DEV, once');
    for i := 0 to High(dev.Args) do
      Check(dev.Args[i] <> '-B', 'a development compile is incremental');
    j := 0;
    for i := 0 to High(rel.Args) do
      if rel.Args[i] = '-B' then
        Inc(j);
    CheckEqual(j, 1, 'and a RELEASE compile still rebuilds everything');
    // every other release element survives, in order: the two vectors read
    // the same once the mode is taken out of one and -B out of the other
    j := 0;
    matched := True;
    for i := 0 to High(dev.Args) do
      if dev.Args[i] = '-d' + PWEB_CLI_DEV_DEFINE then
        continue
      else
      begin
        while (j <= High(rel.Args)) and
              (rel.Args[j] = '-B') do
          Inc(j);
        if (j > High(rel.Args)) or
           (dev.Args[i] <> rel.Args[j]) then
          matched := False;
        Inc(j);
      end;
    Check(matched, 'the release vector is unchanged, element by element');
    while (j <= High(rel.Args)) and
          (rel.Args[j] = '-B') do
      Inc(j);
    CheckEqual(j, Length(rel.Args), 'and nothing else was dropped from it');
    Record_('devfpc-delta|' + target + '|mode|-d' + PWEB_CLI_DEV_DEFINE +
      '|incremental|-B');
  end;
end;

procedure TTestPWebDevPure.ExitMappingAndStageNames;
var
  c: TPWebCliDevCode;
  s: TPWebCliDevStage;
begin
  // the ratified mapping, one line each. Two exits this shard adds meaning
  // to - 5 for the supervised set and 6 for a dev-loop invariant - are the
  // reason this table is in the corpus rather than in a comment
  for c := Low(TPWebCliDevCode) to High(TPWebCliDevCode) do
    Record_('devexit|' + RawUtf8(IntToStr(Ord(c))) + '|' +
      RawUtf8(IntToStr(PWebCliDevExitCode(c))));
  CheckEqual(PWebCliDevExitCode(pdcOk), 0, 'a clean loop is 0');
  CheckEqual(PWebCliDevExitCode(pdcUsage), 2, 'usage is 2');
  CheckEqual(PWebCliDevExitCode(pdcProject), 3,
    'a project refusal - dev_ui_unsupported included - is 3');
  CheckEqual(PWebCliDevExitCode(pdcUnavailable), 4, 'the machine is 4');
  CheckEqual(PWebCliDevExitCode(pdcSetFailed), 5,
    'the supervised set failing is 5');
  CheckEqual(PWebCliDevExitCode(pdcInternal), 6, 'an invariant break is 6');
  for s := Low(TPWebCliDevStage) to High(TPWebCliDevStage) do
    Record_('devstage|' + RawUtf8(IntToStr(Ord(s))) + '|' +
      PWebCliDevStageName(s));
  CheckEqual(PWebCliDevStageName(pdvLoop), 'loop', 'the loop is named');
end;

procedure TTestPWebDevPure.GenerationAndSentinelPaths;
var
  fe: RawUtf8;
begin
  CheckEqual(PWebCliDevGenerationDir(1), 'gen-1', 'generation 1');
  CheckEqual(PWebCliDevGenerationDir(42), 'gen-42', 'generation 42');
  Record_('devgen|1|' + PWebCliDevGenerationDir(1));
  Record_('devgen|42|' + PWebCliDevGenerationDir(42));
  // the sentinel and the install record live UNDER .pweb, inside the
  // ratified mutation set and outside dist/ - so no app.pwb digest moves
  // because of either of them
  fe := AbsRoot('fixture-root') + PathDelim + 'frontend';
  Check(PosEx(PWEB_FE_PWEB_DIR, PWebCliDevSentinelPath(fe)) > 0,
    'the sentinel is under .pweb');
  Check(PosEx(PWEB_CLI_DEV_SENTINEL_FILE, PWebCliDevSentinelPath(fe)) > 0,
    'and it is the build-id file');
  Check(PosEx(PWEB_FE_DIST, PWebCliDevSentinelPath(fe)) = 0,
    'and NOT under dist/');
  Check(PosEx(PWEB_CLI_DEV_INSTALL_RECORD,
    PWebCliDevInstallRecordPath(fe)) > 0, 'the install record is named');
  Record_('devsentinel|logical|' + PWEB_FE_PWEB_DIR + '/' +
    PWEB_CLI_DEV_SENTINEL_DIR + '/' + PWEB_CLI_DEV_SENTINEL_FILE);
  Record_('devinstallrecord|logical|' + PWEB_FE_PWEB_DIR + '/' +
    PWEB_CLI_DEV_SENTINEL_DIR + '/' + PWEB_CLI_DEV_INSTALL_RECORD);
end;

procedure TTestPWebDevPure.AcknowledgementGrammar;
var
  n: Integer;

  procedure One(const Line: RawUtf8; Expect: Integer);
  var
    got: Integer;
    ok: Boolean;
  begin
    ok := PWebCliDevParseAck(Line, got);
    if Expect = 0 then
    begin
      Check(not ok, 'refused: ' + Line);
      Record_('devack|' + Line + '|no');
    end
    else
    begin
      Check(ok, 'accepted: ' + Line);
      CheckEqual(got, Expect, 'and the generation is read exactly');
      Record_('devack|' + Line + '|' + RawUtf8(IntToStr(got)));
    end;
  end;

begin
  // the ONE ratified acknowledgement shape, recognised by its SHAPE and
  // never by the application's own name - so a project called `generation`
  // cannot break the loop
  One('demo: generation 1 loaded', 1);
  One('demo: generation 217 loaded', 217);
  One('generation: generation 3 loaded', 3);
  One('demo: generation 0 loaded', 0);
  One('demo: generation 1 loaded ', 0);
  One('demo: generation  1 loaded', 0);
  One('demo: generation 1 loade', 0);
  One('demo: generation x loaded', 0);
  One('demo: ready', 0);
  One('', 0);
  One('demo: generation 1234567890123 loaded', 0);
  n := 0;
  Check(not PWebCliDevParseAck('demo: generation', n),
    'a truncated line is refused');
end;

procedure TTestPWebDevPure.AnsiStripping;

  procedure One(const Tag, Input, Expect: RawUtf8);
  begin
    CheckEqual(PWebCliDevStripAnsi(Input), Expect, Tag);
    Record_('devansi|' + Tag + '|' + PWebCliDevStripAnsi(Input));
  end;

begin
  // MEASURED necessary: vite colours its output whenever the inherited
  // environment enables it, and the supervisor injects nothing to stop it -
  // so "no ANSI reaches a redirected stream" is enforced on the way OUT,
  // over the CHILD's bytes as well as the supervisor's
  One('plain', 'built in 51ms.', 'built in 51ms.');
  One('sgr', #27'[32mgreen'#27'[0m', 'green');
  One('sgr256', #27'[38;5;196mred'#27'[39m', 'red');
  One('cursor', 'a'#27'[2Kb', 'ab');
  One('osc', #27']0;title'#7'x', 'x');
  One('osc-st', #27']8;;http'#27'\y', 'y');
  One('twobyte', #27'Mz', 'z');
  One('unterminated', 'keep'#27'[3', 'keep');
  One('tab', 'a'#9'b', 'a'#9'b');
  One('bell', 'a'#7'b', 'ab');
  One('cr', 'a'#13'b', 'ab');
end;

procedure TTestPWebDevPure.MutationSetUnchanged;
var
  project: TPWebCliProject;
  set_: TRawUtf8DynArray;
  i: PtrInt;
begin
  // THE C1 MUTATION SET IS UNCHANGED, and that is the claim: everything the
  // dev loop writes - the staged SDK, node_modules, dist, the sentinel, the
  // install record, the whole dev layout and every generation - is already
  // inside one of these four prefixes
  project := FixtureProject;
  set_ := PWebCliMutationSet(project);
  CheckEqual(Length(set_), 4, 'four writable prefixes, exactly as CAP-10C1');
  for i := 0 to High(set_) do
    Record_('devmutation|' + RawUtf8(IntToStr(i)) + '|' + set_[i]);
  CheckEqual(set_[0], 'frontend/' + PWEB_FE_PWEB_DIR,
    'the staged SDK, the sentinel and the install record');
  CheckEqual(set_[1], 'frontend/' + PWEB_FE_NODE_MODULES, 'npm ci');
  CheckEqual(set_[2], 'frontend/' + PWEB_FE_DIST, 'the watcher');
  CheckEqual(set_[3], 'dist', 'the dev layout and every generation');
end;

{ ---------------------------------------------------------------------------
  TTestPWebDevFs
  --------------------------------------------------------------------------- }

function FreshFixture(const Name: RawUtf8; out Full: RawUtf8): Boolean;
var
  parent: RawUtf8;
  stage: TPWebCliStageRefusal;
begin
  Result := False;
  Full := '';
  ForceDirectories(ExpandFileName(PWEB_CAP10C2_FIXTURE));
  if not PWebCliCanonicalDir(RawUtf8(ExpandFileName(PWEB_CAP10C2_FIXTURE)),
       parent) then
    exit;
  // the GUARDED remover, never a recursive delete this suite aims itself
  if not PWebCliPipeRemoveTree(parent, Name, stage) then
    exit;
  Result := PWebCliPipeEnsureDir(parent, Name, Full, stage);
end;

// a development layout over a real target directory, with no compiler and
// no SDK: PWebCliDevEnsureLayout is a pure plan plus directory creation
function LayoutIn(const TargetDir: RawUtf8): TPWebCliDevLayout;
var
  project: TPWebCliProject;
begin
  project := FixtureProject;
  Result := PWebCliDevEnsureLayout(project, PWebCliHostOs, PWebCliHostArch,
    TargetDir);
end;

procedure TTestPWebDevFs.LayoutAndTmpReclaim;
var
  targetDir, full, stray: RawUtf8;
  layout: TPWebCliDevLayout;
  stage: TPWebCliStageRefusal;
begin
  Check(FreshFixture('layout', targetDir), 'the fixture target directory');
  layout := LayoutIn(targetDir);
  CheckEqual(Ord(layout.Refusal), Ord(pdlNone), 'the layout is created');
  Record_('devlayout|created|' + PWEB_CLI_DEV_DIR + '/' +
    PWEB_CLI_DEV_APP_DIR + ',' + PWEB_CLI_DEV_UNIT_DIR + ',' +
    PWEB_CLI_DEV_OBJ_DIR);
  Check(PWebCliEntry(targetDir, PWEB_CLI_DEV_DIR) = pcnDirectory,
    'dev/ exists');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_APP_DIR) = pcnDirectory,
    'dev/app exists');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_UNIT_DIR) = pcnDirectory,
    'dev/units exists');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_OBJ_DIR) = pcnDirectory,
    'dev/obj exists');
  // AND IT IS BESIDE release/, NEVER INSIDE IT
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_RUN_RELEASE) = pcnMissing,
    'a development session creates no release directory');
  Record_('devlayout|beside_release|true');

  // DEV6: a .gen.tmp an interrupted session left behind is removed at the
  // START of the next one - the only moment nothing can be using it
  Check(PWebCliPipeEnsureDir(layout.DevDir, PWEB_CLI_DEV_TMP_DIR, stray,
    stage), 'a stray .gen.tmp is planted');
  Check(PWebCliWriteNewFile(PWebCliJoin(stray, 'half.txt'),
    RawByteString('partial'), False), 'with a half-written file in it');
  layout := LayoutIn(targetDir);
  CheckEqual(Ord(layout.Refusal), Ord(pdlNone), 'the next start succeeds');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_TMP_DIR) = pcnMissing,
    'and the stray .gen.tmp is gone');
  Record_('devlayout|tmp_reclaimed_at_start|true');
  full := '';
  Check(full = '', 'no unused warning');
end;

procedure TTestPWebDevFs.PublishIsOneRenameThatCannotReplace;
var
  targetDir, tmpDist: RawUtf8;
  layout: TPWebCliDevLayout;
  refusal: TPWebCliDevLayoutRefusal;
begin
  Check(FreshFixture('publish', targetDir), 'the fixture target directory');
  layout := LayoutIn(targetDir);
  CheckEqual(Ord(layout.Refusal), Ord(pdlNone), 'the layout is created');

  // ONE generation, assembled in .gen.tmp and published by ONE rename
  Check(PWebCliDevBeginGeneration(layout, tmpDist, refusal),
    'a generation is begun');
  Check(PWebCliWriteNewFile(PWebCliDevTmpBundle(layout),
    RawByteString('not-a-real-archive'), False), 'and carries an archive');
  Check(PWebCliDevTrimGeneration(layout, refusal),
    'the copied dist is trimmed before the publish');
  Check(PWebCliDevPublishGeneration(layout, 1, refusal), 'gen-1 is published');
  Check(PWebCliDevGenerationPresent(layout, 1), 'and it is there');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_TMP_DIR) = pcnMissing,
    'and .gen.tmp is gone, because the rename MOVED it');
  Record_('devpublish|one_rename|true');

  // AND IT MUST NOT REPLACE. A second generation aimed at a name that is
  // already taken is refused rather than overwriting a published one -
  // which is the whole reason a generation can be called immutable
  Check(PWebCliDevBeginGeneration(layout, tmpDist, refusal),
    'a second generation is begun');
  Check(PWebCliWriteNewFile(PWebCliDevTmpBundle(layout),
    RawByteString('second'), False), 'and carries an archive');
  Check(PWebCliDevTrimGeneration(layout, refusal), 'and is trimmed');
  Check(not PWebCliDevPublishGeneration(layout, 1, refusal),
    'publishing onto gen-1 again is REFUSED');
  CheckEqual(PWebCliDevLayoutRefusalText(refusal), 'dev_publish_failed',
    'with its own cause');
  Record_('devpublish|must_not_replace|' +
    PWebCliDevLayoutRefusalText(refusal));
  // the published generation is untouched
  CheckEqual(RawUtf8(StringFromFile(string(PWebCliJoin(
    PWebCliJoin(layout.DevDir, PWebCliDevGenerationDir(1)),
    PWEB_CLI_RUN_BUNDLE)))), 'not-a-real-archive',
    'nothing wrote into a published generation');
  Record_('devpublish|published_immutable|true');
  // and the same tmp publishes cleanly onto the NEXT name
  Check(PWebCliDevPublishGeneration(layout, 2, refusal), 'gen-2 publishes');
  Check(PWebCliDevGenerationPresent(layout, 2), 'and it is there');

  // the generation counter is BOUNDED
  Check(not PWebCliDevPublishGeneration(layout,
    PWEB_CLI_DEV_MAX_GENERATIONS + 1, refusal), 'the counter is bounded');
  CheckEqual(PWebCliDevLayoutRefusalText(refusal), 'dev_generation_bound',
    'with its own cause');
  Record_('devpublish|bounded|' + PWebCliDevLayoutRefusalText(refusal));
end;

procedure TTestPWebDevFs.CleanupOnlyGoesBackwards;
var
  targetDir, tmpDist: RawUtf8;
  layout: TPWebCliDevLayout;
  refusal: TPWebCliDevLayoutRefusal;
  n, removed: Integer;
begin
  Check(FreshFixture('cleanup', targetDir), 'the fixture target directory');
  layout := LayoutIn(targetDir);
  for n := 1 to 6 do
  begin
    Check(PWebCliDevBeginGeneration(layout, tmpDist, refusal), 'begun');
    Check(PWebCliWriteNewFile(PWebCliDevTmpBundle(layout),
      RawByteString('g'), False), 'archived');
    Check(PWebCliDevTrimGeneration(layout, refusal), 'trimmed');
    Check(PWebCliDevPublishGeneration(layout, n, refusal), 'published');
  end;
  removed := PWebCliDevCleanGenerations(layout, 6);
  Record_('devcleanup|current6|removed' + RawUtf8(IntToStr(removed)));
  // the keep window is PWEB_CLI_DEV_KEEP_GENERATIONS behind the current
  // generation, and NOTHING at or after it is ever removed - the host only
  // looks forward, so a removed generation can never be the one it is about
  // to open
  for n := 6 downto 6 - PWEB_CLI_DEV_KEEP_GENERATIONS + 1 do
    Check(PWebCliDevGenerationPresent(layout, n),
      'the keep window survives: gen-' + RawUtf8(IntToStr(n)));
  for n := 1 to 6 - PWEB_CLI_DEV_KEEP_GENERATIONS do
    Check(not PWebCliDevGenerationPresent(layout, n),
      'and everything behind it is gone: gen-' + RawUtf8(IntToStr(n)));
  Record_('devcleanup|keep|' + RawUtf8(IntToStr(PWEB_CLI_DEV_KEEP_GENERATIONS)));
  // a second call removes nothing: there is nothing left behind the window
  CheckEqual(PWebCliDevCleanGenerations(layout, 6), 0,
    'a repeated cleanup is a no-op');
  Record_('devcleanup|idempotent|true');
end;

procedure TTestPWebDevFs.AStartReclaimsAPreviousSessionsGenerations;
var
  targetDir, tmpDist, stray: RawUtf8;
  layout, second: TPWebCliDevLayout;
  refusal: TPWebCliDevLayoutRefusal;
  stage: TPWebCliStageRefusal;
  n, removed: Integer;
begin
  // MEASURED, and the reason this case exists: a session numbers from 1 and
  // publishes by a rename that MUST NOT REPLACE, so a second `pweb dev` on a
  // project that already had one refused at gen-1 with dev_publish_failed
  // and never opened a window. A start therefore reclaims what the previous
  // session published - and ONLY that.
  Check(FreshFixture('reset', targetDir), 'the fixture target directory');
  layout := LayoutIn(targetDir);
  for n := 1 to 3 do
  begin
    Check(PWebCliDevBeginGeneration(layout, tmpDist, refusal), 'begun');
    Check(PWebCliWriteNewFile(PWebCliDevTmpBundle(layout),
      RawByteString('g'), False), 'archived');
    Check(PWebCliDevTrimGeneration(layout, refusal), 'trimmed');
    Check(PWebCliDevPublishGeneration(layout, n, refusal), 'published');
  end;
  // two names that LOOK like generations and are not: the walk removes what
  // this loop wrote, never what merely resembles it
  Check(PWebCliPipeEnsureDir(layout.DevDir, 'gen-x', stray, stage),
    'a non-numeric neighbour');
  Check(PWebCliPipeEnsureDir(layout.DevDir, 'gen-', stray, stage),
    'a prefix with no number');
  Check(PWebCliDevResetGenerations(layout, removed), 'the reset succeeded');
  CheckEqual(removed, 3, 'exactly the three published generations went');
  for n := 1 to 3 do
    Check(not PWebCliDevGenerationPresent(layout, n),
      'gen-' + RawUtf8(IntToStr(n)) + ' is gone');
  Check(PWebCliEntry(layout.DevDir, 'gen-x') = pcnDirectory,
    'gen-x is not a generation and survives');
  Check(PWebCliEntry(layout.DevDir, 'gen-') = pcnDirectory,
    'gen- is not a generation and survives');
  // and the three directories a session needs are still there afterwards
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_APP_DIR) = pcnDirectory,
    'app/ survives');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_UNIT_DIR) = pcnDirectory,
    'units/ survives');
  Check(PWebCliEntry(layout.DevDir, PWEB_CLI_DEV_OBJ_DIR) = pcnDirectory,
    'obj/ survives');
  Record_('devreset|published3|removed' + RawUtf8(IntToStr(removed)) +
    '|kept|gen-x,gen-,app,units,obj');
  // THE END-TO-END SHAPE: a second EnsureLayout over the same directory is
  // what a second `pweb dev` does, and gen-1 must be free afterwards
  for n := 1 to 2 do
  begin
    Check(PWebCliDevBeginGeneration(layout, tmpDist, refusal), 'begun again');
    Check(PWebCliWriteNewFile(PWebCliDevTmpBundle(layout),
      RawByteString('g'), False), 'archived again');
    Check(PWebCliDevTrimGeneration(layout, refusal), 'trimmed again');
    Check(PWebCliDevPublishGeneration(layout, n, refusal),
      'a reclaimed name is free: gen-' + RawUtf8(IntToStr(n)));
  end;
  second := LayoutIn(targetDir);
  CheckEqual(Ord(second.Refusal), Ord(pdlNone), 'the second start resolved');
  CheckEqual(second.Reclaimed, 2, 'and it reclaimed the two it found');
  Check(not PWebCliDevGenerationPresent(second, 1),
    'so gen-1 is free for the session that is starting');
  Record_('devreset|restart|reclaimed2|gen1_free');
end;

procedure TTestPWebDevFs.ConditionalInstallDecision;
var
  fe, nodeModules, pwebDir, devDir, dummy: RawUtf8;
  reason, digest: RawUtf8;
  stage: TPWebCliStageRefusal;
begin
  Check(FreshFixture('install', fe), 'the fixture frontend');
  // 1. no lockfile at all: the decision cannot be made, so it is made in
  // the SAFE direction
  Check(PWebCliDevNeedsInstall('', fe, reason, digest),
    'an unreadable lockfile forces the install');
  CheckEqual(reason, 'lockfile_unreadable', 'and says so');
  Record_('devinstall|no_lockfile|' + reason);

  Check(PWebCliWriteNewFile(PWebCliJoin(fe, PWEB_CLI_DEV_LOCKFILE),
    RawByteString('{"lockfileVersion":3}'), False), 'a lockfile is written');
  // 2. lockfile, no node_modules
  Check(PWebCliDevNeedsInstall('', fe, reason, digest),
    'an absent node_modules forces the install');
  CheckEqual(reason, 'node_modules_absent', 'and says so');
  Check(digest <> '', 'and the lockfile digest was taken');
  Record_('devinstall|no_node_modules|' + reason);

  Check(PWebCliPipeEnsureDir(fe, PWEB_FE_NODE_MODULES, nodeModules, stage),
    'node_modules is created');
  // 3. node_modules, no install record
  Check(PWebCliDevNeedsInstall('', fe, reason, digest),
    'an absent install record forces the install');
  CheckEqual(reason, 'install_record_absent', 'and says so');
  Record_('devinstall|no_record|' + reason);

  Check(PWebCliPipeEnsureDir(fe, PWEB_FE_PWEB_DIR, pwebDir, stage) and
    PWebCliPipeEnsureDir(pwebDir, PWEB_CLI_DEV_SENTINEL_DIR, devDir, stage),
    '.pweb/dev is created');
  Check(PWebCliWriteNewFile(PWebCliDevInstallRecordPath(fe),
    RawByteString(digest + #10), False), 'the record is written');
  // 4. record agrees, but the entry points are absent
  Check(PWebCliDevNeedsInstall('', fe, reason, digest),
    'an unresolvable entry point forces the install');
  CheckEqual(reason, 'vite_absent', 'and says which one');
  Record_('devinstall|no_vite|' + reason);

  // 5. a lockfile that CHANGED beats an agreeing record: the record is
  // re-read against the file rather than trusted
  Check(PWebCliDeleteFile(PWebCliJoin(fe, PWEB_CLI_DEV_LOCKFILE)),
    'the lockfile is replaced');
  Check(PWebCliWriteNewFile(PWebCliJoin(fe, PWEB_CLI_DEV_LOCKFILE),
    RawByteString('{"lockfileVersion":3,"changed":true}'), False),
    'with different bytes');
  Check(PWebCliDevNeedsInstall('', fe, reason, digest),
    'a changed lockfile forces the install');
  CheckEqual(reason, 'lockfile_changed', 'and says so');
  Record_('devinstall|lockfile_changed|' + reason);
  dummy := '';
  Check(dummy = '', 'no unused warning');
end;

end.
