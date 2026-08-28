# CAP-10B2 — Final Artifact: the public Pas2JS scaffold, and the close of CAP-10B

CAP-10B2 closes on hosted run **33168355248** (2026-08-28, commit
`64e0cd8`, branch `phase/cap-10/b2-pas2js-scaffold`, baseline `9503b53`):
all six jobs green on the **first attempt**, no step re-run, `cap7 aggregate`
recording `pas2js_create_corpus: PASS`
and `pas2js_proof_corpus: PASS` on every target, ONE
`pas2js_generated_inventory_digest`
`d34b50871f6c66076dd89f708bdac741e03f0947c931939e09e0ec265f99e280` — 11
files, 25953 bytes — equal on windows-x86_64, linux-x86_64, macos-x86_64 and
macos-arm64, and `CalculatorService.Add(20, 22) = 42` from a real system
WebView on all four, driven by JavaScript that Pas2JS 3.0.1 compiled from
Object Pascal.

`pweb create NAME --ui react|pas2js --bundle-id <reverse.dns>` is the whole
command surface. `dev`, `run` and `build` are still unknown commands.

**Why the closure run is not the first green one.** Run **33160209188**
(commit `13d9e68`) was the first in which every CAP-10B2 gate passed on all
four targets, and every digest quoted here is identical on both runs; it
remains valid B2 evidence, cited as such below. It is not the branch's
closure run, because the commit that first *recorded* this closure
(`5dc1754`, Markdown only) then went red on Windows **twice** at the
**CAP-6b3 uninstall gate** — `left 11 file(s) behind`, then `left 8
file(s)`, a different subset of WebView2 browser images each time, gates 1–8
passing both times. A lock race in a closed shard's CI harness, not a
CAP-10B2 defect: that step passed on three consecutive runs of this branch,
CAP-6b3 runs *before* any CAP-10 step, and that commit changed 376 lines of
Markdown and one comment line. It is now **corrected in CI teardown only**
(below); 33168355248 is the first green run on a HEAD carrying it.

Run 33160209188's `macos-x64` leg first went red at `CAP-7M2 setup pinned
Node` with `getaddrinfo ENOTFOUND nodejs.org` — a runner DNS failure before
any PWeb code ran — and was re-run green on the identical commit; the
closure run needed no re-run on any leg. Two earlier runs, **33155622286**
and **33158296971**, each failed for a defect in this shard's own evidence
plumbing and are described below rather than elided.

## The claim this shard exists to make

**One application, two frontends, one backend contract.** For the same NAME
and bundle identifier the two generated projects share:

| field | value | scope |
|---|---|---|
| `shared_native_source_digest` | `1a76ae3e63dbabf825053122b88e2c08f07e20028bf9735a1ccb945744020c11` | both UIs, four targets |
| `react_generated_inventory_digest` | `1ca77cbb8dc0fed5844fa6aa958ca2727ea560f5bda0b50b23e1bd9b360f3230` | **the CAP-10B1 closure value, unchanged** |
| `pas2js_generated_inventory_digest` | `d34b50871f6c66076dd89f708bdac741e03f0947c931939e09e0ec265f99e280` | four targets |
| `pas2js_pweb_json_digest` | `0d365076be1592ac07fa85f2efea63928fc70ab56b5549a2cd7ea9873cbd7c2f` | four targets |
| `pas2js_frontend_source_digest` | `cff1444479e1aa1165ac953b21d6fbbb31d1bb87ab220f1bd3a0409b23838b69` | four targets |
| `pas2js_static_inventory_digest` | `51ea35c77ee7b556dc30ee19fae74a2f119d8c48296053399bae483b8d9040e1` | four targets |
| `pas2js_app_pwb_semantic_digest` | `0b95cb3782ed7dc28dc50e710063d3e8d90f9d5b985b844ecd96e7b2d7fc7f28` | four targets, 5 entries |
| `supported_uis` | `pas2js,react` | absolute pin |

`src/app.services.pas` and `.gitattributes` are **byte-identical** between
the two templates; `src/demo.lpr` is byte-identical once comments are
removed, and its four differing raw lines are proven to carry no code. The
native executables came out byte-identical on every target — recorded as a
measurement, not required.

## What shipped

```
  tools/templates/pas2js/         the trusted public template, 10 files
  tools/pweb/pweb.cli.args.pas    PWEB_CLI_UI_PAS2JS and a two-value allowlist
  tools/pweb/pweb.cli.report.pas  the help, interpolating both constants
  tools/pweb/pweb.pas             one exit mapping moved
  test/cap10b2/                   the pas2js gates, the parity checks and the
                                  private build proof
