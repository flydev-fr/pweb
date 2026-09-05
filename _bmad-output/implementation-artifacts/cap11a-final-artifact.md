# CAP-11A — the CI matrix: one step sequence, non-blocking evidence, three instrumented flakes

## SPLIT MODEL

**A + B**, and B is forced by a measurement rather than chosen for taste.

`.github/workflows/ci.yml` was **271,637 bytes / 5,824 lines / six jobs**, and the
four platform jobs declared **155 / 92 / 99 / 99** steps kept in agreement by
copying. The property the CAP-7F aggregator exists to check — *the four platform
jobs run the same step sequence* — **was never true in the form it was stated**:
of 236 distinct step names, 70 ran on all four legs, 3 on three, 25 on two and
**106 on exactly one**. What *was* true, and is the fact the split is built on,
is that the shared names appear in the **same relative order on every leg**, and
that the four job orders merge into one linear sequence of 236 names **with zero
conflicts**, each leg's subsequence equal to its current order.

| | before | after |
|---|---|---|
| entry point | `ci.yml`, 271,637 B, 5,824 lines, 6 jobs | `ci.yml` caller, 15,316 B — matrix + inventory + aggregate |
| the sequence | copied 4× inside that file | `platform-leg.yml`, **54,143 B / 1,161 lines / 196 steps**, one list |
| the bodies | inline | **168 composite actions**, 167,134 B total, largest 10,965 B |
| shared gate tail | 71 steps × 4 = **134,523 B (49.5 % of the file)** | written once |

**Why not A alone:** the deduplicated bodies are ≈ 184 KB against a 64 KB bound.
**Why one action per step and not one per shard:** `timeout-minutes` is
unsupported on a composite-action step and supported on a workflow step that
`uses:` one, so grouping would have deleted ~90 per-step budgets — the thing the
`windows:` job header calls "the real protection". **Why not C:** it is the drift
model. **Why not D:** heavier, and it buys nothing A+B does not.

**Divergence has exactly two legal forms**: an `if:` on `inputs.target` at the
sequence step, and the existing ps1/sh twins *inside* an action. 33 actions carry
a `target` input for that reason; the other 135 have one body.

**The applicability table carries a fourth column, and it is load-bearing.**
`applies_to` says which targets a step is *written* for; it cannot say whether a
step that applies to all four actually *runs*. Nine of the 196 steps are
`conditional` — a retry attempt guarded on the previous attempt's outcome, a
diagnostics upload guarded on `failure()` — and they are skipped on every leg of
a healthy run. Holding those to "observed equals declared" refused every green
run; a conditional step must only never run on a target it does not apply to.

## MIGRATION PROOF

**Nothing was renamed, nothing moved on its own leg.** Step names that differed
across platforms stayed *different steps*, each `if:`-guarded — merging them
would have renamed a gate, and a renamed gate is a gate nobody can find.

| claim | measurement |
|---|---|
| every legacy step accounted for | 445 rows in `ci-legacy-inventory.tsv`, 445 in `ci-migration-map.tsv`, 0 unmapped |
| bodies unchanged | **342 compared against their pre-migration digests, 0 differences** (341 against the legacy digest, 1 against a declared amendment) |
| order preserved | the generator refuses if any leg's subsequence differs from its current order |
| the ratified exception | 61 upload steps (103 rows) folded into the collection block, each path preserved in `collection-paths.json` |
| the amendment | one: the Windows floating-upstream-ref guard, which *named* `ci.yml` and now sweeps the tree — declared in `post-migration-amendments.tsv` with the digest it is allowed to have |

`docs/ci-migration.md` names all **236** distinct legacy step names and states
the resolution procedure for a `ci.yml:<line>` citation: **resolve by step name,
not by line number**, because a line number was only ever true of the file at the
commit that cited it.

TWIN_RUN_BLOCK

## UPLOADS

The reference case is hosted run **33955241980**: `CAP-9C1 upload the macOS x64
release record` failed after five internal retries against GitHub's own artifact
service, and because it was an ordinary blocking step **about thirty later steps
were skipped** — the whole CAP-10C1 and CAP-10D2 gate chains — so one
infrastructure timeout cost that target its verdict on every capability after it.

All four ratified properties now hold by construction:

- **(a) no gate depends on an upload.** The 61 interleaved upload steps are gone
  from the sequence; `check_ci_structure.ps1` refuses an `upload-artifact`
  anywhere before the collection block and a `download-artifact` anywhere on a
  leg. `gate_reads_artifact = 0`, pinned.
- **(b) evidence is written to disk by the gate that measured it** — unchanged.
- **(c) one final collection block**, 15 steps, the last thing on the leg, every
  step `if: always()`, three bounded attempts per class guarded on the previous
  attempt's outcome, each `continue-on-error: true`.
- **(d) an upload failure is typed.** `type_collection.ps1` writes
  `evidence_uploaded` and per-class rows (attempts, files, bytes, outcome) and
  **exits 0** — a leg that passed its gates and could not reach the artifact
  service is green and says so.

