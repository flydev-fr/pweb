{
  pweb.blobs.protocol - the blob protocol translator (CAP-12A §6.1.3).

  THE ONE UNIT IN THE TREE THAT KNOWS BOTH SPELLINGS: the reserved URL
  namespace on one side and IBlobStore on the other. pweb.blobs.intf
  names no URI at all, by the SPEC's own rule, and the three platform
  adapters name no store grammar - they hand this unit a logical path, a
  method and a Range header, and answer with what comes back.

  THE NAMESPACE, ratified by CAP-12A §2 and MEASURED:

      pweb://app/_pweb/blob/<32 lowercase hex>

  and NOT `pweb://blob/<token>`, which is what the SPEC sketched before
  CAP-8B ratified the native CSP. `PWEB_NATIVE_CSP` carries
  `connect-src 'self'`, `img-src 'self' data:` and `media-src 'self'`;
  an origin is scheme + host + port, so `pweb://blob` is a DIFFERENT
  origin and every one of those directives refuses it. CAP-12A measured
  that on both engines with a path that would have counted a request if
  one had ever arrived, and counted zero. The invariant - JSON is the
  control plane, the reserved prefix is the data plane - survives; only
  its spelling moved.

  THE RESERVATION IS ENFORCED TWICE and neither place is sufficient
  alone. Here, at serve time, the prefix is tested BEFORE any store -
  asset, folder or generation - is consulted, so a bundle that somehow
  carried `_pweb/...` is unreachable rather than merely unlikely. And at
  pack time, where `pwebbundle` refuses a first segment `_pweb` outright.

  NO PARAMETER MAY RIDE IN A QUERY STRING. MEASURED (CAP-12A §2):
  PWebParseAppUri cuts `?` and `#` before decoding, so
  `.../blob/<token>?range=1` is the SAME resource on both engines.
  Everything the plane needs per request travels in a header (`Range`)
  or in the token.

  Layering: RTL plus mormot.core.base plus pweb.blobs.intf. No webview,
  no rpc, no platform unit, no crypt - which is what lets the three
  platform adapters keep the isolation compile CAP-4 froze for them.
}
unit pweb.blobs.protocol;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.blobs.intf;

const
  /// the reserved FIRST SEGMENT of the privileged origin's path space
  // - `_pweb`, not `_pweb/blob`: later runtime-owned URL space gets room
  // without a second reservation, and one reservation is one rule for
  // the handler, for the bundler and for the documentation
  PWEB_BLOB_RESERVED_SEGMENT = '_pweb';

  /// the blob namespace under it - exactly three segments
  // - a fixed shape is checkable in one comparison before any store is
  // consulted, which is what makes the serve-time reservation cheap
  // enough to sit in front of every request
  PWEB_BLOB_PATH_PREFIX = '_pweb/blob/';

  /// the WHOLE URL a page fetches a blob from
  // - the ONE place in the tree where the store's spelling and the URL's
  // meet. A producer - the fetch door today, the SDK upload API in
  // CAP-12C - hands back a URL rather than a token plus instructions on
  // how to build one, because a second place that concatenated this
  // prefix would be a second answer to the namespace question CAP-12A
  // §2 settled
  // - it is `pweb://app/...` and NOT `pweb://blob/...`: an origin is
  // scheme + host + port, and `connect-src 'self'` in the ratified CSP
  // refuses a second authority before a request for it exists
  PWEB_BLOB_URL_PREFIX = 'pweb://app/' + PWEB_BLOB_PATH_PREFIX;

  /// the longest body one response may carry, in bytes
  // - CAP-12A §5.3, MEASURED: WebView2 delivers response bodies SERIALLY
  // on the host's GUI thread, so a body's production-plus-drain time is
  // a stall for every other pweb://app response. A 256 MiB whole body
  // took 1 434 ms page-side on that engine; at 8 MiB the same rate gives
  // ~45 ms. It is also PWEB_FETCH_MAX_RESPONSE, so the two doors carry
  // one number
  // - in v1 it equals the store's own MaxBlobBytes, so no whole-body
  // answer can exceed it and the clamp below never fires. The clamp
  // exists anyway, in ONE place, so that a later shard which raises the
  // blob ceiling does not have to rediscover where the window is bounded
  PWEB_BLOB_MAX_WINDOW_BYTES = 8 * 1024 * 1024;

  /// the longest Range header value the translator will look at
  // - a header longer than this is not a range, it is a denial of
  // service with a colon in it
  PWEB_BLOB_MAX_RANGE_BYTES = 256;

  /// the one method the v1 plane serves
  PWEB_BLOB_ALLOW_HEADER = 'Allow: GET';

  /// the typed refusal a body-carrying request is answered with
  // - CAP-12A §6.2 ratifies `fetch(PUT pweb://...)` with a typed-array
  // body as the JS->native transport; CAP-12B builds and PROVES that
  // path on all three engines and wires no consumer onto it, because
  // the SDK upload API is CAP-12C's. So the request body is read to
  // completion - a body path that is never drained is a body path that
  // has never run - and then refused BY NAME, with the count and the
  // checksum of what actually arrived, so the refusal is a measurement
  // rather than a shrug
  PWEB_BLOB_UPLOAD_REFUSAL = 'blob_upload_not_enabled';

