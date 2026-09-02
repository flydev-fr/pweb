{
  pweb.cli.probe - executable resolution and bounded, shell-free tool probes
  (CAP-10A, re-based on the CAP-10C0 engine).

  RESOLVES a tool on PATH deterministically and PROBES it through the ONE
  execution engine of the CLI, pweb.cli.process, in its `probe` profile.
  Nothing about how a child is launched, bounded, drained or killed lives
  here any more: CAP-10C0 moved that into pweb.cli.process and
  pweb.cli.platform so that `pweb doctor`, `pweb run` and the later `dev` and
  `build` commands share one implementation rather than three.

  ---------------------------------------------------------------------------
  THE CAP-10A SEMANTICS, UNCHANGED
  ---------------------------------------------------------------------------

  Every probe is (exact absolute executable path, argument array, timeout).
  There is still no command string anywhere in this unit, no descriptor value
  reaches it (the tool names are compile-time constants in pweb.cli.toolchain),
  stdin is /dev/null or NUL from the first instant, both streams are drained
  together, each is captured up to a byte ceiling and read-and-discarded past
  it, and a child that outstays the bound is terminated and reaped rather than
  waited on. The exit code is exact on every platform.

  What CAP-10C0 changed underneath: the Windows launch no longer goes through
  FPC's TProcess and its own quoting, but through CreateProcessW with a
  command line built by the msvcrt-exact rule and a Job Object that owns the
  whole tree; the POSIX launch is fork/execve into a process group of its
  own. A tool that spawns helpers and exits leaves nothing behind.

  ---------------------------------------------------------------------------
  WHAT IS NEVER EXECUTED
  ---------------------------------------------------------------------------

  A candidate that resolves INSIDE the canonical project root is reported and
  never run. Schema 1 has no toolchain model, so a `node` sitting in the
  project is an unexplained binary with a familiar name - and running it
  because of where the user happened to be standing is precisely the shape of
  attack the PATH rules elsewhere in this unit exist to avoid. The empty PATH
  entry, which POSIX defines as the working directory, is dropped for the
  same reason (pweb.cli.platform). A batch file is never executed either: the
  engine refuses `.cmd` / `.bat` before any spawn.

  The working directory handed to a probe is the tool's OWN directory: it is
  explicit, deterministic, and never the directory this CLI was started from.
}
unit pweb.cli.probe;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.process;

type
  /// what happened to one probe - ordinal 0 is a failure state
  TPWebCliProbeOutcome = (
    /// no runnable executable of that name exists on PATH
    ppoNotFound,
    /// the candidate resolves inside the project root: reported, NOT run
    ppoInsideProject,
    /// the process could not be created (or was refused before creation)
    ppoSpawnFailed,
    /// the bound expired; the child was terminated
    ppoTimedOut,
    /// the child died by a signal (POSIX) - distinct from an exit code
    ppoDied,
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
    ppoDied:          Result := 'probe_died';
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

function PWebCliRunProbe(const ExePath: RawUtf8;
  const Args: array of RawUtf8; TimeoutMs: Cardinal): TPWebCliProbe;
var
  spec: TPWebCliExecSpec;
  r: TPWebCliExecResult;
  i: PtrInt;
  dir, name: RawUtf8;
begin
  Result := Default(TPWebCliProbe);
  Result.Outcome := ppoSpawnFailed;
  Result.Path := ExePath;
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := ExePath;
  SetLength(spec.Args, Length(Args));
  for i := 0 to High(Args) do
    spec.Args[i] := Args[i];
  // explicit, deterministic, never this process's working directory
  if PWebCliSplitLast(ExePath, dir, name) then
    spec.WorkDir := dir
  else
    spec.WorkDir := ExePath;
  spec.Profile := pepProbe;
  spec.TimeoutMs := TimeoutMs;
  r := PWebCliExecute(spec);
  Result.Output := r.Output;
  Result.ErrorText := r.ErrorText;
  Result.Truncated := r.Truncated;
  case r.Outcome of
    pcoExited:
      begin
        Result.Outcome := ppoCompleted;
        Result.ExitCode := r.ExitCode;
      end;
    pcoSignaled:
      Result.Outcome := ppoDied;
    pcoForced,
    pcoUnreaped:
      // the ONLY way a probe is forced is its bound expiring
      Result.Outcome := ppoTimedOut;
  else
    Result.Outcome := ppoSpawnFailed;
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
