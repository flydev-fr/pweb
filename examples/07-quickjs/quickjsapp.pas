program quickjsapp;

{ CAP-9C2 plugin-enabled release runtime proof (all four targets):

    quickjsapp + app.pwb + plugins.zip - the release layout, nothing else.

  ONE process, ONE scheduler, ONE CAP-8 policy, ONE bridge chain, ONE
  mORMot server, ONE error taxonomy, and TWO invocation SOURCES:

    real WebView UI -> pweb://app -> TypeScript SDK -> scheduler ->
      CAP-8 policy -> bridge -> mORMot -> CalculatorService.Add = 42

    verified plugins.zip -> generated native registry -> isolated QuickJS
      plugin generation -> the SAME scheduler -> the SAME policy object ->
      the SAME bridge object -> the SAME server -> CalculatorService.Add = 42

  THE TWO ARCHIVES ARE INDEPENDENT SECURITY DOMAINS, and this file is
  where that is enforced rather than asserted:
    - app.pwb is browser content. It is opened by the CAP-6 bundle
      loader and the ONLY store ever handed to a platform asset handler.
    - plugins.zip is native QuickJS package content. It is opened by the
      CAP-9C1 verifier and the ONLY store ever handed to the package
      loader.
  They are two DIFFERENT variables with two different names, each
  wrapped in its own counting decorator, and neither is ever assigned
  from the other. There is no fallback from one archive to the other, no
  pweb:// authority under which the package is mounted, and no plugin
  URL scheme.

  WHAT IS AUTHORITATIVE. The generated registry compiled into this
  executable (-Fi, never shipped as a file) pins the package file name,
  its exact SHA-256 and byte length, its semantic inventory and every
  plugin's identity, entry point, module-graph digest and resource
  bounds. Capabilities are NOT in it: they come from the CAP-8 policy
  built below, keyed by the registry's native PrincipalId. Nothing in
  the archive can reach any of that.

  STARTUP IS FAIL-CLOSED AND ORDERED. app.pwb is resolved from the
  executable/bundle location and validated; plugins.zip is resolved the
  same way and its whole-archive digest, semantic inventory and registry
  coherence are verified BEFORE the first service, policy, bridge,
  scheduler, engine or WebView exists. A whole-package failure exits
  nonzero with webviews_created = 0, engines_created = 0 and
  soa_calls = 0. Past that gate one plugin's failure fails only that
  plugin, and is recorded.

  THE GATE THREAD. webview_run owns the GUI thread, so the acceptance
  sequence runs on a dedicated gate thread started just after navigate.
  It waits for the page's two reports, then drives the plugin half and
  drives the UI half back through webview_dispatch + webview_eval - real
  invocations on the real transport, never a simulation - and finally
  dispatches webview_terminate. Overlap is forced by a barrier INSIDE
  CalculatorService.Add, so "the UI and a plugin ran concurrently" is
  two invocations provably inside one service instance at one time, not
  a sleep.

    quickjsapp [--pweb-verdict=<file>] [--pweb-corpus=<file>]
               [--pweb-autoclose-ms=<N>] }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode, // StringReplaceAll, for the UI-round script template
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.rpc.command, // CAP-10A: the reusable runtime-command decorator
  pweb.capabilities.policy,
  pweb.navigation.policy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.bundle,
  pweb.script.package,
  pweb.script.quickjs,
  pweb.script.plugin,
  pweb.script.release,
  pweb.script.startup,
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2,
  pweb.platform.webview2.runtime
  {$endif LINUX}
  {$endif DARWIN}
  ;

{ The GENERATED native registry - the trust anchor, compiled in with -Fi
  and never shipped as a runtime file. It is emitted per target because
  the archive is deterministic per TOOLCHAIN, not across them (CAP-9C1
  measured three distinct DEFLATE outputs across the four targets). }
{$I pweb.quickjs.registry.inc}

type
  { The platform-selected names, exactly as examples/08-release: the
    Windows and Linux handlers/guards are Create(...)/Detach/Destroy and
    the Cocoa ones are the same surface split in two, because upstream
    builds the WKWebViewConfiguration inside webview_create. }
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
  APP_TITLE = 'PWeb CAP-9 QuickJS';
  LOG_PREFIX = 'quickjsapp';
  MAX_AUTOCLOSE_MS = 300000;
  CLOSER_WAIT_MARGIN_MS = 15000;
  { The canonical runtime verdict, spelled ONCE - printed to stdout and
    written to the --pweb-verdict file. }
  VERDICT_PASS =
    ': app.pwb + plugins.zip -> pweb://app + QuickJS -> SDK -> mORMot -> 42 PASS';
  ARG_VERDICT = '--pweb-verdict=';
  ARG_CORPUS = '--pweb-corpus=';
  ARG_AUTOCLOSE = '--pweb-autoclose-ms=';

  { CAP-10A: the external-open method and its capability are no longer
    spelled here. They come from pweb.rpc.command as
    PWEB_METHOD_OPEN_EXTERNAL / PWEB_CAP_EXTERNAL_OPEN, beside the ONE
    implementation of the command; this host keeps only the platform
    opener and the counter its own gates read. }
  METHOD_REPORT = 'example.report';
  METHOD_PLUGIN_PROBE = 'example.pluginProbe';
  METHOD_CONCURRENT = 'example.concurrent';
  CAP_CALCULATOR_ADD = 'calculator.add';
  CAP_PARKING_READ = 'parking.read';

  PRINCIPAL_WINDOW = 'window:main';
  PRINCIPAL_CALCULATOR = 'plugin:calculator';
  PRINCIPAL_REPORTING = 'plugin:reporting';
  PLUGIN_CALCULATOR = 'quickjs.calculator';
  PLUGIN_REPORTING = 'quickjs.reporting';

  { bounded waits - every one of them, no unbounded blocking anywhere }
  REPORT_WAIT_MS = 60000;
  { bounds ONE export call, so it must comfortably exceed the ratified
    10s CPU bound the runaway export is there to hit - otherwise the
    containment leg would time out instead of being contained }
  EXPORT_WAIT_MS = 45000;
  UI_ROUND_WAIT_MS = 30000;
  { How long ONE barrier arrival waits for its peer.
    It must stay comfortably BELOW the bounded wait a plugin's
    pweb.invoke performs (PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs,
    15000), because the plugin sits inside that wait for the whole
    rendezvous PLUS the service call and the completion delivery that
    follow it. Whichever bound expires first decides what the failure is
    CALLED, and only this one names the real condition - a peer that did
    not arrive - so it must be the one that fires. RunGate refuses to
    start if that ordering is ever inverted; see the guard there for the
    hosted run that measured the inverted case. }
  BARRIER_WAIT_MS = 8000;
  READY_WAIT_MS = 20000;
  UNLOAD_JOIN_MS = 20000;

