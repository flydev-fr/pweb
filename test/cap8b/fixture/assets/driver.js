/* PWeb CAP-8B navigation-matrix driver.
 *
 * Runs in the TRUSTED top document, served over pweb://app by the folder
 * store the navmatrix host mounts. It performs the whole B-matrix in a real
 * window and reports OBSERVED facts through matrix.report; nothing here is
 * inferred from "the page still rendered". The host joins these rows with
 * its native ledger, the guard counters and the opener spy, so a claim the
 * page makes and a claim the native side makes must agree or the run is red.
 *
 * TRANSPORTS. Two are used on purpose:
 *   invoke()     -> window.__pweb_invoke, the bound global the SDK uses.
 *   rawInvoke()  -> window.__webview__.call, the ENGINE message channel
 *                   directly (chrome.webview / webkit.messageHandlers under
 *                   it). CAP-8B MEASURED this raw channel reaches the native
 *                   binding from every frame on Linux and macOS, so the
 *                   trusted top document uses it as a POSITIVE control: it
 *                   proves the channel is wired, which is what makes the
 *                   host's "no CHILD reached it" a real absence rather than
 *                   a broken transport.
 *
 * The child documents (child.html, and a data: inline child) would each
 * call matrix.childExecuted over BOTH transports if they ever executed.
 * frame-src 'none' is what stops them loading at all; the host requires the
 * child_executed counter to stay 0. */

