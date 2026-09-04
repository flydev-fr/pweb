# CAP-10D0 — the public `pweb build`

CAP-10D0 is one command and one claim: **a developer who has just run
`pweb create` can build the project and run it, with no script in between,
on four targets, from any working directory.**

```
pweb create demo --ui react|pas2js --bundle-id com.example.demo
cd demo
pweb build
pweb run          -> 42
```

`pweb --help` now advertises `create doctor run dev build`. That is the
complete CAP-10 surface; the CAP-13 profiles, a distributable Linux
artifact, the macOS signing posture and SDK packaging are CAP-10D1 and
CAP-10D2, and none of their vocabulary is in the build path.

---

## 1. The public build command

```
pweb build [--project <path>]
pweb build --help
```

`--project` and `--help`, and nothing else. No new usage cause, no new exit
category, no new stage, no second execution path. The frontend kind comes
from `pweb.json`; the target is the host target; every stage runs on every
build, which is why there is no incremental mode, nothing to resume and
nothing to clean.

**Every option CAP-10D0 did not ratify is an option the parser refuses**,
and each absence is a contract rather than an omission: `--profile`,
`--target`, `--clean`, `--release`/`--debug`, `--json`, `--watch`,
`--install`, `--output`, `--force`. `check_cap10d0_contracts.ps1` refuses a
parser that grew one, and the CAP-10A decision corpus records the refusal of
four of them by name so the absence is a measurement rather than a promise.

`docs/build-contract.md` is the whole of the contract.

## 2. One execution path, and how it is measured

`tools/pweb/pweb.cli.build.pas` calls `PWebCliRunPipeline` exactly once and
then reads a disk. It spawns nothing, resolves no tool, knows no stage and
carries no platform conditional. Three independent measurements say so:

| what | how |
|---|---|
| the set of units that call the CAP-10C0 engine is unchanged at four | `check_cap10d0_contracts.ps1` enumerates `tools/pweb/*.pas` and requires exactly `pweb.cli.dev`, `pweb.cli.pipeline`, `pweb.cli.probe`, `pweb.cli.run` |
| the build driver names no process API by any spelling | thirteen spellings swept, zero hits |
| it compiles in isolation against the pipeline alone | `build_cap10d0.{ps1,sh}` step 1 |

The ten stage names, the eight `PWEB_CLI_PIPE_*` bounds and the four-prefix
project-mutation set are cross-checked against the source on every leg, and
the headless suite records them into a four-target decision corpus.

## 3. The release replacement, ratified and measured

The rule is the CAP-10C1 layout unit's, unchanged, promoted from an
implementation detail to the public rule and named
`stage_aside_rename_reclaim`: stage in `.pweb-release.tmp`, rename an
existing `release/` aside to `.pweb-old.tmp`, rename the staged tree into
place, reclaim the retired one, and verify through the CAP-10C0 resolver
itself. A rename that would replace an existing path is never used, on
either family.

**The window is stated rather than wished away.** Between the two renames
there is exactly one bounded instant with no release at all
(`one_rename_no_release`), and it cannot be removed: Windows has no atomic
directory swap, POSIX `rename(2)` replaces a directory only when the
destination is empty, `renameat2(RENAME_EXCHANGE)` is Linux-only and would
make one rule three, and an indirection through a junction or symlink is
refused by the C0 resolver itself. What never happens is a **partial** or a
**mixed** layout, and that is what the corpus records:
`build_never_partial_release = true`.

The failure table is `docs/build-contract.md` §3. Five of its rows are
measured headlessly over the production `PWebCliAssembleRelease`, on a real
fixture tree, on four targets — including the `plrCommit` refusal CAP-10C1's
ledger recorded as unexercised.

**The race with a running application is measured per family**, because the
two answers differ and one claim would be false somewhere: on POSIX the old
application runs to completion while the layout is replaced underneath it;
on Windows the release directory is the running application's working
directory, cannot be renamed, and the **build** is refused with
`layout_reclaim_failed` while the application is untouched.

## 4. The CAP-10D1 handoff

**Inherited verbatim, not renegotiable:** the CAP-10C1 ten stages, their
bounds and the Pas2JS assembly; the CAP-10C0 run layout, its resolver and
its exit mapping; the release layout per platform; the ratified
project-mutation set; the supervision engine and its one ladder; the whole
of `docs/dev-contract.md`; and now the whole of `docs/build-contract.md` —
the build grammar, the replacement rule and the six-field summary.

**CAP-10D1 owns:** the CAP-13 normal/offline/fixed profiles and how a build
selects one; what a distributable Linux artifact is beyond the directory the
pipeline commits; and the macOS bundle identity and signing posture. It
inherits three ledger items by name: **C1-11 (a)**, **C1-11 (b)** and
**C1-11 (f)** (§5).