type
  ICalculatorService = interface(IInvokable)
    ['{F2D880F7-0EE4-4EBE-8371-FBB16467BE41}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Counting IAssetStore decorator. app.pwb and plugins.zip each get
    their own instance, so "the browser never reached the package bytes"
    is a NUMBER this process measured and not the absence of a code
    path - the CAP-8B lesson, applied to stores. }
  TCountingAssetStore = class(TInterfacedObject, IAssetStore)
  private
    FInner: IAssetStore;
    FReads: LongInt;
    FHits: LongInt;
  public
    constructor Create(const AInner: IAssetStore);
    function TryRead(const Path: RawUtf8; out Asset: TAssetResponse): Boolean;
    function Reads: LongInt;
    function Hits: LongInt;
  end;

  { Counting ICapabilityPolicy decorator. It DECIDES nothing: every
    answer is the production policy's. What it adds is the per-kind
    observation that makes same_policy a measured fact - the identity
    token recorded when a pkWindow invocation is checked must equal the
    one recorded when a pkQuickJS invocation is checked. }
  TIdentityPolicy = class(TInterfacedObject, ICapabilityPolicy)
  private
    FInner: ICapabilityPolicy;
    FToken: Integer;
  public
    constructor Create(const AInner: ICapabilityPolicy);
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
    property Token: Integer read FToken;
  end;

  { The host-owned bridge decorator: the two runtime methods this host
    implements itself (pweb.openExternal, and the page's report
    channels), plus the per-kind identity/in-flight accounting that
    makes same_bridge, same_server and the overlap proof measurable.
    Every application method still passes straight to the real bridge. }
  TGateBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    FToken: Integer;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    property Token: Integer read FToken;
  end;

  { CAP-8A ratified D9 wrapper: populates Context.Capabilities with the
    policy's PER-INVOCATION effective snapshot before delegating. }
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

  { Mints ONE invocation source per plugin generation from THE scheduler,
    and remembers every source it minted so the same_scheduler gate can
    ask the scheduler itself whether it owns them. Also carries the
    CAP-8 snapshot callback, keyed by the registry's native PrincipalId. }
  TPluginWiring = class
  private
    FScheduler: TInvocationScheduler;
    FPolicy: TPWebCapabilityPolicy;
    FSources: array of IInvocationSource;
    FLock: TCriticalSection;
  public
    constructor Create(AScheduler: TInvocationScheduler;
      APolicy: TPWebCapabilityPolicy);
    destructor Destroy; override;
    function MintSource: IInvocationSource;
    function Snapshot(const APrincipalId: Utf8String): TPWebCapabilities;
    function SourceCount: Integer;
    function SourceAt(AIndex: Integer): IInvocationSource;
  end;

var
  { --- identity tokens: a host-private map from object to a small
    monotonic id in first-seen order. Addresses never leave this
    process; the corpus carries ordinals. --- }
  IdentityLock: TCriticalSection;
  IdentityObjects: array of TObject;

  { --- stores: TWO variables, deliberately never assigned from each
    other, each behind its own counter --- }
  AppStore: IAssetStore;
  PluginStore: IAssetStore;
  AppCounter: TCountingAssetStore;
  PluginCounter: TCountingAssetStore;

  { --- pre-WebView / pre-engine markers: read on every exit path --- }
  WebViewsCreated: LongInt;
  PackageVerified: LongInt;
  { every Add that ever ran did so on the SAME object: the identity
    token is taken inside the method, so a second service instance
    anywhere would show up here as a mismatch. mORMot instantiates a
    sicShared implementation through the non-virtual TInterfacedObject
    constructor, so counting in a constructor would count nothing -
    which is exactly the kind of silently-zero evidence this shard is
    supposed to refuse. }
  ServiceTokenMismatch: LongInt;
  PolicyInstances: LongInt;
  BridgeInstances: LongInt;
  ShutdownFailures: LongInt;

  { --- service / SOA --- }
  ServiceAddCalls: LongInt;
  LastServiceToken: LongInt;
  ServiceThreadId: LongInt;
  GuiThreadId: LongInt;

  { --- per-kind identity observations --- }
  PolicyTokenWindow, PolicyTokenPlugin: LongInt;
  BridgeTokenWindow, BridgeTokenPlugin: LongInt;
  ServiceTokenWindow, ServiceTokenPlugin: LongInt;
  BridgeWindowCalls, BridgePluginCalls: LongInt;
  { every bridge arrival carrying the DENIED plugin principal - must stay 0 }
  DeniedBridgeArrivals: LongInt;
  DeniedSoaArrivals: LongInt;
  OpenerReached: LongInt;

  { --- concurrency --- }
  InFlightWindow, InFlightPlugin: LongInt;
  OverlapObserved: LongInt;
  BarrierArmed, BarrierArrivals, BarrierPeak, BarrierInService: LongInt;
  BarrierEvent: PRTLEvent;

  { --- page reports --- }
  ReportState: LongInt;      // 0 none, 1 pass, 2 fail
  ProbeState: LongInt;
  ReportEvent, ProbeEvent: PRTLEvent;
  ProbeSummary: RawUtf8;
  { --- UI round driven from the gate thread --- }
  UiRoundEvent: PRTLEvent;
  UiRoundJson: RawUtf8;
  UiRoundLock: TCriticalSection;

  { --- corpus --- }
  CorpusLock: TCriticalSection;
  CorpusRows: RawUtf8;
  GateFailures: LongInt;

  { --- wiring --- }
  Scheduler: TInvocationScheduler;
  DecoyScheduler: TInvocationScheduler;
  DecoySchedulerRef: IInvocationScheduler;
  UiSource: IInvocationSource;
  Wiring: TPluginWiring;
  Loader: TPWebQuickJSPackageLoader;
  WebViewHandle: Pointer;
  GateThreadDone: PRTLEvent;
  EvalScript: RawUtf8;
  EvalLock: TCriticalSection;

{ ---------------- identity tokens ---------------- }

function IdentityToken(AObject: TObject): Integer;
var
  i: Integer;
begin
  Result := 0;
  if AObject = nil then
    exit;
  IdentityLock.Acquire;
  try
    for i := 0 to High(IdentityObjects) do
      if IdentityObjects[i] = AObject then
        exit(i + 1);
    SetLength(IdentityObjects, Length(IdentityObjects) + 1);
    IdentityObjects[High(IdentityObjects)] := AObject;
    Result := Length(IdentityObjects);
  finally
    IdentityLock.Release;
  end;
end;

{ ---------------- corpus ---------------- }

{ TWO streams, deliberately. The CORPUS carries only facts that are
  identical on every target - a gate's verdict, an identity, an ordering
  - because it is hashed into one digest the aggregator requires to be
  equal on all four. The LOG carries the same row plus its measured
  detail, which is exactly the part that legitimately differs: how many
  asset reads a particular engine made, what a result JSON looked like.
  Hashing the detail would turn honest per-engine variation into a
  cross-target failure. }
procedure Emit(const ACorpusLine, ADetail: RawUtf8);
begin
  CorpusLock.Acquire;
  try
    CorpusRows := CorpusRows + ACorpusLine + #10;
  finally
    CorpusLock.Release;
  end;
  if ADetail = '' then
    WriteLn(LOG_PREFIX, ' row: ', ACorpusLine)
  else
    WriteLn(LOG_PREFIX, ' row: ', ACorpusLine, ' | ', ADetail);
end;

function N(AValue: Int64): RawUtf8;
begin
  Result := Int64ToUtf8(AValue);
end;

function YesNo(AValue: Boolean): RawUtf8;
begin
  if AValue then
    Result := 'yes'
  else
    Result := 'no';
end;

{ ONE place where a gate row is judged, so a failing row can never be
  emitted without also failing the run. }
procedure Require(const AName: RawUtf8; AOk: Boolean; const ADetail: RawUtf8);
begin
  Emit(AName + '=' + YesNo(AOk), ADetail);
  if not AOk then
  begin
    InterlockedIncrement(GateFailures);
    WriteLn(StdErr, LOG_PREFIX, ': GATE FAILED ', AName, ' ', ADetail);
  end;
end;

function JsonHas(const AJson, ASub: RawUtf8): Boolean;
begin
  Result := Pos(ASub, AJson) > 0;
end;

{ ---------------- service ---------------- }

function TCalculatorService.Add(a, b: Integer): Integer;
var
  inside, peak, token, previous: LongInt;
  waited: Int64;
begin
  InterlockedExchange(ServiceThreadId, LongInt(GetCurrentThreadId));
  token := LongInt(IdentityToken(Self));
  previous := InterlockedExchange(LastServiceToken, token);
  if (previous <> 0) and (previous <> token) then
    InterlockedIncrement(ServiceTokenMismatch);
  InterlockedIncrement(ServiceAddCalls);
  { The overlap proof, and the reason there is no sleep anywhere in this
    program: when the barrier is armed BOTH invocations must be inside
    this method at the same time before either may leave it. If the UI
    and the plugin were not genuinely concurrent, the first arrival
    would time out and the row would go red. }
  if InterlockedCompareExchange(BarrierArmed, 0, 0) = 1 then
  begin
    inside := InterlockedIncrement(BarrierInService);
    repeat
      peak := InterlockedCompareExchange(BarrierPeak, 0, 0);
      if inside <= peak then
        break;
    until InterlockedCompareExchange(BarrierPeak, inside, peak) = peak;
    InterlockedIncrement(BarrierArrivals);
    { wake a peer that is already waiting - and do NOT re-signal inside
      the loop below. A wait that keeps setting the event it is waiting
      on never blocks, so the budget would be spent in microseconds and
      the barrier would report "no overlap" for a run that simply never
      waited. MEASURED that way before the clock became the bound. }
    RTLEventSetEvent(BarrierEvent);
    waited := GetTickCount64;
    while (InterlockedCompareExchange(BarrierInService, 0, 0) < 2) and
          (Int64(GetTickCount64) - waited < BARRIER_WAIT_MS) do
      RTLEventWaitFor(BarrierEvent, 25);
    InterlockedDecrement(BarrierInService);
  end;
  Result := a + b;
end;

{ ---------------- counting asset store ---------------- }

constructor TCountingAssetStore.Create(const AInner: IAssetStore);
begin
  inherited Create;
  if AInner = nil then
    raise Exception.Create('TCountingAssetStore requires an inner store');
  FInner := AInner;
end;

function TCountingAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
begin
  InterlockedIncrement(FReads);
  Result := FInner.TryRead(Path, Asset);
  if Result then
    InterlockedIncrement(FHits);
end;

function TCountingAssetStore.Reads: LongInt;
begin
  Result := InterlockedCompareExchange(FReads, 0, 0);
end;

function TCountingAssetStore.Hits: LongInt;
begin
  Result := InterlockedCompareExchange(FHits, 0, 0);
end;

{ ---------------- identity policy ---------------- }

constructor TIdentityPolicy.Create(const AInner: ICapabilityPolicy);
begin
  inherited Create;
  if AInner = nil then
    raise Exception.Create('TIdentityPolicy requires an inner policy');
  FInner := AInner;
  FToken := IdentityToken(Self);
  InterlockedIncrement(PolicyInstances);
end;

function TIdentityPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
begin
  case Context.PrincipalKind of
    pkWindow:  InterlockedExchange(PolicyTokenWindow, FToken);
    pkQuickJS: InterlockedExchange(PolicyTokenPlugin, FToken);
  end;
  Result := FInner.IsAllowed(Context, Method);
end;

{ ---------------- CAP-8B external opener ---------------- }

function OpenExternalUri(const AUri: RawUtf8): Boolean;
begin
  InterlockedIncrement(OpenerReached);
  {$ifdef DARWIN}
  Result := PWebCocoaOpenExternal(AUri);
  {$else}
  {$ifdef LINUX}
  Result := PWebGtkOpenExternalUri(AUri);
  {$else}
  Result := PWebWv2OpenExternal(AUri);
  {$endif LINUX}
  {$endif DARWIN}
end;

{ CAP-10A: the host's OBSERVATION of an external open. The decision moved
  to pweb.rpc.command; the redacted log line - byte length and outcome
  category, never the URI - is unchanged from CAP-8B. OpenerReached is
  still incremented inside the opener above, so the gate that asserts the
  denied principals reach the opener ZERO times reads exactly the number it
  read before. }
procedure ObserveExternalOpen(const Context: TInvocationContext;
  Outcome: TPWebOpenOutcome; UriBytes: PtrInt);
begin
  case Outcome of
    pooRefused:
      WriteLn(LOG_PREFIX, ': openExternal REFUSED (uri bytes=', UriBytes, ')');
    pooFailed:
      WriteLn(StdErr, LOG_PREFIX, ': openExternal FAILED (uri bytes=',
        UriBytes, ')');
    pooOpened:
      WriteLn(LOG_PREFIX, ': openExternal OK (uri bytes=', UriBytes, ')');
  end;
end;

{ ---------------- gate bridge ---------------- }

constructor TGateBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
  FToken := IdentityToken(Self);
  InterlockedIncrement(BridgeInstances);
end;

procedure LatchPageReport(const Args: TPWebJson);
begin
  WriteLn(LOG_PREFIX, ' report: ', Args);
  if JsonHas(Args, '"ok":true') and
     JsonHas(Args, '"handshake":true') and
     JsonHas(Args, '"secure":true') and
     JsonHas(Args, '"rendered":true') and
     JsonHas(Args, '"rpc":true') and
     JsonHas(Args, '"errmap":true') and
     JsonHas(Args, '"denied":true') and
     JsonHas(Args, '"navExternalBlocked":true') and
     JsonHas(Args, '"navAuthorityBlocked":true') and
     JsonHas(Args, '"navCspBlocked":true') and
     JsonHas(Args, '"navOpenExternal":true') and
     (JsonHas(Args, '"value":42}') or JsonHas(Args, '"value":42,')) and
     (InterlockedCompareExchange(ServiceThreadId, 0, 0) <> 0) and
     (InterlockedCompareExchange(ServiceThreadId, 0, 0) <>
      InterlockedCompareExchange(GuiThreadId, 0, 0)) then
    InterlockedCompareExchange(ReportState, 1, 0)
  else
    InterlockedCompareExchange(ReportState, 2, 0);
  RTLEventSetEvent(ReportEvent);
end;

procedure LatchProbeReport(const Args: TPWebJson);
begin
  WriteLn(LOG_PREFIX, ' pluginProbe: ', Args);
  CorpusLock.Acquire;
  try
    if ProbeSummary = '' then
      ProbeSummary := Args;
  finally
    CorpusLock.Release;
  end;
  if JsonHas(Args, '"ok":true') and
     JsonHas(Args, '"control":true') and
     JsonHas(Args, '"secure":true') and
     JsonHas(Args, '"scriptExecuted":false') and
     JsonHas(Args, '"assetServed":[]') and
     JsonHas(Args, '"sourceBytes":0') and
     JsonHas(Args, '"leakedPath":0') and
     JsonHas(Args, '"leakedDigest":0') then
    InterlockedCompareExchange(ProbeState, 1, 0)
  else
    InterlockedCompareExchange(ProbeState, 2, 0);
  RTLEventSetEvent(ProbeEvent);
end;

function TGateBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  before: LongInt;
begin
  { per-kind identity + in-flight accounting. The overlap flag is set
    when an arrival finds a peer of the OTHER kind already in flight -
    a fact about this bridge object, observed by this bridge object. }
  case Context.PrincipalKind of
    pkWindow:
      begin
        InterlockedExchange(BridgeTokenWindow, FToken);
        InterlockedIncrement(BridgeWindowCalls);
        if InterlockedIncrement(InFlightWindow) >= 1 then
          if InterlockedCompareExchange(InFlightPlugin, 0, 0) >= 1 then
            InterlockedExchange(OverlapObserved, 1);
      end;
    pkQuickJS:
      begin
        InterlockedExchange(BridgeTokenPlugin, FToken);
        InterlockedIncrement(BridgePluginCalls);
        if Context.PrincipalId = PRINCIPAL_REPORTING then
          InterlockedIncrement(DeniedBridgeArrivals);
        if InterlockedIncrement(InFlightPlugin) >= 1 then
          if InterlockedCompareExchange(InFlightWindow, 0, 0) >= 1 then
            InterlockedExchange(OverlapObserved, 1);
      end;
  end;
  before := InterlockedCompareExchange(ServiceAddCalls, 0, 0);
  try
    if Method = METHOD_REPORT then
    begin
      LatchPageReport(Args);
      Result := PWebSuccessResult(PWEB_JSON_NULL);
    end
    else if Method = METHOD_PLUGIN_PROBE then
    begin
      LatchProbeReport(Args);
      Result := PWebSuccessResult(PWEB_JSON_NULL);
    end
    else if Method = METHOD_CONCURRENT then
    begin
      UiRoundLock.Acquire;
      try
        UiRoundJson := Args;
      finally
        UiRoundLock.Release;
      end;
      RTLEventSetEvent(UiRoundEvent);
      Result := PWebSuccessResult(PWEB_JSON_NULL);
    end
    else
      Result := FInner.Invoke(Context, Method, Args, Token);
    { the SOA reach observation: only the calculator service increments
      ServiceAddCalls, and there is exactly one instance of it (asserted
      separately), so recording its identity token per kind is what makes
      same_server a measurement rather than a construction claim }
    if InterlockedCompareExchange(ServiceAddCalls, 0, 0) <> before then
      case Context.PrincipalKind of
        pkWindow:
          InterlockedExchange(ServiceTokenWindow,
            InterlockedCompareExchange(LastServiceToken, 0, 0));
        pkQuickJS:
          begin
            InterlockedExchange(ServiceTokenPlugin,
              InterlockedCompareExchange(LastServiceToken, 0, 0));
            if Context.PrincipalId = PRINCIPAL_REPORTING then
              InterlockedIncrement(DeniedSoaArrivals);
          end;
      end;
  finally
    case Context.PrincipalKind of
      pkWindow: InterlockedDecrement(InFlightWindow);
      pkQuickJS: InterlockedDecrement(InFlightPlugin);
    end;
  end;
end;

{ ---------------- policy context handler ---------------- }

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
  ctx.Capabilities := FPolicy.SnapshotCapabilities(
    ctx.PrincipalId, ctx.WindowId);
  FInner.HandleInvocation(ctx, Request, Completion);
end;

{ ---------------- plugin wiring ---------------- }

constructor TPluginWiring.Create(AScheduler: TInvocationScheduler;
  APolicy: TPWebCapabilityPolicy);
begin
  inherited Create;
  if (AScheduler = nil) or (APolicy = nil) then
    raise Exception.Create('TPluginWiring requires scheduler + policy');
  FScheduler := AScheduler;
  FPolicy := APolicy;
  FLock := TCriticalSection.Create;
end;

destructor TPluginWiring.Destroy;
begin
  SetLength(FSources, 0);
  FLock.Free;
  inherited Destroy;
end;

function TPluginWiring.MintSource: IInvocationSource;
var
  limits: TPWebSourceLimits;
begin
  limits := Default(TPWebSourceLimits);
  limits.MaxConcurrent := 2;
  limits.MaxQueueSize := 16;
  { THE scheduler - the same object the WebView binding's source came
    from. There is no second scheduler in this program's plugin path. }
  Result := FScheduler.RegisterSource(limits);
  FLock.Acquire;
  try
    SetLength(FSources, Length(FSources) + 1);
    FSources[High(FSources)] := Result;
  finally
    FLock.Release;
  end;
end;

function TPluginWiring.Snapshot(
  const APrincipalId: Utf8String): TPWebCapabilities;
begin
  { capabilities come from the CAP-8 policy keyed by the registry's
    NATIVE PrincipalId - never from the archive, never from plugin.json }
  Result := FPolicy.SnapshotCapabilities(APrincipalId, '');
end;

function TPluginWiring.SourceCount: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FSources);
  finally
    FLock.Release;
  end;
end;

function TPluginWiring.SourceAt(AIndex: Integer): IInvocationSource;
begin
  FLock.Acquire;
  try
    if (AIndex < 0) or (AIndex > High(FSources)) then
      Result := nil
    else
      Result := FSources[AIndex];
  finally
    FLock.Release;
  end;
end;

{ ---------------- production policy ---------------- }

{ Built ONLY from native Pascal builder code at the trust level of the
  executable - never from app.pwb, plugins.zip, a manifest, JS, the
  environment or any file. Any malformed row raises
  EPWebCapabilityConfig and the host fails to start. }
function BuildProductionPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALCULATOR_ADD, PWEB_CAP_EXTERNAL_OPEN, CAP_PARKING_READ]);
    // the single production window and its principal
    b.SetWindowCapabilities('main', [CAP_CALCULATOR_ADD, PWEB_CAP_EXTERNAL_OPEN]);
    b.SetPrincipalCapabilities(PRINCIPAL_WINDOW,
      [CAP_CALCULATOR_ADD, PWEB_CAP_EXTERNAL_OPEN]);
    // the two plugin principals. The calculator may add; the reporting
    // plugin holds parking.read, which authorizes nothing this host
    // maps - so its CalculatorService.Add is forbidden BEFORE the
    // bridge, and no dummy parking service exists to consume it.
    b.SetPrincipalCapabilities(PRINCIPAL_CALCULATOR, [CAP_CALCULATOR_ADD]);
    b.SetPrincipalCapabilities(PRINCIPAL_REPORTING, [CAP_PARKING_READ]);
    // the sole application service
    b.MapMethod('CalculatorService.Add', [CAP_CALCULATOR_ADD]);
    // handing a URI to the OS is an AUTHORIZATION decision, mapped
    b.MapMethod(PWEB_METHOD_OPEN_EXTERNAL, [PWEB_CAP_EXTERNAL_OPEN]);
    // runtime-owned methods: explicitly capability-free
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(PWEB_METHOD_ECHO);
    // the page's two machine-verdict channels and the gate's UI round
    b.RegisterZeroCapMethod(METHOD_REPORT);
    b.RegisterZeroCapMethod(METHOD_PLUGIN_PROBE);
    b.RegisterZeroCapMethod(METHOD_CONCURRENT);
    // the SDK acceptance page probes an UNREGISTERED method and requires
    // the bridge's typed method_not_found; every OTHER unknown method -
    // including the three plausible plugin-read names the probe block
    // tries - is forbidden pre-bridge, by design.
    b.RegisterZeroCapMethod('No.SuchMethod');
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ The policy's canonical projection, so "this host constructs the same
  policy as the release host, plus exactly the documented additions" is
  a comparable string and not a claim. }
