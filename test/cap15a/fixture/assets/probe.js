/* CAP-15A outbound-network probe driver - THROWAWAY MEASUREMENT INSTRUMENT.
 *
 * Runs in the trusted top document over pweb://app and measures, row by row,
 * what the ENGINE lets a privileged page do towards a remote origin, and what
 * the NATIVE door (pweb.fetch through the runtime-command layer) does instead.
 *
 * Every row records an OBSERVED fact and its evidence. Nothing is inferred
 * from "the page still works": a refusal is classified by the
 * securitypolicyviolation event that named it, or by the absence of one, and
 * the server's own JSONL log is the independent witness for anything the page
 * is not allowed to read (no-cors requests, beacons, redirect targets).
 *
 * The same driver runs in BOTH host modes:
 *   baseline  the shipped PWEB_NATIVE_CSP, connect-src 'self'
 *   widened   a throwaway shim whose connect-src also names origin A
 * so every difference in the two reports is exactly the one-token widening.
 */
(function () {
  "use strict";

  var rows = [];
  var cfg = null;
  var violations = [];

  function invoke(method, args) {
    if (typeof window.__pweb_invoke !== "function") {
      return Promise.reject(new Error("no __pweb_invoke binding"));
    }
    return Promise.resolve(window.__pweb_invoke(method, args == null ? null : args));
  }

  function delay(ms) {
    return new Promise(function (r) { window.setTimeout(r, ms); });
  }

  function setStatus(t) {
    var el = document.getElementById("status");
    if (el) el.textContent = t;
  }

  document.addEventListener("securitypolicyviolation", function (e) {
    violations.push({
      directive: String(e.violatedDirective || ""),
      blocked: String(e.blockedURI || "")
    });
  });

  /* did the CSP name this URL? Chromium truncates blockedURI for a
   * cross-origin resource to its origin, WebKit reports more, so the match is
   * a prefix test in either direction. */
  function cspNamed(url) {
    for (var i = 0; i < violations.length; i += 1) {
      var b = violations[i].blocked;
      if (!b) continue;
      if (url.indexOf(b) === 0 || b.indexOf(url) === 0) return violations[i].directive;
    }
    return null;
  }

  function row(id, verdict, detail) {
    rows.push({ id: id, verdict: verdict, detail: detail === undefined ? "" : String(detail) });
  }

  function jrow(id, verdict, obj) {
    rows.push({ id: id, verdict: verdict, detail: JSON.stringify(obj) });
  }

  /* ------------------------------------------------------------------ M1 */

  async function probeFetch(id, url, init) {
    try {
      var res = await fetch(url, init || {});
      var text = "";
      try { text = await res.text(); } catch (e) { text = ""; }
      var body = null;
      try { body = JSON.parse(text); } catch (e) { body = null; }
      jrow(id, res.ok ? "ok" : "http-" + res.status, {
        status: res.status,
        // the probe server answers {saw:{...}}; a PUBLIC target answers its
        // own shape, so the raw head is kept whenever `saw` is absent - the
        // measurement is what the SERVER saw, and it must survive a body
        // this driver does not know
        saw: body && body.saw ? body.saw : null,
        bodyHead: body && body.saw ? null : text.slice(0, 500)
      });
      return body;
    } catch (e) {
      // a fetch rejection is one of two very different things; the violation
      // log is what tells them apart
      await delay(30);
      var d = cspNamed(url);
      jrow(id, d ? "blocked-csp" : "blocked-cors-or-network", {
        directive: d,
        error: String(e && e.message ? e.message : e)
      });
      return null;
    }
  }

  function probeXhr(id, url) {
    return new Promise(function (resolve) {
      var x = new XMLHttpRequest();
      var done = false;
      function finish(verdict, detail) {
        if (done) return;
        done = true;
        row(id, verdict, detail);
        resolve();
      }
      try {
        x.open("GET", url, true);
        x.onload = function () { finish("ok", "status=" + x.status + " body=" + String(x.responseText).slice(0, 160)); };
        x.onerror = function () {
          var d = cspNamed(url);
          finish(d ? "blocked-csp" : "blocked-cors-or-network", d ? "directive=" + d : "onerror");
        };
        x.ontimeout = function () { finish("timeout", ""); };
        x.timeout = 4000;
        x.send();
      } catch (e) {
        finish("threw", String(e && e.message ? e.message : e));
      }
    });
  }

  /* ------------------------------------------------------------------ M2 */

  function probeWs(id, url) {
    return new Promise(function (resolve) {
      var done = false;
      var got = [];
      function finish(verdict, detail) {
        if (done) return;
        done = true;
        row(id, verdict, detail);
        resolve();
      }
      var ws;
      try {
        ws = new WebSocket(url);
      } catch (e) {
        var d0 = cspNamed(url);
        finish(d0 ? "blocked-csp" : "threw", String(e && e.message ? e.message : e));
        return;
      }
      ws.onopen = function () { try { ws.send("ping-from-page"); } catch (e) {} };
      ws.onmessage = function (ev) {
        got.push(String(ev.data).slice(0, 60));
        if (got.length >= 2) {
          try { ws.close(); } catch (e) {}
          finish("ok", "frames=" + JSON.stringify(got));
        }
      };
      ws.onerror = function () {
        var d = cspNamed(url);
        finish(d ? "blocked-csp" : "error", (d ? "directive=" + d + " " : "") + "frames=" + JSON.stringify(got));
      };
      ws.onclose = function () {
        var d = cspNamed(url);
        finish(got.length ? "ok-partial" : (d ? "blocked-csp" : "closed"),
          (d ? "directive=" + d + " " : "") + "frames=" + JSON.stringify(got));
      };
      window.setTimeout(function () {
        try { ws.close(); } catch (e) {}
        finish("timeout", "frames=" + JSON.stringify(got));
      }, 2500);
    });
  }

  function probeSse(id, url) {
    return new Promise(function (resolve) {
      var done = false;
      var got = [];
      function finish(verdict, detail) {
        if (done) return;
        done = true;
        row(id, verdict, detail);
        resolve();
      }
      var es;
      try {
        es = new EventSource(url);
      } catch (e) {
        var d0 = cspNamed(url);
        finish(d0 ? "blocked-csp" : "threw", String(e && e.message ? e.message : e));
        return;
      }
      es.onmessage = function (ev) {
        got.push(String(ev.data).slice(0, 40));
        if (got.length >= 3) {
          es.close();
          finish("ok", "events=" + JSON.stringify(got));
        }
      };
      es.onerror = function () {
        var d = cspNamed(url);
        es.close();
        finish(got.length ? "ok-partial" : (d ? "blocked-csp" : "error"),
          (d ? "directive=" + d + " " : "") + "events=" + JSON.stringify(got));
      };
      window.setTimeout(function () {
        try { es.close(); } catch (e) {}
        finish(got.length ? "ok-partial" : "timeout", "events=" + JSON.stringify(got));
      }, 2500);
    });
  }

  /* ------------------------------------------------------------------ M5 */

  function probeSubresource(id, kind, url) {
    return new Promise(function (resolve) {
      var done = false;
      function finish(verdict, detail) {
        if (done) return;
        done = true;
        row(id, verdict, detail);
        resolve();
      }
      var el;
      if (kind === "img") {
        el = document.createElement("img");
        el.onload = function () { finish("loaded", "naturalWidth=" + el.naturalWidth); };
        el.onerror = function () {
          var d = cspNamed(url);
          finish(d ? "blocked-csp" : "error", d ? "directive=" + d : "onerror");
        };
      } else {
        el = document.createElement("script");
        el.onload = function () { finish("loaded", ""); };
        el.onerror = function () {
          var d = cspNamed(url);
          finish(d ? "blocked-csp" : "error", d ? "directive=" + d : "onerror");
        };
      }
      el.src = url;
      document.getElementById("sink").appendChild(el);
      window.setTimeout(function () {
        var d = cspNamed(url);
        finish(d ? "blocked-csp" : "timeout", d ? "directive=" + d : "");
      }, 2500);
    });
  }

  /* ------------------------------------------------------------------ M4 */

  async function nativeFetch(id, args) {
    var t0 = performance.now();
    try {
      var r = await invoke("pweb.fetch", args);
      var ms = Math.round(performance.now() - t0);
      jrow(id, "ok", {
        pageMs: ms,
        status: r && r.status,
        nativeMs: r && r.ms,
        bytes: r && r.bytes,
        truncated: r && r.truncated,
        saw: r && r.bodyText ? (function () {
          try { return JSON.parse(r.bodyText).saw; } catch (e) { return null; }
        })() : null,
        bodyHead: r && r.bodyText ? String(r.bodyText).slice(0, 120) : null
      });
      return r;
    } catch (e) {
      var ms2 = Math.round(performance.now() - t0);
      jrow(id, "rejected", {
        pageMs: ms2,
        code: e && e.code ? e.code : null,
        message: e && e.message ? String(e.message) : String(e)
      });
      return null;
    }
  }

  async function latencySeries(id, fn, n) {
    var samples = [];
    for (var i = 0; i < n; i += 1) {
      var t0 = performance.now();
      var ok = true;
      try { await fn(); } catch (e) { ok = false; }
      samples.push({ ms: Math.round((performance.now() - t0) * 100) / 100, ok: ok });
    }
    var okms = samples.filter(function (s) { return s.ok; }).map(function (s) { return s.ms; });
    okms.sort(function (a, b) { return a - b; });
    jrow(id, okms.length ? "ok" : "all-failed", {
      n: n,
      okCount: okms.length,
      min: okms[0] === undefined ? null : okms[0],
      p50: okms.length ? okms[Math.floor(okms.length / 2)] : null,
      max: okms.length ? okms[okms.length - 1] : null
    });
  }

  /* ------------------------------------------------------------------- */

  async function run() {
    cfg = await invoke("probe.config", null);
    var A = "http://127.0.0.1:" + cfg.portA;
    var B = "http://127.0.0.1:" + cfg.portB;

    row("env.mode", "info", cfg.mode);
    jrow("env.page", "info", {
      origin: window.origin,
      href: location.href,
      protocol: location.protocol,
      host: location.host,
      secureContext: window.isSecureContext === true,
      crossOriginIsolated: window.crossOriginIsolated === true,
      hasWebSocket: typeof WebSocket === "function",
      hasEventSource: typeof EventSource === "function",
      hasSendBeacon: !!(navigator && navigator.sendBeacon),
      hasSubtleCrypto: !!(window.crypto && window.crypto.subtle),
      hasServiceWorker: !!(navigator && navigator.serviceWorker),
      hasStorage: (function () { try { return !!window.localStorage; } catch (e) { return "threw:" + e.name; } })(),
      ua: navigator.userAgent
    });

    /* --- M1: what the engine puts on the wire, and whether CORS passes --- */
    await probeFetch("m1.simple.acao-origin", A + "/echo?acao=origin");
    await probeFetch("m1.simple.acao-star", A + "/echo?acao=star");
    await probeFetch("m1.simple.acao-null", A + "/echo?acao=null");
    await probeFetch("m1.simple.acao-none", A + "/echo?acao=none");
    await probeFetch("m1.preflighted.post", A + "/echo?acao=origin", {
      method: "POST",
      headers: { "content-type": "application/json", "x-cap15a": "1" },
      body: JSON.stringify({ probe: "preflight" })
    });
    await probeFetch("m1.preflight-refused", A + "/echo?acao=none", {
      method: "POST",
      headers: { "content-type": "application/json", "x-cap15a": "1" },
      body: "{}"
    });
    await probeXhr("m1.xhr", A + "/echo?acao=origin");
    // the origin NOTHING names: the control that proves connect-src still governs
    await probeFetch("m1.unnamed-origin", B + "/echo?acao=star");

    if (cfg.publicHttps) {
      await probeFetch("m1.public-https", cfg.publicHttps);
    } else {
      row("m1.public-https", "na", "no public target configured");
    }

    /* --- M2: WebSocket and EventSource under the same widening ---------- */
    await probeWs("m2.ws.named", "ws://127.0.0.1:" + cfg.portA + "/ws");
    await probeWs("m2.ws.unnamed", "ws://127.0.0.1:" + cfg.portB + "/ws");
    await probeSse("m2.sse.acao-origin", A + "/sse?acao=origin");
    await probeSse("m2.sse.acao-none", A + "/sse?acao=none");

    /* --- M3: cookies, credentials, redirects ---------------------------- */
    var docCookie;
    try {
      document.cookie = "c15a_page=1; path=/";
      docCookie = "write-ok read=" + JSON.stringify(document.cookie);
    } catch (e) {
      docCookie = "threw:" + String(e && e.message ? e.message : e);
    }
    row("m3.document-cookie", "info", docCookie);
    await probeFetch("m3.setcookie.credentialed", A + "/setcookie?acao=origin&acac=1", {
      credentials: "include"
    });
    await probeFetch("m3.cookiecheck.credentialed", A + "/cookiecheck?acao=origin&acac=1", {
      credentials: "include"
    });
    await probeFetch("m3.cookiecheck.omit", A + "/cookiecheck?acao=star", { credentials: "omit" });
    // wildcard + credentials is a spec-level refusal: it proves ordinary CORS
    // semantics apply to this scheme rather than something looser
    await probeFetch("m3.credentials-with-star", A + "/echo?acao=star", { credentials: "include" });
    await probeFetch("m3.redirect.same-origin", A + "/redirect?acao=origin&to=" + encodeURIComponent("/echo?acao=origin"));
    // the hole worth measuring: a redirect out of the ONE named origin into an
    // origin the CSP never named
    await probeFetch("m3.redirect.to-unnamed", A + "/redirect?acao=origin&to=" + encodeURIComponent(B + "/echo?acao=star"));

    /* --- M5: what a widened connect-src does NOT widen ------------------ */
    await probeSubresource("m5.remote-img", "img", A + "/img.png");
    await probeSubresource("m5.remote-script", "script", A + "/echo?acao=star");
    // exfiltration shapes that need no server cooperation at all
    var noCors = "unknown";
    try {
      await fetch(A + "/exfil?acao=none", {
        method: "POST",
        mode: "no-cors",
        body: "CAP15A-EXFIL-NOCORS-" + cfg.mode
      });
      noCors = "resolved-opaque";
    } catch (e) {
      await delay(30);
      noCors = cspNamed(A + "/exfil") ? "blocked-csp" : "rejected";
    }
    row("m5.nocors-post", "info", noCors + " (server log is the witness)");
    var beacon = "no-api";
    try {
      if (navigator && navigator.sendBeacon) {
        beacon = navigator.sendBeacon(A + "/exfil?acao=none", "CAP15A-BEACON-" + cfg.mode)
          ? "queued" : "refused";
      }
    } catch (e) {
      beacon = "threw:" + String(e && e.message ? e.message : e);
    }
    row("m5.sendbeacon", "info", beacon + " (server log is the witness)");

    /* --- M4: the native door -------------------------------------------- */
    await nativeFetch("m4.get.echo", { url: A + "/echo?acao=none", method: "GET" });
    await nativeFetch("m4.post.json", {
      url: A + "/echo?acao=none",
      method: "POST",
      headers: { "content-type": "application/json", "x-cap15a": "native" },
      body: JSON.stringify({ probe: "native-post" })
    });
    await nativeFetch("m4.header-refused", {
      url: A + "/echo",
      method: "GET",
      headers: { cookie: "smuggled=1" }
    });
    await nativeFetch("m4.timeout", { url: A + "/slow?ms=4000", method: "GET", timeoutMs: 800 });
    await nativeFetch("m4.unnamed-origin", { url: B + "/echo?acao=star", method: "GET" });
    await nativeFetch("m4.bytes.1mib", { url: A + "/bytes?n=1048576", method: "GET" });
    await nativeFetch("m4.bytes.over-bound", { url: A + "/bytes?n=33554432", method: "GET" });
    if (cfg.publicHttps) {
      await nativeFetch("m4.public-https", { url: cfg.publicHttps, method: "GET" });
    } else {
      row("m4.public-https", "na", "no public target configured");
    }

    await latencySeries("m4.latency.native", function () {
      return invoke("pweb.fetch", { url: A + "/bytes?n=1024", method: "GET" });
    }, 20);
    await latencySeries("m4.latency.engine", function () {
      return fetch(A + "/bytes?n=1024&acao=star").then(function (r) { return r.arrayBuffer(); });
    }, 20);

    // the escape hatch a native-only door leaves for a remote image:
    // bytes over the bridge, then a data: URL, which img-src 'self' data: allows
    var imgVia = "not-attempted";
    var fetched = await invoke("pweb.fetch", { url: A + "/img.png", method: "GET" })
      .catch(function () { return null; });
    if (fetched && fetched.bodyBase64) {
      imgVia = await new Promise(function (resolve) {
        var im = document.createElement("img");
        im.onload = function () { resolve("loaded naturalWidth=" + im.naturalWidth); };
        im.onerror = function () { resolve("data-url-error"); };
        im.src = "data:image/png;base64," + fetched.bodyBase64;
        document.getElementById("sink").appendChild(im);
        window.setTimeout(function () { resolve("timeout"); }, 2000);
      });
    } else {
      imgVia = "native fetch returned no base64 body";
    }
    row("m4.image-via-native", "info", imgVia);

    /* --- the policy is still the authority ------------------------------ */
    await invoke("probe.revokeNetwork", null).catch(function () {});
    await nativeFetch("m4.after-revoke", { url: A + "/echo?acao=none", method: "GET" });

    /* --- CSP outcomes read as late as possible -------------------------- */
    jrow("csp.violations", "info", violations);
    row("csp.header", "info", cfg.cspInEffect);

    setStatus("CAP-15A probe complete (" + rows.length + " rows)");
  }

  run()
    .catch(function (e) {
      row("driver.error", "error", String(e && e.message ? e.message : e));
      setStatus("CAP-15A probe ERROR");
    })
    .then(function () {
      return invoke("probe.report", { mode: cfg ? cfg.mode : "unknown", rows: rows })
        .catch(function () {});
    });
})();
