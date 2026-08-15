program assetsapp;

{ CAP-4 Windows x64 runtime proof:

    pweb://app/index.html (+ CSS/JS referenced normally by the page)
      -> WebView2 WebResourceRequested handler (CAP-4W seam)
      -> canonical logical path -> IAssetStore.TryRead
      -> TFolderAssetStore (mode 'folder') or TZipAssetStore ('zip')

  The same real frontend runs in both modes and must report
  HTML/CSS/JS/secure-context PASS, and the unchanged CAP-3 pipeline
  must still answer CalculatorService.Add({a:20,b:22}) = 42 from the
  asset-loaded page. No SetHtml/Eval injection and no network or
  filesystem URL transport of any kind.

  CAP-7L runs this same proof on Linux/WebKitGTK. Only the handler
  class is selected by platform, at the same attach point; the folder
  and ZIP stores, the URI translation and the verdict are shared
  source, which is exactly what makes this a parity gate.

    assetsapp folder <path-to-frontend/dist>
    assetsapp zip    <path-to-app.zip> }

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
  pweb.assets.zip,
  {$ifdef LINUX}
  pweb.platform.webkitgtk;
  {$else}
  pweb.platform.webview2;
  {$endif LINUX}

const
  MAX_AUTOCLOSE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;

type
  { The one platform-selected name in this file; both handlers expose the
    identical Create(webview_t, IAssetStore)/Detach surface. }
  {$ifdef LINUX}
  TPWebAssetHandler = TWebKitGtkAssetHandler;
  {$else}
  TPWebAssetHandler = TWebView2AssetHandler;
  {$endif LINUX}

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
    WriteLn('assetsapp report: ', Args); // raw page verdict for the log
    // the page reports each stage; require every flag plus the CAP-3
    // worker-thread proof before declaring the runtime verdict PASS.
    // Only the FIRST report latches - a late duplicate cannot flip it.
    if (Pos('"ok":true', Args) > 0) and
       (Pos('"html":true', Args) > 0) and
       (Pos('"css":true', Args) > 0) and
       (Pos('"js":true', Args) > 0) and
       (Pos('"secure":true', Args) > 0) and
       (Pos('"notfound":true', Args) > 0) and
       (Pos('"rpc":true', Args) > 0) and
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
  mode: string;
  store: IAssetStore;
  assetHandler: TPWebAssetHandler;
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
    mode := LowerCase(ParamStr(1));
    if (ParamCount <> 2) or
       ((mode <> 'folder') and (mode <> 'zip')) or
       (ParamStr(2) = '') then
      raise Exception.Create(
        'usage: assetsapp folder <frontend/dist> | assetsapp zip <app.zip>');
    if mode = 'folder' then
      store := TFolderAssetStore.Create(ParamStr(2))
    else
      store := TZipAssetStore.Create(ParamStr(2));

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

    {$ifdef LINUX}
    // CAP-7L: name the knowable cause before webview_create collapses
    // it into a nil the frozen raw layer blames on a WebView2 runtime
    if PWebGtkDisplayUnavailableReason <> '' then
    begin
      WriteLn(StdErr, 'assetsapp: GTK DISPLAY UNAVAILABLE (',
        PWebGtkDisplayUnavailableReason, ')');
      raise Exception.Create('no usable display - no WebView was created');
    end;
    {$endif LINUX}

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
      WebViewCheck(webview_set_title(w,
        PAnsiChar(AnsiString('PWeb CAP-4 assets (' + mode + ')'))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 900, 650, WEBVIEW_HINT_NONE),
        'webview_set_size');
      // production asset path: attach the pweb://app handler on the
      // proven native seam, then navigate - never SetHtml/Eval
      {$ifdef LINUX}
      assetHandler := TWebKitGtkAssetHandler.Create(w, store);
      {$else}
      assetHandler := TWebView2AssetHandler.Create(w, store);
      {$endif LINUX}
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
      WriteLn('assetsapp[', mode,
        ']: HTML/CSS/JS/secure-context/RPC(42) via IAssetStore PASS')
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
    WriteLn('assetsapp: clean exit');
end.
