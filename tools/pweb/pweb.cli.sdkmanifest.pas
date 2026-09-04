{
  pweb.cli.sdkmanifest - what an installed PWeb SDK says about itself, and
  how that is checked (CAP-10D2).

  ONE canonical document, written by ONE tool and read by ONE verifier:

      <root>/share/pweb/sdk-manifest.json

  It carries, for every file the distribution ships, the relative path, the
  byte length and the sha256; plus the template pack's two digests, the
  digests of the repository locks the package was built from, and the
  licence set. `pweb doctor` reports three rows over it and the CAP-10C1
  pipeline refuses a build against an SDK that does not match it.

  ---------------------------------------------------------------------------
  WHAT IT IS AND WHAT IT IS NOT
  ---------------------------------------------------------------------------

  It is an INVENTORY, and the whole of the claim is stated rather than
  implied:

    IT CATCHES   a half-copied SDK, a truncated download, an extraction that
                 lost a file, and a shipped byte that was altered - a
                 patched mORMot unit, a replaced webview library, a
                 rewritten template pack. Verification is FULL: every
                 declared file's length and digest, on every run. There is
                 no sample: a sample would make "one altered file is
                 detected" probabilistic, and a probabilistic tamper claim
                 is not one worth gating a build on.

    IT DOES NOT  catch a manifest that was rewritten to describe the altered
                 bytes, and it does not notice its own absence: an SDK root
                 with no manifest is an UNPACKAGED root - which is exactly
                 what this repository's own staged build tree is - and the
                 three doctor rows say `not_applicable` there rather than
                 inventing a verdict.

  THE ANCHOR, RATIFIED. The manifest is trusted for the inventory; the
  COMPILED CAP-10B0 registry stays the authority for the template pack, so
  the one artifact a user's new project is generated from is anchored in the
  executable rather than in a file beside it. Compiling the manifest's own
  digest into `pweb` was considered and REFUSED: it would pin one binary to
  one package and make a re-packaged SDK unusable with the executable inside
  it.

  ---------------------------------------------------------------------------
  THE CANONICAL FORM, AND WHY THE ESCAPES ARE RATIFIED HERE
  ---------------------------------------------------------------------------

  Fixed key order, two-space indent, LF, exactly one trailing newline, and
  the escape set of ECMAScript's JSON.stringify, exactly:

      "  -> \"        \  -> \\        U+0008 -> \b     U+0009 -> \t
      U+000A -> \n    U+000C -> \f    U+000D -> \r
      any other code point below U+0020 -> \u00xx, LOWERCASE hex
      everything else, `/` and non-ASCII included -> literal

  A value is DECODED before it is re-encoded, so a redundant escape in the
  input (`A` for `A`, `\/` for `/`) normalises to what JSON.stringify
  would have written. Invalid UTF-8 and a lone surrogate are REFUSALS, not
  rewrites: a canonicalizer that repaired its input would be inventing
  bytes.

  That rule is this unit's, and pweb.cli.stage's TypeScript-SDK re-emitter
  now uses it too - which is the whole of deferred item C1-11 (c). Before
  this, that function copied the SOURCE BYTES of each value, so it agreed
  with `node tools/stage-ts-sdk.mjs` only for as long as the pinned
  package.json happened to contain no escape at all. The mjs script keeps its
  staging role and the CAP-10C1 ST1 gate keeps requiring byte-identity, so
  the agreement is now a cross-check between two independent implementations
  rather than a coincidence of formatting.

  ---------------------------------------------------------------------------
  THIS UNIT READS. IT NEVER WRITES, SPAWNS OR RESOLVES
  ---------------------------------------------------------------------------

  Every path is walked one component at a time through PWebCliEntry - the
  same primitive pweb.cli.sdk and pweb.cli.sdkroot use, which compares the
  name byte-exactly and reports a junction or a symlink as pcnLink. So a
  `deps` junction cannot make a digest come from somewhere else, and a case
  variant cannot resolve on NTFS or APFS.

  There is no PWEB_SDK, no PWEB_HOME and no environment read of any kind:
  the root is a PARAMETER, and PWebCliSdkVerify's is the running image's own,
  by the one CAP-10B0 anchor rule.
}
unit pweb.cli.sdkmanifest;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.sdk;

const
  /// the manifest's name, inside <root>/share/pweb
  PWEB_SDK_MANIFEST = 'sdk-manifest.json';
  /// the licence directory, inside <root>/share/pweb
  PWEB_SDK_LICENSES = 'licenses';
  /// the manifest schema - a PUBLIC surface of the distribution
  PWEB_SDK_MANIFEST_SCHEMA = 1;

  /// the manifest itself is bounded: it is an inventory, not an archive
  PWEB_SDK_MANIFEST_MAX_BYTES = 8 * 1024 * 1024;
  /// how many files one distribution may declare
  PWEB_SDK_MAX_FILES = 8192;
  /// the largest shipped file this verifier will read in one piece
  PWEB_SDK_MAX_FILE_BYTES = 268435456;

  /// the six repository locks whose digests travel in the manifest
  // - the LOCK FILES THEMSELVES ARE NEVER SHIPPED: they carry the vendors'
  // download addresses, and docs/distribution-contract.md section 3 freezes
  // that they stay repository build metadata. A digest is not an address, so
  // the package records WHICH lock revision produced it without putting a
  // URL on anybody's build path
  PWEB_SDK_LOCKS: array[0 .. 5] of RawUtf8 = (
    'fpc.lock', 'innosetup.lock', 'mormot.lock', 'pas2js.lock',
    'webview.lock', 'webview2-runtime.lock');

