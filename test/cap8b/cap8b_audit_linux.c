/*
 * CAP-8B Linux/WebKitGTK 4.1 MEASUREMENT probe.
 *
 * This is an AUDIT INSTRUMENT, not production and not a gate of the shipped
 * policy. It is the Linux sibling of test/cap8b/cap8b_audit_win.cpp - same
 * ten phases, same fixture corpus, same JS drivers, same schema-1 document -
 * and it answers, with real runtime evidence rather than API names, the three
 * questions CAP-8B's Checkpoint 1 is not allowed to assume:
 *
 *   1. BRIDGE EXPOSURE - from which frame/window contexts is the privileged
 *      native binding reachable, through the public shim AND through the
 *      lowest raw transport the engine leaves exposed?
 *   2. NAVIGATION COVERAGE - for each navigation kind, does the proposed
 *      native hook OBSERVE it, and can it CANCEL it before content executes?
 *   3. ACTIVE SUBRESOURCES - is a Content-Security-Policy delivered as a
 *      RESPONSE HEADER on the custom scheme actually enforced, and can a
 *      bundle <meta> CSP weaken it?
 *
 * WHY THE RAW TRANSPORT IS THE POINT ON THIS ENGINE. MEASURED from the pinned
 * upstream source (deps/webview .../detail/backends/gtk_webkitgtk.hh): upstream
 * injects its user script with WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, so the
 * `window.__webview__` shim - and therefore `window.__pweb_invoke`, which the
 * shim defines - exists in the TOP DOCUMENT ONLY. But upstream registers the
 * "__webview__" SCRIPT MESSAGE HANDLER on the page's WebKitUserContentManager,
 * and WebKit exposes a user-content message handler in EVERY frame of the page.
 * The raw channel
 *
 *     window.webkit.messageHandlers.__webview__.postMessage(<json string>)
 *
 * is therefore reachable from places the shim is not, and it is the lowest path
 * a hostile document can take. Measuring only the shim would be worthless, so
 * every context here attacks BOTH, and the NATIVE arrival counter - never the
 * page's own optimism - is the authority on what actually reached native.
 *
 * It is written in C against the REAL pinned distro headers on purpose: the
 * production Pascal adapter hand-declares those externals, and a measurement
 * taken through a hand transcription cannot distinguish "the engine behaves
 * like this" from "my declaration is wrong". The same reasoning produced
 * test/cap7l/cap7l_probe.c and test/cap4w/cap4w_probe.cpp, whose structure
 * this file follows deliberately.
 *
 * WHAT THIS FILE IS NOT. It is not part of the product. It includes, links and
 * modifies NOTHING under src/ - not pweb.platform.webkitgtk.pas, not the asset
 * stores, not the capability engine. The corpus, the scheme filter, the
 * "trusted" predicate and the bindings all live in this file and are
 * deliberately cruder than the product's. It serves its corpus from memory and
 * never touches disk.
 *
 * DELIBERATELY HOSTILE FIXTURE. This probe serves content under the
 * pweb://evil authority on
 * purpose - that is the untrusted document whose reach is being measured.
 *
 * ZERO NETWORK, and on this engine with a floor the Windows probe does not
 * need. Every "external" URI targets the reserved TLD example.invalid
 * (RFC 6761: guaranteed never to resolve), and both redirect cases are
 * produced by the probe's OWN 302 responses, never by a server. On top of that,
 * CapUriIsOffline() denies at decide-policy - in EVERY phase, including the two
 * CSP phases where the Windows probe cancels nothing - any navigation whose
 * scheme is not one of pweb:, about:, data:, blob:. That floor is invisible to
 * the page-side reports (a CSP-blocked frame produces no policy decision at
 * all, so "CSP blocked it" and "the floor blocked it" stay distinguishable in
 * the event log) and it guarantees that a CSP the engine turns out NOT to
 * enforce still cannot cause a request to leave the machine.
 *
 * THE ONE STRUCTURAL DIVERGENCE FROM THE WINDOWS PROBE, and it is a MEASURED
 * consequence rather than a choice. The cancelling RULE is the same on both:
 * untrusted navigations are cancelled in any frame and trusted ones are
 * allowed - deliberately WEAKER than the production rule, so that the trusted
 * FIRST LEG of the redirect and download probes actually runs instead of being
 * cancelled and silently never measured. What differs is what an event can
 * SAY about itself. WebView2 reaches that rule through TWO hooks,
 * NavigationStarting and FrameNavigationStarting, so a Windows event always
 * knows which frame it belongs to. WebKitGTK has ONE hook, decide-policy, and
 * whether it can tell a main-frame navigation from a subframe one is the
 * CRITICAL OPEN QUESTION this probe measures - CapProbeSymbols, below,
 * resolves the candidate accessors against the INSTALLED library rather than
 * trusting a header, and every event then carries the answer as main-frame=.
 * Where no discriminator exists, a navigation-time subframe rule on this
 * engine can only ever be URI-based and CSP frame-src becomes the primary
 * subframe defence: a first-class finding about the engine, not a gap in the
 * instrument.
 *
 * EXCEPTION BARRIERS. C has no exceptions, so the barrier here is the GLib
 * one: every GError is consumed and freed at the callback boundary, no callback
 * calls g_error()/abort(), and every WebKitPolicyDecision is completed EXACTLY
 * ONCE on every path - including allocation failure and unknown decision types,
 * which fail CLOSED with webkit_policy_decision_ignore(). An undecided policy
 * DEFAULTS TO ALLOW on this engine, so "return without deciding" is never an
 * option: every branch decides and returns TRUE.
 *
 * WHAT IS NOT A FAILURE. A measurement that says "this engine does not expose
 * that" is a RESULT. The probe exits nonzero only when it could not MEASURE -
 * no display, no WebKitGTK, or the document could not be written - never
 * because a measured value was inconvenient.
 *
 * DERIVED IS NOT MEASURED, and the schema says which is which. A field that
 * reads "false" when the engine was never asked is worse than a missing field,
 * because it silently produces a cross-target comparison that means nothing.
 * So every event carries "user_initiated_basis" - the string that says HOW that
 * row's user_initiated was obtained, "engine:<accessor>" or "unavailable:<why>"
 * - and "user_initiated" itself is JSON null, never false, on any row where
 * this engine exposes no gesture flag (response decisions, action-less
 * decisions, started downloads). "policy" separates a hook that can REFUSE from
 * one that merely observes, so a target with more observation hooks cannot look
 * like it cancelled more, and "detail" is a free-form per-hook string no
 * consumer parses. The document-level "user_initiated_semantics" is the one
 * sentence a reader puts at the head of that column. Same fields, same order
 * and same meaning as the Windows reference, which is the normative one.
 *
 * The same rule governs "download_hook_available": it reports whether
 * "download-started" ACTUALLY FIRED, never whether g_signal_lookup finds the
 * signal, and a note states plainly which of those the value came from. A
 * download only becomes reachable on this engine because the response decision
 * for an undisplayable MIME type is converted with
 * webkit_policy_decision_download() rather than ignored; the download it
 * creates is then refused unconditionally, before any destination is chosen.
 *
 * TERMINATION. Each phase runs its own webview and its own watchdog thread with
 * its own deadline; a phase that exists to observe ONE navigation ends the
 * moment that navigation is observed rather than burning its whole budget.
 *
 * HEADLESS. The probe sets WEBKIT_DISABLE_COMPOSITING_MODE,
 * WEBKIT_DISABLE_DMABUF_RENDERER, GDK_BACKEND and LIBGL_ALWAYS_SOFTWARE itself
 * with setenv(..., 0) - the same guards test/cap7l/run_gui_matrix.sh and
 * test/cap8b/run_audit_linux.sh export - so a bare
 * `xvfb-run -a cap8b_audit_linux out.json` behaves identically to the harness.
 * overwrite=0: an explicit value from the runner always wins.
 *
 * Masking the FPU traps is NOT needed here: this is C, not FPC, so the SSE and
 * x87 exception masks are already the C runtime's defaults. The Pascal
 * adapter's initialization section exists for exactly the opposite reason.
 *
 * Usage: cap8b_audit_linux <output.json>
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <gio/gio.h>
#include <glib.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

/* libsoup-3.0 is less an extra dependency than an admission of one:
   webkit2gtk-4.1 IS the libsoup3 flavour of the API (4.0 is the libsoup2 one),
   and SoupMessageHeaders is the ONLY public vehicle for a response header on a
   custom scheme. The build script decides this define from
   `pkg-config --exists libsoup-3.0`; defaulting to 1 keeps a hand compile on
   the ratified stack working. */
#ifndef CAP8B_HAVE_SOUP3
#define CAP8B_HAVE_SOUP3 1
#endif
#if CAP8B_HAVE_SOUP3
#include <libsoup/soup.h>
#endif

/* webkit_uri_scheme_request_finish() carries NO headers at all - not one.
   webkit_uri_scheme_request_finish_with_response(), with a response built by
   webkit_uri_scheme_response_new() and given headers by
   webkit_uri_scheme_response_set_http_headers(), is the only public path that
   can deliver a Content-Security-Policy on pweb://. All of it arrived in
   WebKitGTK 2.36; Ubuntu 24.04 ships 2.44+, so the ratified stack has it. If a
   build ever lands on an older library the probe still compiles, RECORDS that
   fact, and falls back to finish() - it never silently skips the CSP phase. */
#if CAP8B_HAVE_SOUP3 && WEBKIT_CHECK_VERSION(2, 36, 0)
#define CAP8B_RESPONSE_API 1
#else
#define CAP8B_RESPONSE_API 0
#endif

#include "webview/api.h"

#define CAP8B_SCHEME "pweb"

/* ------------------------------------------------------------------ */
/* small helpers                                                       */
/* ------------------------------------------------------------------ */

/* The probe emits its own JSON so the harness never has to trust a
   page-supplied string to be well formed: every page report crosses this
   escaper before it lands in the artifact. Byte-for-byte the same rules as the
   Windows probe's JStr(), surrounding quotes included. */
static char *CapJStr(const char *s) {
  GString *o = g_string_new("\"");
  const unsigned char *p = (const unsigned char *)((s == NULL) ? "" : s);

  for (; *p != '\0'; ++p) {
    switch (*p) {
    case '"':
      g_string_append(o, "\\\"");
      break;
    case '\\':
      g_string_append(o, "\\\\");
      break;
    case '\n':
      g_string_append(o, "\\n");
      break;
    case '\r':
      g_string_append(o, "\\r");
      break;
    case '\t':
      g_string_append(o, "\\t");
      break;
    default:
      if (*p < 0x20) {
        g_string_append_printf(o, "\\u%04x", (unsigned)*p);
      } else {
        g_string_append_c(o, (gchar)*p);
      }
    }
  }
  g_string_append_c(o, '"');
  return g_string_free(o, FALSE);
}

static const char *CapJBool(gboolean b) { return b ? "true" : "false"; }

static void CapAppendUtf8(GString *out, unsigned int cp) {
  if (cp < 0x80) {
    g_string_append_c(out, (gchar)cp);
  } else if (cp < 0x800) {
    g_string_append_c(out, (gchar)(0xC0 | (cp >> 6)));
    g_string_append_c(out, (gchar)(0x80 | (cp & 0x3F)));
  } else {
    g_string_append_c(out, (gchar)(0xE0 | (cp >> 12)));
    g_string_append_c(out, (gchar)(0x80 | ((cp >> 6) & 0x3F)));
    g_string_append_c(out, (gchar)(0x80 | (cp & 0x3F)));
  }
}

/* Extract and UNESCAPE the first JSON string literal of a webview_bind request
   payload. The payload is always a params array whose first element this probe
   controls, so a full JSON parser would be ceremony - but the unescaping is not
   optional: the page reports are themselves JSON, so every quote inside them
   arrives escaped, and handing the raw array on would make every consumer of
   the artifact unwrap it twice. Byte-for-byte the same rules as the Windows
   probe's FirstJsonString(), \uXXXX included. */
static char *CapFirstJsonString(const char *request) {
  GString *out = NULL;
  const char *at = NULL;
  gsize len = 0;
  gsize i = 0;

  if (request == NULL) {
    return g_strdup("<unparsed>");
  }
  at = strchr(request, '"');
  if (at == NULL) {
    return g_strdup("<unparsed>");
  }
  len = strlen(request);
  out = g_string_new(NULL);
  for (i = (gsize)(at - request) + 1; i < len; ++i) {
    const char c = request[i];

    if (c == '"') {
      return g_string_free(out, FALSE);
    }
    if (c != '\\') {
      g_string_append_c(out, c);
      continue;
    }
    if ((i + 1) >= len) {
      break;
    }
    {
      const char esc = request[++i];

      switch (esc) {
      case 'n':
        g_string_append_c(out, '\n');
        break;
      case 'r':
        g_string_append_c(out, '\r');
        break;
      case 't':
        g_string_append_c(out, '\t');
        break;
      case 'b':
        g_string_append_c(out, '\b');
        break;
      case 'f':
        g_string_append_c(out, '\f');
        break;
      case 'u': {
        unsigned int cp = 0;
        gboolean ok = TRUE;
        int k = 0;

        if ((i + 4) >= len) {
          return g_string_free(out, FALSE);
        }
        for (k = 1; k <= 4; ++k) {
          const char h = request[i + (gsize)k];

          cp <<= 4;
          if ((h >= '0') && (h <= '9')) {
            cp |= (unsigned int)(h - '0');
          } else if ((h >= 'a') && (h <= 'f')) {
            cp |= (unsigned int)(h - 'a' + 10);
          } else if ((h >= 'A') && (h <= 'F')) {
            cp |= (unsigned int)(h - 'A' + 10);
          } else {
            ok = FALSE;
            break;
          }
        }
        if (!ok) {
          g_string_append(out, "\\u");
          break;
        }
        CapAppendUtf8(out, cp);
        i += 4;
        break;
      }
      default:
        g_string_append_c(out, esc);
        break;
      }
    }
  }
  g_string_free(out, TRUE);
  return g_strdup("<unterminated>");
}

/* Replace the FIRST occurrence of needle; the haystack is never modified. */
static char *CapReplaceFirst(const char *haystack, const char *needle,
                             const char *replacement) {
  const char *at = strstr(haystack, needle);
  GString *o = NULL;

  if (at == NULL) {
    return g_strdup(haystack);
  }
  o = g_string_new_len(haystack, (gssize)(at - haystack));
  g_string_append(o, replacement);
  g_string_append(o, at + strlen(needle));
  return g_string_free(o, FALSE);
}

static gboolean CapHasPrefix(const char *s, const char *prefix) {
  return (s != NULL) && (g_str_has_prefix(s, prefix) != FALSE);
}

/* ------------------------------------------------------------------ */
/* phases                                                              */
/* ------------------------------------------------------------------ */

/* The activation phases each get their own fresh WebView on purpose. MEASURED
   on WebView2: a navigation performed in the continuation of a webview_bind
   promise reports IsUserInitiated = TRUE, because upstream resolves that
   promise through host-injected script and the engine runs host script WITH a
   user gesture. WebKitGTK resolves the same promise through
   webkit_web_view_evaluate_javascript, and whether THAT carries a gesture is
   exactly what the activation-bind phase measures rather than assumes. Any
   driver that calls a native binding between cases would contaminate every
   later reading - which is why the coverage driver below makes NO native call
   until its final report, and why each activation control gets a fresh
   WebView and a page that calls nothing it does not have to. */
