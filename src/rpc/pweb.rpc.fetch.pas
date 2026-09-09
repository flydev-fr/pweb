{
  pweb.rpc.fetch - the native outbound network door (CAP-15B).

  ONE runtime-owned method, `pweb.fetch`, behind the `network.fetch`
  capability and a native, per-application origin allowlist compiled into the
  host. The frontend never opens a socket; the runtime does, per invocation,
  under the capability policy that is already in the path.

  ---------------------------------------------------------------------------
  WHY THIS UNIT EXISTS, AND WHY IT IS NOT A CSP
  ---------------------------------------------------------------------------

  CAP-15A built BOTH candidate doors and measured them on the same page, in
  the same window, on every engine it could reach. Door B - widening
  `connect-src` per application - works, and it works DIFFERENTLY on each
  engine in the one place a threat model cannot tolerate ambiguity: WebKitGTK
  stores and re-sends the remote origin's cookies, including on a `no-cors`
  POST the page cannot read and the runtime cannot see; WebView2 sends none.
  A named origin is also a complete, uninspectable exfiltration channel -
  measured: `no-cors` POST and `sendBeacon` delivered their bodies to a
  server sending no CORS headers at all, with no per-call gate and no native
  record. And it reaches only servers TAUGHT about PWeb, because the `Origin`
  it presents is the literal `pweb://app`.

  So `PWEB_NATIVE_CSP` does not change. `connect-src` stays `'self'`, byte
  for byte, in development and production, on all four targets. The door is
  here instead, where every request passes the runtime: method, URL, headers
  and body size are natively visible and refusable, the call is authorized
  per invocation, and the capability can be revoked at runtime.

  The decision, the threat model and every measured row are
  `_bmad-output/implementation-artifacts/cap15a-decision-artifact.md` and
  `cap15a-measurements.md`; `docs/cli-contract.md` §5 carries it publicly.

  ---------------------------------------------------------------------------
  THE SHAPE, AND WHAT IT DELIBERATELY IS NOT
  ---------------------------------------------------------------------------

    invocation
      -> IInvocationSource.TryEnqueue        (frozen)
      -> scheduler worker                    (frozen)
      -> ICapabilityPolicy at the ONE call site (frozen; authoritative)
      -> TPWebFetchBridge                    (this unit)
           pweb.fetch    -> validate -> injected transport -> envelope
           anything else -> FInner.Invoke, verbatim
      -> the runtime-command decorator / the application / mORMot

  An IInvocationBridge DECORATOR and nothing else, in the exact shape of
  `pweb.rpc.command.pas`: no eighth interface, no second RPC path, no new
  scheduler hook, no listening socket, and NO AUTHORIZATION HERE - CAP-8A's
  policy already ran at the scheduler, before the bridge. A principal without
  `network.fetch` was answered forbidden/403 and never reached this code, so
  the transport count for such a principal is zero because nothing ran.

  THE TRANSPORT IS INJECTED, exactly as `pweb.rpc.command` injects the
  platform opener. That is what carries the whole design:

    - this unit names no `mormot.net.*` unit, carries no compiler
      conditional and names
      no operating system, so the CAP-7F divergence sweep holds it at zero
      conditionals forever;
    - a headless test drives the WHOLE door - grammar, allowlist, bounds,
      deadline, envelope - with no socket anywhere;
    - Darwin supplies an `NSURLSession` transport from the adapter layer
      without touching one line of the decision, which is why "exactly one
      file names mormot.net.client" survives a second platform.

  FAIL CLOSED. The constructor refuses a nil inner bridge, a nil transport,
  and an origin the grammar does not accept - the compiled allowlist is
  parsed ONCE, at startup, by the same parser every request URL goes through,
  so a malformed generated literal is a loud startup failure and never a
  runtime surprise.

  ---------------------------------------------------------------------------
  WHERE THE LOOPBACK EXCEPTION IS, AND WHY IT IS NOT HERE
  ---------------------------------------------------------------------------

  The ratified development exception - an http origin whose host is a
  loopback name, with an explicit port and never a wildcard - is a
  property of WHAT IS COMPILED INTO THE ALLOWLIST, not of how the allowlist
  is compared. The descriptor accepts such an origin (a developer really does
  run their API on loopback), `pweb doctor` reports it BY NAME as
  development-only, and a RELEASE `pweb build` REFUSES it by name rather than
  dropping it silently.

  So this unit carries NO `PWEB_DEV` region at all. It names the two
  loopback hosts in exactly one place - the origin grammar, which is what
  ACCEPTS them - and nowhere else; it carries no full loopback origin
  literal; and it compares scheme, host and port, so an http origin can only
  ever match an http request because the scheme is part of the comparison.

  That is strictly stronger than a conditional, because there is no branch
  to compile in by accident, and it moves the proof to where it belongs:
  what a RELEASE image carries. `test/cap15b` sweeps the built release image
  for a loopback ORIGIN and finds none, and - because a negative check whose
  firing was never observed proves nothing - it runs the identical sweep
  over a DEV image that carries one by design and REQUIRES it to fire.

  Called on a scheduler WORKER thread, never the GUI thread. Concurrent
  Invoke calls share no mutable state here; the allowlist is immutable after
  construction.
}
unit pweb.rpc.fetch;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.json,
  mormot.crypt.core,
  pweb.rpc.intf,
  pweb.rpc.support;

