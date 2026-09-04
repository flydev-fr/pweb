{
  pweb.cli.pipeline - sources to the CAP-10C0 run layout, in order
  (CAP-10C1).

  THE ONLY UNIT OF THE PIPELINE THAT RUNS A CHILD. pweb.cli.toolset,
  pweb.cli.stage, pweb.cli.frontend, pweb.cli.pack, pweb.cli.native and
  pweb.cli.layout are PURE PLAN BUILDERS and file operations; every spawn in
  the whole lifecycle goes through PWebCliExecute here, in the CAP-10C0
  supervise profile, with an exact executable path, an argument vector and an
  explicit working directory. There is no shell, no command string, no
  .cmd/.bat, no environment injection and no second execution path - the
  supervision contract applies to a build exactly as it applies to `pweb
  run`, because it is the same engine.

  ---------------------------------------------------------------------------
  THE TEN STAGES
  ---------------------------------------------------------------------------

    1  open        the CAP-10A project, strict-parsed (done by the caller)
    2  toolchain   resolve everything, adopt the doctor's verdict; REFUSE
                   BEFORE ANY WRITE
    3  stage_sdk   materialise the TypeScript SDK          (react only)
    4  install     node <npm-cli.js> ci                    (react only)
    5  typecheck   node tsc                                (react only)
    6  build       node vite build (react) | pas2js + the ratified assembly
    7  pack        app.pwb, through the frozen CAP-6 bundler
    8  compile     fpc against the SDK root
    9  layout      assemble <output>/<os>-<arch>/release/, commit by rename
   10  verify      the CAP-10C0 resolver accepts what was committed

  Ordered and resumable BY DESIGN - each stage's inputs are the previous
  stage's outputs on a disk, not values in memory - but NOT RESUMING in
  C1: every run does every stage of its UI. Resumption is a decision about
  staleness, and a build tool that guesses what is still fresh is a build
  tool that ships a stale artifact.

  ---------------------------------------------------------------------------
  THE PROJECT-MUTATION GATE
  ---------------------------------------------------------------------------

  A pipeline is allowed to write in exactly four places:

      <root>/frontend/.pweb/          the staged SDK        (react)
      <root>/frontend/node_modules/   npm ci                (react)
      <root>/frontend/dist/           vite build            (react)
      <root>/<output>/                everything else       (both)

  Everything else in the project is READ-ONLY, and that is measured rather
  than asserted: the tree minus those four prefixes is digested before the
  first stage and after EVERY stage, and any change at all stops the
  pipeline with pipeline_mutation. A build whose output is not a function of
  its input is a build nobody can reproduce, and the SDK-root dependency
  model exists precisely so it does not have to write into the sources it
  compiles.

  Nothing outside the project root is written by the pipeline itself. The
  toolchain's own children use the OS temp directory, which is theirs.

  ---------------------------------------------------------------------------
  FAILURE, AND INTERRUPTION
  ---------------------------------------------------------------------------

  On a stage failure the pipeline stops at once: no later stage runs, the
  child's REAL typed status is reported (an exit code is an exit code, a
  signal is a signal, a forced termination is a forced termination - never
  all three flattened to "failed"), the tree is drained by membership by the
  engine, and no release directory exists, because the layout stage commits
  by rename and never runs at all.

  A stop request - Ctrl+C, SIGINT, SIGTERM, SIGHUP - travels through the
  engine's own ladder into the running child tree and is then observed
  between stages, so an interrupted build stops within one stage's bound and
  leaves the same nothing a failure leaves.
}
unit pweb.cli.pipeline;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.process,
  pweb.cli.run,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.toolset,
  pweb.cli.frontend,
  pweb.cli.pack,
  pweb.cli.native,
  pweb.cli.layout;

