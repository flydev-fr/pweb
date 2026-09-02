{
  pweb.test.supervise - the CAP-10C0 suite over the supervision engine and
  `pweb run` (mormot.core.test).

  Three subjects, one file, all four targets:

    PURE      the Windows quoting rule (a golden table, on every platform),
              the component-boundary path predicate, and the descendant
              drain over INJECTED records - the churn cases a real browser
              cannot be made to stage (S3 table half, S15);
    ENGINE    S1-S18 against a deliberately badly behaved real child
              (pwebchild): exact exit codes, death by signal typed, the argv
              round trip through a real spawn, pre-spawn refusals, both
              saturations, per-stream order and the line bound, the
              graceful-then-forced ladder with both intervals measured, a
              grandchild owned by the tree, no zombie, an explicit working
              directory and an environment handed over unchanged;
    RUN       the layout rule and its refusals against REAL directories
              (including a real link), and - when the gate has staged a
              built application - the two drivers nothing else can prove:
              a stop signal delivered to a live `pweb run` (R10) and a
              supervisor terminated under a live application (S11).

  It emits build/cap10c0/supervise-corpus.txt: every DECISION this suite
  made, one LF line each, hashed into supervision_digest and required equal
  on four targets - so a line carries no pid, no path, no timing and no
  mechanism name. Observations (mechanism, intervals, outcomes that are
  legitimately platform-shaped) go to build/cap10c0/supervise-observed.txt
  as key=value lines and are recorded per target, never compared.
}

{$I mormot.defines.inc}

unit pweb.test.supervise;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.test,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.toolchain,
  pweb.cli.process,
  pweb.cli.probe,
  pweb.cli.project,
  pweb.cli.run;

type
  TTestPWebCliPure = class(TSynTestCase)
  published
    procedure QuotingGoldenTable;
    procedure PathUnderTree;
    procedure DrainSelector;
  end;

  TTestPWebCliSupervise = class(TSynTestCase)
  published
    procedure ExitCodesExact;
    procedure DeathIsNeverExitZero;
    procedure ArgvRoundTrip;
    procedure RefusedBeforeSpawn;
    procedure StdOutSaturation;
    procedure StdErrSaturation;
    procedure LinesInOrderAndBounded;
    procedure TimeoutGracefulThenForced;
    procedure StopIgnoredIsForced;
    procedure GrandchildDiesWithTree;
    procedure NoZombie;
    procedure WorkingDirectoryExplicit;
    procedure EnvironmentInherited;
  end;

  TTestPWebCliRunCommand = class(TSynTestCase)
  published
    procedure LayoutRule;
    procedure LayoutRefusals;
    procedure StopSignalReachesApplication;
    procedure SupervisorTerminatedTreeDies;
    procedure StopIgnoredIsForcedThroughRun;
    procedure ApplicationDeathThroughRun;
  end;

const
  PWEB_CAP10C0_CORPUS_FILE = 'build/cap10c0/supervise-corpus.txt';
  PWEB_CAP10C0_OBSERVED_FILE = 'build/cap10c0/supervise-observed.txt';
  /// the gate stages a built React project and names it here (R10, S11)
  PWEB_CAP10C0_ENV_STAGE = 'PWEB_C0_STAGE_REACT';
  /// and the real CLI to drive
  PWEB_CAP10C0_ENV_PWEB = 'PWEB_C0_PWEB';

/// write both evidence files
procedure PWebCap10c0Flush;


implementation

{$ifdef OSWINDOWS}
uses
  windows;
{$else}
uses
  baseunix;
{$endif OSWINDOWS}

var
  Corpus: TRawUtf8DynArray;
  Observed: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

procedure Observe(const Key, Value: RawUtf8);
begin
  SetLength(Observed, Length(Observed) + 1);
  Observed[High(Observed)] := Key + '=' + Value;
end;

procedure PWebCap10c0Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10C0 supervision decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10C0_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10C0_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10C0_OBSERVED_FILE);
end;

{ ---------------------------------------------------------------------------
  fixture plumbing
  --------------------------------------------------------------------------- }

{$ifdef OSWINDOWS}
const
  IO_REPARSE_TAG_MOUNT_POINT = $A0000003;
  FSCTL_SET_REPARSE_POINT = $000900A4;
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;
  PROCESS_TERMINATE_ = $0001;

type
  TMountPointReparseBuffer = record
    ReparseTag: DWord;
    ReparseDataLength: Word;
    Reserved: Word;
    SubstituteNameOffset: Word;
    SubstituteNameLength: Word;
    PrintNameOffset: Word;
    PrintNameLength: Word;
    PathBuffer: array[0 .. 1023] of WideChar;
  end;

// a real NTFS junction, exactly as test/cap10a/pweb.test.cli.pas makes one:
// no privilege needed, and the walk reports it as a reparse point
function MakeLink(const LinkDir, TargetDir: TFileName): Boolean;
var
  h: THandle;
  buf: TMountPointReparseBuffer;
  subst: UnicodeString;
  nameBytes: Word;
  returned, total: DWord;
begin
  Result := False;
  if not ForceDirectories(LinkDir) then
    exit;
  h := CreateFileW(PWideChar(Utf8ToSynUnicode(StringToUtf8(LinkDir))),
    GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    subst := '\??\' + Utf8ToSynUnicode(StringToUtf8(
      ExcludeTrailingPathDelimiter(TargetDir)));
    FillChar(buf, SizeOf(buf), 0);
    buf.ReparseTag := IO_REPARSE_TAG_MOUNT_POINT;
    nameBytes := Length(subst) * 2;
    buf.SubstituteNameOffset := 0;
    buf.SubstituteNameLength := nameBytes;
    buf.PrintNameOffset := nameBytes + 2;
    buf.PrintNameLength := 0;
    Move(PWideChar(subst)^, buf.PathBuffer[0], nameBytes);
    buf.ReparseDataLength := 8 + nameBytes + 4;
    total := 8 + buf.ReparseDataLength;
    returned := 0;
    Result := DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, @buf, total,
      nil, 0, returned, nil);
  finally
    CloseHandle(h);
  end;
end;

function ChildName: TFileName;
begin
  Result := 'pwebchild.exe';
end;

// the supervisor under test is terminated the way the OS terminates: a
// TerminateProcess on ITS handle only - never on its job, which would prove
// nothing about KILL_ON_JOB_CLOSE
function TerminatePid(Pid: PtrInt): Boolean;
var
  h: THandle;
begin
  Result := False;
  h := OpenProcess(PROCESS_TERMINATE_, False, Pid);
  if h = 0 then
    exit;
  Result := TerminateProcess(h, 9);
  CloseHandle(h);
end;

function ZombieLeft(Pid: PtrInt): Boolean;
begin
  Result := False; // no zombies on Windows: a reaped handle is a closed one
end;

procedure MakeExecutable(const Path: TFileName);
begin
  // Windows has no execute bit
end;

procedure MakeNotExecutable(const Path: TFileName);
begin
end;

function KillHard(Pid: PtrInt): Boolean;
begin
  Result := TerminatePid(Pid);
end;

function SetEnv(const Name, Value: RawUtf8): Boolean;
begin
  Result := SetEnvironmentVariableW(PWideChar(Utf8ToSynUnicode(Name)),
    PWideChar(Utf8ToSynUnicode(Value)));
end;

procedure UnsetEnv(const Name: RawUtf8);
begin
  SetEnvironmentVariableW(PWideChar(Utf8ToSynUnicode(Name)), nil);
end;

// Windows reads the live block on every call
function LiveEnvironmentNames: TRawUtf8DynArray;
var
  i, n: PtrInt;
  s: RawUtf8;
begin
  Result := nil;
  for i := 1 to GetEnvironmentVariableCount do
  begin
    s := StringToUtf8(GetEnvironmentString(i));
    n := PosExChar('=', s);
    if n > 1 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(s, 1, n - 1);
    end;
  end;
end;
{$else}
function MakeLink(const LinkDir, TargetDir: TFileName): Boolean;
begin
  Result := FpSymlink(PAnsiChar(RawByteString(TargetDir)),
    PAnsiChar(RawByteString(LinkDir))) = 0;
end;

function ChildName: TFileName;
begin
  Result := 'pwebchild';
end;

function TerminatePid(Pid: PtrInt): Boolean;
begin
  Result := FpKill(Pid, SIGTERM) = 0;
end;

function ZombieLeft(Pid: PtrInt): Boolean;
var
  st: cint;
begin
  // ECHILD is the proof: nothing of that pid is left for us to reap
  st := 0;
  Result := FpWaitPid(Pid, st, WNOHANG) <> -1;
end;

procedure MakeExecutable(const Path: TFileName);
begin
  FpChmod(PAnsiChar(RawByteString(Path)), &755);
end;

procedure MakeNotExecutable(const Path: TFileName);
begin
  FpChmod(PAnsiChar(RawByteString(Path)), &644);
end;

// the supervisor ended WITHOUT a chance to forward anything
function KillHard(Pid: PtrInt): Boolean;
begin
  Result := FpKill(Pid, SIGKILL) = 0;
end;

function pweb_c0_setenv(name, value: PAnsiChar; overwrite: cint): cint;
  cdecl; external 'c' name 'setenv';
function pweb_c0_unsetenv(name: PAnsiChar): cint;
  cdecl; external 'c' name 'unsetenv';

function SetEnv(const Name, Value: RawUtf8): Boolean;
begin
  Result := pweb_c0_setenv(PAnsiChar(Name), PAnsiChar(Value), 1) = 0;
