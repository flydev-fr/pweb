/* PWeb CAP-8C multi-principal driver — the ONE shared trusted corpus.
 *
 * Both privileged windows (Main and Login) load THIS byte-identical driver
 * over pweb://app. It performs the same steps in both, reports raw OBSERVED
 * facts, and never determines its own identity: which principal it runs as
 * is a NATIVE fact the host reads from the invocation context, never
 * something the page can see or influence. That is the whole point of the
 * content-swap — the Main window is deliberately served the login page's
 * bytes and the Login window the main page's bytes, and the outcome still
 * follows the native context, not the document.
 *
 * FORGERY: every RPC argument object below carries forged identity fields
 * (principal / capabilities / trusted). The frozen model gives Args ZERO
 * authorization effect, so Main still computes 42 and Login is still
 * forbidden regardless of what the page claims to be.
 *
 * TRANSPORTS: window.__pweb_invoke is the bound global. The page reports its
 * observations through cap8c.report; the host latches the FIRST report per
 * principal and terminates the run once BOTH windows have reported. */

(function () {
  "use strict";

  // which page bytes this document is (derived from the path, because the
  // CAP-8B native CSP is script-src 'self' - an inline claim script would be
  // refused). It has ZERO authorization effect and is reported only so the
  // host can PROVE which page bytes it loaded into which native context: in
  // the content-swap the Main window is served login.html and the Login
  // window main.html, and the outcome still follows the native context.
  var path = String(window.location.pathname || "");
  var claim = (path.indexOf("login") >= 0) ? "login-page" : "main-page";

  // forged identity fields, smuggled into every argument object. The native
  // context is the only identity truth, so these change nothing.
  var FORGE = {
    principal: "window:main",
    capabilities: ["calculator.add", "external.open", "settings.read",
      "parking.read", "window.control"],
    trusted: true
  };
  function forged(extra) {
    var o = { principal: FORGE.principal, capabilities: FORGE.capabilities,
      trusted: FORGE.trusted };
    if (extra) {
      var k;
      for (k in extra) { if (extra.hasOwnProperty(k)) { o[k] = extra[k]; } }
    }
    return o;
  }

  var startHref = window.location.href;

  var OPEN_HTTPS = "https://example.invalid/cap8c-open";
  var OPEN_MAILTO = "mailto:cap8c@example.invalid";
  var OPEN_REFUSED = "http://example.invalid/cap8c-open"; // outside allowlist
  var EXTERNAL_NAV = "https://blocked.invalid/cap8c-nav";

  function invoke(method, args) {
    if (typeof window.__pweb_invoke !== "function") {
      return Promise.reject(new Error("no __pweb_invoke binding"));
    }
    return Promise.resolve(window.__pweb_invoke(method, args == null ? null : args));
  }

  function codeOf(err) {
    return (err && typeof err === "object" && typeof err.code === "string")
      ? err.code : "throw";
  }

  var report = {
    claim: claim,
    secure: (window.location.protocol === "pweb:"),
    handshakeOk: false,
    addValue: null,     // 42 when the native context authorized it
    addCode: "",        // the error code when it was refused
    settingsOk: false,  // settings.read is held by BOTH window principals -
    settingsCode: "",   // the Login window's ALLOW-side proof
    openHttpsOk: false,
    openHttpsCode: "",
    openMailtoOk: false,
    openMailtoCode: "",
    openHttpCode: "",   // the refusal code for the non-allowlisted scheme
    navBlocked: false,  // the raw external navigation was cancelled in place
    error: ""
  };

  function setStatus(t) {
    var el = document.getElementById("status");
    if (el) { el.textContent = t; }
  }

  (function run() {
    // 1) aliveness: the zero-cap handshake succeeds for EVERY principal,
    //    proving denial is a policy decision and not a broken binding
    invoke("pweb.handshake", forged())
      .then(function () {
        report.handshakeOk = true;
        // 2) CalculatorService.Add with CLEAN numeric args (the real SOA
        //    bridge validates its argument shape strictly). Main -> 42;
        //    Login -> forbidden. The route is the native context's, never
        //    the page's claim: the content-swap loads the "wrong" page into
        //    each context and the outcome still follows the context. The
        //    forged identity fields ride the handshake + openExternal calls
        //    below, which tolerate extra fields, to show they are ignored.
        return invoke("CalculatorService.Add", { a: 20, b: 22 }).then(
          function (sum) { report.addValue = sum; },
          function (err) { report.addCode = codeOf(err); }
        );
      })
      .then(function () {
        // 2b) an ALLOWED capability for BOTH window principals
        //    (settings.read): the Login window's allow-side proof - its
        //    denial evidence above is meaningful only because the same
        //    window demonstrably still holds its own capabilities. Forged
        //    fields ride along here too (the method tolerates extra args).
        return invoke("SettingsService.GetValue", forged({})).then(
          function () { report.settingsOk = true; },
          function (err) { report.settingsCode = codeOf(err); }
        );
      })
      .then(function () {
        // 3) external opens. Main is authorized (external.open) and reaches
        //    the injected opener exactly once each for https + mailto; Login
        //    is forbidden pre-bridge and the opener is never reached.
        return invoke("pweb.openExternal", forged({ url: OPEN_HTTPS })).then(
          function () { report.openHttpsOk = true; },
          function (err) { report.openHttpsCode = codeOf(err); }
        );
      })
      .then(function () {
        return invoke("pweb.openExternal", forged({ url: OPEN_MAILTO })).then(
          function () { report.openMailtoOk = true; },
          function (err) { report.openMailtoCode = codeOf(err); }
        );
      })
      .then(function () {
        // 4) a non-allowlisted scheme: invalid_request for an authorized
        //    principal (Main), forbidden for an unauthorized one (Login) -
        //    either way the opener stays untouched
        return invoke("pweb.openExternal", forged({ url: OPEN_REFUSED })).then(
          function () { report.openHttpCode = "opened"; },
          function (err) { report.openHttpCode = codeOf(err); }
        );
      })
      .then(function () {
        // 5) a RAW external navigation from this trusted page: the CAP-8B
        //    guard on THIS window must cancel it in place with no external
        //    side effect (the opener ledger stays untouched). The zero-cap
        //    echo round trip afterwards is a yield the page can PROVE
        //    happened, so a still-pending navigation has had its chance -
        //    and an honoured one would have replaced this document, in
        //    which case cap8c.report never arrives and the host goes red.
        try { window.location.href = EXTERNAL_NAV; } catch (e) {}
        return invoke("pweb.echo", forged({ navprobe: 1 })).catch(function () {});
      })
      .then(function () {
        report.navBlocked =
          window.location.href === startHref &&
          window.location.protocol === "pweb:";
      })
      .catch(function (err) {
        report.error = (err && err.message) ? String(err.message) : String(err);
      })
      .then(function () {
        setStatus("CAP-8C report (" + claim + ")");
        // the host latches the FIRST report from each principal and
        // terminates once both windows have reported
        return invoke("cap8c.report", report).catch(function () {});
      });
  })();
})();
