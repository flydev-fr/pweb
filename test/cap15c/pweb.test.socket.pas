{
  pweb.test.socket - the CAP-15C suite over the native socket door
  (mormot.core.test).

  EVERY CONTRACT ROW, AND NOT ONE SOCKET. The decorator is driven through an
  INJECTED transport that counts every entry, records what it was handed and
  lets a test play the server: deliver a frame, park a reader on a full
  queue, close with a code. So each refusal asserts a NUMBER - the transport
  entry count - rather than the absence of an observation, and a check that
  reached a socket would fail here instead of passing quietly.

    URL        the wss authorisation rule of cap15c-checkpoint1.md §6
    HANDSHAKE  subprotocols, the 15B header allowlist, argument shapes, the
               transport outcomes as typed categories
    TRAFFIC    open/message/close events, send, the long-poll, close codes
    QUEUE      the bounded queue: reading PARKS, nothing is dropped, the idle
               bound closes a socket nobody polls
    OWNERSHIP  a second window cannot touch a socket it does not own; the
               sockets-per-host bound; ids
    LIFECYCLE  document replacement, shutdown before the drain, revocation
    POLICY     the REAL TPWebCapabilityPolicy and the REAL scheduler, over
               this suite's own corpus - the CAP-8A corpus gains nothing

  The transports themselves are measured LIVE against test/cap15c/ws_server.js
  by test/cap15c/socketlive.pas and on Darwin by the probe, because a
  transport is the one thing a fake transport cannot stand in for.

  It emits build/cap15c/socket-corpus.txt, one LF line per decision, which the
  CAP-7F emitters hash into socket_corpus_digest. Every line is the verdict of
  platform-independent logic: no path, no version, no timing.
}

{$I mormot.defines.inc}

unit pweb.test.socket;

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.json,
  mormot.core.variants,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.fetch,
  pweb.rpc.socket,
  pweb.capabilities.policy;

type
  TTestPWebSocketUrl = class(TSynTestCase)
  published
    procedure DeclaredWssOpens;
    procedure SchemePairAndPortAreComponents;
    procedure DevLoopbackIsTheOnlyPlaintext;
    procedure UrlBytesAndShape;
  end;

  TTestPWebSocketHandshake = class(TSynTestCase)
  published
    procedure Subprotocols;
    procedure HeaderAllowlist;
    procedure ArgumentShapes;
    procedure TransportOutcomesAreCategories;
    procedure BoundsReachTheTransport;
  end;

  TTestPWebSocketTraffic = class(TSynTestCase)
  published
    procedure OpenEventComesFirst;
    procedure MessagesInBothEncodings;
    procedure SendContract;
    procedure LongPoll;
    procedure CloseContract;
    procedure RemoteAndAbnormalClose;
  end;

  TTestPWebSocketQueue = class(TSynTestCase)
  published
    procedure ByteBoundParksTheReader;
    procedure CountBoundParksTheReader;
    procedure NativeCloseReleasesAParkedReader;
    procedure IdleBoundClosesUnpolledSocket;
    procedure ParkedReceiveIsPolling;
  end;

  TTestPWebSocketOwnership = class(TSynTestCase)
  published
    procedure SecondWindowCannotTouchIt;
    procedure SocketsPerHostBound;
    procedure IdsAreUnguessable;
  end;

  TTestPWebSocketLifecycle = class(TSynTestCase)
  published
    procedure DocumentReplacementClosesTheWindow;
    procedure BeforeDrainReleasesEverything;
    procedure RevocationClosesImmediately;
  end;

  TTestPWebSocketPolicy = class(TSynTestCase)
  published
    procedure GrantedReachesTheDoor;
    procedure RevokedIsForbiddenWithZeroTransport;
    procedure AbsentFromAppMaximumIsForbidden;
    procedure FetchDoesNotImplySocket;
  end;

const
  /// the file the CAP-7F emitters hash into socket_corpus_digest
  PWEB_CAP15C_CORPUS_FILE = 'build/cap15c/socket-corpus.txt';

implementation

var
  Corpus: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

const
  ORIGINS: array[0..2] of RawUtf8 = (
    'https://api.example.com',
    'https://auth.example.com:8443',
    'http://127.0.0.1:5173');
  RELEASE_ORIGINS: array[0..0] of RawUtf8 = (
    'https://api.example.com');

{ ---------------------------------------------------------------------------
  the injected transport, and a test that plays the server
  --------------------------------------------------------------------------- }

type
  TFakeConn = class
  public
    /// the transport contract, played faithfully: no sink call after
    /// Release returns - a Deliver in progress holds this, and Release waits
    Lock: TRTLCriticalSection;
    Sink: TPWebSocketSink;
    Released: Boolean;
    CloseCode: Integer;
    CloseReason: RawUtf8;
    Sends: Integer;
    LastBinary: Boolean;
    LastPayload: RawByteString;
  end;

var
  FakeLock: TRTLCriticalSection;
  FakeOpens, FakeSendCalls, FakeCloseCalls, FakeReleaseCalls: LongInt;
  FakeOutcome: TPWebSocketOutcome;
  FakeSelected: RawUtf8;
  FakeSeen: TPWebSocketRequest;
  FakeConns: array of TFakeConn;
  FakeSendOutcome: TPWebSocketOutcome;
  // delivered by the fake BEFORE Open returns, to prove the open event
  // still comes first
  FakeEarlyText: RawUtf8;

procedure FakeReset;
var
  i: Integer;
begin
  EnterCriticalSection(FakeLock);
  try
    FakeOpens := 0;
    FakeSendCalls := 0;
    FakeCloseCalls := 0;
    FakeReleaseCalls := 0;
    FakeOutcome := psoOk;
    FakeSendOutcome := psoOk;
    FakeSelected := '';
    FakeSeen := Default(TPWebSocketRequest);
    FakeEarlyText := '';
    for i := 0 to High(FakeConns) do
      FakeConns[i].Free;
    FakeConns := nil;
  finally
    LeaveCriticalSection(FakeLock);
  end;
end;

function FakeOpen(const Request: TPWebSocketRequest;
  const Sink: TPWebSocketSink; const Token: ICancellationToken;
  out Handle: Pointer; out Selected: RawUtf8): TPWebSocketOutcome;
var
  c: TFakeConn;
begin
  InterlockedIncrement(FakeOpens);
  FakeSeen := Request;
  Handle := nil;
  Selected := '';
  if FakeOutcome <> psoOk then
    exit(FakeOutcome);
  c := TFakeConn.Create;
  InitCriticalSection(c.Lock);
  c.Sink := Sink;
  EnterCriticalSection(FakeLock);
  SetLength(FakeConns, Length(FakeConns) + 1);
  FakeConns[High(FakeConns)] := c;
  LeaveCriticalSection(FakeLock);
  if FakeEarlyText <> '' then
    Sink.Deliver(false, FakeEarlyText);
  Handle := c;
  Selected := FakeSelected;
  Result := psoOk;
end;

function FakeSend(Handle: Pointer; Binary: Boolean;
  const Payload: RawByteString): TPWebSocketOutcome;
begin
  InterlockedIncrement(FakeSendCalls);
  Inc(TFakeConn(Handle).Sends);
  TFakeConn(Handle).LastBinary := Binary;
  TFakeConn(Handle).LastPayload := Payload;
  Result := FakeSendOutcome;
end;

procedure FakeClose(Handle: Pointer; Code: Integer; const Reason: RawUtf8);
begin
  InterlockedIncrement(FakeCloseCalls);
  TFakeConn(Handle).CloseCode := Code;
  TFakeConn(Handle).CloseReason := Reason;
end;

procedure FakeRelease(Handle: Pointer);
begin
  InterlockedIncrement(FakeReleaseCalls);
  EnterCriticalSection(TFakeConn(Handle).Lock);
  TFakeConn(Handle).Released := true;
  LeaveCriticalSection(TFakeConn(Handle).Lock);
