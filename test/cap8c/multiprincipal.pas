program multiprincipal;

{ CAP-8C: the multi-principal integration harness.

  One production runtime, ONE shared immutable policy, and three real
  principals differentiated by that single policy instance:

    window:main  / main  (pkWindow, TrustedContent=True)  - a real WebView
    window:login / login (pkWindow, TrustedContent=True)  - a real WebView
    plugin:reporting     (pkPlugin, PluginId=reporting)   - a native source

  The runtime under test is UNCHANGED: the frozen scheduler + CAP-8A policy
  authorize every invocation at the one call site, the frozen
  IInvocationSource/TryEnqueue path carries the plugin (a native context +
  a per-invocation sink, no WebView anywhere), and the CAP-8B navigation
  guard + native CSP install on BOTH privileged views exactly as the
  release host installs them on its one.

  TWO LEGS, one corpus:

  A. NATIVE leg (headless, deterministic - the digest source). Drives the
     whole multi-principal decision matrix through the production
     scheduler/policy/bridge over THREE registered sources (main, login,
     plugin) with native contexts and recording completion sinks:
       - the per-principal method matrix + precedence + error taxonomy;
       - the plugin denial through the source-generic RegisterSource path;
       - the TrustedContent=false pkWindow gate (every method denied);
       - forged-Args (identity fields in Args change nothing);
       - runtime-grant revoke -> in-flight-snapshot -> restore, held across
         the revoke by an explicit barrier (never a sleep);
       - context isolation C1-C7 with barriers + counters (no cross-source
         completion, exact service counts);
       - source-level lifecycle (R-C2): close one source -> the others stay
         functional; reopen arms a FRESH source + fresh context and the old
         context cannot complete into it; reverse close order; shutdown
         drains the plugin source and releases services last.
     Every line it writes to build/cap8c/security-corpus.txt is a pure
     decision or a deterministic counter, so the file bytes - and the
     sha256 the CAP-7F emitters record as security_corpus_digest - are
     identical on all four targets by construction.

  B. GUI leg (two simultaneously live real WebViews - R-C1). Proves the
     same policy differentiates two REAL privileged principals under the
     full CAP-8B guard/CSP, with the CONTENT-SWAP baked in: the Main window
     is served the LOGIN page's bytes and the Login window the MAIN page's
     bytes, and the outcome still follows the native context - Main computes
     42, Login is forbidden - regardless of the document. The Main path
     reaches the injected opener exactly for its authorized https + mailto
     opens; the Login path is forbidden pre-bridge and the opener is never
     reached. The CalculatorService.Add on the Main path runs through a REAL
     mORMot SOA bridge (the service counter is a TInterfacedObject service),
     mirroring the CAP-8B counting/real split ratified in deferred-work.

  R-C2 / R-C3 lifecycle (ratified at Checkpoint 1): window close/reopen is a
  SOURCE-level operation, proven source-generically in the native leg on
  long-lived instances; the GUI leg NEVER performs a mid-loop
  webview_destroy (the macOS crash, T2) and calls webview_terminate only on
  the run-owner, only at shutdown (the Windows thread-global-terminate
  nondeterminism, T2). webview_destroy runs post-loop, reverse creation
  order.

  The host writes build/cap8c/multiprincipal-<target>.json (the per-target
  corpus, overall PASS|FAIL|SKIP) + build/cap8c/security-corpus.txt (the
  canonical digest source) and prints exactly one canonical marker:

      multiprincipal: MULTIPRINCIPAL PASS
      multiprincipal: MULTIPRINCIPAL FAIL (<reason>)

  SKIP is the same honest shape as the CAP-8B nav-matrix: only an absent
  WebView2 runtime / desktop session (webview_create nil) records SKIP for
  the GUI leg, and the aggregator refuses it. The native leg always runs. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.json,
  mormot.core.os,
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
  ;

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
  LOG_PREFIX = 'multiprincipal';
  MARKER_PASS = 'multiprincipal: MULTIPRINCIPAL PASS';
  MARKER_FAIL = 'multiprincipal: MULTIPRINCIPAL FAIL';
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

  DEFAULT_TIMEOUT_MS = 45000;
  MAX_TIMEOUT_MS = 120000;
  CLOSER_WAIT_MARGIN_MS = 10000;
  NATIVE_WAIT_MS = 8000;   // per-invocation completion bound (barriered work)
  BARRIER_WAIT_MS = 8000;  // arrival-barrier bound; never a fixed sleep

  // principals
  PRIN_MAIN = 0;
  PRIN_LOGIN = 1;
  PRIN_PLUGIN = 2;
  ID_MAIN: RawUtf8 = 'window:main';
  ID_LOGIN: RawUtf8 = 'window:login';
  ID_PLUGIN: RawUtf8 = 'plugin:reporting';

  // capabilities (the CAP-8C ceiling)
  CAP_CALC = 'calculator.add';
  CAP_OPEN = PWEB_CAP_EXTERNAL_OPEN; // CAP-10A: from pweb.rpc.command
  CAP_SETTINGS = 'settings.read';
  CAP_PARKING = 'parking.read';
  CAP_WINDOW = 'window.control';

  // methods
  M_ADD = 'CalculatorService.Add';
  M_SETTINGS = 'SettingsService.GetValue';
  M_PARKING = 'ParkingService.List';
  M_WINDOW = 'WindowService.Control';
  { CAP-10A: M_OPEN is PWEB_METHOD_OPEN_EXTERNAL from pweb.rpc.command -
    the alias survives so the decision table below reads unchanged, but the
    spelling now comes from the shipped runtime-command layer instead of a
    fourth private copy of the same literal. }
  M_OPEN = PWEB_METHOD_OPEN_EXTERNAL;
  M_REPORT = 'cap8c.report';
  M_NOSUCH = 'No.SuchMethod';   // registered zero-cap, no bridge impl -> 404
  M_FAULT = 'fault.raise';      // registered zero-cap, bridge raises -> 500
  M_GHOST = 'Ghost.Method';     // unmapped unknown -> forbidden (403)

  // the two URIs the GUI Main path is scripted to open
  EXPECT_HTTPS: RawUtf8 = 'https://example.invalid/cap8c-open';
  EXPECT_MAILTO: RawUtf8 = 'mailto:cap8c@example.invalid';

  CORPUS_FILE = 'build/cap8c/security-corpus.txt';

type
  { the real SOA service on the Main path: a TInterfacedObject whose Add is
    the service counter. GuiPhase separates the single GUI Main add from the
    native-leg adds so "service counter exactly 1" is a clean GUI-leg fact. }
  ICalculatorService = interface(IInvokable)
    ['{7A5F1C20-9E44-4B21-8C0D-2F6B1A9E4D33}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { the counting bridge: per-(principal,method) attribution, the real mORMot
    leg for CalculatorService.Add, the host-owned pweb.openExternal + report
    methods, and the deliberate raise for fault.raise. Denied invocations
    never reach it (policy runs first), so a nonzero login/plugin counter for
    a privileged method is itself the failure. }
  TCountingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge; // real mORMot bridge for CalculatorService.Add
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { the release host's D9 wrapper, verbatim in shape: the per-invocation
    effective snapshot is computed on the callback thread and nothing else
    of the native context is touched }
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

  { records one native invocation's terminal result and signals an event -
    the native leg waits on it (bounded), never sleeps }
  TRecordingCompletion = class(TInterfacedObject, IInvocationCompletion)
  private
    FEvent: PRTLEvent;
    FResult: TPWebInvocationResult;
    FDone: LongInt;
    FCalls: LongInt; // every Complete ATTEMPT that reached this sink
  public
    constructor Create;
    destructor Destroy; override;
    procedure Complete(const AResult: TPWebInvocationResult);
    function WaitResult(out AResult: TPWebInvocationResult;
      ATimeoutMs: Integer): Boolean;
    { how many times the scheduler actually delivered into this sink: the
      frozen exactly-once gate means this can never exceed 1 - the lifecycle
      gate ASSERTS it instead of assuming it }
    function CompleteCalls: LongInt;
  end;

var
  // ---- per-(principal,method) bridge ledgers ----
  CountAdd: array[0..2] of LongInt;
  CountSettings: array[0..2] of LongInt;
  CountParking: array[0..2] of LongInt;
  CountWindow: array[0..2] of LongInt;
  CountOpenOk: array[0..2] of LongInt;
  CountOpenRefused: array[0..2] of LongInt;
  CountHandshake: array[0..2] of LongInt;
  CountReport: array[0..2] of LongInt;
  CountFault: array[0..2] of LongInt;
  // ---- the service counters (real mORMot leg) ----
  GuiServiceAdd: LongInt;
  NativeServiceAdd: LongInt;
  GuiPhase: LongInt; // 1 while the GUI leg runs
  // ---- opener spy ----
  OpenerCalls: LongInt;
  OpenerUnexpectedUri: LongInt;
  // ---- concurrency barrier (native isolation/grant tests) ----
  HeldCount: LongInt;      // invocations parked in the barriered method
  ReleaseGate: PRTLEvent;  // wake-nudge for parked workers (not the gate)
  ReleaseFlag: LongInt;    // the actual broadcast gate: 1 releases ALL parked
  ArrivalEvent: PRTLEvent; // a parked invocation pulses it on entry
  BarrierArmed: LongInt;   // 1 while the barriered method should park
  HeldReturned: PRTLEvent; // pulsed when a released holder LEAVES the barrier
  HeldSignalArmed: LongInt;// 1 while the lifecycle rendezvous wants that pulse
  // ---- GUI report latches ----
  ReportMainLatch: LongInt;
  ReportLoginLatch: LongInt;
  ReportMainJson: RawUtf8;
  ReportLoginJson: RawUtf8;
  AutoCloseHandle: Pointer;
  WatchdogEvent: PRTLEvent;
  WaiterEvent: PRTLEvent; // the report waiter's OWN event: RTL events are
                          // single-waiter, so the two helper threads never
                          // share one
  WaiterStop: LongInt;    // teardown sets it so the waiter exits promptly on
                          // EVERY path, not only when both latches are set
  // ---- corpus + failure accumulation ----
  CorpusLines: RawUtf8;
  FailReasons: RawUtf8;

function PrincipalIndex(const AId: RawUtf8): Integer;
begin
  if AId = ID_MAIN then
    Result := PRIN_MAIN
  else if AId = ID_LOGIN then
    Result := PRIN_LOGIN
  else if AId = ID_PLUGIN then
    Result := PRIN_PLUGIN
  else
    Result := -1;
end;

{ ---- opener spy (navmatrix shape) --------------------------------------- }

function SpyOpenerCore(const AUri: RawUtf8): Boolean;
begin
  InterlockedIncrement(OpenerCalls);
  if (AUri <> EXPECT_HTTPS) and (AUri <> EXPECT_MAILTO) then
    InterlockedIncrement(OpenerUnexpectedUri);
  Result := True;
end;

{$ifdef DARWIN}
function SpyOpenerCocoa(AUri: PAnsiChar): LongInt; cdecl;
var
  uri: RawUtf8;
begin
  if AUri = nil then
    uri := ''
  else
    FastSetString(uri, AUri, StrLen(AUri));
  if SpyOpenerCore(uri) then
    Result := 1
  else
    Result := 0;
end;
{$else}
function SpyOpener(const AUri: RawUtf8): Boolean;
begin
  Result := SpyOpenerCore(AUri);
end;
{$endif DARWIN}

procedure InstallOpenerSpy;
begin
  {$ifdef DARWIN}
  PWebCocoaSetExternalOpener(@SpyOpenerCocoa);
  {$else}
  {$ifdef LINUX}
  PWebGtkSetExternalOpener(@SpyOpener);
  {$else}
  PWebWv2SetExternalOpener(@SpyOpener);
  {$endif LINUX}
  {$endif DARWIN}
end;

procedure RemoveOpenerSpy;
begin
  {$ifdef DARWIN}
  PWebCocoaSetExternalOpener(nil);
  {$else}
  {$ifdef LINUX}
  PWebGtkSetExternalOpener(nil);
  {$else}
  PWebWv2SetExternalOpener(nil);
  {$endif LINUX}
  {$endif DARWIN}
end;

function CallPlatformOpener(const AUri: RawUtf8): Boolean;
begin
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

{ ---- service ------------------------------------------------------------- }

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  if InterlockedCompareExchange(GuiPhase, 0, 0) <> 0 then
    InterlockedIncrement(GuiServiceAdd)
  else
    InterlockedIncrement(NativeServiceAdd);
  Result := a + b;
end;

{ ---- policy-context handler (D9) ----------------------------------------- }

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

{ ---- recording completion ------------------------------------------------ }

constructor TRecordingCompletion.Create;
begin
  inherited Create;
  FEvent := RTLEventCreate;
end;

destructor TRecordingCompletion.Destroy;
begin
  if FEvent <> nil then
    RTLEventDestroy(FEvent);
  inherited Destroy;
end;

procedure TRecordingCompletion.Complete(const AResult: TPWebInvocationResult);
begin
  InterlockedIncrement(FCalls);
  if InterlockedExchange(FDone, 1) <> 0 then
    exit; // idempotent, exactly like the production sink
  FResult := AResult;
  RTLEventSetEvent(FEvent);
end;

function TRecordingCompletion.CompleteCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FCalls, 0, 0);
end;

