{
  pweb.rpc.support - neutral RTL-only helpers over the frozen
  pweb.rpc.intf contracts (Phase 2 / CAP-2 corrective pass).

  Layering by ratified constraint: this unit depends on pweb.rpc.intf
  ONLY - never on pweb.rpc.scheduler, any pweb.webview.* unit, mORMot,
  or a platform unit. It exists so that generic helpers shared by the
  scheduler, bridges, bindings, tests and examples do not couple those
  consumers to the concrete scheduler implementation.

  IMPORTANT - moving PWebValidMethod here does NOT move the gate:
  production RPC admission still calls it from exactly one place,
  IInvocationSource.TryEnqueue in pweb.rpc.scheduler (wire-semantics.md
  "One canonicalization point"). This unit provides the predicate, not
  a second canonicalization/validation path; no transport may validate
  methods anywhere but TryEnqueue.
}
unit pweb.rpc.support;

{$mode ObjFPC}{$H+}

{ The default-message table below is constant implementation data - it
  must not be modifiable at runtime. }
{$J-}

interface

uses
  pweb.rpc.intf;

const
  { Upper bound of the canonical method spelling, in bytes. The wire
    grammar mandates a bounded length (wire-semantics.md "Request
    grammar and limits"); the bound itself is an implementation choice
    of the gate, not wire protocol. }
  PWEB_METHOD_MAX_BYTES = 256;

  { Default human-readable message per error code. No native detail
    ever appears here (wire-semantics.md error contract). These are
    implementation defaults, not frozen wire data - the sole normative
    discriminator stays the `code` member. }
  PWEB_DEFAULT_ERROR_MESSAGE: array[TPWebErrorCode] of Utf8String = (
    'Invalid request',            // pecInvalidRequest
    'Method not found',           // pecMethodNotFound
    'Invocation is not allowed',  // pecForbidden
    'Runtime is busy',            // pecBusy
    'Invocation was cancelled',   // pecCancelled
    'Service error',              // pecServiceError
    'Internal error',             // pecInternalError
    'Runtime is closed',          // pecRuntimeClosed
    'Protocol mismatch'           // pecProtocolMismatch
  );

{ Canonical method grammar predicate (the gate itself stays
  IInvocationSource.TryEnqueue - see the unit header). Accepted here:
  1..PWEB_METHOD_MAX_BYTES bytes, characters [A-Za-z0-9_.] only,
  EXACTLY two non-empty dot-separated segments - the Service.Method
  application form; the runtime-reserved pweb.* form has the same
  shape (wire-semantics.md "Request grammar and limits"). Case is
  preserved exactly - matching is case-sensitive downstream. Rejected:
  zero dots, two or more dots (A.B.C), empty segments (.A / A. / A..B),
  NUL, space, slash, non-ASCII - anything outside the exact grammar. }
function PWebValidMethod(const AMethod: Utf8String): Boolean;

{ Args grammar predicate of the same enqueue gate: a serialized JSON
  object or the PWEB_JSON_NULL literal - never the empty string, never
  an array (named arguments only in protocol v1). Structural check
  only: full JSON validation is the transport parser's duty. Like
  PWebValidMethod, this is the predicate, not the gate - production
  admission calls it only from TryEnqueue. }
function PWebValidArgs(const AArgs: TPWebJson): Boolean;

{ Immutable deep-copy snapshot of a context: plain record assignment
  would share the Capabilities dynamic array reference (frozen
  TInvocationContext comment mandates Copy()). }
function PWebCopyContext(const AContext: TInvocationContext): TInvocationContext;

{ Frozen identity invariants of TInvocationContext: pkWindow implies
  WindowId <> ''; pkPlugin implies PluginId <> ''. }
function PWebValidContext(const AContext: TInvocationContext): Boolean;

{ Result constructors shared by scheduler, bridges and bindings. }
function PWebSuccessResult(const AValue: TPWebJson): TPWebInvocationResult;
function PWebErrorResult(ACode: TPWebErrorCode;
  const AMessage: Utf8String; const AData: TPWebJson = PWEB_JSON_NULL): TPWebInvocationResult;
function PWebDefaultErrorResult(ACode: TPWebErrorCode): TPWebInvocationResult;

{ Portable FPC-3.2.2 atomic read of a LongInt shared across threads
  (a no-op compare-exchange, which is a full read-modify-write barrier
  on every target, including future ARM64 - a plain load carries no
  such guarantee there). Use it wherever correctness depends on
  concurrent visibility of an interlocked-written field (lease gates,
  cancellation/lifecycle flags); provably advisory-only plain reads
  may instead stay plain with a comment saying so. }
function PWebAtomicRead(var AValue: LongInt): LongInt;

implementation

function PWebValidMethod(const AMethod: Utf8String): Boolean;
var
  i, len, dots: Integer;
  prevDot: Boolean;
  c: AnsiChar;
begin
  Result := False;
  len := Length(AMethod);
  if (len < 3) or (len > PWEB_METHOD_MAX_BYTES) then
    exit; // shortest possible Service.Method is 'a.b'
  dots := 0;
  prevDot := True; // a leading dot must fail like an empty segment
  for i := 1 to len do
  begin
    c := AnsiChar(AMethod[i]);
    if c = '.' then
    begin
      if prevDot then
        exit; // empty segment ('..' or leading '.')
      Inc(dots);
      prevDot := True;
    end
    else if c in ['A'..'Z', 'a'..'z', '0'..'9', '_'] then
      prevDot := False
    else
      exit; // NUL, slash, space, non-ASCII... - not canonical grammar
  end;
  if prevDot then
    exit; // trailing dot
  Result := dots = 1; // EXACTLY Service.Method - A.B.C is not canonical
end;

function PWebValidArgs(const AArgs: TPWebJson): Boolean;
var
  a, b: Integer;
begin
  // trim FIRST so equivalent spellings are treated consistently:
  // ' null ' and '{ }' are as acceptable as their unpadded forms
  a := 1;
  b := Length(AArgs);
  while (a <= b) and (AArgs[a] in [#9, #10, #13, ' ']) do
    Inc(a);
  while (b >= a) and (AArgs[b] in [#9, #10, #13, ' ']) do
    Dec(b);
  if b < a then
    exit(False); // empty or whitespace-only is never a valid TPWebJson
  if (b - a + 1 = Length(PWEB_JSON_NULL)) and
     (Copy(AArgs, a, Length(PWEB_JSON_NULL)) = PWEB_JSON_NULL) then
    exit(True);
  Result := (a < b) and (AArgs[a] = '{') and (AArgs[b] = '}');
end;

function PWebCopyContext(const AContext: TInvocationContext): TInvocationContext;
begin
  Result := AContext;
  Result.Capabilities := Copy(AContext.Capabilities);
  // force unique heap copies of the strings as well: the snapshot must
  // stay valid even if the caller mutates its own record afterwards
  UniqueString(Result.WindowId);
  UniqueString(Result.PrincipalId);
  UniqueString(Result.PluginId);
end;

function PWebValidContext(const AContext: TInvocationContext): Boolean;
begin
  case AContext.PrincipalKind of
    pkWindow:
      Result := AContext.WindowId <> '';
    pkPlugin:
      Result := AContext.PluginId <> '';
  else
    Result := True;
  end;
end;

function PWebSuccessResult(const AValue: TPWebJson): TPWebInvocationResult;
begin
  Result := Default(TPWebInvocationResult);
  Result.Kind := prkSuccess;
  if AValue = '' then
    Result.Value := PWEB_JSON_NULL // '' would surface as JS undefined
  else
    Result.Value := AValue;
end;

function PWebErrorResult(ACode: TPWebErrorCode;
  const AMessage: Utf8String; const AData: TPWebJson): TPWebInvocationResult;
begin
  Result := Default(TPWebInvocationResult);
  Result.Kind := prkError;
  Result.Error.Code := ACode;
  if AMessage = '' then
    Result.Error.Message := PWEB_DEFAULT_ERROR_MESSAGE[ACode]
  else
    Result.Error.Message := AMessage;
  if AData = '' then
    Result.Error.Data := PWEB_JSON_NULL
  else
    Result.Error.Data := AData;
end;

function PWebDefaultErrorResult(ACode: TPWebErrorCode): TPWebInvocationResult;
begin
  Result := PWebErrorResult(ACode, PWEB_DEFAULT_ERROR_MESSAGE[ACode]);
end;

function PWebAtomicRead(var AValue: LongInt): LongInt;
begin
  // exchanges 0 for 0 only when the value already IS 0: never mutates,
  // always returns the current value with full interlocked semantics
  Result := InterlockedCompareExchange(AValue, 0, 0);
end;

end.
