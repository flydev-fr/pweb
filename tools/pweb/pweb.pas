program pweb;

{ The PWeb application lifecycle CLI (CAP-10A).

    pweb --help
    pweb --version
    pweb doctor [--json] [--with-paths] [--project <path>] [--no-color]
                [--verbose]

  WHAT THIS BUILD IS. One native FPC console executable, the public entry
  point of the framework. Everything a developer can ask of it today is
  diagnostic: what does this project declare, and can this machine build it.

  WHAT IT IS NOT, AND SAYS SO BY BEING SILENT. `create`, `dev`, `run` and
  `build` are unknown commands here. They are not stubs, not "not implemented
  in this build" placeholders, and they are not listed in --help - because a
  command that parses is a promise, and a lifecycle CLI that promises a
  scaffold it cannot produce is worse than one that has not got there yet.

  THE WHOLE PROCESS IS INERT. It opens no socket, resolves no host, downloads
  nothing, installs nothing, and writes not one byte anywhere: not the
  project, not a lock file, not the registry, not PATH, not a temporary probe
  file. The only thing it starts is a version probe of a tool it found on
  PATH, by exact absolute path, with an argument array, bounded, with no
  shell anywhere (pweb.cli.probe).

  THE EXIT CODE IS THE CONTRACT, and the human text never changes it:

      0  success
      2  usage error          - the command line was refused
      3  project error        - no usable pweb.json
      4  environment error    - a required check failed
      5  probe error          - a required probe could not be run or bounded
      6  internal error       - an unexpected failure, reported without a
                                stack trace

  Precedence is 6 > 5 > 4 > 3 > 2 > 0. Warnings never change the code.

  THE WORKING DIRECTORY IS READ EXACTLY ONCE, at startup, to seed the upward
  search for a descriptor. From that moment the canonical project root is the
  only anchor: no later path resolution consults the CWD, and the process
  never changes it. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.probe,
  pweb.cli.toolchain,
  pweb.cli.doctor,
  pweb.cli.report,
  pweb.cli.args;

const
  PWEB_EXIT_OK = 0;
  PWEB_EXIT_USAGE = 2;
  PWEB_EXIT_PROJECT = 3;
  PWEB_EXIT_ENVIRONMENT = 4;
  PWEB_EXIT_PROBE = 5;
  PWEB_EXIT_INTERNAL = 6;

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

function RunDoctor(const Args: TPWebCliArgs): Integer;
var
  startDir: RawUtf8;
  project: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  report: TPWebCliReport;
  options: TPWebCliRenderOptions;
begin
  // the ONE reading of the working directory in the whole process
  if not PWebCliCwd(startDir) then
  begin
    EmitErr('pweb: the working directory could not be resolved'#10);
    exit(PWEB_EXIT_INTERNAL);
  end;
  project := PWebCliOpenProject(Args.ProjectPath, startDir);
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
begin
  PWebCliPrepareConsole;
  args := PWebCliParseArgs(PWebCliRawArgs);
  if args.Usage <> pcuNone then
  begin
    EmitErr('pweb: ' + PWebCliUsageText(args.Usage));
    if args.Detail <> '' then
      EmitErr(': ' + args.Detail);
    EmitErr(#10#10);
    EmitErr(PWebCliUsageBanner);
    exit(PWEB_EXIT_USAGE);
  end;
  // --help and --version are complete requests: they answer on stdout and
  // do nothing else, whatever command also appeared on the line
  if args.Help then
  begin
    Emit(PWebCliUsageBanner);
    exit(PWEB_EXIT_OK);
  end;
  if args.Version then
  begin
    Emit(PWebCliVersionLine + #10);
    exit(PWEB_EXIT_OK);
  end;
  case args.Command of
    pccDoctor: Result := RunDoctor(args);
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