enum CapPhaseKind {
  CAP_PHASE_EXPOSURE,
  CAP_PHASE_COVERAGE,
  CAP_PHASE_CSP,
  CAP_PHASE_CSP_META,
  CAP_PHASE_ACT_PLAIN,
  CAP_PHASE_ACT_BIND,
  CAP_PHASE_ACT_EVAL,
  CAP_PHASE_ACT_CLICK,
  CAP_PHASE_REDIRECT_EXTERNAL,
  CAP_PHASE_REDIRECT_INTERNAL
};

/* ------------------------------------------------------------------ */
/* the JS drivers                                                      */
/* ------------------------------------------------------------------ */

/* The script every CHILD context runs. It reports what it can SEE and then
   attempts the bridge two ways: through the public shim, and through the RAW
   transport with the upstream envelope shape - which is the lowest path a page
   can reach and the one an isolation proof must attack. The native arrival
   counters, not this script's own optimism, are the authority on what actually
   reached native.

   Identical to the Windows probe's kChildJs - same record shape, same field
   names, same reporting path - with ONE deliberate divergence: the raw
   transport. On WebKit engines the lowest exposed channel is the user-content
   script message handler, not window.chrome.webview. */
static const char kChildJs[] =
    "(function(){\n"
    "  var ctx = window.__cap8b_ctx || 'unknown';\n"
    "  var out = { ctx: ctx, shim: (typeof window.__pweb_invoke),\n"
    "              webview: (typeof window.__webview__), raw: false,\n"
    "              origin: '?', shimThrew: null, rawThrew: null };\n"
    "  try { out.origin = String(location.origin); } catch (e) {}\n"
    "  try { out.raw = !!(window.webkit && window.webkit.messageHandlers &&\n"
    "        window.webkit.messageHandlers.__webview__ &&\n"
    "        typeof window.webkit.messageHandlers.__webview__.postMessage ===\n"
    "          'function'); }\n"
    "  catch (e) { out.raw = false; }\n"
    "  try {\n"
    "    if (typeof window.__pweb_invoke === 'function') {\n"
    "      window.__pweb_invoke('shim.' + ctx, null);\n"
    "    }\n"
    "  } catch (e) { out.shimThrew = String(e); }\n"
    "  try {\n"
    "    if (out.raw) {\n"
    "      window.webkit.messageHandlers.__webview__.postMessage(\n"
    "        JSON.stringify({\n"
    "        id: 'a-' + ctx, method: '__pweb_invoke',\n"
    "        params: ['raw.' + ctx, null] }));\n"
    "    }\n"
    "  } catch (e) { out.rawThrew = String(e); }\n"
    "  try { (window.opener || window.parent).postMessage(\n"
    "          JSON.stringify(out), '*'); } catch (e) {}\n"
    "})();\n";

/* The exposure orchestrator. Builds every context the audit must cover, then
   reports the collected child records plus its own. __CHILDJS__ is replaced by
   the child source as a JS string literal before this is served. Verbatim from
   the Windows probe except for the same raw-transport substitution. */
static const char kExposureJs[] =
    "(function(){\n"
    "  var CHILD = __CHILDJS__;\n"
    "  var recs = [];\n"
    "  window.addEventListener('message', function (ev) {\n"
    "    try { recs.push(JSON.parse(String(ev.data))); } catch (e) {}\n"
    "  });\n"
    "  window.__cap8b_ctx = 'top-trusted';\n"
    "  function frame(id, src) {\n"
    "    var f = document.createElement('iframe');\n"
    "    f.id = id; f.src = src;\n"
    "    document.body.appendChild(f);\n"
    "    return f;\n"
    "  }\n"
    "  frame('same', 'pweb://app/child.html?ctx=iframe-same-origin');\n"
    "  frame('evil', 'pweb://evil/child.html?ctx=iframe-wrong-authority');\n"
    "  var dataDoc = '<html><body><scr' + 'ipt>' +\n"
    "    \"window.__cap8b_ctx='iframe-data';\" + CHILD +\n"
    "    '</scr' + 'ipt></body></html>';\n"
    "  frame('dat', 'data:text/html,' + encodeURIComponent(dataDoc));\n"
    "  var blank = frame('blk', 'about:blank');\n"
    "  var opened = null;\n"
    "  var openThrew = null;\n"
    "  try { opened = window.open('pweb://app/child.html?ctx=window-open',\n"
    "                             'cap8bwin'); }\n"
    "  catch (e) { openThrew = String(e); }\n"
    "  setTimeout(function () {\n"
    "    /* an about:blank child inherits this document's origin, so the\n"
    "       parent can inject into it - the most privileged shape an\n"
    "       'empty' frame can take, and therefore the one worth measuring */\n"
    "    var injected = null;\n"
    "    try {\n"
    "      var cw = blank.contentWindow;\n"
    "      cw.__cap8b_ctx = 'iframe-about-blank';\n"
    "      var s = cw.document.createElement('script');\n"
    "      s.textContent = CHILD;\n"
    "      cw.document.body.appendChild(s);\n"
    "      injected = 'ok';\n"
    "    } catch (e) { injected = String(e); }\n"
    "    setTimeout(function () {\n"
    "      var self = { ctx: 'top-trusted',\n"
    "        shim: (typeof window.__pweb_invoke),\n"
    "        webview: (typeof window.__webview__), raw: false,\n"
    "        origin: String(location.origin), shimThrew: null,\n"
    "        rawThrew: null };\n"
    "      try { self.raw = !!(window.webkit &&\n"
    "        window.webkit.messageHandlers &&\n"
    "        window.webkit.messageHandlers.__webview__ &&\n"
    "        typeof window.webkit.messageHandlers.__webview__.postMessage ===\n"
    "          'function'); }\n"
    "      catch (e) {}\n"
    "      try { window.__pweb_invoke('shim.top-trusted', null); }\n"
    "      catch (e) { self.shimThrew = String(e); }\n"
    "      try { window.webkit.messageHandlers.__webview__.postMessage(\n"
    "        JSON.stringify({\n"
    "        id: 'a-top', method: '__pweb_invoke',\n"
    "        params: ['raw.top-trusted', null] })); }\n"
    "      catch (e) { self.rawThrew = String(e); }\n"
    "      recs.push(self);\n"
    "      window.__cap8b_report(JSON.stringify(\n"
    "        { records: recs, blankInjected: injected,\n"
    "          openThrew: openThrew,\n"
    "          openedWindow: (opened !== null && opened !== undefined) }));\n"
    "    }, 900);\n"
    "  }, 1600);\n"
    "})();\n";

/* The navigation-coverage driver. VERBATIM from the Windows probe, including
 * 'file:///C:/Windows/win.ini' - that is not an oversight. The four targets
 * must run byte-identical drivers or the comparison is meaningless, and the
 * measured question is whether a file: TOP-LEVEL navigation is observed and
 * cancellable, which the hook answers before any path is resolved or any byte
 * read. A Linux-flavoured path would change nothing except comparability.
 *
 * TWO STRUCTURAL RULES, both learned from a first Windows run that measured the
 * wrong thing:
 *
 *  1. IT MAKES NO NATIVE CALL until its final report. An earlier revision
 *     announced each case through a binding, and every subsequent navigation
 *     then read as user-initiated because the binding's promise resolution runs
 *     through host-injected script, which carries a user gesture. Cases are
 *     therefore attributed NATIVELY, by their unique URI (CapCaseForUri).
 *  2. THE DESTRUCTIVE CASES RUN IN A TRUSTED SUBFRAME. A redirect or a download
 *     driven from the top frame replaces the document and kills the driver. The
 *     hook sees a subframe redirect identically, and the page survives to
 *     finish the matrix. */
static const char kCoverageJs[] =
    "(async function(){\n"
    "  var results = [];\n"
    "  function sleep(ms) {\n"
    "    return new Promise(function (r) { setTimeout(r, ms); });\n"
    "  }\n"
    "  function frameTo(src) {\n"
    "    var f = document.createElement('iframe');\n"
    "    f.src = src; document.body.appendChild(f); return f;\n"
    "  }\n"
    "  /* A NATIVE progress mark that is NOT a binding call: it rides the\n"
    "     resource handler, so it involves no ExecuteScript, grants no user\n"
    "     gesture, and survives the document being torn down mid-case - which\n"
    "     is how the first run lost every case after the one that navigated\n"
    "     the driver away without telling anyone. */\n"
    "  function beacon(tag, name) {\n"
    "    try { new Image().src = 'pweb://app/beacon/' + tag + '/' + name; }\n"
    "    catch (e) {}\n"
    "  }\n"
    "  async function run(name, fn) {\n"
    "    beacon('enter', name);\n"
    "    var threw = null;\n"
    "    try { fn(); } catch (e) { threw = String(e); }\n"
    "    await sleep(600);\n"
    "    beacon('leave', name);\n"
    "    results.push({ name: name, threw: threw,\n"
    "                   href: String(location.href),\n"
    "                   marker: (window.__cap8b_marker || null) });\n"
    "  }\n"
    "  await run('script-location-external', function () {\n"
    "    location.href = 'https://example.invalid/top'; });\n"
    "  await run('script-window-open-external', function () {\n"
    "    window.open('https://example.invalid/win', '_blank'); });\n"
    "  await run('anchor-click-external', function () {\n"
    "    var a = document.createElement('a');\n"
    "    a.href = 'https://example.invalid/anchor';\n"
    "    a.textContent = 'x';\n"
    "    document.body.appendChild(a); a.click(); });\n"
    "  await run('anchor-click-blank-external', function () {\n"
    "    var a = document.createElement('a');\n"
    "    a.href = 'https://example.invalid/blank';\n"
    "    a.target = '_blank'; a.textContent = 'y';\n"
    "    document.body.appendChild(a); a.click(); });\n"
    "  await run('subframe-external', function () {\n"
    "    frameTo('https://example.invalid/frame'); });\n"
    "  await run('subframe-wrong-authority', function () {\n"
    "    frameTo('pweb://evil/child.html?ctx=cov-frame'); });\n"
    "  await run('subframe-trusted', function () {\n"
    "    frameTo('pweb://app/child.html?ctx=cov-frame-trusted'); });\n"
    "  await run('form-submit-external', function () {\n"
    "    var f = document.createElement('form');\n"
    "    f.method = 'POST'; f.action = 'https://example.invalid/form';\n"
    "    document.body.appendChild(f); f.submit(); });\n"
    "  await run('redirect-out-of-pweb', function () {\n"
    "    frameTo('pweb://app/redirect-external'); });\n"
    "  await run('meta-refresh-external', function () {\n"
    "    frameTo('pweb://app/metarefresh.html'); });\n"
    "  await run('download', function () {\n"
    "    frameTo('pweb://app/download.bin'); });\n"
    "  await run('scheme-http', function () {\n"
    "    location.href = 'http://example.invalid/plain'; });\n"
    "  await run('scheme-file', function () {\n"
    "    location.href = 'file:///C:/Windows/win.ini'; });\n"
    "  await run('scheme-data', function () {\n"
    "    location.href = 'data:text/html,cap8b-data-top'; });\n"
    /* void(): a javascript: URL whose expression yields a STRING replaces the
       document with that string, which destroyed the driver - and every case
       after it - in an earlier run. The security question here is only
       "does it execute, and does the hook see it", so the destructive
       document-replacing form is deliberately not re-measured. */
    "  await run('scheme-javascript', function () {\n"
    "    location.href = "
    "'javascript:void(window.__cap8b_marker=\\'jsurl\\')'; });\n"
    "  await run('subframe-javascript', function () {\n"
    "    frameTo('javascript:void(0)'); });\n"
    "  await run('scheme-blob', function () {\n"
    "    var u = URL.createObjectURL(new Blob(['cap8b-blob-top'],\n"
    "      { type: 'text/html' }));\n"
    "    window.__cap8b_blob = u; location.href = u; });\n"
    "  await run('scheme-mailto', function () {\n"
    "    location.href = 'mailto:nobody@example.invalid'; });\n"
    "  await run('scheme-unknown', function () {\n"
    "    location.href = 'zzq://example.invalid/unknown'; });\n"
    "  await run('about-blank-late', function () {\n"
    "    location.href = 'about:blank'; });\n"
    "  await run('history-pushstate-back', function () {\n"
    "    history.pushState({}, '', 'pweb://app/index.html?pushed=1');\n"
    "    history.back(); });\n"
    "  await run('fragment-same-document', function () {\n"
    "    location.href = 'pweb://app/index.html#frag'; });\n"
    /* Authority confusion. What matters is not whether these load - the
       audit's own trust test is a crude prefix match - but WHAT URI THE HOOK
       IS HANDED, because that is what a production classifier would parse.
       If the engine folds 'APP' to 'app' before the event, a case-sensitive
       authority rule would disagree with the asset layer for no security
       gain; if it does not, the rule has to decide. Measured, not argued.
       On THIS engine there is a second reading in the same rows for free:
       the scheme handler is called with the whole URI, so the corpus router
       and decide-policy see the same authority spelling or they do not, and
       CAP-7L already measured that get_path() alone would have hidden it. */
    "  await run('authority-uppercase', function () {\n"
    "    frameTo('pweb://APP/child.html?ctx=cov-auth-upper'); });\n"
    "  await run('authority-suffix', function () {\n"
    "    frameTo('pweb://app.evil/child.html?ctx=cov-auth-suffix'); });\n"
    "  await run('authority-userinfo', function () {\n"
    "    frameTo('pweb://app@evil/child.html?ctx=cov-auth-userinfo'); });\n"
    "  await run('authority-port', function () {\n"
    "    frameTo('pweb://app:8080/child.html?ctx=cov-auth-port'); });\n"
    "  await run('authority-empty', function () {\n"
    "    frameTo('pweb:///child.html?ctx=cov-auth-empty'); });\n"
    "  var reloadFrame = frameTo('pweb://app/child.html?ctx=cov-reload');\n"
    "  await sleep(700);\n"
    "  await run('reload-trusted-subframe', function () {\n"
    "    reloadFrame.contentWindow.location.reload(); });\n"
    "  window.__cap8b_report(JSON.stringify({ cases: results,\n"
    "    finalHref: String(location.href) }));\n"
    "})();\n";

/* ---- the user-activation controls ----------------------------------------
 *
 * Each of these is a WHOLE PHASE with a fresh WebView and a page that makes no
 * native call before the navigation it is measuring, so the recorded
 * user-gesture flag belongs to that navigation and to nothing else. All four
 * are verbatim from the Windows probe. */

/* (a) plain script navigation from a timer: no gesture, no native call. */
static const char kActPlainJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'https://example.invalid/act-plain';\n"
    "}, 400);\n";

/* (b) script navigation in the continuation of a native binding promise - the
 *     shape every RPC-driven PWeb page actually has. On this engine that
 *     resolution travels webview_return -> dispatch ->
 *     webkit_web_view_evaluate_javascript, and whether WebKit attaches a user
 *     gesture to host-evaluated script is precisely what this measures. */
static const char kActBindJs[] =
    "setTimeout(function () {\n"
    "  window.__cap8b_ping('ping.act-bind').then(function () {\n"
    "    location.href = 'https://example.invalid/act-after-bind';\n"
    "  }, function () {\n"
    "    location.href = 'https://example.invalid/act-after-bind';\n"
    "  });\n"
    "}, 400);\n";

/* (c) navigation performed by script the HOST injected (webview_eval). The page
 *     itself does nothing; the native side drives it. */
static const char kActEvalJs[] = "window.__cap8b_ready = true;\n";

