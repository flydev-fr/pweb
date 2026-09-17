{
  pweb.rpc.socket - the native WebSocket door (CAP-15C).

  FOUR runtime-owned methods behind ONE capability, `network.socket`:

    pweb.socketOpen      url, protocols?, headers?    ->  id
    pweb.socketSend      id, text | base64            ->  (empty object)
    pweb.socketReceive   id, waitMs?                  ->  events [...]
    pweb.socketClose     id, code?, reason?           ->  (empty object)

  The page opens a WebSocket to a declared origin THROUGH THE NATIVE HOST.
  The engine opens none: `PWEB_NATIVE_CSP` keeps `connect-src 'self'`, byte
  for byte, which is the decision CAP-15A ratified and CAP-15B built fetch on.

  ---------------------------------------------------------------------------
  THE SHAPE - CAP-15B's, with a queue
  ---------------------------------------------------------------------------

  An IInvocationBridge DECORATOR and nothing else: no eighth interface, no
  second RPC path, no scheduler hook, no listening socket, and NO
  AUTHORIZATION HERE - CAP-8A's policy already ran at the scheduler, so a
  principal without `network.socket` never reaches this code.

  THE TRANSPORT IS INJECTED, as a record of plain function types rather than
  an interface, so the kernel's seven frozen boundaries stay seven. mORMot's
  socket layer on Windows and Linux (`pweb.rpc.socket.mormot`),
  NSURLSessionWebSocketTask on Darwin (`pweb.platform.cocoa.socket`). This
  unit names no `mormot.net.*` unit, carries no compiler conditional and
  names no operating system.

  ---------------------------------------------------------------------------
  THE QUEUE IS THE BACKPRESSURE
  ---------------------------------------------------------------------------

  Every socket owns a bounded event queue (PWEB_SOCKET_QUEUE_EVENTS events,
  PWEB_SOCKET_QUEUE_BYTES bytes). A transport asks TPWebSocketSink.Room
  before it reads a message's payload, and WHILE THE ANSWER IS NO IT STOPS
  READING: the kernel buffer fills, the TCP window closes and the server's
  writes block, while the transport's own writes carry on. Nothing is
  dropped from a live socket, ever - measured at Checkpoint 1 on both
  targets, 1024 of 1024 with no gap (cap15c-checkpoint1.md §2). One message
  no larger than the byte bound always fits an EMPTY queue, so a bound can
  never deadlock a legal message and the peak is the bound.

  `receive` is a bounded LONG-POLL: it returns what is queued at once, or
  waits up to `waitMs` for the first event, on the scheduler worker that runs
  it and in one of its source's invocation slots. It is the receive path and
  not a placeholder: CAP-12A measured WebView2
  withholding a streamed body from the page until it is complete, and ratified
  a data plane Range-based, not streaming-based, so no streaming route exists
  for the SDK's receive loop to move onto.

  ---------------------------------------------------------------------------
  THE URL - the wss authorisation rule, with no grammar change
  ---------------------------------------------------------------------------

  The `wss` scheme maps to `https`, `ws` to `http`, and the pair is fixed. The
  authority is validated by THE FETCH GRAMMAR ITSELF - PWebFetchParseOrigin
  over `<mapped scheme>://<authority>` - and compared with the compiled
  allowlist by parsed components through PWebFetchSameOrigin. So a socket
  host and a fetch host cannot mean two different things, and `ws://` is
  reachable only through a declared loopback `http` origin: the grammar
  accepts those only with an explicit port, and a RELEASE `pweb build`
  refuses them by name. This unit therefore has no development branch.

  ---------------------------------------------------------------------------
  LIFECYCLE - a socket cannot outlive what opened it
  ---------------------------------------------------------------------------

  A socket belongs to the (PrincipalId, WindowId) of the native context that
  opened it; any other caller is told `socket_not_found`, exactly as for an
  id that never existed. It is closed when the page closes it, when the peer
  does, when nobody polls it for PWEB_SOCKET_IDLE_MS, when its document is
  replaced (DocumentReplacing), when its capability is revoked
  (AttachPolicy), and before the host drains its scheduler (BeforeDrain).

  Called on scheduler WORKER threads. The lifecycle entry points are called
  on the GUI thread (DocumentReplacing, which never blocks), on the thread
  that changed a grant (the revocation), and on the host's teardown thread
  (BeforeDrain, which releases every transport before it returns).
}
unit pweb.rpc.socket;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.json,
  mormot.crypt.core,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.fetch,
  pweb.capabilities.policy;

const
  { The four runtime-owned methods and their one capability, spelled ONCE for
    the whole repository. The mapping of the four methods to network.socket
    is the HOST's policy configuration, never this unit's.

    CAP-15C AMENDMENT: the brief spelled them `pweb.socket.open` and so on,
    which the FROZEN method grammar refuses - a canonical method is EXACTLY
    two segments, `Service.Method` (wire-semantics.md, PWebValidMethod), so
    those names would have been answered invalid_request at the enqueue gate
    before any policy ran. MEASURED: the CAP-8A builder refused the first
    MapMethod row outright. The runtime-owned precedent is `pweb.openExternal`,
    and these follow it. }
  PWEB_METHOD_SOCKET_OPEN = 'pweb.socketOpen';
  PWEB_METHOD_SOCKET_SEND = 'pweb.socketSend';
  PWEB_METHOD_SOCKET_RECEIVE = 'pweb.socketReceive';
  PWEB_METHOD_SOCKET_CLOSE = 'pweb.socketClose';
  PWEB_CAP_NETWORK_SOCKET = 'network.socket';

  { --- the ratified bounds (cap15c-checkpoint1.md §7) - ONE constants home;
    test/cap15c cross-checks every one of them against the SDKs and the
    contract ----------------------------------------------------------- }

  /// open sockets per HOST PROCESS, across every principal, counted from the
  // moment an open starts until its transport has been released
  PWEB_SOCKET_MAX_SOCKETS = 4;

  /// the wall-clock bound on TCP connect + TLS + the HTTP upgrade
  // - a socket timeout is not a deadline (ledger 15A-5, met again at
  // Checkpoint 1: a 1000 ms timeout, a 101 held for 5 s, upgraded at 5000 ms)
  PWEB_SOCKET_CONNECT_DEADLINE_MS = 10000;

  /// the wall-clock bound on one send
  // - MEASURED at Checkpoint 1: a peer that stops reading held a send 4016 ms
  // on Windows and 8041 ms on Linux against a 2000 ms socket timeout
  PWEB_SOCKET_SEND_DEADLINE_MS = 10000;

  /// one message, either direction: inbound checked on every frame HEADER
  // against the reassembled total, outbound on the decoded bytes
  PWEB_SOCKET_MAX_MESSAGE = 1 shl 20;

  /// the per-socket event queue - the backpressure bound
  PWEB_SOCKET_QUEUE_EVENTS = 64;
  PWEB_SOCKET_QUEUE_BYTES = 1 shl 20;

  /// the long-poll ceiling; a larger waitMs is REFUSED, never clamped
  PWEB_SOCKET_MAX_WAIT_MS = 25000;

  /// a socket with no receive in flight and none returned for this long is
  // closed with a typed reason
  PWEB_SOCKET_IDLE_MS = 60000;

  /// how long a page-initiated close waits for the peer's echo before the
  // transport is released anyway
  PWEB_SOCKET_CLOSE_WAIT_MS = 2000;

  /// subprotocols offered: at most four RFC 7230 tokens of at most 64 bytes
  PWEB_SOCKET_MAX_PROTOCOLS = 4;
  PWEB_SOCKET_MAX_PROTOCOL_BYTES = 64;

  /// the URL and handshake-header bounds ARE fetch's, by name, so the two
  // doors cannot drift apart
  PWEB_SOCKET_MAX_URL_BYTES = PWEB_FETCH_MAX_URL_BYTES;
  PWEB_SOCKET_MAX_HEADERS = PWEB_FETCH_MAX_HEADERS;
  PWEB_SOCKET_MAX_HEADER_BYTES = PWEB_FETCH_MAX_HEADER_BYTES;

  /// RFC 6455 section 5.5: a close frame carries at most 125 bytes, two of
  // which are the code
  PWEB_SOCKET_MAX_REASON_BYTES = 123;

  /// the invocation request bound a network host's binding is given, so a
  // 1 MiB binary message - 1 398 104 base64 characters - can cross at all
  // (cap15c-checkpoint1.md F-8)
  PWEB_SOCKET_REQUEST_BYTES = 2 shl 20;

  /// the close code every NATIVE decision sends the peer - idle, navigation,
  // revocation, shutdown. "Going away", and nothing about why
  PWEB_SOCKET_NATIVE_CLOSE_CODE = 1001;

  /// the typed service_error categories of this door
  PWEB_SOCKET_CAT_NOT_FOUND = 'socket_not_found';
  PWEB_SOCKET_CAT_LIMIT = 'socket_limit';
  PWEB_SOCKET_CAT_CLOSED = 'socket_closed';
  PWEB_SOCKET_CAT_CONNECT = 'connect_failed';
  PWEB_SOCKET_CAT_TLS = 'tls_failed';
  PWEB_SOCKET_CAT_HANDSHAKE = 'handshake_refused';
  PWEB_SOCKET_CAT_DEADLINE = 'deadline';
  PWEB_SOCKET_CAT_SEND = 'send_failed';

