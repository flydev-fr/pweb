{
  pweb.webview.binding - IWebViewBinding over the raw webview C ABI
  (Phase 2 / CAP-2).

  The WebView-flavoured invocation source. It owns, all internally per
  the frozen contracts (pweb.webview.intf.pas):
  - the exception-barriered webview_bind C callback whose only duties
    are: copy id/req immediately (valid only during the callback -
    docs/webview-upstream-semantics.md), validate size, capture a
    native immutable TInvocationContext snapshot, delegate to the
    registered IWebViewInvocationHandler which parses the envelope and
    enqueues non-blocking - plus the one ratified exception, the
    synchronous pre-queue rejection (invalid_request / busy /
    runtime_closed) delivered through the same per-invocation sink;
  - the per-invocation idempotent completion sink, which serializes the
    frozen error envelope from the frozen tables and calls
    webview_return DIRECTLY from the worker thread - thread-safe at the
    pinned commit, verified in docs/webview-upstream-semantics.md -
    never wrapped in webview_dispatch;
  - the handle-use lease covering ONLY each short native return call,
    never bridge or service execution; no new leases once close begins;
    once closed a late completion is swallowed silently without ever
    touching the native handle;
  - the bind/unbind userdata lifetime, strictly enclosed by the
    binding's own lifetime.

  Lifecycle delegates to the SINGLE scheduler-registered
  IInvocationSource this binding fronts, so binding state and source
  state cannot diverge. Close performs: source Quiesce (queued
  invocations complete cancelled while the sink can still deliver) ->
  JS-side unbind (the ratified GUI-thread teardown window during
  Quiescing) -> source Close (still-running in-flight invocations
  complete cancelled; their late worker results die at the
  exactly-once gate) -> lease shutter (no new leases; the native
  handle is out of reach). Actual native destruction stays the owning
  IWebView's deferred concern, after ActiveLeases has drained.

  Headless testability: the native bind/unbind/return entry points are
  injectable cdecl-compatible function pointers defaulting to the real
  raw ABI. An internal constructor detail - not a public contract
  change; production callers use PWebDefaultBindingOptions.

  This unit may use pinned mORMot2 core units (project include
  pattern); only src/lib must stay mORMot-free.
}
unit pweb.webview.binding;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.json,
  pweb.rpc.intf,
  pweb.rpc.scheduler,
  pweb.webview.intf,
  pweb.lib.webview,
  pweb.lib.webview.errors;

const
  { default transport request-size cap (the wire's configurable maximum
    with an absolute security ceiling - configured on the source
    implementation in v1, per the frozen TPWebSourceLimits note) }
  PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES = 1 shl 20;

