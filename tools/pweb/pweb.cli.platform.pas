{
  pweb.cli.platform - THE platform seam of the pweb CLI (CAP-10A).

  Every {$ifdef} the CLI owns lives in this one file. The parser, the project
  reader, the path model, the probe runner, the doctor engine and both
  emitters are platform-free source by construction, and the CAP-7F
  divergence sweep holds them at zero conditionals - the same arrangement the
  runtime already uses, where src/platform/<os>/ carries the engine bodies and
  nothing above them names an operating system.

  WHAT THIS UNIT ANSWERS, and nothing else:

    - what the raw command line actually was, as exact UTF-8 bytes;
    - what this host is (os, architecture, release text, product version);
    - whether stdout is a terminal, and whether ANSI is usable on it;
    - the filesystem questions the project model asks: canonicalize a
      directory through the kernel, resolve ONE entry by its exact on-disk
      spelling, refuse a reparse point, read a small file without following
      a link, and can this directory be written to;
    - how executables are found on this platform (PATH shape, extensions,
      what "executable" means);
    - whether the host's WebView engine is present and usable.

  It DECIDES nothing. Every answer is a fact; the doctor turns facts into
  rows, and the CLI turns rows into exit codes.

  ---------------------------------------------------------------------------
  PATHS
  ---------------------------------------------------------------------------

  One representation crosses this seam: UTF-8 (RawUtf8). On Windows the
  conversion to and from UTF-16 happens here and every kernel call goes
  through the wide API - the RTL's Ansi filesystem layer depends on runtime
  codepage state and mistranslates cross-unit concatenations, which is the
  measured reason TFolderAssetStore and pwebbundle already bypass it. On
  POSIX a path is bytes; they are passed through unchanged, and a path that
  is not valid UTF-8 is refused by the caller rather than silently mangled
  here (a documented CAP-10A limitation, fail-closed, never a guess).

  Canonical Windows paths keep their `\\?\` prefix internally, for the
  long-path headroom the walk needs; PWebCliDisplayPath strips it, and only
  for humans.

  ---------------------------------------------------------------------------
  WHAT IS DELIBERATELY NOT HERE
  ---------------------------------------------------------------------------

  No process is started here (pweb.cli.probe owns that, over FPC's process
  unit, which execs directly on both families). No network call of any kind
  exists in the CLI at all. Nothing in this unit writes, creates, deletes or
  renames anything: PWebCliDirWritable asks the ACL/permission question by
  opening a handle for write access, and never by creating a probe file.
}
unit pweb.cli.platform;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode;

type
  /// the three supported host families
  TPWebCliOs = (pcoWindows, pcoLinux, pcoMacos);

  /// host architecture, resolved at compile time (the CLI is always native)
  TPWebCliArch = (pcaX86_64, pcaArm64, pcaOther);

  /// what one filesystem entry is
  // - ordinal 0 is the absent state so a zeroed value never reads as usable
  TPWebCliNodeKind = (
    pcnMissing,
    pcnFile,
    pcnDirectory,
    /// a symlink, junction or any other reparse point - ALWAYS refused
    pcnLink,
    /// a device node, FIFO, socket: present, but never something we use
    pcnOther);

  /// the host WebView engine, as one measured fact
  TPWebCliEngineFact = record
    /// True only when an application could actually run on this host today
    Usable: Boolean;
    /// machine-stable category, never localized prose
    Category: RawUtf8;
    /// what was seen (a version, a soname, a status word)
    Observed: RawUtf8;
    /// what is required, spelled from the pinned source of truth
    Expected: RawUtf8;
  end;

/// 'windows' | 'linux' | 'macos'
function PWebCliHostOs: TPWebCliOs;
function PWebCliHostOsText: RawUtf8;

/// 'x86_64' | 'arm64' | 'other'
function PWebCliHostArch: TPWebCliArch;
function PWebCliHostArchText: RawUtf8;

/// free-form host release text - DIAGNOSTIC only, never compared
function PWebCliOsRelease: RawUtf8;

/// the host product version as strict X.Y or X.Y.Z, when the platform
// publishes one that can be compared (macOS: kern.osproductversion)
// - returns False elsewhere: an unavailable number is never invented
function PWebCliOsProductVersion(out Version: RawUtf8): Boolean;

/// argv[1..] as exact UTF-8 bytes
// - on Windows read from GetCommandLineW through CommandLineToArgvW, so the
// bytes are the user's, not the process code page's guess at them
function PWebCliRawArgs: TRawUtf8DynArray;

/// is stdout a terminal (never true when redirected to a file or a pipe)
function PWebCliStdOutIsTerminal: Boolean;

/// make the console able to render UTF-8, and enable ANSI where it must be
// asked for; silent and harmless when stdout is not a console
procedure PWebCliPrepareConsole;

/// may ANSI sequences be written to stdout right now
// - False whenever stdout is redirected, and False when the terminal could
// not be put into a mode that understands them
function PWebCliAnsiSupported: Boolean;

/// the process working directory, canonicalized through the kernel
function PWebCliCwd(out Dir: RawUtf8): Boolean;

/// canonicalize an existing DIRECTORY through the kernel
// - resolves links in the input, so everything measured against the result
// is measured against the real directory
// - False when the path does not exist, is not a directory, or cannot be
// resolved
function PWebCliCanonicalDir(const Dir: RawUtf8;
  out Canonical: RawUtf8): Boolean;

/// the parent of a canonical directory; False at the filesystem root
function PWebCliParentDir(const Dir: RawUtf8; out Parent: RawUtf8): Boolean;

/// join a canonical directory and ONE entry name with the native separator
function PWebCliJoin(const Dir, Name: RawUtf8): RawUtf8;

/// make a USER-SUPPLIED path (a --project argument, never a descriptor
/// field) absolute against Base, using this platform's own rules
// - the native separator is accepted, and on Windows so is '/', because a
// command-line argument is typed by a person and not by the schema
function PWebCliAbsolute(const Base, Path: RawUtf8): RawUtf8;

/// split a native path into its parent and its last component
// - False when the path has no separator, or names a filesystem root
function PWebCliSplitLast(const Path: RawUtf8;
  out Parent, Name: RawUtf8): Boolean;

/// strip the internal long-path prefix for human output; never for compares
function PWebCliDisplayPath(const Path: RawUtf8): RawUtf8;

/// resolve ONE entry inside a canonical directory by its EXACT on-disk
// spelling
// - the directory itself is read and the name compared byte-exactly, so a
// case-insensitive volume (NTFS, APFS, a casefold mount) can never resolve
// 'Src' to 'src'; an 8.3 alias cannot match either
// - Kind is pcnMissing when nothing with that exact spelling exists
function PWebCliEntry(const Dir, Name: RawUtf8): TPWebCliNodeKind;

/// what this path is, without following a final link
function PWebCliNodeKind(const Path: RawUtf8): TPWebCliNodeKind;

/// may this process create entries in this directory
// - asks the permission question by opening a handle with write access
// (Windows) or faccessat/access W_OK (POSIX). NOTHING is created, written,
// renamed or removed - `pweb doctor` mutates nothing, and a probe file is a
// mutation however briefly it exists
function PWebCliDirWritable(const Dir: RawUtf8): Boolean;

/// read a small file without following a link on its final component
// - TooBig is set (and False returned) when the file exceeds MaxBytes: a
// descriptor is bounded input, never something streamed
function PWebCliReadSmallFile(const Path: RawUtf8; MaxBytes: PtrInt;
  out Content: RawByteString; out TooBig: Boolean): Boolean;

/// the canonical directory holding the RUNNING executable
// - the ONE trusted anchor the SDK-root resolver is allowed to start from.
// Never the working directory, never a caller-supplied path, never an
// environment variable - the same rule PWebReleaseDirectory already applies
// to app.pwb and plugins.zip, re-used rather than re-decided
function PWebCliExeDir(out Dir: RawUtf8): Boolean;

/// every entry of a canonical directory, in its EXACT on-disk spelling
// - '.' and '..' are never returned; the order is the filesystem's and is
// therefore NEVER trusted - every caller sorts
// - False when the directory cannot be enumerated at all, which is a
// refusal and never an empty result
function PWebCliListDir(const Dir: RawUtf8;
  out Names: TRawUtf8DynArray): Boolean;

/// does this platform carry a POSIX file mode at all
// - False on Windows, where a caller records 'not applicable' rather than
// inventing an answer to a question the filesystem does not ask
function PWebCliHasFileModes: Boolean;

/// True when Path is a regular file carrying the owner execute bit
// - always False on Windows; see PWebCliHasFileModes
function PWebCliExecutableBit(const Path: RawUtf8): Boolean;

{ ---------------------------------------------------------------------------
  THE WRITE PRIMITIVES (CAP-10B0)

  Everything above this line only ever ASKS the filesystem something.
  Everything below it can change the filesystem, and each one is written so
  that the exclusivity is the KERNEL'S rather than a check this code performs
  and then hopes still holds:

    - a directory is created with CreateDirectoryW / mkdir(2), both of which
      fail when the name is taken - by anything, a link included;
    - a file is created with CREATE_NEW / O_CREAT|O_EXCL|O_NOFOLLOW, which
      is an atomic "create or fail" and can never open, truncate, append to
      or follow something that was already there;
    - the commit is a rename that must not replace.

  Nothing here is reachable from `pweb doctor`, and in this build nothing is
  reachable from the `pweb` executable at all: the scaffold engine is not
  linked into it (test/cap10b0/check_cap10b0_contracts.ps1 measures that).
  --------------------------------------------------------------------------- }

/// create ONE directory, EXCLUSIVELY
// - the parent must already exist; nothing is created recursively, because
// a partially created chain is exactly the state this layer exists to make
// impossible
// - False when anything already carries that name, when the parent is
// missing, or when permission is refused - all one answer to the caller,
// which never learns enough to probe a directory it may not read
// - POSIX: the mode is set explicitly AFTER creation, so the result does
// not depend on the invoking shell's umask
function PWebCliCreateDir(const Dir: RawUtf8): Boolean;

/// create and write ONE new file, EXCLUSIVELY
// - never opens, truncates, appends to or follows an existing name
// - SetExecBit requests the owner/group/other execute bits on POSIX and is
// silently irrelevant on Windows; the mode is applied with chmod after the
// write, again so umask cannot make the result host-dependent
function PWebCliWriteNewFile(const Path: RawUtf8;
  const Content: RawByteString; SetExecBit: Boolean): Boolean;

/// remove ONE regular file
// - a directory, a link or anything else is REFUSED rather than removed:
// the staging cleanup may only undo what this unit itself created
function PWebCliDeleteFile(const Path: RawUtf8): Boolean;

/// remove ONE empty directory
function PWebCliRemoveEmptyDir(const Dir: RawUtf8): Boolean;

/// rename a directory onto a name that MUST NOT already exist
// - THE COMMIT of the whole creation transaction. It never replaces and
// never merges
// - Windows: MoveFileExW without MOVEFILE_REPLACE_EXISTING is exclusive in
// the kernel, so there is no window at all
// - POSIX: rename(2) has no portable no-replace form, so the destination is
// lstat'ed immediately before. The residual is bounded and recorded: an
// EMPTY directory created inside that window would be replaced; anything
// holding data cannot be, because rename onto a non-empty directory is
// ENOTEMPTY and onto a file is ENOTDIR
function PWebCliRenameDir(const FromDir, ToDir: RawUtf8): Boolean;

/// atomically replace ONE file with another in the same directory
// - the ONLY replacing primitive in this unit, and it exists for exactly
// one caller: the BUILD-TIME template-pack writer, whose output is a
// regenerated artifact under build/. Project creation never replaces
// anything - see PWebCliRenameDir, which deliberately cannot
// - Windows: MOVEFILE_REPLACE_EXISTING. POSIX: rename(2) over a regular
// file, which POSIX defines as atomic
function PWebCliReplaceFile(const FromPath, ToPath: RawUtf8): Boolean;

/// recursively remove a tree this process staged, and ONLY such a tree
// - Parent must be a canonical directory and Name a single component; the
// target is re-resolved through PWebCliEntry (exact on-disk spelling) and
// must be a real directory, never a link
// - a link, a device or anything unremovable anywhere in the tree ABORTS
// the walk and returns False with the rest left alone: an unbounded
// recursive delete that can be aimed is a delete primitive, and this one is
// deliberately not one
function PWebCliRemoveStagedTree(const Parent, Name: RawUtf8): Boolean;

/// the PATH search directories, in order
// - EMPTY entries are dropped and never treated as the working directory,
// which POSIX would otherwise permit: the CLI must never execute something
// merely because of where it was invoked from
function PWebCliPathDirs: TRawUtf8DynArray;

/// find ONE executable called Tool inside a canonical directory, using this
/// platform's own rules for what "executable" and "called Tool" mean
// - Windows appends each PATHEXT extension in PATHEXT order and matches the
// name case-insensitively, because that is what the operating system itself
// does; RealPath comes back with the TRUE on-disk spelling, so what is
// reported is what would run
// - POSIX matches the name byte-exactly, read from the directory, so a
// case-folding volume cannot resolve 'Node', and then requires a regular
// file with the execute bit for this process
// - a SYMLINK is followed here, deliberately. Refusing links is a
// CONFINEMENT rule and belongs to project paths; on PATH nearly every
// package-managed tool is a link, and refusing those would refuse every
// ordinary install rather than any attack
// - a directory is never executable, whatever it is called
function PWebCliFindExecutable(const Dir, Tool: RawUtf8;
  out RealPath: RawUtf8): Boolean;

/// the host WebView engine, measured through the ratified detector of each
// platform - never reimplemented here
function PWebCliEngine: TPWebCliEngineFact;


{ ---------------------------------------------------------------------------
  CHILD PROCESSES (CAP-10C0)

  The raw primitives under the ONE execution engine in pweb.cli.process.
  Nothing here decides anything: the engine owns the drain loop, the bounds,
  the graceful-then-forced escalation and the outcome typing, and these
  functions are the platform's verbs for it - spawn, read, poll, wait, stop,
  kill, enumerate, release.

  Windows: CreateProcessW from an explicitly quoted command line the engine
  built, stdio inheritance restricted to exactly three handles, the child
  created SUSPENDED, placed in a fresh Job Object carrying
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, then resumed - so every descendant is
  a job member and the whole tree dies with the supervisor's last handle,
  whether the supervisor exits, is killed, or crashes. MEASURED on the dev
  host before this shard was planned: six WebView2 processes spawned by a
  generated host were inside the job, the six unrelated Evergreen processes
  on the machine were not, and the job was empty 254 ms after the host
  exited.

  POSIX: fork + setpgid(0,0) + execve with the argument vector, so the child
  leads a process group of its own and the group is what SIGTERM and SIGKILL
  are sent to. Exec failure travels back through a close-on-exec pipe, so a
  path that exists but cannot run is a typed spawn failure rather than an
  exit code 127 that looks like the application's own. Every child is
  reaped through waitpid; on Linux PR_SET_PDEATHSIG additionally kills the
  direct child if the supervisor dies without a chance to signal the group.
  --------------------------------------------------------------------------- }

type
  /// one child process this CLI started, owned by the platform seam
  // - opaque to every other unit: the fields are handles and pids and
  // nothing outside this unit interprets them
  TPWebCliChild = record
    /// the child's process id
    Pid: PtrInt;
    /// POSIX: the process group the child leads; Windows: 0
    Group: PtrInt;
    /// Windows: the process handle; POSIX: 0
    Handle: PtrUInt;
    /// Windows: the Job Object every descendant belongs to; POSIX: 0
    Job: PtrUInt;
    /// the supervisor's read ends of the child's stdout and stderr
    OutRead: PtrInt;
    ErrRead: PtrInt;
    /// True until PWebCliChildWait has reaped the child
    Running: Boolean;
    /// the exit code, meaningful when Running = False and Signal = 0
    ExitCode: Integer;
    /// POSIX: the terminating signal when Running = False; Windows: 0
    Signal: Integer;
  end;

  /// why a spawn produced no running child - machine-stable, one cause each
  TPWebCliSpawnFailure = (
    psfNone,
    /// the stdio pipes or the NUL / /dev/null stdin could not be created
    psfPipes,
    /// Windows: the Job Object could not be created, configured, or the
    // child could not be assigned to it
    psfJobObject,
    /// CreateProcessW / fork failed
    psfCreate,
    /// POSIX: exec failed after fork; the child reported it and was reaped
    psfExec,
    /// the working directory could not be entered
    psfWorkDir);

  /// one process observed inside the supervised tree
  TPWebCliTreeMember = record
    Pid: PtrInt;
    ParentPid: PtrInt;
    /// the canonical image path, or '' when it could not be read - never
    // guessed, never derived from a name
    Image: RawUtf8;
  end;
  TPWebCliTreeMembers = array of TPWebCliTreeMember;

  TPWebCliChildStream = (pcsStdOut, pcsStdErr);

/// fixed text for a spawn failure
function PWebCliSpawnFailureText(Failure: TPWebCliSpawnFailure): RawUtf8;

/// start ONE child: exact executable path, argument vector, explicit working
/// directory, stdin from NUL / /dev/null, stdout and stderr piped back
// - Args is the vector AFTER argv[0]; the engine has already refused NUL,
// invalid UTF-8 and batch-file executables
// - SeparateConsole (Windows only, ignored elsewhere) gives the child a
// console of its own; used by the CAP-10C0 stop-signal test driver so a
// console control event has a console to travel through, never by a
// public command
function PWebCliChildSpawn(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray; const WorkDir: RawUtf8;
  SeparateConsole: Boolean; out Child: TPWebCliChild;
  out Failure: TPWebCliSpawnFailure; out OsError: Integer): Boolean;

/// read what is available RIGHT NOW from one stream, never blocking
// - > 0: bytes stored in Buf; 0: nothing available; -1: the stream is closed
function PWebCliChildRead(var Child: TPWebCliChild;
  Stream: TPWebCliChildStream; Buf: Pointer; Cap: PtrInt): PtrInt;

/// block for at most TimeoutMs until the child may have exited or produced
/// output (POSIX: poll on both pipes; Windows: wait on the process handle)
procedure PWebCliChildPoll(var Child: TPWebCliChild; TimeoutMs: Cardinal);

/// reap the child if it has exited, without blocking
// - True when Running became False; ExitCode / Signal are then set
function PWebCliChildWait(var Child: TPWebCliChild): Boolean;

/// ask the tree to stop gracefully
// - Windows: WM_CLOSE posted to every VISIBLE top-level window owned by the
// child pid; returns how many were posted (0 = no window yet, retry)
// - POSIX: SIGTERM to the process group; returns 1 on success
function PWebCliChildStop(var Child: TPWebCliChild): Integer;

/// terminate the whole tree at once - the bounded last resort
// - Windows: TerminateJobObject; POSIX: SIGKILL to the process group
function PWebCliChildKill(var Child: TPWebCliChild): Boolean;

/// every process currently belonging to the tree, by MEMBERSHIP only
// - Windows: the Job Object's process id list; POSIX: every process whose
// pgid is the child's group. The child itself is included while it lives
// - Image is read per member and left '' when unreadable
function PWebCliChildMembers(const Child: TPWebCliChild): TPWebCliTreeMembers;

/// close every handle and descriptor; the record is unusable afterwards
// - Windows: closing the Job Object handle kills any member still alive
// (KILL_ON_JOB_CLOSE) - by then the engine has drained or killed them
procedure PWebCliChildRelease(var Child: TPWebCliChild);

/// route Ctrl+C / Ctrl+Break (Windows) or SIGINT / SIGTERM / SIGHUP (POSIX)
/// into PWebCliStopRequested instead of the default termination
// - Windows also re-enables Ctrl+C for this process, which a parent may
// have disabled by creating it in a new process group
// - POSIX also ignores SIGPIPE so a closed forwarding target is an error
// the engine sees rather than a signal that kills the supervisor
function PWebCliInstallStopHandler: Boolean;

/// True once a stop signal has been received; never reset
function PWebCliStopRequested: Boolean;

/// the tree-ownership model of this platform: 'job_object' or 'process_group'
function PWebCliTreeModelText: RawUtf8;

/// True while a process with that id exists (a query, never a signal)
// - test evidence only: the CLI itself decides nothing from it
function PWebCliPidAlive(Pid: PtrInt): Boolean;

/// the Windows command line for (ExePath, Args), quoted by the msvcrt /
/// CommandLineToArgvW rules so the child's argv is byte-for-byte Args
// - platform-free on purpose: it is a pure string function, proven by a
// golden table on all four targets and by a round-trip against a real
// child on Windows, and it is the ONLY place a command line is ever built
function PWebCliWindowsCommandLine(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray): RawUtf8;

implementation

uses
  mormot.core.os,
  {$ifdef WINDOWS}
  windows,
  pweb.platform.webview2.runtime;
  {$else}
  baseunix,
  unix,
  dynlibs;
  {$endif WINDOWS}

const
  PWEB_CLI_ENGINE_LINUX =
    'libwebkit2gtk-4.1.so.0 and libgtk-3.so.0 loadable by the dynamic linker';
  PWEB_CLI_ENGINE_MACOS =
    'macOS >= 12.0 with the system WebKit framework present';

{ ---------------------------------------------------------------------------
  host identity - compile-time, because the CLI is always native
  --------------------------------------------------------------------------- }

function PWebCliHostOs: TPWebCliOs;
begin
  {$ifdef WINDOWS}
  Result := pcoWindows;
  {$else}
  {$ifdef DARWIN}
  Result := pcoMacos;
  {$else}
  Result := pcoLinux;
  {$endif DARWIN}
  {$endif WINDOWS}
end;

function PWebCliHostOsText: RawUtf8;
begin
  case PWebCliHostOs of
    pcoWindows: Result := 'windows';
    pcoMacos:   Result := 'macos';
  else
    Result := 'linux';
  end;
end;

function PWebCliHostArch: TPWebCliArch;
begin
  {$ifdef CPUX86_64}
  Result := pcaX86_64;
  {$else}
  {$ifdef CPUAARCH64}
  Result := pcaArm64;
  {$else}
  Result := pcaOther;
  {$endif CPUAARCH64}
  {$endif CPUX86_64}
end;

function PWebCliHostArchText: RawUtf8;
begin
  case PWebCliHostArch of
    pcaX86_64: Result := 'x86_64';
    pcaArm64:  Result := 'arm64';
  else
    Result := 'other';
  end;
end;

function PWebCliOsRelease: RawUtf8;
begin
  // mORMot's own host description: diagnostic evidence, never a compared
  // field (it differs by machine and by image, which is the whole reason
  // the four-target corpus types it as an observation)
  Result := OSVersionText;
  if Result = '' then
    Result := PWebCliHostOsText;
end;

{ ---------------------------------------------------------------------------
  WINDOWS BODY
  --------------------------------------------------------------------------- }

{$ifdef WINDOWS}

const
  PWEB_LONGPATH_PREFIX = '\\?\';
  PWEB_CLI_UTF8_CP = 65001;
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;
  FILE_ADD_FILE = $0002;
  FILE_ADD_SUBDIRECTORY = $0004;
  // absent from the FPC 3.2.2 windows unit; winnt.h
  FILE_FLAG_OPEN_REPARSE_POINT = $00200000;

// Vista+, absent from the FPC 3.2.2 windows unit (the same declaration
// pweb.assets.folder carries, for the same reason)
function GetFinalPathNameByHandleW(hFile: THandle; lpszFilePath: PWideChar;
  cchFilePath: DWORD; dwFlags: DWORD): DWORD;
  stdcall; external 'kernel32.dll' name 'GetFinalPathNameByHandleW';

// the ONLY shell32 import in the CLI, and it parses rather than executes:
// CommandLineToArgvW splits a command line into argv exactly as the C
// runtime does. Nothing here launches anything.
function CommandLineToArgvW(lpCmdLine: PWideChar;
  var pNumArgs: Integer): PPWideChar;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

function W(const S: RawUtf8): SynUnicode; inline;
begin
  Result := Utf8ToSynUnicode(S);
end;

function U(const S: SynUnicode): RawUtf8; inline;
begin
  Result := SynUnicodeToUtf8(S);
end;

function FinalPathOfHandle(h: THandle): SynUnicode;
var
  len: DWORD;
begin
  Result := '';
  len := GetFinalPathNameByHandleW(h, nil, 0, 0);
  if len = 0 then
    exit;
  SetLength(Result, len);
  len := GetFinalPathNameByHandleW(h, PWideChar(Result), len, 0);
  if (len = 0) or
     (len >= DWORD(Length(Result))) then
  begin
    Result := '';
    exit;
  end;
  SetLength(Result, len);
end;

function WideEquals(P: PWideChar; const S: SynUnicode): Boolean;
var
  i, len: PtrInt;
begin
  Result := False;
  len := Length(S);
  for i := 1 to len do
    if (P^ = #0) or
       (P^ <> S[i]) then
      exit
    else
      Inc(P);
  Result := P^ = #0;
end;

function PWebCliOsProductVersion(out Version: RawUtf8): Boolean;
begin
  // Windows publishes no version this CLI compares anything against: the
  // ratified floor is the WebView2 runtime build, measured by the CAP-6b0
  // detector, not the OS build number. Returning False is the honest answer.
  Version := '';
  Result := False;
end;

function PWebCliRawArgs: TRawUtf8DynArray;
var
  argv: PPWideChar;
  n, i: Integer;
  p: PPWideChar;
begin
  Result := nil;
  n := 0;
  argv := CommandLineToArgvW(GetCommandLineW, n);
  if (argv = nil) or
     (n <= 1) then
  begin
    if argv <> nil then
      LocalFree(HLOCAL(argv));
    exit;
  end;
  try
    SetLength(Result, n - 1);
    for i := 1 to n - 1 do
    begin
      p := argv;
      Inc(p, i);
      Result[i - 1] := U(SynUnicode(WideString(p^)));
    end;
  finally
    LocalFree(HLOCAL(argv));
  end;
end;

var
  ConsoleProbed: Boolean;
  ConsoleIsTty: Boolean;
  ConsoleAnsi: Boolean;

procedure ProbeConsole;
var
  h: THandle;
  mode: DWORD;
begin
  if ConsoleProbed then
    exit;
  ConsoleProbed := True;
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  if (h = 0) or
     (h = INVALID_HANDLE_VALUE) then
    exit;
  mode := 0;
  // GetConsoleMode succeeds on a console handle and fails on a file or a
  // pipe: that IS the redirection test, with no guessing about TERM
  if not GetConsoleMode(h, mode) then
    exit;
  ConsoleIsTty := True;
  ConsoleAnsi := SetConsoleMode(h, mode or
    ENABLE_VIRTUAL_TERMINAL_PROCESSING);
end;

function PWebCliStdOutIsTerminal: Boolean;
begin
  ProbeConsole;
  Result := ConsoleIsTty;
end;

procedure PWebCliPrepareConsole;
begin
  ProbeConsole;
  if ConsoleIsTty then
    // so a path or a project name outside ASCII renders instead of turning
    // into question marks; a console that refuses simply stays as it was
    SetConsoleOutputCP(PWEB_CLI_UTF8_CP);
end;

function PWebCliAnsiSupported: Boolean;
begin
  ProbeConsole;
  Result := ConsoleIsTty and ConsoleAnsi;
end;

function PWebCliCanonicalDir(const Dir: RawUtf8;
  out Canonical: RawUtf8): Boolean;
var
  h: THandle;
  resolved: SynUnicode;
begin
  Result := False;
  Canonical := '';
  if Dir = '' then
    exit;
  h := CreateFileW(PWideChar(W(Dir)), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    if (GetFileAttributesW(PWideChar(W(Dir))) and
        FILE_ATTRIBUTE_DIRECTORY) = 0 then
      exit;
    resolved := FinalPathOfHandle(h);
  finally
    CloseHandle(h);
  end;
  if resolved = '' then
    exit;
  Canonical := U(resolved);
  Result := Canonical <> '';
end;

function PWebCliCwd(out Dir: RawUtf8): Boolean;
var
  buf: SynUnicode;
  len: DWORD;
begin
  Dir := '';
  Result := False;
  len := GetCurrentDirectoryW(0, nil);
  if len = 0 then
    exit;
  SetLength(buf, len);
  len := GetCurrentDirectoryW(len, PWideChar(buf));
  if (len = 0) or
     (len >= DWORD(Length(buf) + 1)) then
    exit;
  SetLength(buf, len);
  Result := PWebCliCanonicalDir(U(buf), Dir);
end;

function PWebCliParentDir(const Dir: RawUtf8; out Parent: RawUtf8): Boolean;
var
  i, floor: PtrInt;
begin
  Parent := '';
  Result := False;
  // '\\?\C:\a\b' -> '\\?\C:\a'; the floor is the volume root '\\?\C:\',
  // which has no parent. A UNC canonical form ('\\?\UNC\server\share')
  // bottoms out at the share for the same reason.
  if Copy(Dir, 1, 8) = PWEB_LONGPATH_PREFIX + 'UNC' then
    floor := 4 + 4
  else
    floor := 4 + 3; // '\\?\' + 'C:\'
  if Length(Dir) <= floor then
    exit;
  i := Length(Dir);
  while (i > 0) and
        (Dir[i] <> '\') do
    Dec(i);
  if i <= floor then
    exit;
  Parent := Copy(Dir, 1, i - 1);
  Result := Parent <> '';
end;

function PWebCliJoin(const Dir, Name: RawUtf8): RawUtf8;
begin
  if Dir = '' then
    Result := Name
  else if Dir[Length(Dir)] = '\' then
    Result := Dir + Name
  else
    Result := Dir + '\' + Name;
end;

function PWebCliDisplayPath(const Path: RawUtf8): RawUtf8;
begin
  Result := Path;
  if Copy(Result, 1, 8) = PWEB_LONGPATH_PREFIX + 'UNC' then
    Result := '\\' + Copy(Result, 9, MaxInt)
  else if Copy(Result, 1, 4) = PWEB_LONGPATH_PREFIX then
    Result := Copy(Result, 5, MaxInt);
end;

function IsAbsoluteW(const Path: RawUtf8): Boolean;
begin
  Result := (Copy(Path, 1, 4) = PWEB_LONGPATH_PREFIX) or
    ((Length(Path) >= 2) and (Path[2] = ':')) or
    ((Length(Path) >= 2) and
     ((Path[1] = '\') or (Path[1] = '/')) and
     ((Path[2] = '\') or (Path[2] = '/')));
end;

function PWebCliAbsolute(const Base, Path: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := Path;
  for i := 1 to Length(Result) do
    if Result[i] = '/' then
      Result[i] := '\'; // one separator from here on
  while (Length(Result) > 3) and
        (Result[Length(Result)] = '\') do
    SetLength(Result, Length(Result) - 1);
  if (Result <> '') and
     not IsAbsoluteW(Result) then
    Result := PWebCliJoin(Base, Result);
end;

function PWebCliSplitLast(const Path: RawUtf8;
  out Parent, Name: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Parent := '';
  Name := '';
  Result := False;
  i := Length(Path);
  while (i > 0) and
        (Path[i] <> '\') and
        (Path[i] <> '/') do
    Dec(i);
  if (i <= 0) or
     (i = Length(Path)) then
    exit;
  Parent := Copy(Path, 1, i - 1);
  Name := Copy(Path, i + 1, MaxInt);
  // 'C:' alone is not a directory a walk can start from
  if (Length(Parent) = 2) and (Parent[2] = ':') then
    Parent := Parent + '\';
  Result := (Parent <> '') and (Name <> '');
end;

function KindOfAttributes(Attrs: DWORD): TPWebCliNodeKind;
begin
  if Attrs = INVALID_FILE_ATTRIBUTES then
    Result := pcnMissing
  else if (Attrs and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
    Result := pcnLink
  else if (Attrs and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
    Result := pcnDirectory
  else
    Result := pcnFile;
end;

function PWebCliEntry(const Dir, Name: RawUtf8): TPWebCliNodeKind;
var
  h: THandle;
  data: TWin32FindDataW;
  nameW: SynUnicode;
begin
  Result := pcnMissing;
  nameW := W(Name);
  if (Dir = '') or
     (nameW = '') then
    exit;
  h := FindFirstFileW(PWideChar(W(PWebCliJoin(Dir, Name))), data{%H-});
  if h = INVALID_HANDLE_VALUE then
    exit;
  windows.FindClose(h);
  // the directory's own spelling is the truth: a case variant on a
  // case-insensitive volume, or an 8.3 alias, is a MISS
  if not WideEquals(@data.cFileName[0], nameW) then
    exit;
  Result := KindOfAttributes(data.dwFileAttributes);
end;

function PWebCliNodeKind(const Path: RawUtf8): TPWebCliNodeKind;
begin
  if Path = '' then
    Result := pcnMissing
  else
    Result := KindOfAttributes(GetFileAttributesW(PWideChar(W(Path))));
end;

function PWebCliDirWritable(const Dir: RawUtf8): Boolean;
var
  h: THandle;
begin
  // the ACL question, asked and not simulated: opening a DIRECTORY handle
  // for FILE_ADD_FILE performs the access check and creates nothing
  h := CreateFileW(PWideChar(W(Dir)), FILE_ADD_FILE or FILE_ADD_SUBDIRECTORY,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  Result := h <> INVALID_HANDLE_VALUE;
  if Result then
    CloseHandle(h);
end;

function PWebCliReadSmallFile(const Path: RawUtf8; MaxBytes: PtrInt;
  out Content: RawByteString; out TooBig: Boolean): Boolean;
var
  h: THandle;
  lo, hi, rd: DWORD;
  size, done: Int64;
begin
  Result := False;
  TooBig := False;
  Content := '';
  if PWebCliNodeKind(Path) <> pcnFile then
    exit; // a link, a directory or nothing at all is never read
  h := CreateFileW(PWideChar(W(Path)), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    // FILE_FLAG_OPEN_REPARSE_POINT is what makes a component swapped for a
    // link between the check and the open FAIL instead of resolving
    // elsewhere; a filesystem that refuses the flag refuses the read
    h := INVALID_HANDLE_VALUE;
    exit;
  end;
  try
    hi := 0;
    lo := windows.GetFileSize(h, @hi);
    if (lo = INVALID_FILE_SIZE) and
       (GetLastError <> NO_ERROR) then
      exit;
    size := (Int64(hi) shl 32) or lo;
    if size < 0 then
      exit;
    if size > MaxBytes then
    begin
      TooBig := True;
      exit;
    end;
    SetLength(Content, size);
    done := 0;
    while done < size do
    begin
      rd := 0;
      if not ReadFile(h, PByteArray(Content)^[done],
           DWORD(size - done), rd, nil) or
         (rd = 0) then
      begin
        Content := '';
        exit;
      end;
      Inc(done, rd);
    end;
    Result := True;
  finally
    CloseHandle(h);
  end;
end;

function PWebCliListDir(const Dir: RawUtf8;
  out Names: TRawUtf8DynArray): Boolean;
var
  h: THandle;
  data: TWin32FindDataW;
  n: PtrInt;
  name: RawUtf8;
begin
  Names := nil;
  Result := False;
  if Dir = '' then
    exit;
  n := 0;
  h := FindFirstFileW(PWideChar(W(PWebCliJoin(Dir, '*'))), data{%H-});
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    repeat
      name := U(SynUnicode(WideString(PWideChar(@data.cFileName[0]))));
      if (name <> '.') and
         (name <> '..') and
         (name <> '') then
      begin
        SetLength(Names, n + 1);
        Names[n] := name;
        Inc(n);
      end;
    until not FindNextFileW(h, data);
    // a mid-enumeration failure must never look like the end of the
    // directory: the only legitimate exit is "no more files"
    Result := GetLastError = ERROR_NO_MORE_FILES;
  finally
    windows.FindClose(h);
  end;
  if not Result then
    Names := nil;
end;

function PWebCliHasFileModes: Boolean;
begin
  Result := False;
end;

function PWebCliExecutableBit(const Path: RawUtf8): Boolean;
begin
  Result := False; // NTFS carries no such bit; the caller records that
end;

function PWebCliCreateDir(const Dir: RawUtf8): Boolean;
begin
  // CreateDirectoryW fails when the name is taken by ANYTHING - a file, a
  // directory, a junction - so the exclusivity is the kernel's
  Result := (Dir <> '') and
    CreateDirectoryW(PWideChar(W(Dir)), nil);
end;

function PWebCliWriteNewFile(const Path: RawUtf8;
  const Content: RawByteString; SetExecBit: Boolean): Boolean;
var
  h: THandle;
  wr: DWORD;
  done: PtrInt;
begin
  Result := False;
  if Path = '' then
    exit;
  // CREATE_NEW is the atomic "create or fail"; no sharing while we write;
  // FILE_FLAG_OPEN_REPARSE_POINT so a name swapped for a link cannot
  // resolve somewhere else even in the branch where it already existed
  h := CreateFileW(PWideChar(W(Path)), GENERIC_WRITE, 0, nil, CREATE_NEW,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    done := 0;
    while done < Length(Content) do
    begin
      wr := 0;
      if not WriteFile(h, PByteArray(Content)^[done],
           DWORD(Length(Content) - done), wr, nil) or
         (wr = 0) then
        exit;
      Inc(done, wr);
    end;
    Result := True;
  finally
    CloseHandle(h);
  end;
end;

function PWebCliDeleteFile(const Path: RawUtf8): Boolean;
begin
  // only a REGULAR file: a directory or a reparse point is refused, so the
  // cleanup can never follow something out of the staged tree
  Result := (PWebCliNodeKind(Path) = pcnFile) and
    DeleteFileW(PWideChar(W(Path)));
end;

function PWebCliRemoveEmptyDir(const Dir: RawUtf8): Boolean;
begin
  Result := (PWebCliNodeKind(Dir) = pcnDirectory) and
    RemoveDirectoryW(PWideChar(W(Dir)));
end;

function PWebCliRenameDir(const FromDir, ToDir: RawUtf8): Boolean;
begin
  // NO MOVEFILE_REPLACE_EXISTING: an existing destination fails the call in
  // the kernel, which is exactly the guarantee the transaction needs and
  // leaves no window between a check and the commit
  Result := (FromDir <> '') and
    (ToDir <> '') and
    MoveFileExW(PWideChar(W(FromDir)), PWideChar(W(ToDir)), 0);
end;

function PWebCliReplaceFile(const FromPath, ToPath: RawUtf8): Boolean;
begin
  Result := (FromPath <> '') and
    (ToPath <> '') and
    MoveFileExW(PWideChar(W(FromPath)), PWideChar(W(ToPath)),
      MOVEFILE_REPLACE_EXISTING);
end;

function SplitEnvList(const Value: RawUtf8; Sep: AnsiChar): TRawUtf8DynArray;
var
  i, start, n: PtrInt;
  item: RawUtf8;
begin
  Result := nil;
  n := 0;
  start := 1;
  for i := 1 to Length(Value) + 1 do
    if (i > Length(Value)) or
       (Value[i] = Sep) then
    begin
      item := Copy(Value, start, i - start);
      // an EMPTY entry means the working directory on both families, and
      // the CLI must never execute something because of where it was run
      if item <> '' then
      begin
        SetLength(Result, n + 1);
        Result[n] := item;
        Inc(n);
      end;
      start := i + 1;
    end;
end;

// the wide environment reader: the Ansi form would fold a non-ACP PATH
// entry into question marks, which is the same class of defect that put
// every other Windows filesystem call in this file on the wide API
function EnvW(const Name: RawUtf8): RawUtf8;
var
  nameW, buf: SynUnicode;
  len: DWORD;
begin
  Result := '';
  nameW := W(Name);
  len := GetEnvironmentVariableW(PWideChar(nameW), nil, 0);
  if len = 0 then
    exit;
  SetLength(buf, len);
  len := GetEnvironmentVariableW(PWideChar(nameW), PWideChar(buf), len);
  if (len = 0) or
     (len > DWORD(Length(buf))) then
    exit;
  SetLength(buf, len);
  Result := U(buf);
end;

function PWebCliPathDirs: TRawUtf8DynArray;
begin
  Result := SplitEnvList(EnvW('PATH'), ';');
end;

function PWebCliFindExecutable(const Dir, Tool: RawUtf8;
  out RealPath: RawUtf8): Boolean;
var
  exts: TRawUtf8DynArray;
  i: PtrInt;
  raw: RawUtf8;
  h: THandle;
  data: TWin32FindDataW;
begin
  Result := False;
  RealPath := '';
  raw := EnvW('PATHEXT');
  if raw = '' then
    // the documented Windows default, spelled here so an emptied PATHEXT
    // cannot make every tool invisible
    raw := '.COM;.EXE;.BAT;.CMD';
  exts := SplitEnvList(raw, ';');
  // ONLY the extension forms. Windows does not execute an extension-less
  // file for a name given without one - which is exactly why an nvm
  // installation's extension-less `npm` shell script must not be selected
  // ahead of npm.cmd. PATHEXT is conventionally UPPERCASE and the files are
  // lowercase, so the match is case-insensitive here: that is the operating
  // system's own rule for executables, not a relaxation of the exact-case
  // rule that governs project paths.
  for i := 0 to High(exts) do
  begin
    h := FindFirstFileW(PWideChar(W(PWebCliJoin(Dir, Tool + exts[i]))),
      data{%H-});
    if h = INVALID_HANDLE_VALUE then
      continue;
    windows.FindClose(h);
    if (data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      continue;
    // cFileName carries the TRUE on-disk spelling, so the path this CLI
    // reports is the path that would run
    RealPath := PWebCliJoin(Dir,
      U(SynUnicode(WideString(PWideChar(@data.cFileName[0])))));
    exit(True);
  end;
end;

function PWebCliEngine: TPWebCliEngineFact;
var
  detection: TPWebWv2DetectionResult;
begin
  // the minimum build is NEVER re-spelled here: it comes from the ratified
  // CAP-6b0 detector, which is also what decides usability below. Two
  // spellings of one threshold is how a doctor starts disagreeing with the
  // runtime it is supposed to describe.
  Result.Expected := 'WebView2 Evergreen runtime, build >= ' +
    RawUtf8(IntToStr(PWEB_WV2_MIN_BUILD));
  // the CAP-6b0 detector is the source of truth for BOTH the probe and the
  // minimum-build policy; this function converts its verdict and never
  // forms one of its own
  detection := PWebWv2Detect;
  Result.Usable := PWebWv2DetectionUsable(detection);
  Result.Category := PWebWv2StatusText(detection.Status);
  if detection.RawVersion <> '' then
    Result.Observed := detection.RawVersion
  else
    Result.Observed := Result.Category;
  if Result.Usable then
    Result.Category := 'usable'
  else if detection.Status = wv2dsAvailable then
    // present but below the CAP-4W loader minimum, or unparseable: a
    // distinct cause from absent, and it must not read as the same row
    Result.Category := 'version_unusable';
end;

{ ---------------------------------------------------------------------------
  child processes - Windows: CreateProcessW + Job Object
  --------------------------------------------------------------------------- }

const
  PWEB_CREATE_SUSPENDED = $00000004;
  PWEB_CREATE_NEW_CONSOLE = $00000010;
  PWEB_CREATE_NEW_PROCESS_GROUP = $00000200;
  PWEB_CREATE_UNICODE_ENVIRONMENT = $00000400;
  PWEB_EXTENDED_STARTUPINFO_PRESENT = $00080000;
  PWEB_PROC_THREAD_ATTRIBUTE_HANDLE_LIST = $00020002;
  PWEB_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = $00002000;
  PWEB_JobObjectBasicProcessIdList = 3;
  PWEB_JobObjectExtendedLimitInformation = 9;
  PWEB_PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  PWEB_ERROR_BROKEN_PIPE = 109;
  PWEB_ERROR_MORE_DATA = 234;
  PWEB_WM_CLOSE = $0010;
  PWEB_CTRL_C_EVENT = 0;
  PWEB_CTRL_BREAK_EVENT = 1;
  PWEB_CTRL_CLOSE_EVENT = 2;
  // the sizes the kernel expects for the two job structures on x64,
  // checked at run time against the records below rather than trusted
  PWEB_JOB_EXT_LIMIT_BYTES = 144;
  PWEB_PROCESS_BASIC_INFO_BYTES = 48;
  PWEB_JOB_PID_LIST_FIRST = 256;
  PWEB_JOB_PID_LIST_MAX = 4096;

type
  TPWebJobBasicLimit = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: PtrUInt;
    MaximumWorkingSetSize: PtrUInt;
    ActiveProcessLimit: DWORD;
    Affinity: PtrUInt;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;
  TPWebIoCounters = record
    ReadOperationCount: QWord;
    WriteOperationCount: QWord;
    OtherOperationCount: QWord;
    ReadTransferCount: QWord;
    WriteTransferCount: QWord;
    OtherTransferCount: QWord;
  end;
  TPWebJobExtendedLimit = record
    Basic: TPWebJobBasicLimit;
    Io: TPWebIoCounters;
    ProcessMemoryLimit: PtrUInt;
    JobMemoryLimit: PtrUInt;
    PeakProcessMemoryUsed: PtrUInt;
    PeakJobMemoryUsed: PtrUInt;
  end;
  TPWebProcessBasicInformation = record
    ExitStatus: LongInt;
    PebBaseAddress: Pointer;
    AffinityMask: PtrUInt;
    BasePriority: LongInt;
    UniqueProcessId: PtrUInt;
    InheritedFromUniqueProcessId: PtrUInt;
  end;
  TPWebStartupInfoExW = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: Pointer;
  end;

// Vista+ / absent from the FPC 3.2.2 windows unit
function CreateJobObjectW(lpJobAttributes: PSecurityAttributes;
  lpName: PWideChar): THandle;
  stdcall; external 'kernel32.dll' name 'CreateJobObjectW';
function SetInformationJobObject(hJob: THandle; JobObjectInformationClass: Integer;
  lpJobObjectInformation: Pointer; cbJobObjectInformationLength: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'SetInformationJobObject';
function QueryInformationJobObject(hJob: THandle;
  JobObjectInformationClass: Integer; lpJobObjectInformation: Pointer;
  cbJobObjectInformationLength: DWORD; lpReturnLength: PDWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'QueryInformationJobObject';
function AssignProcessToJobObject(hJob, hProcess: THandle): BOOL;
  stdcall; external 'kernel32.dll' name 'AssignProcessToJobObject';
function TerminateJobObject(hJob: THandle; uExitCode: UINT): BOOL;
  stdcall; external 'kernel32.dll' name 'TerminateJobObject';
function InitializeProcThreadAttributeList(lpAttributeList: Pointer;
  dwAttributeCount, dwFlags: DWORD; var lpSize: SIZE_T): BOOL;
  stdcall; external 'kernel32.dll' name 'InitializeProcThreadAttributeList';
function UpdateProcThreadAttribute(lpAttributeList: Pointer; dwFlags: DWORD;
  Attribute: PtrUInt; lpValue: Pointer; cbSize: SIZE_T;
  lpPreviousValue: Pointer; lpReturnSize: PSIZE_T): BOOL;
  stdcall; external 'kernel32.dll' name 'UpdateProcThreadAttribute';
procedure DeleteProcThreadAttributeList(lpAttributeList: Pointer);
  stdcall; external 'kernel32.dll' name 'DeleteProcThreadAttributeList';
function QueryFullProcessImageNameW(hProcess: THandle; dwFlags: DWORD;
  lpExeName: PWideChar; var lpdwSize: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'QueryFullProcessImageNameW';
// the parent pid of an arbitrary process, asked of the kernel directly: a
// QUERY on one handle, never an enumeration by name
function NtQueryInformationProcess(ProcessHandle: THandle;
  ProcessInformationClass: Integer; ProcessInformation: Pointer;
  ProcessInformationLength: ULONG; ReturnLength: PULONG): LongInt;
  stdcall; external 'ntdll.dll' name 'NtQueryInformationProcess';

procedure CloseIf(var H: THandle);
begin
  if (H <> 0) and
     (H <> INVALID_HANDLE_VALUE) then
    CloseHandle(H);
  H := 0;
end;

function PWebCliChildSpawn(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray; const WorkDir: RawUtf8;
  SeparateConsole: Boolean; out Child: TPWebCliChild;
  out Failure: TPWebCliSpawnFailure; out OsError: Integer): Boolean;
var
  sa: TSecurityAttributes;
  outRead, outWrite, errRead, errWrite, nulIn, job: THandle;
  handles: array[0 .. 2] of THandle;
  attrSize: SIZE_T;
  attrList: Pointer;
  six: TPWebStartupInfoExW;
  pi: TProcessInformation;
  limit: TPWebJobExtendedLimit;
  exeW, cmdW, dirW: SynUnicode;
  flags: DWORD;
begin
  Result := False;
  Child := Default(TPWebCliChild);
  Failure := psfNone;
  OsError := 0;
  outRead := 0; outWrite := 0; errRead := 0; errWrite := 0;
  nulIn := 0; job := 0;
  attrList := nil;
  FillChar(pi, SizeOf(pi), 0);
  // the working directory is a precondition, refused before anything is
  // created: CreateProcessW would fail with an error that names nothing
  if PWebCliNodeKind(WorkDir) <> pcnDirectory then
  begin
    Failure := psfWorkDir;
    exit;
  end;
  if SizeOf(limit) <> PWEB_JOB_EXT_LIMIT_BYTES then
  begin
    Failure := psfJobObject; // the record does not match the kernel's shape
    exit;
  end;
  FillChar(sa, SizeOf(sa), 0);
  sa.nLength := SizeOf(sa);
  sa.bInheritHandle := True;
  try
    // --- the three stdio handles, and ONLY those are inheritable ------------
    if not CreatePipe(outRead, outWrite, @sa, 0) or
       not CreatePipe(errRead, errWrite, @sa, 0) then
    begin
      OsError := GetLastError;
      Failure := psfPipes;
      exit;
    end;
    // the supervisor's own read ends must not leak into the child, or the
    // child would hold its own pipe open and EOF could never arrive
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(errRead, HANDLE_FLAG_INHERIT, 0);
    nulIn := CreateFileW('NUL', GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @sa, OPEN_EXISTING, 0, 0);
    if nulIn = INVALID_HANDLE_VALUE then
    begin
      OsError := GetLastError;
      nulIn := 0;
      Failure := psfPipes;
      exit;
    end;
    // --- the Job Object, created and configured BEFORE the child exists ----
    job := CreateJobObjectW(nil, nil);
    if job = 0 then
    begin
      OsError := GetLastError;
      Failure := psfJobObject;
      exit;
    end;
    FillChar(limit, SizeOf(limit), 0);
    limit.Basic.LimitFlags := PWEB_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if not SetInformationJobObject(job,
         PWEB_JobObjectExtendedLimitInformation, @limit, SizeOf(limit)) then
    begin
      OsError := GetLastError;
      Failure := psfJobObject;
      exit;
    end;
    // --- the explicit handle list ---------------------------------------
    attrSize := 0;
    InitializeProcThreadAttributeList(nil, 1, 0, attrSize);
    attrList := AllocMem(attrSize);
    if not InitializeProcThreadAttributeList(attrList, 1, 0, attrSize) then
    begin
      OsError := GetLastError;
      FreeMem(attrList);
      attrList := nil;
      Failure := psfCreate;
      exit;
    end;
    handles[0] := nulIn;
    handles[1] := outWrite;
    handles[2] := errWrite;
    if not UpdateProcThreadAttribute(attrList, 0,
         PWEB_PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @handles[0],
         SizeOf(handles), nil, nil) then
    begin
      OsError := GetLastError;
      Failure := psfCreate;
      exit;
    end;
    FillChar(six, SizeOf(six), 0);
    six.StartupInfo.cb := SizeOf(six);
    six.StartupInfo.dwFlags := STARTF_USESTDHANDLES;
    six.StartupInfo.hStdInput := nulIn;
    six.StartupInfo.hStdOutput := outWrite;
    six.StartupInfo.hStdError := errWrite;
    six.lpAttributeList := attrList;
    // --- the process, SUSPENDED so it joins the job before its first
    // instruction can spawn anything of its own ---------------------------
    exeW := W(PWebCliDisplayPath(ExePath));
    cmdW := W(PWebCliWindowsCommandLine(PWebCliDisplayPath(ExePath), Args));
    dirW := W(PWebCliDisplayPath(WorkDir));
    // the command line buffer must be writable: CreateProcessW may modify it
    UniqueString(cmdW);
    flags := PWEB_CREATE_SUSPENDED or PWEB_CREATE_UNICODE_ENVIRONMENT or
      PWEB_EXTENDED_STARTUPINFO_PRESENT;
    // a new process group, so the console's Ctrl+C reaches the supervisor
    // and not the application; the supervisor forwards it as a graceful
    // stop instead. (With a separate console the group is implicit.)
    if SeparateConsole then
      flags := flags or PWEB_CREATE_NEW_CONSOLE
    else
      flags := flags or PWEB_CREATE_NEW_PROCESS_GROUP;
    // lpEnvironment = nil: the child inherits this process's environment
    // block UNCHANGED, which is the ratified CAP-10C0 policy
    if not CreateProcessW(PWideChar(exeW), PWideChar(cmdW), nil, nil, True,
         flags, nil, PWideChar(dirW), six.StartupInfo, pi) then
    begin
      OsError := GetLastError;
      Failure := psfCreate;
      exit;
    end;
    if not AssignProcessToJobObject(job, pi.hProcess) then
    begin
      // a child that cannot be owned is not started at all: it is still
      // suspended, so it has done nothing and can be discarded safely
      OsError := GetLastError;
      TerminateProcess(pi.hProcess, 1);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      Failure := psfJobObject;
      exit;
    end;
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    Child.Pid := pi.dwProcessId;
    Child.Handle := pi.hProcess;
    Child.Job := job;
    Child.OutRead := outRead;
    Child.ErrRead := errRead;
    Child.Running := True;
    job := 0;
    outRead := 0;
    errRead := 0;
    Result := True;
  finally
    if attrList <> nil then
    begin
      DeleteProcThreadAttributeList(attrList);
      FreeMem(attrList);
    end;
    // the child's ends are closed in the parent whatever happened: the
    // child holds its own copies, and a parent that kept a write end would
    // never see EOF on its own read end
    CloseIf(outWrite);
    CloseIf(errWrite);
    CloseIf(nulIn);
    CloseIf(outRead);
    CloseIf(errRead);
    CloseIf(job);
  end;
end;

function PWebCliChildRead(var Child: TPWebCliChild;
  Stream: TPWebCliChildStream; Buf: Pointer; Cap: PtrInt): PtrInt;
var
  h: THandle;
  avail, got: DWORD;
begin
  Result := -1;
  if Stream = pcsStdOut then
    h := Child.OutRead
  else
    h := Child.ErrRead;
  if (h = 0) or
     (Cap <= 0) then
    exit;
  avail := 0;
  // PeekNamedPipe is the non-blocking question; ReadFile on an anonymous
  // pipe would block until at least one byte arrived
  if not PeekNamedPipe(h, nil, 0, nil, @avail, nil) then
  begin
    if GetLastError = PWEB_ERROR_BROKEN_PIPE then
      exit(-1);
    exit(0);
  end;
  if avail = 0 then
    exit(0);
  if avail > DWORD(Cap) then
    avail := Cap;
  got := 0;
  if not ReadFile(h, Buf^, avail, got, nil) then
  begin
    if GetLastError = PWEB_ERROR_BROKEN_PIPE then
      exit(-1);
    exit(0);
  end;
  Result := got;
end;

procedure PWebCliChildPoll(var Child: TPWebCliChild; TimeoutMs: Cardinal);
begin
  // the process handle is the only waitable object here - an anonymous pipe
  // is not - so this returns early on exit and on time otherwise; the engine
  // reads both pipes on every pass either way
  if Child.Running and
     (Child.Handle <> 0) then
    WaitForSingleObject(Child.Handle, TimeoutMs)
  else
    Sleep(TimeoutMs);
end;

function PWebCliChildWait(var Child: TPWebCliChild): Boolean;
var
  code: DWORD;
begin
  Result := not Child.Running;
  if Result or
     (Child.Handle = 0) then
    exit;
  if WaitForSingleObject(Child.Handle, 0) <> WAIT_OBJECT_0 then
    exit;
  code := 0;
  GetExitCodeProcess(Child.Handle, code);
  Child.ExitCode := Integer(code);
  Child.Signal := 0;
  Child.Running := False;
  Result := True;
end;

var
  EnumClosePid: DWORD;
  EnumClosePosted: Integer;

// one callback per top-level window; ONLY a visible window owned by the
// child pid is asked to close. Hidden top-level windows belong to COM,
// WebView2 and the runtime itself and a WM_CLOSE to those would destroy
// infrastructure the host is still using
function CloseWindowsOfPid(hwnd: HWND; lParam: LPARAM): BOOL; stdcall;
var
  pid: DWORD;
begin
  Result := True;
  pid := 0;
  GetWindowThreadProcessId(hwnd, @pid);
  if (pid = EnumClosePid) and
     IsWindowVisible(hwnd) then
    if PostMessageW(hwnd, PWEB_WM_CLOSE, 0, 0) then
      Inc(EnumClosePosted);
end;

function PWebCliChildStop(var Child: TPWebCliChild): Integer;
begin
  Result := 0;
  if not Child.Running then
    exit;
  EnumClosePid := Child.Pid;
  EnumClosePosted := 0;
  EnumWindows(@CloseWindowsOfPid, 0);
  Result := EnumClosePosted;
end;

function PWebCliChildKill(var Child: TPWebCliChild): Boolean;
begin
  Result := False;
  if Child.Job <> 0 then
    Result := TerminateJobObject(Child.Job, 1);
  if Child.Running and
     (Child.Handle <> 0) then
    // belt and braces: the job covers the tree, this covers the child even
    // if the job handle were somehow gone
    Result := TerminateProcess(Child.Handle, 1) or Result;
end;

function ImagePathOfPid(Pid: DWORD; out ParentPid: PtrInt): RawUtf8;
var
  h: THandle;
  buf: array[0 .. 32767] of WideChar;
  len: DWORD;
  pbi: TPWebProcessBasicInformation;
  ret: ULONG;
begin
  Result := '';
  ParentPid := 0;
  h := OpenProcess(PWEB_PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if h = 0 then
    exit; // unreadable: recorded as '', never guessed
  try
    len := Length(buf);
    if QueryFullProcessImageNameW(h, 0, @buf[0], len) and
       (len > 0) then
      Result := U(SynUnicode(WideString(PWideChar(@buf[0]))));
    if SizeOf(pbi) = PWEB_PROCESS_BASIC_INFO_BYTES then
    begin
      ret := 0;
      if NtQueryInformationProcess(h, 0, @pbi, SizeOf(pbi), @ret) = 0 then
        ParentPid := pbi.InheritedFromUniqueProcessId;
    end;
  finally
    CloseHandle(h);
  end;
end;

function PWebCliChildMembers(const Child: TPWebCliChild): TPWebCliTreeMembers;
var
  capacity, i, n: PtrInt;
  bytes, ret: DWORD;
  buf: PByte;
  pids: PPtrUInt;
  ok: Boolean;
begin
  Result := nil;
  if Child.Job = 0 then
    exit;
  capacity := PWEB_JOB_PID_LIST_FIRST;
  repeat
    bytes := 8 + capacity * SizeOf(PtrUInt);
    buf := AllocMem(bytes);
    try
      ret := 0;
      ok := QueryInformationJobObject(Child.Job,
        PWEB_JobObjectBasicProcessIdList, buf, bytes, @ret);
      if not ok and
         (GetLastError = PWEB_ERROR_MORE_DATA) and
         (capacity < PWEB_JOB_PID_LIST_MAX) then
      begin
        capacity := PWEB_JOB_PID_LIST_MAX;
        continue;
      end;
      if not ok then
        exit;
      n := PDWORD(buf + 4)^; // NumberOfProcessIdsInList
      if n > capacity then
        n := capacity;
      pids := PPtrUInt(buf + 8);
      SetLength(Result, n);
      for i := 0 to n - 1 do
      begin
        Result[i].Pid := pids[i];
        Result[i].Image := ImagePathOfPid(pids[i], Result[i].ParentPid);
      end;
      exit;
    finally
      FreeMem(buf);
    end;
  until False;
end;

procedure PWebCliChildRelease(var Child: TPWebCliChild);
var
  h: THandle;
begin
  h := Child.OutRead; CloseIf(h);
  h := Child.ErrRead; CloseIf(h);
  h := Child.Handle;  CloseIf(h);
  // the LAST handle to the job: with KILL_ON_JOB_CLOSE this is the moment
  // any member still alive is terminated by the kernel
  h := Child.Job;     CloseIf(h);
  Child := Default(TPWebCliChild);
end;

var
  StopFlag: LongInt;

function StopHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  // every console event is a stop request; the answer is always "handled"
  // so the default handler (ExitProcess) never runs underneath a supervisor
  // that has a tree to bring down first
  // (CTRL_CLOSE_EVENT is the same request with a bounded window to act on
  // it; dwCtrlType is deliberately not consulted)
  InterlockedExchange(StopFlag, 1);
  Result := True;
end;

function PWebCliInstallStopHandler: Boolean;
begin
  // a parent that created this process in a new group disabled Ctrl+C for
  // it; re-enable it FIRST, so a terminal's Ctrl+C reaches the handler
  SetConsoleCtrlHandler(nil, False);
  Result := SetConsoleCtrlHandler(@StopHandler, True);
end;

function PWebCliStopRequested: Boolean;
begin
  Result := InterlockedExchangeAdd(StopFlag, 0) <> 0;
end;

function PWebCliTreeModelText: RawUtf8;
begin
  Result := 'job_object';
end;

function PWebCliPidAlive(Pid: PtrInt): Boolean;
var
  h: THandle;
  code: DWORD;
begin
  Result := False;
  h := OpenProcess(PWEB_PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if h = 0 then
    exit;
  code := 0;
  if GetExitCodeProcess(h, code) then
    Result := code = STILL_ACTIVE;
  CloseHandle(h);
end;

{$else}

{ ---------------------------------------------------------------------------
  POSIX BODY (Linux and macOS)
  --------------------------------------------------------------------------- }

const
  PWEB_POSIX_PATH_MAX = 4096;
  {$ifdef DARWIN}
  // FPC 3.2.2's Darwin BaseUnix declares neither, and both call sites are
  // confinement code: O_DIRECTORY turns "a file was given as a directory"
  // into a refusal, O_NOFOLLOW makes a link swapped in under us FAIL rather
  // than resolve elsewhere. Values as published by Apple in bsd/sys/fcntl.h,
  // identical to the pair pweb.assets.folder already carries and which
  // test/cap7m/abi_probe_fcntl.c re-measures on every macOS CI run.
  O_DIRECTORY = $00100000;
  O_NOFOLLOW  = $00000100;
  F_GETPATH   = 50;
  PWEB_DARWIN_PATH_MAX = 1024;
  {$endif DARWIN}

{$ifdef DARWIN}
// fcntl(2) is variadic in C and Apple's arm64 ABI passes variadic arguments
// on the stack where x86_64 passes them in registers, so the declaration
// must be variadic on both - exactly as pweb.assets.folder documents.
function pweb_cli_fcntl(fd: cint; cmd: cint): cint; cdecl; varargs;
  external name 'fcntl';

function sysctlbyname(name: PAnsiChar; oldp: Pointer; oldlenp: PPtrUInt;
  newp: Pointer; newlen: PtrUInt): cint; cdecl; external 'c'
  name 'sysctlbyname';

function FinalPathOfFd(fd: cint): RawUtf8;
var
  buf: array[0 .. PWEB_DARWIN_PATH_MAX - 1] of AnsiChar;
  n: PtrInt;
begin
  Result := '';
  FillChar(buf{%H-}, SizeOf(buf), 0);
  if pweb_cli_fcntl(fd, F_GETPATH, @buf[0]) <> 0 then
    exit;
  n := 0;
  while (n < PWEB_DARWIN_PATH_MAX) and
        (buf[n] <> #0) do
    Inc(n);
  if (n = 0) or
     (n >= PWEB_DARWIN_PATH_MAX) or
     (buf[0] <> '/') then
    exit;
  SetString(Result, PAnsiChar(@buf[0]), n);
end;
{$else}
function FinalPathOfFd(fd: cint): RawUtf8;
begin
  Result := RawUtf8(FpReadLink('/proc/self/fd/' + IntToStr(fd)));
  if (Result = '') or
     (Result[1] <> '/') then
    Result := '';
end;
{$endif DARWIN}

function PWebCliOsProductVersion(out Version: RawUtf8): Boolean;
{$ifdef DARWIN}
var
  buf: array[0 .. 63] of AnsiChar;
  len: PtrUInt;
  n: PtrInt;
{$endif DARWIN}
begin
  Version := '';
  Result := False;
  {$ifdef DARWIN}
  // kern.osproductversion is the exact marketing version ('14.6'), which is
  // what the ratified macOS floor is expressed in; parsing the free-form
  // release text would be a second, worse answer to the same question
  FillChar(buf{%H-}, SizeOf(buf), 0);
  len := SizeOf(buf) - 1;
  if sysctlbyname('kern.osproductversion', @buf[0], @len, nil, 0) <> 0 then
    exit;
  n := 0;
  while (n < SizeOf(buf) - 1) and
        (buf[n] <> #0) do
    Inc(n);
  if n = 0 then
    exit;
  SetString(Version, PAnsiChar(@buf[0]), n);
  Result := True;
  {$endif DARWIN}
  // Linux publishes no single comparable product version, and the ratified
  // Linux baseline is a library requirement rather than a distro number
end;

function PWebCliRawArgs: TRawUtf8DynArray;
var
  i: PtrInt;
begin
  // POSIX argv is bytes and the RTL hands them over unchanged
  SetLength(Result, ParamCount);
  for i := 1 to ParamCount do
    Result[i - 1] := RawUtf8(ParamStr(i));
end;

// the POSIX question itself, asked of libc. FPC's RTL spells this
// differently across units and versions, and mORMot's StdOutIsTTY
// deliberately conflates "is a terminal" with "supports colour" by also
// consulting TERM - which is the NEXT question here, not this one.
function isatty(fd: cint): cint; cdecl; external 'c' name 'isatty';

function PWebCliStdOutIsTerminal: Boolean;
begin
  Result := isatty(StdOutputHandle) = 1;
end;

procedure PWebCliPrepareConsole;
begin
  // POSIX terminals are UTF-8 by configuration and there is nothing to set;
  // the function exists so callers stay platform-free
end;

function PWebCliAnsiSupported: Boolean;
begin
  // a terminal that answers isatty understands SGR; TERM=dumb is the one
  // exception worth honouring, and it is the only environment read here
  Result := PWebCliStdOutIsTerminal and
    (RawUtf8(GetEnvironmentVariable('TERM')) <> 'dumb');
end;

function PWebCliCanonicalDir(const Dir: RawUtf8;
  out Canonical: RawUtf8): Boolean;
var
  fd: cint;
begin
  Result := False;
  Canonical := '';
  if Dir = '' then
    exit;
  // O_DIRECTORY refuses a plain file here rather than three steps later;
  // the descriptor is then asked what it actually opened, which resolves
  // every link (and, on macOS, every firmlink) exactly once
  fd := FpOpen(RawByteString(Dir), O_RDONLY or O_DIRECTORY);
  if fd < 0 then
    exit;
  try
    Canonical := FinalPathOfFd(fd);
  finally
    FpClose(fd);
  end;
  Result := Canonical <> '';
end;

function PWebCliCwd(out Dir: RawUtf8): Boolean;
begin
  Result := PWebCliCanonicalDir(RawUtf8(GetCurrentDir), Dir);
end;

function PWebCliParentDir(const Dir: RawUtf8; out Parent: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Parent := '';
  Result := False;
  if (Dir = '') or
     (Dir = '/') then
    exit; // the filesystem root has no parent - the walk stops here
  i := Length(Dir);
  while (i > 1) and
        (Dir[i] <> '/') do
    Dec(i);
  if i <= 1 then
    Parent := '/'
  else
    Parent := Copy(Dir, 1, i - 1);
  Result := True;
end;

function PWebCliJoin(const Dir, Name: RawUtf8): RawUtf8;
begin
  if Dir = '' then
    Result := Name
  else if Dir[Length(Dir)] = '/' then
    Result := Dir + Name
  else
    Result := Dir + '/' + Name;
end;

function PWebCliDisplayPath(const Path: RawUtf8): RawUtf8;
begin
  Result := Path; // POSIX canonical paths are already the displayed form
end;

function PWebCliAbsolute(const Base, Path: RawUtf8): RawUtf8;
begin
  Result := Path;
  while (Length(Result) > 1) and
        (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  if (Result <> '') and
     (Result[1] <> '/') then
    Result := PWebCliJoin(Base, Result);
end;

function PWebCliSplitLast(const Path: RawUtf8;
  out Parent, Name: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Parent := '';
  Name := '';
  Result := False;
  i := Length(Path);
  while (i > 0) and
        (Path[i] <> '/') do
    Dec(i);
  if (i <= 0) or
     (i = Length(Path)) then
    exit;
  if i = 1 then
    Parent := '/'
  else
    Parent := Copy(Path, 1, i - 1);
  Name := Copy(Path, i + 1, MaxInt);
  Result := (Parent <> '') and (Name <> '');
end;

function KindOfStat(const Info: stat): TPWebCliNodeKind;
begin
  if fpS_ISLNK(Info.st_mode) then
    Result := pcnLink
  else if fpS_ISDIR(Info.st_mode) then
    Result := pcnDirectory
  else if fpS_ISREG(Info.st_mode) then
    Result := pcnFile
  else
    Result := pcnOther;
end;

function EntryEquals(P: PAnsiChar; const S: RawUtf8): Boolean;
var
  i, len: PtrInt;
begin
  Result := False;
  len := Length(S);
  for i := 1 to len do
    if (P^ = #0) or
       (P^ <> S[i]) then
      exit
    else
      Inc(P);
  Result := P^ = #0;
end;

function PWebCliNodeKind(const Path: RawUtf8): TPWebCliNodeKind;
var
  info: stat;
begin
  Result := pcnMissing;
  if Path = '' then
    exit;
  // lstat, never stat: a link must be seen as a link
  if FpLstat(RawByteString(Path), info{%H-}) <> 0 then
    exit;
  Result := KindOfStat(info);
end;

// the directory's own bytes are the truth: APFS is case-insensitive by
// default and a Linux mount can carry ext4 casefold, so asking the
// filesystem to match a name would fold case on exactly the platforms where
// confinement matters most
function DirHasExactName(const Dir, Name: RawUtf8): Boolean;
var
  dirp: pDir;
  entry: pDirent;
begin
  Result := False;
  dirp := FpOpendir(RawByteString(Dir));
  if dirp = nil then
    exit;
  try
    repeat
      entry := FpReaddir(dirp^);
      if entry = nil then
        break;
      if EntryEquals(PAnsiChar(@entry^.d_name[0]), Name) then
        exit(True);
    until False;
  finally
    FpClosedir(dirp^);
  end;
end;

function PWebCliEntry(const Dir, Name: RawUtf8): TPWebCliNodeKind;
begin
  Result := pcnMissing;
  if (Dir = '') or
     (Name = '') then
    exit;
  if not DirHasExactName(Dir, Name) then
    exit;
  Result := PWebCliNodeKind(PWebCliJoin(Dir, Name));
end;

function PWebCliFindExecutable(const Dir, Tool: RawUtf8;
  out RealPath: RawUtf8): Boolean;
var
  info: stat;
begin
  Result := False;
  RealPath := '';
  if (Dir = '') or
     (Tool = '') then
    exit;
  if not DirHasExactName(Dir, Tool) then
    exit;
  RealPath := PWebCliJoin(Dir, Tool);
  // fpStat, NOT fpLstat: a symlink on PATH is followed here on purpose -
  // /usr/bin/node is a link on nearly every distribution, and refusing it
  // would refuse ordinary installs rather than any attack. The link
  // REFUSAL is a confinement rule and lives in pweb.cli.paths.
  if FpStat(RawByteString(RealPath), info{%H-}) <> 0 then
  begin
    RealPath := '';
    exit;
  end;
  if not fpS_ISREG(info.st_mode) then
  begin
    RealPath := '';
    exit;
  end;
  Result := FpAccess(RawByteString(RealPath), X_OK) = 0;
  if not Result then
    RealPath := '';
end;

function PWebCliDirWritable(const Dir: RawUtf8): Boolean;
begin
  // access(W_OK or X_OK) asks the kernel the permission question and
  // creates nothing. W_OK alone is not enough: a directory also needs the
  // search bit before anything can be made inside it.
  Result := FpAccess(RawByteString(Dir), W_OK or X_OK) = 0;
end;

function PWebCliReadSmallFile(const Path: RawUtf8; MaxBytes: PtrInt;
  out Content: RawByteString; out TooBig: Boolean): Boolean;
var
  fd: cint;
  info: stat;
  size, done: Int64;
  rd: PtrInt;
begin
  Result := False;
  TooBig := False;
  Content := '';
  // O_NOFOLLOW: a final component swapped for a link between the walk and
  // this open FAILS instead of resolving somewhere else
  fd := FpOpen(RawByteString(Path), O_RDONLY or O_NOFOLLOW);
  if fd < 0 then
    exit;
  try
    if FpFstat(fd, info{%H-}) <> 0 then
      exit;
    if not fpS_ISREG(info.st_mode) then
      exit; // a FIFO or a device is never a descriptor
    size := info.st_size;
    if size < 0 then
      exit;
    if size > MaxBytes then
    begin
      TooBig := True;
      exit;
    end;
    SetLength(Content, size);
    done := 0;
    while done < size do
    begin
      rd := FpRead(fd, PByteArray(Content)^[done], size - done);
      if rd <= 0 then
      begin
        Content := '';
        exit;
      end;
      Inc(done, rd);
    end;
    Result := True;
  finally
    FpClose(fd);
  end;
end;

function PWebCliListDir(const Dir: RawUtf8;
  out Names: TRawUtf8DynArray): Boolean;
var
  dirp: pDir;
  entry: pDirent;
  n, len: PtrInt;
  name: RawUtf8;
begin
  Names := nil;
  Result := False;
  if Dir = '' then
    exit;
  dirp := FpOpendir(RawByteString(Dir));
  if dirp = nil then
    exit;
  n := 0;
  try
    repeat
      entry := FpReaddir(dirp^);
      if entry = nil then
        break;
      len := 0;
      while (len < SizeOf(entry^.d_name)) and
            (entry^.d_name[len] <> #0) do
        Inc(len);
      SetString(name, PAnsiChar(@entry^.d_name[0]), len);
      if (name <> '.') and
         (name <> '..') and
         (name <> '') then
      begin
        SetLength(Names, n + 1);
        Names[n] := name;
        Inc(n);
      end;
    until False;
    Result := True;
  finally
    FpClosedir(dirp^);
  end;
end;

function PWebCliHasFileModes: Boolean;
begin
  Result := True;
end;

function PWebCliExecutableBit(const Path: RawUtf8): Boolean;
var
  info: stat;
begin
  Result := False;
  if (Path = '') or
     (FpLstat(RawByteString(Path), info{%H-}) <> 0) then
    exit;
  if not fpS_ISREG(info.st_mode) then
    exit;
  Result := (info.st_mode and S_IXUSR) <> 0;
end;

function PWebCliCreateDir(const Dir: RawUtf8): Boolean;
begin
  Result := False;
  if Dir = '' then
    exit;
  // mkdir(2) fails with EEXIST when the name is taken by anything at all,
  // a dangling symlink included, so the exclusivity is the kernel's
  if FpMkdir(RawByteString(Dir), &700) <> 0 then
    exit;
  // the mode is set EXPLICITLY afterwards: mkdir's mode argument is masked
  // by the invoking shell's umask, and a generated tree whose permissions
  // depend on who ran the command is not deterministic output
  Result := FpChmod(RawByteString(Dir), &755) = 0;
end;

function PWebCliWriteNewFile(const Path: RawUtf8;
  const Content: RawByteString; SetExecBit: Boolean): Boolean;
var
  fd: cint;
  done: Int64;
  wr: PtrInt;
  mode: TMode;
begin
  Result := False;
  if Path = '' then
    exit;
  // O_CREAT|O_EXCL is the atomic create-or-fail, and by POSIX definition it
  // fails on a symlink even before O_NOFOLLOW is considered; both are
  // requested so the intent is readable rather than inferred
  fd := FpOpen(RawByteString(Path),
    O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW, &600);
  if fd < 0 then
    exit;
  try
    done := 0;
    while done < Length(Content) do
    begin
      wr := FpWrite(fd, PByteArray(Content)^[done], Length(Content) - done);
      if wr <= 0 then
        exit;
      Inc(done, wr);
    end;
  finally
    FpClose(fd);
  end;
  if SetExecBit then
    mode := &755
  else
    mode := &644;
  // chmod, not the open mode: see PWebCliCreateDir - umask must not reach
  // the generated corpus
  Result := FpChmod(RawByteString(Path), mode) = 0;
end;

function PWebCliDeleteFile(const Path: RawUtf8): Boolean;
begin
  // only a REGULAR file: a directory, a symlink or a device is refused, so
  // the cleanup can never follow something out of the staged tree
  Result := (PWebCliNodeKind(Path) = pcnFile) and
    (FpUnlink(RawByteString(Path)) = 0);
end;

function PWebCliRemoveEmptyDir(const Dir: RawUtf8): Boolean;
begin
  Result := (PWebCliNodeKind(Dir) = pcnDirectory) and
    (FpRmdir(RawByteString(Dir)) = 0);
end;

function PWebCliRenameDir(const FromDir, ToDir: RawUtf8): Boolean;
var
  info: stat;
begin
  Result := False;
  if (FromDir = '') or
     (ToDir = '') then
    exit;
  // rename(2) has no portable no-replace form: renameat2(RENAME_NOREPLACE)
  // is Linux-only and renamex_np(RENAME_EXCL) is Darwin-only, and neither
  // can be linked without pinning a libc floor this project has not agreed.
  // So the destination is lstat'ed immediately before the call. The
  // residual is bounded and recorded in deferred-work.md: only an EMPTY
  // directory appearing inside that window could be replaced, because
  // rename onto a non-empty directory is ENOTEMPTY and onto a file is
  // ENOTDIR - no user CONTENT can be destroyed by this call.
  if FpLstat(RawByteString(ToDir), info{%H-}) = 0 then
    exit;
  Result := FpRename(RawByteString(FromDir), RawByteString(ToDir)) = 0;
end;

function PWebCliReplaceFile(const FromPath, ToPath: RawUtf8): Boolean;
begin
  // rename(2) over an existing regular file IS the POSIX atomic replace -
  // no check, no window, no unlink-then-rename gap
  Result := (FromPath <> '') and
    (ToPath <> '') and
    (FpRename(RawByteString(FromPath), RawByteString(ToPath)) = 0);
end;

function SplitEnvList(const Value: RawUtf8; Sep: AnsiChar): TRawUtf8DynArray;
var
  i, start, n: PtrInt;
  item: RawUtf8;
begin
  Result := nil;
  n := 0;
  start := 1;
  for i := 1 to Length(Value) + 1 do
    if (i > Length(Value)) or
       (Value[i] = Sep) then
    begin
      item := Copy(Value, start, i - start);
      // POSIX says an empty PATH entry means the working directory. The CLI
      // must never execute something because of where it was invoked, so
      // the entry is dropped rather than expanded.
      if item <> '' then
      begin
        SetLength(Result, n + 1);
        Result[n] := item;
        Inc(n);
      end;
      start := i + 1;
    end;
end;

function PWebCliPathDirs: TRawUtf8DynArray;
begin
  Result := SplitEnvList(RawUtf8(GetEnvironmentVariable('PATH')), ':');
end;

function PWebCliExecNames(const Tool: RawUtf8): TRawUtf8DynArray;
begin
  // POSIX executables carry no extension convention
  SetLength(Result, 1);
  Result[0] := Tool;
end;

function PWebCliIsExecutable(const Path: RawUtf8): Boolean;
begin
  // a directory with the execute bit is searchable, never runnable
  Result := (PWebCliNodeKind(Path) = pcnFile) and
    (FpAccess(RawByteString(Path), X_OK) = 0);
end;

function PWebCliEngine: TPWebCliEngineFact;
{$ifdef DARWIN}
const
  WEBKIT_FRAMEWORK = '/System/Library/Frameworks/WebKit.framework';
var
  version: RawUtf8;
{$else}
const
  SO_WEBKIT = 'libwebkit2gtk-4.1.so.0';
  SO_GTK = 'libgtk-3.so.0';
var
  hWebkit, hGtk: TLibHandle;
{$endif DARWIN}
begin
  Result.Usable := False;
  {$ifdef DARWIN}
  Result.Expected := PWEB_CLI_ENGINE_MACOS;
  if PWebCliNodeKind(WEBKIT_FRAMEWORK) <> pcnDirectory then
  begin
    Result.Category := 'framework_absent';
    Result.Observed := 'WebKit.framework not present';
    exit;
  end;
  if not PWebCliOsProductVersion(version) then
  begin
    Result.Category := 'version_unreadable';
    Result.Observed := 'kern.osproductversion unavailable';
    exit;
  end;
  Result.Observed := version;
  // the comparison itself belongs to the doctor (it owns the pinned floor);
  // this fact reports presence and the exact product version
  Result.Category := 'present';
  Result.Usable := True;
  {$else}
  Result.Expected := PWEB_CLI_ENGINE_LINUX;
  // the loader's own question, asked the loader's own way: a shipped PWeb
  // application dynamically links these two sonames and dies before main()
  // when either is absent (deployment.md). Loaded read-only and released
  // immediately - nothing is installed and nothing is left behind.
  hWebkit := LoadLibrary(SO_WEBKIT);
  hGtk := LoadLibrary(SO_GTK);
  try
    if hWebkit = NilHandle then
    begin
      Result.Category := 'webkitgtk_absent';
      Result.Observed := SO_WEBKIT + ' not loadable';
      exit;
    end;
    if hGtk = NilHandle then
    begin
      Result.Category := 'gtk_absent';
      Result.Observed := SO_GTK + ' not loadable';
      exit;
    end;
    Result.Category := 'usable';
    Result.Observed := SO_WEBKIT + ' + ' + SO_GTK;
    Result.Usable := True;
  finally
    if hWebkit <> NilHandle then
      UnloadLibrary(hWebkit);
    if hGtk <> NilHandle then
      UnloadLibrary(hGtk);
  end;
  {$endif DARWIN}
end;

{ ---------------------------------------------------------------------------
  child processes - POSIX: fork/execve + process group
  --------------------------------------------------------------------------- }

const
  // what the child writes back through the status pipe when it cannot go on
  PWEB_EXEC_STATUS_CHDIR = 1;
  PWEB_EXEC_STATUS_EXEC = 2;
  PWEB_POSIX_PROC_ALL_PIDS = 1;
  PWEB_POSIX_PROC_PIDTBSDINFO = 3;
  PWEB_POSIX_PROC_BSDINFO_BYTES = 136;
  PWEB_POSIX_PIDPATH_MAX = 4096;
  // absent from BaseUnix on both Linux and Darwin; 1 in every POSIX fcntl.h
  FD_CLOEXEC = 1;
  {$ifdef LINUX}
  PWEB_PR_SET_PDEATHSIG = 1;
  {$endif LINUX}

// FPC 3.2.2's BaseUnix declares neither; both are plain libc calls
function pweb_cli_setpgid(pid, pgid: pid_t): cint;
  cdecl; external 'c' name 'setpgid';
// the LIVE environment of this process, libc's own: FPC's `envp` is a copy
// taken at startup, and a variable set since (setenv) would be missing
// from a child handed that copy - MEASURED by the S18 marker
var
  environ: PPAnsiChar; cvar; external;
{$ifdef LINUX}
function pweb_cli_prctl(option: cint; arg2, arg3, arg4, arg5: culong): cint;
  cdecl; external 'c' name 'prctl';
{$else}
// libproc, re-exported by libSystem: the process-group enumeration and the
// image path of one pid, with no sysctl kinfo_proc layout to get wrong
function proc_listpids(ptype, typeinfo: cuint; buffer: Pointer;
  buffersize: cint): cint; cdecl; external 'c' name 'proc_listpids';
function proc_pidinfo(pid, flavor: cint; arg: QWord; buffer: Pointer;
  buffersize: cint): cint; cdecl; external 'c' name 'proc_pidinfo';
function proc_pidpath(pid: cint; buffer: Pointer; buffersize: cuint): cint;
  cdecl; external 'c' name 'proc_pidpath';

type
  // bsd/sys/proc_info.h proc_bsdinfo, 136 bytes; only three fields are read
  TPWebProcBsdInfo = record
    pbi_flags: cuint;
    pbi_status: cuint;
    pbi_xstatus: cuint;
    pbi_pid: cuint;
    pbi_ppid: cuint;
    pbi_uid: cuint;
    pbi_gid: cuint;
    pbi_ruid: cuint;
    pbi_rgid: cuint;
    pbi_svuid: cuint;
    pbi_svgid: cuint;
    rfu_1: cuint;
    pbi_comm: array[0 .. 15] of AnsiChar;
    pbi_name: array[0 .. 31] of AnsiChar;
    pbi_nfiles: cuint;
    pbi_pgid: cuint;
    pbi_pjobc: cuint;
    e_tdev: cuint;
    e_tpgid: cuint;
    pbi_nice: cint;
    pbi_start_tvsec: QWord;
    pbi_start_tvusec: QWord;
  end;
{$endif LINUX}

procedure CloseFd(var Fd: cint);
begin
  if Fd >= 0 then
    FpClose(Fd);
  Fd := -1;
end;

// fcntl with an integer argument. On Darwin the variadic declaration is
// mandatory (arm64 passes variadic arguments on the stack), exactly as the
// F_GETPATH call above already requires; Linux uses the RTL binding
function SetFdControl(Fd, Cmd, Arg: cint): cint;
begin
  {$ifdef DARWIN}
  Result := pweb_cli_fcntl(Fd, Cmd, Arg);
  {$else}
  Result := FpFcntl(Fd, Cmd, Arg);
  {$endif DARWIN}
end;

function GetFdControl(Fd, Cmd: cint): cint;
begin
  {$ifdef DARWIN}
  Result := pweb_cli_fcntl(Fd, Cmd);
  {$else}
  Result := FpFcntl(Fd, Cmd);
  {$endif DARWIN}
end;

function PWebCliChildSpawn(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray; const WorkDir: RawUtf8;
  SeparateConsole: Boolean; out Child: TPWebCliChild;
  out Failure: TPWebCliSpawnFailure; out OsError: Integer): Boolean;
var
  outp, errp, statusp: TFilDes;
  nul: cint;
  pid: pid_t;
  strs: array of RawByteString;
  argv: array of PAnsiChar;
  exeC, dirC: RawByteString;
  status: array[0 .. 1] of cint;
  n: PtrInt;
  waitStatus: cint;
  i: PtrInt;
begin
  Result := False;
  Child := Default(TPWebCliChild);
  Failure := psfNone;
  OsError := 0;
  outp[0] := -1; outp[1] := -1;
  errp[0] := -1; errp[1] := -1;
  statusp[0] := -1; statusp[1] := -1;
  nul := -1;
  // SeparateConsole is a Windows-only notion; POSIX children share the
  // terminal and the flag is accepted and ignored
  if PWebCliNodeKind(WorkDir) <> pcnDirectory then
  begin
    Failure := psfWorkDir;
    exit;
  end;
  // everything the child will need is built BEFORE the fork, so the child
  // touches no heap between fork and exec
  exeC := RawByteString(ExePath);
  dirC := RawByteString(WorkDir);
  SetLength(strs, Length(Args) + 1);
  SetLength(argv, Length(Args) + 2);
  strs[0] := exeC;
  argv[0] := PAnsiChar(strs[0]);
  for i := 0 to High(Args) do
  begin
    strs[i + 1] := RawByteString(Args[i]);
    argv[i + 1] := PAnsiChar(strs[i + 1]);
  end;
  argv[High(argv)] := nil;
  try
    if (FpPipe(outp) <> 0) or
       (FpPipe(errp) <> 0) or
       (FpPipe(statusp) <> 0) then
    begin
      OsError := fpgeterrno;
      Failure := psfPipes;
      exit;
    end;
    // the supervisor's read ends and BOTH ends of the status pipe are
    // close-on-exec: a successful exec closes the status write end, which
    // is exactly the "no news is good news" the parent waits for below
    SetFdControl(outp[0], F_SETFD, FD_CLOEXEC);
    SetFdControl(errp[0], F_SETFD, FD_CLOEXEC);
    SetFdControl(statusp[0], F_SETFD, FD_CLOEXEC);
    SetFdControl(statusp[1], F_SETFD, FD_CLOEXEC);
    nul := FpOpen('/dev/null', O_RDONLY);
    if nul < 0 then
    begin
      OsError := fpgeterrno;
      Failure := psfPipes;
      exit;
    end;
    pid := FpFork;
    if pid < 0 then
    begin
      OsError := fpgeterrno;
      Failure := psfCreate;
      exit;
    end;
    if pid = 0 then
    begin
      // ---- the child: async-signal-safe calls only, then exec ----------
      pweb_cli_setpgid(0, 0);
      {$ifdef LINUX}
      // if the supervisor dies without signalling the group, the direct
      // child is killed with it (Linux only; a defence, not the mechanism)
      pweb_cli_prctl(PWEB_PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
      {$endif LINUX}
      FpDup2(nul, 0);
      FpDup2(outp[1], 1);
      FpDup2(errp[1], 2);
      FpClose(nul);
      FpClose(outp[1]);
      FpClose(errp[1]);
      if FpChDir(PAnsiChar(dirC)) <> 0 then
      begin
        status[0] := PWEB_EXEC_STATUS_CHDIR;
        status[1] := fpgeterrno;
        FpWrite(statusp[1], status, SizeOf(status));
        FpExit(127);
      end;
      // environ is THIS process's environment, handed over unchanged
      FpExecve(PAnsiChar(exeC), PPAnsiChar(@argv[0]), environ);
      status[0] := PWEB_EXEC_STATUS_EXEC;
      status[1] := fpgeterrno;
      FpWrite(statusp[1], status, SizeOf(status));
      FpExit(127);
    end;
    // ---- the parent ----------------------------------------------------
    // the same call from both sides, so whichever runs first wins and the
    // group exists before anything is sent to it
    pweb_cli_setpgid(pid, pid);
    CloseFd(nul);
    CloseFd(outp[1]);
    CloseFd(errp[1]);
    CloseFd(statusp[1]);
    repeat
      n := FpRead(statusp[0], status, SizeOf(status));
    until (n >= 0) or (fpgeterrno <> ESysEINTR);
    CloseFd(statusp[0]);
    if n = SizeOf(status) then
    begin
      // the child could not exec: it has already exited 127 and is reaped
      // here, so a failed spawn leaves no zombie and no running process
      repeat
        i := FpWaitPid(pid, waitStatus, 0);
      until (i = pid) or ((i < 0) and (fpgeterrno <> ESysEINTR));
      OsError := status[1];
      if status[0] = PWEB_EXEC_STATUS_CHDIR then
        Failure := psfWorkDir
      else
        Failure := psfExec;
      exit;
    end;
    SetFdControl(outp[0], F_SETFL, GetFdControl(outp[0], F_GETFL) or O_NONBLOCK);
    SetFdControl(errp[0], F_SETFL, GetFdControl(errp[0], F_GETFL) or O_NONBLOCK);
    Child.Pid := pid;
    Child.Group := pid;
    Child.OutRead := outp[0];
    Child.ErrRead := errp[0];
    Child.Running := True;
    outp[0] := -1;
    errp[0] := -1;
    Result := True;
  finally
    CloseFd(nul);
    CloseFd(outp[0]);
    CloseFd(outp[1]);
    CloseFd(errp[0]);
    CloseFd(errp[1]);
    CloseFd(statusp[0]);
    CloseFd(statusp[1]);
  end;
end;

function PWebCliChildRead(var Child: TPWebCliChild;
  Stream: TPWebCliChildStream; Buf: Pointer; Cap: PtrInt): PtrInt;
var
  fd: cint;
  n: PtrInt;
begin
  Result := -1;
  if Stream = pcsStdOut then
    fd := Child.OutRead
  else
    fd := Child.ErrRead;
  if (fd < 0) or
     (Cap <= 0) then
    exit;
  n := FpRead(fd, Buf^, Cap);
  if n > 0 then
    exit(n);
  if n = 0 then
    exit(-1); // EOF: every writer has closed its end
  case fpgeterrno of
    ESysEAGAIN,
    ESysEINTR:
      Result := 0;
  else
    Result := -1;
  end;
end;

procedure PWebCliChildPoll(var Child: TPWebCliChild; TimeoutMs: Cardinal);
var
  fds: array[0 .. 1] of pollfd;
  n: Integer;
begin
  n := 0;
  if Child.OutRead >= 0 then
  begin
    fds[n].fd := Child.OutRead;
    fds[n].events := POLLIN;
    fds[n].revents := 0;
    Inc(n);
  end;
  if Child.ErrRead >= 0 then
  begin
    fds[n].fd := Child.ErrRead;
    fds[n].events := POLLIN;
    fds[n].revents := 0;
    Inc(n);
  end;
  // with no descriptor left, poll(nil, 0, ms) is a plain bounded sleep;
  // the engine reaps with waitpid on every pass, so exit is never missed
  FpPoll(@fds[0], n, TimeoutMs);
end;

function PWebCliChildWait(var Child: TPWebCliChild): Boolean;
var
  st: cint;
  r: pid_t;
begin
  Result := not Child.Running;
  if Result or
     (Child.Pid <= 0) then
    exit;
  st := 0;
  r := FpWaitPid(Child.Pid, st, WNOHANG);
  if r = 0 then
    exit; // still running
  if r < 0 then
  begin
    if fpgeterrno = ESysEINTR then
      exit;
    // ECHILD: nothing to reap - the child is gone and nobody can say how.
    // Reported as a signal death so it can never read as a clean exit 0
    Child.ExitCode := -1;
    Child.Signal := SIGKILL;
    Child.Running := False;
    exit(True);
  end;
  if wifexited(st) then
  begin
    Child.ExitCode := wexitstatus(st);
    Child.Signal := 0;
  end
  else if wifsignaled(st) then
  begin
    Child.ExitCode := -1;
    Child.Signal := wtermsig(st);
  end
  else
    exit; // stopped/continued: not an exit
  Child.Running := False;
  Result := True;
end;

function PWebCliChildStop(var Child: TPWebCliChild): Integer;
begin
  Result := 0;
  if Child.Group <= 0 then
    exit;
  if FpKill(-Child.Group, SIGTERM) = 0 then
    Result := 1;
end;

function PWebCliChildKill(var Child: TPWebCliChild): Boolean;
begin
  Result := False;
  if Child.Group <= 0 then
    exit;
  Result := FpKill(-Child.Group, SIGKILL) = 0;
  if Child.Running and
     (Child.Pid > 0) then
    Result := (FpKill(Child.Pid, SIGKILL) = 0) or Result;
end;

{$ifdef LINUX}
// /proc/<pid>/stat: "pid (comm) state ppid pgrp ..." - comm may carry spaces
// and parentheses, so the fields are taken AFTER the last ')'
function ReadProcStat(Pid: PtrInt; out ParentPid, Group: PtrInt): Boolean;
var
  fd: cint;
  buf: array[0 .. 1023] of AnsiChar;
  n, i, field: PtrInt;
  text, tok: RawUtf8;
  fields: array[0 .. 3] of RawUtf8;
begin
  Result := False;
  ParentPid := 0;
  Group := 0;
  fd := FpOpen('/proc/' + IntToStr(Pid) + '/stat', O_RDONLY);
  if fd < 0 then
    exit;
  n := FpRead(fd, buf, SizeOf(buf) - 1);
  FpClose(fd);
  if n <= 0 then
    exit;
  SetString(text, PAnsiChar(@buf[0]), n);
  i := Length(text);
  while (i > 0) and
        (text[i] <> ')') do
    Dec(i);
  if i = 0 then
    exit;
  // after ')': ' state ppid pgrp session ...'
  text := Copy(text, i + 1, MaxInt);
  field := 0;
  tok := '';
  for i := 1 to Length(text) + 1 do
    if (i > Length(text)) or
       (text[i] = ' ') then
    begin
      if tok <> '' then
      begin
        if field <= High(fields) then
          fields[field] := tok;
        Inc(field);
        tok := '';
      end;
    end
    else
      tok := tok + text[i];
  if field < 3 then
    exit;
  ParentPid := StrToIntDef(string(fields[1]), 0);
  Group := StrToIntDef(string(fields[2]), 0);
  Result := True;
end;

function PWebCliChildMembers(const Child: TPWebCliChild): TPWebCliTreeMembers;
var
  dir: PDir;
  entry: PDirent;
  name: RawUtf8;
  pid, ppid, pgrp: PtrInt;
  n, i: PtrInt;
  ok: Boolean;
begin
  Result := nil;
  if Child.Group <= 0 then
    exit;
  dir := FpOpenDir('/proc');
  if dir = nil then
    exit;
  n := 0;
  try
    repeat
      entry := FpReadDir(dir^);
      if entry = nil then
        break;
      name := RawUtf8(PAnsiChar(@entry^.d_name[0]));
      ok := name <> '';
      for i := 1 to Length(name) do
        if not (name[i] in ['0' .. '9']) then
        begin
          ok := False;
          break;
        end;
      if not ok then
        continue;
      pid := StrToIntDef(string(name), 0);
      if pid <= 0 then
        continue;
      if not ReadProcStat(pid, ppid, pgrp) then
        continue; // vanished between readdir and open: benign
      if pgrp <> Child.Group then
        continue;
      SetLength(Result, n + 1);
      Result[n].Pid := pid;
      Result[n].ParentPid := ppid;
      // unreadable (a setuid member, a race) stays '' - recorded, never
      // guessed from the name
      Result[n].Image := RawUtf8(fpReadLink('/proc/' + name + '/exe'));
      Inc(n);
    until False;
  finally
    FpCloseDir(dir^);
  end;
end;
{$else}
function PWebCliChildMembers(const Child: TPWebCliChild): TPWebCliTreeMembers;
var
  bytes, count, i, n: PtrInt;
  pids: array of cint;
  info: TPWebProcBsdInfo;
  path: array[0 .. PWEB_POSIX_PIDPATH_MAX - 1] of AnsiChar;
  len: cint;
begin
  Result := nil;
  if (Child.Group <= 0) or
     (SizeOf(info) <> PWEB_POSIX_PROC_BSDINFO_BYTES) then
    exit;
  bytes := proc_listpids(PWEB_POSIX_PROC_ALL_PIDS, 0, nil, 0);
  if bytes <= 0 then
    exit;
  // headroom for processes created between the two calls
  SetLength(pids, bytes div SizeOf(cint) + 64);
  bytes := proc_listpids(PWEB_POSIX_PROC_ALL_PIDS, 0, @pids[0],
    Length(pids) * SizeOf(cint));
  if bytes <= 0 then
    exit;
  count := bytes div SizeOf(cint);
  n := 0;
  for i := 0 to count - 1 do
  begin
    if pids[i] <= 0 then
      continue;
    if proc_pidinfo(pids[i], PWEB_POSIX_PROC_PIDTBSDINFO, 0, @info,
         SizeOf(info)) <> SizeOf(info) then
      continue; // vanished or not ours to inspect: benign
    if PtrInt(info.pbi_pgid) <> Child.Group then
      continue;
    SetLength(Result, n + 1);
    Result[n].Pid := pids[i];
    Result[n].ParentPid := info.pbi_ppid;
    len := proc_pidpath(pids[i], @path[0], SizeOf(path));
    if len > 0 then
      SetString(Result[n].Image, PAnsiChar(@path[0]), len)
    else
      Result[n].Image := '';
    Inc(n);
  end;
end;
{$endif LINUX}

procedure PWebCliChildRelease(var Child: TPWebCliChild);
var
  fd: cint;
begin
  fd := Child.OutRead; CloseFd(fd);
  fd := Child.ErrRead; CloseFd(fd);
  // a last non-blocking reap so no zombie is left by a caller that gave up
  // waiting; the engine has already bounded that wait and reported it
  PWebCliChildWait(Child);
  Child := Default(TPWebCliChild);
  Child.OutRead := -1;
  Child.ErrRead := -1;
end;

var
  StopFlag: LongInt;

procedure StopSignal(Sig: LongInt; Info: PSigInfo; Context: PSigContext); cdecl;
begin
  // async-signal-safe by construction: one aligned store and nothing else
  StopFlag := 1;
end;

function PWebCliInstallStopHandler: Boolean;
var
  act: SigActionRec;
begin
  FillChar(act, SizeOf(act), 0);
  act.sa_handler := SigActionHandler(@StopSignal);
  FpSigEmptySet(act.sa_mask);
  Result := (FpSigaction(SIGINT, @act, nil) = 0) and
            (FpSigaction(SIGTERM, @act, nil) = 0) and
            (FpSigaction(SIGHUP, @act, nil) = 0);
  // a forwarding target that went away must surface as EPIPE on the write,
  // where the engine can act on it, not as a signal that kills the
  // supervisor with the tree still running
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
end;

function PWebCliStopRequested: Boolean;
begin
  Result := StopFlag <> 0;
end;

function PWebCliTreeModelText: RawUtf8;
begin
  Result := 'process_group';
end;

function PWebCliPidAlive(Pid: PtrInt): Boolean;
begin
  // signal 0 delivers nothing and answers existence; EPERM means it exists
  // and is not ours, which is still "alive"
  Result := (Pid > 0) and
            ((FpKill(Pid, 0) = 0) or (fpgeterrno = ESysEPERM));
end;

{$endif WINDOWS}

{ ---------------------------------------------------------------------------
  SHARED BODIES (CAP-10C0)
  --------------------------------------------------------------------------- }

function PWebCliSpawnFailureText(Failure: TPWebCliSpawnFailure): RawUtf8;
begin
  case Failure of
    psfNone:      Result := 'ok';
    psfPipes:     Result := 'spawn_pipes';
    psfJobObject: Result := 'spawn_job_object';
    psfCreate:    Result := 'spawn_create';
    psfExec:      Result := 'spawn_exec';
    psfWorkDir:   Result := 'spawn_workdir';
  else
    Result := 'spawn_failed';
  end;
end;

function PWebCliWindowsCommandLine(const ExePath: RawUtf8;
  const Args: TRawUtf8DynArray): RawUtf8;

  // the inverse of the C runtime's parser (CommandLineToArgvW and msvcrt
  // agree since Windows 2008): an argument is quoted when it is empty or
  // carries a space, tab or quote; a run of N backslashes followed by a
  // quote becomes 2N+1 backslashes and the escaped quote; a run of N
  // backslashes at the END of a quoted argument becomes 2N, so the closing
  // quote survives; every other backslash is literal
  function QuoteOne(const Arg: RawUtf8): RawUtf8;
  var
    i, nb, k: PtrInt;
    needs: Boolean;
  begin
    needs := Arg = '';
    for i := 1 to Length(Arg) do
      if Arg[i] in [' ', #9, #10, #11, '"'] then
      begin
        needs := True;
        break;
      end;
    if not needs then
      exit(Arg);
    Result := '"';
    i := 1;
    while i <= Length(Arg) do
    begin
      nb := 0;
      while (i <= Length(Arg)) and
            (Arg[i] = '\') do
      begin
        Inc(nb);
        Inc(i);
      end;
      if i > Length(Arg) then
      begin
        for k := 1 to nb * 2 do
          Result := Result + '\';
        break;
      end;
      if Arg[i] = '"' then
      begin
        for k := 1 to nb * 2 + 1 do
          Result := Result + '\';
        Result := Result + '"';
      end
      else
      begin
        for k := 1 to nb do
          Result := Result + '\';
        Result := Result + Arg[i];
      end;
      Inc(i);
    end;
    Result := Result + '"';
  end;

var
  i: PtrInt;
begin
  Result := QuoteOne(ExePath);
  for i := 0 to High(Args) do
    Result := Result + ' ' + QuoteOne(Args[i]);
end;

{ ---------------------------------------------------------------------------
  SHARED BODIES

  Two things that need NO platform knowledge because they are written over
  the primitives above. Keeping them here rather than duplicating them into
  both bodies is not tidiness: every line inside a conditional region is a
  line that can silently differ between two operating systems, and the
  CAP-7F sweep counts those regions for exactly that reason.
  --------------------------------------------------------------------------- }

function PWebCliExeDir(out Dir: RawUtf8): Boolean;
begin
  // Executable.ProgramFilePath is absolute and independent of the working
  // directory - the SAME source of truth PWebReleaseDirectory already uses
  // to find app.pwb and plugins.zip beside a running application. It is
  // then canonicalized through the kernel, so what comes back is the real
  // directory rather than the spelling the loader happened to be given.
  Result := PWebCliCanonicalDir(
    StringToUtf8(Executable.ProgramFilePath), Dir);
end;

const
  /// how deep PWebCliRemoveStagedTree will walk before refusing
  // - the staged tree is one this process wrote under its own path limits,
  // so anything deeper is not ours and the walk stops rather than recursing
  // as far as some other tree happens to go
  PWEB_CLI_STAGED_MAX_DEPTH = 32;

function RemoveTreeAt(const Dir: RawUtf8; Depth: Integer): Boolean;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  child: RawUtf8;
begin
  Result := False;
  if Depth > PWEB_CLI_STAGED_MAX_DEPTH then
    exit;
  if not PWebCliListDir(Dir, names) then
    exit;
  for i := 0 to High(names) do
  begin
    child := PWebCliJoin(Dir, names[i]);
    case PWebCliNodeKind(child) of
      pcnFile:
        if not PWebCliDeleteFile(child) then
          exit;
      pcnDirectory:
        if not RemoveTreeAt(child, Depth + 1) then
          exit;
    else
      // a link, a device, a socket: we did not create it, so we do not
      // remove it, and the caller reports the tree it could not reclaim
      exit;
    end;
  end;
  Result := PWebCliRemoveEmptyDir(Dir);
end;

function PWebCliRemoveStagedTree(const Parent, Name: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if (Parent = '') or
     (Name = '') or
     (Name = '.') or
     (Name = '..') then
    exit;
  // ONE component, never a path: a cleanup argument that can carry a
  // separator is a cleanup argument that can be aimed
  for i := 1 to Length(Name) do
    if (Name[i] = '/') or
       (Name[i] = '\') or
       (Name[i] < ' ') then
      exit;
  // and it must really be a directory, resolved by its EXACT on-disk
  // spelling inside the parent we staged into - never a link
  if PWebCliEntry(Parent, Name) <> pcnDirectory then
    exit;
  Result := RemoveTreeAt(PWebCliJoin(Parent, Name), 0);
end;

end.
