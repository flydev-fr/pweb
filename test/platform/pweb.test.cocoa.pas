unit pweb.test.cocoa;

{ mormot.core.test cases for CAP-7M1: the macOS/Cocoa/WKWebView pweb://app
  adapter, headless.

  These cases exercise the adapter's REAL routines and the REAL bridge, not
  restatements of them. pweb.platform.cocoa exposes its whole request decision
  as PWebCocoaResolveAssetUri and its response-body copy as PWebCocoaCopyBody,
  and the bridge's resolve callback calls exactly those - so "macOS reaches
  the same verdict as Windows and Linux through the same routine" is a
  property proven here rather than asserted in a comment.

  Five things are covered:

    - the URI gate, driven by the CAP-4 hostile vectors expressed as pweb://
      URIs. The store is wrapped in a counting decorator, so "IAssetStore is
      never consulted for a refused URI" is measured, not assumed;
    - MIME parity: the served Content-Type is the store's deterministic type,
      and it is never empty;
    - the response-lifetime rule: the body handed to the bridge must be an
      independent block the BRIDGE owns. The test poisons and frees the source
      after the copy, exactly as the callback frame does, and requires the
      copy to still read back byte-for-byte;
    - the generation-checked handle registry: a handle from a detached
      handler must be UNRESOLVABLE even after its slot is re-occupied. That is
      what makes "no callback after handler destruction" a property of the
      representation rather than of the teardown order;
    - THE TASK STATE MACHINE, driven deterministically through the bridge with
      a stub task: double terminal suppressed, post-stop suppressed, cancel
      idempotent, teardown drains a live task, and a disowned handler is
      inert. Every one of those is a race in the abstract and a certainty
      here, because the stub is driven synchronously and MIMICS WebKit's
      documented raising behaviour - a stub that quietly accepted misuse would
      let the claim gate be deleted with every test still green.

  No window, no NSApplication, no display and no webview_create is required:
  nothing below creates a WKWebView. The unit does link the Cocoa bridge (and
  therefore Cocoa and WebKit), which is why these cases live behind
  {$ifdef DARWIN} in the suite runner. }

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.test,
  pweb.lib.webview.types, // webview_t, for the Attach refusal case only
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.zip,
  pweb.platform.cocoa;

type
  /// CAP-7M1 macOS adapter cases: URI gate, MIME parity, body ownership,
  // the handle registry and the task state machine
  TTestCocoaAdapter = class(TSynTestCase)
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
    /// the bridge-owned body is an independent copy of the asset bytes
    procedure ResponseBodyLifetime;
    /// a handle from a detached handler is unresolvable, slot reuse or not
    procedure HandleRegistryGenerations;
    /// the +new override is confined to WKWebViewConfiguration's metaclass
    procedure SeamConfinement;
    /// claim-once terminals, post-stop suppression, idempotent cancel,
    // teardown drain and a disowned handler - all without a window
    procedure TaskStateMachine;
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
    Result := '<!doctype html><html><body>cap7m1</body></html>'
  else if Name = 'assets/app.js' then
    Result := 'console.log("cap7m1");' + #10
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
  { Proves the negative half of the URI gate: a refused URI must not cost a
    single store lookup. Wrapping is the only way to measure that - asserting
    "it returned False" would pass even if the store had been consulted and
    missed. }
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

{ TTestCocoaAdapter }

procedure TTestCocoaAdapter.Setup;
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

procedure TTestCocoaAdapter.CleanUp;
begin
  fStore := nil;
  fInner := nil;
end;

function TTestCocoaAdapter.StoreReads: Integer;
begin
  Result := (fStore as TCountingAssetStore).Reads;
end;

procedure TTestCocoaAdapter.HostileUriMatrix;
const
  // the CAP-4 hostile corpus, expressed as the URIs a page can actually ask
  // for. Same vectors, same verdicts as Windows and Linux - and reached
  // through the same PWebParseAppUri, not a macOS copy of it.
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
    // Windows device names (refused on EVERY platform: the dev store must
    // match archive behaviour, not the filesystem's)
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
    CheckUtf8(not PWebCocoaResolveAssetUri(HOSTILE[i], fStore, asset),
      'adapter served hostile URI: %', [HOSTILE[i]]);
    CheckUtf8(asset.Content = '', 'hostile URI produced a body: %',
      [HOSTILE[i]]);
    CheckUtf8(asset.ContentType = '',
      'hostile URI produced a content type: %', [HOSTILE[i]]);
    // every one of these dies in the URI layer, so the store must not have
    // been touched at all
    CheckUtf8(StoreReads = before,
      'IAssetStore was consulted for a refused URI: %', [HOSTILE[i]]);
  end;
  // a nil store is a refusal, never a crash
  Check(not PWebCocoaResolveAssetUri('pweb://app/index.html', nil, asset),
    'nil store accepted');
