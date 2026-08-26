{
  pweb.script.release - CAP-9C1 deterministic QuickJS plugin release
  package: the trusted build-time list, the deterministic archive
  writer, the semantic inventory, the generated native registry and
  the runtime whole-package verifier.

  DELIBERATELY ENGINE-FREE, exactly like pweb.script.package. Nothing
  here knows about QuickJS, JSContext, JSValue, threads or the plugin
  lifecycle: it is bytes, grammars and digests over the frozen
  IAssetStore contract. pweb.script.startup is the engine-facing half
  that turns a verified package into running plugins.

  WHAT IS AUTHORITATIVE (security-model.md): the GENERATED NATIVE
  REGISTRY, and nothing else. The archive is script content. A tampered
  or substituted archive cannot change a PluginId, a PrincipalId, a
  PrincipalKind, an AppMaximum, a principal's capabilities, a runtime
  grant, an entry-point declaration, a resource bound or the expected
  package digest: every one of those is either a compiled constant here
  or CAP-8 configuration the host owns. Even with valid archive
  integrity, every invocation still traverses the frozen CAP-8 policy -
  package integrity is not authorization and never substitutes for it.

  CAPABILITIES ARE NOT IN THE REGISTRY. They are obtained from the CAP-8
  policy keyed by the registry's PrincipalId (pweb.script.startup), so
  the packaging tool never sees a capability and is structurally
  incapable of granting one.

  LIMITS ARE NOT CONFIGURABLE FROM THE BUILD-TIME LIST. The generator
  emits the ratified defaults, so a tampered build-time file cannot
  raise a memory cap or switch a CPU bound off.

  THE ORDER THE RUNTIME VERIFIER RUNS IN, and why it is that order:

    locate beside the executable  (never the CWD, never a caller path)
        -> open ONE handle, refusing symlink/reparse indirection
        -> read in bounded chunks while hashing INCREMENTALLY
        -> compare the exact expected SHA-256 and byte length
        -> hand THOSE SAME BYTES to TZipAssetStore
        -> verify the semantic inventory entry by entry
        -> only then publish a package-loader object

  There is no check/open TOCTOU window to race, because there is no
  second read: the bytes that were hashed ARE the bytes that are
  parsed. That is a stronger property than any locking strategy could
  give, and it is why the verifier materialises the archive under a
  hard size cap instead of streaming it twice.

  DETERMINISM, and the one thing it does NOT mean here. The archive is
  written with the CAP-6 deterministic-ZIP contract reused verbatim -
  global bytewise sort of canonical names, PWEB_BUNDLE_FIXED_FILE_AGE,
  PWEB_BUNDLE_DEFLATE_LEVEL, no extra fields, zip64 refused - so the
  same logical input always produces the same archive ON THE SAME
  TOOLCHAIN. It does NOT mean the same bytes on every platform:
  CAP-6/CAP-7L already MEASURED that the mORMot static DEFLATE object
  emits different output for x86_64-win64 and x86_64-linux (the two
  Darwin statics agree with each other). That is why the registry is
  GENERATED PER TARGET at build time and never committed, and why the
  cross-target evidence compares the SEMANTIC inventory rather than the
  archive bytes.

  Canonical sources:
    - core-interfaces.md : IAssetStore.TryRead (frozen) + canonical
                           asset-path rules, reused verbatim.
    - security-model.md  : native trust anchor; package metadata grants
                           nothing.
    - deployment.md      : release artifacts sit beside the executable.
}
unit pweb.script.release;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  {$ifdef WINDOWS}
  Windows,
  {$else}
  BaseUnix,
  {$endif WINDOWS}
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.zip,
  mormot.crypt.core,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.zip,
  pweb.assets.bundle,   // the ratified deterministic-ZIP constants
  pweb.assets.folder,   // Darwin's O_NOFOLLOW lives in its interface
  pweb.script.package;

type
  /// host configuration error (a nil store, a direct API misuse) -
  // surfaced at startup, never as a silent runtime miss
  EPWebRelease = class(Exception);

  { Why a release package operation failed. NATIVE build/startup codes:
    deliberately NOT the nine-code RPC taxonomy (wire-semantics.md) and
    deliberately NOT TPWebPackageLoadCode either - nothing here is an
    invocation, and nothing here is a per-plugin package load. }
  TPWebReleaseCode = (
    prcNone,
    // ---- the trusted build-time plugin list ----
    prcListTooLarge,
    prcListEncoding,          // NUL, bad UTF-8, non-ASCII or a control byte
    prcListSyntax,
    prcListDuplicateKey,
    prcListUnknownField,
    prcListForbiddenField,    // a security-authority key name
    prcListPluginId,
    prcListPrincipalId,
    prcListRoot,
    prcListEntry,
    prcListEmpty,
    prcListDuplicate,         // duplicate plugin id, principal id or root
    prcListCount,
    // ---- deterministic packaging ----
    prcEntryName,             // not a canonical logical path
    prcEntryOutsideRoot,      // not under any registered PluginId root
    prcEntryDuplicate,
    prcEntryCollision,        // Unicode fold or file/directory collision
    prcEntryCodepage,         // not byte-representable through TZipWrite
    prcEntryTooLarge,
    prcEntryCount,
    prcSourceUnreferenced,    // a source file no module graph reaches
    prcSourceMissing,         // a graph module absent from the source set
    prcArchiveWrite,          // the writer or its self-validation failed
    // ---- the generated native registry ----
    prcRegistry,              // the registry itself is inconsistent
    prcRegistryEmit,          // a field is not safely emittable as Pascal
    // ---- runtime whole-package verification ----
    prcPackageMissing,
    prcPackageUnreadable,     // symlink/reparse, not a regular file, I/O
    prcPackageSize,           // short, long or over the hard cap
    prcPackageDigest,         // the whole-archive SHA-256 does not match
    prcArchiveInvalid,        // TZipAssetStore refused the archive
    prcInventoryCount,
    prcInventoryMismatch);

const
  PWEB_RELEASE_CODE_TEXT: array[TPWebReleaseCode] of RawUtf8 = (
    'ok',
    'list_too_large',
    'list_encoding',
    'list_syntax',
    'list_duplicate_key',
    'list_unknown_field',
    'list_forbidden_field',
    'list_plugin_id',
    'list_principal_id',
    'list_root',
    'list_entry',
    'list_empty',
    'list_duplicate',
    'list_count',
    'entry_name',
    'entry_outside_root',
    'entry_duplicate',
    'entry_collision',
    'entry_codepage',
    'entry_too_large',
    'entry_count',
    'source_unreferenced',
    'source_missing',
    'archive_write',
    'registry',
    'registry_emit',
    'package_missing',
    'package_unreadable',
    'package_size',
    'package_digest',
    'archive_invalid',
    'inventory_count',
    'inventory_mismatch');

  /// the ONE production plugin-package file name. Deliberately NOT
  // '.pwb': app.pwb carries a frozen application-bundle contract
  // (manifest.json + index.html + the CAP-6 compatibility predicate)
  // and a structurally different archive must not share its extension
  PWEB_RELEASE_PACKAGE: RawUtf8 = 'plugins.zip';

  /// the generated native registry include, written into the staging
  // directory and compiled with -Fi. NEVER a runtime configuration
  // file: the runtime must not be able to recover security-sensitive
  // descriptor data by reading a sibling file
  PWEB_RELEASE_REGISTRY_INC: RawUtf8 = 'pweb.quickjs.registry.inc';

  /// the QuickJS license artifact the release staging must carry
  PWEB_RELEASE_LICENSE: RawUtf8 = 'LICENSE.quickjs';

  /// hard ceiling on the whole plugin archive, in bytes. The verifier
  // materialises the archive to close the check/open race, so this is
  // what bounds the memory that costs - it is checked BEFORE a byte is
  // read, against the file size the OS reports
  PWEB_RELEASE_PACKAGE_MAX_BYTES = Int64(64) shl 20;   // 64 MiB
  /// hard ceiling on one archive entry, in bytes
  PWEB_RELEASE_ENTRY_MAX_BYTES = Int64(16) shl 20;     // 16 MiB
  /// hard ceiling on the number of archive entries
  PWEB_RELEASE_MAX_ENTRIES = 4096;
  /// hard ceiling on the number of packaged plugins
  PWEB_RELEASE_MAX_PLUGINS = 64;
  /// hard ceiling on the trusted build-time list, in bytes
  PWEB_RELEASE_LIST_MAX_BYTES = 64 shl 10;             // 64 KiB
  /// bound on a native principal identifier, in bytes
  PWEB_RELEASE_PRINCIPAL_MAX_BYTES = 64;
  /// bound on a build-time source root, in bytes
  PWEB_RELEASE_ROOT_MAX_BYTES = 256;

  { The build-time list key names that must never be believed to carry
    authority - the same eight PWEB_PACKAGE_FORBIDDEN_KEYS the CAP-9B1
    manifest scanner refuses, for the same pedagogical reason: an
    unknown-field rejection would be technically correct and useless. }

