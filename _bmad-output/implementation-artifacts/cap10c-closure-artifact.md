# CAP-10C — Phase Closure: supervision, the pipeline, and `pweb dev` for both frontends

CAP-10C is four shards and one claim: **a developer edits a source file and
the running window shows the new bytes, without the application restarting
and without the privileged origin, the CSP or the asset path moving an
inch** — for React and for Pas2JS alike, on four targets.

- **CAP-10C0** built the one child-process supervision engine and exposed
  `pweb run`.
- **CAP-10C1** built the private ten-stage lifecycle pipeline over it.
- **CAP-10C2** made the pipeline public through `pweb dev` and shipped the
  React development loop, rebuild-and-reload behind `pweb://app`.
- **CAP-10C3** shipped the Pas2JS development loop over the same mechanism,
  with the CLI-owned change detection Pas2JS needs, and closed the phase.

`pweb --help` advertises `create doctor run dev`. **`build` is still an
unknown command** and exits 2; CAP-10D owns it.

---

## 1. The four hosted green runs

Each row is the shard's closure HEAD and the hosted run that was green on it.

| shard | closure HEAD | hosted run | what it proved |
|---|---|---|---|
| CAP-10C0 | `28349ef4bd8e42629512f33e606ebef29aa0a09f` | 33625058683 | six jobs green on the first attempt; one `supervision_digest` `120f6769…6db11c0`, 58 decisions, equal on four targets; `Add(20,22)=42` through the real `pweb run` on both built projects |
| CAP-10C1 | `94694bcaf17ba6fdcab29875f66e3b9a1d6cad42` | 33685847062 | the closure commit's own green aggregation; one `pipeline_digest` `f890424a…978e839a`, 46 decisions, equal on four targets; both `app.pwb` byte-identical to the CAP-10B1/B2 harnesses' |
| CAP-10C2 | `36ef6881c818ad3aae3dfb000ba434cbc05c661e` | 33751306417 | the closure commit's own green aggregation; one `dev_digest` `09cc2b1c…ce0b7df6`, 71 decisions, equal on four targets; `dev2_host_pid_unchanged` true and `pipeline_digest` re-measured unchanged |
| CAP-10C3 | `99bee05b8247c0ef7f99121d709f21f42c50c12c` | 33794370400 | all six jobs green, `cap7 aggregate` PASS on four targets; one `dev_pas2js_digest` `410415c2…ba28fad2`, 37 decisions, equal on windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64; six generations published and six acknowledged on every target; `dev_digest` and `pipeline_digest` re-measured **unchanged** at their CAP-10C2 and CAP-10C1 closure values |

Each row cites the run that was green on the tree it closes; the commit that
carries this artifact is re-run behind it, exactly as CAP-10C1's and
CAP-10C2's closures were.

---

## 2. Every supersession, recorded rather than claimed unchanged

A shard that moves a frozen value records the move. A shard that does not
move one **re-measures** it and records that it did not. Both are here.

| what | before | after | shard, and why |
|---|---|---|---|
| `cli_digest` | `97c7b846…6cebbe6` | `1341221d…7dfdd208` | CAP-10C0 — the parser corpus records `args\|run\|ok` where it recorded `args\|run\|unknown_command`; the ratified public surface moved, not the parser |
| `cli_digest` | `1341221d…7dfdd208` | moved | CAP-10C2 — the same reason for `dev`: `args\|dev\|ok` plus seven option rows |
| `cli_digest` | | **unchanged** | CAP-10C3 — `dev` was already a command and no option row moved; the help TEXT changed and is not digested anywhere (only `create --help` is) |
| the React template inventory | `ef5c09d0…`/15/66355 | `ef9a9312…`/16/71416 | CAP-10C2 — the `pweb-dev-sentinel` plugin and `pweb-build.d.ts` |
| the Pas2JS template inventory | | moved | CAP-10C2 — the `PWEB_DEV` region, which belongs in **both** templates or the host branches on frontend kind |
| the Pas2JS template inventory | | **unchanged** | CAP-10C3 — the loop needed no template change; the `PWEB_DEV` region CAP-10C2 added is the whole of what a Pas2JS dev build requires |
| `pipeline_units_linked` | `false` | `true` | CAP-10C2 — **inverted, not deleted**: "private" was a measurement over the compiled unit set, so "public" is the same measurement with the other verdict. Its negative self-test leg was inverted with it |
| `advertised_commands` | `create,doctor,run` | `create,doctor,run,dev` | CAP-10C2 |
| `dev_build_unknown` | `dev,build` | `build_only` | CAP-10C2 — the row that says which of the two moved, rather than dropping the measurement that one of them must stay unknown |
| the CAP-7F divergence allowlist | 2 | 4 | CAP-10C2 — `tools/pweb/pweb.pas` gains one UNIX region, because FPC's Unix threading is armed by linking `cthreads` and `dev` supervises two children on two threads |
| the WebKitGTK and Cocoa adapters | no `Cache-Control` | `no-store` | CAP-10C2, **human-ratified**. MEASURED on WebKitGTK: without the header the handler is asked for `assets/app.js` exactly once and every later re-navigation re-runs the page against the previous bundle. **No digest anywhere covers those adapter sources**, so nothing was claimed unchanged: `git show --stat cef3691` lists two adapters, the C2 gates and the dev loop, and no expectation file. `check_cap10c2_contracts.ps1` §9 now pins all three adapters in source |
| `pipeline_digest` | | **unchanged**, re-measured | CAP-10C2 and CAP-10C3 |
| `supervision_digest`, `doctor_schema_digest`, every `c1_app_pwb_*` | | **unchanged**, re-measured | CAP-10C1, C2 and C3 |
| `dev11_exit`, `dev11_cause`, `dev11_nothing_written` | `3`, `dev_ui_unsupported`, `true` | `dev11_pas2js_supported` = `true` | CAP-10C3 — **inverted, not deleted**, exactly as `pipeline_units_linked` was. CAP-10C2 measured that `pweb dev` refused a pas2js project; CAP-10C3 implements that loop, so the claim is false and the leg now measures that both kinds are advertised. MEASURED the hard way: the un-inverted leg ran `pweb dev` on the project and **hung for eighteen minutes with a live host**, because what used to refuse in milliseconds now starts a development session. The refusal PATH survives for a future frontend kind, pinned in source by `check_cap10c3_contracts.ps1` and exercised as a rule by the CAP-10C3 suite with an unratified UI ordinal |
| `dev_digest` (React) | | **unchanged**, re-measured | CAP-10C3 — the React decisions are the React decisions; the Pas2JS loop adds `dev_pas2js_digest` beside them rather than moving them |

