{
  pweb.cli.toolset - the toolchain one build needs, resolved once (CAP-10C1).

  THE PIPELINE FAILS CLOSED BEFORE IT WRITES ANYTHING. Every executable it
  will ever spawn is resolved here, in one pass, before the first byte is
  staged: a machine that cannot build this project says so at stage 2 rather
  than after `npm ci` has already populated node_modules.

  ---------------------------------------------------------------------------
  ONE SOURCE OF TRUTH FOR VERSIONS, AND IT IS THE DOCTOR
  ---------------------------------------------------------------------------

  This unit does NOT re-implement "is FPC new enough" or "is this exactly
  Pas2JS 3.0.1". `pweb doctor` already answers that, against the pinned
  constants in pweb.cli.toolchain that CI cross-checks against fpc.lock,
  pas2js.lock and webview.lock. So the pipeline RUNS the doctor's own
  requirement graph and adopts its verdict: any REQUIRED row that fails is a
  pipeline refusal carrying THE SAME CAUSE, and the pipeline stops.

  Two answers to one question is how a build and a diagnosis start
  disagreeing about the same machine, and the version a user is shown by
  `pweb doctor` has to be the version the build refused on.

  ---------------------------------------------------------------------------
  WHAT THIS UNIT DOES ADD
  ---------------------------------------------------------------------------

  The doctor reports; a build has to SPAWN. So beyond the verdict this unit
  resolves the exact executables:

    node     the canonical path PATH resolves, by the CAP-10A rule
    npm      NOT an executable at all - the JavaScript entry point, run as
             `node <npm-cli.js>` (below)
    fpc      the canonical path, plus its OWN target (-iTO / -iTP), which is
             checked against the host: a compiler that targets something
             else can produce an executable this layout will never run
    pas2js   the canonical path, for a pas2js project only

  A candidate that resolves INSIDE the canonical project root is reported
  with its path and NEVER executed, exactly as the doctor refuses it. Schema
  1 has no toolchain model, so a `node` sitting in the project is an
  unexplained binary with a familiar name.

  ---------------------------------------------------------------------------
  npm, THROUGH node, BY THE RULE CAP-10C0 RATIFIED
  ---------------------------------------------------------------------------

      D = the directory of the canonical node executable
      Windows   D\node_modules\npm\bin\npm-cli.js
      POSIX     parent(D)/lib/node_modules/npm/bin/npm-cli.js

  Each component is walked through PWebCliEntry, so a redirected `npm` is
  refused rather than followed, and the resolved script is probed as
  `node <npm-cli.js> --version` through the engine's probe profile.

  WHY NOT npm ITSELF. On Windows npm's only entry point on PATH is npm.cmd, a
  BATCH FILE, which the CAP-10C0 engine refuses before any spawn on EVERY
  platform - a batch file is interpreted by a shell, and this CLI has no
  shell and will not grow one. `node <npm-cli.js>` is the same program,
  reached without one.

  When the script is not where the rule says (a Volta shim, an unusual
  distribution layout) this is a REFUSAL, not a fallback: a React build that
  cannot install its dependencies has not got a slower path, it has no path.
  `pweb doctor` keeps its presence row - it diagnoses, and presence is what
  it can honestly claim on every platform.
}
unit pweb.cli.toolset;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.probe,
  pweb.cli.stage,
  pweb.cli.project,
  pweb.cli.doctor,
  pweb.cli.sdkmanifest;

const
  /// the doctor row a BUILD does not depend on - see FirstRequiredFailure
  PWEB_CLI_ROW_WEBVIEW = 'platform.webview';

  /// the components of the npm entry-point rule, spelled once
  PWEB_NPM_NODE_MODULES = 'node_modules';
  PWEB_NPM_LIB = 'lib';
  PWEB_NPM_DIR = 'npm';
  PWEB_NPM_BIN = 'bin';
  PWEB_NPM_CLI = 'npm-cli.js';

