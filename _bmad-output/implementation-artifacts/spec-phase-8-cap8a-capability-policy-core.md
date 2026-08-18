---
title: 'CAP-8A — contextual capability-policy foundation'
type: 'feature'
created: '2026-08-18'
status: 'done'
review_loop_iteration: 0
baseline_commit: '402add26a4037f8b875b0dd343ab80dcb44af676'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every invocation is authorized by `TAllowAllCapabilityPolicy`; the ratified contextual model (`Effective = AppMaximum ∩ Principal ∩ Window ∩ RuntimeGrants`, security-model.md) has no production implementation, so the release host cannot restrict any principal.

**Approach:** Add a platform-neutral production capability engine in `src/security/` behind the frozen `ICapabilityPolicy` — native Pascal builder → immutable policy object, exact grammar, fail-closed mapping, thread-safe runtime grants, per-invocation immutable snapshots — swap the shared release host's policy construction, and prove it with a headless A1–A35 suite plus I1–I10 integration gates on all four CI targets. No RPC-path, navigation, QuickJS, or plugin work.

## Boundaries & Constraints

**Always:**
- Frozen surfaces byte-identical: `src/rpc/pweb.rpc.intf.pas` (Phase-0 baseline), `src/security/pweb.capabilities.pas` (CAP-3 sweep), scheduler, bridge, binding, wire/protocol v1, nine-code taxonomy, SDK payloads, `app.pwb` format.
- The single policy call site stays `pweb.rpc.scheduler.pas:689`; deny ⇒ `forbidden`/403 pre-bridge; policy exception ⇒ deny completed as `internal_error` (ratified in `pweb.rpc.intf.pas:300-311`).
- `forbidden` outranks `method_not_found`; unknown/unmapped ⇒ deny (security-model.md:29-35 DECIDED).
- Grammar `[a-z0-9]+(\.[a-z0-9]+)*`, exact compare, no wildcards; absent factor = unrestricted ≠ explicit empty = no rights; `AppMaximum` mandatory.
- No platform conditional in `src/security/`; `src/security/` stays RTL-only (no mORMot, no webview units).
- Policy configuration only from native Pascal builder code in the host; never from `app.pwb`, manifest, JS, environment, or files.
- Construction fails atomically on any malformed/duplicate/contradictory row.
- Test-first; subject-only commits; evidence via spies/counters, not inference.

**Ask First:** any edit to a frozen file or interface; any new public kernel interface; any deviation from the Checkpoint-1 ratified decisions D1–D10; splitting `ci.yml`.

