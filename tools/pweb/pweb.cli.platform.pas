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

{$endif WINDOWS}

end.
