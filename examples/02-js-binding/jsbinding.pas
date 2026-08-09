program jsbinding;

{ CAP-2 Windows x64 runtime example: JS <-> Pascal through the real
  invocation pipeline.

  create webview -> register a scheduler source (allow-all policy +
  dummy bridge) -> TWebViewBinding binds the internal JS endpoint ->
  the page fires MULTIPLE CONCURRENT invocations (pweb.echo round
  trips, a test.delay, a deliberately rejecting test.fail) -> results
  render from resolved/rejected promises. Every completion travels
  worker -> webview_return (thread-safe at the pin) - off the GUI
  thread, never dispatched.

  The global JS binding name (__pweb_invoke) is an internal
  implementation detail of the runtime - not a public protocol field.

  Teardown order after the run loop exits: binding.Close (quiesce ->
  unbind -> source close -> lease shutter) -> scheduler.Shutdown (the
  GUI loop has exited, so this thread may block on worker drain) ->
  webview_destroy.

  PWEB_SMOKE_AUTOCLOSE_MS=<n> closes the window automatically after n
  milliseconds, exactly like examples/01-hello: background thread ->
  webview_dispatch -> webview_terminate on the GUI thread (a direct
  background-thread terminate does NOT stop the Windows loop at the
  pinned commit; see docs/webview-upstream-semantics.md). }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.scheduler,
  pweb.rpc.bridge.dummy,
  pweb.capabilities,
  pweb.webview.intf,
  pweb.webview.binding;

const
  PAGE_HTML: AnsiString =
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<title>PWeb JS binding</title><style>' +
    'body{font-family:sans-serif;margin:2em}' +
    'li.ok{color:#0a7a2f}li.bad{color:#b00020}' +
    '#status{font-weight:bold;margin-top:1em}' +
    '</style></head><body>' +
    '<h1 id="pweb-jsbinding">PWeb CAP-2: JS &#8596; Pascal invocation pipeline</h1>' +
    '<p>Concurrent invocations through allow-all policy + dummy bridge:</p>' +
    '<ul id="out"></ul><div id="status">running&#8230;</div>' +
    '<script>' +
    'function invoke(m, a) { return window.__pweb_invoke(m, a === undefined ? null : a); }' +
    'window.addEventListener("DOMContentLoaded", function () {' +
    '  var out = document.getElementById("out");' +
    '  function add(cls, text) {' +
    '    var li = document.createElement("li");' +
    '    li.className = cls; li.textContent = text; out.appendChild(li);' +
    '  }' +
    '  var jobs = [];' +
    '  var i;' +
    '  for (i = 1; i <= 8; i++) {' +
    '    (function (n) {' +
    '      jobs.push(invoke("pweb.echo", { n: n, msg: "hello " + n }).then(function (r) {' +
    '        var ok = r && r.n === n && r.msg === "hello " + n;' +
    '        add(ok ? "ok" : "bad", "pweb.echo #" + n + (ok ? " resolved: " : " WRONG: ") + JSON.stringify(r));' +
    '        if (!ok) { throw new Error("bad echo"); }' +
    '      }));' +
    '    })(i);' +
    '  }' +
    '  jobs.push(invoke("test.delay", { slow: true }).then(function (r) {' +
    '    add("ok", "test.delay resolved: " + JSON.stringify(r));' +
    '  }));' +
    '  jobs.push(invoke("test.fail", {}).then(function () {' +
    '    add("bad", "test.fail resolved unexpectedly");' +
    '    throw new Error("should have rejected");' +
    '  }, function (e) {' +
    '    add("ok", "test.fail rejected as expected: " + JSON.stringify(e));' +
    '  }));' +
    '  Promise.allSettled(jobs).then(function (rs) {' +
    '    var ok = rs.filter(function (r) { return r.status === "fulfilled"; }).length;' +
    '    var verdict = ok === rs.length ? "ALL" : "FAILED";' +
    '    document.getElementById("status").textContent =' +
    '      verdict === "ALL" ? "ALL " + rs.length + " concurrent invocations completed correctly"' +
    '                        : "FAILED: " + (rs.length - ok) + " of " + rs.length + " invocations misbehaved";' +
    '    invoke("example.report", { verdict: verdict, ok: ok, total: rs.length });' +
    '  });' +
    '});' +
    '</script></body></html>';

const
  MAX_AUTOCLOSE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;

var
  AutoCloseHandle: Pointer = nil;

  { page verdict, delivered through the pipeline itself:
    0 = never received, 1 = ALL invocations correct, 2 = FAILED }
  ReportState: LongInt = 0;

type
  { decorates the dummy bridge: intercepts the page's final
    example.report invocation so the PROCESS can turn the page verdict
    into an exit code (the human/CI gate observes the invocations, not
    just a clean window teardown); every other method passes through }
  TReportingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

constructor TReportingBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function TReportingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = 'example.report' then
  begin
    if Pos('"verdict":"ALL"', Args) > 0 then
      InterlockedExchange(ReportState, 1)
    else
      InterlockedExchange(ReportState, 2);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

{ Runs on the GUI thread (scheduled by webview_dispatch). Exception
  barrier: nothing may escape into the C frame. }
procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    if WebViewFailed(webview_terminate(w)) then
      WriteLn(StdErr, 'warning: webview_terminate failed in auto-close');
  except
    { swallow: a Pascal exception must never cross the C callback frame }
  end;
end;

function AutoCloseThread(Param: Pointer): PtrInt;
var
  Ms: Integer;
  H: Pointer;