type
  /// raised at Bind/Unbind/Create call sites on the GUI thread - never
  // across a C frame
  EPWebBindingError = class(Exception);

  /// injectable native entry points, signature-identical to the raw ABI
  TPWebNativeBindFn = function(w: webview_t; const name: PAnsiChar;
    fn: webview_bind_fn; arg: Pointer): webview_error_t; cdecl;
  TPWebNativeUnbindFn = function(w: webview_t;
    const name: PAnsiChar): webview_error_t; cdecl;
  TPWebNativeReturnFn = function(w: webview_t; const id: PAnsiChar;
    status: Integer; const result: PAnsiChar): webview_error_t; cdecl;

  /// construction options for TWebViewBinding
  // - ContextTemplate is the NATIVE trust anchor: every invocation's
  //   TInvocationContext is deep-copied from it at the binding; nothing
  //   in it ever comes from the JS payload (security-model.md)
  // - nil native function pointers default to the real raw ABI
  TPWebWebViewBindingOptions = record
    ContextTemplate: TInvocationContext;
    MaxRequestBytes: Integer;
    NativeBind: TPWebNativeBindFn;
    NativeUnbind: TPWebNativeUnbindFn;
    NativeReturn: TPWebNativeReturnFn;
  end;

  TWebViewBinding = class;

  { userdata behind webview_bind: owned by the binding, lifetime
    strictly enclosing the interval from Bind through Unbind/destroy
    (threading-model.md "Ownership at the C boundary"). Holds a plain
    object reference to its owner - the owner outlives every entry by
    construction. }
  TPWebBindEntry = class
  public
    Owner: TWebViewBinding;
    Handler: IWebViewInvocationHandler;
    Name: Utf8String;
  end;

  /// IWebViewBinding implementation over the raw pinned C ABI
  TWebViewBinding = class(TInterfacedObject, IWebViewBinding)
  private
    FHandle: webview_t;
    FSource: IInvocationSource;
    FContextTemplate: TInvocationContext;
    FMaxRequestBytes: Integer;
    FNativeBind: TPWebNativeBindFn;
    FNativeUnbind: TPWebNativeUnbindFn;
    FNativeReturn: TPWebNativeReturnFn;
    FLock: TCriticalSection;  // protects FEntries
    FEntries: TList;          // of TPWebBindEntry
    FLeaseCount: LongInt;
    FLeaseClosed: LongInt;    // nonzero once close began: no new leases
    function FindEntryLocked(const AName: Utf8String): Integer;
    procedure UnbindAllForClose;
  public
    constructor Create(AHandle: webview_t; const ASource: IInvocationSource;
      const AOptions: TPWebWebViewBindingOptions);
    destructor Destroy; override;
    // IWebViewBinding
    procedure Bind(const Name: Utf8String;
      const Handler: IWebViewInvocationHandler);
    procedure Unbind(const Name: Utf8String);
    procedure Quiesce;
    procedure Close;
    function State: TPWebSourceState;
    { --- internal surface for the owning IWebView, the C callback and
          the headless tests; not part of the frozen public contract --- }
    /// handle-use lease around each short native-handle operation only
    function TryAcquireLease: Boolean;
    procedure ReleaseLease;
    /// outstanding short leases; the owner defers native destruction
    // until this has drained to zero after Close
    function ActiveLeases: Integer;
    /// perform one webview_return under a handle-use lease; silently
    // swallowed once close has begun - the handle is never touched
    procedure NativeReturnUnderLease(const AId: RawUtf8; AStatus: Integer;
      const APayload: TPWebJson);
    /// callback-thread duties for one raw invocation (already copied
    // id/request); called from the exception-barriered C callback
    procedure HandleRawInvocation(const AHandler: IWebViewInvocationHandler;
      const AId: RawUtf8; const ARequest: TPWebJson);
  end;

  /// the standard envelope handler: parses the transport envelope far
  // enough to extract Method + Args, rejects malformed envelope JSON
  // pre-queue as invalid_request, enqueues non-blocking, and performs
  // the ratified synchronous pre-queue rejection on any non-accepted
  // TryEnqueue outcome - all on the callback thread, nothing blocking
  TPWebEnvelopeHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FSource: IInvocationSource;
  public
    constructor Create(const ASource: IInvocationSource);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

/// production options: real raw-ABI entry points, default size cap
function PWebDefaultBindingOptions(
  const AContextTemplate: TInvocationContext): TPWebWebViewBindingOptions;

/// serialize the frozen canonical error envelope
// {"code":..,"message":..,"status":..,"data":..} from the frozen tables
function PWebErrorEnvelopeJson(const AError: TPWebError): TPWebJson;

/// map a discriminated result onto the webview_return arms:
// Success -> status 0 + value (never the empty string: JSON null is
// PWEB_JSON_NULL); Error -> nonzero status + canonical error envelope
function PWebResultEnvelope(const AResult: TPWebInvocationResult;
  out AStatus: Integer): TPWebJson;

/// parse the transport invocation envelope ["Method", ArgsObjectOrNull]
// - strict JSON, exactly two elements, first a string, second an
//   object or null; Args is handed over exactly as extracted
function PWebParseInvocationEnvelope(const ARequest: TPWebJson;
  out AMethod: Utf8String; out AArgs: TPWebJson): Boolean;

