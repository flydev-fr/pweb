---
title: 'CAP-11A — the CI matrix: one step sequence, non-blocking evidence, three flakes instrumented'
type: 'refactor'
created: '2026-09-05'
status: 'in-review'
baseline_commit: 'ed1cb716bc912879ab686828a7b0f2018b875795'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/cap10-closure-artifact.md'
  - '{project-root}/docs/kernel.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `.github/workflows/ci.yml` is 265 KB and 5,824 lines across six jobs, and
the property the CAP-7F aggregator exists to check — **the four platform jobs run the
same step sequence** — is asserted by hand-copying, never measured. Measured today: the
four legs declare 155 / 92 / 99 / 99 steps; 70 normalized step names run on all four and
appear in the same relative order, while 106 names run on one leg only. Nothing would go
red if a shard added a gate to three legs. Two failure modes have already cost hosted
runs: on run `33955241980` an `actions/upload-artifact` timeout inside the macos-x64 leg
skipped about thirty later steps, forfeiting the CAP-10C1 and CAP-10D2 verdicts on that
target even though the gate the upload served had already reported success (ledger:
"NO GATE MAY DEPEND ON AN UPLOAD HAVING SUCCEEDED"); and three hosted-Windows flakes —
the `state=0` non-report (`B1-10`, `B2-16`, `D1-15`), the CAP-6b4 U3 uninstall residue
(`D1-16`, diagnosed as a live WebView2 process holding files), and the pinned-installer
fetch stalls (`C3-15`) — fail without naming their cause. There is no retention policy,
no workflow-level concurrency, and the job timeouts are 1.4×–100× the measured maxima.

**Approach:** One reusable workflow (`workflow_call`) carries **the one step sequence**;
a thin `ci.yml` calls it four times from a four-entry matrix and keeps the release
inventory and the aggregate as `needs:` jobs. Every step body moves verbatim into a
per-step composite action under `.github/actions/`, so per-platform divergence can only
be the existing ps1/sh twins inside an action or an `if:` on the runner — never a
different step list. A gate reads the run's own steps from the GitHub API and requires
the four extracted name sequences equal **and** each step's observed run-set equal to its
declared platform applicability. Every interleaved upload moves into one collection block
at the end of the leg with a bounded retry and a typed row, so an upload failure is
infrastructure and forfeits nothing. Retention, concurrency and per-job timeouts are
ratified and gated. The three flakes gain instrumentation that reports what was
**observed**, with no timeout lengthened and no pin moved. The migration is proven by a
twin run on one commit before the old file is removed in its own commit.

## Boundaries & Constraints

**Always:**
- **No product change.** `src/`, `sdk/`, `tools/pweb/`, `tools/setup/`, `examples/` are
  byte-untouched, proven by `git diff --stat` over the whole shard.
- Every step that exists today exists after the migration, with its name, its `shell:`,
  its `timeout-minutes:`, its `if:` and its body **byte-identical** modulo one declared
  normalization (the six-space YAML block indent). The only ratified structural change is
  the upload restructuring named below.
- The four legs run one step list. A step that cannot run on a platform is `if:`-guarded
  and appears as `skipped`, never absent.
- A gate never depends on an upload. Evidence is written to disk by the gate that
  measured it; collection happens once, last, and its failure is typed `infrastructure`.
- Retries are for **transport** only. A completed transfer whose sha256 disagrees with
  its lock is upstream drift and fails immediately — never retried, never re-pinned.
- No timeout is lengthened to make anything pass. Per-attempt fetch bounds are new
  ceilings **inside** existing step budgets, so every ceiling moves down or stays.
- Every contract document under `docs/` and every frozen digest keeps its closure value.
  `docs/ci-migration.md` is the only new document.
- An instrumented cause is reported only when it was observed; `undetermined` is a legal
  value and the honest one.

**Ask First:**
- Declaring PWeb's own licence (see the LICENSE finding: the root carries an untracked,
  `*.txt`-gitignored MPL-2.0 `LICENSE.txt`). The shard's ratified position is
  `sdk_own_license = undeclared`; flipping it to `declared` means committing a licence to
  a public repository and is the human's call.