**Never:** CAP-8B navigation/bridge-removal, QuickJS, plugins, filesystem/process capabilities, CAP-10 CLI, external policy files (JSON/YAML/TOML), JS-supplied security fields, second policy call site, `method_not_found` decided by parsing mORMot error text.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Allowed | MainWindow ctx, `CalculatorService.Add` mapped `calculator.add` ∈ Effective | bridge invoked exactly once → 42 | N/A |
| Denied | LoginWindow/plugin ctx, cap absent | `{"code":"forbidden",...,"status":403}`; bridge/SOA counter = 0 | canonical envelope only |
| Unmapped | catalog-known method, no policy row | forbidden, zero SOA | fail closed |
| Not in catalog, mapped | policy allows, bridge catalog miss | `method_not_found` (bridge, post-policy) | existing contract preserved |
| Zero-cap registered | `pweb.handshake` / `pweb.echo` explicit empty requirement | allowed (context still validated) | distinct from unmapped |
| Malformed ctx | empty PrincipalId, or pkWindow with TrustedContent=false | deny | no exception text to frontend |
| Forged args | origin/capabilities/principal fields inside Args JSON | ignored — decision unchanged | N/A |
| Policy exception | implementation raises in IsAllowed | deny, `internal_error`, never allow | barrier at call site (existing) |
| Grant revoked | native revoke between two invocations | next snapshot denied; in-flight keeps captured snapshot | race-free under lock |
| Config error | duplicate cap, bad grammar, missing AppMaximum | builder raises; no partially valid policy | host fails to start |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.intf.pas` — FROZEN contract: `ICapabilityPolicy` :312-318 (exception⇒deny⇒`internal_error` :300-311), `TInvocationContext` :185-192 (invariants :181-184, deep-copy rule :176-179), `TPWebCapabilities` :164 (grammar comment :160-163), `TPWebPrincipalKind` :153-158, taxonomy :92-102, `PWEB_ERROR_STATUS` 403 :491, reserved `pweb.*` :63-71. Read-only.
- `src/rpc/pweb.rpc.scheduler.pas` — policy call site :689 (exception→`internal_error` :691, deny→`pecForbidden` :698, bridge only after :704); canonical method single gate `TryEnqueue` :282-335 (snapshot copy :305-307). Read-only.
- `src/rpc/pweb.rpc.support.pas` — `PWebCopyContext` :155-164, `PWebValidContext` :166-176 (pkWindow⇒WindowId, pkPlugin⇒PluginId, else true), `PWebValidMethod` :103-133. Read-only.
- `src/rpc/pweb.rpc.mormot.pas` — bridge: handshake echoes `Context.Capabilities` :469-477; reserved-namespace 404 :478-480; strict catalog `FindMethod` :481-483 (built :263-333). Read-only — handshake needs no change once hosts populate `Capabilities`.
- `src/security/pweb.capabilities.pas` — FROZEN allow-all (CI sweep `ci.yml:721-734`, baseline `4653ba77…`). Keep byte-identical; still used by examples 02-06 and existing tests.
- `src/security/pweb.capabilities.policy.pas` — NEW: whole production engine (see Tasks).
- `examples/08-release/releaseapp.pas` — swap point :606-607 (`TAllowAllCapabilityPolicy.Create`); context build :654-658 (`Capabilities` currently never assigned); sole service `CalculatorService.Add` :599-600.
- `test/rpc/pweb.test.scheduler.pas` — deny-path/spy patterns to imitate: `TDenyAllPolicy` :59, `TRaisingPolicy` :65, `TRecordingAllowPolicy` :73, snapshot-immutability tests :757-792.
- `test/core/pwebtests.pas` — `TSynTests` runner; register new cases :48-69.
- `.github/workflows/ci.yml` — pwebtests compile :600-610 (add `-Futest/security`), isolation-compile precedent :480-481, CAP-3 freeze sweep :721-734, cap7f evidence blocks :1446-1485/:1785-1815/:2176-2198/:2503-2525, aggregator job :2635-2725.
- `test/cap7l/build_cap7l.sh:112-118`, `test/cap7m/build_cap7m.sh:83-93` — POSIX unit paths (add `-Futest/security`); marker greps `run_cap7l_gates.sh:56-61`, `run_cap7m_gates.sh:131-143`.
- `test/cap7f/emit_evidence.ps1:241-274`, `emit_evidence.sh`, `check_cap7f_aggregate.ps1:50-73`, `check_cap7f_selftest.ps1`, `check_divergence.ps1:59-74` — evidence field + core zero-conditional list (new unit must be added; ledgered fingerprint upgrade `deferred-work.md:184-185` fires here).

## Tasks & Acceptance

**Execution:**
- [x] `src/security/pweb.capabilities.policy.pas` — new RTL-only unit: `PWebValidCapability` (ratified regex + 128-byte bound, D2); canonical sorted-unique set type + exact intersection with absent-vs-explicit-empty representation; `TPWebCapabilityPolicyBuilder` (AppMaximum, per-principal + per-window static sets, method→required-set rows incl. explicit zero-cap registration; every setter validates; `Build` raises `EPWebCapabilityConfig` on any invalid/duplicate/missing-AppMaximum state); immutable `TPWebCapabilityPolicy` (`ICapabilityPolicy`: context-identity checks D5/D6 → mapping lookup → `required ⊆ AppMaximum ∩ Context.Capabilities`, all-of, fail closed); thread-safe runtime-grant store keyed by PrincipalId (lock-guarded set/revoke/snapshot, copy-on-read); `SnapshotCapabilities(principal…)` = `AppMaximum ∩ Principal ∩ Window ∩ Grants` (D1) for native context construction.
- [x] `test/security/pweb.test.capabilities.pas` — new `TSynTestCase`s covering A1–A35 exactly (grammar A1-A6; construction/intersection A7-A15; mapping A16-A22; context/forgery A23-A26; exception A27; grants/concurrency A28-A30; advisory A31-A32; envelope A33-A35) with counting spies; register in `pwebtests`.
- [x] `test/security/pweb.test.capabilities.integration.pas` — reference config (AppMaximum + MainWindow/LoginWindow/ReportingPlugin + mapping incl. `SettingsService`/`ParkingService` deterministic test services with invocation counters, `GhostService.Ping` mapped-but-unregistered for I7) through real `TInvocationScheduler` + `TMormotInvocationBridge`: gates I1–I10; register in `pwebtests` (guarded like existing mORMot cases).
- [x] `examples/08-release/releaseapp.pas` — build production policy via builder (reference config incl. `pweb.handshake`/`pweb.echo` zero-cap and `CalculatorService.Add → calculator.add`); replace allow-all at :607; populate MainWindow context `Capabilities` from `SnapshotCapabilities` per invocation via a host-private `IWebViewInvocationHandler` wrapper (D9); Add → 42 preserved.
- [x] `.github/workflows/ci.yml` + `test/cap7l/build_cap7l.sh` + `test/cap7m/build_cap7m.sh` + marker greps — add `-Futest/security`, isolation-compile the new unit on all legs, add case-marker greps (Linux/macOS).
- [x] `test/cap7f/emit_evidence.ps1` + `emit_evidence.sh` + `check_cap7f_aggregate.ps1` + `check_cap7f_selftest.ps1` — add `capability_policy` evidence field (suite verdict + policy-decision digest), `$required` + `$mustPass` + `$equalityFields`, one negative selftest leg; keep LF/no-BOM/ordinal rules.
- [x] `test/cap7f/check_divergence.ps1` — add new unit to the zero-conditional core list and land the ledgered per-file fingerprint upgrade (`deferred-work.md:184-185`).
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` — close/append entries (fingerprint upgrade RESOLVED; ci.yml size RECORDED; static-template WebView grant-freshness note if D9 narrowed).