type
  { ONE archive entry, as the builder hands it to the writer. }
  TPWebReleaseEntry = record
    Name: RawUtf8;           // canonical archive path, forward slashes
    Content: RawByteString;  // exact bytes
  end;
  TPWebReleaseEntries = array of TPWebReleaseEntry;

  { ONE semantic inventory row. The inventory is the archive's meaning:
    logical name, exact uncompressed length and exact content digest.
    Unlike the archive bytes it is toolchain-independent, which is why
    it - not the ZIP - is what the four-target evidence compares. }
  TPWebInventoryEntry = record
    Name: RawUtf8;
    Bytes: Int64;
    Sha256: RawUtf8;   // 64 lowercase hex
  end;
  TPWebInventory = array of TPWebInventoryEntry;

  { ONE registered plugin, as the GENERATED registry carries it. Every
    field here is a compiled native constant: script content can never
    reach any of them. Capabilities are deliberately absent - see the
    unit header. }
  TPWebRegistryPlugin = record
    PluginId: Utf8String;
    PrincipalId: Utf8String;
    Root: RawUtf8;            // '<PluginId>/', the archive sub-tree
    EntryPoint: Utf8String;
    PackageId: Utf8String;    // plugin.json "id" must match byte-exactly
    GraphDigest: RawUtf8;     // 64 lowercase hex over the module graph
    ModuleCount: Integer;
    SourceBytes: Int64;
    // CAP-9A engine bounds as SCALARS: this unit stays engine-free, so
    // it cannot name TPWebQuickJSLimits. pweb.script.startup maps them.
    TimeoutSeconds: Cardinal;
    MemoryLimitBytes: PtrUInt;
    StackLimitBytes: PtrUInt;
    InvokeWaitMs: Integer;
    // CAP-9B1 package bounds
    Package: TPWebPackageLimits;
  end;
  TPWebRegistryPlugins = array of TPWebRegistryPlugin;

  { The whole generated registry. This record IS the trust anchor. It is
    passed as a PARAMETER rather than read from a global, so every
    refusal branch below can be proven red on a mutated copy without
    regenerating an include - and so a host can never accidentally read
    a second, softer registry from somewhere else. }
  TPWebPackageRegistry = record
    PackageFile: RawUtf8;      // a bare file name, no directory part
    PackageSha256: RawUtf8;    // 64 lowercase hex
    PackageBytes: Int64;
    InventoryDigest: RawUtf8;  // 64 lowercase hex
    Inventory: TPWebInventory;         // sorted bytewise by Name
    Plugins: TPWebRegistryPlugins;     // sorted bytewise by PluginId
  end;

  { ONE row of the trusted build-time plugin list. Build-time only: it
    is never shipped, never read at runtime, and carries no capability
    and no resource bound by ratified decision. }
  TPWebTrustedPlugin = record
    PluginId: Utf8String;
    PrincipalId: Utf8String;
    Root: RawUtf8;          // repository-relative, forward slashes
    EntryPoint: Utf8String;
  end;
  TPWebTrustedPlugins = array of TPWebTrustedPlugin;

/// fixed diagnostic text for a release code
function PWebReleaseCodeText(ACode: TPWebReleaseCode): RawUtf8;

/// native principal-identifier grammar:
// [a-z0-9]+(\.[a-z0-9]+)* optionally followed by ':' and the same
// shape - 'plugin:calculator' is the canonical form. ASCII, exact case,
// 1..PWEB_RELEASE_PRINCIPAL_MAX_BYTES bytes, no normalization
// - deliberately NOT the capability grammar's validator even though the
// left half coincides: they answer to different specs and must be free
// to diverge
function PWebPrincipalIdValid(const APrincipalId: Utf8String): Boolean;

/// a build-time source root: relative, forward slashes, segments of
// [A-Za-z0-9._-] with no '.' or '..' segment, no leading or trailing
// '/', no drive or UNC form, bounded
function PWebSourceRootValid(const ARoot: RawUtf8): Boolean;

/// True iff S is exactly 64 lowercase hexadecimal digits
function PWebSha256HexValid(const S: RawUtf8): Boolean;

/// lowercase hexadecimal SHA-256 of a byte string
function PWebSha256Hex(const AData: RawByteString): RawUtf8;

/// the archive sub-tree one PluginId owns: '<PluginId>/'
function PWebPluginArchiveRoot(const APluginId: Utf8String): RawUtf8;

