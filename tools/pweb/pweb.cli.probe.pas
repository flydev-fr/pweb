{
  pweb.cli.probe - executable resolution and bounded, shell-free tool probes
  (CAP-10A).

  THE ONLY PLACE IN THE CLI THAT STARTS A PROCESS. Everything about how a
  child is launched, bounded, drained and killed is written here once.

  ---------------------------------------------------------------------------
  NO SHELL, AND HOW THAT IS TRUE RATHER THAN CLAIMED
  ---------------------------------------------------------------------------

  Every probe is (exact absolute executable path, argument array, timeout).
  There is no command string anywhere in this unit: nothing is concatenated,
  quoted, escaped or interpolated, so there is no grammar for a descriptor
  value or an environment variable to escape from - and no descriptor value
  ever reaches this unit in the first place, because the tool names are
  compile-time constants in pweb.cli.toolchain.

  The launch goes through FPC's `process` unit, whose POSIX body calls
  fpexecv/fpexecve directly (packages/fcl-process/src/unix/process.inc) and
  whose Windows body calls CreateProcessW. `cmd.exe /c`, `/bin/sh -c`,
  system(), popen() and mORMot's RunRedirect/RunCommand (which uses popen on
  POSIX) are all absent by construction, and
  test/cap10a/check_cap10a_contracts.ps1 sweeps this tree for every one of
  those spellings.

  ---------------------------------------------------------------------------
  BOUNDED IN EVERY DIRECTION
  ---------------------------------------------------------------------------

    - a wall-clock timeout per probe, after which the child is TERMINATED
      and reaped rather than waited on forever;
    - stdin is closed immediately, so a tool that decides to ask a question
      gets EOF instead of blocking on a terminal the CLI never gave it;
    - stdout AND stderr are drained together, in one non-blocking loop.
      Draining only one of them is the classic deadlock: the child fills the
      other pipe's buffer and blocks, the parent waits for an exit that can
      never come. Both are read every pass;
    - each stream is CAPTURED up to a byte ceiling and then read-and-
      discarded past it. Discarding rather than stopping matters: a probe
      that stopped reading would recreate the same deadlock at the ceiling
      instead of at the buffer.

  ---------------------------------------------------------------------------
  WHAT IS NEVER EXECUTED
  ---------------------------------------------------------------------------

  A candidate that resolves INSIDE the canonical project root is reported and
  never run. Schema 1 has no toolchain model, so a `node` sitting in the
  project is an unexplained binary with a familiar name - and running it
  because of where the user happened to be standing is precisely the shape of
  attack the PATH rules elsewhere in this unit exist to avoid. The empty PATH
  entry, which POSIX defines as the working directory, is dropped for the
  same reason (pweb.cli.platform).
}
unit pweb.cli.probe;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  classes,
  pipes,
  process,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain;

type
  /// what happened to one probe - ordinal 0 is a failure state
  TPWebCliProbeOutcome = (
    /// no runnable executable of that name exists on PATH
    ppoNotFound,
    /// the candidate resolves inside the project root: reported, NOT run
    ppoInsideProject,
    /// the process could not be created
    ppoSpawnFailed,
    /// the bound expired; the child was terminated
    ppoTimedOut,
    /// the child ran to completion (whatever its exit code)
    ppoCompleted);

  /// everything one probe learned
  TPWebCliProbe = record
    Outcome: TPWebCliProbeOutcome;
    /// canonical absolute path of the executable that was selected
    Path: RawUtf8;
    /// how many FURTHER distinct executables of this name PATH carries
    // - a shadowing install is a real cause of "the wrong version" and is
    // reported rather than silently resolved away
    Duplicates: Integer;
    /// the child's exit code (meaningful only when Outcome = ppoCompleted)
    ExitCode: Integer;
    /// captured stdout, bounded
    Output: RawUtf8;
    /// captured stderr, bounded
    ErrorText: RawUtf8;
    /// True when either stream exceeded the ceiling and was discarded past it
    Truncated: Boolean;
  end;

/// stable text for an outcome
function PWebCliProbeOutcomeText(Outcome: TPWebCliProbeOutcome): RawUtf8;

