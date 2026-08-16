unit pweb.test.bundle;

{ mormot.core.test cases for CAP-6: the app.pwb release bundle.

  Headless coverage of the full bundler matrix (creation, required
  roots, determinism, ordering, nested/empty/binary assets, hostile
  paths, every collision class incl. the ratified D1 Unicode fold,
  reserved manifest, D2 threshold, D3 secret/exclusion classification,
  atomic failure with prior-output preservation, self-validation,
  TZipAssetStore reads of the output), the manifest compat matrix over
  parameter-injected protocol sets and runtime versions, tamper
  fixtures over crafted raw ZIP bytes (pweb.test.assets helpers), and
  the loader-refusal proofs: every refusal yields a nil store, so no
  bundle JS can ever have a source to execute from.

  The four D1-mandated cases live in UnicodeFoldPolicy:
    1. cafe/CAFE (e-acute) fold-equal   -> writer rejects
    2. distinct non-ASCII, no fold pair -> writer accepts + serves
    3. fold verdict pinned to expected BYTES (compiled-in Unicode 10.0
       tables; the same assertion runs locally and hosted, proving the
       verdict is machine-independent - no OS case API involved)
    4. hand-crafted ZIP bypassing the bundler -> TZipAssetStore (and
       therefore the loader) rejects the archive as a whole. }

{$I mormot.defines.inc}

interface

uses
  {$ifdef OSWINDOWS}
  windows,
  {$endif OSWINDOWS}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.test,
  mormot.core.zip,
  mormot.crypt.core,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.zip,
  pweb.assets.bundle,
  pweb.test.assets;

type
  /// CAP-6 release-bundle cases: manifest, semver, compat, writer,
  /// loader and tamper matrix - all headless
  TTestBundleSystem = class(TSynTestCase)
  protected
    fDir: TFileName; // temp working directory for bundle files
    function BundlePath(const AName: TFileName): TFileName;
    procedure Setup; override;
    procedure CleanUp; override;
  published
    /// strict X.Y.Z grammar and numeric (never lexicographic) ordering
    procedure SemVerGrammarAndOrdering;
    /// canonical manifest bytes and round-trip
    procedure ManifestCanonicalForm;
    /// strict parse: unknown fields inert, malformed refused
    procedure ManifestStrictParse;
    /// parameter-injected load predicate over every compat row
    procedure CompatPredicate;
    /// ratified D3 secret/dev/sourcemap classification by name only
    procedure NameClassification;
    /// happy path: write, reload via production loader + raw store,
    /// serve every byte, manifest served as an asset (D5)
    procedure WriterHappyPathAndServing;
    /// byte-identical archives across input permutation and rewrite
    procedure WriterDeterminism;
    /// output bytes pinned to a committed SHA-256: toolchain or
    /// dependency drift fails loudly instead of self-comparing green
    procedure WriterGoldenBytes;
    /// hostile names and every collision class fail before writing
    procedure WriterHostileAndCollisions;
    /// the four ratified D1 cases (bundler + store enforcement)
    procedure UnicodeFoldPolicy;
    /// D2 threshold and the reserved root manifest (D5)
    procedure WriterThresholdAndReserved;
    /// injected mid-build failure: temp removed, prior output intact
    procedure WriterAtomicFailure;
    /// loader compat matrix incl. crafted malformed manifests
    procedure LoaderCompatMatrix;
    /// tampered archives refuse with typed reasons and nil stores
    procedure LoaderTamperMatrix;
  end;

implementation

function BE(const AName: RawUtf8;
  const AContent: RawByteString): TPWebBundleEntry;
begin
  Result.Name := AName;
  Result.Content := AContent;
end;

function MkMan(AProtocol: Integer;
  const AMinRuntime: RawUtf8): TPWebBundleManifest;
begin
  Result.Protocol := AProtocol;
  Result.MinRuntime := AMinRuntime;
end;

function TrySerialize(const M: TPWebBundleManifest): Boolean;
begin
  Result := True;
  try
    PWebBundleManifestSerialize(M);
  except
    on EPWebBundle do
      Result := False;
  end;
end;

function BinaryBlob(Len: PtrInt): RawByteString;
var
  i: PtrInt;
begin
  SetLength(Result, Len);
  for i := 1 to Len do
    Result[i] := AnsiChar((i * 7) and 255); // NUL bytes included
end;

const
  INDEX_HTML: RawByteString =
    '<!doctype html><html><body>bundle</body></html>';
  CAFE_LOWER: RawUtf8 = 'caf'#$C3#$A9'.js';   // cafe + e-acute
  CAFE_UPPER: RawUtf8 = 'CAF'#$C3#$89'.js';   // CAFE + E-acute
  CAFE_FOLDED: RawUtf8 = 'CAF'#$C3#$89'.JS';  // pinned fold verdict
  NAIVE_LOWER: RawUtf8 = 'na'#$C3#$AF've.js'; // naive + i-diaeresis
  SIGMA_LOWER: RawUtf8 = #$CF#$83'.js';       // greek small sigma
  SIGMA_UPPER: RawUtf8 = #$CE#$A3'.js';       // greek capital sigma

function TTestBundleSystem.BundlePath(const AName: TFileName): TFileName;
begin
  Result := fDir + PathDelim + AName;
end;

procedure TTestBundleSystem.Setup;
begin
  fDir := GetTempDir + 'pweb-cap6-' + IntToStr(GetCurrentProcessId);
  RmTree(fDir);
  ForceDirectories(fDir);
end;

procedure TTestBundleSystem.CleanUp;
begin
  RmTree(fDir);
end;

