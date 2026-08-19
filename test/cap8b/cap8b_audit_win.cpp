/*
 * CAP-8B Windows/WebView2 MEASUREMENT probe.
 *
 * This is an AUDIT INSTRUMENT, not production and not a gate of the shipped
 * policy. It answers, with real runtime evidence rather than API names, the
 * three questions CAP-8B's Checkpoint 1 is not allowed to assume:
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
 * It is written in C++ against the REAL pinned WebView2 SDK header on
 * purpose: the production Pascal adapter must hand-transcribe those COM
 * vtables, and a measurement taken through a hand transcription cannot
 * distinguish "the engine behaves like this" from "my slot order is wrong".
 * The same reasoning produced test/cap4w/cap4w_probe.cpp and
 * test/cap7l/cap7l_probe.c, whose structure this file follows deliberately.
 *
 * DELIBERATELY HOSTILE FIXTURE. This probe serves pweb://evil/* content on
 * purpose - that is the untrusted document whose reach is being measured.
 * Nothing here is shared with, or reachable from, the production adapters:
 * the corpus, the scheme filter and the bindings all live in this file, and
 * nothing under src/ is included or linked.
 *
 * ZERO NETWORK. Every "external" URI targets the reserved TLD
 * example.invalid, and every case is decided by a navigation hook BEFORE a
 * request could leave the machine. The one redirect case is produced by the
 * probe's own 302 response, not by a server.
 *
 * WHAT IS NOT A FAILURE. A measurement that says "this engine does not
 * expose that" is a RESULT. The probe exits nonzero only when it could not
 * MEASURE - no runtime, no session, no window - never because a measured
 * value was inconvenient.
 *
 * Usage: cap8b_audit_win <output.json>
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>

#include <WebView2.h>
#include <shlwapi.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "webview/api.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

/* ------------------------------------------------------------------ */
/* small helpers                                                       */
/* ------------------------------------------------------------------ */