**CAP-10D1 must not touch:** the dev loop, the dev host, the change
detector, the seam, `PWEB_NATIVE_CSP`, the privileged origin, `pweb.json`
schema 1, the seven frozen interfaces, the adapters, the CAP-10D0 build
grammar, or any dependency pin.

## 5. The two CAP-10D ledger items, disposed of

### C0-12 — the Windows argument forms

| half | disposition |
|---|---|
| (a) the MAX_PATH form for `lpApplicationName` | **MEASURED, and it answers the opposite of what the entry feared: CAP-10D0 changes nothing.** A Pas2JS project rooted at 233 characters — so `<root>/dist/windows-x86_64/release/demolp.exe` passes MAX_PATH comfortably — builds on the hosted Windows runner and answers `long_path_exit = 5`, `long_path_cause = stage_exited`. Exit 5 is "a stage's child failed and its real status is printed"; it is **not** the untyped `supervision_unavailable` (4) an unprefixed `lpApplicationName` would have produced. PWeb's own spawn reached the tool and the tool answered nonzero, so the `\\?\` change is not what this measurement calls for and none is made. `long_path_stage` names the owner: **`build`** — the pinned Pas2JS compiler, not this CLI. Re-ledgered to CAP-10D1 on that name, because a limitation whose owner is a third-party compiler is not one this repository can close. Typed `not_applicable` on the three POSIX targets |
| (b) the pwsh `Start-Process` quoting hazard | **RESOLVED** — one helper, `test/cap10d0/psargs.ps1`, adopted at all 24 CAP-10 call sites in one commit, verified against the fourteen CAP-10C0 golden rows before a call site moved, and proven continuously because the CAP-10D0 gate scaffolds both projects inside a directory whose name carries a space |

### C1-11 — the six release-path observations

| item | disposition | why |
|---|---|---|
| **C1-11 (a)** the toolset's shadowed branches | CAP-10D1 | measured false: `pweb build` adds no toolset caller — one `PWebCliResolveToolset`, inside stage 2, the same call `dev` makes — so the premise that D0's `build` is the caller that needs collapsing is wrong |
| **C1-11 (b)** the `plrCommit` rollback | CAP-10D1 | the refusal itself is now seeded portably and green on four targets; the `hadOld` rollback inside it needs a fault injected between two renames, which is a production test seam the D0 freeze forbids |
| **C1-11 (c)** the manifest re-emitter's escape forms | CAP-10D2 | SDK packaging owns the distribution manifest; the ST1 gate keeps comparing against the real script on four targets on every leg |
| **C1-11 (d)** two names in two units | **RESOLVED** | asserted by value in the suite and at the source in the contract check: `PWEB_PACK_BUNDLE` ≡ `PWEB_CLI_RUN_BUNDLE`, `PWEB_FE_NODE_MODULES` ≡ `PWEB_NPM_NODE_MODULES` |
| **C1-11 (e)** two unseeded production refusals | **RESOLVED** | `arg_longpath_form` is reached for real by the long-path leg rather than synthetically; `pipeline_mutation` is recorded by that leg's own outcome |
| **C1-11 (f)** the per-call-site `Flush` | CAP-10D1 | D0 adds no unflushed call site — `RunBuild` writes through `pweb.pas`'s `Emit`/`EmitErr`, both of which flush — so there is no failing property today |

## 6. Every supersession, recorded rather than claimed unchanged

| what | before | after | why |
|---|---|---|---|
| `cli_digest` | `c4c54b3c…` | `9eb329ae…` | the parser corpus records `args\|build\|ok` where it recorded `args\|build\|unknown_command`, plus seven option rows — exactly as CAP-10C0 moved it for `run` and CAP-10C2 for `dev` |
| the React template inventory | `ef9a9312…` / 16 / 71416 | `06e47ba8…` / 16 / 72884 | the README supersession. No file added or removed; only README.md's bytes moved |
| the Pas2JS template inventory | | moved | the same supersession, compared across four targets rather than pinned to a literal |
| `build_still_unknown` | `true` | `build_available` = `true` | **inverted, not deleted**, exactly as `pipeline_units_linked` was at CAP-10C2 and `dev11` at CAP-10C3 |
| `build_still_unknown_c3` | `true` | `build_available_c3` = `true` | the same inversion in the closing shard's own gate |
| `advertised_commands`, `_c2`, `_c3` | `create,doctor,run,dev` | `create,doctor,run,dev,build` | the surface moved, and the rows that measure it moved with it |
| `dev_build_unknown` | `build_only` | `none` | neither is unknown now; the row reports the surface matrix's verdict over a name that genuinely is |
| the nine "build is unknown" gate pins | `build` | `publish` | the subject moved to a name no shard will ratify, because the claim is a CLOSED command set |
| every `c1_app_pwb_*`, `pipeline_digest`, `dev_digest`, `dev_pas2js_digest`, `supervision_digest`, `doctor_schema_digest` | | **unchanged**, re-measured | a README is not in `dist/`, and CAP-10D0 changed no stage |

