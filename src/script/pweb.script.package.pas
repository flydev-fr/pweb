{
  pweb.script.package - CAP-9B1 plugin package layer: strict manifest,
  package-id grammar, deterministic module resolution, module-graph
  accounting and the private store-scoping adapter.

  DELIBERATELY ENGINE-FREE. This unit knows nothing about QuickJS,
  JSContext, JSValue, threads, Win32, POSIX or ZIP: it is pure text and
  bookkeeping over the frozen IAssetStore contract, so every rule below
  is testable headless without an engine and can never acquire a
  platform-specific behaviour difference. The QuickJS-facing loader
  lives in pweb.script.quickjs and calls into here.

  WHAT IS AUTHORITATIVE (security-model.md): nothing here. The package
  supplies code and DESCRIPTIVE metadata only. PrincipalId, PluginId,
  PrincipalKind (always pkQuickJS) and capabilities come from the native
  descriptor built by trusted host code. plugin.json cannot grant
  anything - the eight security-authority key names are rejected loudly
  rather than ignored, so a developer can never come to believe package
  metadata carries authority.

  RESOLUTION - the whole security story (measured against the pin):
  with a normalize callback installed, QuickJS performs NO path joining
  and hands the specifier through verbatim, so this one function decides
  the single canonical logical path an IAssetStore will ever see:

    reject unless the specifier starts './' or '../'  (bare, absolute,
        protocol-relative and scheme forms all die here)
    reject NUL/controls, '\', ':', '?', '#', '%', '<', '>', '"', '|', '*'
    join dir(importer) + specifier         (dir('main.js') = '')
    fold segments: '.' skip | '' reject | '..' pop-or-REJECT | else push
    rebuild with '/'; require an explicit '.js' or '.mjs'
    bound the result; require PWebAssetPathValid (the CAP-4 fail-closed
        gate: exact case, no device names, strict UTF-8, no traversal)

  '..' therefore NEVER reaches IAssetStore.TryRead, and case is treated
  as a lookup property (the store decides existence byte-exactly), not
  as a syntax property.

  Canonical sources:
    - core-interfaces.md : IAssetStore.TryRead (frozen) + canonical
                           asset-path rules, reused verbatim here.
    - security-model.md  : native trust anchor; package metadata grants
                           nothing.
}
unit pweb.script.package;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  mormot.core.base,
  pweb.assets.intf,
  pweb.assets.support;

type
  /// host configuration error (a bad scoping prefix, a nil store) -
  // surfaced at startup, never as a silent runtime miss
  EPWebPackage = class(Exception);

  { Why a package failed to load. These are NATIVE plugin-start
    failures: they are deliberately NOT the nine-code RPC taxonomy
    (wire-semantics.md), because nothing here is an invocation. }
  TPWebPackageLoadCode = (
    plcNone,
    plcDescriptor,              // the native descriptor itself is invalid
    plcManifestMissing,         // plugin.json absent from the package store
    plcManifestTooLarge,
    plcManifestEncoding,        // NUL, bad UTF-8 or a control byte
    plcManifestSyntax,
    plcManifestDuplicateKey,
    plcManifestUnknownField,
    plcManifestForbiddenField,  // a security-authority key name
    plcManifestSchema,
    plcManifestId,
    plcManifestVersion,
    plcManifestEntry,
    plcEntryMismatch,           // manifest disagrees with native expectation
    plcEntryMissing,            // the entry module is not in the store
    plcSpecifier,               // an import specifier was refused
    plcDepth,
    plcModuleMissing,
    plcModuleTooLarge,
    plcModuleEncoding,
    plcModuleCount,
    plcTotalSource,
    plcCompile,                 // QuickJS syntax/compile failure
    plcEvaluate,                // the graph threw while evaluating
    plcTimeout,                 // the CPU bound interrupted the load
    plcPendingJobs,             // top-level code queued work nothing drains
    plcEngine,                  // engine creation / bootstrap failure
    plcThread);                 // a callback ran off the owning thread

  { Per-package deterministic bounds, enforced BEFORE anything is
    compiled: charging a whole graph into the engine and hoping the
    runtime memory cap catches it is not a bound, it is a race. Zero
    means "use the default" - never "unlimited".

    HONEST SCOPE (the one thing these bounds do NOT do): IAssetStore.
    TryRead is frozen and returns a fully materialised TAssetResponse
    with no size, HEAD or streaming form, so a carrier has already
    allocated the asset by the time its length is observable here - for
    TZipAssetStore that means a highly compressible entry is inflated
    first. These bounds are therefore checked at the EARLIEST point this
    layer can observe (the raw asset length, before any copy, parse or
    compile), and what materialises before that is the carrier's
    contract, not this layer's. CAP-4's ratified v1 asset policy already
    holds that bulk media is not an ordinary bundle asset. }
  TPWebPackageLimits = record
    ManifestMaxBytes: PtrUInt;
    ModuleMaxBytes: PtrUInt;
    TotalSourceMaxBytes: PtrUInt;
    MaxModules: Integer;
    MaxSpecifierBytes: Integer;
    MaxGraphDepth: Integer;
  end;

