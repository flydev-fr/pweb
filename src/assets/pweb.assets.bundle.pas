{
  pweb.assets.bundle - CAP-6 release bundle (app.pwb) writer + loader.

  One production container: app.pwb is a plain ZIP read through the
  existing TZipRead-based TZipAssetStore - this unit only WRAPS the
  CAP-4 asset architecture (validator, MIME, exact-case semantics), it
  never adds a second one.

  Manifest - the ratified compatibility block, canonical bytes
  (see PWEB_BUNDLE_MANIFEST canonical form on the Serialize routine:
  a single pweb object holding protocol:N and minRuntime:"X.Y.Z", no
  whitespace, fixed key order - serialization can never cause hash
  drift). The loader reads ONLY the pweb block; every other field is
  an inert unknown - capability-like fields (allow, capabilities,
  permissions) grant nothing, ever: AppMaximum stays native-side.
  minRuntime grammar is strict numeric X.Y.Z (ratified D6): no
  prerelease/build suffix, no leading zeros - anything else is
  malformed and refuses the bundle.

  Load predicate (checked BEFORE any bundle JS can execute - the host
  calls this loader before it ever creates a webview):

      protocol IN SupportedProtocols
      AND SemVer(RuntimeVersion) >= SemVer(minRuntime)

  Set membership for the protocol, numeric SemVer ordering for the
  runtime - never lexicographic. Malformed or absent manifest/pweb
  block => refuse. A refusal is a typed reason category suitable for a
  native-controlled diagnostic; no parser internals, and never any
  HTML/JS from the rejected bundle.

  Writer - deterministic by construction: global bytewise sort of the
  canonical logical names (manifest.json included), fixed DOS
  timestamp, fixed deflate level, no extra fields (zip64 refused), so
  identical logical input yields byte-identical archives across time
  and machines. Every entry name passes PWebAssetPathValid plus the
  duplicate/Unicode-fold/file-dir collision rules BEFORE anything is
  written. Ratified D1: names stay valid Unicode; two names equal
  under the pinned mORMot Unicode 10.0 simple case fold
  (UpperCaseReference - compiled-in tables, never the OS) reject; the
  fold is an ambiguity-rejection rule only and never rewrites a name.
  D1 is enforced twice - here at bundle construction AND inside
  TZipAssetStore at archive construction - so a hand-crafted app.pwb
  cannot bypass the bundler policy. Output lands in a temp sibling,
  is re-opened through the PRODUCTION loader (including a raw
  stored-name byte compare that closes the TZipWrite non-ASCII
  codepage hazard), then atomically replaces the previous output; on
  any failure the previous output survives and the temp is removed.

  Layering: assets layer only - webview-free and rpc-free. The
  supported-protocol set and the runtime version are parameter-
  injected; only the CLI/host import the pweb.rpc.intf/support
  constants.
}
unit pweb.assets.bundle;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.zip,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.zip;

const
  /// the bundler-owned compatibility manifest entry (served like any
  // other asset per ratified D5 - it holds only public metadata)
  PWEB_BUNDLE_MANIFEST_NAME: RawUtf8 = 'manifest.json';
  /// ratified D2 default per-asset ceiling: 32 MiB; larger media
  // belongs on the blob data plane, never inside app.pwb
  PWEB_BUNDLE_MAX_ASSET_BYTES_DEFAULT = Int64(32) shl 20;
  /// fixed DOS timestamp (1980-01-01 00:00) for every entry, so
  // identical input bytes yield identical archive bytes (the
  // examples/06-assets/mkappzip.pas precedent, generalized)
  PWEB_BUNDLE_FIXED_FILE_AGE = $00210000;
  /// fixed deflate level - part of the deterministic-output contract
  PWEB_BUNDLE_DEFLATE_LEVEL = 6;

type
  /// raised on direct misuse of the bundle-writing API (the loaders
  // never raise - they return typed refusal categories instead)
  EPWebBundle = class(Exception);

  /// the parsed ratified pweb manifest block
  TPWebBundleManifest = record
    Protocol: Integer;    // wire protocol the bundle was built for
    MinRuntime: RawUtf8;  // strict X.Y.Z minimum runtime version (D6)
  end;

  /// typed bundle-refusal categories - the ONLY diagnostic surface a
  // refusal exposes (no parser internals, no archive details)
  TPWebBundleRefusal = (
    pbrNone,                 // accepted
    pbrBundleMissing,        // bundle file absent beside the host
    pbrArchiveInvalid,       // not a valid/canonical ZIP archive
    pbrManifestMissing,      // archive has no manifest.json entry
    pbrManifestMalformed,    // manifest/pweb block/semver malformed
    pbrProtocolUnsupported,  // protocol not in the injected set
    pbrRuntimeIncompatible,  // SemVer(runtime) < SemVer(minRuntime)
    pbrIndexMissing);        // archive has no index.html document

  /// ratified D3 build-input classification, by path/name ONLY (no
  // content is ever read to classify)
  TPWebBundleNameClass = (
    pbcAsset,             // ordinary bundle asset
    pbcSourceMap,         // *.map: excluded by default, explicit opt-in
    pbcSecret,            // secret/dev artifact: hard build error
    pbcReservedManifest); // root manifest.json: the bundler owns it

  /// one logical asset handed to the bundle writer
  TPWebBundleEntry = record
    Name: RawUtf8;           // canonical logical path (forward slashes)
    Content: RawByteString;  // exact asset bytes
  end;

