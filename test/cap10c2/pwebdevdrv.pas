program pwebdevdrv;

{ CAP-10C2: the driver that spawns the REAL `pweb dev` and drives it.

  IT EXISTS AS A SEPARATE PROCESS for the reason the CAP-10C0 stop driver
  does: a real console interrupt has to arrive at a real supervisor running a
  real loop, and a suite that signalled itself would be measuring its own
  runner. It reuses the CAP-10C0 MECHANISM rather than inventing a second one
  - the child is spawned with SeparateConsole, and on Windows the interrupt
  is delivered by test/cap10c0/pwebchild's `ctrlbreak <pid>`, which attaches
  to that console and raises CTRL_C_EVENT. That is what makes interrupt_clean
  measurable on ALL FOUR targets, closing the gap CAP-10C1 recorded.

      pwebdevdrv --pweb <exe> --project <dir> --source <App.tsx>
                 --helper <pwebchild> --report <file> [--cwd <dir>]

  THE SCENARIO, in one supervised run, driven from the engine's own
  stop-check callback - the one place this driver is called on every pass:

    DEV1  generation 1 is packed, the host opens on pweb://app, the page
          reports secure = true and value = 42
    DEV2  a source edit publishes generation 2, it is LOADED, the page
          reports 42 again, and THE HOST PID DOES NOT CHANGE
    DEV4  a BROKEN source stops publishing, the previous generation stays
          live and the host stays alive; fixing it publishes the next one
    DEV6  a real interrupt stops the whole set inside the C0 bounds, with
          exit 0 and no partial generation left on disk

  Every line the run produced is written beside the report, and the report
  itself is key=value with no absolute path in any value the gate compares.

  EXIT: 0 when the scenario ran to its end (whatever it MEASURED - the gate
  decides pass and fail from the rows), 2 on a usage error, 3 when a
  precondition is absent. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  {$ifdef UNIX}
  // NOT cthreads: mormot.uses.inc above already emits it on UNIX, and naming
  // it again is `Duplicate identifier "CTHREADS"`. `tools/pweb/pweb.pas` DOES
  // name it, and must, because that program has no mormot.uses.inc
  baseunix, // DEV7 / DEV8: the external SIGKILL of one named member
  {$endif UNIX}
  {$ifdef OSWINDOWS}
  windows, // DEV7 / DEV8: OpenProcess + TerminateProcess of one named member
  {$endif OSWINDOWS}
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
  pweb.cli.devlayout,
  pweb.cli.dev;

const
  /// how long the whole scenario may take before the driver gives up and
  // stops the run - a bound on a loop it does not control, never a knob
  DRIVER_TOTAL_MS = 900000;
  /// how long one scenario step waits for the event it expects
  DRIVER_STEP_MS = 240000;
  /// how long the broken-rebuild step watches for a generation that must
  // NOT appear
  DRIVER_QUIET_MS = 20000;
  /// the marker a source edit inserts, and the invalid text that breaks it
  DRIVER_MARKER = 'PWEBDEV_MARKER_TWO';
  DRIVER_BREAK = 'const *** = ;';
  /// DEV5: how many edits the burst writes, how long it leaves between
  // them, and how long the loop must then go without publishing before the
  // burst counts as settled
  // - the interval is deliberately SHORTER than any rebuild: the point of
  // this leg is that the edits arrive while the loop is still working
  DRIVER_BURST_EDITS = 5;
  // MEASURED on linux-x86_64 at 50 ms: the burst's last edit was never seen,
  // the page kept reporting 42 and the step timed out. This driver replaces a
  // file by DELETE-then-CREATE, which is what an editor's atomic save looks
  // like, and chokidar - the watcher underneath `vite build --watch` - folds
  // an unlink immediately followed by an add into one event inside a 100 ms
  // window. Five of them 50 ms apart are inside that window and collapse.
  // 150 ms is outside it and still far below the ~310 ms a rebuild takes
  // (measured at the CAP-10C2 checkpoint), so the edits still arrive FASTER
  // THAN THE LOOP CAN ANSWER THEM - which is the whole of what DEV5 claims.
  DRIVER_BURST_GAP_MS = 150;
  DRIVER_BURST_SETTLE_MS = 15000;
  /// the template's own summand, and the text the burst rewrites it to
  // - a COMMENT would prove the generations moved and nothing about what
  // they carried. SUM_B reaches the page: `value` is 20 + SUM_B, so the
  // final report is the one thing that can say the last edit is the one
  // that survived
  DRIVER_SUM_TEXT = 'const SUM_B = 22;';
  DRIVER_SUM_BASE = 22;
  /// what `value` must read after the burst: 20 + 22 + DRIVER_BURST_EDITS
  DRIVER_BURST_VALUE = 20 + DRIVER_SUM_BASE + DRIVER_BURST_EDITS;

type
  /// which of the three runs this driver is performing
  // - DEV7 and DEV8 END the loop, so neither can share the run that ends in
  // DEV6's clean interrupt: a run has exactly one ending, and asking one
  // run to prove two of them is how a gate stops being able to say which
  // ending it saw
  TScenario = (scLoop, scKillHost, scKillWatcher);

  TStep = (
    stAwaitGeneration1,
    stAwaitGeneration2,
    stAwaitQuiet,
    stAwaitGeneration3,
    stBurst,
    stAwaitBurst,
    stInterrupt,
    stAwaitUp,
    stKill,
    stDone);

var
  PwebPath, ProjectDir, SourcePath, StylePath: RawUtf8;
  HelperPath, ReportPath, CwdPath: RawUtf8;
  OriginalStyle: RawByteString;
  StyledCount: Integer;
  OutLines, ErrLines: TRawUtf8DynArray;
  Rows: RawUtf8;
  Step: TStep;
  StepStarted, QuietStarted, RunStarted: Int64;
  PwebPid, HostPid, HostPidAfter: PtrInt;
  Generation1, Generation2, Generation3: Boolean;
  Loaded1, Loaded2, Loaded3: Boolean;
  Ready1, Ready2: Boolean;
  ReadyCount: Integer;
  BrokenPublished: Boolean;
  Interrupted: Boolean;
  OriginalSource: RawByteString;
  Acted: Int64;
  AnsiSeen: Boolean;
  Scenario: TScenario;
  WatcherPid: PtrInt;
  // DEV5: the highest generation the loop announced and the highest the
  // host acknowledged, tracked as NUMBERS because a burst publishes more of
  // them than a scenario can name
  MaxReady, MaxLoaded: Integer;
  BurstBase, BurstWritten: Integer;
  BurstAt, LastReadyAt: Int64;
  BurstMonotonic: Boolean;
  LastValue: Integer;
  // DEV7 / DEV8: the member this run kills, and whether the kill landed
  KillTarget, KillPid: PtrInt;
  Killed: Boolean;

procedure Row(const Key, Value: RawUtf8);
begin
  Rows := Rows + Key + '=' + Value + #10;
end;

function Bool(B: Boolean): RawUtf8;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

procedure Die(const Msg: RawUtf8; Code: Integer);
begin
  WriteLn(StdErr, 'pwebdevdrv: ', string(Msg));
  Flush(StdErr);
  Halt(Code);
end;

function HasText(const Lines: TRawUtf8DynArray;
  const Needle: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  for i := 0 to High(Lines) do
    if PosEx(Needle, Lines[i]) > 0 then
      exit(True);
end;

// the leading run of digits that follows Marker, or Fallback when Marker is
// absent or is not followed by one
// - a line is `generation 2 ready (118 ms)` and a report is `"value":42,`:
// both carry the number this driver wants FOLLOWED by text, so cutting to
// the end of the line and asking StrToIntDef would answer the fallback for
// every line that is not exactly the number
function NumberAfter(const Line, Marker: RawUtf8; Fallback: Integer): Integer;
var
  at, stop: PtrInt;
  digits: RawUtf8;
begin
  Result := Fallback;
  at := PosEx(Marker, Line);
  if at = 0 then
    exit;
  at := at + Length(Marker);
  stop := at;
  while (stop <= Length(Line)) and
        (Line[stop] >= '0') and
        (Line[stop] <= '9') do
    Inc(stop);
  if stop = at then
    exit;
  digits := Copy(Line, at, stop - at);
  Result := StrToIntDef(string(digits), Fallback);
end;

procedure Collect(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  gen: Integer;
begin
  if PosExChar(#27, Line) > 0 then
    AnsiSeen := True;
  if Stream = pcsStdOut then
  begin
    SetLength(OutLines, Length(OutLines) + 1);
    OutLines[High(OutLines)] := Line;
  end
  else
  begin
    SetLength(ErrLines, Length(ErrLines) + 1);
    ErrLines[High(ErrLines)] := Line;
  end;
  WriteLn(Line);
  Flush(Output);
  // THE FIRST STEP'S CLOCK STARTS WHEN THE WATCHER DOES, not when this
  // driver did. MEASURED: the prerequisites - a conditional `npm ci`, one
  // `tsc` and a cold `-B` native compile of the whole mORMot surface - can
  // take minutes, and a step bound measured from the spawn was consumed by
  // them before the watcher existed, so the very first build timed out
  // having never been waited for
  if PosEx('pweb: watch: ', Line) > 0 then
    StepStarted := GetTickCount64();
  // the loop's own lines, read exactly as the gate will read them
  if PosEx('pweb: generation 1 ready', Line) > 0 then Generation1 := True;
  if PosEx('pweb: generation 2 ready', Line) > 0 then Generation2 := True;
  if PosEx('pweb: generation 3 ready', Line) > 0 then Generation3 := True;
  // the same line read as a NUMBER: a burst publishes more generations than
  // a scenario can name, and monotonicity is a property of the sequence
  if PosEx(' ready (', Line) > 0 then
  begin
    gen := NumberAfter(Line, 'pweb: generation ', 0);
    if gen > 0 then
    begin
      // strictly one more than the last: a gap or a repeat is exactly what
      // DEV5 exists to refuse
      if gen <> MaxReady + 1 then
        BurstMonotonic := False;
      if gen > MaxReady then
        MaxReady := gen;
      LastReadyAt := GetTickCount64();
    end;
  end;
  // DEV8 needs to name the OTHER member, so the loop prints its pid in the
  // same shape it prints the host's
  if PosEx('pweb: watch: started pid ', Line) > 0 then
    WatcherPid := NumberAfter(Line, 'pweb: watch: started pid ', 0);
  if PosEx('pweb: started pid ', Line) > 0 then
    if HostPid = 0 then
      HostPid := StrToInt64Def(string(Copy(Line,
        PosEx('pweb: started pid ', Line) + 18, MaxInt)), 0)
    else
      HostPidAfter := StrToInt64Def(string(Copy(Line,
        PosEx('pweb: started pid ', Line) + 18, MaxInt)), 0);
  // the HOST's own acknowledgement, in its one ratified shape
  if PWebCliDevParseAck(Copy(Line, 6, MaxInt), gen) or
     PWebCliDevParseAck(Line, gen) then
  begin
    if gen = 1 then Loaded1 := True;
    if gen = 2 then Loaded2 := True;
    if gen = 3 then Loaded3 := True;
    if gen > MaxLoaded then
      MaxLoaded := gen;
  end;
  // DEV5: the page's OWN arithmetic, which is the only channel that can say
  // which edit is the one still standing. `value` is 20 + SUM_B
  if PosEx('"value":', Line) > 0 then
    LastValue := NumberAfter(Line, '"value":', LastValue);
  // the PAGE's own report: the RPC value and the secure context
  if (PosEx('"value":42', Line) > 0) and
     (PosEx('"secure":true', Line) > 0) then
  begin
    Inc(ReadyCount);
    // DEV3: the page reads --pweb-styled back out of the APPLIED sheet, so
    // this is what proves a style edit reached the running window rather
    // than merely being packed
    if PosEx('"css":true', Line) > 0 then
      Inc(StyledCount);
    if not Ready1 then
      Ready1 := True
    else
      Ready2 := True;
  end;
end;

procedure StartedPid(Opaque: Pointer; Pid: PtrInt);
begin
  PwebPid := Pid;
end;

function ReadWhole(const Path: RawUtf8): RawByteString;
var
  tooBig: Boolean;
begin
  Result := '';
  PWebCliReadSmallFile(Path, PWEB_CLI_PIPE_MAX_FILE_BYTES, Result, tooBig);
end;

// the ONE way this driver edits a project file: it is replaced whole, and
// only ever with bytes derived from what was read at start - so a failed run
// can put the project back exactly as it found it
function WriteWhole(const Path: RawUtf8;
  const Content: RawByteString): Boolean;
begin
  PWebCliDeleteFile(Path);
  Result := PWebCliWriteNewFile(Path, Content, {SetExecBit=}False);
end;

function WriteSource(const Content: RawByteString): Boolean;
begin
  Result := WriteWhole(SourcePath, Content);
end;

// DEV3: a STYLE edit. A trailing comment changes app.css's bytes without
// changing what it declares, so `--pweb-styled` must still read back out of
// the applied sheet on the next generation
function WriteStyle(const Content: RawByteString): Boolean;
begin
  Result := WriteWhole(StylePath, Content);
end;

function Marked: RawByteString;
begin
  // a comment line, appended: it changes the module's bytes, so vite
  // rebuilds, and it cannot change what the page reports
  Result := OriginalSource + RawByteString('// ' + DRIVER_MARKER + #10);
end;

function Broken: RawByteString;
begin
  Result := OriginalSource + RawByteString(DRIVER_BREAK + #10);
end;

// DEV5: the Nth burst edit. It rewrites the template's own summand, so the
// edit is VISIBLE to the page rather than only to the bundler - which is
// what lets the last report say which edit is the one that survived
function Summed(N: Integer): RawByteString;
begin
  Result := RawByteString(StringReplace(string(OriginalSource),
    DRIVER_SUM_TEXT,
    'const SUM_B = ' + IntToStr(DRIVER_SUM_BASE + N) + ';', []));
end;

// DEV7 / DEV8: end ONE member from OUTSIDE the loop, the way a crash or an
// impatient `kill -9` would - never through the supervisor's own ladder,
// which is the graceful path DEV6 already measures. A pid this driver did
// not spawn has no job and no group here, so it is ended directly.
function HardKill(Pid: PtrInt): Boolean;
{$ifdef OSWINDOWS}
var
  h: THandle;
begin
  Result := False;
  if Pid <= 0 then
    exit;
  h := OpenProcess(PROCESS_TERMINATE, False, DWORD(Pid));
  if h = 0 then
    exit;
  Result := TerminateProcess(h, 9);
  CloseHandle(h);
end;
{$else}
begin
  // pid_t is a 32-bit cint and PtrInt is 64-bit here, so the narrowing is
  // written rather than left to an implicit conversion
  Result := (Pid > 0) and
            (FpKill(pid_t(Pid), SIGKILL) = 0);
end;
{$endif OSWINDOWS}

// deliver a REAL interrupt to the supervisor. Windows: the CAP-10C0 helper
// attaches to pweb's own console (it has one of its own, because this driver
// spawned it with SeparateConsole) and raises CTRL_C_EVENT. POSIX: SIGINT
// to the process group, which is what a terminal sends.
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
    Result := (r.Outcome = pcoExited) and (r.ExitCode = 0);
    if Result then
      exit;
  end;
  // POSIX, and the Windows fallback nothing should need: ask the platform
  // seam to stop the child's group, which is the same graceful request a
  // terminal makes
  child := Default(TPWebCliChild);
  child.Pid := PwebPid;
  Result := PWebCliChildStop(child) > 0;
end;

// THE SCENARIO, driven from the engine's stop-check callback: it is asked on
// every pass, it never returns True (this driver stops the run by asking the
// supervisor to stop, not by abandoning it), and every state change happens
// here so the whole thing is one supervised execution.
function DriverTick(Opaque: Pointer): Boolean;
var
  now_: Int64;
begin
  Result := False;
  now_ := GetTickCount64();
  if now_ - RunStarted > DRIVER_TOTAL_MS then
  begin
    // a bound on a loop this driver does not control. It asks the engine to
    // stop rather than walking away from a running tree
    Result := True;
    exit;
  end;
  case Step of
    stAwaitGeneration1:
      if Generation1 and Loaded1 and Ready1 then
      begin
        // DEV3: a STYLE edit. The next generation must apply it, and the
        // page's own `css` field is what proves it did
        if (StylePath = '') or
           WriteStyle(OriginalStyle +
             RawByteString('/* ' + DRIVER_MARKER + ' */'#10)) then
        begin
          Step := stAwaitGeneration2;
          StepStarted := now_;
        end
        else
        begin
          Row('driver_error', 'style_write_failed');
          Result := True;
        end;
      end
      else if now_ - StepStarted > DRIVER_STEP_MS then
      begin
        Row('driver_error', 'generation1_timeout');
        Result := True;
      end;
    stAwaitGeneration2:
      if Generation2 and Loaded2 and Ready2 then
      begin
        // DEV4: break it. The previous generation must stay live
        if WriteSource(Broken) then
        begin
          Step := stAwaitQuiet;
          QuietStarted := now_;
          StepStarted := now_;
        end
        else
        begin
          Row('driver_error', 'source_break_failed');
          Result := True;
        end;
      end
      else if now_ - StepStarted > DRIVER_STEP_MS then
      begin
        Row('driver_error', 'generation2_timeout');
        Result := True;
      end;
    stAwaitQuiet:
      begin
        if Generation3 then
          // a generation published from a BROKEN source: the failure this
          // step exists to catch
          BrokenPublished := True;
        if now_ - QuietStarted > DRIVER_QUIET_MS then
        begin
          // fix it, and the next generation must publish
          if WriteSource(Marked) then
          begin
            Step := stAwaitGeneration3;
            StepStarted := now_;
          end
          else
          begin
            Row('driver_error', 'source_fix_failed');
            Result := True;
          end;
        end;
      end;
    stAwaitGeneration3:
      if Generation3 and Loaded3 then
      begin
        Step := stBurst;
        StepStarted := now_;
      end
      else if now_ - StepStarted > DRIVER_STEP_MS then
      begin
        Row('driver_error', 'generation3_timeout');
        Step := stInterrupt;
      end;
    stBurst:
      begin
        // DEV5: five edits, faster than the loop can answer them. They are
        // written from THIS callback - one per pass - so they land while
        // the supervisor is running rather than while it is idle
        if BurstWritten = 0 then
          BurstBase := MaxReady;
        if BurstWritten < DRIVER_BURST_EDITS then
        begin
          if now_ - Acted >= DRIVER_BURST_GAP_MS then
          begin
            Inc(BurstWritten);
            if not WriteSource(Summed(BurstWritten)) then
            begin
              Row('driver_error', 'burst_write_failed');
              Step := stInterrupt;
              exit;
            end;
            Acted := now_;
          end;
        end
        else
        begin
          BurstAt := now_;
          LastReadyAt := now_;
          Step := stAwaitBurst;
          StepStarted := now_;
        end;
      end;
    stAwaitBurst:
      begin
        // settled = the loop published nothing for a whole settle window,
        // and the page has reported the arithmetic of the LAST edit
        if (now_ - LastReadyAt > DRIVER_BURST_SETTLE_MS) and
           (LastValue = DRIVER_BURST_VALUE) then
        begin
          Step := stInterrupt;
          StepStarted := now_;
        end
        else if now_ - StepStarted > DRIVER_STEP_MS then
        begin
          Row('driver_error', 'burst_timeout');
          Step := stInterrupt;
        end;
      end;
    stInterrupt:
      begin
        // DEV6: a REAL interrupt, through the CAP-10C0 mechanism
        Interrupted := Interrupt;
        Acted := now_;
        Step := stDone;
      end;
    stAwaitUp:
      // DEV7 / DEV8: the whole set has to be UP before one member is ended,
      // or the run would be measuring a start-up failure instead
      if Generation1 and Loaded1 and Ready1 and
         (HostPid <> 0) and (WatcherPid <> 0) then
      begin
        Step := stKill;
        StepStarted := now_;
      end
      else if now_ - StepStarted > DRIVER_STEP_MS then
      begin
        Row('driver_error', 'startup_timeout');
        Result := True;
      end;
    stKill:
      begin
        if Scenario = scKillHost then
          KillPid := HostPid
        else
          KillPid := WatcherPid;
        KillTarget := KillPid;
        Killed := HardKill(KillPid);
        Acted := now_;
        Step := stDone;
      end;
    stDone:
      ;
  end;
end;

procedure ParseArgs;
var
  i: Integer;
  a: RawUtf8;

  function Next(const Name: RawUtf8): RawUtf8;
  begin
    if i >= ParamCount then
      Die(Name + ' needs a value', 2);
    Inc(i);
    Result := RawUtf8(ParamStr(i));
  end;

begin
  i := 1;
  while i <= ParamCount do
  begin
    a := RawUtf8(ParamStr(i));
    if a = '--pweb' then PwebPath := Next(a)
    else if a = '--project' then ProjectDir := Next(a)
    else if a = '--source' then SourcePath := Next(a)
    else if a = '--style' then StylePath := Next(a)
    else if a = '--helper' then HelperPath := Next(a)
    else if a = '--report' then ReportPath := Next(a)
    else if a = '--cwd' then CwdPath := Next(a)
    else if a = '--scenario' then
    begin
      a := Next(a);
      if a = 'loop' then Scenario := scLoop
      else if a = 'killhost' then Scenario := scKillHost
      else if a = 'killwatcher' then Scenario := scKillWatcher
      else Die('unknown scenario: ' + a, 2);
    end
    else
      Die('unknown argument: ' + a, 2);
    Inc(i);
  end;
  if (PwebPath = '') or (ProjectDir = '') or (SourcePath = '') or
     (ReportPath = '') then
    Die('usage: pwebdevdrv --pweb <exe> --project <dir> --source <file> ' +
      '[--style <file>] [--helper <exe>] --report <file> [--cwd <dir>]', 2);
end;

var
  spec: TPWebCliExecSpec;
  r: TPWebCliExecResult;
  i: PtrInt;
  lines: RawUtf8;

begin
  ParseArgs;
  if PWebCliNodeKind(PwebPath) <> pcnFile then
    Die('no such CLI: ' + PwebPath, 3);
  if PWebCliNodeKind(SourcePath) <> pcnFile then
    Die('no such source file: ' + SourcePath, 3);
  if CwdPath = '' then
    if not PWebCliCwd(CwdPath) then
      Die('the working directory could not be resolved', 3);
  OriginalSource := ReadWhole(SourcePath);
  if OriginalSource = '' then
    Die('the source file is empty or unreadable', 3);
  if StylePath <> '' then
  begin
    if PWebCliNodeKind(StylePath) <> pcnFile then
      Die('no such stylesheet: ' + StylePath, 3);
    OriginalStyle := ReadWhole(StylePath);
    if OriginalStyle = '' then
      Die('the stylesheet is empty or unreadable', 3);
  end;

  BurstMonotonic := True;
  if Scenario = scLoop then
    Step := stAwaitGeneration1
  else
    Step := stAwaitUp;
  RunStarted := GetTickCount64();
  StepStarted := RunStarted;
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := PwebPath;
  spec.Args := [RawUtf8('dev'), RawUtf8('--project'), ProjectDir];
  // AN UNRELATED WORKING DIRECTORY, deliberately: `pweb dev` reads the
  // working directory exactly once and must not depend on being inside the
  // project
  spec.WorkDir := CwdPath;
  spec.Profile := pepSupervise;
  spec.TimeoutMs := DRIVER_TOTAL_MS + 60000;
  // the CAP-10C0 mechanism, reused rather than reinvented: its own console,
  // so a Windows CTRL_C_EVENT reaches it and not this driver
  spec.SeparateConsole := True;
  spec.Sink := @Collect;
  spec.StopCheck := @DriverTick;
  spec.Started := @StartedPid;
  spec.TreeRoot := PWebCliDisplayPath(ProjectDir);
  r := PWebCliExecute(spec);

  // put the project back exactly as it was found, whatever happened
  WriteSource(OriginalSource);
  if StylePath <> '' then
    WriteStyle(OriginalStyle);

  Row('driver_target', PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch));
  if Scenario <> scLoop then
  begin
    // DEV7 / DEV8: this run has ONE claim. A member was ended from outside,
    // and the loop had to bring the whole set down and say so
    if Scenario = scKillHost then
      Row('driver_scenario', 'killhost')
    else
      Row('driver_scenario', 'killwatcher');
    Row('kill_target_pid', RawUtf8(IntToStr(KillTarget)));
    Row('kill_delivered', Bool(Killed));
    Row('kill_set_was_up', Bool(Generation1 and Loaded1 and Ready1));
    Row('kill_pweb_outcome', PWebCliChildOutcomeText(r.Outcome));
    Row('kill_pweb_exit', RawUtf8(IntToStr(r.ExitCode)));
    Row('kill_descendants_remaining', RawUtf8(IntToStr(r.Drain.Remaining)));
    // ALWAYS emitted, 0 when no kill was delivered: the aggregator requires
    // every field it carries to be non-empty, so a row that is only
    // sometimes written is a required-field failure on the run where the
    // thing it measures did not happen - which is a confusing way to report
    // a scenario that did not reach its kill
    if Acted <> 0 then
      Row('kill_to_exit_ms', RawUtf8(IntToStr(Int64(GetTickCount64()) - Acted)))
    else
      Row('kill_to_exit_ms', '0');
    Row('driver_ansi_seen', Bool(AnsiSeen));
    Row('driver_step', RawUtf8(IntToStr(Ord(Step))));
    lines := '';
    for i := 0 to High(ErrLines) do
      lines := lines + 'E| ' + ErrLines[i] + #10;
    for i := 0 to High(OutLines) do
      lines := lines + 'O| ' + OutLines[i] + #10;
    PWebCliDeleteFile(ReportPath + '.lines');
    PWebCliWriteNewFile(ReportPath + '.lines', lines, False);
    PWebCliDeleteFile(ReportPath);
    if not PWebCliWriteNewFile(ReportPath, RawByteString(Rows), False) then
      Die('the report could not be written', 3);
    WriteLn(StdErr, 'pwebdevdrv: report written');
    Flush(StdErr);
    Halt(0);
  end;
  Row('driver_scenario', 'loop');
  Row('dev1_generation_ready', Bool(Generation1));
  Row('dev1_generation_loaded', Bool(Loaded1));
  Row('dev1_rpc_and_secure', Bool(Ready1));
  // DEV3: the style edit's generation, and the page reading --pweb-styled
  // back out of the sheet the new generation carried
  Row('dev3_generation_ready', Bool(Generation2));
  Row('dev3_generation_loaded', Bool(Loaded2));
  Row('dev3_styles_applied', Bool(StyledCount >= 2));
  Row('dev3_styled_reports', RawUtf8(IntToStr(StyledCount)));
  // DEV2: the SOURCE edit's generation - the recovery after the break -
  // with the page reporting 42 again
  Row('dev2_generation_ready', Bool(Generation3));
  Row('dev2_generation_loaded', Bool(Loaded3));
  Row('dev2_rpc_and_secure', Bool(Ready2));
  // THE CLAIM DEV2 EXISTS TO MAKE: one pid, for the whole session
  Row('dev2_host_pid_unchanged', Bool((HostPid <> 0) and (HostPidAfter = 0)));
  Row('dev4_broken_published', Bool(BrokenPublished));
  Row('dev4_host_alive_through_break', Bool(Generation3 or Loaded3));
  Row('dev4_recovered', Bool(Generation3 and Loaded3));
  // DEV5: five edits faster than the loop could answer them
  Row('dev5_burst_edits', RawUtf8(IntToStr(BurstWritten)));
  Row('dev5_burst_base', RawUtf8(IntToStr(BurstBase)));
  Row('dev5_generations_after_burst', RawUtf8(IntToStr(MaxReady)));
  // strictly increasing by one, over the WHOLE run and not only the burst
  Row('dev5_burst_monotonic', Bool(BurstMonotonic));
  // every generation the loop announced was also acknowledged by the host,
  // which is what says none of them was published half-written
  Row('dev5_all_generations_loaded', Bool((MaxReady > 0) and
    (MaxLoaded = MaxReady)));
  // THE CLAIM: the page's own arithmetic after the burst settled is the
  // arithmetic of the LAST edit, not of any earlier one
  Row('dev5_final_value', RawUtf8(IntToStr(LastValue)));
  Row('dev5_final_content_correct', Bool(LastValue = DRIVER_BURST_VALUE));
  Row('dev6_interrupt_delivered', Bool(Interrupted));
  Row('dev6_stop_requested',
    Bool(HasText(ErrLines, 'pweb: stop requested')));
  Row('dev6_pweb_outcome', PWebCliChildOutcomeText(r.Outcome));
  Row('dev6_pweb_exit', RawUtf8(IntToStr(r.ExitCode)));
  Row('dev6_descendants_remaining',
    RawUtf8(IntToStr(r.Drain.Remaining)));
  Row('dev6_descendants_seen', RawUtf8(IntToStr(Length(r.Drain.Seen))));
  if Acted <> 0 then
    Row('dev6_interrupt_to_exit_ms',
      RawUtf8(IntToStr(Int64(GetTickCount64()) - Acted)));
  // DEV6's other half - that no partial generation is left on a disk - is
  // measured by the GATE, which knows the layout's absolute path and can
  // simply look. This driver reports what it observed of the RUN
  Row('driver_ready_reports', RawUtf8(IntToStr(ReadyCount)));
  Row('driver_ansi_seen', Bool(AnsiSeen));
  Row('driver_step', RawUtf8(IntToStr(Ord(Step))));

  lines := '';
  for i := 0 to High(ErrLines) do
    lines := lines + 'E| ' + ErrLines[i] + #10;
  for i := 0 to High(OutLines) do
    lines := lines + 'O| ' + OutLines[i] + #10;
  PWebCliDeleteFile(ReportPath + '.lines');
  PWebCliWriteNewFile(ReportPath + '.lines', lines, False);
  PWebCliDeleteFile(ReportPath);
  if not PWebCliWriteNewFile(ReportPath, RawByteString(Rows), False) then
    Die('the report could not be written', 3);
  WriteLn(StdErr, 'pwebdevdrv: report written');
  Flush(StdErr);
  ExitCode := 0;
end.