end;

function FakeTransport: TPWebSocketTransport;
begin
  Result.Open := FakeOpen;
  Result.Send := FakeSend;
  Result.Close := FakeClose;
  Result.Release := FakeRelease;
end;

function LastConn: TFakeConn;
begin
  EnterCriticalSection(FakeLock);
  try
    if FakeConns = nil then
      Result := nil
    else
      Result := FakeConns[High(FakeConns)];
  finally
    LeaveCriticalSection(FakeLock);
  end;
end;

type
  { plays the server on its own thread: its Deliver calls may PARK, which is
    exactly what a test of the queue needs to observe }
  TServerThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Conn: TFakeConn;
    Count, Size: Integer;
    Delivered: LongInt;
    Finished: Boolean;
    constructor CreateFor(AConn: TFakeConn; ACount, ASize: Integer);
  end;

constructor TServerThread.CreateFor(AConn: TFakeConn; ACount, ASize: Integer);
begin
  Conn := AConn;
  Count := ACount;
  Size := ASize;
  FreeOnTerminate := false;
  inherited Create(false);
end;

procedure TServerThread.Execute;
var
  i: Integer;
  b: RawByteString;
begin
  for i := 0 to Count - 1 do
  begin
    SetLength(b, Size);
    FillChar(pointer(b)^, Size, i and 255);
    PCardinal(pointer(b))^ := i; // the sequence number, host order
    // exactly what a transport does: no room, no read - it waits and asks
    // again, and keeps nothing it has not been told it may deliver
    while not Conn.Sink.Room(Size) do
    begin
      if Conn.Released then
        exit;
      Sleep(5);
    end;
    EnterCriticalSection(Conn.Lock);
    try
      if Conn.Released then
        break;
      Conn.Sink.Deliver(true, b);
    finally
      LeaveCriticalSection(Conn.Lock);
    end;
    InterlockedIncrement(Delivered);
  end;
  Finished := true;
end;

{ ---------------------------------------------------------------------------
  invocation helpers
  --------------------------------------------------------------------------- }

type
  TInnerCounter = class(TInterfacedObject, IInvocationBridge)
  public
    Calls: Integer;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TTestToken = class(TInterfacedObject, ICancellationToken)
  public
    Cancelled: LongInt;
    function IsCancelled: Boolean;
  end;

function TInnerCounter.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  Inc(Calls);
  Result := PWebSuccessResult('"inner"');
end;

function TTestToken.IsCancelled: Boolean;
begin
  Result := InterlockedCompareExchange(Cancelled, 0, 0) <> 0;
end;

function Ctx(const Window: Utf8String = 'main'): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := Window;
  Result.PrincipalId := 'window:' + Window;
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := true;
end;

function NewBridge(const Bounds: TPWebSocketBounds): TPWebSocketBridge; overload;
begin
  Result := TPWebSocketBridge.Create(TInnerCounter.Create, FakeTransport,
    ORIGINS, Bounds);
end;

function NewBridge: TPWebSocketBridge; overload;
begin
  Result := NewBridge(PWebSocketDefaultBounds);
end;

function ErrorCodeOf(const R: TPWebInvocationResult): RawUtf8;
begin
  if R.Kind = prkSuccess then
    Result := 'success'
  else
    Result := RawUtf8(PWEB_ERROR_CODE_TEXT[R.Error.Code]);
end;

// the category a service_error carries, or the code otherwise
function Verdict(const R: TPWebInvocationResult): RawUtf8;
var
  v: variant;
begin
  Result := ErrorCodeOf(R);
  if (R.Kind = prkError) and
     (R.Error.Code = pecServiceError) then
  begin
    v := _JsonFast(RawUtf8(R.Error.Data));
    Result := Result + ':' + VariantToUtf8(v.category);
  end;
end;

function Call(B: TPWebSocketBridge; const Method: RawUtf8;
  const Args: RawUtf8; const C: TInvocationContext;
  const Token: ICancellationToken = nil): TPWebInvocationResult;
begin
  Result := (B as IInvocationBridge).Invoke(C, Method, TPWebJson(Args), Token);
end;

function OpenUrl(B: TPWebSocketBridge; const Url: RawUtf8;
  const Extra: RawUtf8 = ''; const Window: Utf8String = 'main'): TPWebInvocationResult;
begin
  Result := Call(B, PWEB_METHOD_SOCKET_OPEN,
    '{"url":' + QuotedStrJson(Url) + Extra + '}', Ctx(Window));
end;

function IdOf(const R: TPWebInvocationResult): RawUtf8;
var
  v: variant;
begin
  Result := '';
  if R.Kind <> prkSuccess then
    exit;
  v := _JsonFast(RawUtf8(R.Value));
  Result := VariantToUtf8(v.id);
end;

function Receive(B: TPWebSocketBridge; const Id: RawUtf8; WaitMs: Integer = 0;
  const Window: Utf8String = 'main';
  const Token: ICancellationToken = nil): TPWebInvocationResult;
begin
  Result := Call(B, PWEB_METHOD_SOCKET_RECEIVE,
    '{"id":' + QuotedStrJson(Id) + ',"waitMs":' + RawUtf8(IntToStr(WaitMs)) +
    '}', Ctx(Window), Token);
end;

// the events of a successful receive, as a TDocVariant array
// the WHOLE receive document; the accessors below read into it while the
// caller's local variant keeps it alive. No late binding: a late-bound member
// of a temporary document is a reference into memory the temporary takes
// with it, and `type` is a reserved word besides
function EventsOf(const R: TPWebInvocationResult): variant;
begin
  if R.Kind <> prkSuccess then
    Result := _JsonFast('{"events":[]}')
  else
    Result := _JsonFast(RawUtf8(R.Value));
end;

function EvCount(const Doc: variant): Integer;
begin
  Result := _Safe(Doc)^.A['events']^.Count;
end;

function EvItem(const Doc: variant; Index: Integer): PDocVariantData;
begin
  Result := _Safe(_Safe(Doc)^.A['events']^.Values[Index]);
end;

function EvS(const Doc: variant; Index: Integer; const Name: RawUtf8): RawUtf8;
begin
  Result := EvItem(Doc, Index)^.U[Name];
end;

function EvI(const Doc: variant; Index: Integer; const Name: RawUtf8): Integer;
begin
  Result := EvItem(Doc, Index)^.I[Name];
end;

function EvB(const Doc: variant; Index: Integer; const Name: RawUtf8): Boolean;
begin
  Result := EvItem(Doc, Index)^.B[Name];
end;

function EventCount(const R: TPWebInvocationResult): Integer;
var
  doc: variant;
begin
  doc := EventsOf(R);
  Result := EvCount(doc);
end;

function WaitUntil(var Counter: LongInt; Expected: LongInt; Ms: Integer): Boolean;
var
  t: Int64;
begin
  t := GetTickCount64 + Ms;
  repeat
    if InterlockedCompareExchange(Counter, 0, 0) >= Expected then
      exit(true);
    Sleep(5);
  until GetTickCount64 > t;
  Result := false;
end;

{ ---------------------------------------------------------------------------
  URL
  --------------------------------------------------------------------------- }