```

The production delta against the CAP-10B1 closure is **three CLI units, one
template list and ten new template files**. `git diff --name-status 9503b53`
reports nothing at all under `src/`, `sdk/`, `examples/` or `deps/`, and
nothing under `tools/pweb/` except the parser, the report and the program.
The frozen engine — `pweb.cli.template`, `pweb.cli.scaffold`,
`pweb.cli.write`, `pweb.cli.project`, `pweb.cli.doctor`, `pwebtemplates` —
is untouched, and `cli_digest` `97c7b846…d6cebbe6` and
`doctor_schema_digest` `2dda57ba…c8fa7aa` are re-measured **unchanged**.

## The first audit answered itself

`ui = "pas2js"` was **already ratified in schema 1**:
`pweb.cli.project.pas:93` declares `TPWebCliUi = (puiReact, puiPas2js)` and
`:910-920` accepts both strings. So did the doctor:
`pweb.cli.doctor.pas:619-696` already reported `ui_not_react` for the four
React rows and required `frontend.pas2js` at the exact pin for a Pas2JS
project, and the CAP-10A decision corpus already carried
`doctor|react-excludes-pas2js|ui_not_pas2js`,
`doctor|pas2js-excludes-node|ok` and `doctor|pas2js-exact-pin|version_mismatch`.

CAP-10B1 had restricted exactly two things: the parser's compiled allowlist
and the pack's contents. That is why this shard changes no schema, no
doctor and no engine — and why `cli_digest` did not move.

## Three measurements that changed what got built

**Pas2JS writes its output through the host's text layer.** The compiled
`assets/app.js` begins `EF BB BF` and carries CRLF on Windows and LF on
POSIX; the compiler exposes no line-ending switch. Packing those bytes
would have made the Pas2JS `app.pwb` an OS-family artifact and
`pas2js_static_inventory_digest` unsatisfiable by construction. The build
strips the BOM and every CR before packing — the same decision, for the same
reason, that already makes the CAP-5 build write `boot.js` byte-exactly with
LF. `pas2js_output_normalised` records what each host actually emitted
(`bom=1 cr=1` on Windows, `bom=1 cr=0` on POSIX) and the normalised bytes
then agree on all four.

**The raw binding is provably SDK-owned, by counting rather than by
banning.** In the frozen CAP-5 bundle and in the generated one alike,
`__pweb_invoke` occurs **exactly once** — as
`this.PWEB_NATIVE_BINDING_NAME = "__pweb_invoke"` inside
`rtl.module("pweb.native", …)` — and neither platform channel occurs at all.
So the rule is occurrence classification: zero in the generated project's
sources, exactly one in the bundle, that one inside the SDK's module body
(bounded above by the next module, not merely below by the previous one).

**`ptcTemplateUnknown` moved from exit 2 to exit 4.** With a compiled
two-value allowlist checked before any lookup, a typed frontend kind can no
longer reach a template lookup, so reaching it means the installation's pack
does not describe an advertised template — the class of `sdk_share_missing`,
not of a typo. It is proven rather than argued: `test/cap10b2/build_cap10b2`
builds a react-only pack from a filtered trusted source and a **second
`pweb`** compiled against it, and the gate requires
`create demo --ui pas2js` to answer 4 with `template_unknown` while the same
executable still creates a React project.

## Superseded, and recorded as superseded

| field | CAP-10B1 | CAP-10B2 |
|---|---|---|
| `template_digest` | `01f16572…2ce26362` | `66b6bc6c30c54d72da3bba10ddf46358da187d8568b477ce9dc5e2bb8485abea` |
| `template_semantic_digest` | `8ed72f24…dea0a8f6` | `0bd4e6544d7587281b6daa18a7d57179c5ab2532a23a66c78123d4c8aabf2373` |
| `template_file_count` | 22 | 32 |
| `public_file_count` | 14 | 24 |
| `public_semantic_digest` | (B1 value) | `45d62a3634df79dd1670c739c850ff93521173882e26202d004936fcf722fd8c` |
| `public_pack_digest` (win+linux) | `30ac777e…aa302417`, 67635 B | `1a002fb96a11946db3287417e4b9c865cc6acc7e387e8e362ddef32f79f2696f`, 94864 B |
| `public_pack_digest` (macos) | `31ce1e67…90975e43`, 67635 B | `06a7629d7118c13d81d2160ef58341f19ee4621838de0ed6837d8d488a5cfd2d`, 94864 B |
| `advertised_ui` = `react` | — | **renamed** `supported_uis` = `pas2js,react` |
| `cli_digest`, `doctor_schema_digest` | — | **unchanged** |

The CAP-9C1 split is preserved and reproduced: the pack's **bytes** are an
OS-family property (same length everywhere, one byte per entry apart between
families — mORMot's `ZIP_OS`), the **semantic inventory** is compared across
all four, and determinism is proved where it is real by rebuilding on each
target.

`advertised_ui` was renamed rather than kept because one frontend was a
value and two are a set, and a set needs one canonical order. That rename is
also this shard's most instructive failure: the first hosted run
(**33155622286**) passed every CAP-10B2 gate on all four targets and then
failed on three of them in `emit_evidence.sh`, which still read the old
name. The empty-value guard the CAP-10B1 emitter already carried is what
caught it — a guard written for a different reason, catching this one.

## What the generated Pas2JS project is

Eleven files; ten templated, `pweb.json` from the serializer.

```
demo/
  pweb.json  .gitattributes  .gitignore  README.md
  src/       demo.lpr  app.services.pas
  frontend/  index.html  app.css  pas2js.cfg
             src/  demoapp.lpr  app.pas