/* The redirect controls, top-frame, one per phase because a redirect that IS
   followed replaces the document.
     - external: the 302 points out of pweb://, and the question is whether a
       navigation hook ever sees the target;
     - internal: the 302 points at another pweb:// authority, which stays inside
       the probe's own scheme handler, so the handler being ASKED for the target
       proves the redirect was FOLLOWED. Without that second probe, "no event
       for the target" and "the redirect was never followed" are
       indistinguishable - and they have opposite security meanings. */
static const char kRedirectExternalJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'pweb://app/redirect-external';\n"
    "}, 400);\n";

static const char kRedirectInternalJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'pweb://app/redirect-internal';\n"
    "}, 400);\n";

/* (d) a REAL user gesture. The page lays the anchor over a large fixed
 *     rectangle at the client-area origin precisely so the native side can
 *     click it without ever asking the page where it is - a page->native
 *     question would itself grant the activation being measured. */
static const char kActClickJs[] =
    "document.body.style.margin = '0';\n"
    "var a = document.createElement('a');\n"
    "a.href = 'https://example.invalid/act-real-click';\n"
    "a.id = 'realclick'; a.textContent = 'real click';\n"
    "a.style.cssText = 'position:fixed;left:0;top:0;width:400px;"
    "height:200px;background:#0a0;display:block';\n"
    "document.body.appendChild(a);\n"
    "a.focus();\n";

/* The CSP driver. Each row is an INDEPENDENT observable: a directive that is
   silently not enforced must show up as a row that LOADED, never as an absence.
   The same-origin rows exist so that "everything blocked" - which would also
   satisfy a naive external-blocked assertion - is distinguishable from a policy
   that is actually usable. Verbatim from the Windows probe. */
static const char kCspJs[] =
    "(async function(){\n"
    "  function sleep(ms) {\n"
    "    return new Promise(function (r) { setTimeout(r, ms); });\n"
    "  }\n"
    "  var out = { violations: [], rows: {} };\n"
    "  document.addEventListener('securitypolicyviolation', function (e) {\n"
    "    out.violations.push({ directive: String(e.violatedDirective),\n"
    "                          blocked: String(e.blockedURI) });\n"
    "  });\n"
    "  out.rows['same-origin-script'] =\n"
    "    (window.__cap8b_same_origin === true) ? 'ran' : 'blocked';\n"
    "  out.rows['inline-script'] =\n"
    "    (window.__cap8b_inline === true) ? 'ran' : 'blocked';\n"
    "  out.rows['external-script'] = 'pending';\n"
    "  var s = document.createElement('script');\n"
    "  s.src = 'https://example.invalid/evil.js';\n"
    "  s.onload = function () { out.rows['external-script'] = 'loaded'; };\n"
    "  s.onerror = function () { out.rows['external-script'] = 'blocked'; };\n"
    "  document.head.appendChild(s);\n"
    "  var f = document.createElement('iframe');\n"
    "  f.src = 'https://example.invalid/frame';\n"
    "  document.body.appendChild(f);\n"
    "  var f2 = document.createElement('iframe');\n"
    "  f2.src = 'pweb://app/child.html?ctx=csp-frame';\n"
    "  document.body.appendChild(f2);\n"
    "  var o = document.createElement('object');\n"
    "  o.data = 'https://example.invalid/o.swf';\n"
    "  document.body.appendChild(o);\n"
    "  try {\n"
    "    await fetch('https://example.invalid/x');\n"
    "    out.rows['external-fetch'] = 'loaded';\n"
    "  } catch (e) { out.rows['external-fetch'] = 'blocked'; }\n"
    "  try {\n"
    "    var r = await fetch('pweb://app/child.html?ctx=csp-selffetch');\n"
    "    out.rows['same-origin-fetch'] =\n"
    "      r.ok ? 'loaded' : ('status-' + r.status);\n"
    "  } catch (e) { out.rows['same-origin-fetch'] = 'blocked'; }\n"
    "  try { new WebSocket('wss://example.invalid/ws');\n"
    "        out.rows['websocket'] = 'constructed';\n"
    "  } catch (e) { out.rows['websocket'] = 'blocked'; }\n"
    "  try { var w = new Worker('pweb://app/worker.js');\n"
    "        out.rows['worker'] = 'constructed'; w.terminate();\n"
    "  } catch (e) { out.rows['worker'] = 'blocked'; }\n"
    "  try { (0, eval)('window.__cap8b_eval = 1');\n"
    "        out.rows['eval'] = (window.__cap8b_eval === 1) ? 'ran' : 'no';\n"
    "  } catch (e) { out.rows['eval'] = 'blocked'; }\n"
    "  try {\n"
    "    var b = document.createElement('base');\n"
    "    b.href = 'https://example.invalid/';\n"
    "    document.head.appendChild(b);\n"
    "    var rel = document.createElement('a');\n"
    "    rel.setAttribute('href', 'rel.js');\n"
    "    out.rows['base-uri'] = (String(rel.href).indexOf('example.invalid')\n"
    "      >= 0) ? 'applied' : 'ignored';\n"
    "  } catch (e) { out.rows['base-uri'] = 'threw'; }\n"
    "  await sleep(1500);\n"
    "  function sawDirective(prefix) {\n"
    "    return out.violations.some(function (v) {\n"
    "      return v.directive.indexOf(prefix) === 0; });\n"
    "  }\n"
    "  out.rows['external-frame'] = sawDirective('frame-src')\n"
    "    ? 'blocked' : 'unknown';\n"
    "  out.rows['trusted-frame'] = sawDirective('frame-src')\n"
    "    ? 'blocked' : 'unknown';\n"
    "  out.rows['object'] = sawDirective('object-src') ? 'blocked' : 'unknown';\n"
    "  /* a constructor that does not throw is NOT evidence of permission:\n"
    "     both of these are enforced asynchronously, so the verdict comes\n"
    "     from the violation report and never from the constructor */\n"
    "  if (out.violations.some(function (v) {\n"
    "        return v.blocked.indexOf('wss:') === 0; })) {\n"
    "    out.rows['websocket'] = 'blocked';\n"
    "  }\n"
    "  if (sawDirective('worker-src')) { out.rows['worker'] = 'blocked'; }\n"
    "  if (out.rows['external-script'] === 'pending') {\n"
    "    out.rows['external-script'] = sawDirective('script-src')\n"
    "      ? 'blocked' : 'unknown';\n"
    "  }\n"
    "  await window.__cap8b_report(JSON.stringify(out));\n"
    "})();\n";

/* The candidate native policy under measurement. VERBATIM from the Windows
   probe - a divergent policy string would make the CSP reports incomparable,
   and the summarizer says so out loud. Deliberately the profile the intent
   proposes, with ONE stated difference: connect-src 'self' rather than 'none',
   because 'none' also blocks SAME-ORIGIN fetch. Whether that difference is
   required is one of the things this probe measures - the same-origin-fetch row
   is what decides it. */
static const char kCandidateCsp[] =
    "default-src 'self'; base-uri 'none'; object-src 'none'; "
    "frame-src 'none'; frame-ancestors 'none'; form-action 'none'; "
    "connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; font-src 'self' data:; media-src 'self'; "
    "worker-src 'none'; manifest-src 'self'";

/* ------------------------------------------------------------------ */
/* recorded measurements                                               */
/* ------------------------------------------------------------------ */

struct CapEvent {
  char *phase;
  char *caseName;
  char *hook;
  char *uri;
  /* userInitiated is meaningful ONLY when userInitiatedKnown is TRUE. The
     distinction is not pedantry: this engine reports a real gesture flag on a
     NAVIGATION action, and exposes NOTHING on a response decision or on a
     started download. Emitting `false` for all of them would make a value that
     was never measured look like a measurement that came back negative - the
     single worst defect an audit instrument can have, and the one this field
     exists to prevent. `basis` states which of those a row is. */
  gboolean userInitiated;
  gboolean userInitiatedKnown;
  char *basis;
  /* A POLICY hook can refuse the navigation; an OBSERVATION hook only says it
     happened. Counting them together would let a target with more observation
     hooks look like it cancelled more. */
  gboolean policy;
  gboolean redirected;
  gboolean cancelled;
  gboolean bootstrapAllowed;
  /* free-form, per-hook: never parsed, only read by a human */
  char *detail;
};

/* What a CALL SITE hands CapRecordEvent. It is a struct rather than a parameter
   list because every field is stated explicitly at every call site on purpose:
   a value that was DERIVED, DEFINED or ASSUMED must never reach the artifact in
   a shape that makes it look MEASURED, and a defaulted boolean is exactly how
   that happens. A basis left NULL is recorded as an unstated basis rather than
   silently becoming an empty string. */
struct CapEventIn {
  const char *hook;
  const char *uri;
  gboolean userInitiatedKnown;
  gboolean userInitiated;
  const char *basis;
  gboolean policy;
  gboolean redirected;
  gboolean cancelled;
  gboolean bootstrapAllowed;
  const char *detail;
};