type
  /// what the translator decided about one request
  TPWebBlobOutcome = (
    /// not under the reserved prefix: the caller consults the asset store
    pboNotReserved,
    /// 200 or 206, Body carries the window
    pboServe,
    /// 404, a constant body and no detail whatsoever
    pboNotFound,
    /// 416, with `Content-Range: bytes */<total>`
    pboRangeNotSatisfiable,
    /// 405, with the typed upload refusal and what arrived
    pboMethodRefused);

  /// how a Range header was read
  TPWebRangeVerdict = (
    /// no Range header: the whole blob, 200
    prvAbsent,
    /// a single range or a suffix range: 206
    prvSingle,
    /// syntactically valid and unsatisfiable: 416
    prvUnsatisfiable,
    /// multi-range, or a syntax this plane does not implement: 200 whole
    prvIgnored);

  { One exchange, in and out. A record rather than eight parameters
    because three adapters fill it and one of them does so across a flat
    C seam. }
  TPWebBlobExchange = record
    // ---- what the adapter read from the request ----
    /// the canonical logical path PWebParseAppUri produced
    LogicalPath: RawUtf8;
    /// the request method, exact case; '' is read as GET
    Method: RawUtf8;
    /// the raw `Range` header value, or ''
    RangeHeader: RawUtf8;
    /// the principal this webview serves - NEVER taken from the page
    Owner: RawUtf8;
    /// how many request-body bytes the adapter actually read
    RequestBodyBytes: Int64;
    /// crc32c over those bytes, accumulated as they were read
    RequestBodyCrc: Cardinal;
    /// False when the adapter could not read the body to its end
    RequestBodyComplete: Boolean;
    // ---- what the translator decided ----
    Outcome: TPWebBlobOutcome;
    /// 200, 206, 404, 405 or 416
    Status: Integer;
    /// the reason phrase that goes with Status
    Reason: RawUtf8;
    /// from TBlobInfo.ContentType, never from the MIME table
    ContentType: RawUtf8;
    /// the window, materialised exactly once
    Body: RawByteString;
    /// `bytes first-last/total`, or `bytes * /total` on a 416; '' otherwise
    ContentRange: RawUtf8;
    /// send `Accept-Ranges: bytes`
    AcceptRanges: Boolean;
    /// extra response headers, CRLF-separated `Name: Value`, or ''
    ExtraHeaders: RawUtf8;
    /// the blob's whole size, for diagnostics and for the 416
    TotalSize: Int64;
    /// how the Range header was read - DIAGNOSTIC, and what the gates pin
    Range: TPWebRangeVerdict;
  end;

/// is this logical path inside the reserved runtime namespace
// - tested by every platform handler BEFORE the asset store, so no
// store - asset, folder or generation - can ever answer under it
// - the path is the CANONICAL one PWebParseAppUri produced: it has no
// leading slash, no empty segment and no query string
function PWebBlobIsReserved(const LogicalPath: RawUtf8): Boolean;

