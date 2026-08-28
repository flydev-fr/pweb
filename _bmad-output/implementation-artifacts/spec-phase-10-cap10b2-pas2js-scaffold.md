---
title: 'CAP-10B2 — the public Pas2JS scaffold and the close of CAP-10B'
type: 'feature'
created: '2026-08-28'
status: 'in-progress'
baseline_commit: '9503b53a55c9dfa0eb0b826f74010cff7beaaf65'
review_loop_iteration: 0
context:
  - '{project-root}/docs/template-contract.md'
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10b1-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `pweb create` scaffolds exactly one frontend. `pweb.json` schema 1
has ratified `ui: "pas2js"` since CAP-10A and `pweb doctor` already carries the
UI-aware `frontend.pas2js` row, but the public parser refuses `--ui pas2js` by a
compiled allowlist because no template existed. CAP-10B closes only when both
ratified frontends are producible and provably equivalent behind the wire.

**Approach:** Add ONE trusted public `pas2js` template beside the frozen `react`
one, widen the compiled allowlist and the help it interpolates, and prove — on
four targets — that the generated Pas2JS project strict-parses, passes doctor,
compiles from real Pascal with pinned Pas2JS 3.0.1 against the trusted SDK root,
packs into `app.pwb`, and reaches `CalculatorService.Add(20,22) = 42` through the
identical native host, while the React corpus stays byte-identical to its B1
closure value.

## Boundaries & Constraints

**Always:** Schema 1, the CAP-10A parser/doctor schema/exit taxonomy, the
CAP-10B0 engine, transaction, path and placeholder semantics, the seven
interfaces, CAP-7/8/9, protocol v1, `app.pwb`, `plugins.zip`, the platform
adapters and every dependency pin stay unchanged — the only additive use is the
already-existing Pas2JS 3.0.1 pin. The React generated project stays
byte-identical to the B1 closure corpus, re-measured, never asserted. Create
stays offline, tool-free, atomic and child-process-free. One scaffold engine,
one writer, one native host composition, one bundler. Every B1 rule that stops
holding is INVERTED and re-measured, never deleted. Pack/registry/help digests
are recorded as SUPERSEDED with old and new values side by side.

**Ratified at Checkpoint 1:** (1) the generated `.gitignore` is a **permitted UI
difference** — the Pas2JS copy drops the npm/TypeScript-SDK block, because those
bytes describe a dependency model a Pas2JS project does not have; the parity
gate whitelists it beside `README.md` and the artifact records the deviation
from "mechanically compare `.gitignore`". (2) `ptcTemplateUnknown` **moves from
exit 2 to exit 4**: with a two-value compiled allowlist it can no longer be
caused by a command line, so it means "this installation's pack does not
describe a template this build advertises" — the same class as
`sdk_share_missing` and `pack_size`. It is PROVEN, not reasoned about: a
react-only pack built from a filtered trusted source and a second `pweb`
compiled against it must answer exit 4 / `template_unknown` to
`create demo --ui pas2js`.

**Ask First:** any change to a React template file; any schema-1 change;
demoting a four-target equality field to a per-target observation; any new exit
category.

**Never:** implement `dev`, `run` or `build`; run Pas2JS, npm or any child
process during create; add a `--ui` alias (`p2js`, `pas`, `js`) or a
case-insensitive match; add QuickJS, plugins, package discovery or a
frontend-specific native RPC route to a generated project; vendor PWeb, mORMot,
the Pas2JS SDK unit or the compiler into a generated project; write an SDK path
back into the project; branch the native host on frontend kind; weaken the
CAP-8B CSP or navigation policy; require npm, Node, Vite or a lockfile for a
Pas2JS project.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Pas2JS create | `pweb create demo --ui pas2js --bundle-id com.example.demo` in an empty parent | exit 0, 11-file project, `ui: "pas2js"` in `pweb.json` | N/A |
| React create | same line with `--ui react` | exit 0, the B1 15-file project, byte-identical to its closure corpus | N/A |
| Unknown UI | `--ui svelte` | exit 2, `unsupported_ui: svelte`, destination absent | usage |
| Case variant | `--ui React` / `--ui PAS2JS` | exit 2, `unsupported_ui`, destination absent | usage |
| Duplicate UI | `--ui pas2js --ui pas2js` | exit 2, `duplicate_option` | usage |
| Missing UI | no `--ui` | exit 2, `missing_option: --ui` | usage |
| Broken install | pas2js create against an SDK root with no pack, a tampered pack, or a react-only pack | exit 4, `sdk_share_missing` / `pack_size` / `template_unknown`, destination absent | environment |
| Destination exists | `demo/` already present | exit 3, existing B0 refusal, nothing overwritten | project |
| Doctor, Pas2JS project | real `pweb doctor --json` | project rows pass; `frontend.node/npm/lockfile/dependencies` = `not_applicable/ui_not_react`; `frontend.pas2js` requires exactly 3.0.1 | env fail if absent |
| Doctor, React project | real `pweb doctor --json` | every B1 row unchanged, `frontend.pas2js` = `not_applicable/ui_not_pas2js` | unchanged |
| Real Pas2JS runtime | generated app run from an unrelated CWD | `html css js secure handshake rpc errmap` all true, `value = 42`, 0 listeners, clean exit | gate fails |

