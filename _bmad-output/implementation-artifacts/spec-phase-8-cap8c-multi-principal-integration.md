---
title: 'CAP-8C — multi-principal integration and CAP-8 closure'
type: 'feature'
created: '2026-08-24'
status: 'in-progress'
review_loop_iteration: 0
baseline_commit: '949a1fc41c7b9822576869680ee0ef7c9f59c2ec'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-8A froze the contextual policy and CAP-8B froze navigation/bridge isolation, but both are proven only for the single `window:main` principal. Nothing demonstrates that the SAME policy instance differentiates principals: no second real WebView principal, no `pkPlugin` source, no per-principal denial with measured zero bridge/SOA activity, no cross-source context isolation, no end-to-end runtime-grant revocation, and no proof that frontend content cannot choose its principal. CAP-8 cannot close without that multi-principal evidence on all four targets.

**Approach:** One production-quality multi-principal integration harness around the UNCHANGED runtime: MainWindow and LoginWindow as two real privileged WebView sources with natively built contexts, ReportingPlugin as a source-generic native (non-WebView) source through the existing `IInvocationScheduler`/`IInvocationSource` path, one shared immutable policy, the same scheduler/bridge/CAP-8B enforcement on every view, per-method counting evidence and the injected opener seam. A Phase-A MEASUREMENT probe of two-simultaneous-WebView topology on all four targets gates the production design at Checkpoint 1. Four-target CI emits one structured security corpus whose canonical digest must be identical everywhere; canonical CAP-8 status updates only after hosted aggregation is green.

## Boundaries & Constraints

**Always:**
- Measure before building: the multi-WebView topology probe runs on Windows x64, Linux x64, macOS x86_64 and macOS arm64 through the frozen public ABI only; Checkpoint 1 presents the measured tables and HALTS. If any pinned engine cannot hold two simultaneously live WebViews through that ABI, STOP at Checkpoint 1 and present the smallest safe alternative (sequential real Main/Login WebViews + concurrent source-generic isolation tests).
- Frozen surfaces byte-identical: seven core interfaces, `TInvocationContext`, `ICapabilityPolicy` signature, scheduler/source lifecycle, bridge + mORMot adapter, error taxonomy, protocol v1, SDK wire, `app.pwb` format, `src/rpc/*`, `src/webview/*`, `src/security/pweb.capabilities*.pas`, `src/security/pweb.navigation.policy.pas`, `src/assets/pweb.assets.support.pas`, `deps/webview`, CAP-7 platform adapters' public surface, CAP-13. No eighth interface, no new public protocol field, no new webview export.
- Native context is the only identity truth: page filename, query, fragment, DOM, JS objects, localStorage, `app.pwb` fields and handshake payloads have ZERO authorization effect; forged capability/principal fields in Args change nothing; the same trusted frontend corpus must prove both window contexts (content-swap test both directions).
- Every refusal happens before the bridge with measured zero bridge/SOA/opener activity — per-method counting ledgers, never unread zeroes; a broken binding never counts as a successful denial (the zero-cap handshake proves each source alive).
- Both privileged views install the full CAP-8B guard/CSP; one shared policy/configuration path — no platform-specific, window-specific or frontend-specific capability sets; per-invocation snapshots immutable; grants keyed by native PrincipalId exactly as CAP-8A froze them.
- Concurrency evidence uses explicit barriers/counters, never sleeps. Test-first; subject-only commit messages.

**Ask First:** Checkpoint-1 ratification of the multi-window topology (simultaneous vs sequential), the exact principal identity strings and factor sets, and the CI corpus field list; ANY upstream `deps/webview` patch or new export (human authorization required, never assumed).

**Never:** plugin loading/discovery, QuickJS, filesystem/process capabilities, CAP-10 promotion of `pweb.openExternal` into frozen RPC units, HTTP/localhost paths, a second RPC route, a dedicated external-content WebView, changes to CAP-8A policy semantics or the CAP-8B navigation policy, moving policy decisions into services or frontend code, a plugin-specific RPC path.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Main allowed | MainWindow `CalculatorService.Add(20,22)` | 42; service counter exactly 1 | N/A |
| Login denied | LoginWindow same method | forbidden/403; bridge+SOA counters 0 | pre-bridge, policy call site only |
| Plugin denied | ReportingPlugin same method via plugin source | forbidden/403; bridge+SOA counters 0 | same policy instance, same call site |
| Aliveness | `pweb.handshake` from all three principals | succeeds (explicit zero-cap route); snapshot advisory | proves denial ≠ broken binding |
| External open, Main | valid https / valid mailto / invalid scheme | opener exactly once / exactly once / invalid_request, opener 0 | CAP-8B validator unchanged |
| External open, Login+Plugin | valid https/mailto | forbidden/403; opener 0 | policy before host command |
| Raw external nav | any trusted page navigates externally | cancelled; opener 0 | CAP-8B classifier unchanged |
| Method precedence | unknown method / `No.SuchMethod` / malformed / service raise | forbidden / 404 via zero-cap route / invalid_request / internal_error — identical per principal | no principal-specific side channel |
| Grant revoke | native revoke `calculator.add` for Main's principal | next Add forbidden; in-flight invocation completes on its old immutable snapshot; Login/Plugin unchanged; restore affects later snapshots only | frozen PrincipalId-keyed store |
| Untrusted window | otherwise-capable pkWindow context, TrustedContent=false | every method denied incl. zero-cap; all counters 0 | frozen identity check |
| Context isolation | C1–C7: concurrent Main/Login, Main/Plugin, Login/Plugin; forged fields; close-one; backpressure | no context bleed, no cross-source completion, exact service counts (1/1/0) | barriers + counters |
| Lifecycle | close Login → Main functional; reopen Login fresh → old context cannot complete into new source; reverse close order; shutdown drains plugin source, services released last | no callback-after-free, no stale reuse, no double completion | watchdogged, exact-once gate |
| Cross-target | canonical structured security corpus | identical semantic values + one digest on all four targets | aggregator refuses divergence/SKIP/missing |