procedure TTestBundleSystem.SemVerGrammarAndOrdering;
const
  GOOD: array[0..5] of RawUtf8 = (
    '0.0.0', '0.1.0', '1.2.3', '0.10.0', '10.20.30', '999999999.0.1');
  BAD: array[0..21] of RawUtf8 = (
    '', '1', '1.0', '1.0.0.0', '01.0.0', '1.02.0', '1.0.03',
    '1.0.0-rc1', '1.0.0+build5', 'v1.0.0', '1.0.0 ', ' 1.0.0',
    '1..0', '.1.0', '1.0.', 'a.b.c', '1.0.x', '1,0,0', '1.0.-1',
    '1.0.0'#10, '0.1.0'#0, '1234567890.0.0');
var
  i: PtrInt;
  major, minor, patch: Cardinal;
  diff: Integer;
begin
  for i := 0 to High(GOOD) do
    CheckUtf8(PWebSemVerValid(GOOD[i]), 'valid semver rejected: %',
      [GOOD[i]]);
  for i := 0 to High(BAD) do
    CheckUtf8(not PWebSemVerValid(BAD[i]), 'bad semver accepted: %',
      [BAD[i]]);
  Check(PWebSemVerParse('1.22.333', major, minor, patch) and
    (major = 1) and (minor = 22) and (patch = 333), 'parse components');
  // numeric ordering - the lexicographic trap rows are the point
  Check(PWebSemVerCompare('0.10.0', '0.9.0', diff) and (diff > 0),
    '0.10.0 must exceed 0.9.0 numerically');
  Check(PWebSemVerCompare('0.9.0', '0.10.0', diff) and (diff < 0));
  Check(PWebSemVerCompare('0.2.0', '0.10.0', diff) and (diff < 0),
    'lexicographic comparison leaked in');
  Check(PWebSemVerCompare('1.0.0', '1.0.0', diff) and (diff = 0));
  Check(PWebSemVerCompare('1.0.0', '0.99.99', diff) and (diff > 0));
  Check(PWebSemVerCompare('0.1.1', '0.1.0', diff) and (diff > 0));
  Check(PWebSemVerCompare('2.0.0', '10.0.0', diff) and (diff < 0));
  // fail closed on any malformed side
  Check(not PWebSemVerCompare('1.0', '1.0.0', diff), 'bad A accepted');
  Check(not PWebSemVerCompare('1.0.0', 'x', diff), 'bad B accepted');
end;

procedure TTestBundleSystem.ManifestCanonicalForm;
var
  m, back: TPWebBundleManifest;
  bytes: RawUtf8;
begin
  bytes := PWebBundleManifestSerialize(MkMan(1, '0.1.0'));
  CheckEqual(bytes, '{"pweb":{"protocol":1,"minRuntime":"0.1.0"}}',
    'canonical manifest bytes drifted');
  Check(PWebBundleManifestParse(bytes, back));
  CheckEqual(back.Protocol, 1);
  CheckEqual(back.MinRuntime, '0.1.0');
  bytes := PWebBundleManifestSerialize(MkMan(42, '10.20.30'));
  CheckEqual(bytes, '{"pweb":{"protocol":42,"minRuntime":"10.20.30"}}');
  Check(PWebBundleManifestParse(bytes, back));
  CheckEqual(back.Protocol, 42);
  CheckEqual(back.MinRuntime, '10.20.30');
  m := MkMan(0, '0.0.0');
  Check(PWebBundleManifestParse(PWebBundleManifestSerialize(m), back));
  CheckEqual(back.Protocol, 0);
  // direct API misuse can never emit malformed canonical bytes
  Check(not TrySerialize(MkMan(1, '1.0')),
    'serialize accepted invalid minRuntime');
  Check(not TrySerialize(MkMan(1, '1.0.0-rc1')),
    'serialize accepted suffixed minRuntime');
  Check(not TrySerialize(MkMan(-1, '0.1.0')),
    'serialize accepted negative protocol');
end;

procedure TTestBundleSystem.ManifestStrictParse;
const
  ACCEPT: array[0..4] of RawByteString = (
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0"}}',
    '{ "pweb" : { "protocol" : 1 , "minRuntime" : "0.1.0" } }',
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0","future":[1,{"y":"z\"q"}]},"more":null}',
    '{"pweb":{"minRuntime":"0.1.0","protocol":1},"num":-1.5e3,"t":true}',
    // capability-like fields are inert unknown members - nothing to
    // grant, nothing to enforce; the loader reads the pweb block only
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0","allow":["fs.read"],"capabilities":{"net":"all"},"permissions":"everything"}}');
  REJECT: array[0..23] of RawByteString = (
    '', 'not json', '{', '{}', '[]', '"pweb"', '42',
    '{"pweb":{}}',
    // integer overflow: above High(Integer), and above the scanner's
    // 10-digit bound - both refuse instead of wrapping
    '{"pweb":{"protocol":4294967297,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":99999999999,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":1}}',
    '{"pweb":{"minRuntime":"0.1.0"}}',
    '{"pweb":1}',
    '{"pweb":[{"protocol":1,"minRuntime":"0.1.0"}]}',
    '{"pweb":{"protocol":"1","minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":1.0,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":true,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":-1,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":1,"minRuntime":"0.1"}}',
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0-rc1"}}',
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0"}} trailing',
    '{"pweb":{"protocol":1,"protocol":1,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0"},"pweb":{"protocol":1,"minRuntime":"0.1.0"}}',
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0",}}');
var
  i: PtrInt;
  m: TPWebBundleManifest;
  deep: RawByteString;
begin
  for i := 0 to High(ACCEPT) do
  begin
    CheckUtf8(PWebBundleManifestParse(ACCEPT[i], m),
      'valid manifest refused: %', [ACCEPT[i]]);
    CheckEqual(m.Protocol, 1);
    CheckEqual(m.MinRuntime, '0.1.0');
  end;
  for i := 0 to High(REJECT) do
    CheckUtf8(not PWebBundleManifestParse(REJECT[i], m),
      'malformed manifest accepted: %', [REJECT[i]]);
  // structural abuse: unterminated string, bad escape, control byte
  Check(not PWebBundleManifestParse(
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0', m), 'unterminated');
  Check(not PWebBundleManifestParse(
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0","x":"\q"}}', m),
    'bad escape accepted');
  Check(not PWebBundleManifestParse(
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0","x":"a'#3'b"}}', m),
    'raw control byte accepted');
  // nesting bound on skipped unknown values
  deep := '{"pweb":{"protocol":1,"minRuntime":"0.1.0"},"d":';
  for i := 1 to 40 do
    deep := deep + '[';
  deep := deep + '1';
  for i := 1 to 40 do
    deep := deep + ']';
  deep := deep + '}';
  Check(not PWebBundleManifestParse(deep, m), 'unbounded nesting');
end;

procedure TTestBundleSystem.CompatPredicate;
begin
  // set membership + numeric semver: the ratified predicate
  Check(PWebBundleCompatCheck(MkMan(1, '0.1.0'), [1], '0.1.0') =
    pbrNone, 'equal runtime refused');
  Check(PWebBundleCompatCheck(MkMan(1, '0.0.9'), [1], '0.1.0') =
    pbrNone, 'older minimum refused');
  Check(PWebBundleCompatCheck(MkMan(1, '0.2.0'), [1], '0.1.0') =
    pbrRuntimeIncompatible, 'newer minimum accepted');
  Check(PWebBundleCompatCheck(MkMan(2, '0.1.0'), [1], '0.1.0') =
    pbrProtocolUnsupported, 'unsupported protocol accepted');
  Check(PWebBundleCompatCheck(MkMan(2, '0.1.0'), [1, 2], '0.1.0') =
    pbrNone, 'set membership broken');
  Check(PWebBundleCompatCheck(MkMan(0, '0.1.0'), [1], '0.1.0') =
    pbrProtocolUnsupported);
  // '0.10.0' vs '0.9.0' both ways - ordering is numeric, never
  // lexicographic (the ratified rule this phase must prove)
  Check(PWebBundleCompatCheck(MkMan(1, '0.9.0'), [1], '0.10.0') =
    pbrNone, 'numeric semver broken (runtime newer)');
  Check(PWebBundleCompatCheck(MkMan(1, '0.10.0'), [1], '0.9.0') =
    pbrRuntimeIncompatible, 'numeric semver broken (runtime older)');
  // malformed sides fail closed
  Check(PWebBundleCompatCheck(MkMan(1, 'bogus'), [1], '0.1.0') =
    pbrManifestMalformed, 'invalid minRuntime accepted');
  Check(PWebBundleCompatCheck(MkMan(1, '0.1.0'), [1], 'bogus') =
    pbrRuntimeIncompatible, 'invalid runtime version accepted');
  // an empty supported set can accept nothing
  Check(PWebBundleCompatCheck(MkMan(1, '0.1.0'), [], '0.1.0') =
    pbrProtocolUnsupported, 'empty protocol set accepted something');
end;

procedure TTestBundleSystem.NameClassification;
const
  SECRET: array[0..16] of RawUtf8 = (
    '.env', '.env.local', 'conf/.env.production',
    'cert.pem', 'keys/server.key', 'x.pfx', 'x.p12', 'x.crt',
    '.gitignore', '.git/config', 'sub/.gitattributes',
    'node_modules/pkg/app.js', 'package-lock.json', 'yarn.lock',
    'unit.pas', '.DS_Store', 'img/Thumbs.db');
  // '.envelope.svg' and '.envrc' pin the exact D3 grammar: only
  // '.env' itself or '.env.*' is secret, never a mere '.env' prefix
  ASSETS: array[0..8] of RawUtf8 = (
    'index.html', 'assets/app.js', 'assets/manifest.json',
    'environment.js', 'gitlog.txt', 'keynote.html', 'a/b/c.wasm',
    '.envelope.svg', '.envrc');
var
  i: PtrInt;
begin
  for i := 0 to High(SECRET) do
    CheckUtf8(PWebBundleClassifyName(SECRET[i]) = pbcSecret,
      'not classified secret: %', [SECRET[i]]);
  for i := 0 to High(ASSETS) do
    CheckUtf8(PWebBundleClassifyName(ASSETS[i]) = pbcAsset,
      'misclassified: %', [ASSETS[i]]);
  // sourcemaps: excluded by default, explicit opt-in at the CLI
  Check(PWebBundleClassifyName('assets/app.js.map') = pbcSourceMap);
  Check(PWebBundleClassifyName('app.css.map') = pbcSourceMap);
  // only the ROOT manifest.json is reserved (D5)
  Check(PWebBundleClassifyName('manifest.json') = pbcReservedManifest);
  Check(PWebBundleClassifyName('MANIFEST.JSON') = pbcReservedManifest);
  Check(PWebBundleClassifyName('assets/manifest.json') = pbcAsset);
  // classification is ASCII-case-insensitive (dev filesystems are)
  Check(PWebBundleClassifyName('.ENV') = pbcSecret);
  Check(PWebBundleClassifyName('CERT.PEM') = pbcSecret);
  Check(PWebBundleClassifyName('NODE_MODULES/x.js') = pbcSecret);
end;

procedure TTestBundleSystem.WriterHappyPathAndServing;
var
  entries: array of TPWebBundleEntry;
  err, raw, entryName: RawUtf8;
  outFile: TFileName;
  store: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
  zr: TZipRead;
  i: PtrInt;
  bytes: RawByteString;
  direct: IAssetStore;
begin
  SetLength(entries, 5);
  entries[0] := BE('index.html', INDEX_HTML);
  entries[1] := BE('assets/app.js', 'console.log("bundle");');
  entries[2] := BE('assets/nested/deep/data.bin', BinaryBlob(4096));
  entries[3] := BE('assets/empty.bin', '');
  entries[4] := BE('notes.txt', 'plain notes');
  outFile := BundlePath('app.pwb');
  CheckUtf8(PWebBundleWrite(outFile, entries, MkMan(1, '0.1.0'), 0,
    err), 'writer failed: %', [err]);
  CheckEqual(err, '');
  Check(FileExists(outFile), 'output missing');
  Check(not FileExists(PWebBundleTempFileName(outFile)), 'temp left behind');
  // production loader with injected runtime facts
  Check(PWebBundleLoadFile(outFile, [1], '0.1.0', store, reason),
    'loader refused a valid bundle');
  Check(reason = pbrNone);
  Check(store <> nil);
  for i := 0 to High(entries) do
  begin
    CheckUtf8(store.TryRead(entries[i].Name, asset),
      'entry unreadable: %', [entries[i].Name]);
    Check(asset.Content = entries[i].Content, 'bytes differ');
    CheckEqual(asset.ContentType,
      PWebAssetMimeType(entries[i].Name));
  end;
  // D5: the manifest is a servable asset like any other entry
  Check(store.TryRead('manifest.json', asset), 'manifest not served');
  Check(asset.Content =
    RawByteString(PWebBundleManifestSerialize(MkMan(1, '0.1.0'))),
    'served manifest bytes drifted');
  CheckEqual(asset.ContentType, 'application/json; charset=utf-8');
  // exact-case semantics are unchanged by the bundle layer
  Check(not store.TryRead('Assets/app.js', asset), 'case folded');
  Check(not store.TryRead('missing.js', asset));
  store := nil;
  // the raw CAP-4 store opens the same file - one architecture
  direct := TZipAssetStore.Create(outFile);
  Check(direct.TryRead('index.html', asset) and
    (asset.Content = INDEX_HTML), 'direct store read differs');
  direct := nil;
  // structural determinism facts: global bytewise name order, fixed
  // timestamp, no extra fields
  zr := TZipRead.Create(outFile);
  try
    CheckEqual(zr.Count, 6, 'entry count');
    raw := '';
    for i := 0 to zr.Count - 1 do
    begin
      FastSetString(entryName, zr.Entry[i].storedName,
        zr.Entry[i].dir^.fileInfo.nameLen);
      if i > 0 then
        CheckUtf8(CompareStr(raw, entryName) < 0,
          'entries not in global bytewise order at %', [entryName]);
      raw := entryName;
      Check(zr.Entry[i].dir^.fileInfo.zlastMod =
        PWEB_BUNDLE_FIXED_FILE_AGE, 'timestamp not fixed');
      CheckEqual(Integer(zr.Entry[i].dir^.fileInfo.extraLen), 0,
        'unexpected extra field');
    end;
  finally
    zr.Free;
  end;
  // buffer-based loading of the same bytes
  bytes := StringFromFile(outFile);
  Check(PWebBundleLoadBuffer(bytes, [1], '0.1.0', store, reason));
  Check(store.TryRead('index.html', asset));
  store := nil;
end;

procedure TTestBundleSystem.WriterDeterminism;
var
  a, b: array of TPWebBundleEntry;
  err: RawUtf8;
  f1, f2: TFileName;
  bytes1, bytes2: RawByteString;
begin
  SetLength(a, 4);
  a[0] := BE('index.html', INDEX_HTML);
  a[1] := BE('assets/app.js', 'js');
  a[2] := BE('assets/z.css', 'css');
  a[3] := BE('assets/data.bin', BinaryBlob(2048));
  // same logical input, permuted order
  SetLength(b, 4);
  b[0] := a[3];
  b[1] := a[1];
  b[2] := a[0];
  b[3] := a[2];
  f1 := BundlePath('det1.pwb');
  f2 := BundlePath('det2.pwb');
  CheckUtf8(PWebBundleWrite(f1, a, MkMan(1, '0.1.0'), 0, err),
    'det1: %', [err]);
  CheckUtf8(PWebBundleWrite(f2, b, MkMan(1, '0.1.0'), 0, err),
    'det2: %', [err]);
  bytes1 := StringFromFile(f1);
  bytes2 := StringFromFile(f2);
  Check(bytes1 <> '', 'empty output');
  Check(bytes1 = bytes2,
    'input order leaked into the archive bytes');
  // rewriting over an existing output (atomic-replace path) is stable
  CheckUtf8(PWebBundleWrite(f1, b, MkMan(1, '0.1.0'), 0, err),
    'rewrite: %', [err]);
  Check(StringFromFile(f1) = bytes2, 'rewrite drifted');
  // manifest participates: a different manifest MUST change the bytes
  CheckUtf8(PWebBundleWrite(f2, a, MkMan(1, '0.2.0'), 0, err),
    'manifest variant: %', [err]);
  Check(StringFromFile(f2) <> bytes1, 'manifest not in the archive');
end;

procedure TTestBundleSystem.WriterGoldenBytes;
const
  // SHA-256 of the archive produced from the fixed literal corpus
  // below (protocol 1, minRuntime 0.1.0). Pinned like CAFE_FOLDED:
  // if the pinned mORMot zip/deflate path, the writer's ordering,
  // timestamps, level or manifest bytes ever drift, this fails
  // loudly on every machine instead of self-comparing green.
  //
  // CAP-7L MEASURED: the pin is per BUILD TOOLCHAIN, not universal.
  // The writer's own contributions - entry order, timestamps,
  // manifest bytes, compression level - are platform-neutral, but the
  // DEFLATE stream is produced by the mORMot static compression
  // object for the target, and the x86_64-linux and x86_64-win64
  // statics do not emit byte-identical output for the same input.
  // Determinism, the property CAP-6 actually ratified, is unaffected:
  // it means "same inputs on the same toolchain always produce the
  // same bytes", and WriterDeterminism proves that separately on each
  // platform. What this constant pins is drift, and it can only do
  // that against a value measured on the same toolchain - hence two.
  // CAP-7M1 added the Darwin arm. MEASURED, run 31919274985: the golden
  // archive hashes to the SAME value on x86_64-darwin and aarch64-darwin,
  // so macOS needs ONE constant where Windows and Linux need one each -
  // the two Darwin statics emit byte-identical DEFLATE output for this
  // corpus, which is a fact worth stating rather than a coincidence to
  // rely on silently. Without this arm Darwin fell into the {$else} and
  // was compared against the WINDOWS digest, which is how it surfaced.
  GOLDEN_SHA256: RawUtf8 =
    {$if defined(DARWIN)}
    '39399116f7f111b12833e27b49b34380fdc1447c43c733fac9e2be7589e6d8dd';
    {$elseif defined(LINUX)}
    'dcf5f272ec0e19615deb132642a8688287650e9f263c23354cf9cdab20f8499a';
    {$else}
    '4f7c040485e9af880023f9543479b0a015d5cb1db98ec158fc83d287835091a2';
    {$endif}
var
  err: RawUtf8;
  target: TFileName;
  filler: RawByteString;
  i: PtrInt;
begin
  // deterministic literal corpus: one sub-256-byte entry (stored)
  // and one compressible 4 KiB entry (deflated) pin both write paths
  SetLength(filler, 4096);
  for i := 1 to Length(filler) do
    filler[i] := AnsiChar(Ord('a') + (i mod 23));
  target := BundlePath('golden.pwb');
  CheckUtf8(PWebBundleWrite(target, [
    BE('index.html', '<!doctype html><title>golden</title>'),
    BE('assets/app.js', filler),
    BE('assets/tiny.css', 'body{margin:0}')],
    MkMan(1, '0.1.0'), 0, err), 'golden write failed: %', [err]);
  CheckEqual(Sha256(StringFromFile(target)), GOLDEN_SHA256,
    'golden archive bytes drifted - a toolchain/dependency change ' +
    'reached the deterministic output');
end;

procedure TTestBundleSystem.WriterHostileAndCollisions;

  procedure CheckRefusedWrite(const Entries: array of TPWebBundleEntry;
    const What: RawUtf8);
  var
    err: RawUtf8;
    target: TFileName;
  begin
    target := BundlePath('refused.pwb');
    CheckUtf8(not PWebBundleWrite(target, Entries, MkMan(1, '0.1.0'),
      0, err), 'hostile input accepted: %', [What]);
    CheckUtf8(err <> '', 'no diagnostic for %', [What]);
    Check(not FileExists(target), 'output produced despite refusal');
    Check(not FileExists(PWebBundleTempFileName(target)), 'temp left behind');
  end;

const
  HOSTILE: array[0..13] of RawUtf8 = (
    '../x.js', './x.js', 'a\b.js', '/absolute.js', 'C:/x.js',
    '//server/share.js', 'x.txt:ads', 'NUL.txt', 'a%20b.js',
    'trailing.', 'trailing ', 'a'#1'b.js', 'a'#$C0#$AF'b.js',
    'assets//x.js');
var
  i: PtrInt;
begin
  for i := 0 to High(HOSTILE) do
    CheckRefusedWrite([BE('index.html', INDEX_HTML),
      BE(HOSTILE[i], 'x')], HOSTILE[i]);
  // collision classes (ratified: duplicate, case, file-dir)
  CheckRefusedWrite([BE('index.html', INDEX_HTML),
    BE('app.js', 'a'), BE('app.js', 'b')], 'exact duplicate');
  CheckRefusedWrite([BE('index.html', INDEX_HTML),
    BE('app.js', 'a'), BE('App.js', 'b')], 'ASCII case collision');
  CheckRefusedWrite([BE('index.html', INDEX_HTML),
    BE('a', 'x'), BE('a/b.js', 'y')], 'file/directory collision');
  CheckRefusedWrite([BE('index.html', INDEX_HTML),
    BE('assets/app.js', 'x'), BE('assets/app.js/x', 'y')],
    'file used as directory');
  // required root: a bundle without index.html cannot boot
  CheckRefusedWrite([BE('assets/app.js', 'x')], 'missing index.html');
  CheckRefusedWrite([], 'empty input');
end;

procedure TTestBundleSystem.UnicodeFoldPolicy;
var
  err: RawUtf8;
  target: TFileName;
  store: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
  rejected: Boolean;
begin
  // D1-3: the fold verdict is pinned to exact BYTES from the
  // compiled-in mORMot Unicode 10.0 tables. This same assertion runs
  // on every dev machine and every CI runner: if any environment
  // consulted an OS case API instead, these bytes would differ there
  // and the suite would fail - proving machine-independence
  CheckEqual(UpperCaseReference(CAFE_LOWER), CAFE_FOLDED,
    'pinned fold of cafe drifted');
  CheckEqual(UpperCaseReference(CAFE_UPPER), CAFE_FOLDED,
    'pinned fold of CAFE drifted');
  Check(UpperCaseReference(CAFE_LOWER) =
    UpperCaseReference(CAFE_UPPER), 'fold pair diverged');
  Check(UpperCaseReference(NAIVE_LOWER) <>
    UpperCaseReference(CAFE_LOWER), 'distinct names folded equal');
  // D1-1: fold-equal pair rejects at BUNDLE CONSTRUCTION
  target := BundlePath('fold.pwb');
  Check(not PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE(CAFE_LOWER, 'a'), BE(CAFE_UPPER, 'b')], MkMan(1, '0.1.0'), 0,
    err), 'Unicode fold collision accepted by the bundler');
  Check(not FileExists(target));
  // D1-2: ordinary non-ASCII distinct names that do NOT fold equal
  // are accepted - v1 names stay valid Unicode, not ASCII-only
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE(CAFE_LOWER, 'cafe-bytes'), BE(NAIVE_LOWER, 'naive-bytes')],
    MkMan(1, '0.1.0'), 0, err), 'non-ASCII names refused: %', [err]);
  Check(PWebBundleLoadFile(target, [1], '0.1.0', store, reason),
    'non-ASCII bundle refused by the loader');
  Check(store.TryRead(CAFE_LOWER, asset) and
    (asset.Content = 'cafe-bytes'), 'non-ASCII entry unreadable');
  // lookup stays exact byte/case-sensitive - the fold never rewrites
  Check(not store.TryRead(CAFE_UPPER, asset),
    'fold leaked into lookup');
  store := nil;
  // D1-4: a hand-crafted ZIP that bypasses the bundler is rejected by
  // TZipAssetStore construction - the mandatory second enforcement
  rejected := False;
  try
    store := TZipAssetStore.CreateFromBuffer(BuildRawZip(
      [RawByteString(CAFE_LOWER), RawByteString(CAFE_UPPER),
       'index.html']));
    store := nil;
  except
    on EPWebZipAssetStore do
      rejected := True;
  end;
  Check(rejected, 'crafted fold-collision archive bypassed the store');
  // the same bypass through the loader: typed refusal, nil store
  Check(not PWebBundleLoadBuffer(BuildRawZip(
    [RawByteString(CAFE_LOWER), RawByteString(CAFE_UPPER),
     'index.html']), [1], '0.1.0', store, reason));
  Check(reason = pbrArchiveInvalid);
  Check(store = nil, 'store escaped a refusal');
  // beyond latin-1: greek sigma pair folds equal too
  rejected := False;
  try
    store := TZipAssetStore.CreateFromBuffer(BuildRawZip(
      [RawByteString(SIGMA_LOWER), RawByteString(SIGMA_UPPER)]));
    store := nil;
  except
    on EPWebZipAssetStore do
      rejected := True;
  end;
  Check(rejected, 'greek fold collision bypassed the store');
  // control: crafted archive with distinct non-ASCII names is fine
  store := TZipAssetStore.CreateFromBuffer(BuildRawZip(
    [RawByteString(CAFE_LOWER), RawByteString(NAIVE_LOWER)]));
  Check(store.TryRead(CAFE_LOWER, asset), 'control read failed');
  store := nil;