/// resolve a tool name against PATH, deterministically
// - candidates are tried in PATH order and, on Windows, in PATHEXT order
// within each directory; the FIRST runnable match wins and every further
// distinct match is counted
// - a candidate that is a directory is never selected, whatever it is called
// - ProjectRoot may be '': the inside-the-project refusal is then inactive
function PWebCliResolveTool(const Tool, ProjectRoot: RawUtf8;
  out Path: RawUtf8; out Duplicates: Integer): TPWebCliProbeOutcome;

/// run ONE exact executable with an argument array, bounded
function PWebCliRunProbe(const ExePath: RawUtf8;
  const Args: array of RawUtf8; TimeoutMs: Cardinal): TPWebCliProbe;

/// resolve then run, in one step
function PWebCliProbeTool(const Tool, ProjectRoot: RawUtf8;
  const Args: array of RawUtf8; TimeoutMs: Cardinal): TPWebCliProbe;

implementation

function PWebCliProbeOutcomeText(Outcome: TPWebCliProbeOutcome): RawUtf8;
begin
  case Outcome of
    ppoNotFound:      Result := 'tool_not_found';
    ppoInsideProject: Result := 'tool_inside_project';
    ppoSpawnFailed:   Result := 'probe_spawn_failed';
    ppoTimedOut:      Result := 'probe_timed_out';
    ppoCompleted:     Result := 'probe_completed';
  else
    Result := 'probe_failed';
  end;
end;

// ASCII case-insensitive containment test used ONLY to refuse: erring
// toward refusal is correct here, and it keeps the comparison identical on
// a case-folding and a case-sensitive volume
function UnderRoot(const Path, Root: RawUtf8): Boolean;
var
  i: PtrInt;
  a, b: AnsiChar;
