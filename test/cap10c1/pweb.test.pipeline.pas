{
  pweb.test.pipeline - the CAP-10C1 suite over the lifecycle pipeline
  (mormot.core.test).

  Two subjects, one file, all four targets:

    PURE    the rules that are pure functions of their inputs - the four
            target COMMAND TABLES (fpc, npm, and the exit mapping), the
            canonical SDK manifest, the Info.plist, the redaction
            projection, the mutation set and the bytewise order. Every one
            of them is computed for ALL FOUR targets on whichever target is
            running, which is the property that lets a Linux runner prove
            what the macOS arm64 link line will be. The same trick CAP-10C0
            used for the Windows quoting rule.

    FS      the rules that are about a real filesystem - the SDK-root
            layout and each of its refusals, the npm entry-point walk for
            both install shapes, the tree digest and its exclusions, the
            TypeScript SDK staging (including that a STALE file does not
            survive it), the Pas2JS normalisation, and the registry-override
            refusal. Fixtures are built under build/cap10c1/fixture and
            reclaimed by the guarded remover, never by a recursive delete
            this suite aims itself.

  It emits build/cap10c1/pipeline-corpus.txt: every DECISION this suite
  made, one LF line each, hashed into pipeline_digest and required equal on
  four targets - so a line carries no absolute path, no timing and no host
  fact. Anything legitimately platform-shaped goes to
  build/cap10c1/pipeline-observed.txt as key=value and is recorded per
  target, never compared.
}

{$I mormot.defines.inc}

unit pweb.test.pipeline;

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
  pweb.cli.pipeline;

type
  TTestPWebPipePure = class(TSynTestCase)
  published
    procedure NativeCommandTable;
    procedure FrontendCommandTable;
    procedure SdkManifestCanonical;
    procedure SdkManifestRefusals;
    procedure InfoPlistTable;
    procedure RedactionProjection;
    procedure MutationSetAndExits;
    procedure BytewiseOrderAndPrefixes;
  end;

  TTestPWebPipeFs = class(TSynTestCase)
  published
    procedure SdkLayoutRefusals;
    procedure NpmEntryPointRule;
    procedure TreeDigestAndExclusions;
    procedure StageTsSdkIsFresh;
    procedure Pas2jsNormalisation;
    procedure RegistryOverrideRefused;
  end;

const
  PWEB_CAP10C1_CORPUS_FILE = 'build/cap10c1/pipeline-corpus.txt';
  PWEB_CAP10C1_OBSERVED_FILE = 'build/cap10c1/pipeline-observed.txt';
  PWEB_CAP10C1_FIXTURE = 'build/cap10c1/fixture';

/// write both evidence files
procedure PWebCap10c1Flush;


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

procedure PWebCap10c1Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10C1 pipeline decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10C1_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10C1_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10C1_OBSERVED_FILE);
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
  // an absolute-looking path in this host's own spelling, so PWebCliJoin and
  // PWebCliSplitLast behave exactly as they will in production. Which
  // spelling it is does not reach the corpus: the redaction replaces it
  if PWebCliHostOs = pcoWindows then
    Result := 'C:\' + Name
  else
    Result := '/' + Name;
end;

function FixtureProject(Ui: TPWebCliUi): TPWebCliProject;
begin
  Result := Default(TPWebCliProject);
  Result.Refusal := pcrNone;
  Result.Root := AbsRoot('fixture-root');
  Result.Schema := PWEB_CLI_SCHEMA;
  Result.Name := 'demo';
  Result.Version := '0.1.0';
  Result.BundleId := 'com.example.demo';
  Result.Ui := Ui;
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

// a layout record built by hand: PWebCliFpcCommand is a PURE function of it,
// so the four-target table needs no filesystem at all
function FixtureSdk(Os: TPWebCliOs; Arch: TPWebCliArch;
  Pas2js: Boolean): TPWebSdkLayout;
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
  if Pas2js then
    Result.Pas2jsSdk := PWebCliJoin(PWebCliJoin(share, PWEB_SDK_SDK),
      PWEB_SDK_PAS2JS)
  else
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

function FixtureTools(const Sdk: TPWebSdkLayout): TPWebCliToolset;
begin
  Result := Default(TPWebCliToolset);
  Result.Node.Path := AbsRoot('tools') + PathDelim + 'node';
  Result.Npm.Script := AbsRoot('tools') + PathDelim + 'npm-cli.js';
  Result.Fpc.Path := AbsRoot('tools') + PathDelim + 'fpc';
  Result.Pas2js.Path := AbsRoot('tools') + PathDelim + 'pas2js';
end;

// the fixture directory of ONE test, reclaimed and recreated
function FixtureDir(const Name: RawUtf8; out Full: RawUtf8): Boolean;
var
  parent, base: RawUtf8;
  refusal: TPWebCliStageRefusal;
