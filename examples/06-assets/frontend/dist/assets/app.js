/* PWeb CAP-4 runtime verdict: proves the real frontend loaded over
   pweb://app through IAssetStore (folder or zip), that the document is
   a secure context, and that the unchanged CAP-3 RPC path still
   answers from the asset-loaded page. */
(function () {
  'use strict';

  function invoke(method, args) {
    return window.__pweb_invoke(method, args === undefined ? null : args);
  }

  function report(payload) {
    return invoke('example.report', payload);
  }

  // the deterministic 404 path must be exercised, not assumed: a
  // missing asset, a non-canonical path (trailing dot) and a wrong-case
  // request must all answer status 404 with an EMPTY body
  function expect404(url) {
    return fetch(url).then(function (r) {
      return r.text().then(function (t) {
        return r.status === 404 && t === '';
      });
    }, function () { return false; });
  }

  window.addEventListener('DOMContentLoaded', function () {
    var out = document.getElementById('verdict');
    // two frames so styles are computed after layout settles
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        var marker = document.getElementById('marker');
        var cssOk = marker !== null &&
          getComputedStyle(marker).backgroundColor === 'rgb(8, 122, 46)';
        var secureOk = window.isSecureContext === true;
        Promise.all([
          expect404('/no-such-file'),
          expect404('/index.html.'),
          expect404('/assets/App.js')
        ]).then(function (nf) {
          var notFoundOk = nf[0] && nf[1] && nf[2];
          invoke('CalculatorService.Add', { a: 20, b: 22 }).then(
            function (v) {
              var rpcOk = v === 42;
              var ok = cssOk && secureOk && rpcOk && notFoundOk;
              out.className = ok ? 'ok' : 'bad';
              out.textContent = ok
                ? 'HTML/CSS/JS/secure/404/RPC(42) - PASS'
                : 'FAILED: css=' + cssOk + ' secure=' + secureOk +
                  ' notfound=' + notFoundOk + ' rpc=' + JSON.stringify(v);
              return report({
                ok: ok,
                html: true, // this script only runs off the loaded page
                js: true,
                css: cssOk,
                secure: secureOk,
                notfound: notFoundOk,
                rpc: rpcOk,
                value: v
              });
            },
            function (e) {
              out.className = 'bad';
              out.textContent = 'RPC FAILED: ' + JSON.stringify(e);
              report({
                ok: false, html: true, js: true, css: cssOk,
                secure: secureOk, notfound: notFoundOk, rpc: false,
                error: e
              });
            });
        });
      });
    });
  });
}());
