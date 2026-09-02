{
  pweb.cli.process - the ONE child-process execution engine of the CLI
  (CAP-10C0).

  THE ONLY PLACE IN THE CLI THAT RUNS A CHILD TO COMPLETION. pweb.cli.probe
  (CAP-10A) is a caller of this unit, `pweb run` is a caller of this unit,
  and `pweb dev` / `pweb build` will be callers of this unit. There is one
  drain loop, one escalation ladder, one outcome type and one descendant
  drain, and the two usage profiles differ only in what they do with the
  bytes and how they treat the bound:

    probe      bounded capture: both streams kept up to a ceiling and
               discarded past it, the bound expiring means the child is
               force-terminated at once (a version query has no window to
               close) - the CAP-10A semantics, unchanged;
    supervise  foreground forwarding: both streams re-emitted line by line
               through a sink, a stop request (Ctrl+C / SIGINT / SIGTERM /
               SIGHUP, or an optional bound) means a GRACEFUL stop first -
               WM_CLOSE to the child's windows, SIGTERM to its group - and
               a forced termination of the whole tree only after the
               ratified grace interval.

  ---------------------------------------------------------------------------
  NO SHELL, NO COMMAND STRING, NO GUESSED ARGUMENT
  ---------------------------------------------------------------------------

  A spawn is (exact executable path, argument vector, explicit working
  directory). Before anything is created the vector is REFUSED if any element
  carries a NUL or is not strict UTF-8, and the executable is refused if it is
  a batch file - `.cmd` / `.bat` are interpreted by cmd.exe and cannot be run
  by CreateProcessW without it, so they are never run at all, on any platform.
  The Windows command line is built by pweb.cli.platform's
  PWebCliWindowsCommandLine, the inverse of the C runtime's parser, and
  test/cap10c0 proves the round trip against a child that echoes its argv.

  ---------------------------------------------------------------------------
  BOUNDED, TYPED, REAPED
  ---------------------------------------------------------------------------

    - both streams are read on every pass, so a child that fills one pipe
      while the supervisor waits on the other can never deadlock it;
    - the exit status is EXACT: the platform seam applies WEXITSTATUS on
      POSIX (the CAP-10A 768-for-3 defect stays fixed) and reads the process
      exit code on Windows; death by signal is pcoSignaled, a termination the
      supervisor had to perform is pcoForced - neither is ever reported as an
      exit code, and neither can ever read as 0;
    - graceful then forced, both intervals bounded and MEASURED into the
      result (StopToExitMs, KillToReapMs), and a child that outlives even the
      forced bound is reported as pcoUnreaped rather than waited on forever;
    - after the child is gone, the tree it owned is drained: members are
      enumerated by MEMBERSHIP (job / process group) through the platform
      seam, given the grace interval, then terminated as a tree and
      re-enumerated until none remain or the pass bound expires. Every
      member seen is recorded with pid, parent pid, image path and whether
      it went gracefully or was forced. An image path is annotation: it is
      never how a process is selected, and an unreadable one is recorded as
      empty, never treated as matching.

  The drain is written over injectable verbs (enumerate, stop, kill, sleep)
  for one reason: the interesting cases - a member that vanishes between two
  passes, a member that appears after the first pass, a survivor at the pass
  bound - cannot be staged against a real browser, and test/cap10c0 proves
  them against injected records, the way test/cap6b3/check_wv2procdrain.ps1
  proves the CI teardown helper this design descends from.
}
unit pweb.cli.process;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.assets.support,
  pweb.cli.platform,
  pweb.cli.toolchain;

