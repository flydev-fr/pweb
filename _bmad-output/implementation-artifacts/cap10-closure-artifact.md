# CAP-10 — phase closure: the `pweb` CLI, from scaffold to a distribution

CAP-10 is eleven shards and one claim: **a `pweb` CLI drives the application
lifecycle from scaffold to release**, and — since CAP-10D2 — the CLI itself is
something you can hand somebody.

```
pweb create demo --ui react|pas2js --bundle-id com.example.demo
pweb doctor
pweb dev
pweb build [--profile normal|offline|fixed-runtime|archive]
pweb run                                             -> 42
```

Five public commands, one public option, and one archive per target whose
extracted tree is the SDK root those commands run out of.

---

## 1. The eleven shards, and the hosted run that closed each

| shard | closure HEAD | hosted run | what it proved |
|---|---|---|---|
| CAP-10A | `08a8b6f24137820eec7da66b251dfc63545c40d6` | 33071121924 | the native CLI, `pweb.json` schema 1, the `doctor` requirement graph, the six exit codes and the reusable runtime-command layer; ONE `cli_digest` and ONE `doctor_schema_digest` on four targets |
| CAP-10B0 | `1dd45ecd98d83384216d225345da7d26cd0ef092` | 33113867439 | the scaffold engine, the trusted template pack and its compiled registry — the pack carries bytes and is believed about nothing else |
| CAP-10B1 | `35f288ddc3b5c3b35dc6083afc32be12ee1ba335` | 33127976094 | `pweb create --ui react`: ONE `generated_inventory_digest` on four targets and **42** from a real system WebView |
| CAP-10B2 | `64e0cd8` | 33168355248 | `pweb create --ui pas2js`: ONE `pas2js_generated_inventory_digest` on four targets and **42** from JavaScript Pas2JS 3.0.1 compiled out of Object Pascal |
| CAP-10C0 | `28349ef4bd8e42629512f33e606ebef29aa0a09f` | 33625058683 | `pweb run` and the ONE child-process engine: exact path, argument vector, explicit working directory, no shell, graceful-then-forced, drained by membership |
| CAP-10C1 | `94694bcaf17ba6fdcab29875f66e3b9a1d6cad42` | 33685847062 | the ten-stage lifecycle pipeline, the SDK root, the project-mutation set and the network policy |
| CAP-10C2 | `765d5d0df049ca130353ea1217a6791a295043a3` | 33748442256 | `pweb dev` for React: rebuild-and-reload behind `pweb://app`, the privileged origin unchanged |
| CAP-10C3 | `99bee05b8247c0ef7f99121d709f21f42c50c12c` | 33794370400 | `pweb dev` for Pas2JS: one content-fingerprint detector, one ladder, and the CAP-10C phase closure |
| CAP-10D0 | `a67978ef` | 33851014894 | the public `pweb build` over the frozen pipeline: ONE `build_digest` on four targets and **42** through the real `pweb run` after the real `pweb build`, for both frontend kinds |
| CAP-10D1 | `89538dee` | 33883767131 | `pweb build --profile`: three Windows installer profiles over the CAP-13 mechanics, one deterministic archive on Linux and macOS, one identity derived from `pweb.json` and refused rather than escaped |
| CAP-10D2 | `1714b65c` | 33919712393 | the SDK distribution, its integrity model, the clean-machine proof and this closure: one archive per target extracted to a spaced non-ASCII path with the checkout aside, **42** from both UIs on four targets, ONE `sdk_digest` `b33df77e…` and ONE `sdk_ship_table_digest` `1308731a…` |

## 2. The SPEC's CAP-10 acceptance, line by line

The SPEC states CAP-10 as one intent and three success clauses. Quoted
verbatim, so a reader can see that the table below answers what was actually
written:

> **intent:** A `pweb` CLI drives the application lifecycle from scaffold to release.

Each clause is answered with the evidence that meets it or with a named
ratified deviation. There is exactly one deviation and it is not a shortfall
against the acceptance line — it is against a *may* in the constraints.

| id | verdict | clause, and the evidence or the ratified reason |
|---|---|---|
| A1 | MET | *a `pweb` CLI drives the application lifecycle from scaffold to release* — five public commands, each proven end to end on four hosted targets; and since CAP-10D2 the release includes the CLI's own distribution, so "from scaffold to release" now closes on itself |
| A2 | MET | *`pweb create MyApp --ui react` scaffolds a runnable app* — CAP-10B1 run 33127976094: ONE `generated_inventory_digest` on four targets, and `CalculatorService.Add(20, 22) = 42` from a real system WebView |
| A3 | MET | *`--ui pas2js` scaffolds a runnable app* — CAP-10B2 run 33168355248: ONE `pas2js_generated_inventory_digest` on four targets, and 42 from JavaScript compiled by Pas2JS 3.0.1 out of Object Pascal |
| A4 | MET | *`pweb dev` runs the frontend watcher and native executable together* — CAP-10C2 (Vite watcher plus the development host, run 33748442256) and CAP-10C3 (the content-fingerprint detector plus the same host, run 33794370400), both under one supervision ladder with two long-lived children |
| A5 | DEVIATED | *Vite HMR **may** use a narrowly scoped development-only WebSocket* (`SPEC.md`, dev-mode trust model). PWeb uses **rebuild-and-reload** and opens no WebSocket at all. The reason is a measurement, not a preference: the CAP-10C2 model-A spike (`cap10c2-model-a-spike.md`) served Vite's own module graph behind `pweb://app` and recorded what it costs — and the SPEC's clause is permissive, so what is deviated from is an allowance rather than a requirement. Production contains no localhost and no WebSocket allowance, which is the property the clause exists to protect, and it is stronger this way |
| A6 | MET | *`pweb build` produces a packaged release* — CAP-10D0 run 33851014894: ONE `build_digest` on four targets, a release directory the CAP-10C0 resolver itself re-accepts, and 42 through the real `pweb run` afterwards for both frontend kinds |
| A7 | MET | *`pweb build` emits `normal`, `offline` and `fixed-runtime` profiles* (the CAP-13 acceptance line CAP-10 delivers the command for) — CAP-10D1 run 33883767131: a generated application installed, ran 42 and uninstalled with zero residue from a PWeb-built `normal` installer on hosted Windows, with `offline` and `fixed-runtime` built from validated pinned inputs over byte-identical CAP-13 `[Code]` |
| A8 | MET | *the lifecycle runs on a machine that never built this repository* — the clause the SPEC implies by saying "CLI" rather than "harness". CAP-10D2: one archive per target, extracted to a path with a space and a non-ASCII character with the checkout's six framework trees renamed aside, driving `doctor`, `create`, `build`, `--profile` and `run` to **42** for both UIs, with `checkout_path_in_argv` = 0 and every unit and library path under the extracted root |

