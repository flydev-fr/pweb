program cap7m_runtime;

{ CAP-7M1 PRODUCTION runtime harness for macOS.

  NOTHING HERE IS A PROBE. Every component on the path is the shipped one:

    real NSApplication + WKWebView   (webview_create, upstream, unpatched)
      -> the pre-create seam          (src/platform/macos/pweb_cocoa_bridge.mm)
      -> TCocoaAssetHandler           (src/platform/macos/pweb.platform.cocoa.pas)
      -> PWebParseAppUri              (src/assets/pweb.assets.support.pas)
      -> IAssetStore                  TFolderAssetStore *and* TZipAssetStore
      -> the page, over pweb://app
      -> __pweb_invoke                (TWebViewBinding + TPWebEnvelopeHandler)
      -> TInvocationScheduler worker  (the frozen threading model)
      -> TMormotInvocationBridge      -> CalculatorService.Add(20, 22) = 42

  test/cap7m/cap7m_probe.mm is KEPT and kept running as the platform-fact
  regression (poststop_throws, abort_delivered, handoff, seam_a_effective).
  This program deliberately does not depend on those answers - production is
  correct whether WebKit copies the body at handoff or retains the pointer -
  but a silent change to them must still fail a gate, which is why both run.

  ONE CORPUS, TWO STORES. test/cap7m/fixture/ is served by the folder store as
  it sits on disk, and by the ZIP store from an archive this program builds
  out of the same files, so folder/ZIP parity is a property the gate
  EXERCISES rather than one it restates.

  TWO SHUTDOWN SHAPES, alternating by cycle: odd cycles call
  webview_terminate, even cycles close the NSWindow - the path a user clicking
  the red button takes, which reaches upstream's windowWillClose: delegate and
  is the commoner of the two in a real application.

  Markers on stdout, one fact per line, read by test/cap7m/run_cap7m_runtime.sh:

    CAP7M1_ENV        store, cycles, gui thread
    CAP7M1_SEAM       the pre-create seam ran for this cycle
    CAP7M1_URI        every URI the PRODUCTION handler observed, verbatim
    CAP7M1_REPORT     the page's own verdict object
    CAP7M1_THREADS    GUI-affine callback, distinct worker, direct return
    CAP7M1_INVOKE     8 concurrent + 1 forced error + 1 outstanding
    CAP7M1_STATS      every bridge counter after teardown
    CAP7M1_REGISTRY   handler registry empty, handle unresolvable
    CAP7M1_SHUTDOWN   which shape, and whether the loop stopped
    CAP7M1_RSS        resident size after the cycle
    CAP7M1_CYCLE_PASS / CAP7M1_PASS / CAP7M1_FAIL

  Usage: cap7m_runtime <folder|zip> <fixture-dir> <work-dir> [cycles 1..20] }

{$I mormot.defines.inc}

{$ifndef DARWIN}
  {$fatal cap7m_runtime is the macOS production runtime harness}
{$endif DARWIN}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.zip,
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
  pweb.capabilities,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.folder,
  pweb.assets.zip,
  pweb.platform.cocoa;

const
  RUNTIME_TIMEOUT_MS = 90000;
  SHUTDOWN_TIMEOUT_MS = 20000;
  WATCHDOG_TICK_MS = 50;
  SLOW_INVOCATION_MS = 400;
  /// the CAP-7M0 per-cycle resident-size budget, reused unchanged. It is a
  // coarse RUNAWAY detector and is described as one: it catches a per-cycle
  // leak of a whole WKWebView and its web content process, not a handful of
  // stray Objective-C objects, and it does not claim otherwise.
  RSS_GROWTH_KB_PER_CYCLE_MAX = 65536;
  MIN_CYCLES_FOR_LEAK_CHECK = 3;
  /// the fixture corpus, in canonical logical-path form. Identical for both
  // stores by construction: the ZIP is built from exactly these files.
  FIXTURE_CORPUS: array[0..4] of string = (
    'index.html',
    'probe.css',
    'probe.js',
    'assets/empty.bin',
    'assets/allbytes.bin');
  /// fixed DOS timestamp (1980-01-01 00:00) so identical input bytes yield
  // identical archive bytes; TZipWrite's default FileAge of 0 would embed
  // the current time on every build
  FIXED_FILE_AGE = $00210000;