/// fixed diagnostic text for a typed refusal category
function PWebBundleRefusalText(Reason: TPWebBundleRefusal): RawUtf8;

/// strict X.Y.Z SemVer parse (ratified D6 grammar)
// - numeric components only, no leading zeros, no prerelease/build
// suffix, no surrounding whitespace; components bounded to 9 digits
function PWebSemVerParse(const Version: RawUtf8;
  out Major, Minor, Patch: Cardinal): Boolean;

/// True iff Version satisfies the strict D6 X.Y.Z grammar
function PWebSemVerValid(const Version: RawUtf8): Boolean;

/// numeric SemVer comparison - NEVER lexicographic ('0.10.0'>'0.9.0')
// - returns False (fail closed) if either side is malformed; on True,
// Diff is <0 / 0 / >0 for A<B / A=B / A>B
function PWebSemVerCompare(const A, B: RawUtf8;
  out Diff: Integer): Boolean;

/// the canonical manifest bytes - exactly
// {"pweb":{"protocol":N,"minRuntime":"X.Y.Z"}} (ratified D6)
// - raises EPWebBundle when Protocol is negative or MinRuntime fails
// the strict D6 grammar, so direct API misuse can never emit
// malformed canonical JSON
function PWebBundleManifestSerialize(
  const Manifest: TPWebBundleManifest): RawUtf8;

/// strict manifest parse (fail closed)
// - the document must be one JSON object containing a "pweb" object
// member with an integer "protocol" >= 0 and a strict-semver string
// "minRuntime"; unknown additive members anywhere are skipped and
// inert (capability-like fields grant nothing); duplicated relevant
// keys, floats, negative protocol, structural errors and trailing
// bytes all return False
function PWebBundleManifestParse(const Json: RawByteString;
  out Manifest: TPWebBundleManifest): Boolean;

/// the ratified load predicate over parameter-injected runtime facts
// - protocol set membership, then numeric SemVer ordering; returns
// pbrNone when the bundle is compatible
function PWebBundleCompatCheck(const Manifest: TPWebBundleManifest;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8): TPWebBundleRefusal;

/// ratified D3 name classification for bundler inputs
// - checked per segment: '.env' exact or '.env.*', '.git*',
// node_modules, .DS_Store, Thumbs.db; checked on the file name:
// lockfiles and the pem/key/pfx/p12/crt/pas extensions (secret), the
// .map extension (sourcemap - excluded by default), and the root
// manifest.json (reserved)
// - ASCII-case-insensitive: dev filesystems are case-insensitive
function PWebBundleClassifyName(
  const LogicalPath: RawUtf8): TPWebBundleNameClass;

/// the temp sibling used by PWebBundleWrite before its atomic replace
// - carries the current process id so concurrent bundler invocations
// targeting the same output can never collide on the temp file
function PWebBundleTempFileName(const OutFile: TFileName): TFileName;

/// deterministic validating app.pwb writer
// - validates every entry (canonical name, D3 secrets, reserved
// manifest, D2 size ceiling, duplicates, ratified D1 Unicode-fold
// collisions, file/dir collisions, index.html presence) BEFORE
// touching the filesystem; MaxAssetBytes <= 0 selects the ratified
// 32 MiB default
// - writes a temp sibling (PWebBundleTempFileName) in global bytewise
// name order with fixed timestamp/level, re-opens it through the
// production loader plus a raw stored-name byte compare and a full
// content compare, then atomically replaces OutFile; on any failure
// the previous OutFile survives untouched, the temp is removed and
// False is returned with a build diagnostic in ErrorMsg
// - explicit *.map entries ARE accepted here by design: the ratified
// default sourcemap exclusion is walk-time policy owned by the CLI
// (which owns the --include-sourcemaps opt-in), while secrets and the
// reserved root manifest stay writer-level defense in depth
function PWebBundleWrite(const OutFile: TFileName;
  const Entries: array of TPWebBundleEntry;
  const Manifest: TPWebBundleManifest;
  MaxAssetBytes: Int64;
  out ErrorMsg: RawUtf8): Boolean;

/// production bundle loader over in-memory archive bytes
// - order is the compatibility proof: archive validation (the whole
// CAP-4 TZipAssetStore construction gate, D1 included) -> manifest ->
// injected compat predicate -> index.html presence -> IAssetStore
// - on refusal Store is nil (no store object escapes) and Reason
// carries the typed category; never raises
function PWebBundleLoadBuffer(const Data: RawByteString;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8;
  out Store: IAssetStore;
  out Reason: TPWebBundleRefusal): Boolean;

