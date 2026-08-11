---
title: 'PWeb Phase 3 / CAP-3 continuation — real in-process mORMot invocation bridge'
type: 'feature'
created: '2026-08-11'
status: 'done'
review_loop_iteration: 0
baseline_commit: '2904359b77385458fc27b7252b6e46a701d452d5'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-3-cap3-mormot-bridge.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-2 reaches only a dummy bridge; CAP-3 must prove the frozen JS-to-scheduler pipeline invokes mORMot in-process. CAP-3U is closed and its Win64 trampoline is a build invariant.

**Approach:** Add a transport-neutral bridge that snapshots exact service RTTI, strictly validates named JSON, calls `TRestServer.Uri()`, and normalizes results/errors. Prove Add→42, redacted exceptions, worker execution, runtime JS flow, zero network, CI order, and freeze integrity.

## Boundaries & Constraints

**Always:** Preserve Phase-0 and CAP-1/CAP-2; policy remains scheduler→bridge. Match one-dot `Service.Method` and parameters exact-case from an immutable post-registration catalog; exclude pseudo-methods and reserve runtime `pweb.*`. Accept strict JSON object or appropriate `null`; reject missing, extra, duplicate, mis-cased, malformed, and deterministically wrong-typed inputs before `Uri()`. Use `TRestUriParams`, supervisor rights, `llfInProcess`, and a unique body. Check cancellation before dispatch; never abort synchronous `Uri()`. Unwrap metadata-known results and preserve `null`; valid status-422 `TServiceCustomAnswer` maps to `service_error`, unexpected exceptions to redacted `internal_error`.

**Ask First:** Changes to the pin, FPC minimum, frozen interfaces/error codes/grammar/named-only contract, policy/capability model, zero-network architecture, or inability to validate/map exceptions safely.

