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

  CAP-8B adds three things to THIS unit rather than to a new one: a
  second transcription of the same COM surface is exactly what drifts,
  so one engine keeps one declaration surface.

    1. Native security headers on every served response. The policy
       itself is PWebNativeSecurityHeaders in pweb.navigation.policy -
       nothing is decided here. MEASURED (findings W4 / W4a): a
       response-header CSP is fully enforced by this engine on the
       pweb custom scheme, and the same page served with a
       deliberately weaker bundle <meta> policy produced a row-for-row
       identical result table, so the bundle cannot relax any row.

    2. TWebView2NavigationGuard - NavigationStarting,
       FrameNavigationStarting, NewWindowRequested and DownloadStarting
       mapped onto PWebClassifyNavigation. The guard decides nothing:
       it translates a native event into a TPWebNavRequest and
       translates the answer back. MEASURED (finding W2): all four
       hooks observe their case BEFORE execution and can refuse it;
       `javascript:`, `file:` and top-level `data:` raise no event at
       all on this engine, which is why the CSP of (1) - not this
       guard - is what stops them.

    3. A private external opener (ShellExecuteExW) gated by
       PWebValidExternalUri, behind a function-pointer seam so a test
       can count its calls. NO navigation callback ever reaches it.
       Ratification R-A.2 is binding: a native navigation callback
       NEVER invokes the OS opener, not even for a "user gesture",
       because MEASURED (finding W3) IsUserInitiated is TRUE for any
       navigation issued in the continuation of a webview_bind promise
       - the ordinary shape of a PWeb page. External opening is a
       capability-authorized runtime invocation, never an inference
       from a flag. IsUserInitiated is still read and counted here,
       DIAGNOSTICALLY, and never branched on.

  The invariant all three serve: a WebView owning the privileged PWeb
  bridge may execute only trusted pweb://app content.

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
  pweb.assets.support,
  pweb.navigation.policy;

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

  EPWebWebView2NavigationGuard = class(Exception);

  { CAP-8B: enforces "only trusted pweb://app content executes in the
    privileged WebView" on the Windows engine.

    Same lifecycle as TWebView2AssetHandler, deliberately: create on the
    GUI thread after webview_create and BEFORE webview_navigate (so the
    very first navigation is already classified), Detach on the GUI
    thread before webview_destroy, borrowed controller never
    AddRef'd, teardown removes the handlers before releasing the owned
    references and disowns the handler objects so a callback can never
    reach a freed guard.

    Every counter below is DIAGNOSTIC. UserActivated in particular is
    recorded and never read back into a decision - see the unit header
    and ratification R-A.3. }
  TWebView2NavigationGuard = class
  private
    fController: Pointer; // borrowed - never AddRef/Release
    fCore: IInterface; // owned ICoreWebView2
    fCore4: IInterface; // owned ICoreWebView2_4 (DownloadStarting)
    fDocHandler: IInterface; // kept alive while bound
    fDocHandlerObj: TObject; // same object, class-typed for detach
    fFrameHandler: IInterface;
    fFrameHandlerObj: TObject;
    fNewWindowHandler: IInterface;
    fNewWindowHandlerObj: TObject;
    fDownloadHandler: IInterface;
    fDownloadHandlerObj: TObject;
    fNavToken: Int64;
    fFrameToken: Int64;
    fNewWindowToken: Int64;
    fDownloadToken: Int64;
    fThreadId: DWord; // GUI thread that created us - COM affinity
    fNavOn: Boolean;
    fFrameOn: Boolean;
    fNewWindowOn: Boolean;
    fDownloadOn: Boolean;
    fSeen: Int64;
    fAllowedTrusted: Int64;
    fCancelled: Int64;
    fUserActivatedSeen: Int64;
    fDenyApplyFailures: Int64;
    // called from the event handlers, always on the GUI thread
    procedure NoteDecision(AAction: TPWebNavAction; AUserActivated: Boolean);
    procedure NoteApplyFailure;
  public
    constructor Create(AWebView: webview_t);
    destructor Destroy; override;
    // idempotent; must run on the GUI thread before webview_destroy
    procedure Detach;
    /// navigation events classified so far
    property Seen: Int64 read fSeen;
    /// events the classifier answered pnaAllowTrusted
    property AllowedTrusted: Int64 read fAllowedTrusted;
    /// events refused - the deny was applied to the engine
    property Cancelled: Int64 read fCancelled;
    /// events the engine reported as user-activated - DIAGNOSTIC ONLY,
    // never an authorization input (ratification R-A.3)
    property UserActivatedSeen: Int64 read fUserActivatedSeen;
    /// denies whose put_Cancel/put_Handled came back failing - a refusal
    // the engine may not have applied. MUST be 0: the runtime matrix
    // requires it, because a lost deny is exactly the silent failure a
    // counter of successful denies cannot see
    property DenyApplyFailures: Int64 read fDenyApplyFailures;
  end;

  /// injectable stand-in for the operating-system opener
  // - TEST SEAM, not a contract: it exists so "called exactly once" and
  // "never called" are counted rather than inferred. It is not a public
  // webview export, not one of the seven interfaces, and crosses no C ABI
  TPWebWv2ExternalOpener = function(const AUri: RawUtf8): Boolean;

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

