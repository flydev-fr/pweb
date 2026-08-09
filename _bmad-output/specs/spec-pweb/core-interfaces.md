# Core interfaces and wire shapes

Companion to `SPEC.md`. No platform or implementation type appears in these signatures.

> **Status: the decomposition is settled; six method sets ratify at Phase 0, the blob method sets at Phase 4b entry.** The table below fixes responsibilities and boundaries for all seven contracts. `IAssetStore` has its concrete signature on record. Writing and ratifying the remaining five Phase 0 method sets (`IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `ICapabilityPolicy`) is a **Phase 0 exit criterion**; the semantics they encode — exactly-once completion, source lifecycle, leases/tokens, discriminated results — are DECIDED in `wire-semantics.md` and `threading-model.md`. The blob contracts freeze their boundary and invariants now and ratify their concrete method sets at Phase 4b entry (see below).

## The seven core contracts

| Interface | Responsibility | Must not reference |
| --- | --- | --- |
| `IWebView` | Window lifecycle, navigation, title, size, script evaluation — all operations GUI-thread-affine unless a method's contract documents otherwise | WebView2, WKWebView, WebKitGTK |
| `IWebViewBinding` | The WebView-flavoured **invocation source**: registering named handlers callable from JS and returning results to them; owns its source lifecycle, its completion sink (`webview_return`), the handle-use lease, and the bind/unbind userdata lifetime | React, Pas2JS, QuickJS |
| `IInvocationBridge` | Turning an invocation (context + canonical method + named arguments) into a service call and its result into a **discriminated Success/Error response**; correlation-free and caller-agnostic | mORMot type names in the signature |
| `IInvocationScheduler` | Enqueuing invocations from **any invocation source** onto the worker pool; per-source backpressure with non-blocking enqueue; exactly-once completion routing to the source's sink; cancellation signalling | Any specific thread-pool implementation, `pweb.webview.*` units |
| `IAssetStore` | Read of a frontend asset by canonical logical path, fail-closed on non-canonical input | ZIP, SynLZ, filesystem paths |
| `IBlobStore` | Ownership, lookup, authorization, streaming and lifetime of bulk binary payloads by opaque handle — `register` / `open` / `read` / `write` / `release` | URI schemes, WebView transports, filesystem paths, platform stream types |
| `ICapabilityPolicy` | Deciding whether a principal may invoke a given canonical method; unknown/unmapped method ⇒ deny; runs before routing | Any concrete policy source (file, manifest format) |

`IAssetStore`, settled — `Exists()` is dropped:

```pascal
IAssetStore = interface
  function TryRead(
    const Path: RawUtf8;
    out Asset: TAssetResponse): Boolean;
end;
```

One lookup instead of two, and no pointless TOCTOU window for `TFolderAssetStore`.

Implementations: `TFolderAssetStore` (dev, over `frontend/dist/`), `TZipAssetStore` (packaging, over `app.zip` / `app.pwb`).

**Asset policy for v1 — DECIDED:** normal frontend application assets (HTML/CSS/JS/icons) are materialised. Large/bulk media is **not supported** as an ordinary `app.pwb` asset in v1; genuinely large data belongs on the blob plane. The bundler warns/errors above a configurable per-asset size threshold. Escape route for bundle-shipped large media: register/expose it through `IBlobStore` and serve it as `pweb://blob/{handle}` rather than as an ordinary `IAssetStore` response.

**Canonical asset paths — DECIDED.** The WebView scheme handler validates and canonicalizes; stores additionally fail closed on non-canonical input:

- forward slashes; no empty, `.`, or `..` segments
- no NUL, no backslash, no drive or UNC prefix
- single percent-decode, then validation; encoded and double-encoded traversal rejected
- Windows device names (`CON`, `NUL`, `COM1`, … including with extensions) and alternate-data-stream forms rejected
- **exact case-sensitive matching on every platform** — development behaviour on Windows (`TFolderAssetStore`) must match ZIP production behaviour, not the case-insensitive filesystem

**Evolution rule:** `TryRead`'s signature is frozen; `TAssetResponse` may evolve **additively** at source level. PWeb v1 promises source-level API compatibility for its Pascal contracts, **not** binary ABI compatibility between separately compiled PWeb framework versions — adding fields to a Pascal record is therefore not claimed to preserve binary ABI.

### Blob side

**Freeze policy — boundary now, method sets at Phase 4b entry.** The architectural boundary is frozen in Phase 0: opaque handles, ownership, lookup, authorization, streaming, metadata, lifetime, release — independent of WebViews and URI schemes. The concrete method sets of

```
IBlobStore
IBlobReader
IBlobWriter
```

are **not** ratified in Phase 0. They are ratified at the **entry gate of Phase 4b**, before any blob implementation, so that real `Range`/upload/resource-handler integration informs the precise streaming API rather than freezing a theoretical method set prematurely.

The direction of that ratification is already fixed — invariants now, signatures later:

- owner-scoped blobs: the owning principal is recorded at registration; the caller principal is checked on open
- handles additionally carry ≥128 bits of cryptographic entropy; adapters never log full handles
- release is logical: open readers keep the backing storage alive; storage is reclaimed after the final reader closes
- readers support the positioned/random access that `Range` requires
- blobs auto-release when their owning principal/source is torn down
- an explicit `native.blobs.release` exists in the SDK

Backing sources: memory, file, archive, generated stream.

`IBlobStore` knows nothing about URLs. The scheme translation is a separate, WebView-side concern:

```
TWebViewBlobProtocol
        │
        ├── pweb://blob/{handle}
        │
        ▼
    IBlobStore
```

That separation is what lets a QuickJS plugin or a native client consume the same blob without inventing a URL for it.

## Upstream C ABI surface (CAP-1)

All 14 entry points are bound with zero mORMot abstraction in `src/lib/`:

```
webview_create        webview_destroy       webview_run
webview_terminate     webview_dispatch      webview_set_title
webview_set_size      webview_navigate      webview_set_html
webview_eval          webview_bind          webview_unbind
webview_return        webview_get_native_handle
```

CAP-1 smoke path:

```pascal
WebView := webview_create(...);

webview_set_title(WebView, 'PWeb');
webview_set_html(WebView, '<h1>Hello Pascal</h1>');
webview_run(WebView);
```

Thread rules for `webview_bind`, `webview_return`, and `webview_dispatch` are in `threading-model.md` and are binding.

## Invocation wire shapes (CAP-2)

Frontend call:

```ts
const result = await nativeInvoke(
  "pweb.echo",
  {
    message: "hello"
  }
);
```

`pweb.echo` uses the runtime-reserved `pweb.*` namespace — the Phase 2 echo test obeys the same `Service.Method`-shaped grammar every later call does (see `wire-semantics.md`).

Pascal receives the `webview_bind` argument array:

```json
[
  "pweb.echo",
  {
    "message": "hello"
  }
]
```

and returns:

```json
{
  "message": "hello"
}
```

The payload carries **method and arguments only**. Identity, window, principal, and capabilities come from `TInvocationContext`, built natively — see `security-model.md`.

The failure path, the protocol version handshake, and cancellation semantics are **DECIDED** in `wire-semantics.md`, ahead of this capability being built.

## Service shape (CAP-3)

```pascal
ICalculatorService = interface(IInvokable)
  ['{...}']

  function Add(A, B: Integer): Integer;
end;
```

Called from the frontend as `await CalculatorService.add(20, 22)` → `42`, routed through `TWebViewInvocationBridge` → `TRestUriParams` → `TRestServer.Uri()`, on a worker. On the wire this is **named arguments** — `{"a": 20, "b": 22}` — per the protocol v1 grammar in `wire-semantics.md`; the SDK's positional sugar is client-side only, and parameter names are public API.

## Asset URIs (CAP-4)

```
pweb://app/index.html
pweb://app/assets/app.js
pweb://app/assets/app.css
```

## Control plane vs data plane (CAP-12)

`webview_bind` receives a JSON argument array and `webview_return` requires valid JSON. That is right for:

```json
{
  "method": "documents.get",
  "id": 123
}
```

and wrong for 80 MB of PDF, 40 MB of image, or 200 MB of video, where base64 only adds size, allocations, and copies.

A service returning bulk data answers with a handle:

```json
{
  "kind": "blob",
  "id": "D8364...",
  "size": 42831781,
  "mime": "application/pdf",
  "url": "pweb://blob/D8364..."
}
```

The frontend then reads it off the data plane:

```ts
const response = await fetch(blob.url);
const data = await response.blob();
```

Headers to support early, so a `<video>` seeking three seconds from the end does not pull 2 GB into memory:

```
Range
Content-Length
Content-Type
ETag
Cache-Control
```

Platform basis for streaming a response body: WebView2 supplies it via `WebResourceRequested`; WebKitGTK finishes a scheme request with a `GInputStream`, including asynchronously; Apple exposes the same model through `WKURLSchemeHandler` / `WKURLSchemeTask`.

### JS → native

SDK surface is stable now:

```ts
const blob = await native.blobs.create(file);
```

Transport is not frozen. WebView2 can receive a request body as a stream, and WebKitGTK exposes `webkit_uri_scheme_request_get_http_body()` since 2.40, but `fetch(PUT pweb://…)` is only declared universal after real macOS integration tests against the `WKURLSchemeTask` `URLRequest`. JSON chunking exists as a fallback, never as the nominal path.

### Platform fast path

```
IWebBlobTransport
       │
       ├── generic pweb://
       │
       └── WebView2SharedBuffer  [optimization]
```

WebView2 shared buffers arrive in JavaScript as an `ArrayBuffer` and could be a very efficient Windows path — kept as a platform optimization, never as public PWeb contract.

## Frontend SDK surface (CAP-5)

TypeScript (`sdk/typescript/`: `invoke.ts`, `events.ts`, `window.ts`):

```ts
import { invoke } from "@pweb/runtime";

const result = await invoke<User>(
  "UserService.Get",
  { id: 42 }
);
```

Pas2JS (`sdk/pas2js/pweb.native.pas`), conceptually:

```pascal
User := await Native.Invoke(
  'UserService.Get',
  Params
);
```

## Capability manifest (CAP-8)

```json
{
  "allow": [
    "settings.read",
    "settings.write",
    "parking.list"
  ]
}
```

This is the app **ceiling**. Effective rights are the intersection defined in `security-model.md`. A denied invocation returns 403 before reaching the SOA layer.

## Bundle container (CAP-6)

`app.pwb` starts as a ZIP:

```
app.pwb
├── manifest.json
├── index.html
└── assets/
```

The optional indexed format, only if benchmarked against ZIP and shown to win:

```
PWB1
├── header
├── index
├── MIME
├── hashes
├── offsets
└── blobs
    ├── stored
    ├── SynLZ
    └── possibly another algorithm
```
