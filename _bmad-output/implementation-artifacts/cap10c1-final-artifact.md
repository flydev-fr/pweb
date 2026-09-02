# CAP-10C1 — Final Artifact: the private lifecycle pipeline, in Pascal, through the C0 engine

CAP-10C1 closes on hosted run **33679593696** (2026-09-02, commit
`10868967f66f0adaa814fd0de9146b56942d7dfe`, branch
`phase/cap-10/c1-lifecycle-pipeline`, baseline `2d5f74d`): all six jobs green,
and re-run green on the closure commit itself (**33682939676**, `0dac9ba`),
`cap7 aggregate` PASS with field-by-field agreement on four targets, ONE
`pipeline_digest`
`f890424a5ef95646b9a48355819e32f49e608c7f5ecc4e69766b4182978e839a` — 46
decisions — equal on windows-x86_64, linux-x86_64, macos-x86_64 and
macos-arm64, and **the pipeline's `app.pwb` byte-identical to the one the
CAP-10B1 and CAP-10B2 harnesses produced on the same job, on every target**,
with `pweb run` launching what it assembled and receiving 42 from both.

`pweb --help` still advertises `create doctor run`. `dev` and `build` are
still unknown commands, and the pipeline units are measured absent from the
shipped executable's compiled unit set.

## The claim this shard exists to make

**A generated project reaches the CAP-10C0 run layout by Pascal code, and it
gets there the same way the harness did.** Everything
`test/cap10b1/prove_cap10b1.{ps1,sh}` and `test/cap10b2/prove_cap10b2.{ps1,sh}`
do — four scripts, two languages, driven by a shell, reaching into this
repository's `deps/` and `build/` — is now eight private units under
`tools/pweb/`, every child spawned by the one CAP-10C0 engine with an exact
path, an argument vector and an explicit working directory. Parity is not an
aspiration in this shard; it is the acceptance, and it is measured
byte-for-byte against the harness on the same runner.

| field | value | scope |
|---|---|---|
| `pipeline_digest` | `f890424a…978e839a` | four targets, 46 decisions |
| `c1_app_pwb_react_parity` / `_pas2js_parity` | `true` / `true` | absolute pins — vs the B1/B2 harness, same job |
| `c1_app_pwb_react_semantic_digest` | `3f2bdfcc…c67ddaac7` | four-target equality |
| `c1_app_pwb_pas2js_semantic_digest` | `0b95cb37…d7fc7f28` | four-target equality |
| `sdk_stage_parity` | `true` | absolute pin — byte-identical to `stage-ts-sdk.mjs` |
| `run_rpc_value_react` / `_pas2js` | 42 / 42 | absolute pins |
| `listener_members_max` / `run_connections_max` | 0 / 0 | absolute pins, membership-scoped |
| `npm_invocation` / `lifecycle_script_policy` | `node_npm_cli` / `ignore_scripts` | absolute pins |
| `network_stages` / `network_stages_pas2js` | `npm_ci` / `none` | absolute pins |
| `build_deterministic` | `true` | absolute pin, two real runs |
| `partial_layout_on_failure` | `false` | absolute pin |
| `project_tree_unchanged` / `sdk_root_unchanged` | `true` / `true` | absolute pins, measured by the gate |
| `flush_live_lines` | `true` | absolute pin — the closed POSIX debt |
| `pipeline_units_linked` | `false` | absolute pin, measured at the link |
| `advertised_commands` | `create,doctor,run` | absolute pin, **unchanged** |
| `cli_digest` / `doctor_schema_digest` / `supervision_digest` | **unchanged**, re-measured against their closure values |

## What shipped

