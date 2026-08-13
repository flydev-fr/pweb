{
  pweb.platform.webview2 - production pweb://app resource handler for
  the Windows/WebView2 engine (CAP-4).

  Attaches a WebResourceRequested handler for pweb://app/* onto an
  existing webview through the CAP-4W seam: the borrowed
  ICoreWebView2Controller native handle exposed by the pinned webview
  C ABI. Environment creation and the pweb custom-scheme registration
  themselves live in the audited CAP-4W dependency patch - this unit
  never reimplements them.

  Request flow (all of it on the WebView2 event thread):

    WebResourceRequested
      -> PWebParseAppUri  (scheme+authority check, single decode,
                           root mapping, canonical validation)
      -> IAssetStore.TryRead
      -> 200 + exact bytes + Content-Type   or deterministic 404

  Only pweb://app is application content: the registered filter is
  'pweb://app/*', and the URI is nevertheless re-verified here - a
  wrong authority is answered 404, never trusted or served.
  Responses never expose physical paths or rejection reasons.

  COM rules, mirroring the proven CAP-4W probe:
    - the controller pointer stays borrowed - never AddRef/Release;
    - CoreWebView2/environment references acquired here are owned and
      released at Detach;
    - teardown order: remove_WebResourceRequested, remove the filter,
      release owned references - before webview_destroy;
    - no Pascal exception ever crosses the COM callback boundary.

  The interface declarations below are a minimal transcription of the
  pinned WebView2 SDK 1.0.1587.40 header: exact IIDs, exact vtable
  slot order, with unused slots declared as never-called stubs.
}
unit pweb.platform.webview2;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.assets.intf,
  pweb.assets.support;

type
  EPWebWebView2AssetHandler = class(Exception);

  { Serves IAssetStore content on pweb://app/* for one webview.
    Create on the GUI thread after webview_create; Detach on the GUI
    thread before webview_destroy (Destroy calls Detach as a guard). }
  TWebView2AssetHandler = class
  private
    fStore: IAssetStore;
    fController: Pointer; // borrowed - never AddRef/Release
    fCore: IInterface; // owned ICoreWebView2
    fEnvironment: IInterface; // owned ICoreWebView2Environment
    fHandler: IInterface; // our event handler, kept alive while bound
    fHandlerObj: TObject; // same object, class-typed for detach
    fToken: Int64;
    fThreadId: DWord; // GUI thread that created us - COM affinity
    fAttached: Boolean;
    fFilterAdded: Boolean;
  public
    constructor Create(AWebView: webview_t; const AStore: IAssetStore);
    destructor Destroy; override;
    // idempotent; must run on the GUI thread before webview_destroy
    procedure Detach;
  end;

/// OBSERVED runtime identity of the WebView that actually opened
// (CAP-6b3)
// - walks the SAME already-proven borrowed-controller chain
// TWebView2AssetHandler.Create uses - controller -> ICoreWebView2 ->
// ICoreWebView2_2 -> ICoreWebView2Environment - and returns
// get_BrowserVersionString verbatim (it may carry a channel suffix
// after a space; interpreting that is the caller's policy)
// - the controller stays BORROWED: never AddRef/Release, exactly like
// the CAP-4W seam; call on the GUI thread after webview_create and
// BEFORE webview_navigate, so a refusal happens before any content
// - never raises: every refusal comes back as a '<...>' marker text
// that can never be mistaken for a version, so a caller comparing
// against a pin fails closed
// - nothing outside the fixed-runtime profile calls this
function PWebWv2ObservedBrowserVersion(AWebView: webview_t): RawUtf8;

implementation

{ ---- minimal pinned WebView2 SDK 1.0.1587.40 COM surface ---- }

const
  PWEB_APP_FILTER: WideString = 'pweb://app/*';
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0;