type
  /// the ten stages, in order
  TPWebCliStageKind = (
    pskOpen, pskToolchain, pskStageSdk, pskInstall, pskTypecheck,
    pskBuild, pskPack, pskCompile, pskLayout, pskVerify);

  /// the exit categories, the CAP-10C0 mapping extended to a build
  // - ordinal 0 is the accepted state
  TPWebCliPipeCode = (
    /// 0 - every stage of this UI ran and the layout verified
    ppcOk,
    /// 2 - the driver was invoked wrongly
    ppcUsage,
    /// 3 - the project, its descriptor, its paths or its layout
    ppcProject,
    /// 4 - the machine cannot build it: the doctor refused, a tool is
    /// missing, unrunnable or the wrong target
    ppcUnavailable,
    /// 5 - a stage's child failed, died or was stopped
    ppcStageFailed,
    /// 6 - an invariant of the pipeline itself broke
    ppcInternal);

  /// what one stage did
  TPWebCliStageReport = record
    Kind: TPWebCliStageKind;
    /// False for a stage this UI does not have
    Applicable: Boolean;
    /// True once the stage was entered
    Entered: Boolean;
    /// True when it completed without a refusal
    Ok: Boolean;
    /// the redacted command projection, '' for a stage with no child
    Command: RawUtf8;
    /// the child's typed outcome, meaningful when Command <> ''
    Outcome: TPWebCliChildOutcome;
    ExitCode: Integer;
    Signal: Integer;
    ElapsedMs: Int64;
    /// machine-stable cause, '' when Ok
    Cause: RawUtf8;
    Detail: RawUtf8;
  end;
  TPWebCliStageReports = array[TPWebCliStageKind] of TPWebCliStageReport;

  /// everything one pipeline run learned
  TPWebCliPipeResult = record
    Code: TPWebCliPipeCode;
    FailedStage: TPWebCliStageKind;
    Cause: RawUtf8;
    Detail: RawUtf8;
    /// True when a stop was requested before the pipeline finished
    Interrupted: Boolean;
    Stages: TPWebCliStageReports;
    /// the read-only project tree, before the first stage and after the last
    TreeBefore: RawUtf8;
    TreeAfter: RawUtf8;
    /// the committed release, '' unless the run reached ppcOk
    ReleaseDir: RawUtf8;
    /// the resolved toolchain, for the evidence
    Toolset: TPWebCliToolset;
    /// what the Pas2JS assembly had to normalise (pas2js only)
    Normalisation: TPWebCliPas2jsNormalisation;
    /// the SDK layout the build read
    Sdk: TPWebSdkLayout;
  end;

  /// the driver's line sink: every line the pipeline emits, already
  // prefixed, already free of ANSI and of any absolute path
  TPWebCliPipeNotify = procedure(Opaque: Pointer; const Line: RawUtf8;
    FromChild: Boolean);

/// stable lowercase name of a stage
function PWebCliStageName(Kind: TPWebCliStageKind): RawUtf8;

/// the ratified exit code of a category
function PWebCliPipeExitCode(Code: TPWebCliPipeCode): Integer;

/// the four writable prefixes of the ratified project-mutation set
function PWebCliMutationSet(const Project: TPWebCliProject): TRawUtf8DynArray;

/// the absolute prefixes every recorded string is projected through, and
/// the logical token each becomes
// - the ONE place the evidence's vocabulary is decided, so a driver, a gate
// and a report cannot each invent their own token for the same root
procedure PWebCliPipeRedactions(const Project: TPWebCliProject;
  const Sdk: TPWebSdkLayout; const Tools: TPWebCliToolset;
  out Prefixes, Tokens: TRawUtf8DynArray);

/// run the whole lifecycle for an ALREADY OPENED project
// - Project.Refusal must be pcrNone; the caller owns discovery and parsing,
// exactly as `pweb run` does
// - Notify receives every line; nil is allowed and means silence
function PWebCliRunPipeline(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Notify: TPWebCliPipeNotify;
  Opaque: Pointer): TPWebCliPipeResult;


implementation

function PWebCliStageName(Kind: TPWebCliStageKind): RawUtf8;
begin
  case Kind of
    pskOpen:      Result := 'open';
    pskToolchain: Result := 'toolchain';
    pskStageSdk:  Result := 'stage_sdk';
    pskInstall:   Result := 'install';
    pskTypecheck: Result := 'typecheck';
    pskBuild:     Result := 'build';
    pskPack:      Result := 'pack';
    pskCompile:   Result := 'compile';
    pskLayout:    Result := 'layout';
    pskVerify:    Result := 'verify';
  else
    Result := 'stage';
  end;
end;