const
  /// how many resolution edges one module may contribute, on average,
  // before the graph ledger itself is treated as the attack
  // - the edge list exists to make the import graph observable; without
  // its own bound an import-dense package inside TotalSourceMaxBytes
  // could grow it far past anything the module bounds account for
  PWEB_PACKAGE_EDGES_PER_MODULE = 8;

  /// bound on the manifest "version" string, in bytes
  PWEB_PACKAGE_VERSION_MAX_BYTES = 32;

type

  { The manifest projection. Descriptive only - see the unit header. }
  TPWebPackageManifest = record
    Schema: Integer;
    Id: RawUtf8;
    Version: RawUtf8;
    Entry: RawUtf8;
  end;

const
  /// the one manifest path, at the package root - never configurable
  PWEB_PACKAGE_MANIFEST: RawUtf8 = 'plugin.json';
  /// the only accepted manifest schema
  PWEB_PACKAGE_SCHEMA = 1;
  /// bound on a package id, in bytes (ASCII, exact case)
  PWEB_PACKAGE_ID_MAX_BYTES = 64;
  /// bound on the entry / any module logical path, in bytes
  PWEB_PACKAGE_ENTRY_MAX_BYTES = 256;

  PWEB_PACKAGE_LOAD_TEXT: array[TPWebPackageLoadCode] of RawUtf8 = (
    'ok',
    'descriptor',
    'manifest_missing',
    'manifest_too_large',
    'manifest_encoding',
    'manifest_syntax',
    'manifest_duplicate_key',
    'manifest_unknown_field',
    'manifest_forbidden_field',
    'manifest_schema',
    'manifest_id',
    'manifest_version',
    'manifest_entry',
    'entry_mismatch',
    'entry_missing',
    'specifier',
    'depth',
    'module_missing',
    'module_too_large',
    'module_encoding',
    'module_count',
    'total_source',
    'compile',
    'evaluate',
    'timeout',
    'pending_jobs',
    'engine',
    'thread');

  { Ratified defaults (CAP-9B1 spec). Hosts may lower them; the HARD
    maxima below can never be exceeded, so a mis-set descriptor cannot
    turn a bound off. }
  PWEB_PACKAGE_DEFAULT_LIMITS: TPWebPackageLimits = (
    ManifestMaxBytes: 64 shl 10;        // 64 KiB
    ModuleMaxBytes: 1 shl 20;           // 1 MiB
    TotalSourceMaxBytes: 8 shl 20;      // 8 MiB
    MaxModules: 256;
    MaxSpecifierBytes: 512;
    MaxGraphDepth: 64);

  PWEB_PACKAGE_HARD_LIMITS: TPWebPackageLimits = (
    ManifestMaxBytes: 1 shl 20;         // 1 MiB
    ModuleMaxBytes: 16 shl 20;          // 16 MiB
    TotalSourceMaxBytes: 64 shl 20;     // 64 MiB
    MaxModules: 4096;
    MaxSpecifierBytes: 1024;
    MaxGraphDepth: 256);

  { The manifest key names that must never be believed to carry
    authority. Matched ASCII-case-insensitively so 'Capabilities' is
    refused with the SAME loud code as 'capabilities' - an unknown-field
    rejection would be technically correct and pedagogically useless. }
  PWEB_PACKAGE_FORBIDDEN_KEYS: array[0..7] of RawUtf8 = (
    'allow',
    'capabilities',
    'permissions',
    'principal',
    'principalid',
    'pluginid',
    'runtimegrants',
    'trustedcontent');

type
  { Module-graph bookkeeping for ONE package load: distinct module
    names, their depth from the entry, the resolution edges and the
    charged source bytes. Deterministic by construction - insertion
    order is resolution order, which is a pure function of the graph.

    Depth is tracked here because QuickJS gives the loader callback no
    depth information: normalize knows the importer, so
    depth(child) = depth(importer) + 1 on first sight. The module-count
    cap independently bounds the native js_resolve_module recursion,
    since a chain of N modules needs N distinct modules. }
  TPWebModuleGraph = class
  private
    fLimits: TPWebPackageLimits;
    fNames: TRawUtf8DynArray;
    fDepths: TIntegerDynArray;
    fLoaded: TByteDynArray;
    fCount: Integer;
    fLoadOrder: TIntegerDynArray;
    fLoadedCount: Integer;
    fEdges: TRawUtf8DynArray;
    fEdgeCount: Integer;
    fTotalBytes: PtrUInt;
    function Intern(const AName: RawUtf8; ADepth: Integer;
      out ACode: TPWebPackageLoadCode): PtrInt;
  public
    constructor Create(const ALimits: TPWebPackageLimits);
    /// register the entry module at depth 0 - call once, first
    function AddEntry(const AName: RawUtf8;
      out ACode: TPWebPackageLoadCode): Boolean;
    /// record one resolved import edge, assigning the child's depth
    function AddEdge(const ABase, AChild: RawUtf8;
      out ACode: TPWebPackageLoadCode): Boolean;
    /// charge one module's source bytes when the loader reads it
    function Charge(const AName: RawUtf8; ABytes: PtrUInt;
      out ACode: TPWebPackageLoadCode): Boolean;
    function IndexOf(const AName: RawUtf8): PtrInt;
    function DepthOf(const AName: RawUtf8): Integer; // -1 when unknown
    /// module names in LOADER-CALL order (the canonical corpus order)
    function LoadedName(AIndex: Integer): RawUtf8;
    /// resolution edges as 'importer>imported'
    function Edge(AIndex: Integer): RawUtf8;
    property Count: Integer read fCount;
    property LoadedCount: Integer read fLoadedCount;
    property EdgeCount: Integer read fEdgeCount;
    property TotalBytes: PtrUInt read fTotalBytes;
  end;

  { Confines one package to a sub-tree of a shared backing store: the
    plugin sees the prefixed sub-tree as its own root and can never name
    a sibling package's module namespace.

      plugin quickjs.calculator -> prefix 'plugins/quickjs.calculator/'
                                -> visible package root ''

    The prefix is native-controlled and never appears in anything the
    script can observe (TryRead returns a Boolean; the loader's thrown
    text is a fixed literal). No enumeration is added to IAssetStore -
    module loading stays demand-driven. }
  TPWebScopedAssetStore = class(TInterfacedObject, IAssetStore)
  private
    fInner: IAssetStore;
    fPrefix: RawUtf8; // canonical, always ends with '/'
  public
    // APrefix may be given with or without its trailing '/'; the part
    // without it must be a canonical logical path, so a hostile or
    // careless prefix is a construction-time refusal
    constructor Create(const AInner: IAssetStore; const APrefix: RawUtf8);
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
  end;