struct CapArrival {
  char *label;
  int count;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* the phase is finished when the page reported, the expected case was observed,
   or the watchdog fired */
static pthread_mutex_t g_wakeLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wake = PTHREAD_COND_INITIALIZER;
static gboolean g_phaseDone;

static GPtrArray *g_events;   /* struct CapEvent *   */
static GPtrArray *g_arrivals; /* struct CapArrival * */
static GPtrArray *g_notes;    /* char *              */
static GPtrArray *g_beacons;  /* char *              */
static GPtrArray *g_popups;   /* GtkWidget * toplevels this probe created */

static char *g_engineVersion;
static char *g_initialSource;
static char *g_exposureReport;
static char *g_coverageReport;
static char *g_cspReport;
static char *g_cspMetaReport;
static int g_cspHeadersEmitted;
static int g_cspHeadersRoundtripped;
/* Whether the "download-started" signal EXISTS on WebKitWebContext. It decides
   ONLY whether a handler can be connected at all; it is never what
   download_hook_available reports - see g_downloadEventsSeen. */
static gboolean g_downloadSignalPresent;

static char *g_phaseName;
/* When a phase exists to measure ONE navigation, naming it here lets the phase
   end the moment that navigation is observed instead of burning its whole
   watchdog budget. NULL for the multi-case phases. */
static const char *g_expectedCase;
static gint g_phaseKind = CAP_PHASE_EXPOSURE;
static gint g_cancelUntrusted;
static gint g_cspOn;
static gint g_trustedCommitted;

static webview_t g_webview;
static WebKitWebView *g_view;
static char **g_reportSlot;

/* the runtime-resolved frame discriminator, if this library has one at all */
typedef gboolean (*CapIsMainFrameFn)(WebKitResponsePolicyDecision *);
static CapIsMainFrameFn g_isMainFrameDocument;

/* The NAVIGATION-decision half of the same question, and the one that decides
   whether a subframe rule can exist at navigation time at all. It holds the
   NAME of whichever candidate accessor resolved on the installed library, or
   NULL when none did - and NULL is the measurement, not a default. */
static const char *g_navFrameDiscriminator;

/* The per-event verdict, so the answer rides every navigation event rather
   than living only in the notes. */
static const char *CapNavFrameVerdict(void) {
  return (g_navFrameDiscriminator != NULL) ? "discriminator-present"
                                           : "unmeasurable";
}

static void CapNote(const char *fmt, ...) G_GNUC_PRINTF(1, 2);

static void CapNote(const char *fmt, ...) {
  va_list args;
  char *text = NULL;

  va_start(args, fmt);
  text = g_strdup_vprintf(fmt, args);
  va_end(args);

  pthread_mutex_lock(&g_lock);
  g_ptr_array_add(g_notes, text);
  pthread_mutex_unlock(&g_lock);

  printf("[cap8b] %s\n", text);
  fflush(stdout);
}

static void CapSignalPhaseDone(void) {
  pthread_mutex_lock(&g_wakeLock);
  g_phaseDone = TRUE;
  pthread_cond_broadcast(&g_wake);
  pthread_mutex_unlock(&g_wakeLock);
}

/* defined with the corpus, below: case attribution is native and keyed by URI */
static char *CapCaseForUri(const char *uri);

static void CapRecordEvent(const struct CapEventIn *in) {
  struct CapEvent *e = g_new0(struct CapEvent, 1);
  gboolean satisfied = FALSE;

  pthread_mutex_lock(&g_lock);
  e->phase = g_strdup((g_phaseName != NULL) ? g_phaseName : "none");
  e->caseName = CapCaseForUri(in->uri);
  e->hook = g_strdup((in->hook != NULL) ? in->hook : "<null>");
  e->uri = g_strdup((in->uri != NULL) ? in->uri : "");
  e->userInitiatedKnown = in->userInitiatedKnown;
  /* a value that was never asked for is never carried, not even privately */
  e->userInitiated = in->userInitiatedKnown ? in->userInitiated : FALSE;
  e->basis = g_strdup((in->basis != NULL)
                          ? in->basis
                          : "unavailable:the probe stated no basis for this "
                            "hook, which is itself a defect");
  e->policy = in->policy;
  e->redirected = in->redirected;
  e->cancelled = in->cancelled;
  e->bootstrapAllowed = in->bootstrapAllowed;
  e->detail = g_strdup((in->detail != NULL) ? in->detail : "");
  printf("[cap8b] event phase=%s case=%s hook=%s user=%s basis=%s policy=%d "
         "redirect=%d cancelled=%d bootstrap=%d uri=%s\n",
         e->phase, e->caseName, e->hook,
         e->userInitiatedKnown ? (e->userInitiated ? "true" : "false") : "null",
         e->basis, e->policy ? 1 : 0, e->redirected ? 1 : 0,
         e->cancelled ? 1 : 0, e->bootstrapAllowed ? 1 : 0, e->uri);
  fflush(stdout);
  satisfied = (g_expectedCase != NULL) && (g_expectedCase[0] != '\0') &&
              (strcmp(e->caseName, g_expectedCase) == 0);
  g_ptr_array_add(g_events, e);
  pthread_mutex_unlock(&g_lock);

  if (satisfied) {
    /* on the GUI thread already - this is an engine signal callback */
    CapSignalPhaseDone();
    webview_terminate(g_webview);
  }
}

static void CapRecordArrival(const char *label) {
  guint i;

  pthread_mutex_lock(&g_lock);
  for (i = 0; i < g_arrivals->len; ++i) {
    struct CapArrival *a = g_ptr_array_index(g_arrivals, i);
    if (strcmp(a->label, label) == 0) {
      a->count += 1;
      pthread_mutex_unlock(&g_lock);
      return;
    }
  }
  {
    struct CapArrival *a = g_new0(struct CapArrival, 1);
    a->label = g_strdup(label);
    a->count = 1;
    g_ptr_array_add(g_arrivals, a);
  }
  pthread_mutex_unlock(&g_lock);
}

/* ------------------------------------------------------------------ */
/* the fixture corpus (memory only - nothing on disk)                  */
/* ------------------------------------------------------------------ */

struct CapAsset {
  char *body; /* owned by the caller; g_free */
  gsize length;
  const char *contentType;
  guint status;
  const char *reason;
  const char *location;    /* NULL, or a Location: header value    */
  const char *disposition; /* NULL, or a Content-Disposition value  */
  gboolean trustedHtml;    /* eligible to carry the candidate CSP   */
};

static char *CapChildDocument(const char *title) {
  return g_strconcat("<!doctype html><html><head><meta charset=\"utf-8\">"
                     "<title>",
                     title,
                     "</title></head><body><div id=\"c\">child</div>"
                     "<script>window.__cap8b_ctx="
                     "(new URLSearchParams(location.search)).get('ctx')"
                     "||'child';</script><script>",
                     kChildJs, "</script></body></html>", NULL);
}

static char *CapOrchestratorJs(void) {
  switch ((enum CapPhaseKind)g_atomic_int_get(&g_phaseKind)) {
  case CAP_PHASE_EXPOSURE: {
    char *escaped = CapJStr(kChildJs);
    char *js = CapReplaceFirst(kExposureJs, "__CHILDJS__", escaped);
    g_free(escaped);
    return js;
  }
  case CAP_PHASE_ACT_PLAIN:
    return g_strdup(kActPlainJs);
  case CAP_PHASE_ACT_BIND:
    return g_strdup(kActBindJs);
  case CAP_PHASE_ACT_EVAL:
    return g_strdup(kActEvalJs);
  case CAP_PHASE_ACT_CLICK:
    return g_strdup(kActClickJs);
  case CAP_PHASE_REDIRECT_EXTERNAL:
    return g_strdup(kRedirectExternalJs);
  case CAP_PHASE_REDIRECT_INTERNAL:
    return g_strdup(kRedirectInternalJs);
  case CAP_PHASE_COVERAGE:
  case CAP_PHASE_CSP:
  case CAP_PHASE_CSP_META:
  default:
    return g_strdup(kCoverageJs);
  }
}

/* Case attribution is NATIVE and keyed by the URI, because the alternative -
   the page announcing each case through a binding - is exactly what
   contaminated the user-activation reading in the first Windows run. Every
   coverage and activation case therefore navigates to a URI that appears
   nowhere else. Ported row for row from the Windows probe so that the two
   documents name the same cases. */
static char *CapCaseForUri(const char *uri) {
  static const struct {
    const char *uri;
    const char *name;
  } kRows[] = {
      {"https://example.invalid/top", "script-location-external"},
      {"https://example.invalid/win", "script-window-open-external"},
      {"https://example.invalid/anchor", "anchor-click-external"},
      {"https://example.invalid/blank", "anchor-click-blank-external"},
      {"https://example.invalid/frame", "subframe-external"},
      {"https://example.invalid/form", "form-submit-external"},
      {"https://example.invalid/redirected", "redirect-out-of-pweb"},
      {"https://example.invalid/metarefresh", "meta-refresh-external"},
      {"http://example.invalid/plain", "scheme-http"},
      {"file:///C:/Windows/win.ini", "scheme-file"},
      {"mailto:nobody@example.invalid", "scheme-mailto"},
      {"zzq://example.invalid/unknown", "scheme-unknown"},
      {"about:blank", "about-blank"},
      {"https://example.invalid/act-plain", "act-plain"},
      {"https://example.invalid/act-after-bind", "act-after-bind"},
      {"https://example.invalid/act-after-eval", "act-after-eval"},
      {"https://example.invalid/act-real-click", "act-real-click"},
  };
  gsize i;

  if (uri == NULL) {
    return g_strdup("(host or startup navigation)");
  }
  for (i = 0; i < G_N_ELEMENTS(kRows); ++i) {
    if (strcmp(uri, kRows[i].uri) == 0) {
      return g_strdup(kRows[i].name);
    }
  }
  if (CapHasPrefix(uri, "pweb://evil/")) {
    return g_strdup("subframe-wrong-authority");
  }
  if (CapHasPrefix(uri, "data:")) {
    return g_strdup("scheme-data");
  }
  if (CapHasPrefix(uri, "blob:")) {
    return g_strdup("scheme-blob");
  }
  if (CapHasPrefix(uri, "javascript:")) {
    return g_strdup("scheme-javascript");
  }
  if (strstr(uri, "/redirect-external") != NULL) {
    return g_strdup("redirect-first-leg");
  }
  if (strstr(uri, "/download.bin") != NULL) {
    return g_strdup("download");
  }
  if (strstr(uri, "ctx=cov-frame-trusted") != NULL) {
    return g_strdup("subframe-trusted");
  }
  if (strstr(uri, "ctx=cov-reload") != NULL) {
    return g_strdup("reload-trusted-subframe");
  }
  if (strstr(uri, "ctx=cov-auth-upper") != NULL) {
    return g_strdup("authority-uppercase");
  }
  if (strstr(uri, "ctx=cov-auth-suffix") != NULL) {
    return g_strdup("authority-suffix");
  }
  if (strstr(uri, "ctx=cov-auth-userinfo") != NULL) {
    return g_strdup("authority-userinfo");
  }
  if (strstr(uri, "ctx=cov-auth-port") != NULL) {
    return g_strdup("authority-port");
  }
  if (strstr(uri, "ctx=cov-auth-empty") != NULL) {
    return g_strdup("authority-empty");
  }
  if (strstr(uri, "pushed=1") != NULL) {
    return g_strdup("history-pushstate-back");
  }
  if (strchr(uri, '#') != NULL) {
    return g_strdup("fragment-same-document");
  }
  return g_strdup("(host or startup navigation)");
}

/* The AUDIT's coarse notion of "trusted", used only to decide what the
   cancelling phase lets through and which document the candidate CSP rides on.
   It is deliberately a prefix test, which is exactly what the PRODUCTION
   classifier is forbidden to do - the product's verdict comes from
   PWebParseAppUri over parsed components. Nothing here is a candidate for
   production. */
static gboolean CapIsAuditTrusted(const char *uri) {
  if (uri == NULL) {
    return FALSE;
  }
  return CapHasPrefix(uri, "pweb://app/") || (strcmp(uri, "pweb://app") == 0);
}

/* The ZERO-NETWORK FLOOR: a URI whose scheme can only ever be satisfied from
   inside this process. Anything else is denied at decide-policy in EVERY phase,
   so a CSP the engine turns out not to enforce still cannot cause a request. */
static gboolean CapUriIsOffline(const char *uri) {
  if (uri == NULL) {
    return FALSE; /* fail closed */
  }
  return CapHasPrefix(uri, "pweb://") || CapHasPrefix(uri, "about:") ||
         CapHasPrefix(uri, "data:") || CapHasPrefix(uri, "blob:");
}

static void CapAssetSet(struct CapAsset *out, char *body,
                        const char *contentType) {
  out->body = body;
  out->length = (gsize)strlen(body);
  out->contentType = contentType;
}

/* Split scheme://authority/path, coarsely - this is a fixture router, not the
   product's validator, and it must be able to answer for the HOSTILE authority
   too. THE URI IS THE WHOLE URI: this is handed the string from
   webkit_uri_scheme_request_get_uri and never the one from
   webkit_uri_scheme_request_get_path, which MEASURED (CAP-7L) returns "/x" for
   "pweb://evil/x" and would silently discard the authority the audit exists to
   distinguish. */
static gboolean CapCorpusFor(const char *uri, struct CapAsset *out) {
  static const char kPrefix[] = "pweb://";
  const char *rest = NULL;
  const char *slash = NULL;
  char *authority = NULL;
  char *path = NULL;
  char *cut = NULL;
  gboolean found = FALSE;

  memset(out, 0, sizeof(*out));
  out->status = 200;
  out->reason = "OK";

  if (!CapHasPrefix(uri, kPrefix)) {
    return FALSE;
  }
  rest = uri + (sizeof(kPrefix) - 1);
  slash = strchr(rest, '/');
  if (slash != NULL) {
    authority = g_strndup(rest, (gsize)(slash - rest));
    path = g_strdup(slash);
  } else {
    authority = g_strdup(rest);
    path = g_strdup("/");
  }
  cut = strpbrk(path, "?#");
  if (cut != NULL) {
    *cut = '\0';
  }

  if (strcmp(authority, "evil") == 0) {
    /* The untrusted document, served ON PURPOSE: the whole exposure question is
       what such a document can reach if it ever executes. */
    if (strstr(uri, "ctx=redirect-target") != NULL) {
      /* Being ASKED for this is the proof that the 302 was FOLLOWED - the one
         observation that separates "the engine never followed the redirect"
         from "it followed it without telling the navigation hook". */
      pthread_mutex_lock(&g_lock);
      g_ptr_array_add(g_beacons, g_strdup("redirect-target-requested"));
      pthread_mutex_unlock(&g_lock);
    }
    if ((strcmp(path, "/child.html") == 0) || (strcmp(path, "/") == 0)) {
      CapAssetSet(out, CapChildDocument("cap8b evil"),
                  "text/html; charset=utf-8");
      found = TRUE;
    }
    goto done;
  }
  if (strcmp(authority, "app") != 0) {
    goto done;
  }

  /* progress beacons: recorded natively, refused so the page never waits */
  if (CapHasPrefix(path, "/beacon/")) {
    pthread_mutex_lock(&g_lock);
    g_ptr_array_add(g_beacons, g_strdup(path + strlen("/beacon/")));
    pthread_mutex_unlock(&g_lock);
    goto done;
  }

  if ((strcmp(path, "/") == 0) || (strcmp(path, "/index.html") == 0)) {
    CapAssetSet(out,
                g_strdup("<!doctype html><html><head><meta charset=\"utf-8\">"
                         "<title>cap8b</title></head><body>"
                         "<div id=\"v\">cap8b</div>"
                         "<script src=\"/orchestrate.js\"></script>"
                         "</body></html>"),
                "text/html; charset=utf-8");
    out->trustedHtml = TRUE;
    found = TRUE;
  } else if (strcmp(path, "/orchestrate.js") == 0) {
    CapAssetSet(out, CapOrchestratorJs(), "text/javascript; charset=utf-8");
    found = TRUE;
  } else if (strcmp(path, "/child.html") == 0) {
    CapAssetSet(out, CapChildDocument("cap8b child"),
                "text/html; charset=utf-8");
    out->trustedHtml = TRUE;
    found = TRUE;
  } else if (strcmp(path, "/redirect-external") == 0) {
    /* The redirect OUT of pweb://, produced by the probe's own 302 - never by
       a server and never by anything that reaches the network. */
    CapAssetSet(out, g_strdup(""), "text/plain; charset=utf-8");
    out->status = 302;
    out->reason = "Found";
    out->location = "https://example.invalid/redirected";
    found = TRUE;
  } else if (strcmp(path, "/redirect-internal") == 0) {
    /* the 302 that stays inside this probe's own scheme handler, so that
       "followed" and "not followed" are distinguishable at all */
    CapAssetSet(out, g_strdup(""), "text/plain; charset=utf-8");
    out->status = 302;
    out->reason = "Found";
    out->location = "pweb://evil/child.html?ctx=redirect-target";
    found = TRUE;
  } else if (strcmp(path, "/download.bin") == 0) {
    CapAssetSet(out, g_strdup("cap8b-download-payload"),
                "application/octet-stream");
    out->disposition = "attachment; filename=\"c.bin\"";
    found = TRUE;
  } else if (strcmp(path, "/metarefresh.html") == 0) {
    /* The redirect mechanism that is actually REACHABLE in this architecture.
       MEASURED on WebView2: a 302 handed back from a resource-response hook is
       not followed at all, so it can never be the redirect a threat model
       worries about; a meta refresh inside trusted content can, and it is a
       plain navigation the hook must see. Whether THIS engine follows the 302
       is the redirect-internal phase's question. */
    CapAssetSet(out,
                g_strdup("<!doctype html><html><head><meta charset=\"utf-8\">"
                         "<meta http-equiv=\"refresh\" "
                         "content=\"0;url=https://example.invalid/metarefresh\">"
                         "</head><body>refresh</body></html>"),
                "text/html; charset=utf-8");
    out->trustedHtml = TRUE;
    found = TRUE;
  } else if (strcmp(path, "/worker.js") == 0) {
    CapAssetSet(out, g_strdup("self.onmessage=function(){};"),
                "text/javascript; charset=utf-8");
    found = TRUE;
  } else if (strcmp(path, "/same-origin.js") == 0) {
    CapAssetSet(out, g_strdup("window.__cap8b_same_origin = true;"),
                "text/javascript; charset=utf-8");
    found = TRUE;
  } else if (strcmp(path, "/csp.js") == 0) {
    CapAssetSet(out, g_strdup(kCspJs), "text/javascript; charset=utf-8");
    found = TRUE;
  } else if ((strcmp(path, "/csp.html") == 0) ||
             (strcmp(path, "/csp-meta.html") == 0)) {
    /* The inline script is the DELIBERATE canary for script-src 'self': if the
       header is enforced it must not run. csp-meta.html additionally carries a
       far WEAKER <meta> policy, which must not be able to rescue it - that is
       the "a tampered bundle cannot weaken the native policy" claim, measured
       rather than asserted. */
    const gboolean meta = (strcmp(path, "/csp-meta.html") == 0);
    CapAssetSet(
        out,
        g_strconcat(
            "<!doctype html><html><head><meta charset=\"utf-8\">",
            meta ? "<meta http-equiv=\"Content-Security-Policy\" "
                   "content=\"default-src * 'unsafe-inline' 'unsafe-eval'; "
                   "script-src * 'unsafe-inline' 'unsafe-eval'; "
                   "connect-src *; frame-src *; object-src *; base-uri *\">"
                 : "",
            "<title>cap8b csp</title></head><body><div id=\"v\">csp</div>"
            "<script src=\"/same-origin.js\"></script>"
            "<script>window.__cap8b_inline = true;</script>"
            "<script src=\"/csp.js\"></script></body></html>",
            NULL),
        "text/html; charset=utf-8");
    out->trustedHtml = TRUE;
    found = TRUE;
  }

done:
  g_free(authority);
  g_free(path);
  return found;
}

/* ------------------------------------------------------------------ */
/* the scheme handler                                                  */
/* ------------------------------------------------------------------ */

/* MEASURED at CAP-7L, and the reason the cell below exists:
   webkit_web_context_register_uri_scheme REFUSES a second registration of the
   same scheme on the same context -

     CRITICAL: Cannot register URI scheme pweb more than once

   - and WebKitGTK 4.1 has no unregister call. Upstream creates its views on the
   shared default context, so phase 2 onwards must RE-OWN the cell phase 1
   installed rather than registering again. Disowning it (rather than removing
   the callback, which is impossible) is what makes the handler fail closed
   between phases. Same model as pweb.platform.webkitgtk's PWebGtkCells. */
struct CapRegistration {
  gint active; /* atomic: 0 once disowned - the callback then refuses */
};

static struct CapRegistration *g_registration;
static WebKitWebContext *g_registeredContext;

static void CapRegistrationDestroyed(gpointer data) {
  if (data == (gpointer)g_registration) {
    g_registration = NULL;
    g_registeredContext = NULL;
  }
  g_free(data);
}

static void CapFinishRefused(WebKitURISchemeRequest *request) {
  GError *error = g_error_new_literal(g_quark_from_static_string("cap8b"), 1,
                                      "cap8b fixture unavailable");
  if (error == NULL) {
    return; /* nothing safe left to do; the request completes unhandled */
  }
  /* finish_error COPIES the error into the request, so ours is ours to free */
  webkit_uri_scheme_request_finish_error(request, error);
  g_error_free(error);
}

static gboolean g_responseApiNoted;

static void CapFinishAsset(WebKitURISchemeRequest *request,
                           const struct CapAsset *a) {
  gpointer copy = NULL;
  GInputStream *stream = NULL;
  const gboolean cspOn = (g_atomic_int_get(&g_cspOn) != 0);

  /* ownership of the body moves to GIO, exactly as in the production adapter:
     nothing the page receives may point at this frame. A zero-byte asset still
     gets a real allocation with an honest length of 0. */
  copy = g_try_malloc((a->length > 0) ? a->length : 1);
  if (copy == NULL) {
    CapFinishRefused(request);
    return;
  }
  if (a->length > 0) {
    memcpy(copy, a->body, a->length);
  }
  stream = g_memory_input_stream_new_from_data(copy, (gssize)a->length, g_free);
  if (stream == NULL) {
    g_free(copy);
    CapFinishRefused(request);
    return;
  }

#if CAP8B_RESPONSE_API
  {
    WebKitURISchemeResponse *response =
        webkit_uri_scheme_response_new(stream, (gint64)a->length);
    SoupMessageHeaders *headers = NULL;

    if (response == NULL) {
      g_object_unref(stream);
      CapFinishRefused(request);
      return;
    }
    webkit_uri_scheme_response_set_content_type(response, a->contentType);
    webkit_uri_scheme_response_set_status(response, a->status, a->reason);

    headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    if (headers != NULL) {
      soup_message_headers_append(headers, "Cache-Control", "no-store");
      if (a->location != NULL) {
        soup_message_headers_append(headers, "Location", a->location);
      }
      if (a->disposition != NULL) {
        soup_message_headers_append(headers, "Content-Disposition",
                                    a->disposition);
      }
      /* The native policy under test rides on TRUSTED HTML only - the same rule
         production would use - so the hostile authority never receives it and
         can never be mistaken for a protected one. */
      if (cspOn && a->trustedHtml) {
        soup_message_headers_append(headers, "Content-Security-Policy",
                                    kCandidateCsp);
        soup_message_headers_append(headers, "X-Content-Type-Options",
                                    "nosniff");
        soup_message_headers_append(headers, "Referrer-Policy", "no-referrer");
        pthread_mutex_lock(&g_lock);
        g_cspHeadersEmitted += 1;
        pthread_mutex_unlock(&g_lock);
      }
      /* transfer full: the response owns the headers from here */
      webkit_uri_scheme_response_set_http_headers(response, headers);
    } else if (!g_responseApiNoted) {
      g_responseApiNoted = TRUE;
      CapNote("soup_message_headers_new returned NULL - responses are being "
              "served with no header at all");
    }
    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response);
  }
#else
  /* MEASURED RESULT, not a silent skip: this build's WebKitGTK/libsoup could
     not supply webkit_uri_scheme_response_*, so NO response header of any kind
     can be attached on this engine and the CSP phases can only measure the
     <meta> path. */
  if (!g_responseApiNoted) {
    g_responseApiNoted = TRUE;
    CapNote("webkit_uri_scheme_response_* unavailable at build time - falling "
            "back to webkit_uri_scheme_request_finish(), which carries NO "
            "headers: no response CSP can be delivered on this build");
  }
  (void)cspOn;
  webkit_uri_scheme_request_finish(request, stream, (gint64)a->length,
                                   a->contentType);
#endif
  g_object_unref(stream); /* the request/response holds its own reference */
}