begin
  Full := '';
  Result := False;
  ForceDirectories(ExpandFileName(PWEB_CAP10C1_FIXTURE));
  if not PWebCliCanonicalDir(RawUtf8(ExpandFileName(PWEB_CAP10C1_FIXTURE)),
       base) then
    exit;
  parent := base;
  if not PWebCliPipeRemoveTree(parent, Name, refusal) then
    exit;
  Result := PWebCliPipeEnsureDir(parent, Name, Full, refusal);
end;

function WriteFixtureFile(const Dir, Name, Content: RawUtf8): Boolean;
begin
  Result := PWebCliWriteNewFile(PWebCliJoin(Dir, Name),
    RawByteString(Content), {SetExecBit=}False);
end;


{ TTestPWebPipePure }

procedure TTestPWebPipePure.NativeCommandTable;
var
  t: PtrInt;
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  tools: TPWebCliToolset;
  cmd: TPWebCliCommand;
  prefixes, tokens: TRawUtf8DynArray;
  text, target: RawUtf8;
begin
  project := FixtureProject(puiReact);
  for t := 0 to High(TARGETS) do
  begin
    sdk := FixtureSdk(TARGETS[t].Os, TARGETS[t].Arch, {Pas2js=}False);
    tools := FixtureTools(sdk);
    target := sdk.Target;
    cmd := PWebCliFpcCommand(tools.Fpc.Path, project, sdk,
      TARGETS[t].Os, TARGETS[t].Arch,
      PWebCliJoin(PWebCliJoin(project.OutputPath.Full, target),
        PWEB_NATIVE_UNIT_DIR),
      PWebCliJoin(PWebCliJoin(project.OutputPath.Full, target),
        PWEB_NATIVE_BIN_DIR),
      project.NativeProgramPath.Full);
    PWebCliPipeRedactions(project, sdk, tools, prefixes, tokens);
    text := PWebCliCommandText(cmd, prefixes, tokens);
    Record_('pipe|fpc|' + target + '|' + text);
    // the three facts each target owes, asserted rather than merely recorded
    Check(Pos('-MObjFPC', text) > 0, 'the mode switch is missing');
    Check(Pos('-B', text) > 0, 'the build-all switch is missing');
    Check(Pos('<root>/src/demo.lpr', text) > 0,
      'the program is not the last argument');
    case TARGETS[t].Os of
      pcoWindows:
        begin
          Check(Pos('-Twin64', text) > 0, 'Win64 is not selected');
          Check(Pos('-Fl<sdk>/share/pweb/deps/mormot2/static/x86_64-win64',
            text) > 0, 'the Windows statics are not the SDK root''s');
          Check(Pos('-no_fixup_chains', text) = 0,
            'an aarch64 workaround reached Windows');
        end;
      pcoLinux:
        begin
          Check(Pos('-k-rpath=$ORIGIN', text) > 0, 'the rpath is missing');
          Check(Pos('-k-lgcc_s', text) > 0, 'libgcc_s is not named');
          Check(Pos('-Twin64', text) = 0, 'a Windows switch reached Linux');
        end;
      pcoMacos:
        begin
          Check(Pos('-WM' + PWEB_CLI_MACOS_MIN, text) > 0,
            'the deployment target is missing');
          Check(Pos('-k-lwebview', text) > 0, 'the dylib is not named');
          Check(Pos('pweb_cocoa_bridge.o', text) > 0,
            'the production bridge is not linked');
          Check(Pos('-k-framework -kCocoa', text) > 0, 'Cocoa is missing');
          Check(Pos('-k-framework -kWebKit', text) > 0, 'WebKit is missing');
          if TARGETS[t].Arch = pcaArm64 then
            Check(Pos('-k-no_fixup_chains', text) > 0,
              'aarch64 links without -no_fixup_chains: every Pascal link ' +
              'would fail on FPC_THREADVARTABLES alignment')
          else
            Check(Pos('-k-no_fixup_chains', text) = 0,
              'x86_64 carries the aarch64 workaround');
        end;
    end;
    // no absolute path may survive the projection: this is what an evidence
    // file and a driver line are allowed to carry
    Check(Pos('fixture-sdk', text) = 0, 'an SDK path leaked');
    Check(Pos('fixture-root', text) = 0, 'a project path leaked');
  end;
end;

procedure TTestPWebPipePure.FrontendCommandTable;
var
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  tools: TPWebCliToolset;
  cmd: TPWebCliCommand;
  prefixes, tokens: TRawUtf8DynArray;
  text: RawUtf8;