/// the token of a `_pweb/blob/<token>` path, or '' for anything else
function PWebBlobPathToken(const LogicalPath: RawUtf8): RawUtf8;

/// the URL a page reads one blob from, or '' for a malformed token
// - a producer hands this back; nothing else in the tree concatenates it
function PWebBlobUrl(const Token: RawUtf8): RawUtf8;

{ Read one `Range` header value against a known total.

  THE GRAMMAR, ratified by CAP-12B as ONE rule on four engines:

    bytes=a-b, bytes=a-, bytes=-suffix   -> prvSingle, answered 206
    anything with a comma (multi-range)  -> prvIgnored, answered 200 whole
    a syntax this plane does not read    -> prvIgnored, answered 200 whole
    valid syntax, nothing to send        -> prvUnsatisfiable, answered 416

  WHY MULTI-RANGE IS 200 AND NOT 416. RFC 7233 §3.1 lets an origin server
  ignore a Range it does not understand, and CAP-12A MEASURED "the
  handler answering 200 to a Range request" as honoured on both engines -
  it is part of the guaranteed surface. Answering 206 with only the first
  window would lie to the engine about what it asked for, and
  `multipart/byteranges` is a second body format this plane refuses to
  own. It is safe here for a reason that is itself a measurement: a blob
  is at most one window, so "the whole thing" is never more than the
  8 MiB §5.3 bounds a response to.

  WHY UNSATISFIABLE IS 416 AND NOT 200. An unsatisfiable range is a page
  BUG - it asked for bytes past the end - and a whole body in reply is
  indistinguishable from success. RFC 7233 §4.4 defines 416 for exactly
  this case and gives it `Content-Range: bytes * /<total>`, so the page
  learns the real size instead of guessing again. The difference from
  multi-range is not stylistic: one is a request this plane chooses not
  to implement, the other is a request that cannot be satisfied at all.

  A byte-range-spec whose first position is past the end, and a
  suffix-length of zero, are the two unsatisfiable forms. `a > b` is not
  one of them: RFC 7233 makes that spec INVALID, which invalidates the
  whole header, which is prvIgnored. }
function PWebBlobParseRange(const Raw: RawUtf8; Total: Int64;
  out First, Last: Int64): TPWebRangeVerdict;

/// translate one request against a store
// - returns False when the path is not reserved, in which case the
// caller carries on to the asset store exactly as it always did
// - never raises: the three callers are resource handlers, two of them
// behind a C frame a Pascal exception may not cross
function PWebBlobServe(const Store: IBlobStore;
  var Exchange: TPWebBlobExchange): Boolean;

/// the constant body every blob 404 carries
// - no path, no token, no reason detail: an unknown token, a foreign
// principal's token and a released token are ONE answer from outside
function PWebBlobNotFoundBody: RawByteString;

/// seal one whole buffer as a blob in one call
// - the shape every CAP-12B producer actually needs: it has the bytes, it
// wants a token. Create, append, seal and - on any refusal - abandon, with
// no producer left holding a writer it forgot to give back
// - it lives beside the translator rather than beside a store because a
// producer must never name an IMPLEMENTATION: the fetch door holds an
// IBlobStore and has no idea whether the bytes end up in memory or, one
// shard from now, in a file
// - Ceiling names which bound refused, or pbcNone
function PWebBlobPut(const Store: IBlobStore; const Owner: RawUtf8;
  const Content: RawByteString; const ContentType: RawUtf8;
  out Token: RawUtf8; out Ceiling: TPWebBlobCeiling): Boolean;

implementation

function PWebBlobIsReserved(const LogicalPath: RawUtf8): Boolean;
const
  N = Length(PWEB_BLOB_RESERVED_SEGMENT);
begin
  Result := False;
  if Length(LogicalPath) < N then
    exit;
  if not CompareMem(pointer(LogicalPath),
         PAnsiChar(PWEB_BLOB_RESERVED_SEGMENT), N) then
    exit;
  // `_pweb` exactly, or `_pweb/` followed by anything: a path that
  // merely STARTS with those five bytes - `_pwebbing/x` - is an ordinary
  // asset and must stay one
  Result := (Length(LogicalPath) = N) or
            (LogicalPath[N + 1] = '/');
