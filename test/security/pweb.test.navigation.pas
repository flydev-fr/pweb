{
  pweb.test.navigation - headless CAP-8B suite over the shared navigation
  classifier (mormot.core.test).

  Covers the mandated B-matrix as CLASSIFIER decisions:
    B1-B3    trusted pweb://app document, reload and fragment allowed
    B4       wrong authority denied, on parsed components
    B5-B7    external https/mailto denied - and, per the ratified model,
             denied WITHOUT any external side effect
    B8-B13   http, file, data, javascript, blob, ws/wss/ftp, unknown denied
    B14-B15  about:blank denied, always - there is no bootstrap exception
    B16-B18  every subframe and every new window denied
    B21-B23  redirect target, form target and download denied
    plus the authority-confusion vectors and the external-URI validator.

  THE LOAD-BEARING TEST IS ActivationIsNotAnInput. CAP-8B measured that no
  engine can honestly report user activation - WebView2 and WebKitGTK both
  report TRUE for a navigation issued in the continuation of a binding
  promise, and WKWebView exposes no public flag at all - so the ratified model
  makes activation DIAGNOSTIC ONLY. That test runs the entire corpus twice
  with UserActivated inverted and requires byte-identical decisions, which
  turns "the classifier does not read the flag" from a comment into a
  property. If someone ever reintroduces a gesture heuristic, that test is
  what fails.

  This unit is WEBVIEW-FREE and BRIDGE-FREE: it exercises a pure function, so
  the whole suite is headless on all four CI targets.

  DecisionDigest emits build/cap7f/navigation-policy.txt - the canonical LF
  decision corpus whose SHA-256 the CAP-7F evidence emitters record as
  navigation_policy_digest and the aggregator requires to be identical across
  the four targets. Every line is a pure decision of a pure function, so the
  bytes are target-independent by construction.
}

{$I mormot.defines.inc}

unit pweb.test.navigation;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.test,
  pweb.navigation.policy;

type
  TTestNavigationPolicy = class(TSynTestCase)
  published
    procedure TrustedDocument;
    procedure WrongAuthority;
    procedure ExternalSchemes;
    procedure FramesWindowsAndDownloads;
    procedure AboutBlankHasNoException;
    procedure ActivationIsNotAnInput;
    procedure ExternalUriValidator;
    procedure NativeHeaderProfile;
    procedure DecisionDigest;
  end;

const
  /// the file the CAP-7F emitters hash into navigation_policy_digest - the
  // ONE spelling of the path on the Pascal side
  PWEB_CAP8B_DIGEST_FILE = 'build/cap7f/navigation-policy.txt';

implementation

type
  TCorpusRow = record
    Uri: RawUtf8;
    Kind: TPWebNavKind;
    Expected: TPWebNavAction;
    Note: RawUtf8;
  end;