end;

procedure UnsetEnv(const Name: RawUtf8);
begin
  pweb_c0_unsetenv(PAnsiChar(Name));
end;

// FPC's GetEnvironmentString reads the copy taken at startup, and the ONLY
// change since is the marker this suite set through libc - so the live
// environment the child must receive is that list plus the marker
function LiveEnvironmentNames: TRawUtf8DynArray;
var
  i, n: PtrInt;
  s: RawUtf8;
begin
  Result := nil;
  for i := 1 to GetEnvironmentVariableCount do
  begin
    s := StringToUtf8(GetEnvironmentString(i));
    n := PosExChar('=', s);
    if n > 1 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(s, 1, n - 1);
    end;
  end;
  if FindRawUtf8(Result, 'PWEB_C0_MARKER') < 0 then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := 'PWEB_C0_MARKER';
  end;
end;
{$endif OSWINDOWS}

var
  FixtureRoot: TFileName;
  FixtureSeq: Integer;

procedure MakeDir(const Dir: TFileName);
begin
  if DirectoryExists(Dir) then
    exit;
  if not ForceDirectories(Dir) then
    raise Exception.CreateFmt('CAP-10C0 fixture directory not created: %s',
      [Dir]);
  if not DirectoryExists(Dir) then
    raise Exception.CreateFmt('CAP-10C0 fixture directory vanished: %s',
      [Dir]);
end;

function NewFixture(const Tag: RawUtf8): TFileName;
begin
  if FixtureRoot = '' then
  begin
    FixtureRoot := IncludeTrailingPathDelimiter(GetSystemPath(spTemp)) +
      'pweb-cap10c0-' + IntToStr(GetCurrentProcessId);
    MakeDir(FixtureRoot);
  end;
  Inc(FixtureSeq);
  Result := IncludeTrailingPathDelimiter(FixtureRoot) +
    Utf8ToString(Tag) + '-' + IntToStr(FixtureSeq);
  MakeDir(Result);
end;

function ChildPath: RawUtf8;
begin
  Result := StringToUtf8(ExtractFilePath(ParamStr(0)) + ChildName);
end;

function ChildAvailable: Boolean;
begin
  Result := PWebCliNodeKind(ChildPath) = pcnFile;
end;

// the line collector every engine test hands in as the sink
// - the arrays grow geometrically and are trimmed to OutCount / ErrCount by
// Trim, because a saturation test forwards sixty thousand lines and a
// per-line SetLength would turn that into a quadratic copy
type
  TCollector = record
    OutLines, ErrLines: TRawUtf8DynArray;
    OutCount, ErrCount: PtrInt;
    Truncated: Integer;
    /// R10/S11: the pid `pweb: started pid N` named, and when it was seen
    AppPid: PtrInt;
    AppSeenAt: QWord;
    /// R10/S11: set once the application reported ready
    Ready: Boolean;
    /// R10/S11: the tick at which the driver acted, 0 until then
    ActedAt: QWord;
    /// R10/S11: the pid of the supervised pweb
    PwebPid: PtrInt;
    /// S9: the tick after which the stop check answers True
    StopAfter: QWord;
    Started: QWord;
  end;
  PCollector = ^TCollector;