`cap10_spec_acceptance_lines_met` = 7, `cap10_spec_acceptance_lines_deviated`
= 1, and the deviation is named rather than absorbed.

## 3. Every supersession recorded across the phase

| what | from | to | shard |
|---|---|---|---|
| `cli_digest` | — | `dc068531…4114b` | 10A (established) |
| `cli_digest` | `dc068531…` | `97c7b846…` | C0 (`run` ratified) |
| `cli_digest` | `97c7b846…` | (C2 value) | C2 (`dev` ratified) |
| `cli_digest` | (C2 value) | `9eb329ae…` | D0 (`build` ratified) |
| `cli_digest` | `9eb329ae…` | `4aa3c03b…` | D1 (`--profile` ratified) |
| `doctor_schema_digest` | — | `2dda57ba…c8fa7aa` | 10A (established) |
| `doctor_schema_digest` | `2dda57ba…c8fa7aa` | **moved by D2** | D2 — the three `sdk.*` rows; the ONE absolute pin, `test/cap10c1/run_cap10c1_gates.ps1`, moves with it |
| `pipeline_units_linked` | absent from the CLI | **required present** | C2 (the pipeline became public) |
| the CAP-7F divergence allowlist for `pweb.pas` | 2 | 4 | C2 |
| `build_execute_callers` | four | **five** (`pweb.cli.package`) | D1 |
| the D0 unratified-option list | nine | **eight** (`--profile` removed) | D1 |
| the pipeline bounds table | eight | **nine** (`PWEB_CLI_PIPE_MAX_ROOT_CHARS`) | D1 |
| the CAP-10A `--profile` case | `unknown_option` | accepted | D1 |
| the D0 gate's option matrix (B9) | one leg | **three** | D1 |
| the CAP-7F cross-target equality set | 44 per-target fields compared | **31 shared facts** compared | D1 |
| the SDK root layout | nine entries | **eleven** — `share/pweb/sdk-manifest.json` and `share/pweb/licenses/`, both ADDITIVE | D2 |
| `PWebCliSdkManifest`'s string re-emission | the source bytes | the **canonical** escape form | D2 (closes C1-11 (c)) |
| `docs/distribution-contract.md` §3, §6, §7 | `dist/<profile>/`, `.pweb-pack.tmp`, "else PATH" | `artifacts/<profile>/`, `.pwpack.tmp`, "and nowhere else" | D2 — three DOCUMENT corrections; nothing in the product moved |

Re-measured **unchanged** by CAP-10D2 and required so: `build_digest`,
`pipeline_digest`, `dev_digest`, `dev_pas2js_digest`, `supervision_digest`,
`pack_digest`, `build_stage_count` = 10, `build_execute_callers` = 5,
`create_corpus`, `pas2js_create_corpus`, and every dependency pin.

## 4. The phase-wide ledger, disposed

165 entries across eleven shards, every one with exactly one judgement from
the closed set `RESOLVED | RECORDED-ONLY | CAP-11 | CAP-12 | CAP-13 | LATER`.
`test/cap10d2/check_cap10_ledger.ps1` re-derives every key and every digest
from `deferred-work.md` on every CI leg, so an entry ADDED, REMOVED or
REWORDED fails the gate rather than passing unnoticed:
**`cap10_ledger_orphans` = 0**.

The four the CAP-10D2 brief named by hand are `B1-5` (the three example
hosts), `D1-8` (the offline/fixed install matrix), `D1-15`/`D1-16`/`C3-15`
/`B1-10`/`B2-16` (the hosted-Windows infrastructure flakes), `10A-6`/`B0-8`
/`B1-7`/`B2-7`/`C0-9`/`D2-10` (the `ci.yml` budget), `C2-5` (the HMR option),
and `C3-1`/`C3-4` (the native-source rebuild loop). Each is below with its
reason.