</frozen-after-approval>

## Code Map

**Read-only evidence — the audits that make this shard small**

- `tools/pweb/pweb.cli.project.pas:93` — `TPWebCliUi = (puiReact, puiPas2js)`;
  `:910-920` parses `ui` and accepts `'react'` **and** `'pas2js'`; `:42`, `:177`,
  `:245-250` document and project both. **Schema 1 already ratifies `pas2js`.**
  No schema change, no widening, nothing to approve.
- `tools/pweb/pweb.cli.doctor.pas:619-696` — the requirement graph is ALREADY
  UI-aware: React rows become `not_applicable/ui_not_react` for a Pas2JS
  project, and `frontend.pas2js` (`PWEB_CLI_TOOL_PAS2JS`, exact
  `PWEB_CLI_PAS2JS_VERSION`) is required only for `puiPas2js`. **No doctor code
  change**; B2 ACTIVATES the row for the first time.
- `tools/pweb/pweb.cli.template.pas:261-272` — `TPWebTplTemplate.Ui` is already
  documented `'react' | 'pas2js'`; `:2061-2086` `PWebTplFind` matches on
  template **Id**, and `pweb.pas` passes `Args.Ui` as that Id — so the new
  template id must be exactly `pas2js`.
- `src/webview/pweb.webview.host.pas:41-45` — "It does NOT branch on frontend
  kind … only `app.pwb` differs." B2 turns that claim into a measurement.
- `sdk/pas2js/pweb.native.pas` — the frozen SDK: `PWebHandshake`, `PWebInvoke`,
  `EPWebError(Code/Status/Data)`, `TPWebRuntimeInfo`, and the ONE private
  binding constant `PWEB_NATIVE_BINDING_NAME = '__pweb_invoke'` (`:60`).
- `examples/05-pas2js/frontend/build.ps1` — the frozen CAP-5 compile model:
  `-Tbrowser -Jc -Jirtl.js -O1`, `-Fu<sdk/pas2js>`, and `assets/boot.js`
  containing `rtl.run();` written byte-exactly with LF. Not modified.
- `examples/05-pas2js/frontend/src/p2japp.pas` — the canonical Pas2JS frontend
  the new template's application source is checked against.
- `pas2js.lock` — 3.0.1, per-target artifacts, and the macOS arm64 native
  source pin (`darwin-arm64-source-commit f27c414b…`, Rosetta banned).
- `tools/templates/react/**` — READ-ONLY. Its 14 files and their generated bytes
  are the B1 closure corpus.

**Production files this shard changes**

- `tools/templates/templates.list` — add the `template = pas2js` block
  (`visibility = public`, `ui = pas2js`, `native-dir src`, `native-ext lpr`,
  `frontend-root frontend`, `output-dir dist`) declaring 10 files.
- `tools/templates/pas2js/**` — NEW, 10 files (tree in Design Notes).
- `tools/pweb/pweb.cli.args.pas:79` — add `PWEB_CLI_UI_PAS2JS = 'pas2js'` beside
  `PWEB_CLI_UI_REACT`; the allowlist at the end of `PWebCliParseArgs` accepts
  exactly those two byte-exact values.
- `tools/pweb/pweb.cli.report.pas:107,159` — usage banner and create help
  INTERPOLATE both constants; no second spelling anywhere.
- `tools/pweb/pweb.pas` — `ExitForTplCode`: `ptcTemplateUnknown` → environment
  (pending ratification item 2); everything else unchanged. `RunCreate` is not
  otherwise touched.
