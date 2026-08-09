---
title: 'PWeb Phase 2 / CAP-2 — JS ↔ Pascal invocation pipeline: scheduler, webview_bind source, policy call site, dummy bridge'
type: 'feature'
created: '2026-08-09'
status: 'done'
review_loop_iteration: 0
baseline_commit: '709bf0fee715d0cf9b8c475b4f801947fc0f4a65'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/threading-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/wire-semantics.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Contracts are frozen and the raw ABI binding works, but nothing implements them: JS cannot call Pascal, no scheduler, no policy call site, no lifecycle. Until this is rock solid, no mORMot code may be written.

**Approach:** On a new branch, implement CAP-2 only: the source-generic `IInvocationScheduler`/`IInvocationSource` with bounded queue + bounded concurrency and exactly-once completion; `IWebViewBinding` over `webview_bind` with an enqueue-only callback; the real `ICapabilityPolicy` call site with an explicit allow-all implementation; a deterministic test/dummy `IInvocationBridge`; lifecycle `Running → Quiescing → Closed` with handle-use leases; headless test suites, a JS↔Pascal runtime example, and extended Windows CI.

## Boundaries & Constraints

**Always:**
- Frozen contracts govern verbatim: `pweb.rpc.intf.pas`, `pweb.webview.intf.pas` (read-only). Canonical path MUST hold — bind callback: copy/validate transport data → native `TInvocationContext` → enqueue only → return (pre-queue sync rejections excepted); worker: canonicalize method exactly once (in `TryEnqueue`) → `policy.IsAllowed` → `bridge.Invoke` with the **identical canonical method value** → terminal completion → `webview_return()` directly from the worker (thread-safe at pin, verified in `docs/webview-upstream-semantics.md`). Never `webview_dispatch(webview_return)`; `webview_dispatch` only for genuinely GUI-affine work.
- Exactly ONE terminal completion per invocation; first wins, later attempts dropped safely; slots release at completion only. No unbounded queues; no ordering guarantee. Malformed envelopes fail before `TryEnqueue`; `TryEnqueue` is the single method canonicalization gate (`Service.Method`, exact, case-sensitive; named args; JSON null is `'null'` never `''`); correlation comes from the native webview binding id; context is native-only.
- No direct Running→Closed: Close while Running performs full Quiesce semantics first. Quiescing refuses new requests, cancels queued ones with terminal completion, cooperatively cancels in-flight; late completions after Closed are discarded without touching the handle; GUI thread never synchronously waits for drain; shutdown bounded; source shutdown ≠ scheduler shutdown.
- Handle-use lease only around actual native-handle use (esp. `webview_return`), never across bridge/service execution; no new leases once close begins; Closed prevents late workers from touching a destroyed handle.
- Exception barriers: no Pascal exception unwinds through any C callback (bind, dispatch); failures become safe terminal completions (`internal_error`) where possible. Policy exception ⇒ deny + `internal_error`; never fail open. Do not bypass policy because it is allow-all.
- Error mapping uses only the frozen nine-code model (CAP-2 paths: `invalid_request`, `forbidden`, `busy`, `cancelled`, `internal_error`, `runtime_closed`); no `unauthorized`; no exception class names/stacks/paths on the wire; a promise never stays pending.
- The global JS binding name stays an internal implementation detail — no new public protocol/SDK fields beyond the frozen corpus.
- Project pattern: examples/tests/apps use `{$I mormot.defines.inc}` + `{$I mormot.uses.inc}`; suites on `mormot.core.test` run with `/noenter`; `src/lib` stays mORMot-free and unmodified except for a demonstrated binding bug.
- CI keeps every CAP-1 gate; adds CAP-2 headless tests (scheduler, lifecycle, backpressure, completion, policy call site, canonicalization, exception barriers where testable) and compiles the runtime example; GUI execution stays a documented local/non-gating smoke exactly as CAP-1.

**Ask First:** any change to a frozen Phase-0 public signature or CAP-1 ABI declaration — STOP and report, do not silently redesign; any new public protocol field; pushing or opening a PR.

