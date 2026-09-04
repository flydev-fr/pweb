{
  pweb.test.sdk - the CAP-10D2 suite over the SDK distribution's integrity
  model (mormot.core.test).

  Three subjects, one file, all four targets:

    CANONICAL   the ONE JSON string rule the whole distribution uses,
                measured class by class against a reference table taken
                from ECMAScript's JSON.stringify. This is deferred item
                C1-11 (c): before CAP-10D2 the TypeScript-SDK re-emitter
                copied its input's SOURCE BYTES, which agrees with
                JSON.stringify only while the input carries no redundant
                escape. Every escape class is here, and so is every form
                the rule REFUSES rather than repairs.

    MANIFEST    the document: emit, parse, re-emit byte-identically; and
                every way a manifest can be wrong, each with its own
                machine-stable cause.

    VERIFY      the verifier over a fixture SDK root this suite builds:
                unpackaged, pristine, one byte altered, one byte added,
                one file removed, a manifest that is truncated, of the
                wrong schema, of the wrong version, or merely
                non-canonical - and a licence declared but not shipped.

  WHY THESE ARE HEADLESS AND STILL REAL. Not one of them needs a compiler, a
  display, a network or a pinned artifact: the escape rule and the document
  are pure functions, and the verifier reads a tree of a dozen small files
  this suite writes. That is what lets a Linux runner assert the whole
  integrity model and what makes the four-target sdk_digest a fact about the
  RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real packager over the real
  staged SDK root, the real archive, the real extraction onto a clean
  machine, the real `pweb doctor` rows, the real build refusal at exit 4 and
  the real 42. Those need real tools and a real runner, and a suite that
  pretended to have them would be the vacuous measurement this repository
  refuses.

  It emits build/cap10d2/sdk-corpus.txt: every DECISION this suite made, one
  LF line each, hashed into sdk_digest and required equal on four targets.
  Anything legitimately platform-shaped goes to
  build/cap10d2/sdk-observed.txt as key=value and is recorded per target,
  never compared.
}

{$I mormot.defines.inc}

unit pweb.test.sdk;

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.test,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.sdk,
  pweb.cli.stage,
  pweb.cli.sdkmanifest;

type
  TTestPWebSdkCanonical = class(TSynTestCase)
  published
    procedure EveryEscapeClassEqualsTheReference;
    procedure ARedundantEscapeIsNormalised;
    procedure TheRuleRefusesRatherThanRepairs;
    procedure CanonicalIsIdempotent;
    procedure TheTypeScriptReEmitterUsesTheSameRule;
  end;

  TTestPWebSdkManifest = class(TSynTestCase)
  published
    procedure AManifestRoundTripsByteIdentically;
    procedure TheInventoryDigestIsAPureFunctionOfTheList;
    procedure EveryMalformedShapeHasItsOwnCause;
    procedure TheOrderIsPartOfTheDocument;
  end;

  TTestPWebSdkVerify = class(TSynTestCase)
  published
    procedure AnUnpackagedRootIsAcceptedAndSaysSo;
    procedure APristineRootVerifiesEveryFile;
    procedure OneAlteredByteIsAMismatch;
    procedure OneAddedByteIsALengthRefusal;
    procedure OneRemovedFileIsMissing;
    procedure AWrongManifestHasItsOwnCauseEach;
    procedure ADeclaredLicenceMustBeShipped;
  end;

const
  PWEB_CAP10D2_CORPUS_FILE = 'build/cap10d2/sdk-corpus.txt';
  PWEB_CAP10D2_OBSERVED_FILE = 'build/cap10d2/sdk-observed.txt';
  PWEB_CAP10D2_FIXTURE = 'build/cap10d2/fixture';

/// write both evidence files
procedure PWebCap10d2Flush;


implementation

var
  Corpus: TRawUtf8DynArray;
  Observed: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

procedure Observe(const Key, Value: RawUtf8);
begin
  SetLength(Observed, Length(Observed) + 1);
  Observed[High(Observed)] := Key + '=' + Value;
end;

