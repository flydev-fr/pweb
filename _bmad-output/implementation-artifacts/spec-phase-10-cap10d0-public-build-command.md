---
title: 'CAP-10D0 — the public `pweb build`: the frozen C1 pipeline exposed, the release replacement ratified, and the two CAP-10D ledger items discharged'
type: 'feature'
created: '2026-09-04'
status: 'done'
baseline_commit: 'c3aa38e5816d6971a29d767db71e04594d9959a1'
review_loop_iteration: 0
context:
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/docs/pipeline-contract.md'
  - '{project-root}/docs/supervision-contract.md'
  - '{project-root}/docs/dev-contract.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c-closure-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-10C1 froze a ten-stage lifecycle pipeline that turns a
generated project into the CAP-10C0 run layout, and CAP-10C2/C3 made every
unit of it public by linking it into `pweb` to serve `pweb dev`. `build` is
still an unknown command that exits 2, so the only way to reach the pipeline
is `pweb dev` — which supervises a live window and never terminates — or the
private CAP-10C1 driver, which is not shipped. The advertised surface is
`create doctor run dev`: a lifecycle CLI that can scaffold, diagnose,
develop and launch, and cannot build. `pweb run` on a fresh project answers
`not_built` with no command that fixes it.

Two ledger items sit unresolved behind that gap. **C0-12** measured that a
Windows layout whose native path exceeds MAX_PATH reaches `CreateProcessW`
in display form and would fail as an untyped `supervision_unavailable`, and
that every CAP-10 gate hands `Start-Process -ArgumentList` an array pwsh
joins **without quoting**, so a repository path with a space would split
`--project`. **C1-11** carries six release-path observations that a public
build re-opens. Both were assigned to CAP-10D because they belong to the
shard that owns the release path and every gate at once.

**Approach:** Expose `pweb build [--project <path>]` over
`pweb.cli.pipeline` and nothing else. One new private driver unit,
`pweb.cli.build`, calls `PWebCliRunPipeline` exactly once, measures the
committed layout with the tree projection that already exists, and returns
the CAP-10C1 exit category unchanged; `pweb.pas` prints the pipeline's own
stage lines and a six-field summary. No stage is added, reordered or
rebounded, no second execution path exists, and the exit mapping, the run
layout, the mutation set, the dev loop and every pin stay where they are.
Ratify the replacement of an existing `release/` as the rule the C1 layout
unit already implements, with its window and its cross-platform behaviour
**measured rather than claimed**. Discharge C0-12 by measuring the long-path
form on the hosted Windows runner and the quoting hazard with one shared
helper every CAP-10 gate adopts, and give each of C1-11's six observations
an explicit disposition. Supersede both template READMEs to document the
five commands honestly, recording every digest that moves.

## Boundaries & Constraints

**Always:**
- **One execution path.** `pweb.cli.pipeline` stays the only unit in the
  repository that runs a child. `pweb.cli.build` spawns nothing, resolves no
  tool and knows no stage: it calls `PWebCliRunPipeline` once and reads the
  filesystem afterwards. Measured at the source and at the link.
- **The ten stages, their order and their bounds are frozen.** `open`,
  `toolchain`, `stage_sdk`, `install`, `typecheck`, `build`, `pack`,
  `compile`, `layout`, `verify`; the eight `PWEB_CLI_PIPE_*` constants; the
  Pas2JS assembly rule. `build` runs every stage of its UI on every
  invocation — no incremental mode, no resume, nothing to clean.
- **The exit mapping is `docs/pipeline-contract.md` §9, unchanged:** 0 built
  and verified, 2 usage, 3 project refused or not confined, 4 the machine
  cannot build it, 5 a stage's child failed with its real typed status, 6 a
  pipeline invariant broke. No new category and no new usage cause.
- **The frontend kind comes from `pweb.json`, never from an option**, and the
  target is the host target. Nothing is cross-compiled.
- **The project-mutation set is unchanged** — `frontend/.pweb/`,
  `frontend/node_modules/`, `frontend/dist/`, `<output>/` — and the tree
  minus those four prefixes is digested before the first stage and after
  every stage by the pipeline itself.
