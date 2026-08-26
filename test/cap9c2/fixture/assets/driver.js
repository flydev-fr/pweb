/* PWeb CAP-9C2 hostile-package harness driver.
 *
 * Runs in the TRUSTED top document of the real WebView this harness
 * opens. Its whole job is to be a REAL UI that keeps working while the
 * native side loads deliberately broken plugin packages beside it: the
 * harness asserts that a plugin that fails to evaluate, and a plugin
 * that tries to import out of its package root, change nothing here.
 *
 * It reports once through example.report and then answers repeated
 * example.concurrent rounds that the harness drives with webview_eval,
 * so "the UI still returns 42 after the failure" is a fresh invocation
 * over the real transport and never a cached verdict. */

(function () {
  "use strict";

  function invoke(method, args) {
    if (typeof window.__pweb_invoke !== "function") {
      return Promise.reject(new Error("no __pweb_invoke binding"));
    }
    return Promise.resolve(window.__pweb_invoke(method, args == null ? null : args));
  }

  function setStatus(text) {
    var el = document.getElementById("status");
    if (el) {
      el.textContent = text;
    }
  }

  var verdict = {
    ok: false,
    handshake: false,
    secure: window.isSecureContext === true,
    rendered: true,
    rpc: false,
    value: null
  };

  invoke("pweb.handshake", null)
    .then(function (info) {
      verdict.handshake = !!info && info.protocol === 1;
      return invoke("CalculatorService.Add", { a: 20, b: 22 });
    })
    .then(function (value) {
      verdict.value = value;
      verdict.rpc = value === 42;
      verdict.ok = verdict.handshake && verdict.secure && verdict.rpc;
      setStatus(verdict.ok ? "CalculatorService.Add(20, 22) = " + value : "FAILED");
    })
    .catch(function (err) {
      verdict.error = String((err && err.code) || err);
      setStatus("FAILED: " + verdict.error);
    })
    .then(function () {
      return invoke("example.report", verdict);
    })
    .catch(function () {
      /* the report channel itself failing is the harness's problem to notice */
    });
})();