type
  ICoreWebView2WebResourceResponse = interface(IUnknown)
    ['{aafcc94f-fa27-48fd-97df-830ef75aaec9}']
    // slots passed opaquely - no method is called through this side
  end;

  ICoreWebView2WebResourceRequest = interface(IUnknown)
    ['{97055cd4-512c-4264-8b5f-e3f446cea6a5}']
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;
    function Stub_put_Uri: HRESULT; stdcall;
    function Stub_get_Method: HRESULT; stdcall;
    function Stub_put_Method: HRESULT; stdcall;
    function Stub_get_Content: HRESULT; stdcall;
    function Stub_put_Content: HRESULT; stdcall;
    function Stub_get_Headers: HRESULT; stdcall;
  end;

  ICoreWebView2WebResourceRequestedEventArgs = interface(IUnknown)
    ['{453e667f-12c7-49d4-be6d-ddbe7956f57a}']
    function get_Request(
      out request: ICoreWebView2WebResourceRequest): HRESULT; stdcall;
    function Stub_get_Response: HRESULT; stdcall;
    function put_Response(
      response: ICoreWebView2WebResourceResponse): HRESULT; stdcall;
    function Stub_GetDeferral: HRESULT; stdcall;
    function Stub_get_ResourceContext: HRESULT; stdcall;
  end;

  ICoreWebView2WebResourceRequestedEventHandler = interface(IUnknown)
    ['{ab00b74c-15f1-4646-80e8-e76341d25d71}']
    function Invoke(sender: IUnknown;
      args: ICoreWebView2WebResourceRequestedEventArgs): HRESULT; stdcall;
  end;

  ICoreWebView2Environment = interface(IUnknown)
    ['{b96d755e-0319-4e92-a296-23436f46a1fc}']
    function Stub_CreateCoreWebView2Controller: HRESULT; stdcall;
    function CreateWebResourceResponse(content: Pointer;
      statusCode: Integer; reasonPhrase: PWideChar; headers: PWideChar;
      out response: ICoreWebView2WebResourceResponse): HRESULT; stdcall;
    // CAP-6b3 turned this slot from a never-called stub into its real
    // declaration; the slot INDEX is unchanged, so every existing
    // caller keeps the exact same vtable layout
    function get_BrowserVersionString(
      out versionInfo: PWideChar): HRESULT; stdcall;
    function Stub_add_NewBrowserVersionAvailable: HRESULT; stdcall;
    function Stub_remove_NewBrowserVersionAvailable: HRESULT; stdcall;
  end;

  ICoreWebView2 = interface(IUnknown)
    ['{76eceacb-0462-4d94-ac83-423a6793775e}']
    function Stub_get_Settings: HRESULT; stdcall;
    function Stub_get_Source: HRESULT; stdcall;
    function Stub_Navigate: HRESULT; stdcall;
    function Stub_NavigateToString: HRESULT; stdcall;
    function Stub_add_NavigationStarting: HRESULT; stdcall;
    function Stub_remove_NavigationStarting: HRESULT; stdcall;
    function Stub_add_ContentLoading: HRESULT; stdcall;
    function Stub_remove_ContentLoading: HRESULT; stdcall;
    function Stub_add_SourceChanged: HRESULT; stdcall;
    function Stub_remove_SourceChanged: HRESULT; stdcall;
    function Stub_add_HistoryChanged: HRESULT; stdcall;
    function Stub_remove_HistoryChanged: HRESULT; stdcall;
    function Stub_add_NavigationCompleted: HRESULT; stdcall;
    function Stub_remove_NavigationCompleted: HRESULT; stdcall;
    function Stub_add_FrameNavigationStarting: HRESULT; stdcall;
    function Stub_remove_FrameNavigationStarting: HRESULT; stdcall;
    function Stub_add_FrameNavigationCompleted: HRESULT; stdcall;
    function Stub_remove_FrameNavigationCompleted: HRESULT; stdcall;
    function Stub_add_ScriptDialogOpening: HRESULT; stdcall;
    function Stub_remove_ScriptDialogOpening: HRESULT; stdcall;
    function Stub_add_PermissionRequested: HRESULT; stdcall;
    function Stub_remove_PermissionRequested: HRESULT; stdcall;
    function Stub_add_ProcessFailed: HRESULT; stdcall;
    function Stub_remove_ProcessFailed: HRESULT; stdcall;
    function Stub_AddScriptToExecuteOnDocumentCreated: HRESULT; stdcall;
    function Stub_RemoveScriptToExecuteOnDocumentCreated: HRESULT; stdcall;
    function Stub_ExecuteScript: HRESULT; stdcall;
    function Stub_CapturePreview: HRESULT; stdcall;
    function Stub_Reload: HRESULT; stdcall;
    function Stub_PostWebMessageAsJson: HRESULT; stdcall;
    function Stub_PostWebMessageAsString: HRESULT; stdcall;
    function Stub_add_WebMessageReceived: HRESULT; stdcall;
    function Stub_remove_WebMessageReceived: HRESULT; stdcall;
    function Stub_CallDevToolsProtocolMethod: HRESULT; stdcall;
    function Stub_get_BrowserProcessId: HRESULT; stdcall;
    function Stub_get_CanGoBack: HRESULT; stdcall;
    function Stub_get_CanGoForward: HRESULT; stdcall;
    function Stub_GoBack: HRESULT; stdcall;
    function Stub_GoForward: HRESULT; stdcall;
    function Stub_GetDevToolsProtocolEventReceiver: HRESULT; stdcall;
    function Stub_Stop: HRESULT; stdcall;
    function Stub_add_NewWindowRequested: HRESULT; stdcall;
    function Stub_remove_NewWindowRequested: HRESULT; stdcall;
    function Stub_add_DocumentTitleChanged: HRESULT; stdcall;
    function Stub_remove_DocumentTitleChanged: HRESULT; stdcall;
    function Stub_get_DocumentTitle: HRESULT; stdcall;
    function Stub_AddHostObjectToScript: HRESULT; stdcall;
    function Stub_RemoveHostObjectFromScript: HRESULT; stdcall;
    function Stub_OpenDevToolsWindow: HRESULT; stdcall;
    function Stub_add_ContainsFullScreenElementChanged: HRESULT; stdcall;
    function Stub_remove_ContainsFullScreenElementChanged: HRESULT; stdcall;
    function Stub_get_ContainsFullScreenElement: HRESULT; stdcall;
    function add_WebResourceRequested(
      eventHandler: ICoreWebView2WebResourceRequestedEventHandler;
      token: PInt64): HRESULT; stdcall;
    function remove_WebResourceRequested(token: Int64): HRESULT; stdcall;
    function AddWebResourceRequestedFilter(uri: PWideChar;
      resourceContext: Integer): HRESULT; stdcall;
    function RemoveWebResourceRequestedFilter(uri: PWideChar;
      resourceContext: Integer): HRESULT; stdcall;
    function Stub_add_WindowCloseRequested: HRESULT; stdcall;
    function Stub_remove_WindowCloseRequested: HRESULT; stdcall;
  end;

  ICoreWebView2_2 = interface(ICoreWebView2)
    ['{9E8F0CF8-E670-4B5E-B2BC-73E061E3184C}']
    function Stub_add_WebResourceResponseReceived: HRESULT; stdcall;
    function Stub_remove_WebResourceResponseReceived: HRESULT; stdcall;
    function Stub_NavigateWithWebResourceRequest: HRESULT; stdcall;
    function Stub_add_DOMContentLoaded: HRESULT; stdcall;
    function Stub_remove_DOMContentLoaded: HRESULT; stdcall;
    function Stub_get_CookieManager: HRESULT; stdcall;
    function get_Environment(
      out environment: ICoreWebView2Environment): HRESULT; stdcall;
  end;

  ICoreWebView2Controller = interface(IUnknown)
    ['{4d00c0d1-9434-4eb6-8078-8697a560334f}']
    function Stub_get_IsVisible: HRESULT; stdcall;
    function Stub_put_IsVisible: HRESULT; stdcall;
    function Stub_get_Bounds: HRESULT; stdcall;
    function Stub_put_Bounds: HRESULT; stdcall;
    function Stub_get_ZoomFactor: HRESULT; stdcall;
    function Stub_put_ZoomFactor: HRESULT; stdcall;
    function Stub_add_ZoomFactorChanged: HRESULT; stdcall;
    function Stub_remove_ZoomFactorChanged: HRESULT; stdcall;
    function Stub_SetBoundsAndZoomFactor: HRESULT; stdcall;
    function Stub_MoveFocus: HRESULT; stdcall;
    function Stub_add_MoveFocusRequested: HRESULT; stdcall;
    function Stub_remove_MoveFocusRequested: HRESULT; stdcall;
    function Stub_add_GotFocus: HRESULT; stdcall;
    function Stub_remove_GotFocus: HRESULT; stdcall;
    function Stub_add_LostFocus: HRESULT; stdcall;
    function Stub_remove_LostFocus: HRESULT; stdcall;
    function Stub_add_AcceleratorKeyPressed: HRESULT; stdcall;
    function Stub_remove_AcceleratorKeyPressed: HRESULT; stdcall;
    function Stub_get_ParentWindow: HRESULT; stdcall;
    function Stub_put_ParentWindow: HRESULT; stdcall;
    function Stub_NotifyParentWindowPositionChanged: HRESULT; stdcall;
    function Stub_Close: HRESULT; stdcall;
    function get_CoreWebView2(out core: ICoreWebView2): HRESULT; stdcall;
  end;