**Never:** Phase 3+ work — `TRestServer.Uri`, `TRestHttpServer`, localhost HTTP, named pipes, mORMot service routing, React/Pas2JS SDK, `pweb://` asset handling, ZIP/`app.pwb`, `IBlobStore` signatures, QuickJS, capability grammar/mappings beyond the frozen corpus; calling the bridge from the bind callback; disk/DB/crypto/service/blocking work in the callback; React in the example (plain HTML/JS suffices).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | JS invoke, valid `["Method", {args}]` | enqueue → worker → policy → bridge → `webview_return` → resolved promise | N/A |
| Malformed envelope | non-JSON / wrong shape / oversize | rejected pre-queue, sync on callback thread | `invalid_request`, never reaches `TryEnqueue` |
| Bad method grammar | case variant, raw URI, empty, NUL | `TryEnqueue` → `perInvalidRequest` | `invalid_request` |
| Queue full | `MaxQueueSize` reached | sync `perBusy`, never blocks | `busy` |
| Not running | Quiescing/Closed source | sync `perClosed` | `runtime_closed` |
| Policy deny | deny-policy variant in test | bridge never called | `forbidden` |
| Bridge raises | test bridge exception | caught worker-side | `internal_error`, no detail leak |
| Cancel in flight | Quiesce during bridge call | token signalled; completes `cancelled`; late result dies at gate | slot released exactly once |
| Destroy race | Close/destroy vs late `webview_return` | lease denied; handle never touched after Closed | completion swallowed silently |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.intf.pas` -- FROZEN, read-only. `TryEnqueue`:387 (single canonicalization gate + semantics), `IInvocationCompletion`:284 (idempotent sink), `ICapabilityPolicy`:312 (exception⇒deny), `IInvocationBridge`:333 (sync worker call, discriminated result), `IInvocationSource`:358 (Quiesce/Close/State), `IInvocationScheduler`:432 (RegisterSource refuses limits <1; Shutdown may block, never on GUI thread), tables `PWEB_ENQUEUE_ERROR`/`PWEB_ERROR_CODE_TEXT`/`PWEB_ERROR_STATUS`:459-499, `PWEB_JSON_NULL`:77.
- `src/webview/pweb.webview.intf.pas` -- FROZEN, read-only. `IWebViewInvocationHandler`:154 (envelope parse duty, pre-queue rejection), `IWebViewBinding`:196 (Bind name = JS global, NOT Service.Method; fronts exactly one source; state never diverges).
- `src/lib/pweb.lib.webview.pas` -- raw ABI, read-only: `webview_bind_fn`:121 (`id`/`req` valid only during callback — copy immediately), `webview_bind`:123, `webview_unbind`:126, `webview_return`:129 (status 0=resolve, nonzero=reject), `webview_init`:114, `webview_eval`:117.
- `docs/webview-upstream-semantics.md` -- measured pin facts: `webview_return` thread-safe and copies id/result before returning (:41-44,:56); terminate must be dispatched; barrier rule (:120).
- `src/lib/pweb.lib.webview.errors.pas:65` -- `WebViewCheck` for GUI-thread call sites.
- `examples/01-hello/hello.pas` -- reuse pattern: `PWEB_SMOKE_AUTOCLOSE_MS` auto-close, dispatch-routed terminate, interlocked close race.
- `test/core/pwebtests.pas` -- suite runner to extend with the new rpc cases; `test/core/pweb.test.core.pas` -- TSynTestCase idiom to copy.
- `.github/workflows/ci.yml` -- CAP-1 gates (keep all): freeze byte-diff vs `b2f04dc`:180-187, RTL-only sweep:169, surface check:165, smoke pattern:203.
- `_bmad-output/specs/spec-pweb/conventions.md` -- frozen layout: new units `src/rpc/pweb.rpc.scheduler.pas`, `src/webview/pweb.webview.binding.pas`; tests under `test/rpc/`; example `examples/02-js-binding/`.
- Toolchain: FPC 3.2.2 (`C:\dev\IDE\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe`), mORMot2 pinned via `mormot.lock` → `deps/mormot2`, webview DLL via `tools/build-webview-dll.ps1`.

## Tasks & Acceptance

**Execution:**
- [x] branch `phase/2-cap2-invocation` off `main`.
- [x] `src/rpc/pweb.rpc.scheduler.pas` -- `TInvocationScheduler` + source impl: worker pool (RTL TThread), per-source bounded active/queue counts, method grammar validation/canonicalization in `TryEnqueue`, exactly-once gate wrapping each completion, policy→bridge order with the same canonical value, cooperative tokens, Quiesce/Close/Shutdown per contract. Never uses any `pweb.webview.*` unit.
- [x] `src/security/pweb.capabilities.pas` -- `TAllowAllCapabilityPolicy` (explicit, documented allow-all; Phase 8 swaps the implementation, never the plumbing).
- [x] `src/rpc/pweb.rpc.bridge.dummy.pas` -- deterministic test/dummy bridge: echo success, scripted `service_error`, raise-on-demand, configurable delay, token-observing cancellation; concurrent-safe. Outside the raw binding layer; shared by tests and the example.
- [x] `src/webview/pweb.webview.binding.pas` -- `TWebViewBinding` over the raw ABI: exception-barriered `webview_bind` callback (copy id/req, size check, envelope parse to Method+Args only, native context snapshot, pre-queue sync rejection via `webview_return`, enqueue, return); completion sink calls `webview_return` under an internal handle-use lease; injectable native-return/native-bind function pointers (defaulting to the real ABI) so lifecycle/race tests run headless; lifecycle delegates to its single scheduler source so states cannot diverge.
- [x] `test/rpc/pweb.test.rpc.pas` (+ helpers) -- mormot.core.test cases covering the twenty mandated deterministic tests: (1) malformed request rejected pre-enqueue (2) valid Method+named Args enqueues (3) method canonicalized once (4) same canonical Method at policy and bridge (5) allow-all permits (6) deny path → `forbidden` (7) queue limit → `busy` (8) concurrency limit respected (9) queued work starts on freed slot (10) exactly-one completion (11) double completion cannot double-release slot (12) bridge exception → `internal_error` (13) cooperative cancellation (14) Quiesce refuses new (15) Quiesce cancels queued (16) Close-while-Running quiesces first (17) late completion after Closed touches nothing (18) lease prevents destroy/return race (19) callback does no synchronous service execution (20) scheduler works with a non-WebView test source. Race/mutation style where practical (loops, delayed bridges, concurrent completers). Register in `pwebtests.pas`.
- [x] `examples/02-js-binding/` -- minimal Windows app: create webview, bind internal JS endpoint, HTML/JS page firing multiple concurrent invocations through allow-all policy + dummy bridge, results rendered from resolved promises; auto-close env var like `01-hello`.
- [x] `.github/workflows/ci.yml` -- keep all CAP-1 steps; compile new units, run extended `pwebtests` headless, compile example 02 with best-effort non-gating run.
- [x] Adversarial review over the mandated angles (callback doing work, escaping exceptions, double completion, slot leaks, cancellation/Quiesce/Close races, late completion after destroy, lease scope, policy bypass, method divergence, WebView assumptions in scheduler, dispatched return, GUI-waits-for-workers deadlock); then final report IMPLEMENTATION / TESTS / RUNTIME SMOKE / CI / FREEZE CHECK / KNOWN LIMITATIONS ending exactly `CAP-2 PASS` or `CAP-2 NOT READY`, then STOP — no Phase 3.

**Acceptance Criteria:**
- Given the branch, when `git diff main -- src/rpc/pweb.rpc.intf.pas src/webview/pweb.webview.intf.pas src/assets/pweb.assets.intf.pas src/lib/` runs, then it is empty.
- Given `pwebtests.exe /noenter`, then all CAP-1 and all twenty CAP-2 tests pass headlessly (no window, no DLL-bound webview required for scheduler/lifecycle cases).
- Given `src/rpc/pweb.rpc.scheduler.pas`, when compiled with no `src/webview` unit path, then it compiles — proving source-genericity.
- Given the example on Windows x64, when the page runs, then concurrent JS invocations resolve with correct echoed payloads off the GUI thread.
- Given CI, then every CAP-1 gate is intact and the CAP-2 suite + example compile are gating; GUI run stays non-gating.

## Spec Change Log

## Design Notes

- Headless testability is the load-bearing design move: `TWebViewBinding` takes the native bind/return/unbind entry points as injectable `cdecl`-compatible function pointers (production default = raw ABI). Tests 17/18 then drive real destroy/return races against a recording fake without a desktop session. Internal constructor detail — not a public contract change.
- Scheduler stays RTL-only (classes/syncobjs); JSON envelope parsing and args validation in the binding/tests may use pinned mORMot2 core units per the project include pattern (`src/lib` alone stays mORMot-free). Args validity at `TryEnqueue`: object-or-`'null'` check per frozen contract; the binding hands over Args exactly as extracted.
- Pre-queue rejection envelope is serialized once in the binding from the frozen tables (`PWEB_ENQUEUE_ERROR` → code/text/status); `webview_return` status: 0 for success arm, nonzero for error arm.
- The dummy bridge implements `pweb.echo` (reserved namespace, ratified as the Phase 2 test method) plus scripted-behavior methods for error/delay/cancel paths — all still `Service.Method`-grammar valid.

## Verification

**Commands:**
- `fpc -MObjFPC -Sh -B -FUbuild/fpc -Fusrc/rpc src/rpc/pweb.rpc.scheduler.pas` (no `-Fusrc/webview`) -- compiles: scheduler is webview-free.
- `fpc … test/core/pwebtests.pas && build/test/pwebtests.exe /noenter` -- exit 0, all cases green.
- `pwsh test/core/check_binding_surface.ps1` -- CAP-1 surface + isolation sweeps still green.
- `git diff --exit-code main -- src/rpc/pweb.rpc.intf.pas src/webview/pweb.webview.intf.pas src/assets/pweb.assets.intf.pas src/lib` -- empty: freeze intact.
- Example 02 built and run locally -- window opens, concurrent results render, clean exit (human-visible gate; CI best-effort only).

## Suggested Review Order

**Invocation pipeline core (scheduler)**

- Entry point: the single method canonicalization/validation gate every source shares.
  [`pweb.rpc.scheduler.pas:429`](../../src/rpc/pweb.rpc.scheduler.pas#L429)

- Worker pipeline order: identical canonical method to policy, then bridge; exceptions ⇒ deny/internal_error.
  [`pweb.rpc.scheduler.pas:827`](../../src/rpc/pweb.rpc.scheduler.pas#L827)

- Exactly-once interlocked completion gate; slot release only at completion.
  [`pweb.rpc.scheduler.pas:383`](../../src/rpc/pweb.rpc.scheduler.pas#L383)

- Close hook: source unregisters itself at pssClosed, breaking the scheduler↔source ref cycle.
  [`pweb.rpc.scheduler.pas:760`](../../src/rpc/pweb.rpc.scheduler.pas#L760)

- Whole-runtime shutdown: quiesce all, drain workers, idempotent, never GUI-thread.
  [`pweb.rpc.scheduler.pas:860`](../../src/rpc/pweb.rpc.scheduler.pas#L860)

**WebView source (C boundary safety)**

- The exception-barriered cdecl bind callback: copy id/req, sink-first, enqueue-only.
  [`pweb.webview.binding.pas:364`](../../src/webview/pweb.webview.binding.pas#L364)

- Per-invocation idempotent sink; failures after sink creation complete through its gate.
  [`pweb.webview.binding.pas:315`](../../src/webview/pweb.webview.binding.pas#L315)

- Envelope parse to Method+Args only; pre-queue sync rejections from the frozen tables.
  [`pweb.webview.binding.pas:645`](../../src/webview/pweb.webview.binding.pas#L645)

- webview_return under a short handle-use lease, straight from the worker, never dispatched.
  [`pweb.webview.binding.pas:622`](../../src/webview/pweb.webview.binding.pas#L622)

- Bind: state re-checked under the close-shared lock; native-unbind on the add-failure branch.
  [`pweb.webview.binding.pas:459`](../../src/webview/pweb.webview.binding.pas#L459)

- Single remove+unbind+free routine; GUI-affinity invariant documented at the call sites.
  [`pweb.webview.binding.pas:517`](../../src/webview/pweb.webview.binding.pas#L517)

- Close performs full Quiesce first; no new leases; state delegates to the one source.
  [`pweb.webview.binding.pas:574`](../../src/webview/pweb.webview.binding.pas#L574)

**Policy call site & bridge**

- Explicit allow-all policy — the plumbing Phase 8 swaps, never bypassed.
  [`pweb.capabilities.pas:35`](../../src/security/pweb.capabilities.pas#L35)

- Deterministic dummy bridge: echo, scripted error, raise, delay, gated block with loud timeout.
  [`pweb.rpc.bridge.dummy.pas:12`](../../src/rpc/pweb.rpc.bridge.dummy.pas#L12)

**Runtime proof**

- Page verdict travels back through the pipeline itself; process exit code reflects it.
  [`jsbinding.pas:92`](../../examples/02-js-binding/jsbinding.pas#L92)

- Reporting-bridge decorator capturing the verdict without touching the dummy bridge.
  [`jsbinding.pas:113`](../../examples/02-js-binding/jsbinding.pas#L113)

**Tests (the twenty mandated + review additions)**

- Exactly-once under 60-iteration cancel/complete races — the freeze's core invariant.
  [`pweb.test.rpc.pas:846`](../../test/rpc/pweb.test.rpc.pas#L846)

- Context snapshot fidelity and independence at policy and bridge.
  [`pweb.test.rpc.pas:1083`](../../test/rpc/pweb.test.rpc.pas#L1083)

- Raising handler cannot cross the C frame; complete-then-raise still returns exactly once.
  [`pweb.test.rpc.pas:1395`](../../test/rpc/pweb.test.rpc.pas#L1395)

- Bound-name Unbind: native unbind recorded, callback inert, re-bind works.
  [`pweb.test.rpc.pas:1366`](../../test/rpc/pweb.test.rpc.pas#L1366)

**CI**

- CAP-2 gates: webview-free scheduler compile proves source-genericity mechanically.
  [`ci.yml:117`](../../.github/workflows/ci.yml#L117)

- New src/lib freeze gate pinned to the CAP-2 baseline commit.
  [`ci.yml:224`](../../.github/workflows/ci.yml#L224)