procedure PWebCap10d2Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10D2 SDK distribution decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10D2_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10D2_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10D2_OBSERVED_FILE);
end;

function Bool(B: Boolean): RawUtf8;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

// a printable projection of arbitrary bytes, so a corpus line is comparable
// across four targets and readable in a log
function Hexed(const S: RawUtf8): RawUtf8;
const
  HEXC: array[0 .. 15] of AnsiChar = '0123456789abcdef';
var
  i: PtrInt;
begin
  Result := '';
  for i := 1 to Length(S) do
    Result := Result + HEXC[Byte(S[i]) shr 4] + HEXC[Byte(S[i]) and $F];
end;


{ ---------------------------------------------------------------------------
  CANONICAL - the one escape rule
  --------------------------------------------------------------------------- }

// a run of one character, as RawUtf8 - the digests below are fixtures, not
// measurements, and spelling them as 64 literal characters would hide what
// they are
function Rep(C: AnsiChar; N: Integer): RawUtf8;
var
  i: PtrInt;
begin
  SetLength(Result, N);
  for i := 1 to N do
    Result[i] := C;
end;

{ THE REFERENCE below is `JSON.stringify(value)` in Node, class by class.
  Pascal has no backslash escape, so every expectation is exactly the bytes
  the file carries: '"a\nb"' really is the six characters " a \ n b ". }
procedure TTestPWebSdkCanonical.EveryEscapeClassEqualsTheReference;

  procedure One(const Name, Value, Expect: RawUtf8);
  var
    got, back: RawUtf8;
  begin
    Check(PWebSdkJsonEncode(Value, got),
      'encode ' + string(Name));
    CheckEqual(got, Expect, 'literal ' + string(Name));
    Check(PWebSdkJsonDecode(Expect, back), 'decode ' + string(Name));
    CheckEqual(back, Value, 'round trip ' + string(Name));
    Record_('escape|' + Name + '|' + Hexed(Value) + '|' + Hexed(got));
  end;

