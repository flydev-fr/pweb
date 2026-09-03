{
  pweb.cli.devlayout - the development layout, and the immutable generation
  (CAP-10C2).

  A PURE PLAN plus the file operations that realise it, over the CAP-10C1
  primitives in pweb.cli.stage and the CAP-10B0 primitives beneath them.
  Nothing here spawns a child, reads the environment or carries a platform
  conditional: the target arrives as (TPWebCliOs, TPWebCliArch) and every
  branch is ordinary runtime code, so the whole four-target layout can be
  asserted from any single target - the CAP-10C1 property, kept.

  ---------------------------------------------------------------------------
  THE LAYOUT
  ---------------------------------------------------------------------------

    <root>/<output>/<os>-<arch>/dev/
      app/            the dev binary and the webview library
                      (macOS: <ident>.app/Contents/MacOS plus Info.plist -
                      and NO Contents/Resources, see PWebCliDevStageApp)
      units/  obj/    the DEV compiler outputs, separate from the release's
      .gen.tmp/       ONE generation under construction - never published
      gen-1/ gen-2/ … app.pwb, immutable, published by ONE rename

  IT LIVES BESIDE `release/` AND NEVER INSIDE IT. `pweb run` resolves
  PWEB_CLI_RUN_RELEASE and nothing else, so no development artifact is
  reachable from the production command however this directory grows; and
  the dev compile's -FU/-FE point HERE, so the release build's compiled unit
  set is never polluted by a unit compiled with -dPWEB_DEV. That is what
  turns "the release binary does not carry the dev unit" from an inference
  into a directory listing.

  ---------------------------------------------------------------------------
  A GENERATION IS IMMUTABLE, AND PUBLISHED BY ONE RENAME
  ---------------------------------------------------------------------------

  Everything a generation will hold is assembled inside `.gen.tmp`, and the
  publish is exactly one PWebCliRenameDir onto `gen-N` - which MUST NOT
  REPLACE, and does not, on any of the four targets. Nothing ever writes
  into a published generation.

  THERE IS NO `current` POINTER FILE, deliberately. A pointer needs a
  replacing rename, which this repository does not have (the host's own
  verdict writer records that RenameFile does not replace on Windows and
  deletes first, a window this design must not have); and a pointer can be
  read torn, which a directory rename cannot be. The reader counts FORWARD
  instead, which needs no pointer at all.

  ---------------------------------------------------------------------------
  CLEANUP IS BOUNDED, AND ONLY EVER BACKWARDS
  ---------------------------------------------------------------------------

  On generation N acknowledged, gen-M for M <= N - PWEB_CLI_DEV_KEEP_GENERATIONS
  is removed through the guarded PWebCliPipeRemoveTree - a removal that
  refuses a link, a device or anything unremovable anywhere in the tree. The
  host only looks forward, so a removed generation can never be the one it is
  about to open. A `.gen.tmp` left behind by an interrupted session is
  removed at the START of the next one, which is the only moment nothing can
  be using it.
}
unit pweb.cli.devlayout;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.project,
  pweb.cli.run,
  pweb.cli.stage,
  pweb.cli.frontend,
  pweb.cli.native,
  pweb.cli.sdkroot,
  pweb.cli.layout;