std::string Narrow(const wchar_t *w) {
  if (w == nullptr) {
    return std::string{};
  }
  const int n =
      WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) {
    return std::string{};
  }
  std::string s(static_cast<size_t>(n - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring Widen(const std::string &s) {
  if (s.empty()) {
    return std::wstring{};
  }
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(),
                                    static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), &w[0],
                      n);
  return w;
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

/* The activation phases are SEPARATE processes-worth of state on purpose.
   MEASURED on this runtime (151.0.4129.86): a navigation performed in the
   continuation of a webview_bind promise reports IsUserInitiated = TRUE,
   because upstream resolves that promise through ExecuteScript and WebView2
   runs host-injected script WITH a user gesture. Any driver that calls a
   native binding between cases therefore contaminates every later
   user-activation reading - which is why the coverage driver below makes NO
   native call until its final report, and why each activation control gets
   its own fresh WebView with a fresh page that calls nothing. */
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
   actually reached native. */
constexpr char kChildJs[] =
    "(function(){\n"
    "  var ctx = window.__cap8b_ctx || 'unknown';\n"
    "  var out = { ctx: ctx, shim: (typeof window.__pweb_invoke),\n"
    "              webview: (typeof window.__webview__), raw: false,\n"
    "              origin: '?', shimThrew: null, rawThrew: null };\n"
    "  try { out.origin = String(location.origin); } catch (e) {}\n"
    "  try { out.raw = !!(window.chrome && window.chrome.webview &&\n"
    "        typeof window.chrome.webview.postMessage === 'function'); }\n"
    "  catch (e) { out.raw = false; }\n"
    "  try {\n"
    "    if (typeof window.__pweb_invoke === 'function') {\n"
    "      window.__pweb_invoke('shim.' + ctx, null);\n"
    "    }\n"
    "  } catch (e) { out.shimThrew = String(e); }\n"
    "  try {\n"
    "    if (out.raw) {\n"
    "      window.chrome.webview.postMessage(JSON.stringify({\n"
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
    "      try { self.raw = !!(window.chrome && window.chrome.webview &&\n"
    "        typeof window.chrome.webview.postMessage === 'function'); }\n"
    "      catch (e) {}\n"
    "      try { window.__pweb_invoke('shim.top-trusted', null); }\n"
    "      catch (e) { self.shimThrew = String(e); }\n"
    "      try { window.chrome.webview.postMessage(JSON.stringify({\n"
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

/* The navigation-coverage driver.
 *
 * TWO STRUCTURAL RULES, both learned from a first run that measured the wrong
 * thing:
 *
 *  1. IT MAKES NO NATIVE CALL until its final report. An earlier revision
 *     announced each case through a binding, and every subsequent navigation
 *     then read as user-initiated because the binding's promise resolution
 *     runs through ExecuteScript, which carries a user gesture. Cases are
 *     therefore attributed NATIVELY, by their unique URI (CaseForUri).
 *  2. THE DESTRUCTIVE CASES RUN IN A TRUSTED SUBFRAME. A redirect or a
 *     download driven from the top frame replaces the document and kills the
 *     driver - the first run died exactly there and lost fourteen cases. The
 *     hook sees a subframe redirect identically, and the page survives to
 *     finish the matrix. */
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
 * Each of these is a WHOLE PHASE with a fresh WebView and a page that makes
 * no native call before the navigation it is measuring, so the recorded
 * IsUserInitiated belongs to that navigation and to nothing else. */

/* (a) plain script navigation from a timer: no gesture, no native call. */
constexpr char kActPlainJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'https://example.invalid/act-plain';\n"
    "}, 400);\n";

/* (b) script navigation in the continuation of a native binding promise -
 *     the shape every RPC-driven PWeb page actually has. */
constexpr char kActBindJs[] =
    "setTimeout(function () {\n"
    "  window.__cap8b_ping('ping.act-bind').then(function () {\n"
    "    location.href = 'https://example.invalid/act-after-bind';\n"
    "  }, function () {\n"
    "    location.href = 'https://example.invalid/act-after-bind';\n"
    "  });\n"
    "}, 400);\n";

/* (c) navigation performed by script the HOST injected (webview_eval). The
 *     page itself does nothing; the native side drives it. */
constexpr char kActEvalJs[] = "window.__cap8b_ready = true;\n";

/* The redirect controls, top-frame, one per phase because a redirect that IS
   followed replaces the document.
     - external: the 302 points out of pweb://, and the question is whether a
       navigation hook ever sees the target;
     - internal: the 302 points at another pweb:// authority, which stays
       inside the resource filter, so the handler being asked for the target
       proves the redirect was FOLLOWED. Without that second probe, "no event
       for the target" and "the redirect was never followed" are
       indistinguishable - and they have opposite security meanings. */
constexpr char kRedirectExternalJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'pweb://app/redirect-external';\n"
    "}, 400);\n";

constexpr char kRedirectInternalJs[] =
    "setTimeout(function () {\n"
    "  location.href = 'pweb://app/redirect-internal';\n"
    "}, 400);\n";

/* (d) a REAL user gesture: the page focuses an anchor and the native side
 *     sends a genuine Enter key to the foreground window. */
constexpr char kActClickJs[] =
    "document.body.style.margin = '0';\n"
    "var a = document.createElement('a');\n"
    "a.href = 'https://example.invalid/act-real-click';\n"
    "a.id = 'realclick'; a.textContent = 'real click';\n"
    "a.style.cssText = 'position:fixed;left:0;top:0;width:400px;"
    "height:200px;background:#0a0;display:block';\n"
    "document.body.appendChild(a);\n"
    "a.focus();\n";

/* The CSP driver. Each row is an INDEPENDENT observable: a directive that is
   silently not enforced must show up as a row that LOADED, never as an
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
    "  /* THE LOCAL-SCHEME FRAMES, which frame-src may not govern at all.\n"
    "     CSP treats about:blank and data: as local schemes, and an\n"
    "     about:blank child INHERITS the parent's origin - so if frame-src\n"
    "     does not stop them, a frame that CSP was assumed to have removed\n"
    "     still exists, and on an engine where the raw transport reaches\n"
    "     native from every frame that is not an academic distinction. */\n"
    "  var fb = document.createElement('iframe');\n"
    "  fb.src = 'about:blank';\n"
    "  document.body.appendChild(fb);\n"
    "  var fd = document.createElement('iframe');\n"
    "  fd.src = 'data:text/html,cap8b-csp-data-frame';\n"
    "  document.body.appendChild(fd);\n"
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
    "  /* For the local-scheme frames the violation report is not the whole\n"
    "     answer: reachability of the child document is. An about:blank child\n"
    "     that survives is same-origin with this page, so it can be scripted\n"
    "     into existence as a bridge holder. */\n"
    "  try {\n"
    "    out.rows['frame-about-blank'] =\n"
    "      (fb.contentDocument !== null && fb.contentDocument !== undefined)\n"
    "        ? 'loaded(same-origin child reachable)' : 'blocked';\n"
    "  } catch (e) { out.rows['frame-about-blank'] = 'blocked(threw)'; }\n"
    "  out.rows['frame-data'] = out.violations.some(function (v) {\n"
    "    return v.blocked.indexOf('data') === 0; }) ? 'blocked' : 'unknown';\n"
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

/* The candidate native policy under measurement. Deliberately the profile the
   intent proposes, with ONE stated difference: connect-src 'self' rather than
   'none', because 'none' also blocks SAME-ORIGIN fetch and the repository's
   existing CAP-4 gates fetch their own assets. Whether that difference is
   required is one of the things this probe measures - the same-origin-fetch
   row is what decides it. */
constexpr char kCandidateCsp[] =
    "default-src 'self'; base-uri 'none'; object-src 'none'; "
    "frame-src 'none'; frame-ancestors 'none'; form-action 'none'; "
    "connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; font-src 'self' data:; media-src 'self'; "
    "worker-src 'none'; manifest-src 'self'";

/* ------------------------------------------------------------------ */
/* recorded measurements                                               */
/* ------------------------------------------------------------------ */

struct NavEvent {
  std::string phase;
  std::string caseName;
  std::string hook;
  std::string uri;
  /* userInitiated is meaningful ONLY when userInitiatedKnown is true. The
     distinction is not pedantry: one engine reports a real gesture flag,
     another can only offer a navigation TYPE from which a gesture may be
     inferred, and a third exposes nothing on some hooks. Emitting `false`
     for all three would make a value that was never measured look like a
     measurement that came back negative - the single worst defect an audit
     instrument can have, and the one this field exists to prevent. `basis`
     states which of those a row is. */
  bool userInitiated = false;
  bool userInitiatedKnown = false;
  std::string basis;
  bool redirected = false;
  bool cancelled = false;
  bool bootstrapAllowed = false;
  /* A POLICY hook can refuse the navigation; an OBSERVATION hook only says it
     happened. Counting them together would let a target with more observation
     hooks look like it cancelled more. */
  bool policy = true;
  /* free-form, per-hook: never parsed, only read by a human */
  std::string detail;
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
  /* "enter/<case>" and "leave/<case>" marks the page emits through the
     resource handler - the only progress channel that neither grants a user
     gesture nor dies with the document */
  std::vector<std::string> beacons;
  int cspHeadersEmitted = 0;
  bool downloadHookAvailable = false;
};

Measurements g_m;
std::mutex g_lock;
std::string g_phaseName = "none";
/* When a phase exists to measure ONE navigation, naming it here lets the
   phase end the moment that navigation is observed instead of burning its
   whole watchdog budget. Empty for the multi-case phases. */
std::string g_expectedCase;
std::atomic<int> g_phaseKind{static_cast<int>(PhaseKind::Exposure)};
std::atomic<bool> g_cancelUntrusted{false};
std::atomic<bool> g_cspOn{false};
std::atomic<bool> g_trustedCommitted{false};
webview_t g_webview = nullptr;
std::string *g_reportSlot = nullptr;

/* the phase is finished when the page reported or the watchdog fired */
std::mutex g_wakeLock;
std::condition_variable g_wake;
bool g_phaseDone = false;

void Note(const std::string &s) {
  std::lock_guard<std::mutex> guard(g_lock);
  g_m.notes.push_back(s);
  std::printf("[cap8b] %s\n", s.c_str());
  std::fflush(stdout);
}

/* defined with the corpus, below: case attribution is native and keyed by URI */
std::string CaseForUri(const std::string &uri);
void SignalPhaseDone();

void RecordEvent(NavEvent e) {
  bool satisfied = false;
  {
    std::lock_guard<std::mutex> guard(g_lock);
    e.phase = g_phaseName;
    e.caseName = CaseForUri(e.uri);
    std::printf("[cap8b] event phase=%s case=%s hook=%s user=%d redirect=%d "
                "cancelled=%d bootstrap=%d uri=%s\n",
                e.phase.c_str(), e.caseName.c_str(), e.hook.c_str(),
                e.userInitiated ? 1 : 0, e.redirected ? 1 : 0,
                e.cancelled ? 1 : 0, e.bootstrapAllowed ? 1 : 0, e.uri.c_str());
    std::fflush(stdout);
    satisfied = !g_expectedCase.empty() && (e.caseName == g_expectedCase);
    g_m.events.push_back(std::move(e));
  }
  if (satisfied) {
    /* on the GUI thread already - this is an engine event callback */
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
  std::string extraHeaders; /* CRLF separated, no trailing CRLF */
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
   contaminated the user-activation reading in the first run. Every coverage
   and activation case therefore navigates to a URI that appears nowhere
   else. */
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
   cancelling phase lets through. It is deliberately a prefix test, which is
   exactly what the PRODUCTION classifier is forbidden to do - the product's
   verdict comes from PWebParseAppUri over parsed components. Nothing here is
   a candidate for production. */
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
    out.extraHeaders = "Location: https://example.invalid/redirected";
    return true;
  }
  if (path == "/redirect-internal") {
    out.status = 302;
    out.body = "";
    out.contentType = "text/plain; charset=utf-8";
    out.extraHeaders =
        "Location: pweb://evil/child.html?ctx=redirect-target";
    return true;
  }
  if (path == "/download.bin") {
    out.body = "cap8b-download-payload";
    out.contentType = "application/octet-stream";
    out.extraHeaders = "Content-Disposition: attachment; filename=\"c.bin\"";
    return true;
  }
  if (path == "/metarefresh.html") {
    /* The redirect mechanism that is actually REACHABLE in this
       architecture. MEASURED: a 302 handed back from a WebResourceRequested
       response is not followed at all on this runtime, so it can never be the
       redirect a threat model worries about; a meta refresh inside trusted
       content can, and it is a plain navigation the hook must see. */
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

/* ------------------------------------------------------------------ */
/* bindings                                                            */
/* ------------------------------------------------------------------ */

void SignalPhaseDone() {
  {
    std::lock_guard<std::mutex> guard(g_wakeLock);
    g_phaseDone = true;
  }
  g_wake.notify_all();
}

void BindInvoke(const char *id, const char *req, void * /*arg*/) {
  const std::string label = FirstJsonString(req == nullptr ? "" : req);
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_m.nativeArrivals[label] += 1;
    std::printf("[cap8b] NATIVE ARRIVAL label=%s\n", label.c_str());
    std::fflush(stdout);
  }
  webview_return(g_webview, id, 0, "null");
}

/* The activation control's round trip: it does nothing but resolve, so that
   the navigation performed in its continuation is measured against a binding
   promise and against nothing else. */
void BindPing(const char *id, const char *req, void * /*arg*/) {
  const std::string label = FirstJsonString(req == nullptr ? "" : req);
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_m.nativeArrivals[label] += 1;
  }
  webview_return(g_webview, id, 0, "null");
}

void BindReport(const char *id, const char *req, void * /*arg*/) {
  /* unwrapped here, once: the artifact carries the page's own JSON, not a
     params array wrapping an escaped copy of it */
  const std::string payload = FirstJsonString(req == nullptr ? "" : req);
  webview_return(g_webview, id, 0, "null");
  {
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_reportSlot != nullptr && g_reportSlot->empty()) {
      *g_reportSlot = payload;
    }
  }
  SignalPhaseDone();
  webview_terminate(g_webview); /* on the GUI thread: the documented path */
}

