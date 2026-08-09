---
title: 'PWeb CAP-2 corrective review — unbind userdata lifetime blocker + five hardening items'
type: 'bugfix'
created: '2026-08-09'
status: 'done'
review_loop_iteration: 0
baseline_commit: '7cb57895181af83bcb9c898333aea8a8a3cf0c4e'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/threading-model.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** External human review of `phase/2-cap2-invocation` found one C-boundary blocker — `TPWebBindEntry` is freed after `FNativeUnbind` without checking the native result, so a failed `webview_unbind` leaves C holding a pointer to freed Pascal memory — plus five hardening items (size-check-after-copy, over-permissive method grammar, concrete-scheduler helper coupling, stale shutdown wording, plain reads of interlocked fields).

**Approach:** Corrective pass on the existing branch only. No Phase-2 restart, no redesign, no Phase 3, no frozen-unit change. Fix ownership structurally, add fault-injection tests, keep every existing gate green.

## Boundaries & Constraints

**Always:**
- **Item 1 (BLOCKER) — unbind/bind userdata ownership.** Invariant: once native C can possibly hold `entry`, some Pascal owner MUST hold it until confirmed detach or native destroy. Confirmed-detached results are ONLY `WEBVIEW_ERROR_OK` and `WEBVIEW_ERROR_NOT_FOUND`; any other code ⇒ do NOT free, do NOT pretend success, keep ownership so a later callback stays memory-safe, report the failure at the GUI-affine Pascal call site, keep retry possible. Unbind: entry is not permanently removed/freed until detach confirmed; OK/NOT_FOUND ⇒ remove+release; other ⇒ entry stays alive/tracked and Unbind fails. Close: if any live unbind fails, do NOT enter a falsely successful Closed, do NOT shutter the handle lease as if teardown were safe; leave a safe retryable teardown state (Quiesce semantics may already hold), propagate at the Pascal/GUI boundary; retry can complete teardown later; never a Running→Closed shortcut. Destructor/failure paths: a native-unbind failure must never become dangling userdata just because the Pascal object is released — retaining/quarantining the entry is preferable to UAF. Bind rollback: registry acquires the entry BEFORE native bind and rolls back if native bind fails — never an unchecked cleanup call. No public interface change to solve this.
- **Item 2 — size check before copy.** At the raw callback: copy the id for correlation, create the sink, then determine request size with a BOUNDED scan and reject oversize BEFORE allocating/copying the full request → `invalid_request`, never enqueued, no exception across C. Add an implementation-only hard safety ceiling of 16 MiB (documented as an implementation safety limit, NOT a protocol-v1 wire constant); effective limit = `min(configured MaxRequestBytes, hard ceiling)`; configuration cannot bypass the ceiling. No unbounded `StrLen(req)` on attacker-controlled data — use a bounded C-string length scan. Do not alter the raw upstream ABI unit.
- **Item 3 — exact grammar.** `PWebValidMethod`: exactly TWO non-empty segments (`dots = 1`), case preserved and case-sensitive; keep rejecting `.A`, `A.`, `A..B`, `A/B`, `A B`, non-ASCII/NUL, empty. `TryEnqueue` remains the ONE canonicalization/validation call site; do not move validation into the WebView parser.
- **Item 4 — neutral support unit.** Create `src/rpc/pweb.rpc.support.pas` depending only on `pweb.rpc.intf` (never `pweb.rpc.scheduler`, `pweb.webview.*`, mORMot, platform units). Move generic helpers there (`PWebCopyContext`, `PWebValidContext`, `PWebSuccessResult`, `PWebErrorResult`, `PWebDefaultErrorResult`, and `PWebValidMethod` may live there); scheduler, dummy bridge, binding, tests consume it. WebView result-envelope serialization stays in the binding layer. Moving `PWebValidMethod` does NOT move the gate — production RPC admission still calls it only from `TryEnqueue`. No new core interface.
- **Item 5 — shutdown wording only.** Do NOT add a watchdog or change `IInvocationScheduler.Shutdown`; current WaitFor behavior is not a defect. Correct the Phase-2 spec artifact so it no longer claims scheduler Shutdown must be bounded; state: source Close/Quiesce non-blocking; native destruction gated by lease drain; whole-runtime Shutdown is an off-GUI drain that MAY BLOCK on a non-cooperative bridge; Phase-3 mORMot bridge must observe cooperative cancellation where feasible; frozen signatures unchanged. Do not reopen Phase 0.
- **Item 6 — atomic reads.** Where correctness depends on concurrent visibility (esp. `FLeaseClosed`, `FLeaseCount`, cancellation/lifecycle flags), use a small portable FPC-3.2.2-compatible atomic-read idiom (future ARM64); where a plain read is provably advisory-only, document that instead of wrapping mechanically. No broad threading rewrite.
- All CAP-1 gates and all existing CAP-2 tests stay green (baseline 510 assertions; count may only increase). Re-run: full suite, surface check, Phase-0 freeze diff, src/lib byte freeze, example compile, local smoke if practical.