type
  /// the two ways a child is run - see the unit header
  TPWebCliExecProfile = (pepProbe, pepSupervise);

  /// what became of the child - ordinal 0 is a failure state
  TPWebCliChildOutcome = (
    /// refused before anything was created (see TPWebCliExecRefusal)
    pcoSpawnRefused,
    /// the platform could not start it (see Failure / OsError)
    pcoSpawnFailed,
    /// it exited by itself; ExitCode is exact
    pcoExited,
    /// POSIX: it died by a signal it did not ask for; Signal is set
    pcoSignaled,
    /// the supervisor had to terminate the tree after the grace interval
    pcoForced,
    /// terminated, but not reaped inside the forced bound - an invariant
    // failure of the platform, reported rather than waited on
    pcoUnreaped);

  /// why a spawn was refused before it was attempted
  TPWebCliExecRefusal = (
    perNone,
    /// no executable path
    perEmptyPath,
    /// an argument (or the path) carries NUL or is not strict UTF-8
    perArgEncoding,
    /// the executable is a batch file: interpreted by a shell, never run
    perBatchFile);

  /// one process the descendant drain saw after the child had exited
  TPWebCliDrainEntry = record
    Pid: PtrInt;
    ParentPid: PtrInt;
    /// '' when unreadable - recorded, never a criterion
    Image: RawUtf8;
    /// annotation: the image lies under the application tree (component
    // boundary; '' is never under anything)
    UnderTree: Boolean;
    /// True when it was still present when the tree was force-terminated
    Forced: Boolean;
  end;
  TPWebCliDrainEntries = array of TPWebCliDrainEntry;

  /// the descendant drain's record
  TPWebCliDrainReport = record
    /// enumeration passes made (>= 1)
    Passes: Integer;
    /// True when nothing had to be force-terminated
    Graceful: Boolean;
    /// True when the forced termination was issued
    Forced: Boolean;
    /// every member seen after the child's exit, once each
    Seen: TPWebCliDrainEntries;
    /// members still present after the last pass - required to be 0
    Remaining: Integer;
  end;

  /// the supervise sink: one forwarded line, without its newline
  // - Truncated is True when the line exceeded PWEB_CLI_RUN_LINE_MAX and
  // was cut; the discarded remainder is never delivered
  TPWebCliLineSink = procedure(Opaque: Pointer; Stream: TPWebCliChildStream;
    const Line: RawUtf8; Truncated: Boolean);

  /// the supervise stop question, asked on every pass
  // - nil means PWebCliStopRequested (the installed console / signal handler)
  TPWebCliStopCheck = function(Opaque: Pointer): Boolean;

  /// called once, right after the child exists, with its pid
  TPWebCliStartedNotify = procedure(Opaque: Pointer; Pid: PtrInt);

  /// everything one execution needs
  TPWebCliExecSpec = record
    ExePath: RawUtf8;
    /// argv[1..]; argv[0] is ExePath
    Args: TRawUtf8DynArray;
    /// explicit and mandatory - never the working directory of this process
    WorkDir: RawUtf8;
    Profile: TPWebCliExecProfile;
    /// probe: the bound (required); supervise: 0 = no bound
    TimeoutMs: Cardinal;
    /// Windows test-driver option, see PWebCliChildSpawn
    SeparateConsole: Boolean;
    Sink: TPWebCliLineSink;
    StopCheck: TPWebCliStopCheck;
    Started: TPWebCliStartedNotify;
    Opaque: Pointer;
    /// the application tree, in display form, for the UnderTree annotation
    TreeRoot: RawUtf8;
  end;

  /// everything one execution learned
  TPWebCliExecResult = record
    Outcome: TPWebCliChildOutcome;
    Refusal: TPWebCliExecRefusal;
    Failure: TPWebCliSpawnFailure;
    OsError: Integer;
    Pid: PtrInt;
    /// exact, meaningful for pcoExited (and recorded for pcoForced)
    ExitCode: Integer;
    /// POSIX signal number for pcoSignaled; 0 otherwise
    Signal: Integer;
    /// the bound expired (probe: the child was killed; supervise: a
    // graceful stop was requested by the bound)
    TimedOut: Boolean;
    /// a stop was requested by the stop check before the child exited
    StopRequested: Boolean;
    /// how many graceful stop requests were posted (Windows: windows
    // closed; POSIX: group signals)
    StopPosts: Integer;
    /// from the first stop request until the child exited; -1 if it did
    // not exit by itself
    StopToExitMs: Integer;
    /// from the forced termination until the reap; -1 if never forced
    KillToReapMs: Integer;
    ElapsedMs: Int64;
    /// probe: the captured stdout; supervise: ''
    Output: RawUtf8;
    /// probe: the captured stderr; supervise: the retained stderr tail
    ErrorText: RawUtf8;
    /// a capture / retention ceiling was exceeded
    Truncated: Boolean;
    /// a forwarded line was cut at PWEB_CLI_RUN_LINE_MAX
    LinesTruncated: Integer;
    Drain: TPWebCliDrainReport;
  end;

  /// the drain's injectable verbs (the real ones bind to pweb.cli.platform)
  TPWebCliDrainEnumerate = function(Opaque: Pointer): TPWebCliTreeMembers;
  TPWebCliDrainAct = procedure(Opaque: Pointer);
  TPWebCliDrainSleep = procedure(Opaque: Pointer; Ms: Cardinal);

