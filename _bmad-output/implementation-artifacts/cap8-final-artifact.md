# CAP-8 — Final Artifact: Contextual Authorization and Bridge Isolation

CAP-8 closes on hosted run **32827378066** (2026-08-25, commit `a59638b`,
branch `phase/cap-8/c-multi-principal`): all six jobs green, `cap7 aggregate`
recording `security_corpus: PASS (denied_soa=0 opener_nonmain=0 secure=true)`
on every target and ONE `security_corpus_digest`
`c5fc378bc3c6eb6aa6db753e35287db5cb7ed6332aeac77b75767919e5adbdf4` equal on
windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64 — the same digest
independently measured on the dev host (Windows) and under WSL Xvfb (Linux).

Component closures (referenced, not restated):
- **CAP-8A** — capability policy core: closure commit `2a8a4a2`, hosted run
  32195981406; artifact `spec-phase-8-cap8a-capability-policy-core.md`.
- **CAP-8B** — privileged navigation and bridge isolation: closure record in
  `spec-phase-8-cap8b-privileged-navigation.md` (commit `949a1fc`), hosted
  run 32742436382.
- **CAP-8C** — multi-principal integration: artifact
  `spec-phase-8-cap8c-multi-principal-integration.md`; measurements and
  ratifications R-C1..R-C4 in `cap8c-topology-findings.md`.

## Native trust source
`TInvocationContext` is built by native host code at the binding/source; JS
supplies method + arguments only. The content-swap gate (Main serving the
nominal login page still computes 42; Login serving the nominal main page
stays forbidden) and the forged-Args vectors prove page content, filenames,
query strings, manifests and handshake payloads have zero authorization
effect — on all four targets, pinned by the corpus digest.

## Capability model
Grammar `[a-z0-9]+(\.[a-z0-9]+)*`, exact match; `Effective = AppMaximum ∩
Principal ∩ Window ∩ RuntimeGrants`; absent factor = unrestricted, explicit
empty = no rights; all-of method mapping; unknown/unmapped denied;
`forbidden` outranks `method_not_found`; explicit zero-cap registration
(handshake, echo, report, the recorded `No.SuchMethod` 404 route); policy at
the single scheduler call site (`pweb.rpc.scheduler.pas:689`), frozen.

## The three principals (CAP-8C harness)
- MainWindow — pkWindow, `window:main`/`main`, TrustedContent=true: full
  factor set; Add=42 through the real mORMot SOA bridge, service counter
  exactly 1; `pweb.openExternal` https+mailto → injected opener exactly once
  each, invalid scheme → `invalid_request` with opener untouched.
- LoginWindow — pkWindow, `window:login`/`login`: distinct real WebView in
  the same process; Add and openExternal forbidden/403 with ZERO bridge/SOA/
  opener activity (per-method counting ledger, not unread zeroes); alive by
  zero-cap handshake AND an allow-side proof (settings.read succeeds through
  the real window, counter exactly 1).
- ReportingPlugin — pkPlugin, `plugin:reporting`, PluginId `reporting`,
  WindowId '': a source-generic non-WebView source through frozen
  `RegisterSource`/`TryEnqueue`; same policy instance, same bridge
  decorators; Add/openExternal forbidden with zero downstream activity;
  handshake completes. No plugin engine, loading, discovery or QuickJS.

## Runtime grants
PrincipalId-keyed, intersection-only (frozen CAP-8A store): revoking
`calculator.add` from `window:main` forbids the next Add while a
barrier-held in-flight Add completes on its immutable pre-revoke snapshot;
Login/Plugin decisions unchanged; restore affects later snapshots only.

## Method/error precedence (identical per principal, digest-pinned)
mapped+allowed → result; mapped+denied → forbidden/403; unknown → forbidden;
`No.SuchMethod` → zero-cap route to the bridge's 404 (recorded
compatibility); malformed → invalid_request; service raise → internal_error.

## External-open authorization
OS opening is an authorization decision: `pweb.openExternal → external.open`
checked pre-bridge; raw external navigation is ALWAYS cancelled in both
privileged windows and never reaches an opener (guard cancelled ≥1 per
window; opener total exactly the authorized Main calls; non-Main opener
count 0 refused by the aggregator). Host-side command placement retained;
CAP-10 promotion remains ledgered.

## Navigation / bridge isolation
Both windows install the full CAP-8B guard + unconditional native CSP; the
CAP-8B navmatrix and headless suites stayed green throughout
(`navigation_policy_digest 360d69f2…` unchanged, four-way equal);
TrustedContent=false pkWindow contexts are denied before method lookup with
all counters zero.

## Platform matrix and lifecycle
R-C1: two simultaneously live WebViews measured supported on all four
targets (topology probe, hosted run 32748017833). R-C2: source-level
close/reopen on long-lived views; stale context cancelled exactly once and
unable to complete into a fresh source; reverse close order; destroy
post-loop reverse order; terminate owner-only at shutdown. R-C3: the Windows
thread-global-terminate nondeterminism and macOS mid-loop destroy(second)
crash are recorded measured limitations. R-C4: the private Cocoa
guard-registry per-view arming extension was human-ratified and shipped with
no public ABI change, no new export, no upstream patch, decisions untouched.
POSIX asset arming is once-per-process (context/process-wide registration
serving both views); Windows is per-controller.

## CI
Four-target matrix + `cap7-aggregate`: `security_corpus` must-PASS,
`security_corpus_digest` equality, refusals for denied-SOA>0, non-Main
opener>0, secure≠true, SKIP promotion, missing evidence, digest divergence —
each refusal branch proven red by the 12+2-leg negative self-test on every
hosted run. Closure run: 32827378066. Red→green trail: 32770563751 (POSIX
single-arming), plus the CAP-8B trail recorded in its closure.

## Freeze result
Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, scheduler/
source lifecycle, bridge + mORMot adapter, nine-code taxonomy, protocol v1,
SDK wire, `app.pwb`, CAP-8A policy core, CAP-8B classifier/CSP, CAP-13:
byte-unchanged (mechanical diff, divergence sweep 64 allowlisted
conditionals). The sole frozen-file delta is the R-C4-ratified Cocoa
guard-registry extension. No eighth interface, no new public protocol field,
no new webview export.

## Waivers / deferred
See `deferred-work.md` (CAP-8B + CAP-8C entries): release-host openExternal
success path (retired by the CAP-8C real-window gate; copy consolidation
residual), download-event real-window depth, R-C3 limitations, macOS
post-loop destroy first-measured by the production gate, dedicated
external-view architectural extension point (NOT built), `ci.yml`/ledger doc
budgets, CAP-13 clean-machine legs per standing waiver,
`security-model.md` R-A rewording (doc-only follow-up).

**CAP-8 PASS — CONTEXTUAL AUTHORIZATION AND BRIDGE ISOLATION FROZEN**