**Never:** Reopen CAP-3U without regression; edit `mormot.defines.inc`; add network transport, a second scheduler/policy path, GUI dispatch, WebView bridge dependencies, positional args, case folding, exception-text parsing/leakage, Phase 4, push, or merge.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Gate | exact Add, reordered `{a,b}` | naked `42`; worker thread | N/A |
| Routing | unknown/case variant/`pweb.*` collision | rejected before SOA | `method_not_found` or startup refusal |
| Arguments | null/missing/extra/duplicate/case/type/malformed | no execution | `invalid_request` |
| Domain failure | valid 422 custom-answer JSON | safe structured data | `service_error` |
| Exception | service raises marker text | process survives; no marker leaks | `internal_error` |
| Cancellation | token cancelled before entry | no `Uri()` call | `cancelled` |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.intf.pas:333`, `pweb.rpc.scheduler.pas:673-720` — frozen bridge and policy→worker order; read-only.
- `src/rpc/pweb.rpc.support.pas:36-202` — reuse result helpers; add runtime version only.
- `mormot.soa.core.pas:671-789`, `mormot.core.interfaces.pas:147-351` — exact methods and argument/output RTTI; exclude pseudo-indices.
- `test/cap3u/cap3u_unwind.pas:274-287` — proven direct `TRestUriParams` pattern.
- `test/core/pwebtests.pas`, `test/rpc/pweb.test.scheduler.pas` — additive runner and shared fixtures.
- `examples/02-js-binding/jsbinding.pas` — binding/scheduler/reporting/teardown model.
- `.github/workflows/ci.yml:98-197,275-398` — retain CAP-3U and baselines; append CAP-3 gates.

## Tasks & Acceptance

**Execution:**
- [x] `test/rpc/pweb.test.mormot.*.pas`, `test/core/pwebtests.pas` — add failing bridge/routing/integration tests and calculator fixture; retain prior cases.
- [x] `src/rpc/pweb.rpc.support.pas`, `src/rpc/pweb.rpc.mormot.pas` — add version and bridge ownership, catalog, validation, built-ins, direct `Uri()`, normalization, cancellation, and redaction.
- [x] `examples/03-mormot-rpc/` — run existing JS binding/scheduler pipeline with automated Add, worker, and exit verdicts.
- [x] `.github/workflows/ci.yml` — after CAP-3U add clean PPUs, headless/neutral compile, zero-network sweep, and example gates; preserve baselines.
- [x] Authoritative CAP-3 report — adversarial review, all gates/smoke/freeze evidence, no history deletion.

**Acceptance Criteria:**
- Given prepared CAP-3U on FPC 3.2.2 Win64, when headless tests run, then Add returns `42`, rejections precede execution, Boom is redacted `internal_error`, and the process stays healthy.
- Given the runtime example, when page JavaScript invokes Add, then completion returns through `webview_return`, service thread differs from GUI, and the automated verdict exits successfully.
- Given the final diff, when forbidden-network and frozen-path checks run, then no transport exists and Phase-0/1/2 paths match `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`.

## Spec Change Log

## Design Notes

The bridge translates but never authorizes. Catalog entries copy spelling and input/output RTTI; later registration is unsupported. Metadata determines wrapper unwrapping, never payload guessing. Only cataloged `TServiceCustomAnswer` methods may produce status-422 domain JSON.

The adversarial review hardened integer range checks, fail-closed unsupported input kinds, duplicate-key handling for runtime methods, native handshake capability reporting, late cancellation coverage, exception redaction, owned/non-owned server lifetime, same-server recovery after an exception, and automated-smoke failure paths. CAP-2 shutdown semantics remain unchanged: source close completes an in-flight invocation as `cancelled`, while the synchronous `Uri()` call is allowed to finish before server release.

## Verification

**Commands:**
- `.\tools\patch-cap3u.ps1` followed by clean `-B -Xm -dPWEB_CALLMETHOD_UNWIND_PROBE` builds — CAP-3U invariant active before any mORMot PPU reuse.
- Transport-neutral bridge compile and dedicated headless run on FPC 3.2.2 Win64 — 124/124 assertions, exit zero.
- Prepared combined suite — 719/719 assertions (595 unchanged CAP-1/CAP-2 + 124 CAP-3), exit zero.
- Example 03 — `CalculatorService.Add -> 42 on scheduler worker PASS`, clean exit zero.
- Restored dependency baseline without the CAP-3U define — 595/595 assertions; pinned source pristine and generated OBJ absent.
- Forbidden-network search plus `git diff --exit-code 4653ba77... --` frozen paths — no hits/diff; CI YAML parsed successfully.

## Suggested Review Order

**Bridge architecture and dispatch**

- Start at the authorized bridge boundary and direct synchronous Uri dispatch.
  [`pweb.rpc.mormot.pas:452`](../../src/rpc/pweb.rpc.mormot.pas#L452)

- Review immutable exact-case catalog construction and fail-closed method publication.
  [`pweb.rpc.mormot.pas:263`](../../src/rpc/pweb.rpc.mormot.pas#L263)

**Validation and normalization**

- Inspect strict named-input validation, duplicate rejection, and metadata range checks.
  [`pweb.rpc.mormot.pas:343`](../../src/rpc/pweb.rpc.mormot.pas#L343)

- Confirm pinned result-wrapper parsing produces PWeb-native JSON values.
  [`pweb.rpc.mormot.pas:395`](../../src/rpc/pweb.rpc.mormot.pas#L395)

**Runtime pipeline and lifetime**

- Follow the real server, bridge, scheduler, binding, and native-context assembly.
  [`mormotrpc.pas:164`](../../examples/03-mormot-rpc/mormotrpc.pas#L164)

- Verify the machine verdict and worker-thread proof drive process success.
  [`mormotrpc.pas:251`](../../examples/03-mormot-rpc/mormotrpc.pas#L251)

**Regression evidence**

- Review strict input, cancellation, handshake, domain, and redaction cases.
  [`pweb.test.mormot.bridge.pas:62`](../../test/rpc/pweb.test.mormot.bridge.pas#L62)

- Check worker, policy, shutdown-drain, concurrency, and ownership proofs.
  [`pweb.test.mormot.integration.pas:33`](../../test/rpc/pweb.test.mormot.integration.pas#L33)

- Confirm CAP-3 gates remain inside the prepared CAP-3U CI state.
  [`ci.yml:170`](../../.github/workflows/ci.yml#L170)

- End at the additive aggregate-runner registration preserving baseline cases.
  [`pwebtests.pas:58`](../../test/core/pwebtests.pas#L58)
