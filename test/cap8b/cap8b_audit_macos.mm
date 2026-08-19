/*
 * CAP-8B macOS/WKWebView MEASUREMENT probe.
 *
 * This is an AUDIT INSTRUMENT, not production and not a gate of the shipped
 * policy. It is the macOS sibling of test/cap8b/cap8b_audit_win.cpp, whose
 * phase list, fixture corpus, JS drivers, case attribution and JSON schema it
 * follows deliberately, and it answers the three questions CAP-8B's
 * Checkpoint 1 is not allowed to assume:
 *
 *   1. BRIDGE EXPOSURE - from which frame/window contexts is the privileged
 *      native binding reachable, through the public shim AND through the
 *      lowest raw transport the engine leaves exposed? On WebKit that lowest
 *      transport is window.webkit.messageHandlers.__webview__.postMessage, and
 *      measuring only the shim would be WORTHLESS here: upstream injects its
 *      user script TOP-FRAME-ONLY (cocoa_webkit.hh:250 passes
 *      forMainFrameOnly=true to WKUserScript_withSource) while it registers
 *      the "__webview__" SCRIPT MESSAGE HANDLER on the user content
 *      controller (cocoa_webkit.hh:508), which WebKit exposes in EVERY frame.
 *      The raw channel may therefore be reachable exactly where the shim is
 *      not, which is the whole point of the exercise.
 *   2. NAVIGATION COVERAGE - for each navigation kind, does the proposed
 *      native hook OBSERVE it, and can it CANCEL it before content executes?
 *   3. ACTIVE SUBRESOURCES - is a Content-Security-Policy delivered as a
 *      RESPONSE HEADER on the custom scheme actually enforced, and can a
 *      bundle <meta> CSP weaken it?
 *
 * It is written in Objective-C++ against the REAL WebKit framework on
 * purpose, exactly as test/cap7m/cap7m_probe.mm is: the production adapter
 * reaches WKWebView through a hand-written Pascal/ObjC seam, and a
 * measurement taken through that seam cannot distinguish "the engine behaves
 * like this" from "my seam is wrong". Compiled WITHOUT ARC to match the
 * repository's existing bridge, because the ownership of the +new return
 * value, of the tracked tasks and of the delegate objects is explicit here
 * exactly as it is in Pascal.
 *
 * ============================ WHAT THIS IS NOT ============================
 *
 * It includes, links and modifies NOTHING under src/. It does not include
 * pweb_cocoa_bridge.h, it does not link pweb_cocoa_bridge.o, and it shares no
 * code with the production adapter - it REPRODUCES the pre-create seam
 * technique that adapter uses, so that what is being measured is the engine
 * and not our own plumbing. deps/webview is not patched; the public export
 * surface stays at 17.
 *
 * It is not a second URI validator either. The fixture router below answers
 * for the HOSTILE authority on purpose and is deliberately a prefix test -
 * exactly what the PRODUCTION classifier is forbidden to be, since the
 * product's verdict comes from PWebParseAppUri over parsed components.
 *
 * DELIBERATELY HOSTILE FIXTURE. This probe serves pweb://evil/* content on
 * purpose - that is the untrusted document whose reach is being measured.
 *
 * ZERO NETWORK. Every "external" URI targets the reserved TLD
 * example.invalid, and every case is decided by a native hook BEFORE a
 * request could leave the machine. The two redirect probes are produced by
 * the probe's OWN 302 responses, never by a server. No listener, no loopback,
 * no HTTP: the corpus is served from memory by this file's own
 * WKURLSchemeHandler and never touches disk.
 *
 * WHAT IS NOT A FAILURE. A measurement that says "this engine does not expose
 * that" is a RESULT. The probe exits nonzero only when it could not MEASURE -
 * no WKWebView, no session, no window - never because a measured value was
 * inconvenient.
 *
 * ====================== WHAT IS SHARED, AND WHAT IS NOT ===================
 *
 * The JS drivers are BYTE-IDENTICAL to cap8b_audit_win.cpp's except for the
 * raw-transport expression, which is engine-specific by definition: Chromium
 * exposes window.chrome.webview, WebKit exposes
 * window.webkit.messageHandlers.__webview__. Every other character - including
 * the Windows-shaped file:/// path in the coverage driver - is retained
 * VERBATIM, because a case whose text differs across targets is a case whose
 * results cannot be compared.
 *
 * The two structural rules the Windows driver learned the hard way are kept
 * for the same reasons, and they matter MORE here rather than less:
 *
 *   1. THE COVERAGE DRIVER MAKES NO NATIVE CALL until its final report. Cases
 *      are attributed NATIVELY by their unique URI (CaseForUri). On WebView2
 *      the reason was measured - a binding promise resolves through
 *      ExecuteScript, which carries a user gesture - and whether
 *      -[WKWebView evaluateJavaScript:] does the same on WebKit is one of the
 *      things the four activation phases exist to measure. A driver that
 *      announced its cases through a binding would answer that question with
 *      its own contamination.
 *   2. THE DESTRUCTIVE CASES RUN IN A TRUSTED SUBFRAME, so a redirect, a
 *      download or a meta refresh cannot replace the driver's own document
 *      and silently drop every later case.
 *
 * ================== THE ENGINE FACTS THIS FILE MEASURES ===================
 *
 *   - THE PRE-CREATE PROBLEM. Upstream builds the WKWebViewConfiguration and
 *     the WKWebView both inside webview_create (cocoa_webkit.hh:450,486), so
 *     there is no moment between them a caller can reach - unless the caller
 *     owns the constructor. The seam below overrides +[WKWebViewConfiguration
 *     new] on that class's OWN metaclass with class_addMethod and installs the
 *     handler with the PUBLIC setURLSchemeHandler:forURLScheme:. It
 *     deliberately does NOT use class_getClassMethod, which would return
 *     NSObject's inherited +new and swizzle +new for every class in the
 *     process; SeamIsConfined() asserts all three observable halves of that
 *     confinement, including the BEHAVIOURAL one - constructing unrelated
 *     objects with +new must not move the seam counter.
 *
 *   - THE NAVIGATION DELEGATE IS FREE. Upstream installs its own WKUIDelegate
 *     ("WebviewWKUIDelegate", used only for runOpenPanelWithParameters,
 *     cocoa_webkit.hh:324) and leaves the NAVIGATION delegate unset, so
 *     -[WKWebView setNavigationDelegate:] on the BROWSER_CONTROLLER handle is
 *     an unoccupied seam. This probe takes it, and also temporarily takes the
 *     UI delegate - restoring upstream's before webview_destroy, so upstream's
 *     destructor releases its own object exactly once - because
 *     createWebViewWithConfiguration: is the ONLY place "was a target=_blank
 *     child ever created" can be observed. The probe never opens a file panel,
 *     so displacing that delegate is inert for the run.
 *
 *   - USER ACTIVATION, AND THE ONE FIELD THIS FILE REFUSES TO FAKE.
 *     -[WKNavigationAction _isUserInitiated] is PRIVATE SPI and is ABSOLUTELY
 *     FORBIDDEN in this repository. WebView2's IsUserInitiated has NO public
 *     equivalent here: this engine exposes NO gesture flag a public API can
 *     read. So user_initiated is emitted as JSON **null** on EVERY event of
 *     this target, never as false - a false would assert that the engine
 *     answered "no gesture" when the engine was never asked, and a
 *     cross-target column built from that assertion would compare a
 *     measurement against a fabrication. What IS observed travels in nav_type
 *     (the raw WKNavigationType), and user_initiated_basis states, per row,
 *     what could have been derived from it: "derived:navigationType==
 *     WKNavigationTypeLinkActivated" on the hooks handed a WKNavigationAction,
 *     "unavailable:..." on the hooks handed none. Whether that derivation is a
 *     sound stand-in is a question for the plan, not for this file; the four
 *     activation phases feed it the data - a timer navigation, a navigation in
 *     a binding-promise continuation, a host evaluateJavaScript: navigation
 *     and a REAL synthesised mouse gesture on a focused anchor - and the notes
 *     say so explicitly.
 *
 *   - EXACTLY-ONCE COMPLETION. Every WKNavigationDelegate decisionHandler and
 *     every WKDownloadDelegate completionHandler is invoked EXACTLY ONCE on
 *     EVERY path including the exception path: a missed completion hangs
 *     WebKit and a second call raises. The call site sits OUTSIDE the barrier
 *     that guards the computation, which is what makes "exactly once"
 *     structural rather than hoped for.
 *
 *   - WKURLSchemeTask THROWS. Apple documents an NSException for a second
 *     response after completion, data before a response, finish before a
 *     response, finish/fail after either, and ANY callback after
 *     stopURLSchemeTask: - and CAP-7M0 MEASURED poststop_throws=1, so the
 *     claim-exactly-once gate below is load-bearing rather than cargo-culted.
 *     Assets are served with NSHTTPURLResponse and never a bare
 *     NSURLResponse: CAP-7M0 measured that a bare one LOADS the resource
 *     perfectly while fetch() reports status 0 and ok === false, which would
 *     silently corrupt every fetch-based row of the CSP phase.
 *
 *   - NO NSException, no ObjC object throw and no C++ exception may cross a C
 *     or ObjC callback boundary. Every callback body is an exception barrier:
 *     a C++ try wrapping an @try/@catch(NSException*)/@catch(id) triple. BOTH
 *     halves are required and neither implies the other: on the 64-bit runtime
 *     `catch (...)` does catch an ObjC throw, but @catch(id) does NOT catch a
 *     C++ one - and every body below builds std::string and pushes onto
 *     std::vector/std::map, so std::bad_alloc and std::length_error are live
 *     paths out of each of them. The barrier is on the C ABI callbacks
 *     (webview_bind handlers, webview_dispatch handlers) and on the
 *     +[WKWebViewConfiguration new] override too - those are reached through
 *     objc_msgSend and a C function pointer respectively, which is exactly
 *     where an escaping exception becomes undefined behaviour rather than a
 *     stack trace.
 *
 * NO FPU REMEDY HERE, DELIBERATELY. The FPC-hosted processes in this
 * repository must call fesetenv(FE_DFL_ENV) before any WebKit work, because
 * FPC enables the invalid-operation, divide-by-zero and overflow traps at
 * startup while WebKit computes with NaNs and infinities as ordinary
 * intermediate values (see src/platform/macos/pweb_cocoa_bridge.mm's
 * pweb_cocoa_mask_fpu_traps). This probe is pure C++/Objective-C++ with no
 * Pascal runtime in the picture, so the traps were never enabled and the
 * remedy is not needed. Do not add it by cargo cult - CAP-7M0's diagnosis
 * rests on exactly this asymmetry.
 *
 * DEPLOYMENT TARGET. The floor is pinned at 12.0 (webview.lock
 * macos-deployment-target). Every API this file touches - WKDownload,
 * WKDownloadDelegate, -[WKNavigationAction shouldPerformDownload],
 * webView:navigationAction:didBecomeDownload: and
 * webView:navigationResponse:didBecomeDownload: - was introduced in macOS
 * 11.3, BELOW that floor, so there is nothing an @available guard could
 * usefully guard and none is written. download_hook_available is nevertheless
 * a RUNTIME query (objc_getClass("WKDownload")), because "the SDK declared it"
 * and "this machine has it" are different statements.
 *
 * TERMINATION. Each phase is bounded by its own watchdog thread, which shuts
 * the phase down through webview_dispatch -> webview_terminate (the
 * cross-thread route CAP-7M ratified; NSApplication is main-thread affine, so
 * calling terminate from the watchdog directly would be a threading defect
 * rather than a shortcut). The artifact is rewritten after EVERY phase, so a
 * process killed by an outer harness bound still leaves everything measured
 * up to that point.
 *
 * Usage: cap8b_audit_macos <output.json>
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#include <objc/runtime.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "webview/api.h"

/* The target id the aggregator keys on, resolved at COMPILE time from the
   architecture actually being built and never from uname: nothing in this
   project cross-builds, and a run that reported the host's idea of its
   architecture would let a translated execution masquerade as the other
   slice's proof. */
#if defined(__aarch64__) || defined(__arm64__)
#define CAP8B_TARGET "macos-arm64"
#elif defined(__x86_64__)
#define CAP8B_TARGET "macos-x86_64"
#else
#error "CAP-8B macOS audit probe: unsupported architecture"
#endif

#define CAP8B_SCHEME @"pweb"