end;

procedure TTestCocoaAdapter.CanonicalUriResolution;
var
  asset: TAssetResponse;
begin
  // the one root mapping lives in the URI layer, and the adapter gets it for
  // free by handing over the whole URI
  Check(PWebCocoaResolveAssetUri('pweb://app/', fStore, asset),
    'root URI refused');
  Check(asset.Content = CorpusBytes('index.html'), 'root bytes differ');
  Check(PWebCocoaResolveAssetUri('pweb://app', fStore, asset),
    'bare authority refused');
  Check(asset.Content = CorpusBytes('index.html'), 'bare bytes differ');
  Check(PWebCocoaResolveAssetUri('pweb://app/assets/app.js', fStore, asset),
    'subresource refused');
  Check(asset.Content = CorpusBytes('assets/app.js'), 'js bytes differ');
  // scheme and authority are case-insensitive per RFC 3986; the PATH is not
  Check(PWebCocoaResolveAssetUri('PWEB://APP/index.html', fStore, asset),
    'case-insensitive scheme/authority refused');
  Check(not PWebCocoaResolveAssetUri('pweb://app/Index.html', fStore, asset),
    'path case was folded');
  // the ratified order is decode ONCE then validate, so a single escape
  // resolves to the plain character
  Check(PWebCocoaResolveAssetUri('pweb://app/index%2ehtml', fStore, asset),
    'single-decode %2e refused');
  Check(asset.Content = CorpusBytes('index.html'), 'decoded bytes differ');
  Check(PWebCocoaResolveAssetUri('pweb://app/assets%2Fapp.js', fStore, asset),
    'decoded %2F separator refused');
  Check(asset.Content = CorpusBytes('assets/app.js'),
    'decoded separator bytes differ');
  // query and fragment are cut before decoding
  Check(PWebCocoaResolveAssetUri('pweb://app/notes.txt?v=1', fStore, asset),
    'query not cut');
  Check(asset.Content = CorpusBytes('notes.txt'), 'query bytes differ');
  Check(PWebCocoaResolveAssetUri('pweb://app/notes.txt#top', fStore, asset),
    'fragment not cut');
  // a zero-byte asset is served, never confused with a miss
  Check(PWebCocoaResolveAssetUri('pweb://app/assets/empty.bin', fStore, asset),
    'zero-byte asset refused');
  Check(asset.Content = '', 'zero-byte asset has content');
  // a missing asset is a refusal with no body
  Check(not PWebCocoaResolveAssetUri('pweb://app/missing.txt', fStore, asset),
    'missing asset served');
  Check(asset.Content = '', 'missing asset produced a body');
end;

procedure TTestCocoaAdapter.WrongAuthorityNeverReachesStore;
var
  asset: TAssetResponse;
  before: Integer;
begin
  // The trap this adapter exists to avoid: WebKit hands the handler every
  // pweb:// URL whatever the authority, and [[[task request] URL] path] would
  // report '/index.html' for pweb://evil/index.html - a perfectly
  // canonical-looking path with the authority discarded. Passing the WHOLE
  // absolute URL to PWebParseAppUri is what makes this a refusal.
  before := StoreReads;
  Check(not PWebCocoaResolveAssetUri('pweb://evil/index.html', fStore, asset),
    'wrong authority served');
  CheckEqual(StoreReads, before, 'wrong authority reached the store');
  // the control: the identical path under the right authority resolves, so
  // the refusal above is about the authority and nothing else
  Check(PWebCocoaResolveAssetUri('pweb://app/index.html', fStore, asset),
    'control request refused');
  CheckEqual(StoreReads, before + 1, 'control did not reach the store');
end;

procedure TTestCocoaAdapter.ContentTypeParity;
var
  asset: TAssetResponse;