function TRecordingCompletion.WaitResult(out AResult: TPWebInvocationResult;
  ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FEvent, ATimeoutMs);
  if InterlockedCompareExchange(FDone, 0, 0) <> 0 then
  begin
    AResult := FResult;
    Result := True;
  end
  else
  begin
    AResult := Default(TPWebInvocationResult);
    Result := False;
  end;
end;

{ ---- opener result (release-host copy, verbatim shape) ------------------- }

{ CAP-10A: the per-principal opener ledger, and nothing else. The decision
  is the shipped one (pweb.rpc.command), so the opener_main/opener_login/
  opener_plugin numbers the CAP-7F aggregator refuses on now describe the
  PRODUCT's command rather than this harness's copy of it. }
procedure ObserveExternalOpen(const Context: TInvocationContext;
  Outcome: TPWebOpenOutcome; UriBytes: PtrInt);
var
  p: Integer;
begin
  p := PrincipalIndex(Context.PrincipalId);
  if p < 0 then
    exit;
  case Outcome of
    pooRefused: InterlockedIncrement(CountOpenRefused[p]);
    pooOpened:  InterlockedIncrement(CountOpenOk[p]);
    // an opener FAILURE keeps its CAP-8C shape: counted nowhere, because
    // the injected spy in this harness never fails and a nonzero here would
    // have to be explained rather than silently absorbed into open_ok
    pooFailed: ;
  end;
end;

{ ---- the counting bridge ------------------------------------------------- }

constructor TCountingBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function CleanAddArgs(const Args: TPWebJson): TPWebJson;
var
  a, b: RawUtf8;
  payload: RawUtf8;
begin
  // reconstruct {"a":<a>,"b":<b>} from the two operands, dropping the barrier
  // sentinel and any forged fields. If either operand is absent the original
  // is passed through so the SOA bridge produces its own invalid_request.
  payload := Args;
  UniqueRawUtf8(payload);
  a := JsonDecode(payload, 'a');
  payload := Args;
  UniqueRawUtf8(payload);
  b := JsonDecode(payload, 'b');
  if (a = '') or (b = '') then
    exit(Args);
  Result := '{"a":' + a + ',"b":' + b + '}';
end;

procedure BarrierParkIfArmed;
var
  deadline: QWord;
begin
  // a barriered invocation parks here until the main thread OPENS THE GATE
  // (a broadcast flag, so every parked worker is released - not just one
  // event waiter), pulsing ArrivalEvent so the main thread knows it arrived.
  // No sleeps: the wait is on an explicit event, bounded by a safety timeout.
  if InterlockedCompareExchange(BarrierArmed, 0, 0) = 0 then
    exit;
  InterlockedIncrement(HeldCount);
  RTLEventSetEvent(ArrivalEvent);
  deadline := GetTickCount64 + BARRIER_WAIT_MS;
  while (InterlockedCompareExchange(ReleaseFlag, 0, 0) = 0) and
        (GetTickCount64 < deadline) do
    RTLEventWaitFor(ReleaseGate, 200);
  // the lifecycle rendezvous: signal that this holder has LEFT the barrier
  // and its bridge call is about to return - the worker's late CompleteOnce
  // follows within the same ExecuteItem iteration (see NativeLifecycle)
  if InterlockedCompareExchange(HeldSignalArmed, 0, 0) <> 0 then
    RTLEventSetEvent(HeldReturned);
end;

function TCountingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  p: Integer;
begin
  p := PrincipalIndex(Context.PrincipalId);
  // the barrier: any AUTHORIZED method (a denied one never reaches the
  // bridge) carrying the "hold" sentinel parks here for the in-flight-
  // snapshot, isolation and backpressure proofs. An explicit event, never a
  // sleep.
  if Pos('"hold":true', Args) > 0 then
    BarrierParkIfArmed;
  if Method = M_ADD then
  begin
    if p >= 0 then
      InterlockedIncrement(CountAdd[p]);
    // the REAL mORMot SOA leg: the service counter is the TInterfacedObject.
    // The SOA bridge validates its argument SHAPE strictly, so the barrier
    // "hold" sentinel (and any forged field) is stripped to the two real
    // operands before delegation - a forged field has zero AUTHORIZATION
    // effect but must not masquerade as a service argument.
    exit(FInner.Invoke(Context, Method, CleanAddArgs(Args), Token));
  end;
  if Method = M_SETTINGS then
  begin
    if p >= 0 then
      InterlockedIncrement(CountSettings[p]);
    exit(PWebSuccessResult('{"value":"stub"}'));
  end;
  if Method = M_PARKING then
  begin
    if p >= 0 then
      InterlockedIncrement(CountParking[p]);
    exit(PWebSuccessResult('{"items":[]}'));
  end;
  if Method = M_WINDOW then
  begin
    if p >= 0 then
      InterlockedIncrement(CountWindow[p]);
    exit(PWebSuccessResult('{"ok":true}'));
  end;
  if Method = PWEB_METHOD_HANDSHAKE then
  begin
    if p >= 0 then
      InterlockedIncrement(CountHandshake[p]);
    exit(PWebSuccessResult('{"protocol":' +
      Utf8String(IntToStr(PWEB_PROTOCOL_VERSION)) + ',"runtime":"' +
      PWEB_RUNTIME_VERSION + '"}'));
  end;
  if Method = PWEB_METHOD_ECHO then
    exit(PWebSuccessResult(Args));
  if Method = M_FAULT then
  begin
    if p >= 0 then
      InterlockedIncrement(CountFault[p]);
    // the "service raise" precedence case: a Pascal exception inside the
    // bridge becomes internal_error with no native detail leaked
    raise Exception.Create('deliberate fault for the precedence matrix');
  end;
  if Method = M_REPORT then
  begin
    // GUI report: latch the FIRST per principal, terminate once both in
    if p = PRIN_MAIN then
    begin
      if InterlockedCompareExchange(ReportMainLatch, 1, 0) = 0 then
        ReportMainJson := Args;
    end
    else if p = PRIN_LOGIN then
    begin
      if InterlockedCompareExchange(ReportLoginLatch, 1, 0) = 0 then
        ReportLoginJson := Args;
    end;
    if p >= 0 then
      InterlockedIncrement(CountReport[p]);
    // the run-owner loop is stopped by ReportWaiterThread once BOTH latches
    // are set (R-C2: terminate only the run-owner, only at shutdown) - never
    // from this worker-thread bridge call
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  // No.SuchMethod (zero-cap, no impl) and anything else -> method_not_found
  Result := PWebDefaultErrorResult(pecMethodNotFound);
end;

{ ---- policy -------------------------------------------------------------- }

function BuildCap8cPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALC, CAP_OPEN, CAP_SETTINGS, CAP_PARKING,
      CAP_WINDOW]);
    // the single shared window + principal configuration - no per-platform,
    // per-window or per-frontend variation
    b.SetWindowCapabilities('main', [CAP_CALC, CAP_OPEN, CAP_SETTINGS,
      CAP_PARKING, CAP_WINDOW]);
    b.SetWindowCapabilities('login', [CAP_SETTINGS, CAP_WINDOW]);
    b.SetPrincipalCapabilities(ID_MAIN, [CAP_CALC, CAP_OPEN, CAP_SETTINGS,
      CAP_PARKING, CAP_WINDOW]);
    b.SetPrincipalCapabilities(ID_LOGIN, [CAP_SETTINGS, CAP_WINDOW]);
    b.SetPrincipalCapabilities(ID_PLUGIN, [CAP_PARKING]);
    // method -> required (all-of), release-host mapping shape
    b.MapMethod(M_ADD, [CAP_CALC]);
    b.MapMethod(M_OPEN, [CAP_OPEN]);
    b.MapMethod(M_SETTINGS, [CAP_SETTINGS]);
    b.MapMethod(M_PARKING, [CAP_PARKING]);
    b.MapMethod(M_WINDOW, [CAP_WINDOW]);
    // zero-cap rows exactly as the release host, plus the harness report and
    // the deliberate-fault probe. No.SuchMethod preserved (mapped-but-
    // unregistered => 404 through the zero-cap route).
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(PWEB_METHOD_ECHO);
    b.RegisterZeroCapMethod(M_REPORT);
    b.RegisterZeroCapMethod(M_NOSUCH);
    b.RegisterZeroCapMethod(M_FAULT);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ ---- corpus + failure helpers ------------------------------------------- }

procedure Emit(const ALine: RawUtf8);
begin
  CorpusLines := CorpusLines + ALine + #10;
end;

procedure Fail(const AReason: RawUtf8);
begin
  if FailReasons <> '' then
    FailReasons := FailReasons + '; ';
  FailReasons := FailReasons + AReason;
end;

procedure Expect(ACond: Boolean; const AReason: RawUtf8);
begin
  if not ACond then
    Fail(AReason);
end;

function CapsCsv(const ACaps: TPWebCapabilities): RawUtf8;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ACaps) do
  begin
    if i > 0 then
      Result := Result + ',';
    Result := Result + ACaps[i];
  end;
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

function YesNo(ACond: Boolean): RawUtf8;
begin
  if ACond then
    Result := 'yes'
  else
    Result := 'no';
end;

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
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

{ code text for a terminal result: the wire `code` for an error, or the
  literal 'success:<value>' for a success (so the digest pins BOTH the arm
  and the value where it matters, e.g. Add=42) }
function CodeOf(const AResult: TPWebInvocationResult): RawUtf8;
begin
  if AResult.Kind = prkSuccess then
    Result := 'success'
  else
    Result := PWEB_ERROR_CODE_TEXT[AResult.Error.Code];
end;

{$ifdef DARWIN}
procedure CheckCocoaRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
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
  raise Exception.Create('no usable display (' + string(reason) + ')');
end;
{$endif LINUX}

// ============================ NATIVE LEG ==================================
// Everything below runs headless against the production scheduler/policy/
// bridge over three registered sources. Its emitted lines are the digest.

var
  gScheduler: TInvocationScheduler;
  gSchedulerRef: IInvocationScheduler;
  gPolicy: TPWebCapabilityPolicy;
  gPolicyRef: ICapabilityPolicy;
  gBridge: IInvocationBridge;
  gServer: TRestServerFullMemory;
  gRealBridge: IInvocationBridge;
  gSrcMain, gSrcLogin, gSrcPlugin: IInvocationSource;