begin
  project := FixtureProject(puiReact);
  sdk := FixtureSdk(pcoLinux, pcaX86_64, {Pas2js=}False);
  tools := FixtureTools(sdk);
  PWebCliPipeRedactions(project, sdk, tools, prefixes, tokens);
  cmd := PWebCliNpmCiCommand(tools.Node.Path, tools.Npm.Script,
    project.FrontendRootPath.Full);
  text := PWebCliCommandText(cmd, prefixes, tokens);
  Record_('pipe|npm|' + text);
  Check(text = '<node> <npm-cli> ci --no-audit --no-fund --ignore-scripts',
    'the npm invocation is not the ratified one: ' + text);
  Check(cmd.WorkDir = project.FrontendRootPath.Full,
    'npm ci does not run in the frontend root');
  // the pack contract, the whole of it
  cmd := PWebCliPackCommand(sdk.Bundler,
    PWebCliJoin(project.FrontendRootPath.Full, PWEB_FE_DIST),
    PWebCliJoin(project.OutputPath.Full, PWEB_PACK_BUNDLE), project.Root);
  text := PWebCliCommandText(cmd, prefixes, tokens);
  Record_('pipe|pack|' + text);
  Check(text = '<bundler> <root>/frontend/dist <root>/dist/app.pwb',
    'the bundler is not invoked with exactly two paths: ' + text);
end;

procedure TTestPWebPipePure.SdkManifestCanonical;
const
  DEV: RawUtf8 =
    '{'#10 +
    '  "name": "@pweb/runtime",'#10 +
    '  "version": "0.1.0",'#10 +
    '  "private": true,'#10 +
    '  "description": "a } brace inside a string",'#10 +
    '  "license": "MIT",'#10 +
    '  "type": "module",'#10 +
    '  "main": "./dist/src/index.js",'#10 +
    '  "types": "./dist/src/index.d.ts",'#10 +
    '  "exports": {'#10 +
    '    ".": {'#10 +
    '      "types": "./dist/src/index.d.ts",'#10 +
    '      "default": "./dist/src/index.js"'#10 +
    '    }'#10 +
    '  },'#10 +
    '  "files": ['#10 +
    '    "dist/src"'#10 +
    '  ],'#10 +
    '  "devDependencies": {'#10 +
    '    "typescript": "7.0.2"'#10 +
    '  }'#10 +
    '}'#10;
  EXPECTED: RawUtf8 =
    '{'#10 +
    '  "name": "@pweb/runtime",'#10 +
    '  "version": "0.1.0",'#10 +
    '  "license": "MIT",'#10 +
    '  "type": "module",'#10 +
    '  "main": "./dist/src/index.js",'#10 +
    '  "types": "./dist/src/index.d.ts",'#10 +
    '  "exports": {'#10 +
    '    ".": {'#10 +
    '      "types": "./dist/src/index.d.ts",'#10 +
    '      "default": "./dist/src/index.js"'#10 +
    '    }'#10 +
    '  }'#10 +
    '}'#10;
var
  canonical: RawUtf8;
  refusal: TPWebCliStageRefusal;
begin
  Check(PWebCliSdkManifest(DEV, canonical, refusal),
    'the canonical manifest was refused: ' +
    PWebCliStageRefusalText(refusal));
  // BYTE equality, including the trailing newline: this is what
  // JSON.stringify(canonical, null, 2) + "\n" produces, and the gate proves
  // the same against the real script on every target
  CheckEqual(canonical, EXPECTED, 'the canonical manifest is not byte-exact');
  Record_('pipe|manifest|canonical|' +
    RawUtf8(IntToStr(Length(canonical))) + '|ok');
  // the description carried a '}' inside a string literal, which a bracket
  // walk that ignored strings would have read as the end of the document
  Check(Pos('brace', canonical) = 0,
    'a development-only key survived into the distribution manifest');
end;

procedure TTestPWebPipePure.SdkManifestRefusals;
var
  canonical: RawUtf8;
  refusal: TPWebCliStageRefusal;