function PWebCliPipeExitCode(Code: TPWebCliPipeCode): Integer;
begin
  case Code of
    ppcOk:          Result := 0;
    ppcUsage:       Result := 2;
    ppcProject:     Result := 3;
    ppcUnavailable: Result := 4;
    ppcStageFailed: Result := 5;
  else
    Result := 6;
  end;
end;

function PWebCliMutationSet(const Project: TPWebCliProject): TRawUtf8DynArray;
begin
  Result := nil;
  SetLength(Result, 4);
  Result[0] := Project.FrontendRoot + '/' + PWEB_FE_PWEB_DIR;
  Result[1] := Project.FrontendRoot + '/' + PWEB_FE_NODE_MODULES;
  Result[2] := Project.FrontendRoot + '/' + PWEB_FE_DIST;
  Result[3] := Project.Output;
end;

type
  /// the pipeline's own state while ONE child runs, reached through the
  // engine's Opaque pointer - the engine takes plain procedures, so this is
  // how a forwarded line knows which stage it belongs to
  PPipeContext = ^TPipeContext;
  TPipeContext = record
    Notify: TPWebCliPipeNotify;
    Opaque: Pointer;
    StagePrefix: RawUtf8;
  end;

procedure PipeSink(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  ctx: PPipeContext;
  text: RawUtf8;
begin
  ctx := PPipeContext(Opaque);
  if (ctx = nil) or
     not Assigned(ctx^.Notify) then
    exit;
  text := ctx^.StagePrefix + Line;
  if Truncated then
    text := text + ' [truncated]';
  ctx^.Notify(ctx^.Opaque, text, {FromChild=}True);
end;

// the pipeline's OWN lines, `pweb: `-prefixed exactly as the run command's
// are, so a forwarded tool line and a supervisor line can never be confused
procedure Say(Notify: TPWebCliPipeNotify; Opaque: Pointer;
  const Line: RawUtf8);
begin
  if Assigned(Notify) then
    Notify(Opaque, 'pweb: ' + Line, {FromChild=}False);
end;

function IntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

// the logical tokens every recorded command is projected through: no
// absolute path, no home directory and no SDK location ever reaches an
// evidence file, and two targets whose real paths differ entirely produce
// the same text
procedure PWebCliPipeRedactions(const Project: TPWebCliProject;
  const Sdk: TPWebSdkLayout; const Tools: TPWebCliToolset;
  out Prefixes, Tokens: TRawUtf8DynArray);
var
  n: PtrInt;

  procedure One(const Prefix, Token: RawUtf8);
  begin
    if Prefix = '' then
      exit;
    SetLength(Prefixes, n + 1);
    SetLength(Tokens, n + 1);
    Prefixes[n] := Prefix;
    Tokens[n] := Token;
    Inc(n);
  end;

  procedure Add(const Prefix, Token: RawUtf8);
  begin
    // BOTH FORMS, canonical first. A path this CLI resolved carries the
    // Windows extended-length prefix; the same path INSIDE an argument
    // carries the display form, because PWebCliArgPath stripped it. A
    // redaction that knew only one of them would leave half the evidence
    // carrying an absolute path - which is exactly what the first run of
    // this driver produced. Canonical first because the display form is a
    // suffix of it, and substituting the suffix first would leave `\\?\`
    // stranded in front of a token
    One(Prefix, Token);
    if PWebCliDisplayPath(Prefix) <> Prefix then
      One(PWebCliDisplayPath(Prefix), Token);
  end;

begin
  Prefixes := nil;
  Tokens := nil;
  n := 0;
  // longest and most specific first: an executable lives INSIDE a directory
  // that may itself be redacted, and the first match wins
  Add(Tools.Npm.Script, '<npm-cli>');
  Add(Tools.Node.Path, '<node>');
  Add(Tools.Fpc.Path, '<fpc>');
  Add(Tools.Pas2js.Path, '<pas2js>');
  Add(Sdk.Bundler, '<bundler>');
  Add(Sdk.Root, '<sdk>');
  Add(Project.Root, '<root>');
end;

function PWebCliRunPipeline(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Notify: TPWebCliPipeNotify;
  Opaque: Pointer): TPWebCliPipeResult;
var
  // the run's record is a LOCAL, and Result is assigned from it exactly
  // once, in the finally below. Pascal's nested functions have a Result of
  // their own, so a helper that wrote to `Result` would be writing to its
  // own return value - and the stage that recorded a refusal would be the
  // stage that lost it
  res: TPWebCliPipeResult;
  ctx: TPipeContext;
  excludes, prefixes, tokens: TRawUtf8DynArray;
  outputDir, targetDir, unitDir, binDir, distDir, assetsDir: RawUtf8;
  appPwb, exePath: RawUtf8;
  frontendRoot, sdkStageParent, found: RawUtf8;
  unreadable: Boolean;
  stageRefusal: TPWebCliStageRefusal;
  feRefusal: TPWebCliFrontendRefusal;
  cmd: TPWebCliCommand;
  layoutResult: TPWebCliLayoutResult;
  verifyLayout: TPWebCliRunLayout;
  staged: Integer;
  digest: RawUtf8;
  k: TPWebCliStageKind;

  procedure Enter(Kind: TPWebCliStageKind);
  begin
    res.Stages[Kind].Entered := True;
    Say(Notify, Opaque, PWebCliStageName(Kind) + ': start');
  end;

  procedure Done(Kind: TPWebCliStageKind);
  begin
    res.Stages[Kind].Ok := True;
    Say(Notify, Opaque, PWebCliStageName(Kind) + ': ok');
  end;

  // one refusal, recorded on its stage and on the run
  function Refuse(Kind: TPWebCliStageKind; Code: TPWebCliPipeCode;
    const Cause, Detail: RawUtf8): Boolean;
  begin
    res.Stages[Kind].Cause := Cause;
    res.Stages[Kind].Detail := Detail;
    res.Code := Code;
    res.FailedStage := Kind;
    res.Cause := Cause;
    res.Detail := Detail;
    Say(Notify, Opaque, PWebCliStageName(Kind) + ': FAILED ' + Cause +
      ' ' + Detail);
    Refuse := False;
  end;

  // the read-only tree, re-measured. Any change at all is an invariant
  // failure of this pipeline, not of the project
  function TreeStillClean(Kind: TPWebCliStageKind): Boolean;
  begin
    TreeStillClean := False;
    if not PWebCliPipeTreeDigest(Project.Root, excludes, digest,
         stageRefusal) then
    begin
      Refuse(Kind, ppcInternal, 'pipeline_tree_unreadable',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    if digest <> res.TreeBefore then
    begin
      Refuse(Kind, ppcInternal, 'pipeline_mutation', PWebCliStageName(Kind));
      exit;
    end;
    res.TreeAfter := digest;
    TreeStillClean := True;
  end;

  // a stop asked for between two stages, observed at the one place it can
  // be acted on without leaving anything half-written
  function StillRunning(Kind: TPWebCliStageKind): Boolean;
  begin
    if PWebCliStopRequested then
    begin
      res.Interrupted := True;
      StillRunning := Refuse(Kind, ppcStageFailed, 'pipeline_interrupted',
        PWebCliStageName(Kind));
      exit;
    end;
    StillRunning := True;
  end;

  // run ONE child through the ONE engine, in the supervise profile
  function RunStage(Kind: TPWebCliStageKind; const Command: TPWebCliCommand;
    TimeoutMs: Cardinal): Boolean;
  var
    spec: TPWebCliExecSpec;
    r: TPWebCliExecResult;
    a: PtrInt;
  begin
    // THE ARGUMENT FORM, CHECKED WHERE IT CANNOT BE FORGOTTEN. This CLI
    // canonicalizes Windows paths into the extended-length form and
    // pweb.cli.platform strips it for the executable, argv[0] and the working
    // directory - but not for the other arguments, which are the caller's.
    // MEASURED: `node \\?\C:\...\npm-cli.js --version` dies inside
    // realpathSync with `EISDIR ... lstat 'C:'`. Every plan builder puts its
    // paths through PWebCliArgPath; this is the invariant that makes a
    // forgotten one a refusal rather than a mystery inside somebody's tool
    for a := 0 to High(Command.Args) do
      if Copy(Command.Args[a], 1, 4) = '\\?\' then
      begin
        RunStage := Refuse(Kind, ppcInternal, 'arg_longpath_form',
          IntText(a));
        exit;
      end;
    ctx.StagePrefix := PWebCliStageName(Kind) + '| ';
    res.Stages[Kind].Command :=
      PWebCliCommandText(Command, prefixes, tokens);
    Say(Notify, Opaque, PWebCliStageName(Kind) + ': ' +
      res.Stages[Kind].Command);
    spec := Default(TPWebCliExecSpec);
    spec.ExePath := Command.Exe;
    spec.Args := Command.Args;
    spec.WorkDir := Command.WorkDir;
    spec.Profile := pepSupervise;
    spec.TimeoutMs := TimeoutMs;
    spec.Sink := @PipeSink;
    spec.StopCheck := nil;   // the installed console / signal handler
    spec.Opaque := @ctx;
    spec.TreeRoot := PWebCliDisplayPath(Command.WorkDir);
    r := PWebCliExecute(spec);
    res.Stages[Kind].Outcome := r.Outcome;
    res.Stages[Kind].ExitCode := r.ExitCode;
    res.Stages[Kind].Signal := r.Signal;
    res.Stages[Kind].ElapsedMs := r.ElapsedMs;
    if r.StopRequested then
      res.Interrupted := True;
    case r.Outcome of
      pcoExited:
        if r.ExitCode = 0 then
        begin
          RunStage := True;
          exit;
        end
        else
          RunStage := Refuse(Kind, ppcStageFailed, 'stage_exited',
            IntText(r.ExitCode));
      pcoSignaled:
        RunStage := Refuse(Kind, ppcStageFailed, 'stage_signaled',
          IntText(r.Signal));
      pcoForced:
        RunStage := Refuse(Kind, ppcStageFailed, 'stage_forced',
          PWebCliStageName(Kind));
      pcoUnreaped:
        RunStage := Refuse(Kind, ppcInternal, 'stage_unreaped',
          PWebCliStageName(Kind));
      pcoSpawnRefused:
        RunStage := Refuse(Kind, ppcUnavailable, 'stage_spawn_refused',
          PWebCliExecRefusalText(r.Refusal));
    else
      RunStage := Refuse(Kind, ppcUnavailable, 'stage_spawn_failed',
        PWebCliSpawnFailureText(r.Failure));
    end;
    if res.Interrupted and
       (res.Code = ppcStageFailed) then
      res.Cause := 'pipeline_interrupted';
  end;

begin
  res := Default(TPWebCliPipeResult);
  Result := res;
  try
  res.Code := ppcOk;
  ctx.Notify := Notify;
  ctx.Opaque := Opaque;
  ctx.StagePrefix := '';
  for k := Low(TPWebCliStageKind) to High(TPWebCliStageKind) do
  begin
    res.Stages[k].Kind := k;
    res.Stages[k].Applicable := (Project.Ui = puiReact) or
      not (k in [pskStageSdk, pskInstall, pskTypecheck]);
  end;

  { --- 1. open ------------------------------------------------------------ }
  Enter(pskOpen);
  if Project.Refusal <> pcrNone then
  begin
    Refuse(pskOpen, ppcProject,
      PWebCliProjectRefusalText(Project.Refusal), Project.Detail);
    exit;
  end;
  // CAP-10D1: the Windows project-root ceiling, refused HERE - before the
  // read-only tree is even digested, so nothing has been written and no
  // child has been spawned. The measurement behind the bound, and why its
  // owner is the pinned compiler rather than this CLI, is
  // PWEB_CLI_PIPE_MAX_ROOT_CHARS in pweb.cli.toolchain. A build tool whose
  // answer to "this path is too long" is a third-party compiler's own
  // failure ten minutes later is a build tool that made the developer do
  // the diagnosis
  if (Os = pcoWindows) and
     (Length(PWebCliDisplayPath(Project.Root)) >
        PWEB_CLI_PIPE_MAX_ROOT_CHARS) then
  begin
    Refuse(pskOpen, ppcProject, 'project_root_too_long',
      IntText(Length(PWebCliDisplayPath(Project.Root))));
    exit;
  end;
  excludes := PWebCliMutationSet(Project);
  if not PWebCliPipeTreeDigest(Project.Root, excludes, res.TreeBefore,
       stageRefusal) then
  begin
    Refuse(pskOpen, ppcInternal, 'pipeline_tree_unreadable',
      PWebCliStageRefusalText(stageRefusal));
    exit;
  end;
  // deliberately NOT seeded from TreeBefore: a value that starts equal and is
  // only re-assigned once it has been PROVED equal is a row that cannot read
  // false however the gate around it is weakened. It stays empty until a
  // stage actually re-measures, and an empty one is not `unchanged`
  res.TreeAfter := '';
  // a package-manager configuration inside the project could redirect the
  // registry `npm ci` fetches from. The templates ship none; this is the
  // lock that makes that a REFUSAL rather than an observation
  if PWebCliRegistryOverridePresent(Project.Root, excludes, found,
       unreadable) then
  begin
    Refuse(pskOpen, ppcProject,
      PWebCliFrontendRefusalText(pfrRegistryOverride), found);
    exit;
  end;
  if unreadable then
  begin
    // the check could not look, which is not the same answer as "nothing
    // is there" and must never be reported as one
    Refuse(pskOpen, ppcInternal, 'pipeline_tree_unreadable', 'registry');
    exit;
  end;
  frontendRoot := Project.FrontendRootPath.Full;
  Done(pskOpen);

  { --- 2. toolchain: refuse before any write ------------------------------ }
  Enter(pskToolchain);
  res.Toolset := PWebCliResolveToolset(Project, Os, Arch);
  if res.Toolset.Refusal <> ptrNone then
  begin
    if res.Toolset.Refusal = ptrDoctorRefused then
      // the SAME cause the doctor reports, so a machine refused by
      // `pweb doctor` is refused here for a reason a user can already read
      Refuse(pskToolchain, ppcUnavailable, res.Toolset.DoctorCause,
        res.Toolset.DoctorRow)
    else
      Refuse(pskToolchain, ppcUnavailable,
        PWebCliToolRefusalText(res.Toolset.Refusal),
        PWebCliToolKindText(res.Toolset.Failed));
    exit;
  end;
  if not PWebCliSdkLayout(Os, Arch, Project.Ui = puiPas2js, res.Sdk) then
  begin
    // the target is restored AFTER the failed resolution, because that
    // call clears the record it fills: an evidence row that lost its
    // target on the one refusal that needs naming one is worse than none
    res.Sdk.Target := PWebCliRunTargetName(Os, Arch);
    Refuse(pskToolchain, ppcUnavailable,
      PWebSdkLayoutRefusalText(res.Sdk.Refusal), res.Sdk.Detail);
    exit;
  end;
  PWebCliPipeRedactions(Project, res.Sdk, res.Toolset, prefixes, tokens);
  Done(pskToolchain);
  if not StillRunning(pskToolchain) then
    exit;

  { --- the output tree: everything below here writes only inside it ------- }
  if not PWebCliPipeEnsurePath(Project.Root, Project.Output, outputDir,
       stageRefusal) or
     not PWebCliPipeEnsureDir(outputDir, res.Sdk.Target, targetDir,
       stageRefusal) then
  begin
    Refuse(pskToolchain, ppcProject, 'output_unwritable', Project.Output);
    exit;
  end;

  { --- 3. stage the TypeScript SDK (react) -------------------------------- }
  if res.Stages[pskStageSdk].Applicable then
  begin
    Enter(pskStageSdk);
    if not PWebCliPipeEnsurePath(frontendRoot,
         PWEB_FE_PWEB_DIR + '/' + PWEB_FE_SDK_DIR, sdkStageParent,
         stageRefusal) then
    begin
      Refuse(pskStageSdk, ppcInternal, 'stage_sdk_dir',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    if not PWebCliStageTsSdk(res.Sdk.TypeScriptSdk, sdkStageParent,
         PWEB_FE_TS_DIR, staged, stageRefusal) then
    begin
      Refuse(pskStageSdk, ppcInternal,
        PWebCliStageRefusalText(stageRefusal), IntText(staged));
      exit;
    end;
    Say(Notify, Opaque, 'stage_sdk: ' + IntText(staged) + ' file(s)');
    if not TreeStillClean(pskStageSdk) then
      exit;
    Done(pskStageSdk);
    if not StillRunning(pskStageSdk) then
      exit;
  end;

  { --- 4. install, the ONE stage allowed to reach the network ------------- }
  if res.Stages[pskInstall].Applicable then
  begin
    Enter(pskInstall);
    cmd := PWebCliNpmCiCommand(res.Toolset.Node.Path,
      res.Toolset.Npm.Script, frontendRoot);
    if not RunStage(pskInstall, cmd, PWEB_CLI_PIPE_NPM_MS) then
      exit;
    if not TreeStillClean(pskInstall) then
      exit;
    Done(pskInstall);
    if not StillRunning(pskInstall) then
      exit;
  end;

  { --- 5. typecheck ------------------------------------------------------- }
  if res.Stages[pskTypecheck].Applicable then
  begin
    Enter(pskTypecheck);
    if not PWebCliTypecheckCommand(res.Toolset.Node.Path, frontendRoot,
         cmd, feRefusal) then
    begin
      Refuse(pskTypecheck, ppcUnavailable,
        PWebCliFrontendRefusalText(feRefusal), '');
      exit;
    end;
    if not RunStage(pskTypecheck, cmd, PWEB_CLI_PIPE_TSC_MS) then
      exit;
    if not TreeStillClean(pskTypecheck) then
      exit;
    Done(pskTypecheck);
    if not StillRunning(pskTypecheck) then
      exit;
  end;

  { --- 6. build ----------------------------------------------------------- }
  Enter(pskBuild);
  if Project.Ui = puiReact then
  begin
    // a fresh dist, so "deterministic across two runs" is a claim about the
    // build rather than about what survived from the last one
    if not PWebCliPipeRemoveTree(frontendRoot, PWEB_FE_DIST,
         stageRefusal) then
    begin
      Refuse(pskBuild, ppcInternal, 'build_dist_reclaim',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    if not PWebCliViteCommand(res.Toolset.Node.Path, frontendRoot, cmd,
         feRefusal) then
    begin
      Refuse(pskBuild, ppcUnavailable,
        PWebCliFrontendRefusalText(feRefusal), '');
      exit;
    end;
    if not RunStage(pskBuild, cmd, PWEB_CLI_PIPE_BUILD_MS) then
      exit;
    distDir := PWebCliJoin(frontendRoot, PWEB_FE_DIST);
    if (PWebCliEntry(frontendRoot, PWEB_FE_DIST) <> pcnDirectory) or
       (PWebCliEntry(distDir, PWEB_FE_INDEX) <> pcnFile) then
    begin
      Refuse(pskBuild, ppcStageFailed,
        PWebCliFrontendRefusalText(pfrOutputMissing),
        Project.FrontendRoot + '/' + PWEB_FE_DIST);
      exit;
    end;
  end
  else
  begin
    if not PWebCliPipeRemoveTree(targetDir, PWEB_FE_DIST, stageRefusal) or
       not PWebCliPipeEnsurePath(targetDir,
         PWEB_FE_DIST + '/' + PWEB_FE_ASSETS, assetsDir, stageRefusal) then
    begin
      Refuse(pskBuild, ppcInternal, 'build_dist_reclaim',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    distDir := PWebCliJoin(targetDir, PWEB_FE_DIST);
    if not PWebCliPas2jsCommand(res.Toolset.Pas2js.Path, frontendRoot,
         res.Sdk.Pas2jsSdk,
         PWebCliJoin(PWebCliJoin(distDir, PWEB_FE_ASSETS), PWEB_FE_APP_JS),
         Project, cmd, feRefusal) then
    begin
      Refuse(pskBuild, ppcProject,
        PWebCliFrontendRefusalText(feRefusal), '');
      exit;
    end;
    if not RunStage(pskBuild, cmd, PWEB_CLI_PIPE_BUILD_MS) then
      exit;
    if not PWebCliAssemblePas2jsDist(frontendRoot, distDir,
         res.Normalisation, feRefusal) then
    begin
      Refuse(pskBuild, ppcInternal,
        PWebCliFrontendRefusalText(feRefusal), '');
      exit;
    end;
  end;
  if not TreeStillClean(pskBuild) then
    exit;
  Done(pskBuild);
  if not StillRunning(pskBuild) then
    exit;

  { --- 7. app.pwb, through the frozen bundler ----------------------------- }
  Enter(pskPack);
  appPwb := PWebCliJoin(targetDir, PWEB_PACK_BUNDLE);
  if PWebCliNodeKind(appPwb) = pcnFile then
    if not PWebCliDeleteFile(appPwb) then
    begin
      Refuse(pskPack, ppcInternal, 'pack_reclaim', PWEB_PACK_BUNDLE);
      exit;
    end;
  cmd := PWebCliPackCommand(res.Sdk.Bundler, distDir, appPwb,
    Project.Root);
  if not RunStage(pskPack, cmd, PWEB_CLI_PIPE_PACK_MS) then
    exit;
  if PWebCliNodeKind(appPwb) <> pcnFile then
  begin
    Refuse(pskPack, ppcInternal, 'pack_output_missing', PWEB_PACK_BUNDLE);
    exit;
  end;
  if not TreeStillClean(pskPack) then
    exit;
  Done(pskPack);
  if not StillRunning(pskPack) then
    exit;

  { --- 8. the native compile ---------------------------------------------- }
  Enter(pskCompile);
  if not PWebCliPipeRemoveTree(targetDir, PWEB_NATIVE_UNIT_DIR,
       stageRefusal) or
     not PWebCliPipeRemoveTree(targetDir, PWEB_NATIVE_BIN_DIR,
       stageRefusal) or
     not PWebCliPipeEnsureDir(targetDir, PWEB_NATIVE_UNIT_DIR, unitDir,
       stageRefusal) or
     not PWebCliPipeEnsureDir(targetDir, PWEB_NATIVE_BIN_DIR, binDir,
       stageRefusal) then
  begin
    Refuse(pskCompile, ppcInternal, 'compile_output_dirs',
      PWebCliStageRefusalText(stageRefusal));
    exit;
  end;
  cmd := PWebCliFpcCommand(res.Toolset.Fpc.Path, Project, res.Sdk,
    Os, Arch, unitDir, binDir, Project.NativeProgramPath.Full);
  if not RunStage(pskCompile, cmd, PWEB_CLI_PIPE_FPC_MS) then
    exit;
  exePath := PWebCliJoin(binDir,
    PWebCliNativeExeName(Project.ProgramIdent, Os));
  if PWebCliNodeKind(exePath) <> pcnFile then
  begin
    // fpc can answer 0 and still not have linked: an executable that is not
    // there is a compile failure, whatever the exit code said
    Refuse(pskCompile, ppcStageFailed, 'compile_output_missing',
      PWebCliNativeExeName(Project.ProgramIdent, Os));
    exit;
  end;
  if not TreeStillClean(pskCompile) then
    exit;
  Done(pskCompile);
  if not StillRunning(pskCompile) then
    exit;

  { --- 9. the release layout, committed by rename ------------------------- }
  Enter(pskLayout);
  layoutResult := PWebCliAssembleRelease(Project, res.Sdk, Os, Arch,
    targetDir, exePath, appPwb);
  if layoutResult.Refusal <> plrNone then
  begin
    Refuse(pskLayout, ppcInternal,
      PWebCliLayoutRefusalText(layoutResult.Refusal), layoutResult.Detail);
    exit;
  end;
  res.ReleaseDir := layoutResult.ReleaseDir;
  if not TreeStillClean(pskLayout) then
    exit;
  Done(pskLayout);
  if not StillRunning(pskLayout) then
    exit;

  { --- 10. verify: the CAP-10C0 resolver's own verdict --------------------- }
  Enter(pskVerify);
  verifyLayout := PWebCliResolveRunLayout(Project, Os, Arch);
  if verifyLayout.Refusal <> prrNone then
  begin
    // an INDEPENDENT resolution, not a re-reading of what stage 9 already
    // checked: between the commit and here the layout is on a disk other
    // things can touch, and the run command's own resolver is the only
    // authority on whether it will accept it
    Refuse(pskVerify, ppcInternal,
      PWebCliRunRefusalText(verifyLayout.Refusal), '');
    exit;
  end;
  Say(Notify, Opaque, 'verify: ' + Project.Output + '/' +
    res.Sdk.Target + '/' + PWEB_CLI_RUN_RELEASE + ' accepted');
  Done(pskVerify);
  res.Code := ppcOk;
  finally
    // ONE assignment, on every path, including an exception nothing here
    // expects: a caller must never receive a zeroed record that reads as a
    // successful build
    Result := res;
  end;
end;

end.
