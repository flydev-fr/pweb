unit pweb.lib.webview.types;

{ Type view over the generated raw binding (pweb.lib.webview.pas).

  This unit contains NO ABI facts of its own: every declaration is a pure
  alias of an identifier in the chet-cli-generated core unit. If upstream
  renames or removes a symbol, regeneration of the core unit makes this view
  fail to compile -- it can never drift silently.

  Raw layer rules apply: RTL only, no logic, handles stay opaque. }

{$MODE OBJFPC}{$H+}

interface

uses
  pweb.lib.webview;

type
  /// Opaque pointer to a webview instance. Never dereference.
  webview_t = pweb.lib.webview.webview_t;

  /// Window size hint (4-byte integer at the C ABI; see abi probe).
  webview_hint_t = pweb.lib.webview.webview_hint_t;
  Pwebview_hint_t = pweb.lib.webview.Pwebview_hint_t;

  /// Native handle kind selector for webview_get_native_handle.
  webview_native_handle_kind_t = pweb.lib.webview.webview_native_handle_kind_t;
  Pwebview_native_handle_kind_t = pweb.lib.webview.Pwebview_native_handle_kind_t;

  /// MAJOR.MINOR.PATCH version triple.
  webview_version_t = pweb.lib.webview.webview_version_t;
  Pwebview_version_t = pweb.lib.webview.Pwebview_version_t;

  /// Full library version information (returned by webview_version).
  webview_version_info_t = pweb.lib.webview.webview_version_info_t;
  Pwebview_version_info_t = pweb.lib.webview.Pwebview_version_info_t;

  /// Callback for webview_dispatch. cdecl; runs on the run/event-loop thread.
  webview_dispatch_fn = pweb.lib.webview.webview_dispatch_fn;

  /// Callback for webview_bind. cdecl; id/req are only valid for the duration
  /// of the callback -- copy immediately (see docs/webview-upstream-semantics.md).
  webview_bind_fn = pweb.lib.webview.webview_bind_fn;

const
  WEBVIEW_HINT_NONE  = pweb.lib.webview.WEBVIEW_HINT_NONE;
  WEBVIEW_HINT_MIN   = pweb.lib.webview.WEBVIEW_HINT_MIN;
  WEBVIEW_HINT_MAX   = pweb.lib.webview.WEBVIEW_HINT_MAX;
  WEBVIEW_HINT_FIXED = pweb.lib.webview.WEBVIEW_HINT_FIXED;

  WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW =
    pweb.lib.webview.WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW;
  WEBVIEW_NATIVE_HANDLE_KIND_UI_WIDGET =
    pweb.lib.webview.WEBVIEW_NATIVE_HANDLE_KIND_UI_WIDGET;
  WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER =
    pweb.lib.webview.WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER;

implementation

end.