begin
  Result := False;
  if (Root = '') or
     (Length(Path) <= Length(Root)) then
    exit;
  for i := 1 to Length(Root) do
  begin
    a := Path[i];
    b := Root[i];
    if a in ['A' .. 'Z'] then
      Inc(a, 32);
    if b in ['A' .. 'Z'] then
      Inc(b, 32);
    if a <> b then
      exit;
  end;
  // the next byte must be a separator, so '/projects/appX' is not treated
  // as being inside '/projects/app'
  Result := (Path[Length(Root) + 1] = '/') or
            (Path[Length(Root) + 1] = '\');
end;

function PWebCliResolveTool(const Tool, ProjectRoot: RawUtf8;
  out Path: RawUtf8; out Duplicates: Integer): TPWebCliProbeOutcome;
var
  dirs, seen: TRawUtf8DynArray;
  d, i: PtrInt;
  canonicalDir, full: RawUtf8;
  isNew: Boolean;
begin
  Path := '';
  Duplicates := 0;
  seen := nil;
  Result := ppoNotFound;
  dirs := PWebCliPathDirs;
  for d := 0 to High(dirs) do
  begin
    // a PATH entry that is not a real directory contributes nothing, and a
    // link in it resolves here so the recorded path is the real one
    if not PWebCliCanonicalDir(dirs[d], canonicalDir) then
      continue;
    // the platform's OWN rule for what this tool is called here and whether
    // it would run: PATHEXT on Windows, the execute bit on POSIX
    if not PWebCliFindExecutable(canonicalDir, Tool, full) then
      continue;
    isNew := True;
    for i := 0 to High(seen) do
      if seen[i] = full then
      begin
        isNew := False;
        break;
      end;
    if not isNew then
      continue;
    SetLength(seen, Length(seen) + 1);
    seen[High(seen)] := full;
    if Path = '' then
    begin
      Path := full;
      if UnderRoot(full, ProjectRoot) then
      begin
        // reported with its path so a human can see WHAT shadowed the
        // tool, and never executed
        Result := ppoInsideProject;
        exit;
      end;
      Result := ppoCompleted; // provisional: resolution succeeded
    end
    else
      Inc(Duplicates);
  end;
  if Path = '' then
    Result := ppoNotFound;
end;

// read whatever is available from one pipe, capturing up to Cap bytes and
// DISCARDING the rest - a reader that stopped would deadlock the child at
// the ceiling instead of at the buffer
procedure DrainPipe(Stream: TInputPipeStream; var Dest: RawUtf8;
  Cap: PtrInt; var Truncated: Boolean; var Moved: Boolean);
var
  avail, got, keep: LongInt;
  buf: array[0 .. 8191] of Byte;
  chunk: RawUtf8;
begin
  if Stream = nil then
    exit;
  repeat
    avail := Stream.NumBytesAvailable;
    if avail <= 0 then
      exit;
    if avail > SizeOf(buf) then
      avail := SizeOf(buf);
    got := Stream.Read(buf, avail);
    if got <= 0 then
      exit;
    Moved := True;
    keep := got;
    if Length(Dest) + keep > Cap then
    begin
      keep := Cap - Length(Dest);
      Truncated := True;
    end;
    if keep > 0 then
    begin
      SetString(chunk, PAnsiChar(@buf[0]), keep);
      Dest := Dest + chunk;
    end;
  until False;
end;

function PWebCliRunProbe(const ExePath: RawUtf8;
  const Args: array of RawUtf8; TimeoutMs: Cardinal): TPWebCliProbe;
var
  p: TProcess;
  i: PtrInt;
  started, now64: QWord;
  moved: Boolean;
begin
  Result := Default(TPWebCliProbe);
  Result.Outcome := ppoSpawnFailed;
  Result.Path := ExePath;
  p := TProcess.Create(nil);
  try
    // the EXACT resolved path, never a name the platform would search for
    p.Executable := string(ExePath);
    for i := 0 to High(Args) do
      p.Parameters.Add(string(Args[i]));
    // poUsePipes and nothing else: no shell, no detached console, no
    // inherited terminal
    p.Options := [poUsePipes];
    p.ShowWindow := swoHIDE;
    try
      p.Execute;
    except
      exit; // ppoSpawnFailed, with no partial state to explain
    end;
    // EOF on stdin from the first instant: a tool that prompts gets an
    // answer it can act on instead of a terminal it will wait on forever
    p.CloseInput;
    started := GetTickCount64;
    repeat
      moved := False;
      DrainPipe(p.Output, Result.Output, PWEB_CLI_PROBE_MAX_BYTES,
        Result.Truncated, moved);
      DrainPipe(p.Stderr, Result.ErrorText, PWEB_CLI_PROBE_MAX_BYTES,
        Result.Truncated, moved);
      if not p.Running then
        break;
      now64 := GetTickCount64;
      if (now64 >= started) and
         (now64 - started > TimeoutMs) then
      begin
        Result.Outcome := ppoTimedOut;
        try
          p.Terminate(255);
        except
          // a child that cannot be terminated is still a timeout, and the
          // CLI is about to exit anyway - never a raise out of a probe
        end;
        try
          p.WaitOnExit;
        except
        end;
        exit;
      end;
      if not moved then
        Sleep(5);
    until False;
    // the child has exited: take what is still sitting in the pipes
    DrainPipe(p.Output, Result.Output, PWEB_CLI_PROBE_MAX_BYTES,
      Result.Truncated, moved);
    DrainPipe(p.Stderr, Result.ErrorText, PWEB_CLI_PROBE_MAX_BYTES,
      Result.Truncated, moved);
    // ExitCode, NEVER ExitStatus. On POSIX ExitStatus is the RAW wait(2)
    // status - exit 3 reads as 768 - and ExitCode is the one that applies
    // wexitstatus; on Windows the two are the same property. MEASURED: the
    // ExitStatus form passed on Windows and reported 768 for exit 3 on
    // Linux, which is precisely the shape of a cross-platform defect that a
    // single-platform test would have shipped.
    Result.ExitCode := p.ExitCode;
    Result.Outcome := ppoCompleted;
  finally
    p.Free;
  end;
end;

function PWebCliProbeTool(const Tool, ProjectRoot: RawUtf8;
  const Args: array of RawUtf8; TimeoutMs: Cardinal): TPWebCliProbe;
var
  path: RawUtf8;
  dup: Integer;
  outcome: TPWebCliProbeOutcome;
begin
  Result := Default(TPWebCliProbe);
  outcome := PWebCliResolveTool(Tool, ProjectRoot, path, dup);
  if outcome <> ppoCompleted then
  begin
    Result.Outcome := outcome;
    Result.Path := path;
    Result.Duplicates := dup;
    exit;
  end;
  Result := PWebCliRunProbe(path, Args, TimeoutMs);
  Result.Duplicates := dup;
end;

end.