- `.gitattributes` — pin `tools/templates/**/*.cfg text eol=lf`.

**Gates, evidence and CI**

- `test/cap10b0/check_cap10b0_contracts.ps1:269` — add `.cfg` to `$textExt`.
- `test/cap10b1/check_cap10b1_contracts.ps1` — INVERT rule 1 (react-only →
  react-and-pas2js), the `'pas2js'`-as-code refusal and the two doc refusals.
- `test/cap10b1/run_cap10b1_gates.ps1` — INVERT: `public_template_count` 1 → 2,
  `create --help` must now advertise `pas2js`, the `pas2js-ui` refusal leg
  becomes a success leg (moved to B2), `advertised_ui` → `supported_uis`.
- `test/cap10b1/build_cap10b1.{ps1,sh}` — stage `sdk/pas2js` into the SDK root
  (`share/pweb/sdk/pas2js`), so the harness resolves the PWeb Pas2JS SDK from an
  installation rather than the checkout.
- `test/cap10b2/` — NEW: `build_cap10b2.{ps1,sh}` (the react-only pack and the
  second CLI that proves `template_unknown` → 4), `check_cap10b2_contracts.ps1`,
  `run_cap10b2_gates.ps1`, `prove_cap10b2.{ps1,sh}` (built on the B1 shapes).
- `test/cap7f/emit_evidence.{ps1,sh}` — merge the B2 corpora.
- `test/cap7f/check_cap7f_aggregate.ps1:55-260` — new fields, must-PASS set,
  equality set, and absolute pins (`supported_uis = pas2js,react`,
  `pas2js_rpc_result = 42`, `pas2js_listener_count = 0`,
  `pas2js_app_raw_binding = false`, `pas2js_loose_assets = false`,
  `pas2js_sdk_binding_owner = true`).
- `test/cap7f/check_cap7f_selftest.ps1` — one negative leg per new refusal
  branch (c85…), and the refusal total keeps being COUNTED, never hardcoded.
- `.github/workflows/ci.yml` — three steps + one upload in each of the four
  native jobs, after the CAP-10B1 block.
- `docs/cli-contract.md:41-51`, `docs/template-contract.md:19,271` — the two
  advertised UIs, the exit mapping and the Pas2JS toolchain row.

## Tasks & Acceptance

**Execution:**

- [ ] `tools/templates/pas2js/` -- add the 10-file trusted template -- one public
      Pas2JS scaffold whose native half is the React one and whose frontend half
      is real Pascal over the frozen SDK.
- [ ] `tools/templates/templates.list` -- declare the `pas2js` template and every
      one of its files explicitly -- the builder cross-checks in both directions.
- [ ] `tools/pweb/pweb.cli.args.pas` -- add `PWEB_CLI_UI_PAS2JS` and accept
      exactly the two byte-exact values -- the allowlist stays compiled, never a
      template lookup, and no alias or case fold is added.
- [ ] `tools/pweb/pweb.cli.report.pas` -- interpolate both constants into the
      usage banner and `create --help` -- a help text with its own copy of the
      answer can advertise a frontend the parser refuses.
- [ ] `tools/pweb/pweb.pas` -- map `ptcTemplateUnknown` to environment -- with a
      two-value allowlist the code can only mean "this installation's pack does
      not describe an advertised template".
- [ ] `test/cap10b1/check_cap10b1_contracts.ps1`, `run_cap10b1_gates.ps1` --
      invert every react-only rule -- a rule deleted the moment it stops holding
      was never load-bearing.
- [ ] `test/cap10b1/build_cap10b1.{ps1,sh}` -- stage `sdk/pas2js` into the SDK
      root -- the frontend must compile against an installation.
- [ ] `test/cap10b2/build_cap10b2.{ps1,sh}` -- build a react-only pack from a
      filtered trusted source and a second `pweb` against it -- so
      `template_unknown` is a refusal somebody watched fire.
- [ ] `test/cap10b2/check_cap10b2_contracts.ps1` -- the two-UI allowlist, the
      shared-source parity gates, the canonical-source check against
      `examples/05-pas2js`, the no-npm-metadata rule and the doc cross-checks.
- [ ] `test/cap10b2/run_cap10b2_gates.ps1` -- the headless matrix: both creates,
      the refusal set, three-CWD determinism, the exact 11-file set, the React
      corpus pin, real doctor on both projects, and the parity projections.