static void CapSchemeRequest(WebKitURISchemeRequest *request,
                             gpointer user_data) {
  struct CapRegistration *registration = (struct CapRegistration *)user_data;
  const gchar *uri = NULL;
  struct CapAsset asset;

  if ((registration == NULL) ||
      (g_atomic_int_get(&registration->active) == 0)) {
    CapFinishRefused(request); /* disowned: fail closed, never serve */
    return;
  }
  uri = webkit_uri_scheme_request_get_uri(request);
  if (uri == NULL) {
    CapFinishRefused(request);
    return;
  }
  if (!CapCorpusFor(uri, &asset)) {
    CapFinishRefused(request);
    return;
  }
  CapFinishAsset(request, &asset);
  g_free(asset.body);
}

/* ------------------------------------------------------------------ */
/* bindings                                                            */
/* ------------------------------------------------------------------ */

/* Every bound name funnels here; the FIRST element of the params array is the
   audit label, which is how each context is attributed. */
static void CapBindInvoke(const char *id, const char *req, void *arg) {
  char *label = CapFirstJsonString(req);

  (void)arg;
  CapRecordArrival(label);
  printf("[cap8b] NATIVE ARRIVAL label=%s\n", label);
  fflush(stdout);
  g_free(label);
  /* completed exactly once, on every path, including a raw arrival from a frame
     that has no shim to receive the reply */
  webview_return(g_webview, id, 0, "null");
}

/* The activation control's round trip: it does nothing but resolve, so that the
   navigation performed in its continuation is measured against a binding
   promise and against nothing else. */
static void CapBindPing(const char *id, const char *req, void *arg) {
  char *label = CapFirstJsonString(req);

  (void)arg;
  CapRecordArrival(label);
  g_free(label);
  webview_return(g_webview, id, 0, "null");
}

static void CapBindReport(const char *id, const char *req, void *arg) {
  /* unwrapped here, once: the artifact carries the page's own JSON, not a
     params array wrapping an escaped copy of it */
  char *payload = CapFirstJsonString(req);

  (void)arg;
  webview_return(g_webview, id, 0, "null");
  pthread_mutex_lock(&g_lock);
  if ((g_reportSlot != NULL) && (*g_reportSlot == NULL)) {
    *g_reportSlot = payload;
    payload = NULL;
  }
  pthread_mutex_unlock(&g_lock);
  /* a second report inside one phase is dropped, never leaked */
  g_free(payload);
  CapSignalPhaseDone();
  webview_terminate(g_webview); /* on the GUI thread: the documented path */
}

static void CapTerminateOnGuiThread(webview_t w, void *arg) {
  (void)arg;
  webview_terminate(w);
}

/* ------------------------------------------------------------------ */
/* the native hooks under measurement                                  */
/* ------------------------------------------------------------------ */

static const char *CapNavTypeName(WebKitNavigationType type) {
  switch (type) {
  case WEBKIT_NAVIGATION_TYPE_LINK_CLICKED:
    return "LINK_CLICKED";
  case WEBKIT_NAVIGATION_TYPE_FORM_SUBMITTED:
    return "FORM_SUBMITTED";
  case WEBKIT_NAVIGATION_TYPE_BACK_FORWARD:
    return "BACK_FORWARD";
  case WEBKIT_NAVIGATION_TYPE_RELOAD:
    return "RELOAD";
  case WEBKIT_NAVIGATION_TYPE_FORM_RESUBMITTED:
    return "FORM_RESUBMITTED";
  case WEBKIT_NAVIGATION_TYPE_OTHER:
    return "OTHER";
  default:
    return "UNKNOWN";
  }
}

/* The candidate rule, applied to every decision type through the ONE hook this
   engine offers.
     - in a cancelling phase it is the trusted-authority rule the product would
       ship, plus the single-use engine bootstrap exception the Windows probe
       also carries (measured rather than assumed: if the engine never needs it,
       no event will ever carry bootstrap_allowed);
     - otherwise it degrades to the zero-network floor, which lets the hostile
       pweb://evil document and the data:/about:blank frames execute - they ARE
       the exposure measurement - while still refusing anything that could reach
       a wire.
   Returns TRUE to deny, and sets *bootstrap when the allowance was the
   bootstrap exception rather than trust. */
static gboolean CapShouldDeny(const char *uri, gboolean *bootstrap) {
  *bootstrap = FALSE;
  if (uri == NULL) {
    return TRUE; /* fail closed on an unknown URI */
  }
  if (g_atomic_int_get(&g_cancelUntrusted) != 0) {
    if (CapIsAuditTrusted(uri)) {
      g_atomic_int_set(&g_trustedCommitted, 1);
      return FALSE;
    }
    if ((strcmp(uri, "about:blank") == 0) &&
        (g_atomic_int_get(&g_trustedCommitted) == 0)) {
      *bootstrap = TRUE;
      return FALSE;
    }
    return TRUE;
  }
  if (CapIsAuditTrusted(uri)) {
    g_atomic_int_set(&g_trustedCommitted, 1);
  }
  return !CapUriIsOffline(uri);
}

static const char *CapFrameNameOf(WebKitNavigationAction *action,
                                  WebKitNavigationPolicyDecision *nav) {
#if WEBKIT_CHECK_VERSION(2, 40, 0)
  (void)nav;
  return webkit_navigation_action_get_frame_name(action);
#else
  const char *name = NULL;
  (void)action;
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  name = webkit_navigation_policy_decision_get_frame_name(nav);
  G_GNUC_END_IGNORE_DEPRECATIONS
  return name;
#endif
}

/* The three things this engine's ONE navigation hook can do with a decision.
   DOWNLOAD is not decoration: a response whose MIME type the engine cannot
   display is NOT converted into a download by ignoring it - ignoring it is
   precisely how the download hook became structurally unreachable in an earlier
   revision, which left download_hook_available reporting an API's existence
   instead of an observed firing. webkit_policy_decision_download() is the only
   call that makes "download-started" reachable at all, and the download it
   creates is refused unconditionally in CapOnDownloadStarted. */
enum CapDecisionOutcome {
  CAP_DECISION_USE,
  CAP_DECISION_IGNORE,
  CAP_DECISION_DOWNLOAD
};

/* Upstream connects ONLY "destroy" on its own window, so "decide-policy" and
   "create" are free. decide-policy is the single navigation hook this engine
   has, and an UNDECIDED policy DEFAULTS TO ALLOW - so every branch below
   decides exactly once and returns TRUE. */
static gboolean CapDecidePolicy(WebKitWebView *view,
                                WebKitPolicyDecision *decision,
                                WebKitPolicyDecisionType type,
                                gpointer user_data) {
  const gboolean popup = (user_data != NULL);
  const char *origin = popup ? "popup/" : "";
  char *hook = NULL;
  char *detail = NULL;
  const char *uri = NULL;
  gboolean userInitiated = FALSE;
  gboolean userInitiatedKnown = FALSE;
  const char *basis = NULL;
  gboolean redirected = FALSE;
  gboolean bootstrap = FALSE;
  gboolean deny = FALSE;
  enum CapDecisionOutcome outcome = CAP_DECISION_IGNORE;
  struct CapEventIn ev;

  (void)view;
  if (decision == NULL) {
    return FALSE; /* nothing to decide with; the default handler owns it */
  }

  switch (type) {
  case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION:
  case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION: {
    WebKitNavigationPolicyDecision *nav =
        WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action =
        (nav != NULL)
            ? webkit_navigation_policy_decision_get_navigation_action(nav)
            : NULL;
    WebKitURIRequest *request = NULL;
    const char *frameName = NULL;
    const char *kind =
        (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION)
            ? "navigation-action"
            : "new-window-action";

    if (action == NULL) {
      /* fail closed: an action-less navigation decision is not something the
         audit is willing to let through by default */
      hook = g_strdup_printf("%sdecide-policy/%s:no-action", origin, kind);
      webkit_policy_decision_ignore(decision);
      memset(&ev, 0, sizeof(ev));
      ev.hook = hook;
      ev.uri = "";
      /* nothing to ask: no action means no gesture flag, so the row says so
         rather than reporting a false the engine never gave */
      ev.userInitiatedKnown = FALSE;
      ev.basis = "unavailable:the decision carried no WebKitNavigationAction";
      ev.policy = TRUE;
      ev.cancelled = TRUE;
      ev.detail = "fail-closed ignore: no action means no URI and no gesture "
                  "flag to read, and this audit never allows what it cannot "
                  "identify";
      CapRecordEvent(&ev);
      g_free(hook);
      return TRUE;
    }
    request = webkit_navigation_action_get_request(action);
    uri = (request != NULL) ? webkit_uri_request_get_uri(request) : NULL;
    userInitiated =
        webkit_navigation_action_is_user_gesture(action) ? TRUE : FALSE;
    userInitiatedKnown = TRUE;
    basis = "engine:webkit_navigation_action_is_user_gesture";
    redirected = webkit_navigation_action_is_redirect(action) ? TRUE : FALSE;
    frameName = CapFrameNameOf(action, nav);
    deny = CapShouldDeny(uri, &bootstrap);
    outcome = deny ? CAP_DECISION_IGNORE : CAP_DECISION_USE;
    detail = g_strdup_printf(
        "mouse-button=%u modifiers=%u frame-name=%s; redirected from "
        "webkit_navigation_action_is_redirect",
        (unsigned)webkit_navigation_action_get_mouse_button(action),
        (unsigned)webkit_navigation_action_get_modifiers(action),
        ((frameName != NULL) && (frameName[0] != '\0')) ? frameName : "_none");

    /* main-frame= rides EVERY navigation event, not just the response ones,
       because "this engine cannot tell me which frame is navigating" is the
       finding that decides whether a subframe rule is possible at navigation
       time - and a finding that appears only as an absence is not a finding. */
    if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
      hook = g_strdup_printf(
          "%sdecide-policy/%s:%s:frame=%s:main-frame=%s", origin, kind,
          CapNavTypeName(webkit_navigation_action_get_navigation_type(action)),
          ((frameName != NULL) && (frameName[0] != '\0')) ? frameName : "_none",
          CapNavFrameVerdict());
    } else {
      hook = g_strdup_printf(
          "%sdecide-policy/%s:%s:main-frame=%s", origin, kind,
          CapNavTypeName(webkit_navigation_action_get_navigation_type(action)),
          CapNavFrameVerdict());
    }
    break;
  }
  case WEBKIT_POLICY_DECISION_TYPE_RESPONSE: {
    WebKitResponsePolicyDecision *rd =
        WEBKIT_RESPONSE_POLICY_DECISION(decision);
    WebKitURIRequest *request =
        (rd != NULL) ? webkit_response_policy_decision_get_request(rd) : NULL;
    WebKitURIResponse *response =
        (rd != NULL) ? webkit_response_policy_decision_get_response(rd) : NULL;
    const gboolean supported =
        (rd != NULL) &&
        (webkit_response_policy_decision_is_mime_type_supported(rd) != FALSE);
    const char *mainFrame = "unmeasurable";
    const char *mime = "<none>";
    unsigned status = 0;
    const char *cspOnResponse = "not-measurable-without-libsoup3";

    uri = (request != NULL) ? webkit_uri_request_get_uri(request) : NULL;
    if ((g_isMainFrameDocument != NULL) && (rd != NULL)) {
      mainFrame = g_isMainFrameDocument(rd) ? "yes" : "no";
    }
    if (response != NULL) {
      const gchar *m = webkit_uri_response_get_mime_type(response);
      mime = (m != NULL) ? m : "<none>";
      status = (unsigned)webkit_uri_response_get_status_code(response);
    }
#if CAP8B_HAVE_SOUP3
    /* Does the Content-Security-Policy the scheme handler attached actually
       come back out of the engine as a response header? This is the "was the
       header ACCEPTED" half of question 3; the csp_report rows are the "was it
       ENFORCED" half, and the two are deliberately measured separately. */
    if (response != NULL) {
      SoupMessageHeaders *headers =
          webkit_uri_response_get_http_headers(response);
      const gboolean seen =
          (headers != NULL) &&
          (soup_message_headers_get_one(headers, "Content-Security-Policy") !=
           NULL);
      cspOnResponse = seen ? "present" : "absent";
      if (seen) {
        pthread_mutex_lock(&g_lock);
        g_cspHeadersRoundtripped += 1;
        pthread_mutex_unlock(&g_lock);
      }
    } else {
      cspOnResponse = "no-response-object";
    }
#endif
    /* A download presents HERE on this engine: a response whose MIME type the
       engine cannot display arrives as a RESPONSE decision rather than through
       a dedicated hook, and it becomes a download ONLY if this handler says so.
       The zero-network floor has already run: CapShouldDeny refuses anything
       whose scheme could reach a wire, so nothing external can ever reach the
       DOWNLOAD outcome. */
    userInitiatedKnown = FALSE;
    basis = "unavailable:WebKitResponsePolicyDecision carries no navigation "
            "action and no user-gesture flag";
    deny = CapShouldDeny(uri, &bootstrap);
    if (deny) {
      outcome = CAP_DECISION_IGNORE;
    } else if (!supported) {
      outcome = CAP_DECISION_DOWNLOAD;
    } else {
      outcome = CAP_DECISION_USE;
    }
    hook = g_strdup_printf("%sdecide-policy/response:mime-%s:main-frame=%s",
                           origin, supported ? "supported" : "unsupported",
                           mainFrame);
    detail = g_strdup_printf(
        "mime=%s http-status=%u csp-header-back-out-of-the-engine=%s%s; "
        "the redirect flag is not exposed on a response decision and is "
        "emitted false rather than measured",
        mime, status, cspOnResponse,
        (outcome == CAP_DECISION_DOWNLOAD)
            ? "; converted with webkit_policy_decision_download so the "
              "download hook is REACHABLE - the download itself is refused "
              "unconditionally at download-started"
            : "");
    break;
  }
  default:
    /* An undecided policy DEFAULTS TO ALLOW on this engine, so an unknown
       decision type is refused rather than fallen through. */
    hook = g_strdup_printf("%sdecide-policy/unknown:%d", origin, (int)type);
    basis = "unavailable:an unknown decision type exposes no gesture flag";
    outcome = CAP_DECISION_IGNORE;
    detail = g_strdup("refused: an undecided policy DEFAULTS TO ALLOW on this "
                      "engine, so a decision type this probe does not know is "
                      "failed closed rather than fallen through");
    break;
  }

  /* EXACTLY ONE decision, on every path, BEFORE the event is recorded - because
     recording can terminate the phase when the expected case is observed. */
  switch (outcome) {
  case CAP_DECISION_USE:
    webkit_policy_decision_use(decision);
    break;
  case CAP_DECISION_DOWNLOAD: {
    /* the deprecation guard is a BUILD portability measure, not an opinion:
       this call is live in webkit2gtk-4.1 and marked deprecated in the 6.0
       headers, and a -Werror build must not break on a probe that is pinned to
       4.1 on purpose. The braces exist so the pragma is the first thing in a
       BLOCK rather than the first thing after a label. */
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    webkit_policy_decision_download(decision);
    G_GNUC_END_IGNORE_DEPRECATIONS
    break;
  }
  case CAP_DECISION_IGNORE:
  default:
    webkit_policy_decision_ignore(decision);
    break;
  }

  memset(&ev, 0, sizeof(ev));
  ev.hook = hook;
  ev.uri = uri;
  ev.userInitiatedKnown = userInitiatedKnown;
  ev.userInitiated = userInitiated;
  ev.basis = basis;
  /* decide-policy REFUSES; it does not merely observe */
  ev.policy = TRUE;
  ev.redirected = redirected;
  ev.cancelled = (outcome == CAP_DECISION_IGNORE);
  ev.bootstrapAllowed = bootstrap;
  ev.detail = detail;
  CapRecordEvent(&ev);
  g_free(hook);
  g_free(detail);
  return TRUE; /* we decided: the default handler must not get a second
                  opinion, because its opinion is always "allow" */
}

