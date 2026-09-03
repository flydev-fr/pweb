{
  pweb.test.devpas2js - the CAP-10C3 suite over the Pas2JS development loop
  (mormot.core.test).

  Two subjects, one file, all four targets:

    PURE    the rules that are pure functions of their inputs - the
            supported-UI predicate and the unratified-ordinal refusal it
            keeps alive, the change-detection model per UI, the input-set
            membership rule, the refusal vocabulary and the bounds this
            shard names.

    FS      the rules that are about a real filesystem - the PAS2JS
            GENERATION COMMAND TABLE for all four targets (the plan builder
            WALKS a frontend, so it needs one to exist), that the
            fingerprint is a function of CONTENT and not of a timestamp,
            that a same-size edit still moves it, that a file outside the
            ratified set moves nothing, and that the file, depth and
            absent-set refusals happen before anything is built. Fixtures
            are built under build/cap10c3/fixture and reclaimed by the
            guarded remover, never by a recursive delete this suite aims
            itself.

  THE FOUR-TARGET PROPERTY IS KEPT. Every command vector is computed for all
  four targets on whichever target is running, and every recorded line is
  projected through the same redaction the loop uses - so a Linux runner
  proves the macOS arm64 Pas2JS generation command line, and the digest is a
  fact about the RULES rather than about four machines.

  It emits build/cap10c3/devpas2js-corpus.txt: every DECISION this suite
  made, one LF line each, hashed into dev_pas2js_digest and required equal on
  four targets. Anything legitimately platform-shaped goes to
  build/cap10c3/devpas2js-observed.txt as key=value and is recorded per
  target, never compared.

  WHAT IS NOT HERE, and belongs to the gate: the real `pweb dev` on the real
  generated Pas2JS project, the running host, the generation switch, the
  compile error that must not stop the loop, the interrupt, the link and
  bound refusals of the REAL CLI, the archive parity with the CAP-10C1
  pipeline and the two binaries' CSP bytes. Those need real tools, a real
  display and a real signal, and a suite that pretended to have them would be
  the vacuous measurement this repository refuses.
}

{$I mormot.defines.inc}

unit pweb.test.devpas2js;

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
  pweb.cli.devinputs,
  pweb.cli.dev;

type
  TTestPWebDevPas2jsPure = class(TSynTestCase)
  published
    procedure SupportedUiAndTheRefusalItKeeps;
    procedure ChangeDetectionModelPerUi;
    procedure InputSetMembership;
    procedure RefusalVocabulary;
    procedure BoundsAreNamedOnce;
  end;

  TTestPWebDevPas2jsFs = class(TSynTestCase)
  published
    procedure Pas2jsGenerationCommandTable;
    procedure FingerprintIsContentNotTimestamp;
    procedure ASameSizeEditMovesTheFingerprint;
    procedure OnlyTheInputSetMovesIt;
    procedure TheBoundsRefuseBeforeAnythingIsBuilt;
  end;

const
  PWEB_CAP10C3_CORPUS_FILE = 'build/cap10c3/devpas2js-corpus.txt';
  PWEB_CAP10C3_OBSERVED_FILE = 'build/cap10c3/devpas2js-observed.txt';
  PWEB_CAP10C3_FIXTURE = 'build/cap10c3/fixture';

/// write both evidence files
procedure PWebCap10c3Flush;


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

procedure PWebCap10c3Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10C3 Pas2JS development-loop decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10C3_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10C3_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10C3_OBSERVED_FILE);
end;

