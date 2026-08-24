/* CAP-8B fixture child body. If a child document ever executes inside the
 * privileged WebView, this fires the tripwire over BOTH the bound global and
 * the raw engine channel - whichever the engine exposes in a subframe. The
 * host requires the child_executed counter to stay 0, so a single arrival
 * here turns the run red. */
(function () {
  "use strict";
  try {
    if (typeof window.__pweb_invoke === "function") {
      window.__pweb_invoke("matrix.childExecuted", null);
    }
  } catch (e) { /* swallowed - the arrival, not the reply, is the signal */ }
  try {
    if (window.__webview__ && typeof window.__webview__.call === "function") {
      window.__webview__.call("__pweb_invoke", "matrix.childExecuted", null);
    }
  } catch (e) { /* idem */ }
})();