/* "create" is the ONLY place a new window can be granted or refused on this
   engine. With NO handler at all, WebKitGTK returns NULL and window.open
   silently yields null - a real (and useful) production property, but it means
   the audit must build the window itself to measure what such a window would
   reach. */
static GtkWidget *CapOnCreate(WebKitWebView *view,
                              WebKitNavigationAction *action,
                              gpointer user_data) {
  const char *uri = NULL;
  gboolean userInitiated = FALSE;
  gboolean userInitiatedKnown = FALSE;
  const char *basis = "unavailable:the create signal carried no "
                      "WebKitNavigationAction";
  gboolean bootstrap = FALSE;
  GtkWidget *child = NULL;
  GtkWidget *window = NULL;
  WebKitUserContentManager *ucm = NULL;
  struct CapEventIn ev;
  static gboolean sharedUcmNoted;

  (void)user_data;
  if (action != NULL) {
    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    uri = (request != NULL) ? webkit_uri_request_get_uri(request) : NULL;
    userInitiated =
        webkit_navigation_action_is_user_gesture(action) ? TRUE : FALSE;
    userInitiatedKnown = TRUE;
    basis = "engine:webkit_navigation_action_is_user_gesture";
  }

  /* every row this hook emits shares the same measured basis and the same
     policy weight: "create" is the ONE place a window can be refused */
  memset(&ev, 0, sizeof(ev));
  ev.uri = uri;
  ev.userInitiatedKnown = userInitiatedKnown;
  ev.userInitiated = userInitiated;
  ev.basis = basis;
  ev.policy = TRUE;
  /* ASKED, not left to the memset. An earlier revision let `redirected` fall
     out of the zeroing, so every create row published "redirected": false -
     a value that reads as an engine answer when the engine was never
     consulted, on a hook where consulting it is one call. The action is in
     hand here and this is the same accessor the navigation branch uses. */
  ev.redirected = (action != NULL &&
                   webkit_navigation_action_is_redirect(action)) ? TRUE : FALSE;

  if (CapShouldDeny(uri, &bootstrap)) {
    ev.hook = "create:refused";
    ev.cancelled = TRUE;
    ev.detail = "the audit rule refused the opened window: returning NULL from "
                "\"create\" yields no view, no window and no load";
    CapRecordEvent(&ev);
    return NULL; /* the documented deny: no view, no window, no load */
  }

  /* THE WORST CASE, built deliberately. The user content manager carries BOTH
     upstream's injected shim scripts AND the "__webview__" script message
     handler, so a host that grants a new window from the same manager hands
     that window the entire privileged bridge. Whether the engine even permits
     the two construct-only properties together is itself measured below. */
  ucm = webkit_web_view_get_user_content_manager(view);
  child = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW, "related-view", view,
                                  "user-content-manager", ucm, NULL));
  if (child == NULL) {
    ev.hook = "create:view-failed";
    ev.cancelled = TRUE;
    ev.detail = "g_object_new(WEBKIT_TYPE_WEB_VIEW) returned NULL - the "
                "window was refused because it could not be built, which is "
                "an instrument condition and not a measured policy";
    CapRecordEvent(&ev);
    return NULL;
  }
  if (!sharedUcmNoted) {
    sharedUcmNoted = TRUE;
    CapNote("create: new WebKitWebView built with related-view + "
            "user-content-manager; the manager is %s the opener's - which is "
            "what decides whether an opened window inherits the privileged "
            "bridge",
            (webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(child)) ==
             ucm)
                ? "SHARED with"
                : "DISTINCT from");
  }
  /* the popup gets the same decision hook, tagged so its events stay
     distinguishable from the opener's */
  g_signal_connect(child, "decide-policy", G_CALLBACK(CapDecidePolicy),
                   GINT_TO_POINTER(1));

  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "cap8b opened window");
  gtk_window_set_default_size(GTK_WINDOW(window), 480, 320);
  gtk_container_add(GTK_CONTAINER(window), child); /* sinks the float */
  gtk_widget_show_all(window);
  g_ptr_array_add(g_popups, window);

  ev.hook = "create:granted";
  ev.cancelled = FALSE;
  ev.detail = "THE WORST CASE, built deliberately: the granted view was "
              "constructed with related-view and the OPENER'S user content "
              "manager, which is what decides whether an opened window "
              "inherits the privileged bridge";
  CapRecordEvent(&ev);
  /* the signal is (transfer full): hand WebKit a reference of its own rather
     than the container's, so tearing the window down at phase teardown can
     never free a view WebKit still holds */
  g_object_ref(child);
  return child;
}

/* Downloads are ALWAYS cancelled here, in every phase, and the cancelled flag
   on a download-started event reflects that unconditional refusal rather than a
   phase rule. The probe must never let a download reach disk: WebKitGTK's
   default destination is a real path in the user's home, and an audit
   instrument that writes files there would be a defect. Cancelling inside this
   handler happens BEFORE "decide-destination" runs, so no path is ever chosen
   and no byte is ever written. The measurement that matters - "is the download
   observable, and can it be stopped before it exists?" - is unaffected.

   THIS SIGNAL FIRING IS THE MEASUREMENT. g_downloadEventsSeen, not
   g_signal_lookup, is what download_hook_available reports: the existence of a
   signal is an API name, and an API name is never evidence. */
static gint g_downloadEventsSeen;

static void CapOnDownloadStarted(WebKitWebContext *context,
                                 WebKitDownload *download, gpointer user_data) {
  WebKitURIRequest *request = NULL;
  const char *uri = NULL;
  struct CapEventIn ev;

  (void)context;
  (void)user_data;
  if (download == NULL) {
    return;
  }
  request = webkit_download_get_request(download);
  uri = (request != NULL) ? webkit_uri_request_get_uri(request) : NULL;
  webkit_download_cancel(download);
  g_atomic_int_inc(&g_downloadEventsSeen);

  memset(&ev, 0, sizeof(ev));
  ev.hook = "download-started";
  ev.uri = uri;
  /* WebKitDownload exposes no user-gesture flag at all - recorded as UNKNOWN,
     never as false */
  ev.userInitiatedKnown = FALSE;
  ev.basis = "unavailable:WebKitDownload exposes no user-gesture flag";
  /* a NOTIFY signal whose refusal is webkit_download_cancel() rather than a
     decision object - it still REFUSES, so it counts as policy */
  ev.policy = TRUE;
  ev.cancelled = TRUE;
  ev.detail = "cancelled unconditionally, in every phase, before "
              "decide-destination runs: nothing reaches disk. This event "
              "firing is the whole of download_hook_available";
  CapRecordEvent(&ev);
}

/* ------------------------------------------------------------------ */
/* what this library actually offers                                   */
/* ------------------------------------------------------------------ */

/* The CRITICAL OPEN QUESTION, measured against the INSTALLED library rather
   than guessed from a header version: can this API distinguish a MAIN-FRAME
   navigation from a SUBFRAME navigation?

   dlsym over the already-loaded library is the honest instrument. A
   compile-time #ifdef would only report what the build headers claim, and a
   hand-written declaration of a symbol that does not exist would fail to link
   rather than produce a measurement. */
static void CapProbeSymbols(void) {
  /* navFrame marks a candidate that could identify the frame BEING NAVIGATED
     in a NAVIGATION_ACTION decision. The response-decision accessor answers a
     different, later question and is deliberately not one of them. */
  static const struct {
    const char *name;
    gboolean navFrame;
  } kCandidates[] = {
      {"webkit_navigation_policy_decision_get_frame_name", FALSE},
      {"webkit_navigation_action_get_frame_name", FALSE},
      {"webkit_navigation_action_is_redirect", FALSE},
      {"webkit_response_policy_decision_is_main_frame_document", FALSE},
      {"webkit_response_policy_decision_get_response", FALSE},
      {"webkit_policy_decision_get_frame_info", TRUE},
      {"webkit_navigation_policy_decision_get_frame_info", TRUE},
      {"webkit_navigation_action_get_frame_info", TRUE},
      {"webkit_navigation_action_is_main_frame", TRUE},
      {"webkit_uri_scheme_response_new", FALSE},
      {"webkit_uri_scheme_response_set_http_headers", FALSE},
      {"webkit_uri_scheme_response_set_status", FALSE},
      {"webkit_uri_scheme_request_finish_with_response", FALSE},
      {"webkit_uri_response_get_http_headers", FALSE},
      {"soup_message_headers_new", FALSE},
      {"soup_message_headers_append", FALSE},
  };
  GString *report = g_string_new("symbols:");
  gsize i;

  for (i = 0; i < G_N_ELEMENTS(kCandidates); ++i) {
    const gboolean present =
        (dlsym(RTLD_DEFAULT, kCandidates[i].name) != NULL) ? TRUE : FALSE;

    g_string_append_printf(report, " %s=%s", kCandidates[i].name,
                           present ? "present" : "ABSENT");
    if (present && kCandidates[i].navFrame &&
        (g_navFrameDiscriminator == NULL)) {
      g_navFrameDiscriminator = kCandidates[i].name;
    }
  }
  CapNote("%s", report->str);
  g_string_free(report, TRUE);

  g_isMainFrameDocument = (CapIsMainFrameFn)dlsym(
      RTLD_DEFAULT, "webkit_response_policy_decision_is_main_frame_document");

  /* The two halves are reported separately because they have different
     security weight: a RESPONSE-time answer arrives after the request was
     already made, so only the NAVIGATION-time answer could ever support a
     "deny this subframe before it loads" rule. */
  if (g_isMainFrameDocument != NULL) {
    CapNote("response-time frame discrimination: MEASURED PRESENT - "
            "webkit_response_policy_decision_is_main_frame_document resolves "
            "on the installed library, so a RESPONSE decision CAN tell a "
            "main-frame document from a subframe one. Every response event "
            "carries the verdict in its hook name as main-frame=yes|no");
  } else {
    CapNote("response-time frame discrimination: MEASURED ABSENT - "
            "webkit_response_policy_decision_is_main_frame_document does not "
            "resolve, so not even a RESPONSE decision can say which frame it "
            "belongs to and every response event carries "
            "main-frame=unmeasurable");
  }

  if (g_navFrameDiscriminator != NULL) {
    /* Deliberately loud, because it would invalidate the finding below: the
       probe will NOT call an accessor whose signature it has not read, so
       this is a "re-plan against this symbol" marker rather than a
       measurement of the frame itself. */
    CapNote("navigation-time frame discrimination: %s RESOLVES on the "
            "installed library - the ABSENT finding this shard planned around "
            "no longer holds and the subframe rule must be re-planned against "
            "it. Every navigation event is tagged "
            "main-frame=discriminator-present rather than carrying a verdict, "
            "because this probe does not call a symbol whose signature it has "
            "not verified",
            g_navFrameDiscriminator);
  } else {
    CapNote("navigation-time frame discrimination: MEASURED ABSENT - no "
            "candidate accessor identifies the frame BEING NAVIGATED in a "
            "NAVIGATION_ACTION decision, so every navigation event carries "
            "main-frame=unmeasurable. WebKitNavigationAction exposes "
            "navigation type, user gesture, redirect and (for new-window "
            "actions only) a target frame NAME, none of which identifies the "
            "frame being navigated; WebKitFrame lives in the web-process "
            "extension API, not the UI process. A navigation-time subframe "
            "rule on this engine can therefore only be URI-based, and CSP "
            "frame-src becomes the primary subframe defence. FIRST-CLASS "
            "FINDING - the Windows probe answers the same question through a "
            "dedicated FrameNavigationStarting hook that has no counterpart "
            "here, and macOS through targetFrame.isMainFrame");
  }
}

/* ------------------------------------------------------------------ */
/* the two activation controls the page cannot produce for itself      */
/* ------------------------------------------------------------------ */

static void CapDriveActEval(webview_t w, void *arg) {
  (void)arg;
  webview_eval(w, "location.href = 'https://example.invalid/act-after-eval';");
}

/* A non-exiting X extension error handler, installed only while XTEST calls are
   in flight. It is the belt to XTestQueryExtension's braces: every libXtst
   faking entry point begins with XTestCheckExtension, which on a server that
   lacks the extension routes to Xlib's DEFAULT extension error handler - and
   that handler PRINTS AND CALLS exit(1). A probe that dies there loses every
   phase it has already measured and never writes the artifact at all, which
   directly contradicts this file's own contract that it exits nonzero only when
   it could not MEASURE. This audit is allowed to report "the gesture could not
   be delivered"; it is not allowed to vanish. */