type
  /// which tool a refusal is about
  TPWebCliToolKind = (ptkNone, ptkNode, ptkNpm, ptkFpc, ptkPas2js);

  /// why the toolchain cannot drive a build - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebCliToolRefusal = (
    ptrNone,
    /// a required row of the CAP-10A requirement graph failed; the row's
    /// own cause is carried in DoctorCause
    ptrDoctorRefused,
    /// no runnable executable of that name exists on PATH
    ptrNotFound,
    /// the candidate resolves inside the project root: reported, NOT run
    ptrInsideProject,
    /// the tool could not be probed (spawn, bound, or a death)
    ptrProbeFailed,
    /// the npm JavaScript entry point is not where the ratified rule says
    ptrNpmCliUnresolved,
    /// the compiler targets something other than this host
    ptrTargetMismatch);

  /// one resolved tool
  TPWebCliTool = record
    Kind: TPWebCliToolKind;
    /// ptrNone when Path (and, for npm, Script) is usable
    Refusal: TPWebCliToolRefusal;
    /// canonical absolute path of the executable that WILL be spawned
    Path: RawUtf8;
    /// npm only: the resolved JavaScript entry point
    Script: RawUtf8;
    /// what the probe read back, '' when nothing was probed
    Version: RawUtf8;
    /// how many FURTHER distinct executables of this name PATH carries
    Duplicates: Integer;
  end;

  /// everything one build's toolchain resolution learned
  TPWebCliToolset = record
    /// ptrNone when every tool this project needs is usable
    Refusal: TPWebCliToolRefusal;
    /// which tool refused (ptkNone for a doctor refusal)
    Failed: TPWebCliToolKind;
    /// the failing doctor row's id and cause, '' when the doctor passed
    DoctorRow: RawUtf8;
    DoctorCause: RawUtf8;
    /// the worst status the requirement graph reported
    DoctorStatus: TPWebCliStatus;
    /// `platform.webview`'s own status/cause - RESOLVED and recorded, and
    // deliberately not build-blocking: it asks whether this machine can
    // DISPLAY a WebView, which is what running needs and not what compiling
    // needs
    WebviewRow: RawUtf8;
    Node: TPWebCliTool;
    Npm: TPWebCliTool;
    Fpc: TPWebCliTool;
    Pas2js: TPWebCliTool;
    /// the compiler's own target, as it reports it (lowercased)
    FpcTargetOs: RawUtf8;
    FpcTargetCpu: RawUtf8;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliToolRefusalText(Refusal: TPWebCliToolRefusal): RawUtf8;

/// stable name of a tool
function PWebCliToolKindText(Kind: TPWebCliToolKind): RawUtf8;

/// the npm JavaScript entry point that belongs to ONE node executable
// - NodePath must be the canonical executable; every component is walked
// - False when the file is not where the ratified rule says it is
function PWebCliResolveNpmCli(const NodePath: RawUtf8; Windows: Boolean;
  out Script: RawUtf8): Boolean;

/// the FPC target names this host must see from its compiler
procedure PWebCliExpectedFpcTarget(Os: TPWebCliOs; Arch: TPWebCliArch;
  out TargetOs, TargetCpu: RawUtf8);

/// resolve everything one build of this project needs
// - runs the CAP-10A requirement graph first and adopts its verdict, so a
// machine the doctor refuses is refused here with the same cause, before
// any tool is spawned and before anything is written
function PWebCliResolveToolset(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch): TPWebCliToolset;

/// the SDK's OWN integrity, asked before anything else (CAP-10D2)
// - this is the earliest question a build can ask, and it is deliberately
// earlier than the requirement graph: a toolchain that cannot vouch for its
// own bytes has no business diagnosing a machine, and the answer costs
// three directory reads on an unpackaged root
// - False with the machine-stable cause and the logical detail when the
// running executable's SDK carries a manifest that does not describe it. An
// SDK with NO manifest is accepted: see pweb.cli.sdkmanifest's header
function PWebCliSdkPreflight(out Cause, Detail: RawUtf8): Boolean;


implementation