const
  { The whole ratified table, as data. Order is fixed because the digest is
    taken over these rows in sequence. }
  CORPUS: array[0 .. 44] of TCorpusRow = (
    // --- B1-B3: the only content that may ever execute -------------------
    (Uri: 'pweb://app/'; Kind: pnkDocument; Expected: pnaAllowTrusted;
     Note: 'B1 root'),
    (Uri: 'pweb://app/index.html'; Kind: pnkDocument;
     Expected: pnaAllowTrusted; Note: 'B1 canonical'),
    (Uri: 'pweb://app/assets/app.js'; Kind: pnkDocument;
     Expected: pnaAllowTrusted; Note: 'B2 nested canonical'),
    (Uri: 'pweb://app/index.html#frag'; Kind: pnkDocument;
     Expected: pnaAllowTrusted; Note: 'B3 fragment'),
    (Uri: 'pweb://app/index.html?q=1'; Kind: pnkDocument;
     Expected: pnaAllowTrusted; Note: 'B3 query'),
    (Uri: 'pweb://app'; Kind: pnkDocument; Expected: pnaAllowTrusted;
     Note: 'B1 authority only'),
    // MEASURED: every engine lower-cases the authority before a hook sees
    // it, and pweb://APP IS the same origin - ratification R-B keeps one
    // truth rather than a stricter rule that could never fire
    (Uri: 'pweb://APP/index.html'; Kind: pnkDocument;
     Expected: pnaAllowTrusted; Note: 'R-B authority case'),

    // --- B4 + authority confusion, all decided on parsed components ------
    (Uri: 'pweb://evil/x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 wrong authority'),
    (Uri: 'pweb://app.evil/x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 suffix'),
    (Uri: 'pweb://app@evil/x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 userinfo'),
    (Uri: 'pweb://app:8080/x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 port'),
    (Uri: 'pweb:///x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 empty authority'),
    (Uri: 'pweb://appevil/x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 prefix confusion'),
    (Uri: 'pweb://app/../secret'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 traversal'),
    (Uri: 'pweb://app/%2e%2e/secret'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 encoded traversal'),
    (Uri: ''; Kind: pnkDocument; Expected: pnaCancel; Note: 'empty uri'),
    (Uri: 'pweb://app/a'#13'b'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B4 control byte'),

    // --- B5-B13: every other scheme, denied with no side effect ----------
    (Uri: 'https://example.invalid/'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B5 https never navigates'),
    (Uri: 'mailto:nobody@example.invalid'; Kind: pnkDocument;
     Expected: pnaCancel; Note: 'B7 mailto never navigates'),
    (Uri: 'http://example.invalid/'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B8 http'),
    (Uri: 'file:///etc/passwd'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B9 file'),
    (Uri: 'data:text/html,x'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B10 data'),
    (Uri: 'javascript:void(0)'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B11 javascript'),
    (Uri: 'blob:pweb://app/abc'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B12 blob'),
    (Uri: 'ws://example.invalid/'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B13 ws'),
    (Uri: 'wss://example.invalid/'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B13 wss'),
    (Uri: 'ftp://example.invalid/'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B13 ftp'),
    (Uri: 'zzq://example.invalid/'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B13 unknown'),
    (Uri: 'about:blank'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B14/B15 no bootstrap exception'),
    (Uri: 'about:srcdoc'; Kind: pnkDocument; Expected: pnaCancel;
     Note: 'B14 about family'),

    // --- B16-B17: no subframe document, trusted authority included -------
    (Uri: 'pweb://app/index.html'; Kind: pnkSubframe; Expected: pnaCancel;
     Note: 'B16 trusted subframe still denied'),
    (Uri: 'pweb://evil/x'; Kind: pnkSubframe; Expected: pnaCancel;
     Note: 'B17 wrong-authority subframe'),
    (Uri: 'https://example.invalid/'; Kind: pnkSubframe; Expected: pnaCancel;
     Note: 'B16 external subframe'),
    (Uri: 'data:text/html,x'; Kind: pnkSubframe; Expected: pnaCancel;
     Note: 'B16 data subframe'),
    (Uri: 'about:blank'; Kind: pnkSubframe; Expected: pnaCancel;
     Note: 'B16 about:blank subframe'),

    // --- B18-B20: no new window, ever ------------------------------------
    (Uri: 'pweb://app/index.html'; Kind: pnkNewWindow; Expected: pnaCancel;
     Note: 'B18 no privileged child'),
    (Uri: 'https://example.invalid/'; Kind: pnkNewWindow; Expected: pnaCancel;
     Note: 'B19 external new window'),
    (Uri: 'mailto:nobody@example.invalid'; Kind: pnkNewWindow;
     Expected: pnaCancel; Note: 'B19 mailto new window'),
    (Uri: 'about:blank'; Kind: pnkNewWindow; Expected: pnaCancel;
     Note: 'B20 blank new window'),

    // --- B21-B23: redirect target, form target, downloads ----------------
    (Uri: 'https://example.invalid/redirected'; Kind: pnkDocument;
     Expected: pnaCancel; Note: 'B21 redirect target'),
    (Uri: 'https://example.invalid/form'; Kind: pnkDocument;
     Expected: pnaCancel; Note: 'B22 form target'),
    (Uri: 'pweb://app/download.bin'; Kind: pnkDownload; Expected: pnaCancel;
     Note: 'B23 trusted download still denied'),
    (Uri: 'https://example.invalid/f.bin'; Kind: pnkDownload;
     Expected: pnaCancel; Note: 'B23 external download'),
    (Uri: 'pweb://app/index.html'; Kind: pnkDownload; Expected: pnaCancel;
     Note: 'B23 download of the app document'),
    (Uri: 'about:blank'; Kind: pnkDownload; Expected: pnaCancel;
     Note: 'B23 blank download')
  );

function KindName(AKind: TPWebNavKind): RawUtf8;
begin
  case AKind of
    pnkDocument:
      Result := 'document';
    pnkSubframe:
      Result := 'subframe';
    pnkNewWindow:
      Result := 'newwindow';
    pnkDownload:
      Result := 'download';
  else
    Result := '?';
  end;
end;

function CorpusSafe(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
  c: AnsiChar;
begin
  // The corpus deliberately contains a URI carrying a control byte, and a
  // raw CR inside a digest file is a trap: any tool that normalises line
  // endings would silently rewrite it and change the sha256 the aggregator
  // compares across four operating systems. Control bytes are therefore
  // escaped in the EMITTED line - the DECISION is still taken over the raw
  // URI, which is the thing under test.
  Result := '';
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    if (c < #$20) or (c = #$7F) then
      Result := Result + '<' + RawUtf8(IntToHex(Ord(c), 2)) + '>'
    else
      Result := Result + c;
  end;
end;

function YesNo(AValue: Boolean): RawUtf8;
begin
  // spelled here rather than borrowed from a library constant: the corpus
  // bytes are a cross-OS digest, so their vocabulary is owned by this file
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

function ActionName(AAction: TPWebNavAction): RawUtf8;
begin
  if AAction = pnaAllowTrusted then
    Result := 'allow'
  else
    Result := 'cancel';
end;

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
  // identical to the CAP-8A suite's: TSynTests runs with the CWD set to the
  // executable's folder, which differs per target, so the corpus is anchored
  // to the repository root by walking up to the webview.lock marker
  dir := Executable.ProgramFilePath;
  for i := 1 to 8 do
  begin
    if FileExists(dir + 'webview.lock') then
      exit(dir);
    parent := ExtractFilePath(ExcludeTrailingPathDelimiter(dir));
    if (parent = '') or (parent = dir) then
      break;
    dir := parent;
  end;
  Result := '';
end;

function Decide(const AUri: RawUtf8; AKind: TPWebNavKind;
  AActivated: Boolean): TPWebNavAction;
var
  r: TPWebNavRequest;
begin
  r.Uri := AUri;
  r.Kind := AKind;
  r.UserActivated := AActivated;
  Result := PWebClassifyNavigation(r);
end;

{ TTestNavigationPolicy }

procedure TTestNavigationPolicy.TrustedDocument;
var
  i: PtrInt;
begin
  // B1-B3: only a canonical pweb://app document is ever allowed, and it is
  // allowed regardless of how the navigation was initiated
  for i := 0 to High(CORPUS) do
    if CORPUS[i].Expected = pnaAllowTrusted then
    begin
      Check(Decide(CORPUS[i].Uri, CORPUS[i].Kind, False) = pnaAllowTrusted,
        'allow row ' + string(CORPUS[i].Note) + ': ' + string(CORPUS[i].Uri));
      Check(CORPUS[i].Kind = pnkDocument,
        'only a top-level document may ever be allowed: ' +
        string(CORPUS[i].Note));
    end;
  // the trusted-origin predicate agrees with the classifier
  Check(PWebNavTrustedUri('pweb://app/index.html'), 'trusted predicate');
  Check(not PWebNavTrustedUri('pweb://evil/index.html'), 'wrong authority');
end;

procedure TTestNavigationPolicy.WrongAuthority;
begin
  // B4: every confusable authority fails on its PARSED components. A prefix
  // test would accept the first three of these.
  Check(Decide('pweb://app.evil/x', pnkDocument, True) = pnaCancel, 'suffix');
  Check(Decide('pweb://app@evil/x', pnkDocument, True) = pnaCancel,
    'userinfo');
  Check(Decide('pweb://appevil/x', pnkDocument, True) = pnaCancel, 'prefix');
  Check(Decide('pweb://app:8080/x', pnkDocument, True) = pnaCancel, 'port');
  Check(Decide('pweb:///x', pnkDocument, True) = pnaCancel, 'empty authority');
  Check(Decide('pweb://app/../secret', pnkDocument, True) = pnaCancel,
    'traversal');
  Check(Decide('pweb://app/%2e%2e/secret', pnkDocument, True) = pnaCancel,
    'encoded traversal');
  // R-B: the authority compares case-insensitively, because every measured
  // engine normalises it before the hook sees it and it is the same origin
  Check(Decide('pweb://APP/index.html', pnkDocument, True) = pnaAllowTrusted,
    'R-B: pweb://APP is the same origin, not a second one');
end;

procedure TTestNavigationPolicy.ExternalSchemes;
var
  i: PtrInt;
begin
  // B5-B13: no scheme other than pweb is ever allowed, in any frame kind,
  // and - the ratified change - https and mailto are no exception
  for i := 0 to High(CORPUS) do
    if CORPUS[i].Expected = pnaCancel then
      Check(Decide(CORPUS[i].Uri, CORPUS[i].Kind, True) = pnaCancel,
        'deny row ' + string(CORPUS[i].Note) + ': ' + string(CORPUS[i].Uri));
end;

procedure TTestNavigationPolicy.FramesWindowsAndDownloads;
var
  uri: RawUtf8;
begin
  // B16-B18, B23: the kind alone decides these, so even the trusted origin
  // is refused. This is what makes the rule provable on the engine that
  // cannot tell a subframe from a main frame (WebKitGTK 4.1, MEASURED
  // ABSENT): its adapter reports pnkDocument and CSP frame-src removes the
  // frame, but where the kind IS known the classifier refuses it outright.
  uri := 'pweb://app/index.html';
  Check(Decide(uri, pnkSubframe, True) = pnaCancel, 'trusted subframe');
  Check(Decide(uri, pnkSubframe, False) = pnaCancel, 'trusted subframe 2');
  Check(Decide(uri, pnkNewWindow, True) = pnaCancel, 'trusted new window');
  Check(Decide(uri, pnkDownload, True) = pnaCancel, 'trusted download');
  // and the same URI as a top-level document IS allowed - proving the kind,
  // not the URI, is what refused the three above
  Check(Decide(uri, pnkDocument, True) = pnaAllowTrusted, 'same uri, document');
end;

procedure TTestNavigationPolicy.AboutBlankHasNoException;
var
  k: TPWebNavKind;
begin
  // B14/B15: MEASURED on all four targets - no engine raises a navigation
  // event for its own initial about:blank (Windows reports it as a source
  // but fires nothing; Linux and macOS report none at all). So there is no
  // bootstrap exception and no Armed state machine, and about:blank is
  // denied in every kind, at every moment, with no state to get wrong.
  for k := Low(TPWebNavKind) to High(TPWebNavKind) do
  begin
    Check(Decide('about:blank', k, True) = pnaCancel,
      'about:blank ' + string(KindName(k)));
    Check(Decide('about:blank', k, False) = pnaCancel,
      'about:blank unactivated ' + string(KindName(k)));
  end;
end;

procedure TTestNavigationPolicy.ActivationIsNotAnInput;
var
  i: PtrInt;
  activated, plain: TPWebNavAction;
begin
  // THE LOAD-BEARING TEST. CAP-8B measured that user activation cannot be
  // reported honestly by any engine: WebView2 and WebKitGTK both report a
  // gesture for a navigation issued in the continuation of a binding
  // promise, and WKWebView exposes no public flag at all. The ratified model
  // therefore makes activation diagnostic only. This walks the ENTIRE corpus
  // with the flag both ways and requires the same answer, so a future
  // gesture heuristic cannot be added without turning this red.
  for i := 0 to High(CORPUS) do
  begin
    plain := Decide(CORPUS[i].Uri, CORPUS[i].Kind, False);
    activated := Decide(CORPUS[i].Uri, CORPUS[i].Kind, True);
    Check(plain = activated,
      'user activation changed the decision for ' + string(CORPUS[i].Note) +
      ' (' + string(CORPUS[i].Uri) + '): a gesture is not an authorization ' +
      'input on any target');
    Check(plain = CORPUS[i].Expected,
      'corpus row ' + string(CORPUS[i].Note) + ' expected ' +
      string(ActionName(CORPUS[i].Expected)) + ', got ' +
      string(ActionName(plain)));
  end;
end;

procedure TTestNavigationPolicy.ExternalUriValidator;
var
  long: RawUtf8;
begin
  // the gate for the capability-authorized external open - NOT for
  // navigation, which never reaches an opener at all
  Check(PWebValidExternalUri('https://example.invalid/'), 'https');
  Check(PWebValidExternalUri('https://example.invalid/a?b=c#d'), 'https full');
  Check(PWebValidExternalUri('mailto:nobody@example.invalid'), 'mailto');
  Check(PWebValidExternalUri('HTTPS://example.invalid/'), 'scheme case');
  // everything else is refused, including the schemes a careless allowlist
  // would let through
  Check(not PWebValidExternalUri(''), 'empty');
  Check(not PWebValidExternalUri('http://example.invalid/'), 'http');
  Check(not PWebValidExternalUri('file:///etc/passwd'), 'file');
  Check(not PWebValidExternalUri('data:text/html,x'), 'data');
  Check(not PWebValidExternalUri('javascript:alert(1)'), 'javascript');
  Check(not PWebValidExternalUri('blob:pweb://app/a'), 'blob');
  Check(not PWebValidExternalUri('ws://example.invalid/'), 'ws');
  Check(not PWebValidExternalUri('pweb://app/index.html'), 'pweb');
  Check(not PWebValidExternalUri('zzq://example.invalid/'), 'unknown');
  // shape rules: an authority for https, a recipient for mailto
  Check(not PWebValidExternalUri('https://'), 'https bare');
  Check(not PWebValidExternalUri('https:/example.invalid'), 'https one slash');
  Check(not PWebValidExternalUri('https:example.invalid'), 'https no slash');
  // the authority must be non-empty AS A PARSED COMPONENT: each of these
  // carries '//' followed immediately by path, query or fragment, and an
  // empty authority is a launcher's invitation to invent one
  Check(not PWebValidExternalUri('https:///x'), 'https empty authority path');
  Check(not PWebValidExternalUri('https://?q=1'), 'https empty authority query');
  Check(not PWebValidExternalUri('https://#frag'), 'https empty authority frag');
  Check(not PWebValidExternalUri('https:////evil.invalid/'),
    'https double-slash authority');
  Check(not PWebValidExternalUri('mailto:'), 'mailto empty');
  Check(not PWebValidExternalUri('mailto:nobody'), 'mailto no host');
  Check(not PWebValidExternalUri('mailto:@example.invalid'), 'mailto no user');
  // A mailto QUERY is refused outright. The substring search this replaced
  // accepted a URI with no recipient at all as long as some parameter value
  // contained an '@', and a mail client honouring `attach=` would then compose
  // a message with a local file the PAGE chose.
  Check(not PWebValidExternalUri(
    'mailto:?attach=/home/me/.ssh/id_rsa&to=attacker@evil.invalid'),
    'mailto attach parameter');
  Check(not PWebValidExternalUri('mailto:x?a=@b'), 'mailto query with @');
  Check(not PWebValidExternalUri('mailto:?body=secret@x'), 'mailto body only');
  Check(not PWebValidExternalUri('mailto:a@b?subject=x'), 'mailto any query');
  Check(not PWebValidExternalUri('mailto:a@b#frag'), 'mailto fragment');
  Check(not PWebValidExternalUri('mailto:a@b@c'), 'mailto two recipients');
  // a raw backslash belongs to neither scheme and is a normalisation trap
  Check(not PWebValidExternalUri('https://example.invalid/a\b'),
    'https backslash');
  Check(not PWebValidExternalUri('https://example.invalid\@evil.invalid/'),
    'https backslash authority confusion');
  // control bytes can never reach a launcher, whatever the scheme
  Check(not PWebValidExternalUri('https://example.invalid/'#13#10'x'), 'crlf');
  Check(not PWebValidExternalUri('https://example.invalid/'#0), 'nul');
  Check(not PWebValidExternalUri('https://example.invalid/'#9), 'tab');
  // the URI-safe ASCII repertoire is the whole repertoire: a raw space,
  // quote, angle bracket or any byte >= $80 is refused outright -
  // percent-encoding is the accepted spelling for every one of them
  Check(not PWebValidExternalUri('https://example.invalid/a b'), 'space');
  Check(not PWebValidExternalUri('https://example.invalid/"x"'), 'quote');
  Check(not PWebValidExternalUri('https://example.invalid/<s>'), 'angles');
  Check(not PWebValidExternalUri('https://example.invalid/'#$7F), 'del');
  Check(not PWebValidExternalUri('https://example.invalid/'#$C3#$A9), 'utf8');
  Check(not PWebValidExternalUri('https://example.invalid/'#$FF), 'high byte');
  Check(not PWebValidExternalUri('mailto:a b@example.invalid'), 'mailto space');
  Check(PWebValidExternalUri('https://example.invalid/a%20b'),
    'percent-encoded space is the accepted spelling');
  // bounded length
  long := 'https://example.invalid/';
  while Length(long) <= PWEB_EXTERNAL_URI_MAX_BYTES do
    long := long + 'aaaaaaaaaaaaaaaa';
  Check(not PWebValidExternalUri(long), 'over the length ceiling');
end;

procedure TTestNavigationPolicy.NativeHeaderProfile;
var
  html, other: RawUtf8;
begin
  // the ratified profile, asserted as properties rather than as one brittle
  // string compare - a future edit that weakens it fails here by name
  Check(Pos('script-src ''self''', PWEB_NATIVE_CSP) > 0, 'script-src self');
  Check(Pos('''unsafe-eval''', PWEB_NATIVE_CSP) = 0, 'no unsafe-eval');
  Check(Pos('script-src ''self'' ''unsafe-inline''', PWEB_NATIVE_CSP) = 0,
    'script-src must never carry unsafe-inline');
  Check(Pos('frame-src ''none''', PWEB_NATIVE_CSP) > 0, 'frame-src none');
  Check(Pos('frame-ancestors ''none''', PWEB_NATIVE_CSP) > 0, 'frame-ancestors');
  Check(Pos('object-src ''none''', PWEB_NATIVE_CSP) > 0, 'object-src none');
  Check(Pos('base-uri ''none''', PWEB_NATIVE_CSP) > 0, 'base-uri none');
  Check(Pos('form-action ''none''', PWEB_NATIVE_CSP) > 0, 'form-action none');
  Check(Pos('worker-src ''none''', PWEB_NATIVE_CSP) > 0, 'worker-src none');
  // R-B: 'self', not 'none' - 'none' also blocks same-origin fetch, which the
  // repository's own CAP-4 fixtures use through the production handlers
  Check(Pos('connect-src ''self''', PWEB_NATIVE_CSP) > 0, 'connect-src self');
  Check(Pos('connect-src ''none''', PWEB_NATIVE_CSP) = 0, 'not connect none');

  // EVERY response carries the CSP, not just text/html. An earlier revision
  // gated it on the media type, which left pweb://app/logo.svg - a scriptable
  // top-level document in the trusted origin - with no policy at all.
  html := PWebNativeSecurityHeaders;
  other := html;
  Check(Pos('Content-Security-Policy: ', html) > 0, 'the CSP is unconditional');
  Check(Pos('X-Content-Type-Options: nosniff', html) > 0, 'nosniff');
  Check(Pos('Referrer-Policy: no-referrer', other) > 0, 'referrer');
end;

procedure TTestNavigationPolicy.DecisionDigest;
var
  lines: RawUtf8;
  allPass: Boolean;
  i: PtrInt;
  got: TPWebNavAction;
  stream: TFileStream;
  root, digestFile: TFileName;

  procedure Emit(const ALine: RawUtf8);
  begin
    lines := lines + ALine + #10; // LF only - the digest crosses OSes
  end;

begin
  // The canonical decision corpus. Every line is a pure decision of a pure
  // function over a fixed table, so the file bytes - and therefore the
  // sha256 the CAP-7F emitters record as navigation_policy_digest - are
  // identical on all four targets by construction.
  lines := '';
  allPass := True;
  Emit('schema=1');
  Emit('csp=' + PWEB_NATIVE_CSP);
  for i := 0 to High(CORPUS) do
  begin
    // emitted with activation BOTH ways on every row: the corpus itself
    // carries the proof that the flag is inert, so a target that somehow
    // read it would produce a different digest rather than a quiet pass
    got := Decide(CORPUS[i].Uri, CORPUS[i].Kind, False);
    if got <> Decide(CORPUS[i].Uri, CORPUS[i].Kind, True) then
    begin
      allPass := False;
      Check(False, 'activation changed row ' + string(CORPUS[i].Note));
    end;
    if got <> CORPUS[i].Expected then
      allPass := False;
    Emit('decision uri=' + CorpusSafe(CORPUS[i].Uri) +
      ' kind=' + KindName(CORPUS[i].Kind) +
      ' activated=both action=' + ActionName(got));
  end;
  // the external-open validator is part of the same shared truth
  Emit('external https=' + YesNo(PWebValidExternalUri('https://example.invalid/')));
  Emit('external mailto=' + YesNo(PWebValidExternalUri('mailto:nobody@example.invalid')));
  Emit('external http=' + YesNo(PWebValidExternalUri('http://example.invalid/')));
  Emit('external file=' + YesNo(PWebValidExternalUri('file:///etc/passwd')));
  // the fail-closed component and repertoire rules, pinned cross-target:
  // empty authorities and raw space/quote/high bytes must read false on
  // every target or the digest disagrees
  Emit('external emptyauth=' + YesNo(PWebValidExternalUri('https:///x')));
  Emit('external emptyauthq=' + YesNo(PWebValidExternalUri('https://?q=1')));
  Emit('external space=' + YesNo(PWebValidExternalUri('https://example.invalid/a b')));
  Emit('external quote=' + YesNo(PWebValidExternalUri('https://example.invalid/"x"')));
  Emit('external highbyte=' + YesNo(PWebValidExternalUri('https://example.invalid/' + #$C3#$A9)));
  Emit('external pctspace=' + YesNo(PWebValidExternalUri('https://example.invalid/a%20b')));
  if allPass then
    Emit('verdict=PASS')
  else
    Emit('verdict=FAIL');

  root := RepoRootFromExecutable;
  if root = '' then
  begin
    Check(False, 'repository root (webview.lock marker) not found from ' +
      string(Executable.ProgramFilePath) +
      ' - refusing to write the digest corpus at an ambiguous location');
    exit;
  end;
  digestFile := root + TFileName(StringReplace(PWEB_CAP8B_DIGEST_FILE,
    '/', PathDelim, [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(digestFile)) then
    Check(False, 'unable to create ' + string(ExtractFilePath(digestFile)))
  else
  begin
    stream := TFileStream.Create(digestFile, fmCreate);
    try
      if lines <> '' then
        stream.WriteBuffer(lines[1], Length(lines));
    finally
      stream.Free;
    end;
  end;
  Check(allPass, 'every navigation-corpus row decided as ratified');
end;

end.