- Any change to a compared field, an absolute pin or the four-target equality list.

**Never:**
- No step is deleted, merged or reordered because it "looks dead"; that is a later,
  measured decision.
- No new third-party action; the six pinned actions stay at their pinned SHAs.
- No `webview.lock` / `mormot.lock` / `fpc.lock` / `pas2js.lock` / `innosetup.lock` /
  `webview2-runtime.lock` value moves.
- No licence text is written or chosen by this shard.
- CAP-11B (the upstream watcher) and CAP-12 are not started.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Four legs agree | a normal run | four extracted step-name sequences identical; `ci_sequence_digest` equal on four | — |
| A step runs on the wrong set of legs | an `if:` that stopped matching | applicability gate red, naming the step and the observed vs declared leg set | gate exit 1 |
| Evidence upload fails after every gate passed | seeded upload failure (`UP2`) | every earlier gate already ran; leg keeps its own conclusion; `evidence_uploaded=false`; the aggregate refuses and names `infrastructure`, not a gate failure | typed, never silent |
| Upload succeeds on attempt 2 | transient artifact-service error | one row per attempt (attempt, bytes, elapsed_ms, outcome); `upload_model=final_step_bounded_retry` | — |
| Pinned installer stalls | transport timeout inside the per-attempt bound | attempt row `transport_timeout`; retried within the bound; sha256 verified after each completed attempt | refuse after N attempts |
| Pinned installer changed upstream | sha256 mismatch on a completed transfer | immediate refusal naming expected/got | never retried |
| Smoke reports nothing | `state=0` on a hosted leg | `smoke_nonreport_cause` from the observation samples: `page_never_loaded` \| `loaded_script_never_ran` \| `ran_missed_window` \| `undetermined`, with the samples beside it | gate still red; re-run stays the disposition |
| U3 residue | fixed-profile uninstall on a contended runner | the path-scoped drain runs and REPORTS (pids, images, graceful/forced) **before** the directory is measured | drain refusal precedes the measure |
| A file under `.github/` exceeds the bound | any commit | size/line gate red naming the file and its measured size | gate exit 1 |
| An upload declares the wrong retention | any commit | retention gate red naming the artifact class | gate exit 1 |

</frozen-after-approval>

## Code Map

**The file being replaced**

- `.github/workflows/ci.yml` — 271,637 B / 5,824 lines. Regions measured:
  header 3,236 B (1–56); `windows` 126,807 B (57–2597, 155 steps, `timeout-minutes: 330`);
  `linux` 45,098 B (2598–3612, 92 steps, 60); `macos-x64` 47,128 B (3613–4675, 99 steps,
  120, job `env: CAP7M_EXPECT_ARCH=x86_64`, job `concurrency: cap7m-macos-x64-${{ github.ref }}`);
  `macos-arm64` 42,603 B (4676–5670, 99 steps, 120, arm64 twins);
  `macos-release-inventory` 3,130 B (5671–5734, 3 steps, 10);
  `cap7-aggregate` 3,635 B (5735–5824, 12 steps, 10).
- Shared gate tail (`CAP-8B real-window navigation matrix` → `CAP-7F upload the … evidence`):
  71 steps per leg, 46,119 + 30,219 + 29,649 + 28,536 = 134,523 B — **49.5 % of the file is
  the same sequence written four times.**
- Union of normalized step names = **204**; 70 on four legs (same relative order on all
  four, verified), 3 on three, 25 on two, 106 on one.
- Step bodies use expressions only twice (`hashFiles` in the macOS FPC cache, `github.ref`
  in the two macOS concurrency groups) and no step-level `env:`, no step `id:`, no
  cross-step `steps.*` reference — so bodies move without rewriting.
- Shells: 182 `pwsh`, 152 `bash`, 1 `cmd` (`ABI probe - C side`, line 592).
- Actions, all SHA-pinned: `actions/checkout` ×5, `actions/upload-artifact` ×105,
  `actions/download-artifact` ×8, `actions/setup-node` ×4, `actions/cache` ×2,
  `ilammy/msvc-dev-cmd` ×1.