Nothing else moved. The seven frozen interfaces, `TInvocationContext`,
`ICapabilityPolicy`, the scheduler, the mORMot bridge, the nine-code
taxonomy, protocol v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json`
schema 1, the CAP-10A parser grammar, doctor and exit taxonomy, the CAP-10B0
engine, the CAP-10C0 engine, `pweb run`, its exit mapping and its layout, the
CAP-10C1 ten stages and mutation set, the CAP-8A policy core, the CAP-8B
classifier and CSP, the CAP-9 runtime, the CAP-13 profiles and every
dependency pin: unchanged across all four shards.

---

## 3. The ledger, disposed of

Every CAP-10C0, CAP-10C1 and CAP-10C2 entry in `deferred-work.md` carries
exactly one disposition below. `test/cap10c3/check_cap10c_ledger.ps1` refuses
an orphan, a stray, a count drift and a silently reworded entry, so this
table is a measurement rather than a review somebody says happened.

The key is `<shard>-<ordinal>` and the digest is the first eight hex of the
SHA-256 of that entry's own `summary` line. `RESOLVED` means the thing the
entry describes is done. `RECORDED-ONLY` means it was never work — a measured
platform limitation, a ratification, or a lesson worth keeping. The rest name
the shard that inherits it.

### CAP-10C0 — 13 entries

| key | digest | disposition | reason |
|---|---|---|---|
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
| C0-12 | b084a444 | CAP-10D | (a) the Windows MAX_PATH form for `lpApplicationName` and a prefix-free `lpCurrentDirectory` and (b) the pwsh `Start-Process -ArgumentList` quoting hazard both belong to a shard that owns the release path and every gate at once, which is CAP-10D. (c) was RESOLVED by C1-5's membership sampler, (d)–(f) are recorded observations the contract already documents |
| C0-13 | 362abf97 | RESOLVED | CAP-10C1 added `Flush(Output)` at the three call sites (C1-1), so a supervised host's first sign of life reaches its supervisor |

### CAP-10C1 — 16 entries

| key | digest | disposition | reason |
|---|---|---|---|
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
| C1-11 | 560f8db5 | CAP-10D | six review findings, none of them a defect: (a) the toolset's shadowed branches deserve collapsing when a caller needs resolution without a full requirement graph — CAP-10D's `build` is that caller; (b) the layout's `plrCommit` rollback, (c) the manifest re-emitter's escape forms, (d) two names spelled in two units, (e) two production refusals no test seeds and (f) per-call-site `Flush` are all release-path concerns a public `build` re-opens |
| C1-12 | 826b8a81 | RESOLVED | the SDK's lib directory carries every name the target's dist provides, and the layout still ships only the one a release needs |
| C1-13 | 42bb2042 | RESOLVED | the gate forwards both streams |
| C1-14 | c0df29e1 | RESOLVED | `/noenter` is passed on Windows only, and the corpus must carry at least one decision whatever the platform |
| C1-15 | a1d3bbf7 | RESOLVED | the pipeline adopts the doctor's BUILD-time rows and not its run-time ones |
| C1-16 | 0cc8ebbc | RESOLVED | the decision corpus records the RULE and never the host that ran it |

### CAP-10C2 — 25 entries

| key | digest | disposition | reason |
|---|---|---|---|
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

**Census: 54 entries — 44 RESOLVED, 7 RECORDED-ONLY, 2 CAP-10D, 1 CAP-11, 0
orphans.** The census is emitted by the gate into
`build/cap10c3/ledger.json` rather than counted by hand here, so a row that
changed disposition changes the number a reader sees.

The four items the closure brief named individually: the Windows **MAX_PATH**
form and the pwsh **`Start-Process` quoting hazard** are C0-12 → CAP-10D; the
**native-source rebuild loop** is not a ledger entry but a documented
property — a native change requires restarting `pweb dev`, stated in
`docs/dev-contract.md` §5b for Pas2JS and §6 for React, and CAP-10D inherits
it unchanged; the **HMR shard option** is C2-5 → RECORDED-ONLY, with the
model-A spike as the data it would start from.

---

## 4. The CAP-10D handoff

### What CAP-10D inherits verbatim, and may not renegotiate

- **The CAP-10C1 ten stages and their bounds** (`open`, `toolchain`,
  `stage_sdk`, `install`, `typecheck`, `build`, `pack`, `compile`, `layout`,
  `verify`), the Pas2JS assembly rule, and the one-caller property:
  `pweb.cli.pipeline` is the only unit that runs a child.
- **The CAP-10C0 run layout** (`<output>/<os>-<arch>/release/`), its
  resolver, and the fact that `pweb run` resolves `release` and nothing else.
- **The release layout per platform**, including the macOS bundle shape and
  the `Info.plist` rule that every value comes from the descriptor and none
  of them can carry an XML metacharacter.
- **The ratified project-mutation set** — four writable prefixes, everything
  else digested before and after every stage.
- **The exit mapping**, 0/2/3/4/5/6, in all three commands.
- **The supervision engine and its one ladder**: exact path, argument vector,
  explicit working directory, no shell, graceful-then-forced, drained by
  membership.
- **The whole of `docs/dev-contract.md`**: the dev/release separation, the
  generation rule, publish-by-rename, the poller, the acknowledgement, and
  the change detectors.

### What CAP-10D must decide

- **The public `build` grammar.** `build` is an unknown command today and
  exits 2. Which options it takes, whether it resumes, and what it prints are
  CAP-10D's to ratify — the pipeline underneath it is not.
- **The CAP-13 profiles** — normal, offline and fixed — and how a build
  selects one.
- **The Linux release**: what a distributable Linux artifact is, beyond the
  directory the pipeline already commits.
- **The macOS bundle identity and signing posture**: what is signed, by whom,
  and what an unsigned build promises.
- **SDK distribution packaging**: how `pweb` plus `share/pweb` — the anchor,
  the bundler, the template pack, the two frontend SDKs, mORMot and the
  platform artifacts — are packaged, installed and located on a machine that
  did not build them.
- **C0-12 and C1-11**, the two ledger items assigned here: the Windows
  MAX_PATH argument form, the pwsh quoting hazard, and the six release-path
  observations a public `build` re-opens.

### What CAP-10D must not touch

The dev loop, the dev host, the change detector, the production seam,
`PWEB_NATIVE_CSP`, the privileged origin, `pweb.json` schema 1, the seven
frozen interfaces, the scheduler, the bridge, protocol v1, the platform
adapters, `app.pwb`, `plugins.zip`, or any dependency pin.

---

## 5. Cross-links

| document | what it freezes |
|---|---|
| [docs/kernel.md](../../docs/kernel.md) | the project kernel: the contract, the landmines, the frozen boundaries |
| [docs/cli-contract.md](../../docs/cli-contract.md) | the public CLI surface, `pweb.json` schema 1, the doctor report, the exit codes, and §5 the development-trust decision |
| [docs/supervision-contract.md](../../docs/supervision-contract.md) | the one child-process engine (CAP-10C0) |
| [docs/pipeline-contract.md](../../docs/pipeline-contract.md) | the ten-stage lifecycle pipeline (CAP-10C1) |
| [docs/dev-contract.md](../../docs/dev-contract.md) | the development loop for both frontends (CAP-10C2, CAP-10C3) |
| [docs/template-contract.md](../../docs/template-contract.md) | the scaffold engine and the trusted template pack (CAP-10B0) |
| [cap10c0-final-artifact.md](cap10c0-final-artifact.md) · [cap10c1-final-artifact.md](cap10c1-final-artifact.md) · [cap10c2-final-artifact.md](cap10c2-final-artifact.md) · [cap10c3-final-artifact.md](cap10c3-final-artifact.md) | the four shard closures |
| [cap10c2-model-a-spike.md](cap10c2-model-a-spike.md) | the measured refusal of Vite's dev server behind `pweb://app` |

**CAP-10C CLOSED.**
