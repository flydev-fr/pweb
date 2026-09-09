---
title: 'CAP-14A — the bundler refuses what the native CSP will not run'
type: 'feature'
created: '2026-09-08'
status: 'in-review'
baseline_commit: '958ff45f13488dad6be4b8b08f1f5cafd2772a7f'
review_loop_iteration: 0
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/docs/pipeline-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `PWEB_NATIVE_CSP` carries `script-src 'self'` with no `'unsafe-inline'`
(`src/security/pweb.navigation.policy.pas:132`). A `dist` whose `index.html` carries an
inline `<script>` — the shape an arbitrary third-party static build routinely has —
bundles cleanly, `--verify`s cleanly, builds cleanly and then **half-works at run time
with no error anywhere**: not at pack, not at build, not at run. An external reviewer
measured exactly that (TODO.txt #2). Every construct the CSP silently kills is in the
same family: an inline `<script>`, a cross-origin or `data:`/`blob:` script `src`, an
`on*=` event-handler attribute, a `javascript:` URL.

**Approach:** `pwebbundle` refuses at **pack** time, with a typed cause naming file and
line, any HTML document the native CSP would not execute — and accepts the constructs it
would: non-executable `<script>` data blocks, inline `<style>` and `style=` (style-src
carries `'unsafe-inline'` by ratified decision), and a same-origin-relative `src`
including Vite's real `type="module"` output. The refusal is walk-time policy owned by
the CLI, exactly as the ratified sourcemap exclusion is. There is **no override**: the
CSP will not run it, so a flag that packs it anyway is a lie.

## Boundaries & Constraints

**Always:**
- One forward, bounded byte scan. No full HTML parser, no DOM, no regex over the file,
  no backtracking, no recursion.
- The refusal is CLI-level (`pwebbundle`) only. `PWebBundleWrite` is untouched, so the
  writer unit the **host** links is byte-unchanged.
- Every existing corpus must still pack, measured rather than assumed: the B1/B2
  templates, `examples/**`, the CAP-7M/8B/8C/9C2 fixtures, Vite's real output and the
  Pas2JS assembly.
- The scanned set is read from `PWebAssetMimeType`, never typed a second time: exactly
  the logical names that resolve to `text/html`.
- Where the scanner cannot decide, it refuses. Every deviation from an engine's own
  tokenizer must be in the over-refusal direction, and each one is named and measured.
- The bundler's own failure exit stays **1**; `pweb build` maps a nonzero pack child to
  its existing typed failure, **exit 5**, `stage_exited`, no layout.

**Ask First:** nothing. Every decision below is settled by this document at Checkpoint 1.

**Never:**
- No CSP change, no host change, no `pweb.json` / manifest / evidence **schema** change
  beyond additive evidence rows, no new CLI option anywhere, no environment variable,
  no per-file exemption, no `--allow-inline-script`.
- No second HTML policy: one unit decides, and the bundler is its only caller.
- No change to `pweb.cli.pipeline.pas`, `pweb.cli.dev.pas` or `pweb.cli.pack.pas` —
  both seams already do the right thing and this shard **measures** them.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| inline script | `<script>window.cfg=1</script>` | refuse `bundle_inline_script`, `index.html:7` | exit 1, nothing written, previous output survives |
| inline module | `<script type="module">import…</script>` | refuse `bundle_inline_script` | as above |
| inline importmap | `<script type="importmap">{…}</script>` | refuse `bundle_inline_script` | as above |
| typed JS essence | `<script type="text/javascript; charset=utf-8">x</script>` | refuse `bundle_inline_script` | as above |
| cross-origin src | `<script src="https://cdn.example/x.js">` | refuse `bundle_external_script` | as above |
| protocol-relative | `<script src="//cdn/x.js">` | refuse `bundle_external_script` | as above |
| data:/blob: src | `<script src="data:text/javascript,…">` | refuse `bundle_external_script` | as above |
| event handler | `<body onload="go()">` | refuse `bundle_inline_handler` | as above |
| javascript: URL | `<a href="java&#9;script:x">` | refuse `bundle_javascript_url` | as above |
| UTF-16 document | `index.html` opening `FF FE` | refuse `bundle_html_encoding` | as above |
| several at once | one of each in one dist | **every** violation reported, one line each, then one failure | one round, nothing written |
| JSON data block | `<script type="application/json">{"a":"</scr"+"ipt>"}</script>` | accept | — |
| ld+json / template | `application/ld+json`, `text/template` | accept | — |
| inline style | `<style>…</style>`, `style="…"` | accept | — |
| same-origin src | `/assets/app.js`, `assets/app.js`, `./x.js` | accept | — |
| Vite output | `<script type="module" crossorigin src="/assets/app.js">` | accept | — |
| `>` in an attribute | `<div data-t="a>b" onclick="x">` | the handler is still found | refuse `bundle_inline_handler` |
| comment / raw text | `<!-- <script>x</script> -->`, `<noscript><img onerror=y></noscript>` | accept | — |
| `pweb build` | a Pas2JS project whose `index.html` gained an inline script | exit **5**, cause `stage_exited`, cause lines forwarded, **no release layout**, previous release intact | — |
| `pweb dev` | the same edit mid-session | generation **not** published, previous generation stays live, `pack: ` lines forwarded, host pid unchanged, loop continues | at start-up the same failure is exit 5 |

</frozen-after-approval>

## Code Map

- `src/security/pweb.navigation.policy.pas:132` — `PWEB_NATIVE_CSP`. **Read-only.** The
  authority for every rule below: `script-src 'self'`, no `'unsafe-inline'`, no
  `'unsafe-eval'`; `style-src 'self' 'unsafe-inline'`.
- `tools/bundler/pwebbundle.pas` — the CLI. `RunBuild` walks (`Collect`), sorts
  (`SortInputs`), runs the **ratified D3 classification pass** that "reports EVERY
  offender before failing", then reads content into `entries` and calls
  `PWebBundleWrite`. The CSP pass joins that same reporting round. `ExitCode := 1` on
  any exception is the one failure code and stays.
- `src/assets/pweb.assets.support.pas:276` — `PWebAssetMimeType`. The single truth for
  "is this a document the engines parse as HTML".
- `src/assets/pweb.assets.bundle.pas` — `PWebBundleClassifyName`, `PWebBundleWrite`.
  **Read-only.** The writer is linked by the production host; nothing here may grow.
- `tools/pweb/pweb.cli.pipeline.pas:415-490` — `RunStage`: `pcoExited` with a nonzero
  code ⇒ `Refuse(pskPack, ppcStageFailed, 'stage_exited', <code>)`, `ppcStageFailed`
  ⇒ **exit 5**, the layout stage never runs. **Read-only.**
- `tools/pweb/pweb.cli.dev.pas:952-963, 1250-1258` — a pack child that fails increments
  `PackFailures`, says "the previous generation stays live", resets the refusal and
  continues. **Read-only.**
- `docs/pipeline-contract.md` §3 (ten stages), §9 (failure and exit categories) — the
  contract home for the new rule.
- `test/cap6/run_cap6_gates.ps1` legs 3-4 — the precedent for a refusal leg proven by
  entry list and by "a refusal creates nothing".
- `test/cap6/check_cap6_nonetwork.ps1` — the swept file set; the new policy unit joins it.
- `test/core/pwebtests.pas` — compiled on four targets with `-Fusrc/assets -Futest/assets`
  by `.github/actions/pweb-test-suite-mormot-core-test`, `test/cap7l/build_cap7l.sh:131`
  and `test/cap7m/build_cap7m.sh:93`, so a new unit in those two directories needs **no
  CI edit**.
- `test/cap7f/emit_evidence.ps1` (`$evidence = [ordered]@{`), `emit_evidence.sh`
  (`evidence.json <<EOF`), `check_cap7f_aggregate.ps1` (`$required`, `$equalityFields`,
  `$absolutePins`) — the three hand-maintained lists `check_schema_agreement.ps1` holds
  to each other. `schema_field_count` moves with them.
- `.github/actions/backlog-disposition-…/action.yml` + `test/cap11a/post-migration-amendments.tsv:7`
  + `step-applicability.tsv` — the worked recipe for **adding** a step to the one
  platform-leg sequence as a declared amendment. Current `ci_sequence_digest` is
  `7f7dc950d8bc7aa96856869421a8bbc8dbfebc469263a3a76a2d1b35d1ac527c` at 202 steps.
- `test/backlog/dispositions.tsv` + `docs/backlog.md` — every `deferred-work.md` entry
  needs a verdict or the step-179 gate goes red.

## Tasks & Acceptance

**Execution:**

- [x] `src/assets/pweb.assets.htmlpolicy.pas` — new unit: the bounded scanner, the five
  typed causes, HTML's own executable-script-type rule, the same-origin-relative `src`
  rule, the `on*` and `javascript:` rules, and `PWebHtmlIsDocument` delegating to
  `PWebAssetMimeType`. Assets-layer only (`sysutils`, `mormot.core.base`,
  `pweb.assets.support`) — it must pass the CAP-6 isolation compile.
- [x] `tools/bundler/pwebbundle.pas` — read each HTML input once in the existing
  offender-reporting round; print one `pwebbundle: <cause>: <logical>:<line>: <text>`
  line per violation, bounded, then fail with the existing "refused input file(s) —
  nothing was written" exception. No new option, no new exit code.
- [x] `test/assets/pweb.test.htmlpolicy.pas` — the headless decision corpus: every
  refusal class, every accept class, every adversarial shape (case, whitespace,
  comments, CDATA, `>` inside an attribute, `</script>` inside a JSON block, tab inside
  `javascript:`, raw-text elements), each written as one line to
  `build/cap7f/html-policy.txt` so four targets can be compared byte for byte.
- [x] `test/core/pwebtests.pas` — register the case (`uses` + published `HtmlPolicy`).
- [x] `test/cap6/check_cap6_nonetwork.ps1` — sweep the new policy unit too; state why
  the new **test** unit is deliberately not swept (it carries scheme fixtures on purpose).
- [x] `test/cap14a/fixtures/**` — a signage-shaped accept dist and its hostile twin
  carrying one of each violation; the UTF-16 fixture is written by the gate, never
  committed as text.
- [x] `test/cap14a/run_cap14a_gates.ps1` — the four-target gate over the **real**
  `pwebbundle` binary: each refusal class, each accept class, every existing corpus
  packs, the `pweb build` refusal on a copied generated Pas2JS project (exit 5, no
  layout, previous release intact), the `pweb dev` refusal (previous generation live,
  cause forwarded, host pid unchanged), no ANSI when redirected. Writes
  `build/cap14a/cli-<target>.json`.
- [x] `test/cap14a/check_cap14a_contracts.ps1` — source-level cross-checks: no new
  option in the bundler's parser, the policy unit absent from the release host's linked
  unit set, the cause vocabulary equal in unit, gate, contract document and README.
- [x] `.github/actions/cap-14a-…/action.yml`, `.github/workflows/platform-leg.yml`,
  `test/cap11a/step-applicability.tsv`, `test/cap11a/post-migration-amendments.tsv`,
  `test/cap11a/collection-paths.json` — the declared amendment, recording
  `ci_sequence_digest` 202 → 203 with its old and new values.
- [x] `test/cap7f/emit_evidence.ps1`, `emit_evidence.sh`,
  `check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1` — the new rows, the equality
  set, the absolute pins, and one perturbation proving a divergence is caught.
- [x] `docs/pipeline-contract.md` (the normative rule), `docs/build-contract.md` and
  `docs/dev-contract.md` (cross-links in their failure tables), `tools/bundler/README.md`.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md`, `test/backlog/dispositions.tsv`,
  `docs/backlog.md` — the shard's own findings, each with a verdict.
- [x] `_bmad-output/implementation-artifacts/cap14a-final-artifact.md` — the shard record,
  including the bundler digest supersession old → new with its reason.

**Acceptance Criteria:**
- Given a dist carrying one of each violation, when it is packed, then **every**
  violation is printed with its cause, its logical path and its line, the exit is 1, and
  no output file exists.
- Given the accept corpus, when it is packed, then the exit is 0 and the archive is
  byte-identical to what the same dist produced before this shard.
- Given every existing corpus — the two templates, the four example dists, the four test
  fixtures, Vite's real output and the Pas2JS assembly — when each is scanned or packed,
  then all pass, measured on four targets.
- Given a generated Pas2JS project whose `frontend/index.html` gained an inline script,
  when `pweb build` runs, then it exits 5, prints the bundler's typed cause, and leaves
  no release layout and the previous release untouched.
- Given the same edit during `pweb dev`, when the loop reacts, then the generation is not
  published, the previous generation stays live, the host pid is unchanged and the loop
  keeps running.
- Given four green targets, when `cap7 aggregate` runs, then `bundle_refusal_classes`,
  `bundle_accept_classes`, `html_policy_digest`, `bundler_digest` and `csp_policy_digest`
  are equal on four and `bundle_corpora_pack` is `true`.
- Given the whole shard, when the bundler's option parser and the release host's linked
  unit set are swept, then there is no new option and the policy unit is not in the host.

## Design Notes

**The five typed causes.** `bundle_inline_script`, `bundle_external_script`,
`bundle_inline_handler`, `bundle_javascript_url` — the four ratified classes — plus
`bundle_html_encoding`, which is not a fifth class of *violation* but a refusal to
**judge**: a document opening with a UTF-16 BOM is one the engines decode as UTF-16 and
this UTF-8 scanner cannot read, so certifying it would be a guess. It closes the one
tokenizer bypass an adversarial reading finds.

**Executable script type is HTML's own rule, not a four-name list.** Absent, empty,
`module`, `importmap`, or a MIME essence (up to the first `;`, ASCII-trimmed and
lowercased) in the sixteen-entry JavaScript MIME type list. `text/javascript; charset=utf-8`
is therefore refused and `application/json` accepted — a four-name list would have missed
the first.

**The over-refusals, each named and each in the safe direction.** An `on…`-prefixed
attribute that no engine honours (`once`) is refused, because a handler an allowlist
forgot is the exact defect this shard exists to kill — measured zero occurrences across
the corpus. A `src` spelled `pweb://app/x.js` is refused, because authority parsing is
where cross-origin acceptance bugs live and a bundle names its own assets relatively. A
`<script>` that is text inside an SVG `<![CDATA[…]]>` carrying a `>` is refused, because
the scanner applies the HTML-namespace bogus-comment rule in both namespaces.

**`.svg` is deliberately not scanned.** An SVG referenced as an image has scripting
disabled by the image context, so a handler inside one is inert *by design* rather than
by CSP, and refusing it would refuse a working dist. Only `text/html` is scanned.

## Verification

**Commands:**
- `pwsh -File test/cap6/build_cap6.ps1` — expected: the isolation compile, the bundler
  and the release host all build.
- `pwsh -File test/cap6/check_cap6_nonetwork.ps1` — expected: PASS with the policy unit
  in the swept set.
- `pwsh -File test/cap6/run_cap6_gates.ps1` — expected: unchanged ALL PASS, including
  the byte-identical rebuild — the accept path moved no archive bytes.
- `build/test/pwebtests.exe /noenter` — expected: the new `Html policy` case green and
  `build/cap7f/html-policy.txt` written.
- `pwsh -File test/cap14a/run_cap14a_gates.ps1` — expected: every refusal class, every
  accept class, every corpus, the build and dev seams.
- `pwsh -File test/cap14a/check_cap14a_contracts.ps1` — expected: no new option, the
  policy unit absent from the host, one cause vocabulary in four places.
- `pwsh -File test/cap7f/check_schema_agreement.ps1` — expected: three lists, zero
  asymmetry.
- `pwsh -File test/cap11a/check_migration_map.ps1` and `check_ci_sequence.ps1` —
  expected: the added step declared, its body digest matching, 203 steps.
- `pwsh -File test/backlog/check_backlog.ps1` — expected: every ledger entry disposed.
- Under **WSL**: `bash test/cap7l/build_cap7l.sh` then the pwebtests suite and
  `pwsh -File test/cap14a/run_cap14a_gates.ps1`, before any push.

**Manual checks:**
- `git diff --stat 958ff45 -- src/security src/webview tools/pweb examples` — expected:
  empty. No CSP change, no host change, no CLI change.
