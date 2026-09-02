program pwebpipe;

{ CAP-10C1: the PRIVATE lifecycle-pipeline driver.

  THIS IS NOT A COMMAND. `pweb` advertises create, doctor and run; `dev` and
  `build` are unknown commands and stay unknown until CAP-10C2 and CAP-10D.
  The pipeline is production code (tools/pweb/pweb.cli.pipeline and the five
  plan builders under it) and this program is the only thing in the tree that
  calls it - which is what lets the whole lifecycle be measured on four
  targets without the public surface moving one byte.

  It exists as a SEPARATE PROCESS rather than as a test case for one reason:
  a real Ctrl+C has to arrive at a real process running a real stage, and a
  suite that signalled itself would be measuring its own runner. The
  CAP-10C0 stop-signal driver is the same shape, for the same reason.

      pwebpipe [--project <path>] [--report <file>]

  --project   exactly what `pweb run --project` means: the descriptor or its
              containing directory, canonicalized, with nothing else searched
  --report    a key=value record of the run, for the gate to read

  OUTPUT. The driver's own lines are `pweb: `-prefixed and go to stderr, as
  the run command's do; a stage's forwarded child lines are prefixed with the
  stage name and go to stdout. Neither carries ANSI, an absolute path, a home
  directory or an SDK location: every recorded string is projected through
  PWebCliPipeRedactions first, which is also what makes two targets whose
  real paths differ entirely produce the same evidence.

  A tool's OWN forwarded bytes are the tool's: vite colours its output when
  it feels like it, and the pipeline injects nothing into the environment to
  stop it. The no-ANSI claim is about the lines this driver writes.

  EXIT: the ratified category (0 clean, 2 usage, 3 project, 4 the machine
  cannot build it, 5 a stage failed or was stopped, 6 internal). }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.process,
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

var
  ReportRows: RawUtf8;

procedure Emit(Opaque: Pointer; const Line: RawUtf8; FromChild: Boolean);
begin
  if FromChild then
  begin
    WriteLn(Line);
    // POSIX block-buffers a pipe; a driver whose progress arrives only at
    // exit is a driver nobody can watch. This is the same debt CAP-10C1
    // closes in the reusable host and in the two template starters
    Flush(Output);
  end
  else
  begin
    WriteLn(StdErr, Line);
    Flush(StdErr);
  end;
end;

procedure Row(const Key, Value: RawUtf8);
begin
  ReportRows := ReportRows + Key + '=' + Value + #10;
end;

function Bool(B: Boolean): RawUtf8;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

function IntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

var
  i: Integer;
  arg, explicit, reportPath, cwd, redacted: RawUtf8;
  prefixes, tokens: TRawUtf8DynArray;
  project: TPWebCliProject;
  res: TPWebCliPipeResult;
  k: TPWebCliStageKind;
  code: Integer;

