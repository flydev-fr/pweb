program pweb;

{ The PWeb application lifecycle CLI (CAP-10A, CAP-10B1, CAP-10B2, CAP-10C0,
  CAP-10C2, CAP-10C3, CAP-10D0).

    pweb --help
    pweb --version
    pweb create NAME --ui react|pas2js --bundle-id <reverse.dns>
    pweb create --help
    pweb doctor [--json] [--with-paths] [--project <path>] [--no-color]
                [--verbose]
    pweb run [--project <path>]
    pweb run --help
    pweb dev [--project <path>]
    pweb dev --help
    pweb build [--project <path>]
    pweb build --help

  WHAT THIS BUILD IS. One native FPC console executable, the public entry
  point of the framework, and with CAP-10D0 the whole of the CAP-10 surface.
  It diagnoses a machine against a project; since CAP-10B1 it creates one;
  since CAP-10C0 it launches the application a project has already built and
  supervises it; since CAP-10C2 and CAP-10C3 it DEVELOPS one of either
  frontend kind - build it, launch it, watch it, rebuild it and reload the
  running window without restarting it; and since CAP-10D0 it BUILDS one, by
  running the whole ten-stage lifecycle pipeline and leaving exactly the
  layout `run` resolves. `pweb create demo --ui react --bundle-id
  com.example.demo`, `pweb build`, `pweb run` is the entire path from
  nothing to a running application, with no script in between.

  WHAT IT IS NOT, AND SAYS SO BY BEING SILENT. `build` was an unknown
  command for four shards - not a stub, not a "not implemented in this
  build" placeholder, and not listed in --help - because a command that
  parses is a promise, and a lifecycle CLI that promises a build it cannot
  perform is worse than one that has not got there yet. It is a command here
  for exactly the same reason it was not before: this executable performs
  the whole of one. `dev` on a project whose `ui` is neither of the two
  ratified kinds is still refused with its own typed cause - CAP-10C2
  implemented react and CAP-10C3 pas2js, and the refusal stays for the next
  one.

  THE PROCESS OPENS NO SOCKET, resolves no host and listens on nothing - in
  development exactly as in production. `dev` starts no development server,
  no proxy and no HMR transport: the completion signal is a file the build
  writes (react) or a bounded content fingerprint of the ratified input set
  this CLI walks itself (pas2js), the switch is a directory rename, and the
  reload is a native re-navigation to pweb://app, which is the only origin
  this framework has. The ONE stage that may reach the network is the react
  dependency install, which is skipped whenever the lockfile and node_modules
  already agree; a pas2js session has no such stage at all.

  `create` writes exactly one tree - the project it was asked for, through
  the frozen CAP-10B0 transaction - and writes nothing anywhere else: not a
  lock file, not the registry, not PATH, not a temporary probe file.
  Everything this CLI ever starts goes through ONE execution engine
  (pweb.cli.process): a version probe from `doctor`, the built application
  from `run`, the toolchain, the watcher and the development host from
  `dev`, and the ten stages' children from `build` - each by exact absolute
  path, with an argument array, an explicit working directory and no shell
  anywhere. `create` starts nothing at all, and `build` starts nothing of
  its OWN: every child it has is one pweb.cli.pipeline runs, which stays the
  only unit in this repository that spawns anything.

  THE EXIT CODE IS THE CONTRACT, and the human text never changes it:

      0  success
      2  usage error          - the command line was refused
      3  project error        - no usable pweb.json, a destination that
                                cannot become one, or a layout that has not
                                been built or is not confined
      4  environment error    - a required check failed, the SDK's own
                                trusted resources are missing or untrusted,
                                or supervision cannot be established
      5  probe error          - a required probe could not be run or
                                bounded; for `run`, the application exited
                                nonzero, died by a signal or had to be
                                force-terminated (its real status is printed)
      6  internal error       - an unexpected failure, reported without a
                                stack trace

  Precedence is 6 > 5 > 4 > 3 > 2 > 0. Warnings never change the code.
  `create` cannot produce a 5: it starts no child process, so there is no
  probe for one to come from.

  THE WORKING DIRECTORY IS READ EXACTLY ONCE, at startup, by the ONE seam in
  Main. `doctor`, `run`, `dev` and `build` use it to seed the upward search
  for a descriptor and `create` uses it as the destination's parent. From
  that moment the canonical root is the only anchor: no later path
  resolution consults the CWD, nothing re-reads it, and the process never
  changes it - `run`'s child is started in the application's OWN directory
  and every stage of a `build` in the directory its plan builder named,
  never in this one. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$ifdef UNIX}
  { CAP-10C2: `dev` supervises two long-lived children on two threads, and
    FPC's Unix threading has to be armed by LINKING this unit - without it
    BeginThread dies with "This binary has no thread support". It must come
    FIRST in the uses clause, which is the RTL's own requirement, and it is
    inert on a run that starts no thread. }
  cthreads,
  {$endif UNIX}
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
  pweb.cli.process,
  pweb.cli.run,
  { CAP-10C2 LINKS THE LIFECYCLE PIPELINE AND THE DEV LOOP. CAP-10C1 froze
    them as PRIVATE and measured their absence from this executable's
    compiled unit set; `pweb dev` is what makes them public, so that
    measurement is re-based in the same commit - from "no pipeline unit is
    linked" to "every one of them is". `build` remained an unknown command
    for two more shards: linking the pipeline was not advertising a build,
    and CAP-10D0 is the shard that performs one. }
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.toolset,
  pweb.cli.frontend,
  pweb.cli.pack,
  pweb.cli.native,
  pweb.cli.layout,
  pweb.cli.pipeline,
  pweb.cli.devlayout,
  { CAP-10C3 adds the Pas2JS change detector beside them, and names it here
    rather than leaving it to reach the link through pweb.cli.dev: the
    linkage claim is a measurement over this executable's compiled unit set,
    and a unit that is only there transitively is a unit whose presence is an
    inference. }
  pweb.cli.devinputs,
  pweb.cli.dev,
  { CAP-10D0 adds the public build driver, and it is ONE unit deep: it calls
    pweb.cli.pipeline and reads a disk. Named here for the same reason
    pweb.cli.devinputs is - the linkage claim is a measurement over this
    executable's compiled unit set, and a unit that reaches the link only
    transitively is a unit whose presence is an inference. }
  pweb.cli.build,
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
  // property of the RENDERER and not of a dozen scattered WriteLn calls.
  // Flushed on every call: `run` forwards an application's lines as they
  // happen, and a pipe must see them then, not when a buffer fills
  Write(string(Text));
  Flush(Output);