void TerminateOnGuiThread(webview_t w, void * /*arg*/) {
  webview_terminate(w);
}

/* ------------------------------------------------------------------ */
/* hook installation                                                   */
/* ------------------------------------------------------------------ */

struct Registration {
  ICoreWebView2 *core = nullptr;
  ICoreWebView2_4 *core4 = nullptr;
  EventRegistrationToken resource{};
  EventRegistrationToken navigation{};
  EventRegistrationToken frameNavigation{};
  EventRegistrationToken newWindow{};
  EventRegistrationToken download{};
  bool resourceOn = false;
  bool filterOn = false;
  bool navigationOn = false;
  bool frameNavigationOn = false;
  bool newWindowOn = false;
  bool downloadOn = false;
};

ICoreWebView2Environment *g_env = nullptr;

/* Shared by NavigationStarting and FrameNavigationStarting: both carry the
   same args interface, and the ONE behavioural difference is whether a
   trusted authority is enough to be allowed - it is not, in a subframe. */
HRESULT HandleNavigationStarting(ICoreWebView2NavigationStartingEventArgs *args,
                                 bool subframe) {
  NavEvent e;
  e.hook = subframe ? "FrameNavigationStarting" : "NavigationStarting";
  LPWSTR uriW = nullptr;
  if (SUCCEEDED(args->get_Uri(&uriW)) && uriW != nullptr) {
    e.uri = Narrow(uriW);
    CoTaskMemFree(uriW);
  }
  BOOL flag = FALSE;
  if (SUCCEEDED(args->get_IsUserInitiated(&flag))) {
    e.userInitiated = (flag != FALSE);
    e.userInitiatedKnown = true;
    e.basis = "engine:NavigationStartingEventArgs::IsUserInitiated";
  } else {
    e.basis = "unavailable:get_IsUserInitiated failed";
  }
  flag = FALSE;
  if (SUCCEEDED(args->get_IsRedirected(&flag))) {
    e.redirected = (flag != FALSE);
  }

  if (g_cancelUntrusted.load()) {
    if (subframe) {
      /* MEASUREMENT policy, deliberately WEAKER than the production rule:
         untrusted subframes are cancelled, trusted ones are allowed. The
         production rule denies every subframe, but enforcing that here would
         cancel the trusted FIRST LEG of the redirect and download probes and
         those two cases would silently never run - which is exactly what an
         earlier revision did. That every subframe CAN be cancelled is already
         established by the trusted-subframe row of this same table. */
      if (!IsAuditTrusted(e.uri)) {
        args->put_Cancel(TRUE);
        e.cancelled = true;
      }
    } else if (IsAuditTrusted(e.uri)) {
      g_trustedCommitted.store(true);
    } else if (e.uri == "about:blank" && !g_trustedCommitted.load()) {
      /* the single-use engine bootstrap exception, measured rather than
         assumed: if the engine never needs it, no event will carry it */
      e.bootstrapAllowed = true;
    } else {
      args->put_Cancel(TRUE);
      e.cancelled = true;
    }
  } else if (IsAuditTrusted(e.uri)) {
    g_trustedCommitted.store(true);
  }
  RecordEvent(std::move(e));
  return S_OK;
}