static int CapXExtensionError(void *display, const char *name,
                              const char *reason) {
  (void)display;
  CapNote("act-real-click: X extension error for %s (%s) - swallowed here "
          "rather than allowed to exit the probe",
          (name != NULL) ? name : "<null>",
          (reason != NULL) ? reason : "<null>");
  return 0;
}

/* A REAL pointer gesture, delivered through the X TEST extension - the Linux
   analogue of the Windows probe's SendInput, and for the same reason: a
   synthetic DOM click would not carry a user activation, and asking the page
   where to click would itself grant the activation being measured.
   libXtst is resolved with dlopen rather than linked, so a machine without it
   yields a MEASURED "gesture not delivered" instead of a build dependency the
   ratified CI stack does not install.

   A SUCCESSFUL dlopen PROVES ONLY THAT THE CLIENT LIBRARY EXISTS. Whether the
   SERVER has the extension is a different question - Xvfb can be built without
   XTEST - and it is asked with XTestQueryExtension, the one entry point that
   does NOT route through XextCheckExtension and therefore cannot reach the
   exiting default handler. No faking function is called before that question
   has been answered. */
static void CapDriveActClick(webview_t w, void *arg) {
  typedef int (*CapXTestMotionFn)(void *, int, int, int, unsigned long);
  typedef int (*CapXTestButtonFn)(void *, unsigned int, int, unsigned long);
  typedef int (*CapXTestQueryFn)(void *, int *, int *, int *, int *);
  typedef int (*CapXFlushFn)(void *);
  typedef int (*CapXExtErrorFn)(void *, const char *, const char *);
  typedef CapXExtErrorFn (*CapXSetExtErrorFn)(CapXExtErrorFn);

  static void *xtest;
  GtkWidget *widget = NULL;
  GtkWidget *toplevel = NULL;
  GdkWindow *gdkWindow = NULL;
  CapXTestMotionFn motion = NULL;
  CapXTestButtonFn button = NULL;
  CapXTestQueryFn queryExtension = NULL;
  CapXFlushFn flush = NULL;
  CapXSetExtErrorFn setExtensionError = NULL;
  CapXExtErrorFn previousHandler = NULL;
  gboolean handlerInstalled = FALSE;
  int eventBase = 0;
  int errorBase = 0;
  int majorVersion = 0;
  int minorVersion = 0;
  void *display = NULL;
  gint originX = 0;
  gint originY = 0;
  gint dx = 0;
  gint dy = 0;

  (void)w;
  (void)arg;
  if (g_view == NULL) {
    CapNote("act-real-click: no WebKitWebView - gesture not delivered");
    return;
  }
  widget = GTK_WIDGET(g_view);
  toplevel = gtk_widget_get_toplevel(widget);
  if ((toplevel == NULL) || !GTK_IS_WINDOW(toplevel)) {
    CapNote("act-real-click: no toplevel window - gesture not delivered");
    return;
  }
  gtk_window_present(GTK_WINDOW(toplevel));
  gdkWindow = gtk_widget_get_window(toplevel);
  if (gdkWindow == NULL) {
    CapNote("act-real-click: toplevel is not realised - gesture not delivered");
    return;
  }
  gdk_window_get_origin(gdkWindow, &originX, &originY);
  /* the page laid a fixed 400x200 anchor at the widget origin precisely so this
     offset needs no question asked of the page */
  if (!gtk_widget_translate_coordinates(widget, toplevel, 120, 60, &dx, &dy)) {
    dx = 120;
    dy = 60;
  }

#ifdef GDK_WINDOWING_X11
  {
    GdkDisplay *gdkDisplay = gtk_widget_get_display(toplevel);
    if ((gdkDisplay != NULL) && GDK_IS_X11_DISPLAY(gdkDisplay)) {
      display = (void *)gdk_x11_display_get_xdisplay(gdkDisplay);
    }
  }
#endif
  if (display == NULL) {
    CapNote("act-real-click: not an X11 display - gesture not delivered "
            "(this is a MEASUREMENT of the environment, not a probe failure)");
    return;
  }
  if (xtest == NULL) {
    xtest = dlopen("libXtst.so.6", RTLD_LAZY | RTLD_LOCAL);
  }
  if (xtest != NULL) {
    motion = (CapXTestMotionFn)dlsym(xtest, "XTestFakeMotionEvent");
    button = (CapXTestButtonFn)dlsym(xtest, "XTestFakeButtonEvent");
    /* resolved from the SAME handle: the query and the faking calls must come
       from one library or the answer says nothing about the callee */
    queryExtension = (CapXTestQueryFn)dlsym(xtest, "XTestQueryExtension");
  }
  flush = (CapXFlushFn)dlsym(RTLD_DEFAULT, "XFlush");
  if ((motion == NULL) || (button == NULL) || (queryExtension == NULL) ||
      (flush == NULL)) {
    CapNote("act-real-click: the X TEST CLIENT library is unavailable "
            "(libXtst.so.6 not loadable, or XTestFakeMotionEvent / "
            "XTestFakeButtonEvent / XTestQueryExtension missing from it) - "
            "gesture not delivered, which is a MEASURED result rather than a "
            "probe failure");
    return;
  }

  /* the swallowing handler goes on BEFORE the first X extension call and comes
     off again on every return path below */
  setExtensionError =
      (CapXSetExtErrorFn)dlsym(RTLD_DEFAULT, "XSetExtensionErrorHandler");
  if (setExtensionError != NULL) {
    previousHandler = setExtensionError(CapXExtensionError);
    handlerInstalled = TRUE;
  }

  if (queryExtension(display, &eventBase, &errorBase, &majorVersion,
                     &minorVersion) == 0) {
    if (handlerInstalled) {
      setExtensionError(previousHandler);
    }
    CapNote("act-real-click: the X SERVER does not advertise the XTEST "
            "extension (XTestQueryExtension returned 0; the client library "
            "loaded fine) - gesture not delivered, which is a MEASURED "
            "property of this display and not a probe failure. A server that "
            "can deliver it is started with 'Xvfb +extension XTEST', which is "
            "the default for xvfb-run on the ratified stack");
    return;
  }

  motion(display, -1, (int)(originX + dx), (int)(originY + dy), 0UL);
  flush(display);
  button(display, 1u, 1 /* press */, 0UL);
  button(display, 1u, 0 /* release */, 0UL);
  flush(display);
  if (handlerInstalled) {
    setExtensionError(previousHandler);
  }
  CapNote("act-real-click: XTEST %d.%d pointer click delivered at root(%d,%d) "
          "= window origin(%d,%d) + widget(120,60)",
          majorVersion, minorVersion, (int)(originX + dx),
          (int)(originY + dy), (int)originX, (int)originY);
}

/* ------------------------------------------------------------------ */
/* one phase                                                           */
/* ------------------------------------------------------------------ */

struct CapPhase {
  const char *name;
  enum CapPhaseKind kind;
  const char *startUri;
  gboolean cspOn;
  gboolean cancelUntrusted;
  char **slot;
  int timeoutSeconds;
  /* the single case this phase exists to observe, or "" for the multi-case
     phases that end with a page report */
  const char *expectedCase;
};

/* TRUE when the phase ended before the wait expired. */
static gboolean CapWaitPhaseDone(int milliseconds) {
  struct timespec deadline;
  gboolean done = FALSE;

  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += milliseconds / 1000;
  deadline.tv_nsec += (long)(milliseconds % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000L;
  }

  pthread_mutex_lock(&g_wakeLock);
  while (!g_phaseDone) {
    if (pthread_cond_timedwait(&g_wake, &g_wakeLock, &deadline) == ETIMEDOUT) {
      break;
    }
  }
  done = g_phaseDone;
  pthread_mutex_unlock(&g_wakeLock);
  return done;
}

static void *CapWatchdogThread(void *argument) {
  const struct CapPhase *ph = (const struct CapPhase *)argument;

  /* The activation controls need something to happen that the page cannot do
     for itself; both are timed from here and dispatched onto the GUI loop, and
     both are skipped the moment the phase has already ended. */
  if ((ph->kind == CAP_PHASE_ACT_EVAL) || (ph->kind == CAP_PHASE_ACT_CLICK)) {
    if (!CapWaitPhaseDone(2000)) {
      webview_dispatch(g_webview,
                       (ph->kind == CAP_PHASE_ACT_EVAL) ? CapDriveActEval
                                                        : CapDriveActClick,
                       NULL);
    }
  }
  if (!CapWaitPhaseDone(ph->timeoutSeconds * 1000)) {
    CapNote("watchdog fired - phase %s did not report within %d s (whatever "
            "the page managed to do is already recorded: this is a RESULT, "
            "not a run failure)",
            ph->name, ph->timeoutSeconds);
    /* cross-thread shutdown travels worker -> dispatch -> terminate */
    webview_dispatch(g_webview, CapTerminateOnGuiThread, NULL);
  }
  return NULL;
}

static void CapDestroyPopups(void) {
  while (g_popups->len > 0) {
    GtkWidget *window = g_ptr_array_index(g_popups, g_popups->len - 1);
    g_ptr_array_remove_index(g_popups, g_popups->len - 1);
    if (window != NULL) {
      gtk_widget_destroy(window);
    }
  }
}