| key | digest | disposition | reason |
|---|---|---|---|
| 10A-1 | 0f3649c6 | RESOLVED | the four byte-similar `pweb.openExternal` copies were consolidated, and the entry it retired stayed retired |
| 10A-2 | a12b9c5f | RESOLVED | the build and release doctor modes were assigned to CAP-10C/D and CAP-10D1 answered the question they would have asked - the packaging PREFLIGHT resolves and verifies every pinned input before the pipeline runs, which is earlier and more specific than a diagnostic row |
| 10A-3 | 75818210 | RECORDED-ONLY | npm is diagnosed by PRESENCE because on Windows its only PATH entry point is a batch file; re-ratified at CAP-10C1 (C1-4) and unchanged since |
| 10A-4 | 8e217c49 | RECORDED-ONLY | a POSIX path is bytes and this CLI carries UTF-8; a measured platform fact rather than work anybody can do |
| 10A-5 | 6c6bb469 | RECORDED-ONLY | an FPC 3.2.2 test-fixture hazard, recorded so the next author does not rediscover it |
| 10A-6 | a6a7ef3d | CAP-11 | the `ci.yml` documentation budget: the per-platform split is CI work and CAP-11 is the phase that owns CI. The budget it inherits is stated at D2-10 |
| 10A-7 | b9d94dfc | RESOLVED | the CAP-10B handoff was consumed by CAP-10B0, B1 and B2 in order |
| B0-1 | 0827868a | RECORDED-ONLY | a measured POSIX commit-window residual; the rename that must not replace has no atomic form to move to |
| B0-2 | 9a646b62 | RECORDED-ONLY | the private fixture declares `ui = react` because schema 1 has two values and no third; a fact about the schema, not work |
| B0-3 | 5bb43210 | RECORDED-ONLY | a doubled opening brace opens a placeholder and there is no escape; an authoring constraint the pack builder enforces at build time |
| B0-4 | 0746420e | RESOLVED | the byte-at-a-time placeholder renderer was replaced in-shard before the pack was ever built |
| B0-5 | eb83acf6 | RECORDED-ONLY | FPC does not define argument evaluation order; a language fact recorded so a test author does not rely on one |
| B0-6 | befab678 | RESOLVED | CAP-10B1 mapped the template layer's typed codes onto the frozen six-code taxonomy, with the usage/environment split stated in `pweb.pas` |
| B0-7 | 8f079714 | RECORDED-ONLY | the CAP-7L shell-mode guard needs no carve-out: no CAP-10 shard has committed a script that wants one |
| B0-8 | eeb7e5b3 | CAP-11 | the same `ci.yml` budget as 10A-6; one owner, one split |
| B0-9 | fd2a5d93 | RESOLVED | the CAP-10B1 handoff was consumed by CAP-10B1 |
| B0-10 | 594f9220 | RECORDED-ONLY | the pack is deterministic per OS FAMILY because mORMot stamps a family-shaped field; a corrected Checkpoint-1 decision, kept as the record of why the claim is per family |
| B1-1 | 62d43ca1 | RECORDED-ONLY | `--output` was designed and deliberately not exposed; the CAP-10D0 surface closed at five commands and one option without it |
| B1-2 | deb0b2e9 | RESOLVED | closed twice over: CAP-10C1 staged mORMot and the platform artifacts into the one SDK root (C1-3), and CAP-10D2 ships that whole root as the distribution and verifies it file by file |
| B1-3 | c338c9d9 | RECORDED-ONLY | a freshly created project cannot be installed standalone and says so loudly; the `file:` specifier is what makes the staged SDK the only source |
| B1-4 | 651a3ed2 | RESOLVED | the CAP-10C handoff was consumed by CAP-10C2, which ratified rebuild-and-reload over HMR on the measured evidence of the model-A spike (C2-5) |
| B1-5 | bfe98de2 | LATER | the three example hosts still compose their own window instead of using `pweb.webview.host`. No property fails: the reusable host is proven by the generated templates on four targets, and `examples/` is a demonstration tree no gate builds a release from. It is a refactor with an owner nobody has named, and naming CAP-11 - whose subject is the CI matrix - would be assigning it to the wrong phase |
| B1-6 | 45e58ff2 | RECORDED-ONLY | `app.ready` is the starter template's channel and not the framework's; recorded so a reader does not take it for a runtime contract |
| B1-7 | 5c503423 | CAP-11 | the same `ci.yml` budget as 10A-6 |
| B1-8 | 43618ec6 | LATER | `create_help_digest` differs between Windows and POSIX and the cause is still not identified. It is compared PER FAMILY by the aggregator, so nothing depends on the difference and no product behaviour is affected; closing it means diffing two renders byte by byte, which is an afternoon nobody has needed to spend |
| B1-9 | cb6251e3 | RESOLVED | two implementations of one projection disagreed about a COMPARER; the ordinal rule is now spelled once and used everywhere |
| B1-10 | 5b22a894 | CAP-11 | the intermittent CAP-5 Pas2JS runtime smoke on hosted Windows - the `state=0` non-report class. CAP-11 owns instrumenting it: a non-report must say whether the page never loaded, never ran, or ran and missed its window. See D1-15, which measured it twice more at a different step |
| B2-1 | 9682ddd1 | RECORDED-ONLY | the two generated `.gitignore` files differ because the two UIs ignore different things; a ratified deviation from the objective, recorded with its reason |
| B2-2 | a0294511 | RESOLVED | the Pas2JS assembly strips the BOM and every CR, which is what makes the four-target semantic digest satisfiable at all |
| B2-3 | 740db426 | RESOLVED | the same closure as B1-2: CAP-10C1 completed the SDK root and CAP-10D2 ships and verifies it |
| B2-4 | 79aa1abc | RESOLVED | the POSIX build proof names the staged SDK's platform units, not the repository's |
| B2-5 | f023e6e6 | RECORDED-ONLY | `*.cfg` had to be un-ignored for the trusted template source; a repository fact recorded where the next author will look for it |
| B2-6 | 80baf736 | RECORDED-ONLY | the two generated native executables were byte-identical on the dev host - observed, never required, because a compiler is entitled to differ |
| B2-7 | b2c9a7aa | CAP-11 | the same `ci.yml` budget as 10A-6 |
| B2-8 | 523763ea | RESOLVED | the CAP-10C handoff for the Pas2JS side was consumed by CAP-10C3 |
| B2-9 | 090e91e6 | RESOLVED | `set -e` made three failure paths unreachable; fixed, and the class named so it is recognised next time |
| B2-10 | 893d2f06 | LATER | the same `set -e` shape survives in `test/cap10b1/prove_cap10b1.sh`. It is a CLOSED shard's harness, every leg of it passes, and the shape can only hide a failure that is not currently occurring; rewriting a closed proof to fix a latent hazard is a change with no failing property and a real regression risk |
| B2-11 | 7a25ed21 | RESOLVED | `pas2js_app_pwb_semantic_digest` measures the packed bundle rather than the pre-pack inventory |
| B2-12 | 9de45780 | RESOLVED | the React/Pas2JS report-shape parity compares the SHAPE, on both pages |
| B2-13 | eaf489c5 | RESOLVED | the FPC unit-path provenance is pinned by the staged SDK root rather than by nothing |
| B2-14 | 392c344a | RESOLVED | both vacuous measurements now fail when their sampler is absent instead of answering a clean zero |
| B2-15 | 7c6f224c | LATER | a generated project's `.gitattributes` does not name `*.cfg`. Only a Pas2JS project has one, its content is ASCII with LF, and the pack builder refuses a CR in a text template - so the divergence this would prevent cannot currently occur. A template change is a supersession of the compiled registry, and one with no failing property is not worth the digest move |
| B2-16 | 41282910 | CAP-11 | no harness fixture drives the "no report received" branch. It is the same instrumentation B1-10 and D1-15 need, and CAP-11 owns it: the fixture and the diagnosis are one piece of work |
| B2-17 | 10123fb2 | RECORDED-ONLY | `contracts.json` is uploaded and consumed by nothing; recorded rather than deleted, because a per-shard fact file costs nothing and the next aggregator may want it |
| B2-18 | c52fcdcb | RESOLVED | superseded by B2-19, whose measurements stand |
| B2-19 | 88c7aac1 | RESOLVED | the CAP-6b3 uninstall/process-drain race, corrected in CI teardown only |
| B2-20 | 84baf3c1 | RESOLVED | `return ,$array` in a function consumed as `@(f ...)`; fixed and kept as a lesson |
| B2-21 | ba2acb8c | RESOLVED | `Set-StrictMode` in a dot-sourced helper applies to the caller; fixed and kept as a lesson |
| C0-1 | 6a879f6b | RESOLVED | the `cli_digest` supersession is recorded in §2, and superseded again at CAP-10C2 with the same discipline |
| C0-2 | b7705b61 | RESOLVED | CAP-10C1 closed the half that is real: the pipeline resolves the npm entry point by the ratified rule, and the doctor's row stays PRESENCE by ratification (C1-4) |
| C0-3 | de150d85 | RECORDED-ONLY | Windows never disables Ctrl+Break for a new process group; a measured platform fact, not work anybody can do |
| C0-4 | 5f9b0d7d | RECORDED-ONLY | a supervisor ended by SIGKILL forwards nothing; the same class of fact, and SIGTERM/SIGINT/SIGHUP are what the drivers measure |
| C0-5 | d3c93b0b | RESOLVED | CAP-10C1 closed it (C1-6): the closer thread no longer sleeps the whole smoke bound while a stop waits |
| C0-6 | c2af93ab | RESOLVED | the divergence sweep counts mORMot's OS spellings, and the sweep re-ratifies on every leg |
| C0-7 | de2ce481 | RESOLVED | the drain's pass bound and its grace window are separate, fixed before the CAP-10C0 closure |
| C0-8 | 190d54dc | RECORDED-ONLY | `SeparateConsole` is a spawn option the product seam carries for the stop drivers; recorded so a reader knows why it exists |
| C0-9 | 9d0d6d92 | CAP-11 | the `ci.yml` documentation budget: the per-platform split is CI work, and CAP-11 is the phase that owns CI |
| C0-10 | faaaba61 | RESOLVED | the CAP-10C1 handoff was consumed by CAP-10C1 |
| C0-11 | 3c693cb8 | RESOLVED | the three reviewers' findings were fixed before the CAP-10C0 closure |
| C0-12 | b084a444 | RESOLVED | both halves closed on the release path: (b) by CAP-10D0's one pwsh quoting helper adopted by every CAP-10 gate, and (a) by CAP-10D1's `project_root_too_long` refusal at the `open` stage, whose bound is bracketed on the hosted Windows runner |
| C0-13 | 362abf97 | RESOLVED | CAP-10C1 added `Flush(Output)` at the three call sites (C1-1), so a supervised host's first sign of life reaches its supervisor |
| C1-1 | 84302c2d | RESOLVED | the template supersession is recorded, and the POSIX stdout debt it closes is C0-13 |
| C1-2 | b7078ba0 | RESOLVED | `arg_longpath_form` refuses a vector that still carries the extended-length prefix, checked where it cannot be forgotten |
| C1-3 | 71067ae3 | RESOLVED | the staged SDK root carries mORMot and the platform artifacts; a build reads nothing from `deps/` |
| C1-4 | 07d1910b | RECORDED-ONLY | a ratification, not work: the doctor's npm row stays PRESENCE and the pipeline resolves the entry point |
| C1-5 | 46f8b18d | RESOLVED | the listening-socket sampler is membership-scoped, and CAP-10C2 and CAP-10C3 both use it |
| C1-6 | 51443cae | RESOLVED | closes C0-5: a stop requested while the auto-close smoke bound is armed no longer waits for the whole bound |
| C1-7 | f2625bce | RESOLVED | CAP-10C2 swept every CAP-10 build script that guarded on the compiler's default target (C2-19) |
| C1-8 | 89e345d4 | RESOLVED | the CAP-10C2 handoff was consumed by CAP-10C2 |
| C1-9 | c2ae96b1 | RESOLVED | the three reviewers' findings were fixed before the CAP-10C1 closure |
| C1-10 | f40c60bb | RESOLVED | the sampler no longer starves the tree it samples |
| C1-11 | 560f8db5 | RESOLVED | all six: (a) RECORDED-ONLY at CAP-10D1 on the second measurement its own disposition asked for, (b) closed at CAP-10D1 through the `PWEB_LAYOUT_FAULTS` seam, (c) closed HERE - the re-emitter canonicalises escapes instead of copying source bytes, (d) and (e) resolved at CAP-10D0, (f) closed at CAP-10D1 as a gate |
| C1-12 | 826b8a81 | RESOLVED | the SDK's lib directory carries every name the target's dist provides, and the layout still ships only the one a release needs |
| C1-13 | 42bb2042 | RESOLVED | the gate forwards both streams |
| C1-14 | c0df29e1 | RESOLVED | `/noenter` is passed on Windows only, and the corpus must carry at least one decision whatever the platform |
| C1-15 | a1d3bbf7 | RESOLVED | the pipeline adopts the doctor's BUILD-time rows and not its run-time ones |
| C1-16 | 0cc8ebbc | RESOLVED | the decision corpus records the RULE and never the host that ran it |
| C2-1 | 965318f5 | RESOLVED | the React template supersession is recorded in §2, with the CAP-10B2 literals moved in the same commit |
| C2-2 | 61de6c63 | RESOLVED | the `cli_digest` supersession is recorded in §2 |
| C2-3 | 3d220578 | RESOLVED | `pipeline_units_linked` was inverted rather than deleted, and its negative leg with it |
| C2-4 | d32a10c9 | RESOLVED | the divergence allowlist re-ratified at 4, and the sweep re-ratifies on every leg |
| C2-5 | 6d781b05 | RECORDED-ONLY | the model-A spike is the DATA an HMR shard would start from; CAP-10C3 needed none of it, because Pas2JS development uses rebuild-and-reload and needs no WebSocket at all |
| C2-6 | 0fc62574 | RESOLVED | the risk was stated before the run and then measured; C2-22 is the fix |
| C2-7 | 0c5c066f | RESOLVED | the template's own `tsconfig.json` no longer refuses its own build config |
| C2-8 | 9808ec67 | RESOLVED | the probe binaries carry the webview library beside them, so a refusal that happens before any window can exist is actually reached |
| C2-9 | d0f8749c | RESOLVED | every CAP-10C2 aggregator refusal has a negative self-test leg, and CAP-10C3 adds one per new refusal |
| C2-10 | 41a9f4e0 | RESOLVED | DEV5, DEV7, DEV8 and DEV10 are driven and seeded rather than inferred |
| C2-11 | 05d462c6 | RESOLVED | the CAP-10C3 handoff was consumed by CAP-10C3: the completion-signal question it named is answered by the CLI-owned content fingerprint of `docs/dev-contract.md` §5b, and neither of the two candidates it listed was taken — a CLI-written sentinel would have made the CLI both the watcher and the signaller for no gain |
| C2-12 | 5927c7c0 | RESOLVED | the reload drain, bounded and placed before the first teardown step |
| C2-13 | b68515cc | RESOLVED | a start reclaims every published generation a previous session left |
| C2-14 | ae7e7fec | RESOLVED | `-B` is release-only; a development compile is incremental into directories no release build reads |
| C2-15 | 88179bd9 | RESOLVED | the build script names its target instead of guarding on the compiler's default |
| C2-16 | c12491aa | RESOLVED | the listener and loose-asset criteria are measured, and CAP-10C3 measures both again for Pas2JS |
| C2-17 | a9fefa01 | RESOLVED | the DEV14 leg reads a live log with `FileShare.ReadWrite`, so it stops passing only while its subject is broken |
| C2-18 | 13418636 | RESOLVED | the closed-shard gates pin `build` alone, each with a comment naming the shard that moved `dev` |
| C2-19 | b99b53e3 | RESOLVED | the default-target sweep closed C1-7 across every CAP-10 build script |
| C2-20 | 74f477e4 | RESOLVED | the `PWEB_DEV` region is in both templates, which is why CAP-10C3 needed no template change at all |
| C2-21 | 6da94776 | RECORDED-ONLY | the verification lesson — run the WHOLE regression set locally, never a subset — and CAP-10C3 acted on it by compiling and running the POSIX legs under WSL before the first push |
| C2-22 | 8255d4ed | RESOLVED | `Cache-Control: no-store` on all three adapters, human-ratified, pinned in source; recorded in §2 |
| C2-23 | edaa8b8c | RECORDED-ONLY | the measurement error worth keeping: a reproduction must name the artifact the build just produced |
| C2-24 | 38b3ab56 | RESOLVED | `csp_transport_terms` says `none` rather than being empty, so a target that failed to emit it is still told apart from one that measured no term |
| C2-25 | 5b5bc3a6 | RESOLVED | the two aggregate holes are closed, and the aggregate is run locally over downloaded evidence before it is trusted |
| C3-1 | dea40c70 | RECORDED-ONLY | a ratification: pas2js has no watch mode, so the detector is a poll over a CONTENT fingerprint |
| C3-2 | fc15aa29 | RESOLVED | a source that does not compile is no longer rebuilt forever; the loop waits for the input to change again |
| C3-3 | 1350cea0 | RECORDED-ONLY | the input-set walk carries its own bounds rather than borrowing the pipeline's; recorded so the two are not conflated |
| C3-4 | 104a2127 | RECORDED-ONLY | a Pas2JS session supervises one long-lived member, which is the same ladder and not a second one |
| C3-5 | 5a59ee4d | RESOLVED | generation 1's `app.pwb` IS the pipeline's release archive, measured rather than asserted |
| C3-6 | adb9b67b | RESOLVED | a fixture aliased a const argument with its own out parameter; found by its own test and fixed |
| C3-7 | 55d17d75 | RECORDED-ONLY | the "no absolute path" claim is about the SUPERVISOR's lines; pas2js makes the distinction visible and the contract states it |
| C3-8 | f1cd2ee3 | RESOLVED | the CAP-10C2 verification lesson was acted on before the first push, and CAP-10D0, D1 and D2 all followed it |
| C3-9 | 9a55ff0b | RECORDED-ONLY | CAP-10C3 moved no frozen value and re-measured each instead of assuming it; the record of a shard that superseded nothing |
| C3-10 | 2c636b01 | RESOLVED | the CAP-10D handoff was consumed by CAP-10D0, D1 and D2 in order |
| C3-11 | adb12f3a | RESOLVED | the inverted `dev11_*` legs, and the closed-shard leg that hung rather than going red |
| C3-12 | 2cd1e180 | RESOLVED | the gate puts the pinned pas2js on PATH, as every sibling gate does |
| C3-13 | 42db28d2 | RESOLVED | the archive parity is measured on a generation the cleanup cannot have removed |
| C3-14 | 351a39b2 | RECORDED-ONLY | the Pas2JS development loop behaved identically on four targets on its first complete run; a measurement worth keeping |
| C3-15 | 5087de8b | CAP-11 | the pinned FPC/Lazarus installer fetch stalled on a hosted Windows runner. It is the pinned-installer fetch-stall class the WebView2 Evergreen fetch already occupies, and CAP-11 owns instrumenting it with a bounded retry that has its own row rather than a longer timeout |
| D0-1 | de05ae0d | RECORDED-ONLY | the release-replacement window cannot be zero on either family, and the contract says so rather than pretending; a ratification with the platform facts behind it |
| D0-2 | f582503b | RECORDED-ONLY | a build racing a running application behaves differently on the two families and neither can produce a partial layout; measured, stated per target, and not work |
| D0-3 | 5520fdaf | RESOLVED | C0-12 (b) and C1-11 (a) closed: one pwsh quoting helper, adopted by every CAP-10 gate at once |
| D0-4 | e16857b1 | RESOLVED | superseded by D1-2, which closed C1-11 (b) whole through the `PWEB_LAYOUT_FAULTS` seam |
| D0-5 | ef15bf8b | RESOLVED | superseded by D1-1, which closed C1-11 (a) as RECORDED-ONLY on the second measurement its own disposition asked for |
| D0-6 | 370fdf29 | RESOLVED | (d) and (e) were resolved in CAP-10D0, (f) at CAP-10D1, and (c) - the manifest re-emitter's escape forms - is closed HERE: `ReadRawString` canonicalises through `PWebSdkJsonCanonical` instead of copying source bytes, and IN4 measures every escape class against JSON.stringify |
| D0-7 | c3a80c88 | RESOLVED | both generated READMEs document the five commands; the template supersession is recorded |
| D0-8 | 31806c6c | RESOLVED | the `cli_digest` supersession is recorded, and the nine "build is unknown" pins were inverted rather than deleted |
| D0-9 | 0940bc39 | RESOLVED | a seeded failure that did not fail, and the two legs it poisoned; found in local verification and fixed |
| D0-10 | b0fa568e | RECORDED-ONLY | a POSIX gate run needs a WSL-native working tree rather than `/mnt/c`; a method note that saved CAP-10D1 and CAP-10D2 a hosted run each |
| D0-11 | b1399381 | RECORDED-ONLY | three CAP-7F field-name collisions and the namespacing rule they force; the rule is what CAP-10D1 and CAP-10D2 followed |
| D0-12 | 20d241df | RESOLVED | the CAP-10D1 handoff was consumed by CAP-10D1 |
| D0-13 | 3d99e9ef | RESOLVED | a host-shaped value in a corpus four targets must agree about; measured on a hosted run and removed |
| D0-14 | dda0986e | RESOLVED | C0-12 (a) measured on the hosted Windows runner and then closed by D1-4: the CLI refuses `project_root_too_long` before the pinned compiler can be the thing that fails |
| D0-15 | bf359b5b | RECORDED-ONLY | a spaced-path re-run of a whole gate chain finds harness assumptions rather than product defects; the three it found were the harness's and were fixed |
| D0-16 | f8ca4996 | RESOLVED | twenty negative self-test legs had landed inside the function they call; fixed before the closure |
| D1-1 | 733f147f | RESOLVED | C1-11 (a) closed as RECORDED-ONLY, with `pack_resolves_toolset` false on four targets as the measurement |
| D1-2 | 48c38b9b | RESOLVED | C1-11 (b) closed: the `hadOld` rollback is exercised and the previous release comes back byte-identical |
| D1-3 | 5607df75 | RESOLVED | C1-11 (f) closed as not needed, with the reason turned from an observation into a gate |
| D1-4 | a5876488 | RESOLVED | the Windows long path: the CLI refuses with a typed cause before the pinned compiler can fail, and the bound is bracketed on the runner |
| D1-5 | 723ad529 | RESOLVED | `artifacts/<profile>/` rather than `dist/<profile>/`, found by the gate's first real run; the contract document caught up at D2-9 |
| D1-6 | 83e0f997 | RECORDED-ONLY | the profile name is `fixed-runtime` and never `fixed`; a ratification whose reason is the CAP-6b4 marker gate |
| D1-7 | 6f2d4612 | RESOLVED | the CAP-10D2 handoff was consumed by CAP-10D2, including its one named ledger item C1-11 (c) |
| D1-8 | 1e23241c | RECORDED-ONLY | the offline and fixed-runtime profiles are proven as BUILDS for a generated application and as INSTALLS by CAP-6b2 and CAP-6b3 over byte-identical `[Code]`. CAP-10D2 widens the build half and not the install half: the clean-machine leg BUILDS all three profiles from the EXTRACTED SDK - clean_machine_profile_result reads normal=0,offline=0,fixed-runtime=0 - and the install/run/uninstall claim stays CAP-10D1's, over an installer the identical code path produced. Re-installing from the extracted SDK would re-prove CAP-10D1 at about twenty minutes of hosted Windows time for no new claim; a shard that wants the other two install matrices should say so and pay for them |
| D1-9 | 7e800df5 | RECORDED-ONLY | the archive's byte-determinism is a per-target claim; the same is true of the SDK archive CAP-10D2 writes with the same writer, and both are pinned per target rather than across four |
| D1-10 | 606376c8 | RESOLVED | the cabinet expander is resolved from the system directory rather than through PATH |
| D1-11 | 73e5221d | RESOLVED | the fixed profile's own MAX_PATH ceiling, refused in the preflight and re-measured on every Windows leg |
| D1-12 | da5abe7c | RESOLVED | a path this CLI builds is checked like a descriptor value, twice, and refuses rather than escaping |
| D1-13 | 030fd3a3 | RESOLVED | ratifying an option is a supersession in two places; the option matrix keeps measuring the same property |
| D1-14 | f146f29e | RESOLVED | the CAP-10C3 driver's whole-file write retries for a bounded two seconds; nothing in the product changed |
| D1-15 | 1c146d3d | CAP-11 | the hosted-Windows `state=0` non-report, seen at two unrelated smokes. CAP-11 owns the instrumentation B1-10 and B2-16 also need: make a non-report say whether the page never loaded, never ran, or ran and missed its window. The disposition for the flake itself is unchanged - re-run the job, never re-ratify |
| D1-16 | d5d67fb8 | CAP-11 | the CAP-6b4 U3 fixed-profile uninstall residue, observed once and not diagnosed. CAP-11 owns the instrumentation: have U3 report the drain it observed before it measures the directory, so a residue failure can say whether a process was still holding the files |
| D1-17 | 95381015 | RESOLVED | the aggregate was comparing exactly the wrong forty-four fields; both halves fixed from a measurement over four real evidence files, and CAP-10D2's own block was written the same way |
| D2-1 | 24bec94a | LATER | the SDK ships no compiler, and Pas2JS additionally has no shippable licence text: the pinned 3.0.1 archive contains no `COPYING.FPC`. Shipping it needs an offline licence text pinned by digest from a reviewed source, which is a decision about provenance rather than a piece of engineering, and no phase currently owns it |
| D2-2 | 16005996 | RECORDED-ONLY | the lock FILES never ship and their digests do; a conflict between the brief and a frozen contract, resolved for the contract and measured as `sdk_lock_files_shipped` = 0 |
| D2-3 | b310af3b | RECORDED-ONLY | one archive rule on four targets, for CAP-10D1's own measured reason; a ratified deviation from the brief |
| D2-4 | 39d4c9a7 | RECORDED-ONLY | the integrity model's bound, stated plainly: an inventory catches an altered file and not a rewritten manifest, and closing the class needs a signature and a key nobody has ratified a home for |
| D2-5 | 6acfde06 | RECORDED-ONLY | the packager assembles a declared set because the repository's own SDK root legitimately carries a private test driver; a design record, measured as `sdk_test_drivers_shipped` = 0 |
| D2-6 | b1cce380 | RECORDED-ONLY | the unreachability mechanism is six renamed trees under a restoring `finally`, and the argv/unit-path assertions are the stronger half; a ratified mechanism |
| D2-7 | 1e73e270 | RECORDED-ONLY | the SDK is verified twice per build - 114 ms - and that is the price of the doctor receiving its environment rather than measuring it; recorded so nobody removes the wrong half |
| D2-8 | 928bae59 | LATER | PWeb's own licence is not declared anywhere in this repository, so the distribution ships third-party notices only. Somebody has to choose the terms; a shard cannot, and inventing one would be the silent derivation `cli-contract.md` refuses |
| D2-9 | cf28989d | RESOLVED | three statements in `docs/distribution-contract.md` had drifted from the shipped code; all three corrected, and section 11 of that document records what moved and why |
| D2-10 | 7e66f6b4 | CAP-11 | the `ci.yml` budget, now 253 KB and 5429 lines before this shard's own steps. CAP-11 owns the split, and what it must preserve is stated: the four platform jobs run the SAME step sequence, which is the property the CAP-7F aggregator exists to check |
| D2-11 | 58acec74 | RESOLVED | the CAP-11 handoff, written; it is section 6 of this artifact |
| D2-12 | eb03bf0d | RESOLVED | the SDK root could not be resolved from a non-ASCII path on Windows, because the RTL hands ParamStr(0) to a process through an ANSI conversion. PWebCliImageDir asks the kernel instead - GetModuleFileNameW - and the clean-machine leg that found it now passes at that very path |
| D2-13 | c3483e49 | LATER | the frozen CAP-6 bundler reads its argv through the same ANSI conversion, so a PROJECT at a non-ASCII path fails at the pack stage with a message about a directory that is plainly there. Closing it is either CAP-6 surface (a UTF-16 argv in pwebbundle) or a new exit-3 cause at the open stage the way CAP-10D1 refuses project_root_too_long; neither is additive to this shard, both routes are named in the entry, and the clean-machine leg keeps the non-ASCII where the brief asks for it - the extracted SDK root |
| D2-14 | 2fa8354b | RESOLVED | an SDK installed under a directory whose name has a space could not LINK on macOS: FPC re-splits its `-k` pass-through values on whitespace, and pweb.cli.native puts two SDK paths through `-k` there. PWebCliLinkPath applies FPC's own `maybequoted` rule to them, conditionally, so no argument vector CAP-10C1 pinned moves and the CAP-10C1 suite is unchanged |
| D2-15 | dd9d4690 | RESOLVED | a clean-machine doctor assertion must be the PIPELINE's rule and not the doctor's overall status: `platform.webview` answers `framework_absent` on hosted macOS by ratified measurement (C1-15), and CM1 now requires that no OTHER required row failed |

