{
  pweb.rpc.fetch.mormot - the mORMot transport behind the CAP-15B fetch seam.

  THE ONLY FILE IN SHIPPED SOURCE PERMITTED TO NAME `mormot.net.client`, and
  the whole reason `pweb.rpc.fetch.pas` injects its transport rather than
  conditionalising it. Selected on Windows and Linux; on Darwin the seam is
  filled by an NSURLSession transport in the adapter layer, so this unit is
  not on that target's compiled unit set at all and the "exactly one file"
  pin holds unchanged across a second platform.

  ---------------------------------------------------------------------------
  IT IS BUILT ON THE FOUR DEFECTS CAP-15A MEASURED, NOT AROUND THEM
  ---------------------------------------------------------------------------

  The CAP-15A spike used this same library and got four things wrong. None of
  them is visible in a code review; three were found only in a server-side
  wire log. Each is answered here by a named mechanism rather than by care:

  1. mORMot RE-SENDS a failed request by itself (ledger 15A-4). One call with
     an 800 ms bound produced TWO `/slow` hits on the wire, which for a
     non-idempotent POST is a duplicate order rather than a slow one. The
     declaration of `THttpClientSocket.Request` says so in as many words:
     "AsRetry is to be kept as false, because this method already retries by
     itself". So this transport passes `AsRetry := true` - entering with
     `rMain` already in the retry set, which is exactly the state
     `DoRetry` refuses to retry from. RETRIES ARE NONE.

  2. A SOCKET TIMEOUT IS NOT A DEADLINE (ledger 15A-5). mORMot's timeout is
     per-READ, so a response that dribbles resets it on every read: 800 ms
     requested, 1609 ms observed. The runtime therefore owns a WALL-CLOCK
     TOTAL-REQUEST deadline, held in TPWebFetchSink and checked between
     slices, so cancellation is not a promise the door keeps only until the
     first byte.

  3. THE RESPONSE BOUND WAS ENFORCED AFTER THE READ (ledger 15A-6). 32 MiB
     was pulled whole into memory and only then refused against the 8 MiB
     limit, which makes a bound a memory amplifier rather than a defence.
     `THttpClientSocket.Request` accepts an `OutStream`, and
     `THttpSocket.GetBody(DestStream)` writes into it in <=256 KiB slices
     (Content-Length path) or chunk by chunk (chunked path), so the sink sees
     every slice BEFORE it is accumulated. `RequestInternal` also publishes
     `TStreamRedirect.ExpectedSize` from the response `Content-Length`
     BEFORE calling `GetBody`, which is why the sink descends from that class
     and gets §4's Content-Length half with at most one slice read.

     `RequestInternal`'s own except block re-raises anything that is not
     `ENetSock` or `EHttpSocket` - "propagate custom exceptions to the caller
     (e.g. from progression)" - so a refusal raised by the sink reaches this
     transport and does NOT enter `DoRetry`.

  4. THE CONVENIENT ENTRY POINTS INHERIT THE SYSTEM PROXY (ledger 15A-7).
     `THttpRequestExtendedOptions.Proxy` defaults to `''`, which means "use
     the system proxy", and `OpenUri`, `OpenOptions` and `TSimpleHttpClient`
     all reach it. `Create` + `OpenBind` consults nothing at all, which is
     why this unit uses those two and why `test/cap15b` forbids the others by
     name: a rule about a default is only as good as the constructor it
     forbids.

  ---------------------------------------------------------------------------
  TLS
  ---------------------------------------------------------------------------

  Certificate validation is ON and there is NO setting anywhere - descriptor,
  environment, argument or Pascal - that can turn it off. The
  `TNetTlsContext` this unit builds is zeroed and never assigns
  `IgnoreCertificateErrors`; the gate sweeps this file for that identifier,
  for `IgnoreTlsCertError` and for `AllowDeprecatedTls` precisely so that the
  absence is measured rather than reviewed.

  On Windows the provider is SChannel, registered by `mormot.net.sock`'s own
  initialization with nothing named and nothing added. On UNIX there is no
  provider at all unless `mormot.lib.openssl11` is LINKED - it assigns
  `NewNetTls` in its initialization and loads `libssl.so.3` from the SYSTEM
  at first use. That is a runtime dependency the product now declares
  (`docs/third-party-licenses.md`) and `pweb doctor` reports by name and
  version (`platform.tls`).

  NO COOKIE JAR EXISTS ON THIS PATH. `THttpClientSocket` keeps none, no
  `Set-Cookie` is honoured and no `Cookie` is ever sent; an application
  carries its own `authorization`, which is the one credential header the
  request allowlist admits.
}
unit pweb.rpc.fetch.mormot;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.buffers,
  mormot.net.sock,
  mormot.net.client,
  {$ifdef UNIX}
  // POSIX has NO TLS layer unless this unit is LINKED: its initialization
  // assigns NewNetTls, and the library itself is the system's. Without it
  // mORMot answers "TLS support not compiled - try including
  // mormot.lib.openssl11 in your project" at the handshake, which is a
  // runtime failure a compile cannot show you.
  //
  // `UNIX`, not mORMot's `OSPOSIX`: this unit does not include
  // mormot.defines.inc - no unit under src/ does - so mORMot's own platform
  // symbols are simply not defined here, and a conditional written in them
  // is a conditional that is always false. MEASURED: it compiled cleanly
  // and every https request then failed at the handshake
  mormot.lib.openssl11,
  {$endif UNIX}
  pweb.rpc.intf,
  pweb.rpc.fetch;