end;

procedure EmitErr(const Text: RawUtf8);
begin
  Write(StdErr, string(Text));
  Flush(StdErr);
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

  ONE of them is USAGE and the rest are ENVIRONMENT, and the split is the
  whole point: "that template is not yours to ask for" is something the
  person at the keyboard typed, while "the pack beside the executable does
  not match the registry compiled into it" is something about the
  installation. A reader who gets 4 for a typo learns nothing and starts
  reinstalling.

  CAP-10B2 MOVED ptcTemplateUnknown from USAGE to ENVIRONMENT, and the
  reason is the allowlist rather than a change of mind. `--ui` is checked
  against a compiled set BEFORE any of this runs, so a typed frontend kind
  can no longer reach a template lookup at all: reaching it means the pack
  this installation carries does not describe a template this build
  advertises, which is the same class of fact as `sdk_share_missing` and
  `pack_size` and is nothing the user did. test/cap10b2 proves it by
  compiling a second CLI against a react-only pack rather than by asserting
  it - a refusal nobody has watched fire is a comment. }
function ExitForTplCode(Code: TPWebTplCode): Integer;
begin
  case Code of
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

{ `pweb create NAME --ui react|pas2js --bundle-id <id>`.

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

{ `pweb run [--project <path>]`.

  Resolve the project exactly as doctor does, resolve the built layout
  beneath its `output` by the one ratified rule (pweb.cli.run), and hand the
  executable to the one execution engine in its supervise profile. This
  function decides exit codes and prints the supervisor's own lines; it
  never builds, never touches the layout, and passes the application no
  argument.

  THE EXIT MAPPING (ratified at the CAP-10C0 checkpoint):

      0  the application exited 0, after a normal or a requested shutdown
      2  usage
      3  the project was refused, or the layout is absent / not confined
      4  supervision prerequisites unavailable (stop handler, pipes, Job
         Object, process creation)
      5  the application exited nonzero, died by a signal, or had to be
         force-terminated - its real status is printed
      6  internal: a refusal that cannot arise from a ratified layout, or a
         child the platform could not reap

  The human text never changes the category, and the category never
  depends on what the application printed. }

procedure RunRefused(const Cause, Detail: RawUtf8);
begin
  EmitErr('pweb: run refused: ' + Cause);
  if Detail <> '' then
    EmitErr(': ' + Detail);
  EmitErr(#10);
end;

// the forwarding sink: the application's lines, verbatim, each on its own
// stream, each re-terminated with one LF. A line the engine had to cut is
// marked so the reader knows it is looking at a bounded head
procedure ForwardLine(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  text: RawUtf8;
begin
  text := Line;
  if Truncated then
    text := text + ' [truncated by pweb]';
  if Stream = pcsStdOut then
    Emit(text + #10)
  else
    EmitErr(text + #10);
end;

// the pid, so a supervisor of the supervisor (the CAP-10C0 test driver, a
// script) can watch the application itself and not only pweb
procedure ApplicationStarted(Opaque: Pointer; Pid: PtrInt);
begin
  EmitErr('pweb: started pid ' + RawUtf8(IntToStr(Pid)) + #10);
end;

function RunRun(const Args: TPWebCliArgs; const StartDir: RawUtf8): Integer;
var
  project: TPWebCliProject;
  layout: TPWebCliRunLayout;
  r: TPWebCliExecResult;
  i, forced: PtrInt;
begin
  project := PWebCliOpenProject(Args.ProjectPath, StartDir);
  if project.Refusal <> pcrNone then
  begin
    // the detail of a project refusal may be a path; the doctor's report
    // redacts paths and this command prints none at all - the cause is the
    // machine-stable part, and a segment name carries no separator
    if (PosExChar('/', project.Detail) = 0) and
       (PosExChar('\', project.Detail) = 0) then
      RunRefused(PWebCliProjectRefusalText(project.Refusal), project.Detail)
    else
      RunRefused(PWebCliProjectRefusalText(project.Refusal), '');
    exit(PWEB_EXIT_PROJECT);
  end;
  layout := PWebCliResolveRunLayout(project, PWebCliHostOs, PWebCliHostArch);
  if layout.Refusal <> prrNone then
  begin
    RunRefused(PWebCliRunRefusalText(layout.Refusal), layout.Detail);
    if layout.Refusal = prrNotBuilt then
      EmitErr('pweb: the project has not been built for ' + layout.Target +
        '; run builds nothing'#10);
    // an unratified host is an environment fact, not a project one
    if layout.Refusal = prrTargetUnsupported then
      exit(PWEB_EXIT_ENVIRONMENT);
    exit(PWEB_EXIT_PROJECT);
  end;
  // the stop handler is a prerequisite of supervision, not of the
  // application: without it a Ctrl+C would kill the supervisor and leave
  // the tree behind, which is the one thing this command must never do
  if not PWebCliInstallStopHandler then
  begin
    RunRefused('supervision_unavailable', 'stop_handler');
    exit(PWEB_EXIT_ENVIRONMENT);
  end;
  // the report names the LOGICAL layout only: never an absolute path, never
  // the SDK, never the home directory
  EmitErr('pweb: running ' + layout.ExeLogical + ' (' +
    PWebCliUiText(project.Ui) + ', production)'#10);
  r := PWebCliRunApplication(layout, @ForwardLine, nil,
    @ApplicationStarted, nil);
  case r.Outcome of
    pcoSpawnRefused:
      begin
        // unreachable for a ratified layout: the identifier grammar
        // admits no batch file and the walk admits no NUL. Reaching it is
        // the CLI contradicting itself
        RunRefused(PWebCliExecRefusalText(r.Refusal), '');
        exit(PWEB_EXIT_INTERNAL);
      end;
    pcoSpawnFailed:
      begin
        RunRefused('supervision_unavailable',
          PWebCliSpawnFailureText(r.Failure) + ' (error ' +
          RawUtf8(IntToStr(r.OsError)) + ')');
        exit(PWEB_EXIT_ENVIRONMENT);
      end;
  end;
  if r.ForwardBroken then
    EmitErr('pweb: the output target went away; forwarding stopped'#10);
  if r.StopRequested then
    EmitErr('pweb: stop requested (' + RawUtf8(IntToStr(r.StopPosts)) +
      ' close request(s) delivered)'#10);
  // the descendants, drained by membership after the application's exit
  forced := 0;
  for i := 0 to High(r.Drain.Seen) do
    if r.Drain.Seen[i].Forced then
      Inc(forced);
  if Length(r.Drain.Seen) > 0 then
    EmitErr('pweb: drained ' + RawUtf8(IntToStr(Length(r.Drain.Seen))) +
      ' descendant process(es) in ' + RawUtf8(IntToStr(r.Drain.Passes)) +
      ' pass(es), ' + RawUtf8(IntToStr(forced)) + ' forced'#10);
  if r.Drain.Remaining > 0 then
    EmitErr('pweb: ' + RawUtf8(IntToStr(r.Drain.Remaining)) +
      ' descendant process(es) survived the drain'#10);
  // the application's own status is printed below whatever the drain did;
  // the CATEGORY is decided last, and survivors outrank every other answer
  // (6, an invariant failure: a supervisor that could not clean up)
  Result := PWEB_EXIT_OK;
  case r.Outcome of
    pcoExited:
      begin
        if r.ExitCode = 0 then
        begin
          EmitErr('pweb: application exited 0'#10);
          if r.Drain.Remaining > 0 then
            exit(PWEB_EXIT_INTERNAL);
          exit(PWEB_EXIT_OK);
        end;
        // the real status, in decimal and - for the NTSTATUS range a
        // crashed Windows process reports - in hex beside it
        if r.ExitCode < 0 then
          EmitErr('pweb: application exited ' +
            RawUtf8(IntToStr(Cardinal(r.ExitCode))) + ' (0x' +
            RawUtf8(IntToHex(Cardinal(r.ExitCode), 8)) + ')'#10)
        else
          EmitErr('pweb: application exited ' +
            RawUtf8(IntToStr(r.ExitCode)) + #10);
        Result := PWEB_EXIT_PROBE;
      end;
    pcoSignaled:
      begin
        if r.Signal < 0 then
          // the ECHILD marker: gone before this supervisor could reap it,
          // and no signal is invented for it
          EmitErr('pweb: application vanished before it could be reaped'#10)
        else
          EmitErr('pweb: application terminated by signal ' +
            RawUtf8(IntToStr(r.Signal)) + #10);
        Result := PWEB_EXIT_PROBE;
      end;
    pcoForced:
      begin
        EmitErr('pweb: application force-terminated after ' +
          RawUtf8(IntToStr(PWEB_CLI_RUN_GRACE_MS)) +
          ' ms without closing; reaped in ' +
          RawUtf8(IntToStr(r.KillToReapMs)) + ' ms'#10);
        Result := PWEB_EXIT_PROBE;
      end;
  else
    // pcoUnreaped: the platform could not reap what it terminated
    EmitErr('pweb: application could not be reaped'#10);
    Result := PWEB_EXIT_INTERNAL;
  end;
  if r.Drain.Remaining > 0 then
    Result := PWEB_EXIT_INTERNAL;
end;

{ `pweb dev [--project <path>]`.

  Resolve the project exactly as doctor and run do, and hand it to the one
  development loop (pweb.cli.dev). This function decides exit codes and
  prints the loop's own lines; it starts no child of its own, resolves no
  path of its own and knows nothing about generations.

  THE EXIT MAPPING is the CAP-10C0 one with the two additions this shard
  ratifies:

      0  the loop stopped cleanly - Ctrl+C, or the developer closed the
         window and the application exited 0
      2  usage
      3  the project was refused, or its declared `ui` is one this build's
         dev loop does not implement (dev_ui_unsupported)
      4  the machine cannot build it: the doctor refused, or a tool is
         missing, unrunnable or the wrong target
      5  a start-up stage's child failed, or the SUPERVISED SET failed -
         the application died, or the watcher exited
      6  an invariant of the dev loop itself broke

  The human text never changes the category, and the category comes from
  the typed outcomes rather than from anything a child printed. }

procedure DevRefused(const Cause, Detail: RawUtf8);
begin
  EmitErr('pweb: dev refused: ' + Cause);
  if Detail <> '' then
    EmitErr(': ' + Detail);
  EmitErr(#10);
end;

// the loop's sink. A child's forwarded line goes to stdout and the loop's
// own `pweb: `-prefixed lines to stderr, exactly as `pweb run` splits them;
// both are already free of ANSI and of every absolute path
procedure DevLine(Opaque: Pointer; const Line: RawUtf8; FromChild: Boolean);
begin
  if FromChild then
    Emit(Line + #10)
  else
    EmitErr(Line + #10);
end;

function RunDev(const Args: TPWebCliArgs; const StartDir: RawUtf8): Integer;
var
  project: TPWebCliProject;
  r: TPWebCliDevResult;
begin
  project := PWebCliOpenProject(Args.ProjectPath, StartDir);
  if project.Refusal <> pcrNone then
  begin
    // the detail of a project refusal may be a path; this command prints
    // none at all - the cause is the machine-stable part
    if (PosExChar('/', project.Detail) = 0) and
       (PosExChar('\', project.Detail) = 0) then
      DevRefused(PWebCliProjectRefusalText(project.Refusal), project.Detail)
    else
      DevRefused(PWebCliProjectRefusalText(project.Refusal), '');
    exit(PWEB_EXIT_PROJECT);
  end;
  // the stop handler is a prerequisite of supervision and is installed
  // BEFORE anything is spawned, exactly as `run` installs it: without it a
  // Ctrl+C would kill this process and leave two trees behind
  if not PWebCliInstallStopHandler then
  begin
    DevRefused('supervision_unavailable', 'stop_handler');
    exit(PWEB_EXIT_ENVIRONMENT);
  end;
  r := PWebCliRunDev(project, PWebCliHostOs, PWebCliHostArch, @DevLine, nil);
  if r.Code <> pdcOk then
    DevRefused(r.Cause, r.Detail);
  if r.Interrupted then
    EmitErr('pweb: stop requested; the watcher and the application were ' +
      'asked to close'#10);
  if r.DescendantsRemaining > 0 then
    EmitErr('pweb: ' + RawUtf8(IntToStr(r.DescendantsRemaining)) +
      ' descendant process(es) survived the drain'#10);
  if r.Published_ > 0 then
    EmitErr('pweb: ' + RawUtf8(IntToStr(r.Published_)) +
      ' generation(s) published, ' + RawUtf8(IntToStr(r.Acknowledged)) +
      ' loaded'#10);
  Result := PWebCliDevExitCode(r.Code);
end;

{ `pweb build [--project <path>]`.

  Resolve the project exactly as doctor, run and dev resolve it, and hand it
  to the one build driver (pweb.cli.build), which hands it to the one
  lifecycle pipeline. This function decides exit codes and prints; it starts
  no child of its own, resolves no path of its own, and knows neither a
  stage nor a bound.

  THE EXIT MAPPING is docs/pipeline-contract.md section 9, unchanged - the
  same six categories `run` and `dev` answer with, and no seventh:

      0  every stage of this UI ran and the layout verified
      2  usage
      3  the project, its descriptor, its paths or its layout
      4  the machine cannot build it: the doctor refused, or a tool is
         missing, unrunnable or the wrong target
      5  a stage's child failed, died or was stopped
      6  an invariant of the pipeline itself broke

  THE OUTPUT is human and nothing else. A stage's forwarded child lines go
  to stdout; every line this CLI writes itself is `pweb: `-prefixed and goes
  to stderr, so `pweb build > out.txt` captures the toolchain's own output
  and the progress stays where a person is watching. No ANSI on either
  stream, no absolute path, no SDK location, no home directory and no
  environment content ever reaches either.

  `pweb run` is suggested at the end ONLY when the CAP-10C0 resolver
  actually accepted the committed layout in the verify stage. A build tool
  that tells you to run something it has not confirmed is runnable is a
  build tool whose last line is a guess. }

procedure BuildRefused(const Cause, Detail: RawUtf8);
begin
  EmitErr('pweb: build failed: ' + Cause);
  if Detail <> '' then
    EmitErr(': ' + Detail);
  EmitErr(#10);
end;

function RunBuild(const Args: TPWebCliArgs; const StartDir: RawUtf8): Integer;
var
  project: TPWebCliProject;
  r: TPWebCliBuildResult;
begin
  project := PWebCliOpenProject(Args.ProjectPath, StartDir);
  if project.Refusal <> pcrNone then
  begin
    // the detail of a project refusal may be a path; this command prints
    // none at all - the cause is the machine-stable part
    if (PosExChar('/', project.Detail) = 0) and
       (PosExChar('\', project.Detail) = 0) then
      BuildRefused(PWebCliProjectRefusalText(project.Refusal), project.Detail)
    else
      BuildRefused(PWebCliProjectRefusalText(project.Refusal), '');
    exit(PWEB_EXIT_PROJECT);
  end;
  // the stop handler is a prerequisite of supervision and is installed
  // BEFORE anything is spawned, exactly as `run` and `dev` install it:
  // without it a Ctrl+C would end this process under a running compiler
  if not PWebCliInstallStopHandler then
  begin
    BuildRefused('supervision_unavailable', 'stop_handler');
    exit(PWEB_EXIT_ENVIRONMENT);
  end;
  EmitErr('pweb: building ' + project.Name + ' (' +
    PWebCliUiText(project.Ui) + ', ' +
    PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch) + ')'#10);
  // @DevLine, and deliberately NOT a second copy of it: `dev` and `build`
  // split their two streams by the same rule, and a second spelling of one
  // rule is a second thing to keep in step
  r := PWebCliRunBuild(project, PWebCliHostOs, PWebCliHostArch,
    @DevLine, nil);
  if r.Code <> ppcOk then
  begin
    BuildRefused(r.Cause, r.Detail);
    if r.Interrupted then
      EmitErr('pweb: stop requested; the running stage was asked to stop ' +
        'and the previous release was left as it was'#10);
    // ONE advisory, on the two refusals an in-use release directory
    // produces. It changes no cause and no category: it names the thing a
    // reader would otherwise spend an afternoon on, because on Windows a
    // directory that is a running process's working directory cannot be
    // renamed at all - and the release directory is exactly that while
    // `pweb run` holds it
    if r.ReleaseInUse then
      EmitErr('pweb: the previous release could not be replaced; stop an ' +
        'application running from it and build again'#10);
    exit(PWebCliPipeExitCode(r.Code));
  end;
  // the summary: six facts, and the release named RELATIVE TO THE PROJECT,
  // which is both the whole truth and the one form that is byte-identical
  // on every machine
  EmitErr('pweb: built ' + r.ProjectName + #10);
  EmitErr('  ' + Pad('ui', 13) + r.Ui + #10);
  EmitErr('  ' + Pad('target', 13) + r.Target + #10);
  EmitErr('  ' + Pad('release', 13) + r.ReleaseLogical + #10);
  EmitErr('  ' + Pad('app.pwb', 13) + r.BundleSha256 + #10);
  EmitErr('  ' + Pad('bytes', 13) + RawUtf8(IntToStr(r.TotalBytes)) + #10);
  if r.Accepted then
    EmitErr('pweb: run it with `pweb run`'#10);
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
    case args.Command of
      pccCreate: EmitErr(PWebCliCreateHelp);
      pccRun:    EmitErr(PWebCliRunHelp);
      pccDev:    EmitErr(PWebCliDevHelp);
      pccBuild:  EmitErr(PWebCliBuildHelp);
    else
      EmitErr(PWebCliUsageBanner);
    end;
    exit(PWEB_EXIT_USAGE);
  end;
  // --help and --version are complete requests: they answer on stdout and
  // do nothing else, whatever command also appeared on the line. A command
  // that was named gets ITS help, because that is the question that was
  // asked
  if args.Help then
  begin
    case args.Command of
      pccCreate: Emit(PWebCliCreateHelp);
      pccRun:    Emit(PWebCliRunHelp);
      pccDev:    Emit(PWebCliDevHelp);
      pccBuild:  Emit(PWebCliBuildHelp);
    else
      Emit(PWebCliUsageBanner);
    end;
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
    pccRun:    Result := RunRun(args, startDir);
    pccDev:    Result := RunDev(args, startDir);
    pccBuild:  Result := RunBuild(args, startDir);
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
