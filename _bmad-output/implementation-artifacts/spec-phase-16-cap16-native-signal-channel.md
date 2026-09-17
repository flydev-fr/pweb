---
title: 'CAP-16 — the native → page signal channel, the socket door on it, and the caller principal'
type: 'feature'
created: '2026-09-17'
status: 'done'
route: 'dispatch'
baseline_commit: 'f8a99a3f3da01b64cc5747b049ac39b0c6b25653'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/cap16-checkpoint1.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap15c-checkpoint1.md'
  - '{project-root}/docs/backlog.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Native state cannot reach a page except by the page polling it,
and the one door that waits for native state — `pweb.socketReceive`'s parked
long-poll — starves the pool: four quiet sockets hold every worker and slot and
an unrelated invoke waits up to 25 s (`15CS-1`). An application service also
cannot own a blob to its caller (`12-5`).

**Approach:** Signal, then pull (FR-M1): native code bumps a per-topic sequence
from any thread; the host evaluates ONE templated script per tick carrying the
coalesced `(topic, seq)` pairs as a `pweb:signal` DOM event; the page reads
through ordinary invocations. Subscribing is `pweb.signalSubscribe` under
`signal.<topic>`. The socket door moves onto a window-scoped `pweb.socket`
topic and its receive never waits. The mORMot bridge exposes the caller
principal to services through a thread-scoped context.

## Boundaries & Constraints

**Always:** the rulings of `cap16-checkpoint1.md` §2–§9 as ratified there —
exactly one `webview_eval` call in `src/**`, one literal template, printable
ASCII encoding; single-slot hooks owned by the channel; `waitMs` retired with
the 15C supersession recorded; every bound in one constants home and
cross-checked against both SDKs; every negative gate proven to fire; the
composition mechanised once, on Linux.

**Ask First:** a departure from any checkpoint ruling; a bound that moves after
ratification.