</frozen-after-approval>

## Code Map

**Frozen / read-only evidence**
- `src/rpc/pweb.rpc.intf.pas:185` — `TInvocationContext` (WindowId/PrincipalId/PrincipalKind/Capabilities/PluginId/TrustedContent); `:181` identity invariants (pkWindow ⇒ WindowId≠''; pkPlugin ⇒ PluginId≠''); `:153` `TPWebPrincipalKind` (pkWindow, pkPlugin, pkSystem, pkQuickJS).
- `src/rpc/pweb.rpc.intf.pas:358` — `IInvocationSource.TryEnqueue(Context, Method, Args, Completion)`: THE plugin path — a native context + a per-invocation sink, no WebView anywhere; `:432` `IInvocationScheduler.RegisterSource(Limits)` / `Shutdown` (never on the GUI thread).
- `src/rpc/pweb.rpc.scheduler.pas:689` — the single CAP-8A policy call site (not moved, not duplicated); `:573` RegisterSource implementation.
- `src/security/pweb.capabilities.policy.pas:135` — builder (`SetAppMaximum`/`SetPrincipalCapabilities`/`SetWindowCapabilities`/`MapMethod`/`RegisterZeroCapMethod`/`Build`); `:225` `SnapshotCapabilities(PrincipalId, WindowId)`; `:237-250` `SetRuntimeGrants`/`RevokeRuntimeGrant`/`ClearRuntimeGrants` — PrincipalId-keyed, intersection-only; `:645` frozen TrustedContent check: an untrusted pkWindow context is denied before the method row is even looked up.
- `docs/kernel.md`, `_bmad-output/specs/spec-pweb/security-model.md` — four-factor model; `threading-model.md` — enqueue/completion/teardown rules the lifecycle tests assert.

**Reuse models (copy the shape, not the files)**
- `examples/08-release/releaseapp.pas:286-311` — `TPolicyContextHandler`: the snapshot-decorating wrapper each window source reuses; `:928-931` native context construction and the identity convention (`PrincipalId='window:main'`, `WindowId='main'`, pkWindow, TrustedContent=True); `:318` `BuildReleasePolicy` builder-call shape; `:338` `pweb.openExternal → external.open` mapping and `:416` `OpenExternalResult` (host-side command STAYS host-side); `:974` guard-install order (asset handler → guard → navigate).
- `test/cap8b/navmatrix.pas` — the instrumented-host pattern: per-method counting bridge (`:551` RequireCount ledger), platform alias + create/attach/teardown order (`:658`), injected opener spy, RTLEvent watchdog, JSON evidence record. CAP-8C's harness is this shape with TWO WebView sources + one plugin source.
- `test/cap8b/fixture/` — driver-corpus model; the CAP-8C fixture reports per-window verdicts without ever determining identity.
- `deps/webview/core/include/webview/detail/engine_base.hh` + `backends/{win32_edge,gtk_webkitgtk,cocoa_webkit}.hh` — run/terminate/loop-ownership and close-one semantics are UNKNOWN facts (global NSApp/gtk_main/GetMessage loops are suspicion, not evidence): the Phase-A probe measures them through the 17-export public ABI only.
- `test/cap7f/emit_evidence.{ps1,sh}`, `check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1` — add the CAP-8C corpus verdict + digest exactly as `navigation_security`/`navigation_policy_digest` were added; `.github/workflows/ci.yml` four target jobs + `cap7-aggregate`.

## Tasks & Acceptance

**Execution — Phase A (topology measurement; ends at Checkpoint 1, HALT):**
- [ ] `test/cap8c/topology.pas` + `run_topology.{ps1,sh}` — a probe host over the frozen public ABI measuring per target: two WebViews created before the loop?, both live concurrently?, which owns `webview_run`?, does closing one stop the loop?, independent binding userdata?, does each handler receive only its own context?, concurrent outstanding invocations?, close-one-keep-one functional? Emits `build/cap8c/topology-<target>.json`.
- [ ] `.github/workflows/ci.yml` — temporary Phase-A topology steps on all four targets + a `cap8c-topology-summary` job; run hosted, collect the four artifacts.
- [ ] **Checkpoint 1** — present MULTI-WEBVIEW RESULT / PRINCIPAL TOPOLOGY / CAPABILITY FACTORS / METHOD MATRIX / FRONTEND FIXTURE / PLUGIN SOURCE / LIFECYCLE / FILES-CODE MAP and the verdict `CAP-8C PLAN READY` or `CAP-8C PLAN BLOCKED`. HALT for human ratification; STOP (no upstream patch, no 18th export) if simultaneous windows need an ABI change.