namespace {

/* ------------------------------------------------------------------ */
/* small helpers                                                       */
/* ------------------------------------------------------------------ */

std::string Narrow(NSString *s) {
  if (s == nil) {
    return std::string{};
  }
  const char *utf8 = [s UTF8String];
  return (utf8 != NULL) ? std::string{utf8} : std::string{};
}

NSString *Widen(const std::string &s) {
  NSString *r = [NSString stringWithUTF8String:s.c_str()];
  return (r != nil) ? r : @"";
}

/* The probe emits its own JSON so the harness never has to trust a
   page-supplied string to be well formed: every page report crosses this
   escaper before it lands in the artifact. */
std::string JStr(const std::string &s) {
  std::string o = "\"";
  for (const char raw : s) {
    const unsigned char c = static_cast<unsigned char>(raw);
    switch (c) {
    case '"':
      o += "\\\"";
      break;
    case '\\':
      o += "\\\\";
      break;
    case '\n':
      o += "\\n";
      break;
    case '\r':
      o += "\\r";
      break;
    case '\t':
      o += "\\t";
      break;
    default:
      if (c < 0x20) {
        char buf[8];
        std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
        o += buf;
      } else {
        o += raw;
      }
    }
  }
  o += "\"";
  return o;
}

std::string JBool(bool b) { return b ? "true" : "false"; }

void AppendUtf8(std::string &out, unsigned int cp) {
  if (cp < 0x80) {
    out += static_cast<char>(cp);
  } else if (cp < 0x800) {
    out += static_cast<char>(0xC0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else {
    out += static_cast<char>(0xE0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  }
}

/* Extract and UNESCAPE the first JSON string literal of a webview_bind
   request payload. The payload is always a params array whose first element
   this probe controls, so a full JSON parser would be ceremony - but the
   unescaping is not optional: the page reports are themselves JSON, so every
   quote inside them arrives escaped, and handing the raw array on would make
   every consumer of the artifact unwrap it twice. */
std::string FirstJsonString(const std::string &request) {
  const size_t start = request.find('"');
  if (start == std::string::npos) {
    return std::string{"<unparsed>"};
  }
  std::string out;
  for (size_t i = start + 1; i < request.size(); ++i) {
    const char c = request[i];
    if (c == '"') {
      return out;
    }
    if (c != '\\') {
      out += c;
      continue;
    }
    if ((i + 1) >= request.size()) {
      break;
    }
    const char esc = request[++i];
    switch (esc) {
    case 'n':
      out += '\n';
      break;
    case 'r':
      out += '\r';
      break;
    case 't':
      out += '\t';
      break;
    case 'b':
      out += '\b';
      break;
    case 'f':
      out += '\f';
      break;
    case 'u': {
      if ((i + 4) >= request.size()) {
        return out;
      }
      unsigned int cp = 0;
      bool ok = true;
      for (int k = 1; k <= 4; ++k) {
        const char h = request[i + static_cast<size_t>(k)];
        cp <<= 4;
        if (h >= '0' && h <= '9') {
          cp |= static_cast<unsigned int>(h - '0');
        } else if (h >= 'a' && h <= 'f') {
          cp |= static_cast<unsigned int>(h - 'a' + 10);
        } else if (h >= 'A' && h <= 'F') {
          cp |= static_cast<unsigned int>(h - 'A' + 10);
        } else {
          ok = false;
          break;
        }
      }
      if (!ok) {
        out += "\\u";
        break;
      }
      AppendUtf8(out, cp);
      i += 4;
      break;
    }
    default:
      out += esc;
      break;
    }
  }
  return std::string{"<unterminated>"};
}

/* ------------------------------------------------------------------ */
/* phases                                                              */
/* ------------------------------------------------------------------ */

/* The activation phases are separate WebViews on purpose. MEASURED on
   WebView2 (151.0.4129.86): a navigation performed in the continuation of a
   webview_bind promise reports IsUserInitiated = TRUE, because upstream
   resolves that promise through ExecuteScript and WebView2 runs host-injected
   script WITH a user gesture. Whether -[WKWebView evaluateJavaScript:] - which
   is how upstream's eval_impl and therefore webview_return reach the page on
   this backend - grants a gesture too is UNMEASURED, and these four phases are
   how it stops being unmeasured. Any driver that called a native binding
   between cases would contaminate the reading, which is why the coverage
   driver makes no native call until its final report. */
enum class PhaseKind {
  Exposure,
  Coverage,
  Csp,
  CspMeta,
  ActPlain,
  ActBind,
  ActEval,
  ActClick,
  RedirectExternal,
  RedirectInternal
};

/* ------------------------------------------------------------------ */
/* the JS drivers                                                      */
/* ------------------------------------------------------------------ */

/* The script every CHILD context runs. It reports what it can SEE and then
   attempts the bridge two ways: through the public shim, and through the RAW
   transport with the upstream envelope shape - which is the lowest path a
   page can reach and the one an isolation proof must attack. The native
   arrival counters, not this script's own optimism, are the authority on what
   actually reached native.
   THE ONLY DIVERGENCE from the Windows driver is the raw transport: WebKit's
   is window.webkit.messageHandlers.__webview__.postMessage, the message
   handler upstream registers at cocoa_webkit.hh:508. The {id, method, params}
   envelope is shared, because upstream's own shim posts exactly that shape on
   every backend (engine_base.hh:235). */
constexpr char kChildJs[] =
    "(function(){\n"
    "  var ctx = window.__cap8b_ctx || 'unknown';\n"
    "  var out = { ctx: ctx, shim: (typeof window.__pweb_invoke),\n"
    "              webview: (typeof window.__webview__), raw: false,\n"
    "              origin: '?', shimThrew: null, rawThrew: null };\n"
    "  try { out.origin = String(location.origin); } catch (e) {}\n"
    "  try { out.raw = !!(window.webkit && window.webkit.messageHandlers &&\n"
    "        window.webkit.messageHandlers.__webview__ && typeof\n"
    "        window.webkit.messageHandlers.__webview__.postMessage ===\n"
    "        'function'); }\n"
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
   reports the collected child records plus its own. __CHILDJS__ is replaced
   by the child source as a JS string literal before this is served. */
constexpr char kExposureJs[] =
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
    "      try { self.raw = !!(window.webkit && window.webkit.messageHandlers\n"
    "        && window.webkit.messageHandlers.__webview__ && typeof\n"
    "        window.webkit.messageHandlers.__webview__.postMessage ===\n"
    "        'function'); }\n"
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

/* The navigation-coverage driver, VERBATIM from cap8b_audit_win.cpp.
 *
 * TWO STRUCTURAL RULES, both learned there from a first run that measured the
 * wrong thing, and both kept here for the same reasons:
 *
 *  1. IT MAKES NO NATIVE CALL until its final report. Cases are attributed
 *     NATIVELY, by their unique URI (CaseForUri), so that nothing the driver
 *     does can grant the user activation the activation phases are measuring.
 *  2. THE DESTRUCTIVE CASES RUN IN A TRUSTED SUBFRAME. A redirect, a download
 *     or a meta refresh driven from the top frame replaces the document and
 *     kills the driver. The hook sees a subframe navigation identically, and
 *     the page survives to finish the matrix.
 *
 * The scheme-file case targets file:///C:/Windows/win.ini on EVERY target,
 * this one included. That is deliberate and is not a copy-paste slip: the hook
 * decides before any load is attempted, so the path's existence is irrelevant,
 * and byte-identical drivers are worth more than a locally plausible path. */
constexpr char kCoverageJs[] =
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
       after it - in an earlier Windows run. The security question here is only
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
       gain; if it does not, the rule has to decide. Measured, not argued. */
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
 * navigationType belongs to that navigation and to nothing else. */

/* (a) plain script navigation from a timer: no gesture, no native call. */
constexpr char kActPlainJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'https://example.invalid/act-plain';\n"
    "}, 400);\n";

/* (b) script navigation in the continuation of a native binding promise -
 *     the shape every RPC-driven PWeb page actually has. On this backend the
 *     promise is resolved by upstream evaluating window.__webview__.onReply
 *     through -[WKWebView evaluateJavaScript:], so this phase measures whether
 *     WebKit treats host-injected script as a user gesture the way WebView2
 *     measurably does. */
constexpr char kActBindJs[] =
    "setTimeout(function () {\n"
    "  window.__cap8b_ping('ping.act-bind').then(function () {\n"
    "    location.href = 'https://example.invalid/act-after-bind';\n"
    "  }, function () {\n"
    "    location.href = 'https://example.invalid/act-after-bind';\n"
    "  });\n"
    "}, 400);\n";

/* (c) navigation performed by script the HOST injected (webview_eval, i.e.
 *     evaluateJavaScript:). The page itself does nothing. */
constexpr char kActEvalJs[] = "window.__cap8b_ready = true;\n";

/* The redirect controls, top-frame, one per phase because a redirect that IS
   followed replaces the document.
     - external: the 302 points out of pweb://, and the question is whether a
       navigation hook ever sees the target;
     - internal: the 302 points at another pweb:// authority, which stays
       inside this probe's own scheme handler, so the handler being ASKED for
       the target proves the redirect was FOLLOWED. Without that second probe,
       "no event for the target" and "the redirect was never followed" are
       indistinguishable - and they have opposite security meanings. */
constexpr char kRedirectExternalJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'pweb://app/redirect-external';\n"
    "}, 400);\n";

constexpr char kRedirectInternalJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'pweb://app/redirect-internal';\n"
    "}, 400);\n";

/* (d) a REAL user gesture: the page lays an anchor over a large fixed
 *     rectangle at the content origin and focuses it, and the native side
 *     posts a genuine mouse down/up pair into the window's event queue. The
 *     page is never asked where the anchor is - a page->native question would
 *     itself grant the activation being measured. */
constexpr char kActClickJs[] =
    "document.body.style.margin = '0';\n"
    "var a = document.createElement('a');\n"
    "a.href = 'https://example.invalid/act-real-click';\n"
    "a.id = 'realclick'; a.textContent = 'real click';\n"
    "a.style.cssText = 'position:fixed;left:0;top:0;width:400px;"
    "height:200px;background:#0a0;display:block';\n"
    "document.body.appendChild(a);\n"
    "a.focus();\n";

/* The CSP driver, VERBATIM. Each row is an INDEPENDENT observable: a directive
   that is silently not enforced must show up as a row that LOADED, never as an
   absence. The same-origin rows exist so that "everything blocked" - which
   would also satisfy a naive external-blocked assertion - is distinguishable
   from a policy that is actually usable. */
constexpr char kCspJs[] =
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

/* The candidate native policy under measurement, VERBATIM - a CSP that
   differed by one character across targets would make the per-directive rows
   incomparable. Deliberately the profile the intent proposes, with ONE stated
   difference: connect-src 'self' rather than 'none', because 'none' also
   blocks SAME-ORIGIN fetch and the repository's existing CAP-4 gates fetch
   their own assets. Whether that difference is required is one of the things
   this probe measures - the same-origin-fetch row is what decides it. */
constexpr char kCandidateCsp[] =
    "default-src 'self'; base-uri 'none'; object-src 'none'; "
    "frame-src 'none'; frame-ancestors 'none'; form-action 'none'; "
    "connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; font-src 'self' data:; media-src 'self'; "
    "worker-src 'none'; manifest-src 'self'";

/* ------------------------------------------------------------------ */
/* recorded measurements                                               */
/* ------------------------------------------------------------------ */

/* The two user_initiated_basis values this target can honestly emit.
 *
 * The first is for the three hooks that ARE handed a WKNavigationAction: the
 * only public signal on them is navigationType, so a gesture reading could at
 * best be DERIVED from it - and the word "derived" in the artifact is what
 * keeps a reader from mistaking it for something the engine reported.
 * The second is for every other hook, which is handed no navigation action at
 * all: there, nothing was derived either, because there was nothing to ask. */
constexpr char kBasisNavType[] =
    "derived:navigationType==WKNavigationTypeLinkActivated";
constexpr char kBasisNoAction[] =
    "unavailable:this hook is handed no WKNavigationAction";

/* Explicit case names for rows that are NOT a coverage case. They are
   parenthesised, exactly as CaseForUri's own fallback is, so no reader can
   confuse one with a driver case. */
constexpr char kCaseLifecycle[] = "(main-frame lifecycle observation)";
constexpr char kCaseNotNavigation[] = "(engine event, not a navigation)";
constexpr char kCaseNoFailingUrl[] = "(no failing URL in the error)";

/* One observed native hook arrival.
 *
 * The FIRST ELEVEN emitted fields are cap8b_audit_win.cpp's, in its order and
 * with its meanings, so the aggregator compares the four targets field by
 * field. The four after them are macOS-only and are ADDITIVE: WebView2's
 * IsUserInitiated has no public equivalent on WebKit, so navigationType and the
 * target frame's identity are the only way this target can report what it
 * actually saw. A reader that knows only the eleven shared fields sees exactly
 * the Windows shape. */
struct NavEvent {
  std::string phase;
  std::string caseName;
  /* When non-empty, THIS is the case name and CaseForUri is not consulted.
     Every hook that sets it does so for one reason: the URI it is handed is
     NOT the URI of the navigation the row is about - either because the hook
     is handed no URI at all, or because it is handed -[WKWebView URL], which
     is the main frame's current document rather than the navigation being
     reported. See the redirect observer and the lifecycle observers. */
  std::string caseOverride;
  std::string hook;
  std::string uri;
  /* userInitiated is meaningful ONLY when userInitiatedKnown is true, and on
     THIS target nothing ever sets it: WKNavigationAction exposes no public
     user-activation flag and -[WKNavigationAction _isUserInitiated] is
     forbidden SPI, so every row emits JSON null. The pair is kept in the
     Windows reference's shape rather than deleted so the emitter below is the
     same emitter, and so a future revision that DOES find a public signal has
     somewhere honest to put it. `basis` states which of the two a row is. */
  bool userInitiated = false;
  bool userInitiatedKnown = false;
  std::string basis{kBasisNoAction};
  bool redirected = false;
  bool cancelled = false;
  bool bootstrapAllowed = false;
  /* A POLICY hook can REFUSE the navigation; an OBSERVATION hook only says it
     happened. Counting them together would let this target - which emits ~8
     hook kinds where Windows emits 4, and where only 4 can refuse - look as if
     it cancelled more. The default is the CONSERVATIVE one, so a hook added
     later is never silently counted as a cancel site: the four that can refuse
     set it explicitly. */
  bool policy = false;
  /* free-form, per-hook: never parsed, only read by a human */
  std::string detail;
  /* macOS-only, additive */
  std::string navType = "n/a";     /* LinkActivated | FormSubmitted | ... */
  std::string targetFrame = "n/a"; /* main | sub | none-new-window | n/a */
  bool mainFrame = false;
  std::string source; /* sourceFrame.request.URL.absoluteString */
};

struct Measurements {
  std::string engineVersion;
  std::string initialSource;
  std::string exposureReport;
  std::string coverageReport;
  std::string cspReport;
  std::string cspMetaReport;
  std::vector<NavEvent> events;
  /* audit label seen by the native binding -> arrival count. This is the ONLY
     authority on which contexts reached native. */
  std::map<std::string, int> nativeArrivals;
  std::vector<std::string> notes;
  /* "enter/<case>" and "leave/<case>" marks the page emits through the scheme
     handler - the only progress channel that neither grants a user gesture nor
     dies with the document */
  std::vector<std::string> beacons;
  int cspHeadersEmitted = 0;
  bool downloadHookAvailable = false;
};

Measurements g_m;
std::mutex g_lock;
std::string g_phaseName = "none";
/* When a phase exists to measure ONE navigation, naming it here lets the phase
   end the moment that navigation is observed instead of burning its whole
   watchdog budget. Empty for the multi-case phases. */
std::string g_expectedCase;
std::atomic<int> g_phaseKind{static_cast<int>(PhaseKind::Exposure)};
std::atomic<bool> g_cancelUntrusted{false};
std::atomic<bool> g_cspOn{false};
std::atomic<bool> g_trustedCommitted{false};
/* the exposure phase is the only one that MATERIALISES a target=_blank child,
   because it is the only one asking "what can a new window reach"; every other
   phase records that createWebViewWithConfiguration: was reached and returns
   nil, which is itself the measurement */
std::atomic<bool> g_makeChildWindows{false};
/* The last URI decidePolicyForNavigationAction was handed, guarded by g_lock.
   The redirect observer is handed no request of its own - only
   -[WKWebView URL], which at redirect time still reads the FIRST LEG - so this
   is the other half of what that row has to report. Written and read on the
   GUI thread only; reset per phase. */
std::string g_lastPolicyUri;
webview_t g_webview = nullptr;
std::string *g_reportSlot = nullptr;

/* the phase is finished when the page reported, the expected case was
   observed, or the watchdog fired */
std::mutex g_wakeLock;
std::condition_variable g_wake;
bool g_phaseDone = false;

/* Exception-barrier bookkeeping. A non-zero count is a finding in its own
   right: it says an engine callback raised where this probe expected it could
   not, and every one is named on stdout as it happens. */
std::atomic<unsigned> g_caught{0};

void Note(const std::string &s) {
  std::lock_guard<std::mutex> guard(g_lock);
  g_m.notes.push_back(s);
  std::printf("[cap8b] %s\n", s.c_str());
  std::fflush(stdout);
}

void NoteCaught(const char *where, const std::string &what) {
  g_caught.fetch_add(1u);
  Note(std::string{"EXCEPTION BARRIER caught in "} + where + ": " + what);
}

/* defined with the corpus, below: case attribution is native and keyed by URI */
std::string CaseForUri(const std::string &uri);
void SignalPhaseDone();

void RecordEvent(NavEvent e) {
  bool satisfied = false;
  {
    std::lock_guard<std::mutex> guard(g_lock);
    e.phase = g_phaseName;
    /* An explicit override WINS. A hook whose URI is not the URI of the
       navigation it is reporting must not be filed by that URI - that is how
       the redirect landed under redirect-first-leg and how every lifecycle
       event after the fragment case landed under fragment-same-document. */
    e.caseName = e.caseOverride.empty() ? CaseForUri(e.uri) : e.caseOverride;
    /* user is printed as the three-valued thing it is. Printing 0 here would
       reintroduce, on stdout, exactly the false-for-unasked the artifact
       refuses to emit. */
    std::printf("[cap8b] event phase=%s case=%s hook=%s user=%s policy=%d "
                "redirect=%d cancelled=%d bootstrap=%d navtype=%s frame=%s "
                "uri=%s detail=%s\n",
                e.phase.c_str(), e.caseName.c_str(), e.hook.c_str(),
                e.userInitiatedKnown ? (e.userInitiated ? "true" : "false")
                                     : "null",
                e.policy ? 1 : 0, e.redirected ? 1 : 0, e.cancelled ? 1 : 0,
                e.bootstrapAllowed ? 1 : 0, e.navType.c_str(),
                e.targetFrame.c_str(), e.uri.c_str(), e.detail.c_str());
    std::fflush(stdout);
    /* A FIXTURE-DERIVED LABEL MAY NEVER END A PHASE. Only a case name the
       engine's own URI produced can satisfy the expectation: otherwise the
       redirect phases would report success on a row that proves no hook ever
       saw the target, which is precisely the distinction they exist to make.
       When no hook sees it, the phase burns its watchdog - and THAT is the
       finding. */
    satisfied = e.caseOverride.empty() && !g_expectedCase.empty() &&
                (e.caseName == g_expectedCase);
    g_m.events.push_back(std::move(e));
  }
  if (satisfied) {
    /* on the GUI thread already - this is an engine delegate callback */
    SignalPhaseDone();
    webview_terminate(g_webview);
  }
}

/* ------------------------------------------------------------------ */
/* the fixture corpus (memory only - nothing on disk)                  */
/* ------------------------------------------------------------------ */

struct Asset {
  std::string body;
  std::string contentType;
  int status = 200;
  /* name/value pairs rather than the Windows probe's CRLF blob: the Cocoa
     response takes an NSDictionary, and re-splitting a string we had just
     joined would be a parser nobody needs. */
  std::vector<std::pair<std::string, std::string>> extraHeaders;
};

std::string ChildDocument(const char *title) {
  return std::string{"<!doctype html><html><head><meta charset=\"utf-8\">"
                     "<title>"} +
         title +
         "</title></head><body><div id=\"c\">child</div>"
         "<script>window.__cap8b_ctx="
         "(new URLSearchParams(location.search)).get('ctx')||'child';"
         "</script><script>" +
         kChildJs + "</script></body></html>";
}

std::string OrchestratorJs() {
  switch (static_cast<PhaseKind>(g_phaseKind.load())) {
  case PhaseKind::Exposure: {
    std::string js(kExposureJs);
    const std::string marker = "__CHILDJS__";
    const size_t at = js.find(marker);
    if (at != std::string::npos) {
      js.replace(at, marker.size(), JStr(std::string(kChildJs)));
    }
    return js;
  }
  case PhaseKind::ActPlain:
    return std::string(kActPlainJs);
  case PhaseKind::ActBind:
    return std::string(kActBindJs);
  case PhaseKind::ActEval:
    return std::string(kActEvalJs);
  case PhaseKind::ActClick:
    return std::string(kActClickJs);
  case PhaseKind::RedirectExternal:
    return std::string(kRedirectExternalJs);
  case PhaseKind::RedirectInternal:
    return std::string(kRedirectInternalJs);
  case PhaseKind::Coverage:
  case PhaseKind::Csp:
  case PhaseKind::CspMeta:
  default:
    return std::string(kCoverageJs);
  }
}

/* Case attribution is NATIVE and keyed by the URI, because the alternative -
   the page announcing each case through a binding - is exactly what
   contaminated the user-activation reading in the Windows probe's first run.
   Every coverage and activation case therefore navigates to a URI that appears
   nowhere else. Kept identical to cap8b_audit_win.cpp's table, row for row. */
std::string CaseForUri(const std::string &uri) {
  struct Row {
    const char *uri;
    const char *name;
  };
  static const Row kRows[] = {
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
  for (const Row &row : kRows) {
    if (uri == row.uri) {
      return std::string{row.name};
    }
  }
  if (uri.rfind("pweb://evil/", 0) == 0) {
    return std::string{"subframe-wrong-authority"};
  }
  if (uri.rfind("data:", 0) == 0) {
    return std::string{"scheme-data"};
  }
  if (uri.rfind("blob:", 0) == 0) {
    return std::string{"scheme-blob"};
  }
  if (uri.rfind("javascript:", 0) == 0) {
    return std::string{"scheme-javascript"};
  }
  if (uri.find("/redirect-external") != std::string::npos) {
    return std::string{"redirect-first-leg"};
  }
  if (uri.find("/download.bin") != std::string::npos) {
    return std::string{"download"};
  }
  if (uri.find("ctx=cov-frame-trusted") != std::string::npos) {
    return std::string{"subframe-trusted"};
  }
  if (uri.find("ctx=cov-reload") != std::string::npos) {
    return std::string{"reload-trusted-subframe"};
  }
  if (uri.find("ctx=cov-auth-upper") != std::string::npos) {
    return std::string{"authority-uppercase"};
  }
  if (uri.find("ctx=cov-auth-suffix") != std::string::npos) {
    return std::string{"authority-suffix"};
  }
  if (uri.find("ctx=cov-auth-userinfo") != std::string::npos) {
    return std::string{"authority-userinfo"};
  }
  if (uri.find("ctx=cov-auth-port") != std::string::npos) {
    return std::string{"authority-port"};
  }
  if (uri.find("ctx=cov-auth-empty") != std::string::npos) {
    return std::string{"authority-empty"};
  }
  if (uri.find("pushed=1") != std::string::npos) {
    return std::string{"history-pushstate-back"};
  }
  if (uri.find('#') != std::string::npos) {
    return std::string{"fragment-same-document"};
  }
  return std::string{"(host or startup navigation)"};
}

/* The AUDIT's coarse notion of "trusted", used only to decide what the
   cancelling phases let through. It is deliberately a prefix test, which is
   exactly what the PRODUCTION classifier is forbidden to do - the product's
   verdict comes from PWebParseAppUri over parsed components. Nothing here is a
   candidate for production. */
bool IsAuditTrusted(const std::string &uri) {
  const std::string p = "pweb://app/";
  return uri.compare(0, p.size(), p) == 0 || uri == "pweb://app";
}

bool CorpusFor(const std::string &uri, Asset &out) {
  const std::string prefix = "pweb://";
  if (uri.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  const size_t slash = uri.find('/', prefix.size());
  const std::string authority =
      uri.substr(prefix.size(), slash == std::string::npos
                                    ? std::string::npos
                                    : slash - prefix.size());
  std::string path = (slash == std::string::npos) ? "/" : uri.substr(slash);
  const size_t cut = path.find_first_of("?#");
  if (cut != std::string::npos) {
    path = path.substr(0, cut);
  }

  if (authority == "evil") {
    /* The untrusted document, served ON PURPOSE: the whole exposure question
       is what such a document can reach if it ever executes. */
    if (uri.find("ctx=redirect-target") != std::string::npos) {
      /* Being ASKED for this is the proof that the 302 was FOLLOWED - the one
         observation that separates "the engine never followed the redirect"
         from "it followed it without telling the navigation hook". */
      std::lock_guard<std::mutex> guard(g_lock);
      g_m.beacons.push_back("redirect-target-requested");
    }
    if (path == "/child.html" || path == "/") {
      out.body = ChildDocument("cap8b evil");
      out.contentType = "text/html; charset=utf-8";
      return true;
    }
    return false;
  }
  if (authority != "app") {
    return false;
  }

  /* progress beacons: recorded natively, answered with an empty 404 so the
     page never waits on them */
  if (path.rfind("/beacon/", 0) == 0) {
    std::lock_guard<std::mutex> guard(g_lock);
    g_m.beacons.push_back(path.substr(std::strlen("/beacon/")));
    return false;
  }

  if (path == "/" || path == "/index.html") {
    out.body = "<!doctype html><html><head><meta charset=\"utf-8\">"
               "<title>cap8b</title></head><body><div id=\"v\">cap8b</div>"
               "<script src=\"/orchestrate.js\"></script></body></html>";
    out.contentType = "text/html; charset=utf-8";
    return true;
  }
  if (path == "/orchestrate.js") {
    out.body = OrchestratorJs();
    out.contentType = "text/javascript; charset=utf-8";
    return true;
  }
  if (path == "/child.html") {
    out.body = ChildDocument("cap8b child");
    out.contentType = "text/html; charset=utf-8";
    return true;
  }
  if (path == "/redirect-external") {
    out.status = 302;
    out.body = "";
    out.contentType = "text/plain; charset=utf-8";
    out.extraHeaders.push_back(
        {std::string{"Location"},
         std::string{"https://example.invalid/redirected"}});
    return true;
  }
  if (path == "/redirect-internal") {
    out.status = 302;
    out.body = "";
    out.contentType = "text/plain; charset=utf-8";
    out.extraHeaders.push_back(
        {std::string{"Location"},
         std::string{"pweb://evil/child.html?ctx=redirect-target"}});
    return true;
  }
  if (path == "/download.bin") {
    out.body = "cap8b-download-payload";
    out.contentType = "application/octet-stream";
    out.extraHeaders.push_back(
        {std::string{"Content-Disposition"},
         std::string{"attachment; filename=\"c.bin\""}});
    return true;
  }
  if (path == "/metarefresh.html") {
    /* The redirect mechanism that is actually REACHABLE in this architecture.
       A 302 handed back from a custom scheme handler may well not be followed
       at all - the public WKURLSchemeTask protocol has no redirect callback
       and the private _didPerformRedirection: SPI is forbidden here - so it can
       never be the redirect a threat model worries about; a meta refresh inside
       trusted content can, and it is a plain navigation the hook must see. */
    out.body = "<!doctype html><html><head><meta charset=\"utf-8\">"
               "<meta http-equiv=\"refresh\" "
               "content=\"0;url=https://example.invalid/metarefresh\">"
               "</head><body>refresh</body></html>";
    out.contentType = "text/html; charset=utf-8";
    return true;
  }
  if (path == "/worker.js") {
    out.body = "self.onmessage=function(){};";
    out.contentType = "text/javascript; charset=utf-8";
    return true;
  }
  if (path == "/same-origin.js") {
    out.body = "window.__cap8b_same_origin = true;";
    out.contentType = "text/javascript; charset=utf-8";
    return true;
  }
  if (path == "/csp.js") {
    out.body = kCspJs;
    out.contentType = "text/javascript; charset=utf-8";
    return true;
  }
  if (path == "/csp.html" || path == "/csp-meta.html") {
    /* The inline script is the DELIBERATE canary for script-src 'self': if the
       header is enforced it must not run. csp-meta.html additionally carries a
       far WEAKER <meta> policy, which must not be able to rescue it - that is
       the "a tampered bundle cannot weaken the native policy" claim, measured
       rather than asserted. */
    const bool meta = (path == "/csp-meta.html");
    out.body =
        std::string{"<!doctype html><html><head><meta charset=\"utf-8\">"} +
        (meta ? "<meta http-equiv=\"Content-Security-Policy\" "
                "content=\"default-src * 'unsafe-inline' 'unsafe-eval'; "
                "script-src * 'unsafe-inline' 'unsafe-eval'; "
                "connect-src *; frame-src *; object-src *; base-uri *\">"
              : "") +
        "<title>cap8b csp</title></head><body><div id=\"v\">csp</div>"
        "<script src=\"/same-origin.js\"></script>"
        "<script>window.__cap8b_inline = true;</script>"
        "<script src=\"/csp.js\"></script></body></html>";
    out.contentType = "text/html; charset=utf-8";
    return true;
  }
  return false;
}

} // namespace

/* ------------------------------------------------------------------ */
/* the scheme handler                                                  */
/* ------------------------------------------------------------------ */

/*
 * The terminal-state guard CAP-7M0 measured into existence. Every task is
 * tracked from startURLSchemeTask: until it reaches a terminal callback OR is
 * stopped, and NOTHING is sent to a task that is not in that set. Apple raises
 * an NSException for each of those mistakes, and an NSException crossing into a
 * C++ frame is undefined behaviour, not an error path.
 *
 * Unlike the production handler this one answers a MISS with a real HTTP 404
 * rather than didFailWithError:, and that difference is deliberate: the Windows
 * reference serves a constant 404, several CSP rows are decided by a fetch()
 * STATUS, and a task failed at the transport level reports no status at all.
 * Production's single reasonless refusal is the right product behaviour and the
 * wrong instrument.
 */
@interface PWebCap8bSchemeHandler : NSObject <WKURLSchemeHandler>
- (void)resetTasks;
@end

@implementation PWebCap8bSchemeHandler {
  NSMutableSet *_live; /* NSValue of the task pointer */
  NSLock *_guard;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _live = [[NSMutableSet alloc] init];
    _guard = [[NSLock alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_live release];
  [_guard release];
  [super dealloc];
}

- (void)trackTask:(id<WKURLSchemeTask>)task {
  [_guard lock];
  [_live addObject:[NSValue valueWithPointer:(const void *)task]];
  [_guard unlock];
}

/* Returns YES exactly once per task: the caller that takes the task out of the
   live set owns the right to send it a terminal callback. */
- (BOOL)claimTask:(id<WKURLSchemeTask>)task {
  BOOL claimed = NO;
  NSValue *key = [NSValue valueWithPointer:(const void *)task];
  [_guard lock];
  if ([_live containsObject:key]) {
    [_live removeObject:key];
    claimed = YES;
  }
  [_guard unlock];
  return claimed;
}

/* Called between phases. The set is keyed by task ADDRESS and the allocator
   reuses addresses freely, so a task abandoned when phase N's run loop stopped
   can alias a brand-new task in phase N+1 - at which point claimTask: would
   hand out a terminal callback that was already spent. Phases never share
   tasks, so the honest reset is to empty the set between them. */
- (void)resetTasks {
  [_guard lock];
  [_live removeAllObjects];
  [_guard unlock];
}

- (void)deliver:(id<WKURLSchemeTask>)task
         status:(int)status
           body:(NSData *)body
        headers:(NSDictionary *)headers {
  if (![self claimTask:task]) {
    return;
  }
  @try {
    NSURL *url = [[task request] URL];
    if (url == nil) {
      /* No URL means no NSHTTPURLResponse can be constructed. Fail closed and
         terminate the task anyway: a task nobody completes is a request WebKit
         waits on forever. */
      [task didFailWithError:[NSError errorWithDomain:@"CAP8B"
                                                 code:2
                                             userInfo:nil]];
      return;
    }
    NSHTTPURLResponse *response =
        [[[NSHTTPURLResponse alloc] initWithURL:url
                                     statusCode:status
                                    HTTPVersion:@"HTTP/1.1"
                                   headerFields:headers] autorelease];
    [task didReceiveResponse:response];
    [task didReceiveData:body];
    [task didFinish];
  } @catch (NSException *e) {
    NoteCaught("schemeHandler.deliver", Narrow([e name]));
    @try {
      /* didFailWithError: is legal after a response and after data - only
         after a TERMINAL is it not - so this is the correct recovery for the
         common case, and is itself guarded for the case where it is not. */
      [task didFailWithError:[NSError errorWithDomain:@"CAP8B"
                                                 code:3
                                             userInfo:nil]];
    } @catch (id inner) {
      (void)inner;
      NoteCaught("schemeHandler.deliver.recover", "exception");
    }
  } @catch (id e) {
    (void)e;
    NoteCaught("schemeHandler.deliver", "non-NSException object");
  }
}

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  try {
    @autoreleasepool {
      @try {
        /* Tracked FIRST, unconditionally. Every path below completes the task
           exactly once through claimTask:. */
        [self trackTask:task];

        const std::string uri = Narrow([[[task request] URL] absoluteString]);

        Asset asset;
        const bool found = CorpusFor(uri, asset);

        const std::string body = found ? asset.body : std::string{};
        const std::string type =
            found ? asset.contentType : std::string{"text/plain; charset=utf-8"};

        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        [headers setObject:Widen(type) forKey:@"Content-Type"];
        [headers setObject:@"no-store" forKey:@"Cache-Control"];
        [headers setObject:[NSString stringWithFormat:@"%lld",
                                                      (long long)body.size()]
                    forKey:@"Content-Length"];
        if (found) {
          for (const auto &header : asset.extraHeaders) {
            [headers setObject:Widen(header.second) forKey:Widen(header.first)];
          }
        }
        /* The native policy under test rides on TRUSTED HTML only - the same
           rule production would use - so the hostile authority never receives
           it and can never be mistaken for a protected one. */
        const bool trustedHtml = found && g_cspOn.load() &&
                                 asset.contentType.rfind("text/html", 0) == 0 &&
                                 IsAuditTrusted(uri);
        if (trustedHtml) {
          [headers setObject:Widen(std::string{kCandidateCsp})
                      forKey:@"Content-Security-Policy"];
          [headers setObject:@"nosniff" forKey:@"X-Content-Type-Options"];
          [headers setObject:@"no-referrer" forKey:@"Referrer-Policy"];
          std::lock_guard<std::mutex> guard(g_lock);
          g_m.cspHeadersEmitted += 1;
        }

        NSData *data = [NSData dataWithBytes:body.data()
                                      length:(NSUInteger)body.size()];
        [self deliver:task
               status:(found ? asset.status : 404)
                 body:data
              headers:headers];
      } @catch (NSException *e) {
        NoteCaught("startURLSchemeTask", Narrow([e name]));
        @try {
          if ([self claimTask:task]) {
            [task didFailWithError:[NSError errorWithDomain:@"CAP8B"
                                                       code:1
                                                   userInfo:nil]];
          }
        } @catch (id inner) {
          (void)inner;
        }
      } @catch (id e) {
        (void)e;
        NoteCaught("startURLSchemeTask", "non-NSException object");
      }
    }
  } catch (const std::exception &e) {
    NoteCaught("startURLSchemeTask", e.what());
  } catch (...) {
    NoteCaught("startURLSchemeTask", "unknown C++ exception");
  }
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  try {
    @try {
      /* After this the task must never be messaged again. Taking it out of the
         live set IS the guard - every later callback is claim-gated. CAP-7M0
         measured that a post-stop delivery really does raise, so this is
         load-bearing rather than cargo-culted; that measurement is not repeated
         here because this file audits navigation, not the task lifecycle. */
      [self claimTask:task];
    } @catch (id e) {
      (void)e;
      NoteCaught("stopURLSchemeTask", "exception");
    }
  } catch (const std::exception &e) {
    NoteCaught("stopURLSchemeTask", e.what());
  } catch (...) {
    NoteCaught("stopURLSchemeTask", "unknown C++ exception");
  }
}

@end

/* ------------------------------------------------------------------ */
/* SEAM B: the pre-create override                                     */
/* ------------------------------------------------------------------ */

/*
 * Upstream creates the configuration AND the web view inside webview_create,
 * so there is no moment between them that a caller can reach - unless the
 * caller owns the constructor. +[WKWebViewConfiguration new] is that
 * constructor (cocoa_webkit.hh:450 calls exactly this selector).
 *
 * The override is added to WKWebViewConfiguration's OWN metaclass with
 * class_addMethod. Note what is deliberately NOT done: class_getClassMethod
 * would return NSObject's inherited +new, and setting ITS implementation would
 * swizzle +new for every class in the process. Adding to this metaclass affects
 * this class alone, and SeamIsConfined() below proves it - including the
 * behavioural half, that constructing unrelated objects with +new does not
 * reach the seam.
 *
 * Installed once and never removed; teardown DISARMS it. With the seam
 * disarmed it does nothing at all but forward.
 */
static PWebCap8bSchemeHandler *g_seamHandler = nil;
static volatile int g_seamArmed = 0;
static int g_seamInstalled = 0;
static unsigned g_seamInvocations = 0;

/* Reached through objc_msgSend as a plain C function pointer, so NOTHING may
   leave it: an exception unwinding out of an IMP is undefined behaviour. The
   [[cls alloc] init] is INSIDE the barrier too - it is a message send into
   WebKit like any other, and it used to sit outside every guard this function
   had. */
static id Cap8bConfigurationNew(Class cls, SEL cmd) {
  (void)cmd;
  id config = nil;
  try {
    @try {
      config = [[cls alloc] init]; /* exactly what +new does, in public API */
    } @catch (id e) {
      (void)e;
      NoteCaught("seam +new alloc/init", "exception");
      config = nil;
    }
    if ((config != nil) &&
        __atomic_load_n(&g_seamArmed, __ATOMIC_SEQ_CST) &&
        (g_seamHandler != nil)) {
      @try {
        [(WKWebViewConfiguration *)config setURLSchemeHandler:g_seamHandler
                                                forURLScheme:CAP8B_SCHEME];
        g_seamInvocations++;
      } @catch (id e) {
        (void)e;
        NoteCaught("seam install", "exception");
      }
    }
  } catch (const std::exception &e) {
    /* NoteCaught builds a std::string, so bad_alloc is a live path out of the
       @catch blocks above as well as out of the sends themselves. */
    NoteCaught("seam +new", e.what());
  } catch (...) {
    NoteCaught("seam +new", "unknown C++ exception");
  }
  return config; /* +1 when non-nil, as +new must return */
}

static int InstallPrecreateSeam(void) {
  if (g_seamInstalled) {
    return 1;
  }
  Class configClass = objc_getClass("WKWebViewConfiguration");
  if (configClass == Nil) {
    return 0;
  }
  Class meta = object_getClass((id)configClass);
  if (meta == Nil) {
    return 0;
  }
  if (!class_addMethod(meta, @selector(new), (IMP)Cap8bConfigurationNew,
                       "@@:")) {
    /* The class already declares its OWN +new: replace that implementation,
       which is still confined to this class.
       The check below is the whole safety of this branch.
       class_getInstanceMethod walks the superclass chain, so on a class that
       merely INHERITS +new from NSObject it returns NSObject's Method - and
       setting that implementation would swizzle +new for EVERY class in the
       process. Identical Method pointers mean inherited; refuse rather than
       guess. */
    Method own = class_getInstanceMethod(meta, @selector(new));
    Class superMeta = class_getSuperclass(meta);
    Method inherited = (superMeta != Nil)
                           ? class_getInstanceMethod(superMeta, @selector(new))
                           : NULL;
    if ((own == NULL) || (own == inherited)) {
      return 0;
    }
    method_setImplementation(own, (IMP)Cap8bConfigurationNew);
  }
  g_seamInstalled = 1;
  return 1;
}

/* Is the +new override CONFINED to WKWebViewConfiguration's own metaclass? The
   same three-part check the production bridge makes, reproduced rather than
   shared: WKWebViewConfiguration's metaclass +new IS ours, NSObject's metaclass
   +new is NOT, and constructing unrelated objects with +new does not move the
   seam counter. The third is the behavioural half and is the one that would
   actually catch a process-wide swizzle. */
static int SeamIsConfined(void) {
  int ok = 0;
  if (!g_seamInstalled) {
    return 0;
  }
  @autoreleasepool {
    @try {
      Class configClass = objc_getClass("WKWebViewConfiguration");
      if (configClass == Nil) {
        return 0;
      }
      Class configMeta = object_getClass((id)configClass);
      Class objectMeta = object_getClass((id)[NSObject class]);
      if ((configMeta == Nil) || (objectMeta == Nil)) {
        return 0;
      }
      const IMP ours = (IMP)Cap8bConfigurationNew;
      const int owns =
          (class_getMethodImplementation(configMeta, @selector(new)) == ours);
      const int leaked =
          (class_getMethodImplementation(objectMeta, @selector(new)) == ours);

      const unsigned before = g_seamInvocations;
      id plain = [NSObject new];
      id array = [NSMutableArray new];
      const unsigned after = g_seamInvocations;
      const int quiet = (plain != nil) && (array != nil) && (after == before);
      [plain release];
      [array release];

      ok = (owns && !leaked && quiet) ? 1 : 0;
    } @catch (id e) {
      (void)e;
      NoteCaught("SeamIsConfined", "exception");
      ok = 0;
    }
  }
  return ok;
}

/* ------------------------------------------------------------------ */
/* the navigation / UI / download delegate                             */
/* ------------------------------------------------------------------ */

namespace {

std::string NavTypeName(WKNavigationType type) {
  switch (type) {
  case WKNavigationTypeLinkActivated:
    return "LinkActivated";
  case WKNavigationTypeFormSubmitted:
    return "FormSubmitted";
  case WKNavigationTypeBackForward:
    return "BackForward";
  case WKNavigationTypeReload:
    return "Reload";
  case WKNavigationTypeFormResubmitted:
    return "FormResubmitted";
  case WKNavigationTypeOther:
    return "Other";
  default:
    break;
  }
  char buf[48];
  std::snprintf(buf, sizeof(buf), "unknown(%ld)", (long)type);
  return std::string{buf};
}

std::string LastPolicyUri() {
  std::lock_guard<std::mutex> guard(g_lock);
  return g_lastPolicyUri;
}

/* The case a SERVER REDIRECT belongs to.
 *
 * didReceiveServerRedirectForProvisionalNavigation is handed no request at
 * all: the only URI reachable from it is -[WKWebView URL], which at redirect
 * time still reads the FIRST LEG. Running that through CaseForUri filed the
 * row under redirect-first-leg, so the redirect-external phase's expectedCase
 * ("redirect-out-of-pweb") never matched, the phase burned its whole watchdog,
 * and the one row that carries redirected=true was attributed to the leg that
 * was NOT redirected.
 *
 * The second leg is not observable from this hook - but it is not unknown
 * either: this probe's own corpus wrote the Location header, so the mapping
 * below is read off the FIXTURE, not guessed from the engine. That makes the
 * case name a LABEL derived from the probe's own input, which is legitimate;
 * what is not legitimate is letting it look measured, so the row's detail
 * carries both URIs that WERE observed and the emitted uri stays the one the
 * hook actually handed us. An unrecognised first leg returns "" and the row
 * falls back to CaseForUri, which is the honest answer for a redirect this
 * probe did not author. */
std::string RedirectCaseForFirstLeg(const std::string &firstLeg) {
  if (firstLeg.find("/redirect-external") != std::string::npos) {
    /* DELIBERATELY NOT CaseForUri("https://example.invalid/redirected").
       That would return `redirect-out-of-pweb`, which on every other target
       means "a navigation hook was handed the redirect target" - a much
       stronger claim than this row can make. This label is derived from the
       Location header THIS FILE wrote, not from anything the engine did, so
       it gets a name that cannot be mistaken for the measurement. */
    return std::string{"redirect-external-target(label-from-fixture)"};
  }
  if (firstLeg.find("/redirect-internal") != std::string::npos) {
    /* Location: pweb://evil/child.html?ctx=redirect-target. CaseForUri would
       call that subframe-wrong-authority, which is true of the URI and false
       of the event, so this row gets its own name. It can only ever appear if
       the engine FOLLOWED an internal 302 - the beacon
       'redirect-target-requested' is the corroborating observation. */
    return std::string{"redirect-internal-target"};
  }
  return std::string{};
}

/* The windows this probe opened itself, kept so teardown can close them
   deterministically. NSWindow's isReleasedWhenClosed defaults to YES for a
   programmatically created window, which would make -close a release and
   -release a double free; every window below is created with it set to NO, so
   ownership is explicit exactly as it is everywhere else in this file. */
NSMutableArray *g_childWindows = nil;
unsigned g_createWebViewCalls = 0;
unsigned g_childWindowsMade = 0;

} // namespace

/* One child window is enough to answer "what can a new window reach". More
   would only multiply the teardown surface. */
#define CAP8B_MAX_CHILD_WINDOWS 1u

@interface PWebCap8bDelegate
    : NSObject <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@end

@implementation PWebCap8bDelegate

/* ---------------- WKNavigationDelegate: the policy hooks ---------------- */

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:
                        (void (^)(WKNavigationActionPolicy))decisionHandler {
  (void)webView;
  /* FAIL CLOSED. The initial value is the answer this hook gives if anything
     below goes wrong, and the handler is invoked OUTSIDE every barrier so it is
     called exactly once on every path. */
  WKNavigationActionPolicy policy = WKNavigationActionPolicyCancel;
  try {
    @try {
      NavEvent e;
      e.hook = "decidePolicyForNavigationAction";
      /* THE hook that can refuse: this one row type is what "cancellable"
         means on this target. */
      e.policy = true;
      e.uri = Narrow([[[action request] URL] absoluteString]);
      {
        /* the redirect observer's other half - see g_lastPolicyUri */
        std::lock_guard<std::mutex> guard(g_lock);
        g_lastPolicyUri = e.uri;
      }

      const WKNavigationType type = [action navigationType];
      e.navType = NavTypeName(type);
      /* THE ONLY PUBLIC SIGNAL ON THIS ENGINE, and it is NOT a gesture flag.
         -[WKNavigationAction _isUserInitiated] is private SPI and is forbidden
         here, so user_initiated stays UNKNOWN (null) and the raw navigationType
         travels in nav_type, with basis saying what a reader could derive from
         it. Assigning (type == LinkActivated) to user_initiated - which this
         probe used to do - would have published a DEFINITION in the column a
         reader compares against WebView2's MEASUREMENT. */
      e.basis = kBasisNavType;

      WKFrameInfo *target = [action targetFrame];
      /* nil targetFrame is WebKit's statement that this action would open a
         NEW WINDOW: it is this backend's NewWindowRequested, and it is the only
         place a target=_blank / window.open can be denied BEFORE the UI
         delegate is consulted. */
      const bool newWindow = (target == nil);
      const bool subframe = !newWindow && ([target isMainFrame] == NO);
      if (newWindow) {
        e.targetFrame = "none-new-window";
        e.mainFrame = false;
      } else {
        e.mainFrame = !subframe;
        e.targetFrame = subframe ? "sub" : "main";
      }
      WKFrameInfo *sourceFrame = [action sourceFrame];
      if (sourceFrame != nil) {
        e.source = Narrow([[[sourceFrame request] URL] absoluteString]);
      }
      e.detail = std::string{"should_download="} +
                 ([action shouldPerformDownload] ? "yes" : "no");

      bool cancel = false;
      if (g_cancelUntrusted.load()) {
        if (newWindow) {
          /* the deny WebView2 spells put_Handled(TRUE) with no NewWindow: the
             engine must not create a window of its own */
          cancel = true;
        } else if (subframe) {
          /* MEASUREMENT policy, deliberately WEAKER than the production rule
             and identical to the Windows probe's: untrusted subframes are
             cancelled, trusted ones are allowed. The production rule denies
             every subframe, but enforcing that here would cancel the trusted
             FIRST LEG of the redirect, meta-refresh and download probes and
             those cases would silently never run. */
          cancel = !IsAuditTrusted(e.uri);
        } else if (IsAuditTrusted(e.uri)) {
          g_trustedCommitted.store(true);
        } else if (e.uri == "about:blank" && !g_trustedCommitted.load()) {
          /* the single-use engine bootstrap exception, measured rather than
             assumed: if the engine never needs it, no event will carry it */
          e.bootstrapAllowed = true;
        } else {
          cancel = true;
        }
      } else if (IsAuditTrusted(e.uri)) {
        g_trustedCommitted.store(true);
      }
      e.cancelled = cancel;
      policy = cancel ? WKNavigationActionPolicyCancel
                      : WKNavigationActionPolicyAllow;
      RecordEvent(std::move(e));
    } @catch (NSException *ex) {
      NoteCaught("decidePolicyForNavigationAction", Narrow([ex name]));
      policy = WKNavigationActionPolicyCancel;
    } @catch (id ex) {
      (void)ex;
      NoteCaught("decidePolicyForNavigationAction", "non-NSException object");
      policy = WKNavigationActionPolicyCancel;
    }
  } catch (const std::exception &ex) {
    NoteCaught("decidePolicyForNavigationAction", ex.what());
    policy = WKNavigationActionPolicyCancel;
  } catch (...) {
    NoteCaught("decidePolicyForNavigationAction", "unknown C++ exception");
    policy = WKNavigationActionPolicyCancel;
  }
  /* EXACTLY ONCE, on EVERY path. A missed completion hangs WebKit; a second
     call raises. */
  @try {
    decisionHandler(policy);
  } @catch (id ex) {
    (void)ex;
    NoteCaught("decidePolicyForNavigationAction.handler", "exception");
  }
}

/* WebView2 has no counterpart: it decides once, at NavigationStarting. This
   hook is therefore recorded rather than used as policy, with ONE exception
   that is not policy either - a response WebKit cannot DISPLAY is converted
   into a download, because that is the only way to reach
   webView:navigationResponse:didBecomeDownload: and therefore the only way to
   measure whether a native hook can stop a download before anything is
   written. The download is then cancelled at its destination decision, so
   nothing ever touches the disk. */
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:
                          (void (^)(WKNavigationResponsePolicy))decisionHandler {
  (void)webView;
  WKNavigationResponsePolicy policy = WKNavigationResponsePolicyCancel;
  try {
    @try {
      NavEvent e;
      e.hook = "decidePolicyForNavigationResponse";
      /* This hook CAN refuse (WKNavigationResponsePolicyCancel), so it counts
         as a policy hook even though this probe deliberately never refuses
         here - `cancelled` is what says what the probe did, `policy` is what
         says what the hook could have done. */
      e.policy = true;
      NSURLResponse *response = [navigationResponse response];
      e.uri = Narrow([[response URL] absoluteString]);
      e.mainFrame = ([navigationResponse isForMainFrame] != NO);
      e.targetFrame = e.mainFrame ? "main" : "sub";

      const BOOL canShow = [navigationResponse canShowMIMEType];
      long status = -1;
      if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        status = (long)[(NSHTTPURLResponse *)response statusCode];
      }
      const bool toDownload = (canShow == NO);
      policy = toDownload ? WKNavigationResponsePolicyDownload
                          : WKNavigationResponsePolicyAllow;

      /* status is the fact that separates "WebKit followed our 302 itself"
         from "WebKit handed the 302 straight to the frame": a redirect the
         engine followed would arrive here as the FINAL response, never as a
         302 for pweb://app/redirect-external. */
      char buf[160];
      std::snprintf(buf, sizeof(buf), "status=%ld can_show=%s policy=%s",
                    status, (canShow != NO) ? "yes" : "no",
                    toDownload ? "download" : "allow");
      e.detail = std::string{buf} + " mime=" + Narrow([response MIMEType]);
      RecordEvent(std::move(e));
    } @catch (NSException *ex) {
      NoteCaught("decidePolicyForNavigationResponse", Narrow([ex name]));
      policy = WKNavigationResponsePolicyCancel;
    } @catch (id ex) {
      (void)ex;
      NoteCaught("decidePolicyForNavigationResponse", "non-NSException object");
      policy = WKNavigationResponsePolicyCancel;
    }
  } catch (const std::exception &ex) {
    NoteCaught("decidePolicyForNavigationResponse", ex.what());
    policy = WKNavigationResponsePolicyCancel;
  } catch (...) {
    NoteCaught("decidePolicyForNavigationResponse", "unknown C++ exception");
    policy = WKNavigationResponsePolicyCancel;
  }
  @try {
    decisionHandler(policy);
  } @catch (id ex) {
    (void)ex;
    NoteCaught("decidePolicyForNavigationResponse.handler", "exception");
  }
}

/* -------------- WKNavigationDelegate: the observation hooks --------------
 *
 * EVERY hook below is policy=false: it can say a navigation happened, it
 * cannot refuse one. That flag is not decoration. This target emits about
 * eight hook kinds where the Windows reference emits four, and all four of
 * those can refuse; without the flag, a per-case event count here would read
 * as "macOS saw more" when what it saw more of is narration.
 *
 * They also share a defect the flag exposed: each reads -[WKWebView URL],
 * which is the MAIN FRAME'S CURRENT DOCUMENT and not the navigation the row is
 * about. After the coverage driver's fragment-same-document case that URL is
 * permanently pweb://app/index.html#frag, and CaseForUri's '#' rule then filed
 * every later observation - the five authority-* cases and
 * reload-trusted-subframe among them - under fragment-same-document. So they
 * carry an explicit case name instead of being attributed by URI, and the URI
 * they were actually handed still travels in `uri`. */

/* The PUBLIC redirect observation point. WKNavigationAction carries no
   "is redirect" flag of its own - WebView2's IsRedirected has no equivalent -
   so `redirected` can only ever be true on an event recorded from here. */
- (void)webView:(WKWebView *)webView
    didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
  (void)navigation;
  try {
    @try {
      NavEvent e;
      e.hook = "didReceiveServerRedirectForProvisionalNavigation";
      const std::string current = Narrow([[webView URL] absoluteString]);
      const std::string firstLeg = LastPolicyUri();
      e.uri = current;
      e.redirected = true;
      e.caseOverride = RedirectCaseForFirstLeg(firstLeg);
      /* BOTH observations, named, so the row can be re-derived by a reader who
         disagrees with the case name above. */
      const char *const how =
          e.caseOverride.empty() ? "by-uri" : "from-fixture-Location";
      e.detail = std::string{"webView.URL="} +
                 (current.empty() ? std::string{"<nil>"} : current) +
                 " last_decidePolicy_uri=" +
                 (firstLeg.empty() ? std::string{"<none>"} : firstLeg) +
                 " case=" + how;
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("didReceiveServerRedirect", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("didReceiveServerRedirect", ex.what());
  } catch (...) {
    NoteCaught("didReceiveServerRedirect", "unknown C++ exception");
  }
}

- (void)webView:(WKWebView *)webView
    didStartProvisionalNavigation:(WKNavigation *)navigation {
  (void)navigation;
  try {
    @try {
      NavEvent e;
      e.hook = "didStartProvisionalNavigation";
      e.uri = Narrow([[webView URL] absoluteString]);
      e.caseOverride = kCaseLifecycle;
      e.detail = "uri is -[WKWebView URL] (the main frame's current document)";
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("didStartProvisionalNavigation", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("didStartProvisionalNavigation", ex.what());
  } catch (...) {
    NoteCaught("didStartProvisionalNavigation", "unknown C++ exception");
  }
}

/* THE "BEFORE CONTENT EXECUTES" BOUNDARY. A cancel that lands after this hook
   has fired for a given document is a cancel that arrived too late, so the
   commit events are what make "cancelled before execution" checkable rather
   than asserted. It is checked by ORDER within a phase - this row against the
   cancelled decidePolicyForNavigationAction row before it - and not by the
   case column, which is why filing the row by its own URI bought nothing and
   cost the five authority-* cases their attribution. */
- (void)webView:(WKWebView *)webView
    didCommitNavigation:(WKNavigation *)navigation {
  (void)navigation;
  try {
    @try {
      NavEvent e;
      e.hook = "didCommitNavigation";
      e.uri = Narrow([[webView URL] absoluteString]);
      e.caseOverride = kCaseLifecycle;
      e.detail = "uri is -[WKWebView URL] (the main frame's current document)";
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("didCommitNavigation", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("didCommitNavigation", ex.what());
  } catch (...) {
    NoteCaught("didCommitNavigation", "unknown C++ exception");
  }
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
  (void)navigation;
  try {
    @try {
      NavEvent e;
      e.hook = "didFinishNavigation";
      e.uri = Narrow([[webView URL] absoluteString]);
      e.caseOverride = kCaseLifecycle;
      e.detail = "uri is -[WKWebView URL] (the main frame's current document)";
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("didFinishNavigation", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("didFinishNavigation", ex.what());
  } catch (...) {
    NoteCaught("didFinishNavigation", "unknown C++ exception");
  }
}

/* A cancelled navigation surfaces HERE, as WebKitErrorDomain 102 ("Frame load
   interrupted"). Recording the domain and code is what lets the aggregator tell
   "the hook cancelled it" apart from "the load failed for its own reasons". */
- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
  (void)webView;
  (void)navigation;
  try {
    @try {
      NavEvent e;
      e.hook = "didFailProvisionalNavigation";
      /* Unlike the lifecycle observers above, this URI IS the failed
         navigation's own - the engine names it in the error - so it is
         attributed by URI. The override only covers the case where the engine
         named nothing, which must not fall through to CaseForUri("") and be
         filed as a startup navigation. */
      e.uri = Narrow([[error userInfo]
          objectForKey:NSURLErrorFailingURLStringErrorKey]);
      if (e.uri.empty()) {
        e.caseOverride = kCaseNoFailingUrl;
      }
      char buf[64];
      std::snprintf(buf, sizeof(buf), " code=%ld", (long)[error code]);
      e.detail = std::string{"domain="} + Narrow([error domain]) + buf;
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("didFailProvisionalNavigation", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("didFailProvisionalNavigation", ex.what());
  } catch (...) {
    NoteCaught("didFailProvisionalNavigation", "unknown C++ exception");
  }
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
  (void)webView;
  (void)navigation;
  try {
    @try {
      NavEvent e;
      e.hook = "didFailNavigation";
      e.uri = Narrow([[error userInfo]
          objectForKey:NSURLErrorFailingURLStringErrorKey]);
      if (e.uri.empty()) {
        e.caseOverride = kCaseNoFailingUrl;
      }
      char buf[64];
      std::snprintf(buf, sizeof(buf), " code=%ld", (long)[error code]);
      e.detail = std::string{"domain="} + Narrow([error domain]) + buf;
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("didFailNavigation", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("didFailNavigation", ex.what());
  } catch (...) {
    NoteCaught("didFailNavigation", "unknown C++ exception");
  }
}

/* A web content process crash would otherwise present as a phase that simply
   stopped producing events until the watchdog fired, and "the engine died" and
   "the engine observed nothing" are opposite findings. */
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  (void)webView;
  try {
    @try {
      NavEvent e;
      e.hook = "webContentProcessDidTerminate";
      /* No URI at all: without the override CaseForUri("") would file the
         death of the content process as a startup navigation. */
      e.caseOverride = kCaseNotNavigation;
      e.detail = "the web content process died";
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("webContentProcessDidTerminate", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("webContentProcessDidTerminate", ex.what());
  } catch (...) {
    NoteCaught("webContentProcessDidTerminate", "unknown C++ exception");
  }
}

/* ------------------- WKNavigationDelegate: downloads -------------------- */
/* Both hooks are macOS 11.3+, i.e. BELOW the pinned 12.0 deployment target, so
   they need no @available guard. See the file header. */

- (void)webView:(WKWebView *)webView
     navigationAction:(WKNavigationAction *)navigationAction
    didBecomeDownload:(WKDownload *)download {
  (void)webView;
  try {
    @try {
      NavEvent e;
      e.hook = "navigationAction:didBecomeDownload";
      e.uri = Narrow([[[navigationAction request] URL] absoluteString]);
      e.navType = NavTypeName([navigationAction navigationType]);
      /* handed a WKNavigationAction, so nav_type is real here - but this hook
         only ANNOUNCES the conversion, it cannot refuse it */
      e.basis = kBasisNavType;
      e.detail = "observation only: the download is already a download here";
      RecordEvent(std::move(e));
      [download setDelegate:self];
    } @catch (id ex) {
      (void)ex;
      NoteCaught("navigationAction:didBecomeDownload", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("navigationAction:didBecomeDownload", ex.what());
  } catch (...) {
    NoteCaught("navigationAction:didBecomeDownload", "unknown C++ exception");
  }
}

- (void)webView:(WKWebView *)webView
    navigationResponse:(WKNavigationResponse *)navigationResponse
     didBecomeDownload:(WKDownload *)download {
  (void)webView;
  try {
    @try {
      NavEvent e;
      e.hook = "navigationResponse:didBecomeDownload";
      e.uri = Narrow([[[navigationResponse response] URL] absoluteString]);
      e.mainFrame = ([navigationResponse isForMainFrame] != NO);
      e.targetFrame = e.mainFrame ? "main" : "sub";
      e.detail = "observation only: the download is already a download here";
      RecordEvent(std::move(e));
      [download setDelegate:self];
    } @catch (id ex) {
      (void)ex;
      NoteCaught("navigationResponse:didBecomeDownload", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("navigationResponse:didBecomeDownload", ex.what());
  } catch (...) {
    NoteCaught("navigationResponse:didBecomeDownload", "unknown C++ exception");
  }
}

/* ------------------------- WKDownloadDelegate --------------------------- */

- (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
                 suggestedFilename:(NSString *)suggestedFilename
                 completionHandler:
                     (void (^)(NSURL *destination))completionHandler {
  (void)download;
  try {
    @try {
      NavEvent e;
      e.hook = "download:decideDestinationUsingResponse";
      /* A nil destination is the documented refusal, so this hook CAN stop a
         download - which is the whole question the download case exists to
         ask. */
      e.policy = true;
      e.uri = Narrow([[response URL] absoluteString]);
      /* `cancelled` reads THE AUDIT'S CANCEL POLICY and nothing else.
         It used to be an unconditional true, which recorded "this probe
         refuses to write to disk" in the column a reader takes to mean "the
         native hook stopped it": the row read cancelled=true even in a phase
         whose policy allowed the download, so it could never answer the
         question it was there for. The zero-disk rule has not changed - the
         destination answer below is nil in every phase - but that is an
         INSTRUMENT fact and now lives in detail, where nothing counts it. */
      const bool cancelling = g_cancelUntrusted.load();
      /* WHAT THIS HOOK ACTUALLY DID, which is refuse - the destination answer
         below is nil in every phase. Reading the phase's cancel policy here
         would publish "not cancelled" for a download this instrument in fact
         refused. The honest reading of this row is therefore "the hook CAN
         refuse a download", not "the audit policy chose to"; detail says so,
         and in practice only the cancelling coverage phase ever reaches it,
         which is also the only phase the Windows reference reaches it in. */
      e.cancelled = true;
      e.detail = std::string{"suggested="} + Narrow(suggestedFilename) +
                 " cancel_policy=" + (cancelling ? "on" : "off") +
                 " destination=nil(UNCONDITIONAL: the audit observes downloads,"
                 " it never writes one - ZERO DISK; this row proves the hook"
                 " can refuse, not that the policy chose to)";
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("download:decideDestination", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("download:decideDestination", ex.what());
  } catch (...) {
    NoteCaught("download:decideDestination", "unknown C++ exception");
  }
  /* EXACTLY ONCE, on EVERY path, and always nil. */
  @try {
    completionHandler(nil);
  } @catch (id ex) {
    (void)ex;
    NoteCaught("download:decideDestination.handler", "exception");
  }
}

- (void)download:(WKDownload *)download
    didFailWithError:(NSError *)error
          resumeData:(NSData *)resumeData {
  (void)download;
  (void)resumeData;
  try {
    @try {
      NavEvent e;
      e.hook = "download:didFailWithError";
      /* No URI: this is the outcome of the destination decision, and it is the
         OBSERVATION that corroborates it - a download stopped at its
         destination surfaces here rather than at downloadDidFinish. */
      e.caseOverride = kCaseNotNavigation;
      char buf[64];
      std::snprintf(buf, sizeof(buf), " code=%ld", (long)[error code]);
      e.detail = std::string{"domain="} + Narrow([error domain]) + buf;
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("download:didFailWithError", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("download:didFailWithError", ex.what());
  } catch (...) {
    NoteCaught("download:didFailWithError", "unknown C++ exception");
  }
}

- (void)downloadDidFinish:(WKDownload *)download {
  (void)download;
  try {
    @try {
      NavEvent e;
      e.hook = "downloadDidFinish";
      e.caseOverride = kCaseNotNavigation;
      e.detail =
          "a download COMPLETED - the destination decision did not stop it";
      RecordEvent(std::move(e));
    } @catch (id ex) {
      (void)ex;
      NoteCaught("downloadDidFinish", "exception");
    }
  } catch (const std::exception &ex) {
    NoteCaught("downloadDidFinish", ex.what());
  } catch (...) {
    NoteCaught("downloadDidFinish", "unknown C++ exception");
  }
}

/* ------------------------------ WKUIDelegate ---------------------------- */

/*
 * THE NEW-WINDOW MEASUREMENT, and the reason this probe displaces upstream's
 * UI delegate at all. Two facts can only be observed here:
 *
 *   - whether cancelling in decidePolicyForNavigationAction (targetFrame ==
 *     nil) prevents the child from being created AT ALL, i.e. whether this
 *     method is ever reached after a Cancel; and
 *   - what a genuinely created new window can reach, which is one of the six
 *     contexts audit question 1 must cover.
 *
 * Only the exposure phase materialises a child. Every other phase records the
 * arrival and returns nil, which is itself the answer.
 */
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  (void)webView;
  (void)windowFeatures;
  WKWebView *created = nil;
  try {
    @try {
      g_createWebViewCalls++;
      NavEvent e;
      e.hook = "createWebViewWithConfiguration";
      /* returning nil refuses the child window: this is the second of the two
         hooks a new-window denial can be spelled in on this engine */
      e.policy = true;
      e.uri = Narrow([[[navigationAction request] URL] absoluteString]);
      e.navType = NavTypeName([navigationAction navigationType]);
      /* handed a WKNavigationAction, so the derivation is available here - but
         user_initiated stays null, exactly as it does everywhere else on this
         target. See the file header. */
      e.basis = kBasisNavType;
      e.targetFrame = "none-new-window";

      /* `cancelled` reads THE AUDIT'S CANCEL POLICY, never the phase's
         child-window setting. It used to be true whenever child windows were
         disabled - which is phase CONFIGURATION - so in the two redirect
         phases, which run non-cancelling, a window.open reaching this hook was
         reported as cancelled although the policy ALLOWED it. Whether a child
         was materialised is an instrument fact and lives in detail. */
      const bool cancelling = g_cancelUntrusted.load();

      if (g_makeChildWindows.load() &&
          (g_childWindowsMade < CAP8B_MAX_CHILD_WINDOWS)) {
        /* The configuration MUST be the one WebKit handed us: it carries the
           opener relationship and the user content controller, and both are
           exactly what the exposure question is about. */
        WKWebView *child =
            [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                               configuration:configuration];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 640, 480)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        /* explicit ownership: see the g_childWindows comment */
        [window setReleasedWhenClosed:NO];
        [window setTitle:@"cap8b child"];
        [child setNavigationDelegate:self];
        [child setUIDelegate:self];
        [window setContentView:child]; /* retains the view */
        [window orderFront:nil];
        if (g_childWindows == nil) {
          g_childWindows = [[NSMutableArray alloc] init];
        }
        [g_childWindows addObject:window];
        [window release]; /* the array holds it now */
        g_childWindowsMade++;
        e.detail = std::string{"created=yes cancel_policy="} +
                   (cancelling ? "on" : "off");
        created = [child autorelease];
        /* THE HOOK'S OWN OUTCOME, not the phase's configuration: a child was
           materialised, so this hook did NOT refuse. Reading the cancel
           policy here would publish a refusal that did not happen. */
        e.cancelled = false;
      } else {
        e.detail =
            std::string{g_makeChildWindows.load()
                            ? "created=no reason=instrument-cap-reached"
                            : "created=no reason=instrument-phase-materialises-"
                              "no-child"} +
            " cancel_policy=" + (cancelling ? "on" : "off") +
            " (returning nil refuses the child either way)";
        /* nil is returned below, so the child really was refused - whatever
           the phase's cancel policy happened to be */
        e.cancelled = true;
      }
      RecordEvent(std::move(e));
    } @catch (NSException *ex) {
      NoteCaught("createWebViewWithConfiguration", Narrow([ex name]));
      created = nil;
    } @catch (id ex) {
      (void)ex;
      NoteCaught("createWebViewWithConfiguration", "non-NSException object");
      created = nil;
    }
  } catch (const std::exception &ex) {
    NoteCaught("createWebViewWithConfiguration", ex.what());
    created = nil;
  } catch (...) {
    NoteCaught("createWebViewWithConfiguration", "unknown C++ exception");
    created = nil;
  }
  return created;
}

@end

/* ------------------------------------------------------------------ */
/* bindings, drivers and phases                                        */
/* ------------------------------------------------------------------ */

namespace {

PWebCap8bDelegate *g_delegate = nil;
/* Upstream's own WKUIDelegate, borrowed for the phase and RESTORED before
   webview_destroy. Upstream's destructor releases whatever UI delegate the view
   carries at that moment (cocoa_webkit.hh:107-111); leaving ours there would
   over-release ours and leak theirs, so the restore is not tidiness but
   correctness. */
id g_upstreamUIDelegate = nil;
WKWebView *g_view = nil;

void CloseChildWindows() {
  @try {
    if (g_childWindows == nil) {
      return;
    }
    for (NSWindow *window in g_childWindows) {
      @try {
        id contentView = [window contentView];
        if ([contentView isKindOfClass:[WKWebView class]]) {
          WKWebView *child = (WKWebView *)contentView;
          [child stopLoading];
          [child setNavigationDelegate:nil];
          [child setUIDelegate:nil];
        }
        [window setContentView:nil];
        [window close];
      } @catch (id e) {
        (void)e;
        NoteCaught("CloseChildWindows.window", "exception");
      }
    }
    [g_childWindows removeAllObjects];
  } @catch (id e) {
    (void)e;
    NoteCaught("CloseChildWindows", "exception");
  }
  g_childWindowsMade = 0;
}

void SignalPhaseDone() {
  {
    std::lock_guard<std::mutex> guard(g_wakeLock);
    g_phaseDone = true;
  }
  g_wake.notify_all();
}

/* The three webview_bind handlers are C ABI callbacks: the engine calls them
   through a function pointer held by upstream's C++ binding table, and an
   exception leaving one crosses that boundary. Each therefore carries the same
   barrier the delegate methods do, and each answers webview_return EXACTLY
   ONCE, on every path, from OUTSIDE it - the same structural rule the
   decisionHandlers follow. */
void BindInvoke(const char *id, const char *req, void * /*arg*/) {
  try {
    @try {
      const std::string label = FirstJsonString(req == nullptr ? "" : req);
      std::lock_guard<std::mutex> guard(g_lock);
      g_m.nativeArrivals[label] += 1;
      std::printf("[cap8b] NATIVE ARRIVAL label=%s\n", label.c_str());
      std::fflush(stdout);
    } @catch (id e) {
      (void)e;
      NoteCaught("BindInvoke", "exception");
    }
  } catch (const std::exception &e) {
    NoteCaught("BindInvoke", e.what());
  } catch (...) {
    NoteCaught("BindInvoke", "unknown C++ exception");
  }
  @try {
    webview_return(g_webview, id, 0, "null");
  } @catch (id e) {
    (void)e;
    NoteCaught("BindInvoke.return", "exception");
  }
}

/* The activation control's round trip: it does nothing but resolve, so that
   the navigation performed in its continuation is measured against a binding
   promise and against nothing else. */
void BindPing(const char *id, const char *req, void * /*arg*/) {
  try {
    @try {
      const std::string label = FirstJsonString(req == nullptr ? "" : req);
      std::lock_guard<std::mutex> guard(g_lock);
      g_m.nativeArrivals[label] += 1;
    } @catch (id e) {
      (void)e;
      NoteCaught("BindPing", "exception");
    }
  } catch (const std::exception &e) {
    NoteCaught("BindPing", e.what());
  } catch (...) {
    NoteCaught("BindPing", "unknown C++ exception");
  }
  @try {
    webview_return(g_webview, id, 0, "null");
  } @catch (id e) {
    (void)e;
    NoteCaught("BindPing.return", "exception");
  }
}

void BindReport(const char *id, const char *req, void * /*arg*/) {
  try {
    @try {
      /* unwrapped here, once: the artifact carries the page's own JSON, not a
         params array wrapping an escaped copy of it */
      const std::string payload = FirstJsonString(req == nullptr ? "" : req);
      std::lock_guard<std::mutex> guard(g_lock);
      if (g_reportSlot != nullptr && g_reportSlot->empty()) {
        *g_reportSlot = payload;
      }
    } @catch (id e) {
      (void)e;
      NoteCaught("BindReport", "exception");
    }
  } catch (const std::exception &e) {
    NoteCaught("BindReport", e.what());
  } catch (...) {
    NoteCaught("BindReport", "unknown C++ exception");
  }
  /* The tail runs on EVERY path, including the one where the report could not
     be stored: a phase whose page reported and whose barrier then fired must
     still end, or it hangs until its watchdog. */
  @try {
    webview_return(g_webview, id, 0, "null");
  } @catch (id e) {
    (void)e;
    NoteCaught("BindReport.return", "exception");
  }
  SignalPhaseDone();
  @try {
    webview_terminate(g_webview); /* on the GUI thread: the documented path */
  } @catch (id e) {
    (void)e;
    NoteCaught("BindReport.terminate", "exception");
  }
}

/* THE PHASE GENERATION, and a MACOS-SPECIFIC hazard the Windows probe does not
   have. webview_dispatch on this backend is dispatch_async_f onto the MAIN
   QUEUE (cocoa_webkit.hh:181), and the main queue only drains while a run loop
   is spinning. A callback the watchdog enqueued microseconds before its phase
   ended therefore does NOT die with that phase: it waits, and runs at the start
   of the NEXT phase's run loop - against a webview_t webview_destroy has
   already freed. On Windows the same dispatch is a window message, which the
   destroyed window discards for us; here nothing does. Every dispatched
   callback therefore carries the generation it was armed in and does nothing at
   all once that generation is over. The stale arrival is NOTED rather than
   swallowed: it is a fact about the engine's queue, and the artifact should
   carry it. */
std::atomic<std::uintptr_t> g_generation{1};

bool DispatchStillCurrent(const char *what, void *arg) {
  if (reinterpret_cast<std::uintptr_t>(arg) == g_generation.load()) {
    return true;
  }
  Note(std::string{"a queued "} + what +
       " arrived after its phase had ended and was ignored - the main queue "
       "outlives the phase that armed it");
  return false;
}

/* Also a C ABI callback - webview_dispatch hands this straight to
   dispatch_async_f - and DispatchStillCurrent builds a std::string on the
   stale path, so the barrier is not decorative. */
void TerminateOnGuiThread(webview_t w, void *arg) {
  try {
    @try {
      if (!DispatchStillCurrent("terminate", arg)) {
        return;
      }
      webview_terminate(w);
    } @catch (id e) {
      (void)e;
      NoteCaught("TerminateOnGuiThread", "exception");
    }
  } catch (const std::exception &e) {
    NoteCaught("TerminateOnGuiThread", e.what());
  } catch (...) {
    NoteCaught("TerminateOnGuiThread", "unknown C++ exception");
  }
}

/* The two activation controls the PAGE cannot produce for itself: a
   host-injected script navigation, and a genuine mouse gesture. Both are
   dispatched onto the GUI thread after a delay, from a thread that is joined
   before any native state dies. */
void DriveActEval(webview_t w, void *arg) {
  try {
    @try {
      if (!DispatchStillCurrent("act-eval drive", arg)) {
        return;
      }
      webview_eval(w,
                   "location.href = 'https://example.invalid/act-after-eval';");
    } @catch (id e) {
      (void)e;
      NoteCaught("DriveActEval", "exception");
    }
  } catch (const std::exception &e) {
    NoteCaught("DriveActEval", e.what());
  } catch (...) {
    NoteCaught("DriveActEval", "unknown C++ exception");
  }
}

/* A REAL mouse gesture, and the macOS analogue of the Windows probe's
   SendInput. The page has laid the anchor over a fixed 400x200 rectangle at
   the content origin precisely so this can click it without ever asking the
   page where it is - a page->native question would itself grant the activation
   being measured.
   NSEvent + -[NSApplication postEvent:atStart:] is used rather than
   CGEventPost DELIBERATELY: posting a CGEvent requires the process to hold
   Accessibility/Input-Monitoring authorisation, which a hosted runner does not
   grant and which would turn a measurement into a permissions prompt. Posting
   into this application's own event queue needs no authorisation and travels
   the same NSApplication -> NSWindow -> WKWebView path a human click does.
   Whether WebKit honours it as a user gesture is precisely the measurement, and
   BOTH answers are results. */
void DriveActClick(webview_t w, void *arg) {
  try {
    if (!DispatchStillCurrent("act-click gesture", arg)) {
      return;
    }
    @autoreleasepool {
      @try {
        NSWindow *window = (NSWindow *)webview_get_window(w);
        if ((window == nil) || (g_view == nil)) {
          Note("act-real-click: no window or view - gesture not delivered");
          return;
        }
        /* makeKeyAndOrderFront: only. -[NSApplication
           activateIgnoringOtherApps:] is DEPRECATED from macOS 14 and this
           translation unit is built -Werror, so calling it would break the
           build on the pinned runners; it is also unnecessary, because
           upstream already activates a non-bundled app at didFinishLaunching
           (cocoa_webkit.hh:428-436) and postEvent: reaches this process's own
           queue regardless of which app is frontmost. */
        [window makeKeyAndOrderFront:nil];

        /* The anchor is 400x200 at the TOP-LEFT of the content, so the target
           is 120 px in and 60 px DOWN FROM THE TOP - and which local y that is
           depends on the view's own convention. A plain NSView's origin is
           bottom-left, but WebKit's view reports isFlipped = YES so that
           content coordinates run top-down, and the two answers differ by the
           whole height of the view: applying the offset from the wrong edge
           would put the click near the bottom of the page, miss the anchor
           entirely, and report "no gesture was honoured" for a gesture that was
           never aimed at it. So ASK the view rather than assume either
           convention - the same rule as everywhere else in this file. */
        const NSRect bounds = [g_view bounds];
        const NSPoint inView =
            ([g_view isFlipped] != NO)
                ? NSMakePoint(NSMinX(bounds) + 120.0, NSMinY(bounds) + 60.0)
                : NSMakePoint(NSMinX(bounds) + 120.0, NSMaxY(bounds) - 60.0);
        const NSPoint inWindow = [g_view convertPoint:inView toView:nil];
        const NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];

        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                           location:inWindow
                                      modifierFlags:0
                                          timestamp:now
                                       windowNumber:[window windowNumber]
                                            context:nil
                                        eventNumber:0
                                         clickCount:1
                                           pressure:1.0];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                         location:inWindow
                                    modifierFlags:0
                                        timestamp:now + 0.05
                                     windowNumber:[window windowNumber]
                                          context:nil
                                      eventNumber:1
                                       clickCount:1
                                         pressure:0.0];
        if ((down == nil) || (up == nil)) {
          Note("act-real-click: NSEvent synthesis failed - gesture not "
               "delivered");
          return;
        }
        [NSApp postEvent:down atStart:NO];
        [NSApp postEvent:up atStart:NO];
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "act-real-click: posted a left mouse down/up pair at "
                      "window(%.1f,%.1f)",
                      inWindow.x, inWindow.y);
        Note(std::string{buf});
      } @catch (id e) {
        (void)e;
        NoteCaught("DriveActClick", "exception");
      }
    }
  } catch (const std::exception &e) {
    NoteCaught("DriveActClick", e.what());
  } catch (...) {
    NoteCaught("DriveActClick", "unknown C++ exception");
  }
}

/* ------------------------------------------------------------------ */
/* one phase                                                           */
/* ------------------------------------------------------------------ */

struct Phase {
  const char *name;
  PhaseKind kind;
  const char *startUri;
  bool cspOn;
  bool cancelUntrusted;
  bool makeChildWindows;
  std::string *slot;
  int timeoutSeconds;
  /* the single case this phase exists to observe, or "" for the multi-case
     phases that end with a page report */
  const char *expectedCase;
};

std::string EngineVersionString() {
  std::string version;
  @autoreleasepool {
    @try {
      NSBundle *webkit = [NSBundle bundleWithIdentifier:@"com.apple.WebKit"];
      NSString *bundleVersion =
          (webkit != nil)
              ? (NSString *)[[webkit infoDictionary]
                    objectForKey:@"CFBundleVersion"]
              : nil;
      NSString *os = [[NSProcessInfo processInfo] operatingSystemVersionString];
      version = std::string{"WebKit "} +
                (bundleVersion != nil ? Narrow(bundleVersion)
                                      : std::string{"<unknown>"}) +
                "; " + Narrow(os);
    } @catch (id e) {
      (void)e;
      version = "<unavailable>";
    }
  }
  return version;
}

/* The setup-and-run half. Split from RunPhase so that every early refusal
   still reaches exactly one teardown. */
bool RunPhaseInner(const Phase &ph, std::thread &watchdog) {
  /* The WKWebView is BORROWED from the pinned C ABI: message sends only, never
     retained or released by us - exactly the CAP-7M seam rule. */
  void *controller = webview_get_native_handle(
      g_webview, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if (controller == nullptr) {
    Note("borrowed browser controller unavailable");
    return false;
  }
  g_view = (WKWebView *)controller;

  /* Where the engine thinks it is BEFORE we navigate: the initial-about:blank
     question, measured rather than assumed. On WebView2 the equivalent is
     get_Source; here it is -[WKWebView URL], which upstream's own eval_impl
     already relies on being nil before content loads
     (cocoa_webkit.hh:237). Any event recorded with
     case="(host or startup navigation)" before ours is the other half of the
     answer. */
  {
    NSString *initial = [[g_view URL] absoluteString];
    const std::string observed =
        (initial != nil) ? Narrow(initial) : std::string{"<nil>"};
    const bool loading = ([g_view isLoading] != NO);
    {
      std::lock_guard<std::mutex> guard(g_lock);
      if (g_m.initialSource.empty()) {
        g_m.initialSource = observed;
      }
    }
    Note(std::string{"phase "} + ph.name +
         ": WKWebView.URL before navigate = " + observed +
         ", isLoading = " + (loading ? "yes" : "no"));
  }

  if (g_m.engineVersion.empty()) {
    std::lock_guard<std::mutex> guard(g_lock);
    g_m.engineVersion = EngineVersionString();
  }

  /* Read-only, and it explains a whole class of results before anyone has to
     guess: WKPreferences.javaScriptCanOpenWindowsAutomatically defaults to NO
     and upstream never sets it, so a script-initiated window.open with no user
     gesture may be refused by the engine before ANY delegate is consulted.
     Reading the live configuration is safe; CAP-7M0's measurement was that
     WRITING to it is silently ineffective. */
  @try {
    WKPreferences *preferences = [[g_view configuration] preferences];
    const BOOL popups = [preferences javaScriptCanOpenWindowsAutomatically];
    Note(std::string{"phase "} + ph.name +
         ": javaScriptCanOpenWindowsAutomatically = " +
         ((popups != NO) ? "YES" : "NO"));
  } @catch (id e) {
    (void)e;
    NoteCaught("read javaScriptCanOpenWindowsAutomatically", "exception");
  }

  /* The navigation delegate is upstream's UNOCCUPIED seam; the UI delegate is
     upstream's and is borrowed, then restored at teardown. */
  @try {
    g_upstreamUIDelegate = [g_view UIDelegate];
    [g_view setNavigationDelegate:g_delegate];
    [g_view setUIDelegate:g_delegate];
  } @catch (id e) {
    (void)e;
    NoteCaught("install delegates", "exception");
    return false;
  }

  webview_bind(g_webview, "__pweb_invoke", BindInvoke, nullptr);
  webview_bind(g_webview, "__cap8b_ping", BindPing, nullptr);
  webview_bind(g_webview, "__cap8b_report", BindReport, nullptr);

  const int seconds = ph.timeoutSeconds;
  const PhaseKind kind = ph.kind;
  /* Captured by value: the generation this phase owns, handed to every
     dispatched callback as its arg so a late arrival can identify itself as
     late. See DispatchStillCurrent. */
  void *const generation =
      reinterpret_cast<void *>(g_generation.load());
  watchdog = std::thread([seconds, kind, generation] {
    /* The activation controls need something to happen that the page cannot do
       for itself; both are timed from here and dispatched onto the GUI loop,
       and both are skipped the moment the phase has already ended. */
    if (kind == PhaseKind::ActEval || kind == PhaseKind::ActClick) {
      std::unique_lock<std::mutex> lock(g_wakeLock);
      const bool ended = g_wake.wait_for(lock, std::chrono::milliseconds(2000),
                                         [] { return g_phaseDone; });
      lock.unlock();
      if (!ended) {
        webview_dispatch(g_webview,
                         (kind == PhaseKind::ActEval) ? DriveActEval
                                                      : DriveActClick,
                         generation);
      }
    }
    std::unique_lock<std::mutex> lock(g_wakeLock);
    if (!g_wake.wait_for(lock, std::chrono::seconds(seconds),
                         [] { return g_phaseDone; })) {
      lock.unlock();
      Note("watchdog fired - the phase did not report in time");
      /* NSApplication is main-thread affine: the ONLY legal shutdown from a
         worker is a dispatch onto the GUI thread. */
      webview_dispatch(g_webview, TerminateOnGuiThread, generation);
    }
  });

  webview_set_title(g_webview, "CAP-8B audit");
  webview_set_size(g_webview, 900, 650, WEBVIEW_HINT_NONE);
  webview_navigate(g_webview, ph.startUri);
  webview_run(g_webview);
  return true;
}

bool RunPhase(const Phase &ph) {
  /* FIRST, before anything in this phase can be armed - the watchdog thread is
     not created until RunPhaseInner, and the previous phase's was joined before
     that phase returned - every callback the PREVIOUS phase left on the main
     queue is now stale by construction. The counter starts at 1 and only ever
     increases, so no generation value is ever the null pointer a dispatch arg
     would be indistinguishable from. */
  g_generation.fetch_add(1u);
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_phaseName = ph.name;
    g_expectedCase = ph.expectedCase;
    /* per phase: a first leg observed in the previous phase must never label
       this phase's redirect */
    g_lastPolicyUri.clear();
  }
  {
    std::lock_guard<std::mutex> guard(g_wakeLock);
    g_phaseDone = false;
  }
  g_phaseKind.store(static_cast<int>(ph.kind));
  g_cspOn.store(ph.cspOn);
  g_cancelUntrusted.store(ph.cancelUntrusted);
  g_makeChildWindows.store(ph.makeChildWindows);
  g_trustedCommitted.store(false);
  g_reportSlot = ph.slot;

  bool ok = false;
  std::thread watchdog;

  @autoreleasepool {
    if (!InstallPrecreateSeam()) {
      Note("the pre-create seam could not be installed - the Objective-C "
           "runtime refused the +[WKWebViewConfiguration new] override");
      return false;
    }
    if (g_seamHandler == nil) {
      g_seamHandler = [[PWebCap8bSchemeHandler alloc] init];
    }
    if (g_delegate == nil) {
      g_delegate = [[PWebCap8bDelegate alloc] init];
    }
    const unsigned seamBefore = g_seamInvocations;
    __atomic_store_n(&g_seamArmed, 1, __ATOMIC_SEQ_CST);

    g_webview = webview_create(0, nullptr);
    if (g_webview == nullptr) {
      /* the no-session condition: NULL, never a code (c_api_impl discards it) */
      Note("webview_create returned null - no WKWebView or no session");
      __atomic_store_n(&g_seamArmed, 0, __ATOMIC_SEQ_CST);
      return false;
    }
    if (g_seamInvocations == seamBefore) {
      Note("the pre-create seam never ran - webview_create did not go through "
           "+[WKWebViewConfiguration new]");
    }

    ok = RunPhaseInner(ph, watchdog);

    /* Whatever happened above, the watchdog is released and joined before any
       native state dies: a thread still holding g_webview across
       webview_destroy is a use-after-free with a timer on it. */
    SignalPhaseDone();
    if (watchdog.joinable()) {
      watchdog.join();
    }
    /* AND AGAIN HERE, the moment this phase's run loop has stopped and its
       watchdog is joined: from now on nothing armed by this phase may run.
       Bumping only at the top of the next RunPhase would leave the teardown
       below - webview_destroy included - inside the OLD generation, so a
       callback drained in that window would pass the guard and reach a
       webview_t that is being freed. Nothing spins a run loop between here and
       the next phase, so that window is not known to be reachable; closing it
       costs one atomic increment, and the counter's only meaning is
       equality. */
    g_generation.fetch_add(1u);

    /* TEARDOWN ORDER IS LOAD-BEARING. Close what we opened, disarm the seam
       (it cannot be uninstalled), drop the delegate pointers WKWebView holds
       unretained, and restore upstream's UI delegate so upstream's destructor
       releases its own object exactly once. */
    CloseChildWindows();
    __atomic_store_n(&g_seamArmed, 0, __ATOMIC_SEQ_CST);
    if (g_view != nil) {
      @try {
        [g_view setNavigationDelegate:nil];
        [g_view setUIDelegate:g_upstreamUIDelegate];
      } @catch (id e) {
        (void)e;
        NoteCaught("restore delegates", "exception");
      }
    }
    g_upstreamUIDelegate = nil;
    g_view = nil;

    webview_unbind(g_webview, "__pweb_invoke");
    webview_unbind(g_webview, "__cap8b_ping");
    webview_unbind(g_webview, "__cap8b_report");

    [g_seamHandler resetTasks];
    g_reportSlot = nullptr;
    webview_destroy(g_webview);
    g_webview = nullptr;
  }
  return ok;
}

/* ------------------------------------------------------------------ */
/* the artifact                                                        */
/* ------------------------------------------------------------------ */

/* Rewritten after EVERY phase, not once at the end. The harness bounds the
   whole process from the outside, and a probe that only writes at exit turns
   any outer kill into a run with no measurement at all. */
void WriteJson(const char *path) {
  std::lock_guard<std::mutex> guard(g_lock);
  std::string j = "{\n";
  j += "  \"schema\": 1,\n";
  j += "  \"target\": \"" CAP8B_TARGET "\",\n";
  j += "  \"engine\": \"WKWebView\",\n";
  j += "  \"engine_version\": " + JStr(g_m.engineVersion) + ",\n";
  j += "  \"initial_source_before_navigate\": " + JStr(g_m.initialSource) +
       ",\n";
  j += "  \"csp_headers_emitted\": " + std::to_string(g_m.cspHeadersEmitted) +
       ",\n";
  j += "  \"download_hook_available\": " + JBool(g_m.downloadHookAvailable) +
       ",\n";
  j += "  \"candidate_csp\": " + JStr(kCandidateCsp) + ",\n";
  /* One line a reader can put at the head of the user_initiated column. Two
     targets whose columns look alike but whose semantics differ is exactly the
     silently-vacuous comparison this artifact exists to prevent - and on this
     target the column is empty by necessity, which a reader must be told
     before they read a single row. */
  j += "  \"user_initiated_semantics\": " +
       JStr("this engine exposes NO public user-activation flag - "
            "-[WKNavigationAction _isUserInitiated] is private SPI and is "
            "forbidden in this repository - so user_initiated is null on "
            "EVERY row here rather than false, nav_type carries the only "
            "public signal, and the four activation phases (act-plain, "
            "act-after-bind, act-after-eval, act-real-click) are the evidence "
            "a human must judge the navigationType==LinkActivated "
            "substitution from") +
       ",\n";

  j += "  \"native_arrivals\": {";
  bool first = true;
  for (const auto &entry : g_m.nativeArrivals) {
    j += first ? "\n" : ",\n";
    first = false;
    j += "    " + JStr(entry.first) + ": " + std::to_string(entry.second);
  }
  j += first ? "},\n" : "\n  },\n";

  j += "  \"events\": [";
  for (size_t i = 0; i < g_m.events.size(); ++i) {
    const NavEvent &e = g_m.events[i];
    j += (i == 0 ? "\n" : ",\n");
    /* The ELEVEN shared fields first, in cap8b_audit_win.cpp's order, then the
       four macOS-only additions. */
    j += "    { \"phase\": " + JStr(e.phase) +
         ", \"case\": " + JStr(e.caseName) + ", \"hook\": " + JStr(e.hook) +
         ", \"uri\": " + JStr(e.uri) +
         /* null, not false, when the engine was never asked - see NavEvent.
            On this target that is EVERY row, and that is the finding. */
         ", \"user_initiated\": " +
         (e.userInitiatedKnown ? JBool(e.userInitiated)
                               : std::string{"null"}) +
         ", \"user_initiated_basis\": " + JStr(e.basis) +
         ", \"policy\": " + JBool(e.policy) +
         ", \"redirected\": " + JBool(e.redirected) +
         ", \"cancelled\": " + JBool(e.cancelled) +
         ", \"bootstrap_allowed\": " + JBool(e.bootstrapAllowed) +
         ", \"detail\": " + JStr(e.detail) +
         ", \"nav_type\": " + JStr(e.navType) +
         ", \"target_frame\": " + JStr(e.targetFrame) +
         ", \"main_frame\": " + JBool(e.mainFrame) +
         ", \"source\": " + JStr(e.source) + " }";
  }
  j += g_m.events.empty() ? "],\n" : "\n  ],\n";

  j += "  \"exposure_report\": " + JStr(g_m.exposureReport) + ",\n";
  j += "  \"coverage_report\": " + JStr(g_m.coverageReport) + ",\n";
  j += "  \"csp_report\": " + JStr(g_m.cspReport) + ",\n";
  j += "  \"csp_meta_report\": " + JStr(g_m.cspMetaReport) + ",\n";

  j += "  \"beacons\": [";
  for (size_t i = 0; i < g_m.beacons.size(); ++i) {
    j += (i == 0 ? "\n    " : ",\n    ");
    j += JStr(g_m.beacons[i]);
  }
  j += g_m.beacons.empty() ? "],\n" : "\n  ],\n";

  j += "  \"notes\": [";
  for (size_t i = 0; i < g_m.notes.size(); ++i) {
    j += (i == 0 ? "\n    " : ",\n    ");
    j += JStr(g_m.notes[i]);
  }
  j += g_m.notes.empty() ? "]\n" : "\n  ]\n";
  j += "}\n";

  std::FILE *f = std::fopen(path, "wb");
  if (f == NULL) {
    std::fprintf(stderr, "[cap8b] cannot write %s\n", path);
    return;
  }
  std::fwrite(j.data(), 1, j.size(), f);
  std::fclose(f);
  std::printf("[cap8b] wrote %s (%zu bytes)\n", path, j.size());
  std::fflush(stdout);
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: cap8b_audit_macos <output.json>\n");
    return 2;
  }

  int ran = 0;

  @autoreleasepool {
    /* The GUI runs on the MAIN thread with a real NSApplication, exactly as
       test/cap7m/cap7m_probe.mm does. Upstream reaches for the shared
       application itself (cocoa_webkit.hh:92); asking for it here first is
       explicit rather than incidental, and it is what makes this probe's own
       child window and its synthesised gesture legal. */
    [NSApplication sharedApplication];

    Note("target " CAP8B_TARGET ", engine WKWebView");
    /* Recorded rather than asserted, and BEFORE any phase, so a run whose seam
       is not confined reads as such instead of merely strange. The two calls
       are SEQUENCED through locals on purpose: SeamIsConfined() is meaningless
       until the seam is installed, and the evaluation order of two calls inside
       one expression is unspecified. */
    const bool seamInstalled = (InstallPrecreateSeam() != 0);
    const bool seamConfined = (SeamIsConfined() != 0);
    Note(std::string{"pre-create seam installed: "} +
         (seamInstalled ? "yes" : "NO") +
         ", confined to WKWebViewConfiguration's own metaclass: " +
         (seamConfined ? "yes" : "NO"));

    /* A RUNTIME query, not a compile-time one: "the 12.0 SDK declares
       WKDownload" and "this machine's WebKit has it" are different
       statements, and the artifact should carry the second. */
    {
      const bool haveDownload = (objc_getClass("WKDownload") != Nil);
      std::lock_guard<std::mutex> guard(g_lock);
      g_m.downloadHookAvailable = haveDownload;
    }

    const Phase phases[] = {
        {"exposure", PhaseKind::Exposure, "pweb://app/index.html", false, false,
         true, &g_m.exposureReport, 30, ""},
        {"coverage", PhaseKind::Coverage, "pweb://app/index.html", false, true,
         false, &g_m.coverageReport, 90, ""},
        {"csp", PhaseKind::Csp, "pweb://app/csp.html", true, false, false,
         &g_m.cspReport, 30, ""},
        {"csp-meta", PhaseKind::CspMeta, "pweb://app/csp-meta.html", true,
         false, false, &g_m.cspMetaReport, 30, ""},
        /* the four user-activation controls: one navigation each, fresh
           WebView each, and the page makes no native call it does not have
           to */
        {"activation-plain", PhaseKind::ActPlain, "pweb://app/index.html",
         false, true, false, nullptr, 15, "act-plain"},
        {"activation-bind", PhaseKind::ActBind, "pweb://app/index.html", false,
         true, false, nullptr, 15, "act-after-bind"},
        {"activation-eval", PhaseKind::ActEval, "pweb://app/index.html", false,
         true, false, nullptr, 15, "act-after-eval"},
        {"activation-click", PhaseKind::ActClick, "pweb://app/index.html",
         false, true, false, nullptr, 20, "act-real-click"},
        /* the two redirect controls: the hook is deliberately NOT cancelling,
           so a redirect that would be followed is actually followed */
        {"redirect-external", PhaseKind::RedirectExternal,
         "pweb://app/index.html", false, false, false, nullptr, 15,
         "redirect-out-of-pweb"},
        {"redirect-internal", PhaseKind::RedirectInternal,
         "pweb://app/index.html", false, false, false, nullptr, 15, ""},
    };
    const int total = static_cast<int>(sizeof(phases) / sizeof(phases[0]));

    for (const Phase &ph : phases) {
      Note(std::string{"=== phase "} + ph.name + " ===");
      if (RunPhase(ph)) {
        ++ran;
      } else {
        Note(std::string{"phase "} + ph.name + " could not run");
      }
      /* after EVERY phase: an outer kill must not cost the phases that did
         complete */
      WriteJson(argv[1]);
    }

    /* ---- the free-form record ---- */

    Note("MEASUREMENT NOTE (schema): each event carries the eleven fields "
         "cap8b_audit_win.cpp emits, in its order - phase, case, hook, uri, "
         "user_initiated, user_initiated_basis, policy, redirected, cancelled, "
         "bootstrap_allowed, detail - followed by four macOS-only additions: "
         "nav_type, target_frame, main_frame and source. They are additive: a "
         "reader that knows only the eleven shared fields sees exactly the "
         "Windows shape. `policy` is true only on a hook that can REFUSE the "
         "navigation and false on one that merely observes it; this target "
         "emits about eight hook kinds where Windows emits four, and only four "
         "of them can refuse (decidePolicyForNavigationAction, "
         "decidePolicyForNavigationResponse, createWebViewWithConfiguration "
         "and download:decideDestinationUsingResponse), so counting rows "
         "without that flag would make this target look as if it cancelled "
         "more when what it saw more of is narration.");
    Note("MEASUREMENT NOTE (user activation): -[WKNavigationAction "
         "_isUserInitiated] is PRIVATE SPI and is forbidden in this "
         "repository, and WKNavigationAction exposes no public user-gesture "
         "flag, so this target has NO equivalent of WebView2's "
         "IsUserInitiated. user_initiated is therefore emitted as JSON null on "
         "EVERY event here, never as false: a false would say the engine "
         "answered 'no gesture' when the engine was never asked, and that "
         "single fabricated value would make the cross-target column "
         "meaningless. What was observed travels in nav_type, and "
         "user_initiated_basis names what a reader could derive from it - "
         "'derived:navigationType==WKNavigationTypeLinkActivated' on the three "
         "hooks handed a WKNavigationAction, 'unavailable:...' on the rest. "
         "Whether that derivation is a sound public stand-in is a decision for "
         "the plan, and the four activation phases are the data it should "
         "decide from: act-plain (a timer navigation), act-after-bind (a "
         "navigation in a binding-promise continuation, i.e. after "
         "evaluateJavaScript:), act-after-eval (a host evaluateJavaScript: "
         "navigation) and act-real-click (a synthesised mouse gesture on a "
         "focused anchor). If act-real-click records LinkActivated while the "
         "other three do not, the substitution holds on this engine; if "
         "act-after-bind also records LinkActivated, it does not.");
    Note("MEASUREMENT NOTE (case attribution): most rows are attributed "
         "NATIVELY by URI (CaseForUri), but a hook whose URI is not the URI of "
         "the navigation it reports carries an explicit case name instead. Two "
         "kinds do. (1) The lifecycle observers - "
         "didStartProvisionalNavigation, didCommitNavigation, "
         "didFinishNavigation - read -[WKWebView URL], which is the main "
         "frame's CURRENT document; after the coverage driver's "
         "fragment-same-document case that URL stays "
         "pweb://app/index.html#frag forever, and attributing by URI filed "
         "every later observation, the five authority-* cases and "
         "reload-trusted-subframe among them, under fragment-same-document. "
         "They are now filed as '(main-frame lifecycle observation)'. (2) "
         "didReceiveServerRedirectForProvisionalNavigation is handed no "
         "request at all and -[WKWebView URL] still reads the FIRST LEG there, "
         "so the one row that carries redirected=true was filed under "
         "redirect-first-leg and the redirect-external phase's expected case "
         "never matched. Its case now comes from this probe's OWN fixture - "
         "the Location header it wrote - and its detail carries both URIs that "
         "were actually observed, so a reader who disagrees with the label can "
         "re-derive the row.");
    Note("MEASUREMENT NOTE (redirects): WKNavigationAction carries no "
         "'is redirect' flag, so `redirected` can only be true on an event "
         "recorded from didReceiveServerRedirectForProvisionalNavigation. The "
         "public WKURLSchemeTask protocol has no redirect callback and the "
         "private _didPerformRedirection: SPI is forbidden here, so 'the "
         "engine did not follow our 302' is a legitimate and important result "
         "rather than a probe defect. The redirect-internal phase is what "
         "makes the two answers distinguishable: its 302 points at "
         "pweb://evil/child.html?ctx=redirect-target, so the beacon "
         "'redirect-target-requested' appears if and only if the engine "
         "actually followed it - and a redirect row filed under the "
         "macOS-only case name 'redirect-internal-target' is the other half of "
         "that same observation.");
    Note("MEASUREMENT NOTE (raw transport): the JS drivers are byte-identical "
         "to cap8b_audit_win.cpp's except for the raw-transport expression - "
         "window.chrome.webview.postMessage there, "
         "window.webkit.messageHandlers.__webview__.postMessage here. That "
         "channel is the message handler upstream registers on the user "
         "content controller (cocoa_webkit.hh:508), which WebKit exposes in "
         "EVERY frame, while the shim user script is injected TOP-FRAME-ONLY "
         "(cocoa_webkit.hh:250, forMainFrameOnly=true). The exposure report "
         "and native_arrivals together are what settle whether the raw channel "
         "outreaches the shim.");
    Note("MEASUREMENT NOTE (raw replies): an arrival that came through the raw "
         "transport from a SUBFRAME carries an id the top frame's promise "
         "table never issued, and webview_return evaluates "
         "window.__webview__.onReply in the MAIN frame only. That reply throws "
         "a TypeError inside an evaluateJavaScript: with no completion "
         "handler, which WebKit discards. The ARRIVAL is the measurement; the "
         "reply is not, and native_arrivals - never the page's optimism - is "
         "the authority.");
    Note("MEASUREMENT NOTE (downloads): WKDownload, WKDownloadDelegate, "
         "-[WKNavigationAction shouldPerformDownload] and both "
         "didBecomeDownload: hooks were introduced in macOS 11.3, BELOW the "
         "pinned 12.0 deployment target, so no @available guard is needed and "
         "none is written; download_hook_available is nevertheless a runtime "
         "query. Any response WebKit cannot display is converted to a download "
         "so the hook is reachable, and every destination decision answers nil "
         "- the audit observes downloads, it never writes one. `cancelled` on "
         "that row reads the AUDIT'S CANCEL POLICY and not the nil answer: the "
         "nil is an instrument rule that holds in every phase, so recording it "
         "as a cancellation made the row unfalsifiable - it would have said "
         "cancelled=true even in a phase whose policy allowed the download, "
         "and could never have answered whether a native hook can stop one. "
         "The nil answer is stated in detail instead, where nothing counts "
         "it, and download:didFailWithError is the corroborating observation.");
    Note("MEASUREMENT NOTE (frame discrimination): FIRST-CLASS FINDING, and a "
         "point on which the four targets are NOT alike. This engine states "
         "the frame relation of every navigation in the one hook that can also "
         "deny it: WKNavigationAction.targetFrame is nil for an action that "
         "would open a new window and otherwise answers isMainFrame, so "
         "target_frame and main_frame are populated on every "
         "decidePolicyForNavigationAction event and a subframe rule here can "
         "be structural rather than URI-shaped. WebView2 reaches the same "
         "place through a separate FrameNavigationStarting hook. WebKitGTK "
         "MEASURED the opposite - no main-frame/subframe discriminator is "
         "reachable at navigation time at all - so a rule expressed as 'deny "
         "every subframe' is enforceable on this target and on Windows, and "
         "must fall back to CSP frame-src on that one.");
    Note("MEASUREMENT NOTE (new windows): WebView2's NewWindowRequested has no "
         "single counterpart here. A target=_blank / window.open action "
         "reaches decidePolicyForNavigationAction with targetFrame == nil, and "
         "only if that is ALLOWED does the UI delegate's "
         "createWebViewWithConfiguration: run. Both are recorded, so 'the "
         "cancel prevented the child from being created at all' is a fact in "
         "the event list rather than an inference. Only the exposure phase "
         "materialises a real child window, and `cancelled` on the "
         "createWebViewWithConfiguration row reads the AUDIT'S CANCEL POLICY "
         "rather than that setting: it used to be true whenever child windows "
         "were disabled, which is phase CONFIGURATION, so in the two redirect "
         "phases - both of which run non-cancelling - a window.open reaching "
         "this hook was reported cancelled although the policy allowed it. "
         "Whether a child was materialised is stated in detail. Note also that "
         "javaScriptCanOpenWindowsAutomatically defaults to NO, which may deny "
         "a script-initiated window.open before any delegate is consulted.");
    Note("MEASUREMENT NOTE (delegates): upstream leaves the navigation "
         "delegate free and this probe takes it. It also borrows the UI "
         "delegate - upstream's is used only for runOpenPanelWithParameters, "
         "which this probe never triggers - because "
         "createWebViewWithConfiguration: is the only place a target=_blank "
         "child can be observed, and restores upstream's before "
         "webview_destroy so upstream's destructor releases its own object "
         "exactly once.");
    Note("MEASUREMENT NOTE (file: case): the coverage driver's scheme-file "
         "case targets file:///C:/Windows/win.ini on EVERY target, this one "
         "included. The hook decides before any load is attempted, so the "
         "path's existence is irrelevant and byte-identical drivers are worth "
         "more than a locally plausible path.");
    {
      char buf[256];
      std::snprintf(buf, sizeof(buf),
                    "createWebViewWithConfiguration reached %u time(s) across "
                    "all phases; %u child window(s) were materialised (only "
                    "the exposure phase materialises any)",
                    g_createWebViewCalls, g_childWindowsMade);
      Note(std::string{buf});
    }
    {
      char buf[192];
      std::snprintf(buf, sizeof(buf),
                    "exception barriers caught %u exception(s); the pre-create "
                    "seam ran %u time(s); phases that ran: %d of %d",
                    g_caught.load(), g_seamInvocations, ran, total);
      Note(std::string{buf});
    }
    Note("NO fesetenv(FE_DFL_ENV) HERE, deliberately: this probe is pure "
         "Objective-C++ with no FPC runtime in the process, so the FPU traps "
         "that force the remedy in every FPC-hosted PWeb binary were never "
         "enabled. Do not add it by cargo cult.");

    WriteJson(argv[1]);

    if (ran == 0) {
      /* Nothing was measured at all: that is an instrument failure, not a
         result, and the harness must be able to tell the two apart. */
      std::fprintf(stderr, "[cap8b] CAP8B_AUDIT_MACOS_UNAVAILABLE\n");
      return 3;
    }
    std::printf("[cap8b] CAP8B_AUDIT_MACOS_DONE phases=%d/%d\n", ran, total);
    std::fflush(stdout);
  }
  return 0;
}