The aggregate then says *which of two things* happened, because the collection
outcome cannot travel inside the artifact it describes: `check_ci_sequence.ps1`
reads the run's own step record through the API — the one channel an upload
failure cannot take away — and the aggregate reports either
`INFRASTRUCTURE, NOT A GATE: every gate on this leg passed and the evidence
upload failed after its bounded retry` or `LEG RED: the leg failed at [...]`.
Both sentences are proved by self-test legs e11 and e12 on copies with a
synthesised run record; the refusal floor rose 219 → 221.

`upload_model = final_step_bounded_retry`, `upload_max_attempts = 3`, both pinned.

## BUDGET / TIMEOUTS / CONCURRENCY

**Size bound: ≤ 64 KB and ≤ 1,600 lines per file under `.github/`**, measured
after CRLF→LF normalisation — `.gitattributes` pins `*.sh` to LF and says nothing
about `*.yml`, so a gate that measured the checkout would disagree with itself
between the Windows and POSIX legs. Largest file after: **54,143 B** (83 % of the
bound). The legacy monolith is excluded *only while it exists*, which
`ci_legacy_present` records.

**Timeouts**, from nine sampled runs (successful maxima) at 2× rounded up to a
multiple of 15:

| job | measured max | before | after |
|---|---|---|---|
| windows | 63.6 min | 330 | **135** |
| linux | 20.1 | 60 | **45** |
| macos-x64 | 34.7 | 120 | **75** |
| macos-arm64 | 29.5 | 120 | **75** |
| release inventory | 0.1 | 10 | 10 |
| cap7 aggregate | 7.4 | 10 | **20** |

Every one is a reduction **except the aggregate**, and that one is stated rather
than glossed: 7.4 measured against a 10-minute budget is 74 %, which is not a
margin — and it is not because anything flaked. One *step* gained a bound it
lacked: `CAP-9C2 plugin-enabled acceptance frontend build` had 10 minutes on the
three POSIX legs and none on Windows, where it measures 3–8 seconds; the sequence
gives it the POSIX bound. No timeout anywhere got longer.