type
  /// why a development layout operation was refused - one cause each
  // - ordinal 0 is the accepted state
  TPWebCliDevLayoutRefusal = (
    pdlNone,
    /// a directory of the layout could not be created
    pdlCreateDir,
    /// the previous `.gen.tmp` could not be reclaimed
    pdlTmpReclaim,
    /// a previous session's published generation could not be reclaimed
    pdlGenerationReclaim,
    /// a file could not be copied into the generation or the app directory
    pdlCopy,
    /// the publishing rename failed, or the target name was already taken
    pdlPublish,
    /// the generation counter reached PWEB_CLI_DEV_MAX_GENERATIONS
    pdlGenerationBound,
    /// an input the layout needs is absent (the dev binary, the library)
    pdlInputMissing);

  /// every path one development session uses - resolved once, at start
  TPWebCliDevLayout = record
    Refusal: TPWebCliDevLayoutRefusal;
    /// which component caused the refusal - logical, never absolute
    Detail: RawUtf8;
    /// <os>-<arch>
    Target: RawUtf8;
    /// <root>/<output>/<os>-<arch>
    TargetDir: RawUtf8;
    /// <target>/dev, and its four children
    DevDir: RawUtf8;
    AppDir: RawUtf8;
    UnitDir: RawUtf8;
    ObjDir: RawUtf8;
    TmpDir: RawUtf8;
    /// the executable the dev compile produces, in ObjDir
    BuiltExe: RawUtf8;
    /// the executable the loop LAUNCHES, inside AppDir
    LaunchExe: RawUtf8;
    /// the logical projection of LaunchExe, for a report that may never
    // name an absolute path
    LaunchLogical: RawUtf8;
    /// how many of a PREVIOUS session's published generations start-up
    // reclaimed - recorded so a report can say the disk was reused rather
    // than leaving it to be inferred from a counter that restarted at 1
    Reclaimed: Integer;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliDevLayoutRefusalText(
  Refusal: TPWebCliDevLayoutRefusal): RawUtf8;

/// the directory name of one generation - `gen-<N>`
function PWebCliDevGenerationDir(N: Integer): RawUtf8;

/// reclaim EVERY published generation a previous session left
// - a session numbers its generations from 1 and publishes each by one
// rename that must not replace, and the dev host is told to open `gen-1`,
// so a surviving `gen-1` is another session's content under the name this
// one is about to write. MEASURED: without this a second `pweb dev` on the
// same project refused at the first publish with dev_publish_failed
// - the directory is ENUMERATED and only names that are exactly the
// ratified `gen-<digits>` shape are removed, so the cost is what is on the
// disk rather than the generation ceiling, and nothing else in <dev> - not
// `app`, not `units`, not `obj` - can be matched by it
function PWebCliDevResetGenerations(const Layout: TPWebCliDevLayout;
  out Removed: Integer): Boolean;

/// resolve and CREATE the development layout beneath an existing target
/// directory, and reclaim any `.gen.tmp` an interrupted session left
// - TargetDir must already exist (the caller creates <output>/<os>-<arch>
// exactly as the C1 pipeline does)
function PWebCliDevEnsureLayout(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch;
  const TargetDir: RawUtf8): TPWebCliDevLayout;

/// place the freshly compiled dev binary and the webview library into
/// <dev>/app, in this target's shape
// - macOS gets the .app bundle with its Info.plist, because a Cocoa
// WebView needs a bundled main executable; NO app.pwb is placed anywhere,
// in any shape, because the dev host is served from the generation root
// and must never find a bundle beside itself
function PWebCliDevStageApp(const Project: TPWebCliProject;
  const Sdk: TPWebSdkLayout; Os: TPWebCliOs; Arch: TPWebCliArch;
  var Layout: TPWebCliDevLayout): Boolean;

/// begin ONE generation: a fresh, empty `.gen.tmp`
function PWebCliDevBeginGeneration(const Layout: TPWebCliDevLayout;
  out TmpDist: RawUtf8; out Refusal: TPWebCliDevLayoutRefusal): Boolean;

/// copy a completed dist/ into the generation under construction
function PWebCliDevSnapshotDist(const Layout: TPWebCliDevLayout;
  const DistDir: RawUtf8; out Files: Integer;
  out Refusal: TPWebCliDevLayoutRefusal): Boolean;

/// discard the generation under construction - a snapshot the sentinel
/// invalidated, or a pack that failed
function PWebCliDevDiscardGeneration(const Layout: TPWebCliDevLayout;
  out Refusal: TPWebCliDevLayoutRefusal): Boolean;

/// remove the copied dist/ from the generation under construction, so what
/// is published is the archive and nothing else
function PWebCliDevTrimGeneration(const Layout: TPWebCliDevLayout;
  out Refusal: TPWebCliDevLayoutRefusal): Boolean;

/// PUBLISH: one rename of `.gen.tmp` onto `gen-N`, which must not replace
function PWebCliDevPublishGeneration(const Layout: TPWebCliDevLayout;
  N: Integer; out Refusal: TPWebCliDevLayoutRefusal): Boolean;

