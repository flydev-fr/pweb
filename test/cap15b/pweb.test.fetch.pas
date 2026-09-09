{
  pweb.test.fetch - the CAP-15B suite over the native outbound door
  (mormot.core.test).

  FOUR SUBJECTS, ONE FILE, ALL FOUR TARGETS, AND NOT ONE SOCKET:

    GRAMMAR   the origin parser and its canonicalization (G1-G14), which is
              the SAME function the descriptor reader, the doctor, the build
              refusal and the running decorator all call;
    REQUEST   the whole §4 request contract driven end to end through an
              INJECTED transport (R1-R24) - method, headers, body, deadline,
              URL bytes and the allowlist comparison;
    RESPONSE  the §5 envelope, the response-header allowlist, the two inline
              caps and the three typed refusals (E1-E12);
    POLICY    CAP-15B rider 2: the real TPWebCapabilityPolicy and the real
              scheduler, so "forbidden with ZERO transport" is measured
              rather than reasoned about (P1-P5).

  WHY THERE IS NO SOCKET HERE, and why that is a strength rather than a
  compromise. §1 splits the decorator from its transport precisely so that
  the DECISION - the grammar, the allowlist, the bounds, the deadline, the
  envelope - can be driven with a transport that counts calls and returns
  scripted bytes. A gate that needed a server to prove that an unlisted
  header is refused would be a gate that proved it about a server. The
  transport ITSELF is measured live, against a real local server, by
  test/cap15b/fetchlive.pas, and on Darwin by the §10 probe.

  ZERO TRANSPORT IS A COUNTER, NOT AN ABSENCE. FakeCalls is incremented on
  every entry to the injected transport, so every refusal row asserts a
  NUMBER rather than the lack of an observation - which is the only way
  "the origin allowlist refused before a socket could exist" can fail
  loudly if somebody ever moves the check.

  It emits build/cap15b/fetch-corpus.txt: every DECISION this suite made,
  one LF line each. The CAP-7F emitters hash it into fetch_corpus_digest and
  the aggregator requires the four targets to produce the same bytes. Every
  line is the verdict of platform-independent logic, so equality is a
  property rather than a hope, and the file deliberately carries no path, no
  version and no timing.
}

{$I mormot.defines.inc}

unit pweb.test.fetch;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.json,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.fetch,
  pweb.capabilities.policy;

type
  TTestPWebFetchGrammar = class(TSynTestCase)
  published
    procedure OriginGrammar;
    procedure OriginCanonicalization;
    procedure OriginSetBounds;
    procedure AllowlistDigest;
  end;

  TTestPWebFetchRequest = class(TSynTestCase)
  published
    procedure UrlBytesAndShape;
    procedure OriginMatching;
    procedure Methods;
    procedure Headers;
    procedure BodyAndDeadline;
    procedure OneCallOneHit;
    procedure DeadlineReachesTheTransport;
  end;

  TTestPWebFetchResponse = class(TSynTestCase)
  published
    procedure Envelope;
    procedure ResponseHeaderAllowlist;
    procedure RedirectIsReturnedNotFollowed;
    procedure InlineCapsAndRefusals;
    procedure TransportOutcomes;
  end;

  TTestPWebFetchPolicy = class(TSynTestCase)
  published
    procedure GrantedReachesTheDoor;
    procedure RevokedIsForbiddenWithZeroTransport;
    procedure AbsentFromAppMaximumIsForbidden;
  end;

const
  /// the file the CAP-7F emitters hash into fetch_corpus_digest
  PWEB_CAP15B_CORPUS_FILE = 'build/cap15b/fetch-corpus.txt';

implementation

var
  /// every decision this suite made, in emission order
  Corpus: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

{ ---------------------------------------------------------------------------
  the injected transport

  It opens nothing. It counts, it records what it was handed, and it returns
  whatever the current script says - which is what lets every row of §4 and
  §5 be a decision of the DECORATOR rather than of a server somebody had to
  keep running.
  --------------------------------------------------------------------------- }

var
  FakeCalls: Integer;
  FakeSeen: TPWebFetchRequest;
  FakeTokenObserved: Boolean;
  FakeDeadlineSeen: Integer;
  FakeMaxSeen: PtrInt;
  FakeOutcome: TPWebFetchOutcome;
  FakeStatus: Integer;
  FakeHeaders: RawUtf8;
  FakeBody: RawByteString;
  FakeBytes: Int64;

procedure FakeReset;
begin
  FakeCalls := 0;
  FakeSeen := Default(TPWebFetchRequest);
  FakeTokenObserved := False;
  FakeDeadlineSeen := 0;
  FakeMaxSeen := 0;
  FakeOutcome := pfoOk;
  FakeStatus := 200;
  FakeHeaders := 'Content-Type: application/json'#13#10;
  FakeBody := '{"ok":true}';
  FakeBytes := Length(FakeBody);
end;

