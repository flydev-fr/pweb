program pweb;

{ The PWeb application lifecycle CLI (CAP-10A, CAP-10B1).

    pweb --help
    pweb --version
    pweb create NAME --ui react --bundle-id <reverse.dns>
    pweb create --help
    pweb doctor [--json] [--with-paths] [--project <path>] [--no-color]
                [--verbose]

  WHAT THIS BUILD IS. One native FPC console executable, the public entry
  point of the framework. It can diagnose a machine against a project, and
  since CAP-10B1 it can create one.

  WHAT IT IS NOT, AND SAYS SO BY BEING SILENT. `dev`, `run` and `build` are
  unknown commands here. They are not stubs, not "not implemented in this
  build" placeholders, and they are not listed in --help - because a command
  that parses is a promise, and a lifecycle CLI that promises a build it
  cannot perform is worse than one that has not got there yet.

  THE PROCESS IS STILL INERT. It opens no socket, resolves no host, downloads
  nothing and installs nothing. `create` writes exactly one tree - the
  project it was asked for, through the frozen CAP-10B0 transaction - and
  writes nothing anywhere else: not a lock file, not the registry, not PATH,
  not a temporary probe file. The only thing this CLI ever starts is a
  version probe of a tool it found on PATH, from `doctor`, by exact absolute
  path, with an argument array, bounded, with no shell anywhere
  (pweb.cli.probe). `create` starts nothing at all.

  THE EXIT CODE IS THE CONTRACT, and the human text never changes it:

      0  success
      2  usage error          - the command line was refused
      3  project error        - no usable pweb.json, or a destination that
                                cannot become one
      4  environment error    - a required check failed, or the SDK's own
                                trusted resources are missing or untrusted
      5  probe error          - a required probe could not be run or bounded
      6  internal error       - an unexpected failure, reported without a
                                stack trace

  Precedence is 6 > 5 > 4 > 3 > 2 > 0. Warnings never change the code.
  `create` cannot produce a 5: it starts no child process, so there is no
  probe for one to come from.

  THE WORKING DIRECTORY IS READ EXACTLY ONCE, at startup, by the ONE seam in
  Main. `doctor` uses it to seed the upward search for a descriptor and
  `create` uses it as the destination's parent. From that moment the
  canonical root is the only anchor: no later path resolution consults the
  CWD, nothing re-reads it, and the process never changes it. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  sysutils,
  mormot.core.base,
  pweb.assets.intf,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.probe,
  pweb.cli.toolchain,
  pweb.cli.doctor,
  pweb.cli.report,
  pweb.cli.sdk,
  pweb.cli.template,
  pweb.cli.scaffold,
  pweb.cli.write,
  pweb.cli.args;

const
  PWEB_EXIT_OK = 0;
  PWEB_EXIT_USAGE = 2;
  PWEB_EXIT_PROJECT = 3;
  PWEB_EXIT_ENVIRONMENT = 4;
  PWEB_EXIT_PROBE = 5;
  PWEB_EXIT_INTERNAL = 6;

{ The GENERATED trust anchor, compiled in with -Fi under WRITEABLECONST OFF.
  It is not read from a file at runtime, it is not committed, and it is not
  configuration: the build produces it from the trusted template source, and
  a CLI that cannot compile it is a CLI whose pack nobody generated.

  This include is the ONLY thing that decides what `create` can produce. The
  pack beside the executable carries bytes; every name, output path, content
  kind, file mode, byte length, digest and template id lives here. }
{$I pweb.templates.registry.inc}

procedure Emit(const Text: RawUtf8);
begin
  // one write path for the whole CLI, so "no ANSI when redirected" is a
  // property of the RENDERER and not of a dozen scattered WriteLn calls
  Write(string(Text));
end;

procedure EmitErr(const Text: RawUtf8);
begin
  Write(StdErr, string(Text));
end;

{ The compiled registry, assembled once from the generated constants. It is
  passed as a PARAMETER everywhere below rather than read from a global by
  the engine, so nothing can ever consult a second, softer registry. }
function CreateRegistry: TPWebTemplateRegistry;
begin
  Result := PWebTplRegistryFrom(PWEB_TPL_GEN_PACK_FILE,
    PWEB_TPL_GEN_PACK_SHA256, PWEB_TPL_GEN_PACK_BYTES,
    PWEB_TPL_GEN_INVENTORY_DIGEST, PWEB_TPL_GEN_INVENTORY,
    PWEB_TPL_GEN_FILES, PWEB_TPL_GEN_TEMPLATES);
end;

procedure CreateRefused(const Cause, Detail: RawUtf8);
begin
  EmitErr('pweb: create failed: ' + Cause);
  if Detail <> '' then
    EmitErr(': ' + Detail);
  EmitErr(#10);
end;

{ The template layer's runtime codes, mapped onto the frozen taxonomy.

  Two of them are USAGE and the rest are ENVIRONMENT, and the split is the
  whole point: "this build has no such frontend" is something the person at
  the keyboard typed, while "the pack beside the executable does not match
  the registry compiled into it" is something about the installation. A
  reader who gets 4 for a typo learns nothing and starts reinstalling. }
function ExitForTplCode(Code: TPWebTplCode): Integer;
begin
  case Code of
    ptcTemplateUnknown,
    ptcTemplatePrivate:
      Result := PWEB_EXIT_USAGE;
  else
    Result := PWEB_EXIT_ENVIRONMENT;
  end;
end;

{ The scaffold layer's codes. Only two of them can be caused by the command
  line - the NAME and the bundle identifier - and both are refused before any
  of this runs. Everything else here is reachable only if a pack that passed
  its own digest disagreed with the registry compiled into this executable,
  which is an invariant failure rather than anything a user did. }
function ExitForScaffoldCode(Code: TPWebScaffoldCode): Integer;
begin
  case Code of
    pscName,
    pscBundleId,
    pscTemplate:
      Result := PWEB_EXIT_USAGE;
  else
    Result := PWEB_EXIT_INTERNAL;
  end;
end;

{ The transaction's refusals. Every one of them is about the DESTINATION -
  its parent, its name, its staging sibling or the commit - so every one of
  them is a project error. The single exception is the generated descriptor
  failing the frozen reader, which says the generator and the reader
  disagree and is nobody's project. }
function ExitForCreateRefusal(Refusal: TPWebCreateRefusal): Integer;
begin
  case Refusal of
    pcwDescriptor:
      Result := PWEB_EXIT_INTERNAL;
  else
    Result := PWEB_EXIT_PROJECT;
  end;
end;

function Pad(const S: RawUtf8; Width: Integer): RawUtf8;
begin
  Result := S;
  while Length(Result) < Width do
    Result := Result + ' ';
end;

{ `pweb create NAME --ui react --bundle-id <id>`.

  The sequence is the frozen CAP-10B0 one and this function adds nothing to
  it: validate the identity, resolve the SDK from the running image, verify
  the pack against the compiled registry, build the complete plan in memory,
  and hand it to the one unit that can create anything. There is no second
  renderer and no second writer here - a dispatch layer that writes files is
  a dispatch layer that will one day write different ones.

  StartDir is the ONE reading of the working directory, made by Main. }
function RunCreate(const Args: TPWebCliArgs; const StartDir: RawUtf8): Integer;
var
  reg: TPWebTemplateRegistry;
  parent, packPath, detail, packSha: RawUtf8;
  packData: RawByteString;
  sdkRefusal: TPWebSdkRefusal;
  tplCode: TPWebTplCode;
  scaffoldCode: TPWebScaffoldCode;
  store: IAssetStore;
  index: Integer;
  identity: TPWebScaffoldIdentity;
  plan: TPWebCreationPlan;
  res: TPWebCreateResult;
begin
  // 1. the identity, refused before anything is read from a disk. The
  // grammars belong to the engine and to the descriptor reader; this
  // function only decides which exit code they mean
  if not PWebScaffoldNameValid(Args.Name) then
  begin
    CreateRefused('invalid_name', Args.Name);
    exit(PWEB_EXIT_USAGE);
  end;
  if not PWebCliValidBundleId(Args.BundleId) then
  begin
    CreateRefused('invalid_bundle_id', Args.BundleId);
    exit(PWEB_EXIT_USAGE);
  end;
  // 2. the destination's parent: the captured working directory, made
  // canonical exactly once. Nothing below re-reads it
  if not PWebCliCanonicalDir(StartDir, parent) then
  begin
    CreateRefused('working_directory', '');
    exit(PWEB_EXIT_PROJECT);
  end;
  // 3. the SDK, from the RUNNING IMAGE and never from the environment
  if not PWebCliTemplatePack(packPath, sdkRefusal) then
  begin
    CreateRefused(PWebSdkRefusalText(sdkRefusal), '');
    exit(PWEB_EXIT_ENVIRONMENT);
  end;
  // 4. the pack, read ONCE while hashing, then verified against the
  // compiled registry over those same bytes
  reg := CreateRegistry;
  if not PWebTplLoadPack(packPath, packData, packSha, tplCode) then
  begin
    CreateRefused(PWebTplCodeText(tplCode), '');
    exit(ExitForTplCode(tplCode));
  end;
  if not PWebTplVerifyPack(reg, packData, packSha, store, tplCode,
       detail) then
  begin
    CreateRefused(PWebTplCodeText(tplCode), detail);
    exit(ExitForTplCode(tplCode));
  end;
  // RequirePublic: a private template is unreachable from a public command
  // even by exact name, and it has its own refusal so the two cases stay
  // distinguishable
  if not PWebTplFind(reg, Args.Ui, {RequirePublic=}True, index, tplCode) then
  begin
    CreateRefused(PWebTplCodeText(tplCode), Args.Ui);
    exit(ExitForTplCode(tplCode));
  end;
  // the registry is compiled in, so an id whose declared UI disagrees with
  // the option that selected it cannot come from a user - it would be this
  // build contradicting itself
  if reg.Templates[index].Ui <> Args.Ui then
  begin
    CreateRefused('registry_ui_mismatch', Args.Ui);
    exit(PWEB_EXIT_INTERNAL);
  end;
  // 5. the identity projection and the complete plan, both in memory
  if not PWebScaffoldIdentityOf(Args.Name, Args.BundleId,
       reg.Templates[index].Ui, identity, scaffoldCode) then
  begin
    CreateRefused(PWebScaffoldCodeText(scaffoldCode), '');
    exit(ExitForScaffoldCode(scaffoldCode));
  end;
  if not PWebBuildPlan(reg, index, store, identity, plan, scaffoldCode,
       detail) then
  begin
    CreateRefused(PWebScaffoldCodeText(scaffoldCode), detail);
    exit(ExitForScaffoldCode(scaffoldCode));
  end;
  // 6. the transaction. On any failure the destination is ABSENT
  if not PWebCreateProject(parent, Args.Name, plan,
       reg.Templates[index], res) then
  begin
    CreateRefused(PWebCreateRefusalText(res.Refusal), res.Detail);
    if res.StageLeaked then
      EmitErr('pweb: a staging directory was left behind: ' +
        res.StagePath + #10);
    exit(ExitForCreateRefusal(res.Refusal));
  end;
  // 7. the report. Deliberately plain: no colour on any stream, no absolute
  // path, no SDK location, no registry digest. The destination is always
  // NAME inside the working directory, so naming it relatively is both the
  // whole truth and the one form that is identical on every machine
  Emit('pweb: created ' + identity.ProjectName + #10);
  Emit('  ' + Pad('ui', 13) + identity.UiKind + #10);
  Emit('  ' + Pad('bundle id', 13) + identity.BundleId + #10);
  Emit('  ' + Pad('directory', 13) + identity.ProjectName + #10);
  Emit('  ' + Pad('files', 13) +
    RawUtf8(IntToStr(res.FilesWritten)) + #10);
  Result := PWEB_EXIT_OK;
end;

function RunDoctor(const Args: TPWebCliArgs; const StartDir: RawUtf8): Integer;
var
  project: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  report: TPWebCliReport;
  options: TPWebCliRenderOptions;
begin
  project := PWebCliOpenProject(Args.ProjectPath, StartDir);
  env := PWebCliRealEnv;
  report := PWebCliDoctorRun(env, project, pdmSource);
  options.Verbose := Args.Verbose;
  options.WithPaths := Args.WithPaths;
  // colour is the conjunction of every condition, evaluated once: a
  // terminal that accepted the request, no --no-color, and never in JSON
  options.Color := (not Args.Json) and (not Args.NoColor) and
    PWebCliAnsiSupported;
  if Args.Json then
    Emit(PWebCliRenderJson(report, project, env, options))
  else
    Emit(PWebCliRenderHuman(report, project, env, options));
  // precedence, highest first. A project refusal outranks an environment
  // one because everything below it was diagnosed without a project.
  if project.Refusal <> pcrNone then
    exit(PWEB_EXIT_PROJECT);
  if report.ProbeFailure then
    exit(PWEB_EXIT_PROBE);
  if report.CountFail > 0 then
    exit(PWEB_EXIT_ENVIRONMENT);
  Result := PWEB_EXIT_OK;
end;

function Main: Integer;
var
  args: TPWebCliArgs;
  startDir: RawUtf8;
begin
  PWebCliPrepareConsole;
  args := PWebCliParseArgs(PWebCliRawArgs);
  if args.Usage <> pcuNone then
  begin
    EmitErr('pweb: ' + PWebCliUsageText(args.Usage));
    if args.Detail <> '' then
      EmitErr(': ' + args.Detail);
    EmitErr(#10#10);
    if args.Command = pccCreate then
      EmitErr(PWebCliCreateHelp)
    else
      EmitErr(PWebCliUsageBanner);
    exit(PWEB_EXIT_USAGE);
  end;
  // --help and --version are complete requests: they answer on stdout and
  // do nothing else, whatever command also appeared on the line. A command
  // that was named gets ITS help, because that is the question that was
  // asked
  if args.Help then
  begin
    if args.Command = pccCreate then
      Emit(PWebCliCreateHelp)
    else
      Emit(PWebCliUsageBanner);
    exit(PWEB_EXIT_OK);
  end;
  if args.Version then
  begin
    Emit(PWebCliVersionLine + #10);
    exit(PWEB_EXIT_OK);
  end;
  // THE ONE reading of the working directory in the whole process. Both
  // commands are handed the same captured value and neither of them, nor
  // anything they call, ever asks the operating system again
  if not PWebCliCwd(startDir) then
  begin
    EmitErr('pweb: the working directory could not be resolved'#10);
    exit(PWEB_EXIT_INTERNAL);
  end;
  case args.Command of
    pccCreate: Result := RunCreate(args, startDir);
    pccDoctor: Result := RunDoctor(args, startDir);
  else
    // unreachable: the parser refuses a line with no command
    Result := PWEB_EXIT_INTERNAL;
  end;
end;

begin
  try
    ExitCode := Main;
  except
    on E: Exception do
    begin
      // no stack trace, no exception class name, no path: an internal
      // failure is a category, and the CLI is not a debugger
      EmitErr('pweb: internal error'#10);
      ExitCode := PWEB_EXIT_INTERNAL;
    end;
  end;
end.