function MakeContext(APrincipal: Integer;
  ATrusted: Boolean = True): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  case APrincipal of
    PRIN_MAIN:
      begin
        Result.WindowId := 'main';
        Result.PrincipalId := ID_MAIN;
        Result.PrincipalKind := pkWindow;
        Result.TrustedContent := ATrusted;
        Result.Capabilities := gPolicy.SnapshotCapabilities(ID_MAIN, 'main');
      end;
    PRIN_LOGIN:
      begin
        Result.WindowId := 'login';
        Result.PrincipalId := ID_LOGIN;
        Result.PrincipalKind := pkWindow;
        Result.TrustedContent := ATrusted;
        Result.Capabilities := gPolicy.SnapshotCapabilities(ID_LOGIN, 'login');
      end;
    PRIN_PLUGIN:
      begin
        Result.PrincipalId := ID_PLUGIN;
        Result.PrincipalKind := pkPlugin;
        Result.PluginId := 'reporting';
        Result.TrustedContent := ATrusted;
        Result.Capabilities := gPolicy.SnapshotCapabilities(ID_PLUGIN);
      end;
  end;
end;

function SourceFor(APrincipal: Integer): IInvocationSource;
begin
  case APrincipal of
    PRIN_MAIN: Result := gSrcMain;
    PRIN_LOGIN: Result := gSrcLogin;
  else
    Result := gSrcPlugin;
  end;
end;

{ run one invocation through a given source with a given context, returning
  the terminal code. A synchronous pre-queue rejection is mapped through the
  frozen PWEB_ENQUEUE_ERROR table, exactly as a transport would. }
function RunOn(ASource: IInvocationSource; const ACtx: TInvocationContext;
  const AMethod, AArgs: RawUtf8; out ARes: TPWebInvocationResult): RawUtf8;
var
  comp: TRecordingCompletion;
  compRef: IInvocationCompletion;
  enq: TPWebEnqueueResult;
begin
  ARes := Default(TPWebInvocationResult);
  comp := TRecordingCompletion.Create;
  compRef := comp;
  enq := ASource.TryEnqueue(ACtx, AMethod, AArgs, compRef);
  if enq <> perAccepted then
  begin
    ARes := PWebDefaultErrorResult(PWEB_ENQUEUE_ERROR[enq]);
    exit(PWEB_ERROR_CODE_TEXT[PWEB_ENQUEUE_ERROR[enq]]);
  end;
  if not comp.WaitResult(ARes, NATIVE_WAIT_MS) then
  begin
    Fail('native invocation ' + AMethod + ' did not complete');
    exit('timeout');
  end;
  Result := CodeOf(ARes);
end;

function Run(APrincipal: Integer; const AMethod, AArgs: RawUtf8): RawUtf8;
var
  res: TPWebInvocationResult;
begin
  Result := RunOn(SourceFor(APrincipal), MakeContext(APrincipal),
    AMethod, AArgs, res);
end;

const
  PRIN_NAME: array[0..2] of RawUtf8 = (
    'window:main', 'window:login', 'plugin:reporting');

procedure Decision(APrincipal: Integer; const AMethod, AArgs, AExpect: RawUtf8);
var
  code: RawUtf8;
begin
  code := Run(APrincipal, AMethod, AArgs);
  Emit('decision principal=' + PRIN_NAME[APrincipal] + ' method=' + AMethod +
    ' code=' + code);
  Expect(code = AExpect, 'decision ' + PRIN_NAME[APrincipal] + '/' + AMethod +
    ' = ' + code + ' expected ' + AExpect);
end;

procedure NativeMethodMatrix;
begin
  // the full per-principal method matrix - the heart of the multi-principal
  // proof: ONE policy, three principals, differentiated decisions
  Emit('snapshot principal=window:main window=main caps=' +
    CapsCsv(gPolicy.SnapshotCapabilities(ID_MAIN, 'main')));
  Emit('snapshot principal=window:login window=login caps=' +
    CapsCsv(gPolicy.SnapshotCapabilities(ID_LOGIN, 'login')));
  Emit('snapshot principal=plugin:reporting window= caps=' +
    CapsCsv(gPolicy.SnapshotCapabilities(ID_PLUGIN)));

  // Main: authorized for all five capabilities
  Decision(PRIN_MAIN, M_ADD, '{"a":20,"b":22}', 'success');
  Decision(PRIN_MAIN, M_SETTINGS, 'null', 'success');
  Decision(PRIN_MAIN, M_PARKING, 'null', 'success');
  Decision(PRIN_MAIN, M_WINDOW, 'null', 'success');
  Decision(PRIN_MAIN, M_OPEN, '{"url":"' + EXPECT_HTTPS + '"}', 'success');
  Decision(PRIN_MAIN, PWEB_METHOD_HANDSHAKE, 'null', 'success');

  // Login: settings.read + window.control only
  Decision(PRIN_LOGIN, M_ADD, '{"a":20,"b":22}', 'forbidden');
  Decision(PRIN_LOGIN, M_SETTINGS, 'null', 'success');
  Decision(PRIN_LOGIN, M_PARKING, 'null', 'forbidden');
  Decision(PRIN_LOGIN, M_WINDOW, 'null', 'success');
  Decision(PRIN_LOGIN, M_OPEN, '{"url":"' + EXPECT_HTTPS + '"}', 'forbidden');
  Decision(PRIN_LOGIN, PWEB_METHOD_HANDSHAKE, 'null', 'success');

  // Plugin: parking.read only, through the source-generic path
  Decision(PRIN_PLUGIN, M_ADD, '{"a":20,"b":22}', 'forbidden');
  Decision(PRIN_PLUGIN, M_SETTINGS, 'null', 'forbidden');
  Decision(PRIN_PLUGIN, M_PARKING, 'null', 'success');
  Decision(PRIN_PLUGIN, M_WINDOW, 'null', 'forbidden');
  Decision(PRIN_PLUGIN, M_OPEN, '{"url":"' + EXPECT_HTTPS + '"}', 'forbidden');
  Decision(PRIN_PLUGIN, PWEB_METHOD_HANDSHAKE, 'null', 'success');
end;

procedure NativePrecedence;
var
  p: Integer;
  ghost, nosuch, malformed, raise_: RawUtf8;
begin
  // identical per principal, no principal-specific side channel:
  //   unknown (unmapped)      -> forbidden
  //   No.SuchMethod (zero-cap)-> method_not_found (bridge miss, 404 route)
  //   malformed grammar       -> invalid_request (enqueue gate)
  //   fault.raise (zero-cap)  -> internal_error (bridge raises)
  for p := PRIN_MAIN to PRIN_PLUGIN do
  begin
    ghost := Run(p, M_GHOST, 'null');
    nosuch := Run(p, M_NOSUCH, 'null');
    malformed := Run(p, 'not a method', 'null');
    raise_ := Run(p, M_FAULT, 'null');
    Emit('precedence principal=' + PRIN_NAME[p] + ' unknown=' + ghost +
      ' nosuch=' + nosuch + ' malformed=' + malformed + ' raise=' + raise_);
    Expect(ghost = 'forbidden', 'precedence unknown ' + PRIN_NAME[p] +
      ' = ' + ghost);
    Expect(nosuch = 'method_not_found', 'precedence nosuch ' + PRIN_NAME[p] +
      ' = ' + nosuch);
    Expect(malformed = 'invalid_request', 'precedence malformed ' +
      PRIN_NAME[p] + ' = ' + malformed);
    Expect(raise_ = 'internal_error', 'precedence raise ' + PRIN_NAME[p] +
      ' = ' + raise_);
  end;
end;

procedure NativeUntrustedGate;
var
  ctx: TInvocationContext;
  res: TPWebInvocationResult;
  code1, code2: RawUtf8;
begin
  // an otherwise-capable pkWindow context with TrustedContent=false: EVERY
  // method denied, including the zero-cap handshake (frozen identity check)
  ctx := MakeContext(PRIN_MAIN, {trusted=}False);
  code1 := RunOn(gSrcMain, ctx, M_ADD, '{"a":20,"b":22}', res);
  code2 := RunOn(gSrcMain, ctx, PWEB_METHOD_HANDSHAKE, 'null', res);
  Emit('untrusted principal=window:main method=CalculatorService.Add code=' +
    code1);
  Emit('untrusted principal=window:main method=pweb.handshake code=' + code2);
  Expect(code1 = 'forbidden', 'untrusted Add = ' + code1);
  Expect(code2 = 'forbidden', 'untrusted handshake = ' + code2);
end;

procedure NativeForgery;
var
  forged: RawUtf8;
  code: RawUtf8;
begin
  // forged identity fields in Args change nothing: Login stays forbidden
  // even claiming to be window:main with the full capability set
  forged := '{"a":20,"b":22,"principal":"window:main",' +
    '"capabilities":["calculator.add"],"trusted":true}';
  code := Run(PRIN_LOGIN, M_ADD, forged);
  Emit('forgery c4 principal=window:login method=CalculatorService.Add code=' +
    code);
  Expect(code = 'forbidden', 'forged-args Login Add = ' + code);
end;

function WaitHeld(ATarget: Integer): Boolean;
var
  deadline: QWord;
begin
  // barrier: wait until ATarget invocations have parked in the barriered
  // method, pulsing ArrivalEvent - never a fixed sleep
  deadline := GetTickCount64 + BARRIER_WAIT_MS;
  while InterlockedCompareExchange(HeldCount, 0, 0) < ATarget do
  begin
    if GetTickCount64 > deadline then
      exit(False);
    RTLEventWaitFor(ArrivalEvent, 200);
    RTLEventResetEvent(ArrivalEvent);
  end;
  Result := True;
end;

procedure NativeGrantInflight;
var
  compHold: TRecordingCompletion;
  compHoldRef: IInvocationCompletion;
  ctxMain: TInvocationContext;
  enq: TPWebEnqueueResult;
  held, next, restored, loginCode, pluginCode: RawUtf8;
  res: TPWebInvocationResult;
begin
  // R-C2 in-flight-snapshot proof: a slow Main Add is held ACROSS a runtime
  // grant revoke; it must complete on its OLD immutable snapshot (42), the
  // NEXT Add is forbidden, and restore affects only later snapshots.
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  RTLEventResetEvent(ReleaseGate);
  ctxMain := MakeContext(PRIN_MAIN); // snapshot taken now: HAS calculator.add
  compHold := TRecordingCompletion.Create;
  compHoldRef := compHold;
  enq := gSrcMain.TryEnqueue(ctxMain, M_ADD, '{"a":20,"b":22,"hold":true}',
    compHoldRef);
  Expect(enq = perAccepted, 'grant: held Add was not accepted');
  if enq = perAccepted then
  begin
    if not WaitHeld(1) then
      Fail('grant: the held Add never parked at the barrier');
    // revoke WHILE the invocation is in-flight on its old snapshot
    gPolicy.RevokeRuntimeGrant(ID_MAIN, CAP_CALC);
    // the NEXT Add, snapshotted AFTER the revoke, is forbidden
    next := RunOn(gSrcMain, MakeContext(PRIN_MAIN), M_ADD, '{"a":20,"b":22}',
      res);
    // Login and Plugin are unaffected by a window:main grant change
    loginCode := Run(PRIN_LOGIN, M_SETTINGS, 'null');
    pluginCode := Run(PRIN_PLUGIN, M_PARKING, 'null');
    // release the held invocation: it completes on its captured snapshot
    InterlockedExchange(ReleaseFlag, 1);
    InterlockedExchange(BarrierArmed, 0);
    RTLEventSetEvent(ReleaseGate);
    if compHold.WaitResult(res, NATIVE_WAIT_MS) then
      held := CodeOf(res)
    else
    begin
      held := 'timeout';
      Fail('grant: the held Add never completed after release');
    end;
    // restore, then confirm later snapshots carry the capability again
    gPolicy.ClearRuntimeGrants(ID_MAIN);
    restored := Run(PRIN_MAIN, M_ADD, '{"a":20,"b":22}');
    Emit('grant inflight=' + held + ' next=' + next + ' restore=' + restored +
      ' login=' + loginCode + ' plugin=' + pluginCode);
    Expect(held = 'success', 'grant in-flight completed as ' + held);
    Expect(next = 'forbidden', 'grant next Add = ' + next);
    Expect(restored = 'success', 'grant restore Add = ' + restored);
    Expect(loginCode = 'success', 'grant login unaffected = ' + loginCode);
    Expect(pluginCode = 'success', 'grant plugin unaffected = ' + pluginCode);
  end;