function FakeTransport(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;
begin
  Inc(FakeCalls);
  FakeSeen := Request;
  FakeDeadlineSeen := Request.DeadlineMs;
  FakeMaxSeen := Request.MaxResponseBytes;
  // THE TOKEN IS REACHED, and the row that matters is that it is reached
  // HERE - inside the transfer - rather than only before the call. The real
  // mid-transfer behaviour of each transport is measured live; what this
  // asserts is that the SEAM carries the token at all, without which no
  // transport could observe one
  FakeTokenObserved := Token <> nil;
  Response := Default(TPWebFetchResponse);
  Response.Status := FakeStatus;
  Response.Headers := FakeHeaders;
  Response.Body := FakeBody;
  Response.Bytes := FakeBytes;
  Response.Ms := 7;
  Result := FakeOutcome;
end;

type
  { the inner bridge: it must never be reached by pweb.fetch, and it counts
    so that "the decorator delegated everything else verbatim" is a number }
  TInnerCounter = class(TInterfacedObject, IInvocationBridge)
  public
    Calls: Integer;
    LastMethod: Utf8String;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TNoToken = class(TInterfacedObject, ICancellationToken)
  public
    function IsCancelled: Boolean;
  end;

function TInnerCounter.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  Inc(Calls);
  LastMethod := Method;
  Result := PWebSuccessResult('"inner"');
end;

function TNoToken.IsCancelled: Boolean;
begin
  Result := False;
end;

const
  ORIGINS: array[0 .. 2] of RawUtf8 = (
    'https://api.example.com',
    'https://auth.example.com:8443',
    'https://cdn.example.com:443');

function TestContext: TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := 'main';
  Result.PrincipalId := 'window:main';
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
end;

// the context a real binding builds: the identity, plus the PER-INVOCATION
// effective-set snapshot the CAP-8A policy computes. Taking it here rather
// than once per test is not a detail - it is what makes a runtime
// revocation observable at all
function PolicyContext(Policy: TPWebCapabilityPolicy): TInvocationContext;
begin
  Result := TestContext;
  Result.Capabilities := Policy.SnapshotCapabilities('window:main', 'main');
end;

// drive ONE pweb.fetch through a freshly built decorator, and return the
// result plus the number of times the transport was entered
function CallFetch(const Args: TPWebJson; out Calls: Integer):
  TPWebInvocationResult;
var
  inner: TInnerCounter;
  innerRef: IInvocationBridge;
  bridge: IInvocationBridge;
  token: ICancellationToken;
begin
  // NO FakeReset HERE: a caller that scripted an outcome would have it
  // wiped between the script and the call, which is how a row about a
  // timeout quietly becomes a row about a success
  inner := TInnerCounter.Create;
  innerRef := inner;
  bridge := TPWebFetchBridge.Create(innerRef, @FakeTransport, ORIGINS);
  token := TNoToken.Create;
  Result := bridge.Invoke(TestContext, PWEB_METHOD_FETCH, Args, token);
  Calls := FakeCalls;
  bridge := nil;
  innerRef := nil;
end;

function ErrorCodeOf(const R: TPWebInvocationResult): RawUtf8;
begin
  if R.Kind = prkSuccess then
    Result := 'success'
  else
    Result := PWEB_ERROR_CODE_TEXT[R.Error.Code];
end;

// one refusal row: the code, and the number of transport entries, which for
// every refusal below must be zero
procedure CheckRefused(Test: TSynTestCase; const Tag: RawUtf8;
  const Args: TPWebJson; const Expected: RawUtf8);
var
  r: TPWebInvocationResult;
  calls: Integer;
begin
  FakeReset;
  r := CallFetch(Args, calls);
  Test.Check(ErrorCodeOf(r) = Expected,
    string(Tag) + ': expected ' + string(Expected) + ', got ' +
    string(ErrorCodeOf(r)));
  Test.Check(calls = 0, string(Tag) + ': the transport was entered');
  Record_('request|' + Tag + '|' + ErrorCodeOf(r) + '|calls=' +
    RawUtf8(IntToStr(calls)));
end;

procedure CheckAccepted(Test: TSynTestCase; const Tag: RawUtf8;
  const Args: TPWebJson);
var
  r: TPWebInvocationResult;
  calls: Integer;
begin
  FakeReset;
  r := CallFetch(Args, calls);
  Test.Check(r.Kind = prkSuccess, string(Tag) + ': refused - ' +
    string(ErrorCodeOf(r)));
  Test.Check(calls = 1, string(Tag) + ': one call must be one wire hit');
  Record_('request|' + Tag + '|success|calls=' + RawUtf8(IntToStr(calls)));
end;

{ ---------------------------------------------------------------------------
  GRAMMAR
  --------------------------------------------------------------------------- }

procedure TTestPWebFetchGrammar.OriginGrammar;

  procedure Accepts(const Text: RawUtf8);
  var
    o: TPWebFetchOrigin;
  begin
    Check(PWebFetchParseOrigin(Text, o), 'origin refused: ' + string(Text));
    Record_('origin|accept|' + Text + '|' + PWebFetchOriginText(o));
  end;

  procedure Refuses(const Tag, Text: RawUtf8);
  var
    o: TPWebFetchOrigin;
  begin
    Check(not PWebFetchParseOrigin(Text, o),
      'origin accepted: ' + string(Text));
    Record_('origin|refuse|' + Tag);
  end;

begin
  // G1: the ratified shape
  Accepts('https://api.example.com');
  Accepts('https://api.example.com:8443');
  Accepts('https://xn--bcher-kva.example');   // punycode IS the spelling
  Accepts('https://a.b.c.d.example.com');
  // G2: the DEVELOPMENT loopback exception, and its exact shape
  Accepts('http://127.0.0.1:5173');
  Accepts('http://localhost:5173');
  Refuses('loopback-no-port', 'http://127.0.0.1');
  Refuses('loopback-no-port-name', 'http://localhost');
  Refuses('http-non-loopback', 'http://api.example.com:80');
  // G3: everything an origin is not
  Refuses('path', 'https://api.example.com/');
  Refuses('path-deep', 'https://api.example.com/v1');
  Refuses('query', 'https://api.example.com?a=1');
  Refuses('fragment', 'https://api.example.com#f');
  Refuses('userinfo', 'https://user@api.example.com');
  Refuses('userinfo-lookalike', 'https://api.example.com@evil.example');
  Refuses('wildcard', 'https://*.example.com');
  Refuses('star', '*');
  Refuses('uppercase-host', 'https://API.example.com');
  Refuses('uppercase-scheme', 'HTTPS://api.example.com');
  Refuses('trailing-dot', 'https://api.example.com.');
  Refuses('empty-label', 'https://api..example.com');
  Refuses('leading-hyphen', 'https://-api.example.com');
  Refuses('trailing-hyphen', 'https://api-.example.com');
  Refuses('empty-authority', 'https:///x');
  Refuses('scheme-only', 'https://');
  Refuses('no-scheme', 'api.example.com');
  Refuses('ws', 'wss://api.example.com');
  Refuses('file', 'file://api.example.com');
  Refuses('ipv6', 'https://[::1]:8443');
  Refuses('port-zero', 'https://api.example.com:0');
  Refuses('port-huge', 'https://api.example.com:65536');
  Refuses('port-leading-zero', 'https://api.example.com:08443');
  Refuses('port-empty', 'https://api.example.com:');
  Refuses('cr', 'https://api.example.com'#13);
  Refuses('lf', 'https://api.example.com'#10);
  Refuses('nul', 'https://api.example.com'#0);
  Refuses('space', 'https://api example.com');
  Refuses('high-byte', 'https://api.example.com'#$C3#$A9);
  Refuses('empty', '');
end;

procedure TTestPWebFetchGrammar.OriginCanonicalization;
var
  a, b: TPWebFetchOrigin;
begin
  // G4: THE DEFAULT PORT IS CANONICALISED AWAY, ON BOTH SIDES
  Check(PWebFetchParseOrigin('https://api.example.com', a), 'implicit');
  Check(PWebFetchParseOrigin('https://api.example.com:443', b), 'explicit');
  Check(PWebFetchSameOrigin(a, b), 'implicit 443 <> explicit 443');
  CheckEqual(PWebFetchOriginText(a), 'https://api.example.com');
  CheckEqual(PWebFetchOriginText(b), 'https://api.example.com');
  Record_('origin|canonical|https-443|' + PWebFetchOriginText(b));
  Check(PWebFetchParseOrigin('http://localhost:80', a), 'http 80');
  CheckEqual(PWebFetchOriginText(a), 'http://localhost');
  Record_('origin|canonical|http-80|' + PWebFetchOriginText(a));
  // a port that is NOT the default survives
  Check(PWebFetchParseOrigin('https://api.example.com:8443', a), '8443');
  CheckEqual(PWebFetchOriginText(a), 'https://api.example.com:8443');
  // G5: the loopback predicate names exactly the ratified two hosts
  Check(PWebFetchParseOrigin('http://127.0.0.1:5173', a), 'loopback ip');
  Check(PWebFetchOriginIsLoopbackHttp(a), 'loopback ip not recognised');
  Check(PWebFetchParseOrigin('https://api.example.com', b), 'https');
  Check(not PWebFetchOriginIsLoopbackHttp(b), 'https read as loopback');
  Record_('origin|loopback|http-127.0.0.1|true');
end;

procedure TTestPWebFetchGrammar.OriginSetBounds;
var
  parsed: TPWebFetchOrigins;
  refusal: TPWebFetchOriginsRefusal;
  detail: RawUtf8;
  nine: array[0 .. 8] of RawUtf8;
  i: PtrInt;
begin
  // G6: at most eight
  for i := 0 to High(nine) do
    nine[i] := 'https://h' + RawUtf8(IntToStr(i)) + '.example.com';
  Check(not PWebFetchParseOrigins(nine, parsed, refusal, detail), 'nine');
  Check(refusal = pforCount, 'nine origins is not a count refusal');
  Record_('originset|count|' + detail);
  // G7: a duplicate AFTER canonicalization
  Check(not PWebFetchParseOrigins(
    ['https://a.example', 'https://a.example:443'], parsed, refusal, detail),
    'canonical duplicate accepted');
  Check(refusal = pforDuplicate, 'not a duplicate refusal');
  Record_('originset|duplicate|' + detail);
  // G8: one bad entry refuses the whole set, by name
  Check(not PWebFetchParseOrigins(
    ['https://a.example', 'http://b.example'], parsed, refusal, detail),
    'bad entry accepted');
  Check(refusal = pforGrammar, 'not a grammar refusal');
  CheckEqual(detail, 'http://b.example');
  Record_('originset|grammar|' + detail);
  // G9: the accepted set is SORTED, so a digest is a function of the set
  Check(PWebFetchParseOrigins(
    ['https://c.example', 'https://a.example', 'https://b.example'],
    parsed, refusal, detail), 'three refused');
  CheckEqual(Length(parsed), 3);
  CheckEqual(PWebFetchOriginText(parsed[0]), 'https://a.example');
  CheckEqual(PWebFetchOriginText(parsed[2]), 'https://c.example');
  Record_('originset|sorted|' + PWebFetchOriginText(parsed[0]) + ',' +
    PWebFetchOriginText(parsed[1]) + ',' + PWebFetchOriginText(parsed[2]));
  // G10: the EMPTY set is a set
  Check(PWebFetchParseOrigins([], parsed, refusal, detail), 'empty refused');
  CheckEqual(Length(parsed), 0);
end;

procedure TTestPWebFetchGrammar.AllowlistDigest;
var
  a, b: RawUtf8;
begin
  // G11: the digest is a function of the SET, not of the spelling or the
  // order somebody typed it in - which is what makes declared == compiled
  // a comparison rather than a coincidence
  a := PWebFetchDeclaredDigest(['https://a.example', 'https://b.example']);
  b := PWebFetchDeclaredDigest(['https://b.example:443', 'https://a.example']);
  CheckEqual(a, b, 'the digest depends on order or spelling');
  Check(a <> '', 'no digest');
  Record_('digest|order-and-spelling-independent|true');
  // G12: a different set is a different digest
  Check(a <> PWebFetchDeclaredDigest(['https://a.example']), 'collision');
  // G13: the empty set has the digest of the empty string, and it is a
  // real value rather than an empty one
  CheckEqual(PWebFetchDeclaredDigest([]),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  Record_('digest|empty-set|' + PWebFetchDeclaredDigest([]));
  // G14: a malformed literal yields NOTHING rather than a plausible hash
  CheckEqual(PWebFetchDeclaredDigest(['http://evil.example']), '');
end;

{ ---------------------------------------------------------------------------
  REQUEST
  --------------------------------------------------------------------------- }

function ArgsUrl(const Url: RawUtf8): TPWebJson;
begin
  Result := TPWebJson('{"url":' + QuotedStrJson(Url) + '}');
end;

procedure TTestPWebFetchRequest.UrlBytesAndShape;
begin
  // R1: the WHOLE url is byte-checked BEFORE it is parsed - a request
  // target is as splittable as a header value, and the CAP-15A spike
  // checked only the headers
  CheckRefused(self, 'url-cr',
    TPWebJson('{"url":"https://api.example.com/a\r\nX: y"}'),
    'invalid_request');
  CheckRefused(self, 'url-lf',
    TPWebJson('{"url":"https://api.example.com/a\nX: y"}'),
    'invalid_request');
  CheckRefused(self, 'url-nul',
    TPWebJson('{"url":"https://api.example.com/a b"}'),
    'invalid_request');
  CheckRefused(self, 'url-space',
    ArgsUrl('https://api.example.com/a b'), 'invalid_request');
  CheckRefused(self, 'url-high-byte',
    TPWebJson('{"url":"https://api.example.com/café"}'),
    'invalid_request');
  // R2: shapes an absolute request target is not
  CheckRefused(self, 'url-relative', ArgsUrl('/v1/things'), 'invalid_request');
  CheckRefused(self, 'url-scheme-file',
    ArgsUrl('file:///etc/passwd'), 'invalid_request');
  CheckRefused(self, 'url-userinfo',
    ArgsUrl('https://api.example.com@evil.example/v1'), 'invalid_request');
  CheckRefused(self, 'url-fragment',
    ArgsUrl('https://api.example.com/v1#f'), 'invalid_request');
  CheckRefused(self, 'url-missing',
    TPWebJson('{"method":"GET"}'), 'invalid_request');
  CheckRefused(self, 'url-not-a-string',
    TPWebJson('{"url":42}'), 'invalid_request');
  CheckRefused(self, 'url-object',
    TPWebJson('{"url":{"a":1}}'), 'invalid_request');
  // R3: an argument this door does not define is a refusal, never a value
  // to ignore - a caller who misspelled timeoutMs must learn so here
  CheckRefused(self, 'unknown-arg',
    TPWebJson('{"url":"https://api.example.com/v1","timeout":5}'),
    'invalid_request');
  // R4: and the target itself is bounded
  CheckRefused(self, 'url-too-long',
    ArgsUrl('https://api.example.com/' + RawUtf8(StringOfChar('a', 2100))),
    'invalid_request');
  // the accepted shape, for contrast
  CheckAccepted(self, 'url-ok', ArgsUrl('https://api.example.com/v1/things'));
  CheckAccepted(self, 'url-no-path', ArgsUrl('https://api.example.com'));
end;

procedure TTestPWebFetchRequest.OriginMatching;
begin
  // R5: BY PARSED COMPONENTS, never by prefix. Every row here is a URL a
  // substring test would have accepted
  CheckRefused(self, 'origin-prefix-attack',
    ArgsUrl('https://api.example.com.evil.test/v1'), 'invalid_request');
  CheckRefused(self, 'origin-prefix-suffix',
    ArgsUrl('https://evil.test/https://api.example.com'), 'invalid_request');
  CheckRefused(self, 'origin-subdomain',
    ArgsUrl('https://sub.api.example.com/v1'), 'invalid_request');
  // R6: a port-only difference is a different origin
  CheckRefused(self, 'origin-port-only',
    ArgsUrl('https://api.example.com:8443/v1'), 'invalid_request');
  CheckRefused(self, 'origin-declared-port-omitted',
    ArgsUrl('https://auth.example.com/v1'), 'invalid_request');
  // R7: the scheme is part of the comparison, so a dev-only origin can
  // never match an https request or the reverse
  CheckRefused(self, 'origin-scheme-mismatch',
    ArgsUrl('http://api.example.com/v1'), 'invalid_request');
  // R8: DEFAULT-PORT CANONICALISATION, BOTH WAYS. `cdn` was declared with
  // an explicit :443 and `api` without one; each must match the other
  // spelling in the URL
  CheckAccepted(self, 'origin-explicit-443-declared-implicit',
    ArgsUrl('https://api.example.com:443/v1'));
  CheckAccepted(self, 'origin-implicit-443-declared-explicit',
    ArgsUrl('https://cdn.example.com/logo.png'));
  CheckAccepted(self, 'origin-explicit-port-declared',
    ArgsUrl('https://auth.example.com:8443/token'));
  // R9: a case variant of a DECLARED host matches (DNS is case-insensitive
  // and every engine lowercases before a hook sees a URI); a case variant
  // of an UNDECLARED one still does not
  CheckAccepted(self, 'origin-host-case',
    ArgsUrl('https://API.Example.COM/v1'));
  CheckRefused(self, 'origin-case-undeclared',
    ArgsUrl('https://EVIL.example/v1'), 'invalid_request');
end;

procedure TTestPWebFetchRequest.Methods;
begin
  // R10: the six, exactly
  CheckAccepted(self, 'method-get',
    TPWebJson('{"url":"https://api.example.com/v1","method":"GET"}'));
  CheckAccepted(self, 'method-post',
    TPWebJson('{"url":"https://api.example.com/v1","method":"POST"}'));
  CheckAccepted(self, 'method-put',
    TPWebJson('{"url":"https://api.example.com/v1","method":"PUT"}'));
  // PATCH IS ACCEPTED - the CAP-15A spike refused it, and §4 marks the row
  // as specified beyond the instrument
  CheckAccepted(self, 'method-patch',
    TPWebJson('{"url":"https://api.example.com/v1","method":"PATCH"}'));
  CheckAccepted(self, 'method-delete',
    TPWebJson('{"url":"https://api.example.com/v1","method":"DELETE"}'));
  CheckAccepted(self, 'method-head',
    TPWebJson('{"url":"https://api.example.com/v1","method":"HEAD"}'));
  // R11: THE COMPARISON IS CASE-SENSITIVE - the spike upper-cased first,
  // and normalising a method is this layer inventing an intent
  CheckRefused(self, 'method-lowercase-patch',
    TPWebJson('{"url":"https://api.example.com/v1","method":"patch"}'),
    'invalid_request');
  CheckRefused(self, 'method-mixed-get',
    TPWebJson('{"url":"https://api.example.com/v1","method":"Get"}'),
    'invalid_request');
  // R12: and nothing outside the six
  CheckRefused(self, 'method-options',
    TPWebJson('{"url":"https://api.example.com/v1","method":"OPTIONS"}'),
    'invalid_request');
  CheckRefused(self, 'method-connect',
    TPWebJson('{"url":"https://api.example.com/v1","method":"CONNECT"}'),
    'invalid_request');
  CheckRefused(self, 'method-not-a-string',
    TPWebJson('{"url":"https://api.example.com/v1","method":7}'),
    'invalid_request');
  // R13: absent means GET
  CheckAccepted(self, 'method-absent', ArgsUrl('https://api.example.com/v1'));
  Check(FakeSeen.Method = 'GET', 'an absent method did not default to GET');
  Record_('request|method-absent-default|' + FakeSeen.Method);
end;

procedure TTestPWebFetchRequest.Headers;
var
  calls: Integer;
  r: TPWebInvocationResult;
begin
  // R14: the allowlist, by name
  CheckAccepted(self, 'header-accept',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"accept":"application/json"}}'));
  CheckAccepted(self, 'header-authorization',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"authorization":"Bearer x"}}'));
  // IF-MATCH IS ACCEPTED - the spike allowed one literal header name
  CheckAccepted(self, 'header-if-match',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"if-match":"\"etag\""}}'));
  CheckAccepted(self, 'header-if-none-match',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"if-none-match":"\"etag\""}}'));
  // AND THE GENERIC x- FAMILY
  CheckAccepted(self, 'header-x-application',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"x-request-id":"abc123"}}'));
  // R15: an unlisted header is refused, and `cookie` above all
  CheckRefused(self, 'header-cookie',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"cookie":"a=b"}}'), 'invalid_request');
  CheckRefused(self, 'header-host',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"host":"evil.example"}}'), 'invalid_request');
  CheckRefused(self, 'header-origin',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"origin":"https://evil.example"}}'), 'invalid_request');
  CheckRefused(self, 'header-user-agent',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"user-agent":"x"}}'), 'invalid_request');
  CheckRefused(self, 'header-content-length',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"content-length":"9"}}'), 'invalid_request');
  // R16: a splitting attempt, refused ON THE BYTES
  CheckRefused(self, 'header-value-crlf',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"x-a":"b\r\nX-Evil: c"}}'), 'invalid_request');
  // MEASURED, and recorded rather than assumed: mORMot's JSON parser
  // decodes an escaped NUL as the byte `?` (0x3F), so a NUL cannot reach a
  // header value through the wire at all and there is nothing here for the
  // byte check to refuse. The row asserts the property that matters - the
  // block that reached the transport carries no NUL and no CR/LF - rather
  // than a refusal the parser upstream has already made impossible. A RAW
  // NUL cannot arrive either: it would have ended the JSON document
  FakeReset;
  r := CallFetch(TPWebJson('{"url":"https://api.example.com/v1",' +
    '"headers":{"x-a":"b c"}}'), calls);
  Check(r.Kind = prkSuccess, 'the escaped-NUL row was refused for some ' +
    'other reason - re-measure before trusting this row');
  Check(Pos(#0, FakeSeen.Headers) = 0, 'a NUL reached the header block');
  Check(Pos(#13, FakeSeen.Headers + 'x') = Length(FakeSeen.Headers) - 1,
    'the header block is not exactly one CRLF-terminated line');
  Record_('request|header-escaped-nul|substituted|no-nul-in-block');
  CheckRefused(self, 'header-name-space',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"x a":"b"}}'), 'invalid_request');
  CheckRefused(self, 'header-name-colon',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"x:a":"b"}}'), 'invalid_request');
  // R17: PRESENT BUT NOT AN OBJECT is invalid_request and NEVER an empty
  // header set - silently dropping every header would let a caller believe
  // an authorization was sent
  CheckRefused(self, 'headers-array',
    TPWebJson('{"url":"https://api.example.com/v1","headers":[]}'),
    'invalid_request');
  CheckRefused(self, 'headers-string',
    TPWebJson('{"url":"https://api.example.com/v1","headers":"accept"}'),
    'invalid_request');
  CheckRefused(self, 'headers-number',
    TPWebJson('{"url":"https://api.example.com/v1","headers":5}'),
    'invalid_request');
  CheckRefused(self, 'headers-value-number',
    TPWebJson('{"url":"https://api.example.com/v1","headers":{"x-a":5}}'),
    'invalid_request');
  // R18: one name, one value
  CheckRefused(self, 'header-repeated',
    TPWebJson('{"url":"https://api.example.com/v1",' +
      '"headers":{"x-a":"1","X-A":"2"}}'), 'invalid_request');
  // R19: content-type crosses SEPARATELY, as the transport's MIME
  r := CallFetch(TPWebJson('{"url":"https://api.example.com/v1",' +
    '"method":"POST","body":"{}",' +
    '"headers":{"content-type":"application/json","x-a":"1"}}'), calls);
  Check(r.Kind = prkSuccess, 'content-type request refused');
  CheckEqual(FakeSeen.Mime, 'application/json');
  Check(Pos('content-type', LowerCaseU(FakeSeen.Headers)) = 0,
    'content-type was ALSO put in the header block');
  Check(Pos('x-a: 1', FakeSeen.Headers) > 0, 'x-a did not reach the block');
  Record_('request|content-type-separate|' + FakeSeen.Mime);
end;

procedure TTestPWebFetchRequest.BodyAndDeadline;
var
  big: RawUtf8;
begin
  // R20: the body ceiling
  big := RawUtf8(StringOfChar('a', PWEB_FETCH_MAX_REQUEST_BODY + 1));
  CheckRefused(self, 'body-over-bound',
    TPWebJson('{"url":"https://api.example.com/v1","method":"POST",' +
      '"body":' + QuotedStrJson(big) + '}'), 'invalid_request');
  CheckAccepted(self, 'body-at-bound',
    TPWebJson('{"url":"https://api.example.com/v1","method":"POST",' +
      '"body":' + QuotedStrJson(RawUtf8(StringOfChar('a',
        PWEB_FETCH_MAX_REQUEST_BODY))) + '}'));
  CheckRefused(self, 'body-not-a-string',
    TPWebJson('{"url":"https://api.example.com/v1","method":"POST",' +
      '"body":{"a":1}}'), 'invalid_request');
  // R21: a body on a bodyless method is a smuggling shape
  CheckRefused(self, 'body-on-get',
    TPWebJson('{"url":"https://api.example.com/v1","body":"x"}'),
    'invalid_request');
  CheckRefused(self, 'body-on-head',
    TPWebJson('{"url":"https://api.example.com/v1","method":"HEAD",' +
      '"body":"x"}'), 'invalid_request');
  // R22: the deadline - default, bounds, and REFUSED rather than clamped
  CheckAccepted(self, 'deadline-absent',
    ArgsUrl('https://api.example.com/v1'));
  CheckEqual(FakeDeadlineSeen, PWEB_FETCH_DEFAULT_DEADLINE_MS);
  Record_('request|deadline-default|' + RawUtf8(IntToStr(FakeDeadlineSeen)));
  CheckAccepted(self, 'deadline-max',
    TPWebJson('{"url":"https://api.example.com/v1","timeoutMs":30000}'));
  CheckEqual(FakeDeadlineSeen, PWEB_FETCH_MAX_DEADLINE_MS);
  CheckRefused(self, 'deadline-over-max',
    TPWebJson('{"url":"https://api.example.com/v1","timeoutMs":30001}'),
    'invalid_request');
  CheckRefused(self, 'deadline-zero',
    TPWebJson('{"url":"https://api.example.com/v1","timeoutMs":0}'),
    'invalid_request');
  CheckRefused(self, 'deadline-negative',
    TPWebJson('{"url":"https://api.example.com/v1","timeoutMs":-1}'),
    'invalid_request');
  CheckRefused(self, 'deadline-not-a-number',
    TPWebJson('{"url":"https://api.example.com/v1","timeoutMs":"5000"}'),
    'invalid_request');
end;

procedure TTestPWebFetchRequest.OneCallOneHit;
var
  calls: Integer;
begin
  // R23: ONE CALL IS ONE WIRE HIT. The CAP-15A spike measured mORMot
  // re-sending a failed request by itself - one pweb.fetch, two hits in the
  // server's log - and for a non-idempotent POST that is a duplicate order.
  // The decorator's half of the answer is that it enters the transport
  // exactly once, whatever the transport then reports
  FakeReset;
  CallFetch(TPWebJson('{"url":"https://api.example.com/v1","method":"POST",' +
    '"body":"{}"}'), calls);
  CheckEqual(calls, 1, 'one pweb.fetch was not one transport entry');
  Record_('request|one-call-one-hit|' + RawUtf8(IntToStr(calls)));
  // and a FAILING transport is still entered once: no retry lives here
  FakeReset;
  FakeOutcome := pfoTransport;
  CallFetch(TPWebJson('{"url":"https://api.example.com/v1"}'), calls);
  CheckEqual(calls, 1, 'a failed exchange was retried');
  Record_('request|no-retry-on-failure|' + RawUtf8(IntToStr(calls)));
end;

procedure TTestPWebFetchRequest.DeadlineReachesTheTransport;
var
  calls: Integer;
begin
  // R24: the SEAM carries the token and the bound to the transport, which
  // is what a transport needs to observe either DURING a transfer. The
  // observation itself is measured live (a slow endpoint) and, on Darwin,
  // by the §10 probe - this row is the half a headless test can own
  FakeReset;
  CallFetch(TPWebJson('{"url":"https://api.example.com/v1",' +
    '"timeoutMs":1234}'), calls);
  Check(FakeTokenObserved, 'the cancellation token did not reach the transport');
  CheckEqual(FakeDeadlineSeen, 1234, 'the deadline did not reach the transport');
  CheckEqual(FakeMaxSeen, PWEB_FETCH_MAX_RESPONSE,
    'the response bound did not reach the transport');
  Record_('request|seam-carries|token=true,deadline=1234,max=' +
    RawUtf8(IntToStr(PWEB_FETCH_MAX_RESPONSE)));
end;

{ ---------------------------------------------------------------------------
  RESPONSE
  --------------------------------------------------------------------------- }

procedure TTestPWebFetchResponse.Envelope;
var
  r: TPWebInvocationResult;
  calls: Integer;
begin
  FakeReset;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'refused');
  // E1: the ratified members, and `truncated` FALSE in every envelope this
  // contract defines
  Check(Pos('"status":200', r.Value) > 0, 'no status');
  Check(Pos('"truncated":false', r.Value) > 0, 'truncated is not false');
  Check(Pos('"bodyText":"{\"ok\":true}"', r.Value) > 0, 'no bodyText');
  Check(Pos('"bodyBase64":null', r.Value) > 0, 'bodyBase64 is not null');
  Check(Pos('"bytes":11', r.Value) > 0, 'no byte count');
  Record_('response|envelope|status=200,truncated=false,text=1,base64=0');
  // E2: a body that is not valid UTF-8 crosses as base64, never as text
  FakeReset;
  FakeBody := RawByteString(#$FF#$FE#$00#$01);
  FakeBytes := 4;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'binary refused');
  Check(Pos('"bodyText":null', r.Value) > 0, 'bodyText is not null');
  Check(Pos('"bodyBase64":"', r.Value) > 0, 'no bodyBase64');
  Record_('response|binary-base64|text=0,base64=1');
