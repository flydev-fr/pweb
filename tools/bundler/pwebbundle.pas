program pwebbundle;

{ CAP-6 release bundler: packs an already-built frontend dist into the
  deterministic app.pwb release container.

    pwebbundle <distdir> <out.pwb> [--min-runtime=X.Y.Z]
               [--max-asset-bytes=N] [--include-sourcemaps]
    pwebbundle --verify <bundle.pwb> [iterations]

  The walk is deterministic: files are collected recursively, then
  globally sorted by canonical logical path BYTES - filesystem
  enumeration order never reaches the archive. Classification is by
  path/name only (ratified D3): secret/dev artifacts are hard errors,
  *.map is excluded by default with a logged skip unless
  --include-sourcemaps opts in, and a root manifest.json in the input
  is refused - the bundler owns that entry. The manifest stamps
  protocol from PWEB_PROTOCOL_VERSION and minRuntime from
  PWEB_RUNTIME_VERSION unless --min-runtime overrides it. All
  validation, determinism, self-validation and the atomic replace live
  in pweb.assets.bundle (the writer this CLI drives).

  --verify reopens an existing bundle through the PRODUCTION loader
  with this runtime's injected facts and reads the two required
  documents; the optional iteration count repeats the full
  load-and-read cycle for observational timing (the kernel keeps ZIP
  as the container unless a benchmark beats it - these are the
  ZIP-side numbers).

  This program never compiles a frontend: its input is a built dist. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  {$ifdef OSWINDOWS}
  windows,
  {$endif OSWINDOWS}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  pweb.rpc.intf,     // PWEB_PROTOCOL_VERSION, PWEB_SUPPORTED_PROTOCOLS
  pweb.rpc.support,  // PWEB_RUNTIME_VERSION
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.bundle;

type
  TInputFile = record
    Logical: RawUtf8;  // canonical forward-slash logical path
    Native: TFileName; // absolute on-disk path
  end;

var
  inputs: array of TInputFile;
  // argv as this program reads it, indexed the way ParamStr indexes it:
  // [1 .. High] are the arguments. [0] is the image, which this program
  // never reads - on Windows it is the command line's OWN spelling of the
  // executable and therefore not necessarily ParamStr(0)'s module path,
  // so a future caller wanting the image must ask for it, not take [0]
  args: array of string;

{$ifdef OSWINDOWS}
// argv from the KERNEL rather than through the RTL's Ansi conversion.
//
// MEASURED, and it is the same defect PWebCliImageDir closed one layer in:
// the RTL's Windows argv is an Ansi conversion of the command line, so
// `pwebbundle "<a directory whose name carries a non-ASCII character>\dist"`
// reaches ParamStr as codepage bytes that are then read back as UTF-8 -
// mORMot sets DefaultSystemCodePage to CP_UTF8 for the whole process - and
// the pack stage refuses a dist directory that is plainly there.
// GetCommandLineW answers in UTF-16 and cannot lose a character. It is the
// only shell32 import here and it PARSES rather than executes: nothing in
// this program launches anything.
//
// TWO CONSEQUENCES, both deliberate. First, the splitting GRAMMAR on Windows
// is now the C runtime's, which is the grammar PWebCliWindowsCommandLine
// quotes FOR - so the CLI's own spawns round-trip exactly, where before two
// different parsers faced one quoter. Second, this is a SECOND COPY of
// pweb.cli.platform's PWebCliRawArgs, and it has to be: CAP-6 compiles this
// program against the assets and rpc layers alone, and depending on a
// tools/pweb unit would be the layering the CAP-6 gate exists to prove.
function CommandLineToArgvW(lpCmdLine: PWideChar;
  var pNumArgs: Integer): PPWideChar;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

procedure ReadArgs;
var
  argv, p: PPWideChar;
  n, i: Integer;
begin
  n := 0;
  argv := CommandLineToArgvW(GetCommandLineW, n);
  // NO FALLBACK TO ParamStr. The RTL argv is the defect this function
  // exists to route around, so quietly reverting to it would undo the fix
  // in the one case nobody watches - and leave the same misleading
  // "directory not found" behind. If the kernel cannot split its own
  // command line, this program does not know its arguments and says so.
  if (argv = nil) or
     (n <= 0) then
    raise Exception.CreateFmt(
      'cannot read the command line (Win32 error %d)', [GetLastError]);
  try
    SetLength(args, n);
    for i := 0 to n - 1 do
    begin
      p := argv;
      Inc(p, i);
      // the same explicit UTF-16 -> UTF-8 -> TFileName round trip Collect
      // uses below, and lossless for the same reason
      args[i] := Utf8ToString(SynUnicodeToUtf8(SynUnicode(WideString(p^))));
    end;
  finally
    LocalFree(HLOCAL(argv));
  end;
end;
{$else}
procedure ReadArgs;
var
  i: PtrInt;
begin
  // POSIX argv is BYTES and the RTL hands them over unchanged, so there is
  // nothing for this program to ask the kernel for
  SetLength(args, ParamCount + 1);
  for i := 0 to ParamCount do
    args[i] := ParamStr(i);
end;
{$endif OSWINDOWS}

// ParamCount and ParamStr, exactly - so every call site below reads the way
// it always did and only the SOURCE of the bytes moved. The clamp and the
// range check below are unreachable through either ReadArgs (both fill
// args[0] before any argument) and exist so that a future caller reaching
// past the end gets '' rather than a range error inside a build tool.
function ArgCount: Integer;
begin
  Result := Length(args) - 1;
  if Result < 0 then
    Result := 0;
end;

function ArgStr(Index: Integer): string;
begin
  if (Index < 0) or
     (Index > High(args)) then
    Result := ''
  else
    Result := args[Index];
end;

{$ifdef OSWINDOWS}
// The walk goes straight to the wide Win32 API over explicit UTF-8 <->
// UTF-16 conversions, mirroring the ratified TFolderAssetStore
// precedent: the RTL Ansi filesystem layer depends on runtime codepage
// state and mistranslates cross-unit concatenations, so a build tool
// whose output must be deterministic gets one path to the kernel.
procedure Collect(const BaseNative: TFileName;
  const RelLogical: RawUtf8);
var
  h: THandle;
  fd: WIN32_FIND_DATAW;
  patternW, nameW: UnicodeString;
  nameU, logical: RawUtf8;
  native: TFileName;
begin
  patternW := UnicodeString(Utf8ToSynUnicode(StringToUtf8(BaseNative)))
    + '\*';
  h := FindFirstFileW(PWideChar(patternW), @fd);
  if h = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('cannot enumerate dist directory: %s',
      [BaseNative]);
  try
    repeat
      nameW := fd.cFileName; // up to the terminating NUL
      if (nameW = '.') or
         (nameW = '..') then
        continue;
      nameU := SynUnicodeToUtf8(SynUnicode(nameW));
      native := BaseNative + PathDelim + Utf8ToString(nameU);
      if RelLogical = '' then
        logical := nameU
      else
        logical := RelLogical + '/' + nameU;
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
        raise Exception.CreateFmt(
          'reparse point refused in dist: %s', [native]);
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        Collect(native, logical)
      else
      begin
        SetLength(inputs, Length(inputs) + 1);
        inputs[High(inputs)].Logical := logical;
        inputs[High(inputs)].Native := native;
      end;
    until not FindNextFileW(h, fd);
    // a mid-enumeration failure must never silently truncate the
    // corpus: the only legitimate loop exit is "no more files"
    if GetLastError <> ERROR_NO_MORE_FILES then
      raise Exception.CreateFmt(
        'directory enumeration failed in %s (Win32 error %d)',
        [BaseNative, GetLastError]);
  finally
    windows.FindClose(h);
  end;
end;
{$else}
procedure Collect(const BaseNative: TFileName;
  const RelLogical: RawUtf8);
var
  sr: TSearchRec;
  native: TFileName;
  logical: RawUtf8;
begin
  if FindFirst(BaseNative + PathDelim + '*', faAnyFile{%H-}, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') then
        continue;
      native := BaseNative + PathDelim + sr.Name;
      if RelLogical = '' then
        logical := StringToUtf8(sr.Name)
      else
        logical := RelLogical + '/' + StringToUtf8(sr.Name);
      if (sr.Attr and $00000400) <> 0 then // reparse point / symlink
        raise Exception.CreateFmt(
          'reparse point refused in dist: %s', [native]);
      if (sr.Attr and faDirectory{%H-}) <> 0 then
        Collect(native, logical)
      else
      begin
        SetLength(inputs, Length(inputs) + 1);
        inputs[High(inputs)].Logical := logical;
        inputs[High(inputs)].Native := native;
      end;
    until FindNext(sr) <> 0;
  finally
    SysUtils.FindClose(sr);
  end;
end;
{$endif OSWINDOWS}

// global bytewise sort of the canonical logical names - the archive
// order is a function of the logical corpus, never of FS enumeration
procedure SortInputs;
var
  i, j: PtrInt;
  tmp: TInputFile;
begin
  for i := 1 to High(inputs) do
  begin
    tmp := inputs[i];
    j := i - 1;
    while (j >= 0) and
          (CompareStr(inputs[j].Logical, tmp.Logical) > 0) do
    begin
      inputs[j + 1] := inputs[j];
      Dec(j);
    end;
    inputs[j + 1] := tmp;
  end;
end;

// True when Path lexically resolves below Dir (both already absolute)
// - ASCII-case-insensitive: Windows paths compare caselessly
function InsideDir(const Path, Dir: TFileName): Boolean;
begin
  Result := (Length(Path) > Length(Dir) + 1) and
    SameText(Copy(Path, 1, Length(Dir) + 1), Dir + PathDelim);
end;

procedure Usage;
begin
  WriteLn(StdErr,
    'usage: pwebbundle <distdir> <out.pwb> [--min-runtime=X.Y.Z]');
  WriteLn(StdErr,
    '                  [--max-asset-bytes=N] [--include-sourcemaps]');
  WriteLn(StdErr,
    '       pwebbundle --verify <bundle.pwb> [iterations]');
end;

procedure RunVerify;
var
  bundleFile: TFileName;
  iterations, iter: Integer;
  store: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
  started, elapsed: Int64;
  totalBytes: Int64;
begin
  if (ArgCount < 2) or
     (ArgCount > 3) then
  begin
    Usage;
    raise Exception.Create('--verify expects <bundle.pwb> [iterations]');
  end;
  bundleFile := ExpandFileName(ArgStr(2));
  iterations := 1;
  if ArgCount = 3 then
    iterations := StrToIntDef(ArgStr(3), 0);
  if iterations < 1 then
    raise Exception.Create('invalid iteration count');
  totalBytes := 0;
  started := GetTickCount64;
  for iter := 1 to iterations do
  begin
    store := nil;
    if not PWebBundleLoadFile(bundleFile, PWEB_SUPPORTED_PROTOCOLS,
         PWEB_RUNTIME_VERSION, store, reason) then
      raise Exception.Create('bundle REFUSED (' +
        Utf8ToString(PWebBundleRefusalText(reason)) + ')');
    // read the two required documents through the production store
    if not store.TryRead(PWEB_ASSET_DEFAULT_DOCUMENT, asset) then
      raise Exception.Create('index document unreadable');
    Inc(totalBytes, Length(asset.Content));
    if not store.TryRead(PWEB_BUNDLE_MANIFEST_NAME, asset) then
      raise Exception.Create('manifest unreadable');
    Inc(totalBytes, Length(asset.Content));
    store := nil;
  end;
  elapsed := GetTickCount64 - started;
  WriteLn('pwebbundle: verify OK (', iterations,
    ' load+read cycle(s) in ', elapsed, ' ms, ', totalBytes,
    ' bytes served)');
end;

procedure RunBuild;
var
  distDir, outFile: TFileName;
  minRuntime: RawUtf8;
  maxAssetBytes: Int64;
  includeSourcemaps: Boolean;
  positional, i, bad: Integer;
  arg: string;
  argU: RawUtf8;
  entries: array of TPWebBundleEntry;
  used: PtrInt;
  content: RawByteString;
  manifest: TPWebBundleManifest;
  err: RawUtf8;
begin
  distDir := '';
  outFile := '';
  minRuntime := PWEB_RUNTIME_VERSION;
  maxAssetBytes := 0; // writer applies the ratified 32 MiB default
  includeSourcemaps := False;
  positional := 0;
  for i := 1 to ArgCount do
  begin
    arg := ArgStr(i);
    if Copy(arg, 1, 2) = '--' then
    begin
      argU := StringToUtf8(arg);
      if argU = '--include-sourcemaps' then
        includeSourcemaps := True
      else if Copy(argU, 1, 14) = '--min-runtime=' then
      begin
        minRuntime := Copy(argU, 15, MaxInt);
        if not PWebSemVerValid(minRuntime) then
          raise Exception.Create(
            '--min-runtime must be strict numeric X.Y.Z');
      end
      else if Copy(argU, 1, 18) = '--max-asset-bytes=' then
      begin
        maxAssetBytes := StrToInt64Def(
          Utf8ToString(Copy(argU, 19, MaxInt)), -1);
        if maxAssetBytes <= 0 then
          raise Exception.Create(
            '--max-asset-bytes must be a positive integer');
      end
      else
      begin
        Usage;
        raise Exception.CreateFmt('unknown option: %s', [arg]);
      end;
    end
    else
    begin
      Inc(positional);
      case positional of
        1:
          distDir := ExcludeTrailingPathDelimiter(ExpandFileName(arg));
        2:
          outFile := ExpandFileName(arg);
      else
        begin
          Usage;
          raise Exception.Create('too many arguments');
        end;
      end;
    end;
  end;
  if (distDir = '') or
     (outFile = '') then
  begin
    Usage;
    raise Exception.Create('missing <distdir> or <out.pwb>');
  end;
  if not DirectoryExists(distDir) then
    raise Exception.CreateFmt('dist directory not found: %s', [distDir]);
  // the output (and its temp sibling) must live OUTSIDE the input
  // tree, or a rebuild would package the previous bundle into itself
  if InsideDir(outFile, distDir) or
     InsideDir(PWebBundleTempFileName(outFile), distDir) then
    raise Exception.CreateFmt(
      'output %s resolves inside the input dist %s - refuse',
      [outFile, distDir]);
  inputs := nil;
  Collect(distDir, '');
  if Length(inputs) = 0 then
    raise Exception.CreateFmt('dist directory is empty: %s', [distDir]);
  SortInputs;
  // ratified D3 classification pass, by name only - report EVERY
  // offender before failing, so a broken dist is fixed in one round
  bad := 0;
  for i := 0 to High(inputs) do
    case PWebBundleClassifyName(inputs[i].Logical) of
      pbcSecret:
        begin
          WriteLn(StdErr, 'pwebbundle: secret/development artifact ',
            'refused by name: ', inputs[i].Logical);
          Inc(bad);
        end;
      pbcReservedManifest:
        begin
          WriteLn(StdErr, 'pwebbundle: input must not contain a ',
            'root manifest.json (the bundler generates it): ',
            inputs[i].Logical);
          Inc(bad);
        end;
    end;
  if bad > 0 then
    raise Exception.CreateFmt(
      '%d refused input file(s) - nothing was written', [bad]);
  SetLength(entries, Length(inputs));
  used := 0;
  for i := 0 to High(inputs) do
  begin
    if (PWebBundleClassifyName(inputs[i].Logical) = pbcSourceMap) and
       not includeSourcemaps then
    begin
      WriteLn('pwebbundle: excluded sourcemap: ', inputs[i].Logical,
        ' (--include-sourcemaps to opt in)');
      continue;
    end;
    content := StringFromFile(inputs[i].Native);
    // an unreadable (locked/denied) file also yields '' - verify the
    // real size so the build fails instead of packaging silence
    if Int64(Length(content)) <> FileSize(inputs[i].Native) then
      raise Exception.CreateFmt('unreadable input file: %s',
        [inputs[i].Native]);
    entries[used].Name := inputs[i].Logical;
    entries[used].Content := content;
    Inc(used);
  end;
  SetLength(entries, used);
  // stamp the ratified compat facts from the ONE native source of
  // truth - the loader will re-check them, parameter-injected
  manifest.Protocol := PWEB_PROTOCOL_VERSION;
  manifest.MinRuntime := minRuntime;
  if not PWebBundleWrite(outFile, entries, manifest, maxAssetBytes,
       err) then
    raise Exception.Create(Utf8ToString(err));
  WriteLn('pwebbundle: ', outFile, ' (', used,
    ' asset(s) + manifest.json, protocol ', manifest.Protocol,
    ', minRuntime ', manifest.MinRuntime, ')');
end;

begin
  ExitCode := 0;
  try
    ReadArgs;
    if (ArgCount >= 1) and
       (ArgStr(1) = '--verify') then
      RunVerify
    else
      RunBuild;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