type
  ICalculatorService = interface(IInvokable)
    ['{5B2A1E44-9C77-4A2E-9F1D-3E6B84C0A712}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { The harness decorator. Application methods still reach the real mORMot
    bridge on workers; three harness-only methods are answered here so the
    page can drive the forced error and the deliberately outstanding
    invocation through the SAME production envelope as everything else. }
  THarnessBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { Records the CALLBACK thread and delegates. The frozen model says the bind
    callback runs on the GUI thread; the only way to state that as a fact is
    to observe it where the callback actually is. }
  TRecordingHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FInner: IWebViewInvocationHandler;
  public
    constructor Create(const AInner: IWebViewInvocationHandler);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

{ ---- the Objective-C runtime, for the window-close shutdown shape only ----

  Two entry points, both public and both documented, declared here in the TEST
  harness rather than added to the production bridge: closing a window is
  something this gate does to exercise upstream's windowWillClose: delegate,
  not something the adapter offers. objc_msgSend is declared with the exact
  prototype of the call being made, which is the documented requirement on
  arm64 - a variadic declaration would put the arguments in the wrong
  places. }

function sel_registerName(const AName: PAnsiChar): Pointer; cdecl;
  external name 'sel_registerName';
procedure PWebObjcSendVoid(AObject: Pointer; ASelector: Pointer); cdecl;
  external name 'objc_msgSend';

var
  GuiThreadId: TThreadID;
  CallbackThreadId: LongInt;
  ServiceThreadId: LongInt;
  AddCalls: LongInt;
  ErrorCalls: LongInt;
  SlowCalls: LongInt;
  ReportSeen: LongInt;
  ReportJson: RawUtf8;
  CycleFinished: LongInt;
  RunReturned: LongInt;
  CycleFailed: LongInt;
  FailureReason: string;
  CloseByWindow: LongInt;
  CurrentWebView: webview_t;
  WatchdogDone: LongInt;

procedure FailCycle(const AReason: string);
begin
  if InterlockedCompareExchange(CycleFailed, 1, 0) = 0 then
    FailureReason := AReason;
end;

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedExchange(ServiceThreadId, LongInt(GetCurrentThreadId));
  InterlockedIncrement(AddCalls);
  Result := a + b;
end;

constructor THarnessBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function THarnessBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = 'example.report' then
  begin
    // FIRST report wins: a late duplicate can never overwrite the verdict
    if InterlockedCompareExchange(ReportSeen, 1, 0) = 0 then
      ReportJson := RawUtf8(Args);
    // The shutdown is NOT performed here. This runs on a scheduler worker,
    // and every Cocoa call is GUI-affine; the watchdog owns the shutdown and
    // reaches the GUI thread through webview_dispatch, which is the only
    // ratified cross-thread route.
    InterlockedExchange(CycleFinished, 1);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else if Method = 'ErrorService.Fail' then
  begin
    InterlockedIncrement(ErrorCalls);
    // rejects with a payload the page can check byte-for-byte, so "the error
    // arm carries its data intact" is proven rather than assumed
    Result := PWebErrorResult(pecServiceError, 'forced harness failure',
      '{"detail":"payload-intact-42"}');
  end
  else if Method = 'SlowService.Wait' then
  begin
    // the page never awaits this one, so it is still in flight when the
    // shutdown begins and teardown has to drain it
    Sleep(SLOW_INVOCATION_MS);
    InterlockedIncrement(SlowCalls);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

constructor TRecordingHandler.Create(const AInner: IWebViewInvocationHandler);
begin
  inherited Create;
  FInner := AInner;
end;

procedure TRecordingHandler.HandleInvocation(const Context: TInvocationContext;
  const Request: TPWebJson; const Completion: IInvocationCompletion);
begin
  InterlockedExchange(CallbackThreadId, LongInt(GetCurrentThreadId));
  FInner.HandleInvocation(Context, Request, Completion);
end;

