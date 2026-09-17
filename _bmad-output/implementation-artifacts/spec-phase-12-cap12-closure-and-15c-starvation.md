---
title: 'CAP-12 closes on 12B, and the CAP-15C starvation is measured'
type: 'chore'
created: '2026-09-17'
status: 'in-progress'
route: 'dispatch'
baseline_commit: 'd46d6ada8299e438f9f51704d82b069571084537'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/cap12a-decision-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap12b-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap15c-final-artifact.md'
  - '{project-root}/docs/backlog.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-12 shipped its read side in 12B but has no phase closure, the
upload line has no recorded disposition, and four sentences in `docs/` and the
two SDKs still promise that "CAP-12 brings streaming" — which CAP-12A measured
impossible on WebView2. Separately, FR-M1 claims from a reading of the code
that parked `pweb.socketReceive` long-polls starve every other invocation under
the ratified host defaults; nobody has measured it.

**Approach:** Two things, one branch, separate commits, no product change.
(1) `cap12-closure-artifact.md` over 12A and 12B: the SPEC blob line MET for the
read side; the upload line DEFERRED with its reason (no consumer, the transport
ratified as typed-array windows, both engine faults measured and reported
upstream); the 12C brief kept under `planning-artifacts` as ready; every "when
CAP-12 brings streaming" sentence replaced by the 12A measurement; ledger at 0
orphans. (2) Under the ratified host defaults (4 workers / 4 slots / queue 32),
open N quiet sockets whose receive loops are parked, then time an unrelated
invoke (Add → 42) for N = 0, 3, 4, 5, on the Windows and Linux hosted legs:
per N the latency, whether it is answered inside the 25 s long-poll bound, and
what the queue held — one typed row per N, one ledger entry with the verdict
confirmed / not confirmed and the numbers. Hosted green, then stop.

## Boundaries & Constraints

**Always:** the measurement composes the real scheduler, the real capability
policy, the real socket decorator over the shipped mORMot transport against the
local witness, and the real mORMot SOA bridge; its worker, slot and queue
numbers are read from `PWebDefaultHostOptions` in source, never typed; a macOS
leg says `not_applicable` by name and the aggregator checks both directions;
every new negative check is observed firing; the ledger stays append-only.

**Never:** change a default, add a worker, add a workaround, or touch the
scheduler, the decorator's behaviour, a pin, `PWEB_NATIVE_CSP` or the protocol
version; gate on the verdict itself (both answers are legitimate); begin
CAP-12C; commit `.claude/settings.json` or `mtron-feature-requests.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| control | N = 0 | Add answers 42, typed `served_beside_parked_polls` | a control not served fails the gate |
| below the pool | N = 3, three polls parked | one worker free; typed by what the order of completions shows | recorded, not gated |
| at the pool | N = 4, four polls parked | typed by whether Add completed before or after the first parked poll returned | recorded, not gated |
| past the pool | N = 5 | the fifth open is refused `socket_limit` (the ratified 4-socket host bound), so four polls park | a fifth socket that opened fails the gate |
| never answered | Add outstanding past 2 × 25 000 ms | typed `not_answered`, `within_long_poll_bound=false` | recorded; the program still tears down |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.scheduler.pas` -- `TInvocationScheduler`, `TryGetSourceCounts` (queued/active snapshot). Reuse; do not change.
- `src/rpc/pweb.rpc.socket.pas` -- `Receive` long-polls in 20 ms slices, honours the token; `BeforeDrain` closes and releases synchronously; `PWEB_SOCKET_MAX_SOCKETS = 4`, `PWEB_SOCKET_MAX_WAIT_MS = 25000`. Comment at :46 carries the streaming sentence — the only edit.
- `src/webview/pweb.webview.host.pas:396` -- `PWebDefaultHostOptions`: `Workers := 4`, `MaxConcurrent := 4`, `MaxQueueSize := 32`. Read, never linked (it pulls in the WebView library).
- `tools/templates/react/src/program.lpr` -- the network host adds `PWEB_SOCKET_MAX_SOCKETS` workers and slots (15C-6). Context for the ledger entry; not measured here.
- `test/cap7m/cap7m_runtime.pas`, `test/cap15c/socketlive.pas` -- models for the SOA composition and the witness helpers.
- `test/cap15c/ws_server.js` -- `/idle` accepts and sends nothing.
- `test/cap15c/{build_cap15c,run_cap15c_gates,check_cap15c_contracts}.ps1` -- build, run, K9.
- `test/cap7f/{emit_evidence.ps1,emit_evidence.sh,check_cap7f_aggregate.ps1,check_cap7f_selftest.ps1}` -- rows, per-target checks, refusal floor 248.
- `test/backlog/{check_backlog.ps1,check_backlog_selftest.ps1,dispositions.tsv}`, `docs/backlog.md`, `deferred-work.md` -- the ledger.
- `docs/cli-contract.md:677,845`, `sdk/typescript/src/socket.ts:18,217`, `sdk/pas2js/pweb.native.pas:170,494` -- the sentences. CAP-5's sweep forbids `fetch(`, `EventSource`, bare `WebSocket` and URLs in `sdk/**`, comments included.