/// hand ONE approved external URI to the Windows default handler
// - CAP-8B, ratification R-A.4/R-A.8: this is reached ONLY from an
// explicit capability-authorized runtime invocation. No navigation
// callback in this unit calls it, and none ever may - MEASURED
// (finding W3) that no engine flag can tell a real click from a
// navigation issued right after any RPC, so a gesture is not a
// boundary and the answer is an authorization decision instead
// - the gate is PWebValidExternalUri (https: and mailto: only, parsed
// components, bounded length, no control bytes); an URI that does not
// pass never reaches the operating system, and the injected seam is
// consulted INSIDE the gate so a counting fake proves that too
// - the URI crosses as DATA: ShellExecuteExW with lpVerb 'open',
// lpFile the URI and lpParameters nil. No shell string, no command
// line, nothing that any interpreter parses
// - never raises and never logs the URI: False is the whole failure
// report, and the caller's page stays exactly where it was
function PWebWv2OpenExternal(const AUri: RawUtf8): Boolean;

/// substitute the opener above - TESTS ONLY
// - nil restores the real ShellExecuteExW path; returns whatever was
// in force, so a test can put it back deterministically
function PWebWv2SetExternalOpener(
  AOpener: TPWebWv2ExternalOpener): TPWebWv2ExternalOpener;

implementation

{ ---- minimal pinned WebView2 SDK 1.0.1587.40 COM surface ---- }

