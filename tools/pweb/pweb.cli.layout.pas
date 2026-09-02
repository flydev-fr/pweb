{
  pweb.cli.layout - assembling the CAP-10C0 run layout (CAP-10C1).

  CAP-10C0 froze what `pweb run` resolves. This unit produces exactly that
  and nothing else:

      <root>/<output>/<os>-<arch>/release/

        windows, linux    <ident>[.exe]  app.pwb  <webview library>
        macos             <ident>.app/Contents/MacOS/<ident>
                          <ident>.app/Contents/MacOS/<webview library>
                          <ident>.app/Contents/Resources/app.pwb
                          <ident>.app/Contents/Info.plist

  The logical paths are NOT restated here: PWebCliRunLogicalLayout is the one
  place the rule lives, and the verification step below re-resolves the
  committed directory through the CAP-10C0 resolver itself. A layout this
  unit assembled and the run command refuses is a defect this unit must
  discover, not one a user should.

  ---------------------------------------------------------------------------
  TEMP AND RENAME, AS CAP-10B0 DOES IT
  ---------------------------------------------------------------------------

  A release is assembled in a sibling `.pweb-release.tmp` and committed by a
  rename that must not replace. A build that failed, or one interrupted at
  any point, therefore leaves NO release directory rather than a partial one
  - which matters because `pweb run` reads a layout by walking it, and a
  half-populated release is a layout that resolves and then does not work.

  When a release is already there the commit is: rename the old one aside to
  `.pweb-old.tmp`, rename the new one into place, then reclaim the old. The
  only intermediate state is NO release, which `pweb run` reports as
  `not_built` - a correct, honest answer - and never a mixture of two builds.
  Nothing is ever removed except a directory this pipeline itself created,
  through PWebCliRemoveStagedTree, which refuses a link, a device or
  anything unremovable anywhere in the tree.

  ---------------------------------------------------------------------------
  Info.plist
  ---------------------------------------------------------------------------

  macOS keys persistent WKWebView state by bundle identifier, so an
  unbundled executable has none and a .app is not decoration. Every value
  comes from the descriptor the developer wrote - the identity is stated
  once, at create time, and travels to the platform unchanged - and none of
  them can carry an XML metacharacter: schema 1's grammars are
  `^[a-z][a-z0-9]*$` for the program identifier,
  `^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$` for the bundle identifier and
  strict X.Y.Z for the version. That is why there is no escaper here: there
  is nothing in the input alphabet to escape, and an escaper over an
  alphabet that cannot need one is a false reassurance.

  LSMinimumSystemVersion is PWEB_CLI_MACOS_MIN, the same constant the
  compile passes as -WM and the doctor compares against, cross-checked in CI
  against webview.lock `macos-deployment-target`.
}
unit pweb.cli.layout;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.run,
  pweb.cli.stage,
  pweb.cli.sdkroot;

const
  /// the sibling the release is built in, and the one an old release is
  // renamed aside to - both dot-leading, both under <output>/<target>
  PWEB_LAYOUT_STAGE = '.pweb-release.tmp';
  PWEB_LAYOUT_OLD = '.pweb-old.tmp';

type
  /// why a release could not be assembled - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebCliLayoutRefusal = (
    plrNone,
    /// an input the assembly needs (executable, bundle, library) is absent
    plrInputMissing,
    /// a directory of the staged layout could not be created
    plrStageDir,
    /// a file could not be copied into the staged layout
    plrStageCopy,
    /// the previous release could not be moved aside or reclaimed
    plrReclaim,
    /// the rename that commits the assembly failed
    plrCommit,
    /// the committed layout is not one the CAP-10C0 resolver accepts
    plrVerify);

  /// what one assembly produced
  TPWebCliLayoutResult = record
    Refusal: TPWebCliLayoutRefusal;
    /// the logical path that caused a refusal, never an absolute one
    Detail: RawUtf8;
    /// the committed release directory (native), '' on any failure
    ReleaseDir: RawUtf8;
    /// how many files it holds
    Files: Integer;
    /// the CAP-10C0 resolver's own verdict on the committed layout
    RunRefusal: TPWebCliRunRefusal;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliLayoutRefusalText(Refusal: TPWebCliLayoutRefusal): RawUtf8;

/// the Info.plist bytes for one project - a pure function of the descriptor
function PWebCliInfoPlist(const Project: TPWebCliProject): RawUtf8;