function PWebCliToolRefusalText(Refusal: TPWebCliToolRefusal): RawUtf8;
begin
  case Refusal of
    ptrNone:              Result := 'ok';
    ptrDoctorRefused:     Result := 'doctor_refused';
    ptrNotFound:          Result := 'tool_not_found';
    ptrInsideProject:     Result := 'tool_inside_project';
    ptrProbeFailed:       Result := 'tool_probe_failed';
    ptrNpmCliUnresolved:  Result := 'npm_cli_unresolved';
    ptrTargetMismatch:    Result := 'tool_target_mismatch';
  else
    Result := 'toolchain_refused';
  end;
end;

function PWebCliToolKindText(Kind: TPWebCliToolKind): RawUtf8;
begin
  case Kind of
    ptkNode:   Result := PWEB_CLI_TOOL_NODE;
    ptkNpm:    Result := PWEB_CLI_TOOL_NPM;
    ptkFpc:    Result := PWEB_CLI_TOOL_FPC;
    ptkPas2js: Result := PWEB_CLI_TOOL_PAS2JS;
  else
    Result := '';
  end;
end;

function PWebCliResolveNpmCli(const NodePath: RawUtf8; Windows: Boolean;
  out Script: RawUtf8): Boolean;
var
  dir, name, base, cur: RawUtf8;
begin
  Script := '';
  Result := False;
  if not PWebCliSplitLast(NodePath, dir, name) then
    exit;
  if Windows then
    // a Windows Node install carries its own node_modules beside node.exe
    base := dir
  else
    // a POSIX install is <prefix>/bin/node with <prefix>/lib/node_modules
    if not PWebCliParentDir(dir, base) then
      exit;
  cur := base;
  if not Windows then
  begin
    if PWebCliEntry(cur, PWEB_NPM_LIB) <> pcnDirectory then
      exit;
    cur := PWebCliJoin(cur, PWEB_NPM_LIB);
  end;
  if PWebCliEntry(cur, PWEB_NPM_NODE_MODULES) <> pcnDirectory then
    exit;
  cur := PWebCliJoin(cur, PWEB_NPM_NODE_MODULES);
  if PWebCliEntry(cur, PWEB_NPM_DIR) <> pcnDirectory then
    exit;
  cur := PWebCliJoin(cur, PWEB_NPM_DIR);
  if PWebCliEntry(cur, PWEB_NPM_BIN) <> pcnDirectory then
    exit;
  cur := PWebCliJoin(cur, PWEB_NPM_BIN);
  if PWebCliEntry(cur, PWEB_NPM_CLI) <> pcnFile then
    exit;
  Script := PWebCliJoin(cur, PWEB_NPM_CLI);
  Result := True;
end;

procedure PWebCliExpectedFpcTarget(Os: TPWebCliOs; Arch: TPWebCliArch;
  out TargetOs, TargetCpu: RawUtf8);
begin
  // FPC's own spellings, which are neither the CAP-10C0 target name nor
  // mORMot's static-directory name. Three namings of one target is a fact
  // about the toolchain; each is written down exactly once
  case Os of
    pcoWindows: TargetOs := 'win64';
    pcoMacos:   TargetOs := 'darwin';
  else
    TargetOs := 'linux';
  end;
  if Arch = pcaArm64 then
    TargetCpu := 'aarch64'
  else
    TargetCpu := 'x86_64';
end;