- [ ] `test/cap10b2/prove_cap10b2.{ps1,sh}` -- relocate, external build stage,
      pinned compiler + staged SDK, static-output sweep, `app.pwb`, native build,
      real WebView run, project-unchanged re-digest, React regression.
- [ ] `test/cap7f/emit_evidence.{ps1,sh}`, `check_cap7f_aggregate.ps1`,
      `check_cap7f_selftest.ps1` -- carry, compare and refuse the B2 corpus.
- [ ] `.github/workflows/ci.yml` -- extend all four native jobs.
- [ ] `docs/cli-contract.md`, `docs/template-contract.md`,
      `_bmad-output/implementation-artifacts/cap10b2-final-artifact.md`,
      `deferred-work.md` -- record the surface, the supersession and the limits.

**Acceptance Criteria:**

- Given the shipped public CLI, when `pweb create --help` runs on any target,
  then it advertises exactly `react|pas2js`, `dev`/`run`/`build` are still
  unknown commands, and `supported_uis` parsed back out of that text is
  `pas2js,react` on all four targets.
- Given `--ui pas2js`, when create runs from three different working directories
  (plain, spaced, non-ASCII) on all four targets, then all twelve trees are
  byte-identical and `pas2js_generated_inventory_digest` is one value.
- Given the same NAME and bundleId, when the two generated projects are compared,
  then `src/app.services.pas` and `.gitattributes` are byte-identical, the
  comment-stripped code of `src/demo.lpr` is byte-identical, and `pweb.json`
  differs only in `"ui"`.
- Given the B1 closure corpus, when React is created on this build, then
  `generated_inventory_digest` still equals `1ca77cbb…60f3230` with 15 files and
  65765 bytes.
- Given the relocated Pas2JS project, when the private harness builds it, then
  the frontend compiles with Pas2JS 3.0.1 on the host's own architecture against
  the staged SDK, the static output contains exactly
  `index.html assets/app.js assets/boot.js assets/app.css`, carries no absolute
  path, no network URL, no dev code and no source map, `__pweb_invoke` occurs
  exactly once and inside the `pweb.native` module, and the project bytes are
  unchanged afterwards.
- Given `app.pwb` built by the frozen bundler, when the generated application
  runs from an unrelated CWD on all four targets, then the page reports
  `html css js secure handshake rpc errmap` true with `value = 42`, the release
  layout is exactly three files, the process opens zero listeners and exits
  cleanly.
- Given both generated applications, when their reports and native corpora are
  compared, then the report field set and every value agree and
  `shared_native_source_digest` is one value across UIs and targets.
- Given the closure run, when the aggregator runs, then every CAP-7/8/9/10A/10B0
  frozen digest is re-measured unchanged, the new absolute pins hold, and the
  negative self-test's counted refusal total exceeds its pre-shard value by the
  number of new branches.

## Design Notes

**The generated Pas2JS project (11 files).** Ten templated plus the generated
`pweb.json`:

```
.gitattributes                     byte-identical to React
.gitignore                         ratification item 1
README.md                          Pas2JS text
pweb.json                          generated; differs from React only in "ui"
src/{{PASCAL_PROGRAM}}.lpr         React's, one header-comment line apart
src/app.services.pas               byte-identical to React
frontend/index.html                static shell, two external scripts, one link
frontend/app.css                   byte-identical to React's frontend/src/app.css
frontend/pas2js.cfg                -Tbrowser -Jc -Jirtl.js -O1
frontend/src/{{PASCAL_PROGRAM}}app.lpr   program demoapp; uses app; RunApp
frontend/src/app.pas               the application logic over the frozen SDK
```

`src/*.lpr` differs from React's ONLY inside the header comment's data-path
block (`React -> @pweb/runtime` becomes `Pas2JS -> pweb.native`). The gate
strips comments with the existing `Get-CodeLines` helper and requires the
remaining CODE to be byte-identical, then requires every differing raw line to
sit inside that comment. No native source names a frontend kind outside a
comment; nothing branches on one.

**Measured before planning, and it decides the output contract.** Pas2JS 3.0.1
writes its JS through the host's text layer: on Windows the compiled `app.js`
begins `EF BB BF` and carries CRLF (1924 pairs in the probe; the committed
CAP-5 `dist/assets/app.js` carries 2000). On POSIX it is LF. Packaging the
compiler's raw bytes would make the Pas2JS `app.pwb` an OS-family artifact. The
build stage therefore **strips a leading UTF-8 BOM and converts CRLF to LF**
before packing — the same decision, for the same reason, that makes CAP-5 write
`boot.js` byte-exactly with LF rather than through `Set-Content`. If the hosted
matrix still shows a divergence after normalisation, the ratified fallback is
the CAP-10B0 `ZIP_OS` shape: pin the bytes per target, compare a semantic
projection, and record the measurement — never quietly drop the field.