/// clamp a host-supplied limits record: zero fields take the default,
// every field is capped at PWEB_PACKAGE_HARD_LIMITS
function PWebClampPackageLimits(
  const ALimits: TPWebPackageLimits): TPWebPackageLimits;

/// package-id grammar: [a-z0-9]+(\.[a-z0-9]+)* , ASCII, 1..64 bytes
// - exact case, NO normalization and NO Unicode: a package id is
// descriptive/consistency metadata that must match the native
// ExpectedPackageId byte-for-byte, so confusables must not be foldable
// into a match. Deliberately NOT the capability grammar's validator,
// even though the shapes coincide today - they answer to different
// specs and must be free to diverge
function PWebPackageIdValid(const AId: RawUtf8): Boolean;

/// strict numeric SemVer X.Y.Z, diagnostics only
// - three dot-separated runs of 1..9 digits, no leading zeros (except a
// bare '0'), no pre-release or build metadata
function PWebPackageVersionValid(const AVersion: RawUtf8): Boolean;

/// a canonical package-relative module path: PWebAssetPathValid plus an
// explicit '.js' or '.mjs' extension and a length bound
// - no implicit index.js, no extension probing, no directory form
function PWebPackageEntryValid(const AEntry: RawUtf8): Boolean;

/// strict plugin.json scanner - see the unit header for why this is not
// a general JSON parser
// - accepts exactly {"schema":1,"id":..,"version":..,"entry":..} in any
// key order, each key exactly once; whitespace limited to space, TAB,
// CR and LF; NO escape sequence is accepted inside any string (all
// three string values are constrained grammars that never need one)
// - ADetail is a short ASCII host-side diagnostic ('' when none); it is
// never handed to script
function PWebParsePluginManifest(const ABytes: RawByteString;
  const ALimits: TPWebPackageLimits; out AManifest: TPWebPackageManifest;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8): Boolean;

/// resolve one import specifier against the importing module's
// canonical name - the algorithm in the unit header
function PWebResolveModuleSpecifier(const ABase, ASpecifier: RawUtf8;
  AMaxBytes: Integer; out ACanonical: RawUtf8): Boolean;

/// prepare raw store bytes for compilation
// - strips ONE optional UTF-8 BOM, refuses embedded NUL and any byte
// sequence PWebStrictUtf8 refuses, and otherwise preserves the bytes
// verbatim: line endings are NOT translated and no platform code-page
// conversion ever runs. An empty module is legal
// - INHERITED STRICTNESS, stated because it is surprising: sharing the
// one PWebStrictUtf8 validator with asset paths means module source
// also inherits its C1-control rule, so a raw U+0080..U+009F byte
// sequence (even inside a comment or string literal) is refused, while
// C0 controls other than NUL pass through. That asymmetry exists
// because the validator was written for portable PATH segments. It is
// deterministic and fail-closed, and a source-specific validator that
// permits C1 is a ratification question, not a silent second copy
function PWebPrepareModuleSource(const ARaw: RawByteString;
  out ASource: RawUtf8; out ACode: TPWebPackageLoadCode): Boolean;

implementation