```
  tools/pweb/pweb.cli.sdkroot.pas    what an installed SDK holds, and where
  tools/pweb/pweb.cli.toolset.pas    node / npm-cli.js / fpc / pas2js, once
  tools/pweb/pweb.cli.stage.pas      the file operations, the tree digest,
                                     and the stage-ts-sdk rule in Pascal
  tools/pweb/pweb.cli.frontend.pas   npm ci / tsc / vite; pas2js + assembly
  tools/pweb/pweb.cli.pack.pas       the app.pwb argument contract
  tools/pweb/pweb.cli.native.pas     the fpc argv, per target, PURE
  tools/pweb/pweb.cli.layout.pas     the release, committed by rename
  tools/pweb/pweb.cli.pipeline.pas   the ordered machine - the ONLY caller
                                     of the CAP-10C0 engine
  tools/pweb/pweb.cli.toolchain.pas  the pipeline bounds and library names
  src/webview/pweb.webview.host.pas  Flush(Output); the closer waits on an
                                     event rather than sleeping its bound
  tools/templates/{react,pas2js}/    Flush after the banner and the report
  docs/pipeline-contract.md          the contract
  test/cap10c1/                      pwebpipe, the suite, the gates
```

Seven units are **pure plan builders**: they produce `(exact path, argv,
working directory)` and never spawn. That is what lets the whole four-target
command matrix be asserted from any single target — a Linux runner proves the
macOS arm64 link line — and it is why not one of them carries a platform
conditional. The divergence sweep re-ratifies unchanged at 200.

## Four measurements that decided the design

**The pinned frontend tree needs no lifecycle script.** Exactly one package in
`package-lock.json` carries `hasInstallScript`: `fsevents@2.3.3`, dev and
optional and `os: darwin`, reached only by the dev watcher. So
`--ignore-scripts` costs nothing and buys the whole class, and the gate
re-counts the marker on every leg — in **both** directions, because zero would
mean the measurement the policy rests on no longer describes the tree.

**Direct invocation is byte-equivalent to the npm-script route.** Measured on
the dev host before a line was written: `node …/vite/bin/vite.js build` from a
`--ignore-scripts` install produced `dist/index.html`, `assets/app.js` and
`assets/index.css` byte-identical to `npm run build`'s, and `pwebbundle` over
that dist produced `38df29f2…cdc0` — the harness's own archive.

**A resolved path is not an argument.** This CLI canonicalizes Windows paths
into the extended-length form, and `pweb.cli.platform` strips it for the
executable, argv[0] and the working directory but not for the caller's other
arguments. `node` handed a prefixed script path dies inside `realpathSync`
with `EISDIR … lstat 'C:'`, which refused the very first end-to-end run.
Every path the pipeline puts into an argument now goes through
`PWebCliArgPath`, and the engine call site **refuses** a vector that still
carries the prefix.

**An SDK that stages only the shipped library name produces a release nobody
can link.** Linux ships `libwebview.so.0.12` and links against
`libwebview.so`; macOS has three names. The first hosted run failed the native
compile on all three POSIX targets for exactly that reason.

## The pipeline

Ten stages, ordered, resumable by design and deliberately not resuming:
`open`, `toolchain`, `stage_sdk`, `install`, `typecheck`, `build`, `pack`,
`compile`, `layout`, `verify` — the middle three skipped for a Pas2JS project,
which runs entirely offline.

**The toolchain refuses before any write.** The pipeline runs the CAP-10A
requirement graph and adopts its verdict with the doctor's own cause, rather
than re-implementing its version checks: two answers to one question is how a
build and a diagnosis start disagreeing about the same machine. One row is
excluded and the exclusion is measured, not assumed — `platform.webview` asks
whether this machine can *display* a WebView, which is what `pweb run` needs
and not what a compile needs. It is resolved and recorded
(`doctor_platform_webview`: `pass/ok` on Windows and Linux,
`fail/framework_absent` on both macOS runners) and a build proceeds.

**The mutation set is measured, not promised.** Four writable prefixes; the
tree minus them is digested before the first stage and after every stage, and
the gate takes its **own** before/after digest of the read-only half rather
than trusting the driver's row. The SDK root is digested before and after too:
a build does not write into the framework it builds against.

**The layout is committed by rename.** A failure or an interrupt leaves no
release and no staging directory. A verification failure — the one path where
the commit has already happened — reclaims the committed release, because an
absent release is `not_built`, a correct answer, and a committed one `pweb
run` refuses is not.

## The debts CAP-10C0 left, closed and measured