- **The network reaches exactly one stage, `install`, for React only.** A
  Pas2JS build declares no network stage and makes none.
- **Human output only, no ANSI from this CLI on either stream, no absolute
  path, no SDK location, no home directory, no environment content.** A
  tool's own forwarded bytes are the tool's.
- **`pweb run` is advertised as a next step only when the CAP-10C0 resolver
  actually accepted the committed layout in the `verify` stage.**
- **Every digest that moves is recorded**, and every digest that does not is
  **re-measured** and recorded unchanged — the CAP-10C discipline.

**Ratified at Checkpoint 1 (human, 2026-09-04):**
- **The replacement window.** The brief's "at no instant is there neither an
  old nor a new `release/`" is unreachable on all three filesystems (see
  Design Notes) and `docs/pipeline-contract.md` §8 already ratifies the
  opposite. **RATIFIED: the C1 stage-aside-rename-reclaim sequence as-is** —
  never a partial or mixed layout, exactly one bounded instant with no
  layout, which `pweb run` answers `not_built`. The evidence field is emitted
  as `build_never_partial_release` plus
  `build_replacement_window = one_rename_no_release`. No production change to
  `pweb.cli.layout`.
- **The C0-12(a) long-path rule. RATIFIED: measure on the hosted Windows
  runner, then apply branch R1 if the measurement fits it** — the canonical
  `\\?\` form for `lpApplicationName`, a prefix-free `lpCurrentDirectory`
  refused before the spawn above 259 characters with a typed cause. If the
  measurement shows R2 or R3 instead, take that branch and record it. This is
  the only permitted change to `pweb.cli.platform`, and
  `supervision_digest` is re-measured and recorded either way.
- **The space-path proof. RATIFIED: L2a and L2b both.** L2a — every CAP-10
  gate adopts `psargs.ps1`, and the D0 gate drives the real CLI through a
  project directory whose name carries a space, on four targets, every run.
  L2b — one new Windows CI job checking out to a path carrying a space and
  running the CAP-10A..D0 gate chain there.

**Ask First (still open):**
- Any option beyond `--project` and `--help`. None is ratified.
- Any change to a frozen contract, digest or pin not listed under Template
  Supersession in Design Notes.

**Never:**
- No second execution path, no new stage, no reordering, no changed bound.
- No `--profile`, `--target`, `--clean`, `--release`, `--debug`, `--json`,
  `--watch`, `--install`, `--output`, `--force`, short option, response file,
  `--` terminator or environment-supplied option.
- No cross-compilation, no installer, archive, DMG, tarball or signature; no
  CAP-13 profile script and no Inno source touched.
- No write outside the mutation set and `<output>`.
- No change to the dev loop, the dev host, the change detector, the
  production seam, `PWEB_NATIVE_CSP`, the privileged origin, the run layout,
  its resolver, the exit mapping, `pweb.json` schema 1, the seven frozen
  interfaces, the scheduler, the bridge, protocol v1, the platform adapters,
  `app.pwb`, `plugins.zip` or any dependency pin.
- No CAP-10D1 (profiles, distributable artifacts), no CAP-10D2 (SDK
  packaging), no CAP-11, no CAP-12.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| B1 react | fresh `pweb create demo --ui react`, `pweb build` | every stage of the react UI runs; `<output>/<target>/release/` accepted by the C0 resolver; summary printed; exit 0; `pweb run` from an unrelated CWD gives 42 | N/A |
| B2 pas2js | fresh pas2js project, `pweb build` | as B1 with `stage_sdk`/`install`/`typecheck` not applicable; `network_calls = 0` for the whole build | N/A |
| B3 replace | a second `pweb build` over an existing `release/` | the rule below runs; no mixed layout at any instant; `.pweb-old.tmp` gone afterwards; exit 0 | a reclaim failure at step 4 is reported and not fatal |
| B4 stage failure | seeded: a TypeScript type error / a broken `.pas` / a missing tool | the pipeline stops at that stage, the child's real typed status is printed, the previous `release/` is **byte-identical** to before, `.pweb-release.tmp` absent | exit 5 (child failed), 4 (tool), 3 (project) — the exact category per §9 |
| B4c commit refusal | `<output>/<target>/release` pre-seeded as a **file** | `layout_commit_failed`, staging reclaimed, the seeded file untouched | exit 6 |
| B5 interrupt | Ctrl+C / SIGINT during `compile` | the C0 ladder stops the child tree, the previous `release/` untouched, `.pweb-release.tmp` reclaimed, descendants 0 | exit 5, cause `pipeline_interrupted` |
| B6 race POSIX | `pweb run` running, `pweb build` replaces the layout | the running application runs to completion; a run started after gets the new layout | N/A |
| B6 race Windows | same | the running application is unaffected and the **build** is refused: the release directory is the running application's working directory and Windows refuses to rename it | exit 6, `layout_reclaim_failed`, plus one advisory line; the old release untouched |
| B7 determinism | two consecutive builds of the same sources | identical `app.pwb` digest and identical layout inventory | N/A |
| B9 grammar | `--project` at a descriptor and at a directory | accepted, canonicalized, nothing else searched | unknown / duplicate / foreign option gives 2; an unratified `ui` ordinal gives 3 |
| B10 redirection | stdout and stderr redirected to files | no ANSI byte from this CLI on either stream; the six summary fields exact; no absolute path | N/A |
| L1 long path | a Windows project whose native path exceeds MAX_PATH | the ratified rule, measured on the hosted runner | typed refusal, never an untyped `supervision_unavailable` |
| L2 spaced path | a path carrying a space reaches every gate's child | every CAP-10 gate green | a gate that splits an argument fails loudly |

</frozen-after-approval>

## Code Map

**Production — the whole delta.**

- `tools/pweb/pweb.cli.args.pas` — the one parser. `TPWebCliCommand`
  (line ~112) gains `pccBuild`; the positional dispatch (the `token = 'dev'`
  chain) gains `build`; the `pccRun`/`pccDev` clause that refuses
  `--verbose` and `--no-color` (~line 520) gains `pccBuild`. `--json`,
  `--with-paths`, `--ui`, `--bundle-id` are already refused generically.
  **No new `TPWebCliUsage` member.** Header comment updated.
- `tools/pweb/pweb.cli.report.pas` — `PWebCliUsageBanner` (line 116) gains
  the `pweb build [--project <path>]` usage line and the `build` command row;
  new `PWebCliBuildHelp` beside `PWebCliDevHelp` (line 265). Interface
  declaration added near the other four help functions.
- `tools/pweb/pweb.cli.build.pas` — **NEW**, the private driver.
  `PWebCliRunBuild(Project, Os, Arch, Notify, Opaque): TPWebCliBuildResult`
  calls `PWebCliRunPipeline` exactly once, then — only on `ppcOk` — takes
  `PWebCliPipeTreeLines(res.ReleaseDir, nil, ...)` for the inventory and total
  bytes and `Sha256` of the layout's `BundlePath` from
  `PWebCliResolveRunLayout`. Uses `pweb.cli.pipeline`, `pweb.cli.run`,
  `pweb.cli.stage`, `pweb.cli.project`, `pweb.cli.platform`,
  `pweb.cli.paths`. **Names no process API.**
- `tools/pweb/pweb.pas` — `RunBuild` beside `RunDev` (line ~633), reusing the
  `DevLine`-shaped sink; `pccBuild` in the `Main` dispatch (line ~723), in the
  `--help` case and in the usage-refusal case; `pweb.cli.build` in `uses`;
  header comment updated.
- `tools/pweb/pweb.cli.platform.pas` — **only if the C0-12(a) measurement
  ratifies it**: `exeW` at line 1453 and the `lpCurrentDirectory` length
  guard. Nothing else.

**Read-only evidence the plan depends on.**

- `tools/pweb/pweb.cli.pipeline.pas` — `PWebCliRunPipeline` (line ~330) is
  the whole engine; `PWebCliPipeExitCode` (216) is the ratified mapping;
  `PWebCliMutationSet` (229); the `RunStage` nested function (~line 410) is
  the only `PWebCliExecute` call site in the repository.
- `tools/pweb/pweb.cli.layout.pas` — `PWebCliAssembleRelease` (line ~115).
  The commit sequence is already `remove .pweb-old.tmp`, `rename release ->
  .pweb-old.tmp`, `rename .pweb-release.tmp -> release`, rollback on failure,
  `remove .pweb-old.tmp`, then the CAP-10C0 resolver's own verdict. The D0
  ratification is this sequence, unchanged.
- `tools/pweb/pweb.cli.platform.pas` — `PWebCliRenameDir` at 1085 (Windows,
  no `MOVEFILE_REPLACE_EXISTING`) and 2333 (POSIX, `lstat` then `rename`,
  bounded residual recorded): "a rename that would replace is never used" is
  already true. `PWebCliRunLogicalLayout` / `PWebCliResolveRunLayout` /
  `PWEB_CLI_RUN_RELEASE` / `PWEB_CLI_RUN_BUNDLE` in `pweb.cli.run.pas`, and
  `PWebCliPipeTreeLines` (`pweb.cli.stage.pas:601`), the
  `<rel>|<size>|<sha256>` projection the summary and B7 both use.
- `test/cap10c1/pwebpipe.pas` — the private C1 driver, the shape `RunBuild`
  follows; **it stays unchanged** as the C1 regression's own driver.
  `test/cap10c3/pwebp2jdrv.pas` (head) is the `SeparateConsole` plus
  `pwebchild ctrlbreak` interrupt mechanism `pwebbuilddrv` reuses, and
  `test/cap10c1/run_cap10c1_gates.ps1:606-660` is the ST10 leg that records
  `interrupt_clean = not_measured` on Windows — the gap D0's driver closes.
- **`build` is pinned unknown in nine places**, each to be inverted with a
  comment naming CAP-10D0 (the CAP-10C2 C2-18 precedent):
  `test/cap10b0/check_cap10b0_contracts.ps1:159`,
  `test/cap10b0/run_cap10b0_gates.ps1:292`,
  `test/cap10b1/check_cap10b1_contracts.ps1:167`,
  `test/cap10b1/run_cap10b1_gates.ps1:229`,
  `test/cap10b2/run_cap10b2_gates.ps1:275`,
  `test/cap10c0/run_cap10c0_gates.ps1:561,566,583,588`,
  `test/cap10c1/run_cap10c1_gates.ps1:738,744,750`,
  `test/cap10c2/run_cap10c2_gates.ps1:281,301,302`,
  `test/cap10c3/check_cap10c3_contracts.ps1:348,357` and
  `test/cap10c3/run_cap10c3_gates.ps1:239,260,261`.
- **The aggregator**: `test/cap7f/emit_evidence.ps1` (the C3 block at
  1461-1550 is the template for a D0 block), `check_cap7f_aggregate.ps1`
  equality list (245-290) and `$absolutePins` (329, 431-432, 530-531),
  `check_cap7f_selftest.ps1` negative legs (1924, 2078).
- **Field-name collisions to avoid**: `build_deterministic` and
  `project_tree_unchanged` already exist in the matrix, emitted by CAP-10C1.
  D0's are `d0_build_deterministic` and `d0_project_tree_unchanged`.
- `test/cap10a/pweb.test.cli.pas:326` — `args|build|unknown_command` becomes
  `args|build|ok` plus the six option rows; `cli_digest` moves, and the pin
  is `test/cap10c1/run_cap10c1_gates.ps1:783` (`$cliClosure`).
- `test/cap10b2/run_cap10b2_gates.ps1:105-108` —
  `$CAP10B1_REACT_INVENTORY_DIGEST` and `$CAP10B1_REACT_TOTAL_BYTES` are the
  only **literal** template pins; the README supersession moves both. The
  file count stays 16.
- `test/cap10c3/check_cap10c_ledger.ps1:203` — the docs index must
  cross-link every contract document; `docs/index.md` gains the
  `build-contract.md` row.
- C1-11(d)'s duplicated names, for the contract check:
  `PWEB_PACK_BUNDLE` (`pweb.cli.pack.pas:37`) versus `PWEB_CLI_RUN_BUNDLE`
  (`pweb.cli.run.pas:70`); `PWEB_FE_NODE_MODULES`
  (`pweb.cli.frontend.pas:95`) versus `PWEB_NPM_NODE_MODULES`
  (`pweb.cli.toolset.pas:89`).
- `docs/` sentences that become false and must be superseded:
  `cli-contract.md` §1 (the "`build` is an unknown command" paragraph) and
  §4; `pipeline-contract.md` intro; `supervision-contract.md` intro
  ("`pweb build` (CAP-10D) **will** run its toolchain through it too");
  `dev-contract.md` §1, §11 ("exposes no `build`") and §12.

## Tasks & Acceptance

**Execution:**

- [x] `tools/pweb/pweb.cli.args.pas` -- add `pccBuild`, the `build` token and
  `build` to the `--verbose`/`--no-color` refusal clause -- one parser, one
  grammar, no new usage cause.
- [x] `tools/pweb/pweb.cli.report.pas` -- add `PWebCliBuildHelp` and the two
  banner lines -- the help text is where a reader learns the surface.
- [x] `tools/pweb/pweb.cli.build.pas` -- NEW: the private driver that calls
  `PWebCliRunPipeline` once and measures the committed layout -- one
  execution path, and a unit whose linkage and process-freedom are both
  measurable.
- [x] `tools/pweb/pweb.pas` -- add `RunBuild`, dispatch `pccBuild`, wire its
  help, print the six-field summary and the conditional `pweb run` line --
  the dispatch layer decides exit codes and prints, and does nothing else.
- [x] `test/cap10d0/psargs.ps1` -- NEW: the one pwsh argument-quoting helper
  (CRT rules, mirroring `PWebCliWindowsCommandLine`), proven by a round trip
  against `test/cap10c0/pwebchild` -- closes C1-11(a)/C0-12(b).
- [x] `test/cap10a,b0,b1,b2,c0,c1,c2,c3/*.ps1` -- adopt `psargs.ps1` at every
  `Start-Process -ArgumentList` call site -- one helper, every gate, all at
  once, as the ledger entry requires.
- [x] `test/cap10d0/pweb.test.build.pas`, `d0tests.pas` -- NEW: the headless
  decision corpus (grammar, help, the driver's pure parts, the replacement
  table, mutation-set membership) -- a corpus four targets must agree on.
- [x] `test/cap10d0/pwebbuilddrv.pas` -- NEW: spawns the real `pweb build`
  with `SeparateConsole` and delivers a real interrupt -- B5 on four targets,
  and the Windows measurement CAP-10C1's ST10 recorded as `not_measured`.
- [x] `test/cap10d0/build_cap10d0.{ps1,sh}` -- NEW: compile the suite and the
  driver against the staged SDK root -- mirrors `build_cap10c3.*`.
- [x] `test/cap10d0/check_cap10d0_contracts.ps1` -- NEW, checkout-only: one
  `PWebCliExecute` call site; the driver names no process API; the ten stage
  names and eight bounds unchanged; the mutation set unchanged; five
  commands advertised; no unratified option token in the parser; the C1-11(d)
  name pairs byte-equal; `docs/index.md` cross-links `build-contract.md`.
- [x] `test/cap10d0/run_cap10d0_gates.ps1` -- NEW: B1-B12, L1-L3, R1-R2;
  emits `build/cap10d0/cli-<target>.json`.
- [x] `test/cap10b0,b1,b2,c0,c1,c2,c3` -- invert every "`build` is unknown"
  pin, each with a comment naming CAP-10D0 -- inverted, never deleted.
- [x] `test/cap10a/pweb.test.cli.pas` -- move `args|build|...` to `ok` and add
  the six option rows; re-baseline `$cliClosure` in
  `test/cap10c1/run_cap10c1_gates.ps1` with the old value in a comment.
- [x] `tools/templates/react/README.md`, `tools/templates/pas2js/README.md`
  -- supersede: document `create doctor build dev run` honestly -- the
  READMEs promise steps that now have names.
- [x] `test/cap10b2/run_cap10b2_gates.ps1` -- re-pin
  `$CAP10B1_REACT_INVENTORY_DIGEST` and `$CAP10B1_REACT_TOTAL_BYTES`, old
  values in a comment naming CAP-10D0 -- a recorded supersession.
- [x] `test/cap7f/emit_evidence.ps1`, `check_cap7f_aggregate.ps1`,
  `check_cap7f_selftest.ps1` -- read the D0 record, add its equality fields
  and absolute pins, and one negative self-test leg per new refusal.
- [x] `.github/workflows/ci.yml` -- four native jobs gain the D0 build,
  contracts, gates and upload steps after C3; the Windows job gains the L1
  long-path leg; L2b only if ratified.
- [x] `docs/build-contract.md` -- NEW: the public build command, the grammar,
  the output, the replacement rule with its window and its failure table, the
  exit mapping by reference, and what a build does not do.
- [x] `docs/index.md`, `docs/cli-contract.md`, `docs/pipeline-contract.md`,
  `docs/supervision-contract.md`, `docs/dev-contract.md` -- supersede every
  sentence that says `build` is unknown.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append the
  CAP-10D0 entries, including the C0-12 and C1-11 dispositions with their
  measurements and the CAP-10D1 handoff.
- [x] `_bmad-output/implementation-artifacts/cap10d0-final-artifact.md` --
  the closure: the hosted green run, every supersession recorded, every
  ledger disposition, and the freeze result.

**Acceptance Criteria:**

- Given a freshly created React project and a freshly created Pas2JS
  project, when `pweb build` then `pweb run` are executed from an unrelated
  working directory on each of the four targets, then
  `CalculatorService.Add(20,22)` answers **42** through the real CLI with no
  script in between.
- Given the shipped `pweb`, when its compiled unit set and its sources are
  measured, then `pweb.cli.pipeline` is the only unit that calls
  `PWebCliExecute`, `pweb.cli.build` names no process API, the ten stage
  names and the eight `PWEB_CLI_PIPE_*` bounds are unchanged, and
  `pweb --help` advertises exactly `create doctor run dev build`.
- Given the project tree minus the four ratified writable prefixes, when it
  is digested before and after a build, then it is unchanged.
- Given the hosted Windows runner and a project path exceeding MAX_PATH,
  when `pweb build` runs, then the ratified long-path rule holds and is
  recorded as a measurement, never as an assertion.
- Given a path carrying a space, when every CAP-10 gate runs, then all are
  green through the one shared quoting helper.
- Given the six C1-11 observations, when the artifact is read, then each
  carries exactly one disposition — resolved, or CAP-10D1/CAP-10D2 with a
  reason — and the template supersession is recorded with its old and new
  digests.
- Given the final HEAD, when hosted CI runs, then every job is green and the
  CAP-7F aggregate passes on four targets.

## Design Notes

**Why the replacement window cannot be zero.** The commit is two renames,
and no portable primitive swaps two populated directories atomically.
Windows `MoveFileExW` has no directory-swap form and
`MOVEFILE_REPLACE_EXISTING` does not apply to a non-empty directory; POSIX
`rename(2)` replaces a directory only when the destination is an **empty**
one, and answers `ENOTEMPTY` otherwise; Linux's `renameat2(RENAME_EXCHANGE)`
would work and is Linux-only, which would make one rule three. An
indirection — a junction or symlink at `release` — is refused by the C0
resolver itself, which fails any reparse point anywhere on the layout chain
(`layout_link`), so a swap-by-link produces a layout `pweb run` will not
accept. `docs/pipeline-contract.md` §8 already ratifies the consequence: the
only intermediate state is *no* release, which `pweb run` reports as
`not_built` — a correct answer — and never a mixture of two builds. D0
ratifies that sentence as the public rule and measures it, and the evidence
field the brief names `build_never_without_release` is emitted as the two
honest fields `build_never_partial_release = true` and
`build_replacement_window = one_rename_no_release`.

**The commit sequence, and its failure table.**

```
1  assemble the new release in <output>/<target>/.pweb-release.tmp
2  if release/ exists as a DIRECTORY:
     2a remove .pweb-old.tmp if present   (guarded remover, refuses a link)
     2b rename release -> .pweb-old.tmp   (never replaces)
3  rename .pweb-release.tmp -> release    (never replaces)
     on failure, and only if 2b happened: rename .pweb-old.tmp -> release
4  remove .pweb-old.tmp                   (guarded; a failure is REPORTED,
                                            never fatal, exit unchanged)
5  verify through the CAP-10C0 resolver itself
```

| failure at | on disk afterwards | exit |
|---|---|---|
| stages 1-8 | old `release/` untouched; no staging left | 3/4/5/6 per §9 |
| 1 (`layout_input_missing`, `_stage_dir_`, `_stage_copy_`) | old `release/` untouched; staging reclaimed | 6 |
| 2a/2b (`layout_reclaim_failed`) | old `release/` untouched | 6 |
| 3 (`layout_commit_failed`) | the old release renamed **back**; if the rollback also fails the tree is at `.pweb-old.tmp` and the diagnostic names it | 6 |
| 4 | new release in place; `.pweb-old.tmp` remains and is reported | 0 |
| 5 (`verify`) | the committed release is removed: no release, `not_built` | 6 |

**The race with `pweb run`, measured rather than assumed.** `pweb run`
launches the application with the executable's **own directory** as its
working directory. On POSIX a directory that is a process's CWD renames
freely and the running process keeps its inode, so a build replaces the
layout underneath it and the old application runs to completion; a run
started afterwards gets the new one. On Windows a directory that is any
process's current directory **cannot** be renamed, so step 2b fails and the
build is refused with `layout_reclaim_failed` while the running application
is untouched. Both are correct — neither ever yields a partial layout — and
they are different, so the corpus carries a typed
`build_replace_while_running` per target rather than one claim that would be
false somewhere. The driver adds one advisory line on that refusal naming the
likely cause; the cause code and the exit category do not move.

**The summary.** Stage progress is a supervisor line and goes to stderr with
the `pweb: ` prefix, exactly as `run` and `dev` emit theirs; a stage's
forwarded child lines go to stdout, exactly as `pwebpipe` routes them. The
summary is six fields and no more:

```
pweb: built demo
  ui           react
  target       windows-x86_64
  release      dist/windows-x86_64/release
  app.pwb      3f2c...64 hex...
  bytes        4823104
pweb: run it with `pweb run`
```

The last line is emitted **only** when the `verify` stage's resolver accepted
the layout. The release directory is project-relative — the whole truth, and
the one form identical on every machine.

**C0-12(a), the measurement before the rule.** `pweb.cli.platform` hands
`CreateProcessW` `PWebCliDisplayPath(ExePath)` for `lpApplicationName`, the
same for argv[0] inside `PWebCliWindowsCommandLine`, and
`PWebCliDisplayPath(WorkDir)` for `lpCurrentDirectory`. L1 creates a project
whose native path exceeds MAX_PATH on the hosted Windows runner, runs
`pweb build`, and records the exit, the failing stage, the cause and the
`GetLastError`. Then exactly one branch is ratified:

- **R1** (ratified as the default) — the canonical `\\?\` form for
  `lpApplicationName`, a prefix-free `lpCurrentDirectory` refused above 259
  characters with a typed cause. Windows has a hard MAX_PATH on a process's
  current directory, so a refusal is the only honest answer there.
- **R2** — the chain already works end to end: close RECORDED-ONLY.
- **R3** — a deeper obstacle (a tool of its own refuses): re-ledger with the
  measurement and name the owner.

**C1-11, six observations, six dispositions** (to be recorded with their
measurements in the final artifact):

| item | disposition | reason |
|---|---|---|
| (a) shadowed toolset branches | **CAP-10D1** | measured: `pweb build` adds no toolset caller — one `PWebCliResolveToolset` inside stage 2, the same call `dev` makes — so the premise that D0's `build` is that caller is false |
| (b) the `plrCommit` rollback unexercised | **CAP-10D1** | the refusal itself is now seeded portably (B4c: `release` pre-seeded as a file) and green on four targets; the `hadOld` rollback inside it needs a fault injected between two renames, i.e. a production test seam the D0 freeze forbids |
| (c) manifest re-emitter escape forms | **CAP-10D2** | SDK packaging owns the distribution manifest; the ST1 gate keeps comparing against the real script on four targets on every leg |
| (d) two names in two units | **RESOLVED** | the D0 contract check asserts `PWEB_PACK_BUNDLE` equals `PWEB_CLI_RUN_BUNDLE` and `PWEB_FE_NODE_MODULES` equals `PWEB_NPM_NODE_MODULES` at the source |
| (e) `arg_longpath_form` / `pipeline_mutation` unseeded | **RESOLVED** | `pipeline_mutation` is seeded by a D0 fixture whose build writes outside the mutation set; `arg_longpath_form` is reached for real by L1, where a plan builder that forgot `PWebCliArgPath` fires it |
| (f) per-call-site `Flush` | **CAP-10D1** | D0 adds no unflushed call site — it reuses `pweb.pas`'s `Emit`/`EmitErr`, both of which flush — so there is no failing property today |

**The evidence fields**, per target, semantically equal across the four
(the native binary keeps its per-target pin): `cli_build_available`,
`advertised_commands_d0 = create,doctor,run,dev,build`,
`build_react_rpc_value` and `build_pas2js_rpc_value` = 42,
`build_replacement_rule = stage_aside_rename_reclaim`,
`build_never_partial_release = true`,
`build_replacement_window = one_rename_no_release`,
`build_failure_leaves_old_release = true`, `build_interrupt_clean`,
`d0_build_deterministic = true`, `build_network_stages`,
`build_network_calls`, `d0_project_tree_unchanged = true`,
`build_replace_while_running` (typed per family), `long_path_rule`
(Windows measured, `not_applicable` elsewhere), `gate_quoting_space_path`,
`release_path_observations_disposed = 6`,
`template_supersession_recorded = true`.

**Aggregator refusals to add**, each with a negative self-test leg (C2-9):
missing target; build unavailable; RPC other than 42 after a public build; a
partial layout observed; the old release altered on a failure; a
non-deterministic `app.pwb`; network outside `install`; descendants above 0;
fewer than six disposed observations; a SKIP promoted.

## Verification

**Commands:**
- `pwsh test/cap10d0/check_cap10d0_contracts.ps1` -- expected: PASS, 0
  violations, `build/cap10d0/contracts.json` written.
- `test/cap10d0/build_cap10d0.sh` (WSL / POSIX) and
  `pwsh test/cap10d0/build_cap10d0.ps1` (Windows) -- expected: the suite and
  the driver compile against the staged SDK root on both families **before**
  any push, per the standing rule that POSIX legs are validated locally.
- `pwsh test/cap10d0/run_cap10d0_gates.ps1` -- expected: every B/L/R leg
  green, `build/cap10d0/cli-<target>.json` emitted with the fields above.
- `pwsh test/cap10a/check_dev_trust.ps1` -- expected: PASS, unchanged.
- `pwsh test/cap10c3/check_cap10c_ledger.ps1` -- expected: PASS with the
  index cross-link intact.
- `pwsh test/cap7f/check_cap7f_selftest.ps1` then
  `pwsh test/cap7f/check_cap7f_aggregate.ps1` -- expected: every new refusal
  has a leg that proves it fires, and the aggregate passes over four
  downloaded corpora.
- `gh run view <id>` on the final HEAD -- expected: every job green.

**Manual checks:**
- `pweb build > out.txt 2> err.txt` on each family: `err.txt` carries the
  stage lines and the six-field summary, `out.txt` carries only tool output;
  neither carries an ESC byte written by `pweb`, an absolute path, the SDK
  location or a home directory.
