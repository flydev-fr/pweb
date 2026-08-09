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
    binding's own lifetime. OWNERSHIP INVARIANT (corrective pass):
    once native C can possibly hold an entry pointer, some Pascal
    owner holds it until the detach is CONFIRMED (webview_unbind
    returned WEBVIEW_ERROR_OK or WEBVIEW_ERROR_NOT_FOUND) or the
    native view is destroyed. The registry acquires the entry BEFORE
    the native bind (rolled back if the native bind fails); a failed
    native unbind keeps the entry tracked and fails the Pascal call at
    the GUI boundary, retryably - there is NO path from a C arg to a
    freed TPWebBindEntry.

  Lifecycle delegates to the SINGLE scheduler-registered
  IInvocationSource this binding fronts, so binding state and source
  state cannot diverge. Close performs: source Quiesce (queued
  invocations complete cancelled while the sink can still deliver) ->
  JS-side unbind (the ratified GUI-thread teardown window during
  Quiescing) -> source Close (still-running in-flight invocations
  complete cancelled; their late worker results die at the
  exactly-once gate) -> lease shutter (no new leases; the native
  handle is out of reach). If ANY JS-side unbind fails to confirm
  detach, Close stops there: the source stays Quiescing, the lease
  stays open, the failure is raised at the (GUI-affine) call site,
  and a later Close retries only the remaining entries - Closed is
  never reported past a failed unbind. Actual native destruction
  stays the owning IWebView's deferred concern, after ActiveLeases
  has drained.

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
  pweb.rpc.support, // neutral helpers - no concrete-scheduler coupling
  pweb.webview.intf,
  pweb.lib.webview,
  pweb.lib.webview.errors;

const
  { default transport request-size cap (the wire's configurable maximum
    with an absolute security ceiling - configured on the source
    implementation in v1, per the frozen TPWebSourceLimits note) }
  PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES = 1 shl 20;

  { IMPLEMENTATION-ONLY hard safety ceiling for the request size:
    16 MiB. NOT a protocol-v1 wire constant - purely a defensive
    implementation limit of this binding. The effective limit is
    min(configured MaxRequestBytes, this ceiling); configuration can
    never bypass it. It bounds the C-string length scan performed on
    attacker-controlled request bytes in the raw callback, so no
    unbounded StrLen ever runs there. }
  PWEB_BINDING_HARD_MAX_REQUEST_BYTES = 16 shl 20;

  { IMPLEMENTATION-ONLY cap on the native correlation id length: 4 KiB.
    At the pinned upstream the bind id is parsed from the JSON message
    the PAGE posts to the internal bridge, so a hostile page influences
    it - the id gets the same bounded-scan discipline as the request.
    Real upstream ids are tiny sequence numbers; an id over this cap
    (or absent/empty) carries no usable correlation and the invocation
    is dropped inertly - nothing could ever be delivered for it. }
  PWEB_BINDING_MAX_ID_BYTES = 4096;

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
    strictly enclosing the interval from Bind through CONFIRMED
    native detach (threading-model.md "Ownership at the C boundary").
    Holds a plain object reference to its owner - the owner outlives
    every entry it still tracks by construction. An entry whose native
    detach could not be confirmed by the time the binding dies is
    QUARANTINED instead of freed (Owner set to nil, entry leaked for
    the process lifetime - the documented leak-by-choice): the raw
    callback treats a nil Owner as inert, so even a callback firing on
    a quarantined entry is memory-safe. }
  TPWebBindEntry = class
  public
    Owner: TWebViewBinding; // nil once quarantined - checked by the callback
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
    { the GUI-affine thread (the creating thread by convention): every
      ownership argument in this unit rests on Bind/Unbind/Close being
      called there, so debug builds ($C+/-Sa) assert it - a single
      off-thread call silently voids every proof. No release cost:
      Assert compiles to nothing with assertions off. }
    FAffinityThread: TThreadID;
    function FindEntryLocked(const AName: Utf8String): Integer;
    { native unbind with detach confirmation: True ONLY for
      WEBVIEW_ERROR_OK / WEBVIEW_ERROR_NOT_FOUND (the two confirmed-
      detached results); any other code means native C may still hold
      the entry pointer, so the caller must NOT free it }
    function TryNativeDetach(AEntry: TPWebBindEntry;
      out AErr: webview_error_t): Boolean;
    { detach every tracked entry without popping; entries whose detach
      is confirmed are removed+freed, failed ones stay tracked for a
      retry. True when no entry remains. }
    function UnbindAllForClose: Boolean;
    { last-resort ownership transfer for entries the destructor could
      not confirm-detach: Owner nil'ed (callback becomes inert),
      Handler released, entry moved to the process-lifetime quarantine
      list - deliberately leaked rather than ever freed under a live C
      reference }
    procedure QuarantineRemainingEntries;
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
    /// the request-size limit actually enforced:
    // min(configured MaxRequestBytes, PWEB_BINDING_HARD_MAX_REQUEST_BYTES)
    function EffectiveMaxRequestBytes: Integer;
    /// perform one webview_return under a handle-use lease; silently
    // swallowed once close has begun - the handle is never touched
    procedure NativeReturnUnderLease(const AId: RawUtf8; AStatus: Integer;
      const APayload: TPWebJson);
    /// callback-thread duties for one raw invocation (id/request were
    // already copied and the per-invocation sink already exists);
    // called from the exception-barriered C callback - once the sink
    // exists, any failure completes THROUGH it (idempotent), never via
    // a direct native return that could double-deliver the same id
    procedure HandleRawInvocation(const AHandler: IWebViewInvocationHandler;
      const ARequest: TPWebJson; const ACompletion: IInvocationCompletion);
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