end;

procedure TTestPWebFetchResponse.ResponseHeaderAllowlist;
var
  r: TPWebInvocationResult;
  calls: Integer;
  headers: RawUtf8;
begin
  FakeReset;
  FakeStatus := 200;
  FakeHeaders :=
    'Content-Type: application/json'#13#10 +
    'Content-Length: 11'#13#10 +
    'ETag: "v1"'#13#10 +
    'Last-Modified: Tue, 01 Jan 2030 00:00:00 GMT'#13#10 +
    'Retry-After: 12'#13#10 +
    'Location: https://api.example.com/v2'#13#10 +
    'X-Request-Id: abc'#13#10 +
    'Set-Cookie: session=secret; Path=/'#13#10 +
    'Server: nginx'#13#10 +
    'Strict-Transport-Security: max-age=1'#13#10;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'refused');
  headers := LowerCaseU(r.Value);
  // E3: the allowlist, present
  Check(Pos('"content-type"', headers) > 0, 'content-type missing');
  Check(Pos('"content-length"', headers) > 0, 'content-length missing');
  Check(Pos('"etag"', headers) > 0, 'etag missing');
  Check(Pos('"last-modified"', headers) > 0, 'last-modified missing');
  Check(Pos('"retry-after"', headers) > 0, 'retry-after missing');
  Check(Pos('"x-request-id"', headers) > 0, 'x- header missing');
  // LOCATION IS PRESENT, because §4 returns a 3xx with it instead of
  // following it, and an allowlist that omitted it would have promised a
  // redirect the envelope could not carry
  Check(Pos('"location"', headers) > 0, 'location missing');
  // E4: SET-COOKIE IS NEVER EXPOSED, so nothing in JavaScript can
  // reconstruct a jar the runtime refused to keep
  Check(Pos('set-cookie', headers) = 0, 'set-cookie reached the envelope');
  Check(Pos('secret', headers) = 0, 'a cookie value reached the envelope');
  // E5: and everything else is simply absent
  Check(Pos('"server"', headers) = 0, 'server reached the envelope');
  Check(Pos('strict-transport-security', headers) = 0, 'hsts reached it');
  Record_('response|header-allowlist|' +
    'content-type,content-length,etag,last-modified,retry-after,location,x-|' +
    'set-cookie=absent');
  // E6: a repeated allowlisted name is COMBINED in order, per RFC 9110
  FakeReset;
  FakeHeaders := 'X-A: 1'#13#10'X-A: 2'#13#10;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(Pos('"x-a":"1, 2"', LowerCaseU(r.Value)) > 0,
    'a repeated header was not combined in order');
  Record_('response|header-repeated-combined|1, 2');