end;

procedure TTestBundleSystem.WriterThresholdAndReserved;
var
  err: RawUtf8;
  target: TFileName;
  big: RawByteString;
  store: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
begin
  target := BundlePath('threshold.pwb');
  // explicit ceiling: 4096-byte asset against a 1024-byte limit
  Check(not PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE('big.bin', BinaryBlob(4096))], MkMan(1, '0.1.0'), 1024, err),
    'oversized asset accepted');
  Check(Pos('big.bin', err) > 0, 'refusal does not name the asset');
  Check(Pos('blob', err) > 0,
    'refusal does not name the blob-plane escape route');
  Check(not FileExists(target));
  // raising the ceiling admits the same asset
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE('big.bin', BinaryBlob(4096))], MkMan(1, '0.1.0'), 8192, err),
    'override ceiling failed: %', [err]);
  Check(FileExists(target));
  // ratified default: 32 MiB, exceeded by one byte -> error (checked
  // before any disk write, so this stays fast)
  SetLength(big, PWEB_BUNDLE_MAX_ASSET_BYTES_DEFAULT + 1);
  FillChar(big[1], Length(big), 0);
  Check(not PWebBundleWrite(BundlePath('big.pwb'),
    [BE('index.html', INDEX_HTML), BE('huge.bin', big)],
    MkMan(1, '0.1.0'), 0, err), 'default ceiling not enforced');
  Check(not FileExists(BundlePath('big.pwb')));
  big := '';
  // D5: the input dist may not contain a ROOT manifest.json
  Check(not PWebBundleWrite(BundlePath('res.pwb'),
    [BE('index.html', INDEX_HTML), BE('manifest.json', '{}')],
    MkMan(1, '0.1.0'), 0, err), 'root manifest.json accepted');
  Check(not PWebBundleWrite(BundlePath('res.pwb'),
    [BE('index.html', INDEX_HTML), BE('MANIFEST.JSON', '{}')],
    MkMan(1, '0.1.0'), 0, err), 'case-variant root manifest accepted');
  // ...but a NESTED manifest.json is an ordinary asset
  CheckUtf8(PWebBundleWrite(BundlePath('res.pwb'),
    [BE('index.html', INDEX_HTML),
     BE('assets/manifest.json', '{"app":true}')],
    MkMan(1, '0.1.0'), 0, err), 'nested manifest refused: %', [err]);
  Check(PWebBundleLoadFile(BundlePath('res.pwb'), [1], '0.1.0',
    store, reason));
  Check(store.TryRead('assets/manifest.json', asset) and
    (asset.Content = '{"app":true}'));
  // the root manifest remains the bundler-generated one
  Check(store.TryRead('manifest.json', asset) and
    (asset.Content =
      RawByteString(PWebBundleManifestSerialize(MkMan(1, '0.1.0')))));
  store := nil;
  // secrets are hard errors in the writer too (defense in depth)...
  Check(not PWebBundleWrite(BundlePath('sec.pwb'),
    [BE('index.html', INDEX_HTML), BE('conf/.env', 'S=1')],
    MkMan(1, '0.1.0'), 0, err), 'secret name accepted by writer');
  // ...but an EXPLICIT *.map entry is accepted by design: the default
  // sourcemap exclusion is the CLI walk's policy (--include-sourcemaps
  // passes the entry through), not a writer-level ban
  CheckUtf8(PWebBundleWrite(BundlePath('map.pwb'),
    [BE('index.html', INDEX_HTML),
     BE('assets/app.js.map', '{"version":3}')],
    MkMan(1, '0.1.0'), 0, err), 'explicit sourcemap refused: %', [err]);
  Check(PWebBundleLoadFile(BundlePath('map.pwb'), [1], '0.1.0',
    store, reason));
  Check(store.TryRead('assets/app.js.map', asset) and
    (asset.Content = '{"version":3}'), 'opt-in sourcemap not served');
  store := nil;
  // an invalid manifest never writes
  Check(not PWebBundleWrite(BundlePath('badman.pwb'),
    [BE('index.html', INDEX_HTML)], MkMan(1, '1.0'), 0, err),
    'invalid manifest semver accepted');
  Check(not PWebBundleWrite(BundlePath('badman.pwb'),
    [BE('index.html', INDEX_HTML)], MkMan(-1, '0.1.0'), 0, err),
    'negative protocol accepted');