end;

function PWebBlobPathToken(const LogicalPath: RawUtf8): RawUtf8;
const
  P = Length(PWEB_BLOB_PATH_PREFIX);
begin
  Result := '';
  if Length(LogicalPath) <> P + PWEB_BLOB_TOKEN_CHARS then
    exit; // exactly three segments, and the third is exactly 32 bytes
  if not CompareMem(pointer(LogicalPath),
         PAnsiChar(PWEB_BLOB_PATH_PREFIX), P) then
    exit;
  Result := Copy(LogicalPath, P + 1, PWEB_BLOB_TOKEN_CHARS);
  if not PWebBlobValidToken(Result) then
    Result := '';
end;

function PWebBlobUrl(const Token: RawUtf8): RawUtf8;
begin
  // a malformed token never becomes a URL: a producer that got one has a
  // defect, and handing the page a URL that can only 404 would hide it
  if PWebBlobValidToken(Token) then
    Result := PWEB_BLOB_URL_PREFIX + Token
  else
    Result := '';
end;

function PWebBlobNotFoundBody: RawByteString;
begin
  Result := 'not found';
end;

// one unsigned decimal, without pulling a formatting unit in
function U64(V: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(V));
end;

function PWebBlobParseRange(const Raw: RawUtf8; Total: Int64;
  out First, Last: Int64): TPWebRangeVerdict;
var
  s: RawUtf8;
  i, dash: PtrInt;
  lhs, rhs: RawUtf8;
  a, b: Int64;

  // strict unsigned decimal, bounded so it cannot overflow Int64
  function Num(const T: RawUtf8; out V: Int64): Boolean;
  var
    k: PtrInt;
  begin
    Result := False;
    V := 0;
    if (T = '') or
       (Length(T) > 18) then
      exit;
    for k := 1 to Length(T) do
    begin
      if not (T[k] in ['0'..'9']) then
        exit;
      V := V * 10 + (Ord(T[k]) - Ord('0'));
    end;
    Result := True;
  end;

begin
  First := 0;
  Last := -1;
  Result := prvAbsent;
  if Raw = '' then
    exit;
  Result := prvIgnored;
  if Length(Raw) > PWEB_BLOB_MAX_RANGE_BYTES then
    exit;
  // spaces are stripped, everything else is read exactly
  s := '';
  for i := 1 to Length(Raw) do
    if Raw[i] <> ' ' then
      s := s + Raw[i];
  if (Length(s) < 7) or
     not CompareMem(pointer(s), PAnsiChar('bytes='), 6) then
    exit; // a unit this plane does not understand - ignore the header
  s := Copy(s, 7, MaxInt);
  for i := 1 to Length(s) do
    if s[i] = ',' then
      exit; // multi-range: ignored, answered whole
  dash := 0;
  for i := 1 to Length(s) do
    if s[i] = '-' then
    begin
      if dash <> 0 then
        exit; // two dashes: not a byte-range-spec
      dash := i;
    end;
  if dash = 0 then
    exit;
  lhs := Copy(s, 1, dash - 1);
  rhs := Copy(s, dash + 1, MaxInt);
  if lhs = '' then
  begin
    // suffix range: the LAST b bytes
    if not Num(rhs, b) then
      exit;
    if (b = 0) or
       (Total <= 0) then
      exit(prvUnsatisfiable);
    if b > Total then
      b := Total;
    First := Total - b;
    Last := Total - 1;
    exit(prvSingle);
  end;
  if not Num(lhs, a) then
    exit;
  if rhs = '' then
    b := Total - 1
  else if not Num(rhs, b) then
    exit
  else if b < a then
    exit; // an invalid byte-range-spec invalidates the whole header
  if (Total <= 0) or
     (a > Total - 1) then
    exit(prvUnsatisfiable);
  if b > Total - 1 then
    b := Total - 1;
  First := a;
  Last := b;
  Result := prvSingle;