- Uploads per leg: windows 30, linux 23, macos 25 each (12–13 `if: always()`, 2–9
  `if: failure()`, 9–10 unconditional). Only `cap7f-evidence-<target>` and
  `cap7m2-release-<arch>` are consumed by another job.

**The aggregate, its premise and its schema**

- `test/cap7f/check_cap7f_aggregate.ps1` (130,501 B) — `$targets` (4), `$expectations`,
  `$required` (~700 rows), `$absolutePins` (l. 433), `$mustPass` (l. 912),
  `$equalityFields` (l. 993). Writes `build/cap7f/platform-matrix.json`.
- `test/cap7f/check_cap7f_selftest.ps1` (124,320 B) — the negative self-test (absent
  artifact, perturbed field, SKIP promotion) run before the real aggregation.
- `test/cap7f/emit_evidence.ps1` (117,050 B) / `emit_evidence.sh` (130,450 B) — the two
  emitters; the field set is maintained by hand in **three** places (ledger D2-11: this
  cost run `33957698297`). ~700 field names each.
- `test/cap7f/check_divergence.ps1` (21,782 B) — the production-surface sweep.

**Harness files this shard modifies (named per the FREEZE clause)**

- `test/cap6/run_cap6_smoke.ps1` — the CAP-6 release smoke driver (`state=0` non-report).
- `test/cap5/run_cap5_smokes.ps1` — the React/Pas2JS smoke driver, same class (`B1-10`).
- `test/cap6b4/run_profile_matrix.ps1` — `Invoke-Uninstall` (l. 483–510) polls for the
  directory to disappear with **no drain in front of it**; U3's failure text is at l. 504.
- `test/cap6b3/wv2procdrain.ps1` — the ratified path-scoped drain
  (`Invoke-PWebProcessDrain`, `Assert-PWebProcessDrained`) already dot-sourced by
  `test/cap6b3/run_fixed_setup_gates.ps1:510`. Reused, not modified.
- `tools/get-fpc-windows.ps1` (l. 137–170), `tools/get-fpc-macos.ps1` (l. 183–210),
  `tools/get-webview2-runtime.ps1` (l. 233), `tools/get-innosetup.ps1` (l. 121),
  `tools/get-pas2js.ps1` (l. 151) — the five pinned-artifact fetchers.
- `test/cap10a/check_cap10a_contracts.ps1:124` — reads `.github/workflows/ci.yml` for the
  `node-version:` pin; a path update only.

**Read-only evidence**

- LICENSE: the repository root carries `LICENSE.txt` (16,726 B, 373 lines, MPL-2.0,
  sha256 `3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04`) which is
  **untracked and ignored** by `.gitignore:94` (`*.txt`). `git ls-files LICENSE.txt` is
  empty, so a CI checkout does not have it.
- The D2 declared table is `tools/pweb/pwebsdk.pas:190–200` — inside the product freeze.
  `docs/sdk-contract.md:89` ships `share/pweb/licenses/**` as "every shipped **third-party**
  component's notice"; `test/cap10d2/check_cap10d2_contracts.ps1:215–247` requires the
  packager table to equal `docs/third-party-licenses.md` exactly.
- Measured job durations, successful runs only (9 runs sampled, `gh run view --json jobs`):
  windows max 63.6 min, linux 20.1, macos-x64 34.7, macos-arm64 29.5, inventory 0.1,
  aggregate 7.4.
- CAP-10E closure: run `33983841968` on `28bda2a`, all six jobs green;
  `cap10e-final-artifact.md:548` reads **CAP-10E PASS**.

## Tasks & Acceptance

**Execution:**

- [ ] `test/cap11a/extract_ci_inventory.ps1` — extract from the old `ci.yml` a per-job
      ordered inventory (step name, normalized name, `shell`, `if`, `timeout-minutes`,
      body sha256) into `test/cap11a/ci-legacy-inventory.tsv` — the committed snapshot
      that keeps CI7 checkable after the old file is deleted.
- [ ] `test/cap11a/migrate_ci.ps1` — one-shot generator: emit
      `.github/workflows/platform-leg.yml` (the one sequence) and one
      `.github/actions/<slug>/action.yml` per step carrying the body verbatim. Twins with
      the same normalized name become one step whose action dispatches on `runner.os`.