static gboolean CapRunPhase(const struct CapPhase *ph) {
  WebKitWebContext *context = NULL;
  WebKitSecurityManager *security = NULL;
  WebKitSettings *settings = NULL;
  struct CapRegistration *registration = NULL;
  pthread_t watchdog;
  gboolean watchdogStarted = FALSE;
  gulong downloadHandler = 0;
  void *controller = NULL;
  static gboolean settingsNoted;
  static gboolean downloadSignalNoted;

  pthread_mutex_lock(&g_lock);
  g_free(g_phaseName);
  g_phaseName = g_strdup(ph->name);
  g_expectedCase = ph->expectedCase;
  g_reportSlot = ph->slot;
  pthread_mutex_unlock(&g_lock);

  pthread_mutex_lock(&g_wakeLock);
  g_phaseDone = FALSE;
  pthread_mutex_unlock(&g_wakeLock);

  g_atomic_int_set(&g_phaseKind, (gint)ph->kind);
  g_atomic_int_set(&g_cspOn, ph->cspOn ? 1 : 0);
  g_atomic_int_set(&g_cancelUntrusted, ph->cancelUntrusted ? 1 : 0);
  g_atomic_int_set(&g_trustedCommitted, 0);

  g_webview = webview_create(0, NULL);
  if (g_webview == NULL) {
    /* the no-display condition: NULL, never a code (c_api_impl discards it) */
    CapNote("webview_create returned NULL - no display, or GTK/WebKitGTK could "
            "not start (run under xvfb-run -a)");
    return FALSE;
  }

  /* The controller is BORROWED from the pinned C ABI: method calls only, and it
     is never ref'd or unref'd - exactly the CAP-7L seam rule. On GTK the
     browser controller IS the WebKitWebView. */
  controller = webview_get_native_handle(
      g_webview, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if (controller == NULL) {
    CapNote("borrowed browser controller unavailable");
    webview_destroy(g_webview);
    g_webview = NULL;
    return FALSE;
  }
  g_view = WEBKIT_WEB_VIEW(controller);

  /* Where the engine thinks it is BEFORE we navigate: the initial-about:blank
     question, measured rather than assumed. */
  if (g_initialSource == NULL) {
    const gchar *initial = webkit_web_view_get_uri(g_view);
    g_initialSource = g_strdup((initial != NULL) ? initial : "<null>");
    CapNote("initial URI before any navigate: %s", g_initialSource);
  }
  if (g_engineVersion == NULL) {
    g_engineVersion =
        g_strdup_printf("%u.%u.%u", webkit_get_major_version(),
                        webkit_get_minor_version(), webkit_get_micro_version());
    CapNote("WebKitGTK %s on GTK %u.%u.%u (API webkit2gtk-4.1, libsoup3)",
            g_engineVersion, gtk_get_major_version(), gtk_get_minor_version(),
            gtk_get_micro_version());
  }

  context = webkit_web_view_get_context(g_view);
  if (context == NULL) {
    CapNote("WebKitWebContext unavailable");
    webview_destroy(g_webview);
    g_webview = NULL;
    g_view = NULL;
    return FALSE;
  }
  security = webkit_web_context_get_security_manager(context);
  if (security == NULL) {
    CapNote("WebKitSecurityManager unavailable");
    webview_destroy(g_webview);
    g_webview = NULL;
    g_view = NULL;
    return FALSE;
  }
  /* classification BEFORE registration and before any navigation, so the very
     first pweb:// document is already a secure, CORS-enabled origin */
  webkit_security_manager_register_uri_scheme_as_secure(security,
                                                        CAP8B_SCHEME);
  webkit_security_manager_register_uri_scheme_as_cors_enabled(security,
                                                              CAP8B_SCHEME);

  if ((g_registration != NULL) && (g_registeredContext == context)) {
    registration = g_registration; /* re-own, never re-register */
    g_atomic_int_set(&registration->active, 1);
  } else {
    registration = (struct CapRegistration *)g_malloc0(sizeof(*registration));
    g_atomic_int_set(&registration->active, 1);
    g_registration = registration;
    g_registeredContext = context;
    /* scheme-WIDE, not per-authority: unlike the WebView2 resource filter this
       handler really does receive pweb://evil, which is exactly what the audit
       needs and what CAP-7L already measured */
    webkit_web_context_register_uri_scheme(context, CAP8B_SCHEME,
                                           CapSchemeRequest, registration,
                                           CapRegistrationDestroyed);
  }

  settings = webkit_web_view_get_settings(g_view);
  if (settings != NULL) {
    if (!settingsNoted) {
      settingsNoted = TRUE;
      CapNote(
          "MEASURED defaults before the probe touches them: "
          "javascript_can_open_windows_automatically=%d, "
          "allow_top_navigation_to_data_urls=%d. The popup default is FALSE, "
          "an INDEPENDENT barrier production inherits for free; the probe sets "
          "it TRUE so window.open reaches the native hook instead of being "
          "suppressed before it - otherwise the exposure and coverage "
          "measurements would only prove that a popup blocker exists",
          webkit_settings_get_javascript_can_open_windows_automatically(
              settings)
              ? 1
              : 0,
          webkit_settings_get_allow_top_navigation_to_data_urls(settings) ? 1
                                                                         : 0);
    }
    webkit_settings_set_javascript_can_open_windows_automatically(settings,
                                                                  TRUE);
    /* console messages carry the engine's own CSP violation text, which is the
       difference between "the row says blocked" and knowing WHY */
    webkit_settings_set_enable_write_console_messages_to_stdout(settings, TRUE);
  }

  g_signal_connect(g_view, "decide-policy", G_CALLBACK(CapDecidePolicy), NULL);
  g_signal_connect(g_view, "create", G_CALLBACK(CapOnCreate), NULL);
  /* the context is shared and outlives the view, so this one must come back off
     again at teardown */
  g_downloadSignalPresent =
      (g_signal_lookup("download-started", WEBKIT_TYPE_WEB_CONTEXT) != 0);
  if (g_downloadSignalPresent) {
    downloadHandler = g_signal_connect(
        context, "download-started", G_CALLBACK(CapOnDownloadStarted), NULL);
  } else if (!downloadSignalNoted) {
    downloadSignalNoted = TRUE;
    CapNote("\"download-started\" does not exist on WebKitWebContext in this "
            "library - no handler could be connected, so the download hook "
            "cannot be exercised and download_hook_available is false for that "
            "reason");
  }

  if (webview_bind(g_webview, "__pweb_invoke", CapBindInvoke, NULL) <
      WEBVIEW_ERROR_OK) {
    CapNote("webview_bind(__pweb_invoke) failed");
  }
  if (webview_bind(g_webview, "__cap8b_ping", CapBindPing, NULL) <
      WEBVIEW_ERROR_OK) {
    CapNote("webview_bind(__cap8b_ping) failed");
  }
  if (webview_bind(g_webview, "__cap8b_report", CapBindReport, NULL) <
      WEBVIEW_ERROR_OK) {
    CapNote("webview_bind(__cap8b_report) failed");
  }

  if (pthread_create(&watchdog, NULL, CapWatchdogThread, (void *)ph) == 0) {
    watchdogStarted = TRUE;
  } else {
    CapNote("watchdog thread could not start - phase %s has no deadline",
            ph->name);
  }

  webview_set_title(g_webview, "CAP-8B audit");
  webview_set_size(g_webview, 900, 650, WEBVIEW_HINT_NONE);
  webview_navigate(g_webview, ph->startUri);
  webview_run(g_webview);

  /* Whatever happened above, the watchdog is released and joined before any
     native state dies: a thread still holding g_webview across webview_destroy
     is a use-after-free with a timer on it. */
  CapSignalPhaseDone();
  if (watchdogStarted) {
    pthread_join(watchdog, NULL);
  }

  if (downloadHandler != 0) {
    g_signal_handler_disconnect(context, downloadHandler);
  }
  /* windows we granted go first: they hold views related to the one upstream is
     about to destroy */
  CapDestroyPopups();

  webview_unbind(g_webview, "__pweb_invoke");
  webview_unbind(g_webview, "__cap8b_ping");
  webview_unbind(g_webview, "__cap8b_report");

  /* disown BEFORE destroy: the scheme callback cannot be unregistered on this
     engine, so it must be unable to serve anything afterwards */
  if (registration != NULL) {
    g_atomic_int_set(&registration->active, 0);
  }

  pthread_mutex_lock(&g_lock);
  g_reportSlot = NULL;
  g_expectedCase = NULL;
  pthread_mutex_unlock(&g_lock);

  webview_destroy(g_webview);
  g_webview = NULL;
  g_view = NULL;
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* the artifact                                                        */
/* ------------------------------------------------------------------ */

static int CapArrivalCmp(gconstpointer a, gconstpointer b) {
  const struct CapArrival *x = *(const struct CapArrival *const *)a;
  const struct CapArrival *y = *(const struct CapArrival *const *)b;
  return strcmp(x->label, y->label);
}

static void CapAppendJson(GString *j, const char *value) {
  char *escaped = CapJStr(value);
  g_string_append(j, escaped);
  g_free(escaped);
}

static gboolean CapWriteJson(const char *path) {
  GString *j = g_string_new("{\n");
  guint i;
  FILE *f = NULL;

  g_string_append(j, "  \"schema\": 1,\n");
  g_string_append(j, "  \"target\": \"linux-x86_64\",\n");
  g_string_append(j, "  \"engine\": \"WebKitGTK 4.1\",\n");
  g_string_append(j, "  \"engine_version\": ");
  CapAppendJson(j, g_engineVersion);
  g_string_append(j, ",\n  \"initial_source_before_navigate\": ");
  CapAppendJson(j, g_initialSource);
  g_string_append_printf(j, ",\n  \"csp_headers_emitted\": %d,\n",
                         g_cspHeadersEmitted);
  /* OBSERVED, never inferred: this is "download-started actually fired", not
     "the signal exists". A note states the same thing in words, and states it
     whichever way the measurement came out. */
  g_string_append_printf(j, "  \"download_hook_available\": %s,\n",
                         CapJBool(g_atomic_int_get(&g_downloadEventsSeen) > 0));
  g_string_append(j, "  \"candidate_csp\": ");
  CapAppendJson(j, kCandidateCsp);
  g_string_append(j, ",\n");
  /* One line a reader can put at the head of the user_initiated column. Two
     targets whose columns look alike but whose semantics differ is exactly the
     silently-vacuous comparison this artifact exists to prevent. */
  g_string_append(j, "  \"user_initiated_semantics\": ");
  CapAppendJson(j,
                "engine-reported gesture flag "
                "(webkit_navigation_action_is_user_gesture) on every "
                "decide-policy navigation/new-window action and on the create "
                "signal; not exposed at all on a response decision, on an "
                "action-less decision or on download-started, emitted there as "
                "null");
  g_string_append(j, ",\n");

  /* sorted, so the four documents diff cleanly */
  g_ptr_array_sort(g_arrivals, CapArrivalCmp);
  g_string_append(j, "  \"native_arrivals\": {");
  for (i = 0; i < g_arrivals->len; ++i) {
    const struct CapArrival *a = g_ptr_array_index(g_arrivals, i);
    g_string_append(j, (i == 0) ? "\n    " : ",\n    ");
    CapAppendJson(j, a->label);
    g_string_append_printf(j, ": %d", a->count);
  }
  g_string_append(j, (g_arrivals->len == 0) ? "},\n" : "\n  },\n");

  g_string_append(j, "  \"events\": [");
  for (i = 0; i < g_events->len; ++i) {
    const struct CapEvent *e = g_ptr_array_index(g_events, i);
    g_string_append(j, (i == 0) ? "\n" : ",\n");
    g_string_append(j, "    { \"phase\": ");
    CapAppendJson(j, e->phase);
    g_string_append(j, ", \"case\": ");
    CapAppendJson(j, e->caseName);
    g_string_append(j, ", \"hook\": ");
    CapAppendJson(j, e->hook);
    g_string_append(j, ", \"uri\": ");
    CapAppendJson(j, e->uri);
    /* null, not false, when the engine was never asked - see struct CapEvent */
    g_string_append_printf(j, ", \"user_initiated\": %s",
                           e->userInitiatedKnown ? CapJBool(e->userInitiated)
                                                 : "null");
    g_string_append(j, ", \"user_initiated_basis\": ");
    CapAppendJson(j, e->basis);
    g_string_append_printf(j, ", \"policy\": %s", CapJBool(e->policy));
    g_string_append_printf(j, ", \"redirected\": %s", CapJBool(e->redirected));
    g_string_append_printf(j, ", \"cancelled\": %s", CapJBool(e->cancelled));
    g_string_append_printf(j, ", \"bootstrap_allowed\": %s",
                           CapJBool(e->bootstrapAllowed));
    g_string_append(j, ", \"detail\": ");
    CapAppendJson(j, e->detail);
    g_string_append(j, " }");
  }
  g_string_append(j, (g_events->len == 0) ? "],\n" : "\n  ],\n");

  g_string_append(j, "  \"exposure_report\": ");
  CapAppendJson(j, g_exposureReport);
  g_string_append(j, ",\n  \"coverage_report\": ");
  CapAppendJson(j, g_coverageReport);
  g_string_append(j, ",\n  \"csp_report\": ");
  CapAppendJson(j, g_cspReport);
  g_string_append(j, ",\n  \"csp_meta_report\": ");
  CapAppendJson(j, g_cspMetaReport);
  g_string_append(j, ",\n");

  g_string_append(j, "  \"beacons\": [");
  for (i = 0; i < g_beacons->len; ++i) {
    g_string_append(j, (i == 0) ? "\n    " : ",\n    ");
    CapAppendJson(j, g_ptr_array_index(g_beacons, i));
  }
  g_string_append(j, (g_beacons->len == 0) ? "],\n" : "\n  ],\n");

  g_string_append(j, "  \"notes\": [");
  for (i = 0; i < g_notes->len; ++i) {
    g_string_append(j, (i == 0) ? "\n    " : ",\n    ");
    CapAppendJson(j, g_ptr_array_index(g_notes, i));
  }
  g_string_append(j, (g_notes->len == 0) ? "]\n" : "\n  ]\n");
  g_string_append(j, "}\n");

  f = fopen(path, "wb");
  if (f == NULL) {
    fprintf(stderr, "[cap8b] cannot write %s: %s\n", path, strerror(errno));
    g_string_free(j, TRUE);
    return FALSE;
  }
  fwrite(j->str, 1, j->len, f);
  fclose(f);
  printf("[cap8b] wrote %s (%lu bytes)\n", path, (unsigned long)j->len);
  fflush(stdout);
  g_string_free(j, TRUE);
  return TRUE;
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
  static const struct CapPhase kPhases[] = {
      {"exposure", CAP_PHASE_EXPOSURE, "pweb://app/index.html", FALSE, FALSE,
       &g_exposureReport, 30, ""},
      {"coverage", CAP_PHASE_COVERAGE, "pweb://app/index.html", FALSE, TRUE,
       &g_coverageReport, 90, ""},
      {"csp", CAP_PHASE_CSP, "pweb://app/csp.html", TRUE, FALSE, &g_cspReport,
       30, ""},
      {"csp-meta", CAP_PHASE_CSP_META, "pweb://app/csp-meta.html", TRUE, FALSE,
       &g_cspMetaReport, 30, ""},
      /* the four user-activation controls: one navigation each, a fresh WebView
         each, and a page that makes no native call it does not have to */
      {"activation-plain", CAP_PHASE_ACT_PLAIN, "pweb://app/index.html", FALSE,
       TRUE, NULL, 15, "act-plain"},
      {"activation-bind", CAP_PHASE_ACT_BIND, "pweb://app/index.html", FALSE,
       TRUE, NULL, 15, "act-after-bind"},
      {"activation-eval", CAP_PHASE_ACT_EVAL, "pweb://app/index.html", FALSE,
       TRUE, NULL, 15, "act-after-eval"},
      {"activation-click", CAP_PHASE_ACT_CLICK, "pweb://app/index.html", FALSE,
       TRUE, NULL, 20, "act-real-click"},
      /* the two redirect controls: the audit rule is deliberately NOT
         cancelling here, so a redirect this engine WOULD follow is actually
         followed. The zero-network floor still refuses the external target, but
         it refuses it AFTER recording the event, so "the hook saw the target"
         stays measurable while nothing reaches a wire. */
      {"redirect-external", CAP_PHASE_REDIRECT_EXTERNAL,
       "pweb://app/index.html", FALSE, FALSE, NULL, 15, "redirect-out-of-pweb"},
      {"redirect-internal", CAP_PHASE_REDIRECT_INTERNAL,
       "pweb://app/index.html", FALSE, FALSE, NULL, 15, ""},
  };
  gsize i;
  int ran = 0;

  if (argc < 2) {
    fprintf(stderr, "usage: cap8b_audit_linux <output.json>\n");
    return 2;
  }

  /* The hosted-runner condition, matched deliberately and set BEFORE the first
     webview_create - which is where GTK is initialised and from where the web
     process is later spawned: no GPU, no compositor. overwrite=0, so an
     explicit value from run_audit_linux.sh always wins. */
  setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", 0);
  setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
  setenv("GDK_BACKEND", "x11", 0);
  setenv("LIBGL_ALWAYS_SOFTWARE", "1", 0);

  g_events = g_ptr_array_new();
  g_arrivals = g_ptr_array_new();
  g_notes = g_ptr_array_new();
  g_beacons = g_ptr_array_new();
  g_popups = g_ptr_array_new();

  CapNote("CAP-8B Linux audit probe: build-time response API = %s "
          "(CAP8B_HAVE_SOUP3=%d, WEBKIT_CHECK_VERSION(2,36,0)=%d)",
          CAP8B_RESPONSE_API ? "available" : "UNAVAILABLE",
          CAP8B_HAVE_SOUP3 ? 1 : 0, WEBKIT_CHECK_VERSION(2, 36, 0) ? 1 : 0);
  CapProbeSymbols();
  CapNote("upstream injects its shim user script with "
          "WEBKIT_USER_CONTENT_INJECT_TOP_FRAME but registers the "
          "\"__webview__\" script message handler on the page's user content "
          "manager, which WebKit exposes in EVERY frame - so every context "
          "attacks the raw handler as well as the shim, and native_arrivals is "
          "the only authority on what got through");
  CapNote("zero-network floor: decide-policy denies, in every phase, any "
          "navigation whose scheme is not pweb:/about:/data:/blob:, so a CSP "
          "this engine turns out not to enforce still cannot produce a request");
  CapNote("cancelling rule, identical to the Windows probe and deliberately "
          "WEAKER than the production rule: untrusted navigations are "
          "cancelled in ANY frame, trusted ones are allowed, so the trusted "
          "first leg of the redirect and download probes actually runs. What "
          "diverges is not the rule but what an event can say about itself - "
          "WebView2 knows the frame from which of its two hooks fired, and "
          "this engine has one hook, so every event here carries the measured "
          "main-frame= verdict instead");

  for (i = 0; i < G_N_ELEMENTS(kPhases); ++i) {
    CapNote("=== phase %s ===", kPhases[i].name);
    if (CapRunPhase(&kPhases[i])) {
      ran += 1;
    } else {
      CapNote("phase %s could not run", kPhases[i].name);
    }
    /* REWRITTEN AFTER EVERY PHASE. A single write point at the end means any
       abort, SIGSEGV, OOM-kill or CI timeout during phases 2-10 discards
       every phase that already succeeded and leaves no artifact at all - the
       exact loss the XTEST repair was made to prevent, re-created for every
       other failure mode. The document is complete and valid after each
       phase, so whatever the process survives to measure survives with it.
       A failure here is deliberately NOT fatal yet: the final write below is
       the one that decides the exit code. */
    (void)CapWriteJson(argv[1]);
  }

  CapNote("csp headers emitted on trusted HTML: %d; response decisions that saw "
          "the header round-trip back through "
          "webkit_uri_response_get_http_headers: %d",
          g_cspHeadersEmitted, g_cspHeadersRoundtripped);

  /* download_hook_available is an OBSERVATION or it is nothing. Whichever way
     it came out, the note says in words what the boolean means, because a
     reader comparing four targets must never have to guess whether a false
     means "this engine cannot observe downloads" or "this probe never asked". */
  if (g_atomic_int_get(&g_downloadEventsSeen) > 0) {
    CapNote("download hook: MEASURED PRESENT - \"download-started\" fired %d "
            "time(s) and every one was refused with webkit_download_cancel "
            "before decide-destination ran, so nothing reached disk. "
            "download_hook_available reports THAT firing and never the "
            "existence of the signal",
            g_atomic_int_get(&g_downloadEventsSeen));
  } else {
    CapNote("download hook: NOT EXERCISED - \"download-started\" never fired "
            "(the signal itself exists on WebKitWebContext: %s), so "
            "download_hook_available is emitted FALSE as a plain statement "
            "that THIS PROBE COULD NOT EXERCISE THE HOOK on this engine, and "
            "NOT as a measurement that the engine cannot observe downloads. "
            "On this engine a download is not a hook the page can reach on its "
            "own: an undisplayable response arrives at decide-policy, and only "
            "webkit_policy_decision_download() turns it into a download at all",
            g_downloadSignalPresent ? "yes" : "no");
  }

  if (!CapWriteJson(argv[1])) {
    /* the measurement could not be recorded: an instrument failure */
    fprintf(stderr, "[cap8b] CAP8B_AUDIT_LINUX_UNWRITABLE\n");
    return 1;
  }
  if (ran == 0) {
    /* Nothing was measured at all: that is an instrument failure, not a result,
       and the harness must be able to tell the two apart. */
    fprintf(stderr, "[cap8b] CAP8B_AUDIT_LINUX_UNAVAILABLE\n");
    return 3;
  }
  printf("[cap8b] CAP8B_AUDIT_LINUX_DONE phases=%d/%d\n", ran,
         (int)G_N_ELEMENTS(kPhases));
  fflush(stdout);
  return 0;
}