end;

{ The C1-C7 mapping of the frozen I/O matrix row ("concurrent Main/Login,
  Main/Plugin, Login/Plugin; forged fields; close-one; backpressure"):
    C1 = concurrent Main/Login          -> NativeIsolationC1 ('isolation c1')
    C2 = concurrent Main/Plugin         -> NativeIsolationC2 ('isolation c2')
    C3 = concurrent Login/Plugin        -> NativeIsolationC3 ('isolation c3')
    C4 = forged fields (native)         -> NativeForgery     ('forgery c4')
    C5 = forged fields + content-swap   -> the GUI leg's forged vectors +
                                           swap rows ('gui content_swap')
    C6 = close-one                      -> NativeLifecycle   ('lifecycle c6')
    C7 = backpressure                   -> NativeBackpressure('backpressure c7')
  In every pairwise test each invocation completes into ITS OWN
  per-invocation sink with ITS OWN principal's decision - no cross-source
  completion is representable - and the bridge deltas are exact. }

procedure NativeIsolationC1;
var
  cMain, cLogin: TRecordingCompletion;
  rMain, rLogin: IInvocationCompletion;
  eMain, eLogin: TPWebEnqueueResult;
  res: TPWebInvocationResult;
  addMainBefore, addLoginBefore: LongInt;
  cMainCode, cLoginCode: RawUtf8;
begin
  // C1: Main and Login concurrently. The authorized Main Add PARKS in the
  // bridge; the Login Add is FORBIDDEN and completes pre-bridge WHILE the
  // Main invocation is demonstrably in flight - the deny is a pre-bridge
  // decision even under concurrency, and neither bleeds into the other.
  addMainBefore := InterlockedCompareExchange(CountAdd[PRIN_MAIN], 0, 0);
  addLoginBefore := InterlockedCompareExchange(CountAdd[PRIN_LOGIN], 0, 0);
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  RTLEventResetEvent(ReleaseGate);
  cMain := TRecordingCompletion.Create; rMain := cMain;
  cLogin := TRecordingCompletion.Create; rLogin := cLogin;
  eMain := gSrcMain.TryEnqueue(MakeContext(PRIN_MAIN), M_ADD,
    '{"a":20,"b":22,"hold":true}', rMain);
  eLogin := gSrcLogin.TryEnqueue(MakeContext(PRIN_LOGIN), M_ADD,
    '{"a":20,"b":22,"hold":true}', rLogin);
  Expect((eMain = perAccepted) and (eLogin = perAccepted),
    'isolation c1: an enqueue was not accepted');
  if not WaitHeld(1) then
    Fail('isolation c1: the authorized Main Add never parked');
  if cLogin.WaitResult(res, NATIVE_WAIT_MS) then
    cLoginCode := CodeOf(res)
  else
    cLoginCode := 'timeout';
  InterlockedExchange(ReleaseFlag, 1);
  InterlockedExchange(BarrierArmed, 0);
  RTLEventSetEvent(ReleaseGate);
  if cMain.WaitResult(res, NATIVE_WAIT_MS) then
    cMainCode := CodeOf(res)
  else
    cMainCode := 'timeout';
  Emit('isolation c1 main=' + cMainCode + ' login=' + cLoginCode +
    ' main_add_delta=' + Utf8String(IntToStr(
      InterlockedCompareExchange(CountAdd[PRIN_MAIN], 0, 0) - addMainBefore)) +
    ' login_add_delta=' + Utf8String(IntToStr(
      InterlockedCompareExchange(CountAdd[PRIN_LOGIN], 0, 0) - addLoginBefore)));
  Expect(cMainCode = 'success', 'isolation c1 Main = ' + cMainCode);
  Expect(cLoginCode = 'forbidden', 'isolation c1 Login = ' + cLoginCode);
  Expect(InterlockedCompareExchange(CountAdd[PRIN_MAIN], 0, 0) -
    addMainBefore = 1, 'isolation c1: Main add delta <> 1');
  Expect(InterlockedCompareExchange(CountAdd[PRIN_LOGIN], 0, 0) -
    addLoginBefore = 0, 'isolation c1: Login add delta <> 0');
end;

procedure NativeIsolationC2;
var
  cMain, cPlugin: TRecordingCompletion;
  rMain, rPlugin: IInvocationCompletion;
  eMain, ePlugin: TPWebEnqueueResult;
  res: TPWebInvocationResult;
  addBefore, parkBefore: LongInt;
  cMainCode, cPluginCode: RawUtf8;
begin
  // C2: Main and Plugin concurrently - BOTH authorized, parked at the
  // barrier AT THE SAME TIME on two different sources, then released; each
  // completes into its own sink and the per-principal bridge deltas are
  // exactly one each.
  addBefore := InterlockedCompareExchange(CountAdd[PRIN_MAIN], 0, 0);
  parkBefore := InterlockedCompareExchange(CountParking[PRIN_PLUGIN], 0, 0);
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  RTLEventResetEvent(ReleaseGate);
  cMain := TRecordingCompletion.Create; rMain := cMain;
  cPlugin := TRecordingCompletion.Create; rPlugin := cPlugin;
  eMain := gSrcMain.TryEnqueue(MakeContext(PRIN_MAIN), M_ADD,
    '{"a":20,"b":22,"hold":true}', rMain);
  ePlugin := gSrcPlugin.TryEnqueue(MakeContext(PRIN_PLUGIN), M_PARKING,
    '{"hold":true}', rPlugin);
  Expect((eMain = perAccepted) and (ePlugin = perAccepted),
    'isolation c2: an enqueue was not accepted');
  if not WaitHeld(2) then
    Fail('isolation c2: the two authorized holders never parked concurrently');
  InterlockedExchange(ReleaseFlag, 1);
  InterlockedExchange(BarrierArmed, 0);
  RTLEventSetEvent(ReleaseGate);
  if cMain.WaitResult(res, NATIVE_WAIT_MS) then
    cMainCode := CodeOf(res)
  else
    cMainCode := 'timeout';
  if cPlugin.WaitResult(res, NATIVE_WAIT_MS) then
    cPluginCode := CodeOf(res)
  else
    cPluginCode := 'timeout';
  Emit('isolation c2 main=' + cMainCode + ' plugin=' + cPluginCode +
    ' main_add_delta=' + Utf8String(IntToStr(
      InterlockedCompareExchange(CountAdd[PRIN_MAIN], 0, 0) - addBefore)) +
    ' plugin_parking_delta=' + Utf8String(IntToStr(
      InterlockedCompareExchange(CountParking[PRIN_PLUGIN], 0, 0) - parkBefore)));
  Expect(cMainCode = 'success', 'isolation c2 Main = ' + cMainCode);
  Expect(cPluginCode = 'success', 'isolation c2 Plugin = ' + cPluginCode);
  Expect(InterlockedCompareExchange(CountAdd[PRIN_MAIN], 0, 0) -
    addBefore = 1, 'isolation c2: Main add delta <> 1');
  Expect(InterlockedCompareExchange(CountParking[PRIN_PLUGIN], 0, 0) -
    parkBefore = 1, 'isolation c2: Plugin parking delta <> 1');
end;

procedure NativeIsolationC3;
var
  cLogin, cPlugin: TRecordingCompletion;
  rLogin, rPlugin: IInvocationCompletion;
  eLogin, ePlugin: TPWebEnqueueResult;
  res: TPWebInvocationResult;
  addBefore, parkBefore: LongInt;
  cLoginCode, cPluginCode: RawUtf8;
begin
  // C3: Login and Plugin concurrently. The authorized Plugin Parking parks;
  // the forbidden Login Add completes pre-bridge while it is in flight.
  addBefore := InterlockedCompareExchange(CountAdd[PRIN_LOGIN], 0, 0);
  parkBefore := InterlockedCompareExchange(CountParking[PRIN_PLUGIN], 0, 0);
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  RTLEventResetEvent(ReleaseGate);
  cLogin := TRecordingCompletion.Create; rLogin := cLogin;
  cPlugin := TRecordingCompletion.Create; rPlugin := cPlugin;
  ePlugin := gSrcPlugin.TryEnqueue(MakeContext(PRIN_PLUGIN), M_PARKING,
    '{"hold":true}', rPlugin);
  eLogin := gSrcLogin.TryEnqueue(MakeContext(PRIN_LOGIN), M_ADD,
    '{"a":20,"b":22,"hold":true}', rLogin);
  Expect((eLogin = perAccepted) and (ePlugin = perAccepted),
    'isolation c3: an enqueue was not accepted');
  if not WaitHeld(1) then
    Fail('isolation c3: the authorized Plugin Parking never parked');
  if cLogin.WaitResult(res, NATIVE_WAIT_MS) then
    cLoginCode := CodeOf(res)
  else
    cLoginCode := 'timeout';
  InterlockedExchange(ReleaseFlag, 1);
  InterlockedExchange(BarrierArmed, 0);
  RTLEventSetEvent(ReleaseGate);
  if cPlugin.WaitResult(res, NATIVE_WAIT_MS) then
    cPluginCode := CodeOf(res)
  else
    cPluginCode := 'timeout';
  Emit('isolation c3 login=' + cLoginCode + ' plugin=' + cPluginCode +
    ' login_add_delta=' + Utf8String(IntToStr(
      InterlockedCompareExchange(CountAdd[PRIN_LOGIN], 0, 0) - addBefore)) +
    ' plugin_parking_delta=' + Utf8String(IntToStr(
      InterlockedCompareExchange(CountParking[PRIN_PLUGIN], 0, 0) - parkBefore)));
  Expect(cLoginCode = 'forbidden', 'isolation c3 Login = ' + cLoginCode);
  Expect(cPluginCode = 'success', 'isolation c3 Plugin = ' + cPluginCode);
  Expect(InterlockedCompareExchange(CountAdd[PRIN_LOGIN], 0, 0) -
    addBefore = 0, 'isolation c3: Login add delta <> 0');
  Expect(InterlockedCompareExchange(CountParking[PRIN_PLUGIN], 0, 0) -
    parkBefore = 1, 'isolation c3: Plugin parking delta <> 1');
end;

procedure NativeBackpressure;
var
  ctx: TInvocationContext;
  c1, c2, c3: TRecordingCompletion;
  r1, r2, r3: IInvocationCompletion;
  e1, e2, e3: TPWebEnqueueResult;
  res: TPWebInvocationResult;
  code1, code2: RawUtf8;
begin
  // C7 backpressure: fill the plugin source's queue while a worker is parked
  // at the barrier, then prove the next enqueue is a non-blocking perBusy.
  // gSrcPlugin was registered with MaxConcurrent=1, MaxQueueSize=1; the
  // shared bridge barrier parks ANY authorized method carrying "hold":true.
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  RTLEventResetEvent(ReleaseGate);
  ctx := MakeContext(PRIN_PLUGIN);
  c1 := TRecordingCompletion.Create; r1 := c1;
  c2 := TRecordingCompletion.Create; r2 := c2;
  c3 := TRecordingCompletion.Create; r3 := c3;
  // ORDERED BY BARRIER, never by luck: the first call must be CLAIMED (in
  // flight, parked in the bridge) before the second is enqueued - otherwise
  // the second races the worker's claim for the single queue slot (measured:
  // one in three local runs refused it as busy). With MaxConcurrent=1
  // occupied by the parked call, the second is guaranteed to stay queued and
  // the third meets a full queue deterministically.
  e1 := gSrcPlugin.TryEnqueue(ctx, M_PARKING, '{"hold":true}', r1);
  Expect(e1 = perAccepted, 'backpressure first not accepted at enqueue');
  if not WaitHeld(1) then
    Fail('backpressure: the first parking call never parked');
  e2 := gSrcPlugin.TryEnqueue(ctx, M_PARKING, 'null', r2); // queued behind it
  e3 := gSrcPlugin.TryEnqueue(ctx, M_PARKING, 'null', r3); // queue full
  InterlockedExchange(ReleaseFlag, 1);
  InterlockedExchange(BarrierArmed, 0);
  RTLEventSetEvent(ReleaseGate);
  // the refused overflow never completes (its sink is never invoked); the
  // two ACCEPTED invocations must both complete successfully after release -
  // asserted, never discarded
  if c1.WaitResult(res, NATIVE_WAIT_MS) then
    code1 := CodeOf(res)
  else
    code1 := 'timeout';
  if c2.WaitResult(res, NATIVE_WAIT_MS) then
    code2 := CodeOf(res)
  else
    code2 := 'timeout';
  Emit('backpressure c7 first=' + Utf8String(IntToStr(Ord(e1))) +
    ' queued=' + Utf8String(IntToStr(Ord(e2))) +
    ' overflow=' + Utf8String(IntToStr(Ord(e3))) +
    ' first_result=' + code1 + ' queued_result=' + code2);
  Expect(e2 = perAccepted, 'backpressure second not accepted');
  Expect(e3 = perBusy, 'backpressure overflow not busy: ' +
    Utf8String(IntToStr(Ord(e3))));
  Expect(code1 = 'success', 'backpressure first completed as ' + code1);
  Expect(code2 = 'success', 'backpressure queued completed as ' + code2);
  Expect(c3.CompleteCalls = 0,
    'backpressure: the refused overflow reached its sink');
end;

procedure NativeLifecycle;
var
  staleCtx: TInvocationContext;
  res: TPWebInvocationResult;
  closedCode, freshCode, mainStill, pluginStill: RawUtf8;
  heldCode, mainAfterPluginClose, mainClosedCode: RawUtf8;
  freshSrc: IInvocationSource;
  limits: TPWebSourceLimits;
  cHold: TRecordingCompletion;
  rHold: IInvocationCompletion;
  enq: TPWebEnqueueResult;
  holdCalls: LongInt;
begin
  // R-C2 source-level close/reopen on long-lived instances.
  //
  // FIRST the stale-in-flight gate: an invocation from the OLD Login
  // context is parked IN the bridge when the source closes. Close completes
  // it as cancelled through its per-invocation sink; the worker's LATE
  // result then dies at the frozen exactly-once gate - so the old context
  // can NEVER complete into anything again (least of all a fresh source,
  // which has its own sinks by construction), and the sink saw EXACTLY one
  // delivery: no callback-after-free, no stale reuse, no double completion.
  staleCtx := MakeContext(PRIN_LOGIN);
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  InterlockedExchange(HeldSignalArmed, 1);
  RTLEventResetEvent(ReleaseGate);
  RTLEventResetEvent(HeldReturned);
  cHold := TRecordingCompletion.Create;
  rHold := cHold;
  enq := gSrcLogin.TryEnqueue(staleCtx, M_SETTINGS, '{"hold":true}', rHold);
  Expect(enq = perAccepted, 'lifecycle: the stale-held enqueue was refused');
  if (enq = perAccepted) and not WaitHeld(1) then
    Fail('lifecycle: the stale-held call never parked');
  gSrcLogin.Close; // completes the in-flight invocation as cancelled NOW
  if cHold.WaitResult(res, NATIVE_WAIT_MS) then
    heldCode := CodeOf(res)
  else
    heldCode := 'timeout';
  // release the parked worker: its late result must die at the gate
  InterlockedExchange(ReleaseFlag, 1);
  InterlockedExchange(BarrierArmed, 0);
  RTLEventSetEvent(ReleaseGate);
  // RENDEZVOUS with the late attempt before reading the exactly-once
  // counter: the bridge pulses HeldReturned the moment the released holder
  // leaves the barrier, and the worker's late CompleteOnce follows within
  // the same ExecuteItem iteration - the frozen scheduler exposes no
  // post-CompleteOnce hook, so after the pulse one short bounded settle
  // wait covers those few remaining instructions. The gate itself makes a
  // second sink delivery impossible IN PRINCIPLE (CompleteOnce's
  // InterlockedExchange first-wins); this read makes the swallow MEASURED
  // after the attempt has actually run, not merely implied.
  RTLEventWaitFor(HeldReturned, NATIVE_WAIT_MS);
  InterlockedExchange(HeldSignalArmed, 0);
  RTLEventResetEvent(HeldReturned);
  RTLEventWaitFor(HeldReturned, 100); // bounded settle; never set again here
  // the closed source refuses new work; the OTHERS stay fully functional
  closedCode := RunOn(gSrcLogin, staleCtx, M_SETTINGS, 'null', res);
  mainStill := Run(PRIN_MAIN, M_ADD, '{"a":20,"b":22}');
  pluginStill := Run(PRIN_PLUGIN, M_PARKING, 'null');
  // reopen: a brand-new source armed with a FRESH login context - the old
  // context/sink cannot complete into it (each sink is per-invocation and
  // the old one is already terminally completed, asserted below)
  limits := Default(TPWebSourceLimits);
  limits.MaxConcurrent := 4;
  limits.MaxQueueSize := 16;
  freshSrc := gScheduler.RegisterSource(limits);
  freshCode := RunOn(freshSrc, MakeContext(PRIN_LOGIN), M_SETTINGS, 'null',
    res);
  holdCalls := cHold.CompleteCalls;
  Emit('lifecycle c6 stale_held=' + heldCode + ' stale_completions=' +
    Utf8String(IntToStr(holdCalls)) + ' closed=' + closedCode +
    ' main_still=' + mainStill + ' plugin_still=' + pluginStill +
    ' reopened=' + freshCode);
  Expect(heldCode = 'cancelled', 'lifecycle stale-held completed as ' +
    heldCode);
  Expect(holdCalls = 1, 'lifecycle stale sink deliveries = ' +
    Utf8String(IntToStr(holdCalls)));
  Expect(closedCode = 'runtime_closed', 'lifecycle closed source = ' +
    closedCode);
  Expect(mainStill = 'success', 'lifecycle main still = ' + mainStill);
  Expect(pluginStill = 'success', 'lifecycle plugin still = ' + pluginStill);
  Expect(freshCode = 'success', 'lifecycle reopened = ' + freshCode);
  freshSrc.Close;
  // REVERSE CLOSE ORDER (registration was main, login, plugin): plugin
  // closes first with Main still functional after it, Main closes last and
  // then refuses - the scheduler outlives every source and Shutdown later
  // finds them already closed (idempotent by the frozen contract)
  gSrcPlugin.Close;
  mainAfterPluginClose := Run(PRIN_MAIN, M_SETTINGS, 'null');
  gSrcMain.Close;
  mainClosedCode := RunOn(gSrcMain, MakeContext(PRIN_MAIN), M_SETTINGS,
    'null', res);
  Emit('lifecycle c6 reverse_close main_after_plugin_close=' +
    mainAfterPluginClose + ' main_closed=' + mainClosedCode);
  Expect(mainAfterPluginClose = 'success',
    'lifecycle main after plugin close = ' + mainAfterPluginClose);
  Expect(mainClosedCode = 'runtime_closed',
    'lifecycle main closed = ' + mainClosedCode);
end;

procedure RunNativeLeg;
var
  limits: TPWebSourceLimits;
  pluginLimits: TPWebSourceLimits;
begin
  gServer := TRestServerFullMemory.CreateWithOwnModel([]);
  if gServer.ServiceRegister(TCalculatorService,
       [TypeInfo(ICalculatorService)], sicShared) = nil then
    raise Exception.Create('unable to register CalculatorService');
  gRealBridge := TMormotInvocationBridge.Create(gServer, True);
  gServer := nil; // owned by the bridge now
  // CAP-10A: the SHIPPED runtime-command layer over the counting bridge -
  // the counting bridge answers method_not_found for anything it does not
  // implement, so the command layer is the OUTER decorator here.
  gBridge := TPWebRuntimeCommandBridge.Create(
    TCountingBridge.Create(gRealBridge), @CallPlatformOpener,
    @ObserveExternalOpen);
  gPolicy := BuildCap8cPolicy;
  gPolicyRef := gPolicy;
  gScheduler := TInvocationScheduler.Create(gPolicyRef, gBridge, 4);
  gSchedulerRef := gScheduler;
  limits := Default(TPWebSourceLimits);
  limits.MaxConcurrent := 4;
  limits.MaxQueueSize := 32;
  gSrcMain := gScheduler.RegisterSource(limits);
  gSrcLogin := gScheduler.RegisterSource(limits);
  pluginLimits := Default(TPWebSourceLimits);
  pluginLimits.MaxConcurrent := 1; // tight, for the backpressure proof
  pluginLimits.MaxQueueSize := 1;
  gSrcPlugin := gScheduler.RegisterSource(pluginLimits);

  Emit('schema=1');
  Emit('policy appmax=' + CapsCsv(PWebCapabilitySetOf(
    [CAP_CALC, CAP_OPEN, CAP_SETTINGS, CAP_PARKING, CAP_WINDOW])));
  NativeMethodMatrix;
  NativePrecedence;
  NativeUntrustedGate;
  NativeForgery;      // C4
  NativeGrantInflight;
  NativeIsolationC1;  // C1 Main/Login
  NativeIsolationC2;  // C2 Main/Plugin
  NativeIsolationC3;  // C3 Login/Plugin
  NativeBackpressure; // C7
  NativeLifecycle;    // C6 (close-one) + reverse close order
end;

// ============================== GUI LEG ===================================
// Two simultaneously live real WebViews (R-C1). Modeled on navmatrix's
// construction/teardown; the run loop is on the Main view (run-owner).
//
// ASSET-ARMING TOPOLOGY, platform-honest (measured hosted, run 32770563751):
//   - Windows/WebView2: the WebResourceRequested handler is PER CONTROLLER,
//     so each window arms its own handler (proven green hosted);
//   - Linux/WebKitGTK: the scheme registration is per WebKitWebContext, and
//     both views created via webview_create(nil) share the DEFAULT context -
//     a second registration is refused by the adapter. ONE handler is
//     registered through the FIRST view's context and serves both;
//   - macOS/WKWebView: the Cocoa bridge keeps a single process-wide armed
//     handler whose pre-create seam installs it into EVERY
//     WKWebViewConfiguration created while armed. ONE handler is created
//     BEFORE either webview_create; its single-shot Attach verifies the
//     FIRST view, and the SECOND view's service is asserted through its own
//     page-loaded report (the driver cannot report without being served).
// The navigation guards are PER VIEW on every platform: per-controller
// events on Windows, per-view signals on Linux, and - under the R-C4
// ratification (CAP-8C Checkpoint follow-up) - per-view arming in the
// private Cocoa bridge: each guard's Create stages its handle, its Attach
// binds it to THAT window, and every decision resolves the arriving view to
// its own guard. Double-arming a single view stays a loud pre-flight
// refusal ('a navigation guard is already armed in this process').

type
  { which asset arming this window performs (see the topology note above) }
  TGuiAssetMode = (
    gamPerView,     // Windows: this window creates its own store + handler
    gamSharedFirst, // POSIX first window: arm/verify the ONE shared handler
    gamNone         // POSIX second window: served by the shared arming
  );

  TGuiWindow = record
    W: webview_t;
    Store: IAssetStore;
    Handler: TPWebAssetHandler;
    Guard: TPWebNavigationGuard;
    Binding: IWebViewBinding;
    Source: IInvocationSource;
    // the guard's decision counters, captured at teardown BEFORE Detach
    // (navmatrix pattern): the raw-nav row requires cancelled >= 1 PER
    // window, so a deferred-but-later-honoured navigation cannot hide
    // behind a still-trusted address at report time
    GuardAllowed: Int64;
    GuardCancelled: Int64;
    GuardApplyFailures: Int64;
  end;

var
  gGuiScheduler: TInvocationScheduler;
  gGuiSchedulerRef: IInvocationScheduler;
  gGuiPolicy: TPWebCapabilityPolicy;
  gGuiPolicyRef: ICapabilityPolicy;
  gGuiBridge: IInvocationBridge;
  gGuiServer: TRestServerFullMemory;
  gGuiRealBridge: IInvocationBridge;
  // the POSIX single arming (see the topology note above): ONE store, ONE
  // handler for the whole process; nil throughout on Windows
  gSharedStore: IAssetStore;
  gSharedHandler: TPWebAssetHandler;

procedure GuiBuildWindow(var AWin: TGuiWindow; APrincipal: Integer;
  const AFixtureDir: TFileName; const ANavUrl: RawUtf8;
  const ATitle: RawUtf8; AAssetMode: TGuiAssetMode);
var
  limits: TPWebSourceLimits;
  ctx: TInvocationContext;
  opts: TPWebWebViewBindingOptions;
begin
  if AAssetMode = gamPerView then
    AWin.Store := TFolderAssetStore.Create(AFixtureDir);
  limits := Default(TPWebSourceLimits);
  limits.MaxConcurrent := 4;
  limits.MaxQueueSize := 32;
  AWin.Source := gGuiScheduler.RegisterSource(limits);

  AWin.W := WebViewCheckCreated(webview_create(0, nil));
  {$ifdef DARWIN}
  // the shared handler was created BEFORE any webview_create (RunGuiLeg), so
  // this view's configuration went through the armed seam; the frozen class
  // offers exactly one Attach, spent on the FIRST view - the second view's
  // service is proven by its page-loaded report, never assumed
  if AAssetMode = gamSharedFirst then
    gSharedHandler.Attach(AWin.W);
  {$endif DARWIN}
  ctx := Default(TInvocationContext);
  if APrincipal = PRIN_MAIN then
  begin
    ctx.WindowId := 'main';
    ctx.PrincipalId := ID_MAIN;
  end
  else
  begin
    ctx.WindowId := 'login';
    ctx.PrincipalId := ID_LOGIN;
  end;
  ctx.PrincipalKind := pkWindow;
  ctx.TrustedContent := True;
  opts := PWebDefaultBindingOptions(ctx);
  AWin.Binding := TWebViewBinding.Create(AWin.W, AWin.Source, opts);
  AWin.Binding.Bind('__pweb_invoke', TPolicyContextHandler.Create(
    TPWebEnvelopeHandler.Create(AWin.Source), gGuiPolicy));
  WebViewCheck(webview_set_title(AWin.W, PAnsiChar(AnsiString(ATitle))),
    'webview_set_title');
  WebViewCheck(webview_set_size(AWin.W, 720, 520, WEBVIEW_HINT_NONE),
    'webview_set_size');
  {$ifndef DARWIN}
  {$ifdef LINUX}
  // ONE registration per process, made through the FIRST view: both views
  // share the default WebKitWebContext, so this single registration serves
  // the second view too - a second Create would be refused by the adapter
  if AAssetMode = gamSharedFirst then
    gSharedHandler := TWebKitGtkAssetHandler.Create(AWin.W, gSharedStore);
  {$else}
  if AAssetMode = gamPerView then
    AWin.Handler := TWebView2AssetHandler.Create(AWin.W, AWin.Store);
  {$endif LINUX}
  {$endif DARWIN}
  {$ifdef DARWIN}
  AWin.Guard := TPWebNavigationGuard.Create;
  AWin.Guard.Attach(AWin.W);
  {$else}
  AWin.Guard := TPWebNavigationGuard.Create(AWin.W);
  {$endif DARWIN}
  WebViewCheck(webview_navigate(AWin.W, PAnsiChar(ANavUrl)), 'webview_navigate');
end;

{ detach this window's guard (counters captured first) and its PER-VIEW
  handler where one exists (Windows); the POSIX shared handler is detached
  ONCE, after both windows, in RunGuiLeg - after every guard has stopped
  deciding and before any webview_destroy, the release-host order }
procedure GuiDetachWindow(var AWin: TGuiWindow);
{$ifdef DARWIN}
var
  cocoaCounters: TPWebCocoaNavCounters;
{$endif DARWIN}
begin
  // reverse construction order, exactly as the release host / navmatrix
  if AWin.Binding <> nil then
    try
      AWin.Binding.Close;
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': binding Close: ', E.Message);
    end;
  if AWin.Guard <> nil then
  begin
    // the counters are read BEFORE Detach, through the properties that
    // survive it by design - exactly as navmatrix reads its one guard
    try
      {$ifdef DARWIN}
      cocoaCounters := AWin.Guard.Counters;
      AWin.GuardAllowed := Int64(cocoaCounters.Allowed);
      AWin.GuardCancelled := Int64(cocoaCounters.Cancelled);
      {$else}
      {$ifdef LINUX}
      AWin.GuardAllowed := AWin.Guard.AllowedCount;
      AWin.GuardCancelled := AWin.Guard.CancelledCount;
      {$else}
      AWin.GuardAllowed := AWin.Guard.AllowedTrusted;
      AWin.GuardCancelled := AWin.Guard.Cancelled;
      AWin.GuardApplyFailures := AWin.Guard.DenyApplyFailures;
      {$endif LINUX}
      {$endif DARWIN}
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': guard counters: ', E.Message);
    end;
    try
      AWin.Guard.Detach;
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': guard Detach: ', E.Message);
    end;
    try
      FreeAndNil(AWin.Guard);
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': guard Free: ', E.Message);
    end;
  end;
  if AWin.Handler <> nil then
  begin
    try
      AWin.Handler.Detach;
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': handler Detach: ', E.Message);
    end;
    FreeAndNil(AWin.Handler);
  end;