const
  /// what a server sees, and the whole of it
  // - no Origin, no Referer, no Cookie, no Sec-Fetch-*, no client hints and
  // no Accept-Language: the entire browser fingerprint is absent because no
  // browser is involved. It carries no version, because a version is a
  // deployment fact an application did not ask to publish
  PWEB_FETCH_USER_AGENT = 'PWeb';

/// the CAP-15B transport for Windows and Linux
// - THE NAME IS PLATFORM-NEUTRAL ON PURPOSE: the Darwin adapter exports the
// same one, and the two units are never both on a compiled unit set, so the
// generated program names one transport and no conditional at the call site
// - satisfies TPWebFetchTransport exactly: it never raises, it answers one
// of the five outcomes, and it decides nothing the decorator has not already
// decided
function PWebFetchNativeTransport(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;

implementation

type
  { Why the read stopped. Raised out of the sink, caught by the transport,
    and never allowed to escape as a native detail. }
  EPWebFetchStop = class(Exception)
  public
    Outcome: TPWebFetchOutcome;
    constructor CreateStop(AOutcome: TPWebFetchOutcome);
  end;

  { The response sink: the whole of §4's "enforced DURING the read".

    It descends from TStreamRedirect for one reason and one only -
    `RequestInternal` sets ExpectedSize on a stream of that class from the
    response Content-Length BEFORE the body loop runs, which is the only hook
    that gives the declared-length half of the bound without reading a body
    first. Nothing else of that class is used: no hash, no progress callback,
    no rate limit, and no redirected stream (the inherited Write is called
    with fRedirected nil, which does the position bookkeeping and returns). }
  TPWebFetchSink = class(TStreamRedirect)
  protected
    FMax: PtrInt;
    FDeadlineTix: Int64;
    FToken: ICancellationToken;
    // mORMot's own growing byte buffer rather than a hand-rolled one: a
    // response sink is not the place to re-derive a reallocation rule, and
    // this one already knows how to grow geometrically without copying
    // more than it must
    FBody: TRawByteStringBuffer;
    FSeen: Int64;
    procedure StopIfDue;
  public
    constructor CreateSink(AMax: PtrInt; ADeadlineTix: Int64;
      const AToken: ICancellationToken);
    function Write(const Buffer; Count: Longint): Longint; override;
    /// exactly the bytes accepted, with no slack capacity attached
    function Body: RawByteString;
    property Seen: Int64
      read FSeen;
  end;

constructor EPWebFetchStop.CreateStop(AOutcome: TPWebFetchOutcome);
begin
  inherited Create('fetch stopped');
  Outcome := AOutcome;
end;

constructor TPWebFetchSink.CreateSink(AMax: PtrInt; ADeadlineTix: Int64;
  const AToken: ICancellationToken);
begin
  inherited Create({aRedirected=}nil, {aRead=}false);
  FMax := AMax;
  FDeadlineTix := ADeadlineTix;
  FToken := AToken;
end;

procedure TPWebFetchSink.StopIfDue;
begin
  // THE DEADLINE IS OBSERVED HERE, between slices, and that is the whole
  // answer to 15A-5: a blocking socket read cannot see a token or a clock,
  // so the check has to live where the read hands bytes back
  if GetTickCount64() >= FDeadlineTix then
    raise EPWebFetchStop.CreateStop(pfoTimedOut);
  if (FToken <> nil) and
     FToken.IsCancelled then
    raise EPWebFetchStop.CreateStop(pfoCancelled);
end;

function TPWebFetchSink.Write(const Buffer; Count: Longint): Longint;
begin
  StopIfDue;
  // the DECLARED length, refused at the FIRST slice rather than after the
  // whole body. mORMot has already put the response Content-Length here
  // when the status carries a body; it is 0 when the length is unknown or
  // the transfer is chunked, and then the running total below is the only
  // bound - which is exactly the "lying or absent length" case §4 names
  if (ExpectedSize > FMax) or
     (FSeen + Count > FMax) then
  begin
    Inc(FSeen, Count);
    raise EPWebFetchStop.CreateStop(pfoTooLarge);
  end;
  FBody.Append(@Buffer, Count);
  Inc(FSeen, Count);
  // position bookkeeping only - fRedirected is nil, so the inherited call
  // hashes nothing and writes nowhere
  Result := inherited Write(Buffer, Count);
end;

function TPWebFetchSink.Body: RawByteString;
begin
  FastSetString(RawUtf8(Result), FBody.Buffer, FBody.Len);
end;

function PWebFetchNativeTransport(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;
var
  client: THttpClientSocket;
  sink: TPWebFetchSink;
  started, deadlineTix: Int64;
  headers: RawUtf8;
begin
  Response := Default(TPWebFetchResponse);
  Result := pfoTransport;
  started := GetTickCount64();
  deadlineTix := started + Request.DeadlineMs;
  if (Token <> nil) and
     Token.IsCancelled then
  begin
    Response.Ms := 0;
    exit(pfoCancelled);
  end;
  sink := nil;
  client := nil;
  try
    try
      // Create + OpenBind, NEVER OpenUri / OpenOptions / TSimpleHttpClient:
      // those take THttpRequestExtendedOptions, whose Proxy defaults to ''
      // meaning "use the system proxy". These two consult nothing, so the
      // origin allowlist stays a statement about who receives the request
      client := THttpClientSocket.Create(Request.DeadlineMs);
      client.RedirectMax := 0; // a 3xx comes back with its Location, never followed
      client.UserAgent := PWEB_FETCH_USER_AGENT;
      // certificate validation stays ON: the context is zeroed and this unit
      // assigns nothing that could relax it
      client.TLS := Default(TNetTlsContext);
      client.OpenBind(Request.Host, RawUtf8(IntToStr(Request.Port)),
        {doBind=}false, Request.Https);
      sink := TPWebFetchSink.CreateSink(Request.MaxResponseBytes, deadlineTix,
        Token);
      Response.Status := client.Request(Request.Target, Request.Method,
        {KeepAlive=}0, Request.Headers, Request.Body, Request.Mime,
        {AsRetry=}true, {InStream=}nil, {OutStream=}sink);
      // the response header block, rebuilt for the decorator's allowlist.
      // GetHeader(HeadersUnFiltered=false) consumes Content-Type and
      // Content-Length into their own fields rather than leaving them in
      // Http.Headers, and both are on the ratified response allowlist, so
      // handing over Http.Headers alone would silently drop two rows the
      // envelope is contracted to carry
      headers := '';
      if client.Http.ContentType <> '' then
        headers := headers + 'Content-Type: ' + client.Http.ContentType + #13#10;
      if client.Http.ContentLength >= 0 then
        headers := headers + 'Content-Length: ' +
          RawUtf8(IntToStr(client.Http.ContentLength)) + #13#10;
      headers := headers + client.Http.Headers;
      Response.Headers := headers;
      Response.Body := sink.Body;
      Response.Bytes := sink.Seen;
      Result := pfoOk;
      // mORMot answers its own client-error status rather than raising for
      // some failures; a status it invented is not an HTTP status
      if Response.Status = HTTP_CLIENTERROR then
      begin
        Response.Body := '';
        Response.Headers := '';
        Result := pfoTransport;
      end;
    except
      on E: EPWebFetchStop do
      begin
        Response.Bytes := 0;
        if sink <> nil then
          Response.Bytes := sink.Seen;
        Response.Body := '';
        Response.Headers := '';
        Response.Status := 0;
        Result := E.Outcome;
      end;
      on Exception do
      begin
        // connect, TLS, protocol, a Content-Encoding an OutStream cannot
        // take: one category, no native text, and the exception never
        // travels out of a transport call
        Response.Body := '';
        Response.Headers := '';
        Response.Status := 0;
        Result := pfoTransport;
      end;
    end;
  finally
    sink.Free;
    client.Free;
  end;
  Response.Ms := GetTickCount64() - started;
  // a deadline that expired while the socket layer was blocked in connect or
  // in the header read is still a deadline: the sink can only see the body
  if (Result = pfoTransport) and
     (GetTickCount64() >= deadlineTix) then
    Result := pfoTimedOut;
end;

end.
