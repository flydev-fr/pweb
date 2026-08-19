{
  pweb.navigation.policy - the CAP-8B privileged-navigation classifier.

  ONE decision, shared by every engine. The platform adapters translate their
  native events into TPWebNavRequest and translate the answer back; they never
  decide anything themselves, and no WebView2, WebKitGTK or WKWebView type
  appears anywhere below.

  THE INVARIANT: a WebView that owns the privileged PWeb bridge may execute
  only trusted pweb://app content.

  ---------------------------------------------------------------------------
  WHY THERE ARE ONLY TWO OUTCOMES
  ---------------------------------------------------------------------------

  An earlier draft had a third, CancelAndOpenExternal, reached when a
  navigation looked user-initiated. CAP-8B MEASURED that no such judgement can
  be made, and the ratified model removed it:

    - WebView2's IsUserInitiated is TRUE for a navigation performed in the
      continuation of a webview_bind promise, because upstream resolves that
      promise through the engine's script-execution API and the engine runs
      host-injected script WITH a user gesture. That is the ordinary shape of
      a PWeb page - `await invoke(...)` and then follow a link.
    - WebKitGTK's is_user_gesture behaves identically, so the defect is a
      property of how a runtime resolves binding promises rather than of one
      vendor's flag.
    - WKWebView exposes no public gesture flag at all
      (-[WKNavigationAction _isUserInitiated] is private SPI, forbidden here),
      and its navigationType alone accepts a script-driven element.click().

  Every engine therefore has a DIFFERENT irreducible false positive, and a
  gesture is not a security boundary. So this classifier never opens anything:
  external navigation is always cancelled, and handing a URI to the operating
  system is a separate, explicitly authorized runtime invocation that travels
  the ordinary RPC path and is checked by ICapabilityPolicy like any other
  method (security-model.md, CAP-8B ratification R-A).

  TPWebNavRequest.UserActivated is carried anyway, because the evidence corpus
  and the diagnostics record it - but PWebClassifyNavigation MUST NOT read it,
  and test/security/pweb.test.navigation.pas proves that by running the whole
  corpus twice with the flag inverted and requiring an identical result.

  ---------------------------------------------------------------------------
  WHAT THIS UNIT DOES NOT DECIDE
  ---------------------------------------------------------------------------

  MEASURED on all four targets, and stated here so nobody writes a test
  asserting a defence this classifier cannot provide:

    - `javascript:` URLs raise NO navigation event and EXECUTE in place. The
      native CSP (script-src 'self', no 'unsafe-inline') is what stops them.
      The row below exists as defence in depth for an engine that might one
      day report one.
    - `file:` and top-level `data:` raise no event either - the engines refuse
      them themselves.
    - An about:blank IFRAME is not blocked by frame-src 'none' on any measured
      engine, and inherits its parent's origin. Nothing untrusted can execute
      there, but "no subframe exists" is not a property this layer delivers.
    - No engine raises a navigation event for its own initial about:blank
      (Windows reports it as a source, Linux and macOS report none), so there
      is deliberately NO bootstrap exception and no Armed state machine. An
      exception nothing needs is an exception nothing tests.

  ---------------------------------------------------------------------------
  LAYERING
  ---------------------------------------------------------------------------

  RTL + mormot.core.base (RawUtf8) + pweb.assets.support. That last dependency
  is the point: PWebParseAppUri is the ratified single truth for what
  pweb://app means, and a second URI parser in the security layer would be a
  second answer to the only question that matters here. Deliberately NO
  webview unit, NO mORMot bridge, NO platform conditional - the CAP-7F
  divergence sweep requires this file to carry zero platform directives.
}
unit pweb.navigation.policy;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.assets.support;