end;

procedure TTestBundleSystem.WriterAtomicFailure;
var
  err: RawUtf8;
  target: TFileName;
  before: RawByteString;
  {$ifdef OSWINDOWS}
  lock: THandle;
  {$endif OSWINDOWS}
begin
  target := BundlePath('atomic.pwb');
  // establish a known-good previous output
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE('v.txt', 'version-one')], MkMan(1, '0.1.0'), 0, err),
    'baseline write failed: %', [err]);
  before := StringFromFile(target);
  Check(before <> '');
  // validation failure: nothing on disk moves
  Check(not PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE('../evil.js', 'x')], MkMan(1, '0.1.0'), 0, err));
  Check(StringFromFile(target) = before, 'prior output damaged');
  Check(not FileExists(PWebBundleTempFileName(target)), 'temp left behind');
  {$ifdef OSWINDOWS}
  // injected MID-BUILD failure: hold the destination open with no
  // sharing, so the temp is fully written and self-validated but the
  // final atomic replace fails -> temp removed, prior output intact
  lock := FileOpen(target, fmOpenRead or fmShareExclusive);
  Check(lock <> THandle(-1), 'could not lock the previous output');
  try
    Check(not PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
      BE('v.txt', 'version-two')], MkMan(1, '0.1.0'), 0, err),
      'replace over a locked output claimed success');
    Check(Pos('atomic replace failed', err) > 0,
      'unexpected failure mode: ' + Utf8ToString(err));
    Check(not FileExists(PWebBundleTempFileName(target)),
      'temp survived the injected failure');
  finally
    FileClose(lock);
  end;
  Check(StringFromFile(target) = before,
    'prior output damaged by the injected failure');
  // once unlocked, the same replace succeeds and the bytes change
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE('v.txt', 'version-two')], MkMan(1, '0.1.0'), 0, err),
    'post-unlock write failed: %', [err]);
  Check(StringFromFile(target) <> before, 'output did not update');
  Check(not FileExists(PWebBundleTempFileName(target)));
  {$endif OSWINDOWS}
