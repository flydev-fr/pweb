program reactapp;

{ CAP-5 React runtime proof (Windows x64):

    pweb://app/index.html + /assets/app.js (esbuild bundle of a real
    React application consuming the @pweb/runtime TypeScript SDK)
      -> WebView2 WebResourceRequested handler (CAP-4W seam)
      -> TFolderAssetStore over the built frontend/dist
      -> React -> TypeScript SDK -> __pweb_invoke -> scheduler
      -> allow-all policy -> in-process mORMot -> 42

  The page performs pweb.handshake through the SDK, invokes
  CalculatorService.Add(a:20, b:22), renders the 42 and reports the
  machine verdict via example.report. The backend below is IDENTICAL to
  the Pas2JS example's host (examples/05-pas2js) apart from the window
  title and log prefix: no backend file branches on frontend kind.

    reactapp <path-to-frontend/dist> }

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
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.folder,
  pweb.platform.webview2;

const
  MAX_AUTOCLOSE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;
  APP_TITLE = 'PWeb CAP-5 React';
  LOG_PREFIX = 'reactapp';

type
  ICalculatorService = interface(IInvokable)
    ['{F2D880F7-0EE4-4EBE-8371-FBB16467BE41}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Test-only decorator for the page's machine verdict. All application
    and runtime methods still pass to the real bridge on workers. }
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
    WriteLn(LOG_PREFIX, ' report: ', Args); // raw page verdict for the log
    // the page reports handshake/secure/rendered/rpc through the SDK;
    // require every flag plus the worker-thread proof before declaring
    // the runtime verdict PASS. Only the FIRST report latches.
    if (Pos('"ok":true', Args) > 0) and
       (Pos('"handshake":true', Args) > 0) and
       (Pos('"secure":true', Args) > 0) and
       (Pos('"rendered":true', Args) > 0) and
       (Pos('"rpc":true', Args) > 0) and
       (Pos('"errmap":true', Args) > 0) and
       ((Pos('"value":42}', Args) > 0) or (Pos('"value":42,', Args) > 0)) and
       (InterlockedCompareExchange(ServiceThreadId, 0, 0) <> 0) and
       (InterlockedCompareExchange(ServiceThreadId, 0, 0) <>
        InterlockedCompareExchange(GuiThreadId, 0, 0)) then
      InterlockedCompareExchange(ReportState, 1, 0)
    else
      InterlockedCompareExchange(ReportState, 2, 0);
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
  store: IAssetStore;
  assetHandler: TWebView2AssetHandler;
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
  assetHandler := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  InterlockedExchange(GuiThreadId, LongInt(GetCurrentThreadId));
  try
    if (ParamCount <> 1) or (ParamStr(1) = '') then
      raise Exception.Create('usage: ' + LOG_PREFIX + ' <frontend/dist>');
    store := TFolderAssetStore.Create(ParamStr(1));

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
    limits := Default(TPWebSourceLimits);
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
      WebViewCheck(webview_set_title(w, PAnsiChar(AnsiString(APP_TITLE))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      // production asset path: attach the pweb://app handler on the
      // proven CAP-4W seam, then navigate - never SetHtml/Eval
      assetHandler := TWebView2AssetHandler.Create(w, store);
      WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

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
          schedulerRef.Shutdown; // drain before bridge/server release
          schedulerDrained := True;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: scheduler Shutdown: ', E.Message);
            ExitCode := 1;
          end;
        end;
      // CAP-4W ordering: unregister the resource handler and release
      // its owned COM references before the webview is destroyed
      if assetHandler <> nil then
        try
          assetHandler.Detach;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: asset handler Detach: ', E.Message);
            ExitCode := 1;
          end;
        end;
      FreeAndNil(assetHandler);
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
      WriteLn(LOG_PREFIX,
        ': React -> SDK -> scheduler -> mORMot -> 42 over pweb://app PASS')
    else
    begin
      WriteLn(StdErr, 'FAIL: page/runtime verdict was not successful ',
        '(state=', ReportState, '; 0=no report received)');
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
  store := nil;
  server.Free;
  if ExitCode = 0 then
    WriteLn(LOG_PREFIX, ': clean exit');
end.