{ ---- GUI-thread callbacks (no Pascal exception may leave them) ---- }

{ webview_dispatch is fire-and-forget: a block queued microseconds before
  webview_run returned can still be sitting on the main queue when the NEXT
  cycle starts servicing it, by which time this cycle's webview is destroyed.
  Every dispatched callback therefore compares the webview it was handed
  against the one that is currently live and does nothing at all otherwise -
  a stale block is inert rather than a use-after-free. }
function IsLiveWebView(w: webview_t): Boolean;
begin
  Result := (w <> nil) and (w = CurrentWebView);
end;

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    if not IsLiveWebView(w) then
      exit;
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

procedure ShutdownOnGuiThread(w: webview_t; arg: Pointer); cdecl;
var
  window: Pointer;
begin
  try
    if not IsLiveWebView(w) then
      exit;
    if PWebAtomicRead(CloseByWindow) <> 0 then
    begin
      window := webview_get_window(w);
      if window <> nil then
      begin
        // -close reaches upstream's windowWillClose: delegate, which is the
        // path a user clicking the red button takes and a DIFFERENT route to
        // the run loop than webview_terminate
        PWebObjcSendVoid(window, sel_registerName('close'));
        exit;
      end;
      FailCycle('webview_get_window returned nil for the close cycle');
    end;
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

function WatchdogThread(Param: Pointer): PtrInt;
var
  waited: Integer;
begin
  Result := 0;
  try
  // Phase 1: the page reports, something fails, or the deadline expires.
  waited := 0;
  while (PWebAtomicRead(CycleFinished) = 0) and
        (PWebAtomicRead(CycleFailed) = 0) and
        (PWebAtomicRead(RunReturned) = 0) do
  begin
    Sleep(WATCHDOG_TICK_MS);
    Inc(waited, WATCHDOG_TICK_MS);
    if waited >= RUNTIME_TIMEOUT_MS then
    begin
      FailCycle('runtime timeout: the page never reported');
      break;
    end;
  end;

  if PWebAtomicRead(RunReturned) <> 0 then
    exit; // the loop already stopped; nothing to ask for (see the finally)

  // A FAILURE IS ALSO A REASON TO SHUT DOWN. Returning quietly here would
  // leave webview_run spinning forever, so a detected defect would report as
  // a CI step timeout instead of as the defect it is.
  webview_dispatch(CurrentWebView, @ShutdownOnGuiThread, nil);

  // Phase 2: the SHUTDOWN ITSELF is on a deadline of its own. CycleFinished
  // is set BEFORE the shutdown is even attempted, so phase 1 returning says
  // nothing about whether the run loop actually stopped - and "the NSWindow
  // close did not end the loop" is precisely one of the two shapes this
  // harness exists to exercise.
  waited := 0;
  while PWebAtomicRead(RunReturned) = 0 do
  begin
    Sleep(WATCHDOG_TICK_MS);
    Inc(waited, WATCHDOG_TICK_MS);
    if waited >= SHUTDOWN_TIMEOUT_MS then
    begin
      FailCycle('the run loop did not stop after the shutdown request');
      break;
    end;
  end;
  if PWebAtomicRead(RunReturned) <> 0 then
    exit;

  // Last resort, so the job fails as the defect it is rather than as a hang.
  webview_dispatch(CurrentWebView, @TerminateOnGuiThread, nil);
  waited := 0;
  while (PWebAtomicRead(RunReturned) = 0) and
        (waited < SHUTDOWN_TIMEOUT_MS) do
  begin
    Sleep(WATCHDOG_TICK_MS);
    Inc(waited, WATCHDOG_TICK_MS);
  end;
  finally
    // The flag the main thread polls. It is set on EVERY exit path, including
    // the early ones, because the main thread refuses to join a thread that
    // has not said it is finished - see the WaitForThreadTerminate note in
    // RunCycle.
    InterlockedExchange(WatchdogDone, 1);
  end;
end;

{ ---- the fixture archive, built from the SAME corpus ---- }

procedure BuildFixtureZip(const AFixture, AOut: TFileName);
var
  zw: TZipWrite;
  i, j: PtrInt;
  native: TFileName;
  name: string;
  content: RawByteString;
  empty: Byte;
