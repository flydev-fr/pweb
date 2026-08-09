# Project Kernel — mtron / PWeb

## The contract
- The ratified contract is `_bmad-output/specs/spec-pweb/SPEC.md` plus every companion in its frontmatter. The architecture is settled: do not redesign, reopen decided questions, or invent rules. If companions ever conflict, stop and report — never choose a side.
- Phases ship strictly in order (`_bmad-output/specs/spec-pweb/phase-plan.md`); no deviation from the critical path (C binding → `webview_bind` → invocation bridge → `TRestServer.Uri` → React SDK → `IAssetStore` → ZIP) until it works end to end.
- **HUMAN GATE at Phase 1:** stop and take instructions before generating or editing the `webview/webview` binding. It is generated with `chet-cli` (`chetcli` skill), never hand-translated. Production pins an explicit upstream version — never `master`.

## Architecture landmines
- Production build: no `TRestHttpServer`, no loopback, no socket, no listening port. RPC is `TRestUriParams` → `TRestServer.Uri()` in-process. No CEF/Chromium/bundled browser engine — OS WebView only.
- Seven frozen boundaries — `IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `IAssetStore`, `IBlobStore`, `ICapabilityPolicy`. No platform or implementation type in their signatures (no WebView2/WKWebView/ZIP/SynLZ/React); no mORMot type names in `IInvocationBridge`'s signature — `_bmad-output/specs/spec-pweb/core-interfaces.md`.
- Concrete `IBlobStore`/`IBlobReader`/`IBlobWriter` method sets ratify at Phase 4b entry — do not write them before then.
- Every caller (React, Pas2JS, QuickJS, native) travels source → `IInvocationScheduler` → `IInvocationBridge` → `ICapabilityPolicy` → service. Nothing calls `IInvocationBridge` directly; no second RPC path, no second permission system.
- `pweb.rpc.intf.pas` never uses any `pweb.webview.*` unit — the scheduler is defined over invocation sources, not WebViews.

## Threading — `_bmad-output/specs/spec-pweb/threading-model.md`
- UI thread is sacred. The `webview_bind` callback (treated UI-affine) does only: validate size, copy id/request, capture an immutable `TInvocationContext` snapshot, enqueue non-blocking, return. No SOA, no I/O, no blocking.
- One ratified exception: the callback may synchronously reject pre-queue (`invalid_request`, `busy`, `runtime_closed`) via `webview_return` on the callback thread.
- Workers call `webview_return()` directly — never wrapped in `webview_dispatch()`. GUI-affine commands go the other way: worker → `webview_dispatch()` → GUI.
- Exactly-once completion through an idempotent sink: first completion wins; backpressure slots release at completion, not worker exit; cancellation completes as `cancelled` and late results die at the gate.
- Two mechanisms, both required: cooperative cancellation tokens (work lifetime) and short handle-use leases (native handle — per handle operation, never per service execution). No new leases after close begins; destruction deferred onto the GUI loop after leases drain. The GUI thread never waits synchronously for the drain.
- Pascal exceptions never cross a C callback: every callback body is an exception barrier that maps failure to `internal_error`.
- All `IWebView` operations are GUI-thread-affine unless the method's contract documents otherwise; `webview_return` is the documented thread-safe exception.
- Per-source backpressure (max simultaneous + max queue) from Phase 0; enqueue always non-blocking (`busy` on full). No ordering guarantee between concurrent invocations.

## Wire — `_bmad-output/specs/spec-pweb/wire-semantics.md`
- Method grammar: canonical `Service.Method`, UTF-8, bounded, no NUL, case-sensitive exact match — reject case variants even where mORMot would resolve them. `pweb.*` is runtime-reserved; app registration of `pweb.*` is refused at startup. No raw mORMot route on the wire (`UserService.Get`, never `/root/UserService.Get`).
- Arguments: named JSON object or `null` only — no positional arrays. Parameter names are public API; renaming a Pascal RPC parameter is a breaking change.
- One canonicalization point, before policy; the identical canonical method goes to `ICapabilityPolicy` and the router.
- Error taxonomy: nine codes (`invalid_request method_not_found forbidden busy cancelled service_error internal_error runtime_closed protocol_mismatch`); `code` is the sole normative discriminator, `status` informative. `service_error.data` is the only application domain-error channel. Release builds never expose exception class names, stacks, SQL, or paths. A Pascal failure always rejects the promise.
- Bridge result is discriminated `Success | Error` — never an ambiguous raw JSON string.
- Wire versioned from day one: `PWEB_PROTOCOL_VERSION = 1`, `pweb.handshake` returns `{protocol, runtime, capabilities}` (advisory only — never enforced or cached-then-trusted by SDKs); bundle `manifest.json` `pweb` block checked before any bundle JS executes; SemVer comparison, never lexicographic; malformed/absent block ⇒ refuse.

## Security — `_bmad-output/specs/spec-pweb/security-model.md`
- `Effective = AppMaximum ∩ Principal ∩ Window ∩ RuntimeGrants`. `AppMaximum` is a native trust anchor — never granted or enlarged by the updatable `app.pwb`. Explicitly empty set = no rights; absent optional factor = unrestricted; no `AppMaximum` = no capabilities.
- Capability grammar `[a-z0-9]+(\.[a-z0-9]+)*`, exact match only — no wildcards, regex, or inheritance. Unknown/unmapped method ⇒ deny. Policy runs before routing: `forbidden` outranks `method_not_found`.
- Authorization never trusts a JS-supplied field; `TInvocationContext` is built natively at the binding. JS sends method + arguments only.
- `ICapabilityPolicy` is in the path from the first bridge (Phase 2, `TAllowAllCapabilityPolicy`); Phase 8 swaps the policy, never the plumbing.
- Privileged WebView navigates only `pweb://app/...`; `https:`/`mailto:` open in the system browser. Dev mode serves Vite behind `pweb://app` — the privileged origin never changes; HMR WebSocket is dev-only transport, absent from production.