type
  /// raised only for direct misuse of this API at construction time
  EPWebSocket = class(Exception);

  /// the bounds a bridge runs with - the constants above, except in a test
  // harness that needs an idle bound shorter than a minute
  TPWebSocketBounds = record
    MaxSockets: Integer;
    ConnectDeadlineMs: Integer;
    SendDeadlineMs: Integer;
    MaxMessage: PtrInt;
    QueueEvents: Integer;
    QueueBytes: PtrInt;
    MaxWaitMs: Integer;
    IdleMs: Integer;
    CloseWaitMs: Integer;
  end;

  /// what the decorator hands a transport - validated, parsed, never re-parsed
  TPWebSocketRequest = record
    Url: RawUtf8;
    Scheme: RawUtf8;          // 'wss' or 'ws'
    Host: RawUtf8;            // lowercase, as the fetch grammar accepted it
    Port: Integer;            // canonical
    Tls: Boolean;
    Target: RawUtf8;          // path + query, always starting with '/'
    Headers: RawUtf8;         // CRLF-separated allowlisted `Name: Value` lines
    Protocols: TRawUtf8DynArray;
    ConnectDeadlineMs: Integer;
    SendDeadlineMs: Integer;
    MaxMessage: PtrInt;
  end;

  /// how a transport call ended - a CATEGORY, never a native detail
  TPWebSocketOutcome = (
    psoOk,
    psoConnectFailed,
    psoTlsFailed,
    /// a 3xx answered the upgrade - refused, NEVER followed
    psoHandshakeRedirect,
    /// any other non-101 status
    psoHandshakeStatus,
    /// a 101 whose Upgrade, Connection or Sec-WebSocket-Accept is wrong, or
    /// that negotiated an extension nobody asked for
    psoHandshakeUpgrade,
    /// a subprotocol that was not offered, or none when some were
    psoHandshakeSubprotocol,
    psoDeadline,
    psoCancelled,
    psoClosed,
    psoSendFailed);

  /// why a connection ended by itself
  TPWebSocketCloseCause = (
    /// the peer sent a close frame (its code and reason are carried)
    pscRemote,
    /// the connection ended without a close handshake
    pscAbnormal,
    /// the peer broke RFC 6455: a masked frame, a reserved bit or opcode, a
    /// control frame over 125 bytes, invalid UTF-8 in a text message
    pscProtocolError,
    /// an inbound message crossed the message bound
    pscMessageTooLarge);

  /// is there room in the page's queue for a message of Size bytes?
  // - THE BACKPRESSURE. A transport asks BEFORE it reads a message's payload,
  // and while the answer is False it stops READING - the kernel buffer fills,
  // the TCP window closes, the server's writes block - while it keeps
  // WRITING, so a page can still send to a peer it is not keeping up with
  // - a closed socket always answers True: whatever is read is discarded
  TPWebSocketRoom = function(Size: PtrInt): Boolean of object;
  /// ONE MESSAGE for the page, after Room said yes; never blocks
  // - it is NOT a blocking call on purpose: a TLS session is not safe to read
  // and write from two threads (OpenSSL's SSL object, SChannel's context),
  // so a transport reads and writes on ONE thread, and a sink that parked
  // that thread would stall its writes along with its reads
  TPWebSocketDeliver = procedure(Binary: Boolean;
    const Payload: RawByteString) of object;
  /// the connection ended by itself; called at most once, never blocks
  TPWebSocketClosed = procedure(Cause: TPWebSocketCloseCause; Code: Integer;
    const Reason: RawUtf8) of object;

  TPWebSocketSink = record
    Room: TPWebSocketRoom;
    Deliver: TPWebSocketDeliver;
    Closed: TPWebSocketClosed;
  end;

  { The injected transport. Contract for an implementation:
      - Open performs TCP, TLS with validation that nothing can disable, and
        the RFC 6455 upgrade under Request.ConnectDeadlineMs observed DURING
        the exchange; it follows no redirect, keeps no cookie, inherits no
        proxy, answers the ping/pong and reassembles fragments ITSELF, and
        never raises;
      - after Open returns psoOk the sink may be called from any thread,
        until Release returns and never after;
      - it asks Sink.Room before reading a message's payload, stops READING
        while the answer is False, and keeps WRITING meanwhile;
      - Send writes one whole message under Request.SendDeadlineMs;
      - Close sends a close frame and does NOT wait for the echo;
      - Release stops the reader and closes the connection; it may block
        briefly, and is never called on the GUI thread. }
  TPWebSocketOpenFn = function(const Request: TPWebSocketRequest;
    const Sink: TPWebSocketSink; const Token: ICancellationToken;
    out Handle: Pointer; out Selected: RawUtf8): TPWebSocketOutcome;
  TPWebSocketSendFn = function(Handle: Pointer; Binary: Boolean;
    const Payload: RawByteString): TPWebSocketOutcome;
  TPWebSocketCloseFn = procedure(Handle: Pointer; Code: Integer;
    const Reason: RawUtf8);
  TPWebSocketReleaseFn = procedure(Handle: Pointer);

  TPWebSocketTransport = record
    Open: TPWebSocketOpenFn;
    Send: TPWebSocketSendFn;
    Close: TPWebSocketCloseFn;
    Release: TPWebSocketReleaseFn;
  end;

  TPWebSocketBridge = class;

  TPWebSocketEventKind = (sekOpen, sekText, sekBinary, sekError, sekClose);

  TPWebSocketEvent = record
    Kind: TPWebSocketEventKind;
    Data: RawByteString;
    Code: Integer;
    Reason: RawUtf8;
    Category: RawUtf8;
    WasClean: Boolean;
    Undelivered: Integer;
  end;

  TPWebSocketState = (pssOpening, pssOpen, pssClosing, pssClosed);

  { One socket. Every field is guarded by the bridge's lock, except that
    SendLock serialises Send, Close and Release on the transport handle. }
  TPWebSocketEntry = class
  private
    FBridge: TPWebSocketBridge;
    Id: RawUtf8;
    PrincipalId, WindowId: Utf8String;
    Handle: Pointer;
    Transported: Boolean;
    State: TPWebSocketState;
    Events: array of TPWebSocketEvent;
    Count: Integer;
    Bytes: PtrInt;
    Arrived: TEvent;
    SendLock: TCriticalSection;
    Receiving: Boolean;
    LastPollTix, ClosingTix, ClosedTix: Int64;
    PageCode: Integer;
    NeedRelease, Released, SendCloseFrame: Boolean;
    CloseFrameCode: Integer;
    /// the page received its close event - or never will
    CloseTaken: Boolean;
    /// invisible to every page call: its document or its grant is gone
    Gone: Boolean;
    Refs: Integer;
    Selected: RawUtf8;
    function RoomFor(Size: PtrInt): Boolean;
    procedure Deliver(Binary: Boolean; const Payload: RawByteString);
    procedure TransportClosed(Cause: TPWebSocketCloseCause; Code: Integer;
      const Reason: RawUtf8);
  public
    constructor Create(ABridge: TPWebSocketBridge);
    destructor Destroy; override;
  end;

  TPWebSocketKeeper = class(TThread)
  private
    FBridge: TPWebSocketBridge;
    FWake: TEvent;
  protected
    procedure Execute; override;
  public
    constructor CreateFor(ABridge: TPWebSocketBridge);
    destructor Destroy; override;
  end;

  { The reusable native WebSocket decorator. }
  TPWebSocketBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    FTransport: TPWebSocketTransport;
    FOrigins: TPWebFetchOrigins;
    FBounds: TPWebSocketBounds;
    FLock: TCriticalSection;
    FEntries: array of TPWebSocketEntry;
    FKeeper: TPWebSocketKeeper;
    FDraining: Boolean;
    FPolicy: TPWebCapabilityPolicy;
    /// keeps the attached policy alive as long as this door: a host tearing
    // down in either order can never leave BeforeDrain holding a freed one
    FPolicyRef: ICapabilityPolicy;
    function Open(const Context: TInvocationContext; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    function Send(const Context: TInvocationContext;
      const Args: TPWebJson): TPWebInvocationResult;
    function Receive(const Context: TInvocationContext; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    function CloseSocket(const Context: TInvocationContext;
      const Args: TPWebJson): TPWebInvocationResult;
    function LiveCountLocked: Integer;
    function FindLocked(const Id: RawUtf8): TPWebSocketEntry;
    function AcquireOwned(const Context: TInvocationContext;
      const Id: RawUtf8): TPWebSocketEntry;
    procedure Unref(E: TPWebSocketEntry);
    procedure PushLocked(E: TPWebSocketEntry; const Ev: TPWebSocketEvent;
      AtHead: Boolean = False);
    procedure CloseNativeLocked(E: TPWebSocketEntry; const Category: RawUtf8;
      MakeGone: Boolean);
    procedure ReleaseEntry(E: TPWebSocketEntry);
    procedure Wake;
    procedure Tick;
    procedure GrantsChanged(const APrincipalId: Utf8String);
  public
    { Fail closed: a nil inner bridge, an incomplete transport or an origin
      the grammar refuses all raise here, at startup. AOrigins is the
      canonical set the build compiled in - the SAME array the fetch door
      is given. }
    constructor Create(const AInner: IInvocationBridge;
      const ATransport: TPWebSocketTransport;
      const AOrigins: array of RawUtf8); overload;
    constructor Create(const AInner: IInvocationBridge;
      const ATransport: TPWebSocketTransport;
      const AOrigins: array of RawUtf8;
      const ABounds: TPWebSocketBounds); overload;
    destructor Destroy; override;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;

    /// the document of this window is being replaced: every socket it owns
    // is closed and becomes invisible NOW, and its transport is released by
    // the keeper - this call never blocks, because its caller is the GUI
    // thread's navigation decision
    procedure DocumentReplacing(const AWindowId: RawUtf8);
    /// the host is about to drain its scheduler: every socket is closed and
    // EVERY TRANSPORT RELEASED before this returns, and no socket opens again
    procedure BeforeDrain;
    /// subscribe to the policy's runtime-grant changes, so that a principal
    // losing network.socket loses its sockets before the revoking call returns
    procedure AttachPolicy(APolicy: TPWebCapabilityPolicy);

    /// sockets not yet closed, for the host's accounting and the gates
    function OpenCount: Integer;
    /// test and gate observation of one socket's queue, by id
    function QueuedEvents(const Id: RawUtf8): Integer;
    function QueuedBytes(const Id: RawUtf8): PtrInt;
    /// the idle close, now, for the gate that measures what it discards
    procedure CloseForIdleNow(const Id: RawUtf8);
  end;

/// the ratified bounds
function PWebSocketDefaultBounds: TPWebSocketBounds;

implementation

const
  WAIT_SLICE_MS = 20;
  KEEPER_TICK_MS = 50;

function PWebSocketDefaultBounds: TPWebSocketBounds;
begin
  Result.MaxSockets := PWEB_SOCKET_MAX_SOCKETS;
  Result.ConnectDeadlineMs := PWEB_SOCKET_CONNECT_DEADLINE_MS;
  Result.SendDeadlineMs := PWEB_SOCKET_SEND_DEADLINE_MS;
  Result.MaxMessage := PWEB_SOCKET_MAX_MESSAGE;
  Result.QueueEvents := PWEB_SOCKET_QUEUE_EVENTS;
  Result.QueueBytes := PWEB_SOCKET_QUEUE_BYTES;
  Result.MaxWaitMs := PWEB_SOCKET_MAX_WAIT_MS;
  Result.IdleMs := PWEB_SOCKET_IDLE_MS;
  Result.CloseWaitMs := PWEB_SOCKET_CLOSE_WAIT_MS;
end;

{ ---------------------------------------------------------------------------
  grammar helpers
  --------------------------------------------------------------------------- }

function AsciiLower(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A' .. 'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

{ The socket URL. Byte-checked BEFORE parsing - no control byte, no space, no
  DEL, nothing at or above $80 - then split, mapped, and handed to the fetch
  grammar so the authority means exactly what a fetch authority means. }
function ParseSocketUrl(const Url: RawUtf8; out Origin: TPWebFetchOrigin;
  out Scheme, Target: RawUtf8; out Tls: Boolean): Boolean;
var
  i, start: PtrInt;
  mapped, authority, rest: RawUtf8;
begin
  Result := False;
  Origin := Default(TPWebFetchOrigin);
  Scheme := '';
  Target := '';
  Tls := False;
  if (Url = '') or
     (Length(Url) > PWEB_SOCKET_MAX_URL_BYTES) then
    exit;
  for i := 1 to Length(Url) do
    if (Url[i] <= ' ') or
       (Url[i] >= #127) then
      exit;
  // the scheme is compared EXACTLY, as fetch compares its own - and read as
  // a TOKEN, so no socket URL is spelled anywhere in the runtime
  i := Pos(':', Url);
  if (i < 3) or
     (Copy(Url, i + 1, 2) <> '//') then
    exit;
  Scheme := Copy(Url, 1, i - 1);
  if Scheme = 'wss' then
  begin
    mapped := 'https';
    Tls := True;
  end
  else if Scheme = 'ws' then
    mapped := 'http'
  else
  begin
    Scheme := '';
    exit;
  end;
  start := i + 3;
  i := start;
  while (i <= Length(Url)) and
        not (Url[i] in ['/', '?', '#']) do
    Inc(i);
  if i = start then
    exit; // an empty authority
  authority := AsciiLower(Copy(Url, start, i - start));
  rest := Copy(Url, i, MaxInt);
  // a fragment is never sent; a URL carrying one is confused, not convenient
  if Pos('#', rest) > 0 then
    exit;
  // userinfo is the classic way to make an undeclared host read as a
  // declared one; the grammar refuses it too, and this says so first
  if Pos('@', authority) > 0 then
    exit;
  if not PWebFetchParseOrigin(mapped + '://' + authority, Origin) then
    exit;
  if rest = '' then
    Target := '/'
  else if rest[1] = '?' then
    Target := '/' + rest
  else
    Target := rest;
  Result := True;
end;

// RFC 7230 tchar: what a subprotocol token may be made of
function ValidProtocol(const P: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if (P = '') or
     (Length(P) > PWEB_SOCKET_MAX_PROTOCOL_BYTES) then
    exit;
  for i := 1 to Length(P) do
    if not (P[i] in ['a' .. 'z', 'A' .. 'Z', '0' .. '9', '!', '#', '$', '%',
      '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~']) then
      exit;
  Result := True;
end;

// the fetch door's header-name grammar, after lowercasing
function ValidHeaderName(const Name: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if (Length(Name) < 1) or
     (Length(Name) > 64) then
    exit;
  for i := 1 to Length(Name) do
    if not (Name[i] in ['a' .. 'z', '0' .. '9', '-', '_', '.', '~', '+']) then
      exit;
  Result := True;
end;

// THE 15B §4 REQUEST-HEADER ALLOWLIST, exactly. Everything a WebSocket
// handshake owns - host, upgrade, connection, sec-websocket-*, origin,
// cookie - is outside it by construction rather than by a second list
function RequestHeaderAllowed(const Lower: RawUtf8): Boolean;
begin
  Result := (Lower = 'accept') or
            (Lower = 'accept-language') or
            (Lower = 'authorization') or
            (Lower = 'content-type') or
            (Lower = 'if-match') or
            (Lower = 'if-none-match') or
            (Lower = 'if-modified-since') or
            ((Length(Lower) > 2) and (Copy(Lower, 1, 2) = 'x-'));
end;

function HasControlByte(const S: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := True;
  for i := 1 to Length(S) do
    if (S[i] = #13) or (S[i] = #10) or (S[i] = #0) then
      exit;
  Result := False;
end;

procedure SkipBlanks(var P: PUtf8Char);
begin
  while (P <> nil) and
        (P^ <= ' ') and
        (P^ <> #0) do
    Inc(P);
end;

{ ---------------------------------------------------------------------------
  argument decoding - mORMot's parser, member by member, because the
  DISTINCTION between a string, an array, an object and a number is exactly
  what this contract makes a refusal
  --------------------------------------------------------------------------- }

type
  TSockArgKind = (sakAbsent, sakString, sakObject, sakArray, sakNumber,
    sakOther);

  TSockArg = record
    Kind: TSockArgKind;
    Text: RawUtf8;
  end;

  TSockArgName = (sanUrl, sanProtocols, sanHeaders, sanId, sanText, sanBase64,
    sanWaitMs, sanCode, sanReason);
  TSockArgNames = set of TSockArgName;
  TSockArgs = array[TSockArgName] of TSockArg;

const
  SOCK_ARG_TEXT: array[TSockArgName] of RawUtf8 = ('url', 'protocols',
    'headers', 'id', 'text', 'base64', 'waitMs', 'code', 'reason');

// an escaped NUL inside a JSON string
// - MEASURED while this suite was written: mORMot's parser decodes an escaped
// NUL (backslash, u, four zeros) as '?' - mormot.core.json calls it "an invalid
// value (at least in our framework)" - so a text of a, NUL, b would reach the wire as `a?b` - a text
// message silently rewritten, and a URL path silently turned into a query.
// A page's string is either carried exactly or refused, so it is refused
function HasEscapedNul(const Json: RawUtf8): Boolean;
var
  i, n: PtrInt;
  inString: Boolean;
begin
  Result := False;
  inString := False;
  n := Length(Json);
  i := 1;
  while i <= n do
  begin
    // a RAW NUL ends mORMot's buffer walk and truncates the value; no page
    // can send one (the binding's C string would end there), but a native
    // caller can, and it is refused for the same reason
    if Json[i] = #0 then
      exit(True);
    if inString then
    begin
      if Json[i] = '\' then
      begin
        if (i + 5 <= n) and
           (Json[i + 1] = 'u') and
           (Json[i + 2] = '0') and
           (Json[i + 3] = '0') and
           (Json[i + 4] = '0') and
           (Json[i + 5] = '0') then
          exit(True);
        Inc(i, 2); // the escaped character, whatever it is
        continue;
      end;
      if Json[i] = '"' then
        inString := False;
    end
    else if Json[i] = '"' then
      inString := True;
    Inc(i);
  end;
end;

// False for malformed JSON, an argument this method does not define, a
// repeated one, or an escaped NUL - each a refusal, never a value to ignore
function DecodeArgs(const Args: TPWebJson; Allowed: TSockArgNames;
  out Decoded: TSockArgs): Boolean;
var
  payload, name: RawUtf8;
  field: TGetJsonField;
  n, found: TSockArgName;
  known: Boolean;
begin
  Result := False;
  for n := Low(TSockArgName) to High(TSockArgName) do
  begin
    Decoded[n].Kind := sakAbsent;
    Decoded[n].Text := '';
  end;
  // mORMot's parser unescapes IN PLACE: never walk the caller's buffer
  payload := RawUtf8(Args);
  UniqueRawUtf8(payload);
  if (payload = '') or
     (payload = PWEB_JSON_NULL) then
    exit(True);
  if HasEscapedNul(payload) then
    exit;
  field.Json := pointer(payload);
  SkipBlanks(field.Json);
  if (field.Json = nil) or
     (field.Json^ <> '{') then
    exit;
  Inc(field.Json);
  SkipBlanks(field.Json);
  if (field.Json <> nil) and
     (field.Json^ = '}') then
    exit(True);
  repeat
    if not field.GetJsonFieldName then
      exit;
    FastSetString(name, field.Value, field.ValueLen);
    field.GetJsonFieldOrObjectOrArray({HandleValuesAsObjectOrArray=}true);
    if field.Json = nil then
      exit;
    known := False;
    found := sanUrl;
    for n := Low(TSockArgName) to High(TSockArgName) do
      if (n in Allowed) and
         (SOCK_ARG_TEXT[n] = name) then
      begin
        known := True;
        found := n;
        break;
      end;
    if not known then
      exit;
    if Decoded[found].Kind <> sakAbsent then
      exit; // repeated
    if field.Value = nil then
      // a JSON null reads as ABSENT, the only sane meaning of `"reason": null`
      Decoded[found].Kind := sakAbsent
    else
    begin
      FastSetString(Decoded[found].Text, field.Value, field.ValueLen);
      if field.WasString then
        Decoded[found].Kind := sakString
      else if Decoded[found].Text = '' then
        Decoded[found].Kind := sakOther
      else
        case Decoded[found].Text[1] of
          '{': Decoded[found].Kind := sakObject;
          '[': Decoded[found].Kind := sakArray;
          '-', '0' .. '9': Decoded[found].Kind := sakNumber;
        else
          Decoded[found].Kind := sakOther;
        end;
    end;
  until field.EndOfObject <> ',';
  Result := field.EndOfObject = '}';
end;

// an integer argument, and nothing else: no fraction, no exponent
function ArgInteger(const A: TSockArg; out Value: Integer): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  Value := 0;
  if (A.Kind <> sakNumber) or
     (Length(A.Text) > 10) then
    exit;
  for i := 1 to Length(A.Text) do
    if not ((A.Text[i] in ['0' .. '9']) or ((i = 1) and (A.Text[i] = '-'))) then
      exit;
  Result := TryStrToInt(string(A.Text), Value);
end;

function ParseProtocols(var Json: RawUtf8; out List: TRawUtf8DynArray): Boolean;
var
  field: TGetJsonField;
  s: RawUtf8;
  i: PtrInt;
begin
  Result := False;
  List := nil;
  UniqueRawUtf8(Json);
  field.Json := pointer(Json);
  SkipBlanks(field.Json);
  if (field.Json = nil) or
     (field.Json^ <> '[') then
    exit;
  Inc(field.Json);
  SkipBlanks(field.Json);
  if (field.Json <> nil) and
     (field.Json^ = ']') then
    exit(True);
  repeat
    field.GetJsonField;
    if (field.Value = nil) or
       not field.WasString then
      exit;
    FastSetString(s, field.Value, field.ValueLen);
    if not ValidProtocol(s) then
      exit;
    for i := 0 to High(List) do
      if List[i] = s then
        exit; // a duplicate offer is an ambiguity, refused
    if Length(List) >= PWEB_SOCKET_MAX_PROTOCOLS then
      exit;
    SetLength(List, Length(List) + 1);
    List[High(List)] := s;
  until field.EndOfObject <> ',';
  Result := field.EndOfObject = ']';
end;

// one `headers` object into the CRLF block the handshake carries
function BuildHeaderBlock(var HeadersJson: RawUtf8; out Block: RawUtf8): Boolean;
var
  field: TGetJsonField;
  name, lower, value: RawUtf8;
  seen: TRawUtf8DynArray;
  i, count: PtrInt;
begin
  Result := False;
  Block := '';
  count := 0;
  seen := nil;
  UniqueRawUtf8(HeadersJson);
  field.Json := pointer(HeadersJson);
  SkipBlanks(field.Json);
  if (field.Json = nil) or
     (field.Json^ <> '{') then
    exit;
  Inc(field.Json);
  SkipBlanks(field.Json);
  if (field.Json <> nil) and
     (field.Json^ = '}') then
    exit(True);
  repeat
    if not field.GetJsonFieldName then
      exit;
    FastSetString(name, field.Value, field.ValueLen);
    field.GetJsonField;
    if (field.Json = nil) and
       (field.EndOfObject <> '}') then
      exit;
    if not field.WasString then
      exit; // `{"x-n": 5}` is not `{"x-n": "5"}`
    FastSetString(value, field.Value, field.ValueLen);
    lower := AsciiLower(name);
    if not ValidHeaderName(lower) or
       not RequestHeaderAllowed(lower) then
      exit;
    for i := 0 to High(seen) do
      if seen[i] = lower then
        exit; // one name, one value
    if (Length(value) > PWEB_SOCKET_MAX_HEADER_BYTES) or
       HasControlByte(value) then
      exit;
    Inc(count);
    if count > PWEB_SOCKET_MAX_HEADERS then
      exit;
    SetLength(seen, Length(seen) + 1);
    seen[High(seen)] := lower;
    Block := Block + name + ': ' + value + #13#10;
  until field.EndOfObject <> ',';
  Result := field.EndOfObject = '}';
end;

function NewSocketId: RawUtf8;
const
  HEX: array[0 .. 15] of AnsiChar = '0123456789abcdef';
var
  b: THash128;
  i: Integer;
begin
  // unguessable across principals: an id is never an authorisation, but it
  // should not be an enumeration either
  Random128(@b);
  SetLength(Result, 32);
  for i := 0 to 15 do
  begin
    Result[i * 2 + 1] := HEX[b[i] shr 4];
    Result[i * 2 + 2] := HEX[b[i] and 15];
  end;
end;

// a peer's close reason cut to the RFC bound without splitting a character
function BoundReason(const Reason: RawUtf8): RawUtf8;
begin
  Result := Reason;
  if Length(Result) > PWEB_SOCKET_MAX_REASON_BYTES then
    SetLength(Result, PWEB_SOCKET_MAX_REASON_BYTES);
  while (Result <> '') and
        not IsValidUtf8(Result) do
    SetLength(Result, Length(Result) - 1);
end;

function ServiceError(const Category: RawUtf8;
  const Extra: RawUtf8 = ''): TPWebInvocationResult;
var
  data: RawUtf8;
begin
  data := '{"category":' + QuotedStrJson(Category);
  if Extra <> '' then
    data := data + ',' + Extra;
  data := data + '}';
  Result := PWebErrorResult(pecServiceError, Utf8String(Category),
    TPWebJson(data));
end;

function Invalid(const Why: Utf8String): TPWebInvocationResult;
begin
  Result := PWebErrorResult(pecInvalidRequest, Why);
end;

function EventJson(const Ev: TPWebSocketEvent): RawUtf8;
begin
  case Ev.Kind of
    sekOpen:
      Result := '{"type":"open","protocol":' + QuotedStrJson(Ev.Reason) + '}';
    sekText:
      Result := '{"type":"message","text":' +
        QuotedStrJson(RawUtf8(Ev.Data)) + '}';
    sekBinary:
      Result := '{"type":"message","base64":"' + BinToBase64(Ev.Data) + '"}';
    sekError:
      Result := '{"type":"error","category":' + QuotedStrJson(Ev.Category) + '}';
  else
    begin
      Result := '{"type":"close","code":' + RawUtf8(IntToStr(Ev.Code)) +
        ',"reason":' + QuotedStrJson(Ev.Reason) + ',"wasClean":';
      if Ev.WasClean then
        Result := Result + 'true'
      else
        Result := Result + 'false';
      Result := Result + ',"category":' + QuotedStrJson(Ev.Category) +
        ',"undelivered":' + RawUtf8(IntToStr(Ev.Undelivered)) + '}';
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  TPWebSocketEntry - the transport's side of the queue
  --------------------------------------------------------------------------- }

constructor TPWebSocketEntry.Create(ABridge: TPWebSocketBridge);
begin
  inherited Create;
  FBridge := ABridge;
  Arrived := TEvent.Create(nil, False, False, '');
  SendLock := TCriticalSection.Create;
end;

destructor TPWebSocketEntry.Destroy;
begin
  Arrived.Free;
  SendLock.Free;
  inherited Destroy;
end;

procedure TPWebSocketEntry.Deliver(Binary: Boolean;
  const Payload: RawByteString);
var
  ev: TPWebSocketEvent;
  n: PtrInt;
begin
  n := Length(Payload);
  FBridge.FLock.Enter;
  try
    if (not Binary) and
       not IsValidUtf8(Payload) then
    begin
      // a transport validates UTF-8 itself; this is the second line, and it
      // answers the peer's defect as the RFC does rather than passing bytes
      // to a page that was promised text
      if State <> pssClosed then
      begin
        ev := Default(TPWebSocketEvent);
        ev.Kind := sekError;
        ev.Category := 'protocol_error';
        FBridge.PushLocked(Self, ev);
        ev := Default(TPWebSocketEvent);
        ev.Kind := sekClose;
        ev.Code := 1007;
        ev.Category := 'protocol_error';
        FBridge.PushLocked(Self, ev);
        State := pssClosed;
        ClosedTix := GetTickCount64;
        if Transported then
        begin
          NeedRelease := True;
          SendCloseFrame := True;
          CloseFrameCode := 1007;
        end;
        FBridge.Wake;
      end;
      exit;
    end;
    // a closed socket takes nothing more: the late frame is discarded
    if State = pssClosed then
      exit;
    // the transport asked RoomFor first; a message is never refused here,
    // because refusing it would be the silent drop this door does not do
    ev := Default(TPWebSocketEvent);
    if Binary then
      ev.Kind := sekBinary
    else
      ev.Kind := sekText;
    ev.Data := Payload;
    FBridge.PushLocked(Self, ev);
  finally
    FBridge.FLock.Leave;
  end;
end;

function TPWebSocketEntry.RoomFor(Size: PtrInt): Boolean;
begin
  FBridge.FLock.Enter;
  try
    Result := (State = pssClosed) or
              (Count = 0) or
              ((Count < FBridge.FBounds.QueueEvents) and
               (Bytes + Size <= FBridge.FBounds.QueueBytes));
  finally
    FBridge.FLock.Leave;
  end;
end;

procedure TPWebSocketEntry.TransportClosed(Cause: TPWebSocketCloseCause;
  Code: Integer; const Reason: RawUtf8);
var
  ev: TPWebSocketEvent;
begin
  FBridge.FLock.Enter;
  try
    if State = pssClosed then
      exit;
    ev := Default(TPWebSocketEvent);
    case Cause of
      pscRemote:
        if State = pssClosing then
          ev.Category := 'page'
        else
          ev.Category := 'remote';
      pscAbnormal:
        ev.Category := 'abnormal';
      pscProtocolError:
        ev.Category := 'protocol_error';
    else
      ev.Category := 'message_too_large';
    end;
    if Cause <> pscRemote then
    begin
      ev.Kind := sekError;
      FBridge.PushLocked(Self, ev);
    end;
    ev.Kind := sekClose;
    ev.Code := Code;
    ev.Reason := BoundReason(Reason);
    ev.WasClean := Cause = pscRemote;
    FBridge.PushLocked(Self, ev);
    State := pssClosed;
    ClosedTix := GetTickCount64;
    if Transported then
      NeedRelease := True;
    FBridge.Wake;
  finally
    FBridge.FLock.Leave;
  end;
end;

{ ---------------------------------------------------------------------------
  TPWebSocketKeeper - idle bounds, close waits, releases
  --------------------------------------------------------------------------- }

constructor TPWebSocketKeeper.CreateFor(ABridge: TPWebSocketBridge);
begin
  FBridge := ABridge;
  FWake := TEvent.Create(nil, False, False, '');
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TPWebSocketKeeper.Destroy;
begin
  FWake.Free;
  inherited Destroy;
end;

procedure TPWebSocketKeeper.Execute;
begin
  while not Terminated do
  begin
    FWake.WaitFor(KEEPER_TICK_MS);
    if Terminated then
      break;
    try
      FBridge.Tick;
    except
      // the keeper never dies of one socket
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  TPWebSocketBridge
  --------------------------------------------------------------------------- }

constructor TPWebSocketBridge.Create(const AInner: IInvocationBridge;
  const ATransport: TPWebSocketTransport; const AOrigins: array of RawUtf8);
begin
  Create(AInner, ATransport, AOrigins, PWebSocketDefaultBounds);
end;

constructor TPWebSocketBridge.Create(const AInner: IInvocationBridge;
  const ATransport: TPWebSocketTransport; const AOrigins: array of RawUtf8;
  const ABounds: TPWebSocketBounds);
var
  detail: RawUtf8;
  refusal: TPWebFetchOriginsRefusal;
begin
  inherited Create;
  if AInner = nil then
    raise EPWebSocket.Create('TPWebSocketBridge requires an inner bridge');
  if not Assigned(ATransport.Open) or
     not Assigned(ATransport.Send) or
     not Assigned(ATransport.Close) or
     not Assigned(ATransport.Release) then
    raise EPWebSocket.Create('TPWebSocketBridge requires a complete transport');
  // the compiled allowlist, through the SAME parser every socket URL's
  // authority goes through, once, at startup
  if not PWebFetchParseOrigins(AOrigins, FOrigins, refusal, detail) then
    raise EPWebSocket.CreateFmt(
      'TPWebSocketBridge refuses the compiled origin allowlist: %s', [detail]);
  FInner := AInner;
  FTransport := ATransport;
  FBounds := ABounds;
  FLock := TCriticalSection.Create;
  FKeeper := TPWebSocketKeeper.CreateFor(Self);
end;

destructor TPWebSocketBridge.Destroy;
var
  i: Integer;
begin
  if not FDraining then
    BeforeDrain;
  if FKeeper <> nil then
  begin
    FKeeper.Terminate;
    FKeeper.FWake.SetEvent;
    FKeeper.WaitFor;
    FreeAndNil(FKeeper);
  end;
  for i := 0 to High(FEntries) do
    FEntries[i].Free;
  FEntries := nil;
  FLock.Free;
  inherited Destroy;
end;

procedure TPWebSocketBridge.Wake;
begin
  if FKeeper <> nil then
    FKeeper.FWake.SetEvent;
end;

function TPWebSocketBridge.LiveCountLocked: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FEntries) do
    if (FEntries[i].State = pssOpening) or
       (FEntries[i].Transported and not FEntries[i].Released) then
      Inc(Result);
end;

function TPWebSocketBridge.FindLocked(const Id: RawUtf8): TPWebSocketEntry;
var
  i: Integer;
begin
  for i := 0 to High(FEntries) do
    if FEntries[i].Id = Id then
      exit(FEntries[i]);
  Result := nil;
end;

function TPWebSocketBridge.AcquireOwned(const Context: TInvocationContext;
  const Id: RawUtf8): TPWebSocketEntry;
begin
  FLock.Enter;
  try
    Result := FindLocked(Id);
    // ANOTHER PRINCIPAL'S SOCKET IS AN UNKNOWN SOCKET: same answer, same
    // path, so this door is not an oracle for ids it did not issue to you
    if (Result <> nil) and
       ((Result.PrincipalId <> Context.PrincipalId) or
        (Result.WindowId <> Context.WindowId) or
        Result.Gone or
        (Result.State = pssOpening) or
        ((Result.State = pssClosed) and Result.CloseTaken)) then
      Result := nil;
    if Result <> nil then
      Inc(Result.Refs);
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSocketBridge.Unref(E: TPWebSocketEntry);
begin
  FLock.Enter;
  try
    Dec(E.Refs);
  finally
    FLock.Leave;
  end;
  Wake;
end;

procedure TPWebSocketBridge.PushLocked(E: TPWebSocketEntry;
  const Ev: TPWebSocketEvent; AtHead: Boolean);
var
  i: Integer;
begin
  SetLength(E.Events, E.Count + 1);
  if AtHead then
  begin
    for i := E.Count downto 1 do
      E.Events[i] := E.Events[i - 1];
    E.Events[0] := Ev;
  end
  else
    E.Events[E.Count] := Ev;
  Inc(E.Count);
  if Ev.Kind in [sekText, sekBinary] then
    Inc(E.Bytes, Length(Ev.Data));
  E.Arrived.SetEvent;
end;

procedure TPWebSocketBridge.CloseNativeLocked(E: TPWebSocketEntry;
  const Category: RawUtf8; MakeGone: Boolean);
var
  kept: array of TPWebSocketEvent;
  i, discarded: Integer;
  ev: TPWebSocketEvent;
begin
  if MakeGone then
  begin
    E.Gone := True;
    E.CloseTaken := True;
  end;
  if E.State = pssClosed then
  begin
    if MakeGone then
    begin
      // nobody will ever read what is queued
      E.Events := nil;
      E.Count := 0;
      E.Bytes := 0;
    end;
    exit;
  end;
  // what the page has not polled is DISCARDED - a native close is not a live
  // socket under backpressure - and the count is TYPED on the close event
  discarded := 0;
  kept := nil;
  for i := 0 to E.Count - 1 do
    if E.Events[i].Kind in [sekText, sekBinary] then
      Inc(discarded)
    else if not MakeGone then
    begin
      SetLength(kept, Length(kept) + 1);
      kept[High(kept)] := E.Events[i];
    end;
  E.Events := kept;
  E.Count := Length(kept);
  E.Bytes := 0;
  if not MakeGone then
  begin
    ev := Default(TPWebSocketEvent);
    ev.Kind := sekClose;
    ev.Code := PWEB_SOCKET_NATIVE_CLOSE_CODE;
    ev.Category := Category;
    ev.WasClean := False;
    ev.Undelivered := discarded;
    PushLocked(E, ev);
  end;
  E.State := pssClosed;
  E.ClosedTix := GetTickCount64;
  if E.Transported then
  begin
    E.NeedRelease := True;
    E.SendCloseFrame := True;
    E.CloseFrameCode := PWEB_SOCKET_NATIVE_CLOSE_CODE;
  end;
  E.Arrived.SetEvent;
  Wake;
end;

// the close frame (when one is owed) and the release, under the handle's
// send lock so no Send can be using the handle while it goes away
procedure TPWebSocketBridge.ReleaseEntry(E: TPWebSocketEntry);
var
  doClose: Boolean;
  code: Integer;
begin
  E.SendLock.Enter;
  try
    FLock.Enter;
    try
      if E.Released or
         not E.Transported or
         not E.NeedRelease then
        exit;
      doClose := E.SendCloseFrame;
      code := E.CloseFrameCode;
    finally
      FLock.Leave;
    end;
    try
      if doClose then
        FTransport.Close(E.Handle, code, '');
    except
    end;
    try
      FTransport.Release(E.Handle);
    except
    end;
    FLock.Enter;
    try
      E.Released := True;
      E.NeedRelease := False;
    finally
      FLock.Leave;
    end;
  finally
    E.SendLock.Leave;
  end;
end;

procedure TPWebSocketBridge.Tick;
var
  work: array of TPWebSocketEntry;
  i, j: Integer;
  e: TPWebSocketEntry;
  now: Int64;
  ev: TPWebSocketEvent;
begin
  work := nil;
  now := GetTickCount64;
  FLock.Enter;
  try
    for i := 0 to High(FEntries) do
    begin
      e := FEntries[i];
      if (e.State = pssOpen) and
         not e.Receiving and
         (now - e.LastPollTix >= FBounds.IdleMs) then
        CloseNativeLocked(e, 'idle', False);
      if (e.State = pssClosing) and
         (now - e.ClosingTix >= FBounds.CloseWaitMs) then
      begin
        // the peer never echoed the page's close: the page is told so, and
        // the transport goes anyway
        ev := Default(TPWebSocketEvent);
        ev.Kind := sekClose;
        ev.Code := e.PageCode;
        ev.Category := 'page';
        PushLocked(e, ev);
        e.State := pssClosed;
        e.ClosedTix := now;
        e.NeedRelease := e.Transported;
      end;
      // a tombstone nobody reads expires with the idle bound
      if (e.State = pssClosed) and
         not e.CloseTaken and
         (now - e.ClosedTix >= FBounds.IdleMs) then
        e.CloseTaken := True;
      if e.NeedRelease and
         not e.Released then
      begin
        Inc(e.Refs);
        SetLength(work, Length(work) + 1);
        work[High(work)] := e;
      end;
    end;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(work) do
  begin
    ReleaseEntry(work[i]);
    FLock.Enter;
    Dec(work[i].Refs);
    FLock.Leave;
  end;
  // remove what is closed, released, read (or unreadable) and unused
  FLock.Enter;
  try
    i := 0;
    while i <= High(FEntries) do
    begin
      e := FEntries[i];
      if (e.State = pssClosed) and
         e.CloseTaken and
         (e.Refs = 0) and
         not e.NeedRelease and
         (e.Released or not e.Transported) then
      begin
        for j := i to High(FEntries) - 1 do
          FEntries[j] := FEntries[j + 1];
        SetLength(FEntries, Length(FEntries) - 1);
        e.Free;
      end
      else
        Inc(i);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPWebSocketBridge.Open(const Context: TInvocationContext;
  const Args: TPWebJson; const Token: ICancellationToken): TPWebInvocationResult;
var
  a: TSockArgs;
  request: TPWebSocketRequest;
  origin: TPWebFetchOrigin;
  scheme, target, selected, id: RawUtf8;
  tls, allowed, closedWhileOpening: Boolean;
  i: Integer;
  e: TPWebSocketEntry;
  sink: TPWebSocketSink;
  handle: Pointer;
  outcome: TPWebSocketOutcome;
  ev: TPWebSocketEvent;
begin
  if not DecodeArgs(Args, [sanUrl, sanProtocols, sanHeaders], a) then
    exit(Invalid('malformed, unknown or repeated argument'));
  if a[sanUrl].Kind <> sakString then
    exit(Invalid('url must be a string'));
  if not ParseSocketUrl(a[sanUrl].Text, origin, scheme, target, tls) then
    exit(Invalid('url is not an acceptable socket target'));
  // THE ALLOWLIST, by parsed components - and the refused origin does not
  // appear in the answer
  allowed := False;
  for i := 0 to High(FOrigins) do
    if PWebFetchSameOrigin(FOrigins[i], origin) then
    begin
      allowed := True;
      break;
    end;
  if not allowed then
    exit(Invalid('origin is not in the native allowlist'));
  request := Default(TPWebSocketRequest);
  case a[sanProtocols].Kind of
    sakAbsent:
      ;
    sakArray:
      if not ParseProtocols(a[sanProtocols].Text, request.Protocols) then
        exit(Invalid('protocols refused'));
  else
    exit(Invalid('protocols must be an array of strings'));
  end;
  case a[sanHeaders].Kind of
    sakAbsent:
      ;
    sakObject:
      if not BuildHeaderBlock(a[sanHeaders].Text, request.Headers) then
        exit(Invalid('header refused'));
  else
    // present but NOT an object: never an empty header set
    exit(Invalid('headers must be an object'));
  end;
  request.Url := a[sanUrl].Text;
  request.Scheme := scheme;
  request.Host := origin.Host;
  request.Port := origin.Port;
  request.Tls := tls;
  request.Target := target;
  request.ConnectDeadlineMs := FBounds.ConnectDeadlineMs;
  request.SendDeadlineMs := FBounds.SendDeadlineMs;
  request.MaxMessage := FBounds.MaxMessage;

  // --- a slot ---------------------------------------------------------------
  FLock.Enter;
  try
    if FDraining then
      exit(ServiceError(PWEB_SOCKET_CAT_CLOSED));
    if LiveCountLocked >= FBounds.MaxSockets then
      exit(ServiceError(PWEB_SOCKET_CAT_LIMIT,
        '"max":' + RawUtf8(IntToStr(FBounds.MaxSockets))));
    e := TPWebSocketEntry.Create(Self);
    e.Id := NewSocketId;
    e.PrincipalId := Context.PrincipalId;
    e.WindowId := Context.WindowId;
    UniqueString(e.PrincipalId);
    UniqueString(e.WindowId);
    e.State := pssOpening;
    e.Refs := 1;
    SetLength(FEntries, Length(FEntries) + 1);
    FEntries[High(FEntries)] := e;
  finally
    FLock.Leave;
  end;

  // --- the exchange ---------------------------------------------------------
  sink.Room := @e.RoomFor;
  sink.Deliver := @e.Deliver;
  sink.Closed := @e.TransportClosed;
  handle := nil;
  selected := '';
  if (Token <> nil) and
     Token.IsCancelled then
    outcome := psoCancelled
  else
    try
      outcome := FTransport.Open(request, sink, Token, handle, selected);
    except
      outcome := psoConnectFailed;
    end;

  closedWhileOpening := False;
  FLock.Enter;
  try
    if outcome = psoOk then
    begin
      e.Handle := handle;
      e.Transported := True;
      if e.State = pssClosed then
      begin
        // its document, its grant or its host went away while it opened
        closedWhileOpening := True;
        e.Gone := True;
        e.CloseTaken := True;
        e.NeedRelease := True;
        e.SendCloseFrame := True;
        e.CloseFrameCode := PWEB_SOCKET_NATIVE_CLOSE_CODE;
      end
      else
      begin
        e.State := pssOpen;
        e.Selected := selected;
        e.LastPollTix := GetTickCount64;
        ev := Default(TPWebSocketEvent);
        ev.Kind := sekOpen;
        ev.Reason := selected;
        // FIRST, even when the peer spoke before Open returned
        PushLocked(e, ev, True);
      end;
    end
    else
    begin
      e.State := pssClosed;
      e.CloseTaken := True;
      e.Gone := True;
    end;
    id := e.Id;
    Dec(e.Refs);
  finally
    FLock.Leave;
  end;
  Wake;

  case outcome of
    psoOk:
      if closedWhileOpening then
        Result := ServiceError(PWEB_SOCKET_CAT_CLOSED)
      else
        Result := PWebSuccessResult(TPWebJson('{"id":"' + id + '"}'));
    psoTlsFailed:
      Result := ServiceError(PWEB_SOCKET_CAT_TLS);
    psoHandshakeRedirect:
      Result := ServiceError(PWEB_SOCKET_CAT_HANDSHAKE, '"reason":"redirect"');
    psoHandshakeStatus:
      Result := ServiceError(PWEB_SOCKET_CAT_HANDSHAKE, '"reason":"status"');
    psoHandshakeUpgrade:
      Result := ServiceError(PWEB_SOCKET_CAT_HANDSHAKE, '"reason":"upgrade"');
    psoHandshakeSubprotocol:
      Result := ServiceError(PWEB_SOCKET_CAT_HANDSHAKE,
        '"reason":"subprotocol"');
    psoDeadline:
      Result := ServiceError(PWEB_SOCKET_CAT_DEADLINE);
    psoCancelled:
      Result := PWebDefaultErrorResult(pecCancelled);
  else
    Result := ServiceError(PWEB_SOCKET_CAT_CONNECT);
  end;
end;

function TPWebSocketBridge.Send(const Context: TInvocationContext;
  const Args: TPWebJson): TPWebInvocationResult;
var
  a: TSockArgs;
  payload: RawByteString;
  binary: Boolean;
  e: TPWebSocketEntry;
  outcome: TPWebSocketOutcome;
  ev: TPWebSocketEvent;
  usable: Boolean;
begin
  if not DecodeArgs(Args, [sanId, sanText, sanBase64], a) then
    exit(Invalid('malformed, unknown or repeated argument'));
  if a[sanId].Kind <> sakString then
    exit(Invalid('id must be a string'));
  if (a[sanText].Kind <> sakAbsent) = (a[sanBase64].Kind <> sakAbsent) then
    exit(Invalid('exactly one of text and base64'));
  if a[sanText].Kind <> sakAbsent then
  begin
    if a[sanText].Kind <> sakString then
      exit(Invalid('text must be a string'));
    payload := a[sanText].Text;
    binary := False;
  end
  else
  begin
    if a[sanBase64].Kind <> sakString then
      exit(Invalid('base64 must be a string'));
    payload := '';
    if (a[sanBase64].Text <> '') and
       not Base64ToBinSafe(pointer(a[sanBase64].Text),
         Length(a[sanBase64].Text), payload) then
      exit(Invalid('base64 is not valid base64'));
    binary := True;
  end;
  if Length(payload) > FBounds.MaxMessage then
    exit(Invalid('message is over the bound'));
  e := AcquireOwned(Context, a[sanId].Text);
  if e = nil then
    exit(ServiceError(PWEB_SOCKET_CAT_NOT_FOUND));
  try
    e.SendLock.Enter;
    try
      FLock.Enter;
      try
        usable := e.State = pssOpen;
      finally
        FLock.Leave;
      end;
      if not usable then
        exit(ServiceError(PWEB_SOCKET_CAT_CLOSED));
      try
        outcome := FTransport.Send(e.Handle, binary, payload);
      except
        outcome := psoSendFailed;
      end;
    finally
      e.SendLock.Leave;
    end;
    if outcome = psoOk then
      exit(PWebSuccessResult('{}'));
    // a send that failed ends the socket: a message half on the wire leaves
    // a connection no page can reason about
    FLock.Enter;
    try
      if e.State <> pssClosed then
      begin
        ev := Default(TPWebSocketEvent);
        ev.Kind := sekError;
        ev.Category := 'abnormal';
        PushLocked(e, ev);
        ev.Kind := sekClose;
        ev.Code := 1006;
        PushLocked(e, ev);
        e.State := pssClosed;
        e.ClosedTix := GetTickCount64;
        e.NeedRelease := e.Transported;
      end;
    finally
      FLock.Leave;
    end;
    if outcome = psoDeadline then
      Result := ServiceError(PWEB_SOCKET_CAT_DEADLINE)
    else
      Result := ServiceError(PWEB_SOCKET_CAT_SEND);
  finally
    Unref(e);
  end;
end;

function TPWebSocketBridge.Receive(const Context: TInvocationContext;
  const Args: TPWebJson; const Token: ICancellationToken): TPWebInvocationResult;
var
  a: TSockArgs;
  waitMs, i: Integer;
  e: TPWebSocketEntry;
  deadline, remaining: Int64;
  json: RawUtf8;
  took, closeTaken, busy, cancelled: Boolean;
begin
  if not DecodeArgs(Args, [sanId, sanWaitMs], a) then
    exit(Invalid('malformed, unknown or repeated argument'));
  if a[sanId].Kind <> sakString then
    exit(Invalid('id must be a string'));
  waitMs := 0;
  if a[sanWaitMs].Kind <> sakAbsent then
    // REFUSED, never clamped: a clamp is a request that quietly became
    // another request
    if not ArgInteger(a[sanWaitMs], waitMs) or
       (waitMs < 0) or
       (waitMs > FBounds.MaxWaitMs) then
      exit(Invalid('waitMs is outside the accepted range'));
  e := AcquireOwned(Context, a[sanId].Text);
  if e = nil then
    exit(ServiceError(PWEB_SOCKET_CAT_NOT_FOUND));
  try
    FLock.Enter;
    try
      busy := e.Receiving;
      if not busy then
      begin
        e.Receiving := True;
        e.LastPollTix := GetTickCount64;
      end;
    finally
      FLock.Leave;
    end;
    // ONE receive in flight per socket: a second one would pin a second
    // scheduler worker for nothing (cap15c-checkpoint1.md F-9)
    if busy then
      exit(PWebDefaultErrorResult(pecBusy));
    deadline := GetTickCount64 + waitMs;
    took := False;
    closeTaken := False;
    cancelled := False;
    json := '';
    repeat
      FLock.Enter;
      try
        if e.Count > 0 then
        begin
          for i := 0 to e.Count - 1 do
          begin
            if i > 0 then
              json := json + ',';
            json := json + EventJson(e.Events[i]);
            if e.Events[i].Kind = sekClose then
              closeTaken := True;
          end;
          e.Events := nil;
          e.Count := 0;
          e.Bytes := 0;
          if closeTaken then
            e.CloseTaken := True;
          took := True;
        end;
      finally
        FLock.Leave;
      end;
      if took then
        break;
      if (Token <> nil) and
         Token.IsCancelled then
      begin
        cancelled := True;
        break;
      end;
      remaining := deadline - GetTickCount64;
      if remaining <= 0 then
        break;
      if remaining > WAIT_SLICE_MS then
        remaining := WAIT_SLICE_MS;
      e.Arrived.WaitFor(remaining);
    until False;
    FLock.Enter;
    try
      e.Receiving := False;
      e.LastPollTix := GetTickCount64;
    finally
      FLock.Leave;
    end;
    // the page has its close event: the slot is freed before this returns,
    // so a page that reopens at once does not race the keeper
    if closeTaken then
      ReleaseEntry(e);
    if cancelled then
      exit(PWebDefaultErrorResult(pecCancelled));
    Result := PWebSuccessResult(TPWebJson('{"events":[' + json + ']}'));
  finally
    Unref(e);
  end;
end;

function TPWebSocketBridge.CloseSocket(const Context: TInvocationContext;
  const Args: TPWebJson): TPWebInvocationResult;
var
  a: TSockArgs;
  code: Integer;
  reason: RawUtf8;
  e: TPWebSocketEntry;
  doClose: Boolean;
begin
  if not DecodeArgs(Args, [sanId, sanCode, sanReason], a) then
    exit(Invalid('malformed, unknown or repeated argument'));
  if a[sanId].Kind <> sakString then
    exit(Invalid('id must be a string'));
  code := 1000;
  if a[sanCode].Kind <> sakAbsent then
    // what a page may send: 1000, or an application code (WHATWG close())
    if not ArgInteger(a[sanCode], code) or
       not ((code = 1000) or ((code >= 3000) and (code <= 4999))) then
      exit(Invalid('code must be 1000 or 3000-4999'));
  reason := '';
  case a[sanReason].Kind of
    sakAbsent:
      ;
    sakString:
      begin
        reason := a[sanReason].Text;
        if (Length(reason) > PWEB_SOCKET_MAX_REASON_BYTES) or
           not IsValidUtf8(reason) then
          exit(Invalid('reason is over 123 UTF-8 bytes'));
      end;
  else
    exit(Invalid('reason must be a string'));
  end;
  e := AcquireOwned(Context, a[sanId].Text);
  if e = nil then
    exit(ServiceError(PWEB_SOCKET_CAT_NOT_FOUND));
  try
    e.SendLock.Enter;
    try
      FLock.Enter;
      try
        doClose := e.State = pssOpen;
        if doClose then
        begin
          e.State := pssClosing;
          e.ClosingTix := GetTickCount64;
          e.PageCode := code;
        end;
      finally
        FLock.Leave;
      end;
      // IDEMPOTENT: a socket already closing or closed answers {} again
      if doClose then
        try
          FTransport.Close(e.Handle, code, reason);
        except
        end;
    finally
      e.SendLock.Leave;
    end;
    Result := PWebSuccessResult('{}');
  finally
    Unref(e);
  end;
end;

function TPWebSocketBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  // exact, case-sensitive matches on the canonical method
  if Method = PWEB_METHOD_SOCKET_RECEIVE then
    Result := Receive(Context, Args, Token)
  else if Method = PWEB_METHOD_SOCKET_SEND then
    Result := Send(Context, Args)
  else if Method = PWEB_METHOD_SOCKET_OPEN then
    Result := Open(Context, Args, Token)
  else if Method = PWEB_METHOD_SOCKET_CLOSE then
    Result := CloseSocket(Context, Args)
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

procedure TPWebSocketBridge.DocumentReplacing(const AWindowId: RawUtf8);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FEntries) do
      if FEntries[i].WindowId = AWindowId then
        CloseNativeLocked(FEntries[i], 'navigation', True);
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSocketBridge.BeforeDrain;
var
  i: Integer;
  snapshot: array of TPWebSocketEntry;
  deadline: Int64;
  opening: Boolean;
begin
  FLock.Enter;
  try
    FDraining := True;
    if (FPolicy <> nil) and
       (TMethod(FPolicy.OnGrantsChanged).Data = Pointer(Self)) then
      FPolicy.OnGrantsChanged := nil;
    FPolicy := nil;
    for i := 0 to High(FEntries) do
      CloseNativeLocked(FEntries[i], 'shutdown', True);
    snapshot := Copy(FEntries);
    for i := 0 to High(snapshot) do
      Inc(snapshot[i].Refs);
  finally
    FLock.Leave;
  end;
  // SYNCHRONOUS: every transport this door holds is released before the host
  // drains its scheduler, so the CAP-9 order is untouched and nothing a
  // socket owns can outlive the drain
  for i := 0 to High(snapshot) do
    ReleaseEntry(snapshot[i]);
  // an open still inside its transport sees the closed state when it
  // returns and releases itself; wait for it within a bound
  deadline := GetTickCount64 + FBounds.ConnectDeadlineMs;
  repeat
    opening := False;
    FLock.Enter;
    try
      for i := 0 to High(snapshot) do
        if snapshot[i].State = pssOpening then
          opening := True;
    finally
      FLock.Leave;
    end;
    if not opening then
      break;
    Sleep(WAIT_SLICE_MS);
  until GetTickCount64 > deadline;
  for i := 0 to High(snapshot) do
    ReleaseEntry(snapshot[i]);
  FLock.Enter;
  try
    for i := 0 to High(snapshot) do
      Dec(snapshot[i].Refs);
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSocketBridge.AttachPolicy(APolicy: TPWebCapabilityPolicy);
begin
  if APolicy = nil then
    raise EPWebSocket.Create('AttachPolicy requires a policy');
  if Assigned(APolicy.OnGrantsChanged) then
    raise EPWebSocket.Create('the policy already has a grants subscriber');
  FPolicy := APolicy;
  FPolicyRef := APolicy;
  APolicy.OnGrantsChanged := @GrantsChanged;
end;

procedure TPWebSocketBridge.GrantsChanged(const APrincipalId: Utf8String);
var
  windows: array of Utf8String;
  policy: TPWebCapabilityPolicy;
  i, j: Integer;
  known: Boolean;
  caps: TPWebCapabilities;
begin
  FLock.Enter;
  try
    policy := FPolicy;
    windows := nil;
    for i := 0 to High(FEntries) do
      if (FEntries[i].PrincipalId = APrincipalId) and
         (FEntries[i].State <> pssClosed) then
      begin
        known := False;
        for j := 0 to High(windows) do
          if windows[j] = FEntries[i].WindowId then
            known := True;
        if not known then
        begin
          SetLength(windows, Length(windows) + 1);
          windows[High(windows)] := FEntries[i].WindowId;
        end;
      end;
  finally
    FLock.Leave;
  end;
  if policy = nil then
    exit;
  for j := 0 to High(windows) do
  begin
    // the POLICY answers whether network.socket survived; this door only
    // acts on the answer
    caps := policy.SnapshotCapabilities(APrincipalId, windows[j]);
    if PWebCapabilityIn(caps, PWEB_CAP_NETWORK_SOCKET) then
      continue;
    FLock.Enter;
    try
      for i := 0 to High(FEntries) do
        if (FEntries[i].PrincipalId = APrincipalId) and
           (FEntries[i].WindowId = windows[j]) then
          CloseNativeLocked(FEntries[i], 'revoked', True);
    finally
      FLock.Leave;
    end;
  end;
end;

function TPWebSocketBridge.OpenCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for i := 0 to High(FEntries) do
      if FEntries[i].State <> pssClosed then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TPWebSocketBridge.QueuedEvents(const Id: RawUtf8): Integer;
var
  e: TPWebSocketEntry;
begin
  FLock.Enter;
  try
    e := FindLocked(Id);
    if e = nil then
      Result := 0
    else
      Result := e.Count;
  finally
    FLock.Leave;
  end;
end;

function TPWebSocketBridge.QueuedBytes(const Id: RawUtf8): PtrInt;
var
  e: TPWebSocketEntry;
begin
  FLock.Enter;
  try
    e := FindLocked(Id);
    if e = nil then
      Result := 0
    else
      Result := e.Bytes;
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSocketBridge.CloseForIdleNow(const Id: RawUtf8);
var
  e: TPWebSocketEntry;
begin
  FLock.Enter;
  try
    e := FindLocked(Id);
    if e <> nil then
      CloseNativeLocked(e, 'idle', False);
  finally
    FLock.Leave;
  end;
end;

end.