begin
  empty := 0;
  DeleteFile(AOut);
  zw := TZipWrite.Create(AOut);
  try
    for i := 0 to High(FIXTURE_CORPUS) do
    begin
      name := FIXTURE_CORPUS[i];
      native := name;
      for j := 1 to Length(native) do
        if native[j] = '/' then
          native[j] := PathDelim;
      native := AFixture + PathDelim + native;
      if not FileExists(native) then
        raise Exception.CreateFmt('missing fixture file: %s', [native]);
      content := StringFromFile(native);
      // an unreadable (locked/denied) file also yields '': verify against the
      // real size so it fails the build instead of silently packaging an
      // empty asset in place of a real one
      if Int64(Length(content)) <> FileSize(native) then
        raise Exception.CreateFmt('unreadable fixture file: %s', [native]);
      if content = '' then
        // a zero-byte asset is still an asset; never hand a nil pointer over
        zw.AddDeflated(name, @empty, 0, 6, FIXED_FILE_AGE)
      else
        zw.AddDeflated(name, pointer(content), Length(content), 6,
          FIXED_FILE_AGE);
    end;
  finally
    zw.Free;
  end;
end;

{ ---- one cycle ---- }

procedure EmitObservedUris(ACycle: Integer);
var
  i, n: Integer;
begin
  n := PWebCocoaObservedCount;
  for i := 0 to n - 1 do
    // ANCHORED on a fixed prefix with the URL running to end of line: these
    // strings are hostile by construction, and a URL containing ' verdict='
    // must never be able to overwrite the verdict column of its own row
    WriteLn('CAP7M1_URI cycle=', ACycle,
      ' verdict=', PWebCocoaObservedVerdict(i),
      ' url=', PWebCocoaObservedUri(i));
end;

function RunCycle(ACycle: Integer; const AMode: string;
  const AFixture, AZipPath: TFileName): Boolean;
var
  store: IAssetStore;
  handler: TCocoaAssetHandler;
  handle: TPWebCocoaHandle;
  seamBefore: QWord;
  w: webview_t;
  server: TRestServerFullMemory;
  factory: TServiceFactoryServerAbstract;
  realBridge, bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  dogId: TThreadID;
  dogHandle: TThreadID;
  dogStarted: Boolean;
  statsBefore, statsAfter: TPWebCocoaStats;
  shape: string;
  waited: Integer;
  observed: Integer;
  ok: Boolean;
