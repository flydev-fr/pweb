---
id: SPEC-pweb
companions:
  - architecture-diagrams.md
  - core-interfaces.md
  - threading-model.md
  - wire-semantics.md
  - security-model.md
  - deployment.md
  - phase-plan.md
  - conventions.md
sources: []   # plan.md was fully absorbed and then deleted from the repo; recoverable at commit 5e3f228
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# PWeb — desktop runtime for FPC/Lazarus with a web frontend and no network server

## Why

A vision to realize, with an opportunity attached. Pascal developers who want a modern web UI on a desktop app today have to stand up an embedded HTTP server on loopback and talk to it from the browser view — which means a listening port, a visible attack surface, port conflicts, and traffic any packet capture can read. PWeb is the Tauri equivalent for FPC/Lazarus: the UI runs in the OS WebView, the backend is mORMot2 SOA, and the two are joined by an in-process invocation bridge so a production build opens no socket at all. The bet is that a clean enough kernel — seven frozen contracts, one RPC path, one asset abstraction — never has to be rewritten as React, Pas2JS, QuickJS plugins, three platforms, and a bundler are added on top of it. Everything downstream resolves against that: correctness of the kernel first, breadth second.

## Capabilities

- **CAP-1**
  - **intent:** Pascal code opens a native system WebView window and renders HTML in it.
  - **success:** A Windows x64 sample creates the view, sets title and HTML, runs, and closes cleanly with no evident leak; all 14 upstream C entry points (see `core-interfaces.md`) are bound and their error paths checked; **and a Windows CI runner compiles the binding and executes its tests on every push from this phase onward.**
- **CAP-2**
  - **intent:** Frontend JavaScript can invoke a named Pascal handler with arguments and await its result.
  - **success:** An `echo` round-trip returns the argument object to a resolved JS promise; a Pascal-side failure rejects the promise instead of hanging it; the work runs off the GUI thread and the result comes back through `webview_return()` (see `threading-model.md`).
- **CAP-3**
  - **intent:** A mORMot2 SOA service is reachable from the frontend without any network transport.
  - **success:** `await CalculatorService.add(20, 22)` returns `42` in the frontend while the process holds no `TRestHttpServer`, no socket, and no listening port; the call passes through `ICapabilityPolicy` on its way, even though the Phase 3 policy is trivially permissive.
- **CAP-4**
  - **intent:** Frontend files are served to the WebView through `IAssetStore` rather than from disk paths or HTTP.
  - **success:** `index.html` plus its JS/CSS load over the `pweb://` scheme from `TFolderAssetStore` in dev and from `TZipAssetStore` over `app.zip`, both through the platform resource handler.
- **CAP-5**
  - **intent:** A TypeScript SDK and a Pas2JS SDK both call backend services over one identical RPC path.
  - **success:** The same service is invoked from a React app and from a Pas2JS app, and the bridge contains no Pas2JS-specific branch.
- **CAP-6**
  - **intent:** A frontend build is packed into a single container the runtime loads directly.
  - **success:** A release build ships with no loose frontend files and boots its UI from `app.pwb` containing `manifest.json`, `index.html`, and `assets/`.
- **CAP-7**
  - **intent:** The same application source builds and runs on Windows, Linux, and macOS behind one contract.
  - **success:** The hello + RPC + assets example passes its gates on all three platforms, with divergence confined to the `platform/` asset handlers.
- **CAP-8**
  - **intent:** Every invocation is authorized against the caller's effective capabilities before it can reach a service.
  - **success:** A method outside the effective set is refused with 403 without touching the SOA layer; the same method allowed for `MainWindow` is refused for `LoginWindow` and for a plugin principal; and a page reached by external navigation has no access to the native bridge. See `security-model.md`.
- **CAP-9**
  - **intent:** Embedded QuickJS scripts invoke the same backend services as the UI.
  - **success:** A QuickJS plugin call traverses `IInvocationBridge` and `ICapabilityPolicy` exactly as a WebView call does, adding no second RPC path and no second permission system.
- **CAP-10**
  - **intent:** A `pweb` CLI drives the application lifecycle from scaffold to release.
  - **success:** `pweb create MyApp --ui react` and `--ui pas2js` scaffold a runnable app; `pweb dev` runs the frontend watcher and native executable together; `pweb build` produces a packaged release.
- **CAP-11**
  - **intent:** The Phase 1 CI grows into the full target matrix, and upstream `webview/webview` drift is caught before it reaches production. This phase *extends* CI; it does not introduce it.
  - **success:** CI builds Windows x64, Linux x64, macOS x64, and macOS ARM64; a separate watcher compiles the binding against upstream head and reports an API diff without changing the pinned version.