/// the native path of the archive inside the generation under construction
function PWebCliDevTmpBundle(const Layout: TPWebCliDevLayout): RawUtf8;

/// remove every generation at or below N - PWEB_CLI_DEV_KEEP_GENERATIONS
// - answers how many were removed; a generation that was already gone is
// not an error, because the caller wants the name free rather than a removal
function PWebCliDevCleanGenerations(const Layout: TPWebCliDevLayout;
  Current: Integer): Integer;

/// True when a published generation carrying an archive exists
function PWebCliDevGenerationPresent(const Layout: TPWebCliDevLayout;
  N: Integer): Boolean;


implementation

function PWebCliDevLayoutRefusalText(
  Refusal: TPWebCliDevLayoutRefusal): RawUtf8;
begin
  case Refusal of
    pdlNone:             Result := 'ok';
    pdlCreateDir:        Result := 'dev_create_dir_failed';
    pdlTmpReclaim:       Result := 'dev_tmp_reclaim_failed';
    pdlGenerationReclaim: Result := 'dev_generation_reclaim_failed';
    pdlCopy:             Result := 'dev_copy_failed';
    pdlPublish:          Result := 'dev_publish_failed';
    pdlGenerationBound:  Result := 'dev_generation_bound';
    pdlInputMissing:     Result := 'dev_input_missing';
  else
    Result := 'dev_layout_refused';
  end;
end;

function PWebCliDevGenerationDir(N: Integer): RawUtf8;
begin
  Result := 'gen-' + RawUtf8(IntToStr(N));
end;

function PWebCliDevTmpBundle(const Layout: TPWebCliDevLayout): RawUtf8;
begin
  Result := PWebCliJoin(Layout.TmpDir, PWEB_CLI_RUN_BUNDLE);
end;

function PWebCliDevResetGenerations(const Layout: TPWebCliDevLayout;
  out Removed: Integer): Boolean;
var
  names: TRawUtf8DynArray;
  i, k: PtrInt;
  name: RawUtf8;
  digits: Boolean;
  stage: TPWebCliStageRefusal;
begin
  Removed := 0;
  Result := PWebCliListDir(Layout.DevDir, names);
  if not Result then
    // a directory that cannot be enumerated is a REFUSAL and never an empty
    // result: reporting "nothing to reclaim" for a tree nobody could read
    // is how a publish later fails on a name this walk never saw
    exit;
  for i := 0 to High(names) do
  begin
    name := names[i];
    if Copy(name, 1, Length(PWEB_CLI_DEV_GEN_PREFIX)) <>
         PWEB_CLI_DEV_GEN_PREFIX then
      continue;
    // `gen-` followed by AT LEAST ONE digit and nothing else. `gen-` alone,
    // `gen-1.bak` and `gen-x` are not generation names and are left alone:
    // this walk removes what this loop wrote, never what it merely resembles
    digits := Length(name) > Length(PWEB_CLI_DEV_GEN_PREFIX);
    for k := Length(PWEB_CLI_DEV_GEN_PREFIX) + 1 to Length(name) do
      if (name[k] < '0') or
         (name[k] > '9') then
      begin
        digits := False;
        break;
      end;
    if not digits then
      continue;
    if PWebCliEntry(Layout.DevDir, name) <> pcnDirectory then
      continue;
    if not PWebCliPipeRemoveTree(Layout.DevDir, name, stage) then
      exit(False);
    Inc(Removed);
  end;
  Result := True;
end;

function PWebCliDevEnsureLayout(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch;
  const TargetDir: RawUtf8): TPWebCliDevLayout;
var
  stage: TPWebCliStageRefusal;
  reclaimed: Integer;

  function Fail(R: TPWebCliDevLayoutRefusal;
    const Detail: RawUtf8): TPWebCliDevLayout;
  begin
    Result := Default(TPWebCliDevLayout);
    Result.Refusal := R;
    Result.Detail := Detail;
    Result.Target := PWebCliRunTargetName(Os, Arch);
  end;