/// production bundle loader over an app.pwb file
// - same pipeline as PWebBundleLoadBuffer, with a typed
// pbrBundleMissing refusal when the file does not exist
function PWebBundleLoadFile(const BundleFile: TFileName;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8;
  out Store: IAssetStore;
  out Reason: TPWebBundleRefusal): Boolean;

implementation

{$ifdef WINDOWS} // FPC-native define: this unit does not include
uses             // mormot.defines.inc, so OSWINDOWS would be unset
  windows;
{$endif WINDOWS}

function IntToUtf8Local(Value: Int64): RawUtf8;
var
  num: shortstring;
begin
  Str(Value, num); // locale-free ASCII digits
  Result := num;
end;

function PWebBundleRefusalText(Reason: TPWebBundleRefusal): RawUtf8;
begin
  case Reason of
    pbrNone:
      Result := 'accepted';
    pbrBundleMissing:
      Result := 'bundle file missing';
    pbrArchiveInvalid:
      Result := 'bundle archive invalid';
    pbrManifestMissing:
      Result := 'bundle manifest missing';
    pbrManifestMalformed:
      Result := 'bundle manifest malformed';
    pbrProtocolUnsupported:
      Result := 'bundle protocol unsupported';
    pbrRuntimeIncompatible:
      Result := 'runtime below bundle minimum';
    pbrIndexMissing:
      Result := 'bundle index document missing';
  else
    Result := 'bundle refused';
  end;
end;

function PWebSemVerParse(const Version: RawUtf8;
  out Major, Minor, Patch: Cardinal): Boolean;
var
  p, len: PtrInt;

  function Component(out V: Cardinal): Boolean;
  var
    digits: PtrInt;
  begin
    Result := False;
    V := 0;
    if (p > len) or
       not (Version[p] in ['0'..'9']) then
      exit;
    if Version[p] = '0' then
    begin
      Inc(p);
      // '0' must stand alone: leading zeros are not strict semver
      if (p <= len) and
         (Version[p] in ['0'..'9']) then
        exit;
    end
    else
    begin
      digits := 0;
      repeat
        V := V * 10 + Cardinal(Ord(Version[p]) - 48);
        Inc(digits);
        Inc(p);
        if digits > 9 then
          exit; // bounded so the numeric value is always exact
      until (p > len) or
            not (Version[p] in ['0'..'9']);
    end;
    Result := True;
  end;

begin
  Result := False;
  Major := 0;
  Minor := 0;
  Patch := 0;
  p := 1;
  len := Length(Version);
  if not Component(Major) then
    exit;
  if (p > len) or
     (Version[p] <> '.') then
    exit;
  Inc(p);
  if not Component(Minor) then
    exit;
  if (p > len) or
     (Version[p] <> '.') then
    exit;
  Inc(p);
  if not Component(Patch) then
    exit;
  // D6: no prerelease/build suffix, no trailing bytes of any kind
  Result := p > len;
end;

function PWebSemVerValid(const Version: RawUtf8): Boolean;
var
  major, minor, patch: Cardinal;
begin
  Result := PWebSemVerParse(Version, major, minor, patch);
end;

function PWebSemVerCompare(const A, B: RawUtf8;
  out Diff: Integer): Boolean;
var
  aMajor, aMinor, aPatch, bMajor, bMinor, bPatch: Cardinal;
begin
  Result := False;
  Diff := 0;
  if not PWebSemVerParse(A, aMajor, aMinor, aPatch) or
     not PWebSemVerParse(B, bMajor, bMinor, bPatch) then
    exit; // fail closed on any malformed side
  if aMajor <> bMajor then
    if aMajor > bMajor then
      Diff := 1
    else
      Diff := -1
  else if aMinor <> bMinor then
    if aMinor > bMinor then
      Diff := 1
    else
      Diff := -1
  else if aPatch <> bPatch then
    if aPatch > bPatch then
      Diff := 1
    else
      Diff := -1
  else
    Diff := 0;
  Result := True;
end;

function PWebBundleManifestSerialize(
  const Manifest: TPWebBundleManifest): RawUtf8;
begin
  if (Manifest.Protocol < 0) or
     not PWebSemVerValid(Manifest.MinRuntime) then
    raise EPWebBundle.Create('invalid manifest: protocol must be ' +
      '>= 0 and minRuntime strict numeric X.Y.Z');
  // Str()-based conversion is locale-free: deterministic ASCII bytes
  Result := '{"pweb":{"protocol":' + IntToUtf8Local(Manifest.Protocol) +
    ',"minRuntime":"' + Manifest.MinRuntime + '"}}';
end;

function PWebBundleManifestParse(const Json: RawByteString;
  out Manifest: TPWebBundleManifest): Boolean;
const
  MAX_DEPTH = 32; // nesting bound for unknown-field skipping