- **CAP-12**
  - **intent:** The frontend reads and writes bulk binary data without pushing it through the JSON invocation bridge.
  - **success:** A service returning a >40 MB PDF answers with a `BlobHandle` envelope; the frontend fetches `pweb://blob/{token}` and the response honours `Range`, `Content-Length`, and `Content-Type` without buffering the whole payload in memory. See `core-interfaces.md`. **Off the critical path: CAP-12 does not gate Phase 5 and is not required by the MVP.**
- **CAP-13**
  - **intent:** A packaged Windows app guarantees the WebView2 runtime is present before the user ever launches it.
  - **success:** `pweb build` emits `normal`, `offline`, and `fixed-runtime` profiles; installing the `normal` profile on a machine without WebView2 runs the bootstrapper during setup and the app then launches, and the `offline` profile does the same with no network. See `deployment.md`.

## Constraints

- No network transport in a production build: no `TRestHttpServer`, no loopback bind, no TCP socket, no listening port. This rules out the embedded-HTTP-server approach entirely and forces the `TRestUriParams` → `TRestServer.Uri()` in-process path.
- The core **decomposition** is seven interfaces — `IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `IAssetStore`, `IBlobStore`, `ICapabilityPolicy` — and none of them may name a platform or implementation type: no WebView2, WKWebView, ZIP, SynLZ, or React in their signatures. Everything else, `webview/webview` and mORMot included, is an implementation behind these boundaries. **The decomposition is settled; the per-method signatures are not.** Writing and ratifying them is a Phase 0 exit criterion — only `IAssetStore` currently has a concrete signature on record, and it is itself under review (see Open Questions).
- The wire protocol is versioned from day one: `PWEB_PROTOCOL_VERSION = 1` plus a handshake returning at minimum `{protocol, runtime, capabilities}`, and a `"pweb": {"protocol", "minRuntime"}` block in the bundle's `manifest.json` so an incompatible bundle is refused **before its JavaScript loads**. `app.pwb` can be updated independently of the native runtime, so the two can desynchronise.
- An **error contract and lifecycle/cancellation semantics are fixed before CAP-2**. They are wire semantics, not implementation detail: no invocation code ships against undefined shutdown behaviour. Concrete candidates are on record in `wire-semantics.md`; the GUI thread never waits synchronously for the drain, and native exception text never crosses the bridge.
- **The UI thread is sacred.** `TRestServer.Uri()` never runs inside the `webview_bind` callback. The callback is UI-affine by internal convention and does only: validate size, copy id and request, capture the invocation context, enqueue, return. Results come back via `webview_return()` called directly from the worker — never wrapped in `webview_dispatch()`. GUI-affine commands run the other way, worker → `webview_dispatch()` → GUI. See `threading-model.md`.
- Per-WebView backpressure exists from Phase 0: bounded simultaneous invocations and bounded queue size. Concurrent invocations carry no ordering guarantee; ordering comes from sequential `await` or from transactional semantics inside the service.
- **JSON is the control plane, `pweb://blob` is the data plane.** Base64 of bulk binary over the RPC bridge is not the nominal path. `IWebBlobTransport` may expose a Windows fast path (WebView2 `SharedBuffer` surfacing as an `ArrayBuffer`) but that fast path never enters the public PWeb contract.
- **Every invocation traverses `ICapabilityPolicy` from the first bridge onward** — Phase 2, via `TAllowAllCapabilityPolicy`. Phase 8 replaces the policy, never the plumbing: security must never require surgery on the RPC path.
- Capability identifiers match `[a-z0-9]+(\.[a-z0-9]+)*` and are matched **exactly** — no wildcards, no regex, no implicit inheritance in v1.
- The wire carries `method` (UTF-8, non-empty, bounded, canonical `Service.Method`) and `arguments` (JSON object or `null`), under a configurable size cap with an absolute security ceiling. **No raw mORMot route on the wire** — `UserService.Get`, never `/root/UserService.Get`.
- **Authorization never trusts a JS-supplied field.** Upstream `webview_bind` delivers only a request id, a JSON request, and a user argument — no origin — so an origin inside the payload is worthless. `TInvocationContext` is built natively and attached to the bridge instance; JS sends method and arguments only.
- The app manifest is a **ceiling**, never a grant: `Effective = AppMaximum ∩ Principal ∩ Window ∩ RuntimeGrants`. Plugins and QuickJS are principals in the same system (`pkWindow`, `pkPlugin`, `pkSystem`, `pkQuickJS`).
- A privileged WebView navigates only within `pweb://app/...`; `https:` and `mailto:` open in the system browser. External content never executes in a WebView holding the privileged bridge.
- Windows defaults to the **WebView2 Evergreen** shared runtime. Fixed Runtime is opt-in only — it adds 250 MB+ to distributed binaries and makes us responsible for its updates.
- Every caller — React, Pas2JS, QuickJS — reaches services through the same `IInvocationBridge`. No special-case route per frontend.
- **Human gate at Phase 1:** work stops for instructions before the `webview/webview` binding is written. A `chet-cli` tool exists for C-header → Pascal binding generation (exposed as the `chetcli` skill) and is the intended path, not hand-translation.
- Toolchain floor: FPC 3.2.2 (dev host currently 3.2.3). A known bug/regression affects mORMot variants in that line — design around it rather than assuming it away.
- Phases ship in order and each gate passes before the next starts: no mORMot code until CAP-2 is solid, and no deviation from the critical path (C binding → `webview_bind` → invocation bridge → `TRestServer.Uri` → React SDK → `IAssetStore` → ZIP) until it works end to end. See `phase-plan.md`.
- Production pins an explicit upstream `webview/webview` version and never follows `master` automatically.
- `app.pwb` is a ZIP read with `TZipRead` until a measurement justifies otherwise.
- Windows x64 first, then Linux, then macOS, because Windows is the development environment; platform resource-handler work starts on WebView2 only.