**Ask First:** any change to `src/rpc/pweb.rpc.intf.pas`, `src/webview/pweb.webview.intf.pas`, `src/assets/pweb.assets.intf.pas`, `src/lib/pweb.lib.webview*.pas` — a genuine frozen-contract contradiction means STOP AND REPORT, never silent edits; pushing, merging, or PR.

**Never:** restarting Phase 2; redesigning architecture; Phase 3 work; public interface changes; a scheduler watchdog; a second canonicalization path in the support unit; leaving ANY path where `C arg → freed TPWebBindEntry` is possible (that is a CAP-2 blocker).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| A. Unbind fails | injected `WEBVIEW_ERROR_INVALID_STATE` | Pascal call reports failure; userdata NOT freed; callback stays memory-safe; retry with OK detaches+frees exactly once | GUI-affine error surfaced |
| B. Unbind not-found | injected `WEBVIEW_ERROR_NOT_FOUND` | treated as safely detached; entry freed exactly once | N/A |
| C. Close, first unbind fails | Quiesce done, injected failure | Closed NOT reported; no lease shutter; retry Close succeeds; final Closed exactly once | retryable teardown state |
| D. Bind rollback | native bind fails / bookkeeping fails | no userdata visible to native code is ever freed; registry rolled back | Bind raises at call site |
| Size at limit | request = effective limit | accepted, enqueued | N/A |
| Size limit+1 | request = limit+1 | rejected before Handler/TryEnqueue, without full copy/alloc | `invalid_request` |
| Ceiling bypass try | MaxRequestBytes > 16 MiB configured | effective limit stays 16 MiB | `invalid_request` above it |
| Grammar | `A.B`, `pweb.echo` / `A.B.C`, `a.b.c.d` | valid / invalid | `invalid_request` |

</frozen-after-approval>

## Code Map

- `src/webview/pweb.webview.binding.pas` -- the blocker: `NativeUnbindAndFree`:517-522 ignores `FNativeUnbind` result before `AEntry.Free`; `Unbind`:524-543 deletes from `FEntries` before confirming detach; `UnbindAllForClose`:545+ pops entries the same way; `Close`:574+ shutters lease (`InterlockedExchange(FLeaseClosed,1)`:590) and closes the source regardless of unbind outcomes; Bind refusal path frees entry:505; raw callback `StrLen(req)`:381 then size check only at `HandleRawInvocation`:652; lease reads `FLeaseClosed`:601,604 / `FLeaseCount`:619 are plain loads. `PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES = 1 shl 20`:70.
- `src/lib/pweb.lib.webview.pas:30-37` -- READ-ONLY: `WEBVIEW_ERROR_OK = 0`, `WEBVIEW_ERROR_NOT_FOUND = 2`, failures negative; `webview_unbind` returns `webview_error_t`.
- `src/rpc/pweb.rpc.scheduler.pas` -- `PWebValidMethod`:175-204 (`dots >= 1` at :204 — change to `= 1`); generic helpers to relocate: `PWebCopyContext`/`PWebValidContext`/`PWebSuccessResult`/`PWebErrorResult`/`PWebDefaultErrorResult` (interface section); `TryEnqueue`:429 stays the only admission gate.
- Helper-coupling consumers to repoint at the new support unit: `src/rpc/pweb.rpc.bridge.dummy.pas:44`, `src/webview/pweb.webview.binding.pas:61`, `test/rpc/pweb.test.rpc.pas:34`, `examples/02-js-binding/jsbinding.pas:41`.
- `test/rpc/pweb.test.rpc.pas` -- fake native functions already injectable (`FakeNativeBind/Unbind/Return` via `TPWebWebViewBindingOptions`); extend the fake unbind with a scriptable result queue for tests A–D; existing cases `UnbindLifecycle`:1366, `RaisingHandlerBarrier`:1395 as idiom.
- `_bmad-output/implementation-artifacts/spec-phase-2-cap2-invocation-pipeline.md` -- record corrective findings/resolutions in its Spec Change Log; rewrite the shutdown-related Known-Limitation wording per Item 5 (its frozen block is untouched — "shutdown bounded" there refers to source teardown, which stays true).
- Toolchain/commands unchanged from Phase-2 spec (FPC 3.2.2, `pwebtests.exe /noenter`, `check_binding_surface.ps1`, freeze diffs vs `main` and `709bf0fee71…` for src/lib).

