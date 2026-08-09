# Core interfaces and wire shapes

Companion to `SPEC.md`. No platform or implementation type appears in these signatures.

> **Status: the decomposition is settled, the signatures are not.** The table below fixes responsibilities and boundaries for all seven contracts. Only `IAssetStore` has a concrete signature on record, and it is itself under review. Writing and ratifying the remaining method sets is a **Phase 0 exit criterion**, and it depends on the open items in `wire-semantics.md` — cancellation and error propagation both change the method set of `IInvocationScheduler` and `IInvocationBridge`.

## The seven core contracts

| Interface | Responsibility | Must not reference |
| --- | --- | --- |
| `IWebView` | Window lifecycle, navigation, title, size, script evaluation | WebView2, WKWebView, WebKitGTK |
| `IWebViewBinding` | Registering named handlers callable from JS and returning results to them | React, Pas2JS, QuickJS |
| `IInvocationBridge` | Turning an invocation into a service call and its result back into a response | mORMot type names in the signature |
| `IInvocationScheduler` | Enqueuing invocations onto the worker pool, backpressure, completion routing | Any specific thread-pool implementation |
| `IAssetStore` | Existence and read of a frontend asset by logical path | ZIP, SynLZ, filesystem paths |
| `IBlobStore` | Ownership, lookup, streaming and lifetime of bulk binary payloads by opaque handle — `register` / `open` / `read` / `write` / `release` | URI schemes, WebView transports, filesystem paths, platform stream types |
| `ICapabilityPolicy` | Deciding whether a principal may invoke a given method | Any concrete policy source (file, manifest format) |

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

**RAM policy for v1:** reasonably small application assets are materialised; bulk content goes through `IBlobStore`. Still open: whether video or very large datasets may live directly inside `app.pwb`. If yes, a reader/stream variant of `TryRead` must be designed now rather than bolted on later.

### Blob side

Surface frozen, transport deliberately not:

```
IBlobStore
IBlobReader
IBlobWriter
```

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
  "echo",
  {
    message: "hello"
  }
);
```

Pascal receives the `webview_bind` argument array:

```json
[
  "echo",
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

The failure path, the protocol version handshake, and cancellation semantics are in `wire-semantics.md` and are settled before this capability is built.

## Service shape (CAP-3)

```pascal
ICalculatorService = interface(IInvokable)
  ['{...}']

  function Add(A, B: Integer): Integer;
end;
```

Called from the frontend as `await CalculatorService.add(20, 22)` → `42`, routed through `TWebViewInvocationBridge` → `TRestUriParams` → `TRestServer.Uri()`, on a worker.

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