// SHCreateMemStream copies the buffer, so the asset bytes need not
// outlive the call. Declared with a RAW pointer result on purpose: an
// interface-typed function result would make FPC expect its own
// hidden-parameter ABI, which does not match the C ABI returning the
// IStream* in RAX. The returned reference (refcount 1) is owned by
// the caller and must be released exactly once.
function SHCreateMemStream(pInit: PByte; cbInit: LongWord): Pointer;
  stdcall; external 'shlwapi.dll' name 'SHCreateMemStream';

{ ---- event handler object ---- }

type
  TResourceRequestedHandler = class(TInterfacedObject,
    ICoreWebView2WebResourceRequestedEventHandler)
  private
    fOwner: TWebView2AssetHandler;
  public
    constructor Create(AOwner: TWebView2AssetHandler);
    function Invoke(sender: IUnknown;
      args: ICoreWebView2WebResourceRequestedEventArgs): HRESULT; stdcall;
  end;

constructor TResourceRequestedHandler.Create(AOwner: TWebView2AssetHandler);
begin
  inherited Create;
  fOwner := AOwner;
end;

procedure CoTaskFree(p: Pointer); stdcall;
  external 'ole32.dll' name 'CoTaskMemFree';

{ ---- CAP-6b3 observed runtime identity ---- }