```

No `package.json`, no lockfile, no `node_modules`, no bundler config and
**no JavaScript or TypeScript at all** — the browser code is produced from
the Pascal beside it. `frontend/pas2js.cfg` carries the four portable
CAP-5-proven options and **no path**: the SDK unit path and the output path
are supplied at build time and never written back. The build compiles into
an **external stage**, so `pas2js_build_out_of_tree` is a stronger claim
than the React path can make — with no package manager there is nothing to
materialise into a working tree at all.

`.gitignore` and the stylesheet's header sentence are ratified permitted
differences: React's names `node_modules/` and the TypeScript-SDK staging
directory, and its stylesheet says `--pweb-styled` "is read back by
App.tsx". Shipping either into a Pas2JS project would ship a false statement
about that project. Every CSS rule is still compared.

## The adversarial review found eight things worth the cost

All sixteen scripted challenges were run and **two produced changes**.
"Can a Pas2JS project compile only from the repository checkout?" found that
the staged-SDK claim was recorded in an invocation string and asserted
nowhere, so `pas2js_sdk_from_sdk_root` now proves that exactly one PWeb unit
path reaches the compiler and that it names the staged root. And walking the
test matrix found that no gate had ever driven the exit-3 destination arm on
a real CLI, which the `destination_exists` leg now does.

Three independent reviewers over the diff produced six more, two of them
serious:

- **`set -e` made the failure paths unreachable.** `prove_cap10b2.sh`
  captured `$?` after bare simple commands for the Pas2JS compile, the
  `app.pwb` build and the FPC compile — and under `set -euo pipefail` the
  shell had already exited. `pas2js_frontend_build=FAIL` could never be
  written. The same shape killed four `grep` substitutions, one of which was
  the "no report received" branch this shard added **specifically** so an
  intermittent timing failure would stay distinguishable from a runtime
  defect. The mitigation for the shard's own carried-in risk was dead code
  on three of four targets.
- **`pas2js_app_pwb_semantic_digest` measured the wrong thing.** It was
  assigned the pre-pack `dist/` inventory, so it could not disagree with its
  own neighbour and never opened the archive. Both proofs now project the
  archive in CAP-7F's own shape, which brings the bundler-owned
  `manifest.json` inside the measurement; `pas2js_app_pwb_entries` is pinned
  to 5 beside it.
- **The report-shape half of the parity claim was measured on one page.**
  `prove_cap10b1` never emitted a field set, so the aggregate published
  "same report shape" from a single reading against a literal. It now emits
  one and CAP-10B2 compares the two.
- **The FPC unit-path provenance was pinned by nothing** — which is exactly
  how the POSIX CAP-10B1 proof kept a repository-relative platform path for
  a whole shard while its header claimed every path was staged. Both are now
  asserted and emitted as `pas2js_native_from_sdk_root`.
- **Two vacuous measurements.** The listener sampler answered a clean 0 when
  `ss`/`lsof` was absent, satisfying an absolute pin by proving nothing; and
  the run waited unbounded, so a hung page would have burned the step
  timeout and emitted nothing.
- **The stylesheet lied in a Pas2JS project** (above).

And one more came from the machinery rather than from a reviewer. The
negative self-test refused run **33158296971** with
`CAP-10B2 BAD-BUNDLE-INVENTORY: pas2js_app_pwb_entries=0` on three targets:
the POSIX proof wrote the new counter as a quoted string while the Windows
twin wrote a number, and the emitter's numeric reader silently substituted
0. A field added that same hour caught a cross-implementation inconsistency
in a field added that same hour.

## Evidence

New four-target fields: `pas2js_create_corpus` and `pas2js_proof_corpus`
(both must-PASS) plus `supported_uis`, `pas2js_create_refusals`,
`pas2js_no_partial`, `pas2js_create_deterministic`,
`pas2js_create_stdout_digest`, `pas2js_generated_inventory_digest`,
`pas2js_generated_inventory_exact`, `pas2js_generated_file_count`,
`pas2js_generated_total_bytes`, `pas2js_pweb_json_digest`,
`pas2js_frontend_source_digest`, `pas2js_generated_no_host_path`,
`react_generated_inventory_digest`, `react_regression_result`,
`shared_native_source_digest`, `native_parity`, `pas2js_doctor_result`,
`pas2js_doctor_version`, `pas2js_compiler_version`,
`pas2js_frontend_build`, `pas2js_native_build`, `pas2js_sdk_from_sdk_root`,
`pas2js_native_from_sdk_root`, `pas2js_output_sweep`,
`pas2js_static_inventory_digest`, `pas2js_app_pwb_semantic_digest`,
`pas2js_app_pwb_entries`, `pas2js_secure_origin`, `pas2js_rpc_result`,
`pas2js_error_mapping`, `pas2js_listener_count`, `pas2js_loose_assets`,
`pas2js_app_raw_binding`, `pas2js_sdk_binding_owner`,
`pas2js_clean_shutdown`, `pas2js_report_received`, `pas2js_report_fields`,
`pas2js_tree_digest`, `pas2js_tree_unchanged`, `pas2js_build_out_of_tree`,
`react_pas2js_parity`, `react_regression_runtime`.

Nine of them are **absolute pins** rather than agreements:
`supported_uis = pas2js,react`, `pas2js_compiler_version = 3.0.1`,
`pas2js_rpc_result = 42`, `pas2js_listener_count = 0`,
`pas2js_app_raw_binding = false`, `pas2js_loose_assets = false`,
`pas2js_sdk_binding_owner = true`, `pas2js_report_received = true`,
`pas2js_clean_shutdown = true`.

Per-target observations, recorded and never compared: `pas2js_compiler_arch`
/ `_host` / `_sha256` (the pinned compiler is a different artifact per
platform by design — i386, x86_64, aarch64), `pas2js_doctor_row` (`pass/ok`
on Linux, `warning/tool_duplicated` where a second Pas2JS is on PATH),
`pas2js_app_pwb_bytes`, `native_binary_equal`, `pas2js_run_elapsed_ms`,
`pas2js_output_normalised`.

Thirteen create refusals are executed against real compiled CLIs on every
target — six rejected UI spellings (`PAS2JS`, `Pas2js`, `pas2JS`, `p2js`,
`pas`, `js`), a duplicate option, `--project` on a create line, an invalid
NAME, three broken installations and an occupied destination — each with its
own machine-stable cause **and** its exit category, with the parent asserted
empty afterwards. The destination leg is new ground: CAP-10B0 proved the
transaction in-process against a synthetic plan, and no gate had ever
watched `ExitForCreateRefusal` become a process exit code.

Twenty-three new negative self-test legs (c85–c107, with c71 redirected)
bring the committed self-test to **111 aggregator refusals + 2 divergence
refusals** (88 + 2 before this shard), so every new refusal branch is proven
red on fixtures before the real aggregation is trusted.

## No Rosetta, asserted where it can mean something

Upstream publishes no aarch64 Pas2JS, so `tools/get-pas2js.ps1` compiles the
same pinned logical version natively from the pinned FPC revision. The proof
asserts `-iSP` before it compiles anything, and the aggregate carries a
`TRANSLATED-COMPILER` refusal for the macos-arm64 leg specifically. Measured
on the real runner: `pas2js_compiler_arch = aarch64`, with a compiler
sha256 distinct from every other target's.

## The CAP-6b3 uninstall race, corrected

Fixed before the branch closed, in **CI teardown only**. Cause: gates 7
and 8 launch three copies of the installed application, each spawning a
WebView2 browser image from *inside* the bundled Fixed Runtime tree; nothing
waited for those to exit; Windows will not delete a mapped image; Inno
reports success anyway; and the 300-second poll had become the only thing
waiting — a timeout, not a synchronisation.

`test/cap6b3/wv2procdrain.ps1` now runs immediately before the uninstaller:
enumerate through `Win32_Process`, select **only** images whose
canonicalised path lies under this installation on a *component* boundary,
bounded graceful window, terminate the remainder **by PID** with the image
re-checked against a fresh record at kill time, re-enumerate until empty or
a bounded timeout — and if anything remains, **refuse to run the uninstaller
at all**, printing the surviving pid/image list, so the gate cannot degrade
into a cleanup step that always passes. Nothing global: `taskkill /IM`,
`Stop-Process -Name` and every machine-wide WebView2 or Evergreen action are
absent by rule and by test — the runner's unrelated Evergreen processes are
what CAP-6b1, CAP-6b2 and gate 8's no-fallback proof depend on.
`check_wv2procdrain.ps1` proves T1–T11 on injected records plus a live CIM
query, in the Windows job *before* the gate.

On the closure run the bundled browser still held the tree on sweep 1 and
was gone on sweep 2 (`graceful=True terminated=0`) — the window nothing used
to wait for. Nothing had to be killed. `CAP-6b3 gate 9 PASS`,
`CAP6B3_SETUP_GATES_PASS`, CAP-6b4 matrix green behind it, `git diff
13d9e68 64e0cd8 -- src/ sdk/ examples/ deps/ tools/` empty. Narrative and
lessons in `deferred-work.md`.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler
and source lifecycle, the mORMot bridge, the nine-code taxonomy, protocol
v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json` schema 1, the
CAP-10A parser grammar, doctor and exit taxonomy, the CAP-10B0 scaffold
engine, transaction, path rules and placeholder set, the CAP-10B1 React
generated project and its runtime semantics, the reusable host unit, the
CAP-8A policy core, the CAP-8B classifier and CSP, the CAP-9 runtime,
package and lifecycle, the platform adapters, the CAP-13 profiles and every
dependency pin: **unchanged**. Pas2JS 3.0.1 is used additively, exactly as
`pas2js.lock` already pinned it.

