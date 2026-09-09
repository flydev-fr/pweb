{
  pweb.platform.cocoa.fetch - the Darwin transport behind the CAP-15B fetch
  seam (CAP-15B, ratified as CAP-15A §10).

  ONE function, PWebFetchNativeTransport, satisfying the injected
  TPWebFetchTransport of src/rpc/pweb.rpc.fetch.pas over NSURLSession.

  ---------------------------------------------------------------------------
  WHY THIS FILE EXISTS AT ALL
  ---------------------------------------------------------------------------

  macOS ships no libssl in a default install, so the Linux answer - mORMot's
  socket client plus the system OpenSSL - has no provider here. CAP-15A
  measured the three candidates and REFUSED two of them:

    1. ship OpenSSL inside the .app. Refused: it adds a bundled cryptographic
       library to a product whose whole claim is that it bundles no engine,
       and it buys a second trust store to keep current for the life of every
       application - a licence row and a notarization surface in exchange for
       a worse security posture than the one the operating system already
       maintains;
    3. declare macOS out of scope. Refused: `pweb doctor` would then report a
       `platform.tls` row saying the product does not work on a target the
       product ships on, which is a hole rather than a limitation.

  So the answer is option 2: a second transport, behind the SAME injected
  seam, on the SYSTEM trust store. The measured cost is one platform file and
  no new dependency - and the reason it is one file rather than a redesign is
  that §1 split the decorator from its transport in the first place.

  ---------------------------------------------------------------------------
  WHAT IT DOES NOT DO
  ---------------------------------------------------------------------------

  It renders no verdict. The URL was parsed, the origin matched by component,
  the method and headers allowlisted, the body bounded and the deadline
  chosen by the shared decorator before this unit is reached, and the
  response envelope - including the response-header allowlist and the rule
  that `set-cookie` is never exposed - is built there afterwards. This unit
  translates one request into one NSURLSession exchange and translates the
  outcome back, exactly as pweb.platform.cocoa translates a navigation.

  It also names NO `mormot.net.*` unit, which is what keeps §8's "exactly one
  file in src/** names mormot.net.client" true on a second platform: on
  Darwin `pweb.rpc.fetch.mormot` is not on the compiled unit set at all.

  ---------------------------------------------------------------------------
  THE SEVEN PROPERTIES, AND WHERE EACH ONE LIVES
  ---------------------------------------------------------------------------

  All seven are enforced in the Objective-C++ half (pweb_cocoa_bridge.mm),
  because that is where the API is. This unit's job is the eighth: to make
  the whole thing a BOUNDED SYNCHRONOUS CALL on a scheduler worker thread,
  and to hand the C side a cancellation predicate it can poll between wait
  slices - which is how `ICancellationToken` becomes observable DURING a
  transfer rather than only before one.

  The token is reached through a plain callback over an opaque pointer to a
  stack record, so nothing of Pascal's object model crosses the seam and no
  lifetime question arises: the record outlives the call by construction.
}
unit pweb.platform.cocoa.fetch;

{$mode ObjFPC}{$H+}
{ Every record below crosses the private C seam. }
{$PACKRECORDS C}

{$ifndef DARWIN}
  {$MESSAGE Error 'pweb.platform.cocoa.fetch is the macOS outbound transport'}
{$endif DARWIN}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.rpc.intf,
  pweb.rpc.fetch;

/// the CAP-15B transport for macOS
// - THE NAME IS PLATFORM-NEUTRAL ON PURPOSE: `pweb.rpc.fetch.mormot` exports
// the same one, the two units are never both on a compiled unit set, and the
// generated program therefore names one transport and no conditional
// - satisfies TPWebFetchTransport exactly: it never raises, it answers one of
// the five outcomes, and it decides nothing the decorator has not decided
function PWebFetchNativeTransport(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;

implementation

const
  { ordinal for ordinal with TPWebFetchOutcome and with the
    PWEB_COCOA_FETCH_* constants in pweb_cocoa_bridge.h. A value outside this
    set is a transport failure, never a guess }
  PWEB_COCOA_FETCH_OK = 0;
  PWEB_COCOA_FETCH_TIMEDOUT = 1;
  PWEB_COCOA_FETCH_CANCELLED = 2;
  PWEB_COCOA_FETCH_TOOLARGE = 3;
  PWEB_COCOA_FETCH_TRANSPORT = 4;

type
  TPWebCocoaFetchRequest = record
    Url: PAnsiChar;
    Method: PAnsiChar;
    Headers: PAnsiChar;
    ContentType: PAnsiChar;
    Body: Pointer;
    BodyLength: Int64;
    DeadlineMs: Int64;
    MaxResponseBytes: Int64;
  end;
  PPWebCocoaFetchRequest = ^TPWebCocoaFetchRequest;

  TPWebCocoaFetchResponse = record
    Status: LongInt;
    Ms: LongInt;
    Bytes: Int64;
    Headers: Pointer;
    Body: Pointer;
    BodyLength: Int64;
    Deliveries: LongInt;
    PeakBytes: Int64;
    RedirectsOffered: LongInt;
    ProxyDictEmpty: LongInt;
  end;
  PPWebCocoaFetchResponse = ^TPWebCocoaFetchResponse;

  TPWebCocoaCancelFn = function(Opaque: Pointer): LongInt; cdecl;

  { what the cancel callback is handed: a pointer to a record on THIS call's
    stack. It outlives the call by construction, so no lifetime rule has to
    be written down and no object crosses the seam }
  TPWebCocoaCancelContext = record
    Token: ICancellationToken;
  end;
  PPWebCocoaCancelContext = ^TPWebCocoaCancelContext;

function pweb_cocoa_fetch(request: PPWebCocoaFetchRequest;
  cancel: TPWebCocoaCancelFn; cancel_opaque: Pointer;
  out_: PPWebCocoaFetchResponse): LongInt; cdecl;
  external name 'pweb_cocoa_fetch';
procedure pweb_cocoa_fetch_release(out_: PPWebCocoaFetchResponse); cdecl;
  external name 'pweb_cocoa_fetch_release';

// polled between wait slices on the C side. It must not raise and must not
// block: a cancellation predicate that can do either is a worker thread that
// can stop being one
function PWebCocoaFetchCancelled(Opaque: Pointer): LongInt; cdecl;
var
  ctx: PPWebCocoaCancelContext;
begin
  Result := 0;
  ctx := PPWebCocoaCancelContext(Opaque);
  if ctx = nil then
    exit;
  try
    if (ctx^.Token <> nil) and
       ctx^.Token.IsCancelled then
      Result := 1;
  except
    // a predicate that raised is not a cancellation: it is a bug, and it
    // dies here rather than travelling into an Objective-C frame
    Result := 0;
  end;
end;

function MapOutcome(Code: LongInt): TPWebFetchOutcome;
begin
  case Code of
    PWEB_COCOA_FETCH_OK:        Result := pfoOk;
    PWEB_COCOA_FETCH_TIMEDOUT:  Result := pfoTimedOut;
    PWEB_COCOA_FETCH_CANCELLED: Result := pfoCancelled;
    PWEB_COCOA_FETCH_TOOLARGE:  Result := pfoTooLarge;
  else
    Result := pfoTransport;
  end;
end;

function PWebFetchNativeTransport(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;
var
  req: TPWebCocoaFetchRequest;
  res: TPWebCocoaFetchResponse;
  ctx: TPWebCocoaCancelContext;
  url, method, headers, mime: RawUtf8;
  code: LongInt;
begin
  Response := Default(TPWebFetchResponse);
  Result := pfoTransport;
  if (Token <> nil) and
     Token.IsCancelled then
    exit(pfoCancelled);
  // NUL-terminated copies the seam can hold for the length of the call:
  // RawUtf8 is already NUL-terminated by the RTL, and the locals keep the
  // buffers alive past the external call
  url := Request.Url;
  method := Request.Method;
  headers := Request.Headers;
  mime := Request.Mime;
  ctx.Token := Token;
  req := Default(TPWebCocoaFetchRequest);
  req.Url := PAnsiChar(url);
  req.Method := PAnsiChar(method);
  if headers <> '' then
    req.Headers := PAnsiChar(headers);
  if mime <> '' then
    req.ContentType := PAnsiChar(mime);
  if Request.Body <> '' then
  begin
    req.Body := pointer(Request.Body);
    req.BodyLength := Length(Request.Body);
  end;
  req.DeadlineMs := Request.DeadlineMs;
  req.MaxResponseBytes := Request.MaxResponseBytes;
  res := Default(TPWebCocoaFetchResponse);
  try
    code := pweb_cocoa_fetch(@req, @PWebCocoaFetchCancelled, @ctx, @res);
    try
      Result := MapOutcome(code);
      Response.Status := res.Status;
      Response.Ms := res.Ms;
      Response.Bytes := res.Bytes;
      if Result = pfoOk then
      begin
        if res.Headers <> nil then
          Response.Headers := RawUtf8(PAnsiChar(res.Headers));
        if (res.Body <> nil) and
           (res.BodyLength > 0) then
        begin
          SetLength(Response.Body, res.BodyLength);
          Move(res.Body^, pointer(Response.Body)^, res.BodyLength);
        end;
      end
      else
      begin
        // nothing partial ever reaches the envelope: a refused exchange
        // carries a category and its byte count, never half a body
        Response.Headers := '';
        Response.Body := '';
        Response.Status := 0;
      end;
    finally
      // the two blocks belong to this side from the moment the call
      // returned, whatever it returned, and are released exactly once
      pweb_cocoa_fetch_release(@res);
    end;
  except
    Response := Default(TPWebFetchResponse);
    Result := pfoTransport;
  end;
  ctx.Token := nil;
end;

end.
