program pwebqjspack;

{ CAP-9C1 private QuickJS plugin packager.

    pwebqjspack <trusted-list> <staging-dir> [--quickjs-src=DIR]
                [--mormot-lock=FILE]

  NOT a public CLI, and deliberately so: CAP-9C1 must not introduce one.
  It is a build-time tool with a fixed argument shape, invoked by the
  CAP-9C1 gate scripts. CAP-10 may later drive the same library
  functions from the `pweb` CLI; nothing here is that CLI.

  What it does, in order:

    1. read and strictly parse the TRUSTED build-time plugin list;
    2. for each listed plugin, walk its source root and resolve its
       COMPLETE module graph by loading it through the unchanged
       production CAP-9B1/B2 path over a TFolderAssetStore - there is no
       second import scanner anywhere in PWeb, so cross-plugin edges,
       missing nodes, dynamic/bare/URL imports and every depth, count
       and size bound are refused here by the same code that refuses
       them at run time;
    3. prove the source tree holds NOTHING the graph does not reach:
       an unreferenced file is a build error naming the exact path;
    4. write plugins.zip deterministically - canonical names sorted
       bytewise, the CAP-6 fixed timestamp and deflate level, no extra
       fields - into a temp sibling, re-open it through TZipRead AND the
       production TZipAssetStore for raw-name, enumeration and content
       compares, then atomically install it;
    5. emit the generated native registry include, whose every field is
       re-validated and emitted as printable ASCII or refused - no
       arbitrary text can become Pascal source;
    6. stage LICENSE.quickjs, assembled from the PINNED mORMot QuickJS
       sources with nothing fabricated;
    7. stage the inventory and build-info evidence files.

  A packaging run reaches the invocation bridge ZERO times: the policy
  it builds denies everything and the bridge it builds refuses and
  counts, and a nonzero count aborts the build. Combined with the frozen
  Loading gate (pweb.invoke is refused for the whole staged load), a
  packaging run cannot produce a backend side effect.

  It never grants anything: descriptors are built with the EMPTY
  capability set, and capabilities are not part of the registry at all.
  It never lowers a bound: engine and package limits are the ratified
  defaults, not build-time input. }

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
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.folder,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.script.package,
  pweb.script.quickjs,
  pweb.script.plugin,
  pweb.script.release,
  pweb.script.startup;