## Tasks & Acceptance

**Execution:**
- [ ] `_bmad-output/planning-artifacts/cap12c-brief.md` -- write the 12C brief, `status: ready` -- the brief the closure keeps.
- [ ] docs, SDKs, decorator comment -- replace the four sentences with the 12A measurement -- they point at nothing.
- [ ] `test/cap15c/check_cap15c_contracts.ps1` -- K9 refuses the promise and requires the measurement -- observed firing on the old tree.
- [ ] `_bmad-output/implementation-artifacts/cap12-closure-artifact.md` -- runs, SPEC lines, phase ledger, re-homed rows, 12C handoff, supersessions.
- [ ] ledger -- append the `12-*` closure entries; TSV rows; `7M1-5` closed; seven CAP-12-owned rows re-homed; `docs/backlog.md` counts and tables.
- [ ] `test/backlog/check_backlog.ps1` + self-test -- map `12`; §5d: the closure table carries every 12A/12B/12 key with its TSV digest and verdict, and no open row is owned by `CAP-12`.
- [ ] `test/cap15c/socketstarve.pas` + build + gate runner -- the instrument, four rows, instrument-validity requirements.
- [ ] `test/cap7f/*` -- required, per-target shape checks, `not_applicable` on macOS, three seeded refusals, floor 251.
- [ ] after the hosted measurement -- one ledger entry (`15CS-1`) with the verdict and the numbers, TSV row, `docs/backlog.md`.

**Acceptance Criteria:**
- Given the branch, when `check_backlog.ps1` runs, then 0 orphans, 0 rewords, and the closure table agrees with the TSV.
- Given `docs/`, `sdk/` and the decorator, when searched, then no sentence says CAP-12 brings streaming, and K9 fails on a planted copy.
- Given the Windows and Linux hosted legs, when CAP-15C runs, then four typed `socket_starvation_n*` rows are written and the aggregator accepts them; the macOS legs carry `not_applicable`.
- Given the final HEAD, when hosted CI runs, then all six jobs are green.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

The discriminating fact is ORDER, not a latency threshold: under starvation the
Add can only be claimed after a parked poll has returned, so its completion
follows the first parked completion. Latency is measured from the Add's own
enqueue while the polls were already parked, so a starved Add is answered
*inside* 25 s by construction; `parked_for_ms` is recorded beside it so the
two add up in the log.

Row shape (no comma, no quote — the shell emitter's reader):
`served_after_a_parked_poll_returned latency_ms=24931.2 within_long_poll_bound=true result=42 opened=4/4 open_refused=none parked=4 parked_for_ms=61 active=4 queued=1`

## Verification

**Commands:**
- `pwsh test/backlog/check_backlog.ps1` and `check_backlog_selftest.ps1` -- PASS, 0 orphans, every perturbation refused
- `pwsh test/cap15c/check_cap15c_contracts.ps1`, `build_cap15c.ps1`, `run_cap15c_gates.ps1` -- PASS on Windows and under WSL
- `pwsh test/cap5/check_cap5_nonetwork.ps1`, `test/cap7f/check_schema_agreement.ps1` -- PASS
- the aggregator and its self-test over the run-35158616270 evidence with the four rows injected -- PASS, floor met
- the whole local chain on Windows and WSL before the push
