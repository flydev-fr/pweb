/*
 * C side of the paired ABI probe for the hand-declared WebKitGTK/GLib
 * externals (CAP-7L).
 *
 * Ratified at CAP-7L checkpoint 1: src/platform/linux/pweb.platform.webkitgtk.pas
 * reaches WebKitGTK and GLib through PRIVATE hand-written externals rather
 * than a second chet binding or a C shim library. The condition attached to
 * that ratification is this file plus its Pascal twin: the scalars carrying
 * those calls must be MEASURED identical on both sides, and every symbol must
 * be proven present in the distro .so it is declared against
 * (test/cap7l/check_abi.sh does the nm -D half).
 *
 * Compiled with the distro GCC against the REAL headers of the ratified
 * stack (webkit2gtk-4.1 + gtk+-3.0, via pkg-config). Emits one "key=value"
 * line per measured fact on stdout, sorted by construction; the Pascal probe
 * (test/cap7l/abi_probe_gtk.pas) emits the exact same lines from the unit's
 * own declarations. Unlike the core webview probe, this pair has NO permitted
 * delta: any diff at all is a blocker.
 *
 * Facts are MEASURED (sizeof / signedness via (T)-1 < 0), never transcribed.
 * That idiom is why check_abi.sh compiles this file with -Wno-type-limits:
 * for an unsigned type the comparison is provably false, which is exactly
 * the fact being recorded, not a defect. Every other warning still blocks.
 *
 * Deliberately NOT measured: the signedness of gchar. Plain char is signed on
 * x86_64 Linux and FPC's AnsiChar is unsigned, but no declaration here passes
 * a gchar BY VALUE - every string crosses as a `const gchar *` / PAnsiChar,
 * where the contract is pointer width plus NUL termination, both of which are
 * measured. Emitting a delta that no call could ever observe would only
 * teach the gate to tolerate deltas.
 */

#include <stdio.h>
#include <stddef.h>

#include <glib.h>
#include <gio/gio.h>
#include <webkit2/webkit2.h>

/* Compile-level signature checks: re-declaring an already declared function
 * with a DIFFERENT prototype is a hard error in C. Every external the Linux
 * platform unit hand-declares is re-declared below with the prototype that
 * unit depends on; if any signature drifts from the installed headers, this
 * file stops compiling. No link dependency is created by the declarations
 * themselves.
 */
WebKitWebContext *webkit_web_view_get_context(WebKitWebView *web_view);
WebKitSecurityManager *webkit_web_context_get_security_manager(
    WebKitWebContext *context);
void webkit_security_manager_register_uri_scheme_as_secure(
    WebKitSecurityManager *security_manager, const gchar *scheme);
void webkit_security_manager_register_uri_scheme_as_cors_enabled(
    WebKitSecurityManager *security_manager, const gchar *scheme);
void webkit_web_context_register_uri_scheme(
    WebKitWebContext *context, const gchar *scheme,
    WebKitURISchemeRequestCallback callback, gpointer user_data,
    GDestroyNotify user_data_destroy_func);
const gchar *webkit_uri_scheme_request_get_uri(WebKitURISchemeRequest *request);
void webkit_uri_scheme_request_finish(WebKitURISchemeRequest *request,
                                      GInputStream *stream,
                                      gint64 stream_length,
                                      const gchar *content_type);
void webkit_uri_scheme_request_finish_error(WebKitURISchemeRequest *request,
                                            GError *error);
GInputStream *g_memory_input_stream_new_from_data(const void *data, gssize len,
                                                  GDestroyNotify destroy);
void g_object_unref(gpointer object);
void g_free(gpointer mem);
gpointer g_try_malloc(gsize n_bytes);
GQuark g_quark_from_static_string(const gchar *string);
GError *g_error_new_literal(GQuark domain, gint code, const gchar *message);
void g_error_free(GError *error);

/* The callback typedefs the unit declares, checked for assignability against
 * the real ones: a convention or parameter-list drift stops compilation. */
typedef void (*probe_destroy_notify)(gpointer data);
typedef void (*probe_uri_scheme_cb)(WebKitURISchemeRequest *request,
                                    gpointer user_data);

static void probe_destroy_impl(gpointer data) { (void)data; }
static void probe_scheme_impl(WebKitURISchemeRequest *request,
                              gpointer user_data) {
  (void)request;
  (void)user_data;
}

#define P_SIZE(name, type) printf("sizeof." name "=%u\n", (unsigned)sizeof(type))
#define P_SIGNED(name, type) \
  printf("signed." name "=%d\n", (int)((type)-1 < 0))

int main(void) {
  /* assignability of our typedefs to the library's own - a hard error if the
     shapes differ, and it keeps the impls referenced under -Wall -Werror */
  GDestroyNotify real_destroy = (GDestroyNotify)probe_destroy_impl;
  WebKitURISchemeRequestCallback real_scheme =
      (WebKitURISchemeRequestCallback)probe_scheme_impl;
  probe_destroy_notify ours_destroy = real_destroy;
  probe_uri_scheme_cb ours_scheme = real_scheme;
  if ((ours_destroy == NULL) || (ours_scheme == NULL)) {
    return 100;
  }

  /* integer scalars carried by the declared signatures */
  P_SIZE("gint", gint);
  P_SIGNED("gint", gint);
  P_SIZE("gint64", gint64);
  P_SIGNED("gint64", gint64);
  P_SIZE("gsize", gsize);
  P_SIGNED("gsize", gsize);
  P_SIZE("gssize", gssize);
  P_SIGNED("gssize", gssize);
  P_SIZE("GQuark", GQuark);
  P_SIGNED("GQuark", GQuark);

  /* opaque handles and string elements */
  P_SIZE("gpointer", gpointer);
  P_SIZE("gchar", gchar);

  /* callback function pointers (width; convention is checked at compile
     level by the assignments above) */
  P_SIZE("fnptr.GDestroyNotify", probe_destroy_notify);
  P_SIZE("fnptr.WebKitURISchemeRequestCallback", probe_uri_scheme_cb);

  return 0;
}