## Non-goals

- The CLI (CAP-10) is not part of the MVP.
- QuickJS scripting (CAP-9) is not part of the MVP.
- macOS and Linux are not part of the MVP; the MVP is Windows x64 only.
- The indexed `PWB1` + SynLZ container is not built until a benchmark against ZIP justifies it.
- No bundled browser engine. PWeb drives the OS WebView; embedding CEF or Chromium is out of scope.
- No serving of app content over HTTP in production, loopback included. Dev-mode Vite and pas2js watchers are exempt because they are not shipped.
- Windows code signing, macOS notarization, and auto-update are out of scope; PWeb produces the artifacts and stops there.
- The mORMot2 tri-license (MPL/GPL/LGPL) is accepted as-is; no relicensing work and no per-license impact analysis.
- The JS → native blob **transport** is not frozen. The SDK surface (`native.blobs.create(file)` over `IBlobStore`/`IBlobReader`/`IBlobWriter`) is; declaring `fetch(PUT pweb://…)` universal waits on real macOS integration tests. JSON chunking is a fallback only.

## Success signal

A React UI calls `await SystemService.getInfo()`; the call traverses the WebView, Pascal, and mORMot2 SOA and returns to React on Windows x64, with production assets served from an archive — while a packet capture of the process across the whole run shows zero traffic.

## Assumptions

- PWeb is a reusable framework for third-party Pascal developers, not a single application; implied by `pweb create MyApp` and the `sdk/` + `examples/` layout.
- Pascal-side invocation failures surface as rejected JS promises; the source shows only the success path.
- "Wireshark sees nothing" means the RPC path emits no traffic, not that a PWeb app is forbidden from doing its own network I/O.
- The MVP (the six checkboxes in `phase-plan.md`) is a concept proof, not a production-ready release — the source makes CAP-8 mandatory before production use.
- React/Vite and Pas2JS are the only frontends validated for v1; others are reachable through the TypeScript SDK but untested.
- Backpressure limits and worker-pool size are configurable, with defaults chosen at implementation time. The decision fixes the mechanism, not the numbers.

## Open Questions

### Phase-0 blockers

<!-- Must close before the signature freeze / CAP-2. Each has a concrete candidate on record in wire-semantics.md — the task is to ratify or replace it, not to invent from nothing. -->

- **Ratify the error contract.** Candidate envelope and code set are in `wire-semantics.md`. Open points: whether `status` earns its place beside `code`, whether `data` is typed per code, whether `busy` carries a retry hint.
- **Ratify the lifecycle model.** `Running → Quiescing → Closed` is on record. Open points: lease vs. refcount vs. cancellation token in `TInvocationContext`, and whether `Quiescing` needs a bounded timeout before forcing `Closed`.
- **Large media in `app.pwb`?** v1 policy is: small app assets materialised, bulk content through `IBlobStore`. If video or very large datasets may live in the bundle directly, a reader/stream variant of `TryRead` must be designed now rather than bolted on later.

### Deferred design decisions

<!-- Written down before the phase named; not blocking the freeze. -->

- **Dev-mode trust model — before Phase 10.** `pweb dev` runs Vite HMR while a privileged WebView is restricted to `pweb://app/...`. Either `127.0.0.1:<ephemeral>` is explicitly trusted in dev builds only, or Vite assets are proxied behind `pweb://app`.