begin
  Result := 0;
  Ms := PtrInt(Param);
  Sleep(Ms);
  H := InterlockedExchange(AutoCloseHandle, nil);
  if H <> nil then
    if WebViewFailed(webview_dispatch(webview_t(H),
        @TerminateOnGuiThread, nil)) then
      WriteLn(StdErr, 'warning: webview_dispatch failed in auto-close');
end;

var
  W: webview_t;
  Scheduler: TInvocationScheduler;
  SchedulerRef: IInvocationScheduler;
  Source: IInvocationSource;
  Binding: IWebViewBinding;
  Limits: TPWebSourceLimits;
  Opts: TPWebWebViewBindingOptions;
  CtxTemplate: TInvocationContext;
  AutoCloseMs: Integer;
  CloserId: TThreadID;
  CloserHandle: TThreadID;
  CloserStarted: Boolean;
  SafeToDestroy: Boolean;
begin
  ExitCode := 0;
  CloserStarted := False;
  CloserId := TThreadID(0);
  CloserHandle := TThreadID(0);
  SafeToDestroy := True;
  try
    // the pipeline: every invocation travels
    //   source -> scheduler -> policy -> bridge
    // with the explicit Phase-2 allow-all policy IN the path
    Scheduler := TInvocationScheduler.Create(
      TAllowAllCapabilityPolicy.Create,
      TReportingBridge.Create(TDummyInvocationBridge.Create), 4);
    SchedulerRef := Scheduler;
    Limits.MaxConcurrent := 4;
    Limits.MaxQueueSize := 64;
    Source := Scheduler.RegisterSource(Limits);

    W := WebViewCheckCreated(webview_create(0, nil));
    try
      AutoCloseHandle := Pointer(W);

      // native trust anchor: the context template never comes from JS
      CtxTemplate := Default(TInvocationContext);
      CtxTemplate.WindowId := 'main';
      CtxTemplate.PrincipalId := 'window:main';
      CtxTemplate.PrincipalKind := pkWindow;
      CtxTemplate.TrustedContent := True;
      Opts := PWebDefaultBindingOptions(CtxTemplate);
      Binding := TWebViewBinding.Create(W, Source, Opts);
      Binding.Bind('__pweb_invoke', TPWebEnvelopeHandler.Create(Source));

      WebViewCheck(webview_set_title(W, 'PWeb JS binding'), 'webview_set_title');
      WebViewCheck(webview_set_size(W, 900, 700, WEBVIEW_HINT_NONE),
        'webview_set_size');
      WebViewCheck(webview_set_html(W, PAnsiChar(PAGE_HTML)),
        'webview_set_html');

      AutoCloseMs := StrToIntDef(GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if AutoCloseMs > MAX_AUTOCLOSE_MS then
        AutoCloseMs := MAX_AUTOCLOSE_MS;
      if AutoCloseMs > 0 then
      begin
        CloserHandle := BeginThread(@AutoCloseThread,
          Pointer(PtrInt(AutoCloseMs)), CloserId);
        CloserStarted := CloserHandle <> TThreadID(0);
        if not CloserStarted then
          WriteLn(StdErr, 'warning: BeginThread failed; auto-close disabled');
      end;

      WebViewCheck(webview_run(W), 'webview_run');
    finally
      // the GUI loop has exited here; this thread is no longer the GUI
      // thread in the operative sense
      if CloserStarted then
      begin
        if WaitForThreadTerminate(CloserHandle,
             AutoCloseMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          WriteLn(StdErr,
            'FAIL: auto-close thread did not terminate in time; ' +
            'skipping webview_destroy to avoid use-after-free');
          SafeToDestroy := False;
          ExitCode := 1;
        end;
        CloseThread(CloserHandle);
      end;
      InterlockedExchange(AutoCloseHandle, nil);
      // teardown order: binding first (quiesce -> unbind -> close ->
      // lease shutter), then scheduler drain, then native destroy.
      // Each step is fenced: a failure in one must never skip the next
      // (in particular webview_destroy must always be attempted).
      try
        if Binding <> nil then
          Binding.Close;
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'FAIL: binding Close: ', E.Message);
          ExitCode := 1;
        end;
      end;
      try
        if SchedulerRef <> nil then
          SchedulerRef.Shutdown; // may block; the GUI loop already exited
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'FAIL: scheduler Shutdown: ', E.Message);
          ExitCode := 1;
        end;
      end;
      if SafeToDestroy then
        try
          WebViewCheck(webview_destroy(W), 'webview_destroy');
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: webview_destroy: ', E.Message);
            ExitCode := 1;
          end;
        end;
    end;
    // the page's own verdict, transported through the pipeline itself
    case ReportState of
      1:
        WriteLn('jsbinding: page reported ALL invocations completed correctly');
      2:
        begin
          WriteLn(StdErr, 'FAIL: page reported FAILED invocations');
          ExitCode := 1;
        end;
    else
      if AutoCloseMs > 0 then
      begin
        // an unattended run had ample time: no verdict is a failure
        WriteLn(StdErr, 'FAIL: no page verdict received before auto-close');
        ExitCode := 1;
      end
      else
        WriteLn(StdErr,
          'warning: no page verdict received (window closed before the page finished?)');
    end;
    if ExitCode = 0 then
      WriteLn('jsbinding: clean exit');
  except
    on E: EWebViewError do
    begin
      WriteLn(StdErr, 'FAIL: ', E.Message);
      ExitCode := 1;
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  // safety net: if setup failed before the inner try/finally (e.g.
  // webview_create raised), the scheduler still drains its workers;
  // Shutdown is idempotent so a second call here is a cheap no-op
  if SchedulerRef <> nil then
    try
      SchedulerRef.Shutdown;
    except
    end;
end.
