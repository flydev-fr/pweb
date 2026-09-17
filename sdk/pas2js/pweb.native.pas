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

  Deliberately absent (as in the TypeScript SDK): event/window APIs and
  any frontend cancellation surface - protocol v1 has no backend
  contract behind them; cancellation originates native-side and surfaces
  here only as the cancelled error code.
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
  PWEB_SOCKET_RECEIVE_WAIT_MS = 25000;
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

    ONE receive loop per socket - `pweb.socketReceive` long-polls, one after
    another. That loop is the receive path, not a placeholder: CAP-12A
    measured WebView2 withholding a streamed body from the page until it is
    complete, and ratified a data plane Range-based, not streaming-based, so
    no streaming route exists to replace it. Each receive in flight holds one
    native scheduler worker for up to `waitMs`.

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
      ReceiveNext;
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

// THE RECEIVE LOOP - one bounded long-poll after another (see the class)
procedure TPWebSocket.ReceiveNext;
var
  args: TJSObject;
begin
  if FReadyState = PWEB_SOCKET_CLOSED then
    exit;
  args := TJSObject.new;
  args['id'] := FId;
  args['waitMs'] := PWEB_SOCKET_RECEIVE_WAIT_MS;
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
      ReceiveNext;
      Result := JS.Undefined;
    end,
    function(AReason: JSValue): JSValue
    begin
      Fail(ConvertReason(AReason));
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
      obj: TJSObject;
      protocolVal, runtimeVal, capsVal, item: JSValue;
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
      // resolve a validated projection (protocol/runtime/capabilities
      // only), mirroring the TS SDK - unknown members never reach callers
      if isUndefined(capsVal) then
        Result := New(['protocol', protocolVal, 'runtime', runtimeVal])
      else
        Result := New(['protocol', protocolVal, 'runtime', runtimeVal,
          'capabilities', capsVal]);
    end);
end;

end.