type
  { What the engine is being asked to do. The adapters map their native event
    kinds onto this; anything they cannot classify maps to pnkDocument, which
    is the strictest interpretation available. }
  TPWebNavKind = (
    /// a top-level document navigation
    pnkDocument,
    /// a subframe document navigation
    pnkSubframe,
    /// a new window / target=_blank / window.open
    pnkNewWindow,
    /// a download
    pnkDownload
  );

  { The whole answer. Two values, for the reason given in the header. }
  TPWebNavAction = (
    /// trusted application content: let it proceed
    pnaAllowTrusted,
    /// refuse, with no external side effect of any kind
    pnaCancel
  );

  { One navigation, as the classifier sees it.

    UserActivated is DIAGNOSTIC ONLY. It is recorded, reported and compared
    across targets; it is never an authorization input. See the header. }
  TPWebNavRequest = record
    Uri: RawUtf8;
    Kind: TPWebNavKind;
    UserActivated: Boolean;
  end;

const
  /// the native security policy applied to trusted HTML responses
  // - MEASURED enforced, byte-identical in effect, on Windows/WebView2,
  // Linux/WebKitGTK 4.1 and macOS/WKWebView (both architectures), with a
  // deliberately weaker bundle <meta> policy proven unable to relax any row
  // - connect-src is 'self' and NOT 'none': 'none' also blocks same-origin
  // fetch, which the repository's own CAP-4 fixtures use through the
  // production handlers. 'self' still blocked every external connection and
  // every wss:// on all four targets (ratification R-B)
  // - no 'unsafe-eval', and script-src carries no 'unsafe-inline': the one
  // inline script the repository served over pweb://app was moved into a
  // bundled file rather than weakened here
  PWEB_NATIVE_CSP: RawUtf8 =
    'default-src ''self''; base-uri ''none''; object-src ''none''; ' +
    'frame-src ''none''; frame-ancestors ''none''; form-action ''none''; ' +
    'connect-src ''self''; script-src ''self''; ' +
    'style-src ''self'' ''unsafe-inline''; img-src ''self'' data:; ' +
    'font-src ''self'' data:; media-src ''self''; worker-src ''none''; ' +
    'manifest-src ''self''';

  /// never let an engine sniff a served asset's type
  PWEB_HEADER_NOSNIFF: RawUtf8 = 'X-Content-Type-Options: nosniff';
  /// a privileged origin has nothing to disclose to anyone
  PWEB_HEADER_REFERRER: RawUtf8 = 'Referrer-Policy: no-referrer';

  /// ceiling for a URI handed to the operating system, in bytes
  PWEB_EXTERNAL_URI_MAX_BYTES = 2048;

/// is this exactly the trusted application origin, by PARSED components?
// - delegates to PWebParseAppUri, the ratified single truth: scheme pweb,
// authority exactly 'app' (case-insensitive per RFC 3986, which every
// measured engine already applies before the hook sees the URI), one
// percent-decode, then the canonical asset-path rules
// - never a prefix test, never a substring search, never a path-only compare:
// pweb://app.evil/, pweb://app@evil/, pweb://app:8080/ and pweb:///x all fail
// here on their components, not on their spelling
function PWebNavTrustedUri(const Uri: RawUtf8): Boolean;

/// THE decision - pure, total, and independent of UserActivated
function PWebClassifyNavigation(const Request: TPWebNavRequest): TPWebNavAction;

/// may this URI be handed to the operating system's default handler?
// - the gate for the capability-authorized external-open invocation, NOT for
// navigation: no navigation path ever reaches an opener (ratification R-A.2)
// - https: and mailto: only, compared on the parsed scheme; bounded length;
// no control bytes; https must carry an authority and mailto a recipient
// - fail-closed: anything unrecognised is refused rather than passed through
function PWebValidExternalUri(const Uri: RawUtf8): Boolean;

/// the response headers a trusted HTML asset carries, CRLF separated
// - the bundle cannot remove or weaken these: they are attached natively, and
// multiple CSP policies combine restrictively (MEASURED on all four targets)
function PWebNativeSecurityHeaders(const AIsHtml: Boolean): RawUtf8;

implementation

function AsciiLowerCh(c: AnsiChar): AnsiChar; inline;
begin
  if c in ['A'..'Z'] then
    Result := AnsiChar(Ord(c) + 32)
  else
    Result := c;
end;

{ the scheme, lower-cased, or '' when the URI has none. Deliberately does not
  decode anything: a scheme is ASCII by RFC 3986 and a URI that needs decoding
  before its scheme is legible is one this layer refuses. }