begin
  // a canonical key that is absent
  Check(not PWebCliSdkManifest('{"name": "x"}'#10, canonical, refusal),
    'a manifest missing six keys was accepted');
  Check(refusal = pstManifestField, 'the absent key has the wrong cause');
  Record_('pipe|manifest|missing|' + PWebCliStageRefusalText(refusal));
  // a canonical key whose value is a NUMBER: refused, never re-encoded on a
  // guess about how JavaScript would have printed it
  Check(not PWebCliSdkManifest(
    '{"name":"x","version":1,"license":"MIT","type":"module",' +
    '"main":"a","types":"b","exports":{}}', canonical, refusal),
    'a numeric version was accepted');
  Check(refusal = pstManifestShape, 'the bad shape has the wrong cause');
  Record_('pipe|manifest|shape|' + PWebCliStageRefusalText(refusal));
  Check(not PWebCliSdkManifest('', canonical, refusal),
    'an empty manifest was accepted');
end;

procedure TTestPWebPipePure.InfoPlistTable;
var
  project: TPWebCliProject;
  plist: RawUtf8;
begin
  project := FixtureProject(puiReact);
  plist := PWebCliInfoPlist(project);
  Record_('pipe|plist|' + RawUtf8(IntToStr(Length(plist))));
  Check(Pos('<string>com.example.demo</string>', plist) > 0,
    'the bundle identifier is not the descriptor''s');
  Check(Pos('<string>demo</string>', plist) > 0,
    'the executable name is not the program identifier');
  Check(Pos('<string>0.1.0</string>', plist) > 0,
    'the version is not the descriptor''s');
  Check(Pos('<string>' + PWEB_CLI_MACOS_MIN + '</string>', plist) > 0,
    'LSMinimumSystemVersion is not the ratified floor');
  Check(Pos('<true/>', plist) > 0, 'the high-resolution key is missing');
  Check(plist[Length(plist)] = #10, 'the plist has no final newline');
  Check(Pos(#13, plist) = 0, 'the plist carries a carriage return');
end;

procedure TTestPWebPipePure.RedactionProjection;
var
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  tools: TPWebCliToolset;
  prefixes, tokens: TRawUtf8DynArray;
  text: RawUtf8;
begin
  project := FixtureProject(puiReact);
  sdk := FixtureSdk(pcoWindows, pcaX86_64, {Pas2js=}False);
  tools := FixtureTools(sdk);
  PWebCliPipeRedactions(project, sdk, tools, prefixes, tokens);
  // the executable is redacted BEFORE the directory that contains it, so a
  // nested root can never be masked by its parent
  text := PWebCliRedact(tools.Npm.Script, prefixes, tokens);
  CheckEqual(text, '<npm-cli>', 'the npm entry point is not redacted first');
  text := PWebCliRedact(PWebCliJoin(sdk.Root, 'anything'), prefixes, tokens);
  CheckEqual(text, '<sdk>/anything', 'the SDK root is not redacted');
  text := PWebCliRedact(PWebCliJoin(project.Root, 'src'), prefixes, tokens);
  CheckEqual(text, '<root>/src', 'the project root is not redacted');
  Record_('pipe|redact|<npm-cli>,<sdk>/anything,<root>/src');
end;

procedure TTestPWebPipePure.MutationSetAndExits;
var
  project: TPWebCliProject;
  set_: TRawUtf8DynArray;
  k: TPWebCliStageKind;
  line: RawUtf8;
begin
  project := FixtureProject(puiReact);
  set_ := PWebCliMutationSet(project);
  CheckEqual(Length(set_), 4, 'the mutation set is not the ratified four');
  CheckEqual(set_[0], 'frontend/.pweb', 'the staged SDK prefix moved');
  CheckEqual(set_[1], 'frontend/node_modules', 'the install prefix moved');
  CheckEqual(set_[2], 'frontend/dist', 'the build prefix moved');
  CheckEqual(set_[3], 'dist', 'the output prefix moved');
  Record_('pipe|mutation_set|' + set_[0] + ',' + set_[1] + ',' + set_[2] +
    ',' + set_[3]);
  // the exit mapping, stated once and pinned here
  CheckEqual(PWebCliPipeExitCode(ppcOk), 0);
  CheckEqual(PWebCliPipeExitCode(ppcUsage), 2);
  CheckEqual(PWebCliPipeExitCode(ppcProject), 3);
  CheckEqual(PWebCliPipeExitCode(ppcUnavailable), 4);
  CheckEqual(PWebCliPipeExitCode(ppcStageFailed), 5);
  CheckEqual(PWebCliPipeExitCode(ppcInternal), 6);
  Record_('pipe|exits|0,2,3,4,5,6');
  line := '';
  for k := Low(TPWebCliStageKind) to High(TPWebCliStageKind) do
  begin
    if line <> '' then
      line := line + ',';
    line := line + PWebCliStageName(k);
  end;
  CheckEqual(line, 'open,toolchain,stage_sdk,install,typecheck,build,pack,' +
    'compile,layout,verify', 'the stage order moved');
  Record_('pipe|stages|' + line);
end;

procedure TTestPWebPipePure.BytewiseOrderAndPrefixes;
var
  names, prefixes: TRawUtf8DynArray;
begin
  // MEASURED on CAP-10B1's hosted run 33126638202: a culture-aware
  // comparison orders these one way and a byte comparison the other, and
  // that disagreement alone made a four-target digest unsatisfiable
  SetLength(names, 4);
  names[0] := 'app.css';
  names[1] := 'App.tsx';
  names[2] := 'main.tsx';
  names[3] := 'Zed.ts';
  PWebCliSortBytewise(names);
  CheckEqual(names[0], 'App.tsx', 'uppercase does not sort first bytewise');
  CheckEqual(names[1], 'Zed.ts');
  CheckEqual(names[2], 'app.css');
  CheckEqual(names[3], 'main.tsx');
  Record_('pipe|order|App.tsx,Zed.ts,app.css,main.tsx');

  SetLength(prefixes, 1);
  prefixes[0] := 'frontend/dist';
  Check(PWebCliUnderAnyPrefix('frontend/dist', prefixes),
    'the prefix itself is not excluded');
  Check(PWebCliUnderAnyPrefix('frontend/dist/assets/app.js', prefixes),
    'a file under the prefix is not excluded');
  Check(not PWebCliUnderAnyPrefix('frontend/dist-backup/x', prefixes),
    'the exclusion is not on a component boundary');
  Check(not PWebCliUnderAnyPrefix('frontend/dis', prefixes),
    'a shorter sibling is excluded');
  Record_('pipe|exclude|component_boundary=true');
end;


{ TTestPWebPipeFs }

procedure TTestPWebPipeFs.SdkLayoutRefusals;
var
  root, share, tree, src, sdkDir, deps, mormot, statics, lib, libRoot, bin,
    platformDir, platformName, dummy: RawUtf8;
  refusal: TPWebCliStageRefusal;
  layout: TPWebSdkLayout;
  os_: TPWebCliOs;
  arch: TPWebCliArch;
  i: PtrInt;

  procedure Step(const Expect: TPWebSdkLayoutRefusal; const Tag: RawUtf8);
  begin
    layout := PWebCliSdkLayoutIn(root, os_, arch, {Pas2js=}False);
    Check(layout.Refusal = Expect,
      Tag + ': expected ' + PWebSdkLayoutRefusalText(Expect) + ', got ' +
      PWebSdkLayoutRefusalText(layout.Refusal));
    Record_('pipe|sdk_layout|' + Tag + '|' +
      PWebSdkLayoutRefusalText(layout.Refusal));
  end;

begin
  // ONE target on every host, and macos-arm64 because it is the RICHEST
  // ladder: it is the only one that also demands the Cocoa bridge object.
  // The resolver is a pure function of a directory tree plus (Os, Arch) -
  // building the fixture is creating directories and files, which no
  // platform makes special - so running it against the HOST's target was
  // the mistake: it recorded one extra decision on macOS and made
  // pipeline_digest, a four-target equality field, unsatisfiable.
  // MEASURED on hosted run 33676507937: 45 lines on Linux, 46 on both
  // macOS targets.
  os_ := pcoMacos;
  arch := pcaArm64;
  Check(FixtureDir('sdklayout', root), 'the fixture root was not created');

  Step(pslShareTree, 'no_share');
  Check(PWebCliPipeEnsureDir(root, PWEB_SDK_SHARE, share, refusal));
  Step(pslShareTree, 'no_share_pweb');
  Check(PWebCliPipeEnsureDir(share, PWEB_SDK_SHARE_PWEB, tree, refusal));
  Step(pslSourceRoot, 'no_src');
  Check(PWebCliPipeEnsureDir(tree, PWEB_SDK_SRC, src, refusal));
  Step(pslSourceRoot, 'no_unit_dirs');
  for i := 0 to High(PWEB_SDK_UNIT_DIRS) do
    Check(PWebCliPipeEnsureDir(src, PWEB_SDK_UNIT_DIRS[i], dummy, refusal));
  Step(pslPlatformUnits, 'no_platform');
  Check(PWebCliPipeEnsureDir(src, PWEB_SDK_PLATFORM, platformDir, refusal));
  // two variables, deliberately: an `out` parameter is cleared on entry, so
  // passing one variable as both the name and the answer hands the callee an
  // empty name - which is how the first draft of this case created nothing
  // and then blamed the resolver
  case os_ of
    pcoWindows: platformName := 'windows';
    pcoMacos:   platformName := 'macos';
  else
    platformName := 'linux';
  end;
  Check(PWebCliPipeEnsureDir(platformDir, platformName, dummy, refusal));
  Step(pslTypeScriptSdk, 'no_sdk_dir');
  Check(PWebCliPipeEnsureDir(tree, PWEB_SDK_SDK, sdkDir, refusal));
  Step(pslTypeScriptSdk, 'no_typescript');
  Check(PWebCliPipeEnsureDir(sdkDir, PWEB_SDK_TYPESCRIPT, dummy, refusal));
  Step(pslTypeScriptSdk, 'no_ts_manifest');
  Check(WriteFixtureFile(dummy, PWEB_SDK_TS_MANIFEST, '{}'));
  Step(pslMormotSource, 'no_deps');
  Check(PWebCliPipeEnsureDir(tree, PWEB_SDK_DEPS, deps, refusal));
  Check(PWebCliPipeEnsureDir(deps, PWEB_SDK_MORMOT, mormot, refusal));
  Step(pslMormotSource, 'no_mormot_src');
  Check(PWebCliPipeEnsureDir(mormot, PWEB_SDK_SRC, dummy, refusal));
  Step(pslMormotStatic, 'no_statics');
  Check(PWebCliPipeEnsureDir(mormot, PWEB_SDK_STATIC, statics, refusal));
  Step(pslMormotStatic, 'no_target_statics');
  Check(PWebCliPipeEnsureDir(statics, PWebCliFpcTargetName(os_, arch),
    dummy, refusal));
  Step(pslPlatformLib, 'no_lib');
  Check(PWebCliPipeEnsureDir(tree, PWEB_SDK_LIB, libRoot, refusal));
  Check(PWebCliPipeEnsureDir(libRoot, PWebCliRunTargetName(os_, arch), lib,
    refusal));
  Step(pslWebviewLib, 'no_webview_lib');
  Check(WriteFixtureFile(lib, PWebCliWebviewLibName(os_), 'x'));
  if os_ = pcoMacos then
  begin
    Step(pslMacosBridge, 'no_bridge');
    Check(WriteFixtureFile(lib, PWEB_CLI_MACOS_BRIDGE_OBJ, 'x'));
  end;
  Step(pslBundler, 'no_bin');
  Check(PWebCliPipeEnsureDir(root, PWEB_SDK_BIN, bin, refusal));
  Step(pslBundler, 'no_bundler');
  dummy := PWEB_SDK_BUNDLER;
  if os_ = pcoWindows then
    dummy := dummy + PWEB_CLI_RUN_WINDOWS_EXT;
  Check(WriteFixtureFile(bin, dummy, 'x'));
  Step(pslNone, 'complete');
  Check(layout.Refusal = pslNone, 'a complete SDK root was refused');
  Check(layout.MormotStatic <> '', 'the statics were not resolved');
  Check(Length(layout.UnitDirs) = Length(PWEB_SDK_UNIT_DIRS) + 1,
    'the six unit directories are not six');
end;

procedure TTestPWebPipeFs.NpmEntryPointRule;
var
  root, binDir, libDir, nm, npmDir, npmBin, dummy: RawUtf8;
  refusal: TPWebCliStageRefusal;
  script: RawUtf8;
begin
  Check(FixtureDir('npmrule', root), 'the fixture root was not created');

  // the WINDOWS shape: <D>\node_modules\npm\bin\npm-cli.js beside node.exe
  Check(PWebCliPipeEnsureDir(root, 'win', binDir, refusal));
  Check(WriteFixtureFile(binDir, 'node.exe', 'x'));
  Check(not PWebCliResolveNpmCli(PWebCliJoin(binDir, 'node.exe'),
    {Windows=}True, script), 'an absent entry point resolved');
  Record_('pipe|npm_cli|windows_absent|refused');
  Check(PWebCliPipeEnsureDir(binDir, PWEB_NPM_NODE_MODULES, nm, refusal));
  Check(PWebCliPipeEnsureDir(nm, PWEB_NPM_DIR, npmDir, refusal));
  Check(PWebCliPipeEnsureDir(npmDir, PWEB_NPM_BIN, npmBin, refusal));
  Check(WriteFixtureFile(npmBin, PWEB_NPM_CLI, '//'));
  Check(PWebCliResolveNpmCli(PWebCliJoin(binDir, 'node.exe'),
    {Windows=}True, script), 'the Windows rule did not resolve');
  CheckEqual(script, PWebCliJoin(npmBin, PWEB_NPM_CLI),
    'the Windows rule resolved somewhere else');
  Record_('pipe|npm_cli|windows|node_modules/npm/bin/npm-cli.js');

  // the POSIX shape: parent(<D>)/lib/node_modules/npm/bin/npm-cli.js
  Check(PWebCliPipeEnsureDir(root, 'posix', dummy, refusal));
  Check(PWebCliPipeEnsureDir(dummy, 'bin', binDir, refusal));
  Check(WriteFixtureFile(binDir, 'node', 'x'));
  Check(not PWebCliResolveNpmCli(PWebCliJoin(binDir, 'node'),
    {Windows=}False, script), 'an absent POSIX entry point resolved');
  Check(PWebCliPipeEnsureDir(dummy, PWEB_NPM_LIB, libDir, refusal));
  Check(PWebCliPipeEnsureDir(libDir, PWEB_NPM_NODE_MODULES, nm, refusal));
  Check(PWebCliPipeEnsureDir(nm, PWEB_NPM_DIR, npmDir, refusal));
  Check(PWebCliPipeEnsureDir(npmDir, PWEB_NPM_BIN, npmBin, refusal));
  Check(WriteFixtureFile(npmBin, PWEB_NPM_CLI, '//'));
  Check(PWebCliResolveNpmCli(PWebCliJoin(binDir, 'node'),
    {Windows=}False, script), 'the POSIX rule did not resolve');
  CheckEqual(script, PWebCliJoin(npmBin, PWEB_NPM_CLI),
    'the POSIX rule resolved somewhere else');
  Record_('pipe|npm_cli|posix|lib/node_modules/npm/bin/npm-cli.js');
end;

procedure TTestPWebPipeFs.TreeDigestAndExclusions;
var
  root, sub, excluded, dummy: RawUtf8;
  refusal: TPWebCliStageRefusal;
  excludes: TRawUtf8DynArray;
  first, second, changed, lines: RawUtf8;
  files: Integer;
begin
  Check(FixtureDir('treedigest', root), 'the fixture root was not created');
  Check(WriteFixtureFile(root, 'pweb.json', '{}'));
  Check(PWebCliPipeEnsureDir(root, 'src', sub, refusal));
  Check(WriteFixtureFile(sub, 'app.pas', 'unit app;'));
  Check(WriteFixtureFile(sub, 'App.pas2', 'unit app2;'));
  Check(PWebCliPipeEnsureDir(root, 'dist', excluded, refusal));
  Check(WriteFixtureFile(excluded, 'noise.bin', 'noise'));
  SetLength(excludes, 1);
  excludes[0] := 'dist';

  Check(PWebCliPipeTreeDigest(root, excludes, first, refusal),
    'the tree digest failed: ' + PWebCliStageRefusalText(refusal));
  // an excluded subtree may change all it likes
  Check(WriteFixtureFile(excluded, 'more.bin', 'more'));
  Check(PWebCliPipeTreeDigest(root, excludes, second, refusal));
  CheckEqual(first, second, 'an excluded change moved the digest');
  Record_('pipe|digest|excluded_change|stable');
  // a change OUTSIDE it must move it
  Check(WriteFixtureFile(sub, 'new.pas', 'unit new;'));
  Check(PWebCliPipeTreeDigest(root, excludes, changed, refusal));
  Check(changed <> first, 'a real change did not move the digest');
  Record_('pipe|digest|real_change|moved');
  // the projection names every file it counted, once
  Check(PWebCliPipeTreeLines(root, excludes, lines, files, refusal));
  CheckEqual(files, 4, 'the walk counted the wrong number of files');
  Check(Pos('dist/'#10, lines) = 0, 'an excluded path reached the lines');
  Check(Pos('src/App.pas2', lines) > 0, 'a file is missing from the lines');
  dummy := Copy(lines, 1, Pos(#10, lines) - 1);
  Check(Pos('pweb.json|', dummy) > 0,
    'the lines are not bytewise-ordered: ' + dummy);
end;

procedure TTestPWebPipeFs.StageTsSdkIsFresh;
var
  root, src, dist, distSrc, destParent, staged, dummyDir: RawUtf8;
  refusal: TPWebCliStageRefusal;
  files: Integer;
  content: RawByteString;
  tooBig: Boolean;
begin
  Check(FixtureDir('stagesdk', root), 'the fixture root was not created');
  Check(PWebCliPipeEnsureDir(root, 'source', src, refusal));
  Check(WriteFixtureFile(src, 'package.json',
    '{"name":"@pweb/runtime","version":"0.1.0","license":"MIT",' +
    '"type":"module","main":"./dist/src/index.js",' +
    '"types":"./dist/src/index.d.ts","exports":{".":{"default":"./x.js"}},' +
    '"devDependencies":{"typescript":"7.0.2"}}'));
  Check(PWebCliPipeEnsureDir(src, 'dist', dist, refusal));
  Check(PWebCliPipeEnsureDir(dist, 'src', distSrc, refusal));
  Check(WriteFixtureFile(distSrc, 'index.js', 'export const a = 1;'#10));
  Check(WriteFixtureFile(distSrc, 'index.d.ts', 'export declare const a: number;'#10));
  // a test build that must NOT be shipped: a `file:` dependency is linked
  // rather than packed, so the package's own `files` field filters nothing
  Check(PWebCliPipeEnsureDir(dist, 'test', dummyDir, refusal));
  Check(WriteFixtureFile(dummyDir, 'capture.js', '// a test'));

  Check(PWebCliPipeEnsureDir(root, 'dest', destParent, refusal));
  // a STALE tree at the destination, with a declaration nothing produces
  Check(PWebCliPipeEnsureDir(destParent, 'typescript', staged, refusal));
  Check(WriteFixtureFile(staged, 'STALE.d.ts', 'export declare const gone: 1;'));

  Check(PWebCliStageTsSdk(src, destParent, 'typescript', files, refusal),
    'staging failed: ' + PWebCliStageRefusalText(refusal));
  staged := PWebCliJoin(destParent, 'typescript');
  Check(PWebCliEntry(staged, 'STALE.d.ts') = pcnMissing,
    'a STALE file survived the staging: the destination was MERGED');
  Record_('pipe|stage_sdk|stale_removed|true');
  Check(PWebCliEntry(staged, 'package.json') = pcnFile,
    'the canonical manifest was not written');
  Check(PWebCliReadSmallFile(PWebCliJoin(staged, 'package.json'),
    65536, content, tooBig));
  Check(Pos('devDependencies', RawUtf8(content)) = 0,
    'a development dependency reached the distribution manifest');
  Check(PWebCliEntry(PWebCliJoin(PWebCliJoin(staged, 'dist'), 'src'),
    'index.js') = pcnFile, 'dist/src was not copied');
  Check(PWebCliEntry(PWebCliJoin(staged, 'dist'), 'test') = pcnMissing,
    'dist/test was staged: a test would ship inside an SDK');
  Record_('pipe|stage_sdk|dist_test_excluded|true');
  CheckEqual(files, 3, 'the staged file count is wrong');
end;

procedure TTestPWebPipeFs.Pas2jsNormalisation;
var
  root, dist, assets: RawUtf8;
  refusal: TPWebCliStageRefusal;
  fe: TPWebCliFrontendRefusal;
  norm: TPWebCliPas2jsNormalisation;
  content: RawByteString;
  tooBig: Boolean;
begin
  Check(FixtureDir('pas2jsnorm', root), 'the fixture root was not created');
  Check(WriteFixtureFile(root, PWEB_FE_INDEX, '<html></html>'#10));
  Check(WriteFixtureFile(root, PWEB_FE_APP_CSS, 'body{}'#10));
  Check(PWebCliPipeEnsureDir(root, 'out', dist, refusal));
  Check(PWebCliPipeEnsureDir(dist, PWEB_FE_ASSETS, assets, refusal));
  // exactly what the Windows compiler emits: a UTF-8 BOM, CRLF, and one
  // LONE CR that a CRLF-only rule would leave behind
  Check(WriteFixtureFile(assets, PWEB_FE_APP_JS,
    #$EF#$BB#$BF'rtl.module("a");'#13#10'var x = 1;'#13'var y = 2;'#10));

  Check(PWebCliAssemblePas2jsDist(root, dist, norm, fe),
    'the assembly failed: ' + PWebCliFrontendRefusalText(fe));
  Check(norm.HadBom, 'the BOM was not detected');
  Check(norm.HadCr, 'the carriage returns were not detected');
  Check(PWebCliReadSmallFile(PWebCliJoin(assets, PWEB_FE_APP_JS), 65536,
    content, tooBig));
  Check(Pos(#13, RawUtf8(content)) = 0,
    'a carriage return survived - including the LONE one');
  Check(Copy(RawUtf8(content), 1, 3) <> #$EF#$BB#$BF,
    'the BOM survived');
  Record_('pipe|pas2js_normalise|bom_stripped=true|every_cr_removed=true');
  Check(PWebCliReadSmallFile(PWebCliJoin(assets, PWEB_FE_BOOT_JS), 65536,
    content, tooBig));
  CheckEqual(RawUtf8(content), PWEB_FE_BOOT_TEXT,
    'the bootstrap is not byte-exact');
  Check(PWebCliEntry(dist, PWEB_FE_INDEX) = pcnFile,
    'index.html was not placed');
  Check(PWebCliEntry(assets, PWEB_FE_APP_CSS) = pcnFile,
    'app.css was not placed');
  Record_('pipe|pas2js_assembly|index.html,assets/app.js,assets/app.css,' +
    'assets/boot.js');
end;

procedure TTestPWebPipeFs.RegistryOverrideRefused;
var
  root, frontend, nm: RawUtf8;
  refusal: TPWebCliStageRefusal;
  found: RawUtf8;
  unreadable: Boolean;
  excludes: TRawUtf8DynArray;
  project: TPWebCliProject;
begin
  Check(FixtureDir('registry', root), 'the fixture root was not created');
  // the writable set comes from the DESCRIPTOR, never from literals here: a
  // project whose frontend.root is not  still has its own
  // node_modules excluded
  project := FixtureProject(puiReact);
  excludes := PWebCliMutationSet(project);
  Check(WriteFixtureFile(root, 'pweb.json', '{}'));
  Check(PWebCliPipeEnsureDir(root, 'frontend', frontend, refusal));
  Check(WriteFixtureFile(frontend, 'package.json', '{}'));
  Check(not PWebCliRegistryOverridePresent(root, excludes, found, unreadable),
    'a clean project was reported as carrying a registry override');
  // one inside node_modules is npm's own business and is NOT the project's
  Check(PWebCliPipeEnsureDir(frontend, PWEB_FE_NODE_MODULES, nm, refusal));
  Check(WriteFixtureFile(nm, '.npmrc', 'registry=http://evil'));
  Check(not PWebCliRegistryOverridePresent(root, excludes, found, unreadable),
    'an .npmrc inside node_modules was treated as the project''s');
  Record_('pipe|registry|node_modules_ignored|true');
  // one the project carries is a REFUSAL
  Check(WriteFixtureFile(frontend, '.npmrc', 'registry=http://evil'));
  Check(PWebCliRegistryOverridePresent(root, excludes, found, unreadable),
    'a project .npmrc was not detected');
  CheckEqual(found, 'frontend/.npmrc', 'the wrong path was named');
  Check(not unreadable, 'a readable tree was reported unreadable');
  Record_('pipe|registry|fail_closed|unreadable_is_a_refusal');
  Record_('pipe|registry|project_npmrc|refused');
end;

end.