/// assemble, commit and verify the release layout
// - ExePath, BundlePath and Sdk.WebviewLib are the three inputs; TargetDir
// is <root>/<output>/<os>-<arch>, which must already exist
function PWebCliAssembleRelease(const Project: TPWebCliProject;
  const Sdk: TPWebSdkLayout; Os: TPWebCliOs; Arch: TPWebCliArch;
  const TargetDir, ExePath, BundlePath: RawUtf8): TPWebCliLayoutResult;


implementation

function PWebCliLayoutRefusalText(Refusal: TPWebCliLayoutRefusal): RawUtf8;
begin
  case Refusal of
    plrNone:         Result := 'ok';
    plrInputMissing: Result := 'layout_input_missing';
    plrStageDir:     Result := 'layout_stage_dir_failed';
    plrStageCopy:    Result := 'layout_stage_copy_failed';
    plrReclaim:      Result := 'layout_reclaim_failed';
    plrCommit:       Result := 'layout_commit_failed';
    plrVerify:       Result := 'layout_verify_failed';
  else
    Result := 'layout_refused';
  end;
end;

function PWebCliInfoPlist(const Project: TPWebCliProject): RawUtf8;
begin
  // tab-indented, exactly as the CAP-7M2 and CAP-10B1 harnesses emit it, so
  // a reader diffing the two sees no cosmetic noise
  Result :=
    '<?xml version="1.0" encoding="UTF-8"?>'#10 +
    '<plist version="1.0">'#10 +
    '<dict>'#10 +
    #9'<key>CFBundleExecutable</key>'#10 +
    #9'<string>' + Project.ProgramIdent + '</string>'#10 +
    #9'<key>CFBundleIdentifier</key>'#10 +
    #9'<string>' + Project.BundleId + '</string>'#10 +
    #9'<key>CFBundleName</key>'#10 +
    #9'<string>' + Project.ProgramIdent + '</string>'#10 +
    #9'<key>CFBundlePackageType</key>'#10 +
    #9'<string>APPL</string>'#10 +
    #9'<key>CFBundleShortVersionString</key>'#10 +
    #9'<string>' + Project.Version + '</string>'#10 +
    #9'<key>CFBundleVersion</key>'#10 +
    #9'<string>' + Project.Version + '</string>'#10 +
    #9'<key>LSMinimumSystemVersion</key>'#10 +
    #9'<string>' + PWEB_CLI_MACOS_MIN + '</string>'#10 +
    #9'<key>NSHighResolutionCapable</key>'#10 +
    #9'<true/>'#10 +
    '</dict>'#10 +
    '</plist>'#10;
end;

function PWebCliAssembleRelease(const Project: TPWebCliProject;
  const Sdk: TPWebSdkLayout; Os: TPWebCliOs; Arch: TPWebCliArch;
  const TargetDir, ExePath, BundlePath: RawUtf8): TPWebCliLayoutResult;
var
  stageDir, appDir, contents, macosDir, resDir, exeName, libName: RawUtf8;
  stage: TPWebCliStageRefusal;
  layout: TPWebCliRunLayout;
  hadOld: Boolean;

  function Fail(R: TPWebCliLayoutRefusal;
    const Detail: RawUtf8): TPWebCliLayoutResult;
  begin
    Result := Default(TPWebCliLayoutResult);
    Result.Refusal := R;
    Result.Detail := Detail;
    // whatever was staged is reclaimed: a failed assembly leaves no
    // half-written directory anywhere, not even a hidden one
    PWebCliPipeRemoveTree(TargetDir, PWEB_LAYOUT_STAGE, stage);
  end;