- [ ] `.github/workflows/platform-leg.yml` — `workflow_call` with inputs
      `target, runner, family, expect_arch, runner_label, timeout_minutes`; the one
      sequence; `permissions: contents: read`.
- [ ] `.github/actions/**/action.yml` — the step bodies, unmodified.
- [ ] `.github/workflows/ci-matrix.yml` — the caller: triggers, `permissions`,
      workflow-level `concurrency`, the four-entry matrix, `macos-release-inventory` and
      `cap7-aggregate` with `needs:`. Renamed to `ci.yml` in the removal commit.
- [ ] `test/cap11a/check_ci_sequence.ps1` — read `runs/<id>/jobs` from the API, drop
      `Set up job` / `Post *` / `Complete job`, require the four name sequences equal and
      each step's observed run-set equal to its declared applicability; write
      `build/cap11a/sequence.json` and `ci_sequence_digest`.
- [ ] `test/cap11a/check_ci_structure.ps1` — the repository gate: file-size and line
      bounds over `.github/**` measured as **committed** bytes (`git cat-file -s`, so a
      CRLF checkout cannot change the answer); retention-days exactly the ratified value
      per artifact class; `concurrency` and `permissions` present; per-job timeouts equal
      to the ratified values; no `uses:` outside the six pinned actions; no gate step
      reading an artifact (`download-artifact` only in the two consumer jobs) — `UP1`.
- [ ] `test/cap11a/check_migration_map.ps1` — every row of `ci-legacy-inventory.tsv` maps
      to exactly one step of the new sequence with an equal body sha256, and
      `docs/ci-migration.md` names it. The declared exception set is the upload
      restructuring, enumerated by name.
- [ ] `.github/actions/collect-leg-evidence/*` + the sequence's collection block — one
      staging step, then bounded-retry uploads for `cap7f-evidence-<target>` (90 d),
      `leg-records-<target>` (90 d), `cap7m2-release-<arch>` (90 d, macOS),
      `cap10d2-sdk-<target>` (14 d or 90 d under the dispatch flag), `leg-diagnostics-<target>`
      (7 d, `if: failure()`), then one typing step writing `build/cap11a/collection.json`
      (per artifact: attempt, bytes, elapsed_ms, outcome) and `evidence_uploaded`.
- [ ] `test/cap7f/check_cap7f_aggregate.ps1` — consume `sequence.json` and the four
      `collection.json`; distinguish "leg green, evidence not uploaded" (typed
      `infrastructure`, named) from "leg red"; add the new rows to `$required`,
      `$equalityFields`, `$absolutePins` as tabled in Design Notes.
- [ ] `test/cap7f/check_cap7f_selftest.ps1` — negative cases for the two new refusals: a
      leg whose evidence is absent with its gates green, and four sequences that differ.
- [ ] `test/cap7f/emit_evidence.ps1` + `emit_evidence.sh` — emit the new rows.
- [ ] `test/cap7f/check_schema_agreement.ps1` — the D2-11 requirement: extract the field
      names from both emitters and from the aggregator's required list and refuse when the
      three disagree.
- [ ] `test/cap6/run_cap6_smoke.ps1`, `test/cap5/run_cap5_smokes.ps1` — start the host through a
      bounded sampler that records window presence/title, engine process set, elapsed and
      exit code to `build/<cap>/smoke-observations.txt`; on a non-report derive
      `smoke_nonreport_cause` from those samples by the stated rule.
- [ ] `test/cap6b4/run_profile_matrix.ps1` — dot-source `wv2procdrain.ps1`; in U3 run and
      REPORT `Assert-PWebProcessDrained` (pids, images, graceful/forced, sweeps) and write
      `build/cap6b4/u3-drain.txt` **before** the directory measure; record the order.
- [ ] `tools/pwebfetch.ps1` — the shared bounded-retry fetch helper: per-attempt time
      bound, one row per attempt, sha256 (and size) verified after every completed
      attempt, digest mismatch never retried; attempts × bound ≤ the existing step budget.
