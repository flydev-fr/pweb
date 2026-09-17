{
  pweb.native - the PWeb Pas2JS frontend SDK (CAP-5).

  A thin adapter over the SAME native invocation primitive the TypeScript
  SDK wraps (the CAP-2 binding's JS global). One wire, one binding, one
  scheduler, one capability path: this unit's responsibility ends at that
  primitive. No HTTP client, no fallback transport, no capability logic,
  no Pas2JS-specific payload - the wire request produced here is
  semantically identical to the TypeScript SDK's for the same logical
  call (proven by the captured-wire parity gate in CI).

  Asynchrony is the platform's: every entry point returns the underlying
  TJSPromise. Rejections are converted INSIDE the SDK to typed
  EPWebError instances, so `await` sites catch `on E: EPWebError` - the
  exact ergonomic mirror of TypeScript's PWebError. This is language
  ergonomics only; resolve/reject semantics on the wire are unchanged.

  Error mapping (identical to the TypeScript SDK):
  - a well-formed canonical envelope with a known protocol v1 `code`
    maps field-for-field; message/status fall back to the frozen
    defaults when absent or mistyped; `data` passes through as received
    (absent/undefined => null);
  - anything else (page-shim Error, unknown code, non-object) maps to a
    generic local internal_error WITHOUT copying content from the
    malformed reason - nothing unvalidated reaches the typed surface,
    and message text is never parsed to determine `code`;
  - an absent primitive rejects immediately with runtime_closed: no
    fallback transport, never a forever-pending promise.

  PWebOnSignal (CAP-16) is the one event surface, as in the TypeScript
  SDK, and it has a backend contract behind it: the native signal channel
  says that a topic moved, and the page reads through PWebInvoke. It
  carries no data and grants nothing; subscribing is itself an invocation
  under a capability.

  Deliberately absent (as in the TypeScript SDK): window APIs and any
  frontend cancellation surface - protocol v1 has no backend contract
  behind them; cancellation originates native-side and surfaces here only
  as the cancelled error code.
}
unit pweb.native;

{$mode objfpc}
{$modeswitch externalclass}

interface

uses
  SysUtils, JS;

const
  { Wire protocol version this SDK speaks. Mirrors the native
    PWEB_PROTOCOL_VERSION in src/rpc/pweb.rpc.intf.pas; CI cross-checks
    the constants so they can never drift silently. }
  PWEB_PROTOCOL_VERSION = 1;

  { Runtime-owned handshake method (reserved pweb.* namespace). }
  PWEB_METHOD_HANDSHAKE = 'pweb.handshake';

  { Runtime-owned outbound fetch method (CAP-15B), and the capability that
    authorizes it. The capability name is ADVISORY here exactly as the
    handshake's list is: authorization is native and per invocation, and
    this SDK never enforces, caches-then-trusts, or grants from a name. }
  PWEB_METHOD_FETCH = 'pweb.fetch';
  PWEB_CAP_NETWORK_FETCH = 'network.fetch';

  { The native socket door (CAP-15C): four runtime-owned methods and the one
    capability that authorizes them - advisory here, as above. The bounds are
    the native ones, cross-checked against src/rpc/pweb.rpc.socket.pas. }
  PWEB_METHOD_SOCKET_OPEN = 'pweb.socketOpen';
  PWEB_METHOD_SOCKET_SEND = 'pweb.socketSend';
  PWEB_METHOD_SOCKET_RECEIVE = 'pweb.socketReceive';
  PWEB_METHOD_SOCKET_CLOSE = 'pweb.socketClose';
  PWEB_CAP_NETWORK_SOCKET = 'network.socket';
  { the most a quiet socket waits between two receives (CAP-16) }
  PWEB_SOCKET_KEEPALIVE_MS = 20000;
  PWEB_SOCKET_MAX_MESSAGE = 1048576;
  PWEB_SOCKET_MAX_PROTOCOLS = 4;
  PWEB_SOCKET_MAX_REASON_BYTES = 123;

  { The blob data plane's READ surface (CAP-12B), and there is deliberately
    no method name here: reading a blob is not an invoke at all, it is an
    ordinary same-origin load of a URL the runtime handed out. What this
    SDK carries is the TYPE of that handle and nothing else: the CAP-5 bar
    is that no SDK source contains a browser network primitive, and the page
    already loads same-origin resources the way it loads its own assets.

    NOTHING HERE BUILDS A BLOB URL. `url` comes from the runtime, which is
    the only place in the product that knows both the store's spelling and
    the URL's, and an SDK that concatenated a prefix would be a second
    answer to a settled namespace question. The bound is the native one,
    cross-checked against src/assets/pweb.blobs.intf.pas. }
  PWEB_BLOB_TOKEN_CHARS = 32;

  { The native signal channel (CAP-16), the twin of `onSignal` in
    @pweb/runtime: two runtime-owned methods, the DOM event the runtime's
    one injected script dispatches on `window`, the handshake feature
    name, the socket door's topic, and the native bounds - cross-checked
    against src/rpc/pweb.rpc.signal.pas. }
  PWEB_METHOD_SIGNAL_SUBSCRIBE = 'pweb.signalSubscribe';
  PWEB_METHOD_SIGNAL_UNSUBSCRIBE = 'pweb.signalUnsubscribe';
  PWEB_SIGNAL_EVENT = 'pweb:signal';
  PWEB_SIGNAL_FEATURE = 'signal';
  PWEB_SIGNAL_TOPIC_SOCKET = 'pweb.socket';
  PWEB_SIGNAL_TICKS_PER_SECOND = 20;
  PWEB_SIGNAL_MAX_SUBSCRIPTIONS = 32;
  PWEB_SIGNAL_MAX_TOPIC_BYTES = 64;

  PWEB_SOCKET_CONNECTING = 0;
  PWEB_SOCKET_OPEN = 1;
  PWEB_SOCKET_CLOSING = 2;
  PWEB_SOCKET_CLOSED = 3;

  { JS global name of the native invocation primitive bound by the CAP-2
    binding (webview_bind). Internal transport detail - applications use
    PWebInvoke, never this global directly. }
  PWEB_NATIVE_BINDING_NAME = '__pweb_invoke';

type
  { Typed PWeb error. Code is the sole normative discriminator; Status is
    informative only - application logic switches on Code. Data carries
    service_error's structured domain payload (or busy retry metadata)
    exactly as received; JS null otherwise. }
  EPWebError = class(Exception)
  private
    FCode: String;
    FStatus: NativeInt;
    FData: JSValue;
  public
    constructor CreateEnvelope(const ACode, AMessage: String;
      AStatus: NativeInt; AData: JSValue);
    property Code: String read FCode;
    property Status: NativeInt read FStatus;
    property Data: JSValue read FData;
  end;

  { The pweb.handshake response, typed over the raw payload object.
    Capabilities is ADVISORY UI metadata only: authorization stays
    native-side and is evaluated per invocation - the SDK never enforces,
    caches-then-trusts, or grants from it. }
  TPWebRuntimeInfo = class external name 'Object' (TJSObject)
  public
    Protocol: NativeInt; external name 'protocol';
    Runtime: String; external name 'runtime';
    Capabilities: TJSArray; external name 'capabilities'; // may be undefined
    { CAP-16: additive runtime features, e.g. 'signal'; may be undefined }
    Features: TJSArray; external name 'features';
  end;

  { Called with the topic's new sequence number. }
  TPWebSignalCallback = reference to procedure(ASeq: NativeInt;
    const ATopic: String);

  { One callback on one topic (CAP-16), the twin of @pweb/runtime's
    PWebSignalSubscription.

    Ready resolves with the topic's sequence once the native subscription
    exists, and rejects with EPWebError (forbidden, invalid_request,
    service_error with category signal_limit, ...). Off removes the
    callback; the native subscription goes with the last callback of its
    topic. Off is idempotent.

    THE RECOVERY PATTERN is the TypeScript SDK's: subscribe, await Ready,
    then read everything ONCE through PWebInvoke, and on every callback
    read again since your own cursor. A signal lost before the
    subscription, across a navigation or a development reload costs
    latency, never correctness. }
  TPWebSignalSubscription = class
  private
    FTopic: String;
    FReady: TJSPromise;
    FCallback: TPWebSignalCallback;
    FOwner: TObject;
    FActive: Boolean;
  public
    procedure Off;
    property Topic: String read FTopic;
    property Ready: TJSPromise read FReady;
  end;

  { One blob the runtime is holding for THIS principal (CAP-12B), typed
    over the raw handle object a fetch envelope carries in `blob`.

    - Token is 32 lowercase hexadecimal characters - exactly 128 bits. It
      is an identifier, never an authorization: the runtime checks the
      owner too, and a token belonging to another principal is answered
      exactly as an unknown one is.
    - Url is where the bytes are, built by the RUNTIME. Use it; never
      derive it.
    - Size is the whole length in bytes.
    - ContentType is what the blob was sealed with, served verbatim and
      never derived from a path extension.

    LIFETIME IS THE RUNTIME'S. A blob dies with the document that owns it -
    a navigation, a reload, a development generation switch - and with the
    capability that governs it, and at shutdown. A handle kept across a
    navigation resolves to nothing, which is a 404 and not something this
    SDK can prevent. }
  TPWebBlobHandle = class external name 'Object' (TJSObject)
  public
    Token: String; external name 'token';
    Url: String; external name 'url';
    Size: NativeInt; external name 'size';
    ContentType: String; external name 'type';
  end;

  TPWebSocket = class;

  { AInfo carries the event's fields as the TypeScript SDK names them:
    `protocol` for open; `code`, `category` for error; `code`, `reason`,
    `wasClean`, `category`, `undelivered` for close. }
  TPWebSocketNotify = reference to procedure(Sender: TPWebSocket;
    AInfo: TJSObject);
  { AData is a String for a text message, a TJSArrayBuffer for a binary one }
  TPWebSocketMessage = reference to procedure(Sender: TPWebSocket;
    AData: JSValue);

  { The native socket door (CAP-15C), the twin of `PWebSocket` in
    @pweb/runtime. The page opens no socket: the runtime does, under the
    `network.socket` capability and the origin allowlist compiled into the
    host.

    ONE receive loop per socket - signal, then receive (CAP-16).
    `pweb.socketReceive` answers at once and never waits; the loop receives
    when the window's `pweb.socket` topic moves, or every
    PWEB_SOCKET_KEEPALIVE_MS, so a quiet socket holds no native worker and
    no invocation slot at all. CAP-15C's parked long-poll did, and four of
    them starved the page. Streaming was never the way out: CAP-12A
    measured WebView2 withholding a streamed body from the page until it is
    complete, and ratified a data plane Range-based, not streaming-based.
    This class, its events and the four method names are unaffected.

    It constructs no URL, supplies no default origin, adds no header, retries
    nothing and reconnects nothing. Send on a socket that is not open raises
    EPWebError invalid_request rather than dropping the message. }
  TPWebSocket = class
  private
    FUrl: String;
    FId: String;
    FReadyState: NativeInt;
    FProtocol: String;
    FSendChain: TJSPromise;
    FCloseWanted: Boolean;
    FCloseCode: NativeInt;
    FCloseReason: String;
    FSubscription: TPWebSignalSubscription;
    FWaiting: Boolean;
    FTimer: JSValue;
    procedure StartLoop;
    procedure WaitSignal;
    procedure Wake;
    procedure StopSignal;
    procedure ReceiveNext;
    procedure DispatchEvent(AEvent: TJSObject);
    procedure Fail(AError: EPWebError);
    procedure RequestClose(ACode: NativeInt; const AReason: String);
  public
    OnOpen: TPWebSocketNotify;
    OnMessage: TPWebSocketMessage;
    OnError: TPWebSocketNotify;
    OnClose: TPWebSocketNotify;
    { AOptions may carry `protocols` (an array of at most four tokens) and
      `headers` (the fetch door's request-header allowlist); both pass
      through byte-exact }
    constructor Create(const AUrl: String; AOptions: TJSObject = nil);
    procedure Send(const AText: String);
    procedure SendBinary(ABuffer: TJSArrayBuffer);
    { 1000, or an application code 3000-4999. Idempotent. }
    procedure Close(ACode: NativeInt = 1000; const AReason: String = '');
    property Url: String read FUrl;
    property ReadyState: NativeInt read FReadyState;
    property Protocol: String read FProtocol;
  end;

{ True when the PWeb native binding is present in this JS context.
  Detection only - never a capability statement. }
function PWebIsRuntime: Boolean;

{ Invoke a PWeb method through the native binding.
  - AMethod passes through byte-exact (Service.Method, case-sensitive;
    the backend is authoritative - the SDK never canonicalizes).
  - AArgs is a named-argument object, or nil (sent as JSON null). Keys
    pass through exactly as supplied.
  - Resolves with whatever JSON value the service produced - object,
    array, string, number, boolean or null. A success value that looks
    like an error envelope is still a success.
  - Rejects with EPWebError; when the binding is absent it rejects
    immediately with code runtime_closed. }
function PWebInvoke(const AMethod: String; AArgs: TJSObject): TJSPromise;

{ One bounded outbound request through the native door (CAP-15B).

  ARequest is a plain object carrying `url` and, optionally, `method`,
  `headers`, `body` and `timeoutMs`. It is passed through BYTE-EXACT: this
  function constructs no URL, supplies no default origin, adds no header,
  follows no redirect, keeps no cookie and retries nothing. Every one of
  those is a NATIVE decision taken under the `network.fetch` capability and
  a per-application origin allowlist compiled into the host, and an SDK that
  supplied one would be a second answer to a settled question.

  Resolves with the response envelope: status, ms, bytes, truncated (always
  False in protocol v1), an allowlisted `headers` object from which
  `set-cookie` is ALWAYS absent, and exactly one of bodyText / bodyBase64.
  Rejects with EPWebError - `forbidden` with zero network activity when the
  application does not hold the capability, `invalid_request` for anything
  the request contract refuses, `cancelled` when the deadline expires, and
  `service_error` with a category in Data for a transport failure or a
  response over a bound. }
function PWebFetch(ARequest: TJSObject): TJSPromise;

{ Perform the runtime handshake and verify protocol compatibility.
  Resolves with TPWebRuntimeInfo when the reported protocol is supported;
  rejects with EPWebError protocol_mismatch when the protocol is
  unsupported OR the payload is not a well-formed handshake response.
  Applications gate startup on this and must not continue against an
  incompatible runtime. }
function PWebHandshake: TJSPromise;

{ Call ACallback whenever ATopic moves (CAP-16). The first callback of a
  topic subscribes natively through pweb.signalSubscribe; the result's
  Ready settles when that answer arrives. A pair whose sequence is not
  newer than the last one seen for its topic is ignored, whatever order
  the engine delivered it in. An empty topic or a nil callback raises
  EPWebError invalid_request locally. }
function PWebOnSignal(const ATopic: String;
  ACallback: TPWebSignalCallback): TPWebSignalSubscription;

{ Remove ACallback from ATopic; nothing happens when it is not there. }
procedure PWebOffSignal(const ATopic: String; ACallback: TPWebSignalCallback);

{ The last sequence this page saw for ATopic, or -1 when it is not
  subscribed. The start of "read everything since N". }
function PWebLastSeq(const ATopic: String): NativeInt;

implementation

const
  { The nine frozen protocol v1 codes - deliberately no unauthorized. }
  KNOWN_CODES: array[0..8] of String = (
    'invalid_request', 'method_not_found', 'forbidden', 'busy',
    'cancelled', 'service_error', 'internal_error', 'runtime_closed',
    'protocol_mismatch');

  { Informative status per code, frozen with protocol v1. Fallback for a
    missing/mistyped envelope status - never a discriminator. }
  KNOWN_STATUS: array[0..8] of NativeInt = (
    400, 404, 403, 429, 499, 422, 500, 503, 426);

  DEFAULT_MESSAGE: array[0..8] of String = (
    'Invalid request', 'Method not found', 'Invocation is not allowed',
    'Runtime is busy', 'Invocation was cancelled', 'Service error',
    'Internal error', 'Runtime is closed', 'Protocol mismatch');

constructor EPWebError.CreateEnvelope(const ACode, AMessage: String;
  AStatus: NativeInt; AData: JSValue);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FStatus := AStatus;
  FData := AData;
end;

function GlobalObject: TJSObject; assembler;
asm
  return globalThis;
end;

function CodeIndex(const ACode: String): NativeInt;
var
  i: NativeInt;
begin
  for i := Low(KNOWN_CODES) to High(KNOWN_CODES) do
    if KNOWN_CODES[i] = ACode then
      exit(i);
  Result := -1;
end;

{ Build a typed error; AHasStatus mirrors TypeScript's rule exactly - the
  envelope status counts as present iff it is an integer (negatives
  included); anything else falls back to the frozen per-code table. }
function MakeErrorEx(const ACode: String; const AMessage: String;
  AHasStatus: Boolean; AStatus: NativeInt; AData: JSValue): EPWebError;
var
  idx: NativeInt;
  msg: String;
  status: NativeInt;
begin
  idx := CodeIndex(ACode);
  msg := AMessage;
  status := AStatus;
  if idx >= 0 then
  begin
    if msg = '' then
      msg := DEFAULT_MESSAGE[idx];
    if not AHasStatus then
      status := KNOWN_STATUS[idx];
  end;
  Result := EPWebError.CreateEnvelope(ACode, msg, status, AData);
end;

function MakeError(const ACode: String; const AMessage: String;
  AData: JSValue): EPWebError;
begin
  Result := MakeErrorEx(ACode, AMessage, False, 0, AData);
end;

function InternalError: EPWebError;
begin
  Result := MakeError('internal_error', '', JS.Null);
end;

{ Map a native rejection reason onto EPWebError - the exact mirror of the
  TypeScript SDK's toPWebError, including the typed-error passthrough. }
function ConvertReason(AReason: JSValue): EPWebError;
var
  obj: TJSObject;
  codeVal, msgVal, statusVal, dataVal: JSValue;
  msg: String;
  statusInt: NativeInt;
begin
  if isObject(AReason) and not isArray(AReason) then
  begin
    if TObject(AReason) is EPWebError then
      exit(EPWebError(TObject(AReason))); // already typed: pass through
    obj := TJSObject(AReason);
    codeVal := obj['code'];
    if isString(codeVal) and (CodeIndex(String(codeVal)) >= 0) then
    begin
      msgVal := obj['message'];
      if isString(msgVal) then
        msg := String(msgVal)
      else
        msg := '';
      statusVal := obj['status'];
      if isInteger(statusVal) then
        statusInt := NativeInt(statusVal)
      else
        statusInt := 0; // ignored when AHasStatus is False
      dataVal := obj['data'];
      if isUndefined(dataVal) then
        dataVal := JS.Null;
      exit(MakeErrorEx(String(codeVal), msg, isInteger(statusVal),
        statusInt, dataVal));
    end;
  end;
  Result := InternalError;
end;

function PWebIsRuntime: Boolean;
var
  g: TJSObject;
begin
  g := GlobalObject;
  Result := isFunction(g[PWEB_NATIVE_BINDING_NAME]);
end;

function PWebInvoke(const AMethod: String; AArgs: TJSObject): TJSPromise;
var
  g: TJSObject;
  fn: JSValue;
  wireArgs: JSValue;
  raw: JSValue;
begin
  if AMethod = '' then
    exit(TJSPromise.reject(MakeError('invalid_request',
      'Method must be a non-empty string', JS.Null)));
  if AArgs = nil then
    wireArgs := JS.Null
  else if isArray(JSValue(AArgs)) or not isObject(JSValue(AArgs)) then
    // a hostile/casted non-object (array, primitive) is rejected locally,
    // exactly as the TypeScript SDK rejects it - named arguments only
    exit(TJSPromise.reject(MakeError('invalid_request',
      'Arguments must be a named-argument object or null', JS.Null)))
  else
    wireArgs := JSValue(AArgs);
  g := GlobalObject;
  fn := g[PWEB_NATIVE_BINDING_NAME];
  if not isFunction(fn) then
    exit(TJSPromise.reject(MakeError('runtime_closed',
      'PWeb native binding is not available', JS.Null)));
  try
    raw := TJSFunction(fn).apply(g, [AMethod, wireArgs]);
  except
    exit(TJSPromise.reject(InternalError));
  end;
  Result := TJSPromise.resolve(raw)._then(
    function(AValue: JSValue): JSValue
    begin
      // a conforming runtime never resolves undefined (JSON null is the
      // literal null); normalize defensively, mirroring the TS SDK
      if isUndefined(AValue) then
        Result := JS.Null
      else
        Result := AValue;
    end).catch(
    function(AReason: JSValue): JSValue
    begin
      raise ConvertReason(AReason);
      Result := JS.Undefined; // unreachable - the raise rejects
    end);
end;

function PWebFetch(ARequest: TJSObject): TJSPromise;
begin
  if ARequest = nil then
    Result := TJSPromise.reject(MakeError('invalid_request',
      'A fetch request object is required', JS.Null))
  else
    // ONE invoke of the runtime-owned method, and nothing else. The object
    // crosses byte-exact: an absent option stays absent, because the native
    // door refuses an argument of the wrong type and sending an explicit
    // undefined would be sending one
    Result := PWebInvoke(PWEB_METHOD_FETCH, ARequest);
end;

{ ---------------- the signal channel (CAP-16) ---------------- }

type
  { one topic: its callbacks, the last sequence seen (-1 before any) and
    the native subscription's answer }
  TPWebTopicState = class
  public
    Callbacks: TJSArray;
    Last: NativeInt;
    Ready: TJSPromise;
  end;

  TPWebSignalHandler = reference to procedure(AEvent: JSValue);
  TPWebTimerHandler = reference to procedure;

var
  // a Map and not an object: a topic may be spelled like a property every
  // object inherits, and a Map has none
  SignalTopics: TJSMap = nil;
  SignalListening: Boolean = False;

function AddGlobalListener(const AType: String; AHandler: JSValue): Boolean; assembler;
asm
  if (typeof globalThis.addEventListener !== 'function') return false;
  globalThis.addEventListener(AType, AHandler);
  return true;
end;

function IsSafeSeq(AValue: JSValue): Boolean; assembler;
asm
  return (typeof AValue === 'number') && Number.isSafeInteger(AValue) &&
    (AValue >= 0);
end;

function StartTimer(AHandler: JSValue; AMs: NativeInt): JSValue; assembler;
asm
  return setTimeout(AHandler, AMs);
end;

procedure StopTimer(AHandle: JSValue); assembler;
asm
  if (AHandle !== undefined) clearTimeout(AHandle);
end;

function TopicState(const ATopic: String): TPWebTopicState;
begin
  if (SignalTopics <> nil) and SignalTopics.has(ATopic) then
    Result := TPWebTopicState(SignalTopics.get(ATopic))
  else
    Result := nil;
end;

procedure DeliverSignal(const ATopic: String; ASeq: NativeInt);
var
  state: TPWebTopicState;
  list: TJSArray;
  i: NativeInt;
  callback: TPWebSignalCallback;
begin
  state := TopicState(ATopic);
  if state = nil then
    exit;
  // THE SEQUENCE IS WHAT IS TRUSTED: an old or repeated one says nothing new
  if (state.Last >= 0) and (ASeq <= state.Last) then
    exit;
  state.Last := ASeq;
  list := state.Callbacks.slice(0);
  for i := 0 to list.length - 1 do
  begin
    callback := TPWebSignalCallback(list[i]);
    try
      callback(ASeq, ATopic);
    except
      // one callback never stops the others
    end;
  end;
end;

procedure ReceiveSignal(AEvent: JSValue);
var
  detail: JSValue;
  list, pair: TJSArray;
  i: NativeInt;
begin
  if not isObject(AEvent) then
    exit;
  detail := TJSObject(AEvent)['detail'];
  if not isArray(detail) then
    exit;
  list := TJSArray(detail);
  for i := 0 to list.length - 1 do
  begin
    if not isArray(list[i]) then
      continue;
    pair := TJSArray(list[i]);
    if (pair.length <> 2) or
       not isString(pair[0]) or
       not IsSafeSeq(pair[1]) then
      continue;
    DeliverSignal(String(pair[0]), NativeInt(pair[1]));
  end;
end;

procedure ListenSignals;
var
  handler: TPWebSignalHandler;
begin
  if SignalListening then
    exit;
  handler := @ReceiveSignal;
  if AddGlobalListener(PWEB_SIGNAL_EVENT, JSValue(handler)) then
    SignalListening := True;
end;

procedure ReleaseSignal(const ATopic: String; AOwner: TPWebTopicState;
  ACallback: TPWebSignalCallback);
var
  idx: NativeInt;
  args: TJSObject;
begin
  idx := AOwner.Callbacks.indexOf(JSValue(ACallback));
  if idx >= 0 then
    AOwner.Callbacks.splice(idx, 1);
  if (AOwner.Callbacks.length > 0) or (TopicState(ATopic) <> AOwner) then
    exit;
  SignalTopics.delete(ATopic);
  // the native subscription goes with the last callback; a refusal here
  // changes nothing the page relies on
  args := TJSObject.new;
  args['topic'] := ATopic;
  PWebInvoke(PWEB_METHOD_SIGNAL_UNSUBSCRIBE, args).catch(
    function(AReason: JSValue): JSValue
    begin
      Result := JS.Undefined;
    end);
end;

procedure TPWebSignalSubscription.Off;
begin
  if not FActive then
    exit;
  FActive := False;
  ReleaseSignal(FTopic, TPWebTopicState(FOwner), FCallback);
end;

function PWebOnSignal(const ATopic: String;
  ACallback: TPWebSignalCallback): TPWebSignalSubscription;
var
  state, fresh: TPWebTopicState;
  args: TJSObject;
begin
  if ATopic = '' then
    raise MakeError('invalid_request',
      'A signal topic must be a non-empty string', JS.Null);
  if not Assigned(ACallback) then
    raise MakeError('invalid_request',
      'A signal callback must be a function', JS.Null);
  ListenSignals;
  if SignalTopics = nil then
    SignalTopics := TJSMap.new;
  state := TopicState(ATopic);
  if state = nil then
  begin
    fresh := TPWebTopicState.Create;
    fresh.Callbacks := TJSArray.new;
    fresh.Last := -1;
    args := TJSObject.new;
    args['topic'] := ATopic;
    fresh.Ready := PWebInvoke(PWEB_METHOD_SIGNAL_SUBSCRIBE, args)._then(
      function(AValue: JSValue): JSValue
      var
        seq: JSValue;
      begin
        seq := JS.Undefined;
        if isObject(AValue) and not isArray(AValue) then
          seq := TJSObject(AValue)['seq'];
        if not IsSafeSeq(seq) then
          raise MakeError('internal_error',
            'A subscription answer carried no sequence', JS.Null);
        if (TopicState(ATopic) = fresh) and
           ((fresh.Last < 0) or (NativeInt(seq) > fresh.Last)) then
          fresh.Last := NativeInt(seq);
        Result := seq;
      end,
      function(AReason: JSValue): JSValue
      begin
        if TopicState(ATopic) = fresh then
          SignalTopics.delete(ATopic);
        raise ConvertReason(AReason);
        Result := JS.Undefined; // unreachable - the raise rejects
      end);
    // observed here so a page that never waits on Ready leaves no unhandled
    // rejection behind; waiting on it still rejects
    fresh.Ready.catch(
      function(AReason: JSValue): JSValue
      begin
        Result := JS.Undefined;
      end);
    SignalTopics.&set(ATopic, fresh);
    state := fresh;
  end;
  if state.Callbacks.indexOf(JSValue(ACallback)) < 0 then
    state.Callbacks.push(JSValue(ACallback));
  Result := TPWebSignalSubscription.Create;
  Result.FTopic := ATopic;
  Result.FReady := state.Ready;
  Result.FCallback := ACallback;
  Result.FOwner := state;
  Result.FActive := True;
end;

procedure PWebOffSignal(const ATopic: String; ACallback: TPWebSignalCallback);
var
  state: TPWebTopicState;
begin
  state := TopicState(ATopic);
  if (state = nil) or
     (state.Callbacks.indexOf(JSValue(ACallback)) < 0) then
    exit;
  ReleaseSignal(ATopic, state, ACallback);
end;

function PWebLastSeq(const ATopic: String): NativeInt;
var
  state: TPWebTopicState;
begin
  state := TopicState(ATopic);
  if state = nil then
    Result := -1
  else
    Result := state.Last;
end;

{ ---------------- TPWebSocket ---------------- }

function SocketBufferToBase64(ABuffer: TJSArrayBuffer): String; assembler;
asm
  var bytes = new Uint8Array(ABuffer);
  var binary = '';
  for (var i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
end;

function SocketBase64ToBuffer(const AText: String): TJSArrayBuffer; assembler;
asm
  var binary = atob(AText);
  var bytes = new Uint8Array(binary.length);
  for (var i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
end;

constructor TPWebSocket.Create(const AUrl: String; AOptions: TJSObject);
var
  args: TJSObject;
begin
  inherited Create;
  FUrl := AUrl;
  FReadyState := PWEB_SOCKET_CONNECTING;
  FSendChain := TJSPromise.resolve(JS.Undefined);
  // an ABSENT option stays absent: the native door refuses an argument of
  // the wrong type, and an explicit undefined would be sending one
  args := TJSObject.new;
  args['url'] := AUrl;
  if AOptions <> nil then
  begin
    if not isUndefined(AOptions['protocols']) then
      args['protocols'] := AOptions['protocols'];
    if not isUndefined(AOptions['headers']) then
      args['headers'] := AOptions['headers'];
  end;
  PWebInvoke(PWEB_METHOD_SOCKET_OPEN, args)._then(
    function(AValue: JSValue): JSValue
    begin
      FId := String(TJSObject(AValue)['id']);
      StartLoop;
      if FCloseWanted then
      begin
        FCloseWanted := False;
        RequestClose(FCloseCode, FCloseReason);
      end;
      Result := JS.Undefined;
    end,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
      Result := JS.Undefined;
    end);
end;

// THE RECEIVE LOOP - signal, then receive (see the class)
procedure TPWebSocket.StartLoop;
begin
  FSubscription := PWebOnSignal(PWEB_SIGNAL_TOPIC_SOCKET,
    procedure(ASeq: NativeInt; const ATopic: String)
    begin
      Wake;
    end);
  FSubscription.Ready._then(
    function(AValue: JSValue): JSValue
    begin
      ReceiveNext;
      Result := JS.Undefined;
    end,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
      StopSignal;
      Result := JS.Undefined;
    end);
end;

// wait for the next `pweb.socket` signal, or for the keepalive
procedure TPWebSocket.WaitSignal;
var
  handler: TPWebTimerHandler;
begin
  FWaiting := True;
  handler := procedure
    begin
      FTimer := JS.Undefined;
      if FWaiting then
      begin
        FWaiting := False;
        ReceiveNext;
      end;
    end;
  FTimer := StartTimer(JSValue(handler), PWEB_SOCKET_KEEPALIVE_MS);
end;

procedure TPWebSocket.Wake;
begin
  if not FWaiting then
    exit;
  FWaiting := False;
  StopTimer(FTimer);
  FTimer := JS.Undefined;
  ReceiveNext;
end;

procedure TPWebSocket.StopSignal;
var
  subscription: TPWebSignalSubscription;
begin
  FWaiting := False;
  StopTimer(FTimer);
  FTimer := JS.Undefined;
  subscription := FSubscription;
  FSubscription := nil;
  if subscription <> nil then
    subscription.Off;
end;

procedure TPWebSocket.ReceiveNext;
var
  args: TJSObject;
  covered: NativeInt;
begin
  if FReadyState = PWEB_SOCKET_CLOSED then
  begin
    StopSignal;
    exit;
  end;
  // the sequence this receive covers, read BEFORE it starts: anything that
  // moves while it is in flight is received again at once
  covered := PWebLastSeq(PWEB_SIGNAL_TOPIC_SOCKET);
  args := TJSObject.new;
  args['id'] := FId;
  PWebInvoke(PWEB_METHOD_SOCKET_RECEIVE, args)._then(
    function(AValue: JSValue): JSValue
    var
      events: JSValue;
      list: TJSArray;
      i: NativeInt;
    begin
      events := TJSObject(AValue)['events'];
      if isArray(events) then
      begin
        list := TJSArray(events);
        for i := 0 to list.length - 1 do
          DispatchEvent(TJSObject(list[i]));
      end;
      if FReadyState = PWEB_SOCKET_CLOSED then
        StopSignal
      else if PWebLastSeq(PWEB_SIGNAL_TOPIC_SOCKET) > covered then
        ReceiveNext
      else
        WaitSignal;
      Result := JS.Undefined;
    end,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
      StopSignal;
      Result := JS.Undefined;
    end);
end;

procedure TPWebSocket.DispatchEvent(AEvent: TJSObject);
var
  kind: String;
begin
  kind := String(AEvent['type']);
  if kind = 'open' then
  begin
    if FReadyState = PWEB_SOCKET_CONNECTING then
      FReadyState := PWEB_SOCKET_OPEN;
    if isString(AEvent['protocol']) then
      FProtocol := String(AEvent['protocol']);
    if Assigned(OnOpen) then
      OnOpen(Self, new(['protocol', FProtocol]));
  end
  else if kind = 'message' then
  begin
    if Assigned(OnMessage) then
      if isString(AEvent['base64']) then
        OnMessage(Self, SocketBase64ToBuffer(String(AEvent['base64'])))
      else
        OnMessage(Self, AEvent['text']);
  end
  else if kind = 'error' then
  begin
    if Assigned(OnError) then
      OnError(Self, new(['code', 'service_error', 'category', AEvent['category']]));
  end
  else if kind = 'close' then
  begin
    FReadyState := PWEB_SOCKET_CLOSED;
    if Assigned(OnClose) then
      OnClose(Self, AEvent);
  end;
end;

procedure TPWebSocket.Fail(AError: EPWebError);
var
  category: JSValue;
begin
  if FReadyState = PWEB_SOCKET_CLOSED then
    exit;
  FReadyState := PWEB_SOCKET_CLOSED;
  category := JS.Null;
  if isObject(AError.Data) and
     isString(TJSObject(AError.Data)['category']) then
    category := TJSObject(AError.Data)['category'];
  if Assigned(OnError) then
    OnError(Self, new(['code', AError.Code, 'category', category]));
  if Assigned(OnClose) then
    OnClose(Self, new(['code', 1006, 'reason', '', 'wasClean', False,
      'category', 'failed', 'undelivered', 0]));
  // a loop waiting for its next signal stops now, not at the keepalive
  if FWaiting then
    StopSignal;
end;

procedure TPWebSocket.Send(const AText: String);
var
  args: TJSObject;
begin
  if FReadyState <> PWEB_SOCKET_OPEN then
    raise MakeError('invalid_request', 'The socket is not open', JS.Null);
  args := TJSObject.new;
  args['id'] := FId;
  args['text'] := AText;
  // ONE send in flight at a time, so messages leave in the order given
  FSendChain := FSendChain._then(
    function(AValue: JSValue): JSValue
    begin
      Result := PWebInvoke(PWEB_METHOD_SOCKET_SEND, args);
    end)._then(nil,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
      Result := JS.Undefined;
    end);
end;

procedure TPWebSocket.SendBinary(ABuffer: TJSArrayBuffer);
var
  args: TJSObject;
begin
  if FReadyState <> PWEB_SOCKET_OPEN then
    raise MakeError('invalid_request', 'The socket is not open', JS.Null);
  args := TJSObject.new;
  args['id'] := FId;
  args['base64'] := SocketBufferToBase64(ABuffer);
  FSendChain := FSendChain._then(
    function(AValue: JSValue): JSValue
    begin
      Result := PWebInvoke(PWEB_METHOD_SOCKET_SEND, args);
    end)._then(nil,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
      Result := JS.Undefined;
    end);
end;

procedure TPWebSocket.RequestClose(ACode: NativeInt; const AReason: String);
var
  args: TJSObject;
begin
  args := TJSObject.new;
  args['id'] := FId;
  args['code'] := ACode;
  if AReason <> '' then
    args['reason'] := AReason;
  FReadyState := PWEB_SOCKET_CLOSING;
  PWebInvoke(PWEB_METHOD_SOCKET_CLOSE, args)._then(nil,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
      Result := JS.Undefined;
    end);
end;

procedure TPWebSocket.Close(ACode: NativeInt; const AReason: String);
begin
  if (FReadyState = PWEB_SOCKET_CLOSING) or
     (FReadyState = PWEB_SOCKET_CLOSED) then
    exit;
  if FId = '' then
  begin
    FCloseWanted := True;
    FCloseCode := ACode;
    FCloseReason := AReason;
    FReadyState := PWEB_SOCKET_CLOSING;
    exit;
  end;
  RequestClose(ACode, AReason);
end;

function Mismatch(const ADetail: String): EPWebError;
begin
  Result := MakeError('protocol_mismatch',
    'PWeb protocol mismatch: ' + ADetail, JS.Null);
end;

function PWebHandshake: TJSPromise;
begin
  Result := PWebInvoke(PWEB_METHOD_HANDSHAKE, nil)._then(
    function(AValue: JSValue): JSValue
    var
      obj, projection: TJSObject;
      protocolVal, runtimeVal, capsVal, featVal, item: JSValue;
      i: NativeInt;
    begin
      if not isObject(AValue) or isArray(AValue) then
        raise Mismatch('handshake response is not an object');
      obj := TJSObject(AValue);
      protocolVal := obj['protocol'];
      if not isInteger(protocolVal) then
        raise Mismatch('handshake response carries no integer protocol');
      // set membership, never an ordering comparison; {1} today
      if NativeInt(protocolVal) <> PWEB_PROTOCOL_VERSION then
        raise Mismatch('runtime protocol ' +
          String(TJSObject(protocolVal).toString) +
          ' is not supported by this SDK (supported: 1)');
      runtimeVal := obj['runtime'];
      if not isString(runtimeVal) or (String(runtimeVal) = '') then
        raise Mismatch('handshake response carries no runtime version');
      capsVal := obj['capabilities'];
      if not isUndefined(capsVal) then
      begin
        if not isArray(capsVal) then
          raise Mismatch('handshake capabilities member is malformed');
        for i := 0 to TJSArray(capsVal).length - 1 do
        begin
          item := TJSArray(capsVal)[i];
          if not isString(item) then
            raise Mismatch('handshake capabilities member is malformed');
        end;
      end;
      // CAP-16: an ADDITIVE member - a runtime with the signal channel lists
      // 'signal', an older one omits it; protocol v1 either way
      featVal := obj['features'];
      if not isUndefined(featVal) then
      begin
        if not isArray(featVal) then
          raise Mismatch('handshake features member is malformed');
        for i := 0 to TJSArray(featVal).length - 1 do
          if not isString(TJSArray(featVal)[i]) then
            raise Mismatch('handshake features member is malformed');
      end;
      // resolve a validated projection (protocol/runtime/capabilities/
      // features only), mirroring the TS SDK - unknown members never reach
      // callers
      projection := New(['protocol', protocolVal, 'runtime', runtimeVal]);
      if not isUndefined(capsVal) then
        projection['capabilities'] := capsVal;
      if not isUndefined(featVal) then
        projection['features'] := featVal;
      Result := projection;
    end);
end;

end.