implementation

{ ---------------- envelope helpers ---------------- }

function PWebDefaultBindingOptions(
  const AContextTemplate: TInvocationContext): TPWebWebViewBindingOptions;
begin
  Result := Default(TPWebWebViewBindingOptions);
  Result.ContextTemplate := AContextTemplate;
  Result.MaxRequestBytes := PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES;
  Result.NativeBind := webview_bind;
  Result.NativeUnbind := webview_unbind;
  Result.NativeReturn := webview_return;
end;

function PWebErrorEnvelopeJson(const AError: TPWebError): TPWebJson;
var
  msg, data: RawUtf8;
begin
  msg := RawUtf8(AError.Message);
  if msg = '' then
    msg := RawUtf8(PWEB_DEFAULT_ERROR_MESSAGE[AError.Code]);
  data := RawUtf8(AError.Data);
  if data = '' then
    data := PWEB_JSON_NULL; // JSON null is 'null', never the empty string
  Result := TPWebJson(FormatUtf8('{"code":"%","message":%,"status":%,"data":%}',
    [PWEB_ERROR_CODE_TEXT[AError.Code], QuotedStrJson(msg),
     PWEB_ERROR_STATUS[AError.Code], data]));
end;

function PWebResultEnvelope(const AResult: TPWebInvocationResult;
  out AStatus: Integer): TPWebJson;
begin
  if AResult.Kind = prkSuccess then
  begin
    AStatus := 0; // resolve arm
    if AResult.Value = '' then
      Result := PWEB_JSON_NULL // '' would surface as JS undefined upstream
    else
      Result := AResult.Value;
  end
  else
  begin
    AStatus := 1; // any nonzero status rejects the JS promise
    Result := PWebErrorEnvelopeJson(AResult.Error);
  end;
end;

function PWebParseInvocationEnvelope(const ARequest: TPWebJson;
  out AMethod: Utf8String; out AArgs: TPWebJson): Boolean;
var
  tmp, m: RawUtf8;
  raw: RawJson;
  info: TGetJsonField;
  P: PUtf8Char;
  eoo: AnsiChar;
begin
  Result := False;
  AMethod := '';
  AArgs := PWEB_JSON_NULL;
  if ARequest = '' then
    exit;
  if not IsValidJson(RawUtf8(ARequest), {strict=}True) then
    exit;
  // private copy: mORMot JSON field extraction decodes in place
  FastSetString(tmp, pointer(ARequest), Length(ARequest));
  P := GotoNextNotSpace(pointer(tmp));
  if P^ <> '[' then
    exit;
  Inc(P);
  info.Json := P;
  info.GetJsonField;
  if (info.Json = nil) or not info.WasString or (info.Value = nil) then
    exit; // first element must be the method string
  if info.EndOfObject <> ',' then
    exit; // exactly two elements are required
  FastSetString(m, info.Value, info.ValueLen);
  eoo := #0;
  GetJsonItemAsRawJson(info.Json, raw, @eoo);
  if (raw = '') or (eoo <> ']') then
    exit;
  // named arguments only in protocol v1: a JSON object, or null
  P := GotoNextNotSpace(pointer(raw));
  if P^ = '{' then
    AArgs := TPWebJson(raw) // handed over exactly as extracted
  else if raw = PWEB_JSON_NULL then
    AArgs := PWEB_JSON_NULL
  else
    exit;
  AMethod := Utf8String(m);
  Result := True;
end;

{ ---------------- per-invocation completion sink ---------------- }

