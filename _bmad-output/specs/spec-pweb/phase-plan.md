# Phase plan, gates, and MVP

Companion to `SPEC.md`. Phases ship in this order; each gate passes before the next phase starts. The rule behind the ordering: validate each layer in isolation before building the one above it.

## Phases

| Phase | Capability | Objective | Verifiable result |
| --- | --- | --- | --- |
| 0 | — | Freeze the 7 interfaces + 4 invariants | No platform code leaks into the core |
| 1 | CAP-1 | `webview/webview` binding **+ minimal Windows CI** | A WebView window driven from Pascal, binding built and tested on every push |
| 2 | CAP-2 | JS ↔ Pascal binding **+ policy call site** | `await native.invoke()` really calls Pascal, through allow-all policy |
| 3 | CAP-3 | mORMot2 bridge | A SOA interface called with no HTTP or socket |
| 4 | CAP-4 | Asset system | HTML/JS/CSS loaded through `IAssetStore` |
| 4b | CAP-12 | Blob data plane *(off critical path)* | Bulk binary served over `pweb://blob`, no base64 |
| 5 | CAP-5 | React + Pas2JS SDK | Two frontends on exactly the same backend |
| 6 | CAP-6 | Release bundle | Application with no scattered frontend files |
| 6b | CAP-13 | Windows runtime provisioning | Setup guarantees WebView2 before first launch |
| 7 | CAP-7 | Cross-platform | Windows/macOS/Linux behind one contract |
| 8 | CAP-8 | Capabilities / security *(hook exists since Phase 2)* | The frontend reaches only authorized RPC |
| 9 | CAP-9 | QuickJS | Plugins and scripts using the same services |
| 10 | CAP-10 | CLI / build tooling | `pweb dev`, `pweb build`, `pweb create` |
| 11 | CAP-11 | Full CI matrix + upstream watcher | All four targets built; `webview/webview` drift reported |

## Per-phase notes and gates

**Phase 0 — abstractions and invariants only.** Define the seven contracts — `IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `IAssetStore`, `IBlobStore`, `ICapabilityPolicy` (see `core-interfaces.md`) — and freeze four invariants:

```
1. UI THREAD IS SACRED
   webview callback → enqueue → worker
   worker → webview_return()

2. EVERGREEN FIRST
   shared runtime
   bootstrapper / standalone if needed
   Fixed = opt-in

3. JSON != BINARY
   native.invoke() = control plane
   pweb://blob   = data plane

4. CAPABILITY = CONTEXTUAL
   manifest = ceiling
   window / plugin = principal
   external origin = zero trust