function PolicyProjection: RawUtf8;
begin
  Result :=
    'appmax=' + CAP_CALCULATOR_ADD + ',' + PWEB_CAP_EXTERNAL_OPEN + ',' +
      CAP_PARKING_READ + ';' +
    'window:main=' + CAP_CALCULATOR_ADD + ',' + PWEB_CAP_EXTERNAL_OPEN + ';' +
    'principal:' + PRINCIPAL_WINDOW + '=' + CAP_CALCULATOR_ADD + ',' +
      PWEB_CAP_EXTERNAL_OPEN + ';' +
    'principal:' + PRINCIPAL_CALCULATOR + '=' + CAP_CALCULATOR_ADD + ';' +
    'principal:' + PRINCIPAL_REPORTING + '=' + CAP_PARKING_READ + ';' +
    'map:CalculatorService.Add=' + CAP_CALCULATOR_ADD + ';' +
    'map:' + PWEB_METHOD_OPEN_EXTERNAL + '=' + PWEB_CAP_EXTERNAL_OPEN + ';' +
    'zero:' + PWEB_METHOD_HANDSHAKE + ',' + PWEB_METHOD_ECHO + ',' +
      METHOD_REPORT + ',' + METHOD_PLUGIN_PROBE + ',' + METHOD_CONCURRENT +
      ',No.SuchMethod';