const
  { The canonical fetch method, spelled ONCE for the whole repository. It
    lives in the reserved pweb.* namespace because it is runtime-owned, not
    application surface - which is also why the frozen bridge answers
    method_not_found for it and why it is intercepted here. }
  PWEB_METHOD_FETCH = 'pweb.fetch';

  { The capability that authorizes it, spelled ONCE. The mapping
    pweb.fetch -> network.fetch is applied by the HOST's policy
    configuration, never by this unit. }
  PWEB_CAP_NETWORK_FETCH = 'network.fetch';

  { --- the ratified bounds (cap15a-decision-artifact.md §2, §4, §5) ------ }

  /// at most eight declared origins - an API, an auth host, a CDN and
  // telemetry with room. An unbounded list is an unbounded surface for a
  // reviewer to read
  PWEB_FETCH_MAX_ORIGINS = 8;

  /// longest canonical origin, in bytes: 'https://' (8) + a 253-byte host
  // + ':65535' (6) = 267
  // - CAP-15B AMENDMENT. §2 ratified 262 and derived it as
  // "'https://' + a 253-byte host + ':65535'", which is 267: 262 is the
  // colon without its port digits. The bound as ratified would have refused
  // a maximum-length host carrying an explicit port - the exact case its own
  // parenthesis says it must hold - so the shard ships the arithmetic
  PWEB_FETCH_MAX_ORIGIN_BYTES = 267;

  /// longest request URL, in bytes
  // - the same ceiling PWEB_EXTERNAL_URI_MAX_BYTES applies to a URI handed
  // to the operating system: an unbounded request target is as unbounded as
  // an unbounded header, and §4 bounds neither by name
  PWEB_FETCH_MAX_URL_BYTES = 2048;

  /// at most sixteen request headers
  PWEB_FETCH_MAX_HEADERS = 16;

  /// longest single request-header value, in bytes
  // - §4 bounds the header COUNT and not the value size; an unbounded value
  // is an unbounded request, so the shard states one
  PWEB_FETCH_MAX_HEADER_BYTES = 4096;

  /// request body ceiling: JSON is the control plane, bulk is CAP-12's blob
  // plane
  PWEB_FETCH_MAX_REQUEST_BODY = 1 shl 20;         // 1 MiB

  /// response ceiling, enforced on Content-Length AND on the running total
  // DURING the read - never after it (measured defect 15A-6)
  PWEB_FETCH_MAX_RESPONSE = 8 shl 20;             // 8 MiB

  /// inline text ceiling, for a body that is valid UTF-8
  PWEB_FETCH_MAX_TEXT_INLINE = 1 shl 20;          // 1 MiB

  /// inline base64 ceiling, for a body that is not
  // - CAP-15B AMENDMENT: §5 says "base64 with a smaller cap" and never says
  // which. 768 KiB encodes to exactly 786432 * 4 / 3 = 1048576 bytes with no
  // padding, so both caps produce the same maximum envelope - which is the
  // property that made §5 want a smaller number in the first place
  PWEB_FETCH_MAX_BASE64_INLINE = 786432;          // 768 KiB

  /// the wall-clock TOTAL-REQUEST deadline, owned by the runtime
  // - a socket timeout is not a deadline: it is per-READ, and a response
  // that dribbles resets it on every read (measured defect 15A-5)
  PWEB_FETCH_DEFAULT_DEADLINE_MS = 10000;
  PWEB_FETCH_MAX_DEADLINE_MS = 30000;

  /// the typed service_error categories this door can answer with
  // - `service_error.data` is the only sanctioned application-defined
  // domain-error channel; the nine-code taxonomy is unchanged
  PWEB_FETCH_CAT_TOO_LARGE = 'response_too_large';
  PWEB_FETCH_CAT_NO_INLINE = 'response_too_large_to_inline';
  PWEB_FETCH_CAT_TRANSPORT = 'transport_failed';