| debt | how it closed | measured |
|---|---|---|
| POSIX stdout block-buffered until exit | `Flush(Output)` in the host and both template starters | `flush_live_lines = true`: the ready report arrives **while the host is alive**, on every target |
| the auto-close bound delayed a requested stop | the closer waits on a `TSynEvent` the teardown sets after `webview_run` returns | with a **55 s** bound armed, a stop completed in **1342 / 1701 / 2749 ms** on linux / macos-x64 / macos-arm64 — where the old closer would have burned the 5 s grace and force-terminated |
| the sampler measured the application pid alone | `listener_members.ps1`, dot-sourced by the C1 **and** C0 gates | `listener_members_max = 0` over 7 / 3 / 1 / 1 members seen; `run_listener_members_max` added **beside** C0's pinned row, which keeps its provenance |
| npm through node | the pipeline resolves the entry point by the ratified rule | `npm_invocation = node_npm_cli`, with the path and version recorded per target |

## Superseded, and recorded as superseded

| field | before | CAP-10C1 |
|---|---|---|
| the React generated-project inventory | `1ca77cbb…b360f3230`, 65765 bytes | `ef5c09d0…70505917`, 66355 bytes, 15 files — the `Flush` lines |
| `generated_tree_digest`, `template_digest`, `public_semantic_digest` and the other template-byte fields | — | moved with it, equal on four targets |
| `cli_digest` | `1341221d…dfdd208` | **unchanged**, compared with its closure value by the gate |
| `doctor_schema_digest` | `2dda57ba…c8fa7aa` | **unchanged** — the npm row stays a presence row, ratified at Checkpoint 1 |
| `supervision_digest` | `120f6769…6db11c0` | **unchanged**, compared with its closure value by the gate |

`test/cap10b2/run_cap10b2_gates.ps1` carried the CAP-10B1 closure inventory as
a literal, with its own instruction that a shard changing the template moves
it in the same commit. It is moved, with a comment naming this shard and the
reason, and hosted run 33665009021 measured the new pair identically on all
four targets — which is what makes it a template change rather than a host
difference.

## The adversarial review, and what it changed

All fourteen challenges were run, and three independent reviewers went over
the diff. Twelve findings became code changes before closure. The ones worth
naming:

- **`project_tree_unchanged` could not read false.** `TreeAfter` was seeded
  from `TreeBefore` and only re-assigned on the path that had already proved
  them equal, so the row that proves a build does not touch its own sources
  was satisfied by construction. It now starts empty, and the gate measures
  the claim itself.
- **`build_deterministic` compared a file with itself.** The second run
  happened before the hashes were taken. The first run's digest is now
  captured before anything re-runs.
- **The POSIX emitter's new helpers were corrupted** — a raw `0x01` where a
  sed backreference belongs and a literal `\n` where a line continuation
  belongs — which would have emptied every CAP-10C1 field on three targets.
- **The registry-override lock failed open** on an unreadable or over-large
  tree, and restated the writable set as literals instead of deriving it from
  the descriptor.
- **A verification failure left the committed release on disk**, and stage 10
  re-read the field stage 9 had already refused on, making it unreachable.
- **`pipeline_units_linked` was a literal**, so an absolute pin guarded a
  constant; it is now the contract gate's own measurement.
- **The suite never ran on POSIX.** `/noenter` is the Windows switch; the
  POSIX runner reads it as a filename, printed its usage and exited 0 — a
  green verdict over nothing, beside `pipeline_corpus_lines: 0`. CAP-10A and
  CAP-10C0 had ratified the rule and this gate did not follow it. Both the
  invocation and a guard neither of those shards has — the corpus must carry
  at least one decision — landed together.
- **A corpus line recorded the host.** The SDK-layout case ran against
  whichever target was executing, so macOS recorded one extra decision and
  `pipeline_digest` had two values. It now runs against macos-arm64 on every
  host, which is the richest ladder.
- **A membership sampler can starve the application it samples.** Fifteen
  socket enumerations per 400 ms pass made a healthy Pas2JS run miss its own
  auto-close window and be killed as a hung run by this very gate, while two
  isolated runs of the same layout exited cleanly at 12.58 s twice.
- **A gate that echoes only the supervisor's lines throws away the
  compiler's.** One hosted run reported `compile: FAILED stage_exited 1` on
  three targets and not one word of why.

## Evidence