/// bounded C-string length scan for attacker-controlled request bytes:
// scans at most AMaxScan bytes; returns the length when a NUL was
// found within the bound, -1 when not (i.e. the string is LONGER than
// AMaxScan - 1 bytes: with AMaxScan = limit + 1 that means oversize),
// and 0 for nil. Never reads past AMaxScan bytes. A degenerate
// AMaxScan <= 0 also reports -1: nothing can be proven NUL-terminated
// within an empty bound, so a zero bound never misreports validity.
function PWebBoundedStrLen(P: PAnsiChar; AMaxScan: PtrInt): PtrInt;

/// number of quarantined (leaked-by-choice) bind entries alive in this
// process - internal diagnostics/test surface, not a frozen contract
function PWebQuarantinedEntryCount: Integer;

implementation

{ ---------------- bounded scan + entry quarantine ---------------- }

function PWebBoundedStrLen(P: PAnsiChar; AMaxScan: PtrInt): PtrInt;
var
  i: PtrInt;
begin
  if P = nil then
    exit(0);
  if AMaxScan <= 0 then
    exit(-1); // empty bound: nothing provable, report as over-bound
  i := 0;
  while (i < AMaxScan) and (P[i] <> #0) do
    Inc(i);
  if i >= AMaxScan then
    Result := -1 // no NUL within the bound: longer than AMaxScan-1 bytes
  else
    Result := i;
end;

var
  { process-lifetime quarantine of bind entries whose native detach was
    never confirmed while their binding died: retaining them (Owner nil,
    callback inert) is a deliberate, documented leak-by-choice - freeing
    memory that native C may still pass back as callback userdata would
    be a use-after-free }
  QuarantineLock: TCriticalSection;
  QuarantinedEntries: TList; // of TPWebBindEntry - NEVER freed

procedure QuarantineEntry(AEntry: TPWebBindEntry);
begin
  AEntry.Owner := nil;   // the raw callback treats nil Owner as inert
  AEntry.Handler := nil; // do not pin the pipeline from a leaked entry
  if QuarantineLock = nil then
    exit; // unit already finalized: the entry still leaks, inert, safely
  QuarantineLock.Enter;
  try
    QuarantinedEntries.Add(AEntry);
  finally
    QuarantineLock.Leave;
  end;
end;

function PWebQuarantinedEntryCount: Integer;
begin
  if QuarantineLock = nil then
    exit(0);
  QuarantineLock.Enter;
  try
    Result := QuarantinedEntries.Count;
  finally
    QuarantineLock.Leave;
  end;
end;

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
var
  err: TPWebError;
begin
  if AResult.Kind = prkSuccess then
  begin
    if AResult.Value = '' then
    begin
      AStatus := 0;
      Result := PWEB_JSON_NULL; // '' would surface as JS undefined upstream
      exit;
    end;
    // defensive: a bridge that produced unparseable JSON is an internal
    // failure - never hand garbage to the page
    if IsValidJson(RawUtf8(AResult.Value), {strict=}True) then
    begin
      AStatus := 0; // resolve arm
      Result := AResult.Value;
      exit;
    end;
    AStatus := 1;
    Result := PWebErrorEnvelopeJson(
      PWebDefaultErrorResult(pecInternalError).Error);
  end
  else
  begin
    AStatus := 1; // any nonzero status rejects the JS promise
    err := AResult.Error;
    // defensive: invalid Data would corrupt the whole envelope; coerce
    // to JSON null rather than shipping unparseable JSON
    if (err.Data <> '') and (err.Data <> PWEB_JSON_NULL) and
       not IsValidJson(RawUtf8(err.Data), {strict=}True) then
      err.Data := PWEB_JSON_NULL;
    Result := PWebErrorEnvelopeJson(err);
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
  copied first, before anything else can fail.

  Exactly-once discipline of the barrier: as soon as the per-invocation
  sink exists, EVERY failure is mapped through sink.Complete - its
  idempotent gate guarantees the native id can never receive a second
  return (e.g. when something raises after a synchronous pre-queue
  rejection already delivered). The direct native-return fallback runs
  ONLY when no sink could have existed for that id, i.e. no delivery
  can possibly have happened yet. }
