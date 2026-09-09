program netprobe;

{ CAP-15A: the outbound-network measurement host. A SPIKE, not a product.

  ONE instrumented host, two modes, four engines. It answers the question
  TODO.txt #1 asks - "PWEB_NATIVE_CSP says connect-src 'self', so a frontend
  cannot reach a remote server; is PWeb an application platform, and through
  which door?" - by measuring both candidate doors on the same page in the
  same window.

  WHAT IS PRODUCTION HERE, unchanged: the asset handler that serves
  pweb://app, the navigation guard, the scheduler, the CAP-8A capability
  policy and the per-invocation effective snapshot. The measurement is worth
  nothing unless the enforcement path is the shipped one.

  WHAT IS THE SPIKE:

    1. TSpikeFetchBridge - a `pweb.fetch` IInvocationBridge decorator in the
       exact shape of the ratified pweb.rpc.command layer (intercept one
       runtime-owned method, delegate everything else verbatim, authorize
       NOTHING itself because CAP-8A already ran at the scheduler). It is the
       proposed door A, built here to be measured rather than shipped.

    2. The CSP. In `widened` mode this program is compiled against a
       GENERATED shim of pweb.navigation.policy whose connect-src also names
       the probe server's origin A - one substituted token, produced by the
       run script, never committed. In `baseline` mode it is compiled against
       the shipped unit, byte for byte.

       The mode is DERIVED from PWEB_NATIVE_CSP at runtime, never taken from
       an environment variable, so a report cannot claim a policy the binary
       does not carry.

  The page (test/cap15a/fixture/assets/probe.js) performs every row and
  reports observed facts through probe.report; the probe server's JSONL log
  is the independent witness for everything the page cannot read. This host
  joins the three and writes build/cap15a/<target>-<mode>.json.

  In `baseline` mode - and only there - the host ASSERTS the shipped
  invariant: no engine-side row reached the network, and the native door
  worked anyway. In `widened` mode nothing is asserted: a measurement shard
  records what an engine does; it does not grade it. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.datetime, // TValuePUtf8Char, used by the JsonDecode overloads
  mormot.core.json,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.net.sock,
  mormot.net.client,
  {$ifdef CAP15A_OPENSSL}
  mormot.lib.openssl11,
  {$endif CAP15A_OPENSSL}
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.capabilities.policy,
  pweb.navigation.policy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.folder,
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2
  {$endif LINUX}
  {$endif DARWIN}
  ,
  pweb.test.reporoot;

type
  {$ifdef DARWIN}
  TPWebAssetHandler = TCocoaAssetHandler;
  TPWebNavigationGuard = TCocoaNavigationGuard;
  {$else}
  {$ifdef LINUX}
  TPWebAssetHandler = TWebKitGtkAssetHandler;
  TPWebNavigationGuard = TWebKitGtkNavigationGuard;
  {$else}
  TPWebAssetHandler = TWebView2AssetHandler;
  TPWebNavigationGuard = TWebView2NavigationGuard;
  {$endif LINUX}
  {$endif DARWIN}

const
  LOG_PREFIX = 'netprobe';
  MARKER_PASS = 'netprobe: NET PROBE COMPLETE';
  MARKER_FAIL = 'netprobe: NET PROBE FAIL';
  {$ifdef DARWIN}
    {$ifdef CPUAARCH64}
    TARGET_ID = 'macos-arm64';
    {$else}
    TARGET_ID = 'macos-x86_64';
    {$endif CPUAARCH64}
  {$else}
  {$ifdef LINUX}
  TARGET_ID = 'linux-x86_64';
  {$else}
  TARGET_ID = 'windows-x86_64';
  {$endif LINUX}
  {$endif DARWIN}

  DEFAULT_TIMEOUT_MS = 90000;
  MAX_TIMEOUT_MS = 240000;
  CLOSER_WAIT_MARGIN_MS = 10000;

  { the proposed method and capability names, spelled once. They are the
    subject of the CONTRACT section of the shard artifact, not a decision
    this program makes. }
  PWEB_METHOD_FETCH = 'pweb.fetch';
  PWEB_CAP_NETWORK_FETCH = 'network.fetch';

  { the spike's bounds. Every one of them is a number the artifact has to
    justify or replace; none is a value this program invents quietly. }
  FETCH_MAX_REQUEST_BODY = 1 shl 20;    // 1 MiB uploaded
  FETCH_MAX_RESPONSE     = 8 shl 20;    // 8 MiB downloaded, then refused
  FETCH_MAX_TEXT_INLINE  = 4 shl 20;    // beyond this the body is not inlined
  FETCH_DEFAULT_TIMEOUT  = 10000;
  FETCH_MAX_TIMEOUT      = 30000;
  FETCH_MAX_HEADERS      = 16;

var
  // ---- native ledger ----
  CountConfig: LongInt;
  CountReport: LongInt;
  CountRevoke: LongInt;
  CountFetchSeen: LongInt;      // pweb.fetch invocations that reached the door
  CountFetchRefusedUri: LongInt;
  CountFetchRefusedHeader: LongInt;
  CountFetchAttempted: LongInt; // invocations that reached the HTTP client
  CountFetchOk: LongInt;
  CountFetchFailed: LongInt;
  CountUnexpected: LongInt;
  // ---- report latch ----
  ReportLatch: LongInt;
  ReportJson: RawUtf8;
  AutoCloseHandle: Pointer;
  WatchdogEvent: PRTLEvent;
  // ---- configuration, computed once at startup on the main thread ----
  PortA, PortB: Integer;
  OriginA, OriginB: RawUtf8;
  PublicHttps, PublicOrigin: RawUtf8;
  ModeName: RawUtf8;
  TlsAvailable: RawUtf8;
  // ---- the policy, for the runtime-revocation probe ----
  GlobalPolicy: TPWebCapabilityPolicy;

{ ---------------------------------------------------------------------------
  the spike native door
  --------------------------------------------------------------------------- }

{ the ONE origin allowlist. Native by construction: it is computed from the
  host's own configuration before any window exists and no argument, header
  or page value can extend it. Comparison is on the full origin - scheme,
  host and port - never a prefix of the URL.

  Two entries: the probe server's origin A, and the optional public https
  target, which is what makes the native door's TLS path measurable. Origin B
  is deliberately in NEITHER list - it is how the refusal is measured as an
  absence on the wire. }
function OriginAllowed(const AOrigin: RawUtf8): Boolean;
begin
  Result := (AOrigin <> '') and
            ((AOrigin = OriginA) or
             ((PublicOrigin <> '') and (AOrigin = PublicOrigin)));
end;

{ split scheme://host[:port] off a URL, lower-casing the scheme and host
  exactly as an origin comparison requires. Returns '' for anything that is
  not an absolute http/https URL with a non-empty authority - fail closed. }
function OriginOf(const AUrl: RawUtf8; out ARest: RawUtf8): RawUtf8;
var
  i, authStart: PtrInt;
  scheme: RawUtf8;
begin
  Result := '';
  ARest := '';
  i := PosEx('://', AUrl);
  if (i < 2) then
    exit;
  scheme := LowerCase(Copy(AUrl, 1, i - 1));
  if (scheme <> 'http') and (scheme <> 'https') then
    exit;
  authStart := i + 3;
  i := authStart;
  while (i <= Length(AUrl)) and (AUrl[i] <> '/') and (AUrl[i] <> '?') and
        (AUrl[i] <> '#') do
    inc(i);
  if i = authStart then
    exit; // empty authority
  Result := scheme + '://' + LowerCase(Copy(AUrl, authStart, i - authStart));
  if i <= Length(AUrl) then
    ARest := Copy(AUrl, i, Length(AUrl) - i + 1)
  else
    ARest := '/';
  // an origin carrying credentials is refused outright: user:pass@host is
  // exactly the shape that makes an allowlist comparison a guess
  if PosEx('@', Result) > 0 then
    Result := '';
end;

{ the request-header allowlist. An app needs to authenticate and to say what
  it sends and accepts; it has no business setting the transport's own
  headers, and Cookie is the one that would quietly turn a stateless door
  into an ambient-credential door. }
function HeaderAllowed(const AName: RawUtf8): Boolean;
var
  n: RawUtf8;
begin
  n := LowerCase(AName);
  Result := (n = 'accept') or (n = 'accept-language') or
            (n = 'authorization') or (n = 'content-type') or
            (n = 'if-none-match') or (n = 'if-modified-since') or
            (n = 'x-cap15a');
end;

type
  TSpikeFetchBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    function Fetch(const Args: TPWebJson): TPWebInvocationResult;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

constructor TSpikeFetchBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  if AInner = nil then
    raise Exception.Create('TSpikeFetchBridge requires an inner bridge');
  FInner := AInner;
end;

function TSpikeFetchBridge.Fetch(const Args: TPWebJson): TPWebInvocationResult;
var
  payload, url, rest, origin, method, body, mime, hdrName, hdrValue: RawUtf8;
  headerBlock, respHeaders, bodyText, bodyB64, envelope: RawUtf8;
  v: array[0 .. 4] of TValuePUtf8Char;
  pairs: TNameValuePUtf8CharDynArray;
  headersJson: RawUtf8;
  timeoutMs, status, i, hdrCount: Integer;
  started, elapsed: Int64;
  client: THttpClientSocket;
  uri: TUri;
  content: RawByteString;
  truncated: Boolean;
begin
  InterlockedIncrement(CountFetchSeen);
  // JsonDecode unescapes IN PLACE, exactly as pweb.rpc.command notes: the
  // decode must never walk the invocation's own buffer
  payload := Args;
  UniqueRawUtf8(payload);
  JsonDecode(pointer(payload), ['url', 'method', 'headers', 'body',
    'timeoutMs'], PValuePUtf8CharArray(@v), {handleObjects=}true);
  url := v[0].ToUtf8;
  method := UpperCase(v[1].ToUtf8);
  headersJson := v[2].ToUtf8;
  body := v[3].ToUtf8;
  timeoutMs := Integer(v[4].ToInteger);

  if method = '' then
    method := 'GET';
  if (method <> 'GET') and (method <> 'POST') and (method <> 'PUT') and
     (method <> 'DELETE') and (method <> 'HEAD') then
  begin
    InterlockedIncrement(CountFetchRefusedUri);
    exit(PWebErrorResult(pecInvalidRequest, 'method not allowed: ' + method,
      PWEB_JSON_NULL));
  end;
  if Length(body) > FETCH_MAX_REQUEST_BODY then
  begin
    InterlockedIncrement(CountFetchRefusedUri);
    exit(PWebErrorResult(pecInvalidRequest, 'request body over bound',
      PWEB_JSON_NULL));
  end;
  if (timeoutMs <= 0) then
    timeoutMs := FETCH_DEFAULT_TIMEOUT;
  if timeoutMs > FETCH_MAX_TIMEOUT then
    timeoutMs := FETCH_MAX_TIMEOUT;

  origin := OriginOf(url, rest);
  if not OriginAllowed(origin) then
  begin
    // THE ALLOWLIST REFUSAL: no socket is opened, no name is resolved, and
    // the refused origin never appears in the message either
    InterlockedIncrement(CountFetchRefusedUri);
    exit(PWebErrorResult(pecInvalidRequest, 'origin not in the native allowlist',
      PWEB_JSON_NULL));
  end;

  headerBlock := '';
  hdrCount := 0;
  if (headersJson <> '') and (headersJson[1] = '{') then
  begin
    JsonDecode(pointer(headersJson), pairs, {handleObjects=}true);
    for i := 0 to High(pairs) do
    begin
      hdrName := pairs[i].Name.ToUtf8;
      hdrValue := pairs[i].Value.ToUtf8;
      if not HeaderAllowed(hdrName) then
      begin
        InterlockedIncrement(CountFetchRefusedHeader);
        exit(PWebErrorResult(pecInvalidRequest,
          'header not in the allowlist: ' + LowerCase(hdrName),
          PWEB_JSON_NULL));
      end;
      // a header value carrying CR, LF or NUL is a splitting attempt, not a
      // header: refused on the bytes rather than sanitized
      if (PosEx(#13, hdrValue) > 0) or (PosEx(#10, hdrValue) > 0) or
         (PosEx(#0, hdrValue) > 0) then
      begin
        InterlockedIncrement(CountFetchRefusedHeader);
        exit(PWebErrorResult(pecInvalidRequest, 'header value has a control byte',
          PWEB_JSON_NULL));
      end;
      inc(hdrCount);
      if hdrCount > FETCH_MAX_HEADERS then
      begin
        InterlockedIncrement(CountFetchRefusedHeader);
        exit(PWebErrorResult(pecInvalidRequest, 'too many headers',
          PWEB_JSON_NULL));
      end;
      if LowerCase(hdrName) = 'content-type' then
        mime := hdrValue
      else
        headerBlock := headerBlock + hdrName + ': ' + hdrValue + #13#10;
    end;
  end;

  if not uri.From(url) then
    exit(PWebErrorResult(pecInvalidRequest, 'unparsable url', PWEB_JSON_NULL));

  InterlockedIncrement(CountFetchAttempted);
  started := GetTickCount64;
  status := 0;
  respHeaders := '';
  content := '';
  try
    client := THttpClientSocket.Create(timeoutMs);
    try
      // NO PROXY, by construction: Create + OpenBind consults nothing.
      // mORMot's higher entry points (OpenUri / OpenOptions /
      // TSimpleHttpClient) take THttpRequestExtendedOptions.Proxy, whose
      // default '' means "use the SYSTEM proxy" - so a product that reached
      // for the convenient constructor would route the door through a
      // machine setting nobody declared. Recorded in the artifact as a
      // contract row, not left as a comment in a spike.
      client.RedirectMax := 0; // measured deliberately: see the artifact
      client.UserAgent := 'PWeb-CAP15A-spike';
      client.OpenBind(uri.Server, uri.Port, {doBind=}false, uri.Https);
      status := client.Request(rest, method, {keepalive=}0, headerBlock,
        body, mime);
      content := client.Content;
      respHeaders := client.Headers;
    finally
      client.Free;
    end;
    InterlockedIncrement(CountFetchOk);
  except
    on E: Exception do
    begin
      InterlockedIncrement(CountFetchFailed);
      elapsed := GetTickCount64 - started;
      exit(PWebErrorResult(pecServiceError,
        'transport: ' + RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message),
        '{"ms":' + RawUtf8(IntToStr(elapsed)) + '}'));
    end;
  end;
  elapsed := GetTickCount64 - started;

  truncated := Length(content) > FETCH_MAX_RESPONSE;
  if truncated then
  begin
    // over the response bound: the bytes are dropped rather than delivered
    // partially - a truncated body that looks whole is the worse failure
    exit(PWebErrorResult(pecServiceError, 'response over the ' +
      RawUtf8(IntToStr(FETCH_MAX_RESPONSE)) + ' byte bound',
      '{"ms":' + RawUtf8(IntToStr(elapsed)) + ',"bytes":' +
      RawUtf8(IntToStr(Length(content))) + '}'));
  end;

  bodyText := PWEB_JSON_NULL;
  bodyB64 := PWEB_JSON_NULL;
  if Length(content) <= FETCH_MAX_TEXT_INLINE then
  begin
    if IsValidUtf8(content) then
      bodyText := QuotedStrJson(RawUtf8(content))
    else
      bodyB64 := '"' + BinToBase64(content) + '"';
  end;

  envelope := '{"status":' + RawUtf8(IntToStr(status)) +
    ',"ms":' + RawUtf8(IntToStr(elapsed)) +
    ',"bytes":' + RawUtf8(IntToStr(Length(content))) +
    ',"truncated":false' +
    ',"headers":' + QuotedStrJson(respHeaders) +
    ',"bodyText":' + bodyText +
    ',"bodyBase64":' + bodyB64 + '}';
  Result := PWebSuccessResult(TPWebJson(envelope));
end;

function TSpikeFetchBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = PWEB_METHOD_FETCH then
    Result := Fetch(Args)
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

{ ---------------------------------------------------------------------------
  the harness bridge: configuration, the report latch, the revocation probe
  --------------------------------------------------------------------------- }

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
  end;
end;

procedure RequestTerminate;
var
  handle: Pointer;
begin
  handle := InterlockedExchange(AutoCloseHandle, nil);
  if handle <> nil then
    webview_dispatch(webview_t(handle), @TerminateOnGuiThread, nil);
end;

type
  TProbeBridge = class(TInterfacedObject, IInvocationBridge)
  public
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

function TProbeBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  publicJson: RawUtf8;
begin
  if Method = 'probe.config' then
  begin
    InterlockedIncrement(CountConfig);
    if PublicHttps = '' then
      publicJson := PWEB_JSON_NULL
    else
      publicJson := QuotedStrJson(PublicHttps);
    exit(PWebSuccessResult(TPWebJson(
      '{"mode":"' + ModeName + '"' +
      ',"portA":' + RawUtf8(IntToStr(PortA)) +
      ',"portB":' + RawUtf8(IntToStr(PortB)) +
      ',"publicHttps":' + publicJson +
      ',"tls":' + QuotedStrJson(TlsAvailable) +
      ',"cspInEffect":' + QuotedStrJson(PWEB_NATIVE_CSP) + '}')));
  end;
  if Method = 'probe.revokeNetwork' then
  begin
    InterlockedIncrement(CountRevoke);
    // the CAP-8A runtime-grant factor is an INTERSECTION: this cannot widen
    // anything, and the next pweb.fetch must be answered `forbidden` by the
    // policy at the scheduler - before the door exists for it
    if GlobalPolicy <> nil then
      GlobalPolicy.SetRuntimeGrants(Context.PrincipalId, []);
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  if Method = 'probe.report' then
  begin
    if InterlockedCompareExchange(ReportLatch, 1, 0) = 0 then
      ReportJson := Args;
    InterlockedIncrement(CountReport);
    RequestTerminate;
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  InterlockedIncrement(CountUnexpected);
  Result := PWebDefaultErrorResult(pecMethodNotFound);
end;

type
  { identical to the release host's D9 wrapper }
  TPolicyContextHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FInner: IWebViewInvocationHandler;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy;
  public
    constructor Create(const AInner: IWebViewInvocationHandler;
      const APolicy: TPWebCapabilityPolicy);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

constructor TPolicyContextHandler.Create(
  const AInner: IWebViewInvocationHandler;
  const APolicy: TPWebCapabilityPolicy);
begin
  inherited Create;
  if (AInner = nil) or (APolicy = nil) then
    raise Exception.Create('TPolicyContextHandler requires handler + policy');
  FInner := AInner;
  FPolicy := APolicy;
  FPolicyRef := APolicy;
end;

procedure TPolicyContextHandler.HandleInvocation(
  const Context: TInvocationContext; const Request: TPWebJson;
  const Completion: IInvocationCompletion);
var
  ctx: TInvocationContext;
begin
  ctx := Context;
  ctx.Capabilities := FPolicy.SnapshotCapabilities(ctx.PrincipalId, ctx.WindowId);
  FInner.HandleInvocation(ctx, Request, Completion);
end;

function BuildProbePolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([PWEB_CAP_NETWORK_FETCH]);
    b.SetWindowCapabilities('main', [PWEB_CAP_NETWORK_FETCH]);
    b.SetPrincipalCapabilities('window:main', [PWEB_CAP_NETWORK_FETCH]);
    b.MapMethod(PWEB_METHOD_FETCH, [PWEB_CAP_NETWORK_FETCH]);
    b.RegisterZeroCapMethod('probe.config');
    b.RegisterZeroCapMethod('probe.report');
    b.RegisterZeroCapMethod('probe.revokeNetwork');
    Result := b.Build;
  finally
    b.Free;
  end;
end;

function WatchdogThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  RTLEventWaitFor(WatchdogEvent, PtrInt(Param));
  RequestTerminate;
end;

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := AValue;
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or (Result[i] < #$20) then
      Result[i] := '''';
end;

{$ifdef DARWIN}
procedure CheckCocoaRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create('FPU traps could not be masked - no WebView created');
end;
{$endif DARWIN}

{$ifdef LINUX}
procedure CheckGtkDisplayUsable;
var
  reason: RawUtf8;
begin
  reason := PWebGtkDisplayUnavailableReason;
  if reason = '' then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': GTK DISPLAY UNAVAILABLE (', reason, ')');
  raise Exception.Create('no usable display - no WebView was created');
end;
{$endif LINUX}

var
  w: webview_t;
  store: IAssetStore;
  assetHandler: TPWebAssetHandler;
  navGuard: TPWebNavigationGuard;
  bridge: IInvocationBridge;
  capPolicy: TPWebCapabilityPolicy;
  capPolicyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  root, fixtureDir, outFile: TFileName;
  publicRest: RawUtf8;
  timeoutMs: Integer;
  closerId, closerHandle: system.TThreadID;
  closerStarted, safeToDestroy, schedulerDrained: Boolean;
  failReasons: RawUtf8;
  pageReport, json: RawUtf8;
  stream: TFileStream;

procedure Fail(const AReason: RawUtf8);
begin
  if failReasons <> '' then
    failReasons := failReasons + '; ';
  failReasons := failReasons + AReason;
end;

function EnvInt(const AName: RawUtf8; ADefault: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(string(AName)), ADefault);
  if (Result <= 0) or (Result > 65535) then
    Result := ADefault;
end;

begin
  ExitCode := 0;
  scheduler := nil;
  assetHandler := nil;
  navGuard := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  failReasons := '';
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock marker) not found');
      fixtureDir := root + 'test' + PathDelim + 'cap15a' + PathDelim + 'fixture';
      if not FileExists(fixtureDir + PathDelim + 'index.html') then
        raise Exception.Create('fixture missing: ' + string(fixtureDir));

      PortA := EnvInt('PWEB_CAP15A_PORT_A', 41597);
      PortB := EnvInt('PWEB_CAP15A_PORT_B', 41598);
      OriginA := 'http://127.0.0.1:' + RawUtf8(IntToStr(PortA));
      OriginB := 'http://127.0.0.1:' + RawUtf8(IntToStr(PortB));
      PublicHttps := RawUtf8(GetEnvironmentVariable('PWEB_CAP15A_PUBLIC_HTTPS'));
      PublicOrigin := '';
      if PublicHttps <> '' then
        PublicOrigin := OriginOf(PublicHttps, publicRest);

      // THE MODE IS DERIVED FROM THE POLICY THE BINARY CARRIES, never from
      // the environment: a report that claimed `baseline` while linked
      // against the widened shim would be the one lie this shard cannot
      // afford
      if PosEx(RawUtf8('127.0.0.1'), PWEB_NATIVE_CSP) > 0 then
        ModeName := 'widened'
      else
        ModeName := 'baseline';

      {$ifdef CAP15A_OPENSSL}
      if OpenSslIsAvailable then
        TlsAvailable := 'openssl available: ' + OpenSslVersionText
      else
        TlsAvailable := 'openssl NOT available';
      {$else}
      {$ifdef OSWINDOWS}
      TlsAvailable := 'schannel (mORMot built-in)';
      {$else}
      TlsAvailable := 'no TLS provider linked into this build';
      {$endif OSWINDOWS}
      {$endif CAP15A_OPENSSL}

      outFile := root + 'build' + PathDelim + 'cap15a' + PathDelim +
        TARGET_ID + '-' + string(ModeName) + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' + string(ExtractFilePath(outFile)));

      timeoutMs := EnvInt('PWEB_CAP15A_TIMEOUT_MS', DEFAULT_TIMEOUT_MS);
      if timeoutMs > MAX_TIMEOUT_MS then
        timeoutMs := MAX_TIMEOUT_MS;

      WriteLn(LOG_PREFIX, ': target=', TARGET_ID, ' mode=', ModeName,
        ' portA=', PortA, ' portB=', PortB);
      WriteLn(LOG_PREFIX, ': csp=', PWEB_NATIVE_CSP);
      WriteLn(LOG_PREFIX, ': tls=', TlsAvailable);

      store := TFolderAssetStore.Create(fixtureDir);
      // the spike door OVER the harness bridge, in the ratified decorator
      // shape: pweb.fetch is intercepted, everything else is delegated
      bridge := TSpikeFetchBridge.Create(TProbeBridge.Create);
      capPolicy := BuildProbePolicy;
      GlobalPolicy := capPolicy;
      capPolicyRef := capPolicy;
      scheduler := TInvocationScheduler.Create(capPolicyRef, bridge, 4);
      schedulerRef := scheduler;
      limits := Default(TPWebSourceLimits);
      limits.MaxConcurrent := 4;
      limits.MaxQueueSize := 64;
      source := scheduler.RegisterSource(limits);

      {$ifdef DARWIN}
      CheckCocoaRuntimeUsable;
      assetHandler := TCocoaAssetHandler.Create(store);
      {$else}
      {$ifdef LINUX}
      CheckGtkDisplayUsable;
      {$endif LINUX}
      {$endif DARWIN}

      if GetEnvironmentVariable('PWEB_CAP15A_DEBUG') = '1' then
        w := WebViewCheckCreated(webview_create(1, nil))
      else
        w := WebViewCheckCreated(webview_create(0, nil));
      try
        {$ifdef DARWIN}
        assetHandler.Attach(w);
        {$endif DARWIN}
        AutoCloseHandle := Pointer(w);
        context := Default(TInvocationContext);
        context.WindowId := 'main';
        context.PrincipalId := 'window:main';
        context.PrincipalKind := pkWindow;
        context.TrustedContent := True;
        opts := PWebDefaultBindingOptions(context);
        binding := TWebViewBinding.Create(w, source, opts);
        binding.Bind('__pweb_invoke', TPolicyContextHandler.Create(
          TPWebEnvelopeHandler.Create(source), capPolicy));
        WebViewCheck(webview_set_title(w, 'PWeb CAP-15A network probe'),
          'webview_set_title');
        WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
          'webview_set_size');
        {$ifndef DARWIN}
        {$ifdef LINUX}
        assetHandler := TWebKitGtkAssetHandler.Create(w, store);
        {$else}
        assetHandler := TWebView2AssetHandler.Create(w, store);
        {$endif LINUX}
        {$endif DARWIN}
        {$ifdef DARWIN}
        navGuard := TPWebNavigationGuard.Create;
        navGuard.Attach(w);
        {$else}
        navGuard := TPWebNavigationGuard.Create(w);
        {$endif DARWIN}
        WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

        WatchdogEvent := RTLEventCreate;
        closerHandle := BeginThread(@WatchdogThread,
          Pointer(PtrInt(timeoutMs)), closerId);
        closerStarted := closerHandle <> system.TThreadID(0);
        if not closerStarted then
          raise Exception.Create('unable to start the watchdog thread');
        WebViewCheck(webview_run(w), 'webview_run');
      finally
        if closerStarted then
        begin
          InterlockedExchange(AutoCloseHandle, nil);
          RTLEventSetEvent(WatchdogEvent);
          if WaitForThreadTerminate(closerHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL watchdog did not terminate');
            safeToDestroy := False;
            ExitCode := 1;
          end;
          CloseThread(closerHandle);
        end;
        if WatchdogEvent <> nil then
        begin
          if safeToDestroy then
            RTLEventDestroy(WatchdogEvent);
          WatchdogEvent := nil;
        end;
        InterlockedExchange(AutoCloseHandle, nil);
        if binding <> nil then
          try
            binding.Close;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL binding Close: ', E.Message);
              ExitCode := 1;
            end;
          end;
        if schedulerRef <> nil then
          try
            schedulerRef.Shutdown;
            schedulerDrained := True;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL scheduler Shutdown: ', E.Message);
              ExitCode := 1;
            end;
          end;
        if navGuard <> nil then
        begin
          try
            navGuard.Detach;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL guard Detach: ', E.Message);
              ExitCode := 1;
            end;
          end;
          try
            FreeAndNil(navGuard);
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL guard Free: ', E.Message);
              ExitCode := 1;
            end;
          end;
        end;
        if assetHandler <> nil then
        begin
          try
            assetHandler.Detach;
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL handler Detach: ', E.Message);
              ExitCode := 1;
            end;
          end;
          FreeAndNil(assetHandler);
        end;
        if safeToDestroy then
          try
            WebViewCheck(webview_destroy(w), 'webview_destroy');
          except
            on E: Exception do
            begin
              WriteLn(StdErr, LOG_PREFIX, ': FAIL webview_destroy: ', E.Message);
              ExitCode := 1;
            end;
          end;
      end;

      pageReport := ReportJson;
      if pageReport = '' then
        Fail('no probe.report arrived (watchdog or crash)');
      if CountConfig <> 1 then
        Fail('probe.config arrived ' + RawUtf8(IntToStr(CountConfig)) +
          ' times, expected 1');
      if CountUnexpected <> 0 then
        Fail('unexpected methods reached the bridge: ' +
          RawUtf8(IntToStr(CountUnexpected)));

      // BASELINE ASSERTIONS - the shipped invariant, and only here. The
      // native door must have worked (that is door A's whole claim) while
      // the engine reached nothing at all; the engine half is asserted from
      // the server's log by the run script, which is the only witness that
      // cannot be fooled by a page that misreports.
      if ModeName = 'baseline' then
      begin
        if CountFetchAttempted < 1 then
          Fail('baseline: the native door never reached the HTTP client');
        if CountFetchOk < 1 then
          Fail('baseline: no native fetch succeeded');
        if CountFetchRefusedUri < 1 then
          Fail('baseline: the origin allowlist refused nothing - the ' +
            'unnamed-origin row did not run');
      end;

      if ExitCode <> 0 then
        Fail('a teardown step failed (see stderr)');

      if pageReport = '' then
        pageReport := 'null';
      json := '{' + #10 +
        '  "schema": 1,' + #10 +
        '  "target": "' + TARGET_ID + '",' + #10 +
        '  "mode": "' + ModeName + '",' + #10 +
        '  "csp": ' + QuotedStrJson(PWEB_NATIVE_CSP) + ',' + #10 +
        '  "tls": ' + QuotedStrJson(TlsAvailable) + ',' + #10 +
        '  "originA": "' + OriginA + '",' + #10 +
        '  "originB": "' + OriginB + '",' + #10 +
        '  "overall": "';
      if failReasons = '' then
        json := json + 'COMPLETE'
      else
        json := json + 'FAIL';
      json := json + '",' + #10;
      if failReasons <> '' then
        json := json + '  "failures": "' + JsonSafeText(failReasons) + '",' + #10;
      json := json +
        '  "native": {' + #10 +
        '    "config": ' + RawUtf8(IntToStr(CountConfig)) + ',' + #10 +
        '    "report": ' + RawUtf8(IntToStr(CountReport)) + ',' + #10 +
        '    "revoke": ' + RawUtf8(IntToStr(CountRevoke)) + ',' + #10 +
        '    "fetch_seen": ' + RawUtf8(IntToStr(CountFetchSeen)) + ',' + #10 +
        '    "fetch_refused_uri": ' + RawUtf8(IntToStr(CountFetchRefusedUri)) + ',' + #10 +
        '    "fetch_refused_header": ' + RawUtf8(IntToStr(CountFetchRefusedHeader)) + ',' + #10 +
        '    "fetch_attempted": ' + RawUtf8(IntToStr(CountFetchAttempted)) + ',' + #10 +
        '    "fetch_ok": ' + RawUtf8(IntToStr(CountFetchOk)) + ',' + #10 +
        '    "fetch_failed": ' + RawUtf8(IntToStr(CountFetchFailed)) + ',' + #10 +
        '    "unexpected_methods": ' + RawUtf8(IntToStr(CountUnexpected)) + #10 +
        '  },' + #10 +
        '  "page": ' + pageReport + #10 +
        '}' + #10;
      stream := TFileStream.Create(outFile, fmCreate);
      try
        if json <> '' then
          stream.WriteBuffer(json[1], Length(json));
      finally
        stream.Free;
      end;

      if failReasons = '' then
        WriteLn(MARKER_PASS)
      else
      begin
        WriteLn(StdErr, MARKER_FAIL, ' (', failReasons, ')');
        ExitCode := 1;
      end;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL ', E.ClassName, ': ', E.Message);
        WriteLn(StdErr, MARKER_FAIL, ' (', E.Message, ')');
        ExitCode := 1;
      end;
    end;
  finally
    if (scheduler <> nil) and not schedulerDrained then
      try
        scheduler.Shutdown;
      except
        on E: Exception do
        begin
          WriteLn(StdErr, LOG_PREFIX, ': FAIL final Shutdown: ', E.Message);
          ExitCode := 1;
        end;
      end;
    try
      GlobalPolicy := nil;
      binding := nil;
      source := nil;
      schedulerRef := nil;
      scheduler := nil;
      capPolicyRef := nil;
      capPolicy := nil;
      bridge := nil;
      store := nil;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL final teardown: ', E.Message);
        ExitCode := 1;
      end;
    end;
  end;
end.