begin
  Result := Default(TPWebCliDevLayout);
  Result.Target := PWebCliRunTargetName(Os, Arch);
  Result.TargetDir := TargetDir;
  if not PWebCliPipeEnsureDir(TargetDir, PWEB_CLI_DEV_DIR, Result.DevDir,
       stage) then
  begin
    Result := Fail(pdlCreateDir, PWEB_CLI_DEV_DIR);
    exit;
  end;
  if not PWebCliPipeEnsureDir(Result.DevDir, PWEB_CLI_DEV_APP_DIR,
       Result.AppDir, stage) or
     not PWebCliPipeEnsureDir(Result.DevDir, PWEB_CLI_DEV_UNIT_DIR,
       Result.UnitDir, stage) or
     not PWebCliPipeEnsureDir(Result.DevDir, PWEB_CLI_DEV_OBJ_DIR,
       Result.ObjDir, stage) then
  begin
    Result := Fail(pdlCreateDir, PWEB_CLI_DEV_APP_DIR);
    exit;
  end;
  // AN INTERRUPTED SESSION'S `.gen.tmp` IS REMOVED HERE, and only here: at
  // start-up nothing can be using it, and leaving it would make the next
  // publish fail on a name that is already taken by half a generation
  if not PWebCliPipeRemoveTree(Result.DevDir, PWEB_CLI_DEV_TMP_DIR,
       stage) then
  begin
    Result := Fail(pdlTmpReclaim, PWEB_CLI_DEV_TMP_DIR);
    exit;
  end;
  // AND SO IS EVERY PUBLISHED GENERATION THE PREVIOUS SESSION LEFT.
  //
  // MEASURED, and the reason this is not merely tidiness: a session numbers
  // its generations from 1 and publishes each by ONE rename that MUST NOT
  // REPLACE, so a second `pweb dev` on a project that already had a session
  // refused at `gen-1` with dev_publish_failed and never opened a window.
  // Numbering from the highest surviving one instead would be worse, not
  // better: the dev host is told to open `gen-1`, so a leftover `gen-1` is
  // not a stale generation of THIS session - it is a different session's
  // content under the name this one promises to write.
  //
  // Bounded by construction: the directory is ENUMERATED and only entries
  // whose name is exactly `gen-<digits>` are removed, so the cost is the
  // number of entries actually present rather than a walk over the
  // generation ceiling, and nothing outside the ratified name shape is ever
  // touched.
  // a LOCAL out-parameter: `Result` is the const argument, and handing the
  // same variable's field as the out one would alias them
  if not PWebCliDevResetGenerations(Result, reclaimed) then
  begin
    Result := Fail(pdlGenerationReclaim, PWEB_CLI_DEV_GEN_PREFIX);
    exit;
  end;
  Result.Reclaimed := reclaimed;
  Result.TmpDir := PWebCliJoin(Result.DevDir, PWEB_CLI_DEV_TMP_DIR);
  Result.BuiltExe := PWebCliJoin(Result.ObjDir,
    PWebCliNativeExeName(Project.ProgramIdent, Os));
  Result.Refusal := pdlNone;
end;

function PWebCliDevStageApp(const Project: TPWebCliProject;
  const Sdk: TPWebSdkLayout; Os: TPWebCliOs; Arch: TPWebCliArch;
  var Layout: TPWebCliDevLayout): Boolean;
var
  stage: TPWebCliStageRefusal;
  appBundle, contents, macosDir, exeName, libName: RawUtf8;
