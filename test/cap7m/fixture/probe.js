/* CAP-7M1 macOS runtime verdict page.
 *
 * THE PAGE STATES EVERY FACT IT IS ASKED ABOUT. Nothing below is inferred
 * from the mere fact that something rendered: the origin, the secure-context
 * classification, the HTTP status of a subresource, the byte-identity of a
 * binary asset, every hostile-URI refusal and the RPC answer are all reported
 * as data, through the PRODUCTION __pweb_invoke binding, and the native
 * harness decides the verdict from what the page said.
 *
 * It is served over pweb://app by the production adapter out of the SAME
 * corpus in both store modes - once from TFolderAssetStore, once from
 * TZipAssetStore - so folder/ZIP parity is a property this gate exercises
 * rather than one it restates.
 */
(function () {
  'use strict';

  function invoke(method, args) {
    return window.__pweb_invoke(method, args === undefined ? null : args);
  }

  /* A refusal on this backend is didFailWithError:, which carries no status
     at all, so fetch() REJECTS. A refusal that somehow arrived as a response
     must still not be ok. Both shapes mean exactly "refused, nothing
     served", which is the claim. */
  function blocked(url) {
    return fetch(url).then(
      function (r) { return r.ok === false; },
      function () { return true; }
    );
  }

  async function run() {
    var out = {};
    var node = document.getElementById('verdict');
    try {
      /* P17: the secure origin, stated by the page. */
      out.protocol = location.protocol;
      out.host = location.host;
      out.origin = location.origin;
      out.secure = window.isSecureContext === true;

      /* the stylesheet loaded as an ordinary subresource and applied */
      out.css = getComputedStyle(node).color === 'rgb(1, 2, 3)';

      /* P5: only NSHTTPURLResponse gives JavaScript a status. A bare
         NSURLResponse loads the resource perfectly and reports status 0. */
      var css = await fetch('pweb://app/probe.css');
      out.subresource = css.ok === true && css.status === 200;

      /* P6: a zero-byte asset is an asset, never a miss. */
      var empty = await fetch('pweb://app/assets/empty.bin');
      var emptyBuf = await empty.arrayBuffer();
      out.zerobyte = empty.ok === true && empty.status === 200 &&
        emptyBuf.byteLength === 0;

      /* P7: 4096 bytes covering every byte value, delivered byte-identically.
         Any truncation, NUL-termination or text conversion fails here. */
      var all = await fetch('pweb://app/assets/allbytes.bin');
      var allBuf = new Uint8Array(await all.arrayBuffer());
      var allOk = all.ok === true && all.status === 200 &&
        allBuf.length === 4096;
      for (var i = 0; allOk && i < allBuf.length; i++) {
        if (allBuf[i] !== (i & 255)) {
          allOk = false;
        }
      }
      out.allbytes = allOk;

      /* P10: query and fragment are cut before the single decode. */
      var q = await fetch('pweb://app/index.html?x=1#y');
      out.query = q.ok === true && q.status === 200;

      /* P9: the hostile matrix, driven from the page. A vector WebKit
         normalises or refuses before the handler is defence in depth and is
         welcome; it is never why a vector is considered handled - the native
         harness cross-checks every observed URI through PWebParseAppUri. */
      out.wronghost = await blocked('pweb://evil/x');
      out.emptyhost = await blocked('pweb:///x');
      out.dotdot = await blocked('pweb://app/../secret');
      out.encdotdot = await blocked('pweb://app/%2e%2e/secret');
      out.dblenc = await blocked('pweb://app/%252e%252e/secret');
      out.backslash = await blocked('pweb://app/a\\b');
      out.nul = await blocked('pweb://app/a%00b');
      out.badpercent = await blocked('pweb://app/a%zz');
      out.pctliteral = await blocked('pweb://app/a%25b');
      out.userinfo = await blocked('pweb://user@app/index.html');
      out.port = await blocked('pweb://app:8080/index.html');
      out.trailingdot = await blocked('pweb://app/index.html.');
      out.wrongcase = await blocked('pweb://app/Index.html');

      /* P11: a missing asset is indistinguishable from every other refusal -
         no reason text, no path, nothing about the filesystem. */
      out.notfound = await blocked('pweb://app/missing.txt');

      /* P20: eight concurrent invocations, each completing exactly once. */
      var echoes = [];
      for (var k = 0; k < 8; k++) {
        echoes.push(invoke('CalculatorService.Add', { a: k, b: k + 1 }));
      }
      var values = await Promise.all(echoes);
      out.concurrency = values.length === 8 &&
        values.every(function (v, idx) { return Number(v) === idx * 2 + 1; });

      /* P19: the unchanged CAP-3 pipeline, from an asset-loaded page. */
      out.rpc = (await invoke('CalculatorService.Add', { a: 20, b: 22 })) === 42;

      /* P20: one forced error must REJECT with its payload intact. */
      out.rejected = false;
      out.payload = null;
      try {
        await invoke('ErrorService.Fail', { go: true });
      } catch (e) {
        out.rejected = true;
        out.payload = (e && e.data && e.data.detail) ? e.data.detail
          : ((e && e.message) ? e.message : String(e));
      }
      out.payloadintact = out.payload === 'payload-intact-42';

      /* P20: deliberately NOT awaited - one invocation is still in flight
         when the shutdown below begins, and teardown has to drain it. */
      invoke('SlowService.Wait', { ms: 400 }).then(function () {},
                                                   function () {});

      out.ok = out.protocol === 'pweb:' && out.host === 'app' &&
        out.origin === 'pweb://app' && out.secure && out.css &&
        out.subresource && out.zerobyte && out.allbytes && out.query &&
        out.wronghost && out.emptyhost && out.dotdot && out.encdotdot &&
        out.dblenc && out.backslash && out.nul && out.badpercent &&
        out.pctliteral && out.userinfo && out.port && out.trailingdot &&
        out.wrongcase && out.notfound && out.concurrency && out.rpc &&
        out.rejected && out.payloadintact;
      node.textContent = out.ok ? 'CAP-7M1 PASS' : 'CAP-7M1 FAIL';
    } catch (e) {
      out.ok = false;
      out.error = String(e);
      node.textContent = 'CAP-7M1 FAIL';
    }
    /* the OBJECT, not JSON.stringify(out): webview serialises the argument
       itself, so a string would arrive double-encoded and every check on the
       native side would silently miss */
    await invoke('example.report', out);
  }

  window.addEventListener('DOMContentLoaded', function () {
    /* two frames so computed style is read after layout settles */
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { run(); });
    });
  });
}());
