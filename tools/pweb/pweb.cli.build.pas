{
  pweb.cli.build - the public `pweb build`, over the frozen CAP-10C1
  pipeline and over nothing else (CAP-10D0).

  THIS UNIT RUNS NOTHING. It calls PWebCliRunPipeline exactly once and then
  READS a disk: the committed release's own inventory, its total size and
  the digest of the app.pwb the ONE layout rule placed. It names no process
  API, resolves no tool, knows no stage bound and carries no platform
  conditional, so "a public build introduced no second execution path" is a
  property of what this file does not link rather than a sentence somebody
  wrote in a contract.

  That matters more here than anywhere else in the CLI. `pweb dev` made the
  pipeline PUBLIC by linking it; `pweb build` makes it REACHABLE by name,
  which is the moment a lifecycle tool usually grows a second way to compile
  something "just for this case". There is one way, it is
  pweb.cli.pipeline, and this unit is a thin decision-and-measurement layer
  in front of it.

  ---------------------------------------------------------------------------
  WHAT IT ADDS TO THE PIPELINE, AND WHAT IT DOES NOT
  ---------------------------------------------------------------------------

  ADDS: the six summary facts a human needs after a successful build -
  the project name, the frontend kind, the target, the release directory
  PROJECT-RELATIVE, the app.pwb digest and the total bytes - plus the one
  advisory that turns an otherwise puzzling refusal into an actionable one.

  DOES NOT ADD: a stage, an order, a bound, an exit category, a resumption
  rule, a cleaning rule, an option, or a second opinion about anything the
  pipeline already decided. TPWebCliPipeCode is REUSED rather than
  redefined, so pweb.cli.pipeline stays the one owner of the mapping and
  PWebCliPipeExitCode stays the one place it turns into a number.

  ---------------------------------------------------------------------------
  THE REPLACEMENT OF AN EXISTING RELEASE (ratified at CAP-10D0)
  ---------------------------------------------------------------------------

  The rule is the CAP-10C1 layout unit's, unchanged, and CAP-10D0 ratifies
  it as the PUBLIC rule rather than an implementation detail:

    1  assemble the new release in a sibling .pweb-release.tmp
    2  if release/ exists as a DIRECTORY: reclaim .pweb-old.tmp, then
       rename release -> .pweb-old.tmp        (a rename that would replace
                                               an existing path is never
                                               used, on either family)
    3  rename .pweb-release.tmp -> release    (on failure, and only if 2
                                               happened, put the old one
                                               back)
    4  reclaim .pweb-old.tmp                  (guarded; a failure here is
                                               REPORTED and is not fatal)
    5  verify by re-resolving through the CAP-10C0 resolver ITSELF

  So there is never a partial layout and never a mixture of two builds, and
  there is EXACTLY ONE bounded instant - between the two renames of steps 2
  and 3 - in which no release exists at all. That instant cannot be removed:
  Windows has no atomic directory swap (MOVEFILE_REPLACE_EXISTING does not
  apply to a populated directory), POSIX rename(2) replaces a directory only
  when the destination is EMPTY, Linux's renameat2(RENAME_EXCHANGE) would do
  it and is Linux-only - which would make one rule three - and an
  indirection through a junction or a symlink at `release` is refused by the
  CAP-10C0 resolver itself, which fails any reparse point anywhere on the
  layout chain. A `pweb run` that starts inside that instant answers
  `not_built`, which is a correct answer; a `pweb run` that started before it
  keeps the layout it already resolved.

  MEASURED, and different on the two families, so it is recorded per target
  rather than claimed once: `pweb run` launches the application with the
  release directory as its working directory. On POSIX that directory
  renames freely and the running process keeps its inode, so a build
  replaces the layout underneath a live application and the old one runs to
  completion. On Windows a directory that is any process's current directory
  cannot be renamed at all, so step 2 fails, the build is refused with
  layout_reclaim_failed and the running application is untouched. Both are
  correct and neither can produce a partial layout - and this unit says so
  in one advisory line rather than leaving a reader to guess.

  ---------------------------------------------------------------------------
  THE EXIT CATEGORY
  ---------------------------------------------------------------------------

  docs/pipeline-contract.md section 9, unchanged and not re-decided here:

      0  every stage of this UI ran and the layout verified
      2  the command line was refused                  (the parser's, above)
      3  the project, its descriptor, its paths or its layout
      4  the machine cannot build it: the doctor refused, or a tool is
         missing, unrunnable or the wrong target
      5  a stage's child failed, died, or was stopped
      6  an invariant of the pipeline itself broke
}
unit pweb.cli.build;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.run,
  pweb.cli.stage,
  pweb.cli.pipeline;

type
  /// everything one public build learned, over and above the pipeline's own
  // result - which is embedded rather than copied field by field
  TPWebCliBuildResult = record
    /// the CAP-10C1 category, REUSED. PWebCliPipeExitCode maps it
    Code: TPWebCliPipeCode;
    /// the stage that refused, meaningful only when Code <> ppcOk
    FailedStage: TPWebCliStageKind;
    Cause: RawUtf8;
    Detail: RawUtf8;
    /// True when a stop was requested before the build finished
    Interrupted: Boolean;
    /// True when the refusal is one an in-use release directory produces,
    // which is worth one advisory line and is never a different category
    ReleaseInUse: Boolean;
    /// the descriptor's own facts, for the summary
    ProjectName: RawUtf8;
    Ui: RawUtf8;
    Target: RawUtf8;
    /// the committed release, PROJECT-RELATIVE and forward-slashed; '' on
    // any failure. Never an absolute path, never the SDK, never a home
    ReleaseLogical: RawUtf8;
    /// `<rel>|<size>|<sha256>` per file of the committed release, sorted -
    /// the CAP-10C1 tree projection, re-used rather than re-invented
    Inventory: RawUtf8;
    /// how many files the release holds, and how many bytes in total
    Files: Integer;
    TotalBytes: Int64;
    /// app.pwb, hashed where the ONE layout rule put it; '' on any failure
    BundleSha256: RawUtf8;
    /// the CAP-10C0 resolver accepted the committed layout in `verify`.
    // The ONLY thing that may make this command suggest `pweb run`
    Accepted: Boolean;
  end;

/// run the whole lifecycle for an ALREADY OPENED project and measure what
/// it committed
// - Project.Refusal must be pcrNone; the caller owns discovery and parsing,
// exactly as `pweb run` and `pweb dev` do
// - Notify receives every line the pipeline emits, already prefixed and
// already free of ANSI and of any absolute path; nil means silence
function PWebCliRunBuild(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Notify: TPWebCliPipeNotify;
  Opaque: Pointer): TPWebCliBuildResult;


implementation

{ The two layout refusals an in-use release directory can produce. They are
  the layout unit's own causes, named here rather than re-derived: a build
  that cannot move the previous release aside, or cannot put the new one in
  its place, is overwhelmingly a build racing an application that is running
  out of that very directory - and on Windows that is the ONLY thing it can
  be, because the release directory is the running application's working
  directory and Windows refuses to rename such a directory at all.

  This changes no category and no cause. It decides one advisory line. }
function InUseRefusal(const Cause: RawUtf8): Boolean;
begin
  Result := (Cause = 'layout_reclaim_failed') or
            (Cause = 'layout_commit_failed');
end;

// the total size of a release, read out of the projection that already
// measured it rather than by walking the tree a second time. A line is
// `<rel>|<size>|<sha256>`, or `<rel>|link` for an entry the walk recorded
// without following - which a ratified layout never contains, and which is
// therefore counted as a file of zero bytes rather than silently skipped
function InventoryBytes(const Lines: RawUtf8; out Files: Integer): Int64;
var
  i, start, bar1, bar2: PtrInt;
  line, sizeText: RawUtf8;
begin
  Result := 0;
  Files := 0;
  start := 1;
  for i := 1 to Length(Lines) + 1 do
    if (i > Length(Lines)) or
       (Lines[i] = #10) then
    begin
      line := Copy(Lines, start, i - start);
      start := i + 1;
      if line = '' then
        continue;
      Inc(Files);
      bar1 := PosEx('|', line);
      if bar1 = 0 then
        continue;
      bar2 := PosEx('|', line, bar1 + 1);
      if bar2 = 0 then
        continue;
      sizeText := Copy(line, bar1 + 1, bar2 - bar1 - 1);
      Result := Result + StrToInt64Def(string(sizeText), 0);
    end;
end;

function PWebCliRunBuild(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Notify: TPWebCliPipeNotify;
  Opaque: Pointer): TPWebCliBuildResult;
var
  pipe: TPWebCliPipeResult;
  layout: TPWebCliRunLayout;
  refusal: TPWebCliStageRefusal;
  content: RawByteString;
  tooBig: Boolean;
  files: Integer;
begin
  Result := Default(TPWebCliBuildResult);
  Result.ProjectName := Project.Name;
  Result.Ui := PWebCliUiText(Project.Ui);
  // the target is stated before the run, so a refusal that never reached
  // the toolchain stage still names the target it was refused for
  Result.Target := PWebCliRunTargetName(Os, Arch);

  // THE ONE CALL. Everything below this line reads a disk and decides
  // nothing the pipeline has not already decided
  pipe := PWebCliRunPipeline(Project, Os, Arch, Notify, Opaque);
  Result.Code := pipe.Code;
  Result.FailedStage := pipe.FailedStage;
  Result.Cause := pipe.Cause;
  Result.Detail := pipe.Detail;
  Result.Interrupted := pipe.Interrupted;
  Result.ReleaseInUse := (pipe.Code <> ppcOk) and InUseRefusal(pipe.Cause);
  if pipe.Sdk.Target <> '' then
    Result.Target := pipe.Sdk.Target;
  Result.Accepted := pipe.Stages[pskVerify].Ok;
  if (pipe.Code <> ppcOk) or
     (pipe.ReleaseDir = '') then
    exit;

  // the release directory NAMED THE WAY THE PIPELINE NAMES IT in its own
  // verify line - the descriptor's `output`, the target and the one
  // constant that owns the directory name - so a reader diffing the two
  // sees one string and not two spellings of it
  Result.ReleaseLogical := Project.Output + '/' + Result.Target + '/' +
    PWEB_CLI_RUN_RELEASE;

  // the inventory: the CAP-10C1 projection, over the committed release and
  // with nothing excluded. A release this walk cannot read is a release
  // that was verified a moment ago, so the failure is recorded by leaving
  // the measurement empty rather than by inventing a refusal the pipeline
  // did not make
  if PWebCliPipeTreeLines(pipe.ReleaseDir, nil, Result.Inventory, files,
       refusal) then
    Result.TotalBytes := InventoryBytes(Result.Inventory, Result.Files);

  // app.pwb, hashed WHERE THE LAYOUT RULE PUT IT. The bundle's position
  // differs between a flat directory and a macOS bundle, and this unit does
  // not know which: it asks the CAP-10C0 resolver, the one place that rule
  // lives, exactly as the pipeline's own verify stage asks it
  layout := PWebCliResolveRunLayout(Project, Os, Arch);
  if (layout.Refusal = prrNone) and
     PWebCliReadSmallFile(layout.BundlePath, PWEB_CLI_PIPE_MAX_FILE_BYTES,
       content, tooBig) then
    Result.BundleSha256 := LowerCaseU(Sha256(content));
end;

end.