end;

{ post-loop native destruction; runs only after BOTH windows are detached
  and the shared handler (POSIX) is detached - never mid-loop (R-C3) }
procedure GuiDestroyWindow(var AWin: TGuiWindow);
begin
  if AWin.W <> nil then
  begin
    try
      WebViewCheck(webview_destroy(AWin.W), 'webview_destroy');
    except
      on E: Exception do
        WriteLn(StdErr, LOG_PREFIX, ': webview_destroy: ', E.Message);
    end;
    AWin.W := nil;
  end;
  AWin.Binding := nil;
  AWin.Source := nil;
  AWin.Store := nil;
end;

function WatchdogThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  RTLEventWaitFor(WatchdogEvent, PtrInt(Param));
  RequestTerminate;
end;

{ the report handler needs to terminate the loop once BOTH windows reported;
  the bridge's report path only latches, so a dispatched poll checks both
  latches. Simpler: a tiny GUI dispatch driven from a helper thread that
  waits on the latches. We reuse the watchdog thread pattern with an extra
  poll: when both latched, terminate. }
function ReportWaiterThread(Param: Pointer): PtrInt;
var
  deadline: QWord;
begin
  Result := 0;
  deadline := GetTickCount64 + QWord(PtrUInt(Param));
  while GetTickCount64 < deadline do
  begin
    if InterlockedCompareExchange(WaiterStop, 0, 0) <> 0 then
      exit;
    if (InterlockedCompareExchange(ReportMainLatch, 1, 1) = 1) and
       (InterlockedCompareExchange(ReportLoginLatch, 1, 1) = 1) then
    begin
      RequestTerminate;
      exit;
    end;
    RTLEventWaitFor(WaiterEvent, 100);
  end;
