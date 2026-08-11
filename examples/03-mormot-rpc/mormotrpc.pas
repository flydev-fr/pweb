program mormotrpc;

{ CAP-3 Windows x64 runtime proof:
    JavaScript -> webview_bind -> existing scheduler -> allow-all policy
    -> TMormotInvocationBridge -> TRestServer.Uri() -> webview_return.
  There is no network transport or listener. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
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
  pweb.webview.binding;

const
  PAGE_HTML: AnsiString =
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<title>PWeb CAP-3 mORMot RPC</title><style>' +
    'body{font-family:sans-serif;margin:2em}#result{font-size:2em;font-weight:bold}' +
    '.ok{color:#087a2e}.bad{color:#b00020}</style></head><body>' +
    '<h1>PWeb CAP-3: in-process mORMot RPC</h1>' +
    '<p>CalculatorService.Add({a:20,b:22})</p>' +
    '<div id="result">running&#8230;</div><script>' +
    'function invoke(m,a){return window.__pweb_invoke(m,a===undefined?null:a);}' +
    'window.addEventListener("DOMContentLoaded",function(){' +
    ' var out=document.getElementById("result");' +
    ' invoke("CalculatorService.Add",{a:20,b:22}).then(function(v){' +
    '  var ok=v===42;out.className=ok?"ok":"bad";' +
    '  out.textContent=ok?"42 — PASS":"WRONG: "+JSON.stringify(v);' +
    '  return invoke("example.report",{ok:ok,value:v});' +
    ' },function(e){out.className="bad";out.textContent="FAILED: "+JSON.stringify(e);' +
    '  invoke("example.report",{ok:false,error:e});});' +
    '});</script></body></html>';
  MAX_AUTOCLOSE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;

type
  ICalculatorService = interface(IInvokable)
    ['{F2D880F7-0EE4-4EBE-8371-FBB16467BE41}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Test-only decorator for the page's machine verdict. All application and
    runtime methods still pass to the real bridge on scheduler workers. }
  TReportingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

var
  AutoCloseHandle: Pointer;
  ReportState: LongInt;
  ServiceThreadId: LongInt;
  GuiThreadId: LongInt;

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedExchange(ServiceThreadId, LongInt(GetCurrentThreadId));
  Result := a + b;
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
    if (Pos('"ok":true', Args) > 0) and
       (InterlockedCompareExchange(ServiceThreadId, 0, 0) <> 0) and
       (InterlockedCompareExchange(ServiceThreadId, 0, 0) <>
        InterlockedCompareExchange(GuiThreadId, 0, 0)) then
      InterlockedExchange(ReportState, 1)
    else
      InterlockedExchange(ReportState, 2);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

function AutoCloseThread(Param: Pointer): PtrInt;
var
  handle: Pointer;
begin
  Result := 0;
  Sleep(PtrInt(Param));
  handle := InterlockedExchange(AutoCloseHandle, nil);
  if handle <> nil then
    webview_dispatch(webview_t(handle), @TerminateOnGuiThread, nil);
end;

var
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
  autoCloseMs: Integer;
  closerId, closerHandle: TThreadID;
  closerStarted, safeToDestroy, schedulerDrained: Boolean;
begin
  ExitCode := 0;
  server := nil;
  scheduler := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  InterlockedExchange(GuiThreadId, LongInt(GetCurrentThreadId));
  try
    server := TRestServerFullMemory.CreateWithOwnModel([]);
    factory := server.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register CalculatorService');
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    bridge := TReportingBridge.Create(realBridge);
    scheduler := TInvocationScheduler.Create(
      TAllowAllCapabilityPolicy.Create, bridge, 4);
    schedulerRef := scheduler;
    limits.MaxConcurrent := 4;
    limits.MaxQueueSize := 32;
    source := scheduler.RegisterSource(limits);

    w := WebViewCheckCreated(webview_create(0, nil));
    try
      AutoCloseHandle := Pointer(w);
      context := Default(TInvocationContext);
      context.WindowId := 'main';
      context.PrincipalId := 'window:main';
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, source, opts);
      binding.Bind('__pweb_invoke', TPWebEnvelopeHandler.Create(source));
      WebViewCheck(webview_set_title(w, 'PWeb CAP-3 mORMot RPC'),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      WebViewCheck(webview_set_html(w, PAnsiChar(PAGE_HTML)),
        'webview_set_html');

      autoCloseMs := StrToIntDef(
        GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if autoCloseMs > MAX_AUTOCLOSE_MS then
        autoCloseMs := MAX_AUTOCLOSE_MS;
      if autoCloseMs > 0 then
      begin
        closerHandle := BeginThread(@AutoCloseThread,
          Pointer(PtrInt(autoCloseMs)), closerId);
        closerStarted := closerHandle <> TThreadID(0);
        if not closerStarted then
          raise Exception.Create('unable to start auto-close thread');
      end;
      WebViewCheck(webview_run(w), 'webview_run');
    finally
      if closerStarted then
      begin
        if WaitForThreadTerminate(closerHandle,
             autoCloseMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          WriteLn(StdErr, 'FAIL: auto-close thread did not terminate');
          safeToDestroy := False;
          ExitCode := 1;
        end;
        CloseThread(closerHandle);
      end;
      InterlockedExchange(AutoCloseHandle, nil);
      if binding <> nil then
        try
          binding.Close;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: binding Close: ', E.Message);
            ExitCode := 1;
          end;
        end;
      if schedulerRef <> nil then
        try
          schedulerRef.Shutdown; // drain before real bridge/server release
          schedulerDrained := True;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: scheduler Shutdown: ', E.Message);
            ExitCode := 1;
          end;
        end;
      if safeToDestroy then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: webview_destroy: ', E.Message);
            ExitCode := 1;
          end;
        end;
    end;

    if ReportState = 1 then
      WriteLn('mormotrpc: CalculatorService.Add -> 42 on scheduler worker PASS')
    else
    begin
      WriteLn(StdErr, 'FAIL: page/runtime verdict was not successful');
      ExitCode := 1;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  if (scheduler <> nil) and not schedulerDrained then
    try
      scheduler.Shutdown;
      schedulerDrained := True;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'FAIL: final scheduler Shutdown: ', E.Message);
        ExitCode := 1;
      end;
    end;
  binding := nil;
  source := nil;
  schedulerRef := nil;
  scheduler := nil;
  bridge := nil;
  realBridge := nil; // frees owned server after worker drain
  server.Free;
  if ExitCode = 0 then
    WriteLn('mormotrpc: clean exit');
end.