## Tasks & Acceptance

**Execution:**
- [x] `src/rpc/pweb.rpc.support.pas` -- new neutral RTL unit (deps: `pweb.rpc.intf` only); move the five generic helpers + `PWebValidMethod`; repoint scheduler, dummy bridge, binding, tests, example.
- [x] `src/webview/pweb.webview.binding.pas` -- restructure entry ownership: registry-owns-before-native-bind with rollback on native-bind failure; Unbind/Close confirm detach (OK/NOT_FOUND) before remove+free, otherwise keep/track the entry, fail the call at the GUI boundary, keep retry viable; Close never reaches Closed nor shutters the lease past a failed unbind; destructor path quarantines rather than frees undetached entries; bounded-length size rejection (16 MiB hard ceiling constant, `min` with configured limit) before full request copy; atomic-read idiom or advisory-only documentation for `FLeaseClosed`/`FLeaseCount` and lifecycle flags.
- [x] `src/rpc/pweb.rpc.scheduler.pas` -- `dots = 1` exact grammar (in the relocated `PWebValidMethod`); admission still only via `TryEnqueue`; document/verify advisory-only plain reads it contains.
- [x] `test/rpc/pweb.test.rpc.pas` -- scriptable fake-unbind results; new cases A–D from the matrix plus size tests (at-limit, limit+1, ceiling-bypass, no-full-alloc instrumentation where practical) and grammar tests (`A.B`, `pweb.echo` valid; `A.B.C`, `a.b.c.d` invalid); mutation/fault-injection style; built-in `Check*()` only.
- [x] `_bmad-output/implementation-artifacts/spec-phase-2-cap2-invocation-pipeline.md` -- change-log entry recording findings + resolutions; shutdown-wording rewrite per Item 5.
- [x] Adversarial re-review of the 12 mandated attack angles (failed unbind then callback; failed Close then retry; failed Close then release; bind-bookkeeping failure; oversize without full alloc; ceiling bypass; `A.B.C` bypass; support unit as second canonicalization path; non-WebView source webview-free; late result after Closed; exception across C; double completion/slot release); then final report FIXES / TESTS / FREEZE CHECK / RUNTIME SMOKE / CI STATUS ending exactly `CAP-2 PASS` or `CAP-2 NOT READY`, then STOP. No push, no merge, no Phase 3.

**Acceptance Criteria:**
- Given the fake native unbind scripted to fail then succeed, when Unbind/Close are retried, then no freed entry is ever reachable from the C side and Closed is reached exactly once — no remaining `C arg → freed TPWebBindEntry` path anywhere.
- Given `pwebtests.exe /noenter`, then all previous 510 assertions plus the new cases pass (count only increases).
- Given `fpc -B -FU… -Fusrc/rpc src/rpc/pweb.rpc.support.pas` with no mORMot/webview paths, then it compiles RTL-only; the scheduler webview-free compile still passes.
- Given `git diff main` over the three `.intf` units and `src/lib`, then it is empty.
- Given CI workflow, then every existing gate is unchanged and still green in local equivalents.

## Spec Change Log