begin
  One('plain', 'abc', '"abc"');
  One('empty', '', '""');
  One('quote', 'a"b', '"a\"b"');
  One('backslash', 'a' + #92 + 'b', '"a' + #92 + #92 + 'b"');
  // the solidus is NOT escaped: JSON permits \/ and JSON.stringify never
  // emits it, so a canonicalizer that did would differ from the reference
  One('solidus', 'a/b', '"a/b"');
  One('backspace', 'a' + #8 + 'b', '"a\bb"');
  One('tab', 'a' + #9 + 'b', '"a\tb"');
  One('newline', 'a' + #10 + 'b', '"a\nb"');
  One('formfeed', 'a' + #12 + 'b', '"a\fb"');
  One('carriagereturn', 'a' + #13 + 'b', '"a\rb"');
  // every other C0 byte is \u00xx with LOWERCASE hex
  One('nul', 'a' + #0 + 'b', '"a' + #92 + 'u0000b"');
  One('soh', 'a' + #1 + 'b', '"a' + #92 + 'u0001b"');
  One('vt', 'a' + #11 + 'b', '"a' + #92 + 'u000bb"');
  One('esc', 'a' + #27 + 'b', '"a' + #92 + 'u001bb"');
  One('unitsep', 'a' + #31 + 'b', '"a' + #92 + 'u001fb"');
  // DEL is NOT a C0 byte and is not escaped
  One('del', 'a' + #127 + 'b', '"a' + #127 + 'b"');
  // non-ASCII is literal UTF-8, never \u
  One('latin1', 'caf' + #$C3 + #$A9, '"caf' + #$C3 + #$A9 + '"');
  One('cjk', #$E6 + #$97 + #$A5 + #$E6 + #$9C + #$AC,
    '"' + #$E6 + #$97 + #$A5 + #$E6 + #$9C + #$AC + '"');
  One('astral', 'a' + #$F0 + #$9F + #$98 + #$80 + 'b',
    '"a' + #$F0 + #$9F + #$98 + #$80 + 'b"');
  Record_('escape_classes|19');
end;

procedure TTestPWebSdkCanonical.ARedundantEscapeIsNormalised;

  procedure One(const Name, Literal, Expect: RawUtf8);
  var
    got: RawUtf8;
  begin
    Check(PWebSdkJsonCanonical(Literal, got), 'canonical ' + string(Name));
    CheckEqual(got, Expect, 'normalised ' + string(Name));
    Record_('normalise|' + Name + '|' + Hexed(Literal) + '|' + Hexed(got));
  end;

begin
  // THIS is the defect C1-11 (c) named: each of these is legal JSON that a
  // source-byte copy would have re-emitted unchanged, and that
  // JSON.stringify re-emits in its shortest form
  One('escaped_ascii', '"' + #92 + 'u0041"', '"A"');
  One('escaped_solidus', '"' + #92 + '/"', '"/"');
  One('escaped_latin1', '"' + #92 + 'u00e9"', '"' + #$C3 + #$A9 + '"');
  One('escaped_uppercase_hex', '"' + #92 + 'u00E9"', '"' + #$C3 + #$A9 + '"');
  One('escaped_tab', '"' + #92 + 'u0009"', '"\t"');
  One('escaped_quote_long', '"' + #92 + 'u0022"', '"\""');
  One('surrogate_pair', '"' + #92 + 'ud83d' + #92 + 'ude00"',
    '"' + #$F0 + #$9F + #$98 + #$80 + '"');
  One('already_canonical', '"a\nb"', '"a\nb"');
  Record_('normalise_classes|8');
end;

procedure TTestPWebSdkCanonical.TheRuleRefusesRatherThanRepairs;

  procedure Refused(const Name, Literal: RawUtf8);
  var
    got: RawUtf8;
  begin
    Check(not PWebSdkJsonCanonical(Literal, got),
      'refused ' + string(Name));
    CheckEqual(got, '', 'no partial output for ' + string(Name));
    Record_('escape_refused|' + Name);
  end;

  procedure EncodeRefused(const Name, Value: RawUtf8);
  var
    got: RawUtf8;
  begin
    Check(not PWebSdkJsonEncode(Value, got), 'encode refused ' +
      string(Name));
    Record_('encode_refused|' + Name);
  end;

begin
  Refused('unterminated', '"abc');
  Refused('not_a_literal', 'abc');
  Refused('unknown_escape', '"a' + #92 + 'xb"');
  Refused('short_unicode', '"' + #92 + 'u00"');
  Refused('bad_hex', '"' + #92 + 'u00zz"');
  Refused('lone_high_surrogate', '"' + #92 + 'ud83d"');
  Refused('lone_low_surrogate', '"' + #92 + 'ude00"');
  Refused('high_then_plain', '"' + #92 + 'ud83dA"');
  // a raw control byte inside a string is not legal JSON, and a
  // canonicalizer that quietly escaped it would be accepting a document no
  // reader agrees with
  Refused('raw_control', '"a' + #1 + 'b"');
  Refused('embedded_quote', '"a"b"');
  // the ENCODER refuses what has no canonical form at all
  EncodeRefused('lone_continuation', 'a' + #$80 + 'b');
  EncodeRefused('truncated_sequence', 'a' + #$C3);
  EncodeRefused('overlong', 'a' + #$C0 + #$AF + 'b');
  EncodeRefused('surrogate_in_utf8', 'a' + #$ED + #$A0 + #$80 + 'b');
  EncodeRefused('five_byte_form', 'a' + #$F8 + #$88 + #$80 + #$80 + #$80);
  Record_('escape_refusals|15');
end;

procedure TTestPWebSdkCanonical.CanonicalIsIdempotent;
var
  once, twice: RawUtf8;
  i: PtrInt;
const
  INPUTS: array[0 .. 4] of RawUtf8 = (
    '"a"', '"a\nb"', '"' + #92 + 'u0041"', '"' + #92 + '/"',
    '"' + #92 + 'ud83d' + #92 + 'ude00"');
begin
  for i := 0 to High(INPUTS) do
  begin
    Check(PWebSdkJsonCanonical(INPUTS[i], once), 'first pass');
    Check(PWebSdkJsonCanonical(once, twice), 'second pass');
    CheckEqual(twice, once, 'canonical of canonical is canonical');
  end;
  Record_('canonical_idempotent|true');
end;

procedure TTestPWebSdkCanonical.TheTypeScriptReEmitterUsesTheSameRule;
var
  canonical: RawUtf8;
  refusal: TPWebCliStageRefusal;
  dev: RawUtf8;
begin
  // the CAP-10C1 re-emitter, over a development manifest whose values carry
  // exactly the escapes a source-byte copy would have passed through. The
  // expected output is what `JSON.stringify(canonical, null, 2)` produces
  dev := '{' + #10 +
    '  "name": "' + #92 + 'u0040pweb/runtime",' + #10 +
    '  "version": "0.1.0",' + #10 +
    '  "license": "MIT",' + #10 +
    '  "type": "module",' + #10 +
    '  "main": ".' + #92 + '/dist/src/index.js",' + #10 +
    '  "types": "./dist/src/index.d.ts",' + #10 +
    '  "exports": {' + #10 +
    '    ".": {' + #10 +
    '      "types": "./dist/src/index.d.ts",' + #10 +
    '      "default": "./dist/src/index.js"' + #10 +
    '    }' + #10 +
    '  },' + #10 +
    '  "devDependencies": { "typescript": "7.0.2" }' + #10 +
    '}' + #10;
  Check(PWebCliSdkManifest(dev, canonical, refusal),
    'the re-emitter accepted the development manifest');
  CheckEqual(PWebCliStageRefusalText(refusal), 'ok', 'no refusal');
  CheckEqual(canonical,
    '{' + #10 +
    '  "name": "@pweb/runtime",' + #10 +
    '  "version": "0.1.0",' + #10 +
    '  "license": "MIT",' + #10 +
    '  "type": "module",' + #10 +
    '  "main": "./dist/src/index.js",' + #10 +
    '  "types": "./dist/src/index.d.ts",' + #10 +
    '  "exports": {' + #10 +
    '    ".": {' + #10 +
    '      "types": "./dist/src/index.d.ts",' + #10 +
    '      "default": "./dist/src/index.js"' + #10 +
    '    }' + #10 +
    '  }' + #10 +
    '}' + #10,
    'C1-11 (c): the re-emitter normalises escapes rather than copying bytes');
  Record_('c1_11_c_reemitter_canonical|true');
  // and a value it cannot decode is a REFUSAL, not a guess
  dev := '{"name": "' + #92 + 'ud800", "version": "1.0.0", "license": "MIT",' +
    ' "type": "module", "main": "a", "types": "b", "exports": {}}';
  Check(not PWebCliSdkManifest(dev, canonical, refusal),
    'a lone surrogate is refused by the re-emitter');
  Record_('c1_11_c_reemitter_refuses_undecodable|true');
end;


{ ---------------------------------------------------------------------------
  MANIFEST - the document
  --------------------------------------------------------------------------- }

function SampleManifest: TPWebSdkManifest;
begin
  Result := Default(TPWebSdkManifest);
  Result.Schema := PWEB_SDK_MANIFEST_SCHEMA;
  Result.PWebVersion := '0.1.0';
  Result.Protocol := 1;
  Result.Target := 'linux-x86_64';
  Result.TemplatePack := Rep('a', 64);
  Result.TemplateInventory := Rep('b', 64);
  Result.TemplateRegistry := Rep('c', 64);
  SetLength(Result.Locks, 2);
  Result.Locks[0].Name := 'fpc.lock';
  Result.Locks[0].Sha256 := Rep('1', 64);
  Result.Locks[1].Name := 'mormot.lock';
  Result.Locks[1].Sha256 := Rep('2', 64);
  SetLength(Result.Licenses, 1);
  Result.Licenses[0] := 'LICENSE.mormot2.md';
  SetLength(Result.Files, 2);
  Result.Files[0].Path := 'bin/pweb';
  Result.Files[0].Bytes := 3;
  Result.Files[0].Sha256 := Rep('d', 64);
  Result.Files[1].Path := 'share/pweb/licenses/LICENSE.mormot2.md';
  Result.Files[1].Bytes := 5;
  Result.Files[1].Sha256 := Rep('e', 64);
end;

procedure TTestPWebSdkManifest.AManifestRoundTripsByteIdentically;
var
  m, back: TPWebSdkManifest;
  text, again, detail: RawUtf8;
  refusal: TPWebSdkManifestRefusal;
begin
  m := SampleManifest;
  text := PWebSdkManifestText(m);
  Check(text <> '', 'the document was emitted');
  CheckEqual(Copy(text, 1, 2), '{' + #10, 'it opens canonically');
  CheckEqual(Copy(text, Length(text) - 1, 2), '}' + #10,
    'exactly one trailing newline after the closing brace');
  Check(Pos(#13, text) = 0, 'LF only, on every platform');
  Check(PWebSdkParse(text, back, refusal, detail),
    'the canonical document parses: ' + string(detail));
  again := PWebSdkManifestText(back);
  CheckEqual(again, text, 'emit(parse(emit(m))) = emit(m)');
  CheckEqual(back.Schema, m.Schema);
  CheckEqual(back.Target, m.Target);
  CheckEqual(Length(back.Files), 2);
  CheckEqual(back.Files[1].Bytes, 5);
  Record_('manifest_round_trip|true');
  Record_('manifest_schema|' + RawUtf8(IntToStr(PWEB_SDK_MANIFEST_SCHEMA)));
  Record_('manifest_shape|' + LowerCaseU(Sha256(text)));
end;

procedure TTestPWebSdkManifest.TheInventoryDigestIsAPureFunctionOfTheList;
var
  m: TPWebSdkManifest;
  a, b: RawUtf8;
begin
  m := SampleManifest;
  a := PWebSdkInventoryDigest(m.Files);
  b := PWebSdkInventoryDigest(m.Files);
  CheckEqual(a, b, 'the same list digests the same twice');
  CheckEqual(Length(a), 64, 'it is a sha256');
  m.Files[1].Bytes := 6;
  Check(PWebSdkInventoryDigest(m.Files) <> a,
    'a byte length is inside the digest');
  m := SampleManifest;
  m.Files[1].Sha256 := Rep('f', 64);
  Check(PWebSdkInventoryDigest(m.Files) <> a,
    'a content digest is inside the digest');
  m := SampleManifest;
  m.Files[1].Path := 'share/pweb/licenses/LICENSE.other.md';
  Check(PWebSdkInventoryDigest(m.Files) <> a, 'a path is inside the digest');
  Record_('inventory_digest_pure|true');
end;

procedure TTestPWebSdkManifest.EveryMalformedShapeHasItsOwnCause;
var
  m: TPWebSdkManifest;
  text, detail: RawUtf8;
  refusal: TPWebSdkManifestRefusal;

  procedure Refused(const Name, Doc: RawUtf8;
    Want: TPWebSdkManifestRefusal);
  var
    parsed: TPWebSdkManifest;
  begin
    Check(not PWebSdkParse(Doc, parsed, refusal, detail),
      'refused ' + string(Name));
    CheckEqual(PWebSdkRefusalTextM(refusal), PWebSdkRefusalTextM(Want),
      'cause of ' + string(Name));
    Record_('manifest_refusal|' + Name + '|' +
      PWebSdkRefusalTextM(refusal));
  end;

begin
  m := SampleManifest;
  text := PWebSdkManifestText(m);
  Refused('empty', '', psmMalformed);
  Refused('not_an_object', '[]', psmMalformed);
  Refused('truncated', Copy(text, 1, Length(text) div 2), psmMalformed);
  Refused('trailing_bytes', text + 'x', psmMalformed);
  Refused('missing_key',
    '{' + #10 + '  "pweb": "0.1.0"' + #10 + '}' + #10, psmMalformed);
  // a value rule, not a shape rule: the digests are fixed-width lowercase
  m := SampleManifest;
  m.TemplatePack := 'nothex';
  Refused('bad_pack_digest', PWebSdkManifestText(m), psmValue);
  m := SampleManifest;
  m.Files[0].Sha256 := Rep('A', 64);
  Refused('uppercase_digest', PWebSdkManifestText(m), psmValue);
  m := SampleManifest;
  m.Files[0].Path := '../escape';
  Refused('traversal_path', PWebSdkManifestText(m), psmValue);
  m := SampleManifest;
  m.Files[0].Path := '/absolute';
  Refused('absolute_path', PWebSdkManifestText(m), psmValue);
  m := SampleManifest;
  m.Files := nil;
  Refused('no_files', PWebSdkManifestText(m), psmValue);
end;

procedure TTestPWebSdkManifest.TheOrderIsPartOfTheDocument;
var
  m: TPWebSdkManifest;
  swap: TPWebSdkFile;
  parsed: TPWebSdkManifest;
  refusal: TPWebSdkManifestRefusal;
  detail: RawUtf8;
begin
  m := SampleManifest;
  swap := m.Files[0];
  m.Files[0] := m.Files[1];
  m.Files[1] := swap;
  Check(not PWebSdkParse(PWebSdkManifestText(m), parsed, refusal, detail),
    'a file list out of bytewise order is refused');
  CheckEqual(PWebSdkRefusalTextM(refusal), 'sdk_manifest_value');
  CheckEqual(detail, 'files.order');
  m := SampleManifest;
  m.Files[1] := m.Files[0];
  Check(not PWebSdkParse(PWebSdkManifestText(m), parsed, refusal, detail),
    'a duplicated path is refused');
  CheckEqual(detail, 'files.order');
  m := SampleManifest;

  m.Locks[0].Name := 'zzz.lock';
  Check(not PWebSdkParse(PWebSdkManifestText(m), parsed, refusal, detail),
    'a lock list out of order is refused');
  CheckEqual(detail, 'locks.order');
  Record_('manifest_order_is_content|true');
end;


{ ---------------------------------------------------------------------------
  VERIFY - the fixture SDK root
  --------------------------------------------------------------------------- }

type
  TFixture = record
    Root: RawUtf8;
    Manifest: TPWebSdkManifest;
  end;

// a minimal but REAL SDK-shaped tree: bin/, share/pweb/, a licence and a
// manifest the verifier walks exactly as it walks a shipped one
function BuildFixture(const Name: RawUtf8): TFixture;
var
  base, root, share, tree, bin, lic: RawUtf8;
  i: PtrInt;

  procedure Sub(const Parent, Child: RawUtf8; out Full: RawUtf8);
  begin
    Full := PWebCliJoin(Parent, Child);
    ForceDirectories(string(PWebCliDisplayPath(Full)));
  end;

  procedure Put(const Full, Content: RawUtf8);
  begin
    FileFromString(Content, string(PWebCliDisplayPath(Full)));
  end;

  procedure Declare(const Logical, Content: RawUtf8);
  begin
    i := Length(Result.Manifest.Files);
    SetLength(Result.Manifest.Files, i + 1);
    Result.Manifest.Files[i].Path := Logical;
    Result.Manifest.Files[i].Bytes := Length(Content);
    Result.Manifest.Files[i].Sha256 := LowerCaseU(Sha256(Content));
  end;

begin
  Result := Default(TFixture);
  base := PWEB_CAP10D2_FIXTURE;
  ForceDirectories(string(base));
  root := base + '/' + Name;
  // reclaimed rather than merged: a stale file surviving into a fixture is
  // the one failure a fixture must not have
  DirectoryDelete(string(root), '*', {DeleteOnlyFilesNotDirectory=}False);
  ForceDirectories(string(root));
  if not PWebCliCanonicalDir(RawUtf8(ExpandFileName(string(root))),
       Result.Root) then
  begin
    Result.Root := '';
    exit;
  end;
  root := Result.Root;
  Sub(root, 'bin', bin);
  Sub(root, PWEB_SDK_SHARE, share);
  Sub(share, PWEB_SDK_SHARE_PWEB, tree);
  Sub(tree, PWEB_SDK_LICENSES, lic);
  Put(PWebCliJoin(bin, 'pweb'), 'exe');
  Put(PWebCliJoin(tree, 'pweb-templates.zip'), 'PK-not-really');
  Put(PWebCliJoin(lic, 'LICENSE.mormot2.md'), 'tri-licence');

  Result.Manifest.Schema := PWEB_SDK_MANIFEST_SCHEMA;
  Result.Manifest.PWebVersion := '0.1.0';
  Result.Manifest.Protocol := 1;
  Result.Manifest.Target := 'fixture-target';
  Result.Manifest.TemplatePack := Rep('a', 64);
  Result.Manifest.TemplateInventory := Rep('b', 64);
  Result.Manifest.TemplateRegistry := Rep('c', 64);
  SetLength(Result.Manifest.Locks, 1);
  Result.Manifest.Locks[0].Name := 'fpc.lock';
  Result.Manifest.Locks[0].Sha256 := Rep('1', 64);
  SetLength(Result.Manifest.Licenses, 1);
  Result.Manifest.Licenses[0] := 'LICENSE.mormot2.md';
  // bytewise ascending, which is the order the document requires
  Declare('bin/pweb', 'exe');
  Declare('share/pweb/licenses/LICENSE.mormot2.md', 'tri-licence');
  Declare('share/pweb/pweb-templates.zip', 'PK-not-really');
end;

procedure WriteManifest(const F: TFixture; const Text: RawUtf8);
begin
  FileFromString(Text, string(PWebCliDisplayPath(
    PWebCliJoin(PWebCliJoin(PWebCliJoin(F.Root, PWEB_SDK_SHARE),
      PWEB_SDK_SHARE_PWEB), PWEB_SDK_MANIFEST))));
end;

function FixturePath(const F: TFixture; const Logical: RawUtf8): RawUtf8;
var
  i, start: PtrInt;
begin
  Result := F.Root;
  start := 1;
  for i := 1 to Length(Logical) + 1 do
    if (i > Length(Logical)) or
       (Logical[i] = '/') then
    begin
      Result := PWebCliJoin(Result, Copy(Logical, start, i - start));
      start := i + 1;
    end;
  Result := PWebCliDisplayPath(Result);
end;

procedure TTestPWebSdkVerify.AnUnpackagedRootIsAcceptedAndSaysSo;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
begin
  f := BuildFixture('unpackaged');
  Check(f.Root <> '', 'the fixture root canonicalized');
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  Check(not fact.Present, 'no manifest is present');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest), 'sdk_unpackaged');
  Check(PWebCliSdkFactAccepted(fact),
    'an unpackaged root does not refuse a build');
  CheckEqual(PWebCliSdkFactCause(fact), '', 'and carries no cause');
  Record_('verify_unpackaged_accepted|true');
end;

procedure TTestPWebSdkVerify.APristineRootVerifiesEveryFile;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
begin
  f := BuildFixture('pristine');
  WriteManifest(f, PWebSdkManifestText(f.Manifest));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  Check(fact.Present, 'the manifest is present');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest), 'ok');
  CheckEqual(PWebSdkRefusalTextM(fact.Integrity), 'ok');
  CheckEqual(PWebSdkRefusalTextM(fact.Version), 'ok');
  CheckEqual(fact.Declared, 3);
  CheckEqual(fact.Verified, 3);
  CheckEqual(fact.Licenses, 1);
  Check(PWebCliSdkFactAccepted(fact), 'a pristine root is accepted');
  Record_('verify_pristine_full|true');
  Observe('fixture_integrity_ms', RawUtf8(IntToStr(fact.ElapsedMs)));
end;

procedure TTestPWebSdkVerify.OneAlteredByteIsAMismatch;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
begin
  f := BuildFixture('altered');
  WriteManifest(f, PWebSdkManifestText(f.Manifest));
  // the SAME LENGTH, so only the digest can tell: this is the case a
  // length-only inventory would miss
  FileFromString('EXE', FixturePath(f, 'bin/pweb'));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest), 'ok',
    'the manifest itself is untouched');
  CheckEqual(PWebSdkRefusalTextM(fact.Integrity), 'sdk_integrity_mismatch');
  CheckEqual(fact.Detail, 'bin/pweb', 'the refusal names the file');
  Check(not PWebCliSdkFactAccepted(fact), 'a build is refused');
  CheckEqual(PWebCliSdkFactCause(fact), 'sdk_integrity_mismatch');
  Record_('verify_altered_byte|sdk_integrity_mismatch');
end;

procedure TTestPWebSdkVerify.OneAddedByteIsALengthRefusal;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
begin
  f := BuildFixture('grown');
  WriteManifest(f, PWebSdkManifestText(f.Manifest));
  FileFromString('exe!', FixturePath(f, 'bin/pweb'));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Integrity), 'sdk_integrity_bytes');
  CheckEqual(fact.Detail, 'bin/pweb');
  Record_('verify_added_byte|sdk_integrity_bytes');
end;

procedure TTestPWebSdkVerify.OneRemovedFileIsMissing;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
begin
  f := BuildFixture('halfcopied');
  WriteManifest(f, PWebSdkManifestText(f.Manifest));
  DeleteFile(string(FixturePath(f, 'share/pweb/pweb-templates.zip')));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Integrity), 'sdk_integrity_missing');
  CheckEqual(fact.Detail, 'share/pweb/pweb-templates.zip');
  Record_('verify_removed_file|sdk_integrity_missing');
end;

procedure TTestPWebSdkVerify.AWrongManifestHasItsOwnCauseEach;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
  m: TPWebSdkManifest;
  text: RawUtf8;
begin
  f := BuildFixture('wrongmanifest');

  WriteManifest(f, 'this is not JSON');
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest), 'sdk_manifest_malformed');
  Check(not PWebCliSdkFactAccepted(fact));
  Record_('verify_malformed_manifest|sdk_manifest_malformed');

  m := f.Manifest;
  m.Schema := 2;
  WriteManifest(f, PWebSdkManifestText(m));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest), 'sdk_manifest_schema');
  CheckEqual(fact.Detail, '2');
  Record_('verify_wrong_schema|sdk_manifest_schema');

  // valid JSON of the right shape, and NOT the canonical serialization of
  // itself: the writer is the only thing that may produce this document
  text := PWebSdkManifestText(f.Manifest);
  WriteManifest(f, ' ' + text);
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest),
    'sdk_manifest_noncanonical');
  Record_('verify_noncanonical|sdk_manifest_noncanonical');

  m := f.Manifest;
  m.PWebVersion := '9.9.9';
  WriteManifest(f, PWebSdkManifestText(m));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Manifest), 'ok',
    'the document is fine');
  CheckEqual(PWebSdkRefusalTextM(fact.Integrity), 'ok',
    'and so are the bytes');
  CheckEqual(PWebSdkRefusalTextM(fact.Version), 'sdk_version_mismatch');
  CheckEqual(fact.Detail, '9.9.9');
  Check(not PWebCliSdkFactAccepted(fact),
    'a mixed installation refuses a build');
  Record_('verify_version_mismatch|sdk_version_mismatch');
end;

procedure TTestPWebSdkVerify.ADeclaredLicenceMustBeShipped;
var
  f: TFixture;
  fact: TPWebCliSdkFact;
  m: TPWebSdkManifest;
begin
  f := BuildFixture('missinglicence');
  m := f.Manifest;
  SetLength(m.Licenses, 2);
  m.Licenses[0] := 'LICENSE.mormot2.md';
  m.Licenses[1] := 'LICENSE.webview.txt';
  WriteManifest(f, PWebSdkManifestText(m));
  fact := PWebCliSdkVerifyIn(f.Root, '0.1.0');
  CheckEqual(PWebSdkRefusalTextM(fact.Integrity), 'sdk_license_missing');
  CheckEqual(fact.Detail, 'LICENSE.webview.txt');
  Check(not PWebCliSdkFactAccepted(fact));
  Record_('verify_declared_licence_must_ship|sdk_license_missing');
  Record_('verify_cases|7');
end;

end.