type
  /// one shipped file, as the manifest declares it
  // - Path is LOGICAL: forward slashes, relative to the SDK root, no
  // leading or trailing separator and no '.' or '..' segment
  TPWebSdkFile = record
    Path: RawUtf8;
    Bytes: Int64;
    Sha256: RawUtf8;
  end;
  TPWebSdkFiles = array of TPWebSdkFile;

  /// one named digest (a lock)
  TPWebSdkNamed = record
    Name: RawUtf8;
    Sha256: RawUtf8;
  end;
  TPWebSdkNameds = array of TPWebSdkNamed;

  /// the whole document
  TPWebSdkManifest = record
    Schema: Integer;
    /// the `pweb` version this package was built from and ships
    PWebVersion: RawUtf8;
    /// PWEB_PROTOCOL_VERSION, recorded so a package states the wire it
    // belongs to without anybody having to run the executable
    Protocol: Integer;
    /// <os>-<arch>, the CAP-10C0 target name
    Target: RawUtf8;
    /// the CAP-10B0 pack file's sha256, its semantic inventory digest and
    // the digest of the registry COMPILED INTO the shipped executable
    TemplatePack: RawUtf8;
    TemplateInventory: RawUtf8;
    TemplateRegistry: RawUtf8;
    Locks: TPWebSdkNameds;
    /// the licence file names, without their directory
    Licenses: TRawUtf8DynArray;
    Files: TPWebSdkFiles;
  end;

  /// why a manifest, or the tree it describes, was refused
  // - machine-stable, one cause each; ordinal 0 is the accepted state
  TPWebSdkManifestRefusal = (
    psmNone,
    /// there is no manifest at all: an UNPACKAGED SDK root, which is a
    /// legitimate arrangement and not a failure
    psmAbsent,
    /// the SDK root itself could not be resolved
    psmRootUnresolved,
    /// the manifest is present and could not be read, or is over its bound
    psmUnreadable,
    /// it is not well-formed JSON of the ratified shape
    psmMalformed,
    /// it is well-formed and is not the canonical serialization of itself
    psmNoncanonical,
    /// the schema is not PWEB_SDK_MANIFEST_SCHEMA
    psmSchema,
    /// a declared value is empty, malformed, out of order or duplicated
    psmValue,
    /// it declares more files than PWEB_SDK_MAX_FILES
    psmTooManyFiles,
    /// the manifest's version is not the running executable's
    psmVersionMismatch,
    /// a declared file is absent, is not a regular file, or is a link
    psmFileMissing,
    /// a declared file is present with a different byte length
    psmFileBytes,
    /// a declared file is present, the right length, and different bytes
    psmFileDigest,
    /// a declared licence is not among the declared files
    psmLicenseMissing,
    /// a string is not valid UTF-8, or carries a lone surrogate
    psmEncoding);

  /// what one verification of one SDK root learned
  // - this is a FACT, injected into the doctor's environment exactly as the
  // host facts are, so the requirement graph reports it without measuring it
  TPWebCliSdkFact = record
    /// the root this fact is about, '' when it could not be resolved
    Root: RawUtf8;
    /// True when share/pweb/sdk-manifest.json exists as a regular file
    Present: Boolean;
    /// psmNone when the manifest is present, canonical and schema 1
    Manifest: TPWebSdkManifestRefusal;
    /// psmNone when every declared file is present with its declared length
    /// and digest, and every declared licence is among them
    Integrity: TPWebSdkManifestRefusal;
    /// psmNone when the manifest's version is the running executable's
    Version: TPWebSdkManifestRefusal;
    /// the logical path, or the field name, the first refusal is about
    Detail: RawUtf8;
    Schema: Integer;
    /// the manifest's own values, recorded whether or not they matched
    PWebVersion: RawUtf8;
    Target: RawUtf8;
    /// how many files were declared, and how many were verified whole
    Declared: Integer;
    Verified: Integer;
    Licenses: Integer;
    Locks: Integer;
    /// how long the full verification took, in milliseconds - an
    /// OBSERVATION, recorded per target and compared with nothing
    ElapsedMs: Int64;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebSdkRefusalTextM(Refusal: TPWebSdkManifestRefusal): RawUtf8;

/// encode ONE UTF-8 string as a canonical JSON string literal, quotes
/// included
// - the ratified escape set; see the unit header
// - False when the input is not valid UTF-8
function PWebSdkJsonEncode(const Value: RawUtf8; out Literal: RawUtf8): Boolean;

/// decode ONE JSON string literal, quotes included, into UTF-8 bytes
// - handles every escape JSON defines, surrogate pairs included
// - False for a malformed literal, a lone surrogate or invalid UTF-8
function PWebSdkJsonDecode(const Literal: RawUtf8; out Value: RawUtf8): Boolean;

/// decode then re-encode: the canonical form of a JSON string literal
// - this is the function deferred item C1-11 (c) asked for, and it is used
// by the manifest writer, by the manifest reader and by
// pweb.cli.stage's TypeScript-SDK re-emitter
function PWebSdkJsonCanonical(const Literal: RawUtf8;
  out Canonical: RawUtf8): Boolean;

/// the canonical serialization of a manifest
// - '' when a value cannot be encoded, which the caller treats as a refusal
function PWebSdkManifestText(const Manifest: TPWebSdkManifest): RawUtf8;

/// the semantic inventory digest of a file list: sha256 over
/// `<path>|<bytes>|<sha256>` lines, LF-terminated, in declared order
// - the value a gate pins per target, and the value two packaging runs of
// one commit must agree about
function PWebSdkInventoryDigest(const Files: TPWebSdkFiles): RawUtf8;

/// strict-parse a canonical manifest
// - the ratified key order is REQUIRED: it is part of the canonical form,
// and a reader that accepted any order would accept a document the writer
// can never produce
function PWebSdkParse(const Text: RawUtf8; out Manifest: TPWebSdkManifest;
  out Refusal: TPWebSdkManifestRefusal; out Detail: RawUtf8): Boolean;

/// read, parse and FULLY verify the SDK rooted at Root
// - ExpectVersion is the RUNNING executable's version; the caller owns that
// identity, so this unit never has to know where a version comes from
// - Root must already be canonical
function PWebCliSdkVerifyIn(const Root, ExpectVersion: RawUtf8): TPWebCliSdkFact;

