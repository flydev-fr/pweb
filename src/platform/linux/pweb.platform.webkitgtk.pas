{
  pweb.platform.webkitgtk - production pweb://app resource handler for
  the Linux/WebKitGTK engine (CAP-7L).

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
      -> finish(stream, length, content type)   or a constant error finish

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
  pweb.assets.support;

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

  /// void (*GDestroyNotify) (gpointer data)
  TGDestroyNotify = procedure(data: Pointer); cdecl;

  /// void (*WebKitURISchemeRequestCallback) (WebKitURISchemeRequest*,
  ///                                         gpointer user_data)
  TWebKitUriSchemeRequestCallback = procedure(request: Pointer;
    user_data: Pointer); cdecl;

  EPWebWebKitGtkAssetHandler = class(Exception);

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

procedure webkit_uri_scheme_request_finish(request: Pointer;
  stream: Pointer; stream_length: TGInt64; content_type: PAnsiChar); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_finish';

procedure webkit_uri_scheme_request_finish_error(request: Pointer;
  error: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_finish_error';

// --- libgio-2.0.so.0 ---

function g_memory_input_stream_new_from_data(data: Pointer; len: TGSSize;
  destroy: TGDestroyNotify): Pointer; cdecl;
  external GIO_LIB name 'g_memory_input_stream_new_from_data';

// --- libgobject-2.0.so.0 ---

procedure g_object_unref(&object: Pointer); cdecl;
  external GOBJECT_LIB name 'g_object_unref';

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
  body, stream: Pointer;
  size: PtrInt;
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
    webkit_uri_scheme_request_finish(request, stream, TGInt64(size),
      PAnsiChar(mime));
    g_object_unref(stream); // the request holds its own reference
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
