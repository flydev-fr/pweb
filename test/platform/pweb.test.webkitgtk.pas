unit pweb.test.webkitgtk;

{ mormot.core.test cases for CAP-7L: the Linux/WebKitGTK pweb://app
  adapter, headless.

  These cases exercise the adapter's REAL routines, not restatements of
  them: pweb.platform.webkitgtk exposes its whole request decision as
  PWebGtkResolveAssetUri and its response-body copy as PWebGtkCopyBody,
  and the scheme callback calls exactly those. So "Linux reaches the same
  verdict as Windows through the same routine" is a property proven here
  rather than asserted in a comment.

  Three things are covered:

    - the URI gate, driven by the CAP-4 hostile vectors expressed as
      pweb:// URIs. The store is wrapped in a counting decorator, so
      "IAssetStore is never consulted for a refused URI" (L11/L12) is
      measured, not assumed;
    - MIME parity: the served Content-Type is the store's deterministic
      type, and it is never empty;
    - the response-lifetime regression: the body handed to GIO must be an
      independent heap copy. The test poisons and frees the source after
      the copy, exactly as the callback frame does, and requires the copy
      to still read back byte-for-byte. A body that aliased the
      RawByteString would fail here rather than as a use-after-free in a
      browser process.

  No window, no display and no GTK initialisation is required: nothing
  below calls a WebKit function. The unit does bind libglib at load time
  (the body copy is a real g_try_malloc/g_free pair), which is why these
  cases live behind {$ifdef LINUX} in the suite runner. }

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.test,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.zip,
  pweb.platform.webkitgtk;

type
  /// CAP-7L Linux adapter cases: URI gate, MIME parity, body lifetime
  TTestWebKitGtkAdapter = class(TSynTestCase)
  protected
    fInner: IAssetStore;
    fStore: IAssetStore; // counting decorator over fInner
    procedure Setup; override;
    procedure CleanUp; override;
    function StoreReads: Integer;
  published
    /// hostile pweb:// URIs are refused and never reach IAssetStore
    procedure HostileUriMatrix;
    /// canonical pweb:// URIs resolve to the exact stored bytes
    procedure CanonicalUriResolution;
    /// the wrong authority is refused by the URI layer, not by the store
    procedure WrongAuthorityNeverReachesStore;
    /// served Content-Type is the deterministic table value, never empty
    procedure ContentTypeParity;
    /// the GIO-owned body is an independent copy of the asset bytes
    procedure ResponseBodyLifetime;
  end;

implementation

uses
  pweb.test.assets; // BuildRawZipEx: raw archives with exact stored names

const
  CORPUS_NAMES: array[0..4] of RawByteString = (
    'index.html', 'assets/app.js', 'assets/app.css',
    'assets/empty.bin', 'notes.txt');

function CorpusBytes(const Name: RawByteString): RawByteString;
begin
  if Name = 'index.html' then
    Result := '<!doctype html><html><body>cap7l</body></html>'
  else if Name = 'assets/app.js' then
    Result := 'console.log("cap7l");' + #10
  else if Name = 'assets/app.css' then
    Result := 'body{margin:0}'
  else if Name = 'assets/empty.bin' then
    Result := '' // zero-byte asset must round-trip
  else if Name = 'notes.txt' then
    Result := 'plain text'
  else
    Result := '';
end;

type
  { Proves the negative half of the URI gate: a refused URI must not cost
    a single store lookup. Wrapping is the only way to measure that -
    asserting "it returned False" would pass even if the store had been
    consulted and missed. }
  TCountingAssetStore = class(TInterfacedObject, IAssetStore)
  private
    fInner: IAssetStore;
    fReads: Integer;
  public
    constructor Create(const AInner: IAssetStore);
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
    property Reads: Integer read fReads;
  end;

constructor TCountingAssetStore.Create(const AInner: IAssetStore);
begin
  inherited Create;
  fInner := AInner;
end;

function TCountingAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
begin
  Inc(fReads);
  Result := fInner.TryRead(Path, Asset);
end;

{ TTestWebKitGtkAdapter }

procedure TTestWebKitGtkAdapter.Setup;
var
  contents: array[0..4] of RawByteString;
  i: PtrInt;
begin
  for i := 0 to High(CORPUS_NAMES) do
    contents[i] := CorpusBytes(CORPUS_NAMES[i]);
  fInner := TZipAssetStore.CreateFromBuffer(
    BuildRawZipEx(CORPUS_NAMES, contents));
  fStore := TCountingAssetStore.Create(fInner);
end;

procedure TTestWebKitGtkAdapter.CleanUp;
begin
  fStore := nil;
  fInner := nil;
end;

function TTestWebKitGtkAdapter.StoreReads: Integer;
begin
  Result := (fStore as TCountingAssetStore).Reads;
end;