begin
  Check(PWebCocoaResolveAssetUri('pweb://app/', fStore, asset));
  CheckEqual(PWebCocoaContentType(asset), PWebAssetMimeType('index.html'));
  CheckEqual(PWebCocoaContentType(asset), 'text/html; charset=utf-8');
  Check(PWebCocoaResolveAssetUri('pweb://app/assets/app.js', fStore, asset));
  CheckEqual(PWebCocoaContentType(asset), 'text/javascript; charset=utf-8');
  Check(PWebCocoaResolveAssetUri('pweb://app/assets/app.css', fStore, asset));
  CheckEqual(PWebCocoaContentType(asset), 'text/css; charset=utf-8');
  Check(PWebCocoaResolveAssetUri('pweb://app/notes.txt', fStore, asset));
  CheckEqual(PWebCocoaContentType(asset), 'text/plain; charset=utf-8');
  Check(PWebCocoaResolveAssetUri('pweb://app/assets/empty.bin', fStore, asset));
  CheckEqual(PWebCocoaContentType(asset), PWEB_ASSET_FALLBACK_MIME);
  // an empty type can never be served: it would let the engine sniff
  asset.ContentType := '';
  CheckEqual(PWebCocoaContentType(asset), PWEB_ASSET_FALLBACK_MIME);
  // and it must fit the fixed seam buffer, or the request is REFUSED rather
  // than served with a truncated type
  Check(Length(PWebCocoaContentType(asset)) < PWEB_COCOA_CONTENT_TYPE_MAX,
    'the fallback MIME does not fit the seam buffer');
end;

procedure TTestCocoaAdapter.ResponseBodyLifetime;
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

  Check(PWebCocoaCopyBody(source, body, size), 'body copy failed');
  CheckEqual(size, Length(source), 'copied length differs');
  Check(body <> nil, 'body pointer is nil');
  Check(body <> pointer(source),
    'the response body ALIASES the Pascal string instead of copying it');
  // poison and release the source exactly as the callback frame does when it
  // returns: a body that pointed here would now be reading garbage
  FillChar(pointer(source)^, Length(source), $5A);
  source := '';
  SetString(readback, PAnsiChar(body), size);
  for i := 1 to Length(readback) do
    CheckUtf8(readback[i] = AnsiChar((i - 1) and 255),
      'bridge-owned body byte % survived poisoning as %',
      [i, Ord(readback[i])]);
  PWebCocoaReleaseBody(body);

  // a zero-byte asset still gets a real, non-nil allocation with an honest
  // length: handing nil across the seam is not the same thing as serving an
  // empty asset, and the two must never be confusable
  Check(PWebCocoaResolveAssetUri('pweb://app/assets/empty.bin', fStore, asset),
    'zero-byte asset refused');
  Check(PWebCocoaCopyBody(asset.Content, body, size),
    'zero-byte body copy failed');
  CheckEqual(size, 0, 'zero-byte body has a length');
  Check(body <> nil, 'zero-byte body must still be a real allocation');
  PWebCocoaReleaseBody(body);
end;

procedure TTestCocoaAdapter.HandleRegistryGenerations;
var
  first, second: TCocoaAssetHandler;
  h1, h2: TPWebCocoaHandle;
  raised: Boolean;
begin
  CheckEqual(PWebCocoaRegistryCount, 0,
    'the handler registry was not empty when this case started');

  first := TCocoaAssetHandler.Create(fStore);
  try
    h1 := first.Handle;
    Check(h1 <> 0, 'no handle was claimed');
    Check(PWebCocoaHandleResolves(h1), 'a live handle does not resolve');
    CheckEqual(PWebCocoaRegistryCount, 1, 'registry count after one claim');

    // the seam is process-wide: two LIVE handlers would both be served by a
    // single callback that can only consult one store, so a second arm is
    // refused loudly rather than resolved in someone's favour
    raised := False;
    second := nil;
    try
      second := TCocoaAssetHandler.Create(fStore);
    except
      on EPWebCocoaAssetHandler do
        raised := True;
    end;
    if second <> nil then
    begin
      second.Detach;
      second.Free;
    end;
    Check(raised, 'a second live pweb://app handler was accepted');

    // Attach must REFUSE while the seam has not run: there is no webview in
    // this process, so the invocation counter cannot have moved
    raised := False;
    try
      // any non-nil handle: Attach must refuse on the SEAM COUNTER, before it
      // ever looks at what it was handed
      first.Attach(webview_t(Pointer(first)));
    except
      on EPWebCocoaAssetHandler do
        raised := True;
    end;
    Check(raised, 'Attach accepted a webview the seam never ran for');
    Check(not first.Attached, 'a refused Attach still marked the handler');
  finally
    first.Detach;
  end;
  Check(not PWebCocoaHandleResolves(h1),
    'a detached handle still resolves');
  CheckEqual(PWebCocoaRegistryCount, 0, 'registry count after release');
  first.Free;

  // THE property that makes "no callback after destruction" structural: the
  // slot is re-occupied, and the OLD handle still does not resolve, because
  // the generation moved on both release and claim.
  second := TCocoaAssetHandler.Create(fStore);
  try
    h2 := second.Handle;
    Check(h2 <> h1, 'the reused slot minted the same handle');
    Check(PWebCocoaHandleResolves(h2), 'the new handle does not resolve');
    Check(not PWebCocoaHandleResolves(h1),
      'a released handle resolved again once its slot was re-occupied');
  finally
    second.Detach;
    second.Free;
  end;
  CheckEqual(PWebCocoaRegistryCount, 0, 'registry not empty at case end');