- [ ] `tools/get-fpc-windows.ps1`, `get-fpc-macos.ps1`, `get-webview2-runtime.ps1`,
      `get-innosetup.ps1`, `get-pas2js.ps1` — route the transfer through the helper; no
      URL, pin or existing verification changes.
- [ ] `test/cap10a/check_cap10a_contracts.ps1` — read the `node-version:` pin from the new
      location.
- [ ] `docs/ci-migration.md` — old step → new location for all 445 platform steps plus the
      two consumer jobs, with the upload restructuring enumerated; and the note that
      ratified artifacts' `ci.yml:<line>` citations resolve through this table.
- [ ] `_bmad-output/implementation-artifacts/deferred-work.md` — append the CAP-11A
      entries: the upload-forfeiture case re-described as resolved by structure, D1-16's
      instrumentation, the ratified retention/timeout/concurrency values, the LICENSE
      measurement, and D2-8's disposition.

**Acceptance Criteria:**
- Given the new structure, when a run completes, then the four legs' extracted step-name
  sequences are byte-identical and each step's observed run-set equals its declared
  applicability.
- Given one commit carrying both the old `ci.yml` and the new structure, when both runs
  finish, then the aggregate's compared fields, absolute pins and four-target equality
  list are byte-identical between the two `platform-matrix.json` files, and per-target
  observations differ only where already typed as observations.
- Given the new structure, when the aggregate runs, then every frozen digest reads its
  closure value.
- Given a seeded upload failure on one leg, when the leg finishes, then every gate on that
  leg still ran, the leg's collection row reads `evidence_uploaded=false`, and the
  aggregate refuses while naming that leg `infrastructure`.
- Given the removal commit, when `.github/workflows/ci.yml` (old) is gone, then
  `check_migration_map.ps1` still passes against the committed legacy inventory.
- Given any commit, when the structure gate runs, then every file under `.github/` is
  ≤ 64 KB and ≤ 1,200 committed lines, every upload declares its class's retention, and
  the ratified concurrency, permissions and per-job timeouts are present.
- Given the shard's whole diff, when `git diff --stat` is taken against the baseline, then
  `src/`, `sdk/`, `tools/pweb/`, `tools/setup/` and `examples/` show zero changed files.

## Design Notes

**Why model A + B, measured.** Model A alone (one file carrying the sequence *and* the
bodies) needs ≈ 184 KB deduplicated — 2.9× the 64 KB bound — so the brief's own fallback
applies: A carries the sequence, B carries the bodies. The decisive constraint is that
**`timeout-minutes` is not supported on steps inside a composite action**, while it *is*
supported on a workflow step that `uses:` one. Grouping several steps per action would
therefore delete ~90 per-step budgets, which the `windows:` job header calls "the real
protection". So the grain is **one composite action per step**: the sequence keeps every
name, `if:` and budget; the action keeps the body and its comments. Projected sizes:
`platform-leg.yml` ≈ 36 KB / ~900 lines (204 steps × ~4 lines), `ci-matrix.yml` ≈ 6 KB,
each `action.yml` ~0.9 KB with the largest ≈ 8 KB.

Model C is refused as the drift model; model D is heavier and buys nothing A+B does not.

**The sequence gate is not vacuous.** Name equality is by construction, so the gate also
compares each step's *observed* run-set against a declared applicability table
(`test/cap11a/step-applicability.tsv`, generated with the sequence). A `runner.os` typo
that silently skips a Windows gate everywhere is red, which is the honest answer to
"can the four legs diverge without a gate going red?".

**Ratified numbers.**

| item | before | after | basis |
|---|---|---|---|
| per-file bound under `.github/**` | none (265 KB) | ≤ 64 KB, ≤ 1200 lines | brief's recommendation; measured fit |
| `windows` job timeout | 330 | 135 | 2 × 63.6 measured max, rounded to 15 |
| `linux` | 60 | 45 | 2 × 20.1 |
| `macos-x64` / `macos-arm64` | 120 / 120 | 75 / 75 | 2 × 34.7 (the larger of the pair) |
| `macos-release-inventory` | 10 | 10 | 0.1 measured; unchanged |
| `cap7-aggregate` | 10 | 20 | 7.4 measured = 74 % of the old budget; the only value that rises, and not because anything flaked |
| concurrency | none at workflow level; two job-level macOS groups | `group: ci-${{ github.ref }}`, `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}`; the two macOS groups removed as subsumed | CAP-7M's job-level scoping was explicitly "because this shard may not touch the others" |
| retention | 89 × 30 d, 16 × 7 d | evidence/records/inventory/matrix 90 d; SDK archives + manifests 14 d (90 d on `workflow_dispatch` with `long_retention`); failure diagnostics 7 d | brief |