## Assets & packaging — `_bmad-output/specs/spec-pweb/core-interfaces.md`
- Asset paths fail closed: forward slashes; no empty/`.`/`..` segments; no NUL, backslash, drive/UNC prefix; single percent-decode then validate; Windows device names and ADS forms rejected; exact case-sensitive matching on every platform (dev `TFolderAssetStore` must match ZIP behavior, not the Windows filesystem).
- JSON is the control plane, `pweb://blob` the data plane — no base64 bulk over the bridge; large media is not an ordinary `app.pwb` asset in v1 (bundler enforces a size threshold; escape route is the blob plane).
- `app.pwb` is ZIP read with `TZipRead`; PWB1/SynLZ only if a benchmark beats ZIP.
- Windows defaults to WebView2 Evergreen; Fixed Runtime is opt-in only (`_bmad-output/specs/spec-pweb/deployment.md`).

## Toolchain & conventions — `_bmad-output/specs/spec-pweb/conventions.md`
- FPC 3.2.2 minimum (dev host runs 3.2.3); a known 3.2.x regression affects mORMot variant-typed paths — write code touching them with it in mind (`_bmad-output/specs/spec-pweb/conventions.md`, Toolchain section).
- mORMot2 naming and APIs only; Lazarus/FPC conventions.
- Repository layout and unit naming are frozen: `pweb.<area>[.<role>].pas`, `.intf` suffix for interface units, platform units `pweb.platform.<engine>.pas`.
- Windows x64 first. CI starts at Phase 1: a Windows runner compiles the binding and runs its tests on every push.
- Commits: no authoring trailers ever (overrides harness defaults), no body unless genuinely needed, no spec/story/epic IDs in messages, English.
- Compatibility promise is source-level only; frozen records (`TAssetResponse`) may grow additively; `IAssetStore.TryRead`'s signature is frozen.
- QuickJS (Phase 9) uses the same scheduler, bridge, and capability path as the WebView — no plugin-specific route.