/// stable text for an outcome
function PWebCliChildOutcomeText(Outcome: TPWebCliChildOutcome): RawUtf8;

/// stable text for a refusal
function PWebCliExecRefusalText(Refusal: TPWebCliExecRefusal): RawUtf8;

/// the pre-spawn refusals, as a pure function over the spec
function PWebCliExecAcceptable(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray; out Refusal: TPWebCliExecRefusal): Boolean;

/// True when Path lies strictly under Root on a COMPONENT boundary
// - '' is never under anything, and neither is Root itself
// - CaseFold selects the Windows comparison (ASCII case-insensitive); both
// separators are accepted so a display path and a canonical one compare
function PWebCliPathUnderTree(const Path, Root: RawUtf8;
  CaseFold: Boolean): Boolean;

/// run ONE child to completion under the given profile - see the unit header
function PWebCliExecute(const Spec: TPWebCliExecSpec): TPWebCliExecResult;

/// the descendant drain over injectable verbs
// - ExcludePid is the child itself (already exited; it may still be listed
// by a job until its handle is closed)
// - GraceMs bounds the graceful window by time; MaxPasses bounds the
// re-enumeration AFTER the forced termination, so the two never compete
function PWebCliDrainTree(Opaque: Pointer; Enumerate: TPWebCliDrainEnumerate;
  Stop, Kill: TPWebCliDrainAct; Sleep: TPWebCliDrainSleep;
  ExcludePid: PtrInt; GraceMs, PollMs: Cardinal; MaxPasses: Integer;
  const TreeRoot: RawUtf8; CaseFold: Boolean): TPWebCliDrainReport;

/// the default stop check: the installed handler's flag
function PWebCliDefaultStopCheck(Opaque: Pointer): Boolean;


implementation

function PWebCliChildOutcomeText(Outcome: TPWebCliChildOutcome): RawUtf8;
begin
  case Outcome of
    pcoSpawnRefused: Result := 'spawn_refused';
    pcoSpawnFailed:  Result := 'spawn_failed';
    pcoExited:       Result := 'exited';
    pcoSignaled:     Result := 'signaled';
    pcoForced:       Result := 'forced';
    pcoUnreaped:     Result := 'unreaped';
  else
    Result := 'unknown';
  end;
end;

function PWebCliExecRefusalText(Refusal: TPWebCliExecRefusal): RawUtf8;
begin
  case Refusal of
    perNone:        Result := 'ok';
    perEmptyPath:   Result := 'empty_path';
    perArgEncoding: Result := 'argument_encoding';
    perBatchFile:   Result := 'batch_file';
  else
    Result := 'refused';
  end;
end;

function PWebCliDefaultStopCheck(Opaque: Pointer): Boolean;
begin
  Result := PWebCliStopRequested;
end;

function LowerAscii(c: AnsiChar): AnsiChar; inline;
begin
  if c in ['A' .. 'Z'] then
    Result := AnsiChar(Ord(c) + 32)
  else
    Result := c;
end;

function PWebCliExecAcceptable(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray; out Refusal: TPWebCliExecRefusal): Boolean;
var
  i, dot, len: PtrInt;
  ext: RawUtf8;