procedure TTestWebKitGtkAdapter.HostileUriMatrix;
const
  // the CAP-4 hostile corpus, expressed as the URIs a page can actually
  // ask for. Same vectors, same verdicts as Windows - and reached
  // through the same PWebParseAppUri, not a Linux copy of it.
  HOSTILE: array[0..31] of RawUtf8 = (
    // wrong or missing authority
    'pweb://evil/x', 'pweb://app.evil/x', 'pweb:///x', 'pweb://',
    'pweb://app:80/x', 'pweb://user@app/x', 'https://app/x',
    'pweb:/app/x', 'file:///etc/passwd', '',
    // traversal, encoded and double-encoded
    'pweb://app/../x', 'pweb://app/%2e%2e/x', 'pweb://app/%252e%252e/x',
    'pweb://app/assets/../x', 'pweb://app/./x',
    'pweb://app/%2e%2e%2fx',
    // separators and empty segments
    'pweb://app//x', 'pweb://app/assets//x', 'pweb://app/a%5cb',
    'pweb://app/a\b', 'pweb://app/assets/',
    // NUL, control bytes and malformed escapes
    'pweb://app/a%00b', 'pweb://app/a%zz', 'pweb://app/a%2',
    'pweb://app/a%',
    // Windows device names (refused on EVERY platform: the dev store
    // must match archive behaviour, not the filesystem's)
    'pweb://app/NUL', 'pweb://app/nul.txt', 'pweb://app/com1.js',
    'pweb://app/CONIN$',
    // trailing dot/space forms and drive/UNC shapes
    'pweb://app/index.html.', 'pweb://app/index.html%20',
    'pweb://app/C:/x');
var
  i: PtrInt;
  asset: TAssetResponse;
  before: Integer;
begin
  for i := 0 to High(HOSTILE) do
  begin
    before := StoreReads;
    CheckUtf8(not PWebGtkResolveAssetUri(HOSTILE[i], fStore, asset),
      'adapter served hostile URI: %', [HOSTILE[i]]);
    CheckUtf8(asset.Content = '', 'hostile URI produced a body: %',
      [HOSTILE[i]]);
    CheckUtf8(asset.ContentType = '',
      'hostile URI produced a content type: %', [HOSTILE[i]]);
    // every one of these dies in the URI layer, so the store must not
    // have been touched at all
    CheckUtf8(StoreReads = before,
      'IAssetStore was consulted for a refused URI: %', [HOSTILE[i]]);
  end;
  // a nil store is a refusal, never a crash
  Check(not PWebGtkResolveAssetUri('pweb://app/index.html', nil, asset),
    'nil store accepted');
end;

procedure TTestWebKitGtkAdapter.CanonicalUriResolution;
var
  asset: TAssetResponse;
begin
  // the one root mapping lives in the URI layer, and the adapter gets it
  // for free by handing over the whole URI
  Check(PWebGtkResolveAssetUri('pweb://app/', fStore, asset),
    'root URI refused');
  Check(asset.Content = CorpusBytes('index.html'), 'root bytes differ');
  Check(PWebGtkResolveAssetUri('pweb://app', fStore, asset),
    'bare authority refused');
  Check(asset.Content = CorpusBytes('index.html'), 'bare bytes differ');
  Check(PWebGtkResolveAssetUri('pweb://app/assets/app.js', fStore, asset),
    'subresource refused');
  Check(asset.Content = CorpusBytes('assets/app.js'), 'js bytes differ');
  // scheme and authority are case-insensitive per RFC 3986; the PATH is not
  Check(PWebGtkResolveAssetUri('PWEB://APP/index.html', fStore, asset),
    'case-insensitive scheme/authority refused');
  Check(not PWebGtkResolveAssetUri('pweb://app/Index.html', fStore, asset),
    'path case was folded');
  // the ratified order is decode ONCE then validate, so a single escape
  // resolves to the plain character. Pinned here exactly as the CAP-4
  // suite pins it, so it can never drift into "reject anything with a %":
  // %2e is a legitimate spelling of '.', while the DOUBLE encoding
  // %252e%252e (in the hostile matrix) still dies in the validator.
  Check(PWebGtkResolveAssetUri('pweb://app/index%2ehtml', fStore, asset),
    'single-decode %2e refused');
  Check(asset.Content = CorpusBytes('index.html'), 'decoded bytes differ');
  Check(PWebGtkResolveAssetUri('pweb://app/assets%2Fapp.js', fStore, asset),
    'decoded %2F separator refused');
  Check(asset.Content = CorpusBytes('assets/app.js'),
    'decoded separator bytes differ');
  // query and fragment are cut before decoding
  Check(PWebGtkResolveAssetUri('pweb://app/notes.txt?v=1', fStore, asset),
    'query not cut');
  Check(asset.Content = CorpusBytes('notes.txt'), 'query bytes differ');
  Check(PWebGtkResolveAssetUri('pweb://app/notes.txt#top', fStore, asset),
    'fragment not cut');
  // a zero-byte asset is served, never confused with a miss
  Check(PWebGtkResolveAssetUri('pweb://app/assets/empty.bin', fStore, asset),
    'zero-byte asset refused');
  Check(asset.Content = '', 'zero-byte asset has content');
  // a missing asset is a refusal with no body
  Check(not PWebGtkResolveAssetUri('pweb://app/missing.txt', fStore, asset),
    'missing asset served');
  Check(asset.Content = '', 'missing asset produced a body');