function SchemeOf(const Uri: RawUtf8): RawUtf8;
var
  i, j: PtrInt;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(Uri) do
  begin
    c := Uri[i];
    if c = ':' then
    begin
      if i = 1 then
        exit; // empty scheme
      SetLength(Result, i - 1);
      Move(pointer(Uri)^, pointer(Result)^, i - 1);
      for j := 1 to Length(Result) do
        Result[j] := AsciiLowerCh(Result[j]);
      exit;
    end;
    // RFC 3986 scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    if i = 1 then
    begin
      if not (c in ['a'..'z', 'A'..'Z']) then
        exit;
    end
    else if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.']) then
      exit;
  end;
end;

function HasControlBytes(const S: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := True;
  for i := 1 to Length(S) do
    if (S[i] < #$20) or (S[i] = #$7F) then
      exit;
  Result := False;
end;

function PWebNavTrustedUri(const Uri: RawUtf8): Boolean;
var
  logical: RawUtf8;
begin
  // one truth, and it parses components rather than matching spellings
  Result := PWebParseAppUri(Uri, logical);
end;

function PWebClassifyNavigation(const Request: TPWebNavRequest): TPWebNavAction;
begin
  // FAIL CLOSED FIRST. Everything below narrows from a refusal; nothing
  // widens from an allowance.
  Result := pnaCancel;

  // Request.UserActivated is deliberately NOT read anywhere in this function.
  // The corpus test inverts it over every row and requires the same answer.

  case Request.Kind of
    pnkDocument:
      // the only thing that may ever execute here
      if PWebNavTrustedUri(Request.Uri) then
        Result := pnaAllowTrusted;
    pnkSubframe:
      // no subframe document, trusted authority included: a privileged
      // WebView hosts exactly one document. On the engine that cannot tell a
      // subframe from a main frame at navigation time (WebKitGTK 4.1,
      // MEASURED ABSENT), the adapter reports pnkDocument and frame-src
      // 'none' is what removes the frame - which is why that directive is
      // load-bearing rather than decorative.
      Result := pnaCancel;
    pnkNewWindow:
      // no second privileged WebView, and no window handed to the engine to
      // populate on its own
      Result := pnaCancel;
    pnkDownload:
      // a privileged WebView never writes a download
      Result := pnaCancel;
  end;
end;

function PWebValidExternalUri(const Uri: RawUtf8): Boolean;
var
  scheme, rest: RawUtf8;
  at: PtrInt;
begin
  Result := False;
  if (Uri = '') or
     (Length(Uri) > PWEB_EXTERNAL_URI_MAX_BYTES) then
    exit;
  if HasControlBytes(Uri) then
    exit; // NUL, CR, LF and every other control byte, always
  scheme := SchemeOf(Uri);
  rest := Copy(Uri, Length(scheme) + 2, MaxInt); // past 'scheme:'
  if scheme = 'https' then
  begin
    // an authority is mandatory: 'https:/x' and 'https:x' are not addresses
    // of anything and must never reach a shell-free launcher either
    if Copy(rest, 1, 2) <> '//' then
      exit;
    if Length(rest) <= 2 then
      exit; // 'https://' alone
    Result := True;
  end
  else if scheme = 'mailto' then
  begin
    // a recipient is mandatory, and it must look like one; the query part
    // (subject/body) is deliberately not inspected and never logged
    at := Pos('@', rest);
    if (at <= 1) or
       (at >= Length(rest)) then
      exit;
    Result := True;
  end;
  // every other scheme, including http, file, data, javascript, blob, ws,
  // wss and anything unrecognised, is refused by falling through
end;

function PWebNativeSecurityHeaders(const AIsHtml: Boolean): RawUtf8;
begin
  // nosniff and no-referrer ride EVERY asset; the CSP rides HTML, where it is
  // the document policy that matters. Attaching it to a script response would
  // be inert, not harmful - it is omitted so the served bytes stay minimal.
  Result := PWEB_HEADER_NOSNIFF + #13#10 + PWEB_HEADER_REFERRER;
  if AIsHtml then
    Result := Result + #13#10 + 'Content-Security-Policy: ' + PWEB_NATIVE_CSP;
end;

end.