end;

{ ---------------- platform pre-create checks ---------------- }

{$ifdef DARWIN}
procedure CheckPlatformRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, LOG_PREFIX,
    ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create(
    'the FPU could not be put in its non-trapping default state - WebKit ' +
    'would kill this process on its first NaN; no WebView was created');
end;
{$else}
{$ifdef LINUX}
procedure CheckPlatformRuntimeUsable;
var
  reason: RawUtf8;
begin
  reason := PWebGtkDisplayUnavailableReason;
  if reason = '' then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': GTK DISPLAY UNAVAILABLE (', reason, ')');
  raise Exception.Create(
    'no usable display - no WebView was created; a GTK/WebKitGTK ' +
    'WebView needs an X or Wayland session');
end;
{$else}
procedure CheckPlatformRuntimeUsable;
var
  detection: TPWebWv2DetectionResult;
begin
  detection := PWebWv2Detect;
  if PWebWv2ProvisioningDecide(detection) = wv2pdAlreadyUsable then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': WEBVIEW2 RUNTIME UNUSABLE (status=',
    PWebWv2StatusText(detection.Status), ', raw=', detection.RawVersion,
    ', minbuild=', PWEB_WV2_MIN_BUILD, ')');
  raise Exception.Create(
    'WebView2 runtime unusable - no WebView was created; ' +
    'install the runtime via the application setup');
end;
{$endif LINUX}
{$endif DARWIN}

{ ---------------- trusted release locations ---------------- }

{ app.pwb, resolved from the EXECUTABLE/BUNDLE location and never the
  CWD. Inside a .app the executable lives in Contents/MacOS and the
  bundle in Contents/Resources. }
function AppBundleFile: TFileName;
begin
  {$ifdef DARWIN}
  Result := ExpandFileName(Executable.ProgramFilePath + '..' +
    PathDelim + 'Resources' + PathDelim + 'app.pwb');
  {$else}
  Result := Executable.ProgramFilePath + 'app.pwb';
  {$endif DARWIN}
end;

{ The directory holding plugins.zip - the same rule, resolved through
  the release unit's own PWebReleaseDirectory off the .app path. }
function PackageDirectory: TFileName;
begin
  {$ifdef DARWIN}
  Result := ExpandFileName(Executable.ProgramFilePath + '..' +
    PathDelim + 'Resources') + PathDelim;
  {$else}
  Result := PWebReleaseDirectory;
  {$endif DARWIN}
end;

function LoadAppBundle: IAssetStore;
var
  inner: IAssetStore;
  refusal: TPWebBundleRefusal;
begin
  if not PWebBundleLoadFile(AppBundleFile, PWEB_SUPPORTED_PROTOCOLS,
       PWEB_RUNTIME_VERSION, inner, refusal) then
  begin
    WriteLn(StdErr, LOG_PREFIX, ': app.pwb REFUSED (',
      PWebBundleRefusalText(refusal), ')');
    raise Exception.Create('bundle refused - no WebView was created');
  end;
  AppCounter := TCountingAssetStore.Create(inner);
  Result := AppCounter;
end;

{ ---------------- GUI-thread dispatch helpers ---------------- }

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

procedure EvalOnGuiThread(w: webview_t; arg: Pointer); cdecl;
var
  js: RawUtf8;
begin
  try
    EvalLock.Acquire;
    try
      js := EvalScript;
    finally
      EvalLock.Release;
    end;
    if js <> '' then
      webview_eval(w, PAnsiChar(js));
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

{ Drive ONE real UI invocation round through the real transport: the
  page's own bound global, evaluated in the trusted document, reporting
  back through example.concurrent. Nothing here simulates a UI call.

  The round is matched BY TAG, not by "a report arrived". A promise
  chain in the page settles on the engine's own schedule, so a report
  from the previous round can land after this one has already cleared
  the slot - and a round that accepts whatever it finds would then
  quietly grade the wrong answer. MEASURED exactly that: four
  consecutive rows each carried the tag of the round before them. }
function RunUiRound(const ATag, AJs: RawUtf8; out AJson: RawUtf8;
  ATimeoutMs: Integer): Boolean;
var
  handle: Pointer;
  waited: Int64;
  want: RawUtf8;
begin
  Result := False;
  AJson := '';
  handle := WebViewHandle;
  if handle = nil then
    exit;
  want := '"tag":"' + ATag + '"';
  UiRoundLock.Acquire;
  try
    UiRoundJson := '';
  finally
    UiRoundLock.Release;
  end;
  RTLEventResetEvent(UiRoundEvent);
  EvalLock.Acquire;
  try
    EvalScript := AJs;
  finally
    EvalLock.Release;
  end;
  webview_dispatch(webview_t(handle), @EvalOnGuiThread, nil);
  waited := GetTickCount64;
  while Int64(GetTickCount64) - waited < ATimeoutMs do
  begin
    RTLEventWaitFor(UiRoundEvent, 50);
    UiRoundLock.Acquire;
    try
      AJson := UiRoundJson;
      if (AJson <> '') and (Pos(want, AJson) = 0) then
        UiRoundJson := ''; // a late round: discard it and keep waiting
    finally
      UiRoundLock.Release;
    end;
    if (AJson <> '') and (Pos(want, AJson) > 0) then
      exit(True);
    AJson := '';
  end;
end;

{ Bounded by the CLOCK, never by an iteration count: a wait whose
  granularity differs from its accounting is a timeout that silently
  is not the timeout it claims. }
function WaitLatched(AEvent: PRTLEvent; var AState: LongInt;
  ATimeoutMs: Integer): LongInt;
var
  started: Int64;
begin
  started := GetTickCount64;
  repeat
    Result := InterlockedCompareExchange(AState, 0, 0);
    if Result <> 0 then
      exit;
    RTLEventWaitFor(AEvent, 100);
  until Int64(GetTickCount64) - started >= ATimeoutMs;
  Result := InterlockedCompareExchange(AState, 0, 0);
end;

{ ---------------- the acceptance gate ---------------- }

const
  UI_ROUND_JS_TEMPLATE =
    '(function(){var f=window.__pweb_invoke;' +
    'if(typeof f!=="function"){return;}' +
    'f("CalculatorService.Add",{a:%A%,b:%B%}).then(function(v){' +
    'f("example.concurrent",{tag:"%TAG%",value:v});},function(e){' +
    'f("example.concurrent",{tag:"%TAG%",error:String(e&&e.code||e)});});})();';

  { What the trusted document looks like, asked FROM the document. It
    reports the two acceptance elements' text and the rendered body
    length, so "the UI rendered" is an observation and not an inference
    from "no error was printed". }
  RENDER_PROBE_JS =
    '(function(){var f=window.__pweb_invoke;' +
    'if(typeof f!=="function"){return;}' +
    'var r=document.getElementById("result");' +
    'var p=document.getElementById("plugin-probe-result");' +
    'var b=document.body?(document.body.textContent||""):"";' +
    'f("example.concurrent",{tag:"render",body:b.length,' +
    'result:(r?r.textContent:"<none>"),' +
    'probe:(p?p.textContent:"<none>")});})();';

function UiRoundJs(const ATag: RawUtf8; A, B: Integer): RawUtf8;
begin
  Result := StringReplaceAll(UI_ROUND_JS_TEMPLATE, '%A%', N(A));
  Result := StringReplaceAll(Result, '%B%', N(B));
  Result := StringReplaceAll(Result, '%TAG%', ATag);
end;

function CallExportOn(AHost: TPWebQuickJSPluginHost; const AName: RawUtf8;
  const AArgs: TPWebJson; out AJson: TPWebJson;
  out ADetail: RawUtf8): TPWebExportCallCode;
begin
  if AHost = nil then
  begin
    AJson := '';
    ADetail := 'no host';
    exit(peccUnavailable);
  end;
  Result := AHost.CallExport(AName, AArgs, AJson, ADetail);
end;

type
  TUiRoundThread = class(TThread)
  private
    FTag: RawUtf8;
    FJs: RawUtf8;
    FJson: RawUtf8;
    FOk: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ATag, AJs: RawUtf8);
    property Json: RawUtf8 read FJson;
    property Ok: Boolean read FOk;
  end;

constructor TUiRoundThread.Create(const ATag, AJs: RawUtf8);
begin
  FTag := ATag;
  FJs := AJs;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TUiRoundThread.Execute;
begin
  FOk := RunUiRound(FTag, FJs, FJson, UI_ROUND_WAIT_MS);
end;

{ The whole acceptance sequence, on its own thread because webview_run
  owns the GUI thread. Every wait below is bounded; nothing sleeps to
  create an outcome. }
procedure RunGate;
var
  calcHost, reportHost: TPWebQuickJSPluginHost;
  code: TPWebExportCallCode;
  life: TPWebPluginLifecycleCode;
  pkg: TPWebPackageLoadCode;
  json, detail, uiJson: RawUtf8;
  scoped: IAssetStore;
  asset: TAssetResponse;
  queued, active: Integer;
  appBefore, pluginBefore, appDelta, pluginDelta, state: LongInt;
  genBefore, genAfter: Int64;
  uiThread: TUiRoundThread;
  i, running, failed: Integer;
  sr: TPWebPluginStartResult;
  ownsUi, ownsPlugins, decoyOwnsNothing, rendered, roundOk: Boolean;
  waitedFor: Int64;