```

This is the architectural lock taken before anything else. After it, `webview/webview`, ZIP, SynLZ, React, Pas2JS, QuickJS, and even mORMot are implementations behind clear boundaries instead of things that gradually colonize the project. Details: `threading-model.md`, `deployment.md`, `security-model.md`, `wire-semantics.md`.

**Phase 0 exit criteria** — the decomposition alone is not the freeze:

1. Concrete method signatures written and ratified for all seven contracts. Today only `IAssetStore` has one, and it is under review (RAM materialisation vs. stream).
2. Error contract decided (`wire-semantics.md`) — it changes `IInvocationBridge`.
3. Lifecycle/cancellation decided (`wire-semantics.md`) — it changes `IInvocationScheduler`.
4. `PWEB_PROTOCOL_VERSION` and the handshake payload in place.

Deciding 2 and 3 after CAP-2 would mean reopening the frozen core, which is the one thing this lock exists to prevent.

**Phase 1 — raw binding. HUMAN GATE FIRST.** Stop and take instructions before writing the binding: it is generated from the C header with `chet-cli` (the `chetcli` skill), not hand-translated. Files under `src/lib/`. Zero mORMot abstraction at this layer. Gate: Windows x64 · window opens · HTML renders · clean shutdown · errors checked · no evident leak · **CI green**.

**Minimal CI starts here, not at Phase 11.** A Windows runner compiles the binding and runs its tests on every push from this phase onward. The binding is the most ABI-sensitive component in the project; it does not get to live ten phases without a guard rail.

**Phase 2 — JS ↔ Pascal.** Files under `src/webview/`. The bind callback only enqueues; work runs on the pool and returns via `webview_return()` (`threading-model.md`). `native.invoke()` is already the real generic pipeline here, so the `ICapabilityPolicy` call site is wired in now with `TAllowAllCapabilityPolicy` — `echo` travels the same road every later call will. Gate: JS → Pascal → resolved JS promise, off the GUI thread, with backpressure limits in place, the error envelope honoured, and the `Running → Quiescing → Closed` transitions exercised. Until this is rock solid, no mORMot code is written.

**Phase 3 — first real milestone.** `TWebViewInvocationBridge` → `ICapabilityPolicy` (still allow-all) → `TRestUriParams` → `TRestServer.Uri()`. The policy call site already exists from Phase 2, so Phase 8 only swaps an implementation. When `await CalculatorService.add(20, 22)` returns `42` with no HTTP server, the framework concept is proven.

**Phase 4 — assets.** `TFolderAssetStore` gives easy development over `frontend/dist/`; `TZipAssetStore` validates packaging over `app.zip`. Requires a small per-platform resource handler; start Windows/WebView2 only, generalize later. **Phase 4b — off the critical path.** It extends the same handler to `pweb://blob` with `Range` support (`core-interfaces.md`) because the infrastructure is already there, but it does **not** gate Phase 5 and the MVP does not require it. Streaming, `Range`, JS→native upload, and the WebKit/WebView2/WKWebView differences are rich enough to consume a week with great enthusiasm; that week must not sit on the path to the first end-to-end `getInfo()`.

**Phase 5 — both SDKs.** No special path for Pas2JS.

**Phase 6 — bundler.** Deliberately ZIP first. The format name (`app.pwb`) is ours, so the internals can change later. Benchmark ZIP against indexed PWB + SynLZ only after ZIP works; if ZIP suffices, keep ZIP. Do not build a proprietary format before there is a measured reason. **Phase 6b** adds the three Windows build profiles (`deployment.md`).

**Phase 7 — platform order.** Windows → Linux → macOS, because Windows is the initial development environment, not because macOS matters less. The core stays `TSystemWebView`; only the asset extensions under `platform/` are platform-specific. RPC, capabilities, mORMot, bundle, and frontend stay identical.

**Phase 8 — security, mandatory before production.** Comes before plugins, filesystem, or process execution. Implements the contextual model in `security-model.md`: manifest as ceiling, principals per window and plugin, `TInvocationContext` built natively, and privileged WebViews restricted to `pweb://app/...`.

**Phase 9 — QuickJS, only now.**

**Phase 10 — CLI, once the runtime is stable.** `pweb create MyApp --ui react|--ui pas2js`, `pweb dev`, `pweb build`, `pweb run`, `pweb doctor`. `pweb dev` runs Vite HMR (React) or the pas2js watcher, plus the native executable.

**Phase 11 — full matrix + upstream watcher.** CI already exists since Phase 1; this phase *widens* it to Windows x64, Linux x64, macOS x64, macOS ARM64. The upstream watcher is independent and only reports; production stays on the pinned version.

## MVP

The MVP is not the CLI, QuickJS, or macOS. It is these six boxes:

```
[x] Windows x64
[x] independent webview/webview binding
[x] React displays a real UI
[x] native.invoke() works
[x] native.invoke() reaches a mORMot service via TRestServer.Uri()
[x] production assets come from an archive, with no HTTP
```

Concretely: `const info = await SystemService.getInfo();` → WebView → Pascal → mORMot2 → back to React, with Wireshark seeing absolutely nothing.

## Critical path

```
Binding C → webview_bind → InvocationBridge → TRestServer.Uri → React SDK → IAssetStore → ZIP
```

No deviation from this chain until it works end to end. Start with Phase 0 + Phase 1 — final interfaces and the upstream ABI binding with its tests — then advance step by step. Do not write 40 units before the first `Hello` has actually run.