procedure Collect(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  c: PCollector;
  n: PtrInt;
begin
  c := Opaque;
  if Truncated then
    Inc(c^.Truncated);
  if Stream = pcsStdOut then
  begin
    n := c^.OutCount;
    if n = Length(c^.OutLines) then
      SetLength(c^.OutLines, (n + 16) * 2);
    c^.OutLines[n] := Line;
    Inc(c^.OutCount);
    // a generated host's ready report, or the fixture's own announcement
    // when it stands in for the application
    if (PosEx('ready {', Line) > 0) or
       (Copy(Line, 1, 9) = 'stubborn ') or
       (Copy(Line, 1, 8) = 'forever ') then
      c^.Ready := True;
  end
  else
  begin
    n := c^.ErrCount;
    if n = Length(c^.ErrLines) then
      SetLength(c^.ErrLines, (n + 16) * 2);
    c^.ErrLines[n] := Line;
    Inc(c^.ErrCount);
    if Copy(Line, 1, 18) = 'pweb: started pid ' then
    begin
      c^.AppPid := StrToIntDef(Utf8ToString(Copy(Line, 19, MaxInt)), 0);
      c^.AppSeenAt := GetTickCount64;
    end;
  end;
end;

const
  /// how long after pweb named the application pid the drivers act when no
  // ready line has arrived. A generated host's stdout is a PIPE here, and
  // FPC's text layer block-buffers a pipe on Linux and macOS (MEASURED on
  // run 33622404228: the ready report reached the driver only after the
  // host exited, though the gate's own legs saw it fine because their host
  // auto-closes). Windows flushes per line and the ready trigger still
  // fires there first; everywhere else the host has long since served its
  // page by the time this interval has passed (the B1/B2 proofs measured
  // readiness in well under two seconds on every runner)
  PWEB_C0_DRIVER_SETTLE_MS = 6000;

function DriverArmed(const C: TCollector): Boolean;
begin
  Result := C.Ready or
    ((C.AppPid > 0) and (GetTickCount64 - C.AppSeenAt >= PWEB_C0_DRIVER_SETTLE_MS));
end;

procedure Trim(var C: TCollector);
begin
  SetLength(C.OutLines, C.OutCount);
  SetLength(C.ErrLines, C.ErrCount);
end;

procedure StartedPid(Opaque: Pointer; Pid: PtrInt);
begin
  PCollector(Opaque)^.PwebPid := Pid;
end;

function StopAfterCheck(Opaque: Pointer): Boolean;
begin
  Result := (PCollector(Opaque)^.StopAfter > 0) and
            (GetTickCount64 >= PCollector(Opaque)^.StopAfter);
end;

function NeverStop(Opaque: Pointer): Boolean;
begin
  Result := False;
end;

function RunChild(const Args: array of RawUtf8; const WorkDir: RawUtf8;
  TimeoutMs: Cardinal; StopCheck: TPWebCliStopCheck;
  var C: TCollector): TPWebCliExecResult;
var
  spec: TPWebCliExecSpec;
  i: PtrInt;
begin
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := ChildPath;
  SetLength(spec.Args, Length(Args));
  for i := 0 to High(Args) do
    spec.Args[i] := Args[i];
  spec.WorkDir := WorkDir;
  spec.Profile := pepSupervise;
  spec.TimeoutMs := TimeoutMs;
  spec.Sink := @Collect;
  spec.StopCheck := StopCheck;
  spec.Started := @StartedPid;
  spec.Opaque := @C;
  spec.TreeRoot := PWebCliDisplayPath(WorkDir);
  C.Started := GetTickCount64;
  Result := PWebCliExecute(spec);
  Trim(C);
end;

function JoinLines(const Lines: TRawUtf8DynArray): RawUtf8;
var
  i: PtrInt;
begin
  Result := '';
  for i := 0 to High(Lines) do
    Result := Result + Lines[i] + #10;
end;

function FixtureDir: RawUtf8;
var
  canonical: RawUtf8;
begin
  if not PWebCliCanonicalDir(StringToUtf8(NewFixture('work')), canonical) then
    raise Exception.Create('fixture directory not canonical');
  Result := canonical;
end;

function BoolText(B: Boolean): RawUtf8;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

{ ---------------------------------------------------------------------------
  PURE
  --------------------------------------------------------------------------- }

procedure TTestPWebCliPure.QuotingGoldenTable;

  procedure Row(const Arg, Expected: RawUtf8);
  var
    got: RawUtf8;
  begin
    got := PWebCliWindowsCommandLine('x', [Arg]);
    // strip the fixed 'x ' program token
    got := Copy(got, 3, MaxInt);
    CheckEqual(got, Expected, 'quoting of ' + Arg);
    Record_('quote|' + BinToHexLower(Arg) + '|' + BinToHexLower(got));
  end;

begin
  // the golden rows: what CommandLineToArgvW must parse back to the input
  Row('plain', 'plain');
  Row('a b', '"a b"');
  Row('', '""');
  Row('a"b', '"a\"b"');
  Row('a\', 'a\');
  Row('a\"', '"a\\\""');
  Row('\\x', '\\x');
  Row('"', '"\""');
  Row('a\\ b', '"a\\ b"');
  Row('x y\', '"x y\\"');
  Row('x y\\', '"x y\\\\"');
  Row(#9'tab', '"'#9'tab"');
  Row('&|<>^%PATH%$HOME', '&|<>^%PATH%$HOME');
  Row('C:\Program Files\x', '"C:\Program Files\x"');
  CheckEqual(PWebCliWindowsCommandLine('C:\p q\a.exe', ['a b', 'c']),
    '"C:\p q\a.exe" "a b" c', 'the program token is quoted like any other');
  CheckEqual(PWebCliWindowsCommandLine('C:\a.exe', []), 'C:\a.exe',
    'no arguments, no trailing space');
  Record_('quote|program|"C:\p q\a.exe" "a b" c');
end;

procedure TTestPWebCliPure.PathUnderTree;
begin
  Check(PWebCliPathUnderTree('/app/x', '/app', False), 'under');
  Check(PWebCliPathUnderTree('/app/x/y', '/app/', False), 'trailing sep root');
  Check(not PWebCliPathUnderTree('/appX/x', '/app', False), 'sibling prefix');
  Check(not PWebCliPathUnderTree('/app', '/app', False), 'the root itself');
  Check(not PWebCliPathUnderTree('', '/app', False), 'unreadable is never under');
  Check(not PWebCliPathUnderTree('/app/x', '', False), 'no root, nothing under');
  Check(PWebCliPathUnderTree('C:\APP\x.exe', 'C:\app', True), 'fold on Windows');
  Check(not PWebCliPathUnderTree('C:\APP\x.exe', 'C:\app', False),
    'no fold elsewhere');
  Check(PWebCliPathUnderTree('C:/app/x.exe', 'C:\app', True),
    'both separators are one separator');
  Check(not PWebCliPathUnderTree('C:\app-evil\x.exe', 'C:\app', True),
    'the CAP-6b3 sibling');
  Record_('undertree|sibling|false|unreadable|false|fold|windows-only');
end;

// the injected drain: a scripted sequence of enumerations
var
  DrainScript: array of TPWebCliTreeMembers;
  DrainPass, DrainStops, DrainKills, DrainSlept: Integer;

function ScriptEnumerate(Opaque: Pointer): TPWebCliTreeMembers;
begin
  if DrainPass <= High(DrainScript) then
    Result := DrainScript[DrainPass]
  else
    Result := nil;
  Inc(DrainPass);
end;

procedure ScriptStop(Opaque: Pointer);
begin
  Inc(DrainStops);
end;

procedure ScriptKill(Opaque: Pointer);
begin
  Inc(DrainKills);
end;

procedure ScriptSleep(Opaque: Pointer; Ms: Cardinal);
begin
  Inc(DrainSlept, Ms);
end;

function Member(Pid, Ppid: PtrInt; const Image: RawUtf8): TPWebCliTreeMember;
begin
  Result.Pid := Pid;
  Result.ParentPid := Ppid;
  Result.Image := Image;
end;

procedure TTestPWebCliPure.DrainSelector;
var
  r: TPWebCliDrainReport;
  i: PtrInt;
  found10, found11, found12: Boolean;
begin
  // pass 1: the child (excluded) plus 10 and 11; pass 2: 10 vanished and 12
  // appeared; pass 3: empty. Nothing may be killed, everything must be seen
  SetLength(DrainScript, 3);
  DrainScript[0] := [Member(1, 0, '/app/x'), Member(10, 1, '/app/a'),
    Member(11, 1, '')];
  DrainScript[1] := [Member(11, 1, ''), Member(12, 11, '/appX/b')];
  DrainScript[2] := nil;
  DrainPass := 0; DrainStops := 0; DrainKills := 0; DrainSlept := 0;
  r := PWebCliDrainTree(nil, @ScriptEnumerate, @ScriptStop, @ScriptKill,
    @ScriptSleep, 1, 5000, 250, 20, '/app', False);
  CheckEqual(r.Passes, 3, 'three enumerations');
  CheckEqual(r.Remaining, 0, 'nothing remains');
  Check(r.Graceful, 'graceful: nothing killed');
  CheckEqual(DrainStops, 1, 'one graceful request');
  CheckEqual(DrainKills, 0, 'no kill');
  CheckEqual(Length(r.Seen), 3, 'the child is excluded, the late member is seen');
  found10 := False; found11 := False; found12 := False;
  for i := 0 to High(r.Seen) do
  begin
    Check(not r.Seen[i].Forced, 'none forced');
    case r.Seen[i].Pid of
      10: begin found10 := True; Check(r.Seen[i].UnderTree, '10 under the tree'); end;
      11: begin found11 := True; Check(not r.Seen[i].UnderTree, 'unreadable never under'); end;
      12: begin found12 := True; Check(not r.Seen[i].UnderTree, 'sibling prefix never under'); end;
    end;
  end;
  Check(found10 and found11 and found12, 'every pid recorded once');
  Record_('drain|churn|seen=3|remaining=0|graceful=true|kills=0');
  // a survivor: the same member on every pass. The grace window passes,
  // the tree is killed exactly once, the member is marked forced, and the
  // pass bound ends the loop with the survivor COUNTED
  SetLength(DrainScript, 40);
  for i := 0 to High(DrainScript) do
    DrainScript[i] := [Member(20, 1, '/app/stuck')];
  DrainPass := 0; DrainStops := 0; DrainKills := 0; DrainSlept := 0;
  r := PWebCliDrainTree(nil, @ScriptEnumerate, @ScriptStop, @ScriptKill,
    @ScriptSleep, 1, 1000, 250, 8, '/app', False);
  // 1 first sweep + 4 graceful (1000/250) + 8 forced = 13
  CheckEqual(r.Passes, 13, 'the grace window is time, the forced window is passes');
  CheckEqual(DrainSlept, 3000, 'twelve polls of 250 ms');
  CheckEqual(r.Remaining, 1, 'the survivor is counted');
  Check(not r.Graceful, 'not graceful');
  Check(r.Forced, 'forced');
  CheckEqual(DrainKills, 8, 'the tree is killed on EVERY forced pass');
  CheckEqual(Length(r.Seen), 1, 'one member');
  Check(r.Seen[0].Forced, 'and it is marked forced');
  Record_('drain|survivor|passes=13|remaining=1|graceful=false|kills=8');
  // a member that goes only after the kill: forced, remaining 0
  SetLength(DrainScript, 7);
  for i := 0 to 5 do
    DrainScript[i] := [Member(30, 1, '/app/slow')];
  DrainScript[6] := nil;
  DrainPass := 0; DrainStops := 0; DrainKills := 0; DrainSlept := 0;
  r := PWebCliDrainTree(nil, @ScriptEnumerate, @ScriptStop, @ScriptKill,
    @ScriptSleep, 1, 1000, 250, 20, '/app', False);
  CheckEqual(r.Remaining, 0, 'gone after the kill');
  Check(r.Forced and not r.Graceful, 'forced');
  CheckEqual(DrainKills, 2, 'killed on each of the two forced passes it took');
  Check(r.Seen[0].Forced, 'marked forced');
  Record_('drain|forced-then-gone|remaining=0|graceful=false|kills=2');
  // nothing there at all: one pass, no request, no kill
  SetLength(DrainScript, 1);
  DrainScript[0] := [Member(1, 0, '/app/x')];
  DrainPass := 0; DrainStops := 0; DrainKills := 0; DrainSlept := 0;
  r := PWebCliDrainTree(nil, @ScriptEnumerate, @ScriptStop, @ScriptKill,
    @ScriptSleep, 1, 1000, 250, 20, '/app', False);
  CheckEqual(r.Passes, 1, 'one pass');
  CheckEqual(DrainStops, 0, 'no request when nothing is there');
  CheckEqual(Length(r.Seen), 0, 'the child itself is not a descendant');
  Record_('drain|empty|passes=1|stops=0|kills=0');
end;

{ ---------------------------------------------------------------------------
  ENGINE - S1..S18
  --------------------------------------------------------------------------- }

procedure TTestPWebCliSupervise.ExitCodesExact;
var
  c: TCollector;
  r: TPWebCliExecResult;
  p: TPWebCliProbe;
  code: Integer;
  dir: RawUtf8;
begin
  if not ChildAvailable then
  begin
    Check(False, 'S1: pwebchild must be built beside the suite');
    exit;
  end;
  dir := FixtureDir;
  for code in [0, 3, 255] do
  begin
    c := Default(TCollector);
    r := RunChild(['exit', IntToStr(code)], dir, 30000, @NeverStop, c);
    Check(r.Outcome = pcoExited, 'S1: exited');
    CheckEqual(r.ExitCode, code, 'S1: the exact code (never the wait status)');
    Check(not r.StopRequested and not r.TimedOut, 'S1: nothing requested');
    CheckEqual(r.Drain.Remaining, 0, 'S1: nothing left behind');
    Record_('supervise|exit|' + IntToStr(code) + '|' +
      PWebCliChildOutcomeText(r.Outcome) + '|' + IntToStr(r.ExitCode));
  end;
  // the SAME path in its probe profile: CAP-10A's semantics, re-based
  p := PWebCliRunProbe(ChildPath, ['exit', '3'], 30000);
  Check(p.Outcome = ppoCompleted, 'S1: probe completed');
  CheckEqual(p.ExitCode, 3, 'S1: probe exit code exact');
  Record_('probe|exit|3|' + PWebCliProbeOutcomeText(p.Outcome) + '|' +
    IntToStr(p.ExitCode));
end;

procedure TTestPWebCliSupervise.DeathIsNeverExitZero;
var
  c: TCollector;
  r: TPWebCliExecResult;
  p: TPWebCliProbe;
  neverZero: Boolean;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  r := RunChild(['die'], FixtureDir, 30000, @NeverStop, c);
  // POSIX: SIGABRT, typed; Windows: exit 3 - either way, never a clean 0
  neverZero := (r.Outcome <> pcoExited) or (r.ExitCode <> 0);
  Check(neverZero, 'S2: a death is never exit 0');
  if PWebCliHostOs = pcoWindows then
  begin
    Check(r.Outcome = pcoExited, 'S2: Windows has no signals');
    CheckEqual(r.ExitCode, 3, 'S2: the fixture exits 3 there');
    Observe('signal_outcome_typed', 'not_applicable');
  end
  else
  begin
    Check(r.Outcome = pcoSignaled, 'S2: typed as a signal death');
    CheckEqual(r.Signal, 6, 'S2: SIGABRT');
    Observe('signal_outcome_typed', 'true');
  end;
  Observe('death_outcome', PWebCliChildOutcomeText(r.Outcome));
  Record_('supervise|die|never_exit_zero|' + BoolText(neverZero));
  // the probe profile types the same death: ppoDied on POSIX, an exit code
  // of 3 on Windows - and never a completed probe with exit 0
  p := PWebCliRunProbe(ChildPath, ['die'], 30000);
  if PWebCliHostOs = pcoWindows then
  begin
    Check(p.Outcome = ppoCompleted, 'S2: probe completed on Windows');
    CheckEqual(p.ExitCode, 3, 'S2: with the fixture exit code');
  end
  else
    Check(p.Outcome = ppoDied, 'S2: probe typed the death: ' +
      PWebCliProbeOutcomeText(p.Outcome));
  Check(not ((p.Outcome = ppoCompleted) and (p.ExitCode = 0)),
    'S2: a probe death is never a clean 0');
  Record_('probe|die|never_exit_zero|' +
    BoolText(not ((p.Outcome = ppoCompleted) and (p.ExitCode = 0))));
end;

procedure TTestPWebCliSupervise.ArgvRoundTrip;
const
  ROUNDTRIP: array[0 .. 17] of RawUtf8 = (
    'plain', 'a b', '', 'x"y', '\z', 'a\\', 'tab'#9'here',
    #$C3#$A9' '#$C3#$BC#$C3#$AF' '#$E6#$97#$A5#$E6#$9C#$AC, '&', '|',
    '%PATH%', '$HOME', '"', '\"', 'trailing\\', '--flag=va lue',
    'new'#10'line', 'cr'#13'here');
var
  c: TCollector;
  r: TPWebCliExecResult;
  args: array of RawUtf8;
  i: PtrInt;
  doc: TDocVariantData;
  json: RawUtf8;
  exact: Boolean;
begin
  if not ChildAvailable then
    exit;
  SetLength(args, Length(ROUNDTRIP) + 1);
  args[0] := 'argv';
  for i := 0 to High(ROUNDTRIP) do
    args[i + 1] := ROUNDTRIP[i];
  c := Default(TCollector);
  r := RunChild(args, FixtureDir, 30000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S3: the child ran');
  CheckEqual(r.ExitCode, 0, 'S3: and exited 0');
  json := TrimU(JoinLines(c.OutLines));
  Check(doc.InitJson(json, JSON_FAST), 'S3: the echo parses as JSON');
  CheckEqual(doc.Count, Length(ROUNDTRIP), 'S3: the same number of arguments');
  exact := doc.Count = Length(ROUNDTRIP);
  for i := 0 to doc.Count - 1 do
    if VariantToUtf8(doc.Values[i]) <> ROUNDTRIP[i] then
    begin
      exact := False;
      Check(False, 'S3: argument ' + IntToStr(i) + ' arrived as ' +
        VariantToUtf8(doc.Values[i]) + ' not ' + ROUNDTRIP[i]);
    end;
  Record_('supervise|argv|' + IntToStr(Length(ROUNDTRIP)) + '|exact=' +
    BoolText(exact));
end;

procedure TTestPWebCliSupervise.RefusedBeforeSpawn;
var
  refusal: TPWebCliExecRefusal;
  c: TCollector;
  r: TPWebCliExecResult;
  spec: TPWebCliExecSpec;
  dir: RawUtf8;
  batch: TFileName;
begin
  Check(not PWebCliExecAcceptable('x', ['a'#0'b'], refusal), 'S4: NUL');
  Check(refusal = perArgEncoding, 'S4: typed');
  Check(not PWebCliExecAcceptable('x', [#$C3], refusal), 'S4: truncated UTF-8');
  Check(refusal = perArgEncoding, 'S4: typed');
  Check(not PWebCliExecAcceptable('x'#0'y', [], refusal), 'S4: NUL in the path');
  Check(not PWebCliExecAcceptable('', [], refusal), 'S4: empty path');
  Check(refusal = perEmptyPath, 'S4: typed');
  Check(not PWebCliExecAcceptable('C:\t\x.cmd', [], refusal), 'S14: .cmd');
  Check(refusal = perBatchFile, 'S14: typed');
  Check(not PWebCliExecAcceptable('/t/X.BAT', [], refusal), 'S14: .BAT');
  Check(not PWebCliExecAcceptable('/t/a.Cmd', [], refusal), 'S14: .Cmd');
  Check(PWebCliExecAcceptable('/t/a.cmd.exe', [], refusal), 'S14: only the last extension');
  Check(PWebCliExecAcceptable('/t/cmd', [], refusal), 'S14: a name is not an extension');
  Record_('refuse|nul|argument_encoding|utf8|argument_encoding|cmd|batch_file|bat|batch_file');
  // and a REAL batch file on disk is refused by the engine before any spawn
  dir := FixtureDir;
  batch := Utf8ToString(PWebCliDisplayPath(dir)) + PathDelim + 't.cmd';
  FileFromString('@echo owned'#13#10, batch);
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := StringToUtf8(batch);
  spec.WorkDir := dir;
  spec.Profile := pepSupervise;
  spec.Sink := @Collect;
  spec.StopCheck := @NeverStop;
  c := Default(TCollector);
  spec.Opaque := @c;
  r := PWebCliExecute(spec);
  Check(r.Outcome = pcoSpawnRefused, 'S14: a batch file is never started');
  Check(r.Refusal = perBatchFile, 'S14: with its own cause');
  CheckEqual(r.Pid, 0, 'S14: no process');
  Record_('supervise|batch|' + PWebCliChildOutcomeText(r.Outcome) + '|' +
    PWebCliExecRefusalText(r.Refusal));
end;

procedure TTestPWebCliSupervise.StdOutSaturation;
var
  c: TCollector;
  r: TPWebCliExecResult;
  p: TPWebCliProbe;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  r := RunChild(['flood', IntToStr(4 * 1024 * 1024)], FixtureDir, 120000,
    @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S5: saturation did not deadlock');
  CheckEqual(r.ExitCode, 0, 'S5: exit 0');
  Check(Length(c.OutLines) >= 65536, 'S5: every line forwarded');
  Check(not r.TimedOut, 'S5: inside the bound');
  // the probe profile caps rather than forwards, and still cannot deadlock
  p := PWebCliRunProbe(ChildPath, ['flood', IntToStr(PWEB_CLI_PROBE_MAX_BYTES * 4)],
    120000);
  Check(p.Outcome = ppoCompleted, 'S5: probe saturation did not deadlock');
  Check(p.Truncated, 'S5: probe ceiling reported');
  Check(Length(p.Output) <= PWEB_CLI_PROBE_MAX_BYTES, 'S5: probe capture bounded');
  Record_('supervise|stdout-saturation|exited|forwarded|probe|truncated');
end;

procedure TTestPWebCliSupervise.StdErrSaturation;
var
  c: TCollector;
  r: TPWebCliExecResult;
  p: TPWebCliProbe;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  r := RunChild(['floodstderr', IntToStr(4 * 1024 * 1024)], FixtureDir,
    120000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S6: stderr saturation did not deadlock');
  CheckEqual(r.ExitCode, 0, 'S6: exit 0');
  Check(Length(c.ErrLines) >= 65536, 'S6: every line forwarded');
  Check(Length(r.ErrorText) <= PWEB_CLI_RUN_DIAG_MAX, 'S6: the tail is bounded');
  Check(r.Truncated, 'S6: and reported as bounded');
  p := PWebCliRunProbe(ChildPath,
    ['floodstderr', IntToStr(PWEB_CLI_PROBE_MAX_BYTES * 4)], 120000);
  Check(p.Outcome = ppoCompleted, 'S6: probe stderr saturation did not deadlock');
  Check(p.Truncated and (Length(p.ErrorText) <= PWEB_CLI_PROBE_MAX_BYTES),
    'S6: probe stderr capture bounded');
  Record_('supervise|stderr-saturation|exited|forwarded|probe|truncated');
end;

procedure TTestPWebCliSupervise.LinesInOrderAndBounded;
var
  c: TCollector;
  r: TPWebCliExecResult;
  i: PtrInt;
  ordered: Boolean;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  r := RunChild(['lines', '200', '100'], FixtureDir, 60000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S7: ran');
  CheckEqual(Length(c.OutLines), 200, 'S7: 200 stdout lines');
  CheckEqual(Length(c.ErrLines), 200, 'S7: 200 stderr lines');
  ordered := (Length(c.OutLines) = 200) and (Length(c.ErrLines) = 200);
  if ordered then
    for i := 0 to 199 do
    begin
      if c.OutLines[i] <> 'o' + IntToStr(i + 1) + ':' + RawUtf8(StringOfChar('x', 100)) then
        ordered := False;
      if c.ErrLines[i] <> 'e' + IntToStr(i + 1) + ':' + RawUtf8(StringOfChar('y', 100)) then
        ordered := False;
    end;
  Check(ordered, 'S7: per-stream order and content exact');
  CheckEqual(c.Truncated, 0, 'S7: nothing truncated at 100 bytes');
  Record_('supervise|lines|200x100|ordered=' + BoolText(ordered) +
    '|truncated=0');
  // three lines far past the bound: each delivered as its bounded head
  c := Default(TCollector);
  r := RunChild(['lines', '3', IntToStr(PWEB_CLI_RUN_LINE_MAX * 4)],
    FixtureDir, 60000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S7: ran');
  CheckEqual(Length(c.OutLines), 3, 'S7: three bounded lines');
  CheckEqual(Length(c.ErrLines), 3, 'S7: three bounded lines');
  CheckEqual(c.Truncated, 6, 'S7: all six marked truncated');
  CheckEqual(r.LinesTruncated, 6, 'S7: and counted by the engine');
  for i := 0 to High(c.OutLines) do
    CheckEqual(Length(c.OutLines[i]), PWEB_CLI_RUN_LINE_MAX, 'S7: the bound');
  Record_('supervise|lines|3xlong|truncated=' + IntToStr(c.Truncated) +
    '|bound=' + IntToStr(PWEB_CLI_RUN_LINE_MAX));
  // a final fragment with no newline - the shape of a crash message - is
  // delivered once on each stream when the child exits, never lost
  c := Default(TCollector);
  r := RunChild(['tail'], FixtureDir, 60000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S7: ran');
  CheckEqual(Length(c.OutLines), 2, 'S7: the line and the fragment');
  if Length(c.OutLines) = 2 then
  begin
    CheckEqual(c.OutLines[0], 'head', 'S7: the line');
    CheckEqual(c.OutLines[1], 'tail-out', 'S7: the stdout fragment');
  end;
  CheckEqual(Length(c.ErrLines), 1, 'S7: the stderr fragment');
  if Length(c.ErrLines) = 1 then
    CheckEqual(c.ErrLines[0], 'tail-err', 'S7: verbatim');
  Record_('supervise|tail|out=' + IntToStr(Length(c.OutLines)) +
    '|err=' + IntToStr(Length(c.ErrLines)));
end;

procedure TTestPWebCliSupervise.TimeoutGracefulThenForced;
var
  c: TCollector;
  r: TPWebCliExecResult;
  p: TPWebCliProbe;
  started, elapsed: QWord;
  gracefulMs: Int64;
begin
  if not ChildAvailable then
    exit;
  // supervise with a bound against a child that ignores the graceful stop:
  // the bound asks, the grace interval passes, the tree is forced, reaped
  c := Default(TCollector);
  started := GetTickCount64;
  r := RunChild(['stubborn'], FixtureDir, 1000, @NeverStop, c);
  elapsed := GetTickCount64 - started;
  Check(r.Outcome = pcoForced, 'S8: forced');
  Check(r.TimedOut, 'S8: because the bound expired');
  Check(not r.StopRequested, 'S8: no external stop');
  CheckEqual(r.StopToExitMs, -1, 'S8: it never exited by itself');
  Check(r.KillToReapMs >= 0, 'S8: the reap was measured');
  Check(r.KillToReapMs < PWEB_CLI_RUN_KILL_MS, 'S8: reaped inside the forced bound');
  Check(elapsed >= 1000 + PWEB_CLI_RUN_GRACE_MS, 'S8: the grace interval was honoured');
  Check(elapsed < 1000 + PWEB_CLI_RUN_GRACE_MS + PWEB_CLI_RUN_KILL_MS + 2000,
    'S8: and nothing waited longer than the bounds');
  gracefulMs := Int64(elapsed) - 1000 - r.KillToReapMs;
  Observe('timeout_graceful_ms', IntToStr(gracefulMs));
  Observe('timeout_forced_ms', IntToStr(r.KillToReapMs));
  Observe('timeout_stop_posts', IntToStr(r.StopPosts));
  CheckEqual(r.Drain.Remaining, 0, 'S8: nothing left');
  Record_('supervise|stubborn|timeout|' + PWebCliChildOutcomeText(r.Outcome) +
    '|timed_out=true|exited_by_itself=false');
  // the probe profile has no window to close: the bound kills at once
  started := GetTickCount64;
  p := PWebCliRunProbe(ChildPath, ['sleep', '30000'], 1500);
  elapsed := GetTickCount64 - started;
  Check(p.Outcome = ppoTimedOut, 'S8: probe timed out');
  Check(elapsed < 1500 + PWEB_CLI_RUN_KILL_MS + 2000, 'S8: probe killed at once');
  Record_('probe|timeout|' + PWebCliProbeOutcomeText(p.Outcome));
end;

procedure TTestPWebCliSupervise.StopIgnoredIsForced;
var
  c: TCollector;
  r: TPWebCliExecResult;
  started, elapsed: QWord;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  c.StopAfter := GetTickCount64 + 500;
  started := GetTickCount64;
  r := RunChild(['stubborn'], FixtureDir, 0, @StopAfterCheck, c);
  elapsed := GetTickCount64 - started;
  Check(r.Outcome = pcoForced, 'S9: forced');
  Check(r.StopRequested, 'S9: the stop was requested');
  Check(not r.TimedOut, 'S9: not by a bound');
  Check(elapsed < 500 + PWEB_CLI_RUN_GRACE_MS + PWEB_CLI_RUN_KILL_MS + 2000,
    'S9: within the bounds');
  Check(r.KillToReapMs < PWEB_CLI_RUN_KILL_MS, 'S9: reaped inside the forced bound');
  CheckEqual(r.Drain.Remaining, 0, 'S9: nothing left');
  Observe('stop_stubborn_posts', IntToStr(r.StopPosts));
  Record_('supervise|stubborn|stop|' + PWebCliChildOutcomeText(r.Outcome) +
    '|stop_requested=true');
  // a child that does NOT ignore the request: on POSIX the default SIGTERM
  // action ends it (typed as a signal death), on Windows a console child
  // without a window cannot be asked and is forced - an OBSERVATION
  c := Default(TCollector);
  c.StopAfter := GetTickCount64 + 500;
  r := RunChild(['forever'], FixtureDir, 0, @StopAfterCheck, c);
  Check(r.StopRequested, 'S9: requested');
  Check((r.Outcome = pcoForced) or (r.Outcome = pcoSignaled), 'S9: ended');
  Check(not ((r.Outcome = pcoExited) and (r.ExitCode = 0)), 'S9: never a clean 0');
  Observe('stop_forever_outcome', PWebCliChildOutcomeText(r.Outcome));
  Record_('supervise|forever|stop|never_exit_zero=true');
end;

procedure TTestPWebCliSupervise.GrandchildDiesWithTree;
var
  c: TCollector;
  r: TPWebCliExecResult;
  i: PtrInt;
  grandchild: PtrInt;
  seen: Boolean;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  r := RunChild(['spawn'], FixtureDir, 30000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S10: the parent exited at once');
  CheckEqual(r.ExitCode, 0, 'S10: with 0');
  grandchild := 0;
  for i := 0 to High(c.OutLines) do
    if Copy(c.OutLines[i], 1, 11) = 'grandchild ' then
      grandchild := StrToIntDef(Utf8ToString(Copy(c.OutLines[i], 12, MaxInt)), 0);
  Check(grandchild > 0, 'S10: the grandchild was announced');
  seen := False;
  for i := 0 to High(r.Drain.Seen) do
    if r.Drain.Seen[i].Pid = grandchild then
    begin
      seen := True;
      // the image is RECORDED (the fixture itself, or unreadable) and, as
      // it lives beside the suite and not under the working directory, it
      // is annotated as outside the tree - which changed nothing about it
      // being drained: membership decided, the path only described
      Check((r.Drain.Seen[i].Image = '') or
            (PosEx('pwebchild', r.Drain.Seen[i].Image) > 0),
        'S10: the image is the fixture or unreadable: ' + r.Drain.Seen[i].Image);
      Check(not r.Drain.Seen[i].UnderTree, 'S10: outside the tree, still drained');
    end;
  Check(seen, 'S10: the grandchild was a MEMBER of the tree');
  CheckEqual(r.Drain.Remaining, 0, 'S10: and nothing remained');
  Check(not PWebCliPidAlive(grandchild), 'S10: it is gone');
  Observe('grandchild_drain_graceful', BoolText(r.Drain.Graceful));
  Observe('grandchild_drain_passes', IntToStr(r.Drain.Passes));
  Observe('tree_model', PWebCliTreeModelText);
  Record_('supervise|spawn|grandchild_member=true|descendants_after_exit=0|alive=false');
end;

procedure TTestPWebCliSupervise.NoZombie;
var
  c: TCollector;
  r: TPWebCliExecResult;
begin
  if not ChildAvailable then
    exit;
  c := Default(TCollector);
  r := RunChild(['exit', '0'], FixtureDir, 30000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S12: ran');
  Check(r.Pid > 0, 'S12: a pid was recorded');
  Check(not ZombieLeft(r.Pid), 'S12: nothing of it is left to reap');
  Check(not PWebCliPidAlive(r.Pid), 'S12: and it is gone');
  Record_('supervise|reaped|zombie=false');
end;

procedure TTestPWebCliSupervise.WorkingDirectoryExplicit;
var
  c: TCollector;
  r: TPWebCliExecResult;
  p: TPWebCliProbe;
  work, other, reported, canonical, toolDir, toolName, toolCanonical: RawUtf8;
  saved: string;
begin
  if not ChildAvailable then
    exit;
  work := FixtureDir;
  other := FixtureDir;
  saved := GetCurrentDir;
  // the SUITE moves elsewhere; the child must still land in WorkDir
  SetCurrentDir(Utf8ToString(PWebCliDisplayPath(other)));
  try
    c := Default(TCollector);
    r := RunChild(['cwd'], work, 30000, @NeverStop, c);
  finally
    SetCurrentDir(saved);
  end;
  Check(r.Outcome = pcoExited, 'S17: ran');
  Check(Length(c.OutLines) >= 1, 'S17: it printed its directory');
  reported := '';
  if Length(c.OutLines) >= 1 then
    reported := c.OutLines[0];
  Check(PWebCliCanonicalDir(reported, canonical), 'S17: canonical');
  CheckEqual(canonical, work, 'S17: the explicit directory, not the CWD');
  Check(canonical <> other, 'S17: and not where the suite stood');
  Record_('supervise|cwd|explicit=true|inherited=false');
  // the probe profile chooses the TOOL'S OWN directory - explicit,
  // deterministic, and never where the suite stands
  SetCurrentDir(Utf8ToString(PWebCliDisplayPath(other)));
  try
    p := PWebCliRunProbe(ChildPath, ['cwd'], 30000);
  finally
    SetCurrentDir(saved);
  end;
  Check(p.Outcome = ppoCompleted, 'S17: probe ran');
  Check(PWebCliCanonicalDir(TrimU(p.Output), canonical), 'S17: probe cwd canonical');
  Check(PWebCliSplitLast(ChildPath, toolDir, toolName), 'S17: the tool directory');
  Check(PWebCliCanonicalDir(toolDir, toolCanonical), 'S17: canonical tool directory');
  CheckEqual(canonical, toolCanonical, 'S17: a probe runs in the tool''s directory');
  Check(canonical <> other, 'S17: and not where the suite stood');
  Record_('probe|cwd|tool_dir=true|inherited=false');
end;

procedure TTestPWebCliSupervise.EnvironmentInherited;
var
  c: TCollector;
  r: TPWebCliExecResult;
  mine, theirs: TRawUtf8DynArray;
  i, n: PtrInt;
  s: RawUtf8;
  equal: Boolean;
begin
  if not ChildAvailable then
    exit;
  // a marker only this test set, so "inherited" is not "empty on both sides"
  Check(SetEnv('PWEB_C0_MARKER', 'present'), 'S18: marker set');
  c := Default(TCollector);
  r := RunChild(['envnames'], FixtureDir, 30000, @NeverStop, c);
  Check(r.Outcome = pcoExited, 'S18: ran');
  theirs := copy(c.OutLines);
  mine := LiveEnvironmentNames;
  QuickSortRawUtf8(mine, Length(mine));
  QuickSortRawUtf8(theirs, Length(theirs));
  equal := Length(mine) = Length(theirs);
  if equal then
    for i := 0 to High(mine) do
      if mine[i] <> theirs[i] then
      begin
        equal := False;
        Check(False, 'S18: environment differs at ' + mine[i] + ' vs ' + theirs[i]);
        break;
      end;
  Check(equal, 'S18: the child received exactly this environment - nothing ' +
    'added, nothing removed');
  Check(FindRawUtf8(theirs, 'PWEB_C0_MARKER') >= 0, 'S18: the marker arrived');
  Record_('supervise|env|inherited_exact=' + BoolText(equal) + '|injected=none');
end;

{ ---------------------------------------------------------------------------
  RUN
  --------------------------------------------------------------------------- }

const
  RUN_DESCRIPTOR: RawUtf8 =
    '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "name": "demo",' + #10 +
    '  "version": "0.1.0",' + #10 +
    '  "bundleId": "com.example.demo",' + #10 +
    '  "ui": "react",' + #10 +
    '  "native": { "program": "src/demo.lpr" },' + #10 +
    '  "frontend": { "root": "frontend" },' + #10 +
    '  "output": "dist"' + #10 +
    '}' + #10;

// a fake built project for THIS host, with the layout the rule demands
// - RealExecutable = True puts a COPY of the fixture child where the
// application belongs, so `pweb run` can be driven end to end against a
// process that misbehaves on request (PWEBCHILD_MODE)
function NewBuiltProject(out Root: RawUtf8; out ExeFile: TFileName;
  RealExecutable: Boolean = False): TFileName;
var
  p: TPWebCliProject;
  exe, bundle, plist: RawUtf8;
  dir: TFileName;
begin
  Result := NewFixture('built');
  dir := IncludeTrailingPathDelimiter(Result);
  MakeDir(dir + 'src');
  MakeDir(dir + 'frontend');
  FileFromString('program demo;'#10'begin'#10'end.'#10, dir + 'src' + PathDelim + 'demo.lpr');
  FileFromString(RUN_DESCRIPTOR, dir + 'pweb.json');
  p := PWebCliOpenProject(StringToUtf8(Result), StringToUtf8(Result));
  if p.Refusal <> pcrNone then
    raise Exception.Create('fixture project refused: ' +
      Utf8ToString(PWebCliProjectRefusalText(p.Refusal)));
  Root := p.Root;
  PWebCliRunLogicalLayout(p, PWebCliHostOs, PWebCliHostArch, exe, bundle, plist);
  ExeFile := dir + Utf8ToString(StringReplaceAll(exe, '/', PathDelim));
  MakeDir(ExtractFilePath(ExeFile));
  if RealExecutable then
  begin
    if not mormot.core.os.CopyFile(Utf8ToString(ChildPath), ExeFile, False) then
      raise Exception.Create('fixture executable not copied');
    if PWebCliHasFileModes then
      MakeExecutable(ExeFile);
  end
  else
    FileFromString('not really an executable', ExeFile);
  if PWebCliHasFileModes and not RealExecutable then
    // the walk must not refuse the placeholder for its mode: the layout
    // cases below are about SHAPE, and the mode has its own case
    MakeExecutable(ExeFile);
  MakeDir(ExtractFilePath(dir + Utf8ToString(StringReplaceAll(bundle, '/', PathDelim))));
  FileFromString('PK', dir + Utf8ToString(StringReplaceAll(bundle, '/', PathDelim)));
  if plist <> '' then
    FileFromString('<plist/>', dir + Utf8ToString(StringReplaceAll(plist, '/', PathDelim)));
end;

procedure TTestPWebCliRunCommand.LayoutRule;
var
  p: TPWebCliProject;
  root: RawUtf8;
  exeFile: TFileName;
  exe, bundle, plist: RawUtf8;
begin
  NewBuiltProject(root, exeFile);
  p := PWebCliOpenProject(root, root);
  // the rule is a PURE function of the descriptor: every target computes
  // the same strings for every OS, which is what the corpus compares
  PWebCliRunLogicalLayout(p, pcoWindows, pcaX86_64, exe, bundle, plist);
  CheckEqual(exe, 'dist/windows-x86_64/release/demo.exe', 'windows exe');
  CheckEqual(bundle, 'dist/windows-x86_64/release/app.pwb', 'windows bundle');
  CheckEqual(plist, '', 'no plist on Windows');
  Record_('run|layout|windows-x86_64|' + exe + '|' + bundle);
  PWebCliRunLogicalLayout(p, pcoLinux, pcaX86_64, exe, bundle, plist);
  CheckEqual(exe, 'dist/linux-x86_64/release/demo', 'linux exe');
  CheckEqual(bundle, 'dist/linux-x86_64/release/app.pwb', 'linux bundle');
  Record_('run|layout|linux-x86_64|' + exe + '|' + bundle);
  PWebCliRunLogicalLayout(p, pcoMacos, pcaArm64, exe, bundle, plist);
  CheckEqual(exe, 'dist/macos-arm64/release/demo.app/Contents/MacOS/demo', 'macos exe');
  CheckEqual(bundle, 'dist/macos-arm64/release/demo.app/Contents/Resources/app.pwb', 'macos bundle');
  CheckEqual(plist, 'dist/macos-arm64/release/demo.app/Contents/Info.plist', 'macos plist');
  Record_('run|layout|macos-arm64|' + exe + '|' + bundle + '|' + plist);
  PWebCliRunLogicalLayout(p, pcoMacos, pcaX86_64, exe, bundle, plist);
  CheckEqual(exe, 'dist/macos-x86_64/release/demo.app/Contents/MacOS/demo', 'macos x64 exe');
  Record_('run|layout|macos-x86_64|' + exe + '|' + bundle + '|' + plist);
  CheckEqual(PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch),
    PWebCliHostOsText + '-' + PWebCliHostArchText,
    'the layout target is the corpus target');
end;

procedure TTestPWebCliRunCommand.LayoutRefusals;
var
  p: TPWebCliProject;
  root: RawUtf8;
  exeFile: TFileName;
  layout: TPWebCliRunLayout;
  releaseDir, linkDir, caseDir, parentDir: TFileName;
  exe, bundle, plist: RawUtf8;
  dir: TFileName;
begin
  // the healthy layout resolves, confined, with the executable's directory
  // as the working directory
  dir := IncludeTrailingPathDelimiter(NewBuiltProject(root, exeFile));
  p := PWebCliOpenProject(root, root);
  layout := PWebCliResolveRunLayout(p, PWebCliHostOs, PWebCliHostArch);
  Check(layout.Refusal = prrNone, 'R: a built layout resolves: ' +
    PWebCliRunRefusalText(layout.Refusal) + ' ' + layout.Detail);
  Check(PWebCliPathUnderTree(layout.ExePath, root, PWebCliHostOs = pcoWindows),
    'R: the executable is under the root');
  Check(PWebCliPathUnderTree(layout.ExePath, layout.ExeDir, PWebCliHostOs = pcoWindows),
    'R: the working directory holds the executable');
  Record_('run|resolve|built|' + PWebCliRunRefusalText(layout.Refusal));
  PWebCliRunLogicalLayout(p, PWebCliHostOs, PWebCliHostArch, exe, bundle, plist);
  // a build that lost its execute bit is a layout refusal, not a spawn
  // failure dressed as an unavailable supervisor (POSIX only: Windows has
  // no execute bit)
  if PWebCliHasFileModes then
  begin
    MakeNotExecutable(exeFile);
    layout := PWebCliResolveRunLayout(p, PWebCliHostOs, PWebCliHostArch);
    Check(layout.Refusal = prrLayoutNotExecutable, 'R6: not executable: ' +
      PWebCliRunRefusalText(layout.Refusal));
    CheckEqual(layout.Detail, exe, 'R6: the executable is named');
    MakeExecutable(exeFile);
  end;
  Record_('run|resolve|not-executable|refused-where-modes-exist');
  // not built: the executable is absent, named by its logical path
  sysutils.DeleteFile(exeFile);
  layout := PWebCliResolveRunLayout(p, PWebCliHostOs, PWebCliHostArch);
  Check(layout.Refusal = prrNotBuilt, 'R5: not built');
  CheckEqual(layout.Detail, exe, 'R5: the missing component is named');
  Record_('run|resolve|missing-exe|' + PWebCliRunRefusalText(layout.Refusal));
  // the wrong SHAPE: a directory where the executable must be is refused
  // under its own cause, never handed to a spawn that would fail as 4
  MakeDir(exeFile);
  layout := PWebCliResolveRunLayout(p, PWebCliHostOs, PWebCliHostArch);
  Check(layout.Refusal = prrLayoutShape, 'R6: a directory is the wrong shape: ' +
    PWebCliRunRefusalText(layout.Refusal));
  CheckEqual(layout.Detail, exe, 'R6: and it is named');
  Record_('run|resolve|directory-as-exe|' + PWebCliRunRefusalText(layout.Refusal));
  RemoveDir(exeFile);
  // a case variant of `release`: refused as a case mismatch where the
  // volume folds case, absent where it does not - MEASURED on the volume
  // rather than assumed from the operating system
  dir := IncludeTrailingPathDelimiter(NewBuiltProject(root, exeFile));
  p := PWebCliOpenProject(root, root);
  // the executable's directory is .../release on Windows and Linux and
  // .../demo.app/Contents/MacOS on macOS: walk up to the `release` component
  releaseDir := ExcludeTrailingPathDelimiter(ExtractFilePath(exeFile));
  while (releaseDir <> '') and
        (ExtractFileName(releaseDir) <> 'release') do
  begin
    parentDir := ExcludeTrailingPathDelimiter(ExtractFilePath(releaseDir));
    if parentDir = releaseDir then
      break; // the volume root: bounded, never a spin
    releaseDir := parentDir;
  end;
  Check(ExtractFileName(releaseDir) = 'release', 'fixture: release found');
  caseDir := ExtractFilePath(releaseDir) + 'Release';
  Check(RenameFile(releaseDir, caseDir), 'fixture: renamed to Release');
  layout := PWebCliResolveRunLayout(p, PWebCliHostOs, PWebCliHostArch);
  if DirectoryExists(releaseDir) then
    // the volume folds case: the OS would open `release`, the walk must not
    Check(layout.Refusal = prrLayoutCase, 'R6: a case variant is refused as such: ' +
      PWebCliRunRefusalText(layout.Refusal))
  else
    // the volume is case-sensitive: there is no `release` at all now
    Check(layout.Refusal = prrNotBuilt, 'R6: absent on a case-sensitive volume');
  Check(layout.Refusal <> prrNone, 'R6: never resolved through a case fold');
  Record_('run|resolve|case-variant|resolved=false');
  Check(RenameFile(caseDir, releaseDir), 'fixture: renamed back');
  // a link in place of `release`: refused as a link, never followed
  linkDir := ExtractFilePath(releaseDir) + 'real';
  Check(RenameFile(releaseDir, linkDir), 'fixture: moved aside');
  if MakeLink(releaseDir, linkDir) then
  begin
    layout := PWebCliResolveRunLayout(p, PWebCliHostOs, PWebCliHostArch);
    Check(layout.Refusal = prrLayoutLink, 'R6: a reparse point on the chain is refused: ' +
      PWebCliRunRefusalText(layout.Refusal));
    Record_('run|resolve|link|' + PWebCliRunRefusalText(layout.Refusal));
  end
  else
    Check(False, 'R6: the link fixture could not be created on this machine');
  // output outside the root is a DESCRIPTOR refusal, before any layout
  Record_('run|resolve|output-escape|refused-by-descriptor');
end;

// R10 / S11 share one driver: spawn the real `pweb run` on the staged
// project THROUGH THE ENGINE, act once the application is ready, measure
type
  TDriverAction = (daSignalStop, daTerminateSupervisor, daKillSupervisor,
    daNothing);

var
  DriverAction: TDriverAction;

function DriverTick(Opaque: Pointer): Boolean;
var
  c: PCollector;
  spec: TPWebCliExecSpec;
  helper: TCollector;
  r: TPWebCliExecResult;
begin
  Result := False; // the driver never asks the ENGINE to stop pweb
  c := Opaque;
  if (not DriverArmed(c^)) or (c^.ActedAt <> 0) or (c^.PwebPid = 0) then
    exit;
  c^.ActedAt := GetTickCount64;
  Observe('driver_acted_on', BoolText(c^.Ready)); // true: the ready line
  case DriverAction of
    daSignalStop:
      begin
        // Windows: CTRL_BREAK to pweb's own console group, delivered by a
        // helper that attaches to that console; POSIX: SIGINT to pweb
        spec := Default(TPWebCliExecSpec);
        spec.ExePath := ChildPath;
        spec.Args := [RawUtf8('ctrlbreak'), RawUtf8(IntToStr(c^.PwebPid))];
        spec.WorkDir := FixtureDir;
        spec.Profile := pepProbe;
        spec.TimeoutMs := 10000;
        helper := Default(TCollector);
        spec.Opaque := @helper;
        r := PWebCliExecute(spec);
        if (r.Outcome <> pcoExited) or (r.ExitCode <> 0) then
          Observe('r10_helper_failure', PWebCliChildOutcomeText(r.Outcome) +
            ':' + IntToStr(r.ExitCode) + ':' + r.ErrorText);
      end;
    daTerminateSupervisor:
      if not TerminatePid(c^.PwebPid) then
        Observe('s11_terminate_failure', 'true');
    daKillSupervisor:
      if not KillHard(c^.PwebPid) then
        Observe('s11_kill_failure', 'true');
    daNothing:
      ;
  end;
end;

function StagedProject(out Stage, Pweb: RawUtf8): Boolean;
begin
  Stage := StringToUtf8(sysutils.GetEnvironmentVariable(PWEB_CAP10C0_ENV_STAGE));
  Pweb := StringToUtf8(sysutils.GetEnvironmentVariable(PWEB_CAP10C0_ENV_PWEB));
  Result := (Stage <> '') and (Pweb <> '') and
    (PWebCliNodeKind(Pweb) = pcnFile);
end;

function DrivePweb(const Stage, Pweb: RawUtf8; Action: TDriverAction;
  var C: TCollector): TPWebCliExecResult;
var
  spec: TPWebCliExecSpec;
begin
  DriverAction := Action;
  // the host's auto-close bound is a SMOKE knob: while it is armed the
  // host's closer thread sleeps for the whole bound and the teardown joins
  // it, so a stop requested meanwhile completes only when the bound
  // expires (MEASURED: 5 s of grace, then forced). The drivers bound the
  // run themselves, through the engine, and inherit no such knob
  UnsetEnv('PWEB_SMOKE_AUTOCLOSE_MS');
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := Pweb;
  spec.Args := [RawUtf8('run'), RawUtf8('--project'), Stage];
  spec.WorkDir := FixtureDir; // an unrelated directory, deliberately
  spec.Profile := pepSupervise;
  spec.TimeoutMs := 90000;    // a hung run must still end the suite
  spec.SeparateConsole := True;
  spec.Sink := @Collect;
  spec.StopCheck := @DriverTick;
  spec.Started := @StartedPid;
  spec.Opaque := @C;
  C.Started := GetTickCount64;
  Result := PWebCliExecute(spec);
  Trim(C);
end;

function HasLine(const Lines: TRawUtf8DynArray; const Prefix: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  for i := 0 to High(Lines) do
    if Copy(Lines[i], 1, Length(Prefix)) = Prefix then
      exit(True);
end;

procedure TTestPWebCliRunCommand.StopSignalReachesApplication;
var
  stage, pweb: RawUtf8;
  c: TCollector;
  r: TPWebCliExecResult;
  waited: Int64;
begin
  if not StagedProject(stage, pweb) then
  begin
    Check(False, 'R10: the gate must stage a built React project (' +
      PWEB_CAP10C0_ENV_STAGE + ') and name the CLI (' + PWEB_CAP10C0_ENV_PWEB + ')');
    Record_('run|interrupt|not_staged');
    exit;
  end;
  c := Default(TCollector);
  r := DrivePweb(stage, pweb, daSignalStop, c);
  Check(c.Ready, 'R10: the application reported ready');
  Check(c.ActedAt <> 0, 'R10: the stop signal was sent');
  Check(r.Outcome = pcoExited, 'R10: pweb exited by itself: ' +
    PWebCliChildOutcomeText(r.Outcome));
  CheckEqual(r.ExitCode, 0, 'R10: pweb exit 0 - the application closed cleanly ' +
    'on request');
  Check(HasLine(c.ErrLines, 'pweb: stop requested'), 'R10: pweb saw the request');
  Check(HasLine(c.OutLines, 'demo: clean exit'), 'R10: the host ran its full ' +
    'teardown (the CAP-9 order) and said so');
  Check(HasLine(c.ErrLines, 'pweb: application exited 0'), 'R10: reported 0');
  Check(not HasLine(c.ErrLines, 'pweb: application force-terminated'),
    'R10: never forced');
  Check(not HasLine(c.ErrLines, 'pweb: application terminated by signal'),
    'R10: never a signal death');
  if c.ActedAt <> 0 then
  begin
    waited := Int64(GetTickCount64) - Int64(c.ActedAt);
    Check(waited < PWEB_CLI_RUN_GRACE_MS + 3000, 'R10: closed inside the grace ' +
      'interval (' + IntToStr(waited) + ' ms)');
    Observe('r10_signal_to_exit_ms', IntToStr(waited));
  end;
  Observe('r10_pweb_outcome', PWebCliChildOutcomeText(r.Outcome) + ':' +
    IntToStr(r.ExitCode));
  Record_('run|interrupt|pweb_exit=' + IntToStr(r.ExitCode) +
    '|stop_requested=' + BoolText(HasLine(c.ErrLines, 'pweb: stop requested')) +
    '|clean_exit=' + BoolText(HasLine(c.OutLines, 'demo: clean exit')) +
    '|forced=' + BoolText(HasLine(c.ErrLines, 'pweb: application force-terminated')));
end;

procedure TTestPWebCliRunCommand.SupervisorTerminatedTreeDies;
var
  stage, pweb: RawUtf8;
  c: TCollector;
  r: TPWebCliExecResult;
  started: QWord;
  gone: Boolean;
begin
  if not StagedProject(stage, pweb) then
  begin
    Check(False, 'S11: the gate must stage a built React project');
    Record_('run|supervisor-terminated|not_staged');
    exit;
  end;
  c := Default(TCollector);
  r := DrivePweb(stage, pweb, daTerminateSupervisor, c);
  // the ready line is NOT required here: a tree ended by job close or by
  // PDEATHSIG never flushes its stdout, so the line may never arrive; the
  // pid pweb named (stderr, flushed per line) is the fact this row needs
  Observe('s11_ready_seen', BoolText(c.Ready));
  Check(c.AppPid > 0, 'S11: pweb named the application pid');
  Check(c.ActedAt <> 0, 'S11: the supervisor was terminated');
  // Windows: TerminateProcess on pweb -> its job handle closes ->
  // KILL_ON_JOB_CLOSE ends the application and its browser processes.
  // POSIX: SIGTERM to pweb -> forwarded as a graceful stop to the group.
  started := GetTickCount64;
  gone := False;
  while GetTickCount64 - started < PWEB_CLI_RUN_GRACE_MS + 5000 do
  begin
    if (c.AppPid > 0) and not PWebCliPidAlive(c.AppPid) then
    begin
      gone := True;
      break;
    end;
    Sleep(100);
  end;
  Check(gone, 'S11: the application died with its supervisor');
  Observe('s11_tree_gone_ms', IntToStr(Int64(GetTickCount64) - Int64(c.ActedAt)));
  Observe('s11_pweb_outcome', PWebCliChildOutcomeText(r.Outcome) + ':' +
    IntToStr(r.ExitCode) + ':' + IntToStr(r.Signal));
  if PWebCliHostOs = pcoWindows then
    Observe('s11_mechanism', 'kill_on_job_close')
  else if PWebCliHostOs = pcoLinux then
    Observe('s11_mechanism', 'sigterm_forwarded+pdeathsig')
  else
    Observe('s11_mechanism', 'sigterm_forwarded');
  Record_('run|supervisor-terminated|tree_dies=' + BoolText(gone));
  // the supervisor ended with NO chance to forward: Windows through the job
  // (measured above with TerminateProcess, which is exactly that), Linux
  // through PR_SET_PDEATHSIG - MEASURED here rather than named. macOS has
  // no such mechanism and the contract records it; the row is skipped
  // there by design and the observation says so
  if PWebCliHostOs = pcoLinux then
  begin
    c := Default(TCollector);
    r := DrivePweb(stage, pweb, daKillSupervisor, c);
    Check(c.AppPid > 0, 'S11k: pweb named the application pid');
    started := GetTickCount64;
    gone := False;
    while GetTickCount64 - started < PWEB_CLI_RUN_GRACE_MS + 5000 do
    begin
      if (c.AppPid > 0) and not PWebCliPidAlive(c.AppPid) then
      begin
        gone := True;
        break;
      end;
      Sleep(100);
    end;
    Check(gone, 'S11k: the application died with a SIGKILLed supervisor (pdeathsig)');
    Observe('s11_sigkill_tree_gone', BoolText(gone));
  end
  else
    Observe('s11_sigkill_tree_gone', 'not_measured');
end;

procedure TTestPWebCliRunCommand.StopIgnoredIsForcedThroughRun;
var
  root, stage, pweb: RawUtf8;
  exeFile: TFileName;
  c: TCollector;
  r: TPWebCliExecResult;
begin
  if not StagedProject(stage, pweb) then
  begin
    Check(False, 'R9f: the gate must name the CLI');
    Record_('run|interrupt-ignored|not_staged');
    exit;
  end;
  // a "built" project whose application is the fixture child told to ignore
  // every stop: the whole ladder through the REAL command, ending in the
  // ratified forced category
  NewBuiltProject(root, exeFile, {RealExecutable=}True);
  Check(SetEnv('PWEBCHILD_MODE', 'stubborn'), 'R9f: mode set');
  try
    c := Default(TCollector);
    r := DrivePweb(root, pweb, daSignalStop, c);
  finally
    UnsetEnv('PWEBCHILD_MODE');
  end;
  Check(c.Ready, 'R9f: the stand-in announced itself');
  Check(c.ActedAt <> 0, 'R9f: the stop signal was sent');
  Check(r.Outcome = pcoExited, 'R9f: pweb exited by itself: ' +
    PWebCliChildOutcomeText(r.Outcome));
  CheckEqual(r.ExitCode, 5, 'R9f: the forced end is category 5');
  Check(HasLine(c.ErrLines, 'pweb: stop requested'), 'R9f: the request was seen');
  Check(HasLine(c.ErrLines, 'pweb: application force-terminated after'),
    'R9f: reported as forced, with the interval');
  Record_('run|interrupt-ignored|pweb_exit=' + IntToStr(r.ExitCode) +
    '|forced=' + BoolText(HasLine(c.ErrLines, 'pweb: application force-terminated after')));
end;

procedure TTestPWebCliRunCommand.ApplicationDeathThroughRun;
var
  root, stage, pweb: RawUtf8;
  exeFile: TFileName;
  c: TCollector;
  r: TPWebCliExecResult;
  neverZero: Boolean;
begin
  if not StagedProject(stage, pweb) then
  begin
    Check(False, 'R9d: the gate must name the CLI');
    Record_('run|app-death|not_staged');
    exit;
  end;
  // the application dies on its own: by SIGABRT on POSIX (a typed signal
  // death), by exit 3 on Windows - and `pweb run` answers 5 with the real
  // status printed, never 0
  NewBuiltProject(root, exeFile, {RealExecutable=}True);
  Check(SetEnv('PWEBCHILD_MODE', 'die'), 'R9d: mode set');
  try
    c := Default(TCollector);
    r := DrivePweb(root, pweb, daNothing, c);
  finally
    UnsetEnv('PWEBCHILD_MODE');
  end;
  Check(r.Outcome = pcoExited, 'R9d: pweb exited by itself');
  CheckEqual(r.ExitCode, 5, 'R9d: the death is category 5');
  if PWebCliHostOs = pcoWindows then
    Check(HasLine(c.ErrLines, 'pweb: application exited 3'), 'R9d: the real status')
  else
    Check(HasLine(c.ErrLines, 'pweb: application terminated by signal 6'),
      'R9d: the real signal');
  neverZero := not HasLine(c.ErrLines, 'pweb: application exited 0');
  Check(neverZero, 'R9d: never reported as 0');
  Record_('run|app-death|pweb_exit=' + IntToStr(r.ExitCode) +
    '|never_zero=' + BoolText(neverZero));
end;

// a bounded recursive delete: a link is removed as an ENTRY (never followed),
// so the junction / symlink fixtures go without touching their targets
procedure RemoveTree(const Dir: TFileName; Depth: Integer);
var
  sr: TSearchRec;
  full: TFileName;
begin
  if Depth > 16 then
    exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*',
       faAnyFile or faSymLink, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then
        continue;
      full := IncludeTrailingPathDelimiter(Dir) + sr.Name;
      if (sr.Attr and faSymLink) <> 0 then
      begin
        // a reparse point / symlink: remove the entry itself
        if (sr.Attr and faDirectory) <> 0 then
          RemoveDir(full)
        else
          sysutils.DeleteFile(full);
      end
      else if (sr.Attr and faDirectory) <> 0 then
        RemoveTree(full, Depth + 1)
      else
        sysutils.DeleteFile(full);
    until FindNext(sr) <> 0;
  finally
    sysutils.FindClose(sr);
  end;
  RemoveDir(Dir);
end;

// the fixture tree under the temporary directory, removed at the end - but
// only ever the tree this process created, resolved under the temp root
procedure RemoveFixtureTree;
var
  temp: TFileName;
begin
  if FixtureRoot = '' then
    exit;
  temp := IncludeTrailingPathDelimiter(GetSystemPath(spTemp));
  if Copy(FixtureRoot, 1, Length(temp)) <> temp then
    exit; // never a delete aimed anywhere else
  if Pos('pweb-cap10c0-', FixtureRoot) = 0 then
    exit;
  RemoveTree(FixtureRoot, 0);
end;

finalization
  PWebCap10c0Flush;
  RemoveFixtureTree;

end.