HRESULT InstallHooks(Registration &reg) {
  ICoreWebView2 *core = reg.core;

  HRESULT hr = core->AddWebResourceRequestedFilter(
      L"pweb://*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  if (FAILED(hr)) {
    return hr;
  }
  reg.filterOn = true;

  hr = core->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [](ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args)
              -> HRESULT {
            ComPtr<ICoreWebView2WebResourceRequest> request;
            if (FAILED(args->get_Request(&request)) || !request) {
              return S_OK;
            }
            LPWSTR uriW = nullptr;
            if (FAILED(request->get_Uri(&uriW)) || uriW == nullptr) {
              return S_OK;
            }
            const std::string uri = Narrow(uriW);
            CoTaskMemFree(uriW);

            Asset asset;
            const bool found = CorpusFor(uri, asset);
            std::string headers =
                "Content-Type: " +
                (found ? asset.contentType
                       : std::string{"text/plain; charset=utf-8"}) +
                "\r\nCache-Control: no-store";
            if (found && !asset.extraHeaders.empty()) {
              headers += "\r\n" + asset.extraHeaders;
            }
            /* The native policy under test rides on TRUSTED HTML only - the
               same rule production would use - so the hostile authority never
               receives it and can never be mistaken for a protected one. */
            const bool trustedHtml =
                found && g_cspOn.load() &&
                asset.contentType.rfind("text/html", 0) == 0 &&
                IsAuditTrusted(uri);
            if (trustedHtml) {
              headers += std::string{"\r\nContent-Security-Policy: "} +
                         kCandidateCsp +
                         "\r\nX-Content-Type-Options: nosniff"
                         "\r\nReferrer-Policy: no-referrer";
              std::lock_guard<std::mutex> guard(g_lock);
              g_m.cspHeadersEmitted += 1;
            }

            if (asset.body.size() > UINT_MAX) {
              return S_OK;
            }
            ComPtr<IStream> stream;
            stream.Attach(SHCreateMemStream(
                found ? reinterpret_cast<const BYTE *>(asset.body.data())
                      : nullptr,
                found ? static_cast<UINT>(asset.body.size()) : 0u));
            if (!stream) {
              return S_OK;
            }
            const int status = found ? asset.status : 404;
            const wchar_t *reason =
                found ? (status == 302 ? L"Found" : L"OK") : L"Not Found";
            ComPtr<ICoreWebView2WebResourceResponse> response;
            if (SUCCEEDED(g_env->CreateWebResourceResponse(
                    stream.Get(), status, reason, Widen(headers).c_str(),
                    &response)) &&
                response) {
              args->put_Response(response.Get());
            }
            return S_OK;
          })
          .Get(),
      &reg.resource);
  if (FAILED(hr)) {
    return hr;
  }
  reg.resourceOn = true;

  hr = core->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args)
              -> HRESULT { return HandleNavigationStarting(args, false); })
          .Get(),
      &reg.navigation);
  if (FAILED(hr)) {
    return hr;
  }
  reg.navigationOn = true;

  hr = core->add_FrameNavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args)
              -> HRESULT { return HandleNavigationStarting(args, true); })
          .Get(),
      &reg.frameNavigation);
  if (FAILED(hr)) {
    return hr;
  }
  reg.frameNavigationOn = true;

  hr = core->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args)
              -> HRESULT {
            NavEvent e;
            e.hook = "NewWindowRequested";
            LPWSTR uriW = nullptr;
            if (SUCCEEDED(args->get_Uri(&uriW)) && uriW != nullptr) {
              e.uri = Narrow(uriW);
              CoTaskMemFree(uriW);
            }
            BOOL flag = FALSE;
            if (SUCCEEDED(args->get_IsUserInitiated(&flag))) {
              e.userInitiated = (flag != FALSE);
              e.userInitiatedKnown = true;
              e.basis = "engine:NewWindowRequestedEventArgs::IsUserInitiated";
            } else {
              e.basis = "unavailable:get_IsUserInitiated failed";
            }
            if (g_cancelUntrusted.load()) {
              /* Handled=TRUE with no NewWindow supplied is the documented
                 deny: the engine must not create a window of its own. */
              args->put_Handled(TRUE);
              e.cancelled = true;
            }
            RecordEvent(std::move(e));
            return S_OK;
          })
          .Get(),
      &reg.newWindow);
  if (FAILED(hr)) {
    return hr;
  }
  reg.newWindowOn = true;

  if (SUCCEEDED(core->QueryInterface(IID_PPV_ARGS(&reg.core4))) &&
      reg.core4 != nullptr) {
    {
      std::lock_guard<std::mutex> guard(g_lock);
      g_m.downloadHookAvailable = true;
    }
    hr = reg.core4->add_DownloadStarting(
        Callback<ICoreWebView2DownloadStartingEventHandler>(
            [](ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *args)
                -> HRESULT {
              NavEvent e;
              e.hook = "DownloadStarting";
              /* this args interface exposes no user-activation flag at all -
                 recorded as UNKNOWN, never as false */
              e.basis = "unavailable:DownloadStartingEventArgs has no flag";
              ComPtr<ICoreWebView2DownloadOperation> op;
              if (SUCCEEDED(args->get_DownloadOperation(&op)) && op) {
                LPWSTR uriW = nullptr;
                if (SUCCEEDED(op->get_Uri(&uriW)) && uriW != nullptr) {
                  e.uri = Narrow(uriW);
                  CoTaskMemFree(uriW);
                }
              }
              if (g_cancelUntrusted.load()) {
                args->put_Cancel(TRUE);
                args->put_Handled(TRUE);
                e.cancelled = true;
              }
              RecordEvent(std::move(e));
              return S_OK;
            })
            .Get(),
        &reg.download);
    if (FAILED(hr)) {
      Note("add_DownloadStarting failed - download coverage not measured");
    } else {
      reg.downloadOn = true;
    }
  } else {
    Note("ICoreWebView2_4 unavailable - no DownloadStarting on this runtime");
  }
  return S_OK;
}

