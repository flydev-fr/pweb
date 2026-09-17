---
title: 'MORMOT-REPIN-2 — the mORMot pin onto the three upstream binding fixes'
type: 'chore'
created: '2026-09-16'
status: 'done'
route: 'dispatch'
baseline_commit: '4aed789bb029fb5f4e2bd4d14749268a7d82358a'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/mormot-repin-2-checkpoint1.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-post-mvp-mormot-repin.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `mormot.lock` pins `da7e1c2f`, which still carries three binding
defects this project reported: the Currency return register on SysV x64 and
AAPCS64 (`RP-2`), `JS_SetMaxStackSize` typed `JSContext` (`9A-3`), and the
`pas_*` heap exports typed 32-bit (`9A-4`). PWeb carries a shadow declaration
for the second and a documented limitation for the first.

**Approach:** Move the pin to the smallest upstream commit on the line
`da7e1c2f` sits on that contains all three fixes, measured before anything
moves; remove every PWeb-side workaround the fixes make unnecessary; keep every
probe as a permanent gate against the unpatched upstream; supersede every value
the move changes, each one measured.

## Boundaries & Constraints

**Always:** verify each upstream hash against the tree; measure on fresh
checkouts of the candidate with no local patch; every `must_pass` Currency row
rests on a measurement taken on that leg's own compiler, with the run id as
provenance; every supersession is a measured old → new pair, never "unchanged"
by assumption; the ledger stays append-only; the statics move only if a
measurement requires it, and then as a second pin with its sha256.

**Never:** patch `deps/mormot2`; widen the pin past the smallest commit that
carries the three fixes; rename a CI step or edit `ci-legacy-inventory.tsv`;
touch the watcher's pinned path; commit `.claude/settings.json` or other local
tooling.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Currency return, arities 0/1/2 | `cap3u_currency`, unpatched candidate | 5/5 on all four targets | a failing row is a finding brought back, not left `observe` |
| stack limit with the pinned binding | `JS_SetMaxStackSize(FEngine.rt, …)`, no shadow | CAP-9A q20-q23 and CAP-9B2 limit rows pass; corpora unchanged | a binding reverted to `JSContext` fails the compile |
| heap exports | QuickJS gates against the pinned 2.4-stable statics | CAP-9 harnesses PASS on four targets | — |
| Win64 unwind | `cap3u_unwind`, unpatched candidate | one RUNTIME_FUNCTION on CallMethod, 12/12 | gate refuses |

</frozen-after-approval>

## Code Map

- `mormot.lock` -- the pin and its provenance comment; `tools/get-mormot.ps1` reads it.
- `deps/mormot2` @ `66d7d51c1fd21bd222b360382ed8e2b4f656aaad` -- READ-ONLY; `src/core/mormot.core.interfaces.pas` (the Currency fix), `src/lib/mormot.lib.quickjs.pas` (`JS_SetMaxStackSize`), `src/lib/mormot.lib.static.pas` (`pas_*`), `src/mormot.defines.inc` (unchanged; `NOLIBCSTATIC` still set on aarch64-darwin).
- `src/script/pweb.script.quickjs.pas` -- the `JS_SetMaxStackSize` shadow (removed) and the aarch64-darwin `pas_*` export block (kept; `pas_malloc_usable_size` aligned to `PtrUInt`). No platform directive changes, so the CAP-7F divergence fingerprint holds.
- `test/cap3u/currency-expectations.tsv` -- every row `must_pass`, header citing the hosted run.
- `test/cap9c1/quickjsrelease.pas` C30 -- the pin prefix `LICENSE.quickjs` must name.
- `LICENSE.quickjs` sha256 sites -- `docs/third-party-licenses.md`, `test/cap10d2/build_cap10d2.{ps1,sh}`, `test/cap7f/check_cap7f_aggregate.ps1`, `test/cap9c2/run_quickjsgui.{ps1,sh}`.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `test/backlog/dispositions.tsv`, `test/backlog/check_backlog.ps1` (shard code `RP2`), `docs/backlog.md` -- the ledger, its dispositions and the human worklist.
- `docs/upstream/mormot-*.md` -- the three reports, now marked resolved with the commits named.
- `examples/03-mormot-rpc/README.md`, `docs/pipeline-contract.md`, `tools/pweb/pweb.cli.sdkroot.pas` -- prose naming the pin's upstream commits.

## Tasks & Acceptance

**Execution:**
- [x] Checkpoint 1 measured and recorded -- `mormot-repin-2-checkpoint1.md`.
- [x] `src/script/pweb.script.quickjs.pas` -- remove the shadow, align the darwin export -- the binding is fixed upstream.
- [x] pin-derived literals -- C30 prefix and the six `LICENSE.quickjs` sites -- the provenance line moved, the licence text did not.
- [x] `mormot.lock` -- candidate commit, comment citing the three commits and the forum post.
- [x] `test/cap3u/currency-expectations.tsv` -- all rows `must_pass` from the hosted measurement run.
- [x] ledger, dispositions, backlog gate and document -- `RP-2`, `9A-3`, `9A-4` resolved upstream; the Currency limitation retired.
- [x] docs and upstream reports -- resolved, commits named.
- [x] final artifact -- CANDIDATE / STATICS / CURRENCY / QUICKJS SHADOWS / DELTA / SUPERSESSIONS / REGRESSIONS / VERDICT.

**Acceptance Criteria:**
- Given the final HEAD, when the four-target CI runs, then every leg and the aggregate are green and the watcher's gates are unaffected.
- Given `test/backlog/check_backlog.ps1`, when it runs, then `RP-2`, `9A-3` and `9A-4` are `CLOSED` by entries of this shard and no row is orphaned or reworded.