**Concurrency** is workflow-level — `ci-${{ github.ref }}`, cancel-in-progress
off the default branch — which CAP-7M deliberately could not make it ("a
workflow-level concurrency group would also govern `windows:` and `linux:`, and
those two jobs are byte-untouched by this shard"). CAP-11A owns the matrix, so
the two per-job macOS groups are gone as subsumed. The expression is
`github.ref_name != 'main'` and not `github.ref != 'refs/heads/main'` **because
the floating-upstream-ref guard sweeps every workflow file for that literal** —
and it is right to.

## RETENTION

| class | artifacts | days |
|---|---|---|
| evidence | `leg-evidence-<target>` | 90 |
| records | `leg-records-<target>` | 90 |
| release inventory | `leg-release-macos-<arch>` | 90 |
| platform matrix | `cap7f-platform-matrix` | 90 |
| distribution | `leg-dist-<target>` | **14**, or 90 on an explicit `workflow_dispatch` with `long_retention` |
| diagnostics | `leg-diagnostics-<target>`, `cap7f-diagnostics-aggregate` | 7 |

Before: 89 uploads at 30 days and 16 at 7, with no policy behind either.
`check_ci_structure.ps1` compares each upload's `retention-days` against its
class as an **exact string**, so the dispatch-conditional form is pinned too, and
publishes `retention_policy_digest` (compared across four targets).

## FLAKE INSTRUMENTATION

**1. The `state=0` non-report (B1-10, B2-16, D1-15).** The line is printed by
`examples/08-release/releaseapp.pas` and its CAP-5 siblings, and `examples/` is
frozen — so a page-side progress report, which would settle this cleanly, is a
product change this shard may not make. `test/cap11a/smokeobserve.ps1` observes
from outside the process (window presence, engine processes beyond a pre-launch
baseline, writes into the WebView2 user-data folder, writes into `Code Cache/js`
— the one direct signal that JavaScript was *compiled* —, the `report:` line,
elapsed against the 8000 ms autoclose) and types
`ran_missed_window | loaded_script_never_ran | page_never_loaded | undetermined`.
**Every branch names the observation it stands on, all observations are recorded
beside the verdict, and `undetermined` is a legal answer** — the row never
guesses. The observer is wrapped in `try/catch` at both call sites and cannot
fail a gate. **KNOWN LIMITATION, stated:** the cause is inferred from engine-side
observations, not reported by the page. Disposition unchanged: re-run the job,
never re-ratify.

**2. The CAP-6b4 U3 residue (D1-16).** The entry asked for one thing — "have U3
report the drain it observed *before* it measures the directory" — and that is
what was built. `run_profile_matrix.ps1` dot-sources the CAP-6b3 helper and runs
`Invoke-PWebProcessDrain` scoped to `$InstallDir` over `releaseapp.exe` and
`msedgewebview2.exe` before the uninstaller, writing pids, images, sweeps and
graceful/forced to `build/cap6b4/u3-drain.txt`; if anything still holds the tree
the uninstaller is **not run**. The CAP-6b3 rule is unchanged — selection by
executable image path under one root, re-checked at kill time — so the runner's
unrelated Evergreen processes are never considered. FL2 asserts the source
**order** and refuses any name-scoped kill. `u3_drain_before_measure = true`,
pinned.

**3. The pinned-installer fetch stalls (C3-15).** `tools/pwebfetch.ps1` gives
every pinned-artifact fetch **3 attempts × 180 s**, a row per attempt, and the
digest verified after **every** completed attempt. 180 s is measured: the healthy
fetches take 3–21 s on hosted runners, while run 33799537793 died at the
20-minute step budget and run 33962919229 spent 1002 s on the same step.
3 × 180 s = 9 minutes, inside the tightest step budget these fetchers run under
(10), **so no ceiling got longer and the retry can never be what fires**. The
safety property: **a retry may only answer a TRANSPORT outcome**; a completed
transfer whose sha256 or size disagrees is refused on the first attempt, never
retried and never fallen back from. Seven seeded cases prove it with no network,
including `F3 NEVER retried` (calls = 1) and `F6 typed as transport, not as
drift`. Five fetchers route through the one helper; no URL, no lock value and no
existing verification changed.

## LICENSE

**`sdk_own_license = undeclared`, and it is a measurement.** `<repo>/LICENSE`
does not exist. `<repo>/LICENSE.txt` **does** exist on the development host —
MPL-2.0, 16,726 bytes, 373 lines, sha256 `3f3d9e00…` — and it is **untracked and
ignored by `.gitignore:94` (`*.txt`)**, so `git ls-files` returns nothing for it
and a CI checkout does not have the file. Declaring it would mean adding a
`!LICENSE.txt` negation and committing a licence to a public repository, which is
choosing one — and the brief's rule is *never choose one*.

So: `tools/pweb/pwebsdk.pas` is byte-untouched, `docs/sdk-contract.md` and
`docs/third-party-licenses.md` keep their closure bytes, the pin is
`sdk_own_license = 'undeclared'`, and **ledger D2-8 stays open with the human as
its owner**. The two steps that would close it are exactly: negate the ignore
rule, and `git add LICENSE.txt`. Both emitters already detect a tracked
`LICENSE`/`LICENSE.md`/`LICENSE.txt`/`COPYING` and would report `declared` with
no further work.

REGRESSIONS_BLOCK

## FREEZE CHECK

`git diff` against the CAP-10E closure `ed1cb71`, over the frozen surface:

- `src/`, `sdk/`, `tools/pweb/`, `tools/setup/`, `examples/` — **no files changed**
- every `*.lock` — **unchanged**
- `docs/kernel.md`, `docs/sdk-contract.md`, `docs/third-party-licenses.md`,
  `docs/index.md` and every other contract document — **unchanged**.
  `docs/ci-migration.md` is the only new document, and it is deliberately not
  added to `docs/index.md`: the index maps the CONTRACTS, and a migration record
  is not one
- `test/cap7f/check_cap7f_aggregate.ps1` — **103 insertions, 2 deletions**, and
  both deletions are lines re-emitted with more detail: no compared field, no
  absolute pin and no `mustPass` entry was removed

What was permitted and used: `.github/**`, the CAP-7F aggregate/self-test/emitters,
the harness files named at Checkpoint 1 (`test/cap6/run_cap6_smoke.ps1`,
`test/cap5/run_cap5_smokes.ps1`, `test/cap6b4/run_profile_matrix.ps1`,
`test/cap10a/check_cap10a_contracts.ps1`, the five `tools/get-*.ps1` fetchers),
`docs/ci-migration.md`, `deferred-work.md` and this artifact.

## KNOWN LIMITATIONS

1. **The non-report cause is inferred, not reported.** `examples/` is frozen, so
   the three-valued cause rests on engine-side observations rather than on the
   page saying where it got to. `undetermined` is a legal outcome and the row
   carries its observations. A page-side progress report belongs to whichever
   shard may next touch `examples/`.
2. **Per-attempt upload elapsed times are read from the run, not self-reported.**
   A sibling step cannot time another step; `type_collection.ps1` records the
   collection block's own elapsed and the exact per-attempt timings come from the
   API in the aggregate.
3. **The matrix job names carry every matrix value** (`leg (windows,
   windows-latest, 135) / windows`). Cosmetic; the sequence gate matches on the
   last path segment, which is the target.
4. **`ci_twin_run_equal` is read from a committed record**, not recomputed on
   every run. The record names both run ids and the commit, and the row reads
   `pending` until the comparison has actually been made.

## VERDICT

VERDICT_BLOCK