begin
  explicit := '';
  reportPath := '';
  i := 1;
  while i <= ParamCount do
  begin
    arg := RawUtf8(ParamStr(i));
    if (arg = '--project') and
       (i < ParamCount) then
    begin
      Inc(i);
      explicit := RawUtf8(ParamStr(i));
    end
    else if (arg = '--report') and
            (i < ParamCount) then
    begin
      Inc(i);
      reportPath := RawUtf8(ParamStr(i));
    end
    else
    begin
      WriteLn(StdErr, 'pweb: usage: pwebpipe [--project <path>] ' +
        '[--report <file>]');
      Halt(2);
    end;
    Inc(i);
  end;

  // the stop handler is installed BEFORE anything is spawned, exactly as
  // `pweb run` installs it, so a Ctrl+C during a stage reaches the engine's
  // ladder rather than ending this process under a running child tree
  if not PWebCliInstallStopHandler then
  begin
    WriteLn(StdErr, 'pweb: supervision unavailable: no stop handler');
    Halt(4);
  end;

  // the working directory is read ONCE, here, to seed discovery - and never
  // consulted again by anything below
  if not PWebCliCwd(cwd) then
    cwd := '';
  project := PWebCliOpenProject(explicit, cwd);

  ReportRows := '';
  res := PWebCliRunPipeline(project, PWebCliHostOs, PWebCliHostArch,
    @Emit, nil);
  code := PWebCliPipeExitCode(res.Code);

  if reportPath <> '' then
  begin
    PWebCliPipeRedactions(project, res.Sdk, res.Toolset, prefixes, tokens);
    Row('pipeline_available', 'true');
    Row('pipeline_exit', IntText(code));
    // `ok`, never the stage a zero-valued FailedStage happens to name: a
    // record whose success reads as "open" is a record somebody will one day
    // grep for a stage name and find in a green run
    if res.Code = ppcOk then
    begin
      Row('pipeline_result', 'ok');
      Row('pipeline_cause', 'ok');
    end
    else
    begin
      Row('pipeline_result', PWebCliStageName(res.FailedStage));
      Row('pipeline_cause', res.Cause);
    end;
    Row('pipeline_detail', PWebCliRedact(res.Detail, prefixes, tokens));
    Row('pipeline_interrupted', Bool(res.Interrupted));
    Row('pipeline_ui', PWebCliUiText(project.Ui));
    Row('pipeline_target', res.Sdk.Target);
    Row('pipeline_fpc_target', res.Toolset.FpcTargetCpu + '-' +
      res.Toolset.FpcTargetOs);
    Row('project_tree_before', res.TreeBefore);
    Row('project_tree_after', res.TreeAfter);
    Row('project_tree_unchanged',
      Bool((res.TreeBefore <> '') and (res.TreeBefore = res.TreeAfter)));
    Row('release_dir', PWebCliRedact(res.ReleaseDir, prefixes, tokens));
    // the npm rule, RECORDED rather than merely obeyed: the doctor's row is
    // presence-only, so this is where a reader sees which entry point was
    // resolved and what it answered
    if res.Toolset.Npm.Script <> '' then
      Row('npm_invocation', 'node_npm_cli')
    else
      Row('npm_invocation', 'none');
    Row('npm_cli_path',
      PWebCliRedact(res.Toolset.Npm.Script, prefixes, tokens));
    Row('npm_version', res.Toolset.Npm.Version);
    Row('node_version', res.Toolset.Node.Version);
    Row('node_duplicates', IntText(res.Toolset.Node.Duplicates));
    Row('fpc_version', res.Toolset.Fpc.Version);
    Row('fpc_duplicates', IntText(res.Toolset.Fpc.Duplicates));
    Row('pas2js_version', res.Toolset.Pas2js.Version);
    Row('lifecycle_script_policy', 'ignore_scripts');
    if project.Ui = puiReact then
      Row('network_stages', 'npm_ci')
    else
      Row('network_stages', '');
    Row('pas2js_had_bom', Bool(res.Normalisation.HadBom));
    Row('pas2js_had_cr', Bool(res.Normalisation.HadCr));
    Row('sdk_root', PWebCliRedact(res.Sdk.Root, prefixes, tokens));
    for k := Low(TPWebCliStageKind) to High(TPWebCliStageKind) do
    begin
      arg := PWebCliStageName(k);
      // a stage with no child has no OUTCOME, and printing the enumeration's
      // ordinal zero would say `spawn_refused` about a stage that never
      // spawned anything
      if res.Stages[k].Command <> '' then
        redacted := PWebCliChildOutcomeText(res.Stages[k].Outcome)
      else
        redacted := 'no_child';
      Row('stage.' + arg, Bool(res.Stages[k].Applicable) + '|' +
        Bool(res.Stages[k].Entered) + '|' + Bool(res.Stages[k].Ok) + '|' +
        res.Stages[k].Cause + '|' + redacted + '|' +
        IntText(res.Stages[k].ExitCode) + '|' +
        IntText(res.Stages[k].ElapsedMs));
      if res.Stages[k].Command <> '' then
        Row('cmd.' + arg, res.Stages[k].Command);
    end;
    // one writer, and it never replaces: a report left from an earlier run
    // is removed first, so a gate can never read a stale record as this
    // run's answer
    if PWebCliNodeKind(reportPath) = pcnFile then
      PWebCliDeleteFile(reportPath);
    if not PWebCliWriteNewFile(reportPath, RawByteString(ReportRows),
         {SetExecBit=}False) then
    begin
      WriteLn(StdErr, 'pweb: could not write the report');
      if code = 0 then
        code := 6;
    end;
  end;

  if res.Code = ppcOk then
    WriteLn(StdErr, 'pweb: pipeline ok')
  else
  begin
    redacted := res.Cause;
    WriteLn(StdErr, 'pweb: pipeline FAILED at ' +
      PWebCliStageName(res.FailedStage) + ': ' + redacted);
  end;
  Flush(StdErr);
  Halt(code);
end.