end;

procedure TTestPWebFetchResponse.RedirectIsReturnedNotFollowed;
var
  r: TPWebInvocationResult;
  calls: Integer;
begin
  // E7: a 3xx is a SUCCESS envelope carrying its Location, and the
  // transport is entered exactly ONCE - following it would leave the
  // allowlist behind, which is the whole reason RedirectMax is 0
  FakeReset;
  FakeStatus := 302;
  FakeHeaders := 'Location: https://evil.example/'#13#10;
  FakeBody := '';
  FakeBytes := 0;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'a 3xx was not returned as an envelope');
  Check(Pos('"status":302', r.Value) > 0, 'the status was rewritten');
  Check(Pos('"location":"https://evil.example/"', r.Value) > 0,
    'the Location did not reach the envelope');
  CheckEqual(calls, 1, 'a redirect was followed');
  Record_('response|redirect-returned|status=302,followed=0');
end;

procedure TTestPWebFetchResponse.InlineCapsAndRefusals;
var
  r: TPWebInvocationResult;
  calls: Integer;
begin
  // E8: a text body AT the inline cap crosses
  FakeReset;
  FakeBody := RawByteString(StringOfChar('a', PWEB_FETCH_MAX_TEXT_INLINE));
  FakeBytes := Length(FakeBody);
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'a body at the inline cap was refused');
  Record_('response|text-at-cap|success');
  // E9: ONE BYTE OVER IT IS A TYPED REFUSAL, never a success with a null
  // body. The CAP-15A spike returned exactly that shape - status 200,
  // truncated false, no bytes - and it is why this row exists
  FakeReset;
  FakeBody := RawByteString(StringOfChar('a', PWEB_FETCH_MAX_TEXT_INLINE + 1));
  FakeBytes := Length(FakeBody);
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkError, 'an over-cap body came back as a success');
  CheckEqual(ErrorCodeOf(r), 'service_error');
  Check(Pos(PWEB_FETCH_CAT_NO_INLINE, r.Error.Data) > 0, 'no category');
  Check(Pos('"inlineMax":1048576', r.Error.Data) > 0, 'no inline bound');
  Check(Pos('"responseMax":8388608', r.Error.Data) > 0, 'no response bound');
  Record_('response|text-over-cap|service_error|' + PWEB_FETCH_CAT_NO_INLINE);
  // E10: the BASE64 cap is smaller, and it is the one a binary body meets
  FakeReset;
  FakeBody := RawByteString(#$FF) +
    RawByteString(StringOfChar('a', PWEB_FETCH_MAX_BASE64_INLINE - 1));
  FakeBytes := Length(FakeBody);
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'a binary body at the base64 cap was refused');
  FakeReset;
  FakeBody := RawByteString(#$FF) +
    RawByteString(StringOfChar('a', PWEB_FETCH_MAX_BASE64_INLINE));
  FakeBytes := Length(FakeBody);
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkError, 'a binary body over the base64 cap crossed');
  Check(Pos('"inlineMax":786432', r.Error.Data) > 0, 'wrong inline bound');
  Record_('response|base64-over-cap|service_error|786432');