end;

procedure TTestCocoaAdapter.SeamConfinement;
var
  handler: TCocoaAssetHandler;
begin
  // THE SINGLE MOST DANGEROUS LINE IN THIS SHARD, made checkable.
  //
  // The seam is installed with class_addMethod on WKWebViewConfiguration's OWN
  // metaclass. The trap it avoids is that class_getClassMethod would have
  // returned NSObject's INHERITED +new, and setting THAT implementation would
  // have swizzled +new for every class in the process - every NSString,
  // every NSArray, every third-party class - which would look perfectly fine
  // in every other test here.
  //
  // Constructing a handler is what installs the seam, so the assertion has to
  // happen with one alive.
  handler := TCocoaAssetHandler.Create(fStore);
  try
    Check(PWebCocoaSeamIsConfined,
      'the +[WKWebViewConfiguration new] override is NOT confined to that ' +
      'class: either its metaclass does not carry our implementation, or ' +
      'NSObject''s does, or an unrelated +new reached the seam');
  finally
    handler.Detach;
    handler.Free;
  end;
  CheckEqual(PWebCocoaRegistryCount, 0, 'registry not empty at case end');
end;

procedure TTestCocoaAdapter.TaskStateMachine;
var
  handler: TCocoaAssetHandler;
  handle: TPWebCocoaHandle;
  task: QWord;
  outcome: TPWebCocoaStubOutcome;
  before, after: TPWebCocoaStats;
  reads: Integer;
  expected: RawByteString;
