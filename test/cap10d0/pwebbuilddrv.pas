program pwebbuilddrv;

{ CAP-10D0: the driver that spawns the REAL `pweb build` and, in its
  interrupt scenario, stops it mid-stage with a REAL console interrupt.

  IT EXISTS AS A SEPARATE PROCESS for the reason the CAP-10C0 stop driver and
  the CAP-10C2/C3 development drivers do: a real interrupt has to arrive at a
  real supervisor running a real compiler, and a suite that signalled itself
  would be measuring its own runner. It reuses the CAP-10C0 MECHANISM rather
  than inventing a second one - the child is spawned with SeparateConsole,
  and on Windows the interrupt is delivered by test/cap10c0/pwebchild's
  `ctrlbreak <pid>`, which attaches to that console and raises CTRL_C_EVENT.

  THIS IS WHY IT EXISTS AT ALL. CAP-10C1's ST10 leg measured an interrupted
  pipeline on POSIX and recorded `interrupt_clean = not_measured` on Windows,
  because a console control event there needs exactly this helper. A public
  `build` is the command a developer will actually press Ctrl+C on, so the
  Windows measurement stops being optional - and this driver is what makes
  it exist on all four targets.

      pwebbuilddrv --pweb <exe> --project <dir> --report <file>
                   [--helper <pwebchild>] [--cwd <dir>]
                   [--scenario interrupt|plain] [--stage <name>]

  interrupt  (default) wait until the named stage reports `start`, let it
             settle, deliver ONE real interrupt, and let the supervisor run
             its ladder to the end. The gate then measures what is on the
             disk: the previous release untouched, no staging tree left, no
             descendant surviving.
  plain      run the build to completion and report what it printed. No
             signal is sent; this is the shape B1, B2 and B10 need, with the
             forwarded lines classified by stream rather than re-parsed out
             of a redirected file.

  --stage    which stage to interrupt; `compile` by default, because it owns
             a real child for long enough to be interrupted reliably and it
             is the LAST stage before the layout is committed - which is the
             instant where an interrupt could do the most damage if the rule
             were wrong.

  OUTPUT. Every line the run produced is written beside the report; the
  report itself is key=value with no absolute path in any value the gate
  compares. The ANSI claim is measured over the CLI's OWN lines only: a
  tool's forwarded bytes are the tool's, and vite colours its output when it
  feels like it.

  EXIT: 0 when the scenario ran to its end (whatever it MEASURED - the gate
  decides pass and fail from the rows), 2 on a usage error, 3 when a
  precondition is absent. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
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
  pweb.cli.pipeline,
  pweb.cli.build;

const
  /// the total bound of one driven run: longer than the pipeline's own
  // fpc bound, because this driver supervises a supervisor
  DRIVER_TOTAL_MS = 1200000;
  /// how long the named stage is left running before the interrupt, so the
  // signal lands INSIDE a child rather than between two stages
  DRIVER_SETTLE_MS = 1500;
  /// how long the ladder is given after the interrupt before this driver
  // stops waiting and says so
  DRIVER_AFTER_MS = 180000;

type
  TScenario = (scInterrupt, scPlain);
  TStep = (stAwaitStage, stSettle, stActed, stDone);

var
  ReportRows: RawUtf8;
  Lines: RawUtf8;
  PwebPath, ProjectDir, ReportPath, HelperPath, CwdPath, StageName: RawUtf8;
  Scenario: TScenario;
  Step: TStep;
  PwebPid: PtrInt;
  RunStarted, StepStarted, Acted: Int64;
  AnsiSeen, Interrupted_, SawSummary, SawRunHint: Boolean;
  OwnLines, ChildLines, StagesStarted, StagesOk: Integer;
  SummaryUi, SummaryTarget, SummaryRelease, SummaryPwb, SummaryBytes: RawUtf8;

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

// the value of an indented `  <name>  <value>` summary row, or ''
function SummaryValue(const Line, Name: RawUtf8): RawUtf8;
var
  rest: RawUtf8;
  i: PtrInt;
begin
  Result := '';
  if Copy(Line, 1, 2 + Length(Name)) <> '  ' + Name then
    exit;
  rest := Copy(Line, 3 + Length(Name), MaxInt);
  i := 1;
  while (i <= Length(rest)) and (rest[i] = ' ') do
    Inc(i);
  if i = 1 then
    exit; // `  uix` is not the `  ui` row
  Result := Copy(rest, i, MaxInt);
end;

// every forwarded line, classified. The CLI's own lines carry the `pweb: `
// prefix exactly as `run` and `dev` emit theirs; a stage's child lines carry
// the stage-name prefix the pipeline puts on them
procedure Collect(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  own: Boolean;
  v: RawUtf8;
begin
  Lines := Lines + Line + #10;
  own := Copy(Line, 1, 6) = 'pweb: ';
  if own then
  begin
    Inc(OwnLines);
    // the no-ANSI claim is about the lines this CLI writes, and only those
    if Pos(#27, Line) > 0 then
      AnsiSeen := True;
    if Pos(': start', Line) > 0 then
      Inc(StagesStarted);
    if Pos(': ok', Line) > 0 then
      Inc(StagesOk);
    if Copy(Line, 1, 12) = 'pweb: built ' then
      SawSummary := True;
    if Pos('run it with', Line) > 0 then
      SawRunHint := True;
    if (Scenario = scInterrupt) and
       (Step = stAwaitStage) and
       (Line = 'pweb: ' + StageName + ': start') then
    begin
      Step := stSettle;
      StepStarted := GetTickCount64();
    end;
  end
  else
    Inc(ChildLines);
  // the summary rows are NOT `pweb: `-prefixed: they are the continuation
  // of the header line, indented, exactly as `pweb create` prints its five
  v := SummaryValue(Line, 'ui');
  if v <> '' then
    SummaryUi := v;
  v := SummaryValue(Line, 'target');
  if v <> '' then
    SummaryTarget := v;
  v := SummaryValue(Line, 'release');
  if v <> '' then
    SummaryRelease := v;
  v := SummaryValue(Line, 'app.pwb');
  if v <> '' then
    SummaryPwb := v;
  v := SummaryValue(Line, 'bytes');
  if v <> '' then
    SummaryBytes := v;
end;

procedure StartedPid(Opaque: Pointer; Pid: PtrInt);
begin
  PwebPid := Pid;
end;

// deliver a REAL interrupt to the supervisor, by the CAP-10C0 mechanism
function Interrupt: Boolean;
var
  spec: TPWebCliExecSpec;
  r: TPWebCliExecResult;
  child: TPWebCliChild;
begin
  Result := False;
  if PwebPid = 0 then
    exit;
  if HelperPath <> '' then
  begin
    spec := Default(TPWebCliExecSpec);
    spec.ExePath := HelperPath;
    spec.Args := [RawUtf8('ctrlbreak'), RawUtf8(IntToStr(PwebPid))];
    spec.WorkDir := CwdPath;
    spec.Profile := pepProbe;
    spec.TimeoutMs := 30000;
    r := PWebCliExecute(spec);
    Result := (r.Outcome = pcoExited) and
              (r.ExitCode = 0);
    if Result then
      exit;
  end;
  // POSIX, and the Windows fallback: the engine's own stop request
  child := Default(TPWebCliChild);
  child.Pid := PwebPid;
  Result := PWebCliChildStop(child) > 0;
end;

// THE SCENARIO, driven from the engine's own stop-check callback - the one
// place this driver is called on every pass. It never returns True except on
// the total bound: this driver stops the run by asking the supervisor to
// stop, never by abandoning it under a running compiler.
function DriverTick(Opaque: Pointer): Boolean;
var
  now_: Int64;
begin
  Result := False;
  now_ := GetTickCount64();
  if now_ - RunStarted > DRIVER_TOTAL_MS then
  begin
    Row('driver_timeout', 'total');
    exit(True);
  end;
  if Scenario = scPlain then
    exit;
  case Step of
    stSettle:
      // the stage has a child now; let it get properly under way, so the
      // interrupt lands INSIDE it rather than between two stages
      if now_ - StepStarted >= DRIVER_SETTLE_MS then
      begin
        Interrupted_ := Interrupt;
        Acted := now_;
        Step := stActed;
      end;
    stActed:
      if now_ - Acted > DRIVER_AFTER_MS then
      begin
        Row('driver_timeout', 'after_interrupt');
        exit(True);
      end;
  end;
end;

function ArgAt(i: Integer): RawUtf8;
begin
  Result := RawUtf8(ParamStr(i));
end;

var
  i: Integer;
  arg: RawUtf8;
  r: TPWebCliExecResult;
  spec: TPWebCliExecSpec;

begin
  PwebPath := '';
  ProjectDir := '';
  ReportPath := '';
  HelperPath := '';
  CwdPath := '';
  StageName := 'compile';
  Scenario := scInterrupt;
  i := 1;
  while i <= ParamCount do
  begin
    arg := ArgAt(i);
    if i = ParamCount then
    begin
      WriteLn(StdErr, 'pwebbuilddrv: option without a value: ' + arg);
      Halt(2);
    end;
    Inc(i);
    if arg = '--pweb' then
      PwebPath := ArgAt(i)
    else if arg = '--project' then
      ProjectDir := ArgAt(i)
    else if arg = '--report' then
      ReportPath := ArgAt(i)
    else if arg = '--helper' then
      HelperPath := ArgAt(i)
    else if arg = '--cwd' then
      CwdPath := ArgAt(i)
    else if arg = '--stage' then
      StageName := ArgAt(i)
    else if arg = '--scenario' then
    begin
      if ArgAt(i) = 'plain' then
        Scenario := scPlain
      else if ArgAt(i) = 'interrupt' then
        Scenario := scInterrupt
      else
      begin
        WriteLn(StdErr, 'pwebbuilddrv: unknown scenario: ' + ArgAt(i));
        Halt(2);
      end;
    end
    else
    begin
      WriteLn(StdErr, 'pwebbuilddrv: usage: --pweb <exe> --project <dir> ' +
        '--report <file> [--helper <p>] [--cwd <d>] [--scenario s] ' +
        '[--stage n]');
      Halt(2);
    end;
    Inc(i);
  end;
  if (PwebPath = '') or
     (ProjectDir = '') or
     (ReportPath = '') then
  begin
    WriteLn(StdErr, 'pwebbuilddrv: --pweb, --project and --report are required');
    Halt(2);
  end;
  if CwdPath = '' then
    CwdPath := RawUtf8(GetCurrentDir);
  // spelled out rather than looped: three names, three messages, and no
  // array constructor whose element type a reader has to work out
  if PWebCliNodeKind(PwebPath) = pcnMissing then
  begin
    WriteLn(StdErr, 'pwebbuilddrv: precondition absent: --pweb');
    Halt(3);
  end;
  if PWebCliNodeKind(ProjectDir) = pcnMissing then
  begin
    WriteLn(StdErr, 'pwebbuilddrv: precondition absent: --project');
    Halt(3);
  end;
  if PWebCliNodeKind(CwdPath) = pcnMissing then
  begin
    WriteLn(StdErr, 'pwebbuilddrv: precondition absent: --cwd');
    Halt(3);
  end;

  // the stop handler, installed before anything is spawned, exactly as the
  // CAP-10C0 drivers install it
  if not PWebCliInstallStopHandler then
  begin
    WriteLn(StdErr, 'pwebbuilddrv: supervision unavailable: no stop handler');
    Halt(3);
  end;

  Step := stAwaitStage;
  RunStarted := GetTickCount64();
  StepStarted := RunStarted;
  Acted := 0;

  spec := Default(TPWebCliExecSpec);
  spec.ExePath := PwebPath;
  spec.Args := [RawUtf8('build'), RawUtf8('--project'), ProjectDir];
  // AN UNRELATED WORKING DIRECTORY, deliberately: `pweb build` reads the
  // working directory exactly once and must not depend on being inside the
  // project it is asked to build
  spec.WorkDir := CwdPath;
  spec.Profile := pepSupervise;
  spec.TimeoutMs := DRIVER_TOTAL_MS + 60000;
  // its own console, so a Windows CTRL_C_EVENT reaches the supervisor and
  // not this driver
  spec.SeparateConsole := True;
  spec.Sink := @Collect;
  spec.StopCheck := @DriverTick;
  spec.Started := @StartedPid;
  spec.TreeRoot := PWebCliDisplayPath(ProjectDir);
  r := PWebCliExecute(spec);
  Step := stDone;

  if Scenario = scPlain then
    Row('driver_scenario', 'plain')
  else
    Row('driver_scenario', 'interrupt');
  Row('driver_target', PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch));
  Row('driver_stage', StageName);
  Row('build_pid', IntText(PwebPid));
  Row('pweb_outcome', PWebCliChildOutcomeText(r.Outcome));
  Row('pweb_exit', IntText(r.ExitCode));
  Row('pweb_signal', IntText(r.Signal));
  Row('descendants_remaining', IntText(r.Drain.Remaining));
  Row('descendants_seen', IntText(Length(r.Drain.Seen)));
  // the CLI's OWN lines carry no ANSI, whatever a tool printed
  Row('driver_ansi_seen', Bool(AnsiSeen));
  Row('own_lines', IntText(OwnLines));
  Row('child_lines', IntText(ChildLines));
  Row('stages_started', IntText(StagesStarted));
  Row('stages_ok', IntText(StagesOk));
  Row('saw_summary', Bool(SawSummary));
  Row('saw_run_hint', Bool(SawRunHint));
  // ALWAYS emitted, empty when the run never got that far: a row that is
  // only sometimes written is a required-field failure on the run where the
  // thing it measures did not happen
  Row('summary_ui', SummaryUi);
  Row('summary_target', SummaryTarget);
  Row('summary_release', SummaryRelease);
  Row('summary_app_pwb', SummaryPwb);
  Row('summary_bytes', SummaryBytes);
  if Scenario = scInterrupt then
  begin
    Row('interrupt_armed', Bool(Acted <> 0));
    Row('interrupt_delivered', Bool(Interrupted_));
    if Acted <> 0 then
      Row('interrupt_to_exit_ms', IntText(Int64(GetTickCount64()) - Acted))
    else
      Row('interrupt_to_exit_ms', '0');
  end;

  // one writer, and it never replaces: a report left from an earlier run is
  // removed first, so a gate can never read a stale record as this run's
  if PWebCliNodeKind(ReportPath) = pcnFile then
    PWebCliDeleteFile(ReportPath);
  if not PWebCliWriteNewFile(ReportPath, RawByteString(ReportRows),
       {SetExecBit=}False) then
  begin
    WriteLn(StdErr, 'pwebbuilddrv: could not write the report');
    Halt(3);
  end;
  if PWebCliNodeKind(ReportPath + '.lines') = pcnFile then
    PWebCliDeleteFile(ReportPath + '.lines');
  PWebCliWriteNewFile(ReportPath + '.lines', RawByteString(Lines),
    {SetExecBit=}False);
  WriteLn(StdErr, 'pwebbuilddrv: done (' +
    PWebCliChildOutcomeText(r.Outcome) + ' ' + IntText(r.ExitCode) + ')');
  Flush(StdErr);
  Halt(0);
end.