procedure PWebBindingRawCallback(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  entry: TPWebBindEntry;
  owner: TWebViewBinding;
  handler: IWebViewInvocationHandler;
  idCopy: RawUtf8;
  reqCopy: RawUtf8;
  sink: IInvocationCompletion;
  limit: Integer;
  idLen, reqLen: PtrInt;
begin
  if arg = nil then
    exit;
  entry := TPWebBindEntry(arg);
  // capture BOTH fields into locals: quarantine nils them, and a
  // quarantined entry (detach never confirmed) must be inert here
  owner := entry.Owner;
  handler := entry.Handler;
  if (owner = nil) or (handler = nil) then
    exit; // inert, memory-safe
  idCopy := '';
  sink := nil;
  try
    // the id is copied FIRST, for correlation - but with the SAME
    // bounded-scan discipline as the request: at the pinned upstream
    // the id is parsed from the JSON message the page posts to the
    // internal bridge, so a hostile page influences it. Absent, empty
    // or over-cap ids carry no usable correlation: nothing enqueued
    // for them could ever deliver, so they are dropped inertly.
    idLen := PWebBoundedStrLen(id, PWEB_BINDING_MAX_ID_BYTES + 1);
    if idLen <= 0 then
      exit; // nil/empty (0) or over the id cap (-1): no correlation
    FastSetString(idCopy, id, idLen);
    sink := TPWebWebViewCompletion.Create(owner, idCopy);
    // request size is determined with a BOUNDED scan and oversize is
    // rejected BEFORE any full copy/allocation of the request: never an
    // unbounded StrLen over attacker-controlled bytes (the ratified
    // "validate size" callback duty, hardened)
    limit := owner.EffectiveMaxRequestBytes;
    if req = nil then
      reqLen := 0
    else
      reqLen := PWebBoundedStrLen(req, PtrInt(limit) + 1);
    if (reqLen < 0) or (reqLen > limit) then
    begin
      // ratified synchronous pre-queue rejection: never enqueued
      sink.Complete(PWebErrorResult(pecInvalidRequest, 'Request too large'));
      exit;
    end;
    if reqLen > 0 then
      FastSetString(reqCopy, req, reqLen)
    else
      reqCopy := '';
    owner.HandleRawInvocation(handler, TPWebJson(reqCopy), sink);
  except
    try
      if sink <> nil then
        // idempotent: dropped if a completion was already delivered
        sink.Complete(PWebDefaultErrorResult(pecInternalError))
      else if idCopy <> '' then
        // sink construction itself failed: no delivery can have
        // happened for this id, a direct return is safe and unique
        owner.NativeReturnUnderLease(idCopy, 1, PWebErrorEnvelopeJson(
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
  if FMaxRequestBytes > PWEB_BINDING_HARD_MAX_REQUEST_BYTES then
    // the implementation safety ceiling: configuration cannot bypass it
    FMaxRequestBytes := PWEB_BINDING_HARD_MAX_REQUEST_BYTES;
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
  FAffinityThread := GetCurrentThreadId; // see the field comment
end;

destructor TWebViewBinding.Destroy;
var
  i: Integer;
begin
  if FSource <> nil then
  begin
    try
      Close; // safety net: normally the owner drove Close already
    except
      // Close failed (typically an unconfirmed native unbind): fall
      // through to the quarantine below - a native-unbind failure must
      // never become dangling userdata just because this Pascal object
      // is released
    end;
    // any entry still tracked here has NO confirmed detach: quarantine
    // it (leak-by-choice) instead of freeing memory native C may still
    // hand back as callback userdata
    QuarantineRemainingEntries;
    // the binding object disappears: close the source (idempotent) and
    // shutter the lease so nothing can reach the handle through the
    // dying binding - this is the last-resort path, not a claim that
    // teardown succeeded
    try
      FSource.Close;
    except
    end;
    InterlockedExchange(FLeaseClosed, 1);
  end
  else if FEntries <> nil then
    // construction never completed: no native bind can have happened,
    // entries (if any) are safe to free normally
    for i := 0 to FEntries.Count - 1 do
      TPWebBindEntry(FEntries[i]).Free;
  FEntries.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TWebViewBinding.QuarantineRemainingEntries;
var
  remaining: array of TPWebBindEntry;
  i: Integer;
begin
  FLock.Enter;
  try
    SetLength(remaining, FEntries.Count);
    for i := 0 to FEntries.Count - 1 do
      remaining[i] := TPWebBindEntry(FEntries[i]);
    FEntries.Clear;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(remaining) do
    QuarantineEntry(remaining[i]);
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
  Assert(GetCurrentThreadId = FAffinityThread,
    'Bind called off the GUI-affine thread'); // debug builds only
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
    // re-check the state INSIDE the lock shared with the close path:
    // UnbindAllForClose runs after the source left pssRunning, so no
    // entry can be added behind an already-drained close
    if FSource.State <> pssRunning then
      raise EPWebBindingError.Create('Bind: refused outside pssRunning');
    if FindEntryLocked(Name) >= 0 then
      raise EPWebBindingError.CreateFmt('Bind: "%s" is already bound',
        [string(Name)]);
    entry := TPWebBindEntry.Create;
    try
      entry.Owner := Self;
      entry.Handler := Handler;
      entry.Name := Name;
      // OWNERSHIP ORDER (corrective invariant): the registry acquires
      // the entry BEFORE the native bind. If the bookkeeping fails the
      // native side has never seen the pointer and the free below is
      // trivially safe; if the native bind fails we roll the registry
      // back - never an unchecked native cleanup call, and never a
      // window where C holds an unowned pointer.
      FEntries.Add(entry);
      try
        err := FNativeBind(FHandle, PAnsiChar(pointer(entry.Name)),
          PWebBindingRawCallback, entry);
      except
        // an injected native-bind implementation may raise (fakes):
        // unregister BEFORE the exception propagates, so the finally
        // below never frees an entry that is still tracked
        FEntries.Remove(entry);
        raise;
      end;
      if err <> WEBVIEW_ERROR_OK then
      begin
        // ANY non-OK result is a refusal - including POSITIVE
        // informational codes: native did not register the callback,
        // so a tracked entry would be a phantom. At the pinned commit
        // a refused webview_bind retains no callback/userdata, so
        // rolling back the registry and freeing the entry is safe -
        // no userdata visible to native code is ever freed.
        FEntries.Remove(entry);
        if err = WEBVIEW_ERROR_DUPLICATE then
          raise EPWebBindingError.CreateFmt(
            'Bind: "%s" is already bound upstream', [string(Name)]);
        WebViewCheck(err, 'webview_bind'); // raises EWebViewError on < 0
        raise EPWebBindingError.CreateFmt(
          'Bind: "%s" refused by native bind (%s)',
          [string(Name), WebViewErrorName(err)]);
      end;
      entry := nil; // bound and registry-owned: nothing left to free
    finally
      entry.Free; // only on the refusal/rollback paths above
    end;
  finally
    FLock.Leave;
  end;
end;

{ Detach one entry natively and CONFIRM the detach. True only for
  WEBVIEW_ERROR_OK and WEBVIEW_ERROR_NOT_FOUND - the two results that
  guarantee native C no longer holds the entry pointer; any other code
  means the callback may still fire with this userdata, so the entry
  must stay alive and tracked. Free-after-confirm is safe because of
  the frozen GUI-affinity convention: the bind callback, Bind, Unbind
  and Close all run on the GUI thread, so no callback can be executing
  inside AEntry while the caller frees it. }
function TWebViewBinding.TryNativeDetach(AEntry: TPWebBindEntry;
  out AErr: webview_error_t): Boolean;
begin
  AErr := FNativeUnbind(FHandle, PAnsiChar(pointer(AEntry.Name)));
  Result := (AErr = WEBVIEW_ERROR_OK) or (AErr = WEBVIEW_ERROR_NOT_FOUND);
end;

procedure TWebViewBinding.Unbind(const Name: Utf8String);
var
  idx: Integer;
  entry: TPWebBindEntry;
  err: webview_error_t;
begin
  Assert(GetCurrentThreadId = FAffinityThread,
    'Unbind called off the GUI-affine thread'); // debug builds only
  if FSource.State = pssClosed then
    exit; // no-op once pssClosed per contract
  FLock.Enter;
  try
    idx := FindEntryLocked(Name);
    if idx < 0 then
      exit; // unknown Name is a no-op
    entry := TPWebBindEntry(FEntries[idx]);
  finally
    FLock.Leave;
  end;
  // GUI-thread by frozen convention (see TryNativeDetach). The entry
  // is NOT removed from the registry until the detach is confirmed:
  // a failed native unbind leaves it tracked and fully functional, the
  // failure is raised here at the GUI boundary, and a later Unbind (or
  // Close) retries the detach.
  if TryNativeDetach(entry, err) then
  begin
    FLock.Enter;
    try
      FEntries.Remove(entry);
    finally
      FLock.Leave;
    end;
    entry.Free; // confirmed detached: exactly one free, exactly here
  end
  else
    raise EPWebBindingError.CreateFmt(
      'Unbind: native unbind of "%s" failed (%s); the binding stays ' +
      'registered and memory-safe - retry Unbind/Close later',
      [string(Name), WebViewErrorName(err)]);
end;

function TWebViewBinding.UnbindAllForClose: Boolean;
var
  snapshot: array of TPWebBindEntry;
  entry: TPWebBindEntry;
  i: Integer;
  err: webview_error_t;
begin
  // the ratified teardown window: GUI thread, source Quiescing.
  // Iterate WITHOUT popping: an entry leaves the registry only once
  // its native detach is confirmed; failed ones stay tracked so a
  // later Close can retry exactly the remainder.
  FLock.Enter;
  try
    SetLength(snapshot, FEntries.Count);
    for i := 0 to FEntries.Count - 1 do
      snapshot[i] := TPWebBindEntry(FEntries[i]);
  finally
    FLock.Leave;
  end;
  Result := True;
  for i := 0 to High(snapshot) do
  begin
    entry := snapshot[i];
    if TryNativeDetach(entry, err) then
    begin
      FLock.Enter;
      try
        FEntries.Remove(entry);
      finally
        FLock.Leave;
      end;
      entry.Free; // confirmed detached
    end
    else
      Result := False; // stays alive and tracked; teardown is retryable
  end;
end;

procedure TWebViewBinding.Quiesce;
begin
  // delegate to the single underlying source: states cannot diverge
  FSource.Quiesce;
end;

procedure TWebViewBinding.Close;
begin
  Assert(GetCurrentThreadId = FAffinityThread,
    'Close called off the GUI-affine thread'); // debug builds only
  // 1) full Quiesce semantics first (there is no Running -> Closed):
  //    refuse new invocations, complete queued ones as cancelled -
  //    those completions still deliver, the lease is still open
  FSource.Quiesce;
  // 2) the ratified teardown window: JS-side unbind on the GUI thread
  //    while the source is Quiescing, before destroy. If ANY detach
  //    fails to confirm, teardown STOPS here in a safe, retryable
  //    state: the source stays Quiescing, the lease stays open, no
  //    falsely successful Closed is ever entered, and the failure is
  //    raised at this (GUI-affine) call site - a later Close retries
  //    only the remaining entries.
  if not UnbindAllForClose then
    raise EPWebBindingError.Create(
      'Close: a native unbind failed to confirm detach; the source ' +
      'stays Quiescing and the entries stay tracked - retry Close');
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
  // correctness DEPENDS on concurrent visibility of the shutter flag
  // here (worker threads vs the closing GUI thread), so both reads are
  // atomic - a plain load could stay stale on a weakly-ordered target
  Result := False;
  if PWebAtomicRead(FLeaseClosed) <> 0 then
    exit; // no new leases once the close transition began
  InterlockedIncrement(FLeaseCount);
  if PWebAtomicRead(FLeaseClosed) <> 0 then
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
  // atomic read: the owner polls this from another thread to gate the
  // deferred native destruction on the lease drain
  Result := PWebAtomicRead(FLeaseCount);
end;

function TWebViewBinding.EffectiveMaxRequestBytes: Integer;
begin
  // already clamped at construction: min(configured, hard ceiling)
  Result := FMaxRequestBytes;
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
  const AHandler: IWebViewInvocationHandler; const ARequest: TPWebJson;
  const ACompletion: IInvocationCompletion);
var
  ctx: TInvocationContext;
begin
  // defense-in-depth size check (the raw callback already rejected
  // oversize with a bounded scan BEFORE copying; this guards any other
  // caller of this internal entry point)
  if Length(ARequest) > FMaxRequestBytes then
  begin
    ACompletion.Complete(PWebErrorResult(pecInvalidRequest, 'Request too large'));
    exit;
  end;
  // native immutable context snapshot - never from the JS payload
  ctx := PWebCopyContext(FContextTemplate);
  // envelope parsing + non-blocking enqueue are the handler's duties
  AHandler.HandleInvocation(ctx, ARequest, ACompletion);
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

initialization
  QuarantineLock := TCriticalSection.Create;
  QuarantinedEntries := TList.Create;

{ deliberately NO finalization for the quarantine machinery: the lock
  and the list follow the same process-lifetime leak-by-choice policy
  as the entries they guard - freeing (or nil'ing) a lock that another
  late thread may just be entering during shutdown would trade a tiny
  bounded leak for a teardown race }

end.