/// the same, for the SDK root of the RUNNING image
function PWebCliSdkVerify(const ExpectVersion: RawUtf8): TPWebCliSdkFact;

/// True when the fact says a build may proceed
// - an ABSENT manifest is not a refusal: it is an unpackaged root
function PWebCliSdkFactAccepted(const Fact: TPWebCliSdkFact): Boolean;

/// the machine-stable cause a refusing fact carries, '' when accepted
function PWebCliSdkFactCause(const Fact: TPWebCliSdkFact): RawUtf8;


implementation

function PWebSdkRefusalTextM(Refusal: TPWebSdkManifestRefusal): RawUtf8;
begin
  case Refusal of
    psmNone:            Result := 'ok';
    psmAbsent:          Result := 'sdk_unpackaged';
    psmRootUnresolved:  Result := 'sdk_root_unresolved';
    psmUnreadable:      Result := 'sdk_manifest_unreadable';
    psmMalformed:       Result := 'sdk_manifest_malformed';
    psmNoncanonical:    Result := 'sdk_manifest_noncanonical';
    psmSchema:          Result := 'sdk_manifest_schema';
    psmValue:           Result := 'sdk_manifest_value';
    psmTooManyFiles:    Result := 'sdk_manifest_too_many_files';
    psmVersionMismatch: Result := 'sdk_version_mismatch';
    psmFileMissing:     Result := 'sdk_integrity_missing';
    psmFileBytes:       Result := 'sdk_integrity_bytes';
    psmFileDigest:      Result := 'sdk_integrity_mismatch';
    psmLicenseMissing:  Result := 'sdk_license_missing';
    psmEncoding:        Result := 'sdk_manifest_encoding';
  else
    Result := 'sdk_manifest_refused';
  end;
end;

{ ---------------------------------------------------------------------------
  UTF-8, strictly

  Neither decoder accepts an overlong form, a surrogate encoded as three
  bytes, or a code point above U+10FFFF. A canonicalizer that accepted a
  non-shortest form would emit different bytes for the same text depending
  on which of the two it was handed.
  --------------------------------------------------------------------------- }

// one code point out of Value at Pos (1-based), advancing Pos past it
function NextUtf8(const Value: RawUtf8; var Pos: PtrInt;
  out Cp: Cardinal): Boolean;
var
  b, c: Byte;
  n, i: PtrInt;
begin
  Cp := 0;
  Result := False;
  if (Pos < 1) or
     (Pos > Length(Value)) then
    exit;
  b := Byte(Value[Pos]);
  if b < $80 then
  begin
    Cp := b;
    Inc(Pos);
    Result := True;
    exit;
  end;
  if (b and $E0) = $C0 then
  begin
    n := 1;
    Cp := b and $1F;
  end
  else if (b and $F0) = $E0 then
  begin
    n := 2;
    Cp := b and $0F;
  end
  else if (b and $F8) = $F0 then
  begin
    n := 3;
    Cp := b and $07;
  end
  else
    exit; // a continuation byte, or $F8..$FF
  if Pos + n > Length(Value) then
    exit;
  for i := 1 to n do
  begin
    c := Byte(Value[Pos + i]);
    if (c and $C0) <> $80 then
      exit;
    Cp := (Cp shl 6) or (c and $3F);
  end;
  // the shortest form, and nothing in the surrogate range
  case n of
    1: if Cp < $80 then exit;
    2: if (Cp < $800) or
          ((Cp >= $D800) and (Cp <= $DFFF)) then exit;
    3: if (Cp < $10000) or
          (Cp > $10FFFF) then exit;
  end;
  Inc(Pos, n + 1);
  Result := True;
end;

function EncodeUtf8Cp(Cp: Cardinal): RawUtf8;
begin
  if Cp < $80 then
    Result := AnsiChar(Cp)
  else if Cp < $800 then
    Result := AnsiChar($C0 or (Cp shr 6)) +
              AnsiChar($80 or (Cp and $3F))
  else if Cp < $10000 then
    Result := AnsiChar($E0 or (Cp shr 12)) +
              AnsiChar($80 or ((Cp shr 6) and $3F)) +
              AnsiChar($80 or (Cp and $3F))
  else
    Result := AnsiChar($F0 or (Cp shr 18)) +
              AnsiChar($80 or ((Cp shr 12) and $3F)) +
              AnsiChar($80 or ((Cp shr 6) and $3F)) +
              AnsiChar($80 or (Cp and $3F));
end;

const
  HEX_LOWER: array[0 .. 15] of AnsiChar = '0123456789abcdef';

function Hex4(Value: Cardinal): RawUtf8;
begin
  SetLength(Result, 4);
  Result[1] := HEX_LOWER[(Value shr 12) and $F];
  Result[2] := HEX_LOWER[(Value shr 8) and $F];
  Result[3] := HEX_LOWER[(Value shr 4) and $F];
  Result[4] := HEX_LOWER[Value and $F];
end;

{ ---------------------------------------------------------------------------
  the ratified escape rule
  --------------------------------------------------------------------------- }

function PWebSdkJsonEncode(const Value: RawUtf8;
  out Literal: RawUtf8): Boolean;
var
  pos, start: PtrInt;
  cp: Cardinal;
  esc: RawUtf8;
begin
  Literal := '';
  Result := False;
  pos := 1;
  Literal := '"';
  while pos <= Length(Value) do
  begin
    start := pos;
    if not NextUtf8(Value, pos, cp) then
    begin
      Literal := '';
      exit;
    end;
    case cp of
      $08: esc := '\b';
      $09: esc := '\t';
      $0A: esc := '\n';
      $0C: esc := '\f';
      $0D: esc := '\r';
      $22: esc := '\"';
      $5C: esc := '\\';
    else
      // every other code point below U+0020 is \u00xx with LOWERCASE hex,
      // and everything at or above it - `/` and non-ASCII included - is
      // literal. That is JSON.stringify's rule, and copying the SOURCE
      // BYTES of the run is what makes a valid input round-trip unchanged
      if cp < $20 then
        esc := '\u' + Hex4(cp)
      else
        esc := Copy(Value, start, pos - start);
    end;
    Literal := Literal + esc;
  end;
  Literal := Literal + '"';
  Result := True;