function PWebWv2ObservedBrowserVersion(AWebView: webview_t): RawUtf8;
var
  controller: Pointer;
  core: ICoreWebView2;
  core2: ICoreWebView2_2;
  env: ICoreWebView2Environment;
  versionW: PWideChar;
  hr: HRESULT;
begin
  Result := '';
  try
    if AWebView = nil then
    begin
      Result := '<no-webview>';
      exit;
    end;
    controller := webview_get_native_handle(AWebView,
      WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
    if controller = nil then
    begin
      Result := '<no-controller>';
      exit;
    end;
    // borrowed, exactly like TWebView2AssetHandler: method calls only
    hr := ICoreWebView2Controller(controller).get_CoreWebView2(core);
    if (hr <> S_OK) or
       (core = nil) then
    begin
      Result := '<get_CoreWebView2 0x' + RawUtf8(IntToHex(hr, 8)) + '>';
      exit;
    end;
    hr := core.QueryInterface(ICoreWebView2_2, core2);
    if (hr <> S_OK) or
       (core2 = nil) then
    begin
      Result := '<no ICoreWebView2_2 0x' + RawUtf8(IntToHex(hr, 8)) + '>';
      exit;
    end;
    hr := core2.get_Environment(env);
    core2 := nil;
    if (hr <> S_OK) or
       (env = nil) then
    begin
      Result := '<get_Environment 0x' + RawUtf8(IntToHex(hr, 8)) + '>';
      exit;
    end;
    versionW := nil;
    hr := env.get_BrowserVersionString(versionW);
    if (hr <> S_OK) or
       (versionW = nil) then
    begin
      Result := '<get_BrowserVersionString 0x' +
        RawUtf8(IntToHex(hr, 8)) + '>';
      exit;
    end;
    Result := RawUnicodeToUtf8(versionW, StrLenW(versionW));
    CoTaskFree(versionW); // the string is CoTaskMemAlloc'd by WebView2
  except
    // the boundary contract: never raise - a refusal marker instead,
    // which no version comparison can ever accept
    Result := '<observation failed>';
  end;
end;

function BuildHeaders(const AContentType: RawUtf8): WideString;
begin
  Result := WideString(Utf8ToSynUnicode(
    'Content-Type: ' + AContentType + #13#10 + 'Cache-Control: no-store'));
end;

function TResourceRequestedHandler.Invoke(sender: IUnknown;
  args: ICoreWebView2WebResourceRequestedEventArgs): HRESULT; stdcall;
var
  request: ICoreWebView2WebResourceRequest;
  response: ICoreWebView2WebResourceResponse;
  uriW: PWideChar;
  uri, logical: RawUtf8;
  asset: TAssetResponse;
  stream: Pointer;
  ok: Boolean;
  headers: WideString;
  status: Integer;
  reason: WideString;
  body: Pointer;
  bodyLen: LongWord;
begin
  Result := S_OK; // never a Pascal exception across the COM boundary
  try
    if (fOwner = nil) or
       (fOwner.fStore = nil) or
       (fOwner.fEnvironment = nil) or
       (args = nil) then
      exit;
    if (args.get_Request(request) <> S_OK) or
       (request = nil) then
      exit;
    uriW := nil;
    if (request.get_Uri(uriW) <> S_OK) or
       (uriW = nil) then
      exit;
    uri := RawUnicodeToUtf8(uriW, StrLenW(uriW));
    CoTaskFree(uriW);
    // filter is pweb://app/* already; re-verify and translate anyway -
    // a wrong scheme/authority is never trusted, only answered 404
    ok := PWebParseAppUri(uri, logical) and
          fOwner.fStore.TryRead(logical, asset);
    if ok then
    begin
      status := 200;
      reason := 'OK';
      headers := BuildHeaders(asset.ContentType);
      body := pointer(asset.Content);
      bodyLen := Length(asset.Content);
    end
    else
    begin
      // deterministic 404: constant body, no path, no reason detail
      status := 404;
      reason := 'Not Found';
      headers := BuildHeaders('text/plain; charset=utf-8');
      body := nil;
      bodyLen := 0;
    end;
    stream := SHCreateMemStream(body, bodyLen);
    if stream = nil then
      exit;
    try
      if ICoreWebView2Environment(fOwner.fEnvironment).
           CreateWebResourceResponse(stream, status, PWideChar(reason),
             PWideChar(headers), response) <> S_OK then
        exit; // the request completes unhandled - fail closed
      if args.put_Response(response) <> S_OK then
        exit; // ditto: unhandled beats undefined
    finally
      IUnknown(stream)._Release; // response holds its own reference
    end;
  except
    // fail closed: the request completes unhandled rather than
    // letting an exception cross the C/COM frame
  end;
end;

{ ---- TWebView2AssetHandler ---- }

constructor TWebView2AssetHandler.Create(AWebView: webview_t;
  const AStore: IAssetStore);
var
  core: ICoreWebView2;
  core2: ICoreWebView2_2;
  env: ICoreWebView2Environment;
  hr: HRESULT;
begin
  inherited Create;
  if AWebView = nil then
    raise EPWebWebView2AssetHandler.Create('webview handle is nil');
  if AStore = nil then
    raise EPWebWebView2AssetHandler.Create('asset store is nil');
  fThreadId := GetCurrentThreadId; // WebView2 objects are STA-affine
  fStore := AStore;
  fController := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if fController = nil then
    raise EPWebWebView2AssetHandler.Create(
      'borrowed browser controller is unavailable');
  // the controller stays borrowed: method calls only, no AddRef
  hr := ICoreWebView2Controller(fController).get_CoreWebView2(core);
  if (hr <> S_OK) or
     (core = nil) then
    raise EPWebWebView2AssetHandler.CreateFmt(
      'get_CoreWebView2 failed: 0x%x', [hr]);
  fCore := core;
  hr := core.QueryInterface(ICoreWebView2_2, core2);
  if (hr <> S_OK) or
     (core2 = nil) then
    raise EPWebWebView2AssetHandler.CreateFmt(
      'ICoreWebView2_2 unavailable: 0x%x', [hr]);
  hr := core2.get_Environment(env);
  core2 := nil;
  if (hr <> S_OK) or
     (env = nil) then
    raise EPWebWebView2AssetHandler.CreateFmt(
      'get_Environment failed: 0x%x', [hr]);
  fEnvironment := env;
  hr := core.AddWebResourceRequestedFilter(
    PWideChar(PWEB_APP_FILTER), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  if hr <> S_OK then
    raise EPWebWebView2AssetHandler.CreateFmt(
      'AddWebResourceRequestedFilter failed: 0x%x', [hr]);
  fFilterAdded := True;
  fHandlerObj := TResourceRequestedHandler.Create(Self);
  fHandler := TResourceRequestedHandler(fHandlerObj);
  hr := core.add_WebResourceRequested(
    TResourceRequestedHandler(fHandlerObj), @fToken);
  if hr <> S_OK then
    raise EPWebWebView2AssetHandler.CreateFmt(
      'add_WebResourceRequested failed: 0x%x', [hr]);
  fAttached := True;
end;

destructor TWebView2AssetHandler.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TWebView2AssetHandler.Detach;
var
  core: ICoreWebView2;
begin
  // CAP-4W teardown order: event removal first, then the filter, then
  // the owned references; the borrowed controller is never touched.
  // WebView2 raw interfaces are apartment-affine: if a misuse calls
  // Detach off the creating GUI thread, skip the native teardown
  // (leaking a registration is fail-safe; a cross-apartment call into
  // a live browser object is undefined behaviour)
  if (fCore <> nil) and
     (GetCurrentThreadId = fThreadId) then
  begin
    core := ICoreWebView2(fCore);
    if fAttached then
    begin
      core.remove_WebResourceRequested(fToken);
      fAttached := False;
    end;
    if fFilterAdded then
    begin
      core.RemoveWebResourceRequestedFilter(
        PWideChar(PWEB_APP_FILTER), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
      fFilterAdded := False;
    end;
    core := nil;
  end;
  if fHandlerObj <> nil then
    TResourceRequestedHandler(fHandlerObj).fOwner := nil;
  fHandlerObj := nil;
  fHandler := nil; // releases the handler object

  fEnvironment := nil;
  fCore := nil;
  fController := nil;
  fStore := nil;
end;

end.
