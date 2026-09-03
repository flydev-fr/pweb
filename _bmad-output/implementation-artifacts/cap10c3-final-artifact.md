# CAP-10C3 — Final Artifact: `pweb dev` for Pas2JS, and the CAP-10C closure

CAP-10C3 closes on hosted run **pending** (commit `pending`, branch
`phase/cap-10/c3-pas2js-dev-loop`, baseline
`36ef6881c818ad3aae3dfb000ba434cbc05c661e`).

`pweb --help` advertises `create doctor run dev`, and `pweb dev --help`
advertises **both** frontend kinds. `build` is still an unknown command.

## The claim this shard exists to make

**A developer edits `frontend/src/app.pas` and the running window shows the
new bytes** — without the application restarting, without a WebSocket, a
listener, a proxy or a platform file-watch API anywhere, and with
generation 1's `app.pwb` **byte-identical to what the CAP-10C1 pipeline
produces from the same sources**.

| field | value | scope |
|---|---|---|
| `change_detection_model` | `cli_content_fingerprint_poll` | absolute pin, four targets |
| `dev_pas2js_digest` | four targets, one value | equality — the RULES, not four machines |
| `dev_pas2js_corpus` / `dev_pas2js_suite` | `PASS` / `PASS` | must-PASS, four targets |
| `dev_pas2js_app_pwb_parity` | `true` | absolute pin — a development generation IS the pipeline's archive |
| `pd2_host_pid_unchanged` | `true` | absolute pin — the whole claim |
| `dev_pas2js_rpc_value` / `dev_pas2js_rpc_after_switch` | `42` / `47` | absolute pins — the template's arithmetic, then the LAST edit's |
| `dev_pas2js_csp_identical` | `true` | absolute pin — dev host CSP == release host CSP, for a Pas2JS project |
| `dev_pas2js_release_dev_free` | `true` | absolute pin — a directory listing and a byte scan |
| `dev_pas2js_partial_generation_published` | `false` | absolute pin, composed from five measurements |
| `dev_pas2js_inconsistent_generation_discarded` | `true` | absolute pin — the consistency rule, driven |
| `dev_pas2js_error_keeps_previous_generation` | `true` | absolute pin |
| `dev_pas2js_network_calls` / `_network_stages` | `0` / `none` | absolute pins — no stage can reach the network |
| `dev_pas2js_listener_members_max` | `0` | absolute pin, membership-scoped |
| `dev_pas2js_loose_assets_used` | `false` | absolute pin |
| `dev_pas2js_watch_api_hits` | `0` | absolute pin — polling was ratified, and the sweep keeps it ratified |
| `pd9_cause` / `pd10_cause` | `dev_input_link` / `dev_input_bound` | absolute pins, exit 3, nothing written |
| `pd11_pweb_exit` / `pd12_pweb_exit` | `0` / `5` | absolute pins, descendants 0 |
| `advertised_ui_dev` | `pas2js,react` | absolute pin |
| `build_still_unknown_c3` | `true` | absolute pin |
| `cap10c_ledger_orphans` / `cap10c_closure_recorded` | `0` / `true` | absolute pins |
| `rd1_dev_digest_unchanged` / `c3_pipeline_digest_unchanged` | `true` / `true` | absolute pins — React and the pipeline did not move |

## The first decision, and the data that made it

Pas2JS has no watch mode and no `writeBundle`, so the CLI owns detection.
Two decisions were ratified at the checkpoint rather than assumed:

**Polling, not a native watcher.** `ReadDirectoryChangesW`, `inotify` and
`FSEvents`/`kqueue` would be three bodies in `pweb.cli.platform`, three
semantics and three ways for one loop to behave differently on four targets
— for an input set of five files. The contract gate sweeps `src/` and
`tools/` for those identifiers as code, so the decision cannot be quietly
reopened.

**A content fingerprint, not `(path, size, mtime)`.** The cheap fingerprint
was the recommended one and is the wrong one: FPC's portable timestamp layer
is **second-granular**, so two edits inside one second that leave the length
alone are one fingerprint and the change is never seen — the adversarial
question "can the detector miss a change" answered by "it can". Hashing the
bytes is immune to that *and* to a same-size edit, and buys a property worth
having on its own: a `touch` or a `git checkout` that alters no byte costs no
generation. Both halves are asserted by the headless suite rather than argued
for.

