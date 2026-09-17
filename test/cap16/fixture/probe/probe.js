/*
 * CAP-16 ENGINE PROBE - the page half.
 *
 * No SDK here, on purpose: this page measures the ENGINE, not PWeb's
 * frontend code. The native half (test/cap16/evalprobe.pas) evaluates
 * scripts built by the production PWebSignalScript, and this page reports
 * what arrived:
 *
 *   csp       the page's OWN eval, Function and inline script are refused
 *             by PWEB_NATIVE_CSP, while the native scripts still run
 *   ordering  K scripts evaluated from K separate GUI dispatches, and K
 *             scripts evaluated back to back inside ONE dispatch, arrive
 *             in the order they were issued - or not, and the row says so
 *   hostile   a topic carrying quotes, a backslash, a closing script tag,
 *             U+2028, U+2029, a NUL, a lone surrogate's bytes, template
 *             syntax and more arrives as exactly the string it was, and
 *             nothing it spells ever runs
 *
 * The hostile table is built from CODE POINTS, never from escape
 * sequences, so the file itself carries no escape that could be mistaken
 * for one of the cases.
 */
(function () {
  "use strict";
  var K = 100;
  var SENTINEL = "__cap16" + "_pwned";
  var received = [];
  var doneAt = 0;

  function cp() {
    return String.fromCodePoint.apply(null, Array.prototype.slice.call(arguments));
  }

  // index -> the string the native side sent, as the page must see it
  var HOSTILE = [
    cp(0x22),
    cp(0x5C),
    "</" + "script><" + "script>window." + SENTINEL + "=1</" + "script>",
    cp(0x2028),
    cp(0x2029),
    cp(0x27),
    cp(0x22) + "]);window." + SENTINEL + "=1;//",
    cp(0x0A),
    "$" + "{window." + SENTINEL + "=1}",
    cp(0x1F600),
    cp(0xFFFD, 0x28),
    cp(0x00),
    "<!" + "--",
    "--" + ">",
    cp(0xFEFF),
    cp(0x85),
    cp(0x60) + ");window." + SENTINEL + "=1;" + cp(0x60),
    cp(0xFFFD, 0xFFFD, 0xFFFD) + "x"
  ];
  var HOSTILE_BASE = 10000;

  window.addEventListener("pweb:signal", function (e) {
    var d = e.detail;
    if (!Array.isArray(d)) {
      received.push({ bad: true });
      return;
    }
    for (var i = 0; i < d.length; i++) {
      received.push({ topic: d[i][0], seq: d[i][1], trusted: e.isTrusted === true });
      if (d[i][0] === "cap16.done") {
        doneAt = Date.now();
      }
    }
  });

  function attempt(fn) {
    try {
      fn();
      return "allowed";
    } catch (err) {
      return "blocked";
    }
  }
  var indirectEval = eval;
  var cspEval = attempt(function () { indirectEval("1"); });
  var cspFunction = attempt(function () { return new Function("return 1")(); });
  var inline = document.createElement("script");
  inline.textContent = "window.__cap16_inline = 1;";
  document.head.appendChild(inline);

  function order(topic) {
    var seqs = received.filter(function (r) { return r.topic === topic; })
      .map(function (r) { return r.seq; });
    var inOrder = true;
    for (var i = 1; i < seqs.length; i++) {
      if (seqs[i] <= seqs[i - 1]) {
        inOrder = false;
      }
    }
    return { count: seqs.length, inOrder: inOrder, first: seqs.slice(0, 5) };
  }

  function codePoints(s) {
    var out = [];
    for (var ch of s) {
      out.push(ch.codePointAt(0));
    }
    return out;
  }

  function hostile() {
    var rows = [];
    for (var i = 0; i < HOSTILE.length; i++) {
      var got = received.filter(function (r) { return r.seq === HOSTILE_BASE + i; });
      rows.push({
        index: i,
        arrived: got.length,
        exact: got.length === 1 && got[0].topic === HOSTILE[i],
        codePoints: got.length === 1 ? codePoints(String(got[0].topic)) : []
      });
    }
    return rows;
  }

  function report() {
    var state = document.getElementById("state");
    var h = hostile();
    var result = {
      cspEval: cspEval,
      cspFunction: cspFunction,
      cspInline: window.__cap16_inline === undefined ? "blocked" : "allowed",
      received: received.length,
      malformed: received.filter(function (r) { return r.bad; }).length,
      trustedEvents: received.filter(function (r) { return r.trusted; }).length,
      dispatch: order("cap16.dispatch"),
      burst: order("cap16.burst"),
      k: K,
      hostileCases: HOSTILE.length,
      hostileExact: h.filter(function (r) { return r.exact; }).length,
      hostile: h,
      pwned: window[SENTINEL] !== undefined,
      userAgent: navigator.userAgent
    };
    if (state) {
      state.textContent = "done";
    }
    window.__cap16_probe_report(result);
  }

  function waitDone() {
    if (doneAt !== 0 && Date.now() - doneAt >= 750) {
      report();
      return;
    }
    setTimeout(waitDone, 50);
  }

  setTimeout(function () {
    window.__cap16_probe_ready(K, HOSTILE.length).then(waitDone, waitDone);
  }, 50);
})();