{ ---------------------------------------------------------------------------
  fixture plumbing
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

function FreshFixture(const Name: RawUtf8; out Full: RawUtf8): Boolean;
var
  parent: RawUtf8;
  stage: TPWebCliStageRefusal;
begin
  Result := False;
  Full := '';
  ForceDirectories(ExpandFileName(PWEB_CAP10C3_FIXTURE));
  if not PWebCliCanonicalDir(RawUtf8(ExpandFileName(PWEB_CAP10C3_FIXTURE)),
       parent) then
    exit;
  // the GUARDED remover, never a recursive delete this suite aims itself
  if not PWebCliPipeRemoveTree(parent, Name, stage) then
    exit;
  Result := PWebCliPipeEnsureDir(parent, Name, Full, stage);
end;

// a project ROOTED AT A REAL DIRECTORY. The synthetic root the CAP-10C2
// suite uses is right for a plan builder that only concatenates strings;
// PWebCliPas2jsCommand WALKS the frontend, so its fixture has to exist - and
// then the project's own root is what the redaction turns back into <root>,
// which is what keeps the recorded line identical on four machines
function FixtureProjectAt(const Root: RawUtf8): TPWebCliProject;
begin
  Result := Default(TPWebCliProject);
  Result.Refusal := pcrNone;
  Result.Root := Root;
  Result.Schema := PWEB_CLI_SCHEMA;
  Result.Name := 'demo';
  Result.Version := '0.1.0';
  Result.BundleId := 'com.example.demo';
  // THE ONE DIFFERENCE from the CAP-10C2 fixture, and the whole subject of
  // this suite
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

function FixtureSdk(Os: TPWebCliOs; Arch: TPWebCliArch): TPWebSdkLayout;
var
  share: RawUtf8;
begin
  Result := Default(TPWebSdkLayout);
  Result.Refusal := pslNone;
  Result.Root := AbsRoot('fixture-sdk');
  Result.Target := PWebCliRunTargetName(Os, Arch);
  Result.FpcTarget := PWebCliFpcTargetName(Os, Arch);
  share := PWebCliJoin(PWebCliJoin(Result.Root, PWEB_SDK_SHARE),
    PWEB_SDK_SHARE_PWEB);
  Result.ShareTree := share;
  // the PAS2JS SDK, which is the one a Pas2JS build resolves instead of the
  // TypeScript tree
  Result.Pas2jsSdk := PWebCliJoin(PWebCliJoin(share, PWEB_SDK_SDK),
    PWEB_SDK_PAS2JS);
  Result.Bundler := PWebCliJoin(PWebCliJoin(Result.Root, PWEB_SDK_BIN),
    PWEB_SDK_BUNDLER);
end;

// the logical projection of one command, exactly as the loop records it
function CommandLine(const Cmd: TPWebCliCommand;
  const Project: TPWebCliProject; const Sdk: TPWebSdkLayout): RawUtf8;
var
  prefixes, tokens: TRawUtf8DynArray;
  tools: TPWebCliToolset;
begin
  tools := Default(TPWebCliToolset);
  tools.Pas2js.Path := AbsRoot('fixture-tools') + PathDelim + 'pas2js';
  PWebCliPipeRedactions(Project, Sdk, tools, prefixes, tokens);
  Result := PWebCliCommandText(Cmd, prefixes, tokens);
end;

// a frontend root carrying the ratified input set and nothing else
function FixtureFrontend(const Name: RawUtf8; out Root: RawUtf8;
  out FrontendRoot: RawUtf8): Boolean;
var
  srcDir: RawUtf8;
  stage: TPWebCliStageRefusal;
begin
  Result := False;
  FrontendRoot := '';
  if not FreshFixture(Name, Root) then
    exit;
  if not PWebCliPipeEnsureDir(Root, 'frontend', FrontendRoot, stage) then
    exit;
  if not PWebCliWriteNewFile(PWebCliJoin(FrontendRoot, PWEB_FE_INDEX),
       RawByteString('<!doctype html>'#10), False) then
    exit;
  if not PWebCliWriteNewFile(PWebCliJoin(FrontendRoot, PWEB_FE_APP_CSS),
       RawByteString(':root{}'#10), False) then
    exit;
  if not PWebCliWriteNewFile(PWebCliJoin(FrontendRoot, PWEB_FE_PAS2JS_CFG),
       RawByteString('-Tbrowser'#10), False) then
    exit;
  if not PWebCliPipeEnsureDir(FrontendRoot, PWEB_FE_SRC, srcDir, stage) then
    exit;
  Result := PWebCliWriteNewFile(PWebCliJoin(srcDir, 'app.pas'),
    RawByteString('unit app; end.'#10), False);
end;

function Rewrite(const Path: RawUtf8; const Content: RawByteString): Boolean;
begin
  PWebCliDeleteFile(Path);
  Result := PWebCliWriteNewFile(Path, Content, False);
end;

{ ---------------------------------------------------------------------------
  TTestPWebDevPas2jsPure
  --------------------------------------------------------------------------- }

procedure TTestPWebDevPas2jsPure.SupportedUiAndTheRefusalItKeeps;
var
  // a RUNTIME value, not a constant the compiler can fold: casting a
  // literal past the enum's range is a compile-time range error, and the
  // whole point of this case is to reach the branch at run time
  raw: Byte;
  unratified: TPWebCliUi;
begin
  // BOTH RATIFIED KINDS ARE IMPLEMENTED as of this shard
  Check(PWebCliDevUiSupported(puiReact), 'react is implemented (CAP-10C2)');
  Check(PWebCliDevUiSupported(puiPas2js), 'pas2js is implemented (CAP-10C3)');
  Record_('devui|react|supported');
  Record_('devui|pas2js|supported');
  // AND THE REFUSAL IS STILL ALIVE. There is no third ratified kind, so the
  // only way to reach the branch is to hand it an ordinal schema 1 does not
  // name - which is exactly the shape of the day a fourth frontend is
  // ratified and its loop has not been written yet. Without this the
  // dev_ui_unsupported path would be unreachable code nobody notices has
  // rotted, and CAP-10C3's own scope requires it to survive
  raw := Ord(High(TPWebCliUi)) + 1;
  unratified := TPWebCliUi(raw);
  Check(not PWebCliDevUiSupported(unratified),
    'an unratified frontend kind is refused');
  Record_('devui|unratified|refused');
  // and the cause the loop reports for it is the ratified one
  Record_('devui|cause|dev_ui_unsupported');
end;

procedure TTestPWebDevPas2jsPure.ChangeDetectionModelPerUi;
begin
  // TWO MODELS, ONE PER FRONTEND KIND, and the reason each is what it is:
  // Vite reports its own completions through a writeBundle sentinel, and
  // pas2js has neither a watch mode nor a writeBundle, so the CLI walks the
  // inputs itself
  CheckEqual(PWebCliDevChangeDetection(puiReact), 'vite_sentinel',
    'React is told when a build finished');
  CheckEqual(PWebCliDevChangeDetection(puiPas2js),
    'cli_content_fingerprint_poll',
    'Pas2JS detection is owned by this CLI');
  Record_('devdetect|react|vite_sentinel');
  Record_('devdetect|pas2js|cli_content_fingerprint_poll');
end;

procedure TTestPWebDevPas2jsPure.InputSetMembership;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
begin
  // THE RATIFIED INPUT SET, asserted as a RULE rather than observed on a
  // disk: exactly the three frontend-root files the CAP-10C1 plan reads,
  // plus the whole of <frontend>/src at any depth
  names := PWebCliDevInputFiles;
  CheckEqual(Length(names), 3, 'three frontend-root files, and no more');
  for i := 0 to High(names) do
    Record_('devinput|file|' + names[i]);
  Check(PWebCliDevInputWatched(PWEB_FE_INDEX), 'index.html is watched');
  Check(PWebCliDevInputWatched(PWEB_FE_APP_CSS), 'app.css is watched');
  Check(PWebCliDevInputWatched(PWEB_FE_PAS2JS_CFG), 'pas2js.cfg is watched');
  Check(PWebCliDevInputWatched(PWEB_FE_SRC + '/app.pas'),
    'a source file is watched');
  Check(PWebCliDevInputWatched(PWEB_FE_SRC + '/deep/nested/unit1.inc'),
    'and so is one at any depth, whatever its extension');
  Record_('devinput|tree|' + PWEB_FE_SRC + '/**');
  // AND WHAT IS NOT WATCHED. Every path here is relative to the FRONTEND
  // ROOT, which is the only base this predicate is ever asked about - the
  // native sources live beside that root and are excluded by the SCAN's
  // root rather than by this rule, which OnlyTheInputSetMovesIt proves on a
  // real tree
  Check(not PWebCliDevInputWatched('pweb.json'), 'the descriptor is not');
  Check(not PWebCliDevInputWatched('README.md'), 'nor is anything else');
  Check(not PWebCliDevInputWatched('dist/windows-x86_64/app.pwb'),
    'nor is the output');
  Check(not PWebCliDevInputWatched('.pweb/dev/build-id'),
    'nor is the React sentinel');
  Check(not PWebCliDevInputWatched('node_modules/vite/index.js'),
    'nor is anything a build itself populates');
  // matched on a COMPONENT boundary, so `src` selects that directory and a
  // sibling that merely starts with the same bytes is outside the set
  Check(not PWebCliDevInputWatched('src-old/app.pas'),
    'a sibling directory sharing a prefix is outside the set');
  Check(not PWebCliDevInputWatched(''), 'and an empty path is nothing');
  Record_('devinput|excluded|' +
    'descriptor,output,sentinel,node_modules,prefix_sibling');
end;

procedure TTestPWebDevPas2jsPure.RefusalVocabulary;
var
  r: TPWebCliDevInputRefusal;
begin
  // the machine-stable causes, spelled once and recorded so a rename is a
  // corpus change rather than a silently different diagnostic
  CheckEqual(PWebCliDevInputRefusalText(pdiNone), 'ok', 'the accepted state');
  CheckEqual(PWebCliDevInputRefusalText(pdiLink), 'dev_input_link',
    'a link or reparse point inside the set');
  CheckEqual(PWebCliDevInputRefusalText(pdiBound), 'dev_input_bound',
    'a set past its file, depth or path bound');
  CheckEqual(PWebCliDevInputRefusalText(pdiFileTooBig), 'dev_input_too_big',
    'one input past the per-file ceiling');
  CheckEqual(PWebCliDevInputRefusalText(pdiUnreadable),
    'dev_input_unreadable', 'a walk that could not look');
  CheckEqual(PWebCliDevInputRefusalText(pdiSetMissing),
    'dev_input_set_missing', 'a frontend without the ratified set');
  for r := Low(TPWebCliDevInputRefusal) to High(TPWebCliDevInputRefusal) do
    Record_('devinputcause|' + RawUtf8(IntToStr(Ord(r))) + '|' +
      PWebCliDevInputRefusalText(r));
end;

procedure TTestPWebDevPas2jsPure.BoundsAreNamedOnce;
begin
  // the bounds this shard adds, recorded so the contract gate compares the
  // CONSTANTS with docs/dev-contract.md rather than with a second copy
  Record_('devbound|PWEB_CLI_DEV_POLL_MS|' +
    RawUtf8(IntToStr(PWEB_CLI_DEV_POLL_MS)));
  Record_('devbound|PWEB_CLI_DEV_MAX_INPUT_FILES|' +
    RawUtf8(IntToStr(PWEB_CLI_DEV_MAX_INPUT_FILES)));
  Record_('devbound|PWEB_CLI_DEV_MAX_INPUT_DEPTH|' +
    RawUtf8(IntToStr(PWEB_CLI_DEV_MAX_INPUT_DEPTH)));
  Record_('devbound|PWEB_CLI_DEV_INPUT_FILE_MAX|' +
    RawUtf8(IntToStr(PWEB_CLI_DEV_INPUT_FILE_MAX)));
  Record_('devbound|PWEB_CLI_DEV_INPUT_PATH_MAX|' +
    RawUtf8(IntToStr(PWEB_CLI_DEV_INPUT_PATH_MAX)));
  // and the CAP-10C2 bounds this loop reuses VERBATIM rather than restating
  Record_('devbound|reused|PWEB_CLI_DEV_DEBOUNCE_MS,' +
    'PWEB_CLI_DEV_DEBOUNCE_MAX_MS,PWEB_CLI_DEV_SNAPSHOT_TRIES,' +
    'PWEB_CLI_DEV_KEEP_GENERATIONS,PWEB_CLI_DEV_MAX_GENERATIONS');
  CheckEqual(PWEB_CLI_DEV_SNAPSHOT_TRIES, 5,
    'the consistency rule keeps the CAP-10C2 try bound');
  CheckEqual(PWEB_CLI_DEV_DEBOUNCE_MS, 250, 'and the CAP-10C2 debounce');
end;

{ ---------------------------------------------------------------------------
  TTestPWebDevPas2jsFs
  --------------------------------------------------------------------------- }

procedure TTestPWebDevPas2jsFs.Pas2jsGenerationCommandTable;
var
  t: Integer;
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  cmd: TPWebCliCommand;
  refusal: TPWebCliFrontendRefusal;
  target, devDir, tmpAssets, root, frontendRoot, srcDir: RawUtf8;
begin
  // THE COMMAND IS THE CAP-10C1 ONE, called and never re-implemented, so
  // this case asserts the C1 builder over a Pas2JS project and a DEV output
  // path - which is the whole reason generation 1's archive is the
  // pipeline's archive
  Check(FixtureFrontend('argv', root, frontendRoot), 'the fixture frontend');
  srcDir := PWebCliJoin(frontendRoot, PWEB_FE_SRC);
  Check(PWebCliWriteNewFile(PWebCliJoin(srcDir, 'demoapp.lpr'),
    RawByteString('program demoapp; begin end.'#10), False),
    'and the entry program the descriptor names');
  project := FixtureProjectAt(root);
  for t := 0 to High(TARGETS) do
  begin
    sdk := FixtureSdk(TARGETS[t].Os, TARGETS[t].Arch);
    target := PWebCliRunTargetName(TARGETS[t].Os, TARGETS[t].Arch);
    // the generation under construction, spelled exactly as devlayout and
    // the loop build it: <output>/<target>/dev/.gen.tmp/dist/assets
    devDir := PWebCliJoin(PWebCliJoin(PWebCliJoin(project.Root, 'dist'),
      target), PWEB_CLI_DEV_DIR);
    tmpAssets := PWebCliJoin(PWebCliJoin(PWebCliJoin(devDir,
      PWEB_CLI_DEV_TMP_DIR), PWEB_FE_DIST), PWEB_FE_ASSETS);
    Check(PWebCliPas2jsCommand(
      AbsRoot('fixture-tools') + PathDelim + 'pas2js', frontendRoot,
      sdk.Pas2jsSdk, PWebCliJoin(tmpAssets, PWEB_FE_APP_JS), project, cmd,
      refusal), 'the Pas2JS generation command is planned');
    CheckEqual(Ord(refusal), Ord(pfrNone), 'and refuses nothing');
    // FOUR ELEMENTS, ALWAYS, AND IN THIS ORDER: the project's own
    // configuration, the SDK unit path, the output and the entry program.
    // A vector that grew a fifth would be a vector the pipeline does not run
    CheckEqual(Length(cmd.Args), 4,
      'the Pas2JS vector is @cfg, -Fu, -o and the entry program');
    Check(Copy(cmd.Args[0], 1, 1) = '@', 'the configuration is read as @file');
    Check(Copy(cmd.Args[1], 1, 3) = '-Fu', 'the SDK unit path is -Fu');
    Check(Copy(cmd.Args[2], 1, 2) = '-o', 'the output is -o');
    // the OUTPUT is inside the generation under construction, so a dev
    // build writes only under <output> and never into the frontend
    Check(PosEx(PWEB_CLI_DEV_TMP_DIR, cmd.Args[2]) > 0,
      'and it is written into the generation under construction');
    // no argument still carries the Windows extended-length prefix - the
    // CAP-10C1 invariant, asserted where a new call site could forget it
    Check(Copy(cmd.Args[2], 1, 4) <> '\\?\',
      'and no argument carries the extended-length prefix');
    Record_('p2jargv|' + target + '|' + CommandLine(cmd, project, sdk));
  end;
  Record_('p2jargv|shape|cfg,sdk_unit_path,output,entry');
end;

procedure TTestPWebDevPas2jsFs.FingerprintIsContentNotTimestamp;
var
  root, frontendRoot, app: RawUtf8;
  a, b, c: TPWebCliDevInputs;
begin
  Check(FixtureFrontend('print', root, frontendRoot), 'the fixture frontend');
  Check(PWebCliDevInputScan(frontendRoot, a), 'the input set is walked');
  CheckEqual(Ord(a.Refusal), Ord(pdiNone), 'and refuses nothing');
  CheckEqual(a.Files, 4, 'index.html, app.css, pas2js.cfg and one source');
  Check(a.Fingerprint <> '', 'and it answers a fingerprint');

  // A REWRITE WITH THE SAME BYTES MOVES NOTHING. The file is deleted and
  // created again - which is what an editor's atomic save looks like, and
  // what a `touch` or a `git checkout` looks like too - so its timestamp is
  // new and its content is not. A detector keyed on mtime would answer
  // "changed" here and cost a whole generation for nothing
  app := PWebCliJoin(PWebCliJoin(frontendRoot, PWEB_FE_SRC), 'app.pas');
  Check(Rewrite(app, RawByteString('unit app; end.'#10)),
    'the source is rewritten with the same bytes');
  Check(PWebCliDevInputScan(frontendRoot, b), 'and walked again');
  CheckEqual(b.Fingerprint, a.Fingerprint,
    'the fingerprint is a function of CONTENT, not of the timestamp');
  Record_('devprint|same_bytes_new_timestamp|unchanged');

  // AND A REAL EDIT MOVES IT
  Check(Rewrite(app, RawByteString('unit app; { edited } end.'#10)),
    'the source is edited');
  Check(PWebCliDevInputScan(frontendRoot, c), 'and walked again');
  Check(c.Fingerprint <> a.Fingerprint, 'a changed byte moves it');
  Record_('devprint|edited|changed');
  Observe('devpas2js_fixture_inputs', RawUtf8(IntToStr(a.Files)));
end;

procedure TTestPWebDevPas2jsFs.ASameSizeEditMovesTheFingerprint;
var
  root, frontendRoot, app: RawUtf8;
  a, b: TPWebCliDevInputs;
begin
  // THE OTHER HALF OF THE SAME ARGUMENT. A fingerprint of (path, size,
  // mtime) misses this whenever the two edits fall inside one timestamp
  // tick, and FPC's portable timestamp layer is SECOND-granular - so an
  // edit that changes one character for another would be invisible for up
  // to a second after the previous one. Content hashing cannot miss it
  Check(FixtureFrontend('samesize', root, frontendRoot),
    'the fixture frontend');
  app := PWebCliJoin(PWebCliJoin(frontendRoot, PWEB_FE_SRC), 'app.pas');
  Check(Rewrite(app, RawByteString('const N = 1;'#10)), 'a source');
  Check(PWebCliDevInputScan(frontendRoot, a), 'is walked');
  Check(Rewrite(app, RawByteString('const N = 2;'#10)),
    'and edited to the SAME LENGTH');
  Check(PWebCliDevInputScan(frontendRoot, b), 'and walked again');
  CheckEqual(b.Files, a.Files, 'the same number of inputs');
  Check(b.Fingerprint <> a.Fingerprint,
    'a same-size edit still moves the fingerprint');
  Record_('devprint|same_size_edit|changed');
end;

procedure TTestPWebDevPas2jsFs.OnlyTheInputSetMovesIt;
var
  root, frontendRoot, deep, nativeSrc: RawUtf8;
  a, b, c, d: TPWebCliDevInputs;
  stage: TPWebCliStageRefusal;
begin
  Check(FixtureFrontend('scope', root, frontendRoot), 'the fixture frontend');
  Check(PWebCliDevInputScan(frontendRoot, a), 'the input set is walked');

  // a file BESIDE the input set inside the same frontend root - not
  // index.html, not app.css, not pas2js.cfg, not under src/
  Check(PWebCliWriteNewFile(PWebCliJoin(frontendRoot, 'NOTES.md'),
    RawByteString('not an input'#10), False), 'an unrelated file is written');
  Check(PWebCliDevInputScan(frontendRoot, b), 'and the set is walked again');
  CheckEqual(b.Fingerprint, a.Fingerprint,
    'a file outside the ratified set moves nothing');
  CheckEqual(b.Files, a.Files, 'and is not counted');
  Record_('devprint|outside_the_set|unchanged');

  // THE NATIVE SOURCES, which live BESIDE the frontend root and are the
  // whole reason a native change still requires restarting `pweb dev`. The
  // scan is rooted at the frontend, so nothing above it can be reached -
  // and that is proved by writing there rather than asserted about a path
  Check(PWebCliPipeEnsureDir(root, 'src', nativeSrc, stage),
    'the project native source directory');
  Check(PWebCliWriteNewFile(PWebCliJoin(nativeSrc, 'app.services.pas'),
    RawByteString('unit app.services; end.'#10), False),
    'holding a native unit');
  Check(PWebCliWriteNewFile(PWebCliJoin(root, 'README.md'),
    RawByteString('# demo'#10), False), 'and a project README');
  Check(PWebCliDevInputScan(frontendRoot, d), 'and the set is walked again');
  CheckEqual(d.Fingerprint, a.Fingerprint,
    'nothing outside the frontend root can move the fingerprint');
  CheckEqual(d.Files, a.Files, 'and nothing outside it is counted');
  Record_('devprint|native_src_and_readme|unchanged');

  // and a NEW file at depth inside src/ moves it, whatever its extension
  Check(PWebCliPipeEnsureDir(PWebCliJoin(frontendRoot, PWEB_FE_SRC),
    'nested', deep, stage), 'a nested source directory');
  Check(PWebCliWriteNewFile(PWebCliJoin(deep, 'helper.inc'),
    RawByteString('{ included }'#10), False), 'holding an include file');
  Check(PWebCliDevInputScan(frontendRoot, c),
    'and the set is walked again');
  Check(c.Fingerprint <> a.Fingerprint,
    'a new file at depth under src/ moves the fingerprint');
  CheckEqual(c.Files, a.Files + 1, 'and is counted');
  Record_('devprint|nested_any_extension|changed');
end;

procedure TTestPWebDevPas2jsFs.TheBoundsRefuseBeforeAnythingIsBuilt;
var
  root, frontendRoot, deep, next, name: RawUtf8;
  scan: TPWebCliDevInputs;
  stage: TPWebCliStageRefusal;
  i: Integer;
begin
  // THE FILE-COUNT BOUND. A walk this loop repeats four times a second
  // needs its own ceiling, and a frontend past it is a fact to report
  // rather than a tree to hash forever
  Check(FixtureFrontend('bound', root, frontendRoot), 'the fixture frontend');
  deep := PWebCliJoin(frontendRoot, PWEB_FE_SRC);
  for i := 1 to PWEB_CLI_DEV_MAX_INPUT_FILES do
    Check(PWebCliWriteNewFile(
      PWebCliJoin(deep, 'u' + RawUtf8(IntToStr(i)) + '.pas'),
      RawByteString('unit u; end.'#10), False), 'one more source');
  Check(not PWebCliDevInputScan(frontendRoot, scan),
    'a set past the file bound is refused');
  CheckEqual(Ord(scan.Refusal), Ord(pdiBound), 'and the cause is the bound');
  Check(scan.Fingerprint = '',
    'a refused walk answers no fingerprint at all');
  Record_('devprint|file_bound|dev_input_bound');

  // THE DEPTH BOUND, measured the same way
  Check(FixtureFrontend('depth', root, frontendRoot),
    'a second fixture frontend');
  deep := PWebCliJoin(frontendRoot, PWEB_FE_SRC);
  for i := 1 to PWEB_CLI_DEV_MAX_INPUT_DEPTH + 1 do
  begin
    name := 'd' + RawUtf8(IntToStr(i));
    // a SEPARATE destination: `Dir` is a const reference and `Full` is an
    // out parameter that is cleared on entry, so handing the same variable
    // as both aliases them and the walk never gets deeper than one level.
    // MEASURED here first, which is exactly what this leg is for
    Check(PWebCliPipeEnsureDir(deep, name, next, stage),
      'one level deeper');
    deep := next;
  end;
  Check(PWebCliWriteNewFile(PWebCliJoin(deep, 'app.pas'),
    RawByteString('unit app; end.'#10), False), 'and a source at the bottom');
  Check(not PWebCliDevInputScan(frontendRoot, scan),
    'a set past the depth bound is refused');
  CheckEqual(Ord(scan.Refusal), Ord(pdiBound), 'and the cause is the bound');
  Record_('devprint|depth_bound|dev_input_bound');

  // AND AN ABSENT INPUT IS ITS OWN CAUSE: a frontend that does not carry the
  // ratified set is a project fact, not a bound
  Check(FreshFixture('missing', root), 'an empty frontend root');
  Check(not PWebCliDevInputScan(root, scan),
    'a frontend without the ratified set is refused');
  CheckEqual(Ord(scan.Refusal), Ord(pdiSetMissing),
    'and the cause names the set, not a bound');
  Record_('devprint|absent_set|dev_input_set_missing');
end;

end.
