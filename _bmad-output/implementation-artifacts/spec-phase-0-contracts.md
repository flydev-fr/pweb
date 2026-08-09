---
title: 'PWeb Phase 0 contract units — ratify the six concrete method sets'
type: 'feature'
created: '2026-08-09'
status: 'done'
review_loop_iteration: 0
baseline_commit: '31cc3a946e270e8355dbddd83207ad7e6b88b57f'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/core-interfaces.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/wire-semantics.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/threading-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/security-model.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Phase 0 cannot exit: five concrete method sets (`IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `ICapabilityPolicy`) are unwritten and the on-record `IAssetStore` signature exists only as prose.

**Approach:** Author minimal contract units (`pweb.rpc.intf.pas`, `pweb.webview.intf.pas`, `pweb.assets.intf.pas`) with only the supporting types the ratified semantics require; compile with FPC 3.2.2 x64; minimization pass; report freeze readiness. Contract authoring only — no implementations, no blob method sets.

## Boundaries & Constraints

**Always:**
- Canonical: SPEC.md + companions + kernel.md. Preserve every ratified semantic: lifecycle Running→Quiescing→Closed, exactly-once idempotent sink, token ≠ lease, discriminated Success|Error result, nine-code taxonomy (`code` normative), named-JSON args, `pweb.*` reserved, fail-closed policy, ratified `TryRead`.
- `pweb.rpc.intf.pas` is RTL-only — no mORMot/webview/platform identifier; that mechanically satisfies the bridge/policy mORMot bans.
- Layout & naming per frozen `conventions.md`; `pweb.webview.intf.pas` may use `pweb.rpc.intf.pas`, never the reverse (scheduler stays source-generic for QuickJS).
- Every public type/method traces to a ratified requirement; ownership/lifetime/thread-affinity documented in source.

**Ask First:** reopening any ratified decision; adding an eighth core interface; any blob method signature.

**Never:** chet-cli; webview binding; CAP-1 or any implementation class; platform code; `TRestServer.Uri`; worker pool; SDKs; blob/CLI code; stories/epics; crossing the Phase-1 gate; `Exists()` on `IAssetStore`; `webview_return` in `IInvocationBridge`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Contract compile | FPC 3.2.2 x64, each unit | Compiles clean | Fix or report |
| rpc.intf isolation | Compile with no mORMot path | Clean (RTL-only) | Freeze blocker |
| Pre-queue rejection | Enqueue on full/closed source | Sync non-blocking result, never via sink | Contract encodes |
| Late completion | Second `Complete` on a sink | Dropped (idempotent, documented) | N/A |

</frozen-after-approval>

## Code Map

- `core-interfaces.md` -- verbatim `IAssetStore.TryRead` (`RawUtf8`, `out TAssetResponse`, Boolean); responsibility/must-not-reference table; blob deferral.
- `wire-semantics.md` -- nine codes + status table (400,404,403,429,499,422,500,503,505); `PWEB_PROTOCOL_VERSION = 1`; discriminated result; lifecycle.
- `threading-model.md` -- callback duties; sync pre-queue rejection; exactly-once sink; token vs lease; GUI-affine default.
- `security-model.md` -- `TInvocationContext` fields (WindowId, PrincipalId, PrincipalKind, Capabilities, PluginId, TrustedContent); kinds `pkWindow pkPlugin pkSystem pkQuickJS`; policy input = context + canonical method.
- mORMot2: `C:/Users/badb/Documents/Embarcadero/Studio/Libraries/mORMot2/src` (assets unit only). FPC: `C:\dev\IDE\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe`. No `src/` exists yet — all units new.

## Tasks & Acceptance

**Execution:**
- [x] `src/rpc/pweb.rpc.intf.pas` -- protocol consts (version, namespace, runtime methods, code-text + status tables); `TPWebJson` (RTL `Utf8String` alias); `TPWebErrorCode` (9, table order); `TPWebError`; `TPWebResultKind`/`TPWebInvocationResult`; `TPWebPrincipalKind`; `TInvocationContext`; `TPWebSourceState`; `TPWebSourceLimits`; `TPWebEnqueueResult`; `ICancellationToken`; `IInvocationCompletion` (idempotent); `ICapabilityPolicy.IsAllowed(ctx, method): Boolean`; `IInvocationBridge.Invoke(ctx, method, args, token): TPWebInvocationResult`; `IInvocationSource` (non-blocking TryEnqueue + per-invocation completion, Quiesce, Close, State); `IInvocationScheduler` (RegisterSource, Shutdown).
- [x] `src/webview/pweb.webview.intf.pas` -- `TPWebSizeHint`; `IWebView` (SetTitle, SetSize, Navigate, SetHtml, Eval, Run, Terminate, Dispatch — GUI-affine except Dispatch); `IWebViewInvocationHandler` (ctx + request + completion, callback-thread contract); `IWebViewBinding` (Bind, Unbind, Quiesce, Close, State).
- [x] `src/assets/pweb.assets.intf.pas` -- `TAssetResponse` (Content, ContentType; additive growth note); `IAssetStore.TryRead` verbatim; fail-closed path semantics in doc comments.
- [x] Compile all three (rpc.intf additionally without mORMot paths); minimization pass per the six mandated questions; deliverable report with declarations, requiring requirement, semantics, per-method justification.

**Acceptance Criteria:**
- Given FPC 3.2.2 x64, when each unit compiles, then all pass and `pweb.rpc.intf.pas` needs zero non-RTL paths.
- Given the six interfaces, then no WebView2/WKWebView/WebKitGTK/React/Pas2JS/ZIP/SynLZ type anywhere, and no QuickJS engine/implementation type — the ratified `pkQuickJS` principal-kind literal (security-model.md) is expected and is not a QuickJS reference; no mORMot type in bridge/policy/scheduler signatures (`RawUtf8` only in the ratified `IAssetStore` shape).
- Given the tree, then no `IBlobStore`/`IBlobReader`/`IBlobWriter` method signature exists.
- Given the report, then it ends with the mandated PHASE 0 CONTRACTS / VALIDATION / VERDICT structure and stops.

## Spec Change Log

## Design Notes

- Bridge = synchronous worker-thread function returning the discriminated result; completion routing stays scheduler-side — keeps every transport out of the bridge; QuickJS maps the same two arms itself.
- Per-invocation `IInvocationCompletion` passed at enqueue is the transport-specific sink; `TryEnqueue` returning `busy`/`closed` synchronously lets the source do the ratified callback-thread pre-queue rejection through the same object.
- Handle-use lease is deliberately absent from public contracts (owned by `IWebViewBinding` internals per core-interfaces.md); only the token is public.
- Pipeline-order note: corpus places the policy call inside the bridge before routing; the task prompt paraphrases scheduler→policy→bridge. No signature couples bridge and policy — contracts are neutral, nothing to reopen.

## Verification

**Commands:**
- `fpc.exe -MObjFPC -Sh -B src/rpc/pweb.rpc.intf.pas` (no mORMot `-Fu`) -- compiles: proves RTL-only isolation.
- Same for webview.intf (`-Fu src/rpc`) and assets.intf (mORMot2 `-Fu`/`-Fi`) -- compile clean.
- `grep -ri "webview2\|wkwebview\|webkitgtk\|react\|pas2js\|synlz\|TZip\|TRest" src/` -- no hits.

## Suggested Review Order

**Invocation pipeline contract (the freeze's core)**

- Entry point: the scheduler-issued source handle — non-blocking enqueue, lifecycle, the pre-queue rejection gate.
  [`pweb.rpc.intf.pas:331`](../../src/rpc/pweb.rpc.intf.pas#L331)

- Bridge: synchronous discriminated Success|Error on a worker; no transport, no mORMot name in the signature.
  [`pweb.rpc.intf.pas:306`](../../src/rpc/pweb.rpc.intf.pas#L306)

- Policy: fail-closed Boolean over native context + canonical method; exception ⇒ deny.
  [`pweb.rpc.intf.pas:285`](../../src/rpc/pweb.rpc.intf.pas#L285)

- Exactly-once idempotent completion sink — the transport-specific reply mechanism kept out of the bridge.
  [`pweb.rpc.intf.pas:258`](../../src/rpc/pweb.rpc.intf.pas#L258)

- Cooperative token; the handle-use lease is deliberately absent from public contracts.
  [`pweb.rpc.intf.pas:233`](../../src/rpc/pweb.rpc.intf.pas#L233)

- Scheduler: RegisterSource + Shutdown only; defined over sources so QuickJS reuses it unchanged.
  [`pweb.rpc.intf.pas:396`](../../src/rpc/pweb.rpc.intf.pas#L396)

**Wire data (normative tables)**

- Nine-code taxonomy in ratified table order; `code` normative, `status` derived.
  [`pweb.rpc.intf.pas:72`](../../src/rpc/pweb.rpc.intf.pas#L72)

- Frozen code-text/status/enqueue-rejection tables — machine-readable, shared by every transport.
  [`pweb.rpc.intf.pas:427`](../../src/rpc/pweb.rpc.intf.pas#L427)

- Protocol constants: version, supported-set shape, reserved namespace, runtime methods.
  [`pweb.rpc.intf.pas:39`](../../src/rpc/pweb.rpc.intf.pas#L39)

**Security identity**

- TInvocationContext: ratified six fields, deep-copy snapshot rule, identity invariants.
  [`pweb.rpc.intf.pas:162`](../../src/rpc/pweb.rpc.intf.pas#L162)

**WebView flavour of the source**

- The binding: Bind/Unbind + lifecycle; sink, lease, userdata all internal; fronts one scheduler source.
  [`pweb.webview.intf.pas:177`](../../src/webview/pweb.webview.intf.pas#L177)

- Handler: the full ratified callback-thread contract (validate/copy/snapshot/enqueue/return; pre-queue exception).
  [`pweb.webview.intf.pas:142`](../../src/webview/pweb.webview.intf.pas#L142)

- IWebView: GUI-affine method set; Dispatch is the sole documented thread-safe exception.
  [`pweb.webview.intf.pas:72`](../../src/webview/pweb.webview.intf.pas#L72)

**Assets**

- Verbatim ratified TryRead plus the extended fail-closed canonical-path rules.
  [`pweb.assets.intf.pas:77`](../../src/assets/pweb.assets.intf.pas#L77)

- TAssetResponse: minimal materialised response; additive-growth evolution rule.
  [`pweb.assets.intf.pas:39`](../../src/assets/pweb.assets.intf.pas#L39)