end;

function HexDigit(C: AnsiChar; out Value: Cardinal): Boolean;
begin
  Result := True;
  case C of
    '0' .. '9': Value := Ord(C) - Ord('0');
    'a' .. 'f': Value := Ord(C) - Ord('a') + 10;
    'A' .. 'F': Value := Ord(C) - Ord('A') + 10;
  else
    Value := 0;
    Result := False;
  end;
end;

// \uXXXX at Pos (which points at the 'u'); advances past the four digits
function ReadHex4(const Literal: RawUtf8; var Pos: PtrInt;
  out Value: Cardinal): Boolean;
var
  i, d: Cardinal;
  k: PtrInt;
begin
  Value := 0;
  Result := False;
  if Pos + 4 > Length(Literal) then
    exit;
  i := 0;
  for k := 1 to 4 do
  begin
    if not HexDigit(Literal[Pos + k], d) then
      exit;
    i := (i shl 4) or d;
  end;
  Inc(Pos, 5);
  Value := i;
  Result := True;
end;

function PWebSdkJsonDecode(const Literal: RawUtf8;
  out Value: RawUtf8): Boolean;
var
  pos, start: PtrInt;
  cp, lo: Cardinal;
begin
  Value := '';
  Result := False;
  if (Length(Literal) < 2) or
     (Literal[1] <> '"') or
     (Literal[Length(Literal)] <> '"') then
    exit;
  pos := 2;
  while pos < Length(Literal) do
  begin
    if Literal[pos] = '"' then
      exit; // an unescaped quote before the end: two literals, not one
    if Literal[pos] <> '\' then
    begin
      start := pos;
      if not NextUtf8(Literal, pos, cp) then
        exit;
      if cp < $20 then
        exit; // a raw control byte is not legal inside a JSON string
      Value := Value + Copy(Literal, start, pos - start);
      continue;
    end;
    Inc(pos);
    if pos >= Length(Literal) then
      exit;
    case Literal[pos] of
      '"':  begin Value := Value + '"';  Inc(pos); end;
      '\':  begin Value := Value + '\';  Inc(pos); end;
      '/':  begin Value := Value + '/';  Inc(pos); end;
      'b':  begin Value := Value + #8;   Inc(pos); end;
      'f':  begin Value := Value + #12;  Inc(pos); end;
      'n':  begin Value := Value + #10;  Inc(pos); end;
      'r':  begin Value := Value + #13;  Inc(pos); end;
      't':  begin Value := Value + #9;   Inc(pos); end;
      'u':
        begin
          if not ReadHex4(Literal, pos, cp) then
            exit;
          if (cp >= $D800) and (cp <= $DBFF) then
          begin
            // a high surrogate MUST be followed by its low half, spelled as
            // a second \u escape. Anything else is a lone surrogate, which
            // has no UTF-8 encoding and is refused rather than replaced
            if (pos + 1 > Length(Literal)) or
               (Literal[pos] <> '\') or
               (Literal[pos + 1] <> 'u') then
              exit;
            Inc(pos);
            if not ReadHex4(Literal, pos, lo) then
              exit;
            if (lo < $DC00) or
               (lo > $DFFF) then
              exit;
            cp := $10000 + ((cp - $D800) shl 10) + (lo - $DC00);
          end
          else if (cp >= $DC00) and (cp <= $DFFF) then
            exit;
          Value := Value + EncodeUtf8Cp(cp);
        end;
    else
      exit; // an escape JSON does not define
    end;
  end;
  Result := pos = Length(Literal);
end;

function PWebSdkJsonCanonical(const Literal: RawUtf8;
  out Canonical: RawUtf8): Boolean;
var
  value: RawUtf8;
begin
  Canonical := '';
  Result := PWebSdkJsonDecode(Literal, value) and
            PWebSdkJsonEncode(value, Canonical);
  if not Result then
    Canonical := '';
end;

{ ---------------------------------------------------------------------------
  the canonical document
  --------------------------------------------------------------------------- }

function IntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

function PWebSdkManifestText(const Manifest: TPWebSdkManifest): RawUtf8;
var
  parts: TRawUtf8DynArray;
  used: PtrInt;
  bad: Boolean;
  i, total, at: PtrInt;

  // the document is assembled into a part list and joined ONCE: an
  // inventory of a few thousand files concatenated onto a growing string
  // copies the whole document per member
  procedure Put(const Text0: RawUtf8);
  begin
    if used >= Length(parts) then
      SetLength(parts, (used + 16) * 2);
    parts[used] := Text0;
    Inc(used);
  end;

  // every string in the document goes through the ONE encoder; an
  // unencodable value makes the whole document empty, so a caller can never
  // ship half of one
  function Enc(const Value: RawUtf8): RawUtf8;
  begin
    if not PWebSdkJsonEncode(Value, Result) then
    begin
      Result := '""';
      bad := True;
    end;
  end;

  procedure Member(const Indent, Key, Literal, Tail: RawUtf8);
  begin
    Put(Indent + '"' + Key + '": ' + Literal + Tail);
  end;

begin
  Result := '';
  parts := nil;
  used := 0;
  bad := False;
  Put('{'#10);
  Member('  ', 'schema', IntText(Manifest.Schema), ','#10);
  Member('  ', 'pweb', Enc(Manifest.PWebVersion), ','#10);
  Member('  ', 'protocol', IntText(Manifest.Protocol), ','#10);
  Member('  ', 'target', Enc(Manifest.Target), ','#10);
  Put('  "templates": {'#10);
  Member('    ', 'pack', Enc(Manifest.TemplatePack), ','#10);
  Member('    ', 'inventory', Enc(Manifest.TemplateInventory), ','#10);
  Member('    ', 'registry', Enc(Manifest.TemplateRegistry), #10);
  Put('  },'#10);
  if Length(Manifest.Locks) = 0 then
    Put('  "locks": [],'#10)
  else
  begin
    Put('  "locks": ['#10);
    for i := 0 to High(Manifest.Locks) do
    begin
      Put('    {'#10);
      Member('      ', 'name', Enc(Manifest.Locks[i].Name), ','#10);
      Member('      ', 'sha256', Enc(Manifest.Locks[i].Sha256), #10);
      if i < High(Manifest.Locks) then
        Put('    },'#10)
      else
        Put('    }'#10);
    end;
    Put('  ],'#10);
  end;
  if Length(Manifest.Licenses) = 0 then
    Put('  "licenses": [],'#10)
  else
  begin
    Put('  "licenses": ['#10);
    for i := 0 to High(Manifest.Licenses) do
      if i < High(Manifest.Licenses) then
        Put('    ' + Enc(Manifest.Licenses[i]) + ','#10)
      else
        Put('    ' + Enc(Manifest.Licenses[i]) + #10);
    Put('  ],'#10);
  end;
  if Length(Manifest.Files) = 0 then
    Put('  "files": []'#10)
  else
  begin
    Put('  "files": ['#10);
    for i := 0 to High(Manifest.Files) do
    begin
      Put('    {'#10);
      Member('      ', 'path', Enc(Manifest.Files[i].Path), ','#10);
      Member('      ', 'bytes', IntText(Manifest.Files[i].Bytes), ','#10);
      Member('      ', 'sha256', Enc(Manifest.Files[i].Sha256), #10);
      if i < High(Manifest.Files) then
        Put('    },'#10)
      else
        Put('    }'#10);
    end;
    Put('  ]'#10);
  end;
  Put('}'#10);
  if bad then
    exit;
  total := 0;
  for i := 0 to used - 1 do
    Inc(total, Length(parts[i]));
  SetLength(Result, total);
  at := 1;
  for i := 0 to used - 1 do
    if parts[i] <> '' then
    begin
      Move(parts[i][1], Result[at], Length(parts[i]));
      Inc(at, Length(parts[i]));
    end;
end;

function PWebSdkInventoryDigest(const Files: TPWebSdkFiles): RawUtf8;
var
  i: PtrInt;
  lines: RawUtf8;
begin
  lines := '';
  for i := 0 to High(Files) do
    lines := lines + Files[i].Path + '|' + IntText(Files[i].Bytes) + '|' +
      Files[i].Sha256 + #10;
  Result := LowerCaseU(Sha256(lines));
end;

{ ---------------------------------------------------------------------------
  the strict reader
  --------------------------------------------------------------------------- }

type
  TScan = record
    Text: RawUtf8;
    Pos: PtrInt;
    Refusal: TPWebSdkManifestRefusal;
    Detail: RawUtf8;
  end;

procedure Fail(var S: TScan; Refusal: TPWebSdkManifestRefusal;
  const Detail: RawUtf8);
begin
  if S.Refusal = psmNone then
  begin
    S.Refusal := Refusal;
    S.Detail := Detail;
  end;
end;

procedure Ws(var S: TScan);
begin
  while (S.Pos <= Length(S.Text)) and
        (S.Text[S.Pos] in [' ', #9, #10, #13]) do
    Inc(S.Pos);
end;

function Ch(var S: TScan; C: AnsiChar; const What: RawUtf8): Boolean;
begin
  Ws(S);
  Result := (S.Pos <= Length(S.Text)) and
            (S.Text[S.Pos] = C);
  if Result then
    Inc(S.Pos)
  else
    Fail(S, psmMalformed, What);
end;

// the same, where the answer is only ever "carry on or record a refusal"
procedure Punct(var S: TScan; C: AnsiChar; const What: RawUtf8);
begin
  Ch(S, C, What);
end;

// one JSON string literal, returned DECODED
function Lit(var S: TScan; out Value: RawUtf8;
  const What: RawUtf8): Boolean;
var
  start: PtrInt;
begin
  Value := '';
  Result := False;
  Ws(S);
  if (S.Pos > Length(S.Text)) or
     (S.Text[S.Pos] <> '"') then
  begin
    Fail(S, psmMalformed, What);
    exit;
  end;
  start := S.Pos;
  Inc(S.Pos);
  while S.Pos <= Length(S.Text) do
  begin
    if S.Text[S.Pos] = '\' then
    begin
      Inc(S.Pos, 2);
      continue;
    end;
    if S.Text[S.Pos] = '"' then
    begin
      Inc(S.Pos);
      if PWebSdkJsonDecode(Copy(S.Text, start, S.Pos - start), Value) then
        Result := True
      else
        Fail(S, psmEncoding, What);
      exit;
    end;
    Inc(S.Pos);
  end;
  Fail(S, psmMalformed, What);
end;

function Num(var S: TScan; out Value: Int64; const What: RawUtf8): Boolean;
var
  start: PtrInt;
  digits: RawUtf8;
begin
  Value := 0;
  Result := False;
  Ws(S);
  start := S.Pos;
  while (S.Pos <= Length(S.Text)) and
        (S.Text[S.Pos] in ['0' .. '9']) do
    Inc(S.Pos);
  if S.Pos = start then
  begin
    Fail(S, psmMalformed, What);
    exit;
  end;
  digits := Copy(S.Text, start, S.Pos - start);
  // a leading zero is not a canonical integer, and eighteen digits is more
  // than any byte length this product can produce
  if ((Length(digits) > 1) and (digits[1] = '0')) or
     (Length(digits) > 18) then
  begin
    Fail(S, psmValue, What);
    exit;
  end;
  Value := StrToInt64Def(string(digits), -1);
  Result := Value >= 0;
  if not Result then
    Fail(S, psmValue, What);
end;

// `"<name>":` in the ratified position; the ORDER is part of the canonical
// form, so a key out of place is a malformed document rather than a
// tolerated variant
function Key(var S: TScan; const Name: RawUtf8): Boolean;
var
  got: RawUtf8;
begin
  Result := Lit(S, got, Name) and
            (got = Name) and
            Ch(S, ':', Name);
  if not Result then
    Fail(S, psmMalformed, Name);
end;

function ValidDigest(const Value: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if Length(Value) <> 64 then
    exit;
  for i := 1 to 64 do
    if not (Value[i] in ['0' .. '9', 'a' .. 'f']) then
      exit;
  Result := True;
end;

// a logical path: forward slashes, relative, no empty, '.' or '..' segment,
// no backslash and no control byte. The same fail-closed shape the asset
// store and the tar writer demand, restated for the one place that reads a
// path out of a document
function ValidLogicalPath(const Value: RawUtf8): Boolean;
var
  i, segStart: PtrInt;
  seg: RawUtf8;
begin
  Result := False;
  if (Value = '') or
     (Value[1] = '/') or
     (Value[Length(Value)] = '/') then
    exit;
  for i := 1 to Length(Value) do
    if (Value[i] = '\') or
       (Value[i] < ' ') then
      exit;
  segStart := 1;
  for i := 1 to Length(Value) + 1 do
    if (i > Length(Value)) or
       (Value[i] = '/') then
    begin
      seg := Copy(Value, segStart, i - segStart);
      if (seg = '') or
         (seg = '.') or
         (seg = '..') then
        exit;
      segStart := i + 1;
    end;
  Result := True;
end;

function PWebSdkParse(const Text: RawUtf8; out Manifest: TPWebSdkManifest;
  out Refusal: TPWebSdkManifestRefusal; out Detail: RawUtf8): Boolean;
var
  s: TScan;
  n: Int64;
  value: RawUtf8;
  i, count: PtrInt;
  more: Boolean;
begin
  Manifest := Default(TPWebSdkManifest);
  s.Text := Text;
  s.Pos := 1;
  s.Refusal := psmNone;
  s.Detail := '';
  Result := False;

  if not Ch(s, '{', 'document') then
  begin
    Refusal := s.Refusal;
    Detail := s.Detail;
    exit;
  end;

  if Key(s, 'schema') and Num(s, n, 'schema') then
    Manifest.Schema := Integer(n);
  Punct(s, ',', 'schema');
  if Key(s, 'pweb') and Lit(s, value, 'pweb') then
    Manifest.PWebVersion := value;
  Punct(s, ',', 'pweb');
  if Key(s, 'protocol') and Num(s, n, 'protocol') then
    Manifest.Protocol := Integer(n);
  Punct(s, ',', 'protocol');
  if Key(s, 'target') and Lit(s, value, 'target') then
    Manifest.Target := value;
  Punct(s, ',', 'target');

  if Key(s, 'templates') and Ch(s, '{', 'templates') then
  begin
    if Key(s, 'pack') and Lit(s, value, 'templates.pack') then
      Manifest.TemplatePack := value;
    Punct(s, ',', 'templates.pack');
    if Key(s, 'inventory') and Lit(s, value, 'templates.inventory') then
      Manifest.TemplateInventory := value;
    Punct(s, ',', 'templates.inventory');
    if Key(s, 'registry') and Lit(s, value, 'templates.registry') then
      Manifest.TemplateRegistry := value;
    Punct(s, '}', 'templates');
  end;
  Punct(s, ',', 'templates');

  // locks
  if Key(s, 'locks') and Ch(s, '[', 'locks') then
  begin
    Ws(s);
    more := (s.Pos <= Length(s.Text)) and (s.Text[s.Pos] <> ']');
    count := 0;
    while more and (s.Refusal = psmNone) do
    begin
      if not Ch(s, '{', 'locks') then
        break;
      SetLength(Manifest.Locks, count + 1);
      if Key(s, 'name') and Lit(s, value, 'locks.name') then
        Manifest.Locks[count].Name := value;
      Punct(s, ',', 'locks.name');
      if Key(s, 'sha256') and Lit(s, value, 'locks.sha256') then
        Manifest.Locks[count].Sha256 := value;
      Punct(s, '}', 'locks');
      Inc(count);
      Ws(s);
      more := (s.Pos <= Length(s.Text)) and (s.Text[s.Pos] = ',');
      if more then
        Inc(s.Pos);
    end;
    Punct(s, ']', 'locks');
  end;
  Punct(s, ',', 'locks');

  // licenses
  if Key(s, 'licenses') and Ch(s, '[', 'licenses') then
  begin
    Ws(s);
    more := (s.Pos <= Length(s.Text)) and (s.Text[s.Pos] <> ']');
    count := 0;
    while more and (s.Refusal = psmNone) do
    begin
      SetLength(Manifest.Licenses, count + 1);
      if Lit(s, value, 'licenses') then
        Manifest.Licenses[count] := value;
      Inc(count);
      Ws(s);
      more := (s.Pos <= Length(s.Text)) and (s.Text[s.Pos] = ',');
      if more then
        Inc(s.Pos);
    end;
    Punct(s, ']', 'licenses');
  end;
  Punct(s, ',', 'licenses');

  // files
  if Key(s, 'files') and Ch(s, '[', 'files') then
  begin
    Ws(s);
    more := (s.Pos <= Length(s.Text)) and (s.Text[s.Pos] <> ']');
    count := 0;
    while more and (s.Refusal = psmNone) do
    begin
      if count >= PWEB_SDK_MAX_FILES then
      begin
        Fail(s, psmTooManyFiles, IntText(count));
        break;
      end;
      if not Ch(s, '{', 'files') then
        break;
      SetLength(Manifest.Files, count + 1);
      if Key(s, 'path') and Lit(s, value, 'files.path') then
        Manifest.Files[count].Path := value;
      Punct(s, ',', 'files.path');
      if Key(s, 'bytes') and Num(s, n, 'files.bytes') then
        Manifest.Files[count].Bytes := n;
      Punct(s, ',', 'files.bytes');
      if Key(s, 'sha256') and Lit(s, value, 'files.sha256') then
        Manifest.Files[count].Sha256 := value;
      Punct(s, '}', 'files');
      Inc(count);
      Ws(s);
      more := (s.Pos <= Length(s.Text)) and (s.Text[s.Pos] = ',');
      if more then
        Inc(s.Pos);
    end;
    Punct(s, ']', 'files');
  end;
  Punct(s, '}', 'document');
  Ws(s);
  if (s.Refusal = psmNone) and
     (s.Pos <= Length(s.Text)) then
    Fail(s, psmMalformed, 'trailing');

  // the value rules, once the shape is known
  if s.Refusal = psmNone then
  begin
    if Manifest.PWebVersion = '' then
      Fail(s, psmValue, 'pweb');
    if Manifest.Target = '' then
      Fail(s, psmValue, 'target');
    if not ValidDigest(Manifest.TemplatePack) then
      Fail(s, psmValue, 'templates.pack');
    if not ValidDigest(Manifest.TemplateInventory) then
      Fail(s, psmValue, 'templates.inventory');
    if not ValidDigest(Manifest.TemplateRegistry) then
      Fail(s, psmValue, 'templates.registry');
    for i := 0 to High(Manifest.Locks) do
    begin
      if Manifest.Locks[i].Name = '' then
        Fail(s, psmValue, 'locks.name');
      if not ValidDigest(Manifest.Locks[i].Sha256) then
        Fail(s, psmValue, 'locks.sha256');
      if (i > 0) and
         (CompareStr(Manifest.Locks[i - 1].Name, Manifest.Locks[i].Name) >= 0) then
        Fail(s, psmValue, 'locks.order');
    end;
    for i := 0 to High(Manifest.Licenses) do
    begin
      if not ValidLogicalPath(Manifest.Licenses[i]) then
        Fail(s, psmValue, 'licenses');
      if (i > 0) and
         (CompareStr(Manifest.Licenses[i - 1], Manifest.Licenses[i]) >= 0) then
        Fail(s, psmValue, 'licenses.order');
    end;
    if Length(Manifest.Files) = 0 then
      Fail(s, psmValue, 'files');
    for i := 0 to High(Manifest.Files) do
    begin
      if not ValidLogicalPath(Manifest.Files[i].Path) then
        Fail(s, psmValue, 'files.path');
      if not ValidDigest(Manifest.Files[i].Sha256) then
        Fail(s, psmValue, 'files.sha256');
      // bytewise ascending, strictly: the order IS the inventory digest,
      // and a duplicate would let one path carry two verdicts
      if (i > 0) and
         (CompareStr(Manifest.Files[i - 1].Path, Manifest.Files[i].Path) >= 0) then
        Fail(s, psmValue, 'files.order');
    end;
  end;

  Refusal := s.Refusal;
  Detail := s.Detail;
  Result := Refusal = psmNone;
end;

{ ---------------------------------------------------------------------------
  the verifier
  --------------------------------------------------------------------------- }

// walk a LOGICAL path from Root one component at a time, so a reparse point
// anywhere along it refuses instead of redirecting a digest
function WalkLogical(const Root, Logical: RawUtf8; out Full: RawUtf8): Boolean;
var
  i, segStart: PtrInt;
  seg, cur: RawUtf8;
  last: Boolean;
begin
  Full := '';
  Result := False;
  cur := Root;
  segStart := 1;
  for i := 1 to Length(Logical) + 1 do
    if (i > Length(Logical)) or
       (Logical[i] = '/') then
    begin
      seg := Copy(Logical, segStart, i - segStart);
      last := i > Length(Logical);
      if last then
      begin
        if PWebCliEntry(cur, seg) <> pcnFile then
          exit;
      end
      else if PWebCliEntry(cur, seg) <> pcnDirectory then
        exit;
      cur := PWebCliJoin(cur, seg);
      segStart := i + 1;
    end;
  Full := cur;
  Result := True;
end;

function Contains(const List: TRawUtf8DynArray;
  const Item: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := True;
  for i := 0 to High(List) do
    if List[i] = Item then
      exit;
  Result := False;
end;

function PWebCliSdkVerifyIn(const Root,
  ExpectVersion: RawUtf8): TPWebCliSdkFact;
var
  share, tree, path, text, full, want: RawUtf8;
  content: RawByteString;
  tooBig: Boolean;
  manifest: TPWebSdkManifest;
  refusal: TPWebSdkManifestRefusal;
  detail: RawUtf8;
  i: PtrInt;
  started: TDateTime;
  paths: TRawUtf8DynArray;
begin
  Result := Default(TPWebCliSdkFact);
  Result.Root := Root;
  Result.Manifest := psmAbsent;
  Result.Integrity := psmAbsent;
  Result.Version := psmAbsent;
  if Root = '' then
  begin
    Result.Manifest := psmRootUnresolved;
    Result.Integrity := psmRootUnresolved;
    Result.Version := psmRootUnresolved;
    exit;
  end;
  // share/pweb, walked - the same two steps pweb.cli.sdk takes
  if PWebCliEntry(Root, PWEB_SDK_SHARE) <> pcnDirectory then
    exit;
  share := PWebCliJoin(Root, PWEB_SDK_SHARE);
  if PWebCliEntry(share, PWEB_SDK_SHARE_PWEB) <> pcnDirectory then
    exit;
  tree := PWebCliJoin(share, PWEB_SDK_SHARE_PWEB);
  if PWebCliEntry(tree, PWEB_SDK_MANIFEST) <> pcnFile then
    exit; // an UNPACKAGED root: not a failure, and not a claim either
  Result.Present := True;
  path := PWebCliJoin(tree, PWEB_SDK_MANIFEST);
  started := Now;

  if not PWebCliReadSmallFile(path, PWEB_SDK_MANIFEST_MAX_BYTES, content,
       tooBig) then
  begin
    Result.Manifest := psmUnreadable;
    Result.Integrity := psmUnreadable;
    Result.Version := psmUnreadable;
    Result.Detail := PWEB_SDK_MANIFEST;
    exit;
  end;
  text := RawUtf8(content);
  if not PWebSdkParse(text, manifest, refusal, detail) then
  begin
    Result.Manifest := refusal;
    Result.Integrity := refusal;
    Result.Version := refusal;
    Result.Detail := detail;
    exit;
  end;
  Result.Schema := manifest.Schema;
  Result.PWebVersion := manifest.PWebVersion;
  Result.Target := manifest.Target;
  Result.Declared := Length(manifest.Files);
  Result.Licenses := Length(manifest.Licenses);
  Result.Locks := Length(manifest.Locks);
  // CANONICAL BY COMPARISON, not by belief: the document is re-emitted from
  // what was parsed and required to equal the bytes on disk. So "canonical
  // form" is a property this verifier measures rather than a rule the
  // writer is trusted to have followed
  if PWebSdkManifestText(manifest) <> text then
  begin
    Result.Manifest := psmNoncanonical;
    Result.Integrity := psmNoncanonical;
    Result.Version := psmNoncanonical;
    Result.Detail := PWEB_SDK_MANIFEST;
    exit;
  end;
  if manifest.Schema <> PWEB_SDK_MANIFEST_SCHEMA then
  begin
    Result.Manifest := psmSchema;
    Result.Integrity := psmSchema;
    Result.Version := psmSchema;
    Result.Detail := IntText(manifest.Schema);
    exit;
  end;
  Result.Manifest := psmNone;

  // the version is its own row: an SDK whose manifest describes a different
  // release is a mixed installation, and that is a different problem from a
  // byte that changed
  if (ExpectVersion <> '') and
     (manifest.PWebVersion <> ExpectVersion) then
  begin
    Result.Version := psmVersionMismatch;
    Result.Detail := manifest.PWebVersion;
  end
  else
    Result.Version := psmNone;

  // FULL verification: every declared file, its length, then its digest
  Result.Integrity := psmNone;
  SetLength(paths, Length(manifest.Files));
  for i := 0 to High(manifest.Files) do
  begin
    paths[i] := manifest.Files[i].Path;
    if not WalkLogical(Root, manifest.Files[i].Path, full) then
    begin
      Result.Integrity := psmFileMissing;
      Result.Detail := manifest.Files[i].Path;
      break;
    end;
    if not PWebCliReadSmallFile(full, PWEB_SDK_MAX_FILE_BYTES, content,
         tooBig) then
    begin
      Result.Integrity := psmFileMissing;
      Result.Detail := manifest.Files[i].Path;
      break;
    end;
    if Length(content) <> manifest.Files[i].Bytes then
    begin
      Result.Integrity := psmFileBytes;
      Result.Detail := manifest.Files[i].Path;
      break;
    end;
    if LowerCaseU(Sha256(content)) <> manifest.Files[i].Sha256 then
    begin
      Result.Integrity := psmFileDigest;
      Result.Detail := manifest.Files[i].Path;
      break;
    end;
    Inc(Result.Verified);
  end;
  // every declared licence has to be one of the declared files, so the
  // licence set is covered by the same digests as everything else
  if Result.Integrity = psmNone then
    for i := 0 to High(manifest.Licenses) do
    begin
      want := PWEB_SDK_SHARE + '/' + PWEB_SDK_SHARE_PWEB + '/' +
        PWEB_SDK_LICENSES + '/' + manifest.Licenses[i];
      if not Contains(paths, want) then
      begin
        Result.Integrity := psmLicenseMissing;
        Result.Detail := manifest.Licenses[i];
        break;
      end;
    end;
  Result.ElapsedMs := Round((Now - started) * 24 * 60 * 60 * 1000);
  if Result.ElapsedMs < 0 then
    Result.ElapsedMs := 0;
end;

function PWebCliSdkVerify(const ExpectVersion: RawUtf8): TPWebCliSdkFact;
var
  root: RawUtf8;
  refusal: TPWebSdkRefusal;
begin
  if not PWebCliSdkRoot(root, refusal) then
  begin
    Result := Default(TPWebCliSdkFact);
    Result.Manifest := psmRootUnresolved;
    Result.Integrity := psmRootUnresolved;
    Result.Version := psmRootUnresolved;
    Result.Detail := PWebSdkRefusalText(refusal);
    exit;
  end;
  Result := PWebCliSdkVerifyIn(root, ExpectVersion);
end;

function PWebCliSdkFactAccepted(const Fact: TPWebCliSdkFact): Boolean;
begin
  // an ABSENT manifest accepts: this repository's own staged SDK root has
  // none, and neither does any tree a developer assembled by hand. What is
  // NOT accepted is a manifest that is present and wrong
  Result := (Fact.Manifest in [psmNone, psmAbsent]) and
            (Fact.Integrity in [psmNone, psmAbsent]) and
            (Fact.Version in [psmNone, psmAbsent]);
end;

function PWebCliSdkFactCause(const Fact: TPWebCliSdkFact): RawUtf8;
begin
  Result := '';
  if PWebCliSdkFactAccepted(Fact) then
    exit;
  // integrity first: a byte that changed is the most specific thing that
  // can be said about an installation, and it is the one a reader acts on
  if not (Fact.Integrity in [psmNone, psmAbsent]) then
    Result := PWebSdkRefusalTextM(Fact.Integrity)
  else if not (Fact.Manifest in [psmNone, psmAbsent]) then
    Result := PWebSdkRefusalTextM(Fact.Manifest)
  else
    Result := PWebSdkRefusalTextM(Fact.Version);
end;

end.