begin
  task := 0;
  expected := CorpusBytes('index.html');
  handler := TCocoaAssetHandler.Create(fStore);
  handle := handler.Handle;
  // TWO nested guards, and both are needed. The inner one disowns the
  // process-wide seam whatever happens; the outer one frees the object. A
  // raising Check must not leave a handler armed - every case that ran after
  // it would then fail to Create with "already armed", turning one failure
  // into a cascade that hides its own cause.
  try
  try
    // --- P3/P5/P6: a served task gets an NSHTTPURLResponse 200 -------------
    task := PWebCocoaStubCreate('pweb://app/index.html');
    Check(task <> 0, 'stub task could not be created');
    try
      PWebCocoaStubStart(task);
      outcome := PWebCocoaStubOutcome(task);
      CheckEqual(outcome.ResponseStatus, 200,
        'a served task did not get an NSHTTPURLResponse 200 - a bare '
        + 'NSURLResponse loads but reports status 0 to fetch()');
      Check(outcome.ResponseLength = Length(expected),
        'Content-Length disagrees with the body');
      Check(outcome.ReceivedBytes = Length(expected),
        'the delivered body length disagrees with the asset');
      CheckEqual(outcome.Finished, 1, 'a served task did not finish');
      CheckEqual(outcome.Failed, 0, 'a served task also failed');
      CheckEqual(outcome.MisuseRaised, 0,
        'the stub raised on a served task');

      // --- P12: a second terminal is suppressed by the claim gate ---------
      before := PWebCocoaStats;
      PWebCocoaStubDeliverAgain(task);
      after := PWebCocoaStats;
      Check(after.SuppressedTerminals = before.SuppressedTerminals + 1,
        'the second terminal was not recorded as suppressed');
      outcome := PWebCocoaStubOutcome(task);
      CheckEqual(outcome.MisuseRaised, 0,
        'a second terminal reached the task - the claim gate leaked');
      Check(after.CaughtExceptions = before.CaughtExceptions,
        'an exception crossed the bridge boundary');
    finally
      PWebCocoaStubRelease(task);
    end;

    // --- P8: a wrong authority is refused and costs no store lookup -------
    reads := StoreReads;
    task := PWebCocoaStubCreate('pweb://evil/index.html');
    try
      PWebCocoaStubStart(task);
      outcome := PWebCocoaStubOutcome(task);
      CheckEqual(outcome.Failed, 1, 'a wrong authority was not refused');
      CheckEqual(outcome.ResponseStatus, 0,
        'a refusal carried a response');
      Check(outcome.ReceivedBytes = 0, 'a refusal carried a body');
      CheckEqual(StoreReads, reads,
        'a wrong-authority request reached IAssetStore');
    finally
      PWebCocoaStubRelease(task);
    end;

    // --- P13/P14: post-stop suppression and idempotent cancel -------------
    task := PWebCocoaStubCreate('pweb://app/index.html');
    try
      PWebCocoaStubLeaveLive(task);
      before := PWebCocoaStats;
      PWebCocoaStubStop(task);
      after := PWebCocoaStats;
      Check(after.TasksStopped = before.TasksStopped + 1,
        'the first stop did not claim the task');
      before := after;
      PWebCocoaStubStop(task); // P14: the second stop is a no-op
      after := PWebCocoaStats;
      Check(after.TasksStopped = before.TasksStopped,
        'the second stop claimed the task again');
      Check(after.StopsIgnored = before.StopsIgnored + 1,
        'the second stop was not recorded as ignored');
      // C5: the four states are LOAD-BEARING, not decorative. This task was
      // left in New (never served), so cancelling it must NOT count as a stop
      // of a SERVING task - the counter that a future chunked delivery is
      // expected to move and a synchronous handler cannot.
      Check(after.StopsWhileServing = before.StopsWhileServing,
        'a stop of a NEW task was filed as a stop of a SERVING task');
      // P13: a callback attempted after the stop is suppressed BEFORE the
      // call is made - never merely caught afterwards
      before := after;
      PWebCocoaStubDeliverAgain(task);
      after := PWebCocoaStats;
      Check(after.SuppressedTerminals = before.SuppressedTerminals + 1,
        'a post-stop delivery was not suppressed');
      outcome := PWebCocoaStubOutcome(task);
      CheckEqual(outcome.Finished, 0, 'a post-stop delivery reached the task');
      CheckEqual(outcome.MisuseRaised, 0,
        'the post-stop delivery raised - it was not suppressed, only caught');
    finally
      PWebCocoaStubRelease(task);
    end;

    // --- P16: teardown with the live-task set non-empty --------------------
    // A synchronous handler never leaves a task live on its own, which is
    // precisely why this state has to be created deliberately: an assertion
    // that can never be reached is not an assertion.
    task := PWebCocoaStubCreate('pweb://app/index.html');
    Check(task <> 0, 'stub task could not be created');
    PWebCocoaStubLeaveLive(task);
    Check(PWebCocoaStats.LiveTasks >= 1, 'the task was not tracked');
  finally
    handler.Detach;
  end;
  outcome := PWebCocoaStubOutcome(task);
  CheckEqual(outcome.Failed, 1, 'teardown left a live task uncompleted');
  CheckEqual(outcome.MisuseRaised, 0, 'teardown raised on a live task');
  Check(PWebCocoaStats.LiveTasks = 0, 'the live-task set was not emptied');
  Check(not PWebCocoaHandleResolves(handle),
    'the handle still resolves after Detach');
  PWebCocoaStubRelease(task);

  // --- P15: a task arriving after Detach is refused, and NO callback
  //          reaches Pascal at all --------------------------------------
  reads := StoreReads;
  before := PWebCocoaStats;
  task := PWebCocoaStubCreate('pweb://app/index.html');
  try
    PWebCocoaStubStart(task);
    outcome := PWebCocoaStubOutcome(task);
    CheckEqual(outcome.Failed, 1, 'a disowned handler served a task');
    Check(outcome.ReceivedBytes = 0, 'a disowned handler produced a body');
    CheckEqual(StoreReads, reads,
      'a disowned handler still reached IAssetStore');
    after := PWebCocoaStats;
    Check(after.CaughtExceptions = before.CaughtExceptions,
      'an exception crossed the boundary of a disowned handler');
  finally
    PWebCocoaStubRelease(task);
  end;
  finally
    handler.Free;
  end;
end;

end.