end;

procedure TTestBundleSystem.LoaderCompatMatrix;

  procedure CheckRefusedLoad(const Data: RawByteString;
    Expected: TPWebBundleRefusal; const What: RawUtf8);
  var
    store: IAssetStore;
    reason: TPWebBundleRefusal;
  begin
    store := nil;
    CheckUtf8(not PWebBundleLoadBuffer(Data, [1], '0.1.0', store,
      reason), 'loader accepted: %', [What]);
    CheckUtf8(reason = Expected, 'wrong refusal for %', [What]);
    // the refusal proof: no IAssetStore object escapes, so there is
    // no source a webview could ever execute bundle JS from
    Check(store = nil, 'store escaped a refusal');
  end;

  function Crafted(const ManifestJson: RawByteString): RawByteString;
  begin
    Result := BuildRawZipEx(['index.html', 'manifest.json'],
      [INDEX_HTML, ManifestJson]);
  end;

var
  err: RawUtf8;
  target: TFileName;
  store: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
begin
  target := BundlePath('compat.pwb');
  // protocol 2 in a runtime supporting {1}: the writer accepts (its
  // self-validation uses the bundle's own facts), the LOADER refuses
  // with the injected set - proving the predicate is parameterized
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML)],
    MkMan(2, '0.1.0'), 0, err), 'proto-2 write failed: %', [err]);
  Check(not PWebBundleLoadFile(target, [1], '0.1.0', store, reason));
  Check(reason = pbrProtocolUnsupported);
  Check(store = nil);
  Check(PWebBundleLoadFile(target, [1, 2], '0.1.0', store, reason),
    'proto 2 refused by a runtime supporting {1,2}');
  store := nil;
  // minRuntime above the injected runtime refuses; below/equal loads
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML)],
    MkMan(1, '0.2.0'), 0, err), 'minruntime write failed: %', [err]);
  Check(not PWebBundleLoadFile(target, [1], '0.1.0', store, reason));
  Check(reason = pbrRuntimeIncompatible);
  Check(store = nil);
  Check(PWebBundleLoadFile(target, [1], '0.2.0', store, reason));
  store := nil;
  Check(PWebBundleLoadFile(target, [1], '1.0.0', store, reason));
  store := nil;
  // numeric ordering through the whole loader: 0.10.0 vs 0.9.0
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML)],
    MkMan(1, '0.9.0'), 0, err), 'semver write failed: %', [err]);
  Check(PWebBundleLoadFile(target, [1], '0.10.0', store, reason),
    'numeric semver broken through the loader');
  store := nil;
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML)],
    MkMan(1, '0.10.0'), 0, err), 'semver write failed: %', [err]);
  Check(not PWebBundleLoadFile(target, [1], '0.9.0', store, reason));
  Check(reason = pbrRuntimeIncompatible);
  Check(store = nil);
  // crafted manifests beyond what the writer would ever emit
  CheckRefusedLoad(Crafted('{"pweb":{"protocol":1,"minRuntime":"1.0"}}'),
    pbrManifestMalformed, 'invalid semver');
  CheckRefusedLoad(Crafted('this is not json'),
    pbrManifestMalformed, 'malformed JSON');
  CheckRefusedLoad(Crafted('{"other":true}'),
    pbrManifestMalformed, 'missing pweb block');
  CheckRefusedLoad(Crafted('{"pweb":{"protocol":"x","minRuntime":"0.1.0"}}'),
    pbrManifestMalformed, 'non-integer protocol');
  // unknown additive fields are ignored; capability-like fields are
  // INERT - the bundle still loads and nothing is granted (there is
  // no capability surface on IAssetStore to grant through)
  Check(PWebBundleLoadBuffer(Crafted(
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0","future":123}}'),
    [1], '0.1.0', store, reason), 'additive field broke loading');
  store := nil;
  Check(PWebBundleLoadBuffer(Crafted(
    '{"pweb":{"protocol":1,"minRuntime":"0.1.0",' +
    '"allow":["*"],"capabilities":{"fs":"rw"},"permissions":"all"},' +
    '"allow":["*"]}'),
    [1], '0.1.0', store, reason), 'capability-like fields broke ' +
    'loading (they must be inert, not errors)');
  Check(store.TryRead('index.html', asset), 'inert-field bundle');
  store := nil;
  // missing bundle file: typed refusal, no store
  Check(not PWebBundleLoadFile(BundlePath('no-such.pwb'), [1],
    '0.1.0', store, reason));
  Check(reason = pbrBundleMissing);
  Check(store = nil);
end;

procedure TTestBundleSystem.LoaderTamperMatrix;

  procedure CheckRefusedLoad(const Data: RawByteString;
    Expected: TPWebBundleRefusal; const What: RawUtf8);
  var
    store: IAssetStore;
    reason: TPWebBundleRefusal;
  begin
    store := nil;
    CheckUtf8(not PWebBundleLoadBuffer(Data, [1], '0.1.0', store,
      reason), 'tampered bundle accepted: %', [What]);
    CheckUtf8(reason = Expected, 'wrong refusal for %', [What]);
    Check(store = nil, 'store escaped a refusal');
  end;

const
  MAN: RawByteString = '{"pweb":{"protocol":1,"minRuntime":"0.1.0"}}';
var
  err: RawUtf8;
  target: TFileName;
  valid, cut: RawByteString;
  store: IAssetStore;
  reason: TPWebBundleRefusal;
begin
  CheckRefusedLoad('', pbrArchiveInvalid, 'empty bytes');
  CheckRefusedLoad('this is not a zip archive at all',
    pbrArchiveInvalid, 'non-ZIP bytes');
  CheckRefusedLoad(BuildRawZip([]), pbrArchiveInvalid,
    'empty archive');
  // a valid bundle, then truncated: fail closed
  target := BundlePath('tamper.pwb');
  CheckUtf8(PWebBundleWrite(target, [BE('index.html', INDEX_HTML),
    BE('assets/app.js', 'x')], MkMan(1, '0.1.0'), 0, err),
    'tamper baseline failed: %', [err]);
  valid := StringFromFile(target);
  cut := Copy(valid, 1, Length(valid) div 2);
  CheckRefusedLoad(cut, pbrArchiveInvalid, 'truncated archive');
  // no manifest entry at all
  CheckRefusedLoad(BuildRawZipEx(['index.html'], [INDEX_HTML]),
    pbrManifestMissing, 'missing manifest');
  // duplicate manifest entries are ambiguous: whole archive refused
  CheckRefusedLoad(BuildRawZipEx(
    ['manifest.json', 'manifest.json', 'index.html'],
    [MAN, MAN, INDEX_HTML]),
    pbrArchiveInvalid, 'duplicate manifest entry');
  // manifest fine but no index.html: refuse before any UI could boot
  CheckRefusedLoad(BuildRawZipEx(['manifest.json'], [MAN]),
    pbrIndexMissing, 'missing index document');
  // hostile entry names reject the archive as a whole (CAP-4 gate)
  CheckRefusedLoad(BuildRawZipEx(
    ['../evil.js', 'index.html', 'manifest.json'],
    ['x', INDEX_HTML, MAN]),
    pbrArchiveInvalid, 'traversal entry');
  CheckRefusedLoad(BuildRawZipEx(
    ['assets\app.js', 'index.html', 'manifest.json'],
    ['x', INDEX_HTML, MAN]),
    pbrArchiveInvalid, 'backslash entry');
  // control: an equivalent crafted archive with canonical names loads
  Check(PWebBundleLoadBuffer(BuildRawZipEx(
    ['assets/app.js', 'index.html', 'manifest.json'],
    ['x', INDEX_HTML, MAN]), [1], '0.1.0', store, reason),
    'crafted control archive refused');
  Check(reason = pbrNone);
  store := nil;
  // every refusal category has distinct, fixed diagnostic text
  Check(PWebBundleRefusalText(pbrBundleMissing) <>
    PWebBundleRefusalText(pbrArchiveInvalid));
  Check(PWebBundleRefusalText(pbrManifestMissing) <>
    PWebBundleRefusalText(pbrManifestMalformed));
  CheckEqual(PWebBundleRefusalText(pbrBundleMissing),
    'bundle file missing');
  CheckEqual(PWebBundleRefusalText(pbrArchiveInvalid),
    'bundle archive invalid');
end;

end.