type
  { the per-invocation idempotent completion sink: first Complete wins,
    later attempts are dropped silently; delivery is webview_return
    called directly from any thread (thread-safe at the pin), under a
    short handle-use lease }
  TPWebWebViewCompletion = class(TInterfacedObject, IInvocationCompletion)
  private
    FBinding: TWebViewBinding;
    FBindingRef: IWebViewBinding; // pins the binding while this sink lives
    FId: RawUtf8;
    FDone: LongInt;
  public
    constructor Create(ABinding: TWebViewBinding; const AId: RawUtf8);
    procedure Complete(const AResult: TPWebInvocationResult);
  end;

constructor TPWebWebViewCompletion.Create(ABinding: TWebViewBinding;
  const AId: RawUtf8);
begin
  inherited Create;
  FBinding := ABinding;
  FBindingRef := ABinding;
  FId := AId;
end;

procedure TPWebWebViewCompletion.Complete(const AResult: TPWebInvocationResult);
var
  status: Integer;
  payload: TPWebJson;
begin
  if InterlockedExchange(FDone, 1) <> 0 then
    exit; // exactly-once: a late attempt dies here, silently
  try
    payload := PWebResultEnvelope(AResult, status);
    FBinding.NativeReturnUnderLease(FId, status, payload);
  except
    // completion delivery must never raise into a worker or a callback
  end;
end;

{ ---------------- the C bind callback ---------------- }

{ Exception barrier: no Pascal exception may unwind through this C
  frame (threading-model.md "Ownership at the C boundary"). id/req are
  valid ONLY during the callback (measured at the pin) - they are
  copied first, before anything else can fail. }