## 5. Known limitations of the phase, stated

Each known limitation below is carried in `deferred-work.md` with the entry
that measured it, and none of them is a defect nobody noticed.

1. **The macOS bundle is not signed with a Developer ID and not notarized.**
   `deployment.md` puts signing out of scope; `macos_codesign_observation`
   records `adhoc` on arm64 and `unsigned` on x64, and a `signed_identity`
   is a gate failure. A copy that reaches a machine through a browser
   carries `com.apple.quarantine` and Gatekeeper refuses it until the user
   removes the attribute (D1 §5).
2. **The offline and fixed-runtime profiles are proven as builds, not as
   installs, for a *generated* application.** Their runtime behaviour is
   CAP-6b2's and CAP-6b3's over byte-identical `[Code]`, and the CAP-10D1
   contract check requires the twins to stay byte-identical on every leg
   (ledger D1-8).
3. **The SDK's integrity model is an inventory, not a signature.** It
   catches an altered file; it does not catch a manifest rewritten to
   describe one, and it does not notice its own absence (ledger D2-4,
   `docs/sdk-contract.md` §4).
4. **PWeb's own licence is not declared anywhere in this repository**, so
   the distribution ships third-party notices only (ledger D2-8).
5. **The SDK ships no compiler.** FPC, Node and Pas2JS are host
   requirements with doctor rows; Pas2JS additionally has no shippable
   licence text, measured (ledger D2-1).
