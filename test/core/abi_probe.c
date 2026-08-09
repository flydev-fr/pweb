/*
 * C side of the paired ABI probe (CAP-1).
 *
 * Compiled with MSVC against the PINNED upstream headers (deps/webview,
 * fetched by tools/get-webview.ps1). Emits one "key=value" line per measured
 * ABI fact on stdout, sorted by construction. The Pascal probe
 * (test/core/abi_probe.pas) emits the exact same lines from the generated
 * binding; any diff between the two outputs is a CAP-1 blocker.
 *
 * Facts are MEASURED (sizeof / offsetof / real enum constants / signedness
 * via (T)-1 < 0), never transcribed from documentation.
 */

#include <stdio.h>
#include <stddef.h>
#include <string.h>

#include "webview/api.h"

typedef void (*probe_dispatch_fn)(webview_t w, void *arg);
typedef void (*probe_bind_fn)(const char *id, const char *req, void *arg);

/* Compile-level signature checks: re-declaring an already declared function
 * with a DIFFERENT prototype is a hard error in C. Every one of the 17
 * pinned entry points is re-declared below with the prototype this project
 * depends on; if any signature drifts from the pinned api.h, this file stops
 * compiling. No link dependency is created.
 */
WEBVIEW_API webview_t webview_create(int debug, void *window);
WEBVIEW_API webview_error_t webview_destroy(webview_t w);
WEBVIEW_API webview_error_t webview_run(webview_t w);
WEBVIEW_API webview_error_t webview_terminate(webview_t w);
WEBVIEW_API webview_error_t webview_dispatch(webview_t w, probe_dispatch_fn fn,
                                             void *arg);
WEBVIEW_API void *webview_get_window(webview_t w);
WEBVIEW_API void *webview_get_native_handle(webview_t w,
                                            webview_native_handle_kind_t kind);
WEBVIEW_API webview_error_t webview_set_title(webview_t w, const char *title);
WEBVIEW_API webview_error_t webview_set_size(webview_t w, int width, int height,
                                             webview_hint_t hints);
WEBVIEW_API webview_error_t webview_navigate(webview_t w, const char *url);
WEBVIEW_API webview_error_t webview_set_html(webview_t w, const char *html);
WEBVIEW_API webview_error_t webview_init(webview_t w, const char *js);
WEBVIEW_API webview_error_t webview_eval(webview_t w, const char *js);
WEBVIEW_API webview_error_t webview_bind(webview_t w, const char *name,
                                         probe_bind_fn fn, void *arg);
WEBVIEW_API webview_error_t webview_unbind(webview_t w, const char *name);
WEBVIEW_API webview_error_t webview_return(webview_t w, const char *id,
                                           int status, const char *result);
WEBVIEW_API const webview_version_info_t *webview_version(void);

#define P_SIZE(name, type) printf("sizeof." name "=%u\n", (unsigned)sizeof(type))
#define P_OFF(rec, field) \
  printf("offset." #rec "." #field "=%u\n", (unsigned)offsetof(rec, field))
#define P_ENUM(name) printf("enum." #name "=%d\n", (int)(name))
#define P_SIGNED(name, type) \
  printf("signed." name "=%d\n", (int)((type)-1 < 0))

int main(void) {
  /* error enum */
  P_SIZE("webview_error_t", webview_error_t);
  P_SIGNED("webview_error_t", webview_error_t);
  P_ENUM(WEBVIEW_ERROR_MISSING_DEPENDENCY);
  P_ENUM(WEBVIEW_ERROR_CANCELED);
  P_ENUM(WEBVIEW_ERROR_INVALID_STATE);
  P_ENUM(WEBVIEW_ERROR_INVALID_ARGUMENT);
  P_ENUM(WEBVIEW_ERROR_UNSPECIFIED);
  P_ENUM(WEBVIEW_ERROR_OK);
  P_ENUM(WEBVIEW_ERROR_DUPLICATE);
  P_ENUM(WEBVIEW_ERROR_NOT_FOUND);

  /* size hint enum */
  P_SIZE("webview_hint_t", webview_hint_t);
  P_SIGNED("webview_hint_t", webview_hint_t);
  P_ENUM(WEBVIEW_HINT_NONE);
  P_ENUM(WEBVIEW_HINT_MIN);
  P_ENUM(WEBVIEW_HINT_MAX);
  P_ENUM(WEBVIEW_HINT_FIXED);

  /* native handle kind enum */
  P_SIZE("webview_native_handle_kind_t", webview_native_handle_kind_t);
  P_SIGNED("webview_native_handle_kind_t", webview_native_handle_kind_t);
  P_ENUM(WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW);
  P_ENUM(WEBVIEW_NATIVE_HANDLE_KIND_UI_WIDGET);
  P_ENUM(WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);

  /* opaque handle */
  P_SIZE("webview_t", webview_t);

  /* version triple */
  P_SIZE("webview_version_t", webview_version_t);
  P_OFF(webview_version_t, major);
  P_OFF(webview_version_t, minor);
  P_OFF(webview_version_t, patch);

  /* per-field signedness, measured: fill with 0xFF, then an unsigned field
     reads as a huge positive value while a signed one reads negative. The
     (x > 0 ? 0 : 1) form avoids compile-time constant-comparison warnings
     that a direct (x < 0) would raise for unsigned fields under /W4 /WX. */
  {
    webview_version_t v;
    memset(&v, 0xFF, sizeof(v));
    printf("signed.webview_version_t.major=%d\n", (v.major > 0) ? 0 : 1);
    printf("signed.webview_version_t.minor=%d\n", (v.minor > 0) ? 0 : 1);
    printf("signed.webview_version_t.patch=%d\n", (v.patch > 0) ? 0 : 1);
  }

  /* version info */
  P_SIZE("webview_version_info_t", webview_version_info_t);
  P_OFF(webview_version_info_t, version);
  P_OFF(webview_version_info_t, version_number);
  P_OFF(webview_version_info_t, pre_release);
  P_OFF(webview_version_info_t, build_metadata);

  /* callback function pointers (width; convention is checked at compile
     level: the typedefs below must be assignable from the api.h callback
     parameter types or this file does not compile) */
  P_SIZE("fnptr.webview_dispatch_fn", probe_dispatch_fn);
  P_SIZE("fnptr.webview_bind_fn", probe_bind_fn);

  return 0;
}