procedure PWebBindingRawCallback(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  entry: TPWebBindEntry;
  idCopy: RawUtf8;
  reqCopy: RawUtf8;
begin
  if arg = nil then
    exit;
  entry := TPWebBindEntry(arg);
  idCopy := '';
  try
    if id <> nil then
      FastSetString(idCopy, id, StrLen(id));
    if req <> nil then
      FastSetString(reqCopy, req, StrLen(req))
    else
      reqCopy := '';
    entry.Owner.HandleRawInvocation(entry.Handler, idCopy, TPWebJson(reqCopy));
  except
    // map any failure to a safe terminal internal_error completion
    // where possible; never let anything cross the C frame
    try
      if idCopy <> '' then
        entry.Owner.NativeReturnUnderLease(idCopy, 1, PWebErrorEnvelopeJson(
          PWebDefaultErrorResult(pecInternalError).Error));
    except
      // swallow: the barrier is absolute
    end;
  end;
end;

{ ---------------- TWebViewBinding ---------------- }

constructor TWebViewBinding.Create(AHandle: webview_t;
  const ASource: IInvocationSource; const AOptions: TPWebWebViewBindingOptions);
begin
  inherited Create;
  if ASource = nil then
    raise EPWebBindingError.Create(
      'TWebViewBinding.Create: a scheduler-registered source is required');
  if not PWebValidContext(AOptions.ContextTemplate) then
    raise EPWebBindingError.Create(
      'TWebViewBinding.Create: context template violates identity invariants');
  FHandle := AHandle;
  FSource := ASource;
  FContextTemplate := PWebCopyContext(AOptions.ContextTemplate);
  FMaxRequestBytes := AOptions.MaxRequestBytes;
  if FMaxRequestBytes <= 0 then
    FMaxRequestBytes := PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES;
  FNativeBind := AOptions.NativeBind;
  if not Assigned(FNativeBind) then
    FNativeBind := webview_bind;
  FNativeUnbind := AOptions.NativeUnbind;
  if not Assigned(FNativeUnbind) then
    FNativeUnbind := webview_unbind;
  FNativeReturn := AOptions.NativeReturn;
  if not Assigned(FNativeReturn) then
    FNativeReturn := webview_return;
  FLock := TCriticalSection.Create;
  FEntries := TList.Create;
end;

destructor TWebViewBinding.Destroy;
begin
  if FSource <> nil then
    try
      Close; // safety net: normally the owner drove Close already
    except
    end;
  FEntries.Free;
  FLock.Free;
  inherited Destroy;
end;

function TWebViewBinding.FindEntryLocked(const AName: Utf8String): Integer;
var
  i: Integer;
begin
  for i := 0 to FEntries.Count - 1 do
    if TPWebBindEntry(FEntries[i]).Name = AName then
      exit(i);
  Result := -1;
end;

procedure TWebViewBinding.Bind(const Name: Utf8String;
  const Handler: IWebViewInvocationHandler);
var
  entry: TPWebBindEntry;
  err: webview_error_t;
begin
  // Name is the JS global binding name - an internal implementation
  // detail, NOT a PWeb RPC Service.Method (frozen contract note)
  if (Name = '') or (Pos(#0, Name) > 0) then
    raise EPWebBindingError.Create('Bind: invalid binding name');
  if Handler = nil then
    raise EPWebBindingError.Create('Bind: handler is required');
  if FSource.State <> pssRunning then
    raise EPWebBindingError.Create('Bind: refused outside pssRunning');
  FLock.Enter;
  try
    if FindEntryLocked(Name) >= 0 then
      raise EPWebBindingError.CreateFmt('Bind: "%s" is already bound',
        [string(Name)]);
    entry := TPWebBindEntry.Create;
    try
      entry.Owner := Self;
      entry.Handler := Handler;
      entry.Name := Name;
      err := FNativeBind(FHandle, PAnsiChar(pointer(entry.Name)),
        PWebBindingRawCallback, entry);
      if err = WEBVIEW_ERROR_DUPLICATE then
        raise EPWebBindingError.CreateFmt(
          'Bind: "%s" is already bound upstream', [string(Name)]);
      WebViewCheck(err, 'webview_bind');
      FEntries.Add(entry);
      entry := nil; // owned by FEntries now
    finally
      entry.Free; // only on the refusal paths above
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TWebViewBinding.Unbind(const Name: Utf8String);
var
  idx: Integer;
  entry: TPWebBindEntry;
begin
  if FSource.State = pssClosed then
    exit; // no-op once pssClosed per contract
  entry := nil;
  FLock.Enter;
  try
    idx := FindEntryLocked(Name);
    if idx < 0 then
      exit; // unknown Name is a no-op
    entry := TPWebBindEntry(FEntries[idx]);
    FEntries.Delete(idx);
  finally
    FLock.Leave;
  end;
  // best-effort native unbind: WEBVIEW_ERROR_NOT_FOUND is informational
  FNativeUnbind(FHandle, PAnsiChar(pointer(entry.Name)));
  entry.Free; // userdata lifetime ends with the binding entry
end;

procedure TWebViewBinding.UnbindAllForClose;
var
  entry: TPWebBindEntry;
begin
  repeat
    entry := nil;
    FLock.Enter;
    try
      if FEntries.Count > 0 then
      begin
        entry := TPWebBindEntry(FEntries[FEntries.Count - 1]);
        FEntries.Delete(FEntries.Count - 1);
      end;
    finally
      FLock.Leave;
    end;
    if entry = nil then
      break;
    FNativeUnbind(FHandle, PAnsiChar(pointer(entry.Name)));
    entry.Free;
  until False;
end;

procedure TWebViewBinding.Quiesce;
begin
  // delegate to the single underlying source: states cannot diverge
  FSource.Quiesce;
end;

procedure TWebViewBinding.Close;
begin
  // 1) full Quiesce semantics first (there is no Running -> Closed):
  //    refuse new invocations, complete queued ones as cancelled -
  //    those completions still deliver, the lease is still open
  FSource.Quiesce;
  // 2) the ratified teardown window: JS-side unbind on the GUI thread
  //    while the source is Quiescing, before destroy
  UnbindAllForClose;
  // 3) close the source: still-running in-flight invocations complete
  //    as cancelled (still deliverable), late worker results will die
  //    at the exactly-once gate
  FSource.Close;
  // 4) shutter the lease: from here no new leases are granted and the
  //    native handle is out of reach; the owning IWebView performs the
  //    actual destruction after ActiveLeases drains
  InterlockedExchange(FLeaseClosed, 1);
end;

function TWebViewBinding.State: TPWebSourceState;
begin
  Result := FSource.State; // the single underlying source state
end;

function TWebViewBinding.TryAcquireLease: Boolean;
begin
  Result := False;
  if FLeaseClosed <> 0 then
    exit; // no new leases once the close transition began
  InterlockedIncrement(FLeaseCount);
  if FLeaseClosed <> 0 then
  begin
    InterlockedDecrement(FLeaseCount); // close raced us: back out
    exit;
  end;
  Result := True;
end;

procedure TWebViewBinding.ReleaseLease;
begin
  InterlockedDecrement(FLeaseCount);
end;

function TWebViewBinding.ActiveLeases: Integer;
begin
  Result := FLeaseCount;
end;

procedure TWebViewBinding.NativeReturnUnderLease(const AId: RawUtf8;
  AStatus: Integer; const APayload: TPWebJson);
var
  payload: TPWebJson;
begin
  if AId = '' then
    exit;
  if not TryAcquireLease then
    exit; // closed: swallowed silently, the handle is never touched
  try
    payload := APayload;
    if payload = '' then
      payload := PWEB_JSON_NULL; // never hand '' (JS undefined) upstream
    // direct worker-side webview_return - never webview_dispatch'ed;
    // its error code is deliberately ignored: completion is best-effort
    // and must never raise into the pipeline
    FNativeReturn(FHandle, PAnsiChar(pointer(AId)), AStatus,
      PAnsiChar(pointer(payload)));
  finally
    ReleaseLease; // the lease covers only this short native operation
  end;
end;

procedure TWebViewBinding.HandleRawInvocation(
  const AHandler: IWebViewInvocationHandler; const AId: RawUtf8;
  const ARequest: TPWebJson);
var
  sink: IInvocationCompletion;
  ctx: TInvocationContext;
begin
  // one idempotent sink per invocation, correlation from the native id
  sink := TPWebWebViewCompletion.Create(Self, AId);
  // ratified callback duty: validate size (sync pre-queue rejection)
  if Length(ARequest) > FMaxRequestBytes then
  begin
    sink.Complete(PWebErrorResult(pecInvalidRequest, 'Request too large'));
    exit;
  end;
  // native immutable context snapshot - never from the JS payload
  ctx := PWebCopyContext(FContextTemplate);
  // envelope parsing + non-blocking enqueue are the handler's duties
  AHandler.HandleInvocation(ctx, ARequest, sink);
end;

{ ---------------- TPWebEnvelopeHandler ---------------- }

constructor TPWebEnvelopeHandler.Create(const ASource: IInvocationSource);
begin
  inherited Create;
  if ASource = nil then
    raise EPWebBindingError.Create(
      'TPWebEnvelopeHandler.Create: source is required');
  FSource := ASource;
end;

procedure TPWebEnvelopeHandler.HandleInvocation(
  const Context: TInvocationContext; const Request: TPWebJson;
  const Completion: IInvocationCompletion);
var
  method: Utf8String;
  args: TPWebJson;
  outcome: TPWebEnqueueResult;
begin
  // parsing split (frozen): malformed envelope JSON is rejected HERE,
  // pre-queue; method/args grammar is TryEnqueue's single shared gate
  if not PWebParseInvocationEnvelope(Request, method, args) then
  begin
    Completion.Complete(
      PWebErrorResult(pecInvalidRequest, 'Malformed invocation envelope'));
    exit;
  end;
  outcome := FSource.TryEnqueue(Context, method, args, Completion);
  if outcome <> perAccepted then
    // the one ratified exception: synchronous pre-queue rejection on
    // the callback thread, mapped by the frozen shared table
    Completion.Complete(PWebDefaultErrorResult(PWEB_ENQUEUE_ERROR[outcome]));
end;

end.
