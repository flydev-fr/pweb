# CAP-10C2 — the model-A spike, and why model A is refused

Evidence record for `spec-phase-10-cap10c2-react-dev-loop.md` Design Note 1.
Run on the dev host, 2026-09-03, against the real generated project
`build/cap10b1/stage/demo/frontend` (Vite 8.2.2, Node 24.11.1, React 18.3.1).


The spike ran the real dev server on the real generated project
(`build/cap10b1/stage/demo/frontend`, Vite 8.2.2, Node 24.11.1) and crawled
the served module graph, reading the bytes rather than guessing. **Fifteen
URLs**, the whole set one page load requests, all `200`, all
`text/javascript` but the document:

```
/                                                       text/html   271 B
/@vite/client                                                    204466 B
/src/main.tsx  /src/App.tsx  /src/app.css                1651 / 18354 / 2563 B
/.pweb/sdk/typescript/dist/src/{index,invoke,handshake,errors,types}.js
/node_modules/.vite/deps/react.js?v=c4f669b9                     221790 B
/node_modules/.vite/deps/react-dom_client.js?v=9bb90a87          2593845 B
/node_modules/.vite/deps/react_jsx-dev-runtime.js?v=11560e86      106046 B
/node_modules/.vite/deps/rolldown-runtime-BvCyGRYZ.js?v=f02b60b2    1287 B
/node_modules/vite/dist/client/env.mjs                             3478 B
```

Zero inline scripts; no `eval` requirement observed; the injected tag is
`<script type="module" src="/@vite/client">`. Every **path** is grammar-valid:
`@vite` and `.vite` are ordinary segments and `PWebAssetPathValid` refuses
none of them. Three findings refuse model A anyway, and each is a measurement:

1. **The query is load-bearing and the frozen URI layer cuts it.**
   `PWebParseAppUri` cuts `?` and `#` before decoding. Measured:
   `/src/app.css` returns **2563 bytes of `text/javascript`** and
   `/src/app.css?direct` returns **1938 bytes of `text/css`** — one path, two
   bodies, distinguished only by the query; and `/src/App.tsx` is 18354 bytes
   against `?t=123`'s 18368, which is the shape of every HMR update URL.
   Model A needs the URI layer to preserve and forward the query — a
   relaxation of the frozen grammar.
2. **The MIME type must come from the proxied response.** `/src/App.tsx`,
   `/src/main.tsx` and `/src/app.css` are all served `text/javascript`, while
   `PWebAssetMimeType` derives it from the extension (`.tsx` →
   `application/octet-stream`). A module script answered as octet-stream is
   refused by every engine's MIME check, so model A needs the handler to stop
   deriving the type — a change to the frozen asset-serving path.
3. **HMR would not connect, and there is no hot boundary to connect for.** The
   served client computes `socketProtocol = importMetaUrl.protocol ===
   "https:" ? "wss" : "ws"` and `socketHost =
   ${importMetaUrl.hostname}:${importMetaUrl.port}/`; under `pweb://app` that
   is `ws://app:/?token=…`, unroutable — so model A needs `server.hmr.host`
   and `.port` in the template, i.e. the same supersession model B needs
   **plus** the CSP allowance. And the template ships **no**
   `@vitejs/plugin-react`: no `/@react-refresh` preamble, no Fast Refresh, so
   a `.tsx` edit is a non-accepted update and the client calls
   `location.reload()`. Model A's one advantage over model B does not exist
   for this template today.

**Model A is refused for CAP-10C2** on findings 1 and 2 — each a grammar or
handler relaxation beyond the single ratified `ws://` allowance, which is
exactly the condition the shard's own rule refuses on. Finding 3 is recorded
because it is what an HMR shard would have to solve first.

**Model B — rebuild-and-reload — is chosen**, and §5 records it. The ratified
`ws://127.0.0.1:<native-selected-port>` allowance stays ratified, unused, and
pinned absent from every profile by `check_dev_trust.ps1`.