end;

procedure TTestPWebFetchResponse.TransportOutcomes;
var
  r: TPWebInvocationResult;
  calls: Integer;
begin
  // E11: a response the transport stopped AT the bound is a typed
  // service_error naming the ceiling - never a truncated body
  FakeReset;
  FakeOutcome := pfoTooLarge;
  FakeBytes := PWEB_FETCH_MAX_RESPONSE + 1;
  FakeBody := '';
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkError, 'an over-bound response came back as a success');
  CheckEqual(ErrorCodeOf(r), 'service_error');
  Check(Pos(PWEB_FETCH_CAT_TOO_LARGE, r.Error.Data) > 0, 'no category');
  Record_('response|over-bound|service_error|' + PWEB_FETCH_CAT_TOO_LARGE);
  // E12: the deadline and a cancellation both complete as `cancelled`
  FakeReset;
  FakeOutcome := pfoTimedOut;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  CheckEqual(ErrorCodeOf(r), 'cancelled');
  Record_('response|deadline|cancelled');
  FakeReset;
  FakeOutcome := pfoCancelled;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  CheckEqual(ErrorCodeOf(r), 'cancelled');
  Record_('response|token|cancelled');
  // and a transport failure is a CATEGORY, never a native detail
  FakeReset;
  FakeOutcome := pfoTransport;
  r := CallFetch(ArgsUrl('https://api.example.com/v1'), calls);
  CheckEqual(ErrorCodeOf(r), 'service_error');
  Check(Pos(PWEB_FETCH_CAT_TRANSPORT, r.Error.Data) > 0, 'no category');
  Check(Pos('Exception', r.Error.Message) = 0, 'a class name leaked');
  Check(Pos('api.example.com', r.Error.Message) = 0, 'the host leaked');
  Record_('response|transport-failure|service_error|' +
    PWEB_FETCH_CAT_TRANSPORT);