begin
  Result := False;
  Refusal := perNone;
  if ExePath = '' then
  begin
    Refusal := perEmptyPath;
    exit;
  end;
  if (Pos(#0, ExePath) > 0) or
     not PWebStrictUtf8(ExePath) then
  begin
    Refusal := perArgEncoding;
    exit;
  end;
  for i := 0 to High(Args) do
    if (Pos(#0, Args[i]) > 0) or
       not PWebStrictUtf8(Args[i]) then
    begin
      Refusal := perArgEncoding;
      exit;
    end;
  // the final extension of the final component, compared case-insensitively
  // on EVERY platform: a file called x.CMD on Linux is not a batch file, but
  // refusing it costs nothing and the rule stays one rule
  len := Length(ExePath);
  dot := 0;
  for i := len downto 1 do
  begin
    if ExePath[i] in ['/', '\'] then
      break;
    if (ExePath[i] = '.') and
       (dot = 0) then
      dot := i;
  end;
  if dot > 0 then
  begin
    ext := Copy(ExePath, dot + 1, MaxInt);
    for i := 1 to Length(ext) do
      ext[i] := LowerAscii(ext[i]);
    if (ext = 'cmd') or
       (ext = 'bat') then
    begin
      Refusal := perBatchFile;
      exit;
    end;
  end;
  Result := True;
end;

function PWebCliPathUnderTree(const Path, Root: RawUtf8;
  CaseFold: Boolean): Boolean;
var
  i, rootLen: PtrInt;
  a, b: AnsiChar;
begin
  Result := False;
  rootLen := Length(Root);
  // a root given with a trailing separator is the same root
  while (rootLen > 0) and
        (Root[rootLen] in ['/', '\']) do
    Dec(rootLen);
  if (rootLen = 0) or
     (Length(Path) <= rootLen + 1) then
    exit;
  for i := 1 to rootLen do
  begin
    a := Path[i];
    b := Root[i];
    // both separators are one separator, so a display path compares with
    // a canonical one and a forward-slash spelling with a backslash one
    if a in ['/', '\'] then
      a := '/';
    if b in ['/', '\'] then
      b := '/';
    if CaseFold then
    begin
      a := LowerAscii(a);
      b := LowerAscii(b);
    end;
    if a <> b then
      exit;
  end;
  // the component boundary: '/app/x' is under '/app', '/appX/x' is not
  Result := Path[rootLen + 1] in ['/', '\'];
end;

{ ---------------------------------------------------------------------------
  the descendant drain
  --------------------------------------------------------------------------- }

function PWebCliDrainTree(Opaque: Pointer; Enumerate: TPWebCliDrainEnumerate;
  Stop, Kill: TPWebCliDrainAct; Sleep: TPWebCliDrainSleep;
  ExcludePid: PtrInt; GraceMs, PollMs: Cardinal; MaxPasses: Integer;
  const TreeRoot: RawUtf8; CaseFold: Boolean): TPWebCliDrainReport;
var
  report: TPWebCliDrainReport;
  members: TPWebCliTreeMembers;
  waited: Cardinal;
  live: PtrInt;
  forcedPasses: Integer;

  // one enumeration: every member other than the child itself, recorded
  // once by pid in Seen, and counted as live for this pass
  function Sweep: PtrInt;
  var
    i, j: PtrInt;
    found: Boolean;
  begin
    members := Enumerate(Opaque);
    Inc(report.Passes);
    Result := 0;
    for i := 0 to High(members) do
    begin
      if members[i].Pid = ExcludePid then
        continue;
      Inc(Result);
      found := False;
      for j := 0 to High(report.Seen) do
        if report.Seen[j].Pid = members[i].Pid then
        begin
          found := True;
          break;
        end;
      if found then
        continue;
      j := Length(report.Seen);
      SetLength(report.Seen, j + 1);
      report.Seen[j].Pid := members[i].Pid;
      report.Seen[j].ParentPid := members[i].ParentPid;
      report.Seen[j].Image := members[i].Image;
      report.Seen[j].UnderTree :=
        PWebCliPathUnderTree(members[i].Image, TreeRoot, CaseFold);
      report.Seen[j].Forced := False;
    end;
  end;

  // every member present NOW was (or is about to be) force-terminated
  procedure MarkForced;
  var
    i, j: PtrInt;
  begin
    for i := 0 to High(members) do
      for j := 0 to High(report.Seen) do
        if report.Seen[j].Pid = members[i].Pid then
          report.Seen[j].Forced := True;
  end;

begin
  report := Default(TPWebCliDrainReport);
  report.Graceful := True;
  if MaxPasses < 1 then
    MaxPasses := 1;
  if PollMs = 0 then
    PollMs := 1;
  live := Sweep;
  if live > 0 then
  begin
    // --- the graceful window, bounded by TIME: ask once, then only watch.
    // A browser tears down as a tree and its members usually go by
    // themselves once the application is gone; nothing is killed yet
    Stop(Opaque);
    waited := 0;
    while (live > 0) and
          (waited < GraceMs) do
    begin
      Sleep(Opaque, PollMs);
      Inc(waited, PollMs);
      live := Sweep;
    end;
    if live > 0 then
    begin
      // --- the forced window, bounded by PASSES: everything still present
      // is terminated as a TREE, then the sweep continues so a member that
      // appeared late is seen and the survivor count is measured rather
      // than assumed. MaxPasses counts from here, so the grace window can
      // never consume the passes the forced window needs (MEASURED: it
      // did, and a grandchild the kill had ended was reported surviving)
      report.Graceful := False;
      report.Forced := True;
      MarkForced;
      Kill(Opaque);
      forcedPasses := 0;
      while (live > 0) and
            (forcedPasses < MaxPasses) do
      begin
        Sleep(Opaque, PollMs);
        Inc(forcedPasses);
        live := Sweep;
        MarkForced;
      end;
    end;
  end;
  report.Remaining := live;
  Result := report;
end;

{ ---------------------------------------------------------------------------
  the execution
  --------------------------------------------------------------------------- }

type
  // per-stream state of one execution
  TStreamState = record
    /// supervise: the partial line not yet delivered
    Pending: RawUtf8;
    /// supervise: the current line exceeded the bound; drop until newline
    Discarding: Boolean;
    /// True once the platform reported the stream closed
    Closed: Boolean;
  end;

  TExecState = record
    Spec: TPWebCliExecSpec;
    Child: TPWebCliChild;
    Res: TPWebCliExecResult;
    Streams: array[TPWebCliChildStream] of TStreamState;
  end;
  PExecState = ^TExecState;

// keep the last Cap bytes of Text + Chunk
procedure RetainTail(var Text: RawUtf8; const Chunk: RawUtf8; Cap: PtrInt;
  var Truncated: Boolean);
begin
  Text := Text + Chunk;
  if Length(Text) > Cap then
  begin
    Truncated := True;
    Delete(Text, 1, Length(Text) - Cap);
  end;
end;

// capture up to Cap bytes, discard the rest - the CAP-10A rule
procedure CaptureCapped(var Text: RawUtf8; const Chunk: RawUtf8; Cap: PtrInt;
  var Truncated: Boolean);
var
  keep: PtrInt;
begin
  keep := Length(Chunk);
  if Length(Text) + keep > Cap then
  begin
    keep := Cap - Length(Text);
    Truncated := True;
  end;
  if keep > 0 then
    Text := Text + Copy(Chunk, 1, keep);
end;

procedure DeliverLine(var S: TExecState; Stream: TPWebCliChildStream;
  var Line: RawUtf8; Truncated: Boolean);
begin
  // one trailing CR is the Windows newline's other half, not content
  if (Line <> '') and
     (Line[Length(Line)] = #13) then
    SetLength(Line, Length(Line) - 1);
  if Truncated then
    Inc(S.Res.LinesTruncated);
  if Assigned(S.Spec.Sink) then
    S.Spec.Sink(S.Spec.Opaque, Stream, Line, Truncated);
  Line := '';
end;

// supervise: cut Chunk into lines, bound each, deliver complete ones
procedure ForwardChunk(var S: TExecState; Stream: TPWebCliChildStream;
  const Chunk: RawUtf8);
var
  st: ^TStreamState;
  i, start: PtrInt;
  piece: RawUtf8;
begin
  st := @S.Streams[Stream];
  start := 1;
  for i := 1 to Length(Chunk) do
    if Chunk[i] = #10 then
    begin
      if not st^.Discarding then
      begin
        piece := Copy(Chunk, start, i - start);
        st^.Pending := st^.Pending + piece;
        if Length(st^.Pending) > PWEB_CLI_RUN_LINE_MAX then
        begin
          SetLength(st^.Pending, PWEB_CLI_RUN_LINE_MAX);
          DeliverLine(S, Stream, st^.Pending, True);
        end
        else
          DeliverLine(S, Stream, st^.Pending, False);
      end
      else
      begin
        // the bounded head was already delivered; the rest of the line is
        // dropped up to and including this newline
        st^.Discarding := False;
        st^.Pending := '';
      end;
      start := i + 1;
    end;
  if start <= Length(Chunk) then
  begin
    if st^.Discarding then
      exit;
    piece := Copy(Chunk, start, MaxInt);
    st^.Pending := st^.Pending + piece;
    if Length(st^.Pending) > PWEB_CLI_RUN_LINE_MAX then
    begin
      // deliver the bounded head NOW rather than holding an unbounded
      // buffer while a child streams one endless line
      SetLength(st^.Pending, PWEB_CLI_RUN_LINE_MAX);
      DeliverLine(S, Stream, st^.Pending, True);
      st^.Discarding := True;
    end;
  end;
end;

// read everything available on one stream; True when bytes moved
function PumpStream(var S: TExecState; Stream: TPWebCliChildStream): Boolean;
var
  buf: array[0 .. 16383] of Byte;
  got: PtrInt;
  chunk: RawUtf8;
begin
  Result := False;
  if S.Streams[Stream].Closed then
    exit;
  repeat
    got := PWebCliChildRead(S.Child, Stream, @buf[0], SizeOf(buf));
    if got < 0 then
    begin
      S.Streams[Stream].Closed := True;
      exit;
    end;
    if got = 0 then
      exit;
    Result := True;
    SetString(chunk, PAnsiChar(@buf[0]), got);
    if S.Spec.Profile = pepProbe then
    begin
      if Stream = pcsStdOut then
        CaptureCapped(S.Res.Output, chunk, PWEB_CLI_PROBE_MAX_BYTES,
          S.Res.Truncated)
      else
        CaptureCapped(S.Res.ErrorText, chunk, PWEB_CLI_PROBE_MAX_BYTES,
          S.Res.Truncated);
    end
    else
    begin
      if Stream = pcsStdErr then
        RetainTail(S.Res.ErrorText, chunk, PWEB_CLI_RUN_DIAG_MAX,
          S.Res.Truncated);
      ForwardChunk(S, Stream, chunk);
    end;
  until False;
end;

function PumpBoth(var S: TExecState): Boolean;
begin
  Result := PumpStream(S, pcsStdOut);
  if PumpStream(S, pcsStdErr) then
    Result := True;
end;

// the real drain verbs, bound to the platform seam through the state
function RealEnumerate(Opaque: Pointer): TPWebCliTreeMembers;
begin
  Result := PWebCliChildMembers(PExecState(Opaque)^.Child);
end;

procedure RealStop(Opaque: Pointer);
begin
  // the child has exited; on POSIX this is SIGTERM to what is left of the
  // group, on Windows there is no window left to close and nothing is sent
  PWebCliChildStop(PExecState(Opaque)^.Child);
end;

procedure RealKill(Opaque: Pointer);
begin
  PWebCliChildKill(PExecState(Opaque)^.Child);
end;

procedure RealSleep(Opaque: Pointer; Ms: Cardinal);
begin
  // keep draining the pipes while waiting: a descendant that inherited the
  // child's stdout and fills it would otherwise block instead of exiting
  PumpBoth(PExecState(Opaque)^);
  PWebCliChildPoll(PExecState(Opaque)^.Child, Ms);
end;

function PWebCliExecute(const Spec: TPWebCliExecSpec): TPWebCliExecResult;
type
  TStage = (stRunning, stGraceful, stForced);
var
  S: TExecState;
  started, now64, stopAt, killAt, lastPost: QWord;
  stage: TStage;
  moved, exited, wantsStop: Boolean;
  stopCheck: TPWebCliStopCheck;
  stream: TPWebCliChildStream;
  refusal: TPWebCliExecRefusal;
  failure: TPWebCliSpawnFailure;
  osError: Integer;
begin
  S := Default(TExecState);
  S.Spec := Spec;
  S.Res.Outcome := pcoSpawnRefused;
  S.Res.StopToExitMs := -1;
  S.Res.KillToReapMs := -1;
  S.Res.Drain.Graceful := True;
  if not PWebCliExecAcceptable(Spec.ExePath, Spec.Args, refusal) then
  begin
    S.Res.Refusal := refusal;
    exit(S.Res);
  end;
  stopCheck := Spec.StopCheck;
  if not Assigned(stopCheck) then
    stopCheck := @PWebCliDefaultStopCheck;
  started := GetTickCount64;
  if not PWebCliChildSpawn(Spec.ExePath, Spec.Args, Spec.WorkDir,
       Spec.SeparateConsole, S.Child, failure, osError) then
  begin
    S.Res.Outcome := pcoSpawnFailed;
    S.Res.Failure := failure;
    S.Res.OsError := osError;
    S.Res.ElapsedMs := GetTickCount64 - started;
    exit(S.Res);
  end;
  S.Res.Pid := S.Child.Pid;
  if Assigned(Spec.Started) then
    Spec.Started(Spec.Opaque, S.Child.Pid);
  stage := stRunning;
  stopAt := 0;
  killAt := 0;
  lastPost := 0;
  exited := False;
  try
    repeat
      moved := PumpBoth(S);
      if PWebCliChildWait(S.Child) then
      begin
        exited := True;
        break;
      end;
      now64 := GetTickCount64;
      case stage of
        stRunning:
          begin
            wantsStop := (Spec.Profile = pepSupervise) and stopCheck(Spec.Opaque);
            if wantsStop then
              S.Res.StopRequested := True
            else if (Spec.TimeoutMs > 0) and
                    (now64 - started > Spec.TimeoutMs) then
            begin
              S.Res.TimedOut := True;
              wantsStop := True;
            end;
            if wantsStop then
              if Spec.Profile = pepProbe then
              begin
                // a probe has no window to close: the bound expiring means
                // the tool is broken, and it is terminated at once
                PWebCliChildKill(S.Child);
                stage := stForced;
                killAt := now64;
              end
              else
              begin
                Inc(S.Res.StopPosts, PWebCliChildStop(S.Child));
                stage := stGraceful;
                stopAt := now64;
                lastPost := now64;
              end;
          end;
        stGraceful:
          begin
            // a host still starting up has no window yet: the request is
            // re-posted until one appears or the grace interval expires
            if (S.Res.StopPosts = 0) and
               (now64 - lastPost >= PWEB_CLI_RUN_STOP_RETRY_MS) then
            begin
              Inc(S.Res.StopPosts, PWebCliChildStop(S.Child));
              lastPost := now64;
            end;
            if now64 - stopAt >= PWEB_CLI_RUN_GRACE_MS then
            begin
              PWebCliChildKill(S.Child);
              stage := stForced;
              killAt := now64;
            end;
          end;
        stForced:
          if now64 - killAt >= PWEB_CLI_RUN_KILL_MS then
            break; // unreaped: reported below, never waited on forever
      end;
      if not moved then
        PWebCliChildPoll(S.Child, 10);
    until False;
    // whatever the pipes still hold, then the partial lines
    PumpBoth(S);
    now64 := GetTickCount64;
    if Spec.Profile = pepSupervise then
      for stream := Low(stream) to High(stream) do
        if (S.Streams[stream].Pending <> '') and
           not S.Streams[stream].Discarding then
          DeliverLine(S, stream, S.Streams[stream].Pending, False);
    if not exited then
      S.Res.Outcome := pcoUnreaped
    else
    begin
      S.Res.ExitCode := S.Child.ExitCode;
      S.Res.Signal := S.Child.Signal;
      case stage of
        stForced:
          begin
            S.Res.Outcome := pcoForced;
            S.Res.KillToReapMs := now64 - killAt;
          end;
        stGraceful:
          begin
            S.Res.StopToExitMs := now64 - stopAt;
            if S.Child.Signal <> 0 then
              S.Res.Outcome := pcoSignaled
            else
              S.Res.Outcome := pcoExited;
          end;
      else
        if S.Child.Signal <> 0 then
          S.Res.Outcome := pcoSignaled
        else
          S.Res.Outcome := pcoExited;
      end;
    end;
    // the tree the child owned, drained by membership
    S.Res.Drain := PWebCliDrainTree(@S, @RealEnumerate, @RealStop, @RealKill,
      @RealSleep, S.Child.Pid, PWEB_CLI_RUN_GRACE_MS,
      PWEB_CLI_RUN_DRAIN_POLL_MS, PWEB_CLI_RUN_DRAIN_PASSES, Spec.TreeRoot,
      PWebCliHostOs = pcoWindows);
    PumpBoth(S);
  finally
    PWebCliChildRelease(S.Child);
    S.Res.ElapsedMs := GetTickCount64 - started;
  end;
  Result := S.Res;
end;

end.