**Measured: the raw binding is provably SDK-owned.** In both the probe bundle
and the frozen CAP-5 bundle, `__pweb_invoke` occurs **exactly once**, as
`this.PWEB_NATIVE_BINDING_NAME = "__pweb_invoke"` inside `rtl.module("pweb.native", …)`,
and `webkit.messageHandlers` / `chrome.webview` occur zero times. So the rule is
an occurrence-classification gate, not an impossible whole-bundle ban: zero
occurrences in the generated application SOURCE, exactly one in the bundle, and
that one inside the SDK module.

**The SDK-root model.** `build_cap10b1` gains one staging line
(`sdk/pas2js` → `share/pweb/sdk/pas2js`). The proof compiles

```
<pinned pas2js> @<project>/frontend/pas2js.cfg -Fu<staged share/pweb/sdk/pas2js> \
  -o<external-stage>/dist/assets/app.js <project>/frontend/src/demoapp.lpr
```

so the output lands OUTSIDE the project and no SDK path is ever written into it.
`@<cfg>` was verified locally against the pinned 3.0.1 compiler: it is read in
addition to the compiler's own `pas2js.cfg`, which is what supplies the RTL.
The compiler and its RTL still come from `deps/pas2js*` exactly as CAP-5/7L/7M2
resolve them — the same half-staged-SDK limitation B1 already ledgered for
mORMot and the webview library, extended by one line rather than re-litigated.

**Frontend flow** (mirrors `App.tsx` field for field, so parity is comparable):
`PWebHandshake` → `PWebInvoke('CalculatorService.Add', {a:20,b:22})` → 42 →
`PWebInvoke('Denied.Probe', nil)` caught as `EPWebError` with
`code='forbidden'`, `status=403`, `data=null` → `PWebInvoke('app.ready', report)`
carrying exactly `{html, css, js, secure, handshake, rpc, value, errmap}`. `css`
is proved by reading `--pweb-styled` back off the computed style, as React does.

**Known risk, carried in.** `deferred-work.md` records an intermittent CAP-5
Pas2JS runtime smoke on Windows (page reported nothing inside its auto-close
window). The B2 harness owns its own wait: it must log the elapsed time to the
report and fail with a distinguishable cause when the window expires, so an
intermittent timing failure is never reported as a runtime defect.

## Verification

**Commands** (all `pwsh -NoProfile -File`, in this order):

- `test/cap10b0/build_cap10b0.ps1`, `test/cap10b1/build_cap10b1.ps1`,
  `test/cap10b2/build_cap10b2.ps1`, `test/cap10a/build_cap10a.ps1` -- exit 0;
  `build/cap10b1/sdk/share/pweb/sdk/pas2js/pweb.native.pas` and the react-only
  CLI present.
- `test/cap10b0/{check_cap10b0_contracts,run_cap10b0_gates}.ps1` -- 0 violations,
  `template_corpus PASS`, 7 builder refusals, superseded counts recorded.
- `test/cap10b1/{check_cap10b1_contracts,run_cap10b1_gates}.ps1` -- 0 violations
  with the inverted two-UI rules, `create_corpus PASS`, and
  `generated_inventory_digest` still
  `1ca77cbb8dc0fed5844fa6aa958ca2727ea560f5bda0b50b23e1bd9b360f3230`.
- `test/cap10b2/check_cap10b2_contracts.ps1`, `run_cap10b2_gates.ps1`,
  `prove_cap10b2.ps1` -- 0 violations, `pas2js_create_corpus PASS`,
  `supported_uis = pas2js,react`, `pas2js_proof_corpus PASS`,
  `pas2js_rpc_result 42`, `pas2js_listener_count 0`.
- `test/cap7f/emit_evidence.ps1` then `test/cap7f/check_cap7f_selftest.ps1` --
  every new refusal branch proven red on fixtures, total COUNTED not hardcoded.
- hosted CI on the shard branch -- all six jobs green, `cap7 aggregate`
  reporting one `pas2js_generated_inventory_digest` on four targets.