// the first REQUIRED row that failed AND that a BUILD depends on, in the
// report's own (id) order, so a machine with several problems always names
// the same one
//
// WHY ONE ROW IS EXCLUDED. `platform.webview` asks whether this machine can
// DISPLAY a WebView: the Evergreen runtime on Windows, WebKitGTK on Linux,
// the WebKit framework on macOS. That is a requirement of RUNNING a built
// application - `pweb run`'s, and the doctor reports it for exactly that
// reason - and not of compiling one. A compiler needs the binding SOURCES,
// which are in the SDK root, not the engine.
//
// MEASURED, and this is why the distinction is drawn rather than assumed:
// hosted run 33674212855 refused both macOS pipelines at stage 2 with
// `framework_absent`, on runners where the CAP-10B1 and CAP-10B2 harnesses
// build and run the same projects successfully. A build that refuses because
// a DISPLAY requirement was not met is a build refusing the wrong question.
// The row is still RESOLVED and recorded as an observation, so nothing is
// hidden: it simply does not block a compile.
function FirstRequiredFailure(const Report: TPWebCliReport;
  out Id, Cause, WebviewStatus: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Id := '';
  Cause := '';
  WebviewStatus := '';
  Result := False;
  for i := 0 to High(Report.Checks) do
  begin
    if Report.Checks[i].Id = PWEB_CLI_ROW_WEBVIEW then
      WebviewStatus := PWebCliStatusText(Report.Checks[i].Status) + '/' +
        Report.Checks[i].Cause;
    if Result or
       (Report.Checks[i].Severity <> pdvRequired) or
       (Report.Checks[i].Status <> pdsFail) or
       (Report.Checks[i].Id = PWEB_CLI_ROW_WEBVIEW) then
      continue;
    Id := Report.Checks[i].Id;
    Cause := Report.Checks[i].Cause;
    Result := True;
  end;
end;

// resolve ONE executable and read a version out of it, with the
// inside-the-project refusal the CAP-10A rule demands
function ResolveOne(Kind: TPWebCliToolKind; const Tool, ProjectRoot: RawUtf8;
  const Arg: RawUtf8): TPWebCliTool;
var
  probe: TPWebCliProbe;
  version: RawUtf8;
begin
  Result := Default(TPWebCliTool);
  Result.Kind := Kind;
  probe := PWebCliProbeTool(Tool, ProjectRoot, [Arg],
    PWEB_CLI_PROBE_TIMEOUT_MS);
  Result.Path := probe.Path;
  Result.Duplicates := probe.Duplicates;
  case probe.Outcome of
    ppoInsideProject:
      Result.Refusal := ptrInsideProject;
    ppoNotFound:
      Result.Refusal := ptrNotFound;
    ppoCompleted:
      if probe.ExitCode <> 0 then
        Result.Refusal := ptrProbeFailed
      else
      begin
        if PWebCliNormalizeVersion(probe.Output, version) then
          Result.Version := version
        else
          Result.Version := '';
        Result.Refusal := ptrNone;
      end;
  else
    Result.Refusal := ptrProbeFailed;
  end;
end;

// one bounded probe of an EXACT executable with an EXACT vector, used where
// the answer is not a version (fpc -iTO / -iTP) or where the executable is
// node and the vector names a script
function ProbeExact(const ExePath: RawUtf8;
  const Args: array of RawUtf8; out Text: RawUtf8): Boolean;
var
  probe: TPWebCliProbe;
  i: PtrInt;
begin
  Text := '';
  probe := PWebCliRunProbe(ExePath, Args, PWEB_CLI_PROBE_TIMEOUT_MS);
  Result := (probe.Outcome = ppoCompleted) and
            (probe.ExitCode = 0);
  if not Result then
    exit;
  Text := probe.Output;
  // one line, trimmed of every trailing control byte: `fpc -iTO` answers
  // with a bare token and a newline whose spelling differs per platform
  for i := Length(Text) downto 1 do
    if Text[i] > ' ' then
    begin
      Text := Copy(Text, 1, i);
      break;
    end
    else if i = 1 then
      Text := '';
end;

function LowerAsciiU(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A' .. 'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function PWebCliSdkPreflight(out Cause, Detail: RawUtf8): Boolean;
var
  fact: TPWebCliSdkFact;
begin
  Cause := '';
  Detail := '';
  fact := PWebCliSdkVerify(PWEB_CLI_VERSION);
  Result := PWebCliSdkFactAccepted(fact);
  if Result then
    exit;
  Cause := PWebCliSdkFactCause(fact);
  Detail := fact.Detail;
end;

function PWebCliResolveToolset(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch): TPWebCliToolset;
var
  report: TPWebCliReport;
  wantOs, wantCpu, text: RawUtf8;
begin
  Result := Default(TPWebCliToolset);
  Result.Refusal := ptrNone;
  Result.Failed := ptkNone;

  // 1. the CAP-10A requirement graph, adopted whole. Its verdict is the
  // pipeline's verdict, and its cause is the pipeline's cause
  report := PWebCliDoctorRun(PWebCliRealEnv, Project, pdmSource);
  Result.DoctorStatus := report.Status;
  if FirstRequiredFailure(report, Result.DoctorRow, Result.DoctorCause,
       Result.WebviewRow) then
  begin
    Result.Refusal := ptrDoctorRefused;
    exit;
  end;

  // 2. the compiler, and the target it actually produces
  Result.Fpc := ResolveOne(ptkFpc, PWEB_CLI_TOOL_FPC, Project.Root, '-iV');
  if Result.Fpc.Refusal <> ptrNone then
  begin
    Result.Refusal := Result.Fpc.Refusal;
    Result.Failed := ptkFpc;
    exit;
  end;
  if ProbeExact(Result.Fpc.Path, ['-iTO'], text) then
    Result.FpcTargetOs := LowerAsciiU(text);
  if ProbeExact(Result.Fpc.Path, ['-iTP'], text) then
    Result.FpcTargetCpu := LowerAsciiU(text);
  PWebCliExpectedFpcTarget(Os, Arch, wantOs, wantCpu);
  // THE CHECK IS ONLY MEANINGFUL WHERE THE COMMAND DOES NOT SELECT THE
  // TARGET ITSELF. pweb.cli.native passes -Px86_64 -Twin64 on Windows, where
  // one installation routinely carries both compilers and the DEFAULT is
  // whichever the installer wrote last; on Linux and macOS it passes
  // neither, so there the default IS the target and a compiler that answers
  // something else would produce an executable the <os>-<arch> layout names
  // and this host can never launch. Recorded on every platform, refused only
  // where it decides anything
  if (Os <> pcoWindows) and
     ((Result.FpcTargetOs <> wantOs) or
      (Result.FpcTargetCpu <> wantCpu)) then
  begin
    Result.Refusal := ptrTargetMismatch;
    Result.Failed := ptkFpc;
    exit;
  end;

  // 3. the frontend toolchain, by UI kind. A Pas2JS project needs no Node
  // at any point of its pipeline, and resolving one would be inventing a
  // requirement the doctor itself reports as not applicable
  if Project.Ui = puiPas2js then
  begin
    Result.Pas2js := ResolveOne(ptkPas2js, PWEB_CLI_TOOL_PAS2JS,
      Project.Root, '-iV');
    if Result.Pas2js.Refusal <> ptrNone then
    begin
      Result.Refusal := Result.Pas2js.Refusal;
      Result.Failed := ptkPas2js;
    end;
    exit;
  end;

  Result.Node := ResolveOne(ptkNode, PWEB_CLI_TOOL_NODE, Project.Root,
    '--version');
  if Result.Node.Refusal <> ptrNone then
  begin
    Result.Refusal := Result.Node.Refusal;
    Result.Failed := ptkNode;
    exit;
  end;
  Result.Npm.Kind := ptkNpm;
  Result.Npm.Path := Result.Node.Path;
  if not PWebCliResolveNpmCli(Result.Node.Path, Os = pcoWindows,
       Result.Npm.Script) then
  begin
    Result.Npm.Refusal := ptrNpmCliUnresolved;
    Result.Refusal := ptrNpmCliUnresolved;
    Result.Failed := ptkNpm;
    exit;
  end;
  if not ProbeExact(Result.Node.Path, [PWebCliArgPath(Result.Npm.Script), '--version'],
       text) then
  begin
    Result.Npm.Refusal := ptrProbeFailed;
    Result.Refusal := ptrProbeFailed;
    Result.Failed := ptkNpm;
    exit;
  end;
  // RECORDED, never compared. No npm floor is pinned in any lock in this
  // repository, and a version this build invented a requirement for would be
  // exactly the number nobody cross-checks that pweb.cli.toolchain's header
  // forbids. What matters is that the entry point resolved and answered
  if not PWebCliNormalizeVersion(text, Result.Npm.Version) then
    Result.Npm.Version := '';
  Result.Npm.Refusal := ptrNone;
end;

end.