end;

var
  gMainWin, gLoginWin: TGuiWindow;
  GuiRan: Boolean;
  GuiSkipped: Boolean;
  GuiFirstCreateOk: Boolean; // set once the MAIN window's create succeeded:
                             // a nil SECOND create is a dual-window
                             // regression and must FAIL, never SKIP
  GuiBaseSettings: array[0..2] of LongInt; // pre-GUI bridge-counter baselines

function RunGuiLeg(const AFixtureDir: TFileName; ATimeoutMs: Integer): Boolean;
var
  watchdogId, waiterId: system.TThreadID;
  watchdogHandle, waiterHandle: system.TThreadID;
  watchdogStarted, waiterStarted, safeToDestroy: Boolean;
begin
  Result := False;
  GuiRan := False;
  GuiSkipped := False;
  watchdogStarted := False;
  waiterStarted := False;
  safeToDestroy := True;
  gMainWin := Default(TGuiWindow);
  gLoginWin := Default(TGuiWindow);

  // a SECOND scheduler for the GUI leg (its own sources/bridge), so the
  // native leg's scheduler can be fully shut down first
  gGuiServer := TRestServerFullMemory.CreateWithOwnModel([]);
  if gGuiServer.ServiceRegister(TCalculatorService,
       [TypeInfo(ICalculatorService)], sicShared) = nil then
    raise Exception.Create('unable to register GUI CalculatorService');
  gGuiRealBridge := TMormotInvocationBridge.Create(gGuiServer, True);
  gGuiServer := nil;
  gGuiBridge := TPWebRuntimeCommandBridge.Create(
    TCountingBridge.Create(gGuiRealBridge), @CallPlatformOpener,
    @ObserveExternalOpen);
  gGuiPolicy := BuildCap8cPolicy;
  gGuiPolicyRef := gGuiPolicy;
  gGuiScheduler := TInvocationScheduler.Create(gGuiPolicyRef, gGuiBridge, 4);
  gGuiSchedulerRef := gGuiScheduler;

  InterlockedExchange(GuiPhase, 1);
  InterlockedExchange(WaiterStop, 0);
  GuiFirstCreateOk := False;
  GuiBaseSettings[PRIN_MAIN] :=
    InterlockedCompareExchange(CountSettings[PRIN_MAIN], 0, 0);
  GuiBaseSettings[PRIN_LOGIN] :=
    InterlockedCompareExchange(CountSettings[PRIN_LOGIN], 0, 0);
  GuiBaseSettings[PRIN_PLUGIN] :=
    InterlockedCompareExchange(CountSettings[PRIN_PLUGIN], 0, 0);
  try
    // the POSIX single arming, BEFORE any webview exists (see the topology
    // note above): one shared store; on macOS the handler itself must be
    // created pre-create so the armed seam reaches BOTH configurations,
    // on Linux the handler is registered through the first view below
    {$ifdef DARWIN}
    gSharedStore := TFolderAssetStore.Create(AFixtureDir);
    gSharedHandler := TCocoaAssetHandler.Create(gSharedStore);
    {$else}
    {$ifdef LINUX}
    gSharedStore := TFolderAssetStore.Create(AFixtureDir);
    {$endif LINUX}
    {$endif DARWIN}
    // create Main first, Login second (destroy order is the reverse)
    // CONTENT-SWAP: Main is served the LOGIN page bytes; Login the MAIN
    // page - content is selected by URL PATH ONLY, so the one shared store
    // serves both windows and the swap gate is unchanged
    GuiBuildWindow(gMainWin, PRIN_MAIN, AFixtureDir, 'pweb://app/login.html',
      'PWeb CAP-8C Main', {$ifdef OSWINDOWS} gamPerView {$else} gamSharedFirst {$endif});
    // from here a nil create is a DUAL-WINDOW regression, never an absent
    // runtime: the SKIP classification below reads this flag
    GuiFirstCreateOk := True;
    GuiBuildWindow(gLoginWin, PRIN_LOGIN, AFixtureDir, 'pweb://app/main.html',
      'PWeb CAP-8C Login', {$ifdef OSWINDOWS} gamPerView {$else} gamNone {$endif});
    AutoCloseHandle := Pointer(gMainWin.W); // the run-owner

    WatchdogEvent := RTLEventCreate;
    WaiterEvent := RTLEventCreate;
    watchdogHandle := BeginThread(@WatchdogThread,
      Pointer(PtrInt(ATimeoutMs)), watchdogId);
    watchdogStarted := watchdogHandle <> system.TThreadID(0);
    waiterHandle := BeginThread(@ReportWaiterThread,
      Pointer(PtrInt(ATimeoutMs)), waiterId);
    waiterStarted := waiterHandle <> system.TThreadID(0);
    if not (watchdogStarted and waiterStarted) then
      raise Exception.Create('unable to start GUI helper threads');

    // the loop runs on the Main view (the run-owner); the topology probe
    // proved both views live and dispatch under this single loop
    WebViewCheck(webview_run(gMainWin.W), 'webview_run');
    GuiRan := True;
  finally
    // wake helpers, clear the handle so their terminate is a no-op
    InterlockedExchange(AutoCloseHandle, nil);
    InterlockedExchange(WaiterStop, 1);
    if WatchdogEvent <> nil then
      RTLEventSetEvent(WatchdogEvent);
    if WaiterEvent <> nil then
      RTLEventSetEvent(WaiterEvent);
    if watchdogStarted then
    begin
      if WaitForThreadTerminate(watchdogHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
        safeToDestroy := False;
      CloseThread(watchdogHandle);
    end;
    if waiterStarted then
    begin
      if WaitForThreadTerminate(waiterHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
        safeToDestroy := False;
      CloseThread(waiterHandle);
    end;
    if WatchdogEvent <> nil then
    begin
      if safeToDestroy then
        RTLEventDestroy(WatchdogEvent);
      WatchdogEvent := nil;
    end;
    if WaiterEvent <> nil then
    begin
      if safeToDestroy then
        RTLEventDestroy(WaiterEvent);
      WaiterEvent := nil;
    end;
    // drain both bindings (REVERSE creation order: Login closed first,
    // exactly as its window is destroyed first) + the scheduler BEFORE any
    // destroy - services are released only after the drain, in the final
    // teardown chain
    if gLoginWin.Binding <> nil then
      try gLoginWin.Binding.Close; except end;
    if gMainWin.Binding <> nil then
      try gMainWin.Binding.Close; except end;
    if gGuiSchedulerRef <> nil then
      try gGuiScheduler.Shutdown; except end;
    // R-C2/R-C3 teardown: guards stop deciding first (reverse creation
    // order), then the ONE shared handler (POSIX) stops serving - after
    // every guard, before any destroy, the release-host order - then the
    // views are destroyed post-loop, Login first. NO mid-loop destroy.
    GuiDetachWindow(gLoginWin);
    GuiDetachWindow(gMainWin);
    if gSharedHandler <> nil then
    begin
      try
        gSharedHandler.Detach;
      except
        on E: Exception do
          WriteLn(StdErr, LOG_PREFIX, ': shared handler Detach: ', E.Message);
      end;
      try
        FreeAndNil(gSharedHandler);
      except
        on E: Exception do
          WriteLn(StdErr, LOG_PREFIX, ': shared handler Free: ', E.Message);
      end;
    end;
    gSharedStore := nil;
    if safeToDestroy then
    begin
      GuiDestroyWindow(gLoginWin);
      GuiDestroyWindow(gMainWin);
    end
    else
    begin
      // a wedged helper thread means the destroys were SKIPPED: a leaked
      // window/thread must never print MULTIPRINCIPAL PASS
      Fail('GUI: a helper thread did not terminate - window destroys skipped');
      gLoginWin.Binding := nil; gLoginWin.Source := nil; gLoginWin.Store := nil;
      gMainWin.Binding := nil; gMainWin.Source := nil; gMainWin.Store := nil;
    end;
    InterlockedExchange(GuiPhase, 0);
  end;
  Result := GuiRan;
end;

function Dense(const AJson: RawUtf8): RawUtf8;
var
  i: PtrInt;
  inStr, skipNext: Boolean;
  c: AnsiChar;
begin
  // remove whitespace OUTSIDE string literals so the Pos-checks below are
  // tolerant of the SDK's serialization spacing (our values carry no
  // spaces). Backslash escapes are honored: a \" inside a string must not
  // toggle the in-string state, or everything after it densifies wrongly.
  Result := '';
  inStr := False;
  skipNext := False;
  for i := 1 to Length(AJson) do
  begin
    c := AJson[i];
    if skipNext then
    begin
      skipNext := False;
      Result := Result + c;
      continue;
    end;
    if inStr and (c = '\') then
      skipNext := True
    else if c = '"' then
      inStr := not inStr;
    if (not inStr) and ((c = ' ') or (c = #9) or (c = #10) or (c = #13)) then
      continue;
    Result := Result + c;
  end;
end;

{ field extractors over a DENSE json (values in this corpus carry no escaped
  quotes): '' when the field is absent - callers treat that as a failure }
function JsonStrField(const ADense, AName: RawUtf8): RawUtf8;
var
  key: RawUtf8;
  p, q: PtrInt;
begin
  Result := '';
  key := '"' + AName + '":"';
  p := Pos(key, ADense);
  if p = 0 then
    exit;
  p := p + Length(key);
  q := p;
  while (q <= Length(ADense)) and (ADense[q] <> '"') do
    Inc(q);
  Result := copy(ADense, p, q - p);
end;

function JsonRawField(const ADense, AName: RawUtf8): RawUtf8;
var
  key: RawUtf8;
  p, q: PtrInt;
begin
  Result := '';
  key := '"' + AName + '":';
  p := Pos(key, ADense);
  if p = 0 then
    exit;
  p := p + Length(key);
  q := p;
  while (q <= Length(ADense)) and not (ADense[q] in [',', '}']) do
    Inc(q);
  Result := copy(ADense, p, q - p);
end;

procedure EvaluateGuiReports;
var
  mainJson, loginJson: RawUtf8;
  settingsMainDelta, settingsLoginDelta: LongInt;
begin
  // both principals must have reported (aliveness); the content-swap facts
  // are read from each principal's own report. On the POSIX targets these
  // two latches are ALSO the single-arming service proof: each report can
  // only arrive if that window's document actually loaded over pweb://app,
  // so the second window reporting IS the asserted evidence that ONE
  // process-wide asset arming serves BOTH views (never an assumption)
  Expect(InterlockedCompareExchange(ReportMainLatch, 1, 1) = 1,
    'GUI: the Main window never reported');
  Expect(InterlockedCompareExchange(ReportLoginLatch, 1, 1) = 1,
    'GUI: the Login window never reported (on POSIX this is also the ' +
    'single-arming service proof for the second view)');
  mainJson := Dense(ReportMainJson);
  loginJson := Dense(ReportLoginJson);
  // Main (window:main) computed 42 despite loading the LOGIN page bytes
  Expect(Pos('"addValue":42', mainJson) > 0,
    'GUI: Main did not compute 42 (content-swap main-context)');
  // the swap is proven by the page bytes each context loaded
  Expect(Pos('"claim":"login-page"', mainJson) > 0,
    'GUI: Main did not load the login page bytes (swap)');
  Expect(Pos('"claim":"main-page"', loginJson) > 0,
    'GUI: Login did not load the main page bytes (swap)');
  // Login (window:login) was forbidden despite loading the MAIN page bytes
  Expect(Pos('"addCode":"forbidden"', loginJson) > 0,
    'GUI: Login Add was not forbidden (content-swap login-context)');
  // the Login window's ALLOW-side proof: settings.read is held by BOTH
  // window principals, so its denial evidence above is a policy decision on
  // a demonstrably functional window, never a broken binding
  Expect(Pos('"settingsOk":true', mainJson) > 0,
    'GUI: Main SettingsService.GetValue did not succeed');
  Expect(Pos('"settingsOk":true', loginJson) > 0,
    'GUI: Login SettingsService.GetValue did not succeed (allow-side)');
  settingsMainDelta := InterlockedCompareExchange(CountSettings[PRIN_MAIN], 0, 0) -
    GuiBaseSettings[PRIN_MAIN];
  settingsLoginDelta := InterlockedCompareExchange(CountSettings[PRIN_LOGIN], 0, 0) -
    GuiBaseSettings[PRIN_LOGIN];
  Expect(settingsMainDelta = 1, 'GUI: Main settings bridge count delta = ' +
    Utf8String(IntToStr(settingsMainDelta)) + ' expected 1');
  Expect(settingsLoginDelta = 1, 'GUI: Login settings bridge count delta = ' +
    Utf8String(IntToStr(settingsLoginDelta)) + ' expected 1');
  // handshake (aliveness) succeeded for both privileged principals
  Expect(Pos('"handshakeOk":true', mainJson) > 0,
    'GUI: Main handshake did not succeed');
  Expect(Pos('"handshakeOk":true', loginJson) > 0,
    'GUI: Login handshake did not succeed');
  // no driver-level exception leaked into either report
  Expect(Pos('"error":""', mainJson) > 0,
    'GUI: the Main report carries a driver error');
  Expect(Pos('"error":""', loginJson) > 0,
    'GUI: the Login report carries a driver error');
  // Main reached the opener for its authorized opens; Login never did
  Expect(Pos('"openHttpsOk":true', mainJson) > 0,
    'GUI: Main https open did not succeed');
  Expect(Pos('"openMailtoOk":true', mainJson) > 0,
    'GUI: Main mailto open did not succeed');
  Expect(Pos('"openHttpsCode":"forbidden"', loginJson) > 0,
    'GUI: Login https open was not forbidden');
  Expect(Pos('"openMailtoCode":"forbidden"', loginJson) > 0,
    'GUI: Login mailto open was not forbidden');
  // the invalid-scheme row, both principals: Main reached the validator and
  // was refused invalid_request; Login never got past the policy
  Expect(Pos('"openHttpCode":"invalid_request"', mainJson) > 0,
    'GUI: Main http open was not refused invalid_request');
  Expect(Pos('"openHttpCode":"forbidden"', loginJson) > 0,
    'GUI: Login http open was not forbidden');
  // the raw external navigation was cancelled IN PLACE in both windows
  // (CAP-8B classifier unchanged, guard installed on BOTH views) - proven
  // page-side AND guard-side: each window's OWN guard must have cancelled
  // at least one navigation, so a deferred-but-later-honoured navigation
  // cannot hide behind a still-trusted address at report time
  Expect(Pos('"navBlocked":true', mainJson) > 0,
    'GUI: the raw external navigation was not blocked in the Main window');
  Expect(Pos('"navBlocked":true', loginJson) > 0,
    'GUI: the raw external navigation was not blocked in the Login window');
  Expect(gMainWin.GuardCancelled >= 1,
    'GUI: the Main window guard cancelled nothing');
  Expect(gLoginWin.GuardCancelled >= 1,
    'GUI: the Login window guard cancelled nothing');
  Expect(gMainWin.GuardAllowed >= 1,
    'GUI: the Main window guard allowed no trusted navigation');
  Expect(gLoginWin.GuardAllowed >= 1,
    'GUI: the Login window guard allowed no trusted navigation');
  {$ifndef DARWIN}
  {$ifndef LINUX}
  // Windows only: a deny whose put_Cancel/put_Handled failed to apply is a
  // refusal the engine may not have honored - required zero, per window
  Expect(gMainWin.GuardApplyFailures = 0,
    'GUI: Main guard deny-apply failures <> 0');
  Expect(gLoginWin.GuardApplyFailures = 0,
    'GUI: Login guard deny-apply failures <> 0');
  {$endif LINUX}
  {$endif DARWIN}
  // both privileged documents ran in the secure pweb:// origin
  Expect(Pos('"secure":true', mainJson) > 0,
    'GUI: Main did not run in the secure pweb:// origin');
  Expect(Pos('"secure":true', loginJson) > 0,
    'GUI: Login did not run in the secure pweb:// origin');
  // the whole opener ledger, exact - never a pair of unread zeroes:
  //   3 = the native-leg Main open + the GUI https + the GUI mailto;
  //   the GUI http vector was refused invalid_request BEFORE any opener
  //   (Main refused count exactly 1); Login/Plugin never reached either arm
  Expect(OpenerCalls = 3, 'GUI: opener calls = ' +
    Utf8String(IntToStr(OpenerCalls)) + ' expected exactly 3');
  Expect(CountOpenOk[PRIN_MAIN] = 3, 'GUI: Main open_ok = ' +
    Utf8String(IntToStr(CountOpenOk[PRIN_MAIN])) + ' expected 3');
  Expect(CountOpenRefused[PRIN_MAIN] = 1, 'GUI: Main open_refused = ' +
    Utf8String(IntToStr(CountOpenRefused[PRIN_MAIN])) + ' expected 1');
  Expect(CountOpenOk[PRIN_LOGIN] = 0, 'GUI: the Login principal reached the opener');
  Expect(CountOpenOk[PRIN_PLUGIN] = 0, 'GUI: the Plugin principal reached the opener');
  Expect(CountOpenRefused[PRIN_LOGIN] = 0,
    'GUI: a Login open reached the validator (forbidden must be pre-bridge)');
  Expect(CountOpenRefused[PRIN_PLUGIN] = 0,
    'GUI: a Plugin open reached the validator (forbidden must be pre-bridge)');
  Expect(OpenerUnexpectedUri = 0, 'GUI: the opener saw an unexpected URI');
  // exactly the Main window's single Add reached the real service
  Expect(GuiServiceAdd = 1, 'GUI: service add count <> 1 (got ' +
    Utf8String(IntToStr(GuiServiceAdd)) + ')');
end;

// =============================== main =====================================

var
  root, fixtureDir, outFile, corpusFile: TFileName;
  timeoutMs: Integer;
  json: RawUtf8;
  overall: RawUtf8;
  stream: TFileStream;
  guiVerdict: RawUtf8;
  guiOut: RawUtf8;
  canSkip: Boolean;
  mainDense, loginDense: RawUtf8;

procedure WriteCorpusFile;
var
  s: TFileStream;
begin
  if root = '' then
    exit;
  corpusFile := root + TFileName(StringReplace(CORPUS_FILE, '/', PathDelim,
    [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(corpusFile)) then
    exit;
  s := TFileStream.Create(corpusFile, fmCreate);
  try
    if CorpusLines <> '' then
      s.WriteBuffer(CorpusLines[1], Length(CorpusLines));
  finally
    s.Free;
  end;
end;

begin
  ExitCode := 0;
  CorpusLines := '';
  FailReasons := '';
  overall := 'FAIL';
  guiVerdict := 'PENDING';
  ReleaseGate := RTLEventCreate;
  ArrivalEvent := RTLEventCreate;
  HeldReturned := RTLEventCreate;
  InstallOpenerSpy;
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock) not found from ' +
          string(Executable.ProgramFilePath));
      fixtureDir := root + 'test' + PathDelim + 'cap8c' + PathDelim + 'fixture';
      if not FileExists(fixtureDir + PathDelim + 'main.html') then
        raise Exception.Create('fixture corpus missing: ' + string(fixtureDir));
      outFile := root + 'build' + PathDelim + 'cap8c' + PathDelim +
        'multiprincipal-' + TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));
      timeoutMs := StrToIntDef(
        GetEnvironmentVariable('PWEB_MULTIPRINCIPAL_TIMEOUT_MS'),
        DEFAULT_TIMEOUT_MS);
      if (timeoutMs <= 0) or (timeoutMs > MAX_TIMEOUT_MS) then
        timeoutMs := DEFAULT_TIMEOUT_MS;

      // ---- NATIVE leg first: the deterministic digest source ----
      RunNativeLeg;
      // shut the native scheduler down before the GUI leg builds its own
      gSchedulerRef.Shutdown;

      // ---- GUI leg: two real WebViews ----
      {$ifdef DARWIN}
      CheckCocoaRuntimeUsable;
      {$endif DARWIN}
      {$ifdef LINUX}
      CheckGtkDisplayUsable;
      {$endif LINUX}
      try
        RunGuiLeg(fixtureDir, timeoutMs);
        EvaluateGuiReports;
        guiVerdict := 'RAN';
      except
        on E: Exception do
        begin
          guiOut := RawUtf8(E.Message);
          // SKIP is legitimate ONLY when the FIRST create came back nil (no
          // WebView2 runtime / desktop session at all): a nil SECOND create
          // after a successful first is a dual-window regression on a
          // machine that demonstrably CAN open a WebView - a FAILURE, never
          // a SKIP. The flag is read on EVERY platform (so the classification
          // is one shared expression); POSIX then forces the answer to
          // no-SKIP, because its runners always supply a real display.
          canSkip := (not GuiFirstCreateOk) and
            ((Pos('returned nil', guiOut) > 0) or
             (Pos('WEBVIEW2 RUNTIME UNUSABLE', guiOut) > 0));
          {$ifdef DARWIN}
          canSkip := False;
          {$endif DARWIN}
          {$ifdef LINUX}
          canSkip := False;
          {$endif LINUX}
          if canSkip then
          begin
            GuiSkipped := True;
            guiVerdict := 'SKIP';
            WriteLn(StdErr, LOG_PREFIX, ': GUI leg SKIP (', guiOut, ')');
          end
          else
          begin
            Fail('GUI leg: ' + guiOut);
            guiVerdict := 'FAIL';
          end;
        end;
      end;

      // ---- corpus: the GUI-derived facts, MEASURED from the reports and
      // the native ledgers (never constants), so the cross-target digest can
      // actually catch a GUI divergence. The values are deterministic on a
      // correct run, which is what makes the digest byte-identical across
      // targets - and any deviation diverges the digest AND fails the
      // assertions above.
      if guiVerdict = 'RAN' then
      begin
        mainDense := Dense(ReportMainJson);
        loginDense := Dense(ReportLoginJson);
        Emit('gui main_add_result=' + JsonRawField(mainDense, 'addValue') +
          ' login_add_code=' + JsonStrField(loginDense, 'addCode'));
        Emit('gui settings main=' + JsonRawField(mainDense, 'settingsOk') +
          ' login=' + JsonRawField(loginDense, 'settingsOk') +
          ' main_count=' + Utf8String(IntToStr(
            InterlockedCompareExchange(CountSettings[PRIN_MAIN], 0, 0) -
            GuiBaseSettings[PRIN_MAIN])) +
          ' login_count=' + Utf8String(IntToStr(
            InterlockedCompareExchange(CountSettings[PRIN_LOGIN], 0, 0) -
            GuiBaseSettings[PRIN_LOGIN])));
        Emit('gui opener calls=' + Utf8String(IntToStr(OpenerCalls)) +
          ' main_ok=' + Utf8String(IntToStr(CountOpenOk[PRIN_MAIN])) +
          ' main_refused=' + Utf8String(IntToStr(CountOpenRefused[PRIN_MAIN])) +
          ' login_ok=' + Utf8String(IntToStr(CountOpenOk[PRIN_LOGIN])) +
          ' plugin_ok=' + Utf8String(IntToStr(CountOpenOk[PRIN_PLUGIN])) +
          ' unexpected=' + Utf8String(IntToStr(OpenerUnexpectedUri)));
        Emit('gui open_http main=' + JsonStrField(mainDense, 'openHttpCode') +
          ' login=' + JsonStrField(loginDense, 'openHttpCode'));
        Emit('gui raw_external_nav main=' +
          JsonRawField(mainDense, 'navBlocked') + ' login=' +
          JsonRawField(loginDense, 'navBlocked') +
          ' guard_cancelled_main=' + YesNo(gMainWin.GuardCancelled >= 1) +
          ' guard_cancelled_login=' + YesNo(gLoginWin.GuardCancelled >= 1));
        Emit('gui secure_origin main=' + JsonRawField(mainDense, 'secure') +
          ' login=' + JsonRawField(loginDense, 'secure'));
        Emit('gui service_add_count=' + Utf8String(IntToStr(GuiServiceAdd)));
        Emit('gui content_swap main_loaded=' +
          JsonStrField(mainDense, 'claim') + ' login_loaded=' +
          JsonStrField(loginDense, 'claim'));
      end;

      if FailReasons = '' then
      begin
        if GuiSkipped then
        begin
          // an honest SKIP corpus: the digest may diverge from the real
          // targets' - the aggregator's mustPass refusal of the SKIP verdict
          // is the one clean signal, never a digest-divergence side effect
          // dressed as a decision disagreement
          Emit('verdict=SKIP');
          overall := 'SKIP';
        end
        else
        begin
          Emit('verdict=PASS');
          overall := 'PASS';
        end;
      end
      else
      begin
        Emit('verdict=FAIL');
        overall := 'FAIL';
      end;
      WriteCorpusFile;
    except
      on E: Exception do
      begin
        Fail(RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message));
        overall := 'FAIL';
        WriteLn(StdErr, LOG_PREFIX, ': FATAL ', E.ClassName, ': ', E.Message);
        // still write whatever corpus was accumulated, so a partial digest
        // and the failure are both on disk
        if Pos('verdict=', CorpusLines) = 0 then
          Emit('verdict=FAIL');
        WriteCorpusFile;
      end;
    end;
  finally
    // release the native + gui runtimes
    try
      gSrcMain := nil; gSrcLogin := nil; gSrcPlugin := nil;
      gSchedulerRef := nil; gScheduler := nil;
      gPolicyRef := nil; gPolicy := nil;
      gBridge := nil; gRealBridge := nil;
      gGuiSchedulerRef := nil; gGuiScheduler := nil;
      gGuiPolicyRef := nil; gGuiPolicy := nil;
      gGuiBridge := nil; gGuiRealBridge := nil;
    except
    end;
    RemoveOpenerSpy;
    if ReleaseGate <> nil then RTLEventDestroy(ReleaseGate);
    if ArrivalEvent <> nil then RTLEventDestroy(ArrivalEvent);
    if HeldReturned <> nil then RTLEventDestroy(HeldReturned);
  end;

  // ---- write the per-target corpus JSON ----
  json := '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "target": "' + TARGET_ID + '",' + #10 +
    '  "overall": "' + overall + '",' + #10 +
    '  "gui": "' + guiVerdict + '",' + #10 +
    '  "main_add_result": ' +
      Utf8String(IntToStr(42 * Ord(Pos('"addValue":42',
        Dense(ReportMainJson)) > 0))) +
      ',' + #10 +
    '  "login_add_forbidden": ' +
      Utf8String(BoolToStr(
        Pos('"addCode":"forbidden"', Dense(ReportLoginJson)) > 0,
        'true', 'false')) +
      ',' + #10 +
    '  "gui_service_add_count": ' + Utf8String(IntToStr(GuiServiceAdd)) + ',' + #10 +
    '  "native_service_add_count": ' + Utf8String(IntToStr(NativeServiceAdd)) + ',' + #10 +
    '  "opener_calls": ' + Utf8String(IntToStr(OpenerCalls)) + ',' + #10 +
    '  "opener_unexpected": ' + Utf8String(IntToStr(OpenerUnexpectedUri)) + ',' + #10 +
    '  "opener_main": ' + Utf8String(IntToStr(CountOpenOk[PRIN_MAIN])) + ',' + #10 +
    '  "opener_login": ' + Utf8String(IntToStr(CountOpenOk[PRIN_LOGIN])) + ',' + #10 +
    '  "opener_plugin": ' + Utf8String(IntToStr(CountOpenOk[PRIN_PLUGIN])) + ',' + #10 +
    '  "denied_bridge_login_add": ' + Utf8String(IntToStr(CountAdd[PRIN_LOGIN])) + ',' + #10 +
    '  "denied_bridge_plugin_add": ' + Utf8String(IntToStr(CountAdd[PRIN_PLUGIN])) + ',' + #10 +
    '  "secure_origin": ' +
      Utf8String(BoolToStr((Pos('"secure":true', Dense(ReportMainJson)) > 0) and
        (Pos('"secure":true', Dense(ReportLoginJson)) > 0), 'true', 'false')) +
      ',' + #10;
  if FailReasons <> '' then
    json := json + '  "failures": "' + JsonSafeText(FailReasons) + '"' + #10
  else
    json := json + '  "failures": null' + #10;
  json := json + '}' + #10;
  try
    stream := TFileStream.Create(outFile, fmCreate);
    try
      if json <> '' then
        stream.WriteBuffer(json[1], Length(json));
    finally
      stream.Free;
    end;
  except
    on E: Exception do
      WriteLn(StdErr, LOG_PREFIX, ': could not write ', string(outFile),
        ': ', E.Message);
  end;

  if (FailReasons = '') and (not GuiSkipped) then
    WriteLn(MARKER_PASS)
  else if GuiSkipped and (FailReasons = '') then
  begin
    WriteLn(StdErr, LOG_PREFIX, ': GUI SKIP (native leg PASS)');
    ExitCode := 2; // distinct from a hard failure; the runner records SKIP
  end
  else
  begin
    WriteLn(StdErr, MARKER_FAIL, ' (', FailReasons, ')');
    ExitCode := 1;
  end;
end.