begin
  Result := Default(TPWebCliLayoutResult);
  exeName := Project.ProgramIdent;
  if Os = pcoWindows then
    exeName := exeName + PWEB_CLI_RUN_WINDOWS_EXT;
  libName := PWebCliWebviewLibName(Os);

  // the three inputs, checked BEFORE anything is created
  if (PWebCliNodeKind(ExePath) <> pcnFile) or
     (PWebCliNodeKind(BundlePath) <> pcnFile) or
     (PWebCliNodeKind(Sdk.WebviewLib) <> pcnFile) then
  begin
    Result := Fail(plrInputMissing, exeName);
    exit;
  end;

  // a fresh staging sibling
  if not PWebCliPipeRemoveTree(TargetDir, PWEB_LAYOUT_STAGE, stage) then
  begin
    Result := Fail(plrStageDir, PWEB_LAYOUT_STAGE);
    exit;
  end;
  if not PWebCliPipeEnsureDir(TargetDir, PWEB_LAYOUT_STAGE, stageDir,
       stage) then
  begin
    Result := Fail(plrStageDir, PWEB_LAYOUT_STAGE);
    exit;
  end;

  if Os = pcoMacos then
  begin
    if not PWebCliPipeEnsureDir(stageDir,
         Project.ProgramIdent + PWEB_CLI_RUN_APP_SUFFIX, appDir, stage) or
       not PWebCliPipeEnsureDir(appDir, PWEB_CLI_RUN_CONTENTS, contents,
         stage) or
       not PWebCliPipeEnsureDir(contents, PWEB_CLI_RUN_MACOS, macosDir,
         stage) or
       not PWebCliPipeEnsureDir(contents, PWEB_CLI_RUN_RESOURCES, resDir,
         stage) then
    begin
      Result := Fail(plrStageDir, PWEB_CLI_RUN_CONTENTS);
      exit;
    end;
    if not PWebCliPipeCopyFile(ExePath, PWebCliJoin(macosDir, exeName),
         stage) or
       not PWebCliPipeCopyFile(Sdk.WebviewLib,
         PWebCliJoin(macosDir, libName), stage) or
       not PWebCliPipeCopyFile(BundlePath,
         PWebCliJoin(resDir, PWEB_CLI_RUN_BUNDLE), stage) then
    begin
      Result := Fail(plrStageCopy, exeName);
      exit;
    end;
    if not PWebCliWriteNewFile(
         PWebCliJoin(contents, PWEB_CLI_RUN_PLIST),
         RawByteString(PWebCliInfoPlist(Project)), {SetExecBit=}False) then
    begin
      Result := Fail(plrStageCopy, PWEB_CLI_RUN_PLIST);
      exit;
    end;
    Result.Files := 4;
  end
  else
  begin
    if not PWebCliPipeCopyFile(ExePath, PWebCliJoin(stageDir, exeName),
         stage) or
       not PWebCliPipeCopyFile(BundlePath,
         PWebCliJoin(stageDir, PWEB_CLI_RUN_BUNDLE), stage) or
       not PWebCliPipeCopyFile(Sdk.WebviewLib,
         PWebCliJoin(stageDir, libName), stage) then
    begin
      Result := Fail(plrStageCopy, exeName);
      exit;
    end;
    Result.Files := 3;
  end;

  // THE COMMIT. The old release is moved aside first, so the only moment
  // without a usable release is the instant between two renames - and never
  // a moment with a mixture of two builds
  hadOld := PWebCliEntry(TargetDir, PWEB_CLI_RUN_RELEASE) = pcnDirectory;
  if hadOld then
  begin
    if not PWebCliPipeRemoveTree(TargetDir, PWEB_LAYOUT_OLD, stage) then
    begin
      Result := Fail(plrReclaim, PWEB_LAYOUT_OLD);
      exit;
    end;
    if not PWebCliRenameDir(
         PWebCliJoin(TargetDir, PWEB_CLI_RUN_RELEASE),
         PWebCliJoin(TargetDir, PWEB_LAYOUT_OLD)) then
    begin
      Result := Fail(plrReclaim, PWEB_CLI_RUN_RELEASE);
      exit;
    end;
  end;
  if not PWebCliRenameDir(stageDir,
       PWebCliJoin(TargetDir, PWEB_CLI_RUN_RELEASE)) then
  begin
    // put the old one back rather than leave the project with neither
    if hadOld then
      PWebCliRenameDir(PWebCliJoin(TargetDir, PWEB_LAYOUT_OLD),
        PWebCliJoin(TargetDir, PWEB_CLI_RUN_RELEASE));
    Result := Fail(plrCommit, PWEB_CLI_RUN_RELEASE);
    exit;
  end;
  if hadOld then
    PWebCliPipeRemoveTree(TargetDir, PWEB_LAYOUT_OLD, stage);

  // THE VERIFICATION IS THE RUN COMMAND'S OWN RESOLVER, not a re-statement
  // of its rule. A layout this unit assembled and `pweb run` refuses is a
  // defect that belongs here, and it is found here
  layout := PWebCliResolveRunLayout(Project, Os, Arch);
  Result.RunRefusal := layout.Refusal;
  if layout.Refusal <> prrNone then
  begin
    Result.Refusal := plrVerify;
    Result.Detail := PWebCliRunRefusalText(layout.Refusal);
    exit;
  end;
  Result.ReleaseDir := PWebCliJoin(TargetDir, PWEB_CLI_RUN_RELEASE);
  Result.Refusal := plrNone;
end;

end.