**Acceptance Criteria:**
- Given the reference config, when MainWindow invokes `CalculatorService.Add`, then result 42 and service counter = 1 (I1); when LoginWindow or ReportingPlugin invokes it, then forbidden/403 and counter = 0 (I2/I3).
- Given a native grant revocation, when the next invocation is enqueued, then it is denied while an already-enqueued invocation keeps its captured snapshot (I4, A28-A29).
- Given any deny (unmapped, empty factor, malformed context, policy exception), when evaluated, then zero bridge/SOA activity and the canonical envelope (I5/I6, A34-A35); exceptions complete as `internal_error` per the frozen contract.
- Given a method mapped but absent from the bridge catalog, when allowed by policy, then existing `method_not_found` behavior is preserved (I7); `pweb.handshake` remains callable via its explicit zero-cap registration (I8) and its capability list is advisory only (A31).
- Given the four CI targets, when the suite runs, then structured decisions are identical, cap7 gates and freeze sweeps stay green, and hosted CI is fully green (acceptance 17-20).

## Design Notes

- D1 (Checkpoint-1 ratified): `Context.Capabilities` = native per-invocation effective snapshot `AppMaximum ∩ Principal ∩ Window ∩ RuntimeGrants`; `IsAllowed` recomputes `AppMaximum ∩ Context.Capabilities` as defense in depth. Handshake then advertises the true effective set with zero bridge changes.
- Precedence consequence (ratified, security-model.md:33-35): through the production host an unknown method now yields `forbidden` (allow-all previously let it reach the bridge's 404). Verify no existing release-host gate asserts `method_not_found` for unknown methods before landing.
- Examples 02-06 deliberately keep `TAllowAllCapabilityPolicy` (earlier-phase demos; frozen file remains in use).

## Verification

**Commands:**
- Windows: `fpc` pwebtests compile line (ci.yml:600-610 + `-Futest/security`) then `build/test/pwebtests.exe /noenter` — expected: exit 0, new cases listed, zero failed assertions.
- Isolation: `fpc -Fusrc/rpc -Fusrc/security src/security/pweb.capabilities.policy.pas` — expected: compiles RTL-only.
- `git diff --exit-code src/security/pweb.capabilities.pas src/rpc/pweb.rpc.intf.pas src/rpc/pweb.rpc.scheduler.pas src/rpc/pweb.rpc.support.pas src/rpc/pweb.rpc.mormot.pas src/webview/` — expected: clean (frozen surfaces untouched).
- Push branch → hosted CI: all six jobs green including `cap7-aggregate` with the new `capability_policy` field equal across four targets.

## Suggested Review Order

**The capability engine (the security core)**

- Entry point: the immutable policy — identity checks, mapping lookup, `required ⊆ AppMaximum ∩ Context.Capabilities`, fail closed.
  [`pweb.capabilities.policy.pas:189`](../../src/security/pweb.capabilities.policy.pas#L189)

- Builder: native trusted config, atomic `Build`, refuses malformed/duplicate/contradictory rows.
  [`pweb.capabilities.policy.pas:135`](../../src/security/pweb.capabilities.policy.pas#L135)

- Grammar validator: ratified regex plus the D2 128-byte bound, no normalization.
  [`pweb.capabilities.policy.pas:96`](../../src/security/pweb.capabilities.policy.pas#L96)

- Absent-vs-explicit-empty factor representation and exact intersection — the DECIDED defaults, encoded.
  [`pweb.capabilities.policy.pas:89`](../../src/security/pweb.capabilities.policy.pas#L89)

- Runtime grants: lock-guarded, refuses out-of-ceiling grants, copy-on-read snapshots (D7).
  [`pweb.capabilities.policy.pas:237`](../../src/security/pweb.capabilities.policy.pas#L237)

- `SnapshotCapabilities` — the D1 four-factor per-invocation snapshot builder.
  [`pweb.capabilities.policy.pas:225`](../../src/security/pweb.capabilities.policy.pas#L225)

**Production wiring (release host)**

- Reference production policy: ceiling, window/principal sets, mapping, zero-cap runtime methods.
  [`releaseapp.pas:261`](../../examples/08-release/releaseapp.pas#L261)

- D9 wrapper: populates only `Context.Capabilities`, per invocation, from the native snapshot.
  [`releaseapp.pas:199`](../../examples/08-release/releaseapp.pas#L199)

- The single swap point — allow-all replaced, call site untouched.
  [`releaseapp.pas:699`](../../examples/08-release/releaseapp.pas#L699)

**Runtime deny proof (review finding P1)**

- Acceptance page probes unmapped `Denied.Probe`, expects forbidden/403; allow-all would 404.
  [`App.tsx:65`](../../examples/04-react/frontend/src/App.tsx#L65)

- `"denied":true` anchored release-side only, so allow-all regression goes red on four targets.
  [`run_host_args_gate.ps1`](../../test/cap7f/run_host_args_gate.ps1)

**Headless proof suites**

- A1–A35 matrix: grammar, intersection, mapping, forgery, exception barrier, grants, concurrency, envelope.
  [`pweb.test.capabilities.pas:60`](../../test/security/pweb.test.capabilities.pas#L60)

- I1–I10 through real scheduler → policy → mORMot bridge with SOA counters.
  [`pweb.test.capabilities.integration.pas:96`](../../test/security/pweb.test.capabilities.integration.pas#L96)

- Registration on all four targets (Windows I-gates ride cap3tests' CAP-3U window).
  [`pwebtests.pas:122`](../../test/core/pwebtests.pas#L122)

**CI evidence & guards**

- `capability_policy` + digest join required/must-pass/equality fields — four targets, one decision set.
  [`check_cap7f_aggregate.ps1:54`](../../test/cap7f/check_cap7f_aggregate.ps1#L54)

- Emitters: corpus honesty checks, digest, freshness delete before the suite.
  [`emit_evidence.ps1:266`](../../test/cap7f/emit_evidence.ps1#L266)

- Ledgered fingerprint upgrade: count-preserving conditional swaps now a named refusal.
  [`check_divergence.ps1:151`](../../test/cap7f/check_divergence.ps1#L151)

- Registration anchors so "never ran" can't pass as "all passed" (POSIX + Windows).
  [`run_cap7l_gates.sh:64`](../../test/cap7l/run_cap7l_gates.sh#L64)

**Ledger**

- Fingerprint RESOLVED, ci.yml size RECORDED, zero-cap ship decision RECORDED, strict-mode DEFERRED.
  [`deferred-work.md`](deferred-work.md)

## CAP-8A closure

**CAP-8A CLOSED (2026-08-19).** Closure commits on `phase/cap-8/a-capability-policy-core`: `0622501` (engine + suites + host swap + CI evidence, post-adversarial-review with all 11 patch findings applied) and `8a8e8b2` (Darwin `TThreadID` portability in the I1 gate; the pas2js page gains the same `Denied.Probe`/`denied` verdict field because the Linux release layout packs the pas2js corpus last). Final green hosted run `32193855004` **attempt 2** — attempt 1 failed only in `windows` at the CAP-6 release runtime smoke with "state=0; no report received", a hosted-runner WebView2 flake on a step whose inputs (React corpus + policy) were byte-identical to the previous green execution of that step in run `32192162842`; `gh run rerun --failed` went green (the same flake family as the recorded CAP-7F closure attempt). All six jobs green including `cap7-aggregate`; the platform matrix records `capability_policy = PASS` on all four targets with one shared decision digest `23b87da524b158f4b1a8ca53057ad794f485086257997534b426b28334bddb2f`, equal to the dev-host digest — identical structured policy decisions on Windows x64, Linux x64, macOS x64, macOS arm64. Run `32192162842` additionally proved the deny-probe counterfactual matrix: Windows green with the probe while Linux (pas2js corpus without the probe) refused — the anchor demonstrably turns red when a corpus lacks the forbidden proof.