/// strict trusted build-time plugin list scanner
// - the repository's existing `key = value` lock-file grammar: '#'
// comments, blank lines, one `plugin = <id>` per block followed by
// `principal`, `root` and `entry`, each key exactly once per block
// - ASCII only, no escape sequence anywhere, bounded, unknown keys are
// hard errors and the eight CAP-9B1 security-authority key names are
// refused with their own loud code
// - ADetail is a short ASCII host-side diagnostic ('' when none)
function PWebParseTrustedPluginList(const ABytes: RawByteString;
  out APlugins: TPWebTrustedPlugins;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;

/// the canonical semantic-inventory projection: one LF-terminated
// 'name bytes sha' line per entry, in the inventory's own order
function PWebInventoryText(const AInventory: TPWebInventory): RawUtf8;

/// SHA-256 of PWebInventoryText - the toolchain-independent identity
// of what the archive MEANS, as opposed to what it weighs
function PWebInventoryDigest(const AInventory: TPWebInventory): RawUtf8;

/// the canonical module-graph projection of ONE plugin: its id, its
// entry point, its modules in loader order with their content digests,
// and its resolution edges sorted bytewise
// - AModules and AHashes are parallel; AEdges is 'importer>imported'
function PWebGraphText(const APluginId, AEntryPoint: Utf8String;
  const AModules, AHashes, AEdges: TRawUtf8DynArray): RawUtf8;

/// SHA-256 of PWebGraphText
function PWebGraphDigest(const APluginId, AEntryPoint: Utf8String;
  const AModules, AHashes, AEdges: TRawUtf8DynArray): RawUtf8;

/// deterministic validating plugin-archive writer
// - validates every entry BEFORE touching the disk: canonical name,
// membership of a registered PluginId root, exact duplicates, the
// ratified CAP-6 D1 Unicode-fold collision rule, file/directory
// collisions, the codepage round-trip and the size/count bounds
// - writes a temp sibling in global bytewise name order with the
// CAP-6 fixed timestamp and deflate level, re-opens it through
// TZipRead for a raw stored-name/timestamp/extra-field compare and
// through the PRODUCTION TZipAssetStore for a full content and
// enumeration compare, then atomically replaces AOutFile; on any
// failure the previous output survives and the temp is removed
// - on success AInventory/ASha256/ABytes describe the installed file
function PWebWritePluginArchive(const AOutFile: TFileName;
  const AEntries: TPWebReleaseEntries;
  const ARoots: TRawUtf8DynArray;
  out AInventory: TPWebInventory;
  out ASha256: RawUtf8; out ABytes: Int64;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;

/// assemble a registry record from the generated include's constants
function PWebRegistryFrom(const APackageFile, APackageSha256: RawUtf8;
  APackageBytes: Int64; const AInventoryDigest: RawUtf8;
  const AInventory: array of TPWebInventoryEntry;
  const APlugins: array of TPWebRegistryPlugin): TPWebPackageRegistry;

/// internal-consistency gate over a registry, run before ANY file is
// touched: grammars, digest shapes, sort order, uniqueness, root
// membership, and the presence of every plugin's manifest and entry
// point in the inventory
function PWebValidateRegistry(const ARegistry: TPWebPackageRegistry;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;

/// emit the deterministic generated native registry include
// - every field is re-validated against its grammar first and every
// emitted string must be printable ASCII without a quote, so NO
// arbitrary text can ever become Pascal source; a violation is a
// refusal (prcRegistryEmit), never an escape
// - the output carries no absolute path, no timestamp and no host name,
// and is LF-terminated so regeneration is byte-identical
function PWebEmitRegistryInclude(const ARegistry: TPWebPackageRegistry;
  const AToolId: RawUtf8; out AText: RawUtf8;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;

/// the ONE trusted runtime location: the directory holding the running
// executable. Never the current working directory, never a caller
// path, never an environment variable
function PWebReleaseDirectory: TFileName;

/// read a release file ONCE into memory while hashing it incrementally
// - opens a single handle refusing symlink/reparse indirection and
// anything that is not a regular file, bounds the size BEFORE reading,
// and returns both the bytes and their lowercase hex SHA-256, so the
// bytes that were hashed are the only bytes any caller ever sees
function PWebReadAndHashReleaseFile(const AFileName: TFileName;
  AMaxBytes: Int64; out AData: RawByteString; out ASha256: RawUtf8;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;

/// THE runtime whole-package verifier - the entry point a host uses
// - order is the proof: registry consistency -> locate beside the
// executable -> read-once-and-hash -> exact digest and length ->
// TZipAssetStore over THOSE bytes -> exact semantic inventory. Only
// then does a store escape
// - on False AStore is nil and no archive was ever handed to anything
function PWebVerifyQuickJSPackage(const ADirectory: TFileName;
  const ARegistry: TPWebPackageRegistry;
  out AStore: IAssetStore;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;


implementation

{ ---------------- small shared helpers ---------------------------------- }

function PWebReleaseCodeText(ACode: TPWebReleaseCode): RawUtf8;
begin
  Result := PWEB_RELEASE_CODE_TEXT[ACode];
end;

function IntStr(AValue: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(AValue));
end;

{ every diagnostic that leaves this unit passes through here: printable
  ASCII only, bounded, so no module byte, host path or archive content
  can ride out on a detail string }
function Sanitize(const AText: RawUtf8; AMax: Integer = 160): RawUtf8;
var
  i, n: PtrInt;
  c: AnsiChar;
begin
  Result := '';
  n := Length(AText);
  if n > AMax then
    n := AMax;
  SetLength(Result, n);
  for i := 1 to n do
  begin
    c := AText[i];
    if (c < ' ') or (c > #126) then
      c := '?';
    Result[i] := c;
  end;
end;

function PWebSha256Hex(const AData: RawByteString): RawUtf8;
begin
  Result := LowerCaseU(Sha256(AData));
end;

function PWebSha256HexValid(const S: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if Length(S) <> 64 then
    exit;
  for i := 1 to 64 do
    if not (((S[i] >= '0') and (S[i] <= '9')) or
            ((S[i] >= 'a') and (S[i] <= 'f'))) then
      exit;
  Result := True;
end;

{ [a-z0-9]+(\.[a-z0-9]+)* over Text[AFrom..ATo] }
function LowerDottedRun(const AText: RawUtf8; AFrom, ATo: PtrInt): Boolean;
var
  i: PtrInt;
  run: Integer;
begin
  Result := False;
  if ATo < AFrom then
    exit;
  run := 0;
  for i := AFrom to ATo do
    case AText[i] of
      'a'..'z', '0'..'9':
        Inc(run);
      '.':
        begin
          if run = 0 then
            exit; // empty segment
          run := 0;
        end;
    else
      exit;
    end;
  Result := run > 0;
end;

function PWebPrincipalIdValid(const APrincipalId: Utf8String): Boolean;
var
  n, colon, i: PtrInt;
  s: RawUtf8;
begin
  Result := False;
  s := RawUtf8(APrincipalId);
  n := Length(s);
  if (n = 0) or (n > PWEB_RELEASE_PRINCIPAL_MAX_BYTES) then
    exit;
  colon := 0;
  for i := 1 to n do
    if s[i] = ':' then
    begin
      if colon <> 0 then
        exit; // at most one ':'
      colon := i;
    end;
  if colon = 0 then
    Result := LowerDottedRun(s, 1, n)
  else
    Result := LowerDottedRun(s, 1, colon - 1) and
              LowerDottedRun(s, colon + 1, n);
end;

function PWebSourceRootValid(const ARoot: RawUtf8): Boolean;
var
  i, n, seg: PtrInt;
  dots: Integer;
begin
  Result := False;
  n := Length(ARoot);
  if (n = 0) or (n > PWEB_RELEASE_ROOT_MAX_BYTES) then
    exit;
  if (ARoot[1] = '/') or (ARoot[n] = '/') then
    exit;
  seg := 0;
  dots := 0;
  for i := 1 to n do
    case ARoot[i] of
      'A'..'Z', 'a'..'z', '0'..'9', '_', '-':
        Inc(seg);
      '.':
        begin
          Inc(seg);
          Inc(dots);
        end;
      '/':
        begin
          if (seg = 0) or (seg = dots) then
            exit; // empty, '.' or '..' segment
          seg := 0;
          dots := 0;
        end;
    else
      exit; // backslash, colon, control, space, anything else
    end;
  Result := (seg > 0) and (seg <> dots);
end;

function PWebPluginArchiveRoot(const APluginId: Utf8String): RawUtf8;
begin
  Result := RawUtf8(APluginId) + '/';
end;

function StartsWithRoot(const AName, ARoot: RawUtf8): Boolean;
begin
  Result := (Length(AName) > Length(ARoot)) and
    (CompareMem(pointer(AName), pointer(ARoot), Length(ARoot)));
end;

{ ---------------- the trusted build-time plugin list --------------------- }

function ForbiddenListKey(const AKey: RawUtf8): Boolean;
var
  i: PtrInt;
  lower: RawUtf8;
begin
  lower := LowerCaseU(AKey);
  for i := 0 to High(PWEB_PACKAGE_FORBIDDEN_KEYS) do
    if lower = PWEB_PACKAGE_FORBIDDEN_KEYS[i] then
      exit(True);
  Result := False;
end;

function PWebParseTrustedPluginList(const ABytes: RawByteString;
  out APlugins: TPWebTrustedPlugins;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  i, n, lineStart, lineEnd, eq, ks, ke, vs, ve, p: PtrInt;
  line, key, value: RawUtf8;
  cur: Integer;             // index of the block being filled, -1 = none
  seen: array[0..3] of Boolean;  // plugin, principal, root, entry
  which: Integer;

  procedure Refuse(ACodeIn: TPWebReleaseCode; const ADetailIn: RawUtf8);
  begin
    ACode := ACodeIn;
    ADetail := Sanitize(ADetailIn);
    APlugins := nil;
  end;

begin
  Result := False;
  APlugins := nil;
  ACode := prcNone;
  ADetail := '';
  cur := -1;
  FillChar(seen, SizeOf(seen), 0);
  n := Length(ABytes);
  if n > PWEB_RELEASE_LIST_MAX_BYTES then
  begin
    Refuse(prcListTooLarge, IntStr(n) + ' bytes');
    exit;
  end;
  // ASCII only: the whole grammar is ASCII, so a non-ASCII byte is
  // either an encoding accident or an attempt at a confusable
  for i := 1 to n do
    if (ABytes[i] = #0) or (ABytes[i] > #126) or
       ((ABytes[i] < ' ') and (ABytes[i] <> #9) and
        (ABytes[i] <> #10) and (ABytes[i] <> #13)) then
    begin
      Refuse(prcListEncoding, 'byte ' + IntStr(i));
      exit;
    end;
  lineStart := 1;
  while lineStart <= n + 1 do
  begin
    lineEnd := lineStart;
    while (lineEnd <= n) and (ABytes[lineEnd] <> #10) do
      Inc(lineEnd);
    p := lineEnd - 1;
    if (p >= lineStart) and (ABytes[p] = #13) then
      Dec(p);
    line := Copy(ABytes, lineStart, p - lineStart + 1);
    lineStart := lineEnd + 1;
    // trim leading blanks
    ks := 1;
    while (ks <= Length(line)) and
          ((line[ks] = ' ') or (line[ks] = #9)) do
      Inc(ks);
    if ks > Length(line) then
      continue;              // blank line
    if line[ks] = '#' then
      continue;              // comment
    eq := PosEx('=', line, ks);
    if eq = 0 then
    begin
      Refuse(prcListSyntax, line);
      exit;
    end;
    ke := eq - 1;
    while (ke >= ks) and ((line[ke] = ' ') or (line[ke] = #9)) do
      Dec(ke);
    key := Copy(line, ks, ke - ks + 1);
    vs := eq + 1;
    while (vs <= Length(line)) and
          ((line[vs] = ' ') or (line[vs] = #9)) do
      Inc(vs);
    ve := Length(line);
    while (ve >= vs) and ((line[ve] = ' ') or (line[ve] = #9)) do
      Dec(ve);
    value := Copy(line, vs, ve - vs + 1);
    if (key = '') or (value = '') then
    begin
      Refuse(prcListSyntax, line);
      exit;
    end;
    for i := 1 to Length(key) do
      if not (key[i] in ['a'..'z']) then
      begin
        Refuse(prcListSyntax, key);
        exit;
      end;
    // the four legitimate keys are resolved FIRST. 'principal' is one of
    // them: this file is build-time configuration at the developer's own
    // trust level, so naming the native principal here is exactly right.
    // What must never appear is a key implying the file could GRANT
    // something - 'capabilities', 'runtimegrants', 'principalid' - and
    // those get their own loud code below rather than an unknown-field
    // rejection that would be technically correct and useless.
    if key = 'plugin' then
      which := 0
    else if key = 'principal' then
      which := 1
    else if key = 'root' then
      which := 2
    else if key = 'entry' then
      which := 3
    else if ForbiddenListKey(key) then
    begin
      Refuse(prcListForbiddenField, key);
      exit;
    end
    else
    begin
      Refuse(prcListUnknownField, key);
      exit;
    end;
    if which = 0 then
    begin
      // a new block: the previous one must have been complete
      if cur >= 0 then
        for i := 1 to 3 do
          if not seen[i] then
          begin
            Refuse(prcListSyntax, 'incomplete block ' +
              RawUtf8(APlugins[cur].PluginId));
            exit;
          end;
      if Length(APlugins) >= PWEB_RELEASE_MAX_PLUGINS then
      begin
        Refuse(prcListCount, IntStr(PWEB_RELEASE_MAX_PLUGINS));
        exit;
      end;
      SetLength(APlugins, Length(APlugins) + 1);
      cur := High(APlugins);
      APlugins[cur] := Default(TPWebTrustedPlugin);
      FillChar(seen, SizeOf(seen), 0);
    end
    else if cur < 0 then
    begin
      Refuse(prcListSyntax, key + ' before any plugin');
      exit;
    end;
    if seen[which] then
    begin
      Refuse(prcListDuplicateKey, key);
      exit;
    end;
    seen[which] := True;
    case which of
      0:
        begin
          if not PWebPackageIdValid(value) then
          begin
            Refuse(prcListPluginId, value);
            exit;
          end;
          APlugins[cur].PluginId := Utf8String(value);
        end;
      1:
        begin
          if not PWebPrincipalIdValid(Utf8String(value)) then
          begin
            Refuse(prcListPrincipalId, value);
            exit;
          end;
          APlugins[cur].PrincipalId := Utf8String(value);
        end;
      2:
        begin
          if not PWebSourceRootValid(value) then
          begin
            Refuse(prcListRoot, value);
            exit;
          end;
          APlugins[cur].Root := value;
        end;
      3:
        begin
          if not PWebPackageEntryValid(value) then
          begin
            Refuse(prcListEntry, value);
            exit;
          end;
          APlugins[cur].EntryPoint := Utf8String(value);
        end;
    end;
  end;
  if cur >= 0 then
    for i := 1 to 3 do
      if not seen[i] then
      begin
        Refuse(prcListSyntax, 'incomplete block ' +
          RawUtf8(APlugins[cur].PluginId));
        exit;
      end;
  if Length(APlugins) = 0 then
  begin
    Refuse(prcListEmpty, '');
    exit;
  end;
  // uniqueness across the whole list. PrincipalId uniqueness is
  // deliberate: two plugins sharing one principal would silently share
  // its capabilities, and that is a decision to ratify, not to inherit
  for i := 0 to High(APlugins) do
    for p := i + 1 to High(APlugins) do
      if (APlugins[i].PluginId = APlugins[p].PluginId) or
         (APlugins[i].PrincipalId = APlugins[p].PrincipalId) or
         (APlugins[i].Root = APlugins[p].Root) then
      begin
        Refuse(prcListDuplicate, RawUtf8(APlugins[p].PluginId));
        exit;
      end;
  Result := True;
end;

{ ---------------- inventory and graph projections ------------------------ }

function PWebInventoryText(const AInventory: TPWebInventory): RawUtf8;
var
  i: PtrInt;
begin
  Result := '';
  for i := 0 to High(AInventory) do
    Result := Result + AInventory[i].Name + ' ' +
      IntStr(AInventory[i].Bytes) + ' ' + AInventory[i].Sha256 + #10;
end;

function PWebInventoryDigest(const AInventory: TPWebInventory): RawUtf8;
begin
  Result := PWebSha256Hex(PWebInventoryText(AInventory));
end;

function PWebGraphText(const APluginId, AEntryPoint: Utf8String;
  const AModules, AHashes, AEdges: TRawUtf8DynArray): RawUtf8;
var
  i: PtrInt;
begin
  Result := 'plugin=' + RawUtf8(APluginId) + #10 +
            'entry=' + RawUtf8(AEntryPoint) + #10;
  for i := 0 to High(AModules) do
  begin
    Result := Result + 'module=' + AModules[i];
    if i <= High(AHashes) then
      Result := Result + ' sha=' + AHashes[i];
    Result := Result + #10;
  end;
  for i := 0 to High(AEdges) do
    Result := Result + 'edge=' + AEdges[i] + #10;
end;

function PWebGraphDigest(const APluginId, AEntryPoint: Utf8String;
  const AModules, AHashes, AEdges: TRawUtf8DynArray): RawUtf8;
begin
  Result := PWebSha256Hex(
    PWebGraphText(APluginId, AEntryPoint, AModules, AHashes, AEdges));
end;

{ ---------------- deterministic plugin-archive writer -------------------- }

function ReleaseTempFileName(const AOutFile: TFileName): TFileName;
begin
  // the process id keeps concurrent builders targeting one output from
  // colliding on the temp file (the CAP-6 rule, reused)
  Result := AOutFile + TFileName('.tmp' + IntStr(GetCurrentProcessId));
end;

function PWebWritePluginArchive(const AOutFile: TFileName;
  const AEntries: TPWebReleaseEntries;
  const ARoots: TRawUtf8DynArray;
  out AInventory: TPWebInventory;
  out ASha256: RawUtf8; out ABytes: Int64;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  n, i, j, ins, r: PtrInt;
  names: TRawUtf8DynArray;
  order: TIntegerDynArray;
  folded: TRawUtf8DynArray;
  name, raw: RawUtf8;
  content: RawByteString;
  tmp: TFileName;
  tmpCreated, replaced, inside: Boolean;
  zw: TZipWrite;
  zr: TZipRead;
  probe: TZipAssetStore;
  probeRef: IAssetStore;
  asset: TAssetResponse;
  data: RawByteString;
  {$ifdef WINDOWS}
  tmpW, outW: SynUnicode;
  {$endif WINDOWS}

  procedure Refuse(ACodeIn: TPWebReleaseCode; const ADetailIn: RawUtf8);
  begin
    ACode := ACodeIn;
    ADetail := Sanitize(ADetailIn);
  end;

begin
  Result := False;
  AInventory := nil;
  ASha256 := '';
  ABytes := 0;
  ACode := prcNone;
  ADetail := '';
  tmpCreated := False;
  replaced := False;
  probe := nil;
  n := Length(AEntries);
  if (n = 0) or (n > PWEB_RELEASE_MAX_ENTRIES) then
  begin
    Refuse(prcEntryCount, IntStr(n));
    exit;
  end;
  if Length(ARoots) = 0 then
  begin
    Refuse(prcRegistry, 'no registered plugin root');
    exit;
  end;
  // ---- validation, entirely before anything touches the disk ----
  SetLength(names, n);
  SetLength(order, n);
  for i := 0 to n - 1 do
  begin
    name := AEntries[i].Name;
    if (not PWebAssetPathValid(name)) or
       (Length(name) > PWEB_ASSET_PATH_MAX_BYTES) then
    begin
      Refuse(prcEntryName, name);
      exit;
    end;
    inside := False;
    for r := 0 to High(ARoots) do
      if StartsWithRoot(name, ARoots[r]) then
      begin
        inside := True;
        break;
      end;
    if not inside then
    begin
      // an unregistered root can never instantiate itself: it cannot
      // even enter the archive
      Refuse(prcEntryOutsideRoot, name);
      exit;
    end;
    if Int64(Length(AEntries[i].Content)) > PWEB_RELEASE_ENTRY_MAX_BYTES then
    begin
      Refuse(prcEntryTooLarge, name);
      exit;
    end;
    // TZipWrite takes native TFileName entry names; require an exact
    // byte round-trip so the codepage hazard fails loudly here
    if StringToUtf8(Utf8ToString(name)) <> name then
    begin
      Refuse(prcEntryCodepage, name);
      exit;
    end;
    // insertion sort: global bytewise order of canonical names, so
    // filesystem or caller order never reaches the archive
    ins := 0;
    while (ins < i) and (CompareStr(names[ins], name) < 0) do
      Inc(ins);
    if (ins < i) and (names[ins] = name) then
    begin
      Refuse(prcEntryDuplicate, name);
      exit;
    end;
    for j := i downto ins + 1 do
    begin
      names[j] := names[j - 1];
      order[j] := order[j - 1];
    end;
    names[ins] := name;
    order[ins] := i;
  end;
  // ratified CAP-6 D1, enforcement point 1 (point 2 is TZipAssetStore,
  // which this writer's self-validation below actually runs)
  SetLength(folded, n);
  for i := 0 to n - 1 do
    folded[i] := UpperCaseReference(names[i]);
  for i := 0 to n - 1 do
    for j := i + 1 to n - 1 do
      if folded[i] = folded[j] then
      begin
        Refuse(prcEntryCollision, names[i] + ' vs ' + names[j]);
        exit;
      end;
  // a name that is also a directory prefix of another is ambiguous
  for i := 0 to n - 1 do
    for j := 0 to n - 1 do
      if (i <> j) and
         (Length(names[j]) > Length(names[i]) + 1) and
         (CompareStr(Copy(names[j], 1, Length(names[i])), names[i]) = 0) and
         (names[j][Length(names[i]) + 1] = '/') then
      begin
        Refuse(prcEntryCollision, names[i] + ' vs ' + names[j]);
        exit;
      end;
  // ---- deterministic write to a temp sibling ----
  tmp := ReleaseTempFileName(AOutFile);
  try
    try
      SysUtils.DeleteFile(tmp);  // stale temp of an interrupted run
      zw := TZipWrite.Create(tmp);
      tmpCreated := True;
      try
        for i := 0 to n - 1 do
        begin
          content := AEntries[order[i]].Content;
          zw.AddDeflated(Utf8ToString(names[i]), pointer(content),
            Length(content), PWEB_BUNDLE_DEFLATE_LEVEL,
            PWEB_BUNDLE_FIXED_FILE_AGE);
        end;
        if zw.NeedZip64 then
        begin
          Refuse(prcArchiveWrite, 'zip64 extra fields break determinism');
          exit;
        end;
      finally
        zw.Free;
      end;
      // ---- self-validation 1: raw stored names, timestamps, extras ----
      zr := TZipRead.Create(tmp);
      try
        if zr.Count <> n then
        begin
          Refuse(prcArchiveWrite, 'entry count drifted');
          exit;
        end;
        for i := 0 to n - 1 do
        begin
          FastSetString(raw, zr.Entry[i].storedName,
            zr.Entry[i].dir^.fileInfo.nameLen);
          if raw <> names[i] then
          begin
            Refuse(prcArchiveWrite, 'stored name drifted: ' + raw);
            exit;
          end;
          if zr.Entry[i].dir^.fileInfo.zlastMod <>
               PWEB_BUNDLE_FIXED_FILE_AGE then
          begin
            Refuse(prcArchiveWrite, 'non-deterministic timestamp on ' +
              names[i]);
            exit;
          end;
          if zr.Entry[i].dir^.fileInfo.extraLen <> 0 then
          begin
            Refuse(prcArchiveWrite, 'unexpected extra field on ' + names[i]);
            exit;
          end;
        end;
      finally
        zr.Free;
      end;
      // ---- self-validation 2: the PRODUCTION store must accept ----
      try
        probe := TZipAssetStore.Create(tmp);
      except
        on E: Exception do
        begin
          Refuse(prcArchiveWrite, 'production store refused the archive (' +
            RawUtf8(E.ClassName) + ')');
          exit;
        end;
      end;
      probeRef := probe;
      if probe.EntryCount <> n then
      begin
        Refuse(prcArchiveWrite, 'store enumeration drifted');
        exit;
      end;
      SetLength(AInventory, n);
      for i := 0 to n - 1 do
      begin
        if probe.EntryName(i) <> names[i] then
        begin
          Refuse(prcArchiveWrite, 'store enumeration order drifted at ' +
            IntStr(i));
          exit;
        end;
        if not probeRef.TryRead(names[i], asset) then
        begin
          Refuse(prcArchiveWrite, 'entry unreadable: ' + names[i]);
          exit;
        end;
        if asset.Content <> AEntries[order[i]].Content then
        begin
          Refuse(prcArchiveWrite, 'content drifted: ' + names[i]);
          exit;
        end;
        AInventory[i].Name := names[i];
        AInventory[i].Bytes := Length(asset.Content);
        AInventory[i].Sha256 := PWebSha256Hex(asset.Content);
      end;
      probeRef := nil;   // release the handle before the replace
      probe := nil;
      // ---- the whole-archive digest of what is about to be installed ----
      data := StringFromFile(tmp);
      if data = '' then
      begin
        Refuse(prcArchiveWrite, 'the written archive could not be re-read');
        exit;
      end;
      ASha256 := PWebSha256Hex(data);
      ABytes := Length(data);
      data := '';
      // ---- atomic replace: the previous output survives or is replaced ----
      {$ifdef WINDOWS}
      tmpW := Utf8ToSynUnicode(StringToUtf8(tmp));
      outW := Utf8ToSynUnicode(StringToUtf8(AOutFile));
      if not MoveFileExW(PWideChar(tmpW), PWideChar(outW),
           MOVEFILE_REPLACE_EXISTING) then
      begin
        Refuse(prcArchiveWrite, 'atomic replace failed (Win32 error ' +
          IntStr(GetLastError) + ')');
        exit;
      end;
      {$else}
      if not RenameFile(tmp, AOutFile) then
      begin
        Refuse(prcArchiveWrite, 'atomic replace failed (rename)');
        exit;
      end;
      {$endif WINDOWS}
      replaced := True;
      Result := True;
    except
      on E: Exception do
      begin
        Refuse(prcArchiveWrite, RawUtf8(E.ClassName) + ': ' +
          RawUtf8(E.Message));
        Result := False;
      end;
    end;
  finally
    probeRef := nil;
    probe := nil;
    if tmpCreated and not replaced then
      SysUtils.DeleteFile(tmp);   // prior output untouched
    if not Result then
    begin
      AInventory := nil;
      ASha256 := '';
      ABytes := 0;
    end;
  end;
end;

{ ---------------- registry assembly and validation ----------------------- }

function PWebRegistryFrom(const APackageFile, APackageSha256: RawUtf8;
  APackageBytes: Int64; const AInventoryDigest: RawUtf8;
  const AInventory: array of TPWebInventoryEntry;
  const APlugins: array of TPWebRegistryPlugin): TPWebPackageRegistry;
var
  i: PtrInt;
begin
  Result := Default(TPWebPackageRegistry);
  Result.PackageFile := APackageFile;
  Result.PackageSha256 := APackageSha256;
  Result.PackageBytes := APackageBytes;
  Result.InventoryDigest := AInventoryDigest;
  SetLength(Result.Inventory, Length(AInventory));
  for i := 0 to High(AInventory) do
    Result.Inventory[i] := AInventory[i];
  SetLength(Result.Plugins, Length(APlugins));
  for i := 0 to High(APlugins) do
    Result.Plugins[i] := APlugins[i];
end;

function BareFileNameValid(const AName: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if (AName = '') or (Length(AName) > 128) then
    exit;
  for i := 1 to Length(AName) do
    case AName[i] of
      'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-':
        ;
    else
      exit;   // '/', '\', ':', control, space - a bare name has none
    end;
  // no leading dot and no '..' anywhere: never a directory traversal
  Result := (AName[1] <> '.') and (PosEx('..', AName, 1) = 0);
end;

function PWebValidateRegistry(const ARegistry: TPWebPackageRegistry;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  i, j, r: PtrInt;
  root, manifest, entry: RawUtf8;
  haveManifest, haveEntry, inside: Boolean;
  modules: Integer;
  bytes: Int64;

  procedure Refuse(const ADetailIn: RawUtf8);
  begin
    ACode := prcRegistry;
    ADetail := Sanitize(ADetailIn);
  end;

begin
  Result := False;
  ACode := prcNone;
  ADetail := '';
  if not BareFileNameValid(ARegistry.PackageFile) then
  begin
    Refuse('package file name');
    exit;
  end;
  if not PWebSha256HexValid(ARegistry.PackageSha256) then
  begin
    Refuse('package sha256');
    exit;
  end;
  if (ARegistry.PackageBytes <= 0) or
     (ARegistry.PackageBytes > PWEB_RELEASE_PACKAGE_MAX_BYTES) then
  begin
    Refuse('package bytes');
    exit;
  end;
  if not PWebSha256HexValid(ARegistry.InventoryDigest) then
  begin
    Refuse('inventory digest');
    exit;
  end;
  if (Length(ARegistry.Inventory) = 0) or
     (Length(ARegistry.Inventory) > PWEB_RELEASE_MAX_ENTRIES) then
  begin
    Refuse('inventory size');
    exit;
  end;
  if (Length(ARegistry.Plugins) = 0) or
     (Length(ARegistry.Plugins) > PWEB_RELEASE_MAX_PLUGINS) then
  begin
    Refuse('plugin count');
    exit;
  end;
  // the inventory digest must be the digest OF this inventory: a
  // registry whose two halves disagree is refused before a file is read
  if PWebInventoryDigest(ARegistry.Inventory) <> ARegistry.InventoryDigest then
  begin
    Refuse('inventory digest does not match the inventory');
    exit;
  end;
  for i := 0 to High(ARegistry.Inventory) do
  begin
    if not PWebAssetPathValid(ARegistry.Inventory[i].Name) then
    begin
      Refuse('inventory name ' + IntStr(i));
      exit;
    end;
    if (ARegistry.Inventory[i].Bytes < 0) or
       (ARegistry.Inventory[i].Bytes > PWEB_RELEASE_ENTRY_MAX_BYTES) then
    begin
      Refuse('inventory bytes ' + ARegistry.Inventory[i].Name);
      exit;
    end;
    if not PWebSha256HexValid(ARegistry.Inventory[i].Sha256) then
    begin
      Refuse('inventory sha ' + ARegistry.Inventory[i].Name);
      exit;
    end;
    if (i > 0) and
       (CompareStr(ARegistry.Inventory[i - 1].Name,
          ARegistry.Inventory[i].Name) >= 0) then
    begin
      Refuse('inventory order at ' + ARegistry.Inventory[i].Name);
      exit;
    end;
  end;
  for i := 0 to High(ARegistry.Plugins) do
  begin
    if not PWebPackageIdValid(RawUtf8(ARegistry.Plugins[i].PluginId)) then
    begin
      Refuse('plugin id ' + IntStr(i));
      exit;
    end;
    if not PWebPrincipalIdValid(ARegistry.Plugins[i].PrincipalId) then
    begin
      Refuse('principal id ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if ARegistry.Plugins[i].Root <>
         PWebPluginArchiveRoot(ARegistry.Plugins[i].PluginId) then
    begin
      Refuse('root <> pluginid/ for ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if not PWebPackageEntryValid(RawUtf8(ARegistry.Plugins[i].EntryPoint)) then
    begin
      Refuse('entry ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if not PWebPackageIdValid(RawUtf8(ARegistry.Plugins[i].PackageId)) then
    begin
      Refuse('package id ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if not PWebSha256HexValid(ARegistry.Plugins[i].GraphDigest) then
    begin
      Refuse('graph digest ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if (ARegistry.Plugins[i].ModuleCount <= 0) or
       (ARegistry.Plugins[i].ModuleCount > PWEB_RELEASE_MAX_ENTRIES) then
    begin
      Refuse('module count ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if (ARegistry.Plugins[i].SourceBytes <= 0) or
       (ARegistry.Plugins[i].SourceBytes > PWEB_RELEASE_PACKAGE_MAX_BYTES) then
    begin
      Refuse('source bytes ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    // a zero CPU bound would make a runaway entry module unkillable:
    // CAP-9B1 already refuses it in the descriptor, and the registry is
    // refused here so it can never even be built
    if ARegistry.Plugins[i].TimeoutSeconds = 0 then
    begin
      Refuse('zero cpu bound ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if (ARegistry.Plugins[i].MemoryLimitBytes = 0) or
       (ARegistry.Plugins[i].StackLimitBytes = 0) or
       (ARegistry.Plugins[i].InvokeWaitMs <= 0) then
    begin
      Refuse('zero engine bound ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    if (i > 0) and
       (CompareStr(RawUtf8(ARegistry.Plugins[i - 1].PluginId),
          RawUtf8(ARegistry.Plugins[i].PluginId)) >= 0) then
    begin
      Refuse('plugin order at ' + RawUtf8(ARegistry.Plugins[i].PluginId));
      exit;
    end;
    for j := 0 to i - 1 do
      if ARegistry.Plugins[j].PrincipalId = ARegistry.Plugins[i].PrincipalId then
      begin
        Refuse('duplicate principal ' + RawUtf8(ARegistry.Plugins[i].PrincipalId));
        exit;
      end;
  end;
  // every inventory entry belongs to exactly one registered root, and
  // every plugin owns its manifest and its declared entry point
  for i := 0 to High(ARegistry.Inventory) do
  begin
    inside := False;
    for r := 0 to High(ARegistry.Plugins) do
      if StartsWithRoot(ARegistry.Inventory[i].Name,
           ARegistry.Plugins[r].Root) then
      begin
        inside := True;
        break;
      end;
    if not inside then
    begin
      Refuse('inventory entry outside every root: ' +
        ARegistry.Inventory[i].Name);
      exit;
    end;
  end;
  for r := 0 to High(ARegistry.Plugins) do
  begin
    root := ARegistry.Plugins[r].Root;
    manifest := root + PWEB_PACKAGE_MANIFEST;
    entry := root + RawUtf8(ARegistry.Plugins[r].EntryPoint);
    haveManifest := False;
    haveEntry := False;
    modules := 0;
    bytes := 0;
    for i := 0 to High(ARegistry.Inventory) do
      if StartsWithRoot(ARegistry.Inventory[i].Name, root) then
      begin
        if ARegistry.Inventory[i].Name = manifest then
          haveManifest := True
        else
        begin
          Inc(modules);
          Inc(bytes, ARegistry.Inventory[i].Bytes);
        end;
        if ARegistry.Inventory[i].Name = entry then
          haveEntry := True;
      end;
    if not haveManifest then
    begin
      Refuse('no ' + PWEB_PACKAGE_MANIFEST + ' under ' + root);
      exit;
    end;
    if not haveEntry then
    begin
      Refuse('entry point missing from the inventory: ' + entry);
      exit;
    end;
    if modules <> ARegistry.Plugins[r].ModuleCount then
    begin
      Refuse('module count <> inventory under ' + root);
      exit;
    end;
    if bytes <> ARegistry.Plugins[r].SourceBytes then
    begin
      Refuse('source bytes <> inventory under ' + root);
      exit;
    end;
  end;
  Result := True;
end;

{ ---------------- the generated native registry emitter ------------------ }

{ The ONE place a value becomes Pascal source. It accepts printable
  ASCII without a quote and REFUSES everything else - it never escapes.
  Every field that reaches it has already passed a constrained grammar
  (ids, canonical paths, 64-hex digests), so a refusal here means a
  caller bypassed a validator, not that a legitimate value was awkward. }
function PascalLiteral(const AValue: RawUtf8; out ALiteral: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  ALiteral := '';
  Result := False;
  if Length(AValue) > 1024 then
    exit;
  for i := 1 to Length(AValue) do
    if (AValue[i] < ' ') or (AValue[i] > #126) or (AValue[i] = '''') then
      exit;
  ALiteral := '''' + AValue + '''';
  Result := True;
end;

function PWebEmitRegistryInclude(const ARegistry: TPWebPackageRegistry;
  const AToolId: RawUtf8; out AText: RawUtf8;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  i: PtrInt;
  lit, tool: RawUtf8;
  sb: RawUtf8;

  function NeedLit(const AValue: RawUtf8; const AWhat: RawUtf8): Boolean;
  begin
    Result := PascalLiteral(AValue, lit);
    if not Result then
    begin
      ACode := prcRegistryEmit;
      ADetail := Sanitize(AWhat);
    end;
  end;

begin
  Result := False;
  AText := '';
  ACode := prcNone;
  ADetail := '';
  // never emit a registry that would not survive its own gate
  if not PWebValidateRegistry(ARegistry, ACode, ADetail) then
    exit;
  if not PascalLiteral(AToolId, tool) then
  begin
    ACode := prcRegistryEmit;
    ADetail := 'tool id';
    exit;
  end;
  sb :=
    '{ GENERATED FILE - DO NOT EDIT.' + #10 +
    #10 +
    '  CAP-9C1 trusted QuickJS plugin registry, produced by ' + AToolId +
      ' from' + #10 +
    '  the trusted build-time plugin list. It is compiled INTO the' + #10 +
    '  executable and is never shipped as a runtime configuration file:' + #10 +
    '  the runtime must not be able to recover security-sensitive' + #10 +
    '  descriptor data by reading a sibling file.' + #10 +
    #10 +
    '  Deterministic by construction - sorted rows, canonical strings,' + #10 +
    '  exact digest lengths, no absolute build path, no timestamp and no' + #10 +
    '  host name - so regeneration from the same inputs on the same' + #10 +
    '  toolchain is byte-identical.' + #10 +
    #10 +
    '  Capabilities are deliberately ABSENT: they come from the CAP-8' + #10 +
    '  policy keyed by PrincipalId, so nothing in the packaging path can' + #10 +
    '  grant a right. Engine and package bounds are the ratified' + #10 +
    '  defaults, not build-time input, so no build-time file can raise a' + #10 +
    '  memory cap or switch a CPU bound off. }' + #10 +
    #10 +
    '{ WRITEABLECONST OFF around the whole block. This registry is the' + #10 +
    '  trust anchor: in Delphi mode typed constants are WRITEABLE by' + #10 +
    '  default, so without this a stray pointer or an out-of-range write' + #10 +
    '  could edit the expected package digest at run time and the' + #10 +
    '  verifier would faithfully compare against the edited value. PUSH' + #10 +
    '  and POP so the including unit''s own setting is restored. }' + #10 +
    '{$PUSH}' + #10 +
    '{$J-}' + #10 +
    #10 +
    'const' + #10 +
    '  PWEB_QUICKJS_REGISTRY_TOOL: RawUtf8 = ' + tool + ';' + #10;
  if not NeedLit(ARegistry.PackageFile, 'package file') then
    exit;
  sb := sb + '  PWEB_QUICKJS_PACKAGE_FILE: RawUtf8 = ' + lit + ';' + #10;
  if not NeedLit(ARegistry.PackageSha256, 'package sha256') then
    exit;
  sb := sb + '  PWEB_QUICKJS_PACKAGE_SHA256: RawUtf8 = ' + lit + ';' + #10;
  sb := sb + '  PWEB_QUICKJS_PACKAGE_BYTES = Int64(' +
    IntStr(ARegistry.PackageBytes) + ');' + #10;
  if not NeedLit(ARegistry.InventoryDigest, 'inventory digest') then
    exit;
  sb := sb + '  PWEB_QUICKJS_INVENTORY_DIGEST: RawUtf8 = ' + lit + ';' + #10 +
    #10 +
    '  PWEB_QUICKJS_INVENTORY: array[0..' +
      IntStr(Length(ARegistry.Inventory) - 1) +
      '] of TPWebInventoryEntry = (' + #10;
  for i := 0 to High(ARegistry.Inventory) do
  begin
    if not NeedLit(ARegistry.Inventory[i].Name, 'inventory name') then
      exit;
    sb := sb + '    (Name: ' + lit + ';' + #10 +
      '     Bytes: ' + IntStr(ARegistry.Inventory[i].Bytes) + ';' + #10;
    if not NeedLit(ARegistry.Inventory[i].Sha256, 'inventory sha') then
      exit;
    sb := sb + '     Sha256: ' + lit + ')';
    if i < High(ARegistry.Inventory) then
      sb := sb + ',';
    sb := sb + #10;
  end;
  sb := sb + '  );' + #10 + #10 +
    '  PWEB_QUICKJS_PLUGINS: array[0..' +
      IntStr(Length(ARegistry.Plugins) - 1) +
      '] of TPWebRegistryPlugin = (' + #10;
  for i := 0 to High(ARegistry.Plugins) do
  begin
    if not NeedLit(RawUtf8(ARegistry.Plugins[i].PluginId), 'plugin id') then
      exit;
    sb := sb + '    (PluginId: ' + lit + ';' + #10;
    if not NeedLit(RawUtf8(ARegistry.Plugins[i].PrincipalId), 'principal id') then
      exit;
    sb := sb + '     PrincipalId: ' + lit + ';' + #10;
    if not NeedLit(ARegistry.Plugins[i].Root, 'root') then
      exit;
    sb := sb + '     Root: ' + lit + ';' + #10;
    if not NeedLit(RawUtf8(ARegistry.Plugins[i].EntryPoint), 'entry point') then
      exit;
    sb := sb + '     EntryPoint: ' + lit + ';' + #10;
    if not NeedLit(RawUtf8(ARegistry.Plugins[i].PackageId), 'package id') then
      exit;
    sb := sb + '     PackageId: ' + lit + ';' + #10;
    if not NeedLit(ARegistry.Plugins[i].GraphDigest, 'graph digest') then
      exit;
    sb := sb + '     GraphDigest: ' + lit + ';' + #10 +
      '     ModuleCount: ' + IntStr(ARegistry.Plugins[i].ModuleCount) +
        ';' + #10 +
      '     SourceBytes: ' + IntStr(ARegistry.Plugins[i].SourceBytes) +
        ';' + #10 +
      '     TimeoutSeconds: ' + IntStr(ARegistry.Plugins[i].TimeoutSeconds) +
        ';' + #10 +
      '     MemoryLimitBytes: ' + IntStr(ARegistry.Plugins[i].MemoryLimitBytes) +
        ';' + #10 +
      '     StackLimitBytes: ' + IntStr(ARegistry.Plugins[i].StackLimitBytes) +
        ';' + #10 +
      '     InvokeWaitMs: ' + IntStr(ARegistry.Plugins[i].InvokeWaitMs) +
        ';' + #10 +
      '     Package: (' + #10 +
      '       ManifestMaxBytes: ' +
        IntStr(ARegistry.Plugins[i].Package.ManifestMaxBytes) + ';' + #10 +
      '       ModuleMaxBytes: ' +
        IntStr(ARegistry.Plugins[i].Package.ModuleMaxBytes) + ';' + #10 +
      '       TotalSourceMaxBytes: ' +
        IntStr(ARegistry.Plugins[i].Package.TotalSourceMaxBytes) + ';' + #10 +
      '       MaxModules: ' +
        IntStr(ARegistry.Plugins[i].Package.MaxModules) + ';' + #10 +
      '       MaxSpecifierBytes: ' +
        IntStr(ARegistry.Plugins[i].Package.MaxSpecifierBytes) + ';' + #10 +
      '       MaxGraphDepth: ' +
        IntStr(ARegistry.Plugins[i].Package.MaxGraphDepth) + '))';
    if i < High(ARegistry.Plugins) then
      sb := sb + ',';
    sb := sb + #10;
  end;
  sb := sb + '  );' + #10 + #10 + '{$POP}' + #10;
  AText := sb;
  Result := True;
end;

{ ---------------- locating and reading the package ----------------------- }

{ A release artifact is resolved from an ABSOLUTE directory or not at
  all: a relative one would be resolved against the current working
  directory, which is exactly the dependency this shard must not have. }
function AbsoluteDirectory(const ADir: TFileName): Boolean;
begin
  {$ifdef WINDOWS}
  Result := ((Length(ADir) >= 3) and
             (((ADir[1] >= 'A') and (ADir[1] <= 'Z')) or
              ((ADir[1] >= 'a') and (ADir[1] <= 'z'))) and
             (ADir[2] = ':') and
             ((ADir[3] = '\') or (ADir[3] = '/'))) or
            ((Length(ADir) >= 2) and
             ((ADir[1] = '\') or (ADir[1] = '/')) and
             ((ADir[2] = '\') or (ADir[2] = '/')));
  {$else}
  Result := (Length(ADir) >= 1) and (ADir[1] = '/');
  {$endif WINDOWS}
end;

function PWebReleaseDirectory: TFileName;
begin
  // Executable.ProgramFilePath is absolute and independent of the
  // current working directory - the same rule app.pwb already follows
  Result := Executable.ProgramFilePath;
end;

{ THE read. Two whole platform bodies rather than one body stitched from
  conditionals: this is security code whose control flow must be obvious
  at a glance, and it follows the ratified TFolderAssetStore precedent
  (pweb.assets.folder.pas splits ReadWholeFile the same way and for the
  same reason). Both bodies obey the identical contract:

    ONE handle, opened refusing symlink/reparse indirection and anything
    that is not a regular file; the size bounded BEFORE a byte is read;
    the buffer filled in 1 MiB chunks with the digest updated as it
    fills, so there is never a second pass over the file and therefore
    no check/open window to race; a short read is a refusal, never a
    truncated buffer. }
{$ifdef WINDOWS}
const
  { Declared here rather than assumed from the RTL: the FPC Windows unit
    of the pinned toolchain does not export it, and a security flag that
    silently resolves to something else would be worse than none. Value
    from the Win32 SDK (winbase.h). }
  PWEB_FILE_FLAG_OPEN_REPARSE_POINT = $00200000;

function ReadAndHashOnce(const AFileName: TFileName; AMaxBytes: Int64;
  out AData: RawByteString; out ASha256: RawUtf8;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  h: THandle;
  wide: SynUnicode;
  info: BY_HANDLE_FILE_INFORMATION;
  size, done: Int64;
  chunk: PtrInt;
  rd: DWORD;
  sha: TSha256;
  dig: TSha256Digest;
begin
  Result := False;
  wide := Utf8ToSynUnicode(StringToUtf8(AFileName));
  { FILE_FLAG_OPEN_REPARSE_POINT is what makes the attribute test below
    REACHABLE, and its absence is the defect CAP-9C2 found by driving a
    real symlinked plugins.zip through a real release layout on the
    hosted Windows runner: without the flag CreateFileW FOLLOWS the link
    and hands back a handle to the TARGET, whose attributes of course
    carry no FILE_ATTRIBUTE_REPARSE_POINT - so the check could never
    fire and the archive was read through the indirection it exists to
    refuse. With the flag the handle refers to the reparse point itself
    and the test refuses it; on an ordinary file the flag is a no-op, so
    the ONE-handle / no-second-read / no-TOCTOU property is unchanged.
    (POSIX already had this right through O_NOFOLLOW.) }
  h := CreateFileW(PWideChar(wide), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING,
    FILE_FLAG_SEQUENTIAL_SCAN or PWEB_FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    if GetLastError = ERROR_FILE_NOT_FOUND then
      ACode := prcPackageMissing
    else
      ACode := prcPackageUnreadable;
    ADetail := 'win32 error ' + IntStr(GetLastError);
    exit;
  end;
  try
    FillChar(info{%H-}, SizeOf(info), 0);
    if not GetFileInformationByHandle(h, info) then
    begin
      ACode := prcPackageUnreadable;
      ADetail := 'file information unavailable';
      exit;
    end;
    // a reparse point is indirection nobody asked for. The digest would
    // catch a substituted target anyway; refusing the indirection is the
    // cheaper, earlier line.
    if (info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
    begin
      ACode := prcPackageUnreadable;
      ADetail := 'reparse point refused';
      exit;
    end;
    if (info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
    begin
      ACode := prcPackageUnreadable;
      ADetail := 'not a regular file';
      exit;
    end;
    size := (Int64(info.nFileSizeHigh) shl 32) or info.nFileSizeLow;
    if size <= 0 then
    begin
      ACode := prcPackageSize;
      ADetail := 'empty';
      exit;
    end;
    // bounded BEFORE a byte is read: this is what keeps materialise-once
    // from being an unbounded allocation
    if size > AMaxBytes then
    begin
      ACode := prcPackageSize;
      ADetail := IntStr(size) + ' > ' + IntStr(AMaxBytes);
      exit;
    end;
    SetLength(AData, size);
    sha.Init;
    done := 0;
    while done < size do
    begin
      chunk := $100000;                        // 1 MiB
      if size - done < chunk then
        chunk := size - done;
      if not ReadFile(h, PByteArray(AData)^[done], DWORD(chunk),
           rd{%H-}, nil) or
         (rd = 0) then
      begin
        AData := '';
        ACode := prcPackageSize;
        ADetail := 'short read';
        exit;
      end;
      sha.Update(@PByteArray(AData)^[done], rd);
      Inc(done, rd);
    end;
    sha.Final(dig{%H-});
    ASha256 := LowerCaseU(Sha256DigestToString(dig));
    Result := True;
  finally
    CloseHandle(h);
  end;
end;
{$else}
function ReadAndHashOnce(const AFileName: TFileName; AMaxBytes: Int64;
  out AData: RawByteString; out ASha256: RawUtf8;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  fd: cint;
  st: stat;
  size, done: Int64;
  chunk, rd: PtrInt;
  sha: TSha256;
  dig: TSha256Digest;
  raw: RawByteString;
begin
  Result := False;
  // POSIX paths are BYTES. Going through StringToUtf8 rather than casting
  // the system string keeps this independent of whatever code page the
  // RTL happens to be configured with - the same reason the CAP-9C1
  // packager talks to the Windows wide API directly.
  raw := StringToUtf8(AFileName);
  // O_NOFOLLOW: a final component that is a symlink makes the OPEN fail
  // instead of resolving somewhere else
  fd := FpOpen(raw, O_RDONLY or O_NOFOLLOW);
  if fd < 0 then
  begin
    // classify without naming an errno constant whose unit varies:
    // a path that exists but would not open is unreadable (a symlink
    // refused by O_NOFOLLOW lands here, correctly), anything else is
    // missing. The digest still governs either way.
    if FileExists(AFileName) then
      ACode := prcPackageUnreadable
    else
      ACode := prcPackageMissing;
    ADetail := 'errno ' + IntStr(fpgeterrno);
    exit;
  end;
  try
    if FpFstat(fd, st{%H-}) <> 0 then
    begin
      ACode := prcPackageUnreadable;
      ADetail := 'fstat failed';
      exit;
    end;
    if not fpS_ISREG(st.st_mode) then
    begin
      ACode := prcPackageUnreadable;
      ADetail := 'not a regular file';
      exit;
    end;
    size := st.st_size;
    if size <= 0 then
    begin
      ACode := prcPackageSize;
      ADetail := 'empty';
      exit;
    end;
    if size > AMaxBytes then
    begin
      ACode := prcPackageSize;
      ADetail := IntStr(size) + ' > ' + IntStr(AMaxBytes);
      exit;
    end;
    SetLength(AData, size);
    sha.Init;
    done := 0;
    while done < size do
    begin
      chunk := $100000;                        // 1 MiB
      if size - done < chunk then
        chunk := size - done;
      rd := FpRead(fd, PByteArray(AData)^[done], chunk);
      if rd <= 0 then
      begin
        AData := '';
        ACode := prcPackageSize;
        ADetail := 'short read';
        exit;
      end;
      sha.Update(@PByteArray(AData)^[done], rd);
      Inc(done, rd);
    end;
    sha.Final(dig{%H-});
    ASha256 := LowerCaseU(Sha256DigestToString(dig));
    Result := True;
  finally
    FpClose(fd);
  end;
end;
{$endif WINDOWS}

function PWebReadAndHashReleaseFile(const AFileName: TFileName;
  AMaxBytes: Int64; out AData: RawByteString; out ASha256: RawUtf8;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
begin
  AData := '';
  ASha256 := '';
  ACode := prcNone;
  ADetail := '';
  if AMaxBytes <= 0 then
    AMaxBytes := PWEB_RELEASE_PACKAGE_MAX_BYTES;
  Result := ReadAndHashOnce(AFileName, AMaxBytes, AData, ASha256, ACode,
    ADetail);
  if not Result then
  begin
    AData := '';
    ASha256 := '';
    if ACode = prcNone then
      ACode := prcPackageUnreadable;
  end;
end;

{ ---------------- THE runtime whole-package verifier --------------------- }

function PWebVerifyQuickJSPackage(const ADirectory: TFileName;
  const ARegistry: TPWebPackageRegistry;
  out AStore: IAssetStore;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  fileName: TFileName;
  data: RawByteString;
  sha: RawUtf8;
  store: TZipAssetStore;
  storeRef: IAssetStore;
  i: PtrInt;
  asset: TAssetResponse;
begin
  Result := False;
  AStore := nil;
  ACode := prcNone;
  ADetail := '';
  // 1. the registry must be self-consistent before it is trusted to
  //    name a file, let alone to judge one
  if not PWebValidateRegistry(ARegistry, ACode, ADetail) then
    exit;
  if not AbsoluteDirectory(ADirectory) then
  begin
    ACode := prcPackageMissing;
    ADetail := 'the package directory must be absolute';
    exit;
  end;
  fileName := IncludeTrailingPathDelimiter(ADirectory) +
    TFileName(Utf8ToString(ARegistry.PackageFile));
  // 2. one handle, one pass, hashed while it is read
  if not PWebReadAndHashReleaseFile(fileName, ARegistry.PackageBytes,
       data, sha, ACode, ADetail) then
    exit;
  try
    // 3. exact length and exact digest, BEFORE the archive is parsed
    if Int64(Length(data)) <> ARegistry.PackageBytes then
    begin
      ACode := prcPackageSize;
      ADetail := IntStr(Length(data)) + ' <> ' +
        IntStr(ARegistry.PackageBytes);
      exit;
    end;
    if sha <> ARegistry.PackageSha256 then
    begin
      ACode := prcPackageDigest;
      ADetail := 'archive digest mismatch';
      exit;
    end;
    // 4. the SAME bytes become the store - no second read, no race
    store := nil;
    try
      store := TZipAssetStore.CreateFromBuffer(data);
    except
      on E: Exception do
      begin
        store := nil;
        ACode := prcArchiveInvalid;
        ADetail := RawUtf8(E.ClassName);
        exit;
      end;
    end;
    storeRef := store;
    // 5. the semantic inventory, entry by entry
    if store.EntryCount <> Length(ARegistry.Inventory) then
    begin
      ACode := prcInventoryCount;
      ADetail := IntStr(store.EntryCount) + ' <> ' +
        IntStr(Length(ARegistry.Inventory));
      exit;
    end;
    for i := 0 to High(ARegistry.Inventory) do
    begin
      if store.EntryName(i) <> ARegistry.Inventory[i].Name then
      begin
        ACode := prcInventoryMismatch;
        ADetail := 'entry ' + IntStr(i) + ' name';
        exit;
      end;
      if not store.TryRead(ARegistry.Inventory[i].Name, asset) then
      begin
        ACode := prcInventoryMismatch;
        ADetail := 'unreadable ' + ARegistry.Inventory[i].Name;
        exit;
      end;
      if Int64(Length(asset.Content)) <> ARegistry.Inventory[i].Bytes then
      begin
        ACode := prcInventoryMismatch;
        ADetail := 'length ' + ARegistry.Inventory[i].Name;
        exit;
      end;
      if PWebSha256Hex(asset.Content) <> ARegistry.Inventory[i].Sha256 then
      begin
        ACode := prcInventoryMismatch;
        ADetail := 'digest ' + ARegistry.Inventory[i].Name;
        exit;
      end;
    end;
    // 6. only now does a store escape
    AStore := storeRef;
    Result := True;
  finally
    data := '';
    if not Result then
    begin
      storeRef := nil;
      AStore := nil;
    end;
  end;
end;

end.
