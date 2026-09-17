---
title: 'CAP-16 — the native → page signal channel, the socket door on it, and the caller principal'
type: 'feature'
created: '2026-09-17'
status: 'in-progress'
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
- [ ] `test/cap16/pweb.test.signal.pas` + `cap16tests.pas` -- the headless suite over a fake view: coalescing, pacing, bounds, grammar, encoder over every byte, capability, revocation race, document replacement, two windows, handshake, the socket loop, the caller principal -- test-first
- [ ] `src/rpc/pweb.rpc.socket.pas` -- waitMs retired, signals, `AttachSignals`, keepalive constant -- §6
- [ ] `src/rpc/pweb.rpc.mormot.pas` -- caller context + helpers -- §8
- [ ] `src/webview/pweb.webview.host.pas` -- the view seam, the one eval, hook derivation -- §2, §5
- [ ] templates -- channel composed, `AttachSignals`, methods registered -- §4
- [ ] SDKs -- `signal.ts`, socket loop, handshake features; Pas2JS twin; SDK tests -- §6, FR-M1 8
- [ ] `test/cap16/{evalprobe,signallive}.pas`, fixtures, `build_cap16.ps1`, `check_cap16_contracts.ps1`, `run_cap16_gates.ps1`, `prove_cap16_composition.sh` -- engine rows, live rows, source gates, composition
- [ ] `test/cap15c/*` -- suite, live program, starvation instrument, contracts migrated -- supersessions
- [ ] dev-trust §8, CAP-7F/11A plumbing, CI step, ledger, docs -- evidence and records

**Acceptance Criteria:**
- Given the four targets, when the CAP-16 step runs, then every evidence row of the brief is present and typed, `eval_sites_release = 1`, `eval_under_csp = true`, `signal_flood_evals_per_s ≤ 20`, and both policy digests are unchanged.
- Given Windows and Linux, when the starvation instrument runs, then N = 0, 3, 4, 5, 8 each answer 42 in under 5 ms with zero invocations in flight.
- Given the Linux composition, when a created project runs a native worker that signals, then the page updates without polling, 42 answers and listener members are 0.
- Given the whole Windows and WSL chains, when run before the push, then they are green; given the final HEAD, hosted CI is green.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `pwsh test/cap16/build_cap16.ps1; pwsh test/cap16/check_cap16_contracts.ps1; pwsh test/cap16/run_cap16_gates.ps1` -- expected: all rows green, Windows and WSL
- `pwsh test/cap15c/build_cap15c.ps1; pwsh test/cap15c/check_cap15c_contracts.ps1; pwsh test/cap15c/run_cap15c_gates.ps1` -- expected: green with the migrated rows
- `pwsh test/cap10a/check_dev_trust.ps1` -- expected: PASS, section 8 reported
- the full Windows and WSL CAP chains before the push -- expected: green