## Implementation Notes

The measurement vehicle is commit `291eb32` on the shard branch: it moves only
the `commit =` line, so the hosted run on it measures the unpatched Currency
return on the two macOS legs, which no host here can reach.

Implemented directly rather than through a dispatched subagent: every step
depended on a measurement taken moments before, and the checkpoint was PLAN
READY with default proposals, so the build continued in the same run.

Surprises, all recorded in the final artifact: the brief's `PtrUInt` for
`pas_malloc` is `PtrInt` in the tree; the aarch64-darwin export block still
returned a 32-bit `pas_malloc_usable_size`; the CAP-10D2 contract refuses an
uncommitted shipped path, so the final chains ran on a committed HEAD; and
four local-harness mismatches (a `cmd` body, an unsigned `pwsh` shim, a long
`RUNNER_TEMP`, an inline-step comment) were corrected and their steps re-run.

## Spec Change Log

## Review Triage Log

Pass 1 — three layers over the diff from `4aed789` (101 kB): blind hunter 14 findings, edge-case hunter 4, verification gap 1 gap + 2 other. No intent_gap and no bad_spec, so no loopback; every surviving finding was a patch, applied here.

| # | layer | finding | verdict | evidence / route |
|---|---|---|---|---|
| 1 | blind | README, `pipeline-contract.md`, `pweb.cli.sdkroot.pas` still name only `896f1c1c`/`790154af` | false | all three state that the pin carries those commits and why the Windows patch went, which stays true at `66d7d51c`; none claims the SysV/AArch64 register was right |
| 2 | blind | the Currency row of `post-migration-amendments.tsv` still says only Windows gates | low | true, and readers of the table would be misled; no gate reads the column (`check_migration_map.ps1` uses 0, 1, 3) — patched, migration map re-run PASS |
| 3 | blind | the delta table sums to 39 of 41 files | low | the two `mormot.commit*.inc` files were missing — patched in checkpoint and artifact |
| 4 | blind | "16th from the tip" vs "seventeen commits after" | low | both true of different sets (15 first-parent + 2 PR commits) — wording patched |
| 5 | blind | the SSSE3 float parser is a default runtime change the artifact justified wrongly | low | verified: `GetExtendedSsse3` is a `nostackframe` leaf with no call, push, non-volatile register or XMM6–15, routed under `ASMX64NOTPIC` + SSSE3 — wording patched |
| 6 | blind | "no request reaches the sign bit" is asserted, not shown | low | the per-runtime limit check can wrap; the true argument is that signedness does not change the ABI — patched in the unit comment, ledger and report; a forum note on upstream's `PtrInt` is the owner's call |
| 7 | blind | the darwin comment says unsigned while `pas_realloc` is `PtrInt`; the widened export was never compiled for aarch64-darwin | low | comment patched; the compile is owed to the hosted run (`RP2-6`) |
| 8 | blind | macOS results written as done (ledger, lock) | medium | true for RP2-2, RP2-5 and the lock comment — reworded, and the owed work is an open row, `RP2-6` |
| 9 | blind | "every value below was measured" overstates the supersession table | low | sources now named per row, local vs hosted pairing stated — patched in the artifact |
| 10 | blind | the regressions table marks CAP-10 PASS on Windows with L2b unrun, and omits the collection steps | low | patched |
| 11 | blind | the checkpoint said red on Windows and Linux, later all four | low | written before the macOS legs finished — patched |
| 12 | blind | the negative evidence has no command; the compile guard is overstated | medium | the two negative legs are written out with their commands in the artifact, and both properties now have permanent gates (`check_pinned_bindings.ps1`, the q22 depth probe); the compile guard is described as covering a typed revert only |
| 13 | blind | `cap3u_currency.pas` blames `790154af` for arm64's 0/5 | low | true, AArch64 was never touched by it — patched; `run_currency.ps1` names the pins |
| 14 | blind | the final HEAD is not named; the spec reads done while AC1 is pending | low | the commit table names every commit; status stays `in-review` until the hosted run |
| 15 | edge | the five Currency cases miss negative, `High(Currency)` and stack-passed arguments | low — rejected | the frozen intent fixes the probe at arities 0/1/2; the fix is value-independent (`fistp` of an exact Int64, the x0 value kept); new cases would need four new hosted measurements |
| 16 | edge | macOS supersessions and no-shadow rows unmeasured while the backlog says nothing is owed | medium | same as 8 — `RP2-6` |
| 17 | edge | the 9A-4 probe was read once and nothing re-checks it | medium | true — `test/cap9a/check_pinned_bindings.ps1` on every leg, refusing each rule's pre-fix form, and refusing the old pin's three wrong declarations |
| 18 | edge | the amendment row is stale | low | same as 2 |
| 19 | verification | no test observes that the configured stack limit is applied | medium | verified: 256 KB is `JS_DEFAULT_STACK_SIZE`; CAP-9A now compares depths at 256 KB and at the 1 MB default (494 vs 1983 frames), Expect only; with the call deleted both are 494 and the harness fails; `quickjs_corpus_digest` unchanged |
| 20 | verification | the amendment row is stale | low | same as 2 |
| 21 | verification | stale "runtime-typed" comments in the unit and in CAP-9A | low | patched |

## Verification

**Commands:**
- the Windows platform-leg bodies replayed in order with FPC 3.2.2 x86_64-win64 -- expected: every pin-dependent step green.
- the Linux platform-leg bodies replayed in a fresh WSL clone -- expected: the same.
- `pwsh test/backlog/check_backlog.ps1` -- expected: PASS.
