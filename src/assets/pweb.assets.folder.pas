{
  pweb.assets.folder - development IAssetStore over a root folder.

  TFolderAssetStore serves the canonical corpus from a configured
  directory (nominally frontend/dist/). It must behave exactly like
  the packaged archive store, not like the underlying filesystem:

    - independent fail-closed validation (pweb.assets.support), even
      though the URI layer validated first - ratified defense in depth;
    - EXACT case-sensitive lookup on every platform: each segment is
      re-read from the directory itself and compared character-exactly,
      so Windows case-insensitivity (and 8.3 short-name aliasing)
      never resolves 'assets/App.js' to 'assets/app.js';
    - confinement below the configured root: no '..'/absolute forms
      survive validation, and any reparse point (symlink/junction) on
      the resolved chain fails the read rather than being followed;
    - zero-byte and binary/NUL-containing assets are served verbatim;
      a vanished file is distinguished from an empty one by opening a
      real handle, never by a '' sentinel.

  On Windows every filesystem call goes straight to the wide Win32
  API over explicitly UTF-8-decoded UTF-16 paths. The RTL Ansi
  filesystem layer is deliberately bypassed: its behaviour depends on
  runtime codepage state (e.g. mORMot switches the RTL to UTF-8), and
  cross-unit string concatenation can yield CP_NONE-tagged payloads
  that the RTL then mistranslates. A store this security-sensitive
  gets one deterministic path to the kernel, not three.

  On POSIX (CAP-7L) the same principle produces raw byte paths handed
  straight to open/lstat/readdir, and the RTL's FindFirst is bypassed
  for one more reason on top: on Unix it matches with fnmatch, so a
  perfectly legal asset name containing '[' or ']' would behave as a
  GLOB and could resolve a different file.

  TryRead never raises - any violation or I/O failure returns False.
  Concurrent TryRead calls share no mutable state.
}
unit pweb.assets.folder;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  pweb.assets.intf,
  pweb.assets.support;

{$ifdef DARWIN}
const
  { CAP-7M0. FPC 3.2.2's Darwin BaseUnix declares NEITHER of these, although
    its Linux BaseUnix declares both - so the POSIX branch below, hardened
    for CAP-7L, does not compile on Darwin without them. They are POSIX by
    name and by behaviour; they are simply not portable through FPC's RTL.

    BOTH CALL SITES ARE SECURITY CODE, which is why they are declared rather
    than the branch weakened:

      O_DIRECTORY  makes "a file was passed as the asset root" a
                   construction-time refusal instead of a silent 404 later;
      O_NOFOLLOW   makes a symlink swapped in between the walk and the open
                   FAIL, instead of resolving somewhere else.

    A wrong O_NOFOLLOW would not fail loudly - it would silently stop
    refusing symlinks, which is a confinement hole rather than a bug. So the
    values are NOT transcribed from memory or documentation: they are
    verified on every macOS CI run against the values <fcntl.h> actually
    defines on the runner's SDK, by the paired probe
    test/cap7m/abi_probe_fcntl.c + .pas via test/cap7m/check_abi.sh, which
    permits ZERO delta. That probe is why these constants live in the
    INTERFACE - the same reason CAP-7L put its hand-declared GTK aliases in
    pweb.platform.webkitgtk's interface.

    Values as published by Apple in xnu, bsd/sys/fcntl.h (O_NOFOLLOW under
    the _DARWIN_C_SOURCE guard, O_DIRECTORY under __DARWIN_C_LEVEL >=
    200809L; both are visible to a default-configured compile). If a future
    FPC adds them to Darwin BaseUnix, this block shadows it with the same
    value and the probe keeps proving that. }
  O_DIRECTORY = $00100000;
  O_NOFOLLOW  = $00000100;
{$endif DARWIN}

type
  EPWebFolderAssetStore = class(Exception);

  TFolderAssetStore = class(TInterfacedObject, IAssetStore)
  private
    {$ifdef WINDOWS}
    fRootW: SynUnicode; // absolute UTF-16 root, no trailing delimiter
    // resolve one segment inside ADirW: it must exist with the exact
    // on-disk spelling, must not be a reparse point, and must match
    // the wanted kind; returns False otherwise
    function ResolveSegment(const ADirW: SynUnicode;
      const ASegment: RawUtf8; AWantDirectory: Boolean;
      out AResolvedW: SynUnicode): Boolean;
    {$else}
    // POSIX paths are byte strings, not text: the kernel-resolved root
    // is kept verbatim so nothing round-trips through a codepage
    fRoot: RawByteString; // absolute root, no trailing '/'
    // same contract as the Windows overload: exact on-disk spelling, no
    // symlink, right kind - or False
    function ResolveSegment(const ADir: RawByteString;
      const ASegment: RawUtf8; AWantDirectory: Boolean;
      out AResolved: RawByteString): Boolean;
    {$endif WINDOWS}
  public
    // ARootDir must exist and be a directory - a configuration error
    // surfaces at startup, never as a silent 404 stream later
    constructor Create(const ARootDir: TFileName);
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
  end;