var
  p, len: PtrInt;
  seenPweb, seenProtocol, seenMinRuntime: Boolean;
  protocolValue: Int64;
  minRuntimeValue, key: RawUtf8;

  function Cur: AnsiChar;
  begin
    if p <= len then
      Result := Json[p]
    else
      Result := #0;
  end;

  procedure SkipWs;
  begin
    while (p <= len) and
          (Json[p] in [' ', #9, #10, #13]) do
      Inc(p);
  end;

  // scan one JSON string, returning its RAW (undecoded) contents.
  // Escapes are validated structurally but left as-is: the canonical
  // manifest never escapes its three ASCII keys or the X.Y.Z value,
  // so an escaped spelling simply fails to match and refuses - fail
  // closed by construction, with no unescape code to get wrong.
  function ScanStringRaw(out Raw: RawUtf8): Boolean;
  var
    start, j: PtrInt;
  begin
    Result := False;
    Raw := '';
    if Cur <> '"' then
      exit;
    Inc(p);
    start := p;
    while p <= len do
      case Json[p] of
        '"':
          begin
            if p > start then
              SetString(Raw, PAnsiChar(@Json[start]), p - start);
            Inc(p);
            Result := True;
            exit;
          end;
        #0..#31:
          exit; // raw control byte inside a string: malformed
        '\':
          begin
            Inc(p);
            if p > len then
              exit;
            case Json[p] of
              '"', '\', '/', 'b', 'f', 'n', 'r', 't':
                Inc(p);
              'u':
                begin
                  if p + 4 > len then
                    exit;
                  for j := 1 to 4 do
                    if not (Json[p + j] in
                        ['0'..'9', 'a'..'f', 'A'..'F']) then
                      exit;
                  Inc(p, 5);
                end;
            else
              exit; // unknown escape
            end;
          end;
      else
        Inc(p);
      end;
    // unterminated string
  end;

  // strict protocol integer: non-negative JSON int, no fraction, no
  // exponent, no leading zeros, bounded - the ratified <int>
  function ScanIntStrict(out V: Int64): Boolean;
  var
    digits: PtrInt;
  begin
    Result := False;
    V := 0;
    if not (Cur in ['0'..'9']) then
      exit; // '-' included: a negative protocol is malformed
    if Cur = '0' then
      Inc(p)
    else
    begin
      digits := 0;
      while (p <= len) and
            (Json[p] in ['0'..'9']) do
      begin
        V := V * 10 + (Ord(Json[p]) - 48);
        Inc(digits);
        Inc(p);
        if digits > 10 then
          exit;
      end;
    end;
    if Cur in ['.', 'e', 'E'] then
      exit; // a float is not the ratified <int>
    if Cur in ['0'..'9'] then
      exit; // '01' style leading zero
    Result := V <= High(Integer);
  end;

  // structural JSON number for skipped unknown members
  function SkipNumber: Boolean;
  begin
    Result := False;
    if Cur = '-' then
      Inc(p);
    if not (Cur in ['0'..'9']) then
      exit;
    if Cur = '0' then
      Inc(p)
    else
      while (p <= len) and
            (Json[p] in ['0'..'9']) do
        Inc(p);
    if Cur = '.' then
    begin
      Inc(p);
      if not (Cur in ['0'..'9']) then
        exit;
      while (p <= len) and
            (Json[p] in ['0'..'9']) do
        Inc(p);
    end;
    if Cur in ['e', 'E'] then
    begin
      Inc(p);
      if Cur in ['+', '-'] then
        Inc(p);
      if not (Cur in ['0'..'9']) then
        exit;
      while (p <= len) and
            (Json[p] in ['0'..'9']) do
        Inc(p);
    end;
    Result := True;
  end;

  function SkipLiteral(const Lit: RawByteString): Boolean;
  begin
    Result := (p + Length(Lit) - 1 <= len) and
      (CompareByte(Json[p], Lit[1], Length(Lit)) = 0);
    if Result then
      Inc(p, Length(Lit));
  end;

  // skip ANY well-formed JSON value: unknown additive fields are
  // ignored and inert - capability-like members included
  function SkipValue(Depth: Integer): Boolean;
  var
    dummy: RawUtf8;
  begin
    Result := False;
    if Depth > MAX_DEPTH then
      exit;
    SkipWs;
    case Cur of
      '"':
        Result := ScanStringRaw(dummy);
      '{':
        begin
          Inc(p);
          SkipWs;
          if Cur = '}' then
          begin
            Inc(p);
            Result := True;
            exit;
          end;
          repeat
            SkipWs;
            if not ScanStringRaw(dummy) then
              exit;
            SkipWs;
            if Cur <> ':' then
              exit;
            Inc(p);
            if not SkipValue(Depth + 1) then
              exit;
            SkipWs;
            if Cur = ',' then
            begin
              Inc(p);
              continue;
            end;
            if Cur = '}' then
            begin
              Inc(p);
              Result := True;
            end;
            exit;
          until False;
        end;
      '[':
        begin
          Inc(p);
          SkipWs;
          if Cur = ']' then
          begin
            Inc(p);
            Result := True;
            exit;
          end;
          repeat
            if not SkipValue(Depth + 1) then
              exit;
            SkipWs;
            if Cur = ',' then
            begin
              Inc(p);
              continue;
            end;
            if Cur = ']' then
            begin
              Inc(p);
              Result := True;
            end;
            exit;
          until False;
        end;
      't':
        Result := SkipLiteral('true');
      'f':
        Result := SkipLiteral('false');
      'n':
        Result := SkipLiteral('null');
      '-', '0'..'9':
        Result := SkipNumber;
    end;
  end;

  function ParsePwebBlock: Boolean;
  var
    blockKey: RawUtf8;
  begin
    Result := False;
    SkipWs;
    if Cur <> '{' then
      exit; // the pweb member must be an object
    Inc(p);
    SkipWs;
    if Cur = '}' then
    begin
      Inc(p);
      Result := True; // empty block parses; required-field check later
      exit;
    end;
    repeat
      SkipWs;
      if not ScanStringRaw(blockKey) then
        exit;
      SkipWs;
      if Cur <> ':' then
        exit;
      Inc(p);
      SkipWs;
      if blockKey = 'protocol' then
      begin
        if seenProtocol then
          exit; // duplicated key is ambiguous: refuse
        if not ScanIntStrict(protocolValue) then
          exit;
        seenProtocol := True;
      end
      else if blockKey = 'minRuntime' then
      begin
        if seenMinRuntime then
          exit;
        if not ScanStringRaw(minRuntimeValue) then
          exit;
        seenMinRuntime := True;
      end
      else if not SkipValue(1) then
        exit; // unknown member of the pweb block: skipped, inert
      SkipWs;
      if Cur = ',' then
      begin
        Inc(p);
        continue;
      end;
      if Cur = '}' then
      begin
        Inc(p);
        Result := True;
      end;
      exit;
    until False;
  end;

begin
  Result := False;
  Manifest.Protocol := 0;
  Manifest.MinRuntime := '';
  seenPweb := False;
  seenProtocol := False;
  seenMinRuntime := False;
  protocolValue := 0;
  minRuntimeValue := '';
  p := 1;
  len := Length(Json);
  SkipWs;
  if Cur <> '{' then
    exit;
  Inc(p);
  SkipWs;
  if Cur = '}' then
    Inc(p) // '{}': parses, but the required pweb block is absent
  else
    repeat
      SkipWs;
      if not ScanStringRaw(key) then
        exit;
      SkipWs;
      if Cur <> ':' then
        exit;
      Inc(p);
      if key = 'pweb' then
      begin
        if seenPweb then
          exit;
        if not ParsePwebBlock then
          exit;
        seenPweb := True;
      end
      else if not SkipValue(1) then
        exit; // unknown top-level member: skipped, inert
      SkipWs;
      if Cur = ',' then
      begin
        Inc(p);
        continue;
      end;
      if Cur = '}' then
      begin
        Inc(p);
        break;
      end;
      exit;
    until False;
  SkipWs;
  if p <= len then
    exit; // trailing bytes after the document
  if not (seenPweb and seenProtocol and seenMinRuntime) then
    exit;
  if not PWebSemVerValid(minRuntimeValue) then
    exit; // D6 grammar gate is part of strict parsing
  Manifest.Protocol := Integer(protocolValue);
  Manifest.MinRuntime := minRuntimeValue;
  Result := True;
end;

function PWebBundleCompatCheck(const Manifest: TPWebBundleManifest;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8): TPWebBundleRefusal;
var
  i: PtrInt;
  supported: Boolean;
  diff: Integer;
begin
  Result := pbrManifestMalformed;
  if not PWebSemVerValid(Manifest.MinRuntime) then
    exit;
  // ratified: SET MEMBERSHIP for the protocol, never ordering
  supported := False;
  for i := 0 to High(SupportedProtocols) do
    if SupportedProtocols[i] = Manifest.Protocol then
      supported := True;
  if not supported then
  begin
    Result := pbrProtocolUnsupported;
    exit;
  end;
  // ratified: numeric SemVer ordering, never lexicographic
  Result := pbrRuntimeIncompatible;
  if not PWebSemVerCompare(RuntimeVersion, Manifest.MinRuntime,
       diff) then
    exit; // an unparseable injected runtime version fails closed
  if diff < 0 then
    exit;
  Result := pbrNone;
end;

function AsciiLowerCopy(const s: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  SetString(Result, PAnsiChar(pointer(s)), Length(s));
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function PWebBundleClassifyName(
  const LogicalPath: RawUtf8): TPWebBundleNameClass;
const
  SECRET_EXT: array[0..5] of RawUtf8 = (
    'pem', 'key', 'pfx', 'p12', 'crt', 'pas');
  LOCKFILES: array[0..8] of RawUtf8 = (
    'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock',
    'pnpm-lock.yaml', 'bun.lockb', 'bun.lock', 'composer.lock',
    'gemfile.lock', 'cargo.lock');
var
  i, start, len, dot: PtrInt;
  seg, last, ext: RawUtf8;
begin
  Result := pbcAsset;
  len := Length(LogicalPath);
  last := '';
  start := 1;
  for i := 1 to len + 1 do
    if (i > len) or
       (LogicalPath[i] = '/') then
    begin
      seg := AsciiLowerCopy(Copy(LogicalPath, start, i - start));
      // D3 per-segment secret/dev names (directories included);
      // '.env' matches exactly or as '.env.*' - never as a prefix of
      // an unrelated name ('.envelope.svg' is an ordinary asset)
      if (seg = '.env') or
         (Copy(seg, 1, 5) = '.env.') or
         (Copy(seg, 1, 4) = '.git') or
         (seg = 'node_modules') or
         (seg = '.ds_store') or
         (seg = 'thumbs.db') then
      begin
        Result := pbcSecret;
        exit;
      end;
      last := seg;
      start := i + 1;
    end;
  // D3 lockfiles, by exact (case-folded) file name
  for i := 0 to High(LOCKFILES) do
    if last = LOCKFILES[i] then
    begin
      Result := pbcSecret;
      exit;
    end;
  // extension of the final segment
  ext := '';
  dot := 0;
  for i := Length(last) downto 1 do
    if last[i] = '.' then
    begin
      dot := i;
      break;
    end;
  if dot > 0 then
    ext := Copy(last, dot + 1, MaxInt);
  for i := 0 to High(SECRET_EXT) do
    if ext = SECRET_EXT[i] then
    begin
      Result := pbcSecret;
      exit;
    end;
  // D5: only the ROOT manifest.json is reserved (the bundler owns it);
  // nested manifest.json files are ordinary assets
  if (last = 'manifest.json') and
     (Pos('/', LogicalPath) = 0) then
  begin
    Result := pbcReservedManifest;
    exit;
  end;
  if ext = 'map' then
    Result := pbcSourceMap;
end;

function PWebBundleTempFileName(const OutFile: TFileName): TFileName;
begin
  Result := OutFile + '.pwbtmp' + IntToStr(GetCurrentProcessId);
end;

{ shared loader tail: manifest -> injected compat -> index.html }

function FinishLoad(const Candidate: IAssetStore;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8;
  out Store: IAssetStore;
  out Reason: TPWebBundleRefusal): Boolean;
var
  asset: TAssetResponse;
  manifest: TPWebBundleManifest;
begin
  Result := False;
  if not Candidate.TryRead(PWEB_BUNDLE_MANIFEST_NAME, asset) then
  begin
    Reason := pbrManifestMissing;
    exit;
  end;
  if not PWebBundleManifestParse(asset.Content, manifest) then
  begin
    Reason := pbrManifestMalformed;
    exit;
  end;
  Reason := PWebBundleCompatCheck(manifest, SupportedProtocols,
    RuntimeVersion);
  if Reason <> pbrNone then
    exit;
  if not Candidate.TryRead(PWEB_ASSET_DEFAULT_DOCUMENT, asset) then
  begin
    Reason := pbrIndexMissing;
    exit;
  end;
  Store := Candidate;
  Result := True;
end;

function PWebBundleLoadBuffer(const Data: RawByteString;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8;
  out Store: IAssetStore;
  out Reason: TPWebBundleRefusal): Boolean;
var
  candidate: IAssetStore;
begin
  Result := False;
  Store := nil;
  Reason := pbrArchiveInvalid;
  try
    // the ONE asset-serving architecture: hostile/ambiguous archives
    // (traversal, duplicates, D1 fold collisions, zip damage) are
    // rejected as a whole by the CAP-4 store construction gate
    candidate := TZipAssetStore.CreateFromBuffer(Data);
    Result := FinishLoad(candidate, SupportedProtocols, RuntimeVersion,
      Store, Reason);
  except
    on Exception do
    begin
      // the loader NEVER raises: any unexpected failure anywhere in
      // the pipeline yields nil store + the typed category only -
      // internals never leak to callers
      Store := nil;
      Reason := pbrArchiveInvalid;
      Result := False;
    end;
  end;
end;

function PWebBundleLoadFile(const BundleFile: TFileName;
  const SupportedProtocols: array of Integer;
  const RuntimeVersion: RawUtf8;
  out Store: IAssetStore;
  out Reason: TPWebBundleRefusal): Boolean;
var
  candidate: IAssetStore;
begin
  Result := False;
  Store := nil;
  if not FileExists(BundleFile) then
  begin
    Reason := pbrBundleMissing;
    exit;
  end;
  Reason := pbrArchiveInvalid;
  try
    candidate := TZipAssetStore.Create(BundleFile);
    Result := FinishLoad(candidate, SupportedProtocols, RuntimeVersion,
      Store, Reason);
  except
    on Exception do
    begin
      // never-raises contract: see PWebBundleLoadBuffer
      Store := nil;
      Reason := pbrArchiveInvalid;
      Result := False;
    end;
  end;
end;

{ deterministic validating writer }

function PWebBundleWrite(const OutFile: TFileName;
  const Entries: array of TPWebBundleEntry;
  const Manifest: TPWebBundleManifest;
  MaxAssetBytes: Int64;
  out ErrorMsg: RawUtf8): Boolean;
var
  n, i, j, ins: PtrInt;
  limit: Int64;
  names: TRawUtf8DynArray;    // global bytewise-sorted canonical names
  source: TIntegerDynArray;   // names[i] -> Entries index, -1=manifest
  folded: TRawUtf8DynArray;   // pinned Unicode 10.0 fold, D1
  manifestBytes: RawUtf8;
  name, raw: RawUtf8;
  content: RawByteString;
  tmp: TFileName;
  tmpCreated, replaced: Boolean;
  zw: TZipWrite;
  zr: TZipRead;
  probe: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
  {$ifdef WINDOWS}
  tmpW, outW: SynUnicode;
  {$endif WINDOWS}

  function EntryBytes(SortedIndex: PtrInt): RawByteString;
  begin
    if source[SortedIndex] < 0 then
      Result := manifestBytes
    else
      Result := Entries[source[SortedIndex]].Content;
  end;

begin
  Result := False;
  ErrorMsg := '';
  tmpCreated := False;
  replaced := False;
  // the manifest the bundler will own must itself be canonical
  if (Manifest.Protocol < 0) or
     not PWebSemVerValid(Manifest.MinRuntime) then
  begin
    ErrorMsg := 'invalid manifest: protocol must be >= 0 and ' +
      'minRuntime strict numeric X.Y.Z (got "' +
      Manifest.MinRuntime + '")';
    exit;
  end;
  limit := MaxAssetBytes;
  if limit <= 0 then
    limit := PWEB_BUNDLE_MAX_ASSET_BYTES_DEFAULT;
  if limit > High(Integer) then
    limit := High(Integer); // v1 assets stay materialisable (2GB cap)
  n := Length(Entries);
  // ---- validation, entirely before anything touches the disk ----
  SetLength(names, n + 1);
  SetLength(source, n + 1);
  for i := 0 to n do
  begin
    if i < n then
    begin
      name := Entries[i].Name;
      if not PWebAssetPathValid(name) then
      begin
        ErrorMsg := 'non-canonical entry name rejected: "' + name + '"';
        exit;
      end;
      case PWebBundleClassifyName(name) of
        pbcSecret:
          begin
            ErrorMsg := 'secret/development artifact refused by ' +
              'name: "' + name + '"';
            exit;
          end;
        pbcReservedManifest:
          begin
            ErrorMsg := 'input must not contain a root ' +
              'manifest.json - the bundler generates it: "' +
              name + '"';
            exit;
          end;
      end;
      if Int64(Length(Entries[i].Content)) > limit then
      begin
        ErrorMsg := 'asset exceeds the per-asset bundle limit of ' +
          IntToUtf8Local(limit) + ' bytes: "' + name +
          '" - bulk media belongs on the pweb://blob data plane ' +
          '(CAP-4b), not inside app.pwb';
        exit;
      end;
    end
    else
      name := PWEB_BUNDLE_MANIFEST_NAME; // the bundler-owned entry
    // insertion sort: global bytewise order of canonical names
    ins := 0;
    while (ins < i) and
          (CompareStr(names[ins], name) < 0) do
      Inc(ins);
    if (ins < i) and
       (names[ins] = name) then
    begin
      ErrorMsg := 'duplicate entry name rejected: "' + name + '"';
      exit;
    end;
    for j := i downto ins + 1 do
    begin
      names[j] := names[j - 1];
      source[j] := source[j - 1];
    end;
    names[ins] := name;
    if i < n then
      source[ins] := i
    else
      source[ins] := -1;
  end;
  Inc(n); // names/source now include manifest.json
  // ratified D1, enforcement point 1 (point 2 is TZipAssetStore):
  // two names equal under the pinned mORMot Unicode 10.0 simple case
  // fold are ambiguous and reject the build. The fold never rewrites
  // a name - it is purely a collision verdict, identical on every
  // machine because the tables are compiled in (never the OS).
  SetLength(folded, n);
  for i := 0 to n - 1 do
    folded[i] := UpperCaseReference(names[i]);
  for i := 0 to n - 1 do
    for j := i + 1 to n - 1 do
      if folded[i] = folded[j] then
      begin
        ErrorMsg := 'case-colliding entry names rejected ' +
          '(Unicode 10.0 fold): "' + names[i] + '" vs "' +
          names[j] + '"';
        exit;
      end;
  // a name that is also a directory prefix of another cannot exist in
  // any folder layout - ambiguous, rejected (mirrors the store rule)
  for i := 0 to n - 1 do
    for j := 0 to n - 1 do
      if (i <> j) and
         (Length(names[j]) > Length(names[i]) + 1) and
         (CompareStr(Copy(names[j], 1, Length(names[i])),
            names[i]) = 0) and
         (names[j][Length(names[i]) + 1] = '/') then
      begin
        ErrorMsg := 'file/directory-colliding entry names ' +
          'rejected: "' + names[i] + '" vs "' + names[j] + '"';
        exit;
      end;
  // the released UI must be bootable: require the default document
  j := -1;
  for i := 0 to n - 1 do
    if names[i] = PWEB_ASSET_DEFAULT_DOCUMENT then
      j := i;
  if j < 0 then
  begin
    ErrorMsg := 'bundle input has no ' + PWEB_ASSET_DEFAULT_DOCUMENT;
    exit;
  end;
  // TZipWrite takes native TFileName entry names; require an exact
  // byte round-trip so the codepage conversion hazard fails loudly
  // here (and would still be caught below by the raw-name compare)
  for i := 0 to n - 1 do
    if StringToUtf8(Utf8ToString(names[i])) <> names[i] then
    begin
      ErrorMsg := 'entry name is not byte-representable through ' +
        'this system codepage: "' + names[i] + '"';
      exit;
    end;
  manifestBytes := PWebBundleManifestSerialize(Manifest);
  // ---- deterministic write to a temp sibling ----
  tmp := PWebBundleTempFileName(OutFile);
  try
    try
      SysUtils.DeleteFile(tmp); // stale temp of an interrupted run
      zw := TZipWrite.Create(tmp);
      tmpCreated := True;
      try
        for i := 0 to n - 1 do
        begin
          content := EntryBytes(i);
          zw.AddDeflated(Utf8ToString(names[i]), pointer(content),
            Length(content), PWEB_BUNDLE_DEFLATE_LEVEL,
            PWEB_BUNDLE_FIXED_FILE_AGE);
        end;
        if zw.NeedZip64 then
        begin
          ErrorMsg := 'bundle exceeds the zip32 bound - zip64 ' +
            'extra fields would break the deterministic format';
          exit;
        end;
      finally
        zw.Free;
      end;
      // ---- self-validation 1: raw stored-name byte compare ----
      // (closes the TZipWrite non-ASCII/codepage hazard: the bytes in
      // the archive must be EXACTLY the canonical sorted names)
      zr := TZipRead.Create(tmp);
      try
        if zr.Count <> n then
        begin
          ErrorMsg := 'self-validation failed: entry count drifted';
          exit;
        end;
        for i := 0 to n - 1 do
        begin
          FastSetString(raw, zr.Entry[i].storedName,
            zr.Entry[i].dir^.fileInfo.nameLen);
          if raw <> names[i] then
          begin
            ErrorMsg := 'self-validation failed: stored entry name ' +
              'drifted: "' + raw + '" expected "' + names[i] + '"';
            exit;
          end;
          if zr.Entry[i].dir^.fileInfo.zlastMod <>
               PWEB_BUNDLE_FIXED_FILE_AGE then
          begin
            ErrorMsg := 'self-validation failed: non-deterministic ' +
              'timestamp on "' + names[i] + '"';
            exit;
          end;
          if zr.Entry[i].dir^.fileInfo.extraLen <> 0 then
          begin
            ErrorMsg := 'self-validation failed: unexpected extra ' +
              'field on "' + names[i] + '"';
            exit;
          end;
        end;
      finally
        zr.Free;
      end;
      // ---- self-validation 2: the PRODUCTION loader must accept ----
      // (compat parameters are the bundle's own facts: the runtime
      // gate belongs to load time, this proves structure + D1 + D5)
      if not PWebBundleLoadFile(tmp, [Manifest.Protocol],
           Manifest.MinRuntime, probe, reason) then
      begin
        ErrorMsg := 'self-validation failed: production loader ' +
          'refused the fresh bundle (' +
          PWebBundleRefusalText(reason) + ')';
        exit;
      end;
      // ---- self-validation 3: every byte serves back identically ----
      for i := 0 to n - 1 do
      begin
        if not probe.TryRead(names[i], asset) then
        begin
          ErrorMsg := 'self-validation failed: entry unreadable: "' +
            names[i] + '"';
          exit;
        end;
        if asset.Content <> EntryBytes(i) then
        begin
          ErrorMsg := 'self-validation failed: content drifted: "' +
            names[i] + '"';
          exit;
        end;
      end;
      probe := nil; // release the file handle before the replace
      // ---- atomic replace: the previous output either survives ----
      // intact or is replaced by a fully validated bundle
      {$ifdef WINDOWS}
      tmpW := Utf8ToSynUnicode(StringToUtf8(tmp));
      outW := Utf8ToSynUnicode(StringToUtf8(OutFile));
      if not MoveFileExW(PWideChar(tmpW), PWideChar(outW),
           MOVEFILE_REPLACE_EXISTING) then
      begin
        ErrorMsg := 'atomic replace failed (Win32 error ' +
          IntToUtf8Local(GetLastError) + ')';
        exit;
      end;
      {$else}
      // POSIX rename() replaces the destination atomically: the
      // previous output survives unless the whole rename succeeds
      if not RenameFile(tmp, OutFile) then
      begin
        ErrorMsg := 'atomic replace failed (rename)';
        exit;
      end;
      {$endif WINDOWS}
      replaced := True;
      Result := True;
    except
      on E: Exception do
      begin
        ErrorMsg := 'bundle write failed (' + StringToUtf8(E.ClassName) +
          ': ' + StringToUtf8(E.Message) + ')';
        Result := False;
      end;
    end;
  finally
    probe := nil; // drop any open handle before removing the temp
    if tmpCreated and
       not replaced then
      // deterministic cleanup, prior output untouched
      SysUtils.DeleteFile(tmp);
  end;
end;

end.
