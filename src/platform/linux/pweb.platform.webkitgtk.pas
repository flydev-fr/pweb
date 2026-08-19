{
  pweb.platform.webkitgtk - production pweb://app resource handler
  (CAP-7L) and privileged-navigation guard (CAP-8B) for the
  Linux/WebKitGTK engine.

  The Linux sibling of pweb.platform.webview2: same surface, same
  request flow, same fail-closed rules - a different engine underneath.

  Attaches a custom URI scheme handler for pweb://app/* onto an existing
  webview through the seam upstream ALREADY exposes, so deps/webview
  carries no Linux patch and the public C ABI stays at exactly 17
  exports:

    webview_get_native_handle(w, BROWSER_CONTROLLER)  -> WebKitWebView*
      -> webkit_web_view_get_context                  -> WebKitWebContext*
      -> webkit_web_context_get_security_manager
           register_uri_scheme_as_secure('pweb')
           register_uri_scheme_as_cors_enabled('pweb')
      -> webkit_web_context_register_uri_scheme('pweb', ...)

  MEASURED at the pinned revision: webview_create builds the
  WebKitWebView and navigates nowhere, so all of the above fits between
  webview_create and the first webview_navigate - which is exactly where
  the examples attach it. The resulting classification is the same one
  Windows gets from HasAuthorityComponent + TreatAsSecure: JS on
  pweb://app/ reports protocol "pweb:", host "app", origin "pweb://app"
  and isSecureContext true.

  Request flow (all of it on the GTK main thread):

    WebKitURISchemeRequest
      -> PWebParseAppUri  (scheme+authority check, single decode,
                           root mapping, canonical validation)
      -> IAssetStore.TryRead
      -> finish_with_response(stream, length, content type, native
                              security headers)   or a constant error
                              finish

  THE URI IS THE WHOLE URI. Only webkit_uri_scheme_request_get_uri is
  ever consulted. webkit_uri_scheme_request_get_path is FORBIDDEN here
  and MEASURED to be unsafe: for 'pweb://evil/x' it returns '/x',
  discarding the authority, which would hand a wrong-host request to
  IAssetStore as if it were a valid path. Only PWebParseAppUri checks
  the authority, and it is given the untouched URI.

  Response ownership is GIO's: the body is copied onto the GLib heap and
  handed to g_memory_input_stream_new_from_data with g_free as the
  destroy notify, so no RawByteString, Pascal temporary or callback
  stack memory is ever referenced after the callback returns.

  Detach rules, and why they differ from the Windows sibling:
    - WebKitGTK 4.1 has NO public API to unregister a URI scheme, so
      Detach cannot remove the handler. Instead the registration record
      is DISOWNED: it is a GLib-owned heap cell whose Owner field is
      cleared, and the callback answers a constant error finish whenever
      it finds no owner. No callback can ever reach a destroyed handler.
    - The record itself is freed by the GDestroyNotify GLib invokes when
      the context is finalised or the scheme is re-registered (upstream
      webviews share the default WebKitWebContext, so a later
      create/attach cycle re-registers and frees the previous cell).
    - Detach is idempotent and safe from any thread: the disown is one
      interlocked pointer-width store.

  No Pascal exception ever crosses the C callback boundary, and no
  refusal reason or physical path is ever exposed to the page: every
  refusal is the same constant error.

  ---------------------------------------------------------------------
  CAP-8B: what may EXECUTE in the privileged WebView
  ---------------------------------------------------------------------

  The handler above answers what pweb://app/* may READ. CAP-8B adds the
  other half, because a WebView owning the privileged PWeb bridge may
  execute only trusted pweb://app content, and until now nothing on this
  engine enforced that. Three additions, all private:

  1. NATIVE SECURITY HEADERS on every asset response.
     webkit_uri_scheme_request_finish carries NO headers at all, so the
     completion moved to webkit_uri_scheme_request_finish_with_response
     over a WebKitURISchemeResponse whose libsoup-3.0 SoupMessageHeaders
     carry PWebNativeSecurityHeaders. This is not a preference: it is
     the only public path, and CAP-8B MEASURED it delivering an ENFORCED
     policy on this engine, row for row identical to Windows and macOS,
     with a deliberately weaker bundle <meta> policy unable to relax a
     single row (findings L4).

     The header set is decided by pweb.navigation.policy and merely
     TRANSPORTED here, exactly as the Windows sibling transports it - a
     second spelling of the CSP would be a second policy. If the set
     cannot be attached, the asset is REFUSED rather than served bare:
     an unprotected trusted document is precisely what the policy
     exists to prevent, and frame-src 'none' in particular is
     load-bearing rather than decorative on this engine (see 2).

  2. A NAVIGATION GUARD on "decide-policy" and "create".
     Upstream connects only "destroy" on its own window, so both signals
     are free. Every decision is translated into a TPWebNavRequest,
     answered by PWebClassifyNavigation - the one shared classifier, no
     engine type in its signature and no second policy table here - and
     translated back into webkit_policy_decision_use / _ignore.

     Three properties this engine forces, all MEASURED:
       - An UNDECIDED policy DEFAULTS TO ALLOW, so all three decision
         types are handled explicitly and the handler returns TRUE
         whenever it decided: the default handler must never get a
         second opinion, because its opinion is always "allow".
       - FRAME DISCRIMINATION IS ABSENT (findings L2): no accessor
         identifies the frame BEING NAVIGATED in a NAVIGATION_ACTION
         decision - webkit_response_policy_decision_is_main_frame_document
         does not even resolve on the installed library, and
         WebKitFrame lives in the web-process extension API. So a
         navigation action is reported as pnkDocument, the strictest
         interpretation available, and CSP frame-src 'none' is what
         removes subframes on Linux.
       - There is NO dedicated download hook a page can reach
         (findings L5): an undisplayable response arrives at
         decide-policy, and only webkit_policy_decision_download turns
         it into a download at all. An unsupported MIME type is
         therefore the download SHAPE here and is classified pnkDownload
         - refused with _ignore, never converted.

     User activation is recorded and carried, and is DIAGNOSTIC ONLY:
     CAP-8B MEASURED webkit_navigation_action_is_user_gesture reporting
     true for a plain script navigation performed in the continuation of
     a binding promise - the ordinary shape of a PWeb page - exactly as
     WebView2's flag does (findings L3). The classifier is required to
     ignore it and its corpus test proves that by inverting the flag
     over every row.

  3. A PRIVATE EXTERNAL OPENER, reached ONLY by an explicit
     capability-authorized runtime invocation and NEVER by a navigation
     callback (ratification R-A.2). Every raw external navigation inside
     the privileged WebView is cancelled, https: and mailto: included,
     because a gesture is not a security boundary on any of the four
     measured engines. g_app_info_launch_default_for_uri hands the URI
     to the desktop as DATA: no shell string, no /bin/sh, no subprocess
     interpolation. libgio-2.0 was already a declared external of this
     unit, so nothing new is shipped.

  Guard teardown follows the asset handler's model for the same reason:
  the callback must never be able to reach a freed object. The cell it
  is given is GLib-owned and reference counted (one reference per
  connected closure, plus the guard's own); Detach is a single
  interlocked pointer-width store that DISOWNS it, after which every
  decision is refused. The signals are deliberately NOT disconnected:
  that would need a WebKitWebView this object cannot prove is still
  alive, and a disown needs nothing at all.

  The WebKitGTK/GLib declarations below are hand-written PRIVATE
  externals (ratified at CAP-7L checkpoint 1 - no second chet binding,
  no C shim library). They are guarded by two gates that must both pass
  before this unit is trusted:
    - test/cap7l/abi_probe_gtk.c / .pas, a paired C/Pascal ABI probe in
      the shape of test/core/abi_probe.*, proving every scalar in these
      signatures has the same size and signedness on both sides;
    - test/cap7l/check_abi.sh, which additionally asserts via nm -D that
      every symbol named below is exported by the exact distro .so it is
      declared against.
}
unit pweb.platform.webkitgtk;

{$mode ObjFPC}{$H+}

{$ifndef LINUX}
  {$MESSAGE Error 'pweb.platform.webkitgtk is the Linux engine adapter'}
{$endif LINUX}
{$ifndef CPUX86_64}
  {$MESSAGE Error 'CAP-7L is ratified for x86_64 only (no ARM64, no i386)'}
{$endif CPUX86_64}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.assets.intf,
  pweb.assets.support,
  // CAP-8B: the ONE classifier and the ONE header set. This adapter
  // translates native events into its request record and its answer back
  // into WebKit calls; it decides nothing of its own.
  pweb.navigation.policy;

type
  { The C scalar contract of the hand-declared WebKitGTK/GLib externals
    in the implementation section.

    These live in the interface for ONE reason: test/cap7l/abi_probe_gtk
    must measure the very types this unit declares, not a copy of them.
    A probe over duplicated aliases would prove nothing. Nothing else may
    use them - the engine surface itself stays private. }
  TGQuark = LongWord; // guint32
  TGSize = PtrUInt; // gsize
  TGSSize = PtrInt; // gssize
  TGInt = LongInt; // gint
  TGInt64 = Int64; // gint64
  TGBoolean = LongInt; // gboolean (a gint, NOT a C99 bool)
  TGUInt = LongWord; // guint
  TGULong = PtrUInt; // gulong
  { The three C enums the CAP-8B signatures carry. Declared as LongWord
    because gcc types an enum with no negative enumerator as unsigned int
    - the same rule that produces the two documented signedness deltas on
    the core probe - and every value below is non-negative. The paired
    probe measures each one rather than trusting that sentence. }
  TGConnectFlags = LongWord; // GConnectFlags
  TWebKitPolicyDecisionType = LongWord; // WebKitPolicyDecisionType
  TWebKitNavigationType = LongWord; // WebKitNavigationType
  TSoupMessageHeadersType = LongWord; // SoupMessageHeadersType

  /// void (*GDestroyNotify) (gpointer data)
  TGDestroyNotify = procedure(data: Pointer); cdecl;

  /// void (*GClosureNotify) (gpointer data, GClosure* closure)
  // - NOT a GDestroyNotify: g_signal_connect_data's destroy notify takes
  // the dying closure as a second argument, and calling one through the
  // other's shape would read a register that was never set
  TGClosureNotify = procedure(data: Pointer; closure: Pointer); cdecl;

  /// void (*GCallback) (void)
  // - the erased shape g_signal_connect_data takes; the G_CALLBACK() macro
  // is exactly this cast, and the real signatures below are what the unit
  // holds its handlers in before erasing them
  TGCallback = procedure; cdecl;

  /// void (*WebKitURISchemeRequestCallback) (WebKitURISchemeRequest*,
  ///                                         gpointer user_data)
  TWebKitUriSchemeRequestCallback = procedure(request: Pointer;
    user_data: Pointer); cdecl;

  /// gboolean (*) (WebKitWebView*, WebKitPolicyDecision*,
  ///               WebKitPolicyDecisionType, gpointer user_data)
  // - the "decide-policy" signal handler. Returning TRUE means WE decided;
  // returning FALSE hands the decision to the default handler, whose
  // answer is always "allow"
  TWebKitDecidePolicyCallback = function(web_view: Pointer;
    decision: Pointer; decision_type: TWebKitPolicyDecisionType;
    user_data: Pointer): TGBoolean; cdecl;

  /// GtkWidget* (*) (WebKitWebView*, WebKitNavigationAction*,
  ///                 gpointer user_data)
  // - the "create" signal handler; NULL means no widget, so no child view,
  // no window and no load
  TWebKitCreateCallback = function(web_view: Pointer;
    navigation_action: Pointer; user_data: Pointer): Pointer; cdecl;

  EPWebWebKitGtkAssetHandler = class(Exception);
  EPWebWebKitGtkNavigationGuard = class(Exception);

  { Serves IAssetStore content on pweb://app/* for one webview.
    Create on the GUI thread after webview_create and BEFORE
    webview_navigate; Detach before webview_destroy (Destroy calls
    Detach as a guard). }
  TWebKitGtkAssetHandler = class
  private
    fStore: IAssetStore;
    fContext: Pointer; // borrowed WebKitWebContext - never unref'd
    fRegistration: Pointer; // PPWebGtkRegistration, owned by GLib
    fThreadId: TThreadID; // GUI thread that created us
    fAttached: Boolean;
  public
    constructor Create(AWebView: webview_t; const AStore: IAssetStore);
    destructor Destroy; override;
    // idempotent; disowns the scheme callback so it can never reach a
    // destroyed handler
    procedure Detach;
  end;

  { CAP-8B: enforces "only trusted pweb://app content may execute here" on
    one WebKitWebView.

    Create on the GUI thread after webview_create and BEFORE
    webview_navigate - the same window the asset handler is attached in,
    and for the same reason: a guard installed after the first navigation
    would be a guard that let the first document through. Detach before
    webview_destroy (Destroy calls Detach as a guard).

    The counters are evidence, not policy. AllowedCount and CancelledCount
    are what a runtime gate reports instead of inferring a verdict from
    "the page still rendered"; LastUserActivated and LastNavigationType are
    the two DIAGNOSTIC values this engine exposes, recorded so the
    cross-target evidence corpus can carry them and never read by any
    decision (findings L3). }
  TWebKitGtkNavigationGuard = class
  private
    fCell: Pointer; // PPWebGtkNavCell, GLib-owned and reference counted
    fThreadId: TThreadID; // GUI thread that created us
    fAttached: Boolean;
    // the counters as they stood at Detach, so a detached guard still
    // answers honestly instead of answering zero
    fAllowed: PtrInt;
    fCancelled: PtrInt;
    fUserActivated: Boolean;
    fNavigationType: PtrUInt;
    function GetAllowed: PtrInt;
    function GetCancelled: PtrInt;
    function GetUserActivated: Boolean;
    function GetNavigationType: PtrUInt;
  public
    constructor Create(AWebView: webview_t);
    destructor Destroy; override;
    // idempotent; disowns the signal callbacks so they can never reach a
    // destroyed guard, and refuses every decision from that point on
    procedure Detach;
    /// navigations allowed as trusted application content
    property AllowedCount: PtrInt read GetAllowed;
    /// navigations, new windows, downloads and responses refused
    property CancelledCount: PtrInt read GetCancelled;
    /// DIAGNOSTIC ONLY - webkit_navigation_action_is_user_gesture of the
    // last navigation action seen, never an authorization input
    property LastUserActivated: Boolean read GetUserActivated;
    /// DIAGNOSTIC ONLY - WebKitNavigationType of the last navigation action
    property LastNavigationType: PtrUInt read GetNavigationType;
  end;

  { The seam that makes "the opener was called exactly once" / "the opener
    was never called" deterministic in CI.

    A plain Pascal function pointer on purpose: it crosses no C frame, so
    it is not part of the hand-declared engine surface and does not appear
    in the paired ABI probe. It is NOT a kernel interface, not a public
    webview export and not part of any frozen contract. }
  TPWebGtkExternalOpener = function(const AUri: RawUtf8): Boolean;

/// the adapter's ENTIRE request decision, in one place.
// The scheme callback calls exactly this, and so do the gates - so
// "the Linux adapter reaches the same verdict as Windows through the
// same routine" is a property the tests actually exercise rather than
// one they restate. Full-URI validation through PWebParseAppUri (never
// a path fragment, never a rebuilt URI), then exactly one
// IAssetStore.TryRead. Fail-closed and never raises.
function PWebGtkResolveAssetUri(const AUri: RawUtf8;
  const AStore: IAssetStore; out Asset: TAssetResponse): Boolean;

/// the Content-Type the adapter serves for a resolved asset
// - the store's deterministic type, with a fallback that can never be
// the empty string (an empty Content-Type would let the engine sniff)
function PWebGtkContentType(const Asset: TAssetResponse): RawUtf8;

/// copy an asset body onto the GLib heap exactly the way the scheme
/// callback does
// - nothing the page receives may point at a RawByteString, a Pascal
// temporary or callback stack memory; this is the copy that makes that
// true, and the response-lifetime regression drives it directly
// - a zero-byte asset still gets a real, non-nil allocation (GLib
// returns nil for a zero-size request) with an honest length of 0
// - returns False only on allocation failure, leaving ABody nil
function PWebGtkCopyBody(const AContent: RawByteString;
  out ABody: Pointer; out ASize: PtrInt): Boolean;

/// release a body from PWebGtkCopyBody that was never handed to GIO
procedure PWebGtkReleaseBody(ABody: Pointer);

/// why a GTK/WebKitGTK WebView cannot be created here, or '' if nothing
/// is knowably wrong before trying
// - the Linux counterpart of the Windows CheckWebView2RuntimeUsable
//   call site, and it exists for a MEASURED reason: with no display,
//   webview_create returns nil and the frozen raw layer reports
//   'missing WebView2 runtime or window creation failure' - a Windows
//   runtime name, on Linux, for a cause that is not it. This names the
//   real one before that can happen.
// - deliberately NOT a gtk_init_check() probe: that would initialise GTK
//   ahead of webview_create and duplicate the work it already does. Only
//   the one condition that is knowable for free is reported; anything
//   else is left to webview_create rather than guessed at.
// - a missing libwebkit2gtk/libgtk is NOT diagnosed here and cannot be:
//   the dynamic loader fails before main(), naming the exact soname
function PWebGtkDisplayUnavailableReason: RawUtf8;

/// hand ONE capability-authorized URI to the desktop's default handler
// - NEVER reachable from a navigation callback (ratification R-A.2): every
// raw external navigation inside the privileged WebView is cancelled with
// no side effect at all, and this is the separate, explicitly authorized
// runtime path the shared release host wires to the external.open
// capability
// - PWebValidExternalUri is the gate and the ONLY gate: https: and mailto:
// on parsed components, bounded length, no control bytes. This function
// re-checks it rather than trusting its caller, because a private opener
// that trusts a string is a private opener that will one day be called
// with a different one
// - the URI is passed as DATA to g_app_info_launch_default_for_uri: no
// shell string, no /bin/sh, no subprocess interpolation, nothing parsed by
// anything but the desktop's own handler registry
// - never raises, never logs the URI, and returns False on refusal, on
// launch failure and on a GError alike: the caller learns that it did not
// happen, and the page learns nothing
function PWebGtkOpenExternalUri(const AUri: RawUtf8): Boolean;

/// install a test double for the OS opener; returns the previous one
// - nil restores the real g_app_info_launch_default_for_uri path
// - the URI gate above runs BEFORE the seam, so a fake cannot be used to
// smuggle an unapproved scheme past it either
function PWebGtkSetExternalOpener(
  AOpener: TPWebGtkExternalOpener): TPWebGtkExternalOpener;

implementation

{ ---- minimal private WebKitGTK / GLib surface ----

  Every declaration below names the exact distro soname it comes from,
  not a bare 'libfoo.so' development link: the deployed application must
  bind the same runtime library the build gated, and MEASURED, FPC
  records these names verbatim as DT_NEEDED. }

const
  WEBKITGTK_LIB = 'libwebkit2gtk-4.1.so.0';
  GIO_LIB = 'libgio-2.0.so.0';
  GOBJECT_LIB = 'libgobject-2.0.so.0';
  GLIB_LIB = 'libglib-2.0.so.0';
  { CAP-8B. NOT a new shipped dependency and not a new engine: WebKitGTK
    API 4.1 IS the libsoup3 flavour of the API - this process already has
    libsoup-3.0.so.0 mapped through libwebkit2gtk-4.1 - and
    SoupMessageHeaders is the only type
    webkit_uri_scheme_response_set_http_headers accepts. Response headers
    are unreachable on this engine without it (findings L4, ratified D4). }
  SOUP_LIB = 'libsoup-3.0.so.0';

// The scalar aliases these signatures use (TGQuark, TGSize, TGSSize,
// TGInt, TGInt64, TGDestroyNotify, TWebKitUriSchemeRequestCallback) are
// declared in the interface so the paired probe measures them directly.

// --- libwebkit2gtk-4.1.so.0 ---

function webkit_web_view_get_context(web_view: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_web_view_get_context';

function webkit_web_context_get_security_manager(
  context: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_web_context_get_security_manager';

procedure webkit_security_manager_register_uri_scheme_as_secure(
  security_manager: Pointer; scheme: PAnsiChar); cdecl;
  external WEBKITGTK_LIB
  name 'webkit_security_manager_register_uri_scheme_as_secure';

procedure webkit_security_manager_register_uri_scheme_as_cors_enabled(
  security_manager: Pointer; scheme: PAnsiChar); cdecl;
  external WEBKITGTK_LIB
  name 'webkit_security_manager_register_uri_scheme_as_cors_enabled';

procedure webkit_web_context_register_uri_scheme(context: Pointer;
  scheme: PAnsiChar; callback: TWebKitUriSchemeRequestCallback;
  user_data: Pointer; user_data_destroy_func: TGDestroyNotify); cdecl;
  external WEBKITGTK_LIB name 'webkit_web_context_register_uri_scheme';

function webkit_uri_scheme_request_get_uri(
  request: Pointer): PAnsiChar; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_get_uri';

// webkit_uri_scheme_request_finish is deliberately NOT declared: it
// carries no headers, so no asset may complete through it any more, and a
// hand-declared external nobody calls is one nobody notices drifting.

procedure webkit_uri_scheme_request_finish_error(request: Pointer;
  error: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_finish_error';

// CAP-8B response surface. This is the ONLY public path on this engine
// that can carry a response header at all, and it was MEASURED delivering
// an ENFORCED CSP through it (findings L4).

function webkit_uri_scheme_response_new(stream: Pointer;
  stream_length: TGInt64): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_new';

procedure webkit_uri_scheme_response_set_content_type(response: Pointer;
  content_type: PAnsiChar); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_set_content_type';

procedure webkit_uri_scheme_response_set_status(response: Pointer;
  status_code: TGUInt; reason_phrase: PAnsiChar); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_set_status';

/// transfer full: the response owns the header set from the call on
procedure webkit_uri_scheme_response_set_http_headers(response: Pointer;
  headers: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_set_http_headers';

procedure webkit_uri_scheme_request_finish_with_response(request: Pointer;
  response: Pointer); cdecl;
  external WEBKITGTK_LIB
  name 'webkit_uri_scheme_request_finish_with_response';

// CAP-8B navigation surface. The pointer a decision arrives as is a
// WebKitPolicyDecision; its TYPE tells which subclass it is, and that is
// what makes the downcast below sound. WEBKIT_NAVIGATION_POLICY_DECISION()
// and friends are GObject cast MACROS - a runtime type check with a
// warning, not an ABI conversion - so there is nothing to call here and
// nothing is lost by not calling it.

procedure webkit_policy_decision_use(decision: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_policy_decision_use';

procedure webkit_policy_decision_ignore(decision: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_policy_decision_ignore';

function webkit_navigation_policy_decision_get_navigation_action(
  decision: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB
  name 'webkit_navigation_policy_decision_get_navigation_action';

function webkit_navigation_action_get_request(
  navigation_action: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_navigation_action_get_request';

/// DIAGNOSTIC ONLY - MEASURED true for a script navigation in the
/// continuation of a binding promise (findings L3)
function webkit_navigation_action_is_user_gesture(
  navigation_action: Pointer): TGBoolean; cdecl;
  external WEBKITGTK_LIB name 'webkit_navigation_action_is_user_gesture';

/// DIAGNOSTIC ONLY - carried in the evidence, never in a decision
function webkit_navigation_action_get_navigation_type(
  navigation_action: Pointer): TWebKitNavigationType; cdecl;
  external WEBKITGTK_LIB
  name 'webkit_navigation_action_get_navigation_type';

function webkit_uri_request_get_uri(request: Pointer): PAnsiChar; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_request_get_uri';

function webkit_response_policy_decision_get_request(
  decision: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB
  name 'webkit_response_policy_decision_get_request';

/// an UNSUPPORTED MIME type is the download shape on this engine: there is
/// no hook a page can reach on its own, and only
/// webkit_policy_decision_download - which this unit deliberately never
/// declares - would turn one into a download (findings L5)
function webkit_response_policy_decision_is_mime_type_supported(
  decision: Pointer): TGBoolean; cdecl;
  external WEBKITGTK_LIB
  name 'webkit_response_policy_decision_is_mime_type_supported';

// --- libgio-2.0.so.0 ---

function g_memory_input_stream_new_from_data(data: Pointer; len: TGSSize;
  destroy: TGDestroyNotify): Pointer; cdecl;
  external GIO_LIB name 'g_memory_input_stream_new_from_data';

/// the OS external opener - the URI as DATA, never a shell string
// - already this unit's library, so CAP-8B ships nothing new
function g_app_info_launch_default_for_uri(uri: PAnsiChar;
  context: Pointer; error: PPointer): TGBoolean; cdecl;
  external GIO_LIB name 'g_app_info_launch_default_for_uri';

// --- libgobject-2.0.so.0 ---

procedure g_object_unref(&object: Pointer); cdecl;
  external GOBJECT_LIB name 'g_object_unref';

/// g_signal_connect() is a MACRO over this call; there is no such export
// - c_handler is erased to GCallback exactly as G_CALLBACK() erases it,
// which is why the unit holds each handler in its real declared type first
function g_signal_connect_data(instance: Pointer;
  detailed_signal: PAnsiChar; c_handler: TGCallback; data: Pointer;
  destroy_data: TGClosureNotify;
  connect_flags: TGConnectFlags): TGULong; cdecl;
  external GOBJECT_LIB name 'g_signal_connect_data';

// --- libsoup-3.0.so.0 ---

function soup_message_headers_new(
  &type: TSoupMessageHeadersType): Pointer; cdecl;
  external SOUP_LIB name 'soup_message_headers_new';

// header_name/header_value rather than name/value: `name` is the directive
// that follows `external`, and a parameter spelled the same reads badly on
// the very line that has to use it
procedure soup_message_headers_append(hdrs: Pointer;
  header_name: PAnsiChar; header_value: PAnsiChar); cdecl;
  external SOUP_LIB name 'soup_message_headers_append';

// --- libglib-2.0.so.0 ---

procedure g_free(mem: Pointer); cdecl;
  external GLIB_LIB name 'g_free';

function g_try_malloc(n_bytes: TGSize): Pointer; cdecl;
  external GLIB_LIB name 'g_try_malloc';

function g_quark_from_static_string(&string: PAnsiChar): TGQuark; cdecl;
  external GLIB_LIB name 'g_quark_from_static_string';

function g_error_new_literal(domain: TGQuark; code: TGInt;
  message: PAnsiChar): Pointer; cdecl;
  external GLIB_LIB name 'g_error_new_literal';

procedure g_error_free(error: Pointer); cdecl;
  external GLIB_LIB name 'g_error_free';

{ ---- constants ---- }

const
  PWEB_SCHEME: PAnsiChar = 'pweb';
  /// static storage: g_quark_from_static_string keeps the pointer
  PWEB_GTK_ERROR_DOMAIN: PAnsiChar = 'pweb-asset';
  /// the ONE refusal text - wrong authority, non-canonical path, missing
  // asset and internal failure are indistinguishable to the page, exactly
  // like the Windows handler's constant 404
  PWEB_GTK_REFUSED: PAnsiChar = 'pweb asset unavailable';
  PWEB_GTK_ERROR_REFUSED = 1;
  /// distinct WebKitWebContexts this process can serve pweb:// on. One is
  // the realistic case (upstream shares the default context); the ceiling
  // only exists so that overflowing it refuses loudly.
  PWEB_GTK_MAX_CONTEXTS = 8;

  { ---- CAP-8B ---- }

  /// the response status every served asset carries
  // - a refusal is never a response: it goes through
  // webkit_uri_scheme_request_finish_error and the one constant error
  PWEB_GTK_STATUS_OK = 200;
  PWEB_GTK_REASON_OK: PAnsiChar = 'OK';

  /// SoupMessageHeadersType: REQUEST = 0, RESPONSE = 1, MULTIPART = 2
  SOUP_MESSAGE_HEADERS_RESPONSE = 1;

  /// WebKitPolicyDecisionType, the three shapes decide-policy delivers
  WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION = 0;
  WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION = 1;
  WEBKIT_POLICY_DECISION_TYPE_RESPONSE = 2;

  /// gboolean, spelled once
  GTK_FALSE = TGBoolean(0);
  GTK_TRUE = TGBoolean(1);

  /// the signals upstream leaves free on the WebKitWebView (it connects
  // only "destroy" on its own window)
  PWEB_GTK_SIGNAL_DECIDE_POLICY: PAnsiChar = 'decide-policy';
  PWEB_GTK_SIGNAL_CREATE: PAnsiChar = 'create';

  /// ceiling for the native header set. PWebNativeSecurityHeaders emits
  // three lines; the ceiling exists so that a fourth one silently DROPPED
  // is impossible - overflowing it refuses the asset instead.
  PWEB_GTK_MAX_HEADERS = 8;

type
  PPWebGtkRegistration = ^TPWebGtkRegistration;
  { The cell GLib owns on our behalf.

    It outlives TWebKitGtkAssetHandler by design: WebKitGTK 4.1 offers no
    unregister call, so the handler cannot take its callback back. What it
    CAN do is disown this cell, after which the callback refuses every
    request. GLib frees the cell through PWebGtkRegistrationDestroyed when
    the context is finalised. }
  TPWebGtkRegistration = record
    // TWebKitGtkAssetHandler while attached, 0 once detached. Written
    // with an interlocked store so a Detach issued (incorrectly) off the
    // GUI thread can never be observed half-written by the callback; the
    // aligned pointer-width read on the callback side is atomic on the
    // ratified x86_64 target.
    Owner: PtrInt;
    // the WebKitWebContext this cell is installed on
    Context: Pointer;
  end;

  { CAP-8B: one response header, already split into the two strings
    soup_message_headers_append wants. The split happens BEFORE any GLib
    object exists, so the only code that can raise runs while there is
    still nothing to leak. }
  TPWebGtkHeader = record
    Name: RawUtf8;
    Value: RawUtf8;
  end;

  TPWebGtkHeaders = record
    Count: PtrInt;
    Items: array[0 .. PWEB_GTK_MAX_HEADERS - 1] of TPWebGtkHeader;
  end;

  PPWebGtkNavCell = ^TPWebGtkNavCell;
  { CAP-8B: everything the navigation callbacks touch.

    Deliberately NOT the guard object: the decision needs nothing from it.
    The classifier is pure and lives in another unit, so a navigation
    callback on this engine dereferences no FPC-managed memory at all -
    it reads an owner flag, calls a pure function and writes counters,
    all inside one GLib allocation. That is a stronger property than the
    asset callback can have (it must reach an IAssetStore), and it is the
    reason the callbacks below carry no `owner` variable.

    Reference counted because TWO closures share it - "decide-policy" and
    "create" - and GLib destroys them independently. Each closure holds
    one reference and drops it through PWebGtkNavCellReleased; the guard
    holds one more and drops it in Detach. The cell is a GLib allocation
    for the reason PWebGtkRegistrationDestroyed documents: a closure can
    die from a libc atexit handler, long after the FPC heap is gone. }
  TPWebGtkNavCell = record
    // TWebKitGtkNavigationGuard while attached, 0 once detached. Written
    // with an interlocked store, exactly like the registration cell.
    Owner: PtrInt;
    // live references: one per connected closure, plus the guard's own
    Refs: PtrInt;
    // evidence, not policy
    Allowed: PtrInt;
    Cancelled: PtrInt;
    // DIAGNOSTIC ONLY, and structurally so: nothing reads these back
    UserActivated: PtrInt;
    NavigationType: PtrInt;
  end;

var
  /// resolved lazily on the GUI thread; 0 until the first refusal
  PWebGtkErrorQuark: TGQuark;

  { Every registration this process has installed, one per context.

    MEASURED, and the reason this table exists at all:
    webkit_web_context_register_uri_scheme REFUSES a second registration
    of the same scheme on the same context - it logs

      CRITICAL: Cannot register URI scheme pweb more than once

    and leaves the FIRST handler installed. WebKitGTK 4.1 has no
    unregister call to undo it with. Upstream webviews are created with
    webkit_web_view_new(), which uses the shared DEFAULT context, so the
    second window in a process - and, far more commonly, the second
    create/destroy cycle of a repeated-lifecycle test - hits exactly that
    refusal. Registering again is therefore not an option; re-OWNING the
    cell already installed is, and it is what Create does.

    STATIC storage, deliberately, and a fixed capacity rather than a
    dynamic array. MEASURED (see PWebGtkRegistrationDestroyed): GLib
    tears the default context down from a libc atexit handler, which runs
    AFTER FPC has finalised its units - a dynamic array's backing store
    is gone by then, while a global in the data segment is valid for the
    entire process lifetime. One context is the realistic case; the
    capacity exists so that exceeding it is a loud refusal rather than an
    overflow.

    GUI-thread only, like every other WebKit call in this unit. }
  PWebGtkCells: array[0 .. PWEB_GTK_MAX_CONTEXTS - 1] of PPWebGtkRegistration;

function PWebGtkFindCell(AContext: Pointer): PPWebGtkRegistration;
var
  i: PtrInt;
begin
  for i := 0 to High(PWebGtkCells) do
    if (PWebGtkCells[i] <> nil) and
       (PWebGtkCells[i]^.Context = AContext) then
    begin
      Result := PWebGtkCells[i];
      exit;
    end;
  Result := nil;
end;

function PWebGtkTrackCell(ACell: PPWebGtkRegistration): Boolean;
var
  i: PtrInt;
begin
  // a slot vacated by a finalised context is reused
  for i := 0 to High(PWebGtkCells) do
    if PWebGtkCells[i] = nil then
    begin
      PWebGtkCells[i] := ACell;
      Result := True;
      exit;
    end;
  Result := False;
end;

{ ---- the shared request decision (see the interface comments) ---- }

function PWebGtkResolveAssetUri(const AUri: RawUtf8;
  const AStore: IAssetStore; out Asset: TAssetResponse): Boolean;
var
  logical: RawUtf8;
begin
  Result := False;
  Asset.Content := '';
  Asset.ContentType := '';
  if AStore = nil then
    exit;
  try
    // ONE validation truth, shared byte-for-byte with Windows: a wrong
    // scheme or authority never reaches IAssetStore, and no filesystem
    // path is ever built from an unvalidated URI
    if not PWebParseAppUri(AUri, logical) then
      exit;
    Result := AStore.TryRead(logical, Asset);
    if not Result then
    begin
      Asset.Content := '';
      Asset.ContentType := '';
    end;
  except
    // a store is contractually fail-closed rather than raising, but the
    // callback boundary above must never depend on that
    Asset.Content := '';
    Asset.ContentType := '';
    Result := False;
  end;
end;

function PWebGtkContentType(const Asset: TAssetResponse): RawUtf8;
begin
  Result := Asset.ContentType;
  if Result = '' then
    Result := PWEB_ASSET_FALLBACK_MIME; // never an empty Content-Type
end;

function PWebGtkCopyBody(const AContent: RawByteString;
  out ABody: Pointer; out ASize: PtrInt): Boolean;
begin
  ABody := nil;
  ASize := Length(AContent);
  if ASize > 0 then
  begin
    ABody := g_try_malloc(TGSize(ASize));
    if ABody = nil then
    begin
      Result := False;
      exit;
    end;
    Move(pointer(AContent)^, ABody^, ASize);
  end
  else
  begin
    // g_try_malloc(0) yields nil; a zero-byte asset is still an asset,
    // so keep the stream's data pointer real and its length honest
    ABody := g_try_malloc(1);
    if ABody = nil then
    begin
      Result := False;
      exit;
    end;
  end;
  Result := True;
end;

procedure PWebGtkReleaseBody(ABody: Pointer);
begin
  if ABody <> nil then
    g_free(ABody);
end;

{ ---- CAP-8B: the native security headers, transported not decided ---- }

function PWebGtkTrimAscii(const S: RawUtf8): RawUtf8;
var
  first, last: PtrInt;
begin
  first := 1;
  last := Length(S);
  while (first <= last) and
        (S[first] in [' ', #9]) do
    Inc(first);
  while (last >= first) and
        (S[last] in [' ', #9]) do
    Dec(last);
  Result := Copy(S, first, last - first + 1);
end;

{ is this response an HTML document, i.e. the one the CSP has to ride?

  The store's type carries its parameters ('text/html; charset=utf-8'), so
  the comparison is on the media type alone, case-insensitively per RFC
  9110. Attaching the CSP to a script response would be inert rather than
  harmful - pweb.navigation.policy says so - so this predicate decides how
  many bytes are served, never whether anything is protected: nosniff and
  no-referrer ride every asset either way. }
function PWebGtkIsHtmlType(const AContentType: RawUtf8): Boolean;
var
  i: PtrInt;
  base: RawUtf8;
begin
  i := Pos(';', AContentType);
  if i > 0 then
    base := Copy(AContentType, 1, i - 1) // drop '; charset=utf-8'
  else
    base := AContentType;
  base := PWebGtkTrimAscii(base);
  for i := 1 to Length(base) do
    if base[i] in ['A' .. 'Z'] then
      base[i] := AnsiChar(Ord(base[i]) + 32);
  Result := base = 'text/html';
end;

{ split the CRLF-separated header block from PWebNativeSecurityHeaders into
  the (name, value) pairs libsoup wants.

  FAIL CLOSED on every surprise - an empty name, an empty value, a line
  with no colon, more lines than the ceiling, no line at all. This runs on
  a constant produced one unit away, so none of those can happen today;
  what the checks buy is that if that constant ever changes shape, the
  asset is REFUSED rather than served with a policy that lost a directive
  on the way out. A silently dropped header is the failure this whole
  mechanism exists to make impossible. }
function PWebGtkSplitHeaderBlock(const ABlock: RawUtf8;
  out AHeaders: TPWebGtkHeaders): Boolean;
var
  i, lineStart, colon, n: PtrInt;
  line: RawUtf8;
begin
  Result := False;
  AHeaders.Count := 0;
  lineStart := 1;
  for i := 1 to Length(ABlock) + 1 do
    if (i > Length(ABlock)) or
       (ABlock[i] = #13) or
       (ABlock[i] = #10) then
    begin
      line := PWebGtkTrimAscii(Copy(ABlock, lineStart, i - lineStart));
      lineStart := i + 1;
      if line = '' then
        continue; // the CRLF pair, and any trailing separator
      colon := Pos(':', line);
      if (colon <= 1) or
         (colon >= Length(line)) then
        exit; // no name, or no value
      n := AHeaders.Count;
      if n >= PWEB_GTK_MAX_HEADERS then
        exit; // never append a truncated policy
      AHeaders.Items[n].Name := PWebGtkTrimAscii(Copy(line, 1, colon - 1));
      AHeaders.Items[n].Value :=
        PWebGtkTrimAscii(Copy(line, colon + 1, MaxInt));
      if (AHeaders.Items[n].Name = '') or
         (AHeaders.Items[n].Value = '') then
        exit;
      AHeaders.Count := n + 1;
    end;
  Result := AHeaders.Count > 0;
end;

function PWebGtkDisplayUnavailableReason: RawUtf8;
begin
  Result := '';
  if (GetEnvironmentVariable('WAYLAND_DISPLAY') = '') and
     (GetEnvironmentVariable('DISPLAY') = '') then
    Result := 'no display: WAYLAND_DISPLAY and DISPLAY are both unset - a ' +
      'GTK/WebKitGTK WebView requires an X or Wayland display (a headless ' +
      'host must run under xvfb-run)';
end;

{ ---- GLib-side callbacks (no Pascal exception may leave them) ---- }

procedure PWebGtkFreeBody(data: Pointer); cdecl;
begin
  // GIO's destroy notify for the response body. Declared here rather
  // than passing @g_free so the transported pointer is unambiguously a
  // Pascal-visible cdecl procedure of the exact GDestroyNotify shape.
  g_free(data);
end;

procedure PWebGtkRegistrationDestroyed(data: Pointer); cdecl;
var
  i: PtrInt;
begin
  { GLib calls this when the context is finalised, which drops the
    tracking slot so a later context allocated at the same address can
    never be mistaken for this one.

    NOTHING here may touch the FPC heap or any managed type. MEASURED:
    GLib finalises the default WebKitWebContext from a libc atexit
    handler, i.e.

      __run_exit_handlers -> g_object_unref -> (WebKit) -> this callback

    and libc runs atexit handlers AFTER FPC's own finalization has
    already shut the heap manager down. An earlier revision allocated
    this cell with New and released it with Dispose here; the result was
    a completely successful run - verdict PASS, "clean exit" printed -
    that then exited 217 with no message, because Dispose faulted inside
    the dead heap. So the cell is a GLib allocation released with g_free,
    and PWebGtkCells is static storage. }
  if data = nil then
    exit;
  for i := 0 to High(PWebGtkCells) do
    if PWebGtkCells[i] = data then
      PWebGtkCells[i] := nil;
  g_free(data);
end;

procedure PWebGtkFinishRefused(request: Pointer);
var
  err: Pointer;
begin
  if request = nil then
    exit;
  if PWebGtkErrorQuark = 0 then
    PWebGtkErrorQuark := g_quark_from_static_string(PWEB_GTK_ERROR_DOMAIN);
  err := g_error_new_literal(PWebGtkErrorQuark, PWEB_GTK_ERROR_REFUSED,
    PWEB_GTK_REFUSED);
  if err = nil then
    exit; // nothing safe left to do; the request completes unhandled
  // finish_error COPIES the error into the request, so ours is ours to free
  webkit_uri_scheme_request_finish_error(request, err);
  g_error_free(err);
end;

procedure PWebGtkSchemeRequest(request: Pointer; user_data: Pointer); cdecl;
var
  reg: PPWebGtkRegistration;
  owner: TWebKitGtkAssetHandler;
  rawUri: PAnsiChar;
  uri, mime: RawUtf8;
  asset: TAssetResponse;
  body, stream, response, soupHeaders: Pointer;
  size, i: PtrInt;
  headers: TPWebGtkHeaders;
begin
  try
    reg := PPWebGtkRegistration(user_data);
    if (reg = nil) or
       (reg^.Owner = 0) then
    begin
      // detached (or never owned): fail closed, never serve
      PWebGtkFinishRefused(request);
      exit;
    end;
    owner := TWebKitGtkAssetHandler(Pointer(reg^.Owner));
    if (request = nil) or
       (owner.fStore = nil) then
    begin
      PWebGtkFinishRefused(request);
      exit;
    end;
    rawUri := webkit_uri_scheme_request_get_uri(request);
    if rawUri = nil then
    begin
      PWebGtkFinishRefused(request);
      exit;
    end;
    // the WHOLE URI, copied out of WebKit's storage immediately. Never
    // webkit_uri_scheme_request_get_path: it drops the authority.
    FastSetString(uri, rawUri, StrLen(rawUri));
    if not PWebGtkResolveAssetUri(uri, owner.fStore, asset) then
    begin
      PWebGtkFinishRefused(request);
      exit;
    end;
    // the body becomes GIO's: a heap copy owned by the input stream and
    // released through g_free long after this frame is gone
    if not PWebGtkCopyBody(asset.Content, body, size) then
    begin
      PWebGtkFinishRefused(request);
      exit;
    end;
    stream := g_memory_input_stream_new_from_data(body, TGSSize(size),
      @PWebGtkFreeBody);
    if stream = nil then
    begin
      PWebGtkReleaseBody(body); // ownership never transferred
      PWebGtkFinishRefused(request);
      exit;
    end;
    mime := PWebGtkContentType(asset);
    // CAP-8B. Everything from here answers ONE question: does this asset
    // reach the page carrying its native policy, or not at all?
    // webkit_uri_scheme_request_finish - the shape the pre-CAP-8B adapter
    // used - carries no headers, so the completion goes through a
    // WebKitURISchemeResponse instead and that call is gone entirely.
    //
    // The split runs FIRST, while the only thing that could raise is
    // Pascal string work and there is no GLib object to leak. Every
    // failure below refuses the asset rather than serving it bare: a
    // trusted HTML document without frame-src 'none' is exactly the
    // situation the CSP exists to prevent, and on THIS engine that
    // directive is the primary subframe defence rather than defence in
    // depth (findings L2 - the navigation hook cannot identify the frame
    // being navigated).
    if not PWebGtkSplitHeaderBlock(
             PWebNativeSecurityHeaders, headers) then
    begin
      g_object_unref(stream);
      PWebGtkFinishRefused(request);
      exit;
    end;
    response := webkit_uri_scheme_response_new(stream, TGInt64(size));
    if response = nil then
    begin
      g_object_unref(stream);
      PWebGtkFinishRefused(request);
      exit;
    end;
    webkit_uri_scheme_response_set_content_type(response, PAnsiChar(mime));
    webkit_uri_scheme_response_set_status(response, PWEB_GTK_STATUS_OK,
      PWEB_GTK_REASON_OK);
    soupHeaders := soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    if soupHeaders = nil then
    begin
      g_object_unref(response);
      g_object_unref(stream);
      PWebGtkFinishRefused(request);
      exit;
    end;
    for i := 0 to headers.Count - 1 do
      soup_message_headers_append(soupHeaders,
        PAnsiChar(headers.Items[i].Name), PAnsiChar(headers.Items[i].Value));
    // transfer full: the response owns the header set from here, and
    // nothing between its creation and this call can raise
    webkit_uri_scheme_response_set_http_headers(response, soupHeaders);
    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response); // the request holds its own reference
    g_object_unref(stream); // and the response holds its own
  except
    // fail closed: a constant refusal beats letting an exception cross
    // the C frame
    try
      PWebGtkFinishRefused(request);
    except
    end;
  end;
end;

{ ---- TWebKitGtkAssetHandler ---- }

constructor TWebKitGtkAssetHandler.Create(AWebView: webview_t;
  const AStore: IAssetStore);
var
  controller, security: Pointer;
  reg: PPWebGtkRegistration;
begin
  inherited Create;
  if AWebView = nil then
    raise EPWebWebKitGtkAssetHandler.Create('webview handle is nil');
  if AStore = nil then
    raise EPWebWebKitGtkAssetHandler.Create('asset store is nil');
  fThreadId := GetCurrentThreadId; // GTK/WebKit calls are GUI-affine
  fStore := AStore;
  controller := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if controller = nil then
    raise EPWebWebKitGtkAssetHandler.Create(
      'borrowed browser controller is unavailable');
  // on GTK the browser controller IS the WebKitWebView; the context it
  // returns is owned by the view - borrowed here, never unref'd
  fContext := webkit_web_view_get_context(controller);
  if fContext = nil then
    raise EPWebWebKitGtkAssetHandler.Create(
      'WebKitWebContext is unavailable');
  security := webkit_web_context_get_security_manager(fContext);
  if security = nil then
    raise EPWebWebKitGtkAssetHandler.Create(
      'WebKitSecurityManager is unavailable');
  // classification BEFORE registration and before any navigation, so the
  // very first pweb://app document is already a secure, CORS-enabled
  // origin - never a page that loads first and gets upgraded after
  webkit_security_manager_register_uri_scheme_as_secure(security,
    PWEB_SCHEME);
  webkit_security_manager_register_uri_scheme_as_cors_enabled(security,
    PWEB_SCHEME);
  reg := PWebGtkFindCell(fContext);
  if reg <> nil then
  begin
    // this process already registered pweb on this context and cannot
    // register it again (see PWebGtkCells): re-own the installed cell.
    // Two LIVE handlers on one context would both be served by a single
    // callback that can only consult one store, so that is refused
    // rather than silently resolved in someone's favour.
    if reg^.Owner <> 0 then
      raise EPWebWebKitGtkAssetHandler.Create(
        'a pweb://app handler is already attached to this WebKitWebContext');
    InterLockedExchange64(PInt64(@reg^.Owner)^, Int64(PtrInt(Pointer(Self))));
    fRegistration := reg;
  end
  else
  begin
    // a GLib allocation, not New: the destroy notify that releases it
    // runs from a libc atexit handler, after the FPC heap is gone
    reg := PPWebGtkRegistration(
      g_try_malloc(TGSize(SizeOf(TPWebGtkRegistration))));
    if reg = nil then
      raise EPWebWebKitGtkAssetHandler.Create(
        'unable to allocate the pweb scheme registration');
    FillChar(reg^, SizeOf(reg^), 0);
    reg^.Owner := PtrInt(Pointer(Self));
    reg^.Context := fContext;
    if not PWebGtkTrackCell(reg) then
    begin
      g_free(reg);
      raise EPWebWebKitGtkAssetHandler.CreateFmt(
        'more than %d WebKitWebContexts served pweb:// in one process',
        [PWEB_GTK_MAX_CONTEXTS]);
    end;
    fRegistration := reg;
    // from here the cell belongs to GLib: it is freed by
    // PWebGtkRegistrationDestroyed, never by us
    webkit_web_context_register_uri_scheme(fContext, PWEB_SCHEME,
      @PWebGtkSchemeRequest, reg, @PWebGtkRegistrationDestroyed);
  end;
  fAttached := True;
end;

destructor TWebKitGtkAssetHandler.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TWebKitGtkAssetHandler.Detach;
var
  reg: PPWebGtkRegistration;
begin
  // WebKitGTK 4.1 cannot unregister a URI scheme, so teardown is a
  // DISOWN, not a removal: after this store the callback can still be
  // entered but finds no owner and refuses. Unlike the Windows sibling
  // this must happen on ANY thread - skipping it would leave a live
  // pointer to an object about to be freed - so it is a single
  // interlocked pointer-width store rather than a guarded native call.
  // The cell itself stays in PWebGtkCells and stays registered, ready
  // for the next handler on the same context to re-own.
  reg := PPWebGtkRegistration(fRegistration);
  if reg <> nil then
    InterLockedExchange64(PInt64(@reg^.Owner)^, 0);
  fRegistration := nil;
  fAttached := False;
  fContext := nil; // borrowed
  fStore := nil;
end;

{ ---- CAP-8B: the navigation guard ---- }

procedure PWebGtkNavCellUnref(ACell: PPWebGtkNavCell);
begin
  if ACell = nil then
    exit;
  if InterLockedDecrement64(PInt64(@ACell^.Refs)^) = 0 then
    g_free(ACell);
end;

procedure PWebGtkNavCellReleased(data: Pointer; closure: Pointer); cdecl;
begin
  { GLib invokes this when a closure holding the cell is destroyed - when
    the WebKitWebView is finalised, or when the signal is disconnected.

    NOTHING here may touch the FPC heap or any managed type, for the
    reason PWebGtkRegistrationDestroyed records in full: GLib tears these
    objects down from a libc atexit handler, and libc runs those AFTER
    FPC's finalization has shut the heap manager down. So the cell is a
    GLib allocation released with g_free.

    Both connected closures share one cell, and GLib destroys them
    independently - hence the reference count rather than a free here. }
  PWebGtkNavCellUnref(PPWebGtkNavCell(data));
end;

{ The whole navigation decision, for all three shapes this engine
  delivers. Called on the GTK main thread, from a C frame.

  It decides NOTHING: it translates a WebKitPolicyDecision into a
  TPWebNavRequest, asks PWebClassifyNavigation - the same pure function
  Windows and macOS ask, over the same record - and translates the answer
  back into webkit_policy_decision_use / _ignore. A second policy table
  here would be a second answer to the only question that matters. }
function PWebGtkDecidePolicy(web_view: Pointer; decision: Pointer;
  decision_type: TWebKitPolicyDecisionType;
  user_data: Pointer): TGBoolean; cdecl;
var
  cell: PPWebGtkNavCell;
  action, request: Pointer;
  rawUri: PAnsiChar;
  req: TPWebNavRequest;
  allow, decided: Boolean;
begin
  { WE DECIDED - set FIRST, so that even the exception path returns it.
    An UNDECIDED policy DEFAULTS TO ALLOW on this engine, so returning
    FALSE from any path hands the navigation to a default handler whose
    answer is always "allow". }
  Result := GTK_TRUE;
  decided := False;
  try
    if decision = nil then
      { Nothing to decide WITH. There is no object to refuse through, so
        the fail-closed answer is to claim the decision and never complete
        it: the navigation cannot proceed, because the only object that
        could authorise it does not exist. Returning FALSE instead would
        be an allow. }
      exit;
    req.Uri := '';
    req.Kind := pnkDocument; // the strictest interpretation available
    req.UserActivated := False;
    cell := PPWebGtkNavCell(user_data);
    if (cell = nil) or
       (cell^.Owner = 0) then
    begin
      // detached, or never owned: refuse everything, exactly like the
      // scheme callback's constant error. A guard that stops guarding
      // does not start allowing.
      decided := True;
      webkit_policy_decision_ignore(decision);
      exit;
    end;
    { The decision's TYPE is what makes each downcast below sound: WebKit
      delivers a WebKitNavigationPolicyDecision for the two action types
      and a WebKitResponsePolicyDecision for the response type. }
    case decision_type of
      WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION,
      WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION:
        begin
          { A navigation action stays pnkDocument even though it may well
            be a subframe: frame discrimination is MEASURED ABSENT on this
            engine (findings L2) - no accessor identifies the frame BEING
            NAVIGATED, and the response-time one does not even resolve on
            the installed library. Reporting pnkSubframe would be a guess,
            and reporting pnkDocument is the strictest reading available:
            every non-trusted URI dies here whatever frame asked, and CSP
            frame-src 'none' is what removes subframes on Linux. }
          if decision_type = WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION then
            req.Kind := pnkNewWindow;
          action :=
            webkit_navigation_policy_decision_get_navigation_action(decision);
          if action <> nil then
          begin
            request := webkit_navigation_action_get_request(action);
            if request <> nil then
            begin
              rawUri := webkit_uri_request_get_uri(request);
              if rawUri <> nil then
                // the WHOLE URI, copied out of WebKit's storage at once
                FastSetString(req.Uri, rawUri, StrLen(rawUri));
            end;
            { DIAGNOSTIC ONLY, both of them. The classifier is required to
              ignore UserActivated and its corpus test proves it by
              inverting the flag over every row - which is exactly what
              this engine's measurement demands, since is_user_gesture
              reads TRUE for a plain script navigation performed in the
              continuation of a binding promise (findings L3). }
            req.UserActivated :=
              webkit_navigation_action_is_user_gesture(action) <> GTK_FALSE;
            if req.UserActivated then
              InterLockedExchange64(PInt64(@cell^.UserActivated)^, 1)
            else
              InterLockedExchange64(PInt64(@cell^.UserActivated)^, 0);
            InterLockedExchange64(PInt64(@cell^.NavigationType)^,
              Int64(webkit_navigation_action_get_navigation_type(action)));
          end;
          // an action-less decision keeps the empty URI, which no row of
          // the classification table can accept
        end;
      WEBKIT_POLICY_DECISION_TYPE_RESPONSE:
        begin
          request := webkit_response_policy_decision_get_request(decision);
          if request <> nil then
          begin
            rawUri := webkit_uri_request_get_uri(request);
            if rawUri <> nil then
              FastSetString(req.Uri, rawUri, StrLen(rawUri));
          end;
          { An unsupported MIME type is the DOWNLOAD shape on this engine:
            there is no download hook a page can reach on its own, an
            undisplayable response arrives here instead, and only
            webkit_policy_decision_download would turn it into one
            (findings L5). It is classified pnkDownload and refused with
            _ignore; that conversion call is not even declared in this
            unit.

            Refusing an unsupported type cannot starve the application.
            MEASURED: across the whole Linux audit the engine raised 22
            RESPONSE decisions and every one of them was a DOCUMENT -
            main frame, subframe, popup or the deliberate download
            fixture. Not one script, stylesheet or fetch produced one,
            while the CSP phases confirm those same subresources loaded
            and ran. Subresources are simply not policy-checked here.

            A response decision carries no navigation action and therefore
            no gesture flag, so UserActivated stays False as an honest
            default rather than a measured value. }
          if webkit_response_policy_decision_is_mime_type_supported(
               decision) = GTK_FALSE then
            req.Kind := pnkDownload;
        end;
    else
      { An unknown decision type. Not a theoretical branch: this engine
        allows anything nobody decided, so a type a future WebKitGTK adds
        must be refused HERE rather than fallen through. Restated rather
        than assumed - an empty URI matches no row of the classification
        table, and pnkDocument is already the strictest kind. }
      req.Uri := '';
    end;
    { The classifier runs while `decided` is still False ON PURPOSE: if it
      ever raised, the handler below must still refuse this decision, and
      a flag set one line earlier would have made that impossible. It is
      set immediately BEFORE the completion call instead, so a fault
      inside THAT call cannot produce a second completion either. }
    allow := PWebClassifyNavigation(req) = pnaAllowTrusted;
    decided := True;
    if allow then
    begin
      InterLockedIncrement64(PInt64(@cell^.Allowed)^);
      webkit_policy_decision_use(decision);
    end
    else
    begin
      InterLockedIncrement64(PInt64(@cell^.Cancelled)^);
      // _ignore, never _download: a refused response must not become
      // bytes on disk, and a denied navigation must not replace the
      // trusted page
      webkit_policy_decision_ignore(decision);
    end;
  except
    // fail closed: a classifier fault denies, and no Pascal exception
    // crosses the C frame
    if not decided then
    begin
      decided := True;
      try
        webkit_policy_decision_ignore(decision);
      except
      end;
    end;
  end;
end;

{ "create" is the only place a new window can be granted on this engine.

  NULL means no widget, so no child WebKitWebView, no window and no load.
  With no handler connected at all this engine already returns NULL - but
  then the refusal would be a property of what nobody subscribed to rather
  than something PWeb enforces, which is precisely the mistake finding W1
  records about Windows' incidental bridge isolation. Connecting an
  explicit refusal makes it ours, and makes it countable.

  It should never fire: decide-policy refuses the NEW_WINDOW_ACTION first.
  If it ever does, the count says so. }
function PWebGtkCreate(web_view: Pointer; navigation_action: Pointer;
  user_data: Pointer): Pointer; cdecl;
var
  cell: PPWebGtkNavCell;
begin
  Result := nil;
  try
    cell := PPWebGtkNavCell(user_data);
    if (cell <> nil) and
       (cell^.Owner <> 0) then
      InterLockedIncrement64(PInt64(@cell^.Cancelled)^);
  except
    // nothing may cross the C frame; the refusal already happened above
  end;
end;

const
  { The two handlers held in their EXACT declared types. g_signal_connect
    erases a handler to GCallback exactly as the G_CALLBACK() macro does,
    which throws the signature away - these assignments are where a drift
    becomes a compile error instead of a corrupted stack, and they are the
    same guarantee the typed callback parameter gives the asset handler's
    registration. }
  PWEB_GTK_DECIDE_POLICY_CB: TWebKitDecidePolicyCallback =
    @PWebGtkDecidePolicy;
  PWEB_GTK_CREATE_CB: TWebKitCreateCallback = @PWebGtkCreate;

constructor TWebKitGtkNavigationGuard.Create(AWebView: webview_t);
var
  controller: Pointer;
  cell: PPWebGtkNavCell;
  handlerId: TGULong;
begin
  inherited Create;
  if AWebView = nil then
    raise EPWebWebKitGtkNavigationGuard.Create('webview handle is nil');
  if not (Assigned(PWEB_GTK_DECIDE_POLICY_CB) and
          Assigned(PWEB_GTK_CREATE_CB)) then
    raise EPWebWebKitGtkNavigationGuard.Create(
      'the navigation callbacks are unresolvable');
  fThreadId := GetCurrentThreadId; // GTK/WebKit calls are GUI-affine
  controller := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if controller = nil then
    raise EPWebWebKitGtkNavigationGuard.Create(
      'borrowed browser controller is unavailable');
  // a GLib allocation, not New: a closure can be destroyed from a libc
  // atexit handler, after the FPC heap is gone (see
  // PWebGtkRegistrationDestroyed, where that cost a silent exit 217)
  cell := PPWebGtkNavCell(g_try_malloc(TGSize(SizeOf(TPWebGtkNavCell))));
  if cell = nil then
    raise EPWebWebKitGtkNavigationGuard.Create(
      'unable to allocate the navigation guard cell');
  FillChar(cell^, SizeOf(cell^), 0);
  cell^.Owner := PtrInt(Pointer(Self));
  cell^.Refs := 1; // ours, dropped in Detach
  // published before the first connect: if a connection below fails, the
  // destructor FPC runs for the failed constructor still finds the cell
  // and drops this reference
  fCell := cell;
  InterLockedIncrement64(PInt64(@cell^.Refs)^); // the decide-policy closure
  handlerId := g_signal_connect_data(controller,
    PWEB_GTK_SIGNAL_DECIDE_POLICY, TGCallback(@PWebGtkDecidePolicy), cell,
    @PWebGtkNavCellReleased, 0);
  if handlerId = 0 then
  begin
    // g_signal_connect_data returns 0 only when the signal name does not
    // parse, and it decides that BEFORE creating the closure that would
    // own the reference just taken - so that reference is still ours
    PWebGtkNavCellUnref(cell);
    raise EPWebWebKitGtkNavigationGuard.Create(
      'the WebKitWebView refused the decide-policy connection');
  end;
  InterLockedIncrement64(PInt64(@cell^.Refs)^); // the create closure
  handlerId := g_signal_connect_data(controller, PWEB_GTK_SIGNAL_CREATE,
    TGCallback(@PWebGtkCreate), cell, @PWebGtkNavCellReleased, 0);
  if handlerId = 0 then
  begin
    PWebGtkNavCellUnref(cell);
    raise EPWebWebKitGtkNavigationGuard.Create(
      'the WebKitWebView refused the create connection');
  end;
  fAttached := True;
end;

destructor TWebKitGtkNavigationGuard.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TWebKitGtkNavigationGuard.Detach;
var
  cell: PPWebGtkNavCell;
begin
  cell := PPWebGtkNavCell(fCell);
  fCell := nil; // idempotent from here
  if cell <> nil then
  begin
    // DISOWN FIRST - one interlocked pointer-width store, safe from any
    // thread, exactly like the asset handler's. After it every decision
    // is refused and the counters can no longer move, so the snapshot
    // below is the final tally rather than a value still in flight.
    InterLockedExchange64(PInt64(@cell^.Owner)^, 0);
    fAllowed := cell^.Allowed;
    fCancelled := cell^.Cancelled;
    fUserActivated := cell^.UserActivated <> 0;
    fNavigationType := PtrUInt(cell^.NavigationType);
    { The signals are deliberately NOT disconnected. Disconnecting needs a
      WebKitWebView this object cannot prove is still alive - Detach is
      allowed to run after webview_destroy, and handing a freed GObject to
      g_signal_handler_disconnect is a use-after-free the disown above
      already makes unnecessary. The cell outlives us either way; GLib
      frees it when the last closure dies. }
    PWebGtkNavCellUnref(cell); // our reference
  end;
  fAttached := False;
end;

function TWebKitGtkNavigationGuard.GetAllowed: PtrInt;
var
  cell: PPWebGtkNavCell;
begin
  cell := PPWebGtkNavCell(fCell);
  if cell <> nil then
    Result := cell^.Allowed
  else
    Result := fAllowed; // the snapshot Detach took
end;

function TWebKitGtkNavigationGuard.GetCancelled: PtrInt;
var
  cell: PPWebGtkNavCell;
begin
  cell := PPWebGtkNavCell(fCell);
  if cell <> nil then
    Result := cell^.Cancelled
  else
    Result := fCancelled;
end;

function TWebKitGtkNavigationGuard.GetUserActivated: Boolean;
var
  cell: PPWebGtkNavCell;
begin
  cell := PPWebGtkNavCell(fCell);
  if cell <> nil then
    Result := cell^.UserActivated <> 0
  else
    Result := fUserActivated;
end;

function TWebKitGtkNavigationGuard.GetNavigationType: PtrUInt;
var
  cell: PPWebGtkNavCell;
begin
  cell := PPWebGtkNavCell(fCell);
  if cell <> nil then
    Result := PtrUInt(cell^.NavigationType)
  else
    Result := fNavigationType;
end;

{ ---- CAP-8B: the private external opener ---- }

var
  { The seam, nil in production. A variable rather than a compile-time
    switch because the counting fake has to be installable in the very
    unit the product ships, from a test binary that links it unchanged. }
  PWebGtkOpener: TPWebGtkExternalOpener = nil;

function PWebGtkLaunchDefaultForUri(const AUri: RawUtf8): Boolean;
var
  err: Pointer;
begin
  err := nil;
  // the URI as DATA to the desktop's own handler registry: no shell
  // string, no /bin/sh, no argument interpolation anywhere
  Result := g_app_info_launch_default_for_uri(PAnsiChar(AUri), nil, @err) <>
    GTK_FALSE;
  if err <> nil then
  begin
    // the GError is FREED, never read and never reported: its message
    // names the desktop handler and echoes the URI, and neither belongs
    // anywhere near the page or the log
    g_error_free(err);
    Result := False;
  end;
end;

function PWebGtkOpenExternalUri(const AUri: RawUtf8): Boolean;
var
  opener: TPWebGtkExternalOpener;
begin
  Result := False;
  // the gate runs BEFORE the seam, so a test double cannot be used to
  // smuggle an unapproved scheme past it either
  if not PWebValidExternalUri(AUri) then
    exit;
  opener := PWebGtkOpener;
  try
    if Assigned(opener) then
      Result := opener(AUri)
    else
      Result := PWebGtkLaunchDefaultForUri(AUri);
  except
    // a failed open is a diagnostic, never a navigation: the trusted page
    // stays exactly where it was and there is no internal fallback
    Result := False;
  end;
end;

function PWebGtkSetExternalOpener(
  AOpener: TPWebGtkExternalOpener): TPWebGtkExternalOpener;
begin
  Result := PWebGtkOpener;
  PWebGtkOpener := AOpener;
end;

initialization
  { MEASURED, and not optional: without this every Linux PWeb process dies
    with 'EInvalidOp: Invalid floating point operation' the moment WebKit
    realises a window.

    FPC starts a Linux process with the SSE and x87 invalid-operation,
    divide-by-zero and overflow traps UNMASKED. GTK, Cairo, Pango and
    WebKit all compute with NaNs, infinities and denormals as ordinary
    intermediate values - entirely legal IEEE-754 arithmetic - so the
    first such computation traps inside a C frame that has no handler and
    the process dies before one pixel or one asset is served.

    Masking is what every FPC host of a GTK stack does. It belongs HERE,
    in the engine adapter's initialization, because linking this unit IS
    the decision to host WebKitGTK in this process: an application that
    does not use the Linux WebView never pays for it, and one that does
    cannot forget it. It runs before any application code, so no window
    can be created ahead of it.

    Written through the System primitives on purpose, NOT through
    math.SetExceptionMask. MEASURED: pulling in the math unit made the
    process exit 217 (FPC's unhandled-exception code) AFTER a completely
    successful run - "clean exit" printed, verdict PASS, then 217 with no
    message. math's finalization restores the FPU control words, and
    mORMot's units - which initialise earlier and therefore finalise
    LATER - then perform floating point with the traps live again. Owning
    the two registers directly leaves nothing to unwind.

      x87 control word bits 0..5  = the six exception masks -> or $3F
      MXCSR         bits 7..12    = the same six masks      -> or $1F80

    This changes only how the FPU REPORTS exceptional results, never the
    results themselves. PWeb transports no floating point of its own -
    the wire is JSON produced above this layer - so none of the product's
    own arithmetic becomes less strict. }
  Set8087CW(Get8087CW or $3F);
  SetSSECSR(GetSSECSR or $1F80);

end.