void RemoveHooks(Registration &reg) {
  if (reg.core == nullptr) {
    return;
  }
  if (reg.downloadOn && reg.core4 != nullptr) {
    reg.core4->remove_DownloadStarting(reg.download);
  }
  if (reg.newWindowOn) {
    reg.core->remove_NewWindowRequested(reg.newWindow);
  }
  if (reg.frameNavigationOn) {
    reg.core->remove_FrameNavigationStarting(reg.frameNavigation);
  }
  if (reg.navigationOn) {
    reg.core->remove_NavigationStarting(reg.navigation);
  }
  if (reg.resourceOn) {
    reg.core->remove_WebResourceRequested(reg.resource);
  }
  if (reg.filterOn) {
    reg.core->RemoveWebResourceRequestedFilter(
        L"pweb://*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  }
  if (reg.core4 != nullptr) {
    reg.core4->Release();
    reg.core4 = nullptr;
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
  std::string *slot;
  int timeoutSeconds;
  /* the single case this phase exists to observe, or "" for the multi-case
     phases that end with a page report */
  const char *expectedCase;
};

/* The two activation controls the PAGE cannot produce for itself: a
   host-injected script navigation, and a genuine keyboard gesture. Both are
   dispatched onto the GUI thread after a delay, from a thread that is joined
   before any native state dies. */
void DriveActEval(webview_t w, void * /*arg*/) {
  webview_eval(w, "location.href = 'https://example.invalid/act-after-eval';");
}

/* A REAL mouse gesture. The page has laid the anchor over a large fixed
   rectangle at the client-area origin precisely so this can click it without
   ever asking the page where it is - a page->native question would itself
   grant the activation being measured. */
void DriveActClick(webview_t w, void * /*arg*/) {
  HWND window = static_cast<HWND>(webview_get_window(w));
  if (window == nullptr) {
    Note("act-real-click: no window handle - gesture not delivered");
    return;
  }
  SetForegroundWindow(window);
  SetActiveWindow(window);

  POINT target{120, 60}; /* well inside the anchor's fixed 400x200 box */
  if (ClientToScreen(window, &target) == 0) {
    Note("act-real-click: ClientToScreen failed - gesture not delivered");
    return;
  }
  const int vsX = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vsY = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vsW = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int vsH = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (vsW <= 0 || vsH <= 0) {
    Note("act-real-click: no virtual screen metrics - gesture not delivered");
    return;
  }
  const LONG nx =
      static_cast<LONG>(((target.x - vsX) * 65535LL) / (vsW - 1));
  const LONG ny =
      static_cast<LONG>(((target.y - vsY) * 65535LL) / (vsH - 1));

  INPUT inputs[3];
  ZeroMemory(inputs, sizeof(inputs));
  for (INPUT &in : inputs) {
    in.type = INPUT_MOUSE;
    in.mi.dx = nx;
    in.mi.dy = ny;
  }
  inputs[0].mi.dwFlags =
      MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE |
                         MOUSEEVENTF_VIRTUALDESK;
  inputs[2].mi.dwFlags =
      MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  const UINT sent = SendInput(3, inputs, sizeof(INPUT));
  Note(std::string{"act-real-click: SendInput delivered "} +
       std::to_string(sent) + " of 3 mouse events at client(120,60)");
}

/* The setup-and-run half. Split from RunPhase so that every early refusal
   still reaches exactly one teardown - the CAP-4W probe uses try/catch for
   the same reason, and a goto chain over COM lifetimes is precisely the shape
   that leaks one reference on the fifth failure path nobody tested. */
bool RunPhaseInner(const Phase &ph, Registration &reg,
                   ComPtr<ICoreWebView2> &core,
                   ComPtr<ICoreWebView2Environment> &env,
                   std::thread &watchdog) {
  /* The controller is BORROWED from the pinned C ABI: method calls only, and
     it is never AddRef'd or Released - exactly the CAP-4W seam rule. */
  auto *controller = static_cast<ICoreWebView2Controller *>(
      webview_get_native_handle(g_webview,
                                WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  if (controller == nullptr) {
    Note("borrowed browser controller unavailable");
    return false;
  }
  if (FAILED(controller->get_CoreWebView2(&core)) || !core) {
    Note("get_CoreWebView2 failed");
    return false;
  }
  reg.core = core.Get();

  /* Where the engine thinks it is BEFORE we navigate: the initial-about:blank
     question, measured rather than assumed. */
  LPWSTR source = nullptr;
  if (SUCCEEDED(core->get_Source(&source)) && source != nullptr) {
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_m.initialSource.empty()) {
      g_m.initialSource = Narrow(source);
    }
    CoTaskMemFree(source);
  }

  ComPtr<ICoreWebView2_2> core2;
  if (SUCCEEDED(core.As(&core2)) && core2) {
    core2->get_Environment(&env);
  }
  if (!env) {
    Note("get_Environment failed");
    return false;
  }
  g_env = env.Get();
  if (g_m.engineVersion.empty()) {
    LPWSTR version = nullptr;
    if (SUCCEEDED(env->get_BrowserVersionString(&version)) &&
        version != nullptr) {
      std::lock_guard<std::mutex> guard(g_lock);
      g_m.engineVersion = Narrow(version);
      CoTaskMemFree(version);
    }
  }

  webview_bind(g_webview, "__pweb_invoke", BindInvoke, nullptr);
  webview_bind(g_webview, "__cap8b_ping", BindPing, nullptr);
  webview_bind(g_webview, "__cap8b_report", BindReport, nullptr);

  if (FAILED(InstallHooks(reg))) {
    Note("InstallHooks failed");
    return false;
  }

  const int seconds = ph.timeoutSeconds;
  const PhaseKind kind = ph.kind;
  watchdog = std::thread([seconds, kind] {
    /* The activation controls need something to happen that the page cannot
       do for itself; both are timed from here and dispatched onto the GUI
       loop, and both are skipped the moment the phase has already ended. */
    if (kind == PhaseKind::ActEval || kind == PhaseKind::ActClick) {
      std::unique_lock<std::mutex> lock(g_wakeLock);
      const bool ended = g_wake.wait_for(lock, std::chrono::milliseconds(2000),
                                         [] { return g_phaseDone; });
      lock.unlock();
      if (!ended) {
        webview_dispatch(g_webview,
                         (kind == PhaseKind::ActEval) ? DriveActEval
                                                      : DriveActClick,
                         nullptr);
      }
    }
    std::unique_lock<std::mutex> lock(g_wakeLock);
    if (!g_wake.wait_for(lock, std::chrono::seconds(seconds),
                         [] { return g_phaseDone; })) {
      lock.unlock();
      Note("watchdog fired - the phase did not report in time");
      webview_dispatch(g_webview, TerminateOnGuiThread, nullptr);
    }
  });

  webview_set_size(g_webview, 900, 650, WEBVIEW_HINT_NONE);
  webview_navigate(g_webview, ph.startUri);
  webview_run(g_webview);
  return true;
}

bool RunPhase(const Phase &ph) {
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_phaseName = ph.name;
    g_expectedCase = ph.expectedCase;
  }
  {
    std::lock_guard<std::mutex> guard(g_wakeLock);
    g_phaseDone = false;
  }
  g_phaseKind.store(static_cast<int>(ph.kind));
  g_cspOn.store(ph.cspOn);
  g_cancelUntrusted.store(ph.cancelUntrusted);
  g_trustedCommitted.store(false);
  g_reportSlot = ph.slot;

  g_webview = webview_create(0, nullptr);
  if (g_webview == nullptr) {
    Note("webview_create returned null - no WebView2 runtime or no session");
    return false;
  }

  Registration reg;
  ComPtr<ICoreWebView2> core;
  ComPtr<ICoreWebView2Environment> env;
  std::thread watchdog;
  const bool ok = RunPhaseInner(ph, reg, core, env, watchdog);

  /* Whatever happened above, the watchdog is released and joined before any
     native state dies: a thread still holding g_webview across
     webview_destroy is a use-after-free with a timer on it. */
  SignalPhaseDone();
  if (watchdog.joinable()) {
    watchdog.join();
  }
  /* CAP-4W ordering: unregister events and the filter, drop owned COM
     references, and only then destroy - the borrowed controller is never
     touched. */
  RemoveHooks(reg);
  g_env = nullptr;
  env.Reset();
  core.Reset();
  reg.core = nullptr;
  g_reportSlot = nullptr;
  webview_destroy(g_webview);
  g_webview = nullptr;
  return ok;
}

/* ------------------------------------------------------------------ */
/* the artifact                                                        */
/* ------------------------------------------------------------------ */

void WriteJson(const char *path) {
  std::string j = "{\n";
  j += "  \"schema\": 1,\n";
  j += "  \"target\": \"windows-x86_64\",\n";
  j += "  \"engine\": \"WebView2\",\n";
  j += "  \"engine_version\": " + JStr(g_m.engineVersion) + ",\n";
  j += "  \"initial_source_before_navigate\": " + JStr(g_m.initialSource) +
       ",\n";
  j += "  \"csp_headers_emitted\": " + std::to_string(g_m.cspHeadersEmitted) +
       ",\n";
  j += "  \"download_hook_available\": " + JBool(g_m.downloadHookAvailable) +
       ",\n";
  j += "  \"candidate_csp\": " + JStr(kCandidateCsp) + ",\n";
  /* One line a reader can put at the head of the user_initiated column. Two
     targets whose columns look alike but whose semantics differ is exactly
     the silently-vacuous comparison this artifact exists to prevent. */
  j += "  \"user_initiated_semantics\": " +
       JStr("engine-reported gesture flag (IsUserInitiated) on both "
            "navigation hooks and on NewWindowRequested; not exposed at all "
            "on DownloadStarting, emitted there as null") +
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
    j += "    { \"phase\": " + JStr(e.phase) +
         ", \"case\": " + JStr(e.caseName) + ", \"hook\": " + JStr(e.hook) +
         ", \"uri\": " + JStr(e.uri) +
         /* null, not false, when the engine never told us - see NavEvent */
         ", \"user_initiated\": " +
         (e.userInitiatedKnown ? JBool(e.userInitiated)
                               : std::string{"null"}) +
         ", \"user_initiated_basis\": " + JStr(e.basis) +
         ", \"policy\": " + JBool(e.policy) +
         ", \"redirected\": " + JBool(e.redirected) +
         ", \"cancelled\": " + JBool(e.cancelled) +
         ", \"bootstrap_allowed\": " + JBool(e.bootstrapAllowed) +
         ", \"detail\": " + JStr(e.detail) + " }";
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

  FILE *f = nullptr;
  if (fopen_s(&f, path, "wb") != 0 || f == nullptr) {
    std::fprintf(stderr, "[cap8b] cannot write %s\n", path);
    return;
  }
  std::fwrite(j.data(), 1, j.size(), f);
  std::fclose(f);
  std::printf("[cap8b] wrote %s (%zu bytes)\n", path, j.size());
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: cap8b_audit_win <output.json>\n");
    return 2;
  }

  const Phase phases[] = {
      {"exposure", PhaseKind::Exposure, "pweb://app/index.html", false, false,
       &g_m.exposureReport, 30, ""},
      {"coverage", PhaseKind::Coverage, "pweb://app/index.html", false, true,
       &g_m.coverageReport, 90, ""},
      {"csp", PhaseKind::Csp, "pweb://app/csp.html", true, false,
       &g_m.cspReport, 30, ""},
      {"csp-meta", PhaseKind::CspMeta, "pweb://app/csp-meta.html", true, false,
       &g_m.cspMetaReport, 30, ""},
      /* the four user-activation controls: one navigation each, fresh WebView
         each, and the page makes no native call it does not have to */
      {"activation-plain", PhaseKind::ActPlain, "pweb://app/index.html", false,
       true, nullptr, 15, "act-plain"},
      {"activation-bind", PhaseKind::ActBind, "pweb://app/index.html", false,
       true, nullptr, 15, "act-after-bind"},
      {"activation-eval", PhaseKind::ActEval, "pweb://app/index.html", false,
       true, nullptr, 15, "act-after-eval"},
      {"activation-click", PhaseKind::ActClick, "pweb://app/index.html", false,
       true, nullptr, 20, "act-real-click"},
      /* the two redirect controls: the hook is deliberately NOT cancelling,
         so a redirect that would be followed is actually followed */
      {"redirect-external", PhaseKind::RedirectExternal,
       "pweb://app/index.html", false, false, nullptr, 15,
       "redirect-out-of-pweb"},
      {"redirect-internal", PhaseKind::RedirectInternal,
       "pweb://app/index.html", false, false, nullptr, 15, ""},
  };

  int ran = 0;
  for (const Phase &ph : phases) {
    Note(std::string{"=== phase "} + ph.name + " ===");
    if (RunPhase(ph)) {
      ++ran;
    } else {
      Note(std::string{"phase "} + ph.name + " could not run");
    }
    /* REWRITTEN AFTER EVERY PHASE, not once at the end. A single write point
       means any abort, crash, OOM-kill or CI timeout in phase 10 discards the
       nine phases that already succeeded and leaves no artifact at all - the
       exact loss the XTEST fix was made to prevent on Linux, re-created for
       every other failure mode. The document is complete and valid after each
       phase, so whatever the process survives to measure is what survives. */
    WriteJson(argv[1]);
  }

  WriteJson(argv[1]);
  if (ran == 0) {
    /* Nothing was measured at all: that is an instrument failure, not a
       result, and the harness must be able to tell the two apart. */
    std::fprintf(stderr, "[cap8b] CAP8B_AUDIT_WIN_UNAVAILABLE\n");
    return 3;
  }
  /* the denominator comes from the table, never a literal: it read /4 for a
     while after the table grew to ten, which is a marker line quietly lying
     about how much of the audit actually ran */
  std::printf("[cap8b] CAP8B_AUDIT_WIN_DONE phases=%d/%d\n", ran,
              static_cast<int>(sizeof(phases) / sizeof(phases[0])));
  return 0;
}