implementation

{$ifdef WINDOWS}

uses
  windows;

const
  PWEB_FA_REPARSE = FILE_ATTRIBUTE_REPARSE_POINT;

// Vista+; absent from the FPC 3.2.2 windows unit, declared here.
// dwFlags 0 = FILE_NAME_NORMALIZED or VOLUME_NAME_DOS ('\\?\C:\...')
function GetFinalPathNameByHandleW(hFile: THandle;
  lpszFilePath: PWideChar; cchFilePath: DWORD; dwFlags: DWORD): DWORD;
  stdcall; external 'kernel32.dll' name 'GetFinalPathNameByHandleW';

// kernel-resolved normalized path of an open handle, '' on failure
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

function WideEquals(P: PWideChar; const W: SynUnicode): Boolean;
var
  i, len: PtrInt;
begin
  Result := False;
  len := Length(W);
  for i := 1 to len do
    if (P^ = #0) or
       (P^ <> W[i]) then
      exit
    else
      Inc(P);
  Result := P^ = #0; // same length too
end;

constructor TFolderAssetStore.Create(const ARootDir: TFileName);
var
  attrs: DWORD;
  configured: SynUnicode;
  h: THandle;
begin
  inherited Create;
  if ARootDir = '' then
    raise EPWebFolderAssetStore.Create('folder asset root is empty');
  // StringToUtf8 honours the input's runtime codepage, so the root is
  // decoded correctly under both the plain and the UTF-8 RTL regimes
  configured := Utf8ToSynUnicode(StringToUtf8(
    ExcludeTrailingPathDelimiter(ExpandFileName(ARootDir))));
  attrs := GetFileAttributesW(PWideChar(configured));
  if (attrs = INVALID_FILE_ATTRIBUTES) or
     ((attrs and FILE_ATTRIBUTE_DIRECTORY) = 0) then
    raise EPWebFolderAssetStore.CreateFmt(
      'folder asset root does not exist: %s', [ARootDir]);
  // canonicalize ONCE through the kernel: a link in the configured
  // root resolves here, so confinement below is relative to the real
  // directory; the '\\?\' form also gives long-path headroom for the
  // walk (validator allows 2048-byte logical paths)
  h := CreateFileW(PWideChar(configured), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if h = INVALID_HANDLE_VALUE then
    raise EPWebFolderAssetStore.CreateFmt(
      'folder asset root cannot be opened: %s', [ARootDir]);
  try
    fRootW := FinalPathOfHandle(h);
  finally
    CloseHandle(h);
  end;
  if fRootW = '' then
    raise EPWebFolderAssetStore.CreateFmt(
      'folder asset root cannot be resolved: %s', [ARootDir]);
end;

function TFolderAssetStore.ResolveSegment(const ADirW: SynUnicode;
  const ASegment: RawUtf8; AWantDirectory: Boolean;
  out AResolvedW: SynUnicode): Boolean;
var
  segW, pathW: SynUnicode;
  h: THandle;
  data: TWin32FindDataW;
  isDir: Boolean;
begin
  Result := False;
  AResolvedW := '';
  segW := Utf8ToSynUnicode(ASegment);
  if segW = '' then
    exit;
  pathW := ADirW + '\' + segW;
  h := FindFirstFileW(PWideChar(pathW), data{%H-});
  if h = INVALID_HANDLE_VALUE then
    exit;
  windows.FindClose(h);
  // the directory tells us the true on-disk spelling: anything but a
  // character-exact match (case variant, 8.3 alias) is a miss
  if not WideEquals(@data.cFileName[0], segW) then
    exit;
  if (data.dwFileAttributes and PWEB_FA_REPARSE) <> 0 then
    exit; // never follow a link out of the root
  isDir := (data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0;
  if isDir <> AWantDirectory then
    exit;
  AResolvedW := pathW;
  Result := True;
end;

function ReadWholeFile(const APathW: SynUnicode;
  out Content: RawByteString): Boolean;
var
  h: THandle;
  size, done: Int64;
  lo, hi, chunk, rd: DWORD;
begin
  Result := False;
  Content := '';
  h := CreateFileW(PWideChar(APathW), GENERIC_READ, FILE_SHARE_READ,
    nil, OPEN_EXISTING, 0, 0);
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    // confinement is re-proven on the OPEN handle: the walk verified
    // each segment, but a component swapped for a link between check
    // and open would resolve elsewhere - the kernel's normalized path
    // of what was actually opened must equal the expected path
    // character-exactly, or the read fails closed
    if FinalPathOfHandle(h) <> APathW then
      exit;
    hi := 0;
    lo := windows.GetFileSize(h, @hi);
    if (lo = INVALID_FILE_SIZE) and
       (GetLastError <> NO_ERROR) then
      exit;
    size := (Int64(hi) shl 32) or lo;
    if (size < 0) or
       (size > High(Integer)) then
      exit; // v1 assets are materialised: bounded by design
    SetLength(Content, size);
    done := 0;
    while done < size do
    begin
      chunk := $100000;
      if size - done < chunk then
        chunk := size - done;
      if not ReadFile(h, PByteArray(Content)^[done], chunk, rd{%H-}, nil) or
         (rd = 0) then
      begin
        Content := '';
        exit; // short read: never serve truncated bytes
      end;
      Inc(done, rd);
    end;
    Result := True;
  finally
    CloseHandle(h);
  end;
end;

function TFolderAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  dirW, resolvedW: SynUnicode;
  segStart, i, len: PtrInt;
begin
  Result := False;
  Asset.Content := '';
  Asset.ContentType := '';
  if not PWebAssetPathValid(Path) then
    exit; // stores fail closed independently of the URI layer
  dirW := fRootW;
  len := Length(Path);
  segStart := 1;
  for i := 1 to len + 1 do
    if (i > len) or
       (Path[i] = '/') then
    begin
      if not ResolveSegment(dirW, Copy(Path, segStart, i - segStart),
           {wantDir=}i <= len, resolvedW) then
        exit;
      dirW := resolvedW;
      segStart := i + 1;
    end;
  if not ReadWholeFile(dirW, Asset.Content) then
    exit;
  Asset.ContentType := PWebAssetMimeType(Path);
  Result := True;
end;

{$else}

uses
  baseunix,
  unix;

{ POSIX branch - hardened for CAP-7L to the same standard as the Windows
  branch above, because the ratified rule is that the dev folder store
  behaves like the packaged archive store, not like whatever filesystem
  happens to sit underneath it. Three properties the pre-CAP-7 fallback
  did not actually have:

    - symlink refusal is EXPLICIT: lstat (never stat) on every segment,
      plus O_NOFOLLOW on the final open, instead of trusting the RTL's
      attribute reporting;
    - exact case is proven by READING the directory and comparing the
      on-disk bytes, never by asking the filesystem to match a name -
      the dev host mounts the repository on DrvFs and CI images can
      carry ext4 casefold or an NTFS mount, all of which fold case;
    - confinement is re-proven on the OPEN descriptor via /proc/self/fd,
      the direct counterpart of the Windows GetFinalPathNameByHandleW
      re-proof, so a component swapped for a link between check and open
      cannot serve a file from somewhere else.

  Only regular files are ever served: any special inode that happens to
  sit in frontend/dist/ - a device node, a FIFO, a named endpoint - is a
  miss, never something the handler starts reading from. }

const
  /// the kernel's own answer to "what did I actually open?"
  PWEB_PROC_SELF_FD = '/proc/self/fd/';

// kernel-resolved absolute path of an open descriptor, '' on failure.
// An unlinked file reads back as '<path> (deleted)', which simply fails
// the equality re-proof below - fail-closed either way.
function FinalPathOfFd(fd: cint): RawByteString;
begin
  Result := RawByteString(FpReadLink(PWEB_PROC_SELF_FD + IntToStr(fd)));
  if (Result = '') or
     (Result[1] <> '/') then
    Result := '';
end;

// byte-exact comparison against a NUL-terminated directory entry, the
// POSIX twin of WideEquals above
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
  Result := P^ = #0; // same length too
end;

constructor TFolderAssetStore.Create(const ARootDir: TFileName);
var
  configured: RawByteString;
  fd: cint;
begin
  inherited Create;
  if ARootDir = '' then
    raise EPWebFolderAssetStore.Create('folder asset root is empty');
  // cast, never convert: the path is bytes and must reach the kernel as
  // the same bytes under both the plain and the UTF-8 RTL regimes
  configured := RawByteString(
    ExcludeTrailingPathDelimiter(ExpandFileName(ARootDir)));
  if configured = '' then
    configured := '/'; // ExcludeTrailingPathDelimiter('/') empties it
  // canonicalize ONCE through the kernel: a link in the CONFIGURED root
  // resolves here, so confinement below is relative to the real
  // directory. O_DIRECTORY also makes "a file was passed as the root" a
  // construction-time refusal rather than a silent 404 stream later.
  fd := FpOpen(configured, O_RDONLY or O_DIRECTORY);
  if fd < 0 then
    raise EPWebFolderAssetStore.CreateFmt(
      'folder asset root does not exist: %s', [ARootDir]);
  try
    fRoot := FinalPathOfFd(fd);
  finally
    FpClose(fd);
  end;
  if fRoot = '' then
    raise EPWebFolderAssetStore.CreateFmt(
      'folder asset root cannot be resolved: %s', [ARootDir]);
end;

function TFolderAssetStore.ResolveSegment(const ADir: RawByteString;
  const ASegment: RawUtf8; AWantDirectory: Boolean;
  out AResolved: RawByteString): Boolean;
var
  path: RawByteString;
  info: stat;
  dirp: pDir;
  entry: pDirent;
  found: Boolean;
begin
  Result := False;
  AResolved := '';
  if ASegment = '' then
    exit;
  path := ADir + '/' + RawByteString(ASegment);
  // lstat, NOT stat: a symlink must be refused, never followed
  if FpLstat(path, info{%H-}) <> 0 then
    exit;
  if fpS_ISLNK(info.st_mode) then
    exit; // never follow a link out of the root
  if AWantDirectory then
  begin
    if not fpS_ISDIR(info.st_mode) then
      exit;
  end
  else if not fpS_ISREG(info.st_mode) then
    exit; // only regular files are assets
  // the directory itself tells us the true on-disk spelling: anything
  // but a byte-exact match (a case variant on a folding mount) is a miss
  dirp := FpOpendir(ADir);
  if dirp = nil then
    exit;
  found := False;
  try
    repeat
      entry := FpReaddir(dirp^);
      if entry = nil then
        break;
      if EntryEquals(PAnsiChar(@entry^.d_name[0]), ASegment) then
      begin
        found := True;
        break;
      end;
    until False;
  finally
    FpClosedir(dirp^);
  end;
  if not found then
    exit;
  AResolved := path;
  Result := True;
end;

function ReadWholeFile(const APath: RawByteString;
  out Content: RawByteString): Boolean;
var
  fd: cint;
  info: stat;
  size, done: Int64;
  chunk, rd: PtrInt;
begin
  Result := False;
  Content := '';
  // O_NOFOLLOW: if the final component became a symlink between the walk
  // and this open, the open FAILS instead of resolving elsewhere
  fd := FpOpen(APath, O_RDONLY or O_NOFOLLOW);
  if fd < 0 then
    exit;
  try
    // confinement is re-proven on the OPEN descriptor: the walk verified
    // each segment, but a component swapped for a link between check and
    // open would resolve elsewhere - the kernel's own path for what was
    // actually opened must equal the expected path byte-exactly, or the
    // read fails closed
    if FinalPathOfFd(fd) <> APath then
      exit;
    if FpFstat(fd, info{%H-}) <> 0 then
      exit;
    if not fpS_ISREG(info.st_mode) then
      exit; // what we opened is not the regular file the walk saw
    size := info.st_size;
    if (size < 0) or
       (size > High(Integer)) then
      exit; // v1 assets are materialised: bounded by design
    SetLength(Content, size);
    done := 0;
    while done < size do
    begin
      chunk := $100000;
      if size - done < chunk then
        chunk := size - done;
      rd := FpRead(fd, PByteArray(Content)^[done], chunk);
      if rd <= 0 then
      begin
        Content := '';
        exit; // short read: never serve truncated bytes
      end;
      Inc(done, rd);
    end;
    Result := True;
  finally
    FpClose(fd);
  end;
end;

function TFolderAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  dir, resolved: RawByteString;
  segStart, i, len: PtrInt;
begin
  Result := False;
  Asset.Content := '';
  Asset.ContentType := '';
  if not PWebAssetPathValid(Path) then
    exit; // stores fail closed independently of the URI layer
  dir := fRoot;
  len := Length(Path);
  segStart := 1;
  for i := 1 to len + 1 do
    if (i > len) or
       (Path[i] = '/') then
    begin
      if not ResolveSegment(dir, Copy(Path, segStart, i - segStart),
           {wantDir=}i <= len, resolved) then
        exit;
      dir := resolved;
      segStart := i + 1;
    end;
  if not ReadWholeFile(dir, Asset.Content) then
    exit;
  Asset.ContentType := PWebAssetMimeType(Path);
  Result := True;
end;

{$endif WINDOWS}

end.