const
  PWEB_APP_FILTER: WideString = 'pweb://app/*';
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0;
  { WebView2's BOOL is a plain 32-bit int and the engine tests it as
    `!= FALSE`. The transcription below therefore types every BOOL slot
    as Integer rather than a Pascal boolean: the ABI is then exact and
    no compiler's choice of true-representation can be involved. }
  COREWEBVIEW2_TRUE = 1;

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

  { ---- CAP-8B navigation-guard slice of the same pinned surface ----

    Same rules as above: exact IIDs, exact vtable slot order from the
    pinned 1.0.1587.40 header, unused slots as never-called stubs. Every
    interface here was driven through the real SDK header by the audit
    probe test/cap8b/cap8b_audit_win.cpp on this runtime, so the probe's
    measured behaviour - not documentation - is the reference for the
    deny performed on each of them.

    Handler Invoke takes `sender: IUnknown` for the same reason the
    resource handler above does: it removes a forward reference to
    ICoreWebView2 without changing any slot, and the sender is never
    used. }

  ICoreWebView2NavigationStartingEventArgs = interface(IUnknown)
    ['{5b495469-e119-438a-9b18-7604f25f2e49}']
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;
    // DIAGNOSTIC ONLY - counted, reported, never branched on. MEASURED
    // (finding W3) TRUE for a navigation in the continuation of a
    // webview_bind promise, so it separates nothing
    function get_IsUserInitiated(
      out isUserInitiated: Integer): HRESULT; stdcall;
    function Stub_get_IsRedirected: HRESULT; stdcall;
    function Stub_get_RequestHeaders: HRESULT; stdcall;
    function Stub_get_Cancel: HRESULT; stdcall;
    function put_Cancel(cancel: Integer): HRESULT; stdcall;
    function Stub_get_NavigationId: HRESULT; stdcall;
  end;

  ICoreWebView2NavigationStartingEventHandler = interface(IUnknown)
    ['{9adbe429-f36d-432b-9ddc-f8881fbd76e3}']
    function Invoke(sender: IUnknown;
      args: ICoreWebView2NavigationStartingEventArgs): HRESULT; stdcall;
  end;

  ICoreWebView2NewWindowRequestedEventArgs = interface(IUnknown)
    ['{34acb11c-fc37-4418-9132-f9c21d1eafb9}']
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;
    // put_NewWindow stays a never-called stub ON PURPOSE: the deny is
    // put_Handled(TRUE) with NO window supplied, which the audit probe
    // MEASURED to prevent the child window entirely. Handing the engine
    // a window to populate is the opposite of refusing one
    function Stub_put_NewWindow: HRESULT; stdcall;
    function Stub_get_NewWindow: HRESULT; stdcall;
    function put_Handled(handled: Integer): HRESULT; stdcall;
    function Stub_get_Handled: HRESULT; stdcall;
    function get_IsUserInitiated(
      out isUserInitiated: Integer): HRESULT; stdcall;
    function Stub_GetDeferral: HRESULT; stdcall;
    function Stub_get_WindowFeatures: HRESULT; stdcall;
  end;

  ICoreWebView2NewWindowRequestedEventHandler = interface(IUnknown)
    ['{d4c185fe-c81c-4989-97af-2d3fa7ab5651}']
    function Invoke(sender: IUnknown;
      args: ICoreWebView2NewWindowRequestedEventArgs): HRESULT; stdcall;
  end;

  ICoreWebView2DownloadOperation = interface(IUnknown)
    ['{3d6b6cf2-afe1-44c7-a995-c65117714336}']
    function Stub_add_BytesReceivedChanged: HRESULT; stdcall;
    function Stub_remove_BytesReceivedChanged: HRESULT; stdcall;
    function Stub_add_EstimatedEndTimeChanged: HRESULT; stdcall;
    function Stub_remove_EstimatedEndTimeChanged: HRESULT; stdcall;
    function Stub_add_StateChanged: HRESULT; stdcall;
    function Stub_remove_StateChanged: HRESULT; stdcall;
    // the only slot this unit calls; the trailing slots are omitted
    // rather than stubbed, exactly as ICoreWebView2WebResourceResponse
    // above omits all of its own - nothing here derives from it, so no
    // later slot index depends on them
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;
  end;

  ICoreWebView2DownloadStartingEventArgs = interface(IUnknown)
    ['{e99bbe21-43e9-4544-a732-282764eafa60}']
    function get_DownloadOperation(
      out downloadOperation: ICoreWebView2DownloadOperation): HRESULT; stdcall;
    function Stub_get_Cancel: HRESULT; stdcall;
    function put_Cancel(cancel: Integer): HRESULT; stdcall;
    function Stub_get_ResultFilePath: HRESULT; stdcall;
    function Stub_put_ResultFilePath: HRESULT; stdcall;
    function Stub_get_Handled: HRESULT; stdcall;
    // MEASURED: the probe denied a download with put_Cancel(TRUE) AND
    // put_Handled(TRUE); Handled also suppresses the engine's own
    // default download UI, so a refusal is silent as well as effective
    function put_Handled(handled: Integer): HRESULT; stdcall;
    function Stub_GetDeferral: HRESULT; stdcall;
  end;

  ICoreWebView2DownloadStartingEventHandler = interface(IUnknown)
    ['{efedc989-c396-41ca-83f7-07f845a55724}']
    function Invoke(sender: IUnknown;
      args: ICoreWebView2DownloadStartingEventArgs): HRESULT; stdcall;
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
    // CAP-8B turned this slot and the five marked below from
    // never-called stubs into their real declarations; every slot
    // INDEX is unchanged, so the existing CAP-4W/CAP-6b3 callers keep
    // the exact same vtable layout (the get_BrowserVersionString
    // precedent on ICoreWebView2Environment above)
    function add_NavigationStarting(
      eventHandler: ICoreWebView2NavigationStartingEventHandler;
      token: PInt64): HRESULT; stdcall;
    function remove_NavigationStarting(token: Int64): HRESULT; stdcall;
    function Stub_add_ContentLoading: HRESULT; stdcall;
    function Stub_remove_ContentLoading: HRESULT; stdcall;
    function Stub_add_SourceChanged: HRESULT; stdcall;
    function Stub_remove_SourceChanged: HRESULT; stdcall;
    function Stub_add_HistoryChanged: HRESULT; stdcall;
    function Stub_remove_HistoryChanged: HRESULT; stdcall;
    function Stub_add_NavigationCompleted: HRESULT; stdcall;
    function Stub_remove_NavigationCompleted: HRESULT; stdcall;
    // CAP-8B: real declarations, same slot indices. This event is the
    // CHILD-frame one - MEASURED: subframe navigations, a wrong-authority
    // subframe, a trusted subframe, a subframe reload and a meta refresh
    // out of pweb:// all arrived here and were all cancellable
    function add_FrameNavigationStarting(
      eventHandler: ICoreWebView2NavigationStartingEventHandler;
      token: PInt64): HRESULT; stdcall;
    function remove_FrameNavigationStarting(token: Int64): HRESULT; stdcall;
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
    // CAP-8B: real declarations, same slot indices
    function add_NewWindowRequested(
      eventHandler: ICoreWebView2NewWindowRequestedEventHandler;
      token: PInt64): HRESULT; stdcall;
    function remove_NewWindowRequested(token: Int64): HRESULT; stdcall;
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

  { _3 exists here only so _4 can inherit the right number of slots -
    nothing in this unit calls any of its five methods. Skipping it and
    deriving _4 from _2 would silently shift add_DownloadStarting five
    slots earlier, which is the class of mistake this transcription
    style is meant to make impossible. }
  ICoreWebView2_3 = interface(ICoreWebView2_2)
    ['{A0D6DF20-3B92-416D-AA0C-437A9C727857}']
    function Stub_TrySuspend: HRESULT; stdcall;
    function Stub_Resume: HRESULT; stdcall;
    function Stub_get_IsSuspended: HRESULT; stdcall;
    function Stub_SetVirtualHostNameToFolderMapping: HRESULT; stdcall;
    function Stub_ClearVirtualHostNameToFolderMapping: HRESULT; stdcall;
  end;

  ICoreWebView2_4 = interface(ICoreWebView2_3)
    ['{20d02d59-6df2-42dc-bd06-f98a694b1302}']
    function Stub_add_FrameCreated: HRESULT; stdcall;
    function Stub_remove_FrameCreated: HRESULT; stdcall;
    function add_DownloadStarting(
      eventHandler: ICoreWebView2DownloadStartingEventHandler;
      token: PInt64): HRESULT; stdcall;
    function remove_DownloadStarting(token: Int64): HRESULT; stdcall;
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

{ ---- CAP-8B private external opener ---- }

const
  // SEE_MASK_NOASYNC is what makes the call safe from a thread that
  // does not pump messages - the launch completes before the call
  // returns instead of relying on the caller's message loop staying
  // alive. NO_UI keeps a failure silent: a shell error box in front of
  // the trusted page would be a side effect of a refusal
  SEE_MASK_NOASYNC = $00000100;
  SEE_MASK_FLAG_NO_UI = $00000400;
  SW_SHOWNORMAL = 1;
  SHELL_VERB_OPEN: WideString = 'open';

type
  // SHELLEXECUTEINFOW, hand-declared for the same reason
  // SHCreateMemStream above is: this unit imports what it uses and
  // nothing else. C alignment is stated rather than inherited, because
  // the layout is an ABI fact and not a compiler preference
  {$PACKRECORDS C}
  TShellExecuteInfoW = record
    cbSize: DWord;
    fMask: DWord;
    hwnd: PtrUInt;
    lpVerb: PWideChar;
    lpFile: PWideChar;
    lpParameters: PWideChar;
    lpDirectory: PWideChar;
    nShow: Integer;
    hInstApp: PtrUInt;
    lpIDList: Pointer;
    lpClass: PWideChar;
    hkeyClass: PtrUInt;
    dwHotKey: DWord;
    hIconOrMonitor: PtrUInt; // the hIcon/hMonitor union
    hProcess: PtrUInt;
  end;
  {$PACKRECORDS DEFAULT}

function ShellExecuteExW(var lpExecInfo: TShellExecuteInfoW): Integer;
  stdcall; external 'shell32.dll' name 'ShellExecuteExW';

const
  COINIT_APARTMENTTHREADED = $2;
  RPC_E_CHANGED_MODE = HRESULT($80010106);

function CoInitializeEx(pvReserved: Pointer; dwCoInit: DWord): HRESULT;
  stdcall; external 'ole32.dll' name 'CoInitializeEx';
procedure CoUninitialize; stdcall; external 'ole32.dll' name 'CoUninitialize';

var
  // nil means "the real shell"; a test substitutes a counting fake
  Wv2ExternalOpener: TPWebWv2ExternalOpener = nil;

function ShellOpenExternal(const AUri: RawUtf8): Boolean;
var
  info: TShellExecuteInfoW;
  uriW: WideString;
  hrInit: HRESULT;
begin
  Result := False;
  uriW := WideString(Utf8ToSynUnicode(AUri));
  if uriW = '' then
    exit;
  // SEE_MASK_NOASYNC documents COM initialization on the calling thread as
  // a precondition, and this runs on a scheduler WORKER that has none.
  // STA, because ShellExecuteEx is a shell API and the shell is STA-bred.
  // S_FALSE (already initialized) still needs the balancing
  // CoUninitialize; RPC_E_CHANGED_MODE (the thread is MTA already) means
  // COM IS initialized - proceed WITHOUT the balancing call. Any other
  // failure refuses: launching with the documented precondition unmet is
  // exactly the undefined behaviour this block exists to remove.
  hrInit := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  if (hrInit <> S_OK) and
     (hrInit <> S_FALSE) and
     (hrInit <> RPC_E_CHANGED_MODE) then
    exit;
  try
    FillChar(info, SizeOf(info), 0);
    info.cbSize := SizeOf(info);
    info.fMask := SEE_MASK_NOASYNC or SEE_MASK_FLAG_NO_UI;
    info.lpVerb := PWideChar(SHELL_VERB_OPEN);
    // the URI is ONE argument handed to the registered protocol handler;
    // lpParameters stays nil so nothing is appended and no interpreter
    // ever sees a command line
    info.lpFile := PWideChar(uriW);
    info.lpParameters := nil;
    info.lpDirectory := nil;
    info.nShow := SW_SHOWNORMAL;
    Result := ShellExecuteExW(info) <> 0;
  finally
    if hrInit <> RPC_E_CHANGED_MODE then
      CoUninitialize;
  end;
end;

function PWebWv2OpenExternal(const AUri: RawUtf8): Boolean;
begin
  Result := False;
  try
    // ONE gate, and it is the shared classifier's - this unit never
    // forms a second opinion about what an external URI is. The seam is
    // consulted inside the gate, so a counting fake also proves that a
    // refused URI produced no opener activity at all
    if not PWebValidExternalUri(AUri) then
      exit;
    if Assigned(Wv2ExternalOpener) then
      Result := Wv2ExternalOpener(AUri)
    else
      Result := ShellOpenExternal(AUri);
  except
    // an opener failure is a diagnostic, never an exception and never a
    // fallback: the caller's page stays exactly where it was
    Result := False;
  end;
end;

function PWebWv2SetExternalOpener(
  AOpener: TPWebWv2ExternalOpener): TPWebWv2ExternalOpener;
begin
  Result := Wv2ExternalOpener;
  Wv2ExternalOpener := AOpener;
end;

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
  // CAP-8B: the native security headers ride EVERY response this
  // handler produces, the deterministic 404 included. MEASURED
  // (findings W4 / W4a): response-header CSP is fully enforced by this
  // engine on the pweb custom scheme, and the identical page served
  // with a deliberately weaker bundle <meta> policy produced a
  // row-for-row identical result table - policies combine
  // restrictively, so a tampered bundle cannot relax a single row.
  // What goes in them is not decided here: PWebNativeSecurityHeaders is
  // the one shared policy, byte-identical on all four targets
  Result := WideString(Utf8ToSynUnicode(
    'Content-Type: ' + AContentType + #13#10 + 'Cache-Control: no-store' +
    #13#10 + PWebNativeSecurityHeaders));
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

{ ---- CAP-8B navigation guard ---- }

{ The four handlers below are written to one shape on purpose:

    1. Result is S_OK before anything else runs. No Pascal exception
       may cross the COM frame, ever.
    2. The verdict starts at pnaCancel. Every early return, every failed
       COM call and every exception therefore DENIES without any single
       path having to remember to.
    3. The deny is applied in a finally, so it is applied EXACTLY ONCE
       on every path - the exception and early-return ones included -
       and an allowed navigation is the only case where nothing is
       applied at all. A denied navigation is refused before commit, so
       it never replaces the trusted page and there is no fallback
       navigation anywhere in this unit.

  None of them decides anything: each translates its native event into
  a TPWebNavRequest, asks PWebClassifyNavigation, and translates the
  answer back. IsUserInitiated is read where the engine offers it and
  counted, never branched on (ratification R-A.3). And none of them
  calls PWebWv2OpenExternal - ratification R-A.2. }

type
  { NavigationStarting and FrameNavigationStarting share ONE event
    interface, so a single Invoke body cannot tell which registration
    called it. The kind is therefore fixed at construction and this
    class is instantiated twice, which makes it structurally impossible
    for either instance to report the other's kind. }
  TWv2NavigationStartingHandler = class(TInterfacedObject,
    ICoreWebView2NavigationStartingEventHandler)
  private
    fOwner: TWebView2NavigationGuard;
    fKind: TPWebNavKind;
  public
    constructor Create(AOwner: TWebView2NavigationGuard;
      AKind: TPWebNavKind);
    function Invoke(sender: IUnknown;
      args: ICoreWebView2NavigationStartingEventArgs): HRESULT; stdcall;
  end;

  TWv2NewWindowRequestedHandler = class(TInterfacedObject,
    ICoreWebView2NewWindowRequestedEventHandler)
  private
    fOwner: TWebView2NavigationGuard;
  public
    constructor Create(AOwner: TWebView2NavigationGuard);
    function Invoke(sender: IUnknown;
      args: ICoreWebView2NewWindowRequestedEventArgs): HRESULT; stdcall;
  end;

  TWv2DownloadStartingHandler = class(TInterfacedObject,
    ICoreWebView2DownloadStartingEventHandler)
  private
    fOwner: TWebView2NavigationGuard;
  public
    constructor Create(AOwner: TWebView2NavigationGuard);
    function Invoke(sender: IUnknown;
      args: ICoreWebView2DownloadStartingEventArgs): HRESULT; stdcall;
  end;

constructor TWv2NavigationStartingHandler.Create(
  AOwner: TWebView2NavigationGuard; AKind: TPWebNavKind);
begin
  inherited Create;
  fOwner := AOwner;
  fKind := AKind;
end;

function TWv2NavigationStartingHandler.Invoke(sender: IUnknown;
  args: ICoreWebView2NavigationStartingEventArgs): HRESULT; stdcall;
var
  req: TPWebNavRequest;
  action: TPWebNavAction;
  uriW: PWideChar;
  activated: Integer;
  applyFailed: Boolean;
begin
  Result := S_OK;
  action := pnaCancel; // fail closed before a single byte is read
  applyFailed := False;
  req.Uri := '';
  req.Kind := fKind;
  req.UserActivated := False;
  try
    try
      if args = nil then
        exit;
      uriW := nil;
      if (args.get_Uri(uriW) = S_OK) and
         (uriW <> nil) then
      begin
        req.Uri := RawUnicodeToUtf8(uriW, StrLenW(uriW));
        CoTaskFree(uriW); // the string is CoTaskMemAlloc'd by WebView2
      end;
      // an unreadable URI stays '', which the classifier refuses: a
      // navigation nobody can name is not one anybody allows
      activated := 0;
      if args.get_IsUserInitiated(activated) = S_OK then
        req.UserActivated := activated <> 0;
      action := PWebClassifyNavigation(req);
    finally
      // MEASURED: put_Cancel(TRUE) here refuses the navigation before
      // it executes, on every case the coverage table lists. A failing
      // put_Cancel is a refusal the engine may not have applied - it is
      // COUNTED, and the runtime matrix requires that count to be 0,
      // because losing a deny silently is the one failure a counter of
      // successful denies cannot see
      if (args <> nil) and
         (action = pnaCancel) then
        applyFailed := args.put_Cancel(COREWEBVIEW2_TRUE) <> S_OK;
      // a disowned handler (post-Detach) has already denied above and
      // simply has nowhere to count it
      if fOwner <> nil then
      begin
        fOwner.NoteDecision(action, req.UserActivated);
        if applyFailed then
          fOwner.NoteApplyFailure;
      end;
    end;
  except
    // the barrier: an exception anywhere above already left action at
    // pnaCancel and the finally already applied it
  end;
end;

constructor TWv2NewWindowRequestedHandler.Create(
  AOwner: TWebView2NavigationGuard);
begin
  inherited Create;
  fOwner := AOwner;
end;

function TWv2NewWindowRequestedHandler.Invoke(sender: IUnknown;
  args: ICoreWebView2NewWindowRequestedEventArgs): HRESULT; stdcall;
var
  req: TPWebNavRequest;
  action: TPWebNavAction;
  uriW: PWideChar;
  activated: Integer;
  applyFailed: Boolean;
begin
  Result := S_OK;
  action := pnaCancel;
  applyFailed := False;
  req.Uri := '';
  req.Kind := pnkNewWindow;
  req.UserActivated := False;
  try
    try
      if args = nil then
        exit;
      uriW := nil;
      if (args.get_Uri(uriW) = S_OK) and
         (uriW <> nil) then
      begin
        req.Uri := RawUnicodeToUtf8(uriW, StrLenW(uriW));
        CoTaskFree(uriW);
      end;
      activated := 0;
      if args.get_IsUserInitiated(activated) = S_OK then
        req.UserActivated := activated <> 0;
      // the answer for pnkNewWindow is fixed, and it is still ASKED
      // for: one table, in one file, for all four targets
      action := PWebClassifyNavigation(req);
    finally
      // Handled=TRUE with NO NewWindow supplied - MEASURED to prevent
      // the child window entirely. This args interface has no
      // put_Cancel, and handing the engine a window to populate would
      // be the opposite of refusing one. put_Handled IS the deny here,
      // so its failure is counted like a lost put_Cancel
      if (args <> nil) and
         (action = pnaCancel) then
        applyFailed := args.put_Handled(COREWEBVIEW2_TRUE) <> S_OK;
      if fOwner <> nil then
      begin
        fOwner.NoteDecision(action, req.UserActivated);
        if applyFailed then
          fOwner.NoteApplyFailure;
      end;
    end;
  except
  end;
end;

constructor TWv2DownloadStartingHandler.Create(
  AOwner: TWebView2NavigationGuard);
begin
  inherited Create;
  fOwner := AOwner;
end;

function TWv2DownloadStartingHandler.Invoke(sender: IUnknown;
  args: ICoreWebView2DownloadStartingEventArgs): HRESULT; stdcall;
var
  req: TPWebNavRequest;
  action: TPWebNavAction;
  op: ICoreWebView2DownloadOperation;
  uriW: PWideChar;
  applyFailed: Boolean;
begin
  Result := S_OK;
  action := pnaCancel;
  applyFailed := False;
  req.Uri := '';
  req.Kind := pnkDownload;
  // this args interface exposes NO activation flag at all. False here
  // means "the engine was not asked", not "the user did not act" - and
  // since nothing branches on it, the distinction costs nothing
  req.UserActivated := False;
  try
    try
      if args = nil then
        exit;
      op := nil;
      if (args.get_DownloadOperation(op) = S_OK) and
         (op <> nil) then
      begin
        uriW := nil;
        if (op.get_Uri(uriW) = S_OK) and
           (uriW <> nil) then
        begin
          req.Uri := RawUnicodeToUtf8(uriW, StrLenW(uriW));
          CoTaskFree(uriW);
        end;
      end;
      action := PWebClassifyNavigation(req);
    finally
      // Cancel refuses the transfer; Handled additionally suppresses the
      // engine's own download UI, so the refusal is silent as well as
      // effective (both were exercised by the audit probe). Either call
      // failing is counted: a lost Cancel is a lost deny outright, and a
      // lost Handled leaves engine UI a refusal promised to suppress
      if (args <> nil) and
         (action = pnaCancel) then
      begin
        if args.put_Cancel(COREWEBVIEW2_TRUE) <> S_OK then
          applyFailed := True;
        if args.put_Handled(COREWEBVIEW2_TRUE) <> S_OK then
          applyFailed := True;
      end;
      if fOwner <> nil then
      begin
        fOwner.NoteDecision(action, req.UserActivated);
        if applyFailed then
          fOwner.NoteApplyFailure;
      end;
    end;
  except
  end;
end;

{ ---- TWebView2NavigationGuard ---- }

constructor TWebView2NavigationGuard.Create(AWebView: webview_t);
var
  core: ICoreWebView2;
  core4: ICoreWebView2_4;
  hr: HRESULT;
begin
  inherited Create;
  if AWebView = nil then
    raise EPWebWebView2NavigationGuard.Create('webview handle is nil');
  fThreadId := GetCurrentThreadId; // WebView2 objects are STA-affine
  fController := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if fController = nil then
    raise EPWebWebView2NavigationGuard.Create(
      'borrowed browser controller is unavailable');
  // the controller stays borrowed: method calls only, no AddRef -
  // the same CAP-4W seam TWebView2AssetHandler walks
  hr := ICoreWebView2Controller(fController).get_CoreWebView2(core);
  if (hr <> S_OK) or
     (core = nil) then
    raise EPWebWebView2NavigationGuard.CreateFmt(
      'get_CoreWebView2 failed: 0x%x', [hr]);
  fCore := core;

  // a partly installed guard is not a guard: every add_ below raises on
  // failure, and the destructor FPC runs for a failed constructor calls
  // Detach, which removes whatever did register
  fDocHandlerObj := TWv2NavigationStartingHandler.Create(Self, pnkDocument);
  fDocHandler := TWv2NavigationStartingHandler(fDocHandlerObj);
  hr := core.add_NavigationStarting(
    TWv2NavigationStartingHandler(fDocHandlerObj), @fNavToken);
  if hr <> S_OK then
    raise EPWebWebView2NavigationGuard.CreateFmt(
      'add_NavigationStarting failed: 0x%x', [hr]);
  fNavOn := True;

  fFrameHandlerObj := TWv2NavigationStartingHandler.Create(Self, pnkSubframe);
  fFrameHandler := TWv2NavigationStartingHandler(fFrameHandlerObj);
  hr := core.add_FrameNavigationStarting(
    TWv2NavigationStartingHandler(fFrameHandlerObj), @fFrameToken);
  if hr <> S_OK then
    raise EPWebWebView2NavigationGuard.CreateFmt(
      'add_FrameNavigationStarting failed: 0x%x', [hr]);
  fFrameOn := True;

  fNewWindowHandlerObj := TWv2NewWindowRequestedHandler.Create(Self);
  fNewWindowHandler := TWv2NewWindowRequestedHandler(fNewWindowHandlerObj);
  hr := core.add_NewWindowRequested(
    TWv2NewWindowRequestedHandler(fNewWindowHandlerObj), @fNewWindowToken);
  if hr <> S_OK then
    raise EPWebWebView2NavigationGuard.CreateFmt(
      'add_NewWindowRequested failed: 0x%x', [hr]);
  fNewWindowOn := True;

  // ICoreWebView2_4 is NOT optional here. It shipped long before
  // PWEB_WV2_MIN_BUILD (pweb.platform.webview2.runtime), which the
  // CAP-6b0 detector already refuses to start below, so its absence is
  // a broken runtime rather than an old one - and a guard without the
  // download hook is a guard with a hole. Refusing to construct is the
  // fail-closed answer; degrading quietly is not
  hr := core.QueryInterface(ICoreWebView2_4, core4);
  if (hr <> S_OK) or
     (core4 = nil) then
    raise EPWebWebView2NavigationGuard.CreateFmt(
      'ICoreWebView2_4 unavailable: 0x%x', [hr]);
  fCore4 := core4;
  fDownloadHandlerObj := TWv2DownloadStartingHandler.Create(Self);
  fDownloadHandler := TWv2DownloadStartingHandler(fDownloadHandlerObj);
  hr := core4.add_DownloadStarting(
    TWv2DownloadStartingHandler(fDownloadHandlerObj), @fDownloadToken);
  if hr <> S_OK then
    raise EPWebWebView2NavigationGuard.CreateFmt(
      'add_DownloadStarting failed: 0x%x', [hr]);
  fDownloadOn := True;
end;

destructor TWebView2NavigationGuard.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TWebView2NavigationGuard.NoteDecision(AAction: TPWebNavAction;
  AUserActivated: Boolean);
begin
  // all four events arrive on the GUI thread this object was created
  // on, so plain increments are correct here and no interlocking is
  // needed; these are diagnostics and never feed a decision
  inc(fSeen);
  if AAction = pnaAllowTrusted then
    inc(fAllowedTrusted)
  else
    inc(fCancelled);
  if AUserActivated then
    inc(fUserActivatedSeen);
end;

procedure TWebView2NavigationGuard.NoteApplyFailure;
begin
  // same GUI-thread affinity as NoteDecision; a plain increment suffices
  inc(fDenyApplyFailures);
end;

procedure TWebView2NavigationGuard.Detach;
var
  core: ICoreWebView2;
  onThread: Boolean;
begin
  // teardown order mirrors TWebView2AssetHandler and the audit probe:
  // remove every registration first, in reverse of the order it was
  // made, and only then release the owned references. The borrowed
  // controller is never touched. WebView2 raw interfaces are
  // apartment-affine, so a Detach off the creating GUI thread skips the
  // native teardown: leaking a registration is fail-safe, while a
  // cross-apartment call into a live browser object is undefined
  onThread := GetCurrentThreadId = fThreadId;
  if (fCore <> nil) and
     onThread then
  begin
    core := ICoreWebView2(fCore);
    if fDownloadOn and
       (fCore4 <> nil) then
    begin
      ICoreWebView2_4(fCore4).remove_DownloadStarting(fDownloadToken);
      fDownloadOn := False;
    end;
    if fNewWindowOn then
    begin
      core.remove_NewWindowRequested(fNewWindowToken);
      fNewWindowOn := False;
    end;
    if fFrameOn then
    begin
      core.remove_FrameNavigationStarting(fFrameToken);
      fFrameOn := False;
    end;
    if fNavOn then
    begin
      core.remove_NavigationStarting(fNavToken);
      fNavOn := False;
    end;
    core := nil;
  end;
  // disown BEFORE releasing: WebView2 holds its own reference to each
  // handler, so an object may outlive this guard. A disowned handler
  // still denies (its verdict starts at pnaCancel) and simply has no
  // owner to count into - it can never reach a freed guard.
  //
  // KNOWN RESIDUAL for the off-thread MISUSE path only: the disown is one
  // atomic pointer store, but an event handler mid-Invoke on the GUI
  // thread may already have read fOwner; if the misusing thread then also
  // FREES this guard inside that window, NoteDecision touches freed
  // memory. Closing that would need a rendezvous with the GUI thread,
  // which a leak-don't-crash fallback cannot perform. The supported
  // contract stands: Detach runs on the GUI thread before
  // webview_destroy, where events and Detach are serialized by the one
  // thread and the race cannot exist - both hosts obey it.
  if fDocHandlerObj <> nil then
    TWv2NavigationStartingHandler(fDocHandlerObj).fOwner := nil;
  if fFrameHandlerObj <> nil then
    TWv2NavigationStartingHandler(fFrameHandlerObj).fOwner := nil;
  if fNewWindowHandlerObj <> nil then
    TWv2NewWindowRequestedHandler(fNewWindowHandlerObj).fOwner := nil;
  if fDownloadHandlerObj <> nil then
    TWv2DownloadStartingHandler(fDownloadHandlerObj).fOwner := nil;
  fDocHandlerObj := nil;
  fFrameHandlerObj := nil;
  fNewWindowHandlerObj := nil;
  fDownloadHandlerObj := nil;
  if onThread then
  begin
    // on the creating thread the ordinary releases are correct: the
    // registrations are gone, so WebView2 drops its handler references
    // and ours may be the last
    fDocHandler := nil;
    fFrameHandler := nil;
    fNewWindowHandler := nil;
    fDownloadHandler := nil;
    fCore4 := nil;
    fCore := nil;
  end
  else
  begin
    // OFF the creating thread every Release is as forbidden as the
    // remove_* calls above: fCore/fCore4 are apartment-affine browser
    // objects, and the handlers are still registered (nothing removed
    // them), so even our own objects must not be dropped to a refcount
    // the engine no longer backs. Leak the lot - pointer-nil with no
    // Release - which is the same fail-safe the skipped native teardown
    // already chose
    Pointer(fDocHandler) := nil;
    Pointer(fFrameHandler) := nil;
    Pointer(fNewWindowHandler) := nil;
    Pointer(fDownloadHandler) := nil;
    Pointer(fCore4) := nil;
    Pointer(fCore) := nil;
  end;
  fController := nil;
end;

end.
