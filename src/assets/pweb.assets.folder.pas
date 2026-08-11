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

type
  EPWebFolderAssetStore = class(Exception);

  TFolderAssetStore = class(TInterfacedObject, IAssetStore)
  private
    fRootW: SynUnicode; // absolute UTF-16 root, no trailing delimiter
    // resolve one segment inside ADirW: it must exist with the exact
    // on-disk spelling, must not be a reparse point, and must match
    // the wanted kind; returns False otherwise
    function ResolveSegment(const ADirW: SynUnicode;
      const ASegment: RawUtf8; AWantDirectory: Boolean;
      out AResolvedW: SynUnicode): Boolean;
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

{ POSIX fallback - not part of the CAP-4 Windows gate. Case-sensitive
  lookup and reparse refusal rely on the native filesystem semantics
  plus the same per-segment walk; revisited for the CAP-7 platforms. }

const
  PWEB_FA_REPARSE = $00000400; // faSymLink

constructor TFolderAssetStore.Create(const ARootDir: TFileName);
var
  root: TFileName;
begin
  inherited Create;
  if ARootDir = '' then
    raise EPWebFolderAssetStore.Create('folder asset root is empty');
  root := ExcludeTrailingPathDelimiter(ExpandFileName(ARootDir));
  if not DirectoryExists(root) then
    raise EPWebFolderAssetStore.CreateFmt(
      'folder asset root does not exist: %s', [root]);
  fRootW := Utf8ToSynUnicode(StringToUtf8(root));
end;

function TFolderAssetStore.ResolveSegment(const ADirW: SynUnicode;
  const ASegment: RawUtf8; AWantDirectory: Boolean;
  out AResolvedW: SynUnicode): Boolean;
var
  segW: SynUnicode;
  native: TFileName;
  sr: TSearchRec;
  isDir: Boolean;
begin
  Result := False;
  AResolvedW := '';
  segW := Utf8ToSynUnicode(ASegment);
  if segW = '' then
    exit;
  native := Utf8ToString(ASegment);
  if FindFirst(Utf8ToString(SynUnicodeToUtf8(ADirW)) + PathDelim + native,
       faAnyFile, sr) <> 0 then
    exit;
  try
    if sr.Name <> native then
      exit;
    if (sr.Attr and PWEB_FA_REPARSE) <> 0 then
      exit;
    isDir := (sr.Attr and faDirectory) <> 0;
    if isDir <> AWantDirectory then
      exit;
    AResolvedW := ADirW + '/' + segW;
    Result := True;
  finally
    FindClose(sr);
  end;
end;

function ReadWholeFile(const APathW: SynUnicode;
  out Content: RawByteString): Boolean;
var
  h: THandle;
  size, done: Int64;
  rd: LongInt;
  native: TFileName;
begin
  Result := False;
  Content := '';
  native := Utf8ToString(SynUnicodeToUtf8(APathW));
  h := FileOpen(native, fmOpenRead or fmShareDenyWrite);
  if h = THandle(-1) then
    exit;
  try
    size := FileSeek(h, Int64(0), fsFromEnd);
    if (size < 0) or
       (FileSeek(h, Int64(0), fsFromBeginning) <> 0) then
      exit;
    SetLength(Content, size);
    done := 0;
    while done < size do
    begin
      rd := FileRead(h, PByteArray(Content)^[done], size - done);
      if rd <= 0 then
      begin
        Content := '';
        exit;
      end;
      Inc(done, rd);
    end;
    Result := True;
  finally
    FileClose(h);
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
    exit;
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

{$endif WINDOWS}

end.