begin
  calcHost := nil;
  reportHost := nil;
  { THE BOUND ORDERING, enforced rather than remembered.

    G7 parks a plugin invocation inside the barrier until its peer
    arrives, and a plugin's pweb.invoke is itself bounded by
    InvokeWaitMs. If the barrier may wait LONGER than that, a slow
    rendezvous trips the plugin's defensive completion cap first and the
    gate reports a runtime internal error for what was really "the peer
    was late" - a diagnosis that sends the next reader into the wrong
    half of the system.

    MEASURED exactly that way on hosted run 33099868501 (windows,
    attempt 1) with the two inverted at 20000 vs 15000:

        plugin_result_isolated code=threw detail=PWebError: Internal error

    Attempt 2 on the same commit was green with the frozen digest, so
    nothing behavioural had changed - only the order in which two
    timeouts could fire. This raise is deliberately NOT a gate row: it
    is a precondition on the harness itself, it must fail before a
    window is opened rather than be recorded as a verdict, and adding a
    row here would re-baseline the frozen CAP-9C2 corpus digest for a
    fact about this file. }
  if BARRIER_WAIT_MS >= PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs then
    raise Exception.CreateFmt(
      'CAP-9C2 harness bound inversion: BARRIER_WAIT_MS=%d must be ' +
      'well below the plugin invoke wait of %dms, or a late peer ' +
      'surfaces as an internal error instead of as concurrent_overlap',
      [BARRIER_WAIT_MS, PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs]);
  try
    { ---- G-1: the document actually rendered, and the eval transport
      is warm. This row is a required CAP-9 success signal in its own
      right - "WebView HTML/CSS/JS rendered" - AND it removes a
      readiness race from every UI round after it: a first eval issued
      before the document is ready can be delivered late, which would
      turn the concurrency barrier below into a timing accident. }
    { Bounded by the CLOCK, never by an attempt count. Each probe returns
      as soon as its own report lands - typically in milliseconds - so
      "sixty attempts" collapses to about three seconds, which is long
      enough for React to mount on a fast developer machine and not on a
      hosted runner. MEASURED exactly that way: every other row on the
      hosted Windows job was green and this one alone was red, because
      the loop had spent its sixty tries before the tree existed. It is
      the same defect the service barrier had - an iteration count is not
      a timeout - and it is why both are now written against a tick. }
    rendered := False;
    waitedFor := GetTickCount64;
    while (not rendered) and
          (Int64(GetTickCount64) - waitedFor < REPORT_WAIT_MS) do
    begin
      if RunUiRound('render', RENDER_PROBE_JS, uiJson, 2000) and
         JsonHas(uiJson, '"tag":"render"') then
        { BOTH acceptance elements must exist. An empty <div id="root">
          still yields a non-empty document, so "the body has bytes" is
          not evidence that the component tree mounted - it was the
          false positive that hid a two-React-instance bundle. }
        rendered := (not JsonHas(uiJson, '"result":"<none>"')) and
                    (not JsonHas(uiJson, '"probe":"<none>"'));
      if not rendered then
        { a POLL INTERVAL, not evidence: GateThreadDone is set once, at
          the very end of this gate, so waiting on it here is simply a
          bounded pause that no signal can shorten }
        RTLEventWaitFor(GateThreadDone, 250);
    end;
    Require('ui_rendered', rendered, 'page=' + uiJson);

    { ---- G0/G1: the page's two independent verdicts ---- }
    state := WaitLatched(ReportEvent, ReportState, REPORT_WAIT_MS);
    Require('page_report', state = 1, 'state=' + N(state));
    { the browser-invisibility window: the plugin package store must not
      move while the page is doing everything it can to reach it }
    pluginBefore := PluginCounter.Reads;
    state := WaitLatched(ProbeEvent, ProbeState, REPORT_WAIT_MS);
    Require('page_plugin_probe', state = 1, 'state=' + N(state));
    pluginDelta := PluginCounter.Reads - pluginBefore;
    Require('browser_plugin_store_arrivals', pluginDelta = 0,
      'delta=' + N(pluginDelta));
    Require('browser_app_store_reads', AppCounter.Reads > 0,
      'reads=' + N(AppCounter.Reads));
    Require('browser_plugin_script_marker',
      JsonHas(ProbeSummary, '"scriptExecuted":false'), 'from=page');
    Require('raw_channel_source_bytes',
      JsonHas(ProbeSummary, '"sourceBytes":0'), 'from=page');
    Require('raw_channel_no_path_or_digest',
      JsonHas(ProbeSummary, '"leakedPath":0') and
      JsonHas(ProbeSummary, '"leakedDigest":0'), 'from=page');
    { Every attempt refused, on BOTH transports. The exact codes are
      recorded rather than forced: a three-segment pweb.* name fails the
      frozen method grammar at the enqueue gate (invalid_request, an
      even earlier refusal than the policy's), while a well-formed
      unmapped Service.Method reaches the policy and is forbidden. Both
      are refusals that read no bytes; pretending they were the same
      code would be tidier and less true. }
    Require('raw_channel_refused',
      JsonHas(ProbeSummary, '"rawChannel":true') and
      JsonHas(ProbeSummary, '"rawAttempts":3') and
      JsonHas(ProbeSummary, '"rawRefused":3'), 'from=page');
    Require('sdk_plugin_read_refused',
      JsonHas(ProbeSummary, '"sdkAttempts":3') and
      JsonHas(ProbeSummary, '"sdkRefused":3') and
      JsonHas(ProbeSummary, '"forbidden"'), 'from=page');
    Require('browser_asset_probes_refused',
      JsonHas(ProbeSummary, '"assetAttempts":9') and
      JsonHas(ProbeSummary, '"assetRefused":9'), 'from=page');

    { ---- plugin hosts ---- }
    calcHost := Loader.HostOf(PLUGIN_CALCULATOR);
    reportHost := Loader.HostOf(PLUGIN_REPORTING);
    running := Loader.RunningCount;
    failed := 0;
    for i := 0 to Loader.Count - 1 do
    begin
      sr := Loader.StartResult(i);
      if not sr.Running then
        Inc(failed);
      Emit('plugin id=' + sr.PluginId + ' principal=' + sr.PrincipalId +
        ' running=' + YesNo(sr.Running) + ' code=' +
        PWEB_PLUGIN_START_TEXT[sr.Code], sr.Detail);
    end;
    Require('plugins_running', (running = 2) and (failed = 0),
      'running=' + N(running) + ' failed=' +
      N(failed));
    Require('plugin_hosts_present',
      (calcHost <> nil) and (reportHost <> nil), '');

    { ---- G3: shared runtime object identity, MEASURED ----
      The scheduler ITSELF answers whether it created a source
      (TryGetSourceCounts returns False for a source it did not), so
      same_scheduler is a question put to the object rather than a
      property of how this file happens to be wired. }
    ownsUi := Scheduler.TryGetSourceCounts(UiSource, queued, active);
    Require('scheduler_owns_ui_source', ownsUi, '');
    ownsPlugins := Wiring.SourceCount >= 2;
    for i := 0 to Wiring.SourceCount - 1 do
      ownsPlugins := ownsPlugins and
        Scheduler.TryGetSourceCounts(Wiring.SourceAt(i), queued, active);
    Require('scheduler_owns_plugin_sources', ownsPlugins,
      'sources=' + N(Wiring.SourceCount));
    { and the discriminating half: a SECOND, equally configured scheduler
      does not own them. Without this row "same scheduler" would be a
      predicate that answers yes to everything. }
    decoyOwnsNothing :=
      not DecoyScheduler.TryGetSourceCounts(UiSource, queued, active);
    for i := 0 to Wiring.SourceCount - 1 do
      decoyOwnsNothing := decoyOwnsNothing and
        (not DecoyScheduler.TryGetSourceCounts(Wiring.SourceAt(i),
          queued, active));
    Require('decoy_scheduler_owns_nothing', decoyOwnsNothing, '');

    { ---- G4: what the sandbox can see, from inside it ---- }
    code := CallExportOn(calcHost, 'env', PWEB_JSON_NULL, json, detail);
    Require('quickjs_env_call', code = peccOk,
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' ' + detail);
    Require('quickjs_window_absent', JsonHas(json, '"window":"undefined"'), '');
    Require('quickjs_document_absent',
      JsonHas(json, '"document":"undefined"'), '');
    Require('quickjs_webkit_channel_absent',
      JsonHas(json, '"webkit":"undefined"'), '');
    Require('quickjs_webview2_channel_absent',
      JsonHas(json, '"chrome":"undefined"'), '');
    Require('quickjs_raw_webview_invoke_absent',
      JsonHas(json, '"rawInvoke":"undefined"') and
      JsonHas(json, '"rawInvokeJson":"undefined"'), '');
    Require('quickjs_no_ambient_io',
      JsonHas(json, '"fetch":"undefined"') and
      JsonHas(json, '"std":"undefined"') and
      JsonHas(json, '"os":"undefined"'), '');
    Require('quickjs_marker_absent', JsonHas(json, '"marker":"undefined"'), '');
    Require('quickjs_pweb_present', JsonHas(json, '"pweb":"object"'), '');

    { ---- G5: the denied principal, alive and refused ---- }
    code := CallExportOn(reportHost, 'alive', PWEB_JSON_NULL, json, detail);
    Require('reporting_alive',
      (code = peccOk) and JsonHas(json, '"protocol":1'),
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' ' + json);
    appBefore := InterlockedCompareExchange(DeniedBridgeArrivals, 0, 0);
    pluginBefore := InterlockedCompareExchange(DeniedSoaArrivals, 0, 0);
    code := CallExportOn(reportHost, 'add', '{"a":20,"b":22}', json, detail);
    Require('reporting_code',
      (code = peccOk) and JsonHas(json, '"forbidden"'),
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' result=' + json);
    { the informative half of the frozen taxonomy, from the export that
      reports both: `code` is the sole normative discriminator, but a
      status that disagreed with it would mean the mapping is only
      half-applied. Two calls, so the denied deltas below cover both. }
    code := CallExportOn(reportHost, 'addRefusal', '{"a":20,"b":22}', json,
      detail);
    Require('reporting_status',
      (code = peccOk) and JsonHas(json, '"outcome":"refused"') and
      JsonHas(json, '"code":"forbidden"') and JsonHas(json, '"status":403'),
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' result=' + json);
    Require('reporting_denied_bridge_delta',
      InterlockedCompareExchange(DeniedBridgeArrivals, 0, 0) = appBefore,
      'delta=' + N(InterlockedCompareExchange(DeniedBridgeArrivals, 0, 0) -
        appBefore));
    Require('reporting_soa_count',
      InterlockedCompareExchange(DeniedSoaArrivals, 0, 0) = pluginBefore,
      'delta=' + N(InterlockedCompareExchange(DeniedSoaArrivals, 0, 0) -
        pluginBefore));

    { ---- G6: the canonical plugin answer, and the app store untouched ---- }
    appBefore := AppCounter.Reads;
    code := CallExportOn(calcHost, 'add', '{"a":20,"b":22}', json, detail);
    Require('quickjs_add',
      (code = peccOk) and JsonHas(json, '"sum":42') and
      JsonHas(json, '"local":42'),
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' result=' + json);
    appDelta := AppCounter.Reads - appBefore;
    Require('quickjs_app_store_arrivals', appDelta = 0,
      'delta=' + N(appDelta));

    { the calculator's own forbidden probe: package integrity is not
      authorization, and this principal does not hold external.open }
    code := CallExportOn(calcHost, 'openExternal', PWEB_JSON_NULL, json, detail);
    Require('plugin_open_external_forbidden',
      (code = peccOk) and JsonHas(json, 'forbidden'), 'result=' + json);
    Require('opener_reached',
      InterlockedCompareExchange(OpenerReached, 0, 0) = 0,
      'count=' + N(OpenerReached));

    { ---- cross-store confinement, from the plugin's own root ---- }
    scoped := Loader.ScopedStoreOf(PLUGIN_CALCULATOR);
    Require('plugin_scope_present', scoped <> nil, '');
    if scoped <> nil then
    begin
      Require('plugin_cannot_read_app_index',
        not scoped.TryRead('index.html', asset), '');
      Require('plugin_cannot_read_app_asset',
        not scoped.TryRead('assets/app.js', asset), '');
      Require('plugin_cannot_escape_root',
        not scoped.TryRead('../quickjs.reporting/main.js', asset), '');
      Require('plugin_reads_own_module',
        scoped.TryRead('main.js', asset), '');
    end;

    { ---- G7: real concurrency, forced by a barrier inside the service ---- }
    InterlockedExchange(BarrierPeak, 0);
    InterlockedExchange(BarrierArrivals, 0);
    InterlockedExchange(OverlapObserved, 0);
    InterlockedExchange(BarrierArmed, 1);
    { round 1 - DISTINGUISHING values, so a crossed completion would be
      visible as a swapped number rather than as two identical 42s.

      The UI invocation is started first and the plugin call is issued
      only once the bridge has actually SEEN it. Without that handshake
      the plugin would arrive first and sit in the barrier for however
      long the eval round trip takes - and a plugin blocked in a
      synchronous pweb.invoke is still inside its own Evaluate call, so
      a slow peer would be answered by the plugin's CPU bound rather
      than by the barrier. The handshake is a fact (a counter this
      process incremented), never a sleep. }
    uiThread := TUiRoundThread.Create('distinct', UiRoundJs('distinct', 1, 2));
    try
      waitedFor := GetTickCount64;
      while (InterlockedCompareExchange(InFlightWindow, 0, 0) < 1) and
            (Int64(GetTickCount64) - waitedFor < UI_ROUND_WAIT_MS) do
        RTLEventWaitFor(BarrierEvent, 10);
      Require('ui_invocation_in_flight',
        InterlockedCompareExchange(InFlightWindow, 0, 0) >= 1,
        'in_flight=' + N(InFlightWindow));
      code := CallExportOn(calcHost, 'add', '{"a":5,"b":6}', json, detail);
      uiThread.WaitFor;
      uiJson := uiThread.Json;
    finally
      uiThread.Free;
    end;
    InterlockedExchange(BarrierArmed, 0);
    RTLEventSetEvent(BarrierEvent);
    Require('concurrent_overlap',
      InterlockedCompareExchange(OverlapObserved, 0, 0) = 1,
      'peak_in_service=' + N(BarrierPeak));
    Require('concurrent_barrier_peak', BarrierPeak >= 2,
      'peak=' + N(BarrierPeak));
    Require('plugin_result_isolated',
      (code = peccOk) and JsonHas(json, '"sum":11'),
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' result=' + json +
      ' detail=' + detail);
    Require('ui_result_isolated',
      JsonHas(uiJson, '"tag":"distinct"') and JsonHas(uiJson, '"value":3'),
      'result=' + uiJson);
    Require('no_cross_delivery',
      (not JsonHas(json, '":3')) and (not JsonHas(uiJson, '11')),
      'plugin=' + json + ' ui=' + uiJson);

    { round 2 - the canonical 42 from BOTH sources }
    uiThread := TUiRoundThread.Create('canonical', UiRoundJs('canonical', 20, 22));
    try
      code := CallExportOn(calcHost, 'add', '{"a":20,"b":22}', json, detail);
      uiThread.WaitFor;
      uiJson := uiThread.Json;
    finally
      uiThread.Free;
    end;
    Require('ui_add', JsonHas(uiJson, '"value":42'), 'result=' + uiJson);
    Require('quickjs_add_canonical',
      (code = peccOk) and JsonHas(json, '"sum":42'), 'result=' + json);

    { the identity rows, now that BOTH kinds have travelled the chain }
    Require('same_policy',
      (PolicyTokenWindow <> 0) and (PolicyTokenWindow = PolicyTokenPlugin) and
      (InterlockedCompareExchange(PolicyInstances, 0, 0) = 1),
      'window=' + N(PolicyTokenWindow) + ' plugin=' +
      N(PolicyTokenPlugin) + ' instances=' +
      N(PolicyInstances));
    Require('same_bridge',
      (BridgeTokenWindow <> 0) and (BridgeTokenWindow = BridgeTokenPlugin) and
      (InterlockedCompareExchange(BridgeInstances, 0, 0) = 1),
      'window=' + N(BridgeTokenWindow) + ' plugin=' +
      N(BridgeTokenPlugin) + ' instances=' +
      N(BridgeInstances));
    Require('same_server',
      (ServiceTokenWindow <> 0) and
      (ServiceTokenWindow = ServiceTokenPlugin) and
      (InterlockedCompareExchange(ServiceTokenMismatch, 0, 0) = 0),
      'window=' + N(ServiceTokenWindow) + ' plugin=' +
      N(ServiceTokenPlugin) + ' instance_mismatch=' +
      N(ServiceTokenMismatch));
    Require('same_scheduler',
      ownsUi and ownsPlugins and decoyOwnsNothing,
      'ui=' + YesNo(ownsUi) + ' plugins=' + YesNo(ownsPlugins) +
      ' decoy_excluded=' + YesNo(decoyOwnsNothing));

    { ---- G9: CPU-bound containment in the real GUI process ---- }
    code := CallExportOn(reportHost, 'runaway', PWEB_JSON_NULL, json, detail);
    Require('resource_limit_code', code = peccResourceLimit,
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' ' + detail);
    code := CallExportOn(reportHost, 'label', PWEB_JSON_NULL, json, detail);
    Require('tainted_generation_refuses', code = peccUnavailable,
      'code=' + PWEB_EXPORT_CALL_TEXT[code]);
    Require('tainted_host_failed', reportHost.State = ppsFailed,
      'state=' + PWEB_PLUGIN_STATE_TEXT[reportHost.State]);
    code := CallExportOn(calcHost, 'add', '{"a":20,"b":22}', json, detail);
    Require('neighbour_survived_timeout',
      (code = peccOk) and JsonHas(json, '"sum":42'), 'result=' + json);
    { the round runs on its own statement, never inside the Require
      argument list: FPC evaluates arguments right to left, so a detail
      built from uiJson in the same call would show the PREVIOUS round's
      answer - which is exactly how four rows came to carry the wrong
      tag while every gate was in fact green }
    roundOk := RunUiRound('after-timeout', UiRoundJs('after-timeout', 20, 22),
      uiJson, UI_ROUND_WAIT_MS) and JsonHas(uiJson, '"value":42');
    Require('ui_survived_timeout', roundOk, 'result=' + uiJson);

    { ---- G10: explicit B2 reload in the GUI process ---- }
    genBefore := calcHost.GenerationId;
    life := calcHost.Reload(calcHost.ReloadTemplate, pkg, detail);
    genAfter := calcHost.GenerationId;
    Require('reload_ok', life = plfOk,
      'life=' + PWEB_PLUGIN_LIFECYCLE_TEXT[life] + ' pkg=' +
      PWEB_PACKAGE_LOAD_TEXT[pkg] + ' ' + detail);
    Require('reload_generation_changed',
      (genAfter <> genBefore) and (genAfter <> 0),
      'before=' + N(genBefore) + ' after=' +
      N(genAfter));
    code := CallExportOn(calcHost, 'add', '{"a":20,"b":22}', json, detail);
    Require('reload_result_stable',
      (code = peccOk) and JsonHas(json, '"sum":42'), 'result=' + json);
    roundOk := RunUiRound('after-reload', UiRoundJs('after-reload', 20, 22),
      uiJson, UI_ROUND_WAIT_MS) and JsonHas(uiJson, '"value":42');
    Require('ui_survived_reload', roundOk, 'result=' + uiJson);

    { ---- G11: explicit unload of the isolated neighbour ---- }
    life := reportHost.Unload;
    Require('unload_reporting',
      life in [plfOk, plfBadState],
      'life=' + PWEB_PLUGIN_LIFECYCLE_TEXT[life]);
    code := CallExportOn(calcHost, 'add', '{"a":20,"b":22}', json, detail);
    Require('calculator_after_unload',
      (code = peccOk) and JsonHas(json, '"sum":42'), 'result=' + json);
    roundOk := RunUiRound('after-unload', UiRoundJs('after-unload', 20, 22),
      uiJson, UI_ROUND_WAIT_MS) and JsonHas(uiJson, '"value":42');
    Require('ui_after_unload', roundOk, 'result=' + uiJson);

    { ---- G12: memory-bound containment, deliberately LAST ---- }
    code := CallExportOn(calcHost, 'memhog', PWEB_JSON_NULL, json, detail);
    Require('memory_limit_code', code = peccResourceLimit,
      'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' ' + detail);
    roundOk := RunUiRound('after-memory', UiRoundJs('after-memory', 20, 22),
      uiJson, UI_ROUND_WAIT_MS) and JsonHas(uiJson, '"value":42');
    Require('ui_survived_memory_limit', roundOk, 'result=' + uiJson);

    { ---- counters that must hold over the WHOLE run ---- }
    Require('quickjs_export_wrong_thread',
      calcHost.ExportWrongThreadCalls = 0,
      'count=' + N(calcHost.ExportWrongThreadCalls));
    { both are set by the ONE verifier call that had to succeed before a
      service, a policy, a scheduler, an engine or a WebView existed }
    Require('plugin_archive_verified',
      InterlockedCompareExchange(PackageVerified, 0, 0) = 1,
      'sha256+length compared before the archive was parsed');
    Require('plugin_inventory_verified',
      InterlockedCompareExchange(PackageVerified, 0, 0) = 1,
      'semantic inventory compared entry by entry');
  except
    on E: Exception do
    begin
      InterlockedIncrement(GateFailures);
      WriteLn(StdErr, LOG_PREFIX, ': GATE EXCEPTION ', E.ClassName, ': ',
        E.Message);
      Emit('gate_exception=' + RawUtf8(E.ClassName), E.Message);
    end;
  end;
  { the GUI loop is asked to end from here, always - a gate that threw
    must not leave the window open until the outer watchdog fires }
  if WebViewHandle <> nil then
    webview_dispatch(webview_t(WebViewHandle), @TerminateOnGuiThread, nil);
  RTLEventSetEvent(GateThreadDone);
end;

function GateThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  try
    RunGate;
  except
    on E: Exception do
    begin
      InterlockedIncrement(GateFailures);
      WriteLn(StdErr, LOG_PREFIX, ': GATE THREAD ', E.ClassName, ': ',
        E.Message);
      RTLEventSetEvent(GateThreadDone);
    end;
  end;
end;

{ ---------------- arguments and evidence files ---------------- }

procedure ParseArguments(out AVerdictFile, ACorpusFile: TFileName;
  out AAutoCloseMs: Integer);
var
  i: Integer;
  arg, value: string;
  verdictSeen, corpusSeen, autoCloseSeen: Boolean;
begin
  AVerdictFile := '';
  ACorpusFile := '';
  AAutoCloseMs := -1;
  verdictSeen := False;
  corpusSeen := False;
  autoCloseSeen := False;
  // PASS 1: capture only, so a refused command line still leaves evidence
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, Length(ARG_VERDICT)) = ARG_VERDICT then
    begin
      value := Copy(arg, Length(ARG_VERDICT) + 1, MaxInt);
      if value <> '' then
        AVerdictFile := ExpandFileName(value);
    end
    else if Copy(arg, 1, Length(ARG_CORPUS)) = ARG_CORPUS then
    begin
      value := Copy(arg, Length(ARG_CORPUS) + 1, MaxInt);
      if value <> '' then
        ACorpusFile := ExpandFileName(value);
    end;
  end;
  // PASS 2: validate and refuse
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, Length(ARG_VERDICT)) = ARG_VERDICT then
    begin
      if verdictSeen then
        raise Exception.Create('duplicate argument refused: ' + ARG_VERDICT);
      verdictSeen := True;
      if Copy(arg, Length(ARG_VERDICT) + 1, MaxInt) = '' then
        raise Exception.Create(ARG_VERDICT + ' requires a file path');
    end
    else if Copy(arg, 1, Length(ARG_CORPUS)) = ARG_CORPUS then
    begin
      if corpusSeen then
        raise Exception.Create('duplicate argument refused: ' + ARG_CORPUS);
      corpusSeen := True;
      if Copy(arg, Length(ARG_CORPUS) + 1, MaxInt) = '' then
        raise Exception.Create(ARG_CORPUS + ' requires a file path');
    end
    else if Copy(arg, 1, Length(ARG_AUTOCLOSE)) = ARG_AUTOCLOSE then
    begin
      if autoCloseSeen then
        raise Exception.Create('duplicate argument refused: ' + ARG_AUTOCLOSE);
      autoCloseSeen := True;
      value := Copy(arg, Length(ARG_AUTOCLOSE) + 1, MaxInt);
      AAutoCloseMs := StrToIntDef(value, -1);
      if AAutoCloseMs < 0 then
        raise Exception.Create(
          ARG_AUTOCLOSE + ' requires a non-negative integer, got: ' + value);
    end
    else
      raise Exception.Create('usage: ' + LOG_PREFIX +
        ' [' + ARG_VERDICT + '<file>] [' + ARG_CORPUS + '<file>] [' +
        ARG_AUTOCLOSE + '<ms>] -- unknown argument: ' + arg);
  end;
end;

procedure WriteTextFileAtomic(const AFile: TFileName; const AText: RawUtf8);
var
  tmp: TFileName;
  s: TFileStream;
begin
  tmp := AFile + '.' + IntToStr(GetProcessID) + '.tmp';
  s := TFileStream.Create(tmp, fmCreate);
  try
    if AText <> '' then
      s.WriteBuffer(AText[1], Length(AText));
  finally
    s.Free;
  end;
  {$ifdef OSWINDOWS}
  if FileExists(AFile) then
    DeleteFile(AFile);
  {$endif OSWINDOWS}
  if not RenameFile(tmp, AFile) then
    raise Exception.Create('unable to move the evidence file into place: ' +
      string(AFile));
end;

{ ---------------- main ---------------- }

var
  w: webview_t;
  assetHandler: TPWebAssetHandler;
  navGuard: TPWebNavigationGuard;
  server: TRestServerFullMemory;
  factory: TServiceFactoryServerAbstract;
  realBridge, bridge: IInvocationBridge;
  prodPolicy: TPWebCapabilityPolicy;
  identityPolicy: TIdentityPolicy;
  policyRef: ICapabilityPolicy;
  schedulerRef: IInvocationScheduler;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  registry: TPWebPackageRegistry;
  srcFactory: TPWebPluginSourceFactory;
  snapCb: TPWebQuickJSSnapshotEvent;
  releaseCode: TPWebReleaseCode;
  releaseDetail: RawUtf8;
  autoCloseMs, argAutoCloseMs: Integer;
  verdictFile, corpusFile: TFileName;
  gateId, gateHandle: system.TThreadID;
  gateStarted, safeToDestroy, schedulerDrained: Boolean;
  shutdownOrder: RawUtf8;
begin
  ExitCode := 0;
  server := nil;
  Scheduler := nil;
  DecoyScheduler := nil;
  Loader := nil;
  Wiring := nil;
  assetHandler := nil;
  navGuard := nil;
  gateStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  verdictFile := '';
  corpusFile := '';
  argAutoCloseMs := -1;
  shutdownOrder := '';
  IdentityLock := TCriticalSection.Create;
  CorpusLock := TCriticalSection.Create;
  UiRoundLock := TCriticalSection.Create;
  EvalLock := TCriticalSection.Create;
  BarrierEvent := RTLEventCreate;
  ReportEvent := RTLEventCreate;
  ProbeEvent := RTLEventCreate;
  UiRoundEvent := RTLEventCreate;
  GateThreadDone := RTLEventCreate;
  InterlockedExchange(GuiThreadId, LongInt(GetCurrentThreadId));
  try
    ParseArguments(verdictFile, corpusFile, argAutoCloseMs);

    { ---- 1-2: app.pwb from the trusted location, validated ---- }
    AppStore := LoadAppBundle;

    { ---- 3-6: plugins.zip from the trusted location; whole-archive
      SHA-256, semantic inventory and registry coherence - all BEFORE a
      single service, policy, bridge, scheduler, engine or WebView
      exists. On refusal nothing below this line ever runs. ---- }
    registry := PWebRegistryFrom(PWEB_QUICKJS_PACKAGE_FILE,
      PWEB_QUICKJS_PACKAGE_SHA256, PWEB_QUICKJS_PACKAGE_BYTES,
      PWEB_QUICKJS_INVENTORY_DIGEST, PWEB_QUICKJS_INVENTORY,
      PWEB_QUICKJS_PLUGINS);
    if not PWebVerifyQuickJSPackage(PackageDirectory, registry, PluginStore,
         releaseCode, releaseDetail) then
    begin
      WriteLn(StdErr, LOG_PREFIX, ': plugins.zip REFUSED (',
        PWebReleaseCodeText(releaseCode), ') ', releaseDetail);
      WriteLn(StdErr, LOG_PREFIX, ': pre-webview markers webviews_created=',
        InterlockedCompareExchange(WebViewsCreated, 0, 0),
        ' soa_calls=', InterlockedCompareExchange(ServiceAddCalls, 0, 0));
      raise Exception.Create('plugin package refused - no WebView was ' +
        'created, no engine exists and no service was ever reached');
    end;
    InterlockedExchange(PackageVerified, 1);
    PluginCounter := TCountingAssetStore.Create(PluginStore);
    PluginStore := PluginCounter;
    WriteLn(LOG_PREFIX, ': plugins.zip VERIFIED (plugins=',
      Length(registry.Plugins), ', inventory=',
      Length(registry.Inventory), ')');

    { ---- 7: services ---- }
    server := TRestServerFullMemory.CreateWithOwnModel([]);
    factory := server.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register CalculatorService');
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil;

    { ---- 8: ONE production CAP-8 policy ---- }
    prodPolicy := BuildProductionPolicy;
    identityPolicy := TIdentityPolicy.Create(prodPolicy);
    policyRef := identityPolicy;

    { ---- 9: ONE bridge/decorator chain ---- }
    // CAP-10A: the reusable runtime-command layer sits BETWEEN this host's
    // gate decorator and the real bridge, deliberately - the gate must keep
    // seeing every arrival, because its per-kind identity, in-flight and
    // denied-arrival counters are the measurements CAP-9C2 ratified. So
    // pweb.openExternal is still counted here, then falls through to the
    // one shared implementation instead of a private copy of it.
    bridge := TGateBridge.Create(
      TPWebRuntimeCommandBridge.Create(realBridge, @OpenExternalUri,
        @ObserveExternalOpen));

    { ---- 10: ONE scheduler (plus the decoy the identity gate needs) ---- }
    Scheduler := TInvocationScheduler.Create(policyRef, bridge, 4);
    schedulerRef := Scheduler;
    DecoyScheduler := TInvocationScheduler.Create(policyRef, bridge, 1);
    DecoySchedulerRef := DecoyScheduler;

    { ---- 11-12: the plugin manager over the VERIFIED package bytes,
      then stage/load/publish each registered plugin independently ---- }
    Wiring := TPluginWiring.Create(Scheduler, prodPolicy);
    srcFactory := Wiring.MintSource; // Delphi-mode event assignment
    snapCb := Wiring.Snapshot;
    Loader := TPWebQuickJSPackageLoader.Create(registry, PluginStore,
      srcFactory, snapCb, READY_WAIT_MS, EXPORT_WAIT_MS,
      UNLOAD_JOIN_MS, 0);
    WriteLn(LOG_PREFIX, ': plugins published running=', Loader.StartAll,
      '/', Loader.Count);

    { ---- 13: the UI source, from the SAME scheduler ---- }
    limits := Default(TPWebSourceLimits);
    limits.MaxConcurrent := 4;
    limits.MaxQueueSize := 32;
    UiSource := Scheduler.RegisterSource(limits);

    {$ifdef DARWIN}
    CheckPlatformRuntimeUsable;
    { Cocoa's pweb://app seam is armed by CONSTRUCTION and only a webview
      created after it can be served. The APP store is the only store
      that ever reaches this constructor. }
    assetHandler := TCocoaAssetHandler.Create(AppStore);
    {$else}
    CheckPlatformRuntimeUsable;
    {$endif DARWIN}

    w := WebViewCheckCreated(webview_create(0, nil));
    InterlockedIncrement(WebViewsCreated);
    try
      {$ifdef DARWIN}
      assetHandler.Attach(w);
      {$endif DARWIN}
      WebViewHandle := Pointer(w);
      context := Default(TInvocationContext);
      context.WindowId := 'main';
      context.PrincipalId := PRINCIPAL_WINDOW;
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, UiSource, opts);
      binding.Bind('__pweb_invoke', TPolicyContextHandler.Create(
        TPWebEnvelopeHandler.Create(UiSource), prodPolicy));
      WebViewCheck(webview_set_title(w, PAnsiChar(AnsiString(APP_TITLE))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 700, WEBVIEW_HINT_NONE),
        'webview_set_size');
      { the pweb://app handler - THE APP STORE, and only ever the app
        store. The package store is not in scope at this call site by
        construction: it lives in a different variable that no platform
        unit in this program ever sees. }
      {$ifndef DARWIN}
      {$ifdef LINUX}
      assetHandler := TWebKitGtkAssetHandler.Create(w, AppStore);
      {$else}
      assetHandler := TWebView2AssetHandler.Create(w, AppStore);
      {$endif LINUX}
      {$endif DARWIN}
      { CAP-8B: the privileged-navigation guard, installed after the
        handler and before the first navigation, so no document commits
        unclassified. Plugin integration changes nothing here. }
      {$ifdef DARWIN}
      navGuard := TPWebNavigationGuard.Create;
      navGuard.Attach(w);
      {$else}
      navGuard := TPWebNavigationGuard.Create(w);
      {$endif DARWIN}
      WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

      { ---- 15: the gate, on its own thread ---- }
      gateHandle := BeginThread(@GateThread, nil, gateId);
      gateStarted := gateHandle <> system.TThreadID(0);
      if not gateStarted then
        raise Exception.Create('unable to start the acceptance gate thread');

      if argAutoCloseMs >= 0 then
        autoCloseMs := argAutoCloseMs
      else
        autoCloseMs := StrToIntDef(
          GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if autoCloseMs > MAX_AUTOCLOSE_MS then
        autoCloseMs := MAX_AUTOCLOSE_MS;
      WebViewCheck(webview_run(w), 'webview_run');
    finally
      { THE RECORDED SHUTDOWN ORDER. The frozen platform lifecycle
        requires Detach and webview_destroy inside this block, so the
        plugin generations are closed BEFORE the scheduler drains and
        the scheduler drains BEFORE the native view dies: no plugin
        context outlives its source, no source outlives scheduler
        shutdown, and no scheduler worker can touch QuickJS afterwards. }
      if gateStarted then
      begin
        if WaitForThreadTerminate(gateHandle,
             autoCloseMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          WriteLn(StdErr, LOG_PREFIX, ': FAIL gate thread did not terminate');
          safeToDestroy := False;
          InterlockedIncrement(ShutdownFailures);
        end;
        CloseThread(gateHandle);
      end;
      shutdownOrder := 'gate_joined';
      WebViewHandle := nil;
      if binding <> nil then
        try
          binding.Close;
          shutdownOrder := shutdownOrder + '>binding_close';
        except
          on E: Exception do
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL binding Close: ', E.Message);
            InterlockedIncrement(ShutdownFailures);
          end;
        end;
      if Loader <> nil then
        try
          Loader.UnloadAll;
          shutdownOrder := shutdownOrder + '>plugins_unloaded';
        except
          on E: Exception do
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL plugin UnloadAll: ', E.Message);
            InterlockedIncrement(ShutdownFailures);
          end;
        end;
      if schedulerRef <> nil then
        try
          schedulerRef.Shutdown;
          schedulerDrained := True;
          shutdownOrder := shutdownOrder + '>scheduler_drained';
        except
          on E: Exception do
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL scheduler Shutdown: ',
              E.Message);
            InterlockedIncrement(ShutdownFailures);
          end;
        end;
      if DecoySchedulerRef <> nil then
        try
          DecoySchedulerRef.Shutdown;
        except
          on E: Exception do
            WriteLn(StdErr, LOG_PREFIX, ': FAIL decoy Shutdown: ', E.Message);
        end;
      if navGuard <> nil then
        try
          navGuard.Detach;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL guard Detach: ', E.Message);
            InterlockedIncrement(ShutdownFailures);
          end;
        end;
      try
        FreeAndNil(navGuard);
      except
        on E: Exception do
          WriteLn(StdErr, LOG_PREFIX, ': FAIL guard Free: ', E.Message);
      end;
      if assetHandler <> nil then
        try
          assetHandler.Detach;
          shutdownOrder := shutdownOrder + '>handler_detached';
        except
          on E: Exception do
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL handler Detach: ', E.Message);
            InterlockedIncrement(ShutdownFailures);
          end;
        end;
      FreeAndNil(assetHandler);
      if safeToDestroy then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
          shutdownOrder := shutdownOrder + '>webview_destroyed';
        except
          on E: Exception do
          begin
            WriteLn(StdErr, LOG_PREFIX, ': FAIL webview_destroy: ', E.Message);
            InterlockedIncrement(ShutdownFailures);
          end;
        end;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  if (Scheduler <> nil) and not schedulerDrained then
    try
      Scheduler.Shutdown;
      schedulerDrained := True;
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': FAIL final Shutdown: ', E.Message);
    end;

  try
    FreeAndNil(Loader);
    FreeAndNil(Wiring);
    binding := nil;
    UiSource := nil;
    schedulerRef := nil;
    Scheduler := nil;
    DecoySchedulerRef := nil;
    DecoyScheduler := nil;
    policyRef := nil;
    prodPolicy := nil;
    identityPolicy := nil;
    bridge := nil;
    realBridge := nil;
    AppStore := nil;
    PluginStore := nil;
    AppCounter := nil;
    PluginCounter := nil;
    server.Free;
    shutdownOrder := shutdownOrder + '>services_released';
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: final teardown: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  if ExitCode = 0 then
  begin
    { two rows, not one: every gate row is exactly name=yes|no so the
      aggregator's rule can stay trivial, and the ACTUAL teardown order -
      which this shard is required to record rather than describe - gets
      its own row. It is identical on all four targets because it is
      built by the same statements. }
    Emit('clean_shutdown=' +
      YesNo(InterlockedCompareExchange(ShutdownFailures, 0, 0) = 0), '');
    Emit('shutdown_order=' + shutdownOrder, '');
    Emit('policy_projection=' + PolicyProjection, '');
    if (InterlockedCompareExchange(GateFailures, 0, 0) <> 0) or
       (InterlockedCompareExchange(ShutdownFailures, 0, 0) <> 0) then
    begin
      WriteLn(StdErr, LOG_PREFIX, ': FAIL ',
        InterlockedCompareExchange(GateFailures, 0, 0), ' gate row(s) and ',
        InterlockedCompareExchange(ShutdownFailures, 0, 0),
        ' shutdown step(s) failed');
      ExitCode := 1;
    end;
  end;

  if corpusFile <> '' then
    try
      WriteTextFileAtomic(corpusFile, CorpusRows);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL corpus write: ', E.Message);
        ExitCode := 1;
      end;
    end;
  if verdictFile <> '' then
    try
      if ExitCode = 0 then
        WriteTextFileAtomic(verdictFile, LOG_PREFIX + VERDICT_PASS + #10)
      else
        WriteTextFileAtomic(verdictFile, LOG_PREFIX + ': FAIL (exit=' +
          N(ExitCode) + ')' + #10);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL verdict write: ', E.Message);
        ExitCode := 1;
      end;
    end;

  RTLEventDestroy(GateThreadDone);
  RTLEventDestroy(UiRoundEvent);
  RTLEventDestroy(ProbeEvent);
  RTLEventDestroy(ReportEvent);
  RTLEventDestroy(BarrierEvent);
  EvalLock.Free;
  UiRoundLock.Free;
  CorpusLock.Free;
  IdentityLock.Free;

  if ExitCode = 0 then
  begin
    WriteLn(LOG_PREFIX, VERDICT_PASS);
    WriteLn(LOG_PREFIX, ': clean exit');
  end;
end.