begin
  Result := False;
  exeName := PWebCliNativeExeName(Project.ProgramIdent, Os);
  libName := PWebCliWebviewLibName(Os);
  if (PWebCliNodeKind(Layout.BuiltExe) <> pcnFile) or
     (PWebCliNodeKind(Sdk.WebviewLib) <> pcnFile) then
  begin
    Layout.Refusal := pdlInputMissing;
    Layout.Detail := exeName;
    exit;
  end;
  // a FRESH app directory on every start: a stale binary beside a new one
  // is the failure this loop must never be able to have
  if not PWebCliPipeRemoveTree(Layout.DevDir, PWEB_CLI_DEV_APP_DIR,
       stage) or
     not PWebCliPipeEnsureDir(Layout.DevDir, PWEB_CLI_DEV_APP_DIR,
       Layout.AppDir, stage) then
  begin
    Layout.Refusal := pdlCreateDir;
    Layout.Detail := PWEB_CLI_DEV_APP_DIR;
    exit;
  end;
  if Os = pcoMacos then
  begin
    if not PWebCliPipeEnsureDir(Layout.AppDir,
         Project.ProgramIdent + PWEB_CLI_RUN_APP_SUFFIX, appBundle,
         stage) or
       not PWebCliPipeEnsureDir(appBundle, PWEB_CLI_RUN_CONTENTS, contents,
         stage) or
       not PWebCliPipeEnsureDir(contents, PWEB_CLI_RUN_MACOS, macosDir,
         stage) then
    begin
      Layout.Refusal := pdlCreateDir;
      Layout.Detail := PWEB_CLI_RUN_CONTENTS;
      exit;
    end;
    if not PWebCliPipeCopyFile(Layout.BuiltExe,
         PWebCliJoin(macosDir, exeName), stage) or
       not PWebCliPipeCopyFile(Sdk.WebviewLib,
         PWebCliJoin(macosDir, libName), stage) then
    begin
      Layout.Refusal := pdlCopy;
      Layout.Detail := exeName;
      exit;
    end;
    // THE ONE THING NOT COPIED, and the reason it is not: there is no
    // Contents/Resources and no app.pwb anywhere in this bundle. The dev
    // host is served from its generation root and REFUSES to start without
    // one, so a bundle beside it could only ever be a way to load the
    // wrong thing
    if not PWebCliWriteNewFile(
         PWebCliJoin(contents, PWEB_CLI_RUN_PLIST),
         RawByteString(PWebCliInfoPlist(Project)), {SetExecBit=}False) then
    begin
      Layout.Refusal := pdlCopy;
      Layout.Detail := PWEB_CLI_RUN_PLIST;
      exit;
    end;
    Layout.LaunchExe := PWebCliJoin(macosDir, exeName);
    Layout.LaunchLogical := Project.Output + '/' + Layout.Target + '/' +
      PWEB_CLI_DEV_DIR + '/' + PWEB_CLI_DEV_APP_DIR + '/' +
      Project.ProgramIdent + PWEB_CLI_RUN_APP_SUFFIX + '/' +
      PWEB_CLI_RUN_CONTENTS + '/' + PWEB_CLI_RUN_MACOS + '/' + exeName;
  end
  else
  begin
    if not PWebCliPipeCopyFile(Layout.BuiltExe,
         PWebCliJoin(Layout.AppDir, exeName), stage) or
       not PWebCliPipeCopyFile(Sdk.WebviewLib,
         PWebCliJoin(Layout.AppDir, libName), stage) then
    begin
      Layout.Refusal := pdlCopy;
      Layout.Detail := exeName;
      exit;
    end;
    Layout.LaunchExe := PWebCliJoin(Layout.AppDir, exeName);
    Layout.LaunchLogical := Project.Output + '/' + Layout.Target + '/' +
      PWEB_CLI_DEV_DIR + '/' + PWEB_CLI_DEV_APP_DIR + '/' + exeName;
  end;
  Layout.Refusal := pdlNone;
  Result := True;
end;

function PWebCliDevBeginGeneration(const Layout: TPWebCliDevLayout;
  out TmpDist: RawUtf8; out Refusal: TPWebCliDevLayoutRefusal): Boolean;
var
  stage: TPWebCliStageRefusal;
  tmp: RawUtf8;
begin
  Result := False;
  TmpDist := '';
  Refusal := pdlTmpReclaim;
  if not PWebCliPipeRemoveTree(Layout.DevDir, PWEB_CLI_DEV_TMP_DIR,
       stage) then
    exit;
  Refusal := pdlCreateDir;
  if not PWebCliPipeEnsureDir(Layout.DevDir, PWEB_CLI_DEV_TMP_DIR, tmp,
       stage) then
    exit;
  if not PWebCliPipeEnsureDir(tmp, PWEB_FE_DIST, TmpDist, stage) then
    exit;
  Refusal := pdlNone;
  Result := True;
end;

function PWebCliDevSnapshotDist(const Layout: TPWebCliDevLayout;
  const DistDir: RawUtf8; out Files: Integer;
  out Refusal: TPWebCliDevLayoutRefusal): Boolean;
