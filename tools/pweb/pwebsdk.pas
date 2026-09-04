program pwebsdk;

{ The CAP-10D2 trusted SDK packager.

    pwebsdk --sdk <staged sdk root> --repo <checkout> --out <dir>

  It reads ONE staged SDK root and the checkout beside it, and produces
  exactly two artifacts:

    <sdk>/share/pweb/sdk-manifest.json   the canonical inventory: schema,
                 version, protocol, target, the template pack's three
                 digests, the six lock digests, the licence set, and for
                 every shipped file its relative path, byte length and
                 sha256. Written by THIS tool and by nothing else.
    <out>/pweb-sdk-<version>-<os>-<arch>.tar.gz
                 the distribution. Its extracted tree IS the CAP-10C1
                 section 2 SDK root, complete, so a machine that never
                 built this repository can doctor, create, build and run.

  ---------------------------------------------------------------------------
  IT ASSEMBLES A DECLARED SET; IT DOES NOT FILTER A DIRECTORY
  ---------------------------------------------------------------------------

  SHIP_TABLE below is the whole of the ship decision, and every component in
  it is named. That is not a stylistic choice: the staged SDK root in this
  repository carries build/cap10c1/bin/pwebpipe in its bin/ - the private
  CAP-10C1 lifecycle driver, which resolves its root from the running image
  exactly as `pweb` does and therefore has to live there - and a packager
  that shipped "whatever is in bin/" would ship a test driver to users. A
  filter would have needed an exception; an assembler needs nothing.

  Inside a component it takes WHOLE, every file on disk is either acceptable
  or a REFUSAL. There is no skipping: a tree that quietly grew a file is how
  an unreviewed byte reaches somebody's installation.

  WHAT IT REFUSES, and why each belongs at build time:

    - a symlink or a junction anywhere. Trusted build input is read, never
      followed;
    - node_modules, a .git directory, a .env, an .npmrc/.netrc, and any
      credential-shaped name. None of them has any business in a
      distribution, and the cheapest place to prove that is before the bytes
      are ever archived;
    - a compiled artifact under the two SOURCE trees (share/pweb/src and
      share/pweb/sdk). mORMot's static/ and the platform lib/ carry objects
      on purpose; a .ppu beside a .pas does not;
    - an absent repository lock, an absent licence, and a licence the
      ratified table does not name;
    - a component the staged root does not carry.

  IT IS A BUILD TOOL, and it behaves like one: explicit arguments rather
  than a working directory, no process, no socket, no URL, and it writes
  only the two files it was told to write.

  ---------------------------------------------------------------------------
  WHAT IS PINNED RATHER THAN SHIPPED, AND WHY
  ---------------------------------------------------------------------------

  The SDK ships PWeb's framework, its two frontend SDKs, its bundler, its
  dependencies' sources and the Windows packaging kit. It ships NO COMPILER:
  FPC, Node and Pas2JS are host requirements with `pweb doctor` rows, and
  bundling one of the three and not the other two would make the rule
  "whichever one we felt like carrying".

  Pas2JS has a second reason, and it is a measurement rather than a
  preference: the pinned Pas2JS 3.0.1 archive contains NO COPYING.FPC. Its
  own packages/rtl/README.txt refers to one "included in this distribution"
  and the file is not there, so this repository has no offline, pinned,
  verifiable licence text for the compiler or its RTL - and a component
  whose licence cannot be shipped cannot be shipped.

  The Inno Setup compiler (28 MB) and the three WebView2 runtime artifacts
  (495 MB) stay pinned for the same no-compiler rule and for Microsoft's
  distribution terms. `pweb build --profile` resolves them from
  <sdk>/share/pweb/deps/ and refuses with the CAP-10D1 refusal, unchanged,
  when they are not there.

  THE LOCKS THEMSELVES NEVER SHIP. docs/distribution-contract.md section 3
  freezes it: they carry the vendors' download addresses, and an installed
  SDK must not put one on anybody's build path. What travels is their
  DIGESTS, inside the manifest, so a package still records which lock
  revision produced it. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.sdk,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.template,
  pweb.cli.tar,
  pweb.cli.sdkmanifest,
  pweb.cli.run;

const
  TOOL_ID = 'pwebsdk';
  /// how deep a shipped component tree may go
  MAX_TREE_DEPTH = 16;
  /// the archive's own basename and its single top-level directory
  ARCHIVE_STEM = 'pweb-sdk';

{ The GENERATED CAP-10B0 trust anchor, compiled in with -Fi exactly as
  tools/pweb/pweb.pas compiles it in. The manifest's `templates` block is
  taken from HERE and never from the pack file beside it: the registry is
  what `pweb create` believes, so it is the registry a package has to
  record. }
{$I pweb.templates.registry.inc}

type
  /// a component is one named FILE or one whole TREE
  TShipKind = (skFile, skTree);
  /// which targets carry it
  TShipWhen = (swAlways, swWindows, swNotMacos);
  TShipEntry = record
    /// the logical path under the SDK root; <target> and <fpctarget> are
    // substituted, and '.exe' is appended to an executable on Windows
    Path: RawUtf8;
    Kind: TShipKind;
    When_: TShipWhen;
    /// bin/ entries are 0755 on every target: Windows has no mode plane to
    // read one from, and an SDK packaged there must still extract runnable
    // on the machine it was packaged for
    ForceExec: Boolean;
    /// a source tree, where a compiled artifact is a refusal
    SourceOnly: Boolean;
    Note: RawUtf8;
  end;

const
  { --------------------------------------------------------------------- }
  {  THE SHIP TABLE - the whole of the decision, ratified at CAP-10D2      }
  {  Checkpoint 1. Its DIGEST is compared across the four targets; the     }
  {  bytes it resolves to are per-target by construction.                  }
  { --------------------------------------------------------------------- }
  SHIP_TABLE: array[0 .. 11] of TShipEntry = (
    (Path: 'bin/pweb'; Kind: skFile; When_: swAlways;
     ForceExec: True; SourceOnly: False;
     Note: 'the CLI - this repository'),
    (Path: 'bin/pwebbundle'; Kind: skFile; When_: swAlways;
     ForceExec: True; SourceOnly: False;
     Note: 'the frozen CAP-6 bundler - this repository'),
    (Path: 'share/pweb/pweb-templates.zip'; Kind: skFile; When_: swAlways;
     ForceExec: False; SourceOnly: False;
     Note: 'the CAP-10B0 public pack - this repository'),
    (Path: 'share/pweb/src'; Kind: skTree; When_: swAlways;
     ForceExec: False; SourceOnly: True;
     Note: 'the PWeb Pascal source root - this repository'),
    (Path: 'share/pweb/sdk/typescript'; Kind: skTree; When_: swAlways;
     ForceExec: False; SourceOnly: True;
     Note: 'the pinned TypeScript SDK - MIT'),
    (Path: 'share/pweb/sdk/pas2js'; Kind: skTree; When_: swAlways;
     ForceExec: False; SourceOnly: True;
     Note: 'the PWeb Pas2JS SDK unit - this repository'),
    (Path: 'share/pweb/deps/mormot2/src'; Kind: skTree; When_: swAlways;
     ForceExec: False; SourceOnly: False;
     Note: 'mORMot 2 sources, CAP-3U-patched on Windows - MPL/GPL/LGPL'),
    (Path: 'share/pweb/deps/mormot2/static/<fpctarget>'; Kind: skTree;
     When_: swAlways; ForceExec: False; SourceOnly: False;
     Note: 'mORMot 2 statics for this target - MPL/GPL/LGPL'),
    (Path: 'share/pweb/deps/mormot2/static/delphi'; Kind: skTree;
     When_: swWindows; ForceExec: False; SourceOnly: False;
     Note: 'two objects a Win64 build reaches by a relative path'),
    (Path: 'share/pweb/lib/<target>'; Kind: skTree; When_: swAlways;
     ForceExec: False; SourceOnly: False;
     Note: 'the platform artifacts - MIT webview, BSD WebView2 SDK'),
    (Path: 'share/pweb/pack'; Kind: skTree; When_: swWindows;
     ForceExec: False; SourceOnly: False;
     Note: 'the CAP-10D1 packaging kit and its two compiled helpers'),
    (Path: 'share/pweb/licenses'; Kind: skTree; When_: swAlways;
     ForceExec: False; SourceOnly: False;
     Note: 'every shipped component''s licence, exactly once'));

  { The ratified licence set. One row per SHIPPED third-party component;
    the condition is the component's own. Windows and Linux carry QuickJS
    because mORMot's static tree for those targets carries quickjs.o -
    MEASURED: neither x86_64-darwin nor aarch64-darwin does. }
  LICENSE_TABLE: array[0 .. 3] of TShipEntry = (
    (Path: 'LICENSE.mormot2.md'; Kind: skFile; When_: swAlways;
     ForceExec: False; SourceOnly: False;
     Note: 'mORMot 2 - MPL 1.1 / GPL 2.0 / LGPL 2.1 tri-licence'),
    (Path: 'LICENSE.quickjs.txt'; Kind: skFile; When_: swNotMacos;
     ForceExec: False; SourceOnly: False;
     Note: 'QuickJS - MIT, inside mORMot''s static tree'),
    (Path: 'LICENSE.webview.txt'; Kind: skFile; When_: swAlways;
     ForceExec: False; SourceOnly: False;
     Note: 'webview/webview - MIT'),
    (Path: 'LICENSE.webview2sdk.txt'; Kind: skFile; When_: swWindows;
     ForceExec: False; SourceOnly: False;
     Note: 'Microsoft WebView2 SDK - BSD-style'));

  { Names that may never enter a distribution, matched on a whole path
    SEGMENT so `envelope.pas` is not mistaken for `.env`. }
  FORBIDDEN_EXACT: array[0 .. 7] of RawUtf8 = (
    '.env', '.git', '.npmrc', '.netrc', '.pgpass', 'node_modules',
    'id_rsa', 'id_ed25519');
  FORBIDDEN_PREFIX: array[0 .. 3] of RawUtf8 = (
    '.env.', 'secret', 'credential', 'id_rsa.');
  FORBIDDEN_SUFFIX: array[0 .. 5] of RawUtf8 = (
    '.pem', '.key', '.p12', '.pfx', '.keystore', '.log');
  { Compiled artifacts, refused inside a SOURCE tree only. }
  SOURCE_FORBIDDEN_SUFFIX: array[0 .. 5] of RawUtf8 = (
    '.ppu', '.o', '.a', '.exe', '.dll', '.so');

var
  SdkArg: RawUtf8 = '';
  RepoArg: RawUtf8 = '';
  OutArg: RawUtf8 = '';

procedure Die(const Cause, Detail: RawUtf8);
begin
  WriteLn(StdErr, TOOL_ID, ': ', string(Cause), ': ', string(Detail));
  Flush(StdErr);
  Halt(1);
end;

procedure Usage;
begin
  WriteLn(StdErr, 'usage: pwebsdk --sdk <root> --repo <dir> --out <dir>');
  Flush(StdErr);
  Halt(2);
end;

{ Long options only, one spelling each, no short forms and no environment
  fallback - the grammar rule CAP-10A froze for the public CLI, applied here
  exactly as tools/pweb/pwebtemplates.pas applies it. }
procedure ParseArgs;
var
  i: Integer;
  arg: RawUtf8;

  function Take(const Name: RawUtf8; var Target: RawUtf8): Boolean;
  begin
    Result := arg = Name;
    if not Result then
      exit;
    if Target <> '' then
      Die('repeated_option', Name);
    if i >= ParamCount then
      Die('missing_value', Name);
    Inc(i);
    Target := RawUtf8(ParamStr(i));
    if Target = '' then
      Die('empty_value', Name);
  end;

begin
  i := 1;
  while i <= ParamCount do
  begin
    arg := RawUtf8(ParamStr(i));
    if not (Take('--sdk', SdkArg) or
            Take('--repo', RepoArg) or
            Take('--out', OutArg)) then
      Usage;
    Inc(i);
  end;
  if (SdkArg = '') or
     (RepoArg = '') or
     (OutArg = '') then
    Usage;
end;

function LowerA(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A' .. 'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function HasPrefix(const S, Prefix: RawUtf8): Boolean;
begin
  Result := (Prefix <> '') and
            (Length(S) >= Length(Prefix)) and
            (Copy(S, 1, Length(Prefix)) = Prefix);
end;

function HasSuffix(const S, Suffix: RawUtf8): Boolean;
begin
  Result := (Suffix <> '') and
            (Length(S) >= Length(Suffix)) and
            (Copy(S, Length(S) - Length(Suffix) + 1, Length(Suffix)) = Suffix);
end;

{ One path SEGMENT, judged. The comparison is case-insensitive because the
  two filesystems this runs on are, and a `.ENV` that shipped because the
  check was case-sensitive would be the same secret. }
procedure RefuseName(const Segment, Logical: RawUtf8; SourceOnly: Boolean);
var
  low: RawUtf8;
  i: PtrInt;
begin
  low := LowerA(Segment);
  for i := 0 to High(FORBIDDEN_EXACT) do
    if low = FORBIDDEN_EXACT[i] then
      Die('sdk_secret_path', Logical);
  for i := 0 to High(FORBIDDEN_PREFIX) do
    if HasPrefix(low, FORBIDDEN_PREFIX[i]) then
      Die('sdk_secret_path', Logical);
  for i := 0 to High(FORBIDDEN_SUFFIX) do
    if HasSuffix(low, FORBIDDEN_SUFFIX[i]) then
      Die('sdk_secret_path', Logical);
  if SourceOnly then
    for i := 0 to High(SOURCE_FORBIDDEN_SUFFIX) do
      if HasSuffix(low, SOURCE_FORBIDDEN_SUFFIX[i]) then
        Die('sdk_build_output', Logical);
end;

var
  { the shipped set, in discovery order until it is sorted }
  Files: TPWebSdkFiles;
  Contents: array of RawByteString;
  Execs: array of Boolean;
  Used: PtrInt = 0;

procedure Add(const Logical: RawUtf8; const Content: RawByteString;
  Exec: Boolean);
begin
  if Used >= PWEB_SDK_MAX_FILES then
    Die('sdk_too_many_files', Logical);
  if Used >= Length(Files) then
  begin
    SetLength(Files, (Used + 64) * 2);
    SetLength(Contents, Length(Files));
    SetLength(Execs, Length(Files));
  end;
  Files[Used].Path := Logical;
  Files[Used].Bytes := Length(Content);
  Files[Used].Sha256 := LowerCaseU(Sha256(Content));
  Contents[Used] := Content;
  Execs[Used] := Exec;
  Inc(Used);
end;

{ Join a canonical native directory and a logical forward-slash path, one
  segment at a time - NOT a concatenation: a Windows canonical path carries
  the long-path prefix, on which the kernel performs no normalization at
  all, so a forward slash left in one is part of a file name. }
function JoinLogical(const Dir, Logical: RawUtf8): RawUtf8;
var
  i, start: PtrInt;
begin
  Result := Dir;
  start := 1;
  for i := 1 to Length(Logical) + 1 do
    if (i > Length(Logical)) or
       (Logical[i] = '/') then
    begin
      Result := PWebCliJoin(Result, Copy(Logical, start, i - start));
      start := i + 1;
    end;
end;

procedure ReadOne(const Full, Logical: RawUtf8; ForceExec: Boolean);
var
  content: RawByteString;
  tooBig: Boolean;
begin
  if not PWebCliReadSmallFile(Full, PWEB_SDK_MAX_FILE_BYTES, content,
       tooBig) then
    if tooBig then
      Die('sdk_file_too_big', Logical)
    else
      Die('sdk_component_unreadable', Logical);
  // the execute bit is READ from the file where the platform has one, and
  // FORCED for bin/ where it does not: an SDK packaged on Windows still has
  // to extract runnable on the machine it was packaged for
  Add(Logical, content,
    ForceExec or (PWebCliHasFileModes and PWebCliExecutableBit(Full)));
end;

procedure WalkTree(const Dir, Logical: RawUtf8; Depth: Integer;
  SourceOnly: Boolean);
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  full, rel: RawUtf8;
begin
  if Depth > MAX_TREE_DEPTH then
    Die('sdk_tree_too_deep', Logical);
  if not PWebCliListDir(Dir, names) then
    Die('sdk_component_unreadable', Logical);
  PWebCliSortBytewise(names);
  for i := 0 to High(names) do
  begin
    full := PWebCliJoin(Dir, names[i]);
    rel := Logical + '/' + names[i];
    RefuseName(names[i], rel, SourceOnly);
    case PWebCliNodeKind(full) of
      pcnDirectory:
        WalkTree(full, rel, Depth + 1, SourceOnly);
      pcnFile:
        ReadOne(full, rel, False);
      pcnLink:
        // trusted build input is READ, never followed. A link here is not a
        // file to resolve, it is a review that did not happen
        Die('sdk_reparse_point', rel);
    else
      Die('sdk_not_a_regular_file', rel);
    end;
  end;
end;

function Substitute(const Path, Target, FpcTarget: RawUtf8;
  Windows: Boolean): RawUtf8;
begin
  Result := Path;
  if Result = 'share/pweb/deps/mormot2/static/<fpctarget>' then
    Result := 'share/pweb/deps/mormot2/static/' + FpcTarget
  else if Result = 'share/pweb/lib/<target>' then
    Result := 'share/pweb/lib/' + Target;
  if Windows and HasPrefix(Result, 'bin/') then
    Result := Result + PWEB_CLI_RUN_WINDOWS_EXT;
end;

function Applies(When_: TShipWhen; Os: TPWebCliOs): Boolean;
begin
  case When_ of
    swWindows:   Result := Os = pcoWindows;
    swNotMacos:  Result := Os <> pcoMacos;
  else
    Result := True;
  end;
end;

{ The ship decision, digested. It is the TABLE that is compared across the
  four targets - the entries, their kinds, their conditions and the licence
  rows - and never the bytes it resolves to, which are per-target by
  construction. }
function ShipTableDigest: RawUtf8;
var
  lines: RawUtf8;
  i: PtrInt;
begin
  lines := '';
  for i := 0 to High(SHIP_TABLE) do
    lines := lines + 'ship|' + SHIP_TABLE[i].Path + '|' +
      RawUtf8(IntToStr(Ord(SHIP_TABLE[i].Kind))) + '|' +
      RawUtf8(IntToStr(Ord(SHIP_TABLE[i].When_))) + '|' +
      RawUtf8(IntToStr(Ord(SHIP_TABLE[i].ForceExec))) + '|' +
      RawUtf8(IntToStr(Ord(SHIP_TABLE[i].SourceOnly))) + '|' +
      SHIP_TABLE[i].Note + #10;
  for i := 0 to High(LICENSE_TABLE) do
    lines := lines + 'licence|' + LICENSE_TABLE[i].Path + '|' +
      RawUtf8(IntToStr(Ord(LICENSE_TABLE[i].When_))) + '|' +
      LICENSE_TABLE[i].Note + #10;
  Result := LowerCaseU(Sha256(lines));
end;

procedure SortFiles;
var
  i, j: PtrInt;
  f: TPWebSdkFile;
  c: RawByteString;
  e: Boolean;
begin
  for i := 1 to Used - 1 do
  begin
    f := Files[i];
    c := Contents[i];
    e := Execs[i];
    j := i - 1;
    while (j >= 0) and
          (CompareStr(Files[j].Path, f.Path) > 0) do
    begin
      Files[j + 1] := Files[j];
      Contents[j + 1] := Contents[j];
      Execs[j + 1] := Execs[j];
      Dec(j);
    end;
    Files[j + 1] := f;
    Contents[j + 1] := c;
    Execs[j + 1] := e;
  end;
  for i := 1 to Used - 1 do
    if Files[i - 1].Path = Files[i].Path then
      Die('sdk_duplicate_path', Files[i].Path);
end;

procedure WriteArtifact(const Path: RawUtf8; const Content: RawByteString;
  Exec: Boolean);
var
  tmp: RawUtf8;
begin
  // regenerated on every run, so it cannot use the exclusive create the
  // PROJECT writer uses - but it still lands atomically, through the one
  // replacing primitive the platform seam exposes
  tmp := Path + '.tmp';
  PWebCliDeleteFile(tmp);
  if not PWebCliWriteNewFile(tmp, Content, Exec) then
    Die('sdk_write_failed', tmp);
  if not PWebCliReplaceFile(tmp, Path) then
    Die('sdk_write_failed', Path);
end;

var
  cwd, sdkRoot, repoRoot, outBase, outDir: RawUtf8;
  target, fpcTarget, logical, full, stem, archivePath: RawUtf8;
  os_: TPWebCliOs;
  arch: TPWebCliArch;
  isWindows: Boolean;
  manifest: TPWebSdkManifest;
  manifestText: RawUtf8;
  content: RawByteString;
  tooBig: Boolean;
  entries: TPWebTarEntries;
  dirs: TRawUtf8DynArray;
  raw, gz: RawByteString;
  tarRefusal: TPWebTarRefusal;
  reg: TPWebTemplateRegistry;
  fact: TPWebCliSdkFact;
  i, j, k: PtrInt;
  found: Boolean;
  seg: RawUtf8;

begin
  ParseArgs;
  if not PWebCliCwd(cwd) then
    Die('sdk_cwd_unresolved', '');
  if not PWebCliCanonicalDir(PWebCliAbsolute(cwd, SdkArg), sdkRoot) then
    Die('sdk_root_refused', SdkArg);
  if not PWebCliCanonicalDir(PWebCliAbsolute(cwd, RepoArg), repoRoot) then
    Die('sdk_repo_refused', RepoArg);
  outBase := PWebCliDisplayPath(cwd);
  outDir := PWebCliAbsolute(outBase, OutArg);

  os_ := PWebCliHostOs;
  arch := PWebCliHostArch;
  isWindows := os_ = pcoWindows;
  target := PWebCliRunTargetName(os_, arch);
  fpcTarget := PWebCliFpcTargetName(os_, arch);
  if (target = '') or
     (fpcTarget = '') then
    Die('sdk_target_unsupported', target);

  // ---- 1. the declared components, in table order ------------------------
  for i := 0 to High(SHIP_TABLE) do
  begin
    if not Applies(SHIP_TABLE[i].When_, os_) then
      continue;
    logical := Substitute(SHIP_TABLE[i].Path, target, fpcTarget, isWindows);
    full := JoinLogical(sdkRoot, logical);
    case PWebCliNodeKind(full) of
      pcnFile:
        if SHIP_TABLE[i].Kind <> skFile then
          Die('sdk_component_kind', logical)
        else
          ReadOne(full, logical, SHIP_TABLE[i].ForceExec);
      pcnDirectory:
        if SHIP_TABLE[i].Kind <> skTree then
          Die('sdk_component_kind', logical)
        else
          WalkTree(full, logical, 1, SHIP_TABLE[i].SourceOnly);
      pcnLink:
        Die('sdk_reparse_point', logical);
    else
      Die('sdk_component_missing', logical);
    end;
  end;
  SetLength(Files, Used);
  SetLength(Contents, Used);
  SetLength(Execs, Used);
  SortFiles;

  // ---- 2. the licence set: exactly the ratified table --------------------
  manifest := Default(TPWebSdkManifest);
  for i := 0 to High(LICENSE_TABLE) do
  begin
    if not Applies(LICENSE_TABLE[i].When_, os_) then
      continue;
    logical := 'share/pweb/' + PWEB_SDK_LICENSES + '/' + LICENSE_TABLE[i].Path;
    found := False;
    for j := 0 to Used - 1 do
      if Files[j].Path = logical then
      begin
        found := True;
        if Files[j].Bytes = 0 then
          Die('sdk_license_empty', LICENSE_TABLE[i].Path);
      end;
    if not found then
      Die('sdk_license_missing', LICENSE_TABLE[i].Path);
    SetLength(manifest.Licenses, Length(manifest.Licenses) + 1);
    manifest.Licenses[High(manifest.Licenses)] := LICENSE_TABLE[i].Path;
  end;
  // and NOTHING ELSE is in licenses/: a notice nobody ratified is a notice
  // nobody reviewed
  for j := 0 to Used - 1 do
    if HasPrefix(Files[j].Path, 'share/pweb/' + PWEB_SDK_LICENSES + '/') then
    begin
      seg := Copy(Files[j].Path,
        Length('share/pweb/' + PWEB_SDK_LICENSES + '/') + 1, MaxInt);
      found := False;
      for k := 0 to High(manifest.Licenses) do
        if manifest.Licenses[k] = seg then
          found := True;
      if not found then
        Die('sdk_license_unratified', seg);
    end;

  // ---- 3. the six lock digests. The FILES never ship ---------------------
  for i := 0 to High(PWEB_SDK_LOCKS) do
  begin
    if PWebCliEntry(repoRoot, PWEB_SDK_LOCKS[i]) <> pcnFile then
      Die('sdk_lock_missing', PWEB_SDK_LOCKS[i]);
    if not PWebCliReadSmallFile(PWebCliJoin(repoRoot, PWEB_SDK_LOCKS[i]),
         PWEB_SDK_MANIFEST_MAX_BYTES, content, tooBig) then
      Die('sdk_lock_unreadable', PWEB_SDK_LOCKS[i]);
    SetLength(manifest.Locks, i + 1);
    manifest.Locks[i].Name := PWEB_SDK_LOCKS[i];
    manifest.Locks[i].Sha256 := LowerCaseU(Sha256(content));
  end;

  // ---- 4. the manifest ---------------------------------------------------
  reg := PWebTplRegistryFrom(PWEB_TPL_GEN_PACK_FILE, PWEB_TPL_GEN_PACK_SHA256,
    PWEB_TPL_GEN_PACK_BYTES, PWEB_TPL_GEN_INVENTORY_DIGEST,
    PWEB_TPL_GEN_INVENTORY, PWEB_TPL_GEN_FILES, PWEB_TPL_GEN_TEMPLATES);
  manifest.Schema := PWEB_SDK_MANIFEST_SCHEMA;
  manifest.PWebVersion := PWEB_RUNTIME_VERSION;
  manifest.Protocol := PWEB_PROTOCOL_VERSION;
  manifest.Target := target;
  manifest.TemplatePack := LowerCaseU(PWEB_TPL_GEN_PACK_SHA256);
  manifest.TemplateInventory := LowerCaseU(PWEB_TPL_GEN_INVENTORY_DIGEST);
  manifest.TemplateRegistry := LowerCaseU(PWebTplRegistryDigest(reg));
  SetLength(manifest.Files, Used);
  for i := 0 to Used - 1 do
    manifest.Files[i] := Files[i];
  // the pack beside the executable has to BE the pack the compiled registry
  // describes: a package whose two anchors disagree is one whose `create`
  // would refuse on the machine it was installed on
  logical := 'share/pweb/' + PWEB_SDK_TEMPLATE_PACK;
  found := False;
  for i := 0 to Used - 1 do
    if Files[i].Path = logical then
    begin
      found := True;
      if Files[i].Sha256 <> manifest.TemplatePack then
        Die('sdk_template_pack_mismatch', Files[i].Sha256);
      if Files[i].Bytes <> PWEB_TPL_GEN_PACK_BYTES then
        Die('sdk_template_pack_mismatch', RawUtf8(IntToStr(Files[i].Bytes)));
    end;
  if not found then
    Die('sdk_component_missing', logical);

  manifestText := PWebSdkManifestText(manifest);
  if manifestText = '' then
    Die('sdk_manifest_unencodable', '');
  WriteArtifact(JoinLogical(sdkRoot, 'share/pweb/' + PWEB_SDK_MANIFEST),
    RawByteString(manifestText), {Exec=}False);

  // the writer's own output, read back through the READER: a manifest this
  // tool cannot verify is a manifest it must not ship
  fact := PWebCliSdkVerifyIn(sdkRoot, PWEB_RUNTIME_VERSION);
  if not PWebCliSdkFactAccepted(fact) then
    Die('sdk_self_verify_failed',
      PWebCliSdkFactCause(fact) + ' ' + fact.Detail);
  if fact.Verified <> Used then
    Die('sdk_self_verify_partial', RawUtf8(IntToStr(fact.Verified)));

  // ---- 5. the archive, by the CAP-10D1 deterministic writer --------------
  stem := ARCHIVE_STEM + '-' + PWEB_RUNTIME_VERSION + '-' + target;
  entries := nil;
  SetLength(entries, 1);
  entries[0].Name := stem;
  entries[0].Directory := True;
  entries[0].Executable := True;
  // explicit directory members rather than implied ones, because an implied
  // directory's mode is whatever the extracting tar decides
  dirs := nil;
  for i := 0 to Used - 1 do
  begin
    logical := '';
    for j := 1 to Length(Files[i].Path) do
      if Files[i].Path[j] = '/' then
      begin
        logical := Copy(Files[i].Path, 1, j - 1);
        found := False;
        for k := 0 to High(dirs) do
          if dirs[k] = logical then
            found := True;
        if not found then
        begin
          SetLength(dirs, Length(dirs) + 1);
          dirs[High(dirs)] := logical;
          SetLength(entries, Length(entries) + 1);
          entries[High(entries)].Name := stem + '/' + logical;
          entries[High(entries)].Directory := True;
          entries[High(entries)].Executable := True;
        end;
      end;
  end;
  for i := 0 to Used - 1 do
  begin
    SetLength(entries, Length(entries) + 1);
    entries[High(entries)].Name := stem + '/' + Files[i].Path;
    entries[High(entries)].Content := Contents[i];
    entries[High(entries)].Executable := Execs[i];
  end;
  // the manifest travels INSIDE the archive and is deliberately not in its
  // own inventory: a document cannot carry its own digest
  SetLength(entries, Length(entries) + 1);
  entries[High(entries)].Name :=
    stem + '/share/pweb/' + PWEB_SDK_MANIFEST;
  entries[High(entries)].Content := RawByteString(manifestText);
  PWebTarSort(entries);
  if not PWebTarWrite(entries, raw, tarRefusal) then
    Die('sdk_archive_refused', PWebTarRefusalText(tarRefusal));
  if not PWebTarGzip(raw, gz) then
    Die('sdk_archive_refused', PWebTarRefusalText(patCompress));
  if PWebCliNodeKind(outDir) <> pcnDirectory then
    if not PWebCliCreateDir(outDir) then
      Die('sdk_out_dir_refused', OutArg);
  archivePath := PWebCliJoin(outDir, stem + '.tar.gz');
  WriteArtifact(archivePath, gz, {Exec=}False);

  // ---- 6. the machine-readable summary the gate reads --------------------
  WriteLn('sdk_schema ', PWEB_SDK_MANIFEST_SCHEMA);
  WriteLn('sdk_version ', string(PWEB_RUNTIME_VERSION));
  WriteLn('sdk_protocol ', PWEB_PROTOCOL_VERSION);
  WriteLn('sdk_target ', string(target));
  WriteLn('sdk_files ', Used);
  WriteLn('sdk_bytes ', Length(raw));
  WriteLn('sdk_inventory_digest ',
    string(PWebSdkInventoryDigest(manifest.Files)));
  WriteLn('sdk_manifest_sha256 ',
    string(LowerCaseU(Sha256(RawByteString(manifestText)))));
  WriteLn('sdk_manifest_bytes ', Length(manifestText));
  WriteLn('sdk_ship_table_digest ', string(ShipTableDigest));
  WriteLn('sdk_licenses ', Length(manifest.Licenses));
  WriteLn('sdk_locks ', Length(manifest.Locks));
  WriteLn('sdk_archive ', string(stem), '.tar.gz');
  WriteLn('sdk_archive_bytes ', Length(gz));
  WriteLn('sdk_archive_sha256 ', string(LowerCaseU(Sha256(gz))));
  WriteLn('sdk_integrity_ms ', fact.ElapsedMs);
  Flush(Output);
end.