procedure TTestPWebSocketUrl.DeclaredWssOpens;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    r := OpenUrl(b, 'wss://api.example.com/feed?x=1');
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(FakeOpens, 1);
    CheckEqual(FakeSeen.Scheme, 'wss');
    CheckEqual(FakeSeen.Host, 'api.example.com');
    CheckEqual(FakeSeen.Port, 443);
    Check(FakeSeen.Tls, 'wss must be TLS');
    CheckEqual(FakeSeen.Target, '/feed?x=1');
    CheckEqual(Length(IdOf(r)), 32);
    Record_('url|wss://api.example.com/feed?x=1|open|port=443|tls');
    // the default port canonicalised both ways
    r := OpenUrl(b, 'wss://api.example.com:443');
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(FakeSeen.Target, '/');
    Record_('url|wss://api.example.com:443|open|target=/');
    // a non-default declared port matches only itself
    r := OpenUrl(b, 'wss://auth.example.com:8443/s');
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(FakeSeen.Port, 8443);
    Record_('url|wss://auth.example.com:8443/s|open|port=8443');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketUrl.SchemePairAndPortAreComponents;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;

  procedure Refused(const Url: RawUtf8);
  var
    r: TPWebInvocationResult;
    before: Integer;
  begin
    before := FakeOpens;
    r := OpenUrl(b, Url);
    CheckEqual(ErrorCodeOf(r), 'invalid_request', Url);
    CheckEqual(FakeOpens, before, 'a refused URL reached the transport: ' + Url);
    Record_('url|' + Url + '|invalid_request|opens=0');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    // a port-only mismatch
    Refused('wss://api.example.com:8443/feed');
    // the scheme pair is fixed: a plaintext declaration never authorises TLS
    Refused('wss://127.0.0.1:5173/hmr');
    // and a TLS declaration never authorises plaintext
    Refused('ws://api.example.com/feed');
    // another host entirely
    Refused('wss://evil.example.com/feed');
    // a prefix is not a match
    Refused('wss://api.example.com.evil.example/feed');
    // localhost and 127.0.0.1 are different hosts
    Refused('ws://localhost:5173/hmr');
    // fetch's schemes are not socket schemes
    Refused('https://api.example.com/feed');
    Refused('http://127.0.0.1:5173/hmr');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketUrl.DevLoopbackIsTheOnlyPlaintext;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    r := OpenUrl(b, 'ws://127.0.0.1:5173/hmr');
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(FakeSeen.Port, 5173);
    Check(not FakeSeen.Tls, 'ws must not be TLS');
    Record_('url|ws://127.0.0.1:5173/hmr|open|dev-loopback');
    // the grammar requires an explicit loopback port, so a portless ws URL
    // can never match a declared loopback origin
    r := OpenUrl(b, 'ws://127.0.0.1/hmr');
    CheckEqual(ErrorCodeOf(r), 'invalid_request');
    Record_('url|ws://127.0.0.1/hmr|invalid_request|portless');
  finally
    keep := nil;
  end;
  // A RELEASE-SHAPED allowlist carries no http origin at all - `pweb build`
  // refuses a loopback origin by name - so no ws URL can match anything
  FakeReset;
  b := TPWebSocketBridge.Create(TInnerCounter.Create, FakeTransport,
    RELEASE_ORIGINS, PWebSocketDefaultBounds);
  keep := b;
  try
    r := OpenUrl(b, 'ws://127.0.0.1:5173/hmr');
    CheckEqual(ErrorCodeOf(r), 'invalid_request');
    CheckEqual(FakeOpens, 0);
    Record_('url|release-allowlist|ws://127.0.0.1:5173/hmr|invalid_request|opens=0');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketUrl.UrlBytesAndShape;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;

  procedure Refused(const Url, Why: RawUtf8);
  var
    r: TPWebInvocationResult;
  begin
    r := OpenUrl(b, Url);
    CheckEqual(ErrorCodeOf(r), 'invalid_request', Why);
    CheckEqual(FakeOpens, 0, 'a malformed URL reached the transport: ' + Why);
    Record_('url|' + Why + '|invalid_request|opens=0');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    Refused('wss://user@api.example.com/', 'userinfo');
    Refused('wss://api.example.com@evil.example/', 'userinfo-trick');
    Refused('wss://api.example.com/feed#frag', 'fragment');
    Refused('wss://api.example.com/a'#13#10'Host: evil', 'crlf');
    // QuotedStrJson escapes it as  , which mORMot's parser would decode
    // as '?' and silently turn this path into a query - refused instead
    // a RAW NUL, placed in the JSON by hand: QuotedStrJson would stop at it
    CheckEqual(ErrorCodeOf(Call(b, PWEB_METHOD_SOCKET_OPEN,
      '{"url":"wss://api.example.com/a' + #0 + 'b"}', Ctx)), 'invalid_request');
    CheckEqual(FakeOpens, 0, 'a raw NUL in a URL reached the transport');
    Record_('url|raw-nul|invalid_request|opens=0');
    // and the ESCAPE a page actually sends, spelled out rather than produced
    // by QuotedStrJson, which writes a raw byte
    CheckEqual(ErrorCodeOf(Call(b, PWEB_METHOD_SOCKET_OPEN,
      '{"url":"wss://api.example.com/a' + #92 + 'u0000b"}', Ctx)),
      'invalid_request');
    CheckEqual(FakeOpens, 0, 'an escaped NUL in a URL reached the transport');
    Record_('url|escaped-nul|invalid_request|opens=0');
    Refused('wss://api.example.com/a b', 'space');
    Refused('wss://api.example.com/caf'#$C3#$A9, 'non-ascii');
    Refused('WSS://api.example.com/', 'uppercase-scheme');
    Refused('wss:///feed', 'empty-authority');
    Refused('wss://api.example.com:0/', 'port-zero');
    Refused('wss://api.example.com:65536/', 'port-overflow');
    Refused('wss://[::1]:443/', 'ipv6');
    Refused('wss://api.example.com/' + RawUtf8(StringOfChar('a', 2048)),
      'over-2048-bytes');
    Refused('', 'empty');
  finally
    keep := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  HANDSHAKE
  --------------------------------------------------------------------------- }

procedure TTestPWebSocketHandshake.Subprotocols;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;

  procedure Refused(const Extra, Why: RawUtf8);
  begin
    r := OpenUrl(b, 'wss://api.example.com/', Extra);
    CheckEqual(ErrorCodeOf(r), 'invalid_request', Why);
    CheckEqual(FakeOpens, 1, 'a refused subprotocol list reached the transport: ' + Why);
    Record_('protocols|' + Why + '|invalid_request');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    FakeSelected := 'json.v2';
    r := OpenUrl(b, 'wss://api.example.com/',
      ',"protocols":["chat.v1","json.v2","a","b"]');
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(Length(FakeSeen.Protocols), 4);
    CheckEqual(FakeSeen.Protocols[1], 'json.v2');
    Record_('protocols|four-tokens|open');
    Refused(',"protocols":["a","b","c","d","e"]', 'five');
    Refused(',"protocols":["a","a"]', 'duplicate');
    Refused(',"protocols":["has space"]', 'space');
    Refused(',"protocols":["a,b"]', 'comma');
    Refused(',"protocols":[""]', 'empty');
    Refused(',"protocols":["' + RawUtf8(StringOfChar('p', 65)) + '"]',
      'over-64-bytes');
    Refused(',"protocols":"chat.v1"', 'not-an-array');
    Refused(',"protocols":[1]', 'element-not-string');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketHandshake.HeaderAllowlist;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  i: Integer;
  many: RawUtf8;

  procedure Refused(const Headers, Why: RawUtf8);
  var
    before: Integer;
  begin
    before := FakeOpens;
    r := OpenUrl(b, 'wss://api.example.com/', ',"headers":' + Headers);
    CheckEqual(ErrorCodeOf(r), 'invalid_request', Why);
    CheckEqual(FakeOpens, before, 'a refused header reached the transport: ' + Why);
    Record_('headers|' + Why + '|invalid_request|opens=0');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    r := OpenUrl(b, 'wss://api.example.com/',
      ',"headers":{"Authorization":"Bearer t","x-app":"1","accept-language":"fr"}');
    CheckEqual(ErrorCodeOf(r), 'success');
    Check(PosEx('Authorization: Bearer t'#13#10, FakeSeen.Headers) > 0,
      'authorization did not reach the handshake');
    Check(PosEx('x-app: 1'#13#10, FakeSeen.Headers) > 0,
      'an x- header did not reach the handshake');
    Record_('headers|authorization+x-app+accept-language|open');
    // everything a handshake OWNS is outside the allowlist by construction
    Refused('{"cookie":"a=1"}', 'cookie');
    Refused('{"origin":"https://evil.example"}', 'origin');
    Refused('{"host":"evil.example"}', 'host');
    Refused('{"sec-websocket-protocol":"x"}', 'sec-websocket-protocol');
    Refused('{"sec-websocket-key":"x"}', 'sec-websocket-key');
    Refused('{"upgrade":"h2c"}', 'upgrade');
    Refused('{"connection":"close"}', 'connection');
    Refused('{"proxy-authorization":"x"}', 'proxy-authorization');
    // splitting and repetition
    Refused('{"x-a":"1\r\nHost: evil"}', 'crlf-value');
    Refused('{"x-a":"1","X-A":"2"}', 'repeat');
    Refused('{"x a":"1"}', 'bad-name');
    Refused('{"x-a":5}', 'non-string-value');
    Refused('"authorization: x"', 'not-an-object');
    Refused('{"x-a":"' + RawUtf8(StringOfChar('v', 4097)) + '"}',
      'value-over-4096');
    many := '{';
    for i := 0 to 16 do
    begin
      if i > 0 then
        many := many + ',';
      many := many + '"x-h' + RawUtf8(IntToStr(i)) + '":"v"';
    end;
    Refused(many + '}', 'seventeen');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketHandshake.ArgumentShapes;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;

  procedure Refused(const Method, Args, Why: RawUtf8);
  var
    r: TPWebInvocationResult;
  begin
    r := Call(b, Method, Args, Ctx);
    CheckEqual(ErrorCodeOf(r), 'invalid_request', Why);
    Record_('args|' + Why + '|invalid_request');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    Refused(PWEB_METHOD_SOCKET_OPEN, 'null', 'open-null');
    Refused(PWEB_METHOD_SOCKET_OPEN, '{}', 'open-no-url');
    Refused(PWEB_METHOD_SOCKET_OPEN, '{"url":5}', 'open-url-number');
    Refused(PWEB_METHOD_SOCKET_OPEN,
      '{"url":"wss://api.example.com/","timeoutMs":5}', 'open-unknown-arg');
    Refused(PWEB_METHOD_SOCKET_OPEN,
      '{"url":"wss://api.example.com/","url":"wss://api.example.com/"}',
      'open-repeated-arg');
    Refused(PWEB_METHOD_SOCKET_SEND, '{"id":"x"}', 'send-no-payload');
    Refused(PWEB_METHOD_SOCKET_RECEIVE, '{}', 'receive-no-id');
    Refused(PWEB_METHOD_SOCKET_CLOSE, '{"id":5}', 'close-id-number');
    CheckEqual(FakeOpens, 0);
    // a method this decorator does not own is delegated verbatim
    Check(Call(b, 'Calculator.Add', '{"a":1}', Ctx).Value = '"inner"',
      'a non-socket method was not delegated');
    Record_('args|non-socket-method|delegated');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketHandshake.TransportOutcomesAreCategories;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  token: TTestToken;
  tokenRef: ICancellationToken;

  procedure Outcome(O: TPWebSocketOutcome; const Expected, Why: RawUtf8);
  var
    r: TPWebInvocationResult;
  begin
    FakeOutcome := O;
    r := OpenUrl(b, 'wss://api.example.com/');
    CheckEqual(Verdict(r), Expected, Why);
    // a failed open holds NO slot and leaves no socket behind
    CheckEqual(b.OpenCount, 0, 'a failed open kept a slot: ' + Why);
    // and never carries a native detail
    Check(PosEx('Exception', r.Error.Message) = 0, 'a native detail leaked');
    Record_('outcome|' + Why + '|' + Expected);
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    Outcome(psoConnectFailed, 'service_error:connect_failed', 'connect');
    Outcome(psoTlsFailed, 'service_error:tls_failed', 'tls');
    Outcome(psoHandshakeRedirect, 'service_error:handshake_refused', 'redirect');
    Outcome(psoHandshakeStatus, 'service_error:handshake_refused', 'status');
    Outcome(psoHandshakeUpgrade, 'service_error:handshake_refused', 'upgrade');
    Outcome(psoHandshakeSubprotocol, 'service_error:handshake_refused',
      'subprotocol');
    Outcome(psoDeadline, 'service_error:deadline', 'deadline');
    Outcome(psoCancelled, 'cancelled', 'cancelled');
    // the redirect reason is typed, never the server's text
    FakeOutcome := psoHandshakeRedirect;
    Check(PosEx('"reason":"redirect"', RawUtf8(
      OpenUrl(b, 'wss://api.example.com/').Error.Data)) > 0,
      'a refused 3xx did not say redirect');
    // a token already cancelled: the decorator still answers cancelled
    FakeOutcome := psoOk;
    token := TTestToken.Create;
    tokenRef := token;
    token.Cancelled := 1;
    CheckEqual(ErrorCodeOf(Call(b, PWEB_METHOD_SOCKET_OPEN,
      '{"url":"wss://api.example.com/"}', Ctx, tokenRef)), 'cancelled');
    Record_('outcome|token-cancelled-before-open|cancelled');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketHandshake.BoundsReachTheTransport;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    OpenUrl(b, 'wss://api.example.com/');
    CheckEqual(FakeSeen.ConnectDeadlineMs, PWEB_SOCKET_CONNECT_DEADLINE_MS);
    CheckEqual(FakeSeen.SendDeadlineMs, PWEB_SOCKET_SEND_DEADLINE_MS);
    CheckEqual(FakeSeen.MaxMessage, PWEB_SOCKET_MAX_MESSAGE);
    // the ratified numbers, spelled once, cross-checked here and by the gate
    CheckEqual(PWEB_SOCKET_MAX_SOCKETS, 4);
    CheckEqual(PWEB_SOCKET_CONNECT_DEADLINE_MS, 10000);
    CheckEqual(PWEB_SOCKET_SEND_DEADLINE_MS, 10000);
    CheckEqual(PWEB_SOCKET_MAX_MESSAGE, 1 shl 20);
    CheckEqual(PWEB_SOCKET_QUEUE_EVENTS, 64);
    CheckEqual(PWEB_SOCKET_QUEUE_BYTES, 1 shl 20);
    CheckEqual(PWEB_SOCKET_MAX_WAIT_MS, 25000);
    CheckEqual(PWEB_SOCKET_IDLE_MS, 60000);
    CheckEqual(PWEB_SOCKET_MAX_PROTOCOLS, 4);
    CheckEqual(PWEB_SOCKET_MAX_REASON_BYTES, 123);
    CheckEqual(PWEB_SOCKET_REQUEST_BYTES, 2 shl 20);
    Record_('bounds|sockets=4|connect=10000|send=10000|message=1048576|' +
      'queue=64/1048576|wait=25000|idle=60000|protocols=4|reason=123|' +
      'request=2097152');
  finally
    keep := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  TRAFFIC
  --------------------------------------------------------------------------- }

procedure TTestPWebSocketTraffic.OpenEventComesFirst;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  ev: variant;
  id: RawUtf8;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    FakeSelected := 'json.v2';
    // the server speaks before Open has even returned
    FakeEarlyText := 'early';
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    r := Receive(b, id);
    CheckEqual(EventCount(r), 2);
    ev := EventsOf(r);
    CheckEqual(EvS(ev, 0, 'type'), 'open');
    CheckEqual(EvS(ev, 0, 'protocol'), 'json.v2');
    CheckEqual(EvS(ev, 1, 'type'), 'message');
    CheckEqual(EvS(ev, 1, 'text'), 'early');
    Record_('traffic|open-event-first|protocol=json.v2|then-early-message');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketTraffic.MessagesInBothEncodings;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  ev: variant;
  id: RawUtf8;
  c: TFakeConn;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    c.Sink.Deliver(false, 'h'#$C3#$A9'llo "q"');
    c.Sink.Deliver(true, #0#1#2#255);
    r := Receive(b, id);
    CheckEqual(EventCount(r), 3);
    ev := EventsOf(r);
    CheckEqual(EvS(ev, 1, 'text'), 'h'#$C3#$A9'llo "q"');
    CheckEqual(EvS(ev, 2, 'base64'), BinToBase64(#0#1#2#255));
    Record_('traffic|text-utf8|binary-base64');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketTraffic.SendContract;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  c: TFakeConn;
  big: RawByteString;

  function Send(const Args: RawUtf8): TPWebInvocationResult;
  begin
    Result := Call(b, PWEB_METHOD_SOCKET_SEND,
      '{"id":' + QuotedStrJson(id) + Args + '}', Ctx);
  end;

  procedure Refused(const Args, Why: RawUtf8);
  var
    before: Integer;
  begin
    before := FakeSendCalls;
    CheckEqual(ErrorCodeOf(Send(Args)), 'invalid_request', Why);
    CheckEqual(FakeSendCalls, before, 'a refused send reached the transport: ' + Why);
    Record_('send|' + Why + '|invalid_request|sends=0');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    CheckEqual(ErrorCodeOf(Send(',"text":"hi"')), 'success');
    CheckEqual(c.LastPayload, 'hi');
    Check(not c.LastBinary, 'text went out as binary');
    CheckEqual(ErrorCodeOf(Send(',"base64":"AAEC/w=="')), 'success');
    CheckEqual(c.LastPayload, #0#1#2#255);
    Check(c.LastBinary, 'base64 went out as text');
    CheckEqual(ErrorCodeOf(Send(',"text":""')), 'success');
    Record_('send|text|base64|empty-text|success');
    // a text message is carried EXACTLY or refused: never `a?b`
    Refused(',"text":"a' + #92 + 'u0000b"', 'text-escaped-nul');
    Refused(',"text":"a' + #0 + 'b"', 'text-raw-nul');
    // while a literal backslash-u-0000 in the text is six ordinary characters
    CheckEqual(ErrorCodeOf(Send(',"text":"\\u0000"')), 'success');
    CheckEqual(c.LastPayload, RawUtf8(#92'u0000'));
    Record_('send|literal-backslash-u0000|carried-exactly');
    Refused(',"text":"a","base64":"AA=="', 'both');
    Refused(',"base64":"not base64!"', 'bad-base64');
    Refused(',"text":5', 'text-not-string');
    Refused(',"binary":"AA=="', 'unknown-arg');
    // exactly the bound goes; one byte over does not
    SetLength(big, PWEB_SOCKET_MAX_MESSAGE);
    FillChar(pointer(big)^, Length(big), Ord('a'));
    CheckEqual(ErrorCodeOf(Send(',"text":' + QuotedStrJson(RawUtf8(big)))),
      'success');
    Refused(',"text":' + QuotedStrJson(RawUtf8(big + 'a')), 'text-over-1mib');
    Refused(',"base64":"' + BinToBase64(big + 'a') + '"', 'binary-over-1mib');
    Record_('send|exactly-1mib|success');
    // a transport failure closes the socket and is typed
    FakeSendOutcome := psoSendFailed;
    CheckEqual(Verdict(Send(',"text":"x"')), 'service_error:send_failed');
    FakeSendOutcome := psoOk;
    CheckEqual(Verdict(Send(',"text":"x"')), 'service_error:socket_closed');
    Record_('send|transport-failure|send_failed|then|socket_closed');
    // a send deadline is its own category
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    FakeSendOutcome := psoDeadline;
    CheckEqual(Verdict(Send(',"text":"x"')), 'service_error:deadline');
    Record_('send|deadline|service_error:deadline');
  finally
    keep := nil;
  end;
end;

type
  { cancels a token after a delay - FPC 3.2 has no anonymous procedures }
  TCancelLater = class(TThread)
  protected
    procedure Execute; override;
  public
    Token: TTestToken;
    DelayMs: Integer;
    constructor CreateFor(AToken: TTestToken; ADelayMs: Integer);
  end;

constructor TCancelLater.CreateFor(AToken: TTestToken; ADelayMs: Integer);
begin
  Token := AToken;
  DelayMs := ADelayMs;
  FreeOnTerminate := true;
  inherited Create(false);
end;

procedure TCancelLater.Execute;
begin
  Sleep(DelayMs);
  InterlockedIncrement(Token.Cancelled);
end;

procedure TTestPWebSocketTraffic.LongPoll;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  c: TFakeConn;
  t0: Int64;
  r: TPWebInvocationResult;
  th: TServerThread;
  token: TTestToken;
  tokenRef: ICancellationToken;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id); // takes the open event
    // nothing queued, no wait: an immediate empty answer
    r := Call(b, PWEB_METHOD_SOCKET_RECEIVE, '{"id":' + QuotedStrJson(id) + '}', Ctx);
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(EventCount(r), 0);
    Record_('receive|no-wait|empty');
    // a message arriving DURING the wait ends it early
    th := TServerThread.CreateFor(c, 1, 8);
    t0 := GetTickCount64;
    r := Receive(b, id, 5000);
    CheckEqual(EventCount(r), 1);
    Check(GetTickCount64 - t0 < 4000, 'a long-poll waited past its first event');
    th.WaitFor;
    th.Free;
    Record_('receive|long-poll|returns-on-first-event');
    // a wait that expires answers empty
    t0 := GetTickCount64;
    r := Receive(b, id, 150);
    CheckEqual(EventCount(r), 0);
    Check(GetTickCount64 - t0 >= 140, 'a long-poll returned before its wait');
    Record_('receive|long-poll|expires-empty');
    // the bound is REFUSED, not clamped
    CheckEqual(ErrorCodeOf(Receive(b, id, PWEB_SOCKET_MAX_WAIT_MS + 1)),
      'invalid_request');
    CheckEqual(ErrorCodeOf(Receive(b, id, -1)), 'invalid_request');
    CheckEqual(ErrorCodeOf(Call(b, PWEB_METHOD_SOCKET_RECEIVE,
      '{"id":' + QuotedStrJson(id) + ',"waitMs":"5"}', Ctx)), 'invalid_request');
    Record_('receive|wait-over-max|negative|string|invalid_request');
    // the token is observed DURING the wait
    token := TTestToken.Create;
    tokenRef := token;
    TCancelLater.CreateFor(token, 100);
    t0 := GetTickCount64;
    r := Receive(b, id, 5000, 'main', tokenRef);
    CheckEqual(ErrorCodeOf(r), 'cancelled');
    Check(GetTickCount64 - t0 < 2000, 'a cancelled long-poll was not released');
    Record_('receive|token-during-wait|cancelled');
  finally
    keep := nil;
  end;
end;

type
  TReceiveThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Bridge: TPWebSocketBridge;
    Id: RawUtf8;
    Res: TPWebInvocationResult;
  end;

procedure TReceiveThread.Execute;
begin
  Res := Receive(Bridge, Id, 1500);
end;

procedure TTestPWebSocketTraffic.CloseContract;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  c: TFakeConn;
  r: TPWebInvocationResult;
  ev: variant;
  rt: TReceiveThread;

  function Close(const Args: RawUtf8): TPWebInvocationResult;
  begin
    Result := Call(b, PWEB_METHOD_SOCKET_CLOSE,
      '{"id":' + QuotedStrJson(id) + Args + '}', Ctx);
  end;

  procedure Refused(const Args, Why: RawUtf8);
  begin
    CheckEqual(ErrorCodeOf(Close(Args)), 'invalid_request', Why);
    CheckEqual(FakeCloseCalls, 0, 'a refused close reached the transport: ' + Why);
    Record_('close|' + Why + '|invalid_request');
  end;

begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id);
    Refused(',"code":1001', 'code-1001');
    Refused(',"code":2999', 'code-2999');
    Refused(',"code":5000', 'code-5000');
    Refused(',"code":"1000"', 'code-string');
    Refused(',"reason":"' + RawUtf8(StringOfChar('r', 124)) + '"', 'reason-124');
    Refused(',"reason":5', 'reason-number');
    // a second concurrent receive is busy, and the first still works
    rt := TReceiveThread.Create(true);
    rt.Bridge := b;
    rt.Id := id;
    rt.FreeOnTerminate := false;
    rt.Start;
    Sleep(150);
    CheckEqual(ErrorCodeOf(Receive(b, id, 0)), 'busy');
    Record_('receive|second-concurrent|busy');
    CheckEqual(ErrorCodeOf(Close(',"code":4000,"reason":"done"')), 'success');
    CheckEqual(FakeCloseCalls, 1);
    CheckEqual(c.CloseCode, 4000);
    CheckEqual(c.CloseReason, 'done');
    // idempotent
    CheckEqual(ErrorCodeOf(Close('')), 'success');
    CheckEqual(FakeCloseCalls, 1, 'a second close reached the transport');
    Record_('close|4000|done|idempotent');
    // the server's echo is the page's close event
    c.Sink.Closed(pscRemote, 4000, 'done');
    rt.WaitFor;
    r := rt.Res;
    rt.Free;
    if EventCount(r) = 0 then
      r := Receive(b, id, 500);
    CheckEqual(EventCount(r), 1);
    ev := EventsOf(r);
    CheckEqual(EvS(ev, 0, 'type'), 'close');
    CheckEqual(EvI(ev, 0, 'code'), 4000);
    CheckEqual(EvS(ev, 0, 'category'), 'page');
    Check(EvB(ev, 0, 'wasClean'), 'an echoed page close was not clean');
    Record_('close|echo|category=page|clean');
    // and the socket is gone once its close event was received
    Check(WaitUntil(FakeReleaseCalls, 1, 2000), 'the closed socket was not released');
    Sleep(300);
    CheckEqual(Verdict(Receive(b, id)), 'service_error:socket_not_found');
    Record_('close|after-close-event|socket_not_found');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketTraffic.RemoteAndAbnormalClose;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  c: TFakeConn;
  r: TPWebInvocationResult;
  ev: variant;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    c.Sink.Deliver(false, 'one');
    c.Sink.Deliver(false, 'two');
    c.Sink.Closed(pscRemote, 4001, 'bye');
    r := Receive(b, id);
    ev := EventsOf(r);
    // what arrived BEFORE the close is kept, in order, and the close is last
    CheckEqual(EventCount(r), 4);
    CheckEqual(EvS(ev, 1, 'text'), 'one');
    CheckEqual(EvS(ev, 2, 'text'), 'two');
    CheckEqual(EvI(ev, 3, 'code'), 4001);
    CheckEqual(EvS(ev, 3, 'reason'), 'bye');
    CheckEqual(EvS(ev, 3, 'category'), 'remote');
    CheckEqual(EvI(ev, 3, 'undelivered'), 0);
    Record_('close|remote|4001|bye|messages-kept-in-order');
    // an abnormal end: an error event, then close 1006
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id);
    c.Sink.Closed(pscAbnormal, 1006, '');
    r := Receive(b, id);
    ev := EventsOf(r);
    CheckEqual(EventCount(r), 2);
    CheckEqual(EvS(ev, 0, 'type'), 'error');
    CheckEqual(EvS(ev, 0, 'category'), 'abnormal');
    CheckEqual(EvI(ev, 1, 'code'), 1006);
    Check(not EvB(ev, 1, 'wasClean'), 'an abnormal close was clean');
    Record_('close|abnormal|error-then-close-1006');
    // an inbound message over the bound
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id);
    c.Sink.Closed(pscMessageTooLarge, 1009, '');
    ev := EventsOf(Receive(b, id));
    CheckEqual(EvS(ev, 1, 'category'), 'message_too_large');
    CheckEqual(EvI(ev, 1, 'code'), 1009);
    Record_('close|message_too_large|1009');
    // a protocol error
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id);
    c.Sink.Closed(pscProtocolError, 1002, '');
    ev := EventsOf(Receive(b, id));
    CheckEqual(EvS(ev, 1, 'category'), 'protocol_error');
    Record_('close|protocol_error|1002');
    // a peer close reason is bounded
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id);
    c.Sink.Closed(pscRemote, 1000, RawUtf8(StringOfChar('z', 200)));
    ev := EventsOf(Receive(b, id));
    CheckEqual(Length(EvS(ev, 0, 'reason')), PWEB_SOCKET_MAX_REASON_BYTES);
    Record_('close|remote-reason|bounded-123');
  finally
    keep := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  QUEUE
  --------------------------------------------------------------------------- }

// drain every binary event, checking the sequence number of each
function DrainInOrder(B: TPWebSocketBridge; const Id: RawUtf8;
  Expected: Integer; out Gaps: Integer): Integer;
var
  r: TPWebInvocationResult;
  ev: variant;
  i, n: Integer;
  bin: RawByteString;
  t: Int64;
begin
  Result := 0;
  Gaps := 0;
  t := GetTickCount64 + 20000;
  while (Result < Expected) and (GetTickCount64 < t) do
  begin
    r := Receive(B, Id, 200);
    ev := EventsOf(r);
    n := EvCount(ev);
    for i := 0 to n - 1 do
      if EvS(ev, i, 'type') = 'message' then
      begin
        bin := Base64ToBin(EvS(ev, i, 'base64'));
        if (Length(bin) < 4) or
           (PCardinal(pointer(bin))^ <> Cardinal(Result)) then
          Inc(Gaps);
        Inc(Result);
      end;
  end;
end;

procedure TTestPWebSocketQueue.ByteBoundParksTheReader;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  th: TServerThread;
  got, gaps: Integer;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    Receive(b, id);
    // 100 messages of 64 KiB from a server that does not wait
    th := TServerThread.CreateFor(LastConn, 100, 65536);
    Sleep(400);
    // the reader is PARKED: 16 messages is exactly the 1 MiB byte bound
    CheckEqual(b.QueuedBytes(id), PWEB_SOCKET_QUEUE_BYTES);
    CheckEqual(th.Delivered, 16);
    Check(not th.Finished, 'the reader was not parked by a full queue');
    Record_('queue|64kib-flood|parked-at-1048576-bytes|16-queued');
    got := DrainInOrder(b, id, 100, gaps);
    th.WaitFor;
    CheckEqual(got, 100, 'a message was dropped');
    CheckEqual(gaps, 0, 'a message arrived out of order');
    th.Free;
    Record_('queue|64kib-flood|100-of-100|0-gaps');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketQueue.CountBoundParksTheReader;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  th: TServerThread;
  got, gaps: Integer;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    Receive(b, id);
    th := TServerThread.CreateFor(LastConn, 1000, 8);
    Sleep(400);
    CheckEqual(b.QueuedEvents(id), PWEB_SOCKET_QUEUE_EVENTS);
    CheckEqual(th.Delivered, PWEB_SOCKET_QUEUE_EVENTS);
    Record_('queue|small-flood|parked-at-64-events');
    got := DrainInOrder(b, id, 1000, gaps);
    th.WaitFor;
    CheckEqual(got, 1000);
    CheckEqual(gaps, 0);
    th.Free;
    Record_('queue|small-flood|1000-of-1000|0-gaps');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketQueue.NativeCloseReleasesAParkedReader;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  th: TServerThread;
  t0: Int64;
  ev: variant;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    Receive(b, id);
    th := TServerThread.CreateFor(LastConn, 50, 65536);
    Sleep(300);
    Check(not th.Finished, 'the reader was not parked');
    t0 := GetTickCount64;
    // the idle path: the queue is discarded, and the count is TYPED
    b.CloseForIdleNow(id);
    th.WaitFor;
    Check(GetTickCount64 - t0 < 2000, 'a parked reader was not released by a close');
    th.Free;
    ev := EventsOf(Receive(b, id));
    CheckEqual(EvS(ev, 0, 'type'), 'close');
    CheckEqual(EvS(ev, 0, 'category'), 'idle');
    CheckEqual(EvI(ev, 0, 'undelivered'), 16);
    Record_('queue|native-close-while-parked|reader-released|undelivered=16');
  finally
    keep := nil;
  end;
end;

function ShortIdle: TPWebSocketBounds;
begin
  Result := PWebSocketDefaultBounds;
  Result.IdleMs := 300;
end;

procedure TTestPWebSocketQueue.IdleBoundClosesUnpolledSocket;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  c: TFakeConn;
  ev: variant;
begin
  FakeReset;
  b := NewBridge(ShortIdle);
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    // the page never polls
    Check(WaitUntil(FakeReleaseCalls, 1, 3000), 'an unpolled socket was not released');
    CheckEqual(FakeCloseCalls, 1);
    CheckEqual(c.CloseCode, 1001);
    ev := EventsOf(Receive(b, id));
    CheckEqual(EvS(ev, 1, 'type'), 'close');
    CheckEqual(EvS(ev, 1, 'category'), 'idle');
    Record_('queue|idle-bound|close-1001|category=idle');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketQueue.ParkedReceiveIsPolling;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
begin
  FakeReset;
  b := NewBridge(ShortIdle);
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    // one long-poll three times the idle bound: a receive in flight IS polling
    Receive(b, id, 900);
    CheckEqual(FakeCloseCalls, 0, 'a socket with a receive in flight was closed as idle');
    Receive(b, id, 0);
    Record_('queue|receive-in-flight-counts-as-polling');
  finally
    keep := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  OWNERSHIP
  --------------------------------------------------------------------------- }

procedure TTestPWebSocketOwnership.SecondWindowCannotTouchIt;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  id: RawUtf8;
  foreign, unknown: RawUtf8;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    foreign := Verdict(Call(b, PWEB_METHOD_SOCKET_SEND,
      '{"id":' + QuotedStrJson(id) + ',"text":"x"}', Ctx('other')));
    unknown := Verdict(Call(b, PWEB_METHOD_SOCKET_SEND,
      '{"id":"00000000000000000000000000000000","text":"x"}', Ctx('other')));
    CheckEqual(foreign, 'service_error:socket_not_found');
    // indistinguishable from an id that never existed: no oracle
    CheckEqual(foreign, unknown);
    CheckEqual(FakeSendCalls, 0, 'a foreign send reached the transport');
    CheckEqual(Verdict(Receive(b, id, 0, 'other')), 'service_error:socket_not_found');
    CheckEqual(Verdict(Call(b, PWEB_METHOD_SOCKET_CLOSE,
      '{"id":' + QuotedStrJson(id) + '}', Ctx('other'))),
      'service_error:socket_not_found');
    CheckEqual(FakeCloseCalls, 0, 'a foreign close reached the transport');
    // and the owner still has it
    CheckEqual(EventCount(Receive(b, id)), 1);
    Record_('ownership|foreign-send-receive-close|socket_not_found|same-as-unknown|0-transport');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketOwnership.SocketsPerHostBound;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  ids: array[0..3] of RawUtf8;
  i: Integer;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    for i := 0 to 3 do
    begin
      // across windows: the bound is per HOST, not per principal
      if i < 2 then
        ids[i] := IdOf(OpenUrl(b, 'wss://api.example.com/'))
      else
        ids[i] := IdOf(OpenUrl(b, 'wss://api.example.com/', '', 'other'));
      Check(ids[i] <> '', 'socket ' + IntToStr(i) + ' did not open');
    end;
    CheckEqual(Verdict(OpenUrl(b, 'wss://api.example.com/')),
      'service_error:socket_limit');
    CheckEqual(FakeOpens, 4, 'the fifth socket reached the transport');
    Record_('limit|fifth-socket|socket_limit|opens=4');
    // a closed and released socket frees its slot, even before its close
    // event is received
    LastConn.Sink.Closed(pscRemote, 1000, '');
    Check(WaitUntil(FakeReleaseCalls, 1, 2000), 'a remotely closed socket was not released');
    Check(IdOf(OpenUrl(b, 'wss://api.example.com/')) <> '',
      'a released slot was not reusable');
    Record_('limit|released-slot|reusable');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketOwnership.IdsAreUnguessable;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  a, c: RawUtf8;
  i: Integer;
  hex: Boolean;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    a := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    CheckEqual(Length(a), 32);
    Check(a <> c, 'two sockets shared an id');
    hex := true;
    for i := 1 to Length(a) do
      if not (a[i] in ['0'..'9', 'a'..'f']) then
        hex := false;
    Check(hex, 'an id is not lowercase hex');
    Record_('ids|32-lowercase-hex|distinct');
  finally
    keep := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  LIFECYCLE
  --------------------------------------------------------------------------- }

procedure TTestPWebSocketLifecycle.DocumentReplacementClosesTheWindow;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  mine, theirs: RawUtf8;
  sendsBefore: Integer;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    mine := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    theirs := IdOf(OpenUrl(b, 'wss://api.example.com/', '', 'other'));
    sendsBefore := FakeSendCalls;
    b.DocumentReplacing('main');
    // immediately: the replaced document's socket is gone for every call
    CheckEqual(Verdict(Call(b, PWEB_METHOD_SOCKET_SEND,
      '{"id":' + QuotedStrJson(mine) + ',"text":"x"}', Ctx)),
      'service_error:socket_not_found');
    CheckEqual(FakeSendCalls, sendsBefore);
    Check(WaitUntil(FakeReleaseCalls, 1, 2000), 'a replaced document''s socket was not released');
    CheckEqual(FakeCloseCalls, 1);
    // the other window is untouched
    CheckEqual(ErrorCodeOf(Call(b, PWEB_METHOD_SOCKET_SEND,
      '{"id":' + QuotedStrJson(theirs) + ',"text":"x"}', Ctx('other'))), 'success');
    Record_('lifecycle|document-replacing|window-closed|other-window-untouched');
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSocketLifecycle.BeforeDrainReleasesEverything;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
begin
  FakeReset;
  b := NewBridge;
  keep := b;
  try
    OpenUrl(b, 'wss://api.example.com/');
    OpenUrl(b, 'wss://api.example.com/', '', 'other');
    b.BeforeDrain;
    // SYNCHRONOUS: every transport released before BeforeDrain returned
    CheckEqual(FakeReleaseCalls, 2);
    CheckEqual(b.OpenCount, 0);
    CheckEqual(Verdict(OpenUrl(b, 'wss://api.example.com/')),
      'service_error:socket_closed');
    CheckEqual(FakeOpens, 2, 'an open after the drain began reached the transport');
    Record_('lifecycle|before-drain|all-released-synchronously|new-open-refused');
  finally
    keep := nil;
  end;
end;

function BuildSocketPolicy(WithSocket, WithFetch: Boolean): TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
  caps: array of Utf8String;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    caps := ['calculator.add'];
    if WithSocket then
      caps := caps + [PWEB_CAP_NETWORK_SOCKET];
    if WithFetch then
      caps := caps + [PWEB_CAP_NETWORK_FETCH];
    b.SetAppMaximum(caps);
    b.SetWindowCapabilities('main', caps);
    b.SetPrincipalCapabilities('window:main', caps);
    if WithSocket then
    begin
      b.MapMethod(PWEB_METHOD_SOCKET_OPEN, [PWEB_CAP_NETWORK_SOCKET]);
      b.MapMethod(PWEB_METHOD_SOCKET_SEND, [PWEB_CAP_NETWORK_SOCKET]);
      b.MapMethod(PWEB_METHOD_SOCKET_RECEIVE, [PWEB_CAP_NETWORK_SOCKET]);
      b.MapMethod(PWEB_METHOD_SOCKET_CLOSE, [PWEB_CAP_NETWORK_SOCKET]);
    end;
    if WithFetch then
      b.MapMethod(PWEB_METHOD_FETCH, [PWEB_CAP_NETWORK_FETCH]);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

procedure TTestPWebSocketLifecycle.RevocationClosesImmediately;
var
  b: TPWebSocketBridge;
  keep: IInvocationBridge;
  policy: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  id: RawUtf8;
  c: TFakeConn;
begin
  FakeReset;
  policy := BuildSocketPolicy(true, true);
  policyRef := policy;
  b := NewBridge;
  keep := b;
  try
    b.AttachPolicy(policy);
    id := IdOf(OpenUrl(b, 'wss://api.example.com/'));
    c := LastConn;
    Receive(b, id);
    // a grant change that KEEPS network.socket closes nothing - an explicit
    // factor first, because revoking one capability from an ABSENT factor
    // empties it (CAP-8A's documented fail-closed rule)
    policy.SetRuntimeGrants('window:main',
      ['calculator.add', PWEB_CAP_NETWORK_SOCKET, PWEB_CAP_NETWORK_FETCH]);
    policy.RevokeRuntimeGrant('window:main', 'calculator.add');
    CheckEqual(b.OpenCount, 1, 'an unrelated revocation closed a socket');
    policy.ClearRuntimeGrants('window:main');
    CheckEqual(b.OpenCount, 1, 'clearing grants back to the static set closed a socket');
    // the revocation itself
    policy.SetRuntimeGrants('window:main', ['calculator.add']);
    // BEFORE the revoking call returned: the socket is closed for every call
    CheckEqual(b.OpenCount, 0, 'a revoked socket survived the revoking call');
    CheckEqual(Verdict(Call(b, PWEB_METHOD_SOCKET_SEND,
      '{"id":' + QuotedStrJson(id) + ',"text":"x"}', Ctx)),
      'service_error:socket_not_found');
    CheckEqual(FakeSendCalls, 0, 'a revoked socket reached the transport');
    // a frame the server sends after the revoke is discarded, never queued
    c.Sink.Deliver(false, 'after-revoke');
    CheckEqual(b.QueuedEvents(id), 0);
    Check(WaitUntil(FakeReleaseCalls, 1, 2000), 'a revoked socket was not released');
    CheckEqual(c.CloseCode, 1001);
    Record_('lifecycle|revoke|closed-before-return|0-sends|late-frame-discarded|close-1001');
    b.BeforeDrain;
  finally
    keep := nil;
    policyRef := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  POLICY - the real policy and the real scheduler
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

function ThroughScheduler(Policy: TPWebCapabilityPolicy;
  const Method: Utf8String; const Args: TPWebJson): TPWebInvocationResult;
var
  bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TPolicySink;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
  policyRef: ICapabilityPolicy;
  impl: TPWebSocketBridge;
  context: TInvocationContext;
begin
  FakeReset;
  Result := Default(TPWebInvocationResult);
  impl := TPWebSocketBridge.Create(TInnerCounter.Create, FakeTransport,
    ORIGINS, PWebSocketDefaultBounds);
  bridge := impl;
  policyRef := Policy;
  scheduler := TInvocationScheduler.Create(policyRef, bridge, 1);
  schedulerRef := scheduler;
  try
    limits.MaxConcurrent := 1;
    limits.MaxQueueSize := 4;
    source := scheduler.RegisterSource(limits);
    sink := TPolicySink.Create;
    sinkRef := sink;
    // the context a host builds: the policy's own per-invocation snapshot
    context := Ctx;
    context.Capabilities := Policy.SnapshotCapabilities('window:main', 'main');
    if source.TryEnqueue(context, Method, Args, sinkRef) = perAccepted then
      if sink.Wait(5000) then
        Result := sink.Res;
  finally
    impl.BeforeDrain;
    scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    bridge := nil;
    policyRef := nil;
  end;
end;

procedure TTestPWebSocketPolicy.GrantedReachesTheDoor;
var
  r: TPWebInvocationResult;
begin
  r := ThroughScheduler(BuildSocketPolicy(true, false), PWEB_METHOD_SOCKET_OPEN,
    '{"url":"wss://api.example.com/"}');
  CheckEqual(ErrorCodeOf(r), 'success');
  CheckEqual(FakeOpens, 1);
  Record_('policy|granted|success|opens=1');
end;

procedure TTestPWebSocketPolicy.RevokedIsForbiddenWithZeroTransport;
var
  policy: TPWebCapabilityPolicy;
  r: TPWebInvocationResult;
begin
  policy := BuildSocketPolicy(true, false);
  policy.SetRuntimeGrants('window:main', ['calculator.add']);
  r := ThroughScheduler(policy, PWEB_METHOD_SOCKET_OPEN,
    '{"url":"wss://api.example.com/"}');
  CheckEqual(ErrorCodeOf(r), 'forbidden');
  CheckEqual(FakeOpens, 0, 'a forbidden open reached the transport');
  Record_('policy|revoked|forbidden|opens=0');
  policy := BuildSocketPolicy(true, false);
  policy.SetRuntimeGrants('window:main', ['calculator.add', PWEB_CAP_NETWORK_SOCKET]);
  r := ThroughScheduler(policy, PWEB_METHOD_SOCKET_OPEN,
    '{"url":"wss://api.example.com/"}');
  CheckEqual(ErrorCodeOf(r), 'success');
  CheckEqual(FakeOpens, 1);
  Record_('policy|regranted|success|opens=1');
end;

function MappingOutsideAppMaximumRaises: Boolean;
var
  b: TPWebCapabilityPolicyBuilder;
  p: TPWebCapabilityPolicy;
begin
  Result := False;
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum(['calculator.add']);
    b.MapMethod(PWEB_METHOD_SOCKET_OPEN, [PWEB_CAP_NETWORK_SOCKET]);
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

procedure TTestPWebSocketPolicy.AbsentFromAppMaximumIsForbidden;
var
  r: TPWebInvocationResult;
begin
  r := ThroughScheduler(BuildSocketPolicy(false, false), PWEB_METHOD_SOCKET_OPEN,
    '{"url":"wss://api.example.com/"}');
  CheckEqual(ErrorCodeOf(r), 'forbidden');
  CheckEqual(FakeOpens, 0);
  Record_('policy|absent-from-appmaximum|forbidden|opens=0');
  Check(MappingOutsideAppMaximumRaises,
    'a policy mapping pweb.socket.open outside AppMaximum was built');
  Record_('policy|mapping-outside-appmaximum|construction-refused');
end;

procedure TTestPWebSocketPolicy.FetchDoesNotImplySocket;
var
  r: TPWebInvocationResult;
begin
  // network.fetch and network.socket are two capabilities, exactly: holding
  // one reaches nothing behind the other
  r := ThroughScheduler(BuildSocketPolicy(false, true), PWEB_METHOD_SOCKET_OPEN,
    '{"url":"wss://api.example.com/"}');
  CheckEqual(ErrorCodeOf(r), 'forbidden');
  CheckEqual(FakeOpens, 0);
  Record_('policy|fetch-only|socket-open|forbidden|opens=0');
end;

initialization
  InitCriticalSection(FakeLock);

finalization
  FakeReset;
  if Length(Corpus) > 0 then
  begin
    ForceDirectories('build/cap15c');
    FileFromString(RawUtf8ArrayToCsv(Corpus, #10) + #10,
      PWEB_CAP15C_CORPUS_FILE);
  end;
  DoneCriticalSection(FakeLock);

end.