const
  TOOL_ID = 'pwebqjspack';
  DEFAULT_QUICKJS_SRC = 'deps/mormot2/res/static/libquickjs';
  DEFAULT_MORMOT_LOCK = 'mormot.lock';
  READY_WAIT_MS = 30000;
  JOIN_MS = 30000;

  { The pinned files that participate in the static QuickJS build: the
    amalgamation inputs tools/build_quickjs_darwin.sh concatenates
    (which is upstream's own compile-all.sh recipe) plus every pinned
    header they include. Order is fixed, so the artifact is
    deterministic. }
  LICENSE_SOURCES: array[0..16] of RawUtf8 = (
    'cutils.h',
    'cutils.c',
    'libbf.h',
    'libbf.c',
    'libregexp.h',
    'libregexp.c',
    'libregexp-opcode.h',
    'libunicode.h',
    'libunicode.c',
    'libunicode-table.h',
    'list.h',
    'quickjs.h',
    'quickjs.c',
    'quickjs-atom.h',
    'quickjs-opcode.h',
    'quickjs-jsx.h',
    'quickjs-version.h');

type
  { Denies every method for every principal. A packaging run has no
    business authorizing anything, and this makes that structural rather
    than incidental. }
  TDenyAllPolicy = class(TInterfacedObject, ICapabilityPolicy)
  public
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
  end;

  { Refuses and COUNTS. A nonzero count aborts the build: it would mean
    packaged top-level code reached the bridge, which the frozen Loading
    gate is supposed to make impossible. }
  TRefusingBridge = class(TInterfacedObject, IInvocationBridge)
  public
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TSourceFactory = class
  public
    function Make: IInvocationSource;
  end;

var
  gScheduler: TInvocationScheduler;
  gSchedulerRef: IInvocationScheduler;
  gPolicyRef: ICapabilityPolicy;
  gBridge: IInvocationBridge;
  gFactory: TSourceFactory;
  gMakeSource: TPWebPluginSourceFactory;
  gBridgeArrivals: LongInt;

function TDenyAllPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
begin
  Result := False;
end;

function TRefusingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  InterlockedIncrement(gBridgeArrivals);
  Result := PWebDefaultErrorResult(pecForbidden);
end;

function TSourceFactory.Make: IInvocationSource;
var
  lim: TPWebSourceLimits;
begin
  lim := Default(TPWebSourceLimits);
  lim.MaxConcurrent := 2;
  lim.MaxQueueSize := 4;
  Result := gScheduler.RegisterSource(lim);
end;

procedure Die(const AMessage: RawUtf8);
begin
  WriteLn(StdErr, TOOL_ID, ': ', AMessage);
  Halt(2);
end;

procedure Say(const AMessage: RawUtf8);
begin
  WriteLn(TOOL_ID, ': ', AMessage);
end;

function IntStr(AValue: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(AValue));
end;

{ The trusted list carries forward-slash paths so it reads the same on
  every platform. FindFirst on Windows refuses a mixed-separator mask
  (MEASURED: ERROR_PATH_NOT_FOUND), so every path is converted to native
  separators exactly once, here. }
function NativePath(const ALogical: RawUtf8): TFileName;
begin
  Result := ExpandFileName(TFileName(StringReplace(Utf8ToString(ALogical),
    '/', PathDelim, [rfReplaceAll])));
end;

{ ---------------- deterministic source walk ------------------------------ }

var
  walked: TRawUtf8DynArray;
  walkedCount: Integer;

procedure Collected(const ALogical: RawUtf8);
begin
  if walkedCount = Length(walked) then
    SetLength(walked, walkedCount * 2 + 16);
  walked[walkedCount] := ALogical;
  Inc(walkedCount);
end;

{$ifdef OSWINDOWS}
{ The walk goes straight to the wide Win32 API over explicit UTF-8 <->
  UTF-16 conversions, mirroring tools/bundler/pwebbundle.pas and the
  ratified TFolderAssetStore precedent: the RTL Ansi filesystem layer
  depends on runtime codepage state and mistranslates cross-unit
  concatenations, so a build tool whose output must be deterministic
  gets one path to the kernel.

  MEASURED here too, and worth recording because it is silent: the RTL
  FindFirst refused this tool's concatenated root with
  ERROR_PATH_NOT_FOUND while mORMot's own DirectoryExists accepted the
  very same string, so the failure surfaced as "plugin source root is
  empty" rather than as an error. }
procedure WalkRoot(const ABaseNative: TFileName; const ARelLogical: RawUtf8);
var
  h: THandle;
  fd: WIN32_FIND_DATAW;
  patternW, nameW: UnicodeString;
  nameU, logical: RawUtf8;
  native: TFileName;
begin
  patternW := UnicodeString(Utf8ToSynUnicode(StringToUtf8(ABaseNative))) +
    '\*';
  h := FindFirstFileW(PWideChar(patternW), @fd);
  if h = INVALID_HANDLE_VALUE then
    Die('cannot enumerate a plugin source root: ' +
      StringToUtf8(ABaseNative));
  try
    repeat
      nameW := fd.cFileName;   // up to the terminating NUL
      if (nameW = '.') or
         (nameW = '..') then
        continue;
      nameU := SynUnicodeToUtf8(SynUnicode(nameW));
      native := ABaseNative + PathDelim + Utf8ToString(nameU);
      if ARelLogical = '' then
        logical := nameU
      else
        logical := ARelLogical + '/' + nameU;
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
        Die('reparse point refused in a plugin source root: ' +
          StringToUtf8(native));
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        WalkRoot(native, logical)
      else
        Collected(logical);
    until not FindNextFileW(h, fd);
    // a mid-enumeration failure must never silently truncate the corpus:
    // the only legitimate loop exit is "no more files"
    if GetLastError <> ERROR_NO_MORE_FILES then
      Die('directory enumeration failed in ' + StringToUtf8(ABaseNative) +
        ' (Win32 error ' + IntStr(GetLastError) + ')');
  finally
    windows.FindClose(h);
  end;
end;
{$else}
procedure WalkRoot(const ABaseNative: TFileName; const ARelLogical: RawUtf8);
var
  sr: TSearchRec;
  native: TFileName;
  logical: RawUtf8;
begin
  if FindFirst(ABaseNative + PathDelim + '*', faAnyFile{%H-}, sr) <> 0 then
    Die('cannot enumerate a plugin source root: ' +
      StringToUtf8(ABaseNative));
  try
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') then
        continue;
      native := ABaseNative + PathDelim + sr.Name;
      if ARelLogical = '' then
        logical := StringToUtf8(sr.Name)
      else
        logical := ARelLogical + '/' + StringToUtf8(sr.Name);
      if (sr.Attr and $00000400) <> 0 then   // reparse point / symlink
        Die('reparse point refused in a plugin source root: ' +
          StringToUtf8(native));
      if (sr.Attr and faDirectory{%H-}) <> 0 then
        WalkRoot(native, logical)
      else
        Collected(logical);
    until FindNext(sr) <> 0;
  finally
    SysUtils.FindClose(sr);
  end;
end;
{$endif OSWINDOWS}

function WalkPluginRoot(const ARoot: TFileName): TRawUtf8DynArray;
var
  i, j: PtrInt;
  tmp: RawUtf8;
begin
  walked := nil;
  walkedCount := 0;
  WalkRoot(ExcludeTrailingPathDelimiter(ARoot), '');
  SetLength(walked, walkedCount);
  // bytewise sort, so the tool's own diagnostics are deterministic too
  for i := 1 to High(walked) do
  begin
    tmp := walked[i];
    j := i - 1;
    while (j >= 0) and
          (CompareStr(walked[j], tmp) > 0) do
    begin
      walked[j + 1] := walked[j];
      Dec(j);
    end;
    walked[j + 1] := tmp;
  end;
  Result := walked;
end;

{ ---------------- the QuickJS license artifact --------------------------- }

{ CRLF -> LF. The pinned sources check out CRLF on Windows
  (core.autocrlf=true) and LF everywhere else - MEASURED - so without
  this the artifact could not be byte-identical on four targets. The
  WORDS are verbatim; only the line terminator is canonicalized, and the
  artifact says so about itself. }
function NormalizeLf(const AText: RawByteString): RawByteString;
var
  i, n: PtrInt;
begin
  Result := '';
  n := Length(AText);
  SetLength(Result, n);
  n := 0;
  for i := 1 to Length(AText) do
    if AText[i] <> #13 then
    begin
      Inc(n);
      Result[n] := AText[i];
    end;
  SetLength(Result, n);
end;

{ the leading /* ... */ block, verbatim, or '' when the file has none }
function LeadingNotice(const AText: RawByteString): RawByteString;
var
  i, n: PtrInt;
begin
  Result := '';
  n := Length(AText);
  i := 1;
  while (i <= n) and
        ((AText[i] = #10) or (AText[i] = ' ') or (AText[i] = #9)) do
    Inc(i);
  if (i + 1 > n) or
     (AText[i] <> '/') or
     (AText[i + 1] <> '*') then
    exit;
  n := PosEx('*/', AText, i);
  if n = 0 then
    exit;
  Result := Copy(AText, i, n + 1 - i + 1);
end;

function BuildLicense(const ASrcDir, ALockFile: TFileName): RawUtf8;
var
  i: PtrInt;
  raw, norm, notice: RawByteString;
  path: TFileName;
  commit, version: RawUtf8;
  p: PtrInt;
begin
  raw := StringFromFile(ALockFile);
  if raw = '' then
    Die('the mORMot lock file could not be read: ' + StringToUtf8(ALockFile));
  norm := NormalizeLf(raw);
  p := Pos('commit = ', norm);
  if p = 0 then
    Die('no `commit = ` line in ' + StringToUtf8(ALockFile));
  commit := '';
  Inc(p, Length('commit = '));
  while (p <= Length(norm)) and (norm[p] > ' ') do
  begin
    commit := commit + norm[p];
    Inc(p);
  end;
  if Length(commit) <> 40 then
    Die('the mORMot pin commit is not a 40-character sha');
  raw := StringFromFile(ASrcDir + PathDelim + 'quickjs-version.h');
  if raw = '' then
    Die('quickjs-version.h could not be read from ' + StringToUtf8(ASrcDir));
  version := '';
  norm := NormalizeLf(raw);
  p := Pos('"', norm);
  if p > 0 then
  begin
    Inc(p);
    while (p <= Length(norm)) and (norm[p] <> '"') do
    begin
      version := version + norm[p];
      Inc(p);
    end;
  end;
  if version = '' then
    Die('QUICKJS_VERSION could not be read from quickjs-version.h');
  Result :=
    'QuickJS license material shipped with this PWeb release' + #10 +
    '=======================================================' + #10 +
    #10 +
    'PWeb embeds the QuickJS JavaScript engine. The notices below are' + #10 +
    'reproduced VERBATIM from the pinned sources this build compiles;' + #10 +
    'nothing here is paraphrased, summarised or written by PWeb. The one' + #10 +
    'canonicalization applied is the line terminator: every notice is' + #10 +
    'emitted with LF endings, because the pinned sources check out with' + #10 +
    'CRLF on Windows and LF elsewhere and this artifact must be' + #10 +
    'byte-identical on every target.' + #10 +
    #10 +
    'Provenance (facts, not licence text):' + #10 +
    '  upstream        : QuickJS by Fabrice Bellard and Charlie Gordon,' + #10 +
    '                    through the c-smile/quickjspp fork' + #10 +
    '  QUICKJS_VERSION : ' + version + #10 +
    '  source tree     : deps/mormot2/res/static/libquickjs' + #10 +
    '  mORMot2 commit  : ' + commit + #10 +
    #10 +
    'Each section names the pinned file, the SHA-256 of its' + #10 +
    'LF-normalized bytes, and its leading notice block exactly as that' + #10 +
    'file carries it.' + #10;
  for i := 0 to High(LICENSE_SOURCES) do
  begin
    path := ASrcDir + PathDelim + TFileName(Utf8ToString(LICENSE_SOURCES[i]));
    raw := StringFromFile(path);
    if raw = '' then
      Die('pinned QuickJS source missing: ' + LICENSE_SOURCES[i]);
    norm := NormalizeLf(raw);
    notice := LeadingNotice(norm);
    Result := Result + #10 +
      '-------------------------------------------------------------' + #10 +
      'file   : res/static/libquickjs/' + LICENSE_SOURCES[i] + #10 +
      'sha256 : ' + PWebSha256Hex(norm) + #10 +
      '-------------------------------------------------------------' + #10;
    if notice = '' then
      Result := Result +
        '(this pinned file carries no leading notice block)' + #10
    else
      Result := Result + RawUtf8(notice) + #10;
  end;
end;

{ ---------------- main --------------------------------------------------- }

var
  listFile, stagingDir, srcDir, lockFile: TFileName;
  listBytes: RawByteString;
  trusted: TPWebTrustedPlugins;
  rcode: TPWebReleaseCode;
  pcode: TPWebPackageLoadCode;
  detail: RawUtf8;
  i, j, k: PtrInt;
  store: IAssetStore;
  build: TPWebPluginBuildResult;
  files: TRawUtf8DynArray;
  entries, all: TPWebReleaseEntries;
  inventory: TPWebInventory;
  sha, text, evidence: RawUtf8;
  bytes: Int64;
  registry: TPWebPackageRegistry;
  plugins: TPWebRegistryPlugins;
  arg: string;
  outZip, outInc, outLic, outInv, outInfo: TFileName;

begin
  ExitCode := 0;
  if ParamCount < 2 then
  begin
    WriteLn(StdErr, 'usage: ', TOOL_ID,
      ' <trusted-list> <staging-dir> [--quickjs-src=DIR] [--mormot-lock=FILE]');
    Halt(2);
  end;
  listFile := TFileName(ParamStr(1));
  stagingDir := IncludeTrailingPathDelimiter(TFileName(ParamStr(2)));
  srcDir := TFileName(StringReplace(DEFAULT_QUICKJS_SRC, '/', PathDelim,
    [rfReplaceAll]));
  lockFile := TFileName(DEFAULT_MORMOT_LOCK);
  for i := 3 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, 14) = '--quickjs-src=' then
      srcDir := TFileName(Copy(arg, 15, MaxInt))
    else if Copy(arg, 1, 14) = '--mormot-lock=' then
      lockFile := TFileName(Copy(arg, 15, MaxInt))
    else
      Die('unknown argument: ' + StringToUtf8(arg));
  end;
  if not FileExists(listFile) then
    Die('trusted plugin list not found: ' + StringToUtf8(listFile));
  if not ForceDirectories(stagingDir) then
    Die('unable to create the staging directory: ' + StringToUtf8(stagingDir));

  listBytes := StringFromFile(listFile);
  if not PWebParseTrustedPluginList(listBytes, trusted, rcode, detail) then
    Die('trusted plugin list refused (' + PWebReleaseCodeText(rcode) + ': ' +
      detail + ')');
  Say('trusted plugins: ' + IntStr(Length(trusted)));

  // the staging directory must not sit inside a plugin source root: a
  // rebuild would otherwise walk the previous archive into the next one
  for i := 0 to High(trusted) do
    if Pos(LowerCaseU(StringToUtf8(
           ExpandFileName(TFileName(Utf8ToString(trusted[i].Root))))),
         LowerCaseU(StringToUtf8(ExpandFileName(stagingDir)))) = 1 then
      Die('the staging directory is inside plugin root ' +
        RawUtf8(trusted[i].PluginId));

  gPolicyRef := TDenyAllPolicy.Create;
  gBridge := TRefusingBridge.Create;
  gScheduler := TInvocationScheduler.Create(gPolicyRef, gBridge, 2);
  gSchedulerRef := gScheduler;
  gFactory := TSourceFactory.Create;
  gMakeSource := gFactory.Make; // Delphi-mode event assignment
  try
    all := nil;
    SetLength(plugins, Length(trusted));
    for i := 0 to High(trusted) do
    begin
      if not DirectoryExists(NativePath(trusted[i].Root)) then
        Die('plugin source root not found: ' + trusted[i].Root);
      files := WalkPluginRoot(NativePath(trusted[i].Root));
      if Length(files) = 0 then
        Die('plugin source root is empty: ' + trusted[i].Root);
      try
        store := TFolderAssetStore.Create(NativePath(trusted[i].Root));
      except
        on E: Exception do
        begin
          store := nil;
          Die('plugin source root refused by the folder store (' +
            RawUtf8(E.ClassName) + '): ' + trusted[i].Root);
        end;
      end;
      if not PWebResolvePluginPackage(trusted[i].PluginId,
           trusted[i].EntryPoint, store, gMakeSource, build, pcode, detail,
           READY_WAIT_MS, JOIN_MS) then
        Die('module graph refused for ' + RawUtf8(trusted[i].PluginId) +
          ' (' + PWEB_PACKAGE_LOAD_TEXT[pcode] + ': ' + detail + ')');
      store := nil;
      if not PWebPluginArchiveEntries(build, files, entries, rcode, detail) then
        Die('source tree refused for ' + RawUtf8(trusted[i].PluginId) +
          ' (' + PWebReleaseCodeText(rcode) + ': ' + detail + ')');
      k := Length(all);
      SetLength(all, k + Length(entries));
      for j := 0 to High(entries) do
        all[k + j] := entries[j];
      plugins[i] := Default(TPWebRegistryPlugin);
      plugins[i].PluginId := trusted[i].PluginId;
      plugins[i].PrincipalId := trusted[i].PrincipalId;
      plugins[i].Root := PWebPluginArchiveRoot(trusted[i].PluginId);
      plugins[i].EntryPoint := trusted[i].EntryPoint;
      plugins[i].PackageId := trusted[i].PluginId;
      plugins[i].GraphDigest := build.GraphDigest;
      plugins[i].ModuleCount := Length(build.Modules);
      plugins[i].SourceBytes := build.SourceBytes;
      // the RATIFIED defaults, never build-time input
      plugins[i].TimeoutSeconds := PWEB_QUICKJS_DEFAULT_LIMITS.TimeoutSeconds;
      plugins[i].MemoryLimitBytes := PWEB_QUICKJS_DEFAULT_LIMITS.MemoryLimitBytes;
      plugins[i].StackLimitBytes := PWEB_QUICKJS_DEFAULT_LIMITS.StackLimitBytes;
      plugins[i].InvokeWaitMs := PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs;
      plugins[i].Package := PWEB_PACKAGE_DEFAULT_LIMITS;
      Say('resolved ' + RawUtf8(trusted[i].PluginId) + ': ' +
        IntStr(Length(build.Modules)) + ' modules, ' +
        IntStr(Length(build.Edges)) + ' edges, ' +
        IntStr(build.SourceBytes) + ' bytes, graph ' + build.GraphDigest);
    end;
    if InterlockedCompareExchange(gBridgeArrivals, 0, 0) <> 0 then
      Die('packaged top-level code reached the invocation bridge ' +
        IntStr(gBridgeArrivals) + ' times - refusing to package');
  finally
    try
      if gSchedulerRef <> nil then
        gSchedulerRef.Shutdown;
    except
    end;
    gSchedulerRef := nil;
    gScheduler := nil;
    gPolicyRef := nil;
    gBridge := nil;
    FreeAndNil(gFactory);
  end;

  // ---- the deterministic archive ----
  outZip := stagingDir + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE));
  SetLength(files, Length(plugins));
  for i := 0 to High(plugins) do
    files[i] := plugins[i].Root;
  if not PWebWritePluginArchive(outZip, all, files, inventory, sha, bytes,
       rcode, detail) then
    Die('archive refused (' + PWebReleaseCodeText(rcode) + ': ' + detail + ')');
  Say('wrote ' + PWEB_RELEASE_PACKAGE + ': ' + IntStr(Length(inventory)) +
    ' entries, ' + IntStr(bytes) + ' bytes, sha256 ' + sha);

  // ---- the generated native registry ----
  registry := PWebRegistryFrom(PWEB_RELEASE_PACKAGE, sha, bytes,
    PWebInventoryDigest(inventory), inventory, plugins);
  if not PWebValidateRegistry(registry, rcode, detail) then
    Die('registry refused (' + PWebReleaseCodeText(rcode) + ': ' + detail + ')');
  if not PWebEmitRegistryInclude(registry, TOOL_ID, text, rcode, detail) then
    Die('registry emission refused (' + PWebReleaseCodeText(rcode) + ': ' +
      detail + ')');
  outInc := stagingDir + TFileName(Utf8ToString(PWEB_RELEASE_REGISTRY_INC));
  if not FileFromString(text, outInc) then
    Die('unable to write ' + PWEB_RELEASE_REGISTRY_INC);
  Say('wrote ' + PWEB_RELEASE_REGISTRY_INC + ': ' + IntStr(Length(text)) +
    ' bytes, sha256 ' + PWebSha256Hex(text));

  // ---- the license artifact ----
  outLic := stagingDir + TFileName(Utf8ToString(PWEB_RELEASE_LICENSE));
  text := BuildLicense(srcDir, lockFile);
  if not FileFromString(text, outLic) then
    Die('unable to write ' + PWEB_RELEASE_LICENSE);
  Say('wrote ' + PWEB_RELEASE_LICENSE + ': ' + IntStr(Length(text)) +
    ' bytes, sha256 ' + PWebSha256Hex(text));

  // ---- evidence ----
  outInv := stagingDir + 'package-inventory.txt';
  if not FileFromString(PWebInventoryText(inventory), outInv) then
    Die('unable to write package-inventory.txt');
  evidence :=
    'tool=' + TOOL_ID + #10 +
    'package=' + PWEB_RELEASE_PACKAGE + #10 +
    'package_sha256=' + registry.PackageSha256 + #10 +
    'package_bytes=' + IntStr(registry.PackageBytes) + #10 +
    'inventory_digest=' + registry.InventoryDigest + #10 +
    'inventory_entries=' + IntStr(Length(registry.Inventory)) + #10 +
    'plugins=' + IntStr(Length(registry.Plugins)) + #10;
  for i := 0 to High(registry.Plugins) do
    evidence := evidence +
      'plugin=' + RawUtf8(registry.Plugins[i].PluginId) +
      ' principal=' + RawUtf8(registry.Plugins[i].PrincipalId) +
      ' entry=' + RawUtf8(registry.Plugins[i].EntryPoint) +
      ' modules=' + IntStr(registry.Plugins[i].ModuleCount) +
      ' source_bytes=' + IntStr(registry.Plugins[i].SourceBytes) +
      ' graph=' + registry.Plugins[i].GraphDigest + #10;
  outInfo := stagingDir + 'package-build-info.txt';
  if not FileFromString(evidence, outInfo) then
    Die('unable to write package-build-info.txt');
  Say('staging complete');
end.