6. **The archive's byte-determinism is a per-target claim**, not a
   cross-target one: two runs on one machine agree byte for byte, and two
   targets legitimately do not (ledger D1-9, D2-3).
7. **`create_help_digest` differs between Windows and POSIX** and the cause
   is not identified. It is compared per family and nothing depends on it
   (ledger B1-8).
8. **Three hosted-Windows infrastructure flakes** are carried with owners
   rather than explained away: the `state=0` non-report, the CAP-6b4 U3
   uninstall residue, and the pinned-installer fetch stalls. All three are
   assigned to CAP-11 for instrumentation, and the disposition for a flake
   is unchanged — re-run the job, never re-ratify.

## 6. The CAP-11 handoff

**What CAP-11 inherits verbatim and may not renegotiate.** Everything
CAP-10D0 and CAP-10D1 handed over — the ten stages and their bounds, the run
layout and its resolver, the release layout, the project-mutation set, the
supervision engine and its one ladder, `docs/dev-contract.md`,
`docs/build-contract.md`, the whole of `docs/distribution-contract.md`
including its corrected §3/§6/§7 — plus the whole of
**`docs/sdk-contract.md`**: the shipped set and the pin-only set, the
manifest's schema and canonical form, the ratified escape rule, the three
integrity rows and their causes, the `open`-stage refusal at exit 4, the
tool-location rule with no fallback chain, and the installation model
(extract; nothing else is mutated).