**Never:** an eighth interface or a new method on the seven; a protocol
version bump; data or an id on the channel; a change to `PWEB_NATIVE_CSP`, the
fetch or blob units, or any pin; a fan-out hook; a larger default pool as the
starvation fix; QuickJS subscriptions (9A-2).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| subscribe, granted | `{topic:"jobs"}`, `signal.jobs` held | `{topic, seq}` | — |
| subscribe, not granted / undeclared | capability absent, or topic unknown | no subscription, zero scripts | `forbidden` |
| flood | 1000 signals on one topic in one tick | one pair, last seq | — |
| revoke | `signal.jobs` revoked mid-flood | no script carrying `jobs` issued after the revoke returns | — |
| document replaced | navigation / reload / generation switch | the window's subscriptions and queue gone | — |
| hostile topic | quotes, U+2028/2029, `</script>`, NUL, invalid UTF-8 | delivered exactly, nothing runs | encoder escapes |
| receive with waitMs | `{id, waitMs: 25000}` | nothing waits | `invalid_request` |
| N quiet sockets | N = 0…8, loop subscribed, nothing in flight | unrelated invoke < 5 ms | — |
| caller blob | a service calls `PWebCallerBlobPut` | handle owned by the caller | outside a call: refused |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.signal.pas` -- NEW: the channel, pacer, encoder, bounds (written at Checkpoint 1)
- `src/rpc/pweb.rpc.socket.pas:1683-1784` -- `Receive`'s parked loop to remove; `:1222` `PushLocked` is where every queued event signals; `:1938` `AttachPolicy` to retire; `:147` `PWEB_SOCKET_MAX_WAIT_MS`
- `src/rpc/pweb.rpc.mormot.pas:489-495` -- `FServer.Uri(call)`: the caller context wraps it
- `src/webview/pweb.webview.host.pas:184-232,505-552,1101-1113,1199-1235` -- options, trusted-document hook, reload dispatch pattern (busy count), arming and teardown order
- `src/security/pweb.capabilities.policy.pas:263-267` -- the single grants slot
- `src/assets/pweb.blobs.protocol.pas:244,282` -- `PWebBlobPut`, `PWebBlobUrl` (frozen; reused)
- `sdk/typescript/src/socket.ts`, `handshake.ts`, `index.ts`; `sdk/pas2js/pweb.native.pas` -- the SDK twins
- `tools/templates/{react,pas2js}/src/{program.lpr,app.services.pas}` -- composition
- `test/cap15c/{socketstarve,socketlive,sockethost}.pas`, `pweb.test.socket.pas`, `check_cap15c_contracts.ps1` (K5–K8), `run_cap15c_gates.ps1` (L2) -- migrate
- `test/cap12b/bloblive.pas` -- live-harness shape; `test/cap15c/prove_cap15c_composition.sh` -- composition shape
- `test/cap10a/check_dev_trust.ps1` -- section 8; `test/cap7f/{emit_evidence.ps1,.sh,check_cap7f_aggregate.ps1,check_cap7f_selftest.ps1,check_divergence.ps1}`, `test/cap11a/{collection-paths.json,step-applicability.tsv,post-migration-amendments.tsv}`, `.github/workflows/platform-leg.yml` -- evidence plumbing

## Tasks & Acceptance

**Execution:**
- [x] `test/cap16/pweb.test.signal.pas` + `cap16tests.pas` -- the headless suite over a fake view: coalescing, pacing, bounds, grammar, encoder over every byte, capability, revocation race, document replacement, two windows, handshake, the socket loop, the caller principal -- test-first
- [x] `src/rpc/pweb.rpc.socket.pas` -- waitMs retired, signals, `AttachSignals`, keepalive constant -- §6
- [x] `src/rpc/pweb.rpc.mormot.pas` -- caller context + helpers -- §8
- [x] `src/webview/pweb.webview.host.pas` -- the view seam, the one eval, hook derivation -- §2, §5
- [x] templates -- channel composed, `AttachSignals`, methods registered -- §4
- [x] SDKs -- `signal.ts`, socket loop, handshake features; Pas2JS twin; SDK tests -- §6, FR-M1 8
- [x] `test/cap16/{evalprobe,signallive}.pas`, fixtures, `build_cap16.ps1`, `check_cap16_contracts.ps1`, `run_cap16_gates.ps1`, `prove_cap16_composition.sh` -- engine rows, live rows, source gates, composition
- [x] `test/cap15c/*` -- suite, live program, starvation instrument, contracts migrated -- supersessions
- [x] dev-trust §8, CAP-7F/11A plumbing, CI step, ledger, docs -- evidence and records

**Acceptance Criteria:**
- Given the four targets, when the CAP-16 step runs, then every evidence row of the brief is present and typed, `eval_sites_release = 1`, `eval_under_csp = true`, `signal_flood_evals_per_s ≤ 20`, and both policy digests are unchanged.
- Given Windows and Linux, when the starvation instrument runs, then N = 0, 3, 4, 5, 8 each answer 42 in under 5 ms with zero invocations in flight.
- Given the Linux composition, when a created project runs a native worker that signals, then the page updates without polling, 42 answers and listener members are 0.
- Given the whole Windows and WSL chains, when run before the push, then they are green; given the final HEAD, hosted CI is green.

## Implementation Notes

- **The channel is one unit and platform-free.** `src/rpc/pweb.rpc.signal.pas`
  is an `IInvocationBridge` decorator with its own pacer thread; it joined the
  CAP-7F zero-conditional frozen core beside `pweb.rpc.caller.pas`.
- **The pacer runs on a microsecond clock.** A millisecond `GetTickCount64`
  gave 62 scripts where 60 were allowed on Linux (20.67/s against R = 20),
  because a 50 ms tick measured in whole milliseconds rounds in the wrong
  direction. `QueryPerformanceMicroSeconds` and a half-open measuring window
  (`EvalsAtStart` / `EvalsAtEnd`) make the bound exact: 60 scripts in 3 s.
- **Two reference cycles were designed out** rather than broken later: the
  global `PWebSignal` installation holds an uncounted pointer, and the
  channel/door pair is a weak door pointer plus a `ChannelGone` callback the
  channel fires from its own destructor.
- **`busy` for a second receive is retired** (ledger `16-7`), which Checkpoint
  1 had kept: with no wait it describes nothing, and the socket suite now
  measures two loops sharing one queue.
- **The image cannot pin "one script".** FPC materialises the template
  constant twice in the data section, so the composition holds the release
  image to *one distinct* script literal (no `new CustomEvent(` that is not the
  template) and leaves the exactly-one-site claim to K1/K2, which count source.
- **The CAP-10B1 React inventory moved a third time** (`869ff929…`, 80 939
  bytes, 16 files), measured identically on Windows and Linux before the pin in
  `test/cap10b2/run_cap10b2_gates.ps1` was superseded.

## Spec Change Log

- `busy` on a second `pweb.socketReceive` retired after Checkpoint 1 ruled it
  kept; recorded in the checkpoint artifact and as ledger `16-7`.

## Review Triage Log

| finding | verdict | evidence | route |
|---|---|---|---|
| handshake splices `features` without checking for an existing member (blind, edge) | medium | verified in `Handshake`: the splice was unconditional, so a second decorator that advertised `features` would leave two members and a reader keeps the last | patch — merge into the array that is there, three suite cases |
| `DetachView` leaves `FViewAttached` set, so a second `AttachView` raises and its Stalled-clearing loop is dead (blind, edge) | low | verified: `DetachView` cleared `FView` only; `PaceStep` still exits on the nil dispatch, so nothing leaked, but the re-attach path could not run | patch — clear the flag |
| the channel keeps a window's principal binding forever, so a window whose next document belongs to another principal is refused for the life of the process (blind, edge) | medium | verified in `Subscribe`: `t.PrincipalId` is set at creation and only compared afterwards; `DocumentReplacing` dropped subscriptions but kept the name | patch — release the binding when no subscription is left; suite case |
| `PWebCallerBlobPut` concatenates `token` and the URL raw while `type` goes through the encoder (blind) | low | verified at the handle construction: both are 32 hex characters today, so the output is identical; the asymmetry is in the documented producer | patch — encode all three |
| the flood gate sits one script under the ratified bound (blind) | medium | verified: checkpoint 1 section 9 ratifies `3 × R + 1` over a 3 s window and the runner required `≤ 3 × R`; a drain lands on each end of a half-open window, and both targets measure exactly 60 | patch — allow the ratified plus one, in the runner and the aggregator |
| the reload gate pins `lost=5`, a race outcome, rather than the recovery invariant (blind) | medium | verified: the five signals are emitted 150 ms after the call and the page's phase 2 waits 400 ms, so the count is timing, not contract | patch — gate `phase2Seq = resubscribed + missed`, `missed ≥ 1`; aggregator regex widened; selftest case moved to `lost=0` |
| K7 bans `waitMs` from every SDK file, so no SDK suite can assert the retirement (blind) | low | verified in the sweep: it reads `git ls-files -- sdk` including `test/`; the claim it pins is that neither SDK *sends* it | patch — sweep the shipped SDK, require a non-empty file set |
| `docs/cli-contract.md` swallows `waitMs is retired` into one code span, and the gate pinned the typo (blind) | low | verified in both places and in K7's phrase list | patch — reword both and move the needle to `` `waitMs` is retired `` |
| nothing tells an application generated before CAP-16 that its host must register the two signal methods, or every socket fails at open (blind, edge) | medium | verified: the SDK loop subscribes before receiving, and an older `app.services.pas` has no `RegisterZeroCapMethod` for them | patch — the upgrade paragraph in the contract |
| the SDK keepalive receive — the only thing that keeps a quiet socket inside the idle bound — is run by no test (verification-gap, pre-verified) | high | filed with the demonstration: neutering the timer leaves every existing test green | patch — a `node:test` mock-timers case; observed failing on the neutered timer |
| a socket made gone (revocation, navigation, shutdown) signals nothing, so the page learns only on its keepalive (edge) | medium | verified by implementing it: the suite then measured that the channel drops the window's `pweb.socket` subscription *before* the door is told, so the signal reaches nobody; delivering one anyway is what the security ruling forbids | defer — ledger `16-10`, reverted in code, recorded as a known limitation |
| the "bound 0" claim does not cover the channel lock held across `webview_eval` (blind) | low | verified in `Drain`: the lock is held across the eval on purpose, and that is what makes a returned revocation final; the gate's class is event waits | defer — ledger `16-11` |
| nothing removes a `TPWebSignalTarget`, so eight window ids exhaust the bound; the principal is never cleared (blind, edge) | low | verified: window ids are named at composition (`'main'` by default) and never minted at run time, so no shipped host can reach the bound; the principal half is patched above | defer — ledger `16-12` |
| revocation is silent in both SDKs: `ready` rejects only the first refusal (blind, edge) | low | verified: the channel carries no data, so there is nothing to deliver; ledger `16-5` already records that a page re-subscribes | rejected — the fix is new SDK surface the intent excludes (no data on the channel) |
| every generated app runs a pacer thread that wakes once a second (blind) | low | verified: `PaceStep` returns `PACER_IDLE_MS` when nothing is pending; the wake-up is what retries a window whose dispatch the view refused | rejected — the fix trades a measured retry for an idle saving nobody asked for; recorded in the artifact |
| neither SDK enforces `PWEB_SIGNAL_MAX_TOPIC_BYTES` locally (blind) | low | verified: an over-long topic costs one round trip and comes back `invalid_request`, typed | rejected — a guard for a typed refusal already given |
| `DocumentReplacing` / `BeforeDrain` never clear `Outstanding`, so a window could be skipped forever (edge) | false | `Drain` clears `Outstanding` at its top, before any early exit, and the dispatch still runs after a document replacement | rejected on its refutation |
| a cancelled receive discards a ready answer (edge) | false | the invocation is cancelled; its result is discarded by the scheduler either way, and every other door answers `cancelled` first | rejected on its refutation |
| `webview_eval` only queues, so a pair issued before a revocation can execute after it (edge) | false | the claim, in the contract and in the artifact, is that no script carrying a revoked topic is *issued* after the revoking call returns; `Drain` holds the lock across the eval for exactly that reason | rejected on its refutation |
| `WindowLastScript` has no caller (verification-gap, other) | low | verified: the suite reads scripts from its own fake view | rejected — an observer beside `WindowEvalCount` and `EvalCount`, used by no gate but costing nothing |
| both SDKs can subscribe and unsubscribe the socket topic out of order on a reconnect (verification-gap, other; edge) | maybe-false | the ordering depends on scheduler admission, and neither SDK awaits the release; what would settle it is a reconnect test driving `close` and a new `PWebSocket` in the same turn with both invocations captured | defer — recorded here; the socket loop's own keepalive recovers a missed subscription within 20 s |
| both SDKs would fail every socket against a runtime that predates CAP-16 (edge) | medium | verified: `PWEB_SIGNAL_FEATURE` exists and is advertised, and neither loop consults it — but an SDK is shipped with the runtime it matches (one repository, one version), and the real case is an application whose own host is older | patch — the upgrade paragraph above; the feature row stays advisory |

## Verification

**Commands:**
- `pwsh test/cap16/build_cap16.ps1; pwsh test/cap16/check_cap16_contracts.ps1; pwsh test/cap16/run_cap16_gates.ps1` -- expected: all rows green, Windows and WSL
- `pwsh test/cap15c/build_cap15c.ps1; pwsh test/cap15c/check_cap15c_contracts.ps1; pwsh test/cap15c/run_cap15c_gates.ps1` -- expected: green with the migrated rows
- `pwsh test/cap10a/check_dev_trust.ps1` -- expected: PASS, section 8 reported
- the full Windows and WSL CAP chains before the push -- expected: green