end;

function UploadReceipt(const Exchange: TPWebBlobExchange): RawByteString;
const
  HEX: array[0 .. 15] of AnsiChar = '0123456789abcdef';
  JSON_BOOL: array[Boolean] of RawUtf8 = ('false', 'true');
var
  crc: RawUtf8;
  i: Integer;
  v: Cardinal;
begin
  SetLength(crc, 8);
  v := Exchange.RequestBodyCrc;
  for i := 7 downto 0 do
  begin
    crc[i + 1] := HEX[v and 15];
    v := v shr 4;
  end;
  // THE BYTES ARE NAMED, NOT THE PAYLOAD. What comes back is how many
  // bytes arrived and a checksum of them - enough for a page to prove
  // its upload crossed intact, and nothing a page did not already have.
  Result := RawByteString('{"error":"' + PWEB_BLOB_UPLOAD_REFUSAL +
    '","method":' + AnsiQuotedStr(Exchange.Method, '"') +
    ',"requestBodyBytes":' + U64(Exchange.RequestBodyBytes) +
    ',"requestBodyCrc32c":"' + crc +
    '","requestBodyComplete":' + JSON_BOOL[Exchange.RequestBodyComplete] + '}');
end;

function PWebBlobServe(const Store: IBlobStore;
  var Exchange: TPWebBlobExchange): Boolean;
var
  token: RawUtf8;
  reader: IBlobReader;
  info: TBlobInfo;
  first, last, count: Int64;
  got: Integer;
  method: RawUtf8;