**What CAP-11 owns.**

- **The CI matrix.** `.github/workflows/ci.yml` is 253 KB and 5429 lines
  before CAP-10D2's own steps, and five ledger entries across five shards
  have been recording that budget since CAP-10A. The split into
  per-platform workflows is CAP-11's, and what it must preserve is stated
  rather than assumed: **the four platform jobs run the same step sequence**,
  which is the property `test/cap7f/check_cap7f_aggregate.ps1` exists to
  check. A split that let them drift would remove the only thing that makes
  a four-target digest meaningful.
- **Artifact retention.** CAP-10D2 uploads four SDK archives (11 MB gzipped
  each on Windows) plus their manifests on every run. There is no retention
  policy beyond the 30 days every other upload uses, and a phase whose
  subject is CI should decide one deliberately.
- **The upstream `webview/webview` watcher, whose contract is REPORT AND
  NEVER RE-PIN.** It compiles the binding against upstream head and
  publishes an API diff. It must not move `webview.lock`, must not
  regenerate a binding, must not touch a build, and must not fail the
  matrix: an upstream that changed is news, not a regression.
- **Instrumenting three flakes**, none of which is a product defect and all
  of which have cost hosted runs:
  1. the hosted-Windows `state=0` non-report (`B1-10`, `B2-16`, `D1-15`) —
     a non-report must say whether the page never loaded, never ran, or ran
     and missed its window;
  2. the CAP-6b4 U3 fixed-profile uninstall residue (`D1-16`) — U3 must
     report the drain it observed *before* it measures the directory;
  3. the pinned-installer fetch stalls, Lazarus/FPC and WebView2 Evergreen
     (`C3-15`) — a bounded retry with its own evidence row, never a longer
     timeout.