- 2026-08-09 (round 3) — Intermittent failure of mandated test 17 ("late completion after Closed") diagnosed as a TEST-side race, production correct: the token-observing `test.block` bridge call completes early on Quiesce, so the worker's cancelled completion could win the exactly-once gate before Close's own cancel loop; its delivery then landed after the lease shutter and was swallowed silently — exactly the documented post-close lease rule — leaving zero returns and diverging the scenario premise (the failure signature was a MISSING return, never an extra one, so no exactly-once/lease violation existed). Fixed with positive synchronization, no sleeps: new `test.blockhard` dummy method (gated like `test.block` but deliberately token-IGNORING, same 30s loud cap) makes Close the deterministic deliverer of the terminal cancelled return, and a single-worker pipeline plus a sentinel invocation on a second source fences the trailing negative assertions — the sentinel can only complete after the worker's late CompleteOnce attempt has run. Evidence: 5/15 failing runs before, 0/22 after; 595 assertions per run; full verification set green.
- 2026-08-09 (round 2) — Adversarial re-review (3 reviewers) applied, 12 findings resolved: C1 guard-page test (PAGE_NOACCESS after exactly limit+1 accessible bytes) pins the bounded-scan/copy-after-check property against regression; C2 the correlation id gets the same bounded-scan discipline (`PWEB_BINDING_MAX_ID_BYTES` = 4 KiB implementation cap; absent/empty/over-cap ids drop inertly — the id IS page-influenced at the pin, comment corrected); C3 Bind treats ANY non-OK native result as refusal (positive informational codes included) and unregisters the entry before a raising injected bind propagates; C4 `PWebBoundedStrLen(AMaxScan <= 0)` defined as -1; C5 quarantine lock/list are process-lifetime leak-by-choice (no finalization free) and the callback captures Owner AND Handler locals; C6 dummy-bridge `FGateOpen` reads use `PWebAtomicRead`; C7 example teardown retries a failed `Binding.Close` once before reporting FAIL (README documents it); C8 CI compiles `pweb.rpc.support.pas` with `-Fusrc/rpc` only as its own gate; C9 `PWebValidArgs` joined `PWebValidMethod` in the support unit (gate unchanged: TryEnqueue); C10 test fixes (default-clamp assert, scripted unbind results leave the fake registry untouched with `RemoveFakeBinding` simulating genuine absence, name-keyed failure scripting instead of call-order, immediate assertions on synchronous fires); C11 debug-only (`$C+`) GUI-affinity `Assert` in Bind/Unbind/Close against a recorded affinity thread id; C12 the `-Fldeps/mormot2/static/x86_64-win64` local link requirement documented in the example README build section. Suite: 593 assertions, 0 failed; all gates re-verified green.
- 2026-08-09 — Implemented as specified. Notable implementation choices within the spec's latitude: the effective size limit is applied by clamping `FMaxRequestBytes` at construction (exposed via internal `EffectiveMaxRequestBytes` for tests); quarantined entries live on a unit-level process-lifetime list with `Owner`/`Handler` nil'ed so a late native callback is provably inert (`PWebQuarantinedEntryCount` is the test hook); ceiling-bypass is tested both by introspection (32 MiB configured → 16 MiB effective) and behaviorally (16 MiB + 64 request rejected `invalid_request`); the binding now depends on `pweb.rpc.support` instead of `pweb.rpc.scheduler` entirely. Local toolchain note: linking `pwebtests`/example 02 locally needs `-Fldeps/mormot2/static/x86_64-win64` (libkernel32.a ships in the pinned mORMot statics); CI is unaffected. Suite: 510 → 582 assertions, exit 0.

## Design Notes

- Ownership restructure sketch: `FEntries` keeps the entry through the whole native-bound interval; Unbind marks the entry `Detaching`, calls native unbind, and only on OK/NOT_FOUND removes+frees; on failure it restores/keeps it tracked (state `Bound` or `DetachFailed`) and raises/reports. Close iterates without popping; any failure leaves remaining entries tracked, source stays Quiescing, lease stays open, Close returns reporting failure; a later Close retries the remaining entries. Destructor: entries still undetached are moved to a process-lifetime quarantine list (leak-by-choice, documented) rather than freed.
- Bounded scan helper: `PWebBoundedStrLen(p: PAnsiChar; MaxScan: PtrInt): PtrInt` scanning at most `effective_limit + 1` bytes; oversize detected when no NUL within the bound.
- Atomic-read idiom for FPC 3.2.2: `InterlockedCompareExchange(field, 0, 0)` (or `InterlockedExchangeAdd(field, 0)`) wrapped in a tiny local helper; apply where a stale read could break correctness (lease gate), document advisory-only reads (e.g. `State`, counters used in tests).

## Verification