function StripBom(const ARaw: RawByteString): RawByteString;
begin
  // exactly once: a doubled BOM leaves a stray U+FEFF, which the JS
  // parser then reports as an illegal character - a loud, correct
  // failure rather than a silent second strip.
  // The three bytes are compared as CHARACTER LITERALS, never through a
  // string constant: a high-byte string literal in Pascal source is
  // subject to the unit's source/ANSI code page, and mORMot switches
  // the RTL to UTF-8 at runtime - so a '#$EF#$BB#$BF' constant can be
  // silently re-encoded to six bytes before it ever reaches a compare
  if (Length(ARaw) >= 3) and
     (ARaw[1] = #$EF) and
     (ARaw[2] = #$BB) and
     (ARaw[3] = #$BF) then
    Result := Copy(ARaw, 4, Length(ARaw) - 3)
  else
    Result := ARaw;
end;

function PWebClampPackageLimits(
  const ALimits: TPWebPackageLimits): TPWebPackageLimits;

  function Cap(AValue, ADefault, AHard: PtrUInt): PtrUInt;
  begin
    if AValue = 0 then
      Result := ADefault
    else if AValue > AHard then
      Result := AHard
    else
      Result := AValue;
  end;

  function CapI(AValue, ADefault, AHard: Integer): Integer;
  begin
    if AValue <= 0 then
      Result := ADefault
    else if AValue > AHard then
      Result := AHard
    else
      Result := AValue;
  end;

begin
  Result.ManifestMaxBytes := Cap(ALimits.ManifestMaxBytes,
    PWEB_PACKAGE_DEFAULT_LIMITS.ManifestMaxBytes,
    PWEB_PACKAGE_HARD_LIMITS.ManifestMaxBytes);
  Result.ModuleMaxBytes := Cap(ALimits.ModuleMaxBytes,
    PWEB_PACKAGE_DEFAULT_LIMITS.ModuleMaxBytes,
    PWEB_PACKAGE_HARD_LIMITS.ModuleMaxBytes);
  Result.TotalSourceMaxBytes := Cap(ALimits.TotalSourceMaxBytes,
    PWEB_PACKAGE_DEFAULT_LIMITS.TotalSourceMaxBytes,
    PWEB_PACKAGE_HARD_LIMITS.TotalSourceMaxBytes);
  Result.MaxModules := CapI(ALimits.MaxModules,
    PWEB_PACKAGE_DEFAULT_LIMITS.MaxModules,
    PWEB_PACKAGE_HARD_LIMITS.MaxModules);
  Result.MaxSpecifierBytes := CapI(ALimits.MaxSpecifierBytes,
    PWEB_PACKAGE_DEFAULT_LIMITS.MaxSpecifierBytes,
    PWEB_PACKAGE_HARD_LIMITS.MaxSpecifierBytes);
  Result.MaxGraphDepth := CapI(ALimits.MaxGraphDepth,
    PWEB_PACKAGE_DEFAULT_LIMITS.MaxGraphDepth,
    PWEB_PACKAGE_HARD_LIMITS.MaxGraphDepth);
  // a per-module cap above the total is incoherent; the total wins
  if Result.ModuleMaxBytes > Result.TotalSourceMaxBytes then
    Result.ModuleMaxBytes := Result.TotalSourceMaxBytes;
end;

{ ---------------- grammars ---------------- }

function PWebPackageIdValid(const AId: RawUtf8): Boolean;
var
  i, len: PtrInt;
  c: AnsiChar;
  segLen: PtrInt;
begin
  Result := False;
  len := Length(AId);
  if (len = 0) or
     (len > PWEB_PACKAGE_ID_MAX_BYTES) then
    exit;
  segLen := 0;
  for i := 1 to len do
  begin
    c := AId[i];
    if c = '.' then
    begin
      if segLen = 0 then
        exit; // leading dot or '..' - no empty segment
      segLen := 0;
      continue;
    end;
    // ASCII lower-case and digits only: no upper case, no '-', no '_',
    // no Unicode, so nothing is confusable with anything else
    if not (((c >= 'a') and (c <= 'z')) or
            ((c >= '0') and (c <= '9'))) then
      exit;
    Inc(segLen);
  end;
  Result := segLen <> 0; // no trailing dot
end;

function PWebPackageVersionValid(const AVersion: RawUtf8): Boolean;
var
  i, len, digits, parts: PtrInt;
  c: AnsiChar;
  leadingZero: Boolean;
begin
  Result := False;
  len := Length(AVersion);
  if (len = 0) or
     (len > PWEB_PACKAGE_VERSION_MAX_BYTES) then
    exit;
  parts := 1;
  digits := 0;
  leadingZero := False;
  for i := 1 to len do
  begin
    c := AVersion[i];
    if c = '.' then
    begin
      if (digits = 0) or (leadingZero and (digits > 1)) then
        exit;
      Inc(parts);
      if parts > 3 then
        exit;
      digits := 0;
      leadingZero := False;
      continue;
    end;
    if (c < '0') or (c > '9') then
      exit; // no pre-release, no build metadata, no 'v' prefix
    if digits = 0 then
      leadingZero := c = '0';
    Inc(digits);
    if digits > 9 then
      exit;
  end;
  Result := (parts = 3) and (digits > 0) and
            not (leadingZero and (digits > 1));
end;

function HasModuleExtension(const APath: RawUtf8): Boolean;
var
  len, dot: PtrInt;
begin
  Result := False;
  len := Length(APath);
  if (len > 3) and (Copy(APath, len - 2, 3) = '.js') then
    dot := len - 2
  else if (len > 4) and (Copy(APath, len - 3, 4) = '.mjs') then
    dot := len - 3
  else
    exit;
  // require a real basename before the extension: '.js' and 'lib/.js'
  // are dotfiles, not modules, and a package that ships one is far more
  // likely to be probing the resolver than to mean it
  Result := (dot > 1) and (APath[dot - 1] <> '/');
end;

function PWebPackageEntryValid(const AEntry: RawUtf8): Boolean;
begin
  Result := (Length(AEntry) <= PWEB_PACKAGE_ENTRY_MAX_BYTES) and
            PWebAssetPathValid(AEntry) and
            HasModuleExtension(AEntry);
end;

{ ---------------- module specifier resolution ---------------- }

function PWebResolveModuleSpecifier(const ABase, ASpecifier: RawUtf8;
  AMaxBytes: Integer; out ACanonical: RawUtf8): Boolean;
var
  i, n, dirEnd, segStart, depth: PtrInt;
  joined, seg: RawUtf8;
  stack: TRawUtf8DynArray;
  c: AnsiChar;
begin
  ACanonical := '';
  Result := False;
  if AMaxBytes <= 0 then
    AMaxBytes := PWEB_PACKAGE_DEFAULT_LIMITS.MaxSpecifierBytes;
  n := Length(ASpecifier);
  if (n = 0) or
     (n > AMaxBytes) then
    exit;
  // RELATIVE ONLY. Everything else - bare 'lodash', absolute '/x.js',
  // 'https://...', 'file:...', protocol-relative '//host/x.js' - fails
  // right here, before any store is consulted. Measured: QuickJS hands
  // all of those through verbatim, so this is the only gate needed.
  if not (((n >= 2) and (ASpecifier[1] = '.') and (ASpecifier[2] = '/')) or
          ((n >= 3) and (ASpecifier[1] = '.') and (ASpecifier[2] = '.') and
           (ASpecifier[3] = '/'))) then
    exit;
  for i := 1 to n do
  begin
    c := ASpecifier[i];
    // NUL and every other control byte including DEL; backslash; the
    // scheme/ADS colon; query and fragment (a module specifier is a
    // package path, not a browser URL); '%' per the single-decode
    // policy - nothing here is ever URI-decoded
    if (c < #$20) or
       (c = #$7F) or
       (c in ['\', ':', '?', '#', '%', '<', '>', '"', '|', '*']) then
      exit;
  end;
  // the importing module's directory; '' at the package root
  dirEnd := 0;
  for i := Length(ABase) downto 1 do
    if ABase[i] = '/' then
    begin
      dirEnd := i;
      break;
    end;
  joined := Copy(ABase, 1, dirEnd) + ASpecifier;
  // fold '.' and '..' HERE: the store is never handed a traversal form
  SetLength(stack, 0);
  depth := 0;
  segStart := 1;
  for i := 1 to Length(joined) + 1 do
    if (i > Length(joined)) or
       (joined[i] = '/') then
    begin
      seg := Copy(joined, segStart, i - segStart);
      segStart := i + 1;
      if seg = '.' then
        continue;
      if seg = '' then
        exit; // '//' , a leading '/' or a trailing '/' (directory import)
      if seg = '..' then
      begin
        if depth = 0 then
          exit; // escape above the package root - fail closed
        Dec(depth);
        SetLength(stack, depth);
        continue;
      end;
      Inc(depth);
      SetLength(stack, depth);
      stack[depth - 1] := seg;
    end;
  if depth = 0 then
    exit;
  ACanonical := stack[0];
  for i := 1 to depth - 1 do
    ACanonical := ACanonical + '/' + stack[i];
  if (Length(ACanonical) > AMaxBytes) or
     (not PWebPackageEntryValid(ACanonical)) then
  begin
    ACanonical := '';
    exit;
  end;
  Result := True;
end;

{ ---------------- module source ---------------- }

function PWebPrepareModuleSource(const ARaw: RawByteString;
  out ASource: RawUtf8; out ACode: TPWebPackageLoadCode): Boolean;
var
  stripped: RawByteString;
  i: PtrInt;
begin
  ASource := '';
  ACode := plcNone;
  stripped := StripBom(ARaw);
  for i := 1 to Length(stripped) do
    if stripped[i] = #0 then
    begin
      // an embedded NUL would truncate the zero-terminated buffer the
      // pinned JS_Eval reads, so the bytes compiled would not be the
      // bytes hashed - refuse rather than silently compile a prefix
      ACode := plcModuleEncoding;
      exit(False);
    end;
  if not PWebStrictUtf8(RawUtf8(stripped)) then
  begin
    ACode := plcModuleEncoding;
    exit(False);
  end;
  // verbatim from here: CRLF stays CRLF, LF stays LF, an empty module
  // stays empty (and is legal)
  ASource := RawUtf8(stripped);
  Result := True;
end;

{ ---------------- the strict manifest scanner ---------------- }

function AsciiLowerStr(const s: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := s;
  for i := 1 to Length(Result) do
    if (Result[i] >= 'A') and (Result[i] <= 'Z') then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function IsForbiddenKey(const AKey: RawUtf8): Boolean;
var
  i: PtrInt;
  low: RawUtf8;
begin
  low := AsciiLowerStr(AKey);
  for i := 0 to High(PWEB_PACKAGE_FORBIDDEN_KEYS) do
    if low = PWEB_PACKAGE_FORBIDDEN_KEYS[i] then
      exit(True);
  Result := False;
end;

function PWebParsePluginManifest(const ABytes: RawByteString;
  const ALimits: TPWebPackageLimits; out AManifest: TPWebPackageManifest;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8): Boolean;
var
  text: RawUtf8;
  p, len, scan: PtrInt; // p is captured by the nested scanners below, so
                        // it can never be a for-loop counter (FPC refuses)
  seenSchema, seenId, seenVersion, seenEntry: Boolean;
  key: RawUtf8;
  lim: TPWebPackageLimits;

  procedure Fail(ACodeIn: TPWebPackageLoadCode; const ADetailIn: RawUtf8);
  begin
    ACode := ACodeIn;
    ADetail := ADetailIn;
  end;

  procedure SkipWs;
  begin
    // exactly four whitespace bytes, per JSON; a vertical tab or form
    // feed between tokens is a syntax error, not "probably fine"
    while (p <= len) and
          (text[p] in [' ', #9, #13, #10]) do
      Inc(p);
  end;

  function ReadString(out AValue: RawUtf8): Boolean;
  var
    start: PtrInt;
    c: AnsiChar;
  begin
    AValue := '';
    Result := False;
    if (p > len) or (text[p] <> '"') then
    begin
      Fail(plcManifestSyntax, 'string expected');
      exit;
    end;
    Inc(p);
    start := p;
    while p <= len do
    begin
      c := text[p];
      if c = '"' then
      begin
        AValue := Copy(text, start, p - start);
        Inc(p);
        exit(True);
      end;
      if c = '\' then
      begin
        // NO escapes: every value here is a constrained grammar
        // (package id, numeric SemVer, canonical path) that can never
        // need one, and refusing them removes a whole class of parser
        // bug rather than implementing it correctly
        Fail(plcManifestSyntax, 'escape sequence');
        exit;
      end;
      if (c < #$20) or (c = #$7F) then
      begin
        Fail(plcManifestEncoding, 'control byte in string');
        exit;
      end;
      Inc(p);
    end;
    Fail(plcManifestSyntax, 'unterminated string');
  end;

  function ReadSchema(out AValue: Integer): Boolean;
  var
    digits: Integer;
    v: Int64;
    leadingZero: Boolean;
  begin
    AValue := 0;
    Result := False;
    digits := 0;
    v := 0;
    leadingZero := (p <= len) and (text[p] = '0');
    while (p <= len) and (text[p] >= '0') and (text[p] <= '9') do
    begin
      // an integer literal only: '1.0', '"1"', '+1', '1e0' are all
      // schema violations, never "close enough to 1"
      v := v * 10 + (Ord(text[p]) - Ord('0'));
      Inc(digits);
      Inc(p);
      if digits > 9 then
      begin
        Fail(plcManifestSchema, 'schema out of range');
        exit;
      end;
    end;
    if digits = 0 then
    begin
      Fail(plcManifestSyntax, 'integer expected');
      exit;
    end;
    if leadingZero and (digits > 1) then
    begin
      // '01' is not JSON, and a scanner that refuses 1.0 and "1" while
      // quietly taking 01 is not the strict scanner it claims to be
      Fail(plcManifestSyntax, 'leading zero');
      exit;
    end;
    AValue := Integer(v);
    Result := True;
  end;

begin
  AManifest := Default(TPWebPackageManifest);
  ACode := plcNone;
  ADetail := '';
  Result := False;
  // clamp HERE too: this is a public entry point, and a caller passing a
  // zero-valued record means "use the defaults" everywhere else in this
  // unit - it must not mean "refuse every manifest" only here
  lim := PWebClampPackageLimits(ALimits);
  if PtrUInt(Length(ABytes)) > lim.ManifestMaxBytes then
  begin
    Fail(plcManifestTooLarge, '');
    exit;
  end;
  text := RawUtf8(StripBom(ABytes));
  len := Length(text);
  if len = 0 then
  begin
    Fail(plcManifestSyntax, 'empty');
    exit;
  end;
  for scan := 1 to len do
    if text[scan] = #0 then
    begin
      Fail(plcManifestEncoding, 'NUL');
      exit;
    end;
  if not PWebStrictUtf8(text) then
  begin
    Fail(plcManifestEncoding, 'utf8');
    exit;
  end;
  seenSchema := False;
  seenId := False;
  seenVersion := False;
  seenEntry := False;
  p := 1;
  SkipWs;
  if (p > len) or (text[p] <> '{') then
  begin
    Fail(plcManifestSyntax, 'object expected');
    exit;
  end;
  Inc(p);
  SkipWs;
  if (p <= len) and (text[p] = '}') then
  begin
    Fail(plcManifestSyntax, 'empty object');
    exit;
  end;
  repeat
    SkipWs;
    if not ReadString(key) then
      exit;
    SkipWs;
    if (p > len) or (text[p] <> ':') then
    begin
      Fail(plcManifestSyntax, 'colon expected');
      exit;
    end;
    Inc(p);
    SkipWs;
    if key = 'schema' then
    begin
      if seenSchema then
      begin
        Fail(plcManifestDuplicateKey, key);
        exit;
      end;
      seenSchema := True;
      if not ReadSchema(AManifest.Schema) then
        exit;
    end
    else if key = 'id' then
    begin
      if seenId then
      begin
        Fail(plcManifestDuplicateKey, key);
        exit;
      end;
      seenId := True;
      if not ReadString(AManifest.Id) then
        exit;
    end
    else if key = 'version' then
    begin
      if seenVersion then
      begin
        Fail(plcManifestDuplicateKey, key);
        exit;
      end;
      seenVersion := True;
      if not ReadString(AManifest.Version) then
        exit;
    end
    else if key = 'entry' then
    begin
      if seenEntry then
      begin
        Fail(plcManifestDuplicateKey, key);
        exit;
      end;
      seenEntry := True;
      if not ReadString(AManifest.Entry) then
        exit;
    end
    else if IsForbiddenKey(key) then
    begin
      // LOUD, before any engine exists: the point is that a developer
      // who writes "capabilities": [...] here is told the manifest
      // grants nothing, instead of shipping a package that silently
      // ignores it and looks like it worked
      Fail(plcManifestForbiddenField, key);
      exit;
    end
    else
    begin
      Fail(plcManifestUnknownField, key);
      exit;
    end;
    SkipWs;
    if (p <= len) and (text[p] = ',') then
    begin
      Inc(p);
      continue;
    end;
    break;
  until False;
  SkipWs;
  if (p > len) or (text[p] <> '}') then
  begin
    Fail(plcManifestSyntax, 'closing brace expected');
    exit;
  end;
  Inc(p);
  SkipWs;
  if p <= len then
  begin
    Fail(plcManifestSyntax, 'trailing content');
    exit;
  end;
  if not (seenSchema and seenId and seenVersion and seenEntry) then
  begin
    Fail(plcManifestSyntax, 'missing key');
    exit;
  end;
  if AManifest.Schema <> PWEB_PACKAGE_SCHEMA then
  begin
    Fail(plcManifestSchema, '');
    exit;
  end;
  if not PWebPackageIdValid(AManifest.Id) then
  begin
    Fail(plcManifestId, '');
    exit;
  end;
  if not PWebPackageVersionValid(AManifest.Version) then
  begin
    Fail(plcManifestVersion, '');
    exit;
  end;
  if not PWebPackageEntryValid(AManifest.Entry) then
  begin
    Fail(plcManifestEntry, '');
    exit;
  end;
  Result := True;
end;

{ ---------------- TPWebModuleGraph ---------------- }

constructor TPWebModuleGraph.Create(const ALimits: TPWebPackageLimits);
begin
  inherited Create;
  fLimits := PWebClampPackageLimits(ALimits);
end;

function TPWebModuleGraph.IndexOf(const AName: RawUtf8): PtrInt;
var
  i: PtrInt;
begin
  for i := 0 to fCount - 1 do
    if fNames[i] = AName then // byte-exact: case is never folded
      exit(i);
  Result := -1;
end;

function TPWebModuleGraph.DepthOf(const AName: RawUtf8): Integer;
var
  ndx: PtrInt;
begin
  ndx := IndexOf(AName);
  if ndx < 0 then
    Result := -1
  else
    Result := fDepths[ndx];
end;

function TPWebModuleGraph.Intern(const AName: RawUtf8; ADepth: Integer;
  out ACode: TPWebPackageLoadCode): PtrInt;
begin
  ACode := plcNone;
  Result := IndexOf(AName);
  if Result >= 0 then
  begin
    // a module reached again by a shorter path keeps the smaller depth
    // for REPORTING, but note what the bound below actually enforces:
    // MaxGraphDepth is applied on FIRST SIGHT of a module, and lowering
    // a depth here does not re-walk descendants already interned. The
    // decision is therefore traversal-order dependent - always in the
    // fail-closed direction (a diamond whose long arm is walked first
    // can be refused though its shortest path is inside the bound; a
    // graph deeper than the bound can never be accepted). Making it
    // order-independent means a propagation pass over fEdges, which
    // buys nothing a package author cannot get by importing sanely.
    if ADepth < fDepths[Result] then
      fDepths[Result] := ADepth;
    exit;
  end;
  if ADepth > fLimits.MaxGraphDepth then
  begin
    ACode := plcDepth;
    exit(-1);
  end;
  if fCount >= fLimits.MaxModules then
  begin
    ACode := plcModuleCount;
    exit(-1);
  end;
  if fCount >= Length(fNames) then
  begin
    SetLength(fNames, fCount + 16);
    SetLength(fDepths, fCount + 16);
    SetLength(fLoaded, fCount + 16);
  end;
  fNames[fCount] := AName;
  fDepths[fCount] := ADepth;
  fLoaded[fCount] := 0;
  Result := fCount;
  Inc(fCount);
end;

function TPWebModuleGraph.AddEntry(const AName: RawUtf8;
  out ACode: TPWebPackageLoadCode): Boolean;
begin
  Result := Intern(AName, 0, ACode) >= 0;
end;

function TPWebModuleGraph.AddEdge(const ABase, AChild: RawUtf8;
  out ACode: TPWebPackageLoadCode): Boolean;
var
  baseDepth: Integer;
begin
  ACode := plcNone;
  baseDepth := DepthOf(ABase);
  if baseDepth < 0 then
  begin
    // an importer QuickJS resolved from is always a module we interned
    // (the entry via AddEntry, everything else via a previous AddEdge).
    // Treating an unknown importer as the root would silently under-
    // count the depth of its whole subtree, so it is a hard failure
    // rather than a quiet default.
    ACode := plcEngine;
    exit(False);
  end;
  if Intern(AChild, baseDepth + 1, ACode) < 0 then
    exit(False);
  // the edge ledger needs its own bound: it is written from attacker-
  // supplied import statements and is not covered by any module bound
  if fEdgeCount >= fLimits.MaxModules * PWEB_PACKAGE_EDGES_PER_MODULE then
  begin
    ACode := plcModuleCount;
    exit(False);
  end;
  if fEdgeCount >= Length(fEdges) then
    SetLength(fEdges, fEdgeCount * 2 + 16); // geometric, never quadratic
  fEdges[fEdgeCount] := ABase + '>' + AChild;
  Inc(fEdgeCount);
  Result := True;
end;

function TPWebModuleGraph.Charge(const AName: RawUtf8; ABytes: PtrUInt;
  out ACode: TPWebPackageLoadCode): Boolean;
var
  ndx: PtrInt;
begin
  ACode := plcNone;
  if ABytes > fLimits.ModuleMaxBytes then
  begin
    ACode := plcModuleTooLarge;
    exit(False);
  end;
  if fTotalBytes + ABytes > fLimits.TotalSourceMaxBytes then
  begin
    // charged BEFORE compilation, so an oversized graph is refused
    // while it is still bytes - never after the engine has already
    // allocated it and only the QuickJS heap cap stands in the way
    ACode := plcTotalSource;
    exit(False);
  end;
  // NEVER intern at depth 0 here: AddEntry/AddEdge already assigned this
  // module's depth, and Intern keeps the SMALLEST depth it is told - so
  // charging at 0 would flatten the whole graph to depth 1 and silently
  // disable the depth bound (measured: a 6-deep chain loaded under
  // MaxGraphDepth = 3). An uninterned module reaching Charge would mean
  // the loader read source for something resolution never produced, so
  // it is a hard failure, not a re-intern.
  ndx := IndexOf(AName);
  if ndx < 0 then
  begin
    ACode := plcEngine;
    exit(False);
  end;
  Inc(fTotalBytes, ABytes);
  if fLoaded[ndx] = 0 then
  begin
    fLoaded[ndx] := 1;
    if fLoadedCount >= Length(fLoadOrder) then
      SetLength(fLoadOrder, fLoadedCount + 16);
    fLoadOrder[fLoadedCount] := ndx;
    Inc(fLoadedCount);
  end;
  Result := True;
end;

function TPWebModuleGraph.LoadedName(AIndex: Integer): RawUtf8;
begin
  if (AIndex < 0) or (AIndex >= fLoadedCount) then
    Result := ''
  else
    Result := fNames[fLoadOrder[AIndex]];
end;

function TPWebModuleGraph.Edge(AIndex: Integer): RawUtf8;
begin
  if (AIndex < 0) or (AIndex >= fEdgeCount) then
    Result := ''
  else
    Result := fEdges[AIndex];
end;

{ ---------------- TPWebScopedAssetStore ---------------- }

constructor TPWebScopedAssetStore.Create(const AInner: IAssetStore;
  const APrefix: RawUtf8);
var
  bare: RawUtf8;
begin
  inherited Create;
  if AInner = nil then
    raise EPWebPackage.Create('TPWebScopedAssetStore requires a store');
  bare := APrefix;
  while (bare <> '') and (bare[Length(bare)] = '/') do
    SetLength(bare, Length(bare) - 1);
  if not PWebAssetPathValid(bare) then
    raise EPWebPackage.CreateFmt(
      'TPWebScopedAssetStore: non-canonical prefix (%d bytes)',
      [Length(APrefix)]); // the prefix itself is never echoed
  // a prefix long enough to crowd out a full-length module path would
  // turn legal modules into plcModuleMissing at LOOKUP time - a host
  // configuration error surfacing as a runtime miss. Refuse it now, at
  // startup, where a configuration error belongs.
  if Length(bare) + 1 + PWEB_PACKAGE_ENTRY_MAX_BYTES >
       PWEB_ASSET_PATH_MAX_BYTES then
    raise EPWebPackage.CreateFmt(
      'TPWebScopedAssetStore: prefix leaves no room for a module path ' +
      '(%d bytes)', [Length(APrefix)]);
  fInner := AInner;
  fPrefix := bare + '/';
end;

function TPWebScopedAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  full: RawUtf8;
begin
  Asset := Default(TAssetResponse);
  Result := False;
  // independent fail-closed validation, exactly like the folder and ZIP
  // stores: the caller having validated is never a reason not to
  if not PWebAssetPathValid(Path) then
    exit;
  full := fPrefix + Path;
  // re-validate the concatenation, which can only fail on the total
  // length bound - but a bound checked once is a bound
  if not PWebAssetPathValid(full) then
    exit;
  Result := fInner.TryRead(full, Asset);
end;

end.