**Execution — Phase B (production; only after ratification):**
- [ ] `test/cap8c/multiprincipal.pas` — the integration harness: two real WebView sources with native contexts (`window:main`/`main`; `window:login`/`login`; both pkWindow, TrustedContent=True), one native plugin source (`plugin:reporting`, PluginId='reporting', WindowId='', pkPlugin) registered via `RegisterSource` and enqueued with `TryEnqueue`; one shared `BuildCap8cPolicy` (AppMaximum = calculator.add, external.open, settings.read, parking.read, window.control; Main = all five; Login = settings.read, window.control; Plugin = parking.read; mappings and zero-cap rows exactly as the release host, `No.SuchMethod` behavior preserved); counting bridge + production decorators + injected opener; CAP-8B guard on BOTH views.
- [ ] `test/cap8c/fixture/` — one shared trusted corpus for both windows, per-window verdict reporting, forged-Args vectors, content-swap proof (login page in Main context ⇒ Add still 42; main page in Login context ⇒ Add still 403).
- [ ] `test/cap8c/multiprincipal.pas` (same host) — context-isolation C1–C7 with barriers/counters; runtime-grant revoke → in-flight snapshot → restore; TrustedContent=false pkWindow gate; per-principal method/error precedence; the external-open principal matrix; multi-window lifecycle incl. reverse close order, Login reopen with a fresh source (stale context cannot complete into it), scheduler shutdown order (drain → shutdown → release services last).
- [ ] `test/cap7f/emit_evidence.{ps1,sh}` + `check_cap7f_aggregate.ps1` + `check_cap7f_selftest.ps1` + `.github/workflows/ci.yml` — replace topology steps with the production cap8c gate per target; emit the structured security corpus (main_add_result, login/plugin codes, service/opener/bridge counters, untrusted_window_code, grant results, forgery, secure_origin, lifecycle_result…) + one canonical digest; aggregator requires all four targets, refuses missing/SKIP-promotion/denied-SOA>0/non-Main opener/secure=false/digest divergence; add negative self-test legs.
- [ ] `_bmad-output/implementation-artifacts/deferred-work.md` — append residuals (incl. the dedicated-external-view architectural extension point, explicitly NOT built here).
- [ ] CAP-8 final artifact + canonical status update — ONLY after hosted aggregation is green: concise record referencing CAP-8A/CAP-8B closures, the three principal contexts, grant behavior, precedence, platform/lifecycle matrices, CI runs, freeze result, waivers.

**Acceptance Criteria:**
- Given the ratified topology on each of the four targets, when the harness runs hosted, then every I/O-matrix row holds with its exact counters and the security corpus digest is byte-identical across targets.
- Given the full suite, when CAP-7/CAP-8A/CAP-8B/CAP-13 gates re-run, then all stay green and every frozen surface diffs clean.
- Given items 1–24 of the canonical CAP-8 acceptance all pass on hosted CI, when the final artifact is recorded, then canonical CAP-8 status reads closed — and not before.

## Design Notes

- Plugin source = `RegisterSource` + `TryEnqueue` with a native pkPlugin context and a private completion sink — the scheduler is already source-generic; no adapter interface, no WebView, no new route. TrustedContent is set True natively for the plugin but is not an authorization factor for pkPlugin under the frozen model (`pweb.capabilities.policy.pas:645-649`).
- Grants: revoking `calculator.add` targets PrincipalId `window:main` (the frozen key); the in-flight-snapshot proof uses a slow service call held by a barrier across the revoke.
- The harness substitutes a counting bridge for per-method attribution AND drives one real mORMot-bridge leg for the Main path (service counter = TInterfacedObject service), mirroring the CAP-8B split ratified in deferred-work.
- Sequential fallback (only if ratified at Checkpoint 1): Main and Login run as consecutive real windows in one process against the SAME policy/scheduler instances; every concurrency proof then runs source-generically (WebView source + plugin source), which the frozen interfaces support without a second window.

## Verification

**Commands:**
- Phase A: `pwsh test/cap8c/run_topology.ps1` locally, then the hosted four-target run — expected: four `topology-<target>.json` artifacts and the summary table at Checkpoint 1.
- Phase B: `pwsh test/cap8c/run_multiprincipal.ps1` (and `.sh` per target) — expected: harness PASS, every ledger row exact, corpus written.
- `build/test/pwebtests.exe /noenter` — expected: exit 0, CAP-8A + CAP-8B cases still registered and green.
- `pwsh test/cap7f/check_divergence.ps1` and `git diff --exit-code` over every frozen surface — expected: PASS / clean.
- Push → hosted CI: six jobs green including `cap7-aggregate` with the cap8c corpus digest equal on all four targets; only then record CAP-8 closure.