**Commands:**
- `fpc -MObjFPC -Sh -B -FUbuild/verify -Fusrc/rpc src/rpc/pweb.rpc.support.pas` -- compiles RTL-only, no mORMot/webview paths.
- `fpc -MObjFPC -Sh -B -FUbuild/verify -Fusrc/rpc src/rpc/pweb.rpc.scheduler.pas` -- webview-free compile still green.
- rebuild + `build/test/pwebtests.exe /noenter` -- exit 0, ≥510 assertions, all new cases listed.
- `pwsh test/core/check_binding_surface.ps1` -- PASS.
- `git diff --exit-code main -- src/rpc/pweb.rpc.intf.pas src/webview/pweb.webview.intf.pas src/assets/pweb.assets.intf.pas src/lib` -- empty.
- Example 02 rebuild + run with `PWEB_SMOKE_AUTOCLOSE_MS` -- page reports ALL, exit 0.

## Suggested Review Order

**Userdata ownership (the blocker fix)**

- Entry point: detach confirmed only on OK/NOT_FOUND — the sole gate to remove+free.
  [`pweb.webview.binding.pas:744`](../../src/webview/pweb.webview.binding.pas#L744)

- Unbind keeps the entry alive/tracked on failure; raises at the GUI boundary, retryably.
  [`pweb.webview.binding.pas:751`](../../src/webview/pweb.webview.binding.pas#L751)

- Close stops before the lease shutter on any failed detach; source stays Quiescing, retry finishes.
  [`pweb.webview.binding.pas:836`](../../src/webview/pweb.webview.binding.pas#L836)

- Bind: registry owns before native bind; ANY non-OK result or raise rolls back safely.
  [`pweb.webview.binding.pas:662`](../../src/webview/pweb.webview.binding.pas#L662)

- Destructor quarantine: leak-by-choice beats UAF; callback exits inertly on nil Owner/Handler.
  [`pweb.webview.binding.pas:634`](../../src/webview/pweb.webview.binding.pas#L634)

**Bounded ingress**

- Bounded scans for req AND id before any copy; 16 MiB hard ceiling, 4 KiB id cap.
  [`pweb.webview.binding.pas:490`](../../src/webview/pweb.webview.binding.pas#L490)

- The bounded-scan primitive with explicit nil/zero-bound semantics.
  [`pweb.webview.binding.pas:261`](../../src/webview/pweb.webview.binding.pas#L261)

- Ceiling clamp at construction: configuration cannot bypass the implementation limit.
  [`pweb.webview.binding.pas:579`](../../src/webview/pweb.webview.binding.pas#L579)

**Neutral support layer**

- Exact two-segment grammar (dots = 1) beside args validation — one home, gate stays in TryEnqueue.
  [`pweb.rpc.support.pas:63`](../../src/rpc/pweb.rpc.support.pas#L63)

- Portable atomic-read idiom (FPC 3.2.2 / future ARM64).
  [`pweb.rpc.support.pas:95`](../../src/rpc/pweb.rpc.support.pas#L95)

**Tests (fault injection)**

- Guard-page test: an unbounded scan or copy-before-check regression faults loudly.
  [`pweb.test.rpc.pas:1949`](../../test/rpc/pweb.test.rpc.pas#L1949)

- Deterministic late-completion teardown: token-ignoring gate + single worker + sentinel fence.
  [`pweb.test.rpc.pas:1613`](../../test/rpc/pweb.test.rpc.pas#L1613)

- Unbind failure / Close retry / quarantine / bind rollback — scripted by name, no ordering dependence.
  [`pweb.test.rpc.pas:1665`](../../test/rpc/pweb.test.rpc.pas#L1665)

- Token-ignoring `test.blockhard` powering the deterministic race scenarios.
  [`pweb.rpc.bridge.dummy.pas:58`](../../src/rpc/pweb.rpc.bridge.dummy.pas#L58)

**Peripherals**

- CI gate: support unit compiles RTL-only/intf-only, before the scheduler.
  [`ci.yml:124`](../../.github/workflows/ci.yml#L124)

- Debug-only GUI-affinity assertion anchoring every ownership proof.
  [`pweb.webview.binding.pas:593`](../../src/webview/pweb.webview.binding.pas#L593)

- Example teardown: bounded Close retry; README documents build flags and failure semantics.
  [`jsbinding.pas:1`](../../examples/02-js-binding/jsbinding.pas#L1)