**The collection block.** GitHub gives no way to retry one `uses:` step from inside
itself, and `continue-on-error` is unsupported inside composite actions, so the bounded
retry is N sibling attempt steps guarded on the previous attempt's `outcome` — measured
constraint, not preference. The block is the last thing on the leg, every step is
`if: always()`, and the typing step never fails the leg: a leg that passed its gates and
could not upload stays green and says so, which is precisely the distinction the aggregate
must make.

**Flake instrumentation, and what it may not claim.** The `state=0` message is printed by
`examples/*.pas`, which is frozen, so the cause is derived from what a *driver* can
observe: window presence and title (title change ⇒ the document parsed), the engine
process set, elapsed vs `PWEB_SMOKE_AUTOCLOSE_MS`, exit code, and the host's own stdout
lines. `ran_missed_window` is only claimed when a `report:` line is present; otherwise the
row is `loaded_script_never_ran` (title observed) or `page_never_loaded` (never observed),
and `undetermined` when the samples do not separate them. The row carries the samples
beside it, which is the CAP-10E long-path lesson applied.

**LICENSE — the measurement, and why the shard does not choose.** `<repo>/LICENSE` does
not exist. `<repo>/LICENSE.txt` exists on the dev host, is MPL-2.0, and is **ignored by
`.gitignore:94` and untracked**, so it is not in the repository a runner checks out.
Declaring it would mean adding a `!LICENSE.txt` negation and committing a licence to a
public repository — an outward-facing act the brief reserves ("never choose one"). The
shard therefore records `sdk_own_license = undeclared`, leaves ledger D2-8 open with the
human as owner, and touches neither `tools/pweb/pwebsdk.pas` nor `docs/sdk-contract.md`
nor `docs/third-party-licenses.md`. The report states the two steps that would flip it.

**Twin-run plan.** Commit T adds the new structure as `ci-matrix.yml` with `on: push`
while `ci.yml` stays byte-untouched, so one push yields two runs × six jobs. The
comparison tool downloads both `cap7f-platform-matrix` artifacts and asserts byte identity
over the compared fields, the absolute pins and the four-target equality list, recording
both run ids and the digests in `test/cap11a/twin-run.json` — the committed record the
`ci_twin_run_equal` row is read from. Commit T+1 deletes `ci.yml` and renames
`ci-matrix.yml` onto it.

## Verification

**Commands:**
- `pwsh -File test/cap11a/check_ci_structure.ps1` — expected: sizes, retention, timeouts,
  concurrency, permissions and the artifact-read sweep all pass.
- `pwsh -File test/cap11a/check_migration_map.ps1` — expected: 445 legacy steps mapped,
  0 unmapped, 0 body-digest differences outside the declared upload set.
- `pwsh -File test/cap7f/check_schema_agreement.ps1` — expected: the three field lists
  agree with zero asymmetry.
- `pwsh -File test/cap11a/check_ci_sequence.ps1 -RunId <id>` — expected: four equal
  sequences and applicability match.
- `pwsh -File test/cap6b3/check_wv2procdrain.ps1` — expected: unchanged PASS (the drain
  contract is reused, not modified).
- `bash test/cap7f/…` under WSL for every POSIX twin touched, before any push.
- `git diff --stat <baseline> -- src sdk tools/pweb tools/setup examples` — expected: empty.

**Manual checks:**
- The twin run's two `platform-matrix.json` files, diffed field by field.
- `docs/ci-migration.md` resolves a spot-check of `ci.yml:<line>` citations taken from the
  CAP-10D1, CAP-10D2 and CAP-10E artifacts.
