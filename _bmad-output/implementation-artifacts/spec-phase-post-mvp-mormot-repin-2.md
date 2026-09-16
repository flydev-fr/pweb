---
title: 'MORMOT-REPIN-2 — the mORMot pin onto the three upstream binding fixes'
type: 'chore'
created: '2026-09-16'
status: 'in-progress'
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
- [ ] `mormot.lock` -- candidate commit, comment citing the three commits and the forum post.
- [ ] `test/cap3u/currency-expectations.tsv` -- all rows `must_pass` from the hosted measurement run.
- [ ] ledger, dispositions, backlog gate and document -- `RP-2`, `9A-3`, `9A-4` resolved upstream; the Currency limitation retired.
- [ ] docs and upstream reports -- resolved, commits named.
- [ ] final artifact -- CANDIDATE / STATICS / CURRENCY / QUICKJS SHADOWS / DELTA / SUPERSESSIONS / REGRESSIONS / VERDICT.

**Acceptance Criteria:**
- Given the final HEAD, when the four-target CI runs, then every leg and the aggregate are green and the watcher's gates are unaffected.
- Given `test/backlog/check_backlog.ps1`, when it runs, then `RP-2`, `9A-3` and `9A-4` are `CLOSED` by entries of this shard and no row is orphaned or reworded.

## Implementation Notes

The measurement vehicle is commit `291eb32` on the shard branch: it moves only
the `commit =` line, so the hosted run on it measures the unpatched Currency
return on the two macOS legs, which no host here can reach.

## Verification

**Commands:**
- the Windows platform-leg bodies replayed in order with FPC 3.2.2 x86_64-win64 -- expected: every pin-dependent step green.
- the Linux platform-leg bodies replayed in a fresh WSL clone -- expected: the same.
- `pwsh test/backlog/check_backlog.ps1` -- expected: PASS.