begin
  Result := False;
  Exchange.Outcome := pboNotReserved;
  Exchange.Status := 0;
  Exchange.Reason := '';
  Exchange.ContentType := '';
  Exchange.Body := '';
  Exchange.ContentRange := '';
  Exchange.AcceptRanges := False;
  Exchange.ExtraHeaders := '';
  Exchange.TotalSize := 0;
  Exchange.Range := prvAbsent;
  try
    if not PWebBlobIsReserved(Exchange.LogicalPath) then
      exit;
    // FROM HERE THE ANSWER IS THIS UNIT'S, whatever happens: the caller
    // must not fall through to a store, because the whole point of the
    // reservation is that nothing else may answer under this prefix.
    Result := True;
    Exchange.Outcome := pboNotFound;
    Exchange.Status := 404;
    Exchange.Reason := 'Not Found';
    Exchange.ContentType := 'text/plain; charset=utf-8';
    Exchange.Body := PWebBlobNotFoundBody;

    method := Exchange.Method;
    if method = '' then
      method := 'GET';
    if method <> 'GET' then
    begin
      // The body was already read by the adapter, on purpose. See
      // PWEB_BLOB_UPLOAD_REFUSAL.
      Exchange.Outcome := pboMethodRefused;
      Exchange.Status := 405;
      Exchange.Reason := 'Method Not Allowed';
      Exchange.ContentType := 'application/json; charset=utf-8';
      Exchange.ExtraHeaders := PWEB_BLOB_ALLOW_HEADER;
      Exchange.Body := UploadReceipt(Exchange);
      exit;
    end;

    token := PWebBlobPathToken(Exchange.LogicalPath);
    if (token = '') or
       (Store = nil) or
       (Exchange.Owner = '') or
       not Store.OpenBlob(Exchange.Owner, token, reader) or
       (reader = nil) or
       not reader.Info(info) then
      exit; // the 404 above, unchanged and detail-free
    Exchange.TotalSize := info.Size;
    Exchange.ContentType := info.ContentType;
    Exchange.AcceptRanges := True;

    Exchange.Range := PWebBlobParseRange(Exchange.RangeHeader, info.Size,
      first, last);
    case Exchange.Range of
      prvUnsatisfiable:
        begin
          Exchange.Outcome := pboRangeNotSatisfiable;
          Exchange.Status := 416;
          Exchange.Reason := 'Range Not Satisfiable';
          Exchange.ContentType := 'text/plain; charset=utf-8';
          Exchange.Body := 'range not satisfiable';
          Exchange.ContentRange := 'bytes */' + U64(info.Size);
          // ACCEPT-RANGES STAYS ON A 416, deliberately. What was wrong was
          // the range, not the capability: the resource IS rangeable, and a
          // 416 that withdrew the advertisement would tell a page to stop
          // trying rather than to try a range that exists. The
          // Content-Range above gives it the length it needs to compute one.
          exit;
        end;
      prvSingle:
        begin
          count := last - first + 1;
          if count > PWEB_BLOB_MAX_WINDOW_BYTES then
          begin
            // a shorter 206 than was asked for is a legal 206: the
            // Content-Range below reports what was actually sent
            count := PWEB_BLOB_MAX_WINDOW_BYTES;
            last := first + count - 1;
          end;
          Exchange.Outcome := pboServe;
          Exchange.Status := 206;
          Exchange.Reason := 'Partial Content';
          Exchange.ContentRange := 'bytes ' + U64(first) + '-' + U64(last) +
            '/' + U64(info.Size);
        end;
    else
      begin
        // prvAbsent and prvIgnored are the same answer, and that is the
        // ratified rule rather than a shortcut
        first := 0;
        count := info.Size;
        if count > PWEB_BLOB_MAX_WINDOW_BYTES then
          count := PWEB_BLOB_MAX_WINDOW_BYTES;
        Exchange.Outcome := pboServe;
        Exchange.Status := 200;
        Exchange.Reason := 'OK';
      end;
    end;

    if count < 0 then
      count := 0;
    if count > 0 then
    begin
      SetLength(Exchange.Body, count);
      got := reader.ReadAt(first, pointer(Exchange.Body), Integer(count));
      if got <> count then
      begin
        // a short or failed read is NOT a short body: the plane would
        // rather answer 404 than hand the page a truncated resource it
        // has no way to detect
        Exchange.Outcome := pboNotFound;
        Exchange.Status := 404;
        Exchange.Reason := 'Not Found';
        Exchange.ContentType := 'text/plain; charset=utf-8';
        Exchange.ContentRange := '';
        Exchange.AcceptRanges := False;
        Exchange.Body := PWebBlobNotFoundBody;
      end;
    end;
  except
    // fail closed, and never across the caller's C frame
    Result := True;
    Exchange.Outcome := pboNotFound;
    Exchange.Status := 404;
    Exchange.Reason := 'Not Found';
    Exchange.ContentType := 'text/plain; charset=utf-8';
    Exchange.Body := PWebBlobNotFoundBody;
    Exchange.ContentRange := '';
    Exchange.AcceptRanges := False;
  end;
end;

{ ---- the one-call producer helper ---- }

function PWebBlobPut(const Store: IBlobStore; const Owner: RawUtf8;
  const Content: RawByteString; const ContentType: RawUtf8;
  out Token: RawUtf8; out Ceiling: TPWebBlobCeiling): Boolean;
var
  writer: IBlobWriter;
  bounds: IBlobBounds;
begin
  Token := '';
  Ceiling := pbcNone;
  Result := False;
  if Store = nil then
  begin
    Ceiling := pbcClosed;
    exit;
  end;
  // the typed create when the store offers one, the ratified create
  // otherwise - a store that carries only IBlobStore still works, it
  // just cannot say which ceiling refused
  if Supports(Store, IBlobBounds, bounds) then
  begin
    if not bounds.CreateBlobTyped(Owner, Length(Content), writer, Ceiling) then
      exit;
  end
  else if not Store.CreateBlob(Owner, Length(Content), writer) then
  begin
    Ceiling := pbcClosed;
    exit;
  end;
  try
    if (Content <> '') and
       not writer.Append(pointer(Content), Length(Content)) then
    begin
      Ceiling := pbcBlobBytes;
      writer.Abandon;
      exit;
    end;
    if not writer.Seal(ContentType, Token) then
    begin
      Ceiling := pbcClosed;
      writer.Abandon;
      exit;
    end;
    Result := True;
  finally
    writer := nil;
  end;
end;

end.