type
  /// raised only for direct misuse of this API at construction time
  // - the fetch path itself never raises across a bridge call
  EPWebFetch = class(Exception);

  /// one origin, as PARSED COMPONENTS - never as a string to prefix-test
  // - Port is always CANONICAL: an absent port is the scheme default, so
  // https://api.example.com and https://api.example.com:443 are one origin
  TPWebFetchOrigin = record
    Scheme: RawUtf8;   // 'https' or 'http', lowercase, exact
    Host: RawUtf8;     // lowercase, ASCII, punycode spelling for an IDN
    Port: Integer;     // 1..65535, canonical
  end;
  TPWebFetchOrigins = array of TPWebFetchOrigin;

  /// what the decorator hands a transport - already validated, already
  /// parsed, and never to be re-parsed
  // - Url is the exact original request target; Scheme/Host/Port/Target are
  // the parsed components. A transport uses whichever its API needs, and
  // NEITHER of them re-derives the other: one parser, one truth
  TPWebFetchRequest = record
    Url: RawUtf8;
    Method: RawUtf8;        // GET POST PUT PATCH DELETE HEAD, exact case
    Scheme: RawUtf8;
    Host: RawUtf8;
    Port: Integer;
    Https: Boolean;
    Target: RawUtf8;        // path + query, always starting with '/'
    Headers: RawUtf8;       // CRLF-separated `Name: Value` lines, or ''
    Mime: RawUtf8;          // the content-type value, or ''
    Body: RawByteString;
    /// the wall-clock total-request deadline, in milliseconds
    DeadlineMs: Integer;
    /// the ceiling the transport must enforce DURING the read
    MaxResponseBytes: PtrInt;
  end;

  /// what a transport hands back
  TPWebFetchResponse = record
    Status: Integer;
    /// the raw response header block, CRLF-separated `Name: Value` lines
    // - the decorator owns the allowlist; a transport never filters
    Headers: RawUtf8;
    Body: RawByteString;
    /// how many body bytes were observed, which may exceed Length(Body)
    /// when the read was refused at the bound
    Bytes: Int64;
    /// wall-clock milliseconds the exchange took
    // - THE TRANSPORT OWNS THE CLOCK, and that is why this field exists
    // rather than a GetTickCount64 in the decorator: the transport already
    // has to hold a monotonic deadline to slice its reads against, and one
    // clock is one answer. It also keeps this unit free of mormot.core.os,
    // which is what "names no operating system" means when it is a property
    // of the uses clause rather than a promise
    Ms: Integer;
  end;

  /// how one transport attempt ended - a CATEGORY, never a native detail
  TPWebFetchOutcome = (
    /// the exchange completed; Status/Headers/Body are meaningful
    pfoOk,
    /// the wall-clock deadline expired during the exchange
    pfoTimedOut,
    /// the cancellation token was observed during the exchange
    pfoCancelled,
    /// the response crossed MaxResponseBytes and the read was stopped
    pfoTooLarge,
    /// anything else: connect, TLS, protocol, or a refused encoding
    pfoTransport);

  { The injected transport. A PLAIN FUNCTION TYPE, exactly like
    TPWebExternalOpener - not an interface, because the kernel's seven frozen
    boundaries are seven and a door does not need an eighth.

    Contract for an implementation:
      - it opens ONE connection, issues ONE request, and follows NO redirect;
      - it keeps no cookie jar, honours no Set-Cookie and sends no Cookie;
      - it retries NOTHING, ever;
      - it inherits no proxy;
      - it validates the server certificate and offers no way not to;
      - it observes Token AND the deadline DURING the transfer, not only
        before it - a blocking read cannot see either, so it reads in bounded
        slices and checks between them;
      - it stops reading at MaxResponseBytes rather than after it;
      - it MUST NOT raise: every failure is one of the outcomes above. }
  TPWebFetchTransport = function(const Request: TPWebFetchRequest;
    const Token: ICancellationToken;
    out Response: TPWebFetchResponse): TPWebFetchOutcome;

  /// what one fetch attempt did, for the host's own accounting
  TPWebFetchDecision = (
    /// refused before any transport activity of any kind
    pfdRefused,
    /// the transport was reached and the exchange completed
    pfdCompleted,
    /// the transport was reached and did not complete
    pfdFailed);

  { The host's private observation hook: logging in the production hosts,
    counters in the gate harnesses. It DECIDES nothing - it is called after
    the outcome is settled and its result is ignored.

    UrlBytes is the byte LENGTH of the requested URL, never the URL: the
    redaction contract is that neither the query string nor the host reaches
    a log or a counter. }
  TPWebFetchObserver = procedure(const Context: TInvocationContext;
    Decision: TPWebFetchDecision; UrlBytes, ResponseBytes: PtrInt);

  { The reusable outbound-network decorator. }
  TPWebFetchBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    FTransport: TPWebFetchTransport;
    FObserver: TPWebFetchObserver;
    FOrigins: TPWebFetchOrigins;
    function Fetch(const Context: TInvocationContext; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    function Refuse(const Context: TInvocationContext;
      ACode: TPWebErrorCode; const AMessage: Utf8String;
      UrlBytes: PtrInt): TPWebInvocationResult;
  public
    { Fail closed: a nil inner bridge, a nil transport or an origin the
      grammar refuses all raise here, at startup, rather than becoming a
      runtime surprise. AOrigins is the CANONICAL set the build compiled in;
      an empty set is legal only in the sense that a host with no origins
      does not install this decorator at all (build-contract §7.5). }
    constructor Create(const AInner: IInvocationBridge;
      ATransport: TPWebFetchTransport; const AOrigins: array of RawUtf8;
      AObserver: TPWebFetchObserver = nil);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    /// the compiled allowlist, canonical and sorted - what the host reports
    // so that "declared == compiled" is measured at the bytes
    function AllowlistDigest: RawUtf8;
  end;

/// the ONE origin grammar of this product, shared by the descriptor reader,
/// the doctor, the build refusal and this decorator
// - scheme + lowercase host + optional `:port`, and NOTHING else: no path,
// query or fragment, no userinfo, no `*`, no wildcard label, no trailing
// dot, no uppercase, no IDN (punycode is the accepted spelling), no IPv6
// literal, no byte >= $80
// - `https` always; `http` ONLY for the loopback hosts 127.0.0.1 and
// localhost and ONLY with an explicit port. Whether such an origin may reach
// a RELEASE image is a build question, not a grammar question - see
// PWebFetchOriginIsLoopbackHttp
// - Origin.Port is canonical on success: an absent port becomes the scheme
// default, so declaring both spellings is a duplicate
function PWebFetchParseOrigin(const Text: RawUtf8;
  out Origin: TPWebFetchOrigin): Boolean;

/// the canonical spelling of a parsed origin - the DEFAULT PORT IS DROPPED
// - this is the form the byte bound is measured on, the form the duplicate
// check compares, and the form the compiled literal carries
function PWebFetchOriginText(const Origin: TPWebFetchOrigin): RawUtf8;

/// are these the same origin? BY PARSED COMPONENTS, never by prefix
function PWebFetchSameOrigin(const A, B: TPWebFetchOrigin): Boolean;

/// is this the ratified development-only loopback exception?
// - `http` with host 127.0.0.1 or localhost. A release `pweb build` refuses
// such an origin BY NAME rather than dropping it, and `pweb doctor` reports
// it by name long before a build refuses on it
function PWebFetchOriginIsLoopbackHttp(const Origin: TPWebFetchOrigin): Boolean;

/// the allowlist digest: sha256 over the canonical origin texts, sorted,
/// one per line, each line LF-terminated
// - computed from `pweb.json` by the build and again from the COMPILED array
// by the host, so "the production carries exactly the declared set" is a
// measurement rather than a promise. An empty set has its own digest, which
// is the digest of the empty string
function PWebFetchAllowlistDigest(const Origins: TPWebFetchOrigins): RawUtf8;

type
  /// why a declared origin set was refused - one cause each, so a caller can
  /// map them onto its own machine-stable diagnostics
  TPWebFetchOriginsRefusal = (
    pforNone,
    /// more than PWEB_FETCH_MAX_ORIGINS entries
    pforCount,
    /// an entry the grammar does not accept
    pforGrammar,
    /// two entries that are the same origin after canonicalization
    pforDuplicate);

/// the allowlist digest of a COMPILED origin literal, recomputed from the
/// array the host carries
// - the generated host prints this beside APP_NETWORK_ALLOWLIST_DIGEST, and
// the build proof compares both with the digest computed from pweb.json. So
// descriptor -> generated include -> compiled array is closed at the bytes
// rather than at each step's good intentions
// - '' when the literal is not one this grammar accepts, which cannot
// happen for a set the constructor already refused to start without
function PWebFetchDeclaredDigest(const Origins: array of RawUtf8): RawUtf8;

/// parse and canonicalize a set of declared origins
// - applies the count bound, then the grammar (which carries the byte
// bound), then the duplicate refusal, and returns the sorted canonical set
// - Detail names the origin that failed, never a machine path
function PWebFetchParseOrigins(const Text: array of RawUtf8;
  out Origins: TPWebFetchOrigins; out Refusal: TPWebFetchOriginsRefusal;
  out Detail: RawUtf8): Boolean;

implementation

{ ---------------------------------------------------------------------------
  the origin grammar - ONE parser, used by the descriptor and by every URL
  --------------------------------------------------------------------------- }

function AsciiLower(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A' .. 'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function DefaultPortOf(const Scheme: RawUtf8): Integer;
begin
  if Scheme = 'https' then
    Result := 443
  else
    Result := 80;
end;

// a host label set that admits punycode and refuses everything a
// look-alike attack needs: no uppercase, no underscore, no wildcard, no
// empty label, no leading or trailing hyphen, no trailing dot
function ValidHost(const Host: RawUtf8): Boolean;
var
  i, labelLen: PtrInt;
  c: AnsiChar;
begin
  Result := False;
  if (Length(Host) < 1) or
     (Length(Host) > 253) then
    exit;
  labelLen := 0;
  for i := 1 to Length(Host) do
  begin
    c := Host[i];
    if c = '.' then
    begin
      if labelLen = 0 then
        exit; // empty label, a leading dot, or '..'
      if Host[i - 1] = '-' then
        exit; // a label may not end on a hyphen
      labelLen := 0;
      continue;
    end;
    if not (c in ['a' .. 'z', '0' .. '9', '-']) then
      exit;
    if (labelLen = 0) and
       (c = '-') then
      exit; // a label may not start on a hyphen
    Inc(labelLen);
    if labelLen > 63 then
      exit;
  end;
  if labelLen = 0 then
    exit; // a trailing dot
  Result := Host[Length(Host)] <> '-';
end;

function ParsePort(const Text: RawUtf8; out Port: Integer): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  Port := 0;
  if (Length(Text) < 1) or
     (Length(Text) > 5) then
    exit;
  if (Length(Text) > 1) and
     (Text[1] = '0') then
    exit; // no leading zero: '080' and '80' must not both spell one port
  for i := 1 to Length(Text) do
  begin
    if not (Text[i] in ['0' .. '9']) then
      exit;
    Port := Port * 10 + (Ord(Text[i]) - Ord('0'));
  end;
  Result := (Port >= 1) and (Port <= 65535);
end;

// every byte a URL or an origin may not carry, checked BEFORE anything is
// parsed: controls (CR, LF, NUL included), DEL, space, the quoting and
// bracket characters, the backslash, and every byte >= $80. A request target
// is as splittable as a header value, and the CAP-15A spike checked only the
// headers
function HasForbiddenBytes(const S: RawUtf8): Boolean;
var
  i: PtrInt;
  c: AnsiChar;
begin
  Result := True;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c <= ' ') or
       (c = #127) or
       (Ord(c) >= $80) or
       (c = '"') or (c = '<') or (c = '>') or (c = '\') or
       (c = '^') or (c = '`') or (c = '{') or (c = '}') or (c = '|') then
      exit;
  end;
  Result := False;
end;

// split `scheme://authority` and return the authority plus what follows it.
// The authority ends at the FIRST '/', '?' or '#' - the RFC 3986 grammar,
// never a substring guess
function SplitScheme(const Text: RawUtf8; out Scheme, Authority,
  Rest: RawUtf8): Boolean;
var
  i, start: PtrInt;
begin
  Result := False;
  Scheme := '';
  Authority := '';
  Rest := '';
  i := Pos('://', Text);
  if i <= 1 then
    exit;
  Scheme := Copy(Text, 1, i - 1);
  // the scheme is compared EXACTLY: this product spells it lowercase and a
  // request that does not is refused rather than normalised
  if (Scheme <> 'https') and
     (Scheme <> 'http') then
    exit;
  start := i + 3;
  i := start;
  while (i <= Length(Text)) and
        not (Text[i] in ['/', '?', '#']) do
    Inc(i);
  if i = start then
    exit; // an empty authority: 'https:///x' invites a launcher to invent one
  Authority := Copy(Text, start, i - start);
  Rest := Copy(Text, i, MaxInt);
  Result := True;
end;

// one authority into host + port. Userinfo and IPv6 literals are refused
// here rather than resolved: `https://api.example.com@evil.example/` is the
// classic way to make an undeclared origin read as a declared one
function SplitAuthority(const Authority, Scheme: RawUtf8;
  out Host: RawUtf8; out Port: Integer): Boolean;
var
  colon: PtrInt;
begin
  Result := False;
  Host := '';
  Port := 0;
  if Pos('@', Authority) > 0 then
    exit;
  if (Pos('[', Authority) > 0) or
     (Pos(']', Authority) > 0) then
    exit; // an IPv6 literal is not in the ratified grammar
  colon := Pos(':', Authority);
  if colon = 0 then
  begin
    Host := Authority;
    Port := DefaultPortOf(Scheme);
  end
  else
  begin
    Host := Copy(Authority, 1, colon - 1);
    if not ParsePort(Copy(Authority, colon + 1, MaxInt), Port) then
      exit;
  end;
  if Pos(':', Host) > 0 then
    exit; // a second colon is not a port
  Result := ValidHost(Host);
end;

function PWebFetchParseOrigin(const Text: RawUtf8;
  out Origin: TPWebFetchOrigin): Boolean;
var
  scheme, authority, rest, host: RawUtf8;
  port: Integer;
begin
  Result := False;
  Origin := Default(TPWebFetchOrigin);
  if (Text = '') or
     (Length(Text) > PWEB_FETCH_MAX_ORIGIN_BYTES) then
    exit;
  if HasForbiddenBytes(Text) then
    exit;
  if not SplitScheme(Text, scheme, authority, rest) then
    exit;
  // an ORIGIN is scheme + host + port and nothing else: a path, a query, a
  // fragment or even a bare trailing slash is a different kind of thing and
  // is refused rather than trimmed
  if rest <> '' then
    exit;
  if not SplitAuthority(authority, scheme, host, port) then
    exit;
  // the declared spelling is lowercase, exactly: the descriptor is
  // developer-controlled build metadata, so it can be required to be
  // canonical rather than normalised on the developer's behalf
  if host <> AsciiLower(host) then
    exit;
  if scheme = 'http' then
    // the ratified development exception, and its whole shape: loopback
    // only, and never without an explicit port
    if ((host <> '127.0.0.1') and (host <> 'localhost')) or
       (Pos(':', authority) = 0) then
      exit;
  Origin.Scheme := scheme;
  Origin.Host := host;
  Origin.Port := port;
  Result := True;
end;

function PWebFetchOriginText(const Origin: TPWebFetchOrigin): RawUtf8;
begin
  Result := Origin.Scheme + '://' + Origin.Host;
  if Origin.Port <> DefaultPortOf(Origin.Scheme) then
    Result := Result + ':' + RawUtf8(IntToStr(Origin.Port));
end;

function PWebFetchSameOrigin(const A, B: TPWebFetchOrigin): Boolean;
begin
  Result := (A.Port = B.Port) and
            (A.Scheme = B.Scheme) and
            (A.Host = B.Host);
end;

function PWebFetchOriginIsLoopbackHttp(const Origin: TPWebFetchOrigin): Boolean;
begin
  Result := (Origin.Scheme = 'http') and
            ((Origin.Host = '127.0.0.1') or (Origin.Host = 'localhost'));
end;

function PWebFetchAllowlistDigest(const Origins: TPWebFetchOrigins): RawUtf8;
var
  i: PtrInt;
  text: RawUtf8;
begin
  text := '';
  for i := 0 to High(Origins) do
    text := text + PWebFetchOriginText(Origins[i]) + #10;
  Result := LowerCaseU(Sha256(text));
end;

function PWebFetchDeclaredDigest(const Origins: array of RawUtf8): RawUtf8;
var
  parsed: TPWebFetchOrigins;
  refusal: TPWebFetchOriginsRefusal;
  detail: RawUtf8;
begin
  if PWebFetchParseOrigins(Origins, parsed, refusal, detail) then
    Result := PWebFetchAllowlistDigest(parsed)
  else
    Result := '';
end;

function PWebFetchParseOrigins(const Text: array of RawUtf8;
  out Origins: TPWebFetchOrigins; out Refusal: TPWebFetchOriginsRefusal;
  out Detail: RawUtf8): Boolean;
var
  i, j, n: PtrInt;
  one: TPWebFetchOrigin;
  swap: TPWebFetchOrigin;
begin
  Result := False;
  Origins := nil;
  Detail := '';
  Refusal := pforNone;
  if Length(Text) > PWEB_FETCH_MAX_ORIGINS then
  begin
    Refusal := pforCount;
    Detail := RawUtf8(IntToStr(Length(Text)));
    exit;
  end;
  SetLength(Origins, Length(Text));
  n := 0;
  for i := 0 to High(Text) do
  begin
    if not PWebFetchParseOrigin(Text[i], one) then
    begin
      Refusal := pforGrammar;
      Detail := Text[i];
      Origins := nil;
      exit;
    end;
    // the duplicate check runs AFTER canonicalization, so
    // https://a.example and https://a.example:443 are caught as the one
    // origin they are
    for j := 0 to n - 1 do
      if PWebFetchSameOrigin(Origins[j], one) then
      begin
        Refusal := pforDuplicate;
        Detail := PWebFetchOriginText(one);
        Origins := nil;
        exit;
      end;
    Origins[n] := one;
    Inc(n);
  end;
  // sorted by canonical text, so the digest is a function of the SET and
  // never of the order somebody typed it in
  for i := 1 to n - 1 do
    for j := 0 to n - 2 do
      if PWebFetchOriginText(Origins[j]) > PWebFetchOriginText(Origins[j + 1]) then
      begin
        swap := Origins[j];
        Origins[j] := Origins[j + 1];
        Origins[j + 1] := swap;
      end;
  Result := True;
end;

{ ---------------------------------------------------------------------------
  the request grammar
  --------------------------------------------------------------------------- }

// the request URL: the same parser as the declared origin, plus the target.
// The host is ASCII-lowercased for COMPARISON - DNS is case-insensitive and
// every engine already applies that before a hook sees a URI - while the
// DECLARED side stays canonical-only, so a case variant can match a declared
// origin and can never conjure an undeclared one
function ParseRequestUrl(const Url: RawUtf8; out Origin: TPWebFetchOrigin;
  out Target: RawUtf8): Boolean;
var
  scheme, authority, rest, host: RawUtf8;
  port: Integer;
begin
  Result := False;
  Origin := Default(TPWebFetchOrigin);
  Target := '';
  if (Url = '') or
     (Length(Url) > PWEB_FETCH_MAX_URL_BYTES) then
    exit;
  // BEFORE parsing, and over the WHOLE url rather than only the headers
  if HasForbiddenBytes(Url) then
    exit;
  if not SplitScheme(Url, scheme, authority, rest) then
    exit;
  // a fragment is never sent and has no meaning in a request target; a
  // request carrying one is confused rather than convenient, and this door
  // refuses it instead of silently trimming it
  if Pos('#', rest) > 0 then
    exit;
  if not SplitAuthority(AsciiLower(authority), scheme, host, port) then
    exit;
  Origin.Scheme := scheme;
  Origin.Host := host;
  Origin.Port := port;
  if rest = '' then
    Target := '/'
  else
    Target := rest;
  Result := True;
end;

function ValidMethod(const Method: RawUtf8): Boolean;
begin
  // EXACT and case-sensitive: `patch` is not `PATCH`, and normalising it
  // would be this layer inventing an intent
  Result := (Method = 'GET') or (Method = 'POST') or (Method = 'PUT') or
            (Method = 'PATCH') or (Method = 'DELETE') or (Method = 'HEAD');
end;

function MethodTakesNoBody(const Method: RawUtf8): Boolean;
begin
  Result := (Method = 'GET') or (Method = 'HEAD');
end;

// RFC 9110 token characters, which is the whole of what a header name may
// be. Anything else - a space, a colon, a control byte - is a splitting
// attempt rather than a name
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

// the REQUEST-header allowlist. `x-`-prefixed application headers are
// admitted as a family; everything else is named
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

// the RESPONSE-header allowlist. `location` is here because §4 returns a
// 3xx with its Location instead of following it, and an allowlist that
// omitted it would have promised a redirect the envelope could not carry.
// `set-cookie` is NEVER here, so nothing in JavaScript can reconstruct a jar
// the runtime refused to keep
function ResponseHeaderAllowed(const Lower: RawUtf8): Boolean;
begin
  Result := (Lower = 'content-type') or
            (Lower = 'content-length') or
            (Lower = 'etag') or
            (Lower = 'last-modified') or
            (Lower = 'retry-after') or
            (Lower = 'location') or
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

{ ---------------------------------------------------------------------------
  argument decoding

  mORMot's own parser, walked member by member, because the DISTINCTION
  between a JSON string and a JSON object is exactly what §4 makes a refusal:
  a `headers` field that is present but not an object is invalid_request and
  never an empty header set, since silently dropping every header would let a
  caller believe an `authorization` was sent.
  --------------------------------------------------------------------------- }

type
  TPWebFetchArgKind = (fakAbsent, fakString, fakObject, fakArray, fakNumber,
    fakOther);

  TPWebFetchArg = record
    Kind: TPWebFetchArgKind;
    Text: RawUtf8;
  end;

  TPWebFetchArgs = record
    Url, Method, Headers, Body, TimeoutMs: TPWebFetchArg;
    Unknown: Boolean;
    Malformed: Boolean;
  end;

procedure TakeArg(var Arg: TPWebFetchArg; const Field: TGetJsonField;
  var Duplicate: Boolean);
begin
  if Arg.Kind <> fakAbsent then
  begin
    Duplicate := True;
    exit;
  end;
  if Field.Value = nil then
  begin
    // a JSON null is decoded as Value=nil; it reads as ABSENT, which is the
    // only sane meaning for `"headers": null`
    Arg.Kind := fakAbsent;
    exit;
  end;
  FastSetString(RawUtf8(Arg.Text), Field.Value, Field.ValueLen);
  if Field.WasString then
    Arg.Kind := fakString
  else if Arg.Text = '' then
    Arg.Kind := fakOther
  else
    case Arg.Text[1] of
      '{': Arg.Kind := fakObject;
      '[': Arg.Kind := fakArray;
      '-', '0' .. '9': Arg.Kind := fakNumber;
    else
      Arg.Kind := fakOther; // true / false
    end;
end;

function DecodeArgs(var Payload: RawUtf8; out Args: TPWebFetchArgs): Boolean;
var
  field: TGetJsonField;
  name: RawUtf8;
  duplicate: Boolean;
begin
  Args := Default(TPWebFetchArgs);
  duplicate := False;
  Result := False;
  if (Payload = '') or
     (Payload = PWEB_JSON_NULL) then
    // no arguments at all: `url` is then missing, which the caller reports
    exit(True);
  field.Json := pointer(Payload);
  if field.Json = nil then
    exit(True);
  while (field.Json <> nil) and
        (field.Json^ <= ' ') and
        (field.Json^ <> #0) do
    Inc(field.Json);
  if (field.Json = nil) or
     (field.Json^ <> '{') then
    exit; // not an object at all - the enqueue gate should have caught it
  Inc(field.Json);
  while (field.Json <> nil) and
        (field.Json^ <= ' ') and
        (field.Json^ <> #0) do
    Inc(field.Json);
  if (field.Json <> nil) and
     (field.Json^ = '}') then
    exit(True); // `{}`
  repeat
    if not field.GetJsonFieldName then
      exit;
    FastSetString(name, field.Value, field.ValueLen);
    field.GetJsonFieldOrObjectOrArray({HandleValuesAsObjectOrArray=}true);
    if field.Json = nil then
      exit;
    if name = 'url' then
      TakeArg(Args.Url, field, duplicate)
    else if name = 'method' then
      TakeArg(Args.Method, field, duplicate)
    else if name = 'headers' then
      TakeArg(Args.Headers, field, duplicate)
    else if name = 'body' then
      TakeArg(Args.Body, field, duplicate)
    else if name = 'timeoutMs' then
      TakeArg(Args.TimeoutMs, field, duplicate)
    else
      // an argument this door does not define is a REFUSAL, not a value to
      // ignore: a caller that misspelled `timeoutMs` must learn so here and
      // not by watching a ten-second default it never asked for
      Args.Unknown := True;
    if duplicate then
      Args.Unknown := True;
  until field.EndOfObject <> ',';
  Result := field.EndOfObject = '}';
end;

// one `headers` object into the CRLF block a transport sends, plus the
// content-type it carries separately
function BuildHeaderBlock(var HeadersJson: RawUtf8; out Block, Mime: RawUtf8;
  out Detail: RawUtf8): Boolean;
var
  field: TGetJsonField;
  name, lower, value: RawUtf8;
  seen: TRawUtf8DynArray;
  i, count: PtrInt;
begin
  Result := False;
  Block := '';
  Mime := '';
  Detail := '';
  count := 0;
  seen := nil;
  field.Json := pointer(HeadersJson);
  if field.Json = nil then
    exit(True);
  while (field.Json^ <= ' ') and
        (field.Json^ <> #0) do
    Inc(field.Json);
  if field.Json^ <> '{' then
  begin
    Detail := 'headers';
    exit;
  end;
  Inc(field.Json);
  while (field.Json^ <= ' ') and
        (field.Json^ <> #0) do
    Inc(field.Json);
  if field.Json^ = '}' then
    exit(True);
  repeat
    if not field.GetJsonFieldName then
    begin
      Detail := 'headers';
      exit;
    end;
    FastSetString(name, field.Value, field.ValueLen);
    field.GetJsonField;
    if field.Json = nil then
    begin
      Detail := 'headers';
      exit;
    end;
    if not field.WasString then
    begin
      // a header VALUE that is not a string is refused rather than
      // stringified: `{"x-n": 5}` and `{"x-n": "5"}` are different requests
      Detail := name;
      exit;
    end;
    FastSetString(value, field.Value, field.ValueLen);
    lower := AsciiLower(name);
    if not ValidHeaderName(lower) then
    begin
      Detail := 'name';
      exit;
    end;
    if not RequestHeaderAllowed(lower) then
    begin
      Detail := lower;
      exit;
    end;
    for i := 0 to High(seen) do
      if seen[i] = lower then
      begin
        // one name, one value: a repeated header is an ambiguity this door
        // does not resolve on the caller's behalf
        Detail := lower;
        exit;
      end;
    if Length(value) > PWEB_FETCH_MAX_HEADER_BYTES then
    begin
      Detail := lower;
      exit;
    end;
    // a value carrying CR, LF or NUL is a splitting attempt, not a header:
    // refused ON THE BYTES rather than sanitized
    if HasControlByte(value) then
    begin
      Detail := lower;
      exit;
    end;
    Inc(count);
    if count > PWEB_FETCH_MAX_HEADERS then
    begin
      Detail := 'count';
      exit;
    end;
    SetLength(seen, Length(seen) + 1);
    seen[High(seen)] := lower;
    if lower = 'content-type' then
      Mime := value
    else
      Block := Block + name + ': ' + value + #13#10;
  until field.EndOfObject <> ',';
  Result := field.EndOfObject = '}';
  if not Result then
    Detail := 'headers';
end;

{ ---------------------------------------------------------------------------
  the response envelope
  --------------------------------------------------------------------------- }

// the raw response header block into the allowlisted JSON object. Names are
// lowercased; a repeated allowlisted name is COMBINED in order with ', ',
// which is RFC 9110 §5.3 field-order semantics and the only combination that
// loses nothing
function BuildResponseHeaders(const Raw: RawUtf8): RawUtf8;
var
  i, lineStart, colon: PtrInt;
  line, name, value: RawUtf8;
  names, values: TRawUtf8DynArray;
  j: PtrInt;
  found: Boolean;
begin
  names := nil;
  values := nil;
  lineStart := 1;
  i := 1;
  while lineStart <= Length(Raw) do
  begin
    i := lineStart;
    while (i <= Length(Raw)) and
          (Raw[i] <> #13) and
          (Raw[i] <> #10) do
      Inc(i);
    line := Copy(Raw, lineStart, i - lineStart);
    lineStart := i + 1;
    if (lineStart <= Length(Raw)) and
       (Raw[i] = #13) and
       (Raw[lineStart] = #10) then
      Inc(lineStart);
    if line = '' then
      continue;
    colon := Pos(':', line);
    if colon <= 1 then
      continue;
    name := AsciiLower(Copy(line, 1, colon - 1));
    value := Copy(line, colon + 1, MaxInt);
    while (value <> '') and
          (value[1] = ' ') do
      Delete(value, 1, 1);
    while (value <> '') and
          (value[Length(value)] = ' ') do
      SetLength(value, Length(value) - 1);
    if not ResponseHeaderAllowed(name) then
      continue;
    found := False;
    for j := 0 to High(names) do
      if names[j] = name then
      begin
        values[j] := values[j] + ', ' + value;
        found := True;
        break;
      end;
    if found then
      continue;
    SetLength(names, Length(names) + 1);
    SetLength(values, Length(values) + 1);
    names[High(names)] := name;
    values[High(values)] := value;
  end;
  Result := '{';
  for j := 0 to High(names) do
  begin
    if j > 0 then
      Result := Result + ',';
    Result := Result + QuotedStrJson(names[j]) + ':' + QuotedStrJson(values[j]);
  end;
  Result := Result + '}';
end;

function ErrorData(const Category: RawUtf8; const Extra: RawUtf8 = ''): TPWebJson;
begin
  Result := TPWebJson('{"category":' + QuotedStrJson(Category));
  if Extra <> '' then
    Result := Result + TPWebJson(',' + Extra);
  Result := Result + '}';
end;

{ ---------------------------------------------------------------------------
  TPWebFetchBridge
  --------------------------------------------------------------------------- }

constructor TPWebFetchBridge.Create(const AInner: IInvocationBridge;
  ATransport: TPWebFetchTransport; const AOrigins: array of RawUtf8;
  AObserver: TPWebFetchObserver);
var
  detail: RawUtf8;
  refusal: TPWebFetchOriginsRefusal;
begin
  inherited Create;
  if AInner = nil then
    raise EPWebFetch.Create('TPWebFetchBridge requires an inner bridge');
  if not Assigned(ATransport) then
    raise EPWebFetch.Create('TPWebFetchBridge requires a transport');
  // the compiled allowlist goes through the SAME parser every request URL
  // does, once, at startup. A generated literal the grammar refuses is a
  // construction error - loudly, before a window exists - and never a
  // runtime path that answers something plausible
  if not PWebFetchParseOrigins(AOrigins, FOrigins, refusal, detail) then
    raise EPWebFetch.CreateFmt(
      'TPWebFetchBridge refuses the compiled origin allowlist: %s', [detail]);
  FInner := AInner;
  FTransport := ATransport;
  FObserver := AObserver;
end;

function TPWebFetchBridge.AllowlistDigest: RawUtf8;
begin
  Result := PWebFetchAllowlistDigest(FOrigins);
end;

function TPWebFetchBridge.Refuse(const Context: TInvocationContext;
  ACode: TPWebErrorCode; const AMessage: Utf8String;
  UrlBytes: PtrInt): TPWebInvocationResult;
begin
  if Assigned(FObserver) then
    FObserver(Context, pfdRefused, UrlBytes, 0);
  Result := PWebErrorResult(ACode, AMessage, PWEB_JSON_NULL);
end;

function TPWebFetchBridge.Fetch(const Context: TInvocationContext;
  const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  payload: RawUtf8;
  decoded: TPWebFetchArgs;
  request: TPWebFetchRequest;
  response: TPWebFetchResponse;
  origin: TPWebFetchOrigin;
  detail, bodyText, bodyB64, envelope: RawUtf8;
  outcome: TPWebFetchOutcome;
  i: PtrInt;
  allowed: Boolean;
begin
  // mORMot's parser unescapes IN PLACE, so it must never walk the caller's
  // buffer: Args belongs to the invocation, not to this function
  payload := Args;
  UniqueRawUtf8(payload);
  if not DecodeArgs(payload, decoded) then
    exit(Refuse(Context, pecInvalidRequest, 'malformed arguments', 0));
  if decoded.Unknown then
    exit(Refuse(Context, pecInvalidRequest,
      'unknown or repeated argument', 0));

  // --- url -----------------------------------------------------------------
  if decoded.Url.Kind <> fakString then
    exit(Refuse(Context, pecInvalidRequest, 'url must be a string', 0));
  if not ParseRequestUrl(decoded.Url.Text, origin, request.Target) then
    exit(Refuse(Context, pecInvalidRequest, 'url is not an acceptable request target',
      Length(decoded.Url.Text)));
  // THE ALLOWLIST, by parsed components and never by prefix. The refused
  // origin does not appear in the message either: a page learns that it was
  // refused, not what the native allowlist happens to contain
  allowed := False;
  for i := 0 to High(FOrigins) do
    if PWebFetchSameOrigin(FOrigins[i], origin) then
    begin
      allowed := True;
      break;
    end;
  if not allowed then
    exit(Refuse(Context, pecInvalidRequest,
      'origin is not in the native allowlist', Length(decoded.Url.Text)));

  // --- method --------------------------------------------------------------
  case decoded.Method.Kind of
    fakAbsent:
      request.Method := 'GET';
    fakString:
      request.Method := decoded.Method.Text;
  else
    exit(Refuse(Context, pecInvalidRequest, 'method must be a string',
      Length(decoded.Url.Text)));
  end;
  if not ValidMethod(request.Method) then
    exit(Refuse(Context, pecInvalidRequest, 'method is not allowed',
      Length(decoded.Url.Text)));

  // --- headers -------------------------------------------------------------
  case decoded.Headers.Kind of
    fakAbsent:
      begin
        request.Headers := '';
        request.Mime := '';
      end;
    fakObject:
      if not BuildHeaderBlock(decoded.Headers.Text, request.Headers,
           request.Mime, detail) then
        exit(Refuse(Context, pecInvalidRequest,
          'header refused: ' + detail, Length(decoded.Url.Text)));
  else
    // present but NOT an object: invalid_request, never an empty header set
    exit(Refuse(Context, pecInvalidRequest, 'headers must be an object',
      Length(decoded.Url.Text)));
  end;

  // --- body ----------------------------------------------------------------
  case decoded.Body.Kind of
    fakAbsent:
      request.Body := '';
    fakString:
      request.Body := decoded.Body.Text;
  else
    exit(Refuse(Context, pecInvalidRequest, 'body must be a string',
      Length(decoded.Url.Text)));
  end;
  if Length(request.Body) > PWEB_FETCH_MAX_REQUEST_BODY then
    exit(Refuse(Context, pecInvalidRequest, 'request body is over the bound',
      Length(decoded.Url.Text)));
  if (request.Body <> '') and
     MethodTakesNoBody(request.Method) then
    // a body on a bodyless method is a smuggling shape, not a convenience
    exit(Refuse(Context, pecInvalidRequest,
      'this method takes no body', Length(decoded.Url.Text)));

  // --- deadline ------------------------------------------------------------
  case decoded.TimeoutMs.Kind of
    fakAbsent:
      request.DeadlineMs := PWEB_FETCH_DEFAULT_DEADLINE_MS;
    fakNumber:
      begin
        request.DeadlineMs := StrToIntDef(string(decoded.TimeoutMs.Text), -1);
        // a value over the maximum is REFUSED, never clamped: a clamp is a
        // request that quietly became a different request
        if (request.DeadlineMs < 1) or
           (request.DeadlineMs > PWEB_FETCH_MAX_DEADLINE_MS) then
          exit(Refuse(Context, pecInvalidRequest,
            'timeoutMs is outside the accepted range', Length(decoded.Url.Text)));
      end;
  else
    exit(Refuse(Context, pecInvalidRequest, 'timeoutMs must be a number',
      Length(decoded.Url.Text)));
  end;

  // --- the exchange --------------------------------------------------------
  request.Url := decoded.Url.Text;
  request.Scheme := origin.Scheme;
  request.Host := origin.Host;
  request.Port := origin.Port;
  request.Https := origin.Scheme = 'https';
  request.MaxResponseBytes := PWEB_FETCH_MAX_RESPONSE;
  response := Default(TPWebFetchResponse);
  outcome := pfoTransport;
  try
    outcome := FTransport(request, Token, response);
  except
    // a transport that raised is a FAILURE, never a success - and the
    // exception dies here rather than travelling out of a bridge call
    outcome := pfoTransport;
  end;

  case outcome of
    pfoTimedOut, pfoCancelled:
      begin
        if Assigned(FObserver) then
          FObserver(Context, pfdFailed, Length(request.Url), 0);
        exit(PWebDefaultErrorResult(pecCancelled));
      end;
    pfoTooLarge:
      begin
        if Assigned(FObserver) then
          FObserver(Context, pfdFailed, Length(request.Url), response.Bytes);
        exit(PWebErrorResult(pecServiceError,
          'the response is over the ' +
            RawUtf8(IntToStr(PWEB_FETCH_MAX_RESPONSE)) + ' byte bound',
          ErrorData(PWEB_FETCH_CAT_TOO_LARGE,
            '"responseMax":' + RawUtf8(IntToStr(PWEB_FETCH_MAX_RESPONSE)))));
      end;
    pfoTransport:
      begin
        if Assigned(FObserver) then
          FObserver(Context, pfdFailed, Length(request.Url), 0);
        // a CATEGORY, never a native detail: no exception class name, no
        // stack, no path, no host
        exit(PWebErrorResult(pecServiceError, 'the exchange did not complete',
          ErrorData(PWEB_FETCH_CAT_TRANSPORT)));
      end;
  end;

  // --- the envelope --------------------------------------------------------
  bodyText := PWEB_JSON_NULL;
  bodyB64 := PWEB_JSON_NULL;
  if IsValidUtf8(response.Body) then
  begin
    if Length(response.Body) > PWEB_FETCH_MAX_TEXT_INLINE then
    begin
      if Assigned(FObserver) then
        FObserver(Context, pfdCompleted, Length(request.Url),
          Length(response.Body));
      // NEVER a success with a null body: a `status: 200` envelope carrying
      // `truncated: false` and no bytes is precisely the silently
      // half-working shape this repository refuses
      exit(PWebErrorResult(pecServiceError,
        'the response is too large to inline',
        ErrorData(PWEB_FETCH_CAT_NO_INLINE,
          '"bytes":' + RawUtf8(IntToStr(Length(response.Body))) +
          ',"inlineMax":' + RawUtf8(IntToStr(PWEB_FETCH_MAX_TEXT_INLINE)) +
          ',"responseMax":' + RawUtf8(IntToStr(PWEB_FETCH_MAX_RESPONSE)))));
    end;
    bodyText := QuotedStrJson(RawUtf8(response.Body));
  end
  else
  begin
    if Length(response.Body) > PWEB_FETCH_MAX_BASE64_INLINE then
    begin
      if Assigned(FObserver) then
        FObserver(Context, pfdCompleted, Length(request.Url),
          Length(response.Body));
      exit(PWebErrorResult(pecServiceError,
        'the response is too large to inline',
        ErrorData(PWEB_FETCH_CAT_NO_INLINE,
          '"bytes":' + RawUtf8(IntToStr(Length(response.Body))) +
          ',"inlineMax":' + RawUtf8(IntToStr(PWEB_FETCH_MAX_BASE64_INLINE)) +
          ',"responseMax":' + RawUtf8(IntToStr(PWEB_FETCH_MAX_RESPONSE)))));
    end;
    bodyB64 := '"' + BinToBase64(response.Body) + '"';
  end;

  if Assigned(FObserver) then
    FObserver(Context, pfdCompleted, Length(request.Url),
      Length(response.Body));

  // `truncated` is FALSE in every envelope this contract defines. It is
  // reserved for a future streaming form and never means "some of the body
  // is here" - the over-cap cases above are typed refusals precisely so that
  // it cannot come to mean that
  envelope := '{"status":' + RawUtf8(IntToStr(response.Status)) +
    ',"ms":' + RawUtf8(IntToStr(response.Ms)) +
    ',"bytes":' + RawUtf8(IntToStr(Length(response.Body))) +
    ',"truncated":false' +
    ',"headers":' + BuildResponseHeaders(response.Headers) +
    ',"bodyText":' + bodyText +
    ',"bodyBase64":' + bodyB64 + '}';
  Result := PWebSuccessResult(TPWebJson(envelope));
end;

function TPWebFetchBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  // exact, case-sensitive match on the canonical method - the single
  // canonicalization point upstream already produced it
  if Method = PWEB_METHOD_FETCH then
    Result := Fetch(Context, Args, Token)
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

end.