begin
  Result := False;
  handler := nil;
  scheduler := nil;
  server := nil;
  w := nil;
  handle := 0;
  seamBefore := 0;
  dogHandle := TThreadID(0);
  dogStarted := False;
  InterlockedExchange(CallbackThreadId, 0);
  InterlockedExchange(ServiceThreadId, 0);
  InterlockedExchange(AddCalls, 0);
  InterlockedExchange(ErrorCalls, 0);
  InterlockedExchange(SlowCalls, 0);
  InterlockedExchange(ReportSeen, 0);
  InterlockedExchange(CycleFinished, 0);
  InterlockedExchange(RunReturned, 0);
  InterlockedExchange(CycleFailed, 0);
  InterlockedExchange(WatchdogDone, 0);
  // odd cycles terminate programmatically, even cycles close the window
  InterlockedExchange(CloseByWindow, Ord((ACycle mod 2) = 0));
  ReportJson := '';
  FailureReason := '';
  PWebCocoaResetObserved;
  // The bridge's counters are process CUMULATIVE by design, so a per-cycle
  // number is a DELTA. Summing them across cycles - or comparing an absolute
  // to a per-cycle expectation - would report cycle 3 as having started three
  // times as many tasks as it did.
  statsBefore := PWebCocoaStats;

  try
    try
      if AMode = 'folder' then
        store := TFolderAssetStore.Create(AFixture)
      else
        store := TZipAssetStore.Create(AZipPath);

      // THE SEAM IS ARMED BEFORE THE WEBVIEW EXISTS. Upstream builds the
      // configuration and the view both inside webview_create, so this is
      // the only order in which a handler can be installed at all.
      handler := TCocoaAssetHandler.Create(store);
      handle := handler.Handle;
      seamBefore := PWebCocoaSeamInvocations;

      w := WebViewCheckCreated(webview_create(0, nil));
      CurrentWebView := w;

      // raises unless the seam RAN: a seam that silently stopped running can
      // never again present as success
      handler.Attach(w);
      // readback is RECORDED, never asserted here: 'absent' cannot tell a
      // configuration copy that drops the scheme-handler map from a view with
      // no handler, and that distinction has never been measured on this
      // platform. 'foreign' would already have raised inside Attach. What
      // actually proves this view is served is the served main document and
      // the page's own verdict, both asserted below.
      WriteLn('CAP7M1_SEAM cycle=', ACycle, ' seam_ran=1 seam_delta=',
        PWebCocoaSeamInvocations - seamBefore,
        ' readback=', PWebCocoaReadbackName(handler.Readback));

      server := TRestServerFullMemory.CreateWithOwnModel([]);
      factory := server.ServiceRegister(TCalculatorService,
        [TypeInfo(ICalculatorService)], sicShared);
      if factory = nil then
        raise Exception.Create('unable to register CalculatorService');
      realBridge := TMormotInvocationBridge.Create(server, True);
      server := nil; // owned by the bridge from here
      bridge := THarnessBridge.Create(realBridge);
      scheduler := TInvocationScheduler.Create(
        TAllowAllCapabilityPolicy.Create, bridge, 4);
      schedulerRef := scheduler;
      limits.MaxConcurrent := 4;
      limits.MaxQueueSize := 32;
      source := scheduler.RegisterSource(limits);

      context := Default(TInvocationContext);
      context.WindowId := 'main';
      context.PrincipalId := 'window:main';
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, source, opts);
      binding.Bind('__pweb_invoke',
        TRecordingHandler.Create(TPWebEnvelopeHandler.Create(source)));

      WebViewCheck(webview_set_title(w,
        PAnsiChar(AnsiString('PWeb CAP-7M1 (' + AMode + ')'))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

      dogHandle := BeginThread(@WatchdogThread, nil, dogId);
      dogStarted := dogHandle <> TThreadID(0);
      if not dogStarted then
        raise Exception.Create('unable to start the watchdog thread');

      WebViewCheck(webview_run(w), 'webview_run');
    finally
      InterlockedExchange(RunReturned, 1);
      if dogStarted then
      begin
        // WaitForThreadTerminate's TIMEOUT IS IGNORED ON UNIX: FPC implements
        // it as pthread_join, which has no timed form. Joining a wedged
        // watchdog would therefore block forever and report as a CI step
        // timeout - exactly the outcome the two watchdog deadlines exist to
        // avoid. So the completion FLAG is polled with a real bound, and the
        // join happens only once the thread has said it is finished. If it
        // never does, the handle is deliberately leaked (bounded by the cycle
        // count) rather than traded for a hang.
        waited := 0;
        while (PWebAtomicRead(WatchdogDone) = 0) and
              (waited < SHUTDOWN_TIMEOUT_MS * 3) do
        begin
          Sleep(WATCHDOG_TICK_MS);
          Inc(waited, WATCHDOG_TICK_MS);
        end;
        if PWebAtomicRead(WatchdogDone) = 0 then
          FailCycle('the watchdog thread did not finish within its own bounds')
        else
        begin
          WaitForThreadTerminate(dogHandle, 0); // returns at once: it is done
          CloseThread(dogHandle);
        end;
      end;
      // THE RATIFIED TEARDOWN ORDER: binding Close -> scheduler Shutdown ->
      // handler Detach -> webview_destroy. Detach itself disowns, then fails
      // every live task, then makes the handle unresolvable.
      if binding <> nil then
        try
          binding.Close;
        except
          on E: Exception do
            FailCycle('binding Close: ' + E.Message);
        end;
      if schedulerRef <> nil then
        try
          schedulerRef.Shutdown; // drains the outstanding invocation
        except
          on E: Exception do
            FailCycle('scheduler Shutdown: ' + E.Message);
        end;
      if handler <> nil then
        try
          handler.Detach;
        except
          on E: Exception do
            FailCycle('handler Detach: ' + E.Message);
        end;
      if w <> nil then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
        except
          on E: Exception do
            FailCycle('webview_destroy: ' + E.Message);
        end;
      CurrentWebView := nil;
      FreeAndNil(handler);
      binding := nil;
      source := nil;
      schedulerRef := nil;
      scheduler := nil;
      bridge := nil;
      realBridge := nil; // frees the owned server after worker drain
      store := nil;
      server.Free;
    end;
  except
    on E: Exception do
      FailCycle(E.ClassName + ': ' + E.Message);
  end;

  observed := PWebCocoaObservedCount;
  EmitObservedUris(ACycle);
  if ReportJson <> '' then
    WriteLn('CAP7M1_REPORT cycle=', ACycle, ' ', ReportJson);

  statsAfter := PWebCocoaStats;
  // DELTAS, except live_tasks, which is instantaneous and must read 0 after
  // teardown whatever the history.
  WriteLn('CAP7M1_STATS cycle=', ACycle,
    ' started=', statsAfter.TasksStarted - statsBefore.TasksStarted,
    ' served=', statsAfter.TasksServed - statsBefore.TasksServed,
    ' refused=', statsAfter.TasksRefused - statsBefore.TasksRefused,
    ' stopped=', statsAfter.TasksStopped - statsBefore.TasksStopped,
    ' stops_serving=',
      statsAfter.StopsWhileServing - statsBefore.StopsWhileServing,
    ' stops_ignored=', statsAfter.StopsIgnored - statsBefore.StopsIgnored,
    ' suppressed=',
      statsAfter.SuppressedTerminals - statsBefore.SuppressedTerminals,
    ' caught=', statsAfter.CaughtExceptions - statsBefore.CaughtExceptions,
    ' unresolved=',
      statsAfter.UnresolvedHandles - statsBefore.UnresolvedHandles,
    ' live=', statsAfter.LiveTasks);
  // The URI ring's own integrity. A ring that silently overwrote its oldest
  // entries would make the leak check quietly stop covering the requests it
  // can no longer see, and a request whose URL could not be read at all is
  // counted rather than recorded so that a blank row can never enter the
  // oracle's positional join. observed + nonconforming must account for every
  // task the bridge started this cycle.
  WriteLn('CAP7M1_URI_RING cycle=', ACycle,
    ' observed=', observed,
    ' dropped=', PWebCocoaObservedDropped,
    ' nonconforming=', PWebCocoaObservedNonconforming,
    ' started=', statsAfter.TasksStarted - statsBefore.TasksStarted);
  WriteLn('CAP7M1_REGISTRY cycle=', ACycle,
    ' handlers=', PWebCocoaRegistryCount,
    ' handle_resolves=', Ord(PWebCocoaHandleResolves(handle)));
  WriteLn('CAP7M1_THREADS cycle=', ACycle,
    ' gui_affine=', Ord(PWebAtomicRead(CallbackThreadId) = LongInt(GuiThreadId)),
    ' worker_distinct=', Ord((PWebAtomicRead(ServiceThreadId) <> 0) and
      (PWebAtomicRead(ServiceThreadId) <> LongInt(GuiThreadId))),
    ' direct_return=1');
  WriteLn('CAP7M1_INVOKE cycle=', ACycle,
    ' adds=', PWebAtomicRead(AddCalls),
    ' errors=', PWebAtomicRead(ErrorCalls),
    ' outstanding=', PWebAtomicRead(SlowCalls));
  if PWebAtomicRead(CloseByWindow) <> 0 then
    shape := 'window-close'
  else
    shape := 'terminate';
  WriteLn('CAP7M1_SHUTDOWN cycle=', ACycle, ' shape=', shape,
    ' clean=', Ord(PWebAtomicRead(CycleFailed) = 0));
  WriteLn('CAP7M1_RSS cycle=', ACycle, ' rss_kb=', PWebCocoaResidentKb);

  ok := PWebAtomicRead(CycleFailed) = 0;
  if ok and (PWebAtomicRead(ReportSeen) = 0) then
  begin
    FailCycle('the page never reported');
    ok := False;
  end;
  if ok and (Pos('"ok":true', ReportJson) = 0) then
  begin
    FailCycle('the page verdict was not ok');
    ok := False;
  end;
  // 8 concurrent + 1 explicit RPC = 9 CalculatorService.Add calls
  if ok and (PWebAtomicRead(AddCalls) <> 9) then
  begin
    FailCycle('CalculatorService.Add did not complete exactly nine times');
    ok := False;
  end;
  if ok and (PWebAtomicRead(ErrorCalls) <> 1) then
  begin
    FailCycle('the forced error did not complete exactly once');
    ok := False;
  end;
  if ok and (PWebAtomicRead(SlowCalls) <> 1) then
  begin
    FailCycle('the outstanding invocation was not drained by teardown');
    ok := False;
  end;
  if ok and (PWebAtomicRead(CallbackThreadId) <> LongInt(GuiThreadId)) then
  begin
    FailCycle('the bind callback did not run on the GUI thread');
    ok := False;
  end;
  if ok and ((PWebAtomicRead(ServiceThreadId) = 0) or
             (PWebAtomicRead(ServiceThreadId) = LongInt(GuiThreadId))) then
  begin
    FailCycle('no invocation was serviced off the GUI thread');
    ok := False;
  end;
  // Every one of these is a DELTA over this cycle, not an absolute: the
  // bridge's counters are process cumulative, so an absolute comparison would
  // charge cycle 3 with cycle 1's history.
  if ok and (statsAfter.CaughtExceptions <> statsBefore.CaughtExceptions) then
  begin
    FailCycle('an Objective-C exception reached the bridge boundary');
    ok := False;
  end;
  if ok and
     (statsAfter.SuppressedTerminals <> statsBefore.SuppressedTerminals) then
  begin
    FailCycle('a terminal delivery had to be suppressed');
    ok := False;
  end;
  if ok and
     (statsAfter.UnresolvedHandles <> statsBefore.UnresolvedHandles) then
  begin
    FailCycle('a callback arrived for a handle that no longer resolves');
    ok := False;
  end;
  if ok and (statsAfter.LiveTasks <> 0) then
  begin
    FailCycle('the live-task set was not empty after teardown');
    ok := False;
  end;
  // The ring must have seen every task the bridge started, and must not have
  // dropped or failed to read any of them - otherwise the URI leak check
  // covers an unknown subset of the requests.
  if ok and (PWebCocoaObservedDropped <> 0) then
  begin
    FailCycle('the diagnostic URI ring overflowed and dropped observations');
    ok := False;
  end;
  if ok and (PWebCocoaObservedNonconforming <> 0) then
  begin
    FailCycle('a request arrived with a URL that could not be read at all');
    ok := False;
  end;
  if ok and
     (QWord(observed) <> statsAfter.TasksStarted - statsBefore.TasksStarted) then
  begin
    FailCycle('the URI ring did not observe every task the bridge started');
    ok := False;
  end;
  if ok and (PWebCocoaRegistryCount <> 0) then
  begin
    FailCycle('the handler registry was not empty after teardown');
    ok := False;
  end;
  if ok and PWebCocoaHandleResolves(handle) then
  begin
    FailCycle('the handler handle still resolves after Detach');
    ok := False;
  end;

  if ok then
    WriteLn('CAP7M1_CYCLE_PASS cycle=', ACycle, ' store=', AMode)
  else
    WriteLn(StdErr, 'CAP7M1_FAIL cycle=', ACycle, ' store=', AMode,
      ' reason=', FailureReason);
  Result := ok;
end;

var
  mode: string;
  fixture, work, zipPath: TFileName;
  cycles, cycle, failures: Integer;
  rss: array[0..20] of QWord;
  base, last, span, budget, growth: QWord;
begin
  ExitCode := 0;
  failures := 0;
  FillChar(rss, SizeOf(rss), 0);
  GuiThreadId := GetCurrentThreadId;
  try
    if (ParamCount < 3) or (ParamCount > 4) then
      raise Exception.Create(
        'usage: cap7m_runtime <folder|zip> <fixture-dir> <work-dir> [cycles]');
    mode := LowerCase(ParamStr(1));
    if (mode <> 'folder') and (mode <> 'zip') then
      raise Exception.Create('store mode must be folder or zip');
    fixture := ExcludeTrailingPathDelimiter(ExpandFileName(ParamStr(2)));
    work := ExcludeTrailingPathDelimiter(ExpandFileName(ParamStr(3)));
    cycles := 3;
    if ParamCount = 4 then
      cycles := StrToIntDef(ParamStr(4), 0);
    if (cycles < 1) or (cycles > 20) then
      raise Exception.Create('cycles must be 1..20');
    if not DirectoryExists(fixture) then
      raise Exception.CreateFmt('fixture directory missing: %s', [fixture]);
    ForceDirectories(work);

    // ONE CORPUS, TWO STORES: the archive is built from exactly the files the
    // folder store serves, so a parity failure is a real difference between
    // the two stores and never a difference between two corpora.
    zipPath := work + PathDelim + 'cap7m-fixture.zip';
    BuildFixtureZip(fixture, zipPath);

    // the bounded diagnostic ring, so the gate can cross-check every URI the
    // PRODUCTION handler observed against the shared PWebParseAppUri
    PWebCocoaObserveUris(True);

    WriteLn('CAP7M1_ENV store=', mode, ' cycles=', cycles,
      ' gui_thread=', PtrUInt(GuiThreadId), ' fixture=', fixture);
    // STATED, not inferred from the absence of a crash. With the traps as FPC
    // sets them every cycle died with EInvalidOp the moment WebKit touched a
    // NaN, so "the process is still alive" is exactly the kind of evidence
    // this shard refuses to accept for anything else either.
    WriteLn('CAP7M1_FPU store=', mode, ' traps_masked=',
      Ord(PWebCocoaFpuTrapsMasked));
    if not PWebCocoaFpuTrapsMasked then
    begin
      WriteLn(StdErr, 'CAP7M1_FAIL store=', mode,
        ' reason=the FPU could not be put in its non-trapping default state');
      Halt(1);
    end;

    for cycle := 1 to cycles do
    begin
      if not RunCycle(cycle, mode, fixture, zipPath) then
        Inc(failures);
      rss[cycle] := PWebCocoaResidentKb;
    end;

    // P23's leak half. The crash and the hang are the cycle verdict and the
    // two watchdog deadlines; this is the leak, and cycle 1 is never the
    // baseline - WebKit legitimately populates its caches on the first
    // navigation, and treating that as a leak would be a false positive on
    // every single run.
    if cycles >= MIN_CYCLES_FOR_LEAK_CHECK then
    begin
      base := rss[2];
      last := rss[cycles];
      span := QWord(cycles - 2);
      budget := QWord(RSS_GROWTH_KB_PER_CYCLE_MAX) * span;
      if last > base then
        growth := last - base
      else
        growth := 0;
      WriteLn('CAP7M1_LEAK base_cycle=2 base_kb=', base,
        ' last_cycle=', cycles, ' last_kb=', last,
        ' growth_kb=', growth, ' budget_kb=', budget);
      if growth > budget then
      begin
        WriteLn(StdErr, 'CAP7M1_FAIL reason=resident size grew ', growth,
          ' KiB over ', span, ' cycle(s), budget ', budget, ' KiB');
        Inc(failures);
      end;
    end
    else
      WriteLn('CAP7M1_LEAK skipped=1 reason=needs>=',
        MIN_CYCLES_FOR_LEAK_CHECK, ' cycles, ran ', cycles);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'CAP7M1_FAIL reason=', E.ClassName, ': ', E.Message);
      Inc(failures);
    end;
  end;

  if failures <> 0 then
  begin
    WriteLn(StdErr, 'CAP7M1_FAIL store=', mode, ' failed=', failures);
    ExitCode := 1;
  end
  else
    WriteLn('CAP7M1_PASS store=', mode, ' cycles=', cycles);
end.
