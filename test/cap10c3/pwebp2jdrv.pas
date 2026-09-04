program pwebp2jdrv;

{ CAP-10C3: the driver that spawns the REAL `pweb dev` on a REAL generated
  PAS2JS project and drives it.

  IT EXISTS AS A SEPARATE PROCESS for the reason the CAP-10C0 stop driver and
  the CAP-10C2 development driver do: a real console interrupt has to arrive
  at a real supervisor running a real loop, and a suite that signalled itself
  would be measuring its own runner. It reuses the CAP-10C0 MECHANISM rather
  than inventing a second one - the child is spawned with SeparateConsole,
  and on Windows the interrupt is delivered by test/cap10c0/pwebchild's
  `ctrlbreak <pid>`, which attaches to that console and raises CTRL_C_EVENT.

      pwebp2jdrv --pweb <exe> --project <dir> --source <app.pas>
                 --style <app.css> --markup <index.html>
                 --native <src/app.services.pas> --readme <README.md>
                 --helper <pwebchild> --report <file> [--cwd <dir>]
                 [--scenario loop|killhost]

  THE SCENARIO, in one supervised run, driven from the engine's own
  stop-check callback - the one place this driver is called on every pass:

    PD1  generation 1 is packed BEFORE the host starts, the host opens on
         pweb://app, the page reports secure = true and value = 42
    PD3  a STYLE edit publishes the next generation and the page reads
         --pweb-styled back out of the APPLIED sheet
    PD4  a MARKUP edit publishes the next generation (the gate reads the
         marker out of the published archive; this driver reports the switch)
    PD5  a BROKEN source stops publishing, the compiler's own output is
         forwarded, the previous generation stays live and the host stays
         alive - and the loop says so ONCE rather than rebuilding forever
    PD2  fixing it publishes the next generation, and the page's OWN
         arithmetic moves with the edit
    PD8  a file OUTSIDE the ratified input set - the native sources, the
         README - publishes nothing at all
    PD7  the input set REWRITTEN CONTINUOUSLY across a build: the generation
         is discarded and rebuilt, and a later quiet window publishes the
         correct content
    PD6  five edits faster than the loop can answer them: generations
         monotonic, nothing partial, and the page's last arithmetic is the
         LAST edit's
    PD11 a real interrupt stops the whole set inside the C0 bounds, with
         exit 0 and no partial generation left on disk

  and, in the `killhost` scenario and only there:

    PD12 the host is ended from OUTSIDE: the loop stops, exit 5, and the
         drain finds nothing left - there is no watcher child in a Pas2JS
         session, so the detector leaves nothing behind either

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
  // it again is `Duplicate identifier "CTHREADS"`
  baseunix, // PD12: the external SIGKILL of the host
  {$endif UNIX}
  {$ifdef OSWINDOWS}
  windows, // PD12: OpenProcess + TerminateProcess of the host
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
  pweb.cli.devinputs,
  pweb.cli.dev;

const
  /// how long the whole scenario may take before the driver gives up and
  // stops the run - a bound on a loop it does not control, never a knob
  DRIVER_TOTAL_MS = 900000;
  /// how long one scenario step waits for the event it expects
  DRIVER_STEP_MS = 240000;
  /// how long a step watches for a generation that must NOT appear
  DRIVER_QUIET_MS = 12000;
  /// the marker a style or markup edit inserts
  DRIVER_MARKER = 'PWEBDEV_MARKER_C3';
  /// PD7: how long the input set is rewritten CONTINUOUSLY, and how often
  // - the window is deliberately longer than PWEB_CLI_DEV_DEBOUNCE_MAX_MS,
  // so the debounce reaches its ceiling and the build STARTS while the
  // writes are still arriving. That is the only way to be sure the
  // consistency rule is exercised rather than merely available
  DRIVER_MOVE_MS = 9000;
  DRIVER_MOVE_GAP_MS = 40;
  /// how long a whole-file replacement may keep losing to a reader that has
  // not let go yet, and how often it tries again
  // - see WriteWhole. Small enough that it cannot hide a file this driver
  // genuinely cannot write, and larger than a compiler's read of one source
  DRIVER_WRITE_RETRY_MS = 2000;
  DRIVER_WRITE_RETRY_GAP_MS = 20;
  /// PD6: how many edits the burst writes and how long it leaves between
  // them, and how long the loop must then go without publishing before the
  // burst counts as settled
  DRIVER_BURST_EDITS = 5;
  DRIVER_BURST_GAP_MS = 150;
  DRIVER_BURST_SETTLE_MS = 15000;
  /// the template's own summand, and the arithmetic the page reports
  // - a COMMENT would prove the generations moved and nothing about what
  // they carried. SUM_B reaches the page: `value` is 20 + SUM_B, so the
  // report is the one channel that can say which edit is still standing
  DRIVER_SUM_TEXT = 'SUM_B = 22;';
  DRIVER_SUM_BASE = 22;
  /// PD2: what the page must report after the single source edit
  DRIVER_PD2_VALUE = 20 + DRIVER_SUM_BASE + 1;
  /// PD6: what it must report after the burst settled
  DRIVER_BURST_VALUE = 20 + DRIVER_SUM_BASE + DRIVER_BURST_EDITS;
  /// PD5: the text that makes the unit refuse to compile, inside the const
  // block rather than after `end.` - MEASURED: pas2js accepts trailing text
  // after the final END, so appending garbage is not a broken source
  DRIVER_BREAK_TEXT = 'SUM_B = ;';

type
  /// which run this driver is performing
  // - PD12 ENDS the loop, so it cannot share the run that ends in PD11's
  // clean interrupt: a run has exactly one ending, and asking one run to
  // prove two of them is how a gate stops being able to say which it saw
  TScenario = (scLoop, scKillHost);

  TStep = (
    stAwaitGeneration1,
    stAwaitStyle,
    stAwaitMarkup,
    stAwaitBrokenQuiet,
    stAwaitFixed,
    stAwaitOutsideQuiet,
    stMoving,
    stAwaitMoved,
    stBurst,
    stAwaitBurst,
    stInterrupt,
    stAwaitUp,
    stKill,
    stDone);

var
  PwebPath, ProjectDir, SourcePath, StylePath, MarkupPath: RawUtf8;
  NativePath, ReadmePath: RawUtf8;
  HelperPath, ReportPath, CwdPath: RawUtf8;
  OriginalSource, OriginalStyle, OriginalMarkup: RawByteString;
  OriginalNative, OriginalReadme: RawByteString;
  OutLines, ErrLines: TRawUtf8DynArray;
  Rows: RawUtf8;
  Step: TStep;
  StepStarted, QuietStarted, RunStarted, Acted: Int64;
  PwebPid, HostPid, HostPidAfter: PtrInt;
  Scenario: TScenario;
  AnsiSeen, Interrupted: Boolean;
  // the generation NUMBERS the loop announced and the host acknowledged
  MaxReady, MaxLoaded: Integer;
  Monotonic: Boolean;
  LastReadyAt: Int64;
  // the page's own report
  ReadyCount, StyledCount, LastValue: Integer;
  // the generation each step is waiting to pass
  StyleBase, MarkupBase, BrokenBase, FixedBase, OutsideBase: Integer;
  MoveBase, BurstBase: Integer;
  // PD5 / PD7 / PD6 observations
  CompileFailures, CompilerLines, Discarded: Integer;
  MoveWritten, BurstWritten: Integer;
  // PD12
  KillPid: PtrInt;
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

function IntText(V: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(V));
end;

procedure Die(const Msg: RawUtf8; Code: Integer);
begin
  WriteLn(StdErr, 'pwebp2jdrv: ', string(Msg));
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

// the leading run of digits that follows Marker, or Fallback
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
  // THE FIRST STEP'S CLOCK STARTS WHEN DETECTION IS ARMED, not when this
  // driver did: the native dev compile of the whole mORMot surface runs
  // first and can take minutes, and a step bound measured from the spawn
  // would be consumed by it before the loop existed
  if PosEx('pweb: watch: ', Line) > 0 then
    StepStarted := GetTickCount64();
  // the loop's own generation line, read exactly as the gate reads it
  if PosEx(' ready (', Line) > 0 then
  begin
    gen := NumberAfter(Line, 'pweb: generation ', 0);
    if gen > 0 then
    begin
      // strictly one more than the last: a gap or a repeat is exactly what
      // the monotonicity claim exists to refuse
      if gen <> MaxReady + 1 then
        Monotonic := False;
      if gen > MaxReady then
        MaxReady := gen;
      LastReadyAt := GetTickCount64();
    end;
  end;
  // PD5: the loop reports a compile failure and keeps the previous
  // generation live
  if PosEx('compile failed', Line) > 0 then
    Inc(CompileFailures);
  // the compiler's OWN forwarded output, under the prefix this loop gives it
  if PosEx('pas2js: ', Line) > 0 then
    Inc(CompilerLines);
  // PD7: the consistency rule firing, in its ratified words
  if (PosEx(' discarded: the inputs moved during the build', Line) > 0) or
     (PosEx(' abandoned: the sources changed faster', Line) > 0) then
    Inc(Discarded);
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
    if gen > MaxLoaded then
      MaxLoaded := gen;
  // the page's OWN report - the only channel that can say what the running
  // window actually computed
  if PosEx('"value":', Line) > 0 then
    LastValue := NumberAfter(Line, '"value":', LastValue);
  if PosEx('"secure":true', Line) > 0 then
  begin
    Inc(ReadyCount);
    // the page reads --pweb-styled back out of the APPLIED sheet, so this
    // is what proves a style edit reached the running window rather than
    // merely being packed
    if PosEx('"css":true', Line) > 0 then
      Inc(StyledCount);
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
//
// IT RETRIES, and the retry is the point rather than a workaround. PD7
// rewrites the input set roughly twenty-five times a second WHILE a build is
// in flight, which means this delete-then-create races the PAS2JS COMPILER
// reading the very file it is rewriting. On Windows a third-party reader
// that opened the source without FILE_SHARE_DELETE makes the delete fail,
// and a delete that DID succeed against a reader holding the handle leaves
// the name delete-pending, where CREATE_NEW answers access-denied until the
// last handle closes. Neither is a fact about the development loop - it is
// the operating system's momentary answer about a compiler this repository
// does not own - so a driver that reported it as a failure would be
// reporting the compiler's file handle as a defect in `pweb dev`. MEASURED:
// the hosted Windows leg of 2026-09-04 failed PD6/PD7 with
// `move_write_failed` on the first such collision after this scenario had
// run green on every previous Windows run. The budget is bounded and small
// on purpose: it absorbs a handle that is closing, never a file that is
// genuinely unwritable, and a write that never lands still fails the leg.
function WriteWhole(const Path: RawUtf8;
  const Content: RawByteString): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  repeat
    PWebCliDeleteFile(Path);
    Result := PWebCliWriteNewFile(Path, Content, {SetExecBit=}False);
    if Result or (waited >= DRIVER_WRITE_RETRY_MS) then
      exit;
    SleepHiRes(DRIVER_WRITE_RETRY_GAP_MS);
    Inc(waited, DRIVER_WRITE_RETRY_GAP_MS);
  until False;
end;

function Summed(N: Integer): RawByteString;
begin
  Result := RawByteString(StringReplace(string(OriginalSource),
    DRIVER_SUM_TEXT, 'SUM_B = ' + IntToStr(DRIVER_SUM_BASE + N) + ';', []));
end;

function Broken: RawByteString;
begin
  Result := RawByteString(StringReplace(string(OriginalSource),
    DRIVER_SUM_TEXT, DRIVER_BREAK_TEXT, []));
end;

// PD7: the Nth "moving" write - well-formed Pascal whose BYTES differ every
// time, so the input fingerprint keeps moving while a build is in flight
function Moved(N: Integer): RawByteString;
begin
  Result := RawByteString(StringReplace(string(OriginalSource),
    'unit app;', 'unit app; { move ' + IntToStr(N) + ' }', []));
end;

// PD12: end the host from OUTSIDE the loop, the way a crash or an impatient
// `kill -9` would - never through the supervisor's own ladder, which is the
// graceful path PD11 already measures
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

// deliver a REAL interrupt to the supervisor
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
  child := Default(TPWebCliChild);
  child.Pid := PwebPid;
  Result := PWebCliChildStop(child) > 0;
end;

// THE SCENARIO, driven from the engine's stop-check callback: it is asked on
// every pass, it never returns True except on the total bound (this driver
// stops the run by asking the supervisor to stop, not by abandoning it), and
// every state change happens here so the whole thing is one supervised
// execution.
function DriverTick(Opaque: Pointer): Boolean;
var
  now_: Int64;

  // move to the next step, arming its clock
  procedure Next(S: TStep);
  begin
    Step := S;
    StepStarted := now_;
    QuietStarted := now_;
  end;

  function TimedOut(const Cause: RawUtf8): Boolean;
  var
    over: Boolean;
  begin
    // a LOCAL rather than a bare read of the function name: inside its own
    // body a function that takes a parameter is its own reference, not its
    // result, and `if TimedOut then` does not compile
    over := now_ - StepStarted > DRIVER_STEP_MS;
    if over then
      Row('driver_error', Cause);
    TimedOut := over;
  end;

begin
  Result := False;
  now_ := GetTickCount64();
  if now_ - RunStarted > DRIVER_TOTAL_MS then
  begin
    // a bound on a loop this driver does not control. It asks the engine to
    // stop rather than walking away from a running tree
    Row('driver_error', 'total_timeout');
    exit(True);
  end;
  case Step of
    stAwaitGeneration1:
      // PD1: generation 1 is packed BEFORE the host starts, the window
      // opens, and the page reports 42 in a secure context
      if (MaxReady >= 1) and (MaxLoaded >= 1) and (ReadyCount >= 1) then
      begin
        StyleBase := MaxReady;
        // PD3: a STYLE edit. A trailing comment changes app.css's bytes
        // without changing what it declares, so --pweb-styled must still
        // read back out of the APPLIED sheet on the next generation
        if WriteWhole(StylePath, OriginalStyle +
             RawByteString('/* ' + DRIVER_MARKER + ' */'#10)) then
          Next(stAwaitStyle)
        else
        begin
          Row('driver_error', 'style_write_failed');
          Result := True;
        end;
      end
      else if TimedOut('generation1_timeout') then
        Result := True;
    stAwaitStyle:
      if (MaxReady > StyleBase) and (MaxLoaded >= MaxReady) then
      begin
        MarkupBase := MaxReady;
        // PD4: a MARKUP edit. The gate reads the marker out of the
        // published archive; this driver reports the switch
        if WriteWhole(MarkupPath, OriginalMarkup +
             RawByteString('<!-- ' + DRIVER_MARKER + ' -->'#10)) then
          Next(stAwaitMarkup)
        else
        begin
          Row('driver_error', 'markup_write_failed');
          Result := True;
        end;
      end
      else if TimedOut('style_timeout') then
        Result := True;
    stAwaitMarkup:
      if (MaxReady > MarkupBase) and (MaxLoaded >= MaxReady) then
      begin
        BrokenBase := MaxReady;
        // PD5: break it. The previous generation must stay live
        if WriteWhole(SourcePath, Broken) then
          Next(stAwaitBrokenQuiet)
        else
        begin
          Row('driver_error', 'source_break_failed');
          Result := True;
        end;
      end
      else if TimedOut('markup_timeout') then
        Result := True;
    stAwaitBrokenQuiet:
      if now_ - QuietStarted > DRIVER_QUIET_MS then
      begin
        FixedBase := MaxReady;
        // PD2: fix it, with an edit the PAGE can see - the template's own
        // summand, so `value` moves with the source
        if WriteWhole(SourcePath, Summed(1)) then
          Next(stAwaitFixed)
        else
        begin
          Row('driver_error', 'source_fix_failed');
          Result := True;
        end;
      end;
    stAwaitFixed:
      if (MaxReady > FixedBase) and (MaxLoaded >= MaxReady) and
         (LastValue = DRIVER_PD2_VALUE) then
      begin
        OutsideBase := MaxReady;
        // PD8: files OUTSIDE the ratified input set. Nothing may publish
        if WriteWhole(NativePath, OriginalNative +
             RawByteString(#10'// ' + DRIVER_MARKER + #10)) and
           WriteWhole(ReadmePath, OriginalReadme +
             RawByteString(#10'<!-- ' + DRIVER_MARKER + ' -->'#10)) then
          Next(stAwaitOutsideQuiet)
        else
        begin
          Row('driver_error', 'outside_write_failed');
          Result := True;
        end;
      end
      else if TimedOut('fixed_timeout') then
        Result := True;
    stAwaitOutsideQuiet:
      if now_ - QuietStarted > DRIVER_QUIET_MS then
      begin
        MoveBase := MaxReady;
        Acted := 0;
        MoveWritten := 0;
        Next(stMoving);
      end;
    stMoving:
      // PD7: rewrite the input set CONTINUOUSLY for longer than the
      // debounce ceiling, so the build starts while the writes are still
      // arriving and the consistency rule has to fire
      if now_ - StepStarted > DRIVER_MOVE_MS then
      begin
        // the last write leaves the source in its ORIGINAL well-formed
        // shape, so what publishes afterwards is content the gate can check
        if WriteWhole(SourcePath, Summed(1)) then
          Next(stAwaitMoved)
        else
        begin
          Row('driver_error', 'move_restore_failed');
          Result := True;
        end;
      end
      else if now_ - Acted >= DRIVER_MOVE_GAP_MS then
      begin
        Inc(MoveWritten);
        if not WriteWhole(SourcePath, Moved(MoveWritten)) then
        begin
          Row('driver_error', 'move_write_failed');
          Step := stInterrupt;
          exit;
        end;
        Acted := now_;
      end;
    stAwaitMoved:
      if (MaxReady > MoveBase) and (MaxLoaded >= MaxReady) and
         (LastValue = DRIVER_PD2_VALUE) then
      begin
        BurstBase := MaxReady;
        BurstWritten := 0;
        Acted := 0;
        Next(stBurst);
      end
      else if TimedOut('moved_timeout') then
        Step := stInterrupt;
    stBurst:
      // PD6: five edits, faster than the loop can answer them. They are
      // written from THIS callback - one per pass - so they land while the
      // supervisor is running rather than while it is idle
      if BurstWritten < DRIVER_BURST_EDITS then
      begin
        if now_ - Acted >= DRIVER_BURST_GAP_MS then
        begin
          Inc(BurstWritten);
          if not WriteWhole(SourcePath, Summed(BurstWritten)) then
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
        LastReadyAt := now_;
        Next(stAwaitBurst);
      end;
    stAwaitBurst:
      // settled = the loop published nothing for a whole settle window, and
      // the page has reported the arithmetic of the LAST edit
      if (now_ - LastReadyAt > DRIVER_BURST_SETTLE_MS) and
         (LastValue = DRIVER_BURST_VALUE) then
        Next(stInterrupt)
      else if TimedOut('burst_timeout') then
        Step := stInterrupt;
    stInterrupt:
      begin
        // PD11: a REAL interrupt, through the CAP-10C0 mechanism
        Interrupted := Interrupt;
        Acted := now_;
        Step := stDone;
      end;
    stAwaitUp:
      // PD12: the whole set has to be UP before the host is ended, or the
      // run would be measuring a start-up failure instead
      if (MaxReady >= 1) and (MaxLoaded >= 1) and (ReadyCount >= 1) and
         (HostPid <> 0) then
        Next(stKill)
      else if TimedOut('startup_timeout') then
        Result := True;
    stKill:
      begin
        KillPid := HostPid;
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

  function NextArg(const Name: RawUtf8): RawUtf8;
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
    if a = '--pweb' then PwebPath := NextArg(a)
    else if a = '--project' then ProjectDir := NextArg(a)
    else if a = '--source' then SourcePath := NextArg(a)
    else if a = '--style' then StylePath := NextArg(a)
    else if a = '--markup' then MarkupPath := NextArg(a)
    else if a = '--native' then NativePath := NextArg(a)
    else if a = '--readme' then ReadmePath := NextArg(a)
    else if a = '--helper' then HelperPath := NextArg(a)
    else if a = '--report' then ReportPath := NextArg(a)
    else if a = '--cwd' then CwdPath := NextArg(a)
    else if a = '--scenario' then
    begin
      a := NextArg(a);
      if a = 'loop' then Scenario := scLoop
      else if a = 'killhost' then Scenario := scKillHost
      else Die('unknown scenario: ' + a, 2);
    end
    else
      Die('unknown argument: ' + a, 2);
    Inc(i);
  end;
  if (PwebPath = '') or (ProjectDir = '') or (SourcePath = '') or
     (StylePath = '') or (MarkupPath = '') or (ReportPath = '') then
    Die('usage: pwebp2jdrv --pweb <exe> --project <dir> --source <file> ' +
      '--style <file> --markup <file> [--native <file>] [--readme <file>] ' +
      '[--helper <exe>] --report <file> [--cwd <dir>] ' +
      '[--scenario loop|killhost]', 2);
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
  if PWebCliNodeKind(StylePath) <> pcnFile then
    Die('no such stylesheet: ' + StylePath, 3);
  if PWebCliNodeKind(MarkupPath) <> pcnFile then
    Die('no such markup file: ' + MarkupPath, 3);
  if CwdPath = '' then
    if not PWebCliCwd(CwdPath) then
      Die('the working directory could not be resolved', 3);
  OriginalSource := ReadWhole(SourcePath);
  OriginalStyle := ReadWhole(StylePath);
  OriginalMarkup := ReadWhole(MarkupPath);
  if (OriginalSource = '') or (OriginalStyle = '') or
     (OriginalMarkup = '') then
    Die('an input of the ratified set is empty or unreadable', 3);
  // the SOURCE must carry the summand this driver edits, or every
  // arithmetic claim below would be measuring nothing
  if PosEx(DRIVER_SUM_TEXT, OriginalSource) = 0 then
    Die('the source does not carry ' + DRIVER_SUM_TEXT, 3);
  if NativePath <> '' then
    OriginalNative := ReadWhole(NativePath);
  if ReadmePath <> '' then
    OriginalReadme := ReadWhole(ReadmePath);

  Monotonic := True;
  if Scenario = scLoop then
    Step := stAwaitGeneration1
  else
    Step := stAwaitUp;
  RunStarted := GetTickCount64();
  StepStarted := RunStarted;
  QuietStarted := RunStarted;
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
  WriteWhole(SourcePath, OriginalSource);
  WriteWhole(StylePath, OriginalStyle);
  WriteWhole(MarkupPath, OriginalMarkup);
  if (NativePath <> '') and (OriginalNative <> '') then
    WriteWhole(NativePath, OriginalNative);
  if (ReadmePath <> '') and (OriginalReadme <> '') then
    WriteWhole(ReadmePath, OriginalReadme);

  Row('driver_target', PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch));
  Row('driver_ansi_seen', Bool(AnsiSeen));
  Row('driver_step', IntText(Ord(Step)));
  Row('driver_ready_reports', IntText(ReadyCount));
  Row('generations_ready', IntText(MaxReady));
  Row('generations_loaded', IntText(MaxLoaded));
  if Scenario = scKillHost then
  begin
    // PD12: this run has ONE claim. The host was ended from outside, and
    // the loop had to bring the whole set down and say so
    Row('driver_scenario', 'killhost');
    Row('pd12_set_was_up', Bool((MaxReady >= 1) and (MaxLoaded >= 1) and
      (ReadyCount >= 1)));
    Row('pd12_kill_target_pid', IntText(KillPid));
    Row('pd12_kill_delivered', Bool(Killed));
    Row('pd12_pweb_outcome', PWebCliChildOutcomeText(r.Outcome));
    Row('pd12_pweb_exit', IntText(r.ExitCode));
    Row('pd12_descendants_remaining', IntText(r.Drain.Remaining));
    // ALWAYS emitted, 0 when no kill was delivered: every field the
    // aggregator carries must be non-empty, so a row that is only
    // sometimes written is a required-field failure on the run where the
    // thing it measures did not happen
    if Acted <> 0 then
      Row('pd12_kill_to_exit_ms', IntText(Int64(GetTickCount64()) - Acted))
    else
      Row('pd12_kill_to_exit_ms', '0');
  end
  else
  begin
    Row('driver_scenario', 'loop');
    // PD1
    Row('pd1_generation_ready', Bool(MaxReady >= 1));
    Row('pd1_generation_loaded', Bool(MaxLoaded >= 1));
    Row('pd1_rpc_and_secure', Bool(ReadyCount >= 1));
    // PD3 - the page read --pweb-styled back out of the APPLIED sheet on
    // more than the first generation
    Row('pd3_generation_ready', Bool(MaxReady > StyleBase));
    Row('pd3_styles_applied', Bool(StyledCount >= 2));
    Row('pd3_styled_reports', IntText(StyledCount));
    // PD4
    Row('pd4_generation_ready', Bool(MaxReady > MarkupBase));
    // PD5 - the broken source published NOTHING, the compiler's own output
    // was forwarded, and the loop said so ONCE rather than forever
    Row('pd5_broken_published', Bool(FixedBase > BrokenBase));
    Row('pd5_compile_failures', IntText(CompileFailures));
    Row('pd5_compiler_lines_forwarded', IntText(CompilerLines));
    Row('pd5_error_forwarded', Bool(CompilerLines > 0));
    Row('pd5_recovered', Bool(MaxReady > FixedBase));
    // PD2 - the page's OWN arithmetic moved with the source edit
    Row('pd2_generation_ready', Bool(MaxReady > FixedBase));
    Row('pd2_host_pid_unchanged',
      Bool((HostPid <> 0) and (HostPidAfter = 0)));
    // PD8 - nothing outside the ratified input set published anything
    Row('pd8_outside_published', Bool(MoveBase > OutsideBase));
    // PD7 - the consistency rule fired, and a later quiet window published
    Row('pd7_moving_writes', IntText(MoveWritten));
    Row('pd7_discarded', IntText(Discarded));
    Row('pd7_inconsistent_discarded', Bool(Discarded > 0));
    Row('pd7_recovered', Bool(MaxReady > MoveBase));
    // PD6 - five edits faster than the loop could answer them
    Row('pd6_burst_edits', IntText(BurstWritten));
    Row('pd6_monotonic', Bool(Monotonic));
    Row('pd6_all_generations_loaded',
      Bool((MaxReady > 0) and (MaxLoaded = MaxReady)));
    Row('pd6_final_value', IntText(LastValue));
    Row('pd6_final_content_correct', Bool(LastValue = DRIVER_BURST_VALUE));
    // PD11
    Row('pd11_interrupt_delivered', Bool(Interrupted));
    Row('pd11_stop_requested',
      Bool(HasText(ErrLines, 'pweb: stop requested')));
    Row('pd11_pweb_outcome', PWebCliChildOutcomeText(r.Outcome));
    Row('pd11_pweb_exit', IntText(r.ExitCode));
    Row('pd11_descendants_remaining', IntText(r.Drain.Remaining));
    Row('pd11_descendants_seen', IntText(Length(r.Drain.Seen)));
    if Acted <> 0 then
      Row('pd11_interrupt_to_exit_ms',
        IntText(Int64(GetTickCount64()) - Acted))
    else
      Row('pd11_interrupt_to_exit_ms', '0');
  end;

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
  WriteLn(StdErr, 'pwebp2jdrv: report written');
  Flush(StdErr);
  ExitCode := 0;
end.