var
  stage: TPWebCliStageRefusal;
  target: RawUtf8;
begin
  Files := 0;
  Refusal := pdlCopy;
  target := PWebCliJoin(Layout.TmpDir, PWEB_FE_DIST);
  Result := PWebCliPipeCopyTree(DistDir, target, Files, stage);
  if Result then
    Refusal := pdlNone;
end;

function PWebCliDevDiscardGeneration(const Layout: TPWebCliDevLayout;
  out Refusal: TPWebCliDevLayoutRefusal): Boolean;
var
  stage: TPWebCliStageRefusal;
begin
  Refusal := pdlNone;
  Result := PWebCliPipeRemoveTree(Layout.DevDir, PWEB_CLI_DEV_TMP_DIR,
    stage);
  if not Result then
    Refusal := pdlTmpReclaim;
end;

function PWebCliDevTrimGeneration(const Layout: TPWebCliDevLayout;
  out Refusal: TPWebCliDevLayoutRefusal): Boolean;
var
  stage: TPWebCliStageRefusal;
begin
  Refusal := pdlNone;
  // what is PUBLISHED is one archive and nothing else. The copied dist is
  // an input to the pack, not part of the generation, and leaving it would
  // multiply every session's disk by the size of the frontend
  Result := PWebCliPipeRemoveTree(Layout.TmpDir, PWEB_FE_DIST, stage);
  if not Result then
    Refusal := pdlTmpReclaim;
end;

function PWebCliDevPublishGeneration(const Layout: TPWebCliDevLayout;
  N: Integer; out Refusal: TPWebCliDevLayoutRefusal): Boolean;
var
  name: RawUtf8;
begin
  Result := False;
  if (N < 1) or
     (N > PWEB_CLI_DEV_MAX_GENERATIONS) then
  begin
    Refusal := pdlGenerationBound;
    exit;
  end;
  name := PWebCliDevGenerationDir(N);
  Refusal := pdlPublish;
  // the name MUST be free. PWebCliRenameDir does not replace on any of the
  // four targets, so this check is belt to its braces rather than the
  // safety itself - but a name that is taken means the counter and the disk
  // disagree, which is worth its own refusal
  if PWebCliEntry(Layout.DevDir, name) <> pcnMissing then
    exit;
  if not PWebCliRenameDir(Layout.TmpDir,
       PWebCliJoin(Layout.DevDir, name)) then
    exit;
  Refusal := pdlNone;
  Result := True;
end;

function PWebCliDevGenerationPresent(const Layout: TPWebCliDevLayout;
  N: Integer): Boolean;
var
  dir: RawUtf8;
begin
  Result := False;
  if PWebCliEntry(Layout.DevDir, PWebCliDevGenerationDir(N)) <>
       pcnDirectory then
    exit;
  dir := PWebCliJoin(Layout.DevDir, PWebCliDevGenerationDir(N));
  Result := PWebCliEntry(dir, PWEB_CLI_RUN_BUNDLE) = pcnFile;
end;

function PWebCliDevCleanGenerations(const Layout: TPWebCliDevLayout;
  Current: Integer): Integer;
var
  n, lowest: Integer;
  stage: TPWebCliStageRefusal;
begin
  Result := 0;
  // BACKWARDS ONLY, and never within the keep window. The host counts
  // forward from the generation it has, so nothing removed here can be the
  // one it is about to open
  n := Current - PWEB_CLI_DEV_KEEP_GENERATIONS;
  if n < 1 then
    exit;
  // bounded: at most the keep window's worth of removals per call, walking
  // down from the newest removable one until a name is already gone
  lowest := n - PWEB_CLI_DEV_KEEP_GENERATIONS - 1;
  if lowest < 1 then
    lowest := 1;
  while n >= lowest do
  begin
    if PWebCliEntry(Layout.DevDir, PWebCliDevGenerationDir(n)) =
         pcnDirectory then
    begin
      if PWebCliPipeRemoveTree(Layout.DevDir, PWebCliDevGenerationDir(n),
           stage) then
        Inc(Result);
    end;
    Dec(n);
  end;
end;

end.
