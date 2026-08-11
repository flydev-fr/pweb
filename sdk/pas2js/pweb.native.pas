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