**What CAP-11 must not touch.** The seven frozen interfaces,
`TInvocationContext`, `ICapabilityPolicy`, the scheduler, the mORMot bridge,
the nine-code taxonomy, protocol v1, the SDK wire, `app.pwb`, `plugins.zip`,
`pweb.json` schema 1, the CAP-10A parser grammar and exit taxonomy, the
CAP-10B0 engine and its compiled registry, the CAP-10C0 supervision engine
and layout, the CAP-10C1 ten stages and mutation set, the CAP-10C2/C3 dev
host and ladder, the CAP-10D0 build grammar, the CAP-10D1 identity rules and
pinned inputs, the CAP-10D2 shipped set and manifest, the CAP-8A policy core,
the CAP-8B classifier and CSP, the CAP-9 runtime, every CAP-13 file, the
three platform adapters, and every dependency pin.

## 7. Cross-links

| document | what it freezes |
|---|---|
| [../../docs/index.md](../../docs/index.md) | the map of every contract document |
| [../../docs/cli-contract.md](../../docs/cli-contract.md) | the command surface, schema 1, the doctor report and the six exit codes |
| [../../docs/template-contract.md](../../docs/template-contract.md) | the scaffold engine and the trusted pack |
| [../../docs/supervision-contract.md](../../docs/supervision-contract.md) | the one child-process engine |
| [../../docs/pipeline-contract.md](../../docs/pipeline-contract.md) | the ten stages, the SDK root and the mutation set |
| [../../docs/dev-contract.md](../../docs/dev-contract.md) | the development loop for both frontends |
| [../../docs/build-contract.md](../../docs/build-contract.md) | the public build command |
| [../../docs/distribution-contract.md](../../docs/distribution-contract.md) | `pweb build --profile` |
| [../../docs/sdk-contract.md](../../docs/sdk-contract.md) | the SDK distribution and its integrity model |
| [cap10c-closure-artifact.md](cap10c-closure-artifact.md) | the CAP-10C sub-phase closure this one widens |

---

## Verdict

**CAP-10 CLOSED.** Five public commands, one public option, eleven hosted
green runs, 165 ledger entries disposed with 0 orphans, seven SPEC acceptance
clauses met and one ratified deviation named, and a distribution a machine
that never built this repository can extract and use.
