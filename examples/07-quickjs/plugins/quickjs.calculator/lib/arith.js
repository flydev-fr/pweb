// CAP-9C1 packaged plugin module. Pure arithmetic: it touches no host
// surface at all, so it proves a resolution edge without proving
// anything about authority.
//
// CAP-9C2 puts the browser-execution marker HERE, and the choice is the
// whole point of the probe. This is the only module in the corpus with
// no import of its own, so it is the only one that would EVALUATE
// cleanly if a WebView ever served it as <script type="module">. Every
// other module would die on an unresolved import before its top level
// ran, and a marker that could not fire proves nothing. The guard means
// the statement is inert under QuickJS - `window` does not exist there,
// which the `env` export asserts separately.

if (typeof window !== 'undefined') {
  window.__PWEB_PLUGIN_SOURCE_EXECUTED_IN_WEBVIEW__ = true;
}

export function sum(a, b) {
  return a + b;
}

export const ORIGIN = 'quickjs.calculator/lib/arith.js';
