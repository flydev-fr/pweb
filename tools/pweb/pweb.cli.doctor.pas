{
  pweb.cli.doctor - the diagnostic engine behind `pweb doctor` (CAP-10A).

  ONE structured result array. The human report and the JSON document are two
  PROJECTIONS of it (pweb.cli.report) and neither can say anything the other
  cannot, which is the only way "the two modes agree" is a property rather
  than a habit.

  ---------------------------------------------------------------------------
  DIAGNOSTIC ONLY
  ---------------------------------------------------------------------------

  This engine inspects and reports. It downloads nothing, installs nothing,
  writes nothing, and touches no registry, no PATH, no lock file, no project
  file and no .env. The only side effects it can have at all are the ones its
  injected environment performs: reading directories, reading a file, and
  running a version probe that this repository bounds and never gives a shell
  to. `output` writability is asked as a permission question, never by
  creating a probe file.

  ---------------------------------------------------------------------------
  THE REQUIREMENT GRAPH
  ---------------------------------------------------------------------------

  CAP-10A implements exactly ONE mode, pdmSource: what must be true to open,
  edit and compile the project as source on this machine. The build and
  release modes - Inno Setup, the pinned WebView2 artifacts, Xcode 16.4 and
  SDK 15.5, the mORMot and webview pins, the three Windows profiles - belong
  to CAP-10C/D and this build emits NO ROW for them.

  That absence is deliberate and it is the honest shape. Schema 1 carries no
  dependency model, so where a generated project's mORMot lives is a question
  this build genuinely cannot answer; a `not_applicable` row for it would
  read like a considered verdict on a question nobody asked. Emitting nothing
  says what is true - and the rule stated in the objective ("do not require
  every release tool for a simple doctor on a source project") is exactly
  this rule, applied by leaving the graph small rather than by filling it
  with excuses.

  A row is NEVER downgraded to hide a failed prerequisite: an absent required
  tool fails, an absent OPTIONAL feature warns, and a check that does not
  apply to this project's UI is not_applicable with its reason recorded.

  ---------------------------------------------------------------------------
  INJECTION
  ---------------------------------------------------------------------------

  Everything the engine cannot compute - the host facts, the engine fact, the
  filesystem answers and the probe runner - arrives in TPWebCliDoctorEnv. The
  production environment is PWebCliRealEnv; the test suite substitutes a
  fully synthetic one, which is what makes the healthy path, every failure
  cause, the timeout and the saturation cases reproducible on four targets
  without needing four broken machines.
}
unit pweb.cli.doctor;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.assets.bundle,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.probe,
  pweb.cli.toolchain,
  // CAP-10D2: the installation's own integrity, MEASURED elsewhere and
  // reported here. The engine stays a pure function of its environment -
  // the fact arrives in TPWebCliDoctorEnv exactly as the host facts do
  pweb.cli.sdkmanifest;

const
  /// the doctor JSON contract version - a PUBLIC CLI surface
  PWEB_CLI_DOCTOR_SCHEMA = 1;
  /// the CLI's own version: one identity with the runtime it ships beside
  PWEB_CLI_VERSION = PWEB_RUNTIME_VERSION;

type
  /// the four statuses, in worsening order - ordinal 0 is the good one
  TPWebCliStatus = (pdsPass, pdsNotApplicable, pdsWarning, pdsFail);

  /// whether a failing row is fatal for the mode being diagnosed
  TPWebCliSeverity = (pdvRequired, pdvOptional);

  /// the requirement graph modes; CAP-10A implements only pdmSource
  TPWebCliMode = (pdmSource);

  /// one structured check result
  TPWebCliCheck = record
    /// stable identifier, also the sort key of the whole report
    Id: RawUtf8;
    Status: TPWebCliStatus;
    Severity: TPWebCliSeverity;
    /// machine-stable cause token - THE machine authority, never prose
    Cause: RawUtf8;
    /// one fixed English sentence; a diagnostic aid, never the authority
    Summary: RawUtf8;
    /// the measured value (a version, a soname, a count)
    Observed: RawUtf8;
    /// what the pinned source of truth requires
    Expected: RawUtf8;
    /// short, stable instruction
    Remediation: RawUtf8;
    /// a filesystem path this row is about, '' when none
    Path: RawUtf8;
    /// True when this row failed because a PROBE could not be run or bounded,
    /// rather than because the environment answered something wrong
    ProbeFailure: Boolean;
  end;
  TPWebCliChecks = array of TPWebCliCheck;

  /// the whole diagnosis
  TPWebCliReport = record
    Checks: TPWebCliChecks;
    CountPass: Integer;
    CountWarning: Integer;
    CountFail: Integer;
    CountNotApplicable: Integer;
    /// the worst status any row carries
    Status: TPWebCliStatus;
    /// True when at least one REQUIRED row failed for a probe reason
    ProbeFailure: Boolean;
  end;

  /// the injectable environment - every fact the engine cannot compute
  TPWebCliDoctorEnv = record
    OsText: RawUtf8;
    ArchText: RawUtf8;
    Release: RawUtf8;
    OsProductVersion: RawUtf8;   // '' when the platform publishes none
    Engine: TPWebCliEngineFact;
    /// CAP-10D2: what the running executable's own SDK says about itself
    // - a default-initialized environment carries Present = False, which is
    // the UNPACKAGED state: the three sdk rows are then not_applicable, and
    // a synthetic environment that never heard of a manifest reports the
    // same thing this repository's own staged SDK root reports
    Sdk: TPWebCliSdkFact;
    NodeKind: function(const Path: RawUtf8): TPWebCliNodeKind;
    DirWritable: function(const Dir: RawUtf8): Boolean;
    ProbeTool: function(const Tool, ProjectRoot: RawUtf8;
      const Args: TRawUtf8DynArray; TimeoutMs: Cardinal): TPWebCliProbe;
  end;

/// the production environment: the real host, the real filesystem, the real
/// bounded probe runner
function PWebCliRealEnv: TPWebCliDoctorEnv;

/// stable lowercase text for a status
function PWebCliStatusText(Status: TPWebCliStatus): RawUtf8;

/// stable lowercase text for a severity
function PWebCliSeverityText(Severity: TPWebCliSeverity): RawUtf8;

/// normalize a tool's reported version to strict X.Y.Z
// - accepts an optional leading 'v', a two-component X.Y (padded with .0)
// and trailing whitespace or a trailing line; refuses anything else, which
// is what makes "malformed version" a distinct cause from "wrong version"
function PWebCliNormalizeVersion(const Raw: RawUtf8;
  out Version: RawUtf8): Boolean;

/// run the whole requirement graph
// - Project.Refusal <> pcrNone is expected and handled: the host rows are
// still produced, and the project rows carry the refusal
function PWebCliDoctorRun(const Env: TPWebCliDoctorEnv;
  const Project: TPWebCliProject; Mode: TPWebCliMode): TPWebCliReport;

implementation

function PWebCliStatusText(Status: TPWebCliStatus): RawUtf8;
begin
  case Status of
    pdsPass:          Result := 'pass';
    pdsNotApplicable: Result := 'not_applicable';
    pdsWarning:       Result := 'warning';
  else
    Result := 'fail';
  end;
end;

function PWebCliSeverityText(Severity: TPWebCliSeverity): RawUtf8;
begin
  if Severity = pdvOptional then
    Result := 'optional'
  else
    Result := 'required';
end;

{ ---------------------------------------------------------------------------
  the production environment
  --------------------------------------------------------------------------- }

function RealProbe(const Tool, ProjectRoot: RawUtf8;
  const Args: TRawUtf8DynArray; TimeoutMs: Cardinal): TPWebCliProbe;
begin
  case Length(Args) of
    0: Result := PWebCliProbeTool(Tool, ProjectRoot, [], TimeoutMs);
    1: Result := PWebCliProbeTool(Tool, ProjectRoot, [Args[0]], TimeoutMs);
  else
    Result := PWebCliProbeTool(Tool, ProjectRoot, [Args[0], Args[1]],
      TimeoutMs);
  end;
end;

function PWebCliRealEnv: TPWebCliDoctorEnv;
begin
  Result := Default(TPWebCliDoctorEnv);
  Result.OsText := PWebCliHostOsText;
  Result.ArchText := PWebCliHostArchText;
  Result.Release := PWebCliOsRelease;
  if not PWebCliOsProductVersion(Result.OsProductVersion) then
    Result.OsProductVersion := '';
  Result.Engine := PWebCliEngine;
  // the running image's own SDK, by the one CAP-10B0 anchor rule. On an
  // unpackaged root this is three directory reads and nothing else; on a
  // packaged one it is the FULL inventory - measured at 288 files / 38 MB
  // in 57 ms, which is why there is no sampling policy to argue about
  Result.Sdk := PWebCliSdkVerify(PWEB_CLI_VERSION);
  Result.NodeKind := @PWebCliNodeKind;
  Result.DirWritable := @PWebCliDirWritable;
  Result.ProbeTool := @RealProbe;
end;

{ ---------------------------------------------------------------------------
  version normalization
  --------------------------------------------------------------------------- }

function PWebCliNormalizeVersion(const Raw: RawUtf8;
  out Version: RawUtf8): Boolean;
var
  i, dots: PtrInt;
  s: RawUtf8;
  c: AnsiChar;
begin
  Version := '';
  Result := False;
  // the FIRST line only: a tool that prints a banner after its version is
  // reporting a version, not two of them
  i := 1;
  while (i <= Length(Raw)) and
        (Raw[i] <> #10) and
        (Raw[i] <> #13) do
    Inc(i);
  s := Copy(Raw, 1, i - 1);
  while (s <> '') and
        ((s[1] = ' ') or (s[1] = #9)) do
    s := Copy(s, 2, MaxInt);
  while (s <> '') and
        ((s[Length(s)] = ' ') or (s[Length(s)] = #9)) do
    SetLength(s, Length(s) - 1);
  if (s <> '') and
     ((s[1] = 'v') or (s[1] = 'V')) then
    s := Copy(s, 2, MaxInt);
  if s = '' then
    exit;
  dots := 0;
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if c = '.' then
      Inc(dots)
    else if not (c in ['0' .. '9']) then
      exit; // a suffix, a build tag or a word: malformed for comparison
  end;
  if dots = 1 then
    s := s + '.0'; // 'X.Y' is a real shape (macOS product versions)
  if not PWebSemVerValid(s) then
    exit;
  Version := s;
  Result := True;
end;

{ ---------------------------------------------------------------------------
  the engine
  --------------------------------------------------------------------------- }

type
  TReportBuilder = record
    Report: TPWebCliReport;
  end;

procedure Add(var B: TReportBuilder; const Id: RawUtf8;
  Status: TPWebCliStatus; Severity: TPWebCliSeverity;
  const Cause, Summary, Observed, Expected, Remediation, Path: RawUtf8;
  ProbeFailure: Boolean = False);
var
  n: PtrInt;
begin
  n := Length(B.Report.Checks);
  SetLength(B.Report.Checks, n + 1);
  B.Report.Checks[n].Id := Id;
  B.Report.Checks[n].Status := Status;
  B.Report.Checks[n].Severity := Severity;
  B.Report.Checks[n].Cause := Cause;
  B.Report.Checks[n].Summary := Summary;
  B.Report.Checks[n].Observed := Observed;
  B.Report.Checks[n].Expected := Expected;
  B.Report.Checks[n].Remediation := Remediation;
  B.Report.Checks[n].Path := Path;
  B.Report.Checks[n].ProbeFailure := ProbeFailure;
end;

// one tool row: resolve, probe, normalize, compare - with a DISTINCT cause
// for every way it can go wrong, because "node is broken" and "node is old"
// are different problems with different fixes
procedure AddToolRow(var B: TReportBuilder; const Env: TPWebCliDoctorEnv;
  const Id, Tool, VersionArg, ProjectRoot, Expected, Remediation: RawUtf8;
  ExactVersion: Boolean; const Wanted: RawUtf8);
var
  probe: TPWebCliProbe;
  args: TRawUtf8DynArray;
  version: RawUtf8;
  diff: Integer;
begin
  SetLength(args, 1);
  args[0] := VersionArg;
  probe := Env.ProbeTool(Tool, ProjectRoot, args, PWEB_CLI_PROBE_TIMEOUT_MS);
  case probe.Outcome of
    ppoNotFound:
      begin
        Add(B, Id, pdsFail, pdvRequired, 'tool_not_found',
          'the tool was not found on PATH', '', Expected, Remediation, '');
        exit;
      end;
    ppoInsideProject:
      begin
        Add(B, Id, pdsFail, pdvRequired, 'tool_inside_project',
          'the tool resolves inside the project and was NOT executed',
          '', Expected,
          'remove the project-local executable from PATH', probe.Path);
        exit;
      end;
    ppoSpawnFailed:
      begin
        Add(B, Id, pdsFail, pdvRequired, 'probe_spawn_failed',
          'the tool could not be started', '',
          Expected, Remediation, probe.Path, {ProbeFailure=}True);
        exit;
      end;
    ppoTimedOut:
      begin
        Add(B, Id, pdsFail, pdvRequired, 'probe_timed_out',
          'the tool did not answer within the bound and was terminated',
          '', Expected, Remediation, probe.Path,
          {ProbeFailure=}True);
        exit;
      end;
    ppoDied:
      begin
        // CAP-10C0: a tool that died by a signal has no exit code to read
        // and no version to parse - its own cause, never 'unparseable'
        Add(B, Id, pdsFail, pdvRequired, 'probe_died',
          'the tool died by a signal during the version query', '',
          Expected, Remediation, probe.Path, {ProbeFailure=}True);
        exit;
      end;
  end;
  if probe.ExitCode <> 0 then
  begin
    Add(B, Id, pdsFail, pdvRequired, 'probe_exit_code',
      'the version query failed', '', Expected,
      Remediation, probe.Path, {ProbeFailure=}True);
    exit;
  end;
  if not PWebCliNormalizeVersion(probe.Output, version) then
  begin
    Add(B, Id, pdsFail, pdvRequired, 'version_malformed',
      'the tool did not report a version this build can compare', '',
      Expected, Remediation, probe.Path);
    exit;
  end;
  if ExactVersion then
  begin
    if version <> Wanted then
    begin
      Add(B, Id, pdsFail, pdvRequired, 'version_mismatch',
        'the tool reports a version other than the pinned one', version,
        Expected, Remediation, probe.Path);
      exit;
    end;
  end
  else if Wanted <> '' then
  begin
    if not PWebSemVerCompare(version, Wanted, diff) then
    begin
      Add(B, Id, pdsFail, pdvRequired, 'version_malformed',
        'the reported version could not be compared', version, Expected,
        Remediation, probe.Path);
      exit;
    end;
    if diff < 0 then
    begin
      Add(B, Id, pdsFail, pdvRequired, 'version_too_old',
        'the tool is older than the supported floor', version, Expected,
        Remediation, probe.Path);
      exit;
    end;
  end;
  if probe.Duplicates > 0 then
  begin
    // a shadowing install is a warning, not a failure: the selected tool
    // satisfies the requirement, and the row says which one was selected
    Add(B, Id, pdsWarning, pdvRequired, 'tool_duplicated',
      'more than one install of this tool is on PATH', version, Expected,
      'PATH carries other installs of this tool; the reported one was used',
      probe.Path);
    exit;
  end;
  Add(B, Id, pdsPass, pdvRequired, 'ok', 'the tool satisfies its pin',
    version, Expected, '', probe.Path);
end;

// a tool whose PRESENCE is the requirement, with nothing executed
//
// npm is the reason this exists. On Windows its only entry point is
// npm.cmd, a BATCH FILE - CreateProcess cannot run it and the only way to
// ask it for a version is cmd.exe, which this CLI does not have and will not
// grow. So npm is diagnosed the way it can be diagnosed honestly: it is
// found, its real path is reported, and no version claim is made about it
// on any platform - because a check that answers on POSIX and lies on
// Windows is worse than one that answers the same everywhere.
procedure AddPresenceRow(var B: TReportBuilder; const Env: TPWebCliDoctorEnv;
  const Id, Tool, ProjectRoot, Expected, Remediation: RawUtf8;
  Severity: TPWebCliSeverity);
var
  path: RawUtf8;
  dup: Integer;
  outcome: TPWebCliProbeOutcome;
  absent: TPWebCliStatus;
begin
  if Severity = pdvOptional then
    absent := pdsWarning
  else
    absent := pdsFail;
  outcome := PWebCliResolveTool(Tool, ProjectRoot, path, dup);
  case outcome of
    ppoInsideProject:
      Add(B, Id, pdsFail, Severity, 'tool_inside_project',
        'the tool resolves inside the project and was NOT executed', '',
        Expected, 'remove the project-local executable from PATH', path);
    ppoCompleted:
      Add(B, Id, pdsPass, Severity, 'ok', 'the tool is present on PATH',
        '', Expected, '', path);
  else
    Add(B, Id, absent, Severity, 'tool_not_found',
      'the tool was not found on PATH', '', Expected, Remediation, '');
  end;
end;

procedure SortById(var Checks: TPWebCliChecks);
var
  i, j: PtrInt;
  tmp: TPWebCliCheck;
begin
  // insertion sort over a handful of rows: the ORDER is part of the public
  // JSON contract, so it comes from the id and never from emission order
  for i := 1 to High(Checks) do
  begin
    tmp := Checks[i];
    j := i - 1;
    while (j >= 0) and
          (Checks[j].Id > tmp.Id) do
    begin
      Checks[j + 1] := Checks[j];
      Dec(j);
    end;
    Checks[j + 1] := tmp;
  end;
end;

function PWebCliDoctorRun(const Env: TPWebCliDoctorEnv;
  const Project: TPWebCliProject; Mode: TPWebCliMode): TPWebCliReport;
var
  b: TReportBuilder;
  i: PtrInt;
  ok: Boolean;
  version, anchor: RawUtf8;
  diff: Integer;
  kind: TPWebCliNodeKind;
begin
  b := Default(TReportBuilder);
  ok := Project.Refusal = pcrNone;

  { ---- identity ---- }
  Add(b, 'cli.version', pdsPass, pdvRequired, 'ok',
    'the pweb CLI and the wire protocol it speaks',
    PWEB_CLI_VERSION + ' protocol ' + RawUtf8(IntToStr(PWEB_PROTOCOL_VERSION)),
    PWEB_CLI_VERSION, '', '');

  { ---- host ---- }
  if Env.ArchText = 'other' then
    Add(b, 'host.platform', pdsFail, pdvRequired, 'arch_unsupported',
      'this architecture is not one PWeb supports',
      Env.OsText + '/' + Env.ArchText, 'x86_64 or arm64',
      'build and run PWeb on a supported architecture', '')
  else
    Add(b, 'host.platform', pdsPass, pdvRequired, 'ok',
      'the host family and architecture',
      Env.OsText + '/' + Env.ArchText, 'x86_64 or arm64', '', '');

  { ---- project ---- }
  if ok then
    Add(b, 'project.descriptor', pdsPass, pdvRequired, 'ok',
      'the project descriptor parsed at the supported schema',
      Project.Name + ' ' + Project.Version + ' (' +
        PWebCliUiText(Project.Ui) + ') schema ' +
        RawUtf8(IntToStr(Project.Schema)),
      PWEB_CLI_DESCRIPTOR + ' schema ' + RawUtf8(IntToStr(PWEB_CLI_SCHEMA)),
      '', Project.DescriptorPath)
  else
    Add(b, 'project.descriptor', pdsFail, pdvRequired,
      PWebCliProjectRefusalText(Project.Refusal),
      'no usable project descriptor', Project.Detail,
      PWEB_CLI_DESCRIPTOR + ' schema ' + RawUtf8(IntToStr(PWEB_CLI_SCHEMA)),
      'create or correct pweb.json, or pass --project',
      Project.DescriptorPath);

  if not ok then
  begin
    // every project-dependent row is not_applicable, with the reason
    // recorded - never a SKIP that hides the failure above
    Add(b, 'project.native_program', pdsNotApplicable, pdvRequired,
      'no_project', 'requires a valid project descriptor', '', '', '', '');
    Add(b, 'project.frontend_root', pdsNotApplicable, pdvRequired,
      'no_project', 'requires a valid project descriptor', '', '', '', '');
    Add(b, 'project.output', pdsNotApplicable, pdvRequired,
      'no_project', 'requires a valid project descriptor', '', '', '', '');
  end
  else
  begin
    if Project.NativeProgramPath.MissingSegments > 0 then
      Add(b, 'project.native_program', pdsFail, pdvRequired, 'path_absent',
        'the native program source named by the descriptor is not there',
        Project.NativeProgram, 'an existing file under the project root',
        'create the file or correct native.program in pweb.json',
        Project.NativeProgramPath.Full)
    else
    begin
      kind := Env.NodeKind(Project.NativeProgramPath.Full);
      if kind <> pcnFile then
        Add(b, 'project.native_program', pdsFail, pdvRequired,
          'path_not_file', 'native.program does not name a regular file',
          Project.NativeProgram, 'an existing file under the project root',
          'correct native.program in pweb.json',
          Project.NativeProgramPath.Full)
      else
        Add(b, 'project.native_program', pdsPass, pdvRequired, 'ok',
          'the native program source is present and confined',
          Project.NativeProgram, 'an existing file under the project root',
          '', Project.NativeProgramPath.Full);
    end;

    if Project.FrontendRootPath.MissingSegments > 0 then
      Add(b, 'project.frontend_root', pdsFail, pdvRequired, 'path_absent',
        'the frontend root named by the descriptor is not there',
        Project.FrontendRoot, 'an existing directory under the project root',
        'create the directory or correct frontend.root in pweb.json',
        Project.FrontendRootPath.Full)
    else if Env.NodeKind(Project.FrontendRootPath.Full) <> pcnDirectory then
      Add(b, 'project.frontend_root', pdsFail, pdvRequired,
        'path_not_directory', 'frontend.root does not name a directory',
        Project.FrontendRoot, 'an existing directory under the project root',
        'correct frontend.root in pweb.json', Project.FrontendRootPath.Full)
    else
      Add(b, 'project.frontend_root', pdsPass, pdvRequired, 'ok',
        'the frontend root is present and confined', Project.FrontendRoot,
        'an existing directory under the project root', '',
        Project.FrontendRootPath.Full);

    // the output directory is allowed not to exist yet - that is what a
    // project looks like before its first build. What must hold is that
    // something can be created there, asked as a permission question.
    anchor := Project.OutputPath.ExistingDir;
    if Env.DirWritable(anchor) then
    begin
      if Project.OutputPath.MissingSegments > 0 then
        Add(b, 'project.output', pdsPass, pdvRequired, 'ok_absent',
          'the output directory does not exist yet and can be created',
          Project.Output, 'a writable directory under the project root',
          '', anchor)
      else
        Add(b, 'project.output', pdsPass, pdvRequired, 'ok',
          'the output directory exists and is writable', Project.Output,
          'a writable directory under the project root', '',
          Project.OutputPath.Full);
    end
    else
      Add(b, 'project.output', pdsFail, pdvRequired, 'not_writable',
        'nothing can be created in the output location', Project.Output,
        'a writable directory under the project root',
        'grant write access to the output directory', anchor);
  end;

  { ---- the host WebView engine ---- }
  if not Env.Engine.Usable then
    Add(b, 'platform.webview', pdsFail, pdvRequired, Env.Engine.Category,
      'the host WebView engine is not usable', Env.Engine.Observed,
      Env.Engine.Expected, 'install or update the platform WebView runtime',
      '')
  else if (Env.OsText = 'macos') and
          (Env.OsProductVersion <> '') then
  begin
    // macOS is the one platform whose ENGINE requirement is a version of
    // the operating system itself: the ratified floor is the first branch
    // whose WebKit treats a custom-scheme origin as a secure context
    if not PWebCliNormalizeVersion(Env.OsProductVersion, version) then
      Add(b, 'platform.webview', pdsFail, pdvRequired, 'version_malformed',
        'the macOS product version could not be compared',
        Env.OsProductVersion, Env.Engine.Expected,
        'update macOS to ' + PWEB_CLI_MACOS_MIN + ' or later', '')
    else if not PWebSemVerCompare(version, PWEB_CLI_MACOS_MIN + '.0', diff) then
      Add(b, 'platform.webview', pdsFail, pdvRequired, 'version_malformed',
        'the macOS product version could not be compared', version,
        Env.Engine.Expected,
        'update macOS to ' + PWEB_CLI_MACOS_MIN + ' or later', '')
    else if diff < 0 then
      Add(b, 'platform.webview', pdsFail, pdvRequired, 'version_too_old',
        'macOS is older than the ratified floor', version,
        Env.Engine.Expected,
        'update macOS to ' + PWEB_CLI_MACOS_MIN + ' or later', '')
    else
      Add(b, 'platform.webview', pdsPass, pdvRequired, 'ok',
        'the host WebView engine is usable', version, Env.Engine.Expected,
        '', '');
  end
  else
    Add(b, 'platform.webview', pdsPass, pdvRequired, 'ok',
      'the host WebView engine is usable', Env.Engine.Observed,
      Env.Engine.Expected, '', '');

  { ---- the installation itself (CAP-10D2) ----

    Three rows over one fact, and the split is deliberate: "there is no
    manifest here", "the manifest is broken" and "a shipped byte moved" are
    three different problems with three different answers, and a single
    `sdk.ok` row would have flattened them into one.

    An SDK with NO manifest is not a failure. This repository's own staged
    build tree has none, and neither has any root a developer assembled by
    hand; the rows say not_applicable with the reason recorded, exactly as
    a Pas2JS row does for a React project. What is refused is a manifest
    that is PRESENT and does not describe the tree it sits in. }
  if not Env.Sdk.Present then
  begin
    if Env.Sdk.Manifest = psmRootUnresolved then
    begin
      Add(b, 'sdk.manifest', pdsFail, pdvRequired,
        PWebSdkRefusalTextM(psmRootUnresolved),
        'the SDK root of the running executable could not be resolved',
        Env.Sdk.Detail, '<sdk>/bin/pweb', 'reinstall the PWeb SDK', '');
      Add(b, 'sdk.integrity', pdsFail, pdvRequired,
        PWebSdkRefusalTextM(psmRootUnresolved),
        'the shipped file set could not be verified', Env.Sdk.Detail, '',
        'reinstall the PWeb SDK', '');
      Add(b, 'sdk.version', pdsFail, pdvRequired,
        PWebSdkRefusalTextM(psmRootUnresolved),
        'the SDK version could not be read', Env.Sdk.Detail,
        PWEB_CLI_VERSION, 'reinstall the PWeb SDK', '');
    end
    else
    begin
      Add(b, 'sdk.manifest', pdsNotApplicable, pdvRequired,
        PWebSdkRefusalTextM(psmAbsent),
        'this SDK root carries no distribution manifest', '',
        PWEB_SDK_MANIFEST, '', '');
      Add(b, 'sdk.integrity', pdsNotApplicable, pdvRequired,
        PWebSdkRefusalTextM(psmAbsent),
        'there is no declared file set to verify', '', '', '', '');
      Add(b, 'sdk.version', pdsNotApplicable, pdvRequired,
        PWebSdkRefusalTextM(psmAbsent),
        'there is no declared version to compare', '', PWEB_CLI_VERSION,
        '', '');
    end;
  end
  else
  begin
    if Env.Sdk.Manifest = psmNone then
      Add(b, 'sdk.manifest', pdsPass, pdvRequired, 'ok',
        'the distribution manifest is present, canonical and schema ' +
          RawUtf8(IntToStr(PWEB_SDK_MANIFEST_SCHEMA)),
        RawUtf8(IntToStr(Env.Sdk.Declared)) + ' files, ' +
          RawUtf8(IntToStr(Env.Sdk.Licenses)) + ' licences',
        'schema ' + RawUtf8(IntToStr(PWEB_SDK_MANIFEST_SCHEMA)), '',
        PWEB_SDK_MANIFEST)
    else
      Add(b, 'sdk.manifest', pdsFail, pdvRequired,
        PWebSdkRefusalTextM(Env.Sdk.Manifest),
        'the distribution manifest is not one this release can read',
        Env.Sdk.Detail, 'schema ' +
          RawUtf8(IntToStr(PWEB_SDK_MANIFEST_SCHEMA)),
        'extract the SDK archive again', PWEB_SDK_MANIFEST);
    // NOT downgraded when the manifest failed: a set that could not be
    // checked has not been checked, and reporting that as not_applicable
    // would hide a failed prerequisite behind an absence
    if Env.Sdk.Integrity = psmNone then
      Add(b, 'sdk.integrity', pdsPass, pdvRequired, 'ok',
        'every shipped file matches the manifest',
        RawUtf8(IntToStr(Env.Sdk.Verified)) + '/' +
          RawUtf8(IntToStr(Env.Sdk.Declared)) + ' files in ' +
          RawUtf8(IntToStr(Env.Sdk.ElapsedMs)) + ' ms',
        RawUtf8(IntToStr(Env.Sdk.Declared)) + ' files', '', '')
    else
      Add(b, 'sdk.integrity', pdsFail, pdvRequired,
        PWebSdkRefusalTextM(Env.Sdk.Integrity),
        'a shipped file is missing or is not the bytes the manifest declares',
        Env.Sdk.Detail, RawUtf8(IntToStr(Env.Sdk.Declared)) + ' files',
        'extract the SDK archive again', '');
    if Env.Sdk.Version = psmNone then
      Add(b, 'sdk.version', pdsPass, pdvRequired, 'ok',
        'the manifest describes this release', Env.Sdk.PWebVersion,
        PWEB_CLI_VERSION, '', '')
    else
      Add(b, 'sdk.version', pdsFail, pdvRequired,
        PWebSdkRefusalTextM(Env.Sdk.Version),
        'the manifest describes a different release',
        Env.Sdk.PWebVersion, PWEB_CLI_VERSION,
        'install one PWeb SDK, not two', '');
  end;

  { ---- the compiler ---- }
  AddToolRow(b, Env, 'toolchain.fpc', PWEB_CLI_TOOL_FPC, '-iV', Project.Root,
    'Free Pascal Compiler >= ' + PWEB_CLI_FPC_MIN,
    'install FPC ' + PWEB_CLI_FPC_MIN +
      ' or later and put its bin directory on PATH',
    {ExactVersion=}False, PWEB_CLI_FPC_MIN);

  { ---- the frontend toolchain, by UI kind ---- }
  if ok and (Project.Ui = puiReact) then
  begin
    AddToolRow(b, Env, 'frontend.node', PWEB_CLI_TOOL_NODE, '--version',
      Project.Root, 'Node.js >= ' + PWEB_CLI_NODE_MIN,
      'install Node.js ' + PWEB_CLI_NODE_MIN + ' or later',
      {ExactVersion=}False, PWEB_CLI_NODE_MIN);
    AddPresenceRow(b, Env, 'frontend.npm', PWEB_CLI_TOOL_NPM, Project.Root,
      'npm present on PATH', 'install npm (it ships with Node.js)',
      pdvRequired);
    // the lockfile is not a nicety here: every frontend this repository
    // builds is built from a committed lockfile, and an unlocked install
    // is a different product on every machine
    if Project.FrontendRootPath.MissingSegments > 0 then
      Add(b, 'frontend.lockfile', pdsFail, pdvRequired, 'no_frontend_root',
        'the frontend root does not exist, so its lockfile cannot be read',
        Project.FrontendRoot, 'package.json + package-lock.json',
        'create the frontend root named by pweb.json', '')
    else
    begin
      if Env.NodeKind(PWebCliJoin(Project.FrontendRootPath.Full,
           'package.json')) <> pcnFile then
        Add(b, 'frontend.lockfile', pdsFail, pdvRequired, 'package_absent',
          'the frontend has no package.json', Project.FrontendRoot,
          'package.json + package-lock.json',
          'add package.json to the frontend root', '')
      else if Env.NodeKind(PWebCliJoin(Project.FrontendRootPath.Full,
                'package-lock.json')) <> pcnFile then
        Add(b, 'frontend.lockfile', pdsFail, pdvRequired, 'lockfile_absent',
          'the frontend has no package-lock.json', Project.FrontendRoot,
          'package.json + package-lock.json',
          'run npm install once and commit package-lock.json', '')
      else
        Add(b, 'frontend.lockfile', pdsPass, pdvRequired, 'ok',
          'the frontend is pinned by a committed lockfile',
          Project.FrontendRoot, 'package.json + package-lock.json', '',
          Project.FrontendRootPath.Full);
    end;
    // the one OPTIONAL row of the source mode: dependencies that are not
    // installed yet do not stop anyone opening or inspecting the project,
    // and installing them is what CAP-10C/D will do. A warning says so; a
    // failure would be this doctor overstating its own requirement.
    if (Project.FrontendRootPath.MissingSegments = 0) and
       (Env.NodeKind(PWebCliJoin(Project.FrontendRootPath.Full,
          'node_modules')) = pcnDirectory) then
      Add(b, 'frontend.dependencies', pdsPass, pdvOptional, 'ok',
        'the frontend dependencies are installed', Project.FrontendRoot,
        'node_modules present in the frontend root', '', '')
    else
      Add(b, 'frontend.dependencies', pdsWarning, pdvOptional,
        'not_installed',
        'the frontend dependencies are not installed yet',
        Project.FrontendRoot, 'node_modules present in the frontend root',
        'run npm ci in the frontend root', '');
  end
  else
  begin
    Add(b, 'frontend.dependencies', pdsNotApplicable, pdvOptional,
      'ui_not_react',
      'installed npm dependencies apply only to a React project',
      '', '', '', '');
    Add(b, 'frontend.node', pdsNotApplicable, pdvRequired, 'ui_not_react',
      'Node.js is required only for a React project', '', '', '', '');
    Add(b, 'frontend.npm', pdsNotApplicable, pdvRequired, 'ui_not_react',
      'npm is required only for a React project', '', '', '', '');
    Add(b, 'frontend.lockfile', pdsNotApplicable, pdvRequired,
      'ui_not_react',
      'a package lockfile is required only for a React project',
      '', '', '', '');
  end;

  if ok and (Project.Ui = puiPas2js) then
    AddToolRow(b, Env, 'frontend.pas2js', PWEB_CLI_TOOL_PAS2JS, '-iV',
      Project.Root, 'Pas2JS ' + PWEB_CLI_PAS2JS_VERSION + ' exactly',
      'install the pinned Pas2JS ' + PWEB_CLI_PAS2JS_VERSION,
      {ExactVersion=}True, PWEB_CLI_PAS2JS_VERSION)
  else
    Add(b, 'frontend.pas2js', pdsNotApplicable, pdvRequired, 'ui_not_pas2js',
      'Pas2JS is required only for a Pas2JS project', '', '', '', '');

  SortById(b.Report.Checks);
  b.Report.Status := pdsPass;
  for i := 0 to High(b.Report.Checks) do
  begin
    case b.Report.Checks[i].Status of
      pdsPass:          Inc(b.Report.CountPass);
      pdsNotApplicable: Inc(b.Report.CountNotApplicable);
      pdsWarning:       Inc(b.Report.CountWarning);
      pdsFail:          Inc(b.Report.CountFail);
    end;
    if b.Report.Checks[i].Status > b.Report.Status then
      b.Report.Status := b.Report.Checks[i].Status;
    if (b.Report.Checks[i].Status = pdsFail) and
       (b.Report.Checks[i].Severity = pdvRequired) and
       b.Report.Checks[i].ProbeFailure then
      b.Report.ProbeFailure := True;
  end;
  // not_applicable is not a worse outcome than pass: it is an absence of a
  // question, and a report made only of pass and not_applicable is healthy
  if b.Report.Status = pdsNotApplicable then
    b.Report.Status := pdsPass;
  Result := b.Report;
end;

end.