## What shipped

```
  tools/pweb/pweb.cli.devinputs.pas  NEW - the input set, the bounded
                                     content-fingerprint walk, the typed
                                     refusals; no spawn, no env read, no
                                     platform conditional
  tools/pweb/pweb.cli.dev.pas        the pas2js branch: the supported-UI
                                     predicate, the skipped node stages, no
                                     watcher child, the detector loop and
                                     the generation builder
  tools/pweb/pweb.cli.toolchain.pas  five bounds
  tools/pweb/pweb.cli.report.pas     both UIs advertised
  docs/dev-contract.md               section 5b, the stage table's second
                                     column, the one-member set, the bounds,
                                     and section 12 rewritten as the CAP-10D
                                     handoff
  docs/cli-contract.md               sections 1 and 5, final wording
  docs/index.md                      every contract document cross-linked
  test/cap10c3/                      the suite, the driver, the gates, the
                                     contract cross-checks and the ledger
                                     disposition gate
  cap10c-closure-artifact.md         the CAP-10C phase closure
```

**Nothing else moved.** The dev host, the production seam, `devlayout`, the
C1 pipeline and its stages, `pweb.cli.frontend`, both templates, schema 1,
the seven interfaces, the adapters and every pin are unchanged — and each is
re-measured rather than assumed.

## One defect the first hosted run found, and two the local runs did

**The gate never put the pinned `pas2js` on `PATH`, and the local harness
hid it.** Hosted run 33787727548 failed the Linux leg with fifteen PD rows
false at once; the driver's own forwarded lines said why in three:
`pweb: toolchain: FAILED tool_not_found frontend.pas2js`. The loop resolves
tools on PATH by ratified design and every CI job fetches the pinned compiler
into `deps/` *without* putting it there — which is why `test/cap10b2` and
`test/cap10c1` each carry an explicit block that prepends it. The CAP-10C3
gate had none. It passed locally on every run because the **local invocation**
set PATH in its wrapper: a harness more generous than the one under test,
which is the CAP-10C2 stale-binary lesson wearing different clothes. The fix
is the sibling gates' own block, a refusal at the top when no `pas2js` can be
found at all, and a `pas2js_on_path` row pinned true on four targets with its
own negative self-test leg — so the next occurrence says one thing instead of
fifteen. The gate was then re-run locally with **no PATH help at all**, which
is the only run that proves the block works.



**A source that does not compile was rebuilt forever.** The first working
loop answered a broken `const` by recompiling the whole frontend every few
seconds for as long as it stayed broken. React has no equivalent, because
Vite's `writeBundle` does not fire on a failed build and a broken source
produces no new sentinel at all; a fingerprint, by contrast, stays changed.
A failed attempt now records the input state it answered — `before`, the
fingerprint taken *ahead* of the compile, never a fresh one taken after it,
so a fix that landed *during* the failed build still looks like a change on
the next pass. Measured both ways: three failure lines in fifteen seconds
before, exactly one after.

**A test aliased a const argument with its own out parameter.** The
depth-bound leg built its directories with `PWebCliPipeEnsureDir(deep, name,
deep, stage)`; `out` clears the variable on entry, so the tree stayed one
level deep and the bound was never reached — the leg reported "not refused"
and was right to. It is the same aliasing `pweb.cli.devlayout` documents at
`PWebCliDevResetGenerations`, met a second time in a test.

## Evidence

New four-target fields: `dev_pas2js_corpus` and `dev_pas2js_suite` (both
must-PASS) plus `dev_pas2js_digest`, `dev_pas2js_corpus_lines`,
`dev_pas2js_available`, `change_detection_model`, `advertised_ui_dev`,
`dev_pas2js_option_matrix`, `build_still_unknown_c3`,
`advertised_commands_c3`, `dev_pas2js_csp_identical`,
`dev_pas2js_release_dev_free`, `dev_pas2js_transport_hits`,
`dev_pas2js_watch_api_hits`, `dev_region_in_pas2js_template`, the
`cap10c_ledger_*` and `cap10c_closure_recorded` rows, the `pd1`–`pd15` rows,
the `dev_pas2js_*` observation and pin rows, and `rd1_dev_digest_unchanged` /
`rd1_dev_suite` / `c3_pipeline_digest_unchanged`.