The divergence sweep re-ratifies at **176 conditionals**, every allowlist
row unchanged; `tools/templates/` is outside it by design and the new
template's Pascal is judged instead by `check_cap10b2_contracts.ps1`, which
allows it **none** beyond the ratified `{$apptype console}`.

## Known limitations / deferred

See `deferred-work.md` (CAP-10B2 entries): the `.gitignore` and stylesheet
deviations from byte-identity and why they were ratified; the BOM/CRLF
measurement and the fallback if a future toolchain breaks the equality; the
SDK root still half-staged (the Pas2JS compiler and its RTL come from
`deps/`, as mORMot and the webview library already did); the `set -e` class
fixed here and left recorded for the CAP-10B1 POSIX proof; the `*.cfg`
gitignore negation; the generated `.gitattributes` that cannot cover `*.cfg`
without re-baselining a frozen React value; `native_binary_equal` as an
observation; the absence of a harness-level fixture for the now-reachable
"no report received" branch; `contracts.json` being uploaded and consumed by
nothing; the `ci.yml` documentation budget at 197.5 KB; and the CAP-10C
handoff for the Pas2JS side of `pweb dev`. The CAP-6b3 race this closure
surfaced is ledgered **RESOLVED**, not deferred.

**CAP-10B PASS — REACT AND PAS2JS SCAFFOLDS FROZEN**