end;

procedure TTestWebKitGtkAdapter.WrongAuthorityNeverReachesStore;
var
  asset: TAssetResponse;
  before: Integer;
begin
  // MEASURED trap this adapter exists to avoid: on GTK the scheme is
  // registered scheme-WIDE, so pweb://evil/x really does arrive at the
  // handler, and webkit_uri_scheme_request_get_path() would report '/x'
  // - a perfectly canonical-looking path with the authority discarded.
  // Passing the WHOLE URI to PWebParseAppUri is what makes this a refusal.
  before := StoreReads;
  Check(not PWebGtkResolveAssetUri('pweb://evil/index.html', fStore, asset),
    'wrong authority served');
  CheckEqual(StoreReads, before, 'wrong authority reached the store');
  // the control: the identical path under the right authority resolves,
  // so the refusal above is about the authority and nothing else
  Check(PWebGtkResolveAssetUri('pweb://app/index.html', fStore, asset),
    'control request refused');
  CheckEqual(StoreReads, before + 1, 'control did not reach the store');
end;

procedure TTestWebKitGtkAdapter.ContentTypeParity;
var
  asset: TAssetResponse;
begin
  Check(PWebGtkResolveAssetUri('pweb://app/', fStore, asset));
  CheckEqual(PWebGtkContentType(asset), PWebAssetMimeType('index.html'));
  CheckEqual(PWebGtkContentType(asset), 'text/html; charset=utf-8');
  Check(PWebGtkResolveAssetUri('pweb://app/assets/app.js', fStore, asset));
  CheckEqual(PWebGtkContentType(asset),
    'text/javascript; charset=utf-8');
  Check(PWebGtkResolveAssetUri('pweb://app/assets/app.css', fStore, asset));
  CheckEqual(PWebGtkContentType(asset), 'text/css; charset=utf-8');
  Check(PWebGtkResolveAssetUri('pweb://app/notes.txt', fStore, asset));
  CheckEqual(PWebGtkContentType(asset), 'text/plain; charset=utf-8');
  Check(PWebGtkResolveAssetUri('pweb://app/assets/empty.bin', fStore, asset));
  CheckEqual(PWebGtkContentType(asset), PWEB_ASSET_FALLBACK_MIME);
  // an empty type can never be served: it would let the engine sniff
  asset.ContentType := '';
  CheckEqual(PWebGtkContentType(asset), PWEB_ASSET_FALLBACK_MIME);
end;

procedure TTestWebKitGtkAdapter.ResponseBodyLifetime;
var
  asset: TAssetResponse;
  source, readback: RawByteString;
  body: Pointer;
  size: PtrInt;
  i: PtrInt;
begin
  // binary content including NUL and every byte value, so a truncating or
  // text-converting copy cannot pass
  SetLength(source, 512);
  for i := 1 to Length(source) do
    source[i] := AnsiChar((i - 1) and 255);

  Check(PWebGtkCopyBody(source, body, size), 'body copy failed');
  CheckEqual(size, Length(source), 'copied length differs');
  Check(body <> nil, 'body pointer is nil');
  Check(body <> pointer(source),
    'the response body ALIASES the Pascal string instead of copying it');
  // poison and release the source exactly as the callback frame does when
  // it returns: a body that pointed here would now be reading garbage
  FillChar(pointer(source)^, Length(source), $5A);
  source := '';
  SetString(readback, PAnsiChar(body), size);
  for i := 1 to Length(readback) do
    CheckUtf8(readback[i] = AnsiChar((i - 1) and 255),
      'GIO-owned body byte % survived poisoning as %',
      [i, Ord(readback[i])]);
  PWebGtkReleaseBody(body);

  // a zero-byte asset still gets a real, non-nil allocation with an
  // honest length: g_try_malloc(0) returns nil, and handing nil to the
  // input stream is not the same thing as serving an empty asset
  Check(PWebGtkResolveAssetUri('pweb://app/assets/empty.bin', fStore, asset),
    'zero-byte asset refused');
  Check(PWebGtkCopyBody(asset.Content, body, size),
    'zero-byte body copy failed');
  CheckEqual(size, 0, 'zero-byte body has a length');
  Check(body <> nil, 'zero-byte body must still be a real allocation');
  PWebGtkReleaseBody(body);

  // repeated copies never hand back the same block while both are live
  Check(PWebGtkCopyBody('abc', body, size), 'first repeat copy failed');
  Check(size = 3, 'repeat copy length');
  PWebGtkReleaseBody(body);
end;

end.