Nothing else moved. The seven frozen interfaces, `TInvocationContext`,
`ICapabilityPolicy`, the scheduler, the mORMot bridge, the nine-code
taxonomy, protocol v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json`
schema 1, the CAP-10A parser grammar and exit taxonomy, the CAP-10B0 engine,
the CAP-10C0 engine and layout, the CAP-10C1 ten stages, bounds and mutation
set, the CAP-10C2/C3 dev host, seam, generation rule, poller and ladder, the
CAP-8A policy core, the CAP-8B classifier and CSP, the CAP-9 runtime, the
CAP-13 profiles, the three platform adapters and every dependency pin:
unchanged.

## 7. Evidence

| leg | what it proves |
|---|---|
| B1/B2 | `pweb build` then `pweb run` answers **42** on a fresh React project and a fresh Pas2JS one, from an unrelated working directory, with the stage lines and the six-field summary the contract names |
| B3/B7 | a second build replaces the first whole, leaves neither temporary sibling behind, and produces an identical `app.pwb` and an identical layout inventory |
| B4 | a seeded stage failure stops the pipeline with the child's real status and leaves the previous release byte-identical |
| B5 | a **real** interrupt mid-compile, delivered through the CAP-10C0 console mechanism on all four targets, leaves the previous release untouched, no staging tree and zero descendants — the measurement CAP-10C1's ST10 recorded as `not_measured` on Windows |
| B6 | a build racing a running application: the application runs to completion and answers 42, and the two families' outcomes are typed apart |
| B2 network | a Pas2JS build's own process tree is **sampled** through the CAP-10C1 membership sampler while it runs, and opens zero connections — the declared "no network stage" turned into a measurement, with the sampler's own liveness required so a vacuous zero cannot pass |
| B8/B10/B11 | the project tree minus the mutation set is unchanged; no ANSI, no absolute path and exactly six summary fields; five commands advertised and every `<cmd> --help` green |
| L1/L2 | the Windows long path, measured; every CAP-10 gate green through one quoting helper, with both projects at a spaced path on every leg |

**The hosted run.** CAP-10D0's closure HEAD and the hosted run that was
green on it:

| shard | closure HEAD | hosted run | what it proved |
|---|---|---|---|
| CAP-10D0 | `a67978ef` | 33851014894 | all six jobs green; one `build_digest` `1d5230a9…9fb18` equal on windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64; `42` through the real `pweb run` after the real `pweb build` for both frontend kinds on every target; and `supervision_digest`, `pipeline_digest`, `dev_digest` and `dev_pas2js_digest` re-measured **unchanged** at their CAP-10C0/C1/C2/C3 closure values |

The substance behind the green, checked field by field rather than taken
from the conclusion: `build_corpus`, `build_suite`, `build_option_matrix`,
`build_help_matrix` and `gate_quoting_space_path` PASS on all four;
`cli_build_available`, `build_never_partial_release`,
`build_failure_leaves_old_release`, `build_interrupt_clean`,
`d0_build_deterministic`, `d0_project_tree_unchanged` and
`d0_template_supersession_recorded` true on all four;
`build_pas2js_network_calls`, `build_descendants_after_interrupt` and
`build_driver_spawns` zero on all four; `build_stage_count` ten,
`build_unratified_options` none, `release_path_observations_disposed` six.

The three per-target measurements, recorded rather than compared:
`build_replace_while_running` reads `windows_refused_layout_reclaim` on
Windows and `posix_old_runs_to_completion` on the three POSIX targets;
`long_path_rule` reads `typed_refusal_stage_exited` on Windows with
`long_path_stage = build` at 233 characters, and `not_applicable`
elsewhere.

The evidence above is emitted per target into `build/cap10d0/cli-<target>.json`
and aggregated field by field by `test/cap7f/check_cap7f_aggregate.ps1`,
which refuses a missing target, a build that is unavailable, an RPC other
than 42 after a public build, a partial layout, an altered previous release,
a non-deterministic `app.pwb`, network outside `install`, a surviving
descendant, fewer than six disposed observations, or a SKIP promoted to a
pass. Every one of those refusals has a negative self-test leg that proves
it fires.

## 8. Cross-links

| document | what it freezes |
|---|---|
| [../../docs/build-contract.md](../../docs/build-contract.md) | the public build command — this shard's contract |
| [../../docs/cli-contract.md](../../docs/cli-contract.md) | the public command surface and the six exit codes |
| [../../docs/pipeline-contract.md](../../docs/pipeline-contract.md) | the ten stages, their bounds and the release layout |
| [../../docs/supervision-contract.md](../../docs/supervision-contract.md) | the one child-process engine |
| [cap10c-closure-artifact.md](cap10c-closure-artifact.md) | the CAP-10C phase closure and the handoff this shard consumed |

---

## Verdict

**CAP-10D0 PASS — PUBLIC BUILD COMMAND FROZEN**