Nineteen new negative self-test legs (C3-1 … C3-19) prove each new
aggregator refusal red on a fixture before the real aggregation is trusted
with it. The committed self-test floor is raised from 84 to **179**, which
is the count that actually fires — the old floor had been left at 84 while
the real number reached 160, so a leg could have stopped running for two
shards without anybody noticing.

**The aggregate and its self-test were run locally**, on a four-target
fixture built from the CAP-10C2 hosted evidence with this shard's rows merged
in: the real aggregator PASSes and all 179 refusals fire. That is the
CAP-10C2 ledger's own lesson — the aggregate job is the only place the
cross-target aggregator and its negative self-test run, so a shard that
changes their inputs cannot verify them from a native job alone.

**The POSIX legs were verified locally before the first push**, which is the
CAP-10C2 ledger's own lesson acted on: the three isolation units, the
headless suite and the driver compiled under WSL with the exact flags
`build_cap10c3.sh` uses, the suite ran there, and its decision corpus
digested to `410415c2…ba28fad2` — the same value the Windows run produced.
The whole Windows gate set ran locally to PASS. WSL cannot cover macOS, and
the two Cocoa legs rely on hosted CI.

## Superseded, and recorded as superseded

| field | before | CAP-10C3 |
|---|---|---|
| `dev11_exit` / `dev11_cause` / `dev11_nothing_written` | `3` / `dev_ui_unsupported` / `true` | **inverted** into one row, `dev11_pas2js_supported` = `true` |
| `cli_digest` | | **unchanged** — `dev` was already a command and no option row moved; the help TEXT changed and only `create --help` is digested anywhere |
| the Pas2JS template inventory | | **unchanged** — CAP-10C2 put the `PWEB_DEV` region in both templates, so the loop needed no template change |
| `dev_digest`, `pipeline_digest`, `supervision_digest`, `doctor_schema_digest`, every `c1_app_pwb_*` | | **unchanged**, re-measured |

**The one inversion, and how it was found.** CAP-10C2's DEV11 leg ran `pweb
dev` on a pas2js project and required exit 3 with `dev_ui_unsupported`. This
shard makes that false, and the leg does not merely go red — it **hangs**,
because what used to refuse in milliseconds now starts a real development
session with a live host. It was found by running the CAP-10C2 regression
locally before the first push, where it sat for eighteen minutes; on a hosted
runner it would have burned a job's whole timeout for a one-line diagnosis.
The row is inverted rather than deleted, the negative self-test leg is
inverted with it, and the refusal path it used to measure is now pinned in
source and exercised as a rule by the CAP-10C3 suite.

The consolidated table across all four shards is
[cap10c-closure-artifact.md](cap10c-closure-artifact.md) §2.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler,
the mORMot bridge, the nine-code taxonomy, protocol v1, the SDK wire,
`app.pwb`, `plugins.zip`, `pweb.json` schema 1, the CAP-10A parser grammar,
doctor and exit taxonomy, the CAP-10B0 engine, the B1/B2 templates, the
CAP-10C0 engine, `pweb run`, its exit mapping and its layout, the CAP-10C1
ten stages, bounds, mutation set and Pas2JS assembly, the CAP-10C2 dev host,
seam, generation rule, poller, acknowledgement and ladder, the CAP-8A policy
core, the CAP-8B classifier and CSP, the CAP-9 runtime, the CAP-13 profiles,
the three platform adapters and every dependency pin: **unchanged**.
`check_dev_trust.ps1` PASS on every leg, now pinning the final §5 wording and
the `PWEB_DEV` region in **both** templates.

## Known limitations / deferred

See `deferred-work.md` (CAP-10C3 entries): the detection ratification and its
data; the broken-source rebuild loop and its fix; the input-set walk's own
bounds; the one-member supervised set; the archive-parity measurement; the
const/out aliasing found by its own test; the scope of the no-absolute-path
claim; the verification lesson acted on; the absence of any supersession; and
the CAP-10D handoff.

**CAP-10C3 PASS — PAS2JS DEVELOPMENT LOOP FROZEN, CAP-10C CLOSED**