end;

{ ---------------------------------------------------------------------------
  POLICY (CAP-15B rider 2)

  The CAP-8A capability corpus is FROZEN and gains nothing here: its digest
  is an acceptance condition of this shard. That freeze must not become a
  coverage hole, so these three legs drive the REAL TPWebCapabilityPolicy
  and the REAL scheduler over their own corpus, and they measure the thing
  the corpus cannot: that a refusal happens BEFORE the bridge, with the
  transport never entered.
  --------------------------------------------------------------------------- }

type
  TPolicySink = class(TInterfacedObject, IInvocationCompletion)
  public
    Done: Boolean;
    Res: TPWebInvocationResult;
    procedure Complete(const AResult: TPWebInvocationResult);
    function Wait(Ms: Integer): Boolean;
  end;

procedure TPolicySink.Complete(const AResult: TPWebInvocationResult);
begin
  Res := AResult;
  Done := True;
end;

function TPolicySink.Wait(Ms: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while (not Done) and (waited < Ms) do
  begin
    Sleep(5);
    Inc(waited, 5);
  end;
  Result := Done;
end;

// build the policy a generated host builds under PWEB_NET, or without the
// capability when WithNetwork is False
function BuildPolicy(WithNetwork: Boolean): TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    if WithNetwork then
    begin
      b.SetAppMaximum(['calculator.add', PWEB_CAP_NETWORK_FETCH]);
      b.SetWindowCapabilities('main',
        ['calculator.add', PWEB_CAP_NETWORK_FETCH]);
      b.SetPrincipalCapabilities('window:main',
        ['calculator.add', PWEB_CAP_NETWORK_FETCH]);
    end
    else
    begin
      // the AppMaximum CEILING. The window and the principal DO grant it -
      // app.pwb can never enlarge a native trust anchor - and CAP-8A's
      // builder refuses to even CONSTRUCT a policy that maps a method to a
      // capability outside the ceiling, which is stronger than answering
      // forbidden at runtime. That construction refusal is asserted
      // separately below; this policy simply does not map the method, which
      // is the shape a host WITHOUT the network region actually produces
      b.SetAppMaximum(['calculator.add']);
      b.SetWindowCapabilities('main',
        ['calculator.add', PWEB_CAP_NETWORK_FETCH]);
      b.SetPrincipalCapabilities('window:main',
        ['calculator.add', PWEB_CAP_NETWORK_FETCH]);
    end;
    if WithNetwork then
      b.MapMethod(PWEB_METHOD_FETCH, [PWEB_CAP_NETWORK_FETCH]);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

// the CAP-8A construction refusal, isolated: a host that mapped pweb.fetch
// without putting network.fetch in AppMaximum does not start
function MappingOutsideAppMaximumRaises: Boolean;
var
  b: TPWebCapabilityPolicyBuilder;
  p: TPWebCapabilityPolicy;
begin
  Result := False;
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum(['calculator.add']);
    b.MapMethod(PWEB_METHOD_FETCH, [PWEB_CAP_NETWORK_FETCH]);
    try
      p := b.Build;
      p.Free;
    except
      Result := True;
    end;
  finally
    b.Free;
  end;
end;

// one invocation through the REAL scheduler, over the REAL policy and the
// real decorator, returning the result and the transport entry count
function ThroughScheduler(Policy: TPWebCapabilityPolicy;
  const Method: Utf8String; const Args: TPWebJson;
  out Calls: Integer): TPWebInvocationResult;
var
  inner: IInvocationBridge;
  bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TPolicySink;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
  policyRef: ICapabilityPolicy;
begin
  FakeReset;
  Result := Default(TPWebInvocationResult);
  inner := TInnerCounter.Create;
  bridge := TPWebFetchBridge.Create(inner, @FakeTransport, ORIGINS);
  policyRef := Policy;
  scheduler := TInvocationScheduler.Create(policyRef, bridge, 1);
  schedulerRef := scheduler;
  try
    limits.MaxConcurrent := 1;
    limits.MaxQueueSize := 4;
    source := scheduler.RegisterSource(limits);
    sink := TPolicySink.Create;
    sinkRef := sink;
    if source.TryEnqueue(PolicyContext(Policy), Method, Args, sinkRef) =
         perAccepted then
      if sink.Wait(5000) then
        Result := sink.Res;
    scheduler.Shutdown;
  finally
    scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    bridge := nil;
    inner := nil;
    policyRef := nil;
  end;
  Calls := FakeCalls;
end;

procedure TTestPWebFetchPolicy.GrantedReachesTheDoor;
var
  policy: TPWebCapabilityPolicy;
  r: TPWebInvocationResult;
  calls: Integer;
begin
  // P1: granted -> allowed, and the transport IS entered
  policy := BuildPolicy(True);
  r := ThroughScheduler(policy, PWEB_METHOD_FETCH,
    ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'a granted pweb.fetch was refused: ' +
    string(ErrorCodeOf(r)));
  CheckEqual(calls, 1, 'the transport was not entered exactly once');
  Record_('policy|granted|success|calls=1');
end;

procedure TTestPWebFetchPolicy.RevokedIsForbiddenWithZeroTransport;
var
  policy: TPWebCapabilityPolicy;
  r: TPWebInvocationResult;
  calls: Integer;
begin
  // P2: REVOKED AT RUNTIME -> forbidden, with ZERO transport. The CAP-15A
  // spike measured this against its own bridge; here it is measured against
  // the shipped one, through the real scheduler, and the zero is a COUNTER
  policy := BuildPolicy(True);
  policy.SetRuntimeGrants('window:main', ['calculator.add']);
  r := ThroughScheduler(policy, PWEB_METHOD_FETCH,
    ArgsUrl('https://api.example.com/v1'), calls);
  CheckEqual(ErrorCodeOf(r), 'forbidden');
  CheckEqual(calls, 0, 'a forbidden invocation reached the transport');
  Record_('policy|revoked|forbidden|calls=0');
  // P3: and the door works again when the grant comes back, so the row
  // above is a revocation rather than a broken fixture
  policy := BuildPolicy(True);
  policy.SetRuntimeGrants('window:main',
    ['calculator.add', PWEB_CAP_NETWORK_FETCH]);
  r := ThroughScheduler(policy, PWEB_METHOD_FETCH,
    ArgsUrl('https://api.example.com/v1'), calls);
  Check(r.Kind = prkSuccess, 'a re-granted pweb.fetch was refused');
  CheckEqual(calls, 1, 'the transport was not entered after a re-grant');
  Record_('policy|regranted|success|calls=1');
end;

procedure TTestPWebFetchPolicy.AbsentFromAppMaximumIsForbidden;
var
  policy: TPWebCapabilityPolicy;
  r: TPWebInvocationResult;
  calls: Integer;
begin
  // P4: ABSENT FROM AppMaximum -> forbidden even though the window and the
  // principal both grant it. This is the runtime half of "a project that
  // declared no origins cannot reach the door"; the compiled half - that
  // such a project does not link the decorator at all - is a BUILD proof
  // (test/cap15b, empty_origins_links_decorator) because a unit that is not
  // on a compiled unit set cannot be observed from inside one
  policy := BuildPolicy(False);
  r := ThroughScheduler(policy, PWEB_METHOD_FETCH,
    ArgsUrl('https://api.example.com/v1'), calls);
  CheckEqual(ErrorCodeOf(r), 'forbidden');
  CheckEqual(calls, 0, 'an unauthorized invocation reached the transport');
  Record_('policy|absent-from-appmaximum|forbidden|calls=0');
  // and the CAP-8A builder refuses to CONSTRUCT the contradictory host at
  // all, which is stronger than refusing its invocations: a host that
  // published a door its ceiling forbids does not start
  Check(MappingOutsideAppMaximumRaises,
    'a policy mapping pweb.fetch outside AppMaximum was built');
  Record_('policy|mapping-outside-appmaximum|construction-refused');
  // P5: an UNMAPPED method is denied too - forbidden outranks
  // method_not_found, and the decorator delegates it rather than answering
  policy := BuildPolicy(True);
  r := ThroughScheduler(policy, 'Other.Method', PWEB_JSON_NULL, calls);
  CheckEqual(ErrorCodeOf(r), 'forbidden');
  CheckEqual(calls, 0, 'an unmapped method reached the transport');
  Record_('policy|unmapped|forbidden|calls=0');
end;

initialization

finalization
  // the corpus is written once, at unit finalization, so a partial run
  // cannot leave a file the aggregator would hash as if it were whole
  if Length(Corpus) > 0 then
  begin
    ForceDirectories('build/cap15b');
    FileFromString(RawUtf8ArrayToCsv(Corpus, #10) + #10,
      'build/cap15b/fetch-corpus.txt');
  end;

end.