(function () {
  "use strict";

  var startHref = window.location.href;

  var EXTERNAL_NAV = "https://blocked.invalid/cap8b-nav";
  var EXTERNAL_SCRIPT = "https://blocked.invalid/cap8b-probe.js";
  var EXTERNAL_FRAME = "https://blocked.invalid/cap8b-frame.html";
  var TRUSTED_CHILD = "/assets/child.html";
  var DATA_CHILD =
    "data:text/html,<script>(" +
    "function(){try{window.__pweb_invoke&&window.__pweb_invoke(" +
    "'matrix.childExecuted',null);}catch(e){}" +
    "try{window.__webview__&&window.__webview__.call(" +
    "'__pweb_invoke','matrix.childExecuted',null);}catch(e){}})()<\/script>";
  // the two URIs the host's opener spy expects, byte for byte
  var OPEN_HTTPS = "https://example.invalid/cap8b-open";
  var OPEN_MAILTO = "mailto:cap8b@example.invalid";
  // http: is outside the ratified external allowlist, so the native
  // validator must refuse it with invalid_request BEFORE any opener runs
  var OPEN_REFUSED = "http://example.invalid/cap8b-open";

  function invoke(method, args) {
    // window.__pweb_invoke is the upstream-bound global; it returns a
    // promise that rejects with the canonical error envelope on failure
    if (typeof window.__pweb_invoke !== "function") {
      return Promise.reject(new Error("no __pweb_invoke binding"));
    }
    return Promise.resolve(window.__pweb_invoke(method, args == null ? null : args));
  }

  function rawInvoke(method, args) {
    // the ENGINE channel, one level below the bound global: __webview__.call
    // builds the {id, method, params} message and posts it straight into
    // chrome.webview / webkit.messageHandlers via __webview__.post
    if (!window.__webview__ || typeof window.__webview__.call !== "function") {
      return Promise.reject(new Error("no __webview__ raw channel"));
    }
    return Promise.resolve(
      window.__webview__.call("__pweb_invoke", method, args == null ? null : args)
    );
  }

  function delay(ms) {
    return new Promise(function (resolve) {
      window.setTimeout(resolve, ms);
    });
  }

  function setStatus(text) {
    var el = document.getElementById("status");
    if (el) {
      el.textContent = text;
    }
  }

  // CSP violation capture, armed before anything can violate it. WebKit
  // names 'script-src'/'frame-src'; Chromium may name 'script-src-elem' -
  // match the family rather than one spelling, exactly as the React page.
  var cspScriptBlocked = false;
  var cspFrameBlocked = false;
  function onViolation(event) {
    var d = event && event.violatedDirective;
    if (typeof d !== "string") {
      return;
    }
    if (d.indexOf("script-src") === 0) {
      cspScriptBlocked = true;
    }
    if (d.indexOf("frame-src") === 0) {
      cspFrameBlocked = true;
    }
  }
  document.addEventListener("securitypolicyviolation", onViolation);

  function armCspProbes() {
    // an external script - script-src 'self' must refuse it
    var s = document.createElement("script");
    s.src = EXTERNAL_SCRIPT;
    document.head.appendChild(s);
    // an external frame and a servable TRUSTED child frame - frame-src
    // 'none' must refuse BOTH (a privileged WebView hosts one document),
    // and the trusted child is the load-bearing one: it WOULD execute and
    // call matrix.childExecuted if the directive let it in
    [EXTERNAL_FRAME, TRUSTED_CHILD, DATA_CHILD].forEach(function (src) {
      var f = document.createElement("iframe");
      f.src = src;
      document.body.appendChild(f);
    });
  }

  function attemptExternalNavigations() {
    // every one of these must be CANCELLED by the guard with no external
    // side effect; if any were honoured the document would be replaced and
    // matrix.report would never arrive - which the host reads as failure
    try {
      // the return value is evidence: a denied window.open comes back null
      // on every engine here (Handled=TRUE with no NewWindow on WebView2,
      // the create signal answered null on WebKitGTK, no
      // createWebViewWithConfiguration: on WKWebView). A non-null return
      // is a real window proxy the deny failed to prevent.
      var opened = window.open(EXTERNAL_NAV, "_blank");
      report.windowOpenNull = (opened === null || opened === undefined);
    } catch (e) {
      // a refusal that throws is still a refusal, and still no window
      report.windowOpenNull = true;
    }
    try {
      var a = document.createElement("a");
      a.href = EXTERNAL_NAV;
      a.textContent = "x";
      document.body.appendChild(a);
      a.click();
    } catch (e) { /* idem */ }
    try {
      var form = document.createElement("form");
      form.method = "GET";
      form.action = EXTERNAL_NAV;
      document.body.appendChild(form);
      form.submit();
    } catch (e) { /* idem */ }
    try {
      var dl = document.createElement("a");
      dl.href = EXTERNAL_NAV;
      dl.setAttribute("download", "cap8b.bin");
      document.body.appendChild(dl);
      dl.click();
    } catch (e) { /* idem */ }
    try {
      window.location.href = EXTERNAL_NAV;
    } catch (e) { /* idem */ }
  }

  function stillTrusted() {
    return (
      window.location.href === startHref &&
      window.location.protocol === "pweb:"
    );
  }

  var report = {
    allPass: false,
    rawControlOk: false,
    addOk: false,
    cspScriptBlocked: false,
    cspFrameBlocked: false,
    cspHeaderVisible: false,
    cspHeaderNote: "",
    windowOpenNull: false,
    jsUriBlocked: false,
    metaRefreshHeld: false,
    openHttpsOk: false,
    openMailtoOk: false,
    openHttpRefused: false,
    externalNavBlocked: false,
    slowRaceOk: false,
    error: ""
  };

  function isEnvelope(err, code) {
    return err && typeof err === "object" && err.code === code;
  }

  (function run() {
    // arm the passive probes first so their violations are queued while the
    // active steps below drain the task queue
    armCspProbes();

    // 1) the RAW-channel positive control from the trusted top document
    rawInvoke("matrix.rawControl", null)
      .then(function () {
        report.rawControlOk = true;
        // 2) an ordinary RPC through the bound global
        return invoke("matrix.add", { a: 20, b: 22 });
      })
      .then(function (sum) {
        report.addOk = sum === 42;
        // 2b) the unconditional-CSP rule, pinned at the ENGINE boundary: a
        // same-origin fetch of a NON-HTML asset must come back carrying the
        // native Content-Security-Policy header. This is the exact
        // regression a media-type-gated header path would reintroduce, and
        // a same-origin response exposes every header to fetch(), so an
        // absence here is an absence on the wire, not a CORS filter.
        return fetch("/assets/child.js", { cache: "no-store" }).then(
          function (res) {
            var v = null;
            try {
              v = res.headers.get("content-security-policy");
            } catch (e) {
              v = null;
            }
            report.cspHeaderVisible = !!(res.ok && v && v.length > 0);
            report.cspHeaderNote = report.cspHeaderVisible
              ? "present"
              : "absent-or-hidden (status " + res.status + ")";
          },
          function () {
            report.cspHeaderVisible = false;
            report.cspHeaderNote = "same-origin fetch failed";
          }
        );
      })
      .then(function () {
        // 3) capability-authorized external opens: https and mailto succeed
        // (the CAP-8A policy allows external.open, then the native validator
        // accepts the allowlisted scheme and the spy counts the call)
        return invoke("pweb.openExternal", { url: OPEN_HTTPS });
      })
      .then(function () {
        report.openHttpsOk = true;
        return invoke("pweb.openExternal", { url: OPEN_MAILTO });
      })
      .then(function () {
        report.openMailtoOk = true;
        // 4) a NON-allowlisted scheme: invalid_request/400, opener untouched
        return invoke("pweb.openExternal", { url: OPEN_REFUSED }).then(
          function () {
            report.openHttpRefused = false; // a success here is a defect
          },
          function (err) {
            report.openHttpRefused = isEnvelope(err, "invalid_request");
          }
        );
      })
      .then(function () {
        // 5) the RPC / navigation race: start a slow worker call, then
        // immediately attempt an external navigation. The navigation is
        // cancelled and the invocation still completes exactly once.
        var slow = invoke("matrix.slow", { spin: 1 });
        attemptExternalNavigations();
        return slow.then(function (r) {
          report.slowRaceOk =
            !!r && r.done === true && stillTrusted();
        });
      })
      .then(function () {
        // 5b) a top-level meta refresh out of pweb:// - MEASURED observable
        // and cancellable where the engine schedules it at all. An honoured
        // refresh replaces this document and matrix.report never arrives.
        try {
          var meta = document.createElement("meta");
          meta.httpEquiv = "refresh";
          meta.content = "0;url=" + EXTERNAL_NAV;
          document.head.appendChild(meta);
        } catch (e) { /* a refusal that throws is still a refusal */ }
        // 5c) a javascript: URI with a side-effect flag. MEASURED (W2a): no
        // navigation event fires for it - the native CSP (script-src 'self',
        // no 'unsafe-inline') is what stops the execution, so the flag
        // staying unset is a CSP fact, not a classifier fact.
        try {
          window.location.href = "javascript:window.__cap8b_js=1";
        } catch (e) { /* idem */ }
        // long enough for a zero-delay refresh timer and the js: URI to
        // have fired if either was going to
        return delay(700);
      })
      .then(function () {
        report.jsUriBlocked = window.__cap8b_js === undefined;
        report.metaRefreshHeld = stillTrusted();
        // 6) a real native round-trip is a yield the page can PROVE
        // happened, so a still-pending async navigation has had its chance
        return invoke("pweb.echo", { navprobe: 1 });
      })
      .then(function () {
        report.externalNavBlocked = stillTrusted();
        // read the CSP outcomes as late as possible - every await above has
        // let the violation queue drain
        report.cspScriptBlocked = cspScriptBlocked;
        report.cspFrameBlocked = cspFrameBlocked;
        report.allPass =
          report.rawControlOk &&
          report.addOk &&
          report.cspScriptBlocked &&
          report.cspFrameBlocked &&
          report.windowOpenNull &&
          report.jsUriBlocked &&
          report.metaRefreshHeld &&
          report.openHttpsOk &&
          report.openMailtoOk &&
          report.openHttpRefused &&
          report.externalNavBlocked &&
          report.slowRaceOk;
        setStatus(report.allPass ? "NAV MATRIX PASS (page)" : "NAV MATRIX FAIL (page)");
      })
      .catch(function (err) {
        report.error =
          err && err.message
            ? String(err.message)
            : typeof err === "object"
            ? JSON.stringify(err)
            : String(err);
        setStatus("NAV MATRIX ERROR: " + report.error);
      })
      .then(function () {
        document.removeEventListener("securitypolicyviolation", onViolation);
        // the host latches the FIRST report and then terminates the window
        return invoke("matrix.report", report).catch(function () {
          /* the report channel itself failing is the host's to notice */
        });
      });
  })();
})();