New four-target fields: `pipeline_corpus` and `pipeline_suite` (both
must-PASS) plus `pipeline_digest`, `pipeline_corpus_lines`,
`pipeline_available`, `npm_invocation`, `npm_cli_path`, `npm_version`,
`node_version`, `fpc_version`, `fpc_target`, `pas2js_version`,
`pas2js_normalised`, `lifecycle_script_policy`, `lockfile_install_scripts`,
`network_stages`, `network_stages_pas2js`, `sdk_stage_parity`,
`sdk_stage_stale_removed`, `c1_runtime_from_sdk_root`, the eight
`c1_app_pwb_*` fields, `build_deterministic`, `native_compile_react`,
`native_compile_pas2js`, `layout_accepted_by_run`, `run_rpc_value_react`,
`run_rpc_value_pas2js`, `listener_members_max`, `listener_members_seen`,
`listener_sampler_scope`, `run_connections_max`, `flush_live_lines`,
`interrupt_clean`, `interrupt_mechanism`, `autoclose_stop_honoured`,
`doctor_platform_webview`, the four `tc_*` rows, `typecheck_failure`,
`partial_layout_on_failure`, `sdk_root_unchanged`,
`template_supersession_recorded`, `project_tree_unchanged`, `driver_no_ansi`,
`pipeline_units_linked`, `cli_digest_unchanged`,
`doctor_schema_digest_unchanged`, `c0_supervision_digest_unchanged`, plus
CAP-10C0's three new membership rows.

Twenty-eight are absolute pins. Eleven new negative self-test legs (c44–c54)
prove each new aggregator refusal red on a fixture before the real aggregation
is trusted with it; the committed self-test reaches **136 aggregator refusals
+ 2 divergence refusals** (125 + 2 before this shard).

Per-target facts, recorded and never compared: the raw archive digests —
`38df29f2…` on Windows, `82c131d7…` on Linux, and `129d0932…` on **both**
macOS targets, which is the OS-family property CAP-10B0 measured in the ZIP
`version made by` byte, showing itself again; `pas2js_normalised` (`cr=true`
on Windows alone, which is why the normalisation exists); the tool versions;
`listener_members_seen`; `autoclose_stop_ms`; and `interrupt_clean`, measured
`true` on the three POSIX targets and honestly `not_measured` on Windows,
where a console control event needs the helper the CAP-10C0 suite owns.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler and
source lifecycle, the mORMot bridge, the nine-code taxonomy, protocol v1, the
SDK wire, `app.pwb`, `plugins.zip`, `pweb.json` schema 1, the CAP-10A parser
grammar, doctor and exit taxonomy, the CAP-10B0 engine, the CAP-10C0 engine,
`pweb run`, its exit mapping and its layout, the CAP-8A policy core, the
CAP-8B classifier and CSP, the CAP-9 runtime, the platform adapters, the
CAP-13 profiles and every dependency pin: **unchanged**. The CAP-10B1 and
CAP-10B2 template BYTES moved, by the recorded supersession above, and their
runtime semantics did not. `check_dev_trust.ps1` PASS on every leg:
`pweb://app` is the only privileged origin and the production profile carries
no `ws://`, `localhost` or `127.0.0.1` allowance. The divergence sweep
re-ratifies at 200 conditionals with no new allowlist entry.

## Known limitations / deferred

See `deferred-work.md` (CAP-10C1 entries): the template supersession; the
`\\?\` argument-form finding; the SDK-root completion that closes CAP-10B1's
`deps/` limitation; the npm doctor-row decision; the membership sampler; the
closer event; the Windows-only default-target scoping; the review-driven
fixes; the POSIX link-time library names; the vacuous-suite invocation; the
host-in-the-corpus finding; the sampler load measurement; the run-time WebView
requirement; and the deferred findings — the doctor/toolset resolution
overlap, the `plrCommit` rollback path no gate exercises, the JSON
re-emission's narrow precondition, two names spelled in two units,
`arg_longpath_form` and `pipeline_mutation` as refusals no test seeds, and the
per-call-site shape of the flush. The CAP-10C2 handoff is recorded there too.

**CAP-10C1 PASS — LIFECYCLE PIPELINE FROZEN**
