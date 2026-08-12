---
title: 'PWeb Phase 6 / CAP-6 release bundle — deterministic app.pwb bundler and runtime boot'
type: 'feature'
created: '2026-08-12'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'cadea5beacc28a411be84e7c128bbd99a337d355'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-4-cap4-asset-system.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-5-cap5-frontend-sdks.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every runtime proof still serves the frontend from loose files (`TFolderAssetStore` over `frontend/dist/`) or a hand-built test `app.zip`; no production container, no bundler, no manifest, and no compatibility gate exist, so a release cannot ship as `MyApp.exe + app.pwb`.

**Approach:** Implement a deterministic ZIP bundler (library unit + CLI tool) that packs an already-built frontend dist plus a generated `manifest.json` into `app.pwb`, and the smallest runtime bundle loader that validates the archive, checks the ratified compatibility predicate **before any bundle JS executes**, then serves the UI through the unchanged CAP-4 path (`TZipAssetStore` → `pweb://app` WebView2 handler), proven by a release-layout runtime gate with no loose frontend files and no fallback.

## Boundaries & Constraints

**Always:** `app.pwb` is ZIP read with the existing `TZipRead`-based `TZipAssetStore`; one asset-serving architecture (CAP-4 validator, MIME, handler, exact-case semantics) — the bundle layer only wraps it. Manifest schema is exactly the ratified block `{"pweb":{"protocol":<int>,"minRuntime":"X.Y.Z"}}`; load predicate is `protocol ∈ PWEB_SUPPORTED_PROTOCOLS AND SemVer(runtime) >= SemVer(minRuntime)` — set membership, SemVer ordering never lexicographic; malformed/absent manifest or `pweb` block ⇒ refuse; refusal is a native-controlled diagnostic (typed reason category, no parser internals), never HTML/JS from the rejected bundle, and zero bundle JS executes before acceptance. `manifest.json` cannot grant anything: the loader reads only the `pweb` block; capability-like fields (`allow`, `capabilities`, `permissions`) are inert unknown fields; `AppMaximum` stays native-side. Bundler validates every entry name through `PWebAssetPathValid` plus duplicate/case/file-dir collision rules before writing; **ratified D1 (closes the deferred CAP-4 finding):** entry names remain valid Unicode (no ASCII-only restriction); any two logical names comparing equal under the pinned mORMot Unicode 10.0 simple case fold (`UpperCaseReference`) reject — enforced twice, at bundle construction AND at `TZipAssetStore` construction, so a hand-crafted/tampered `app.pwb` cannot bypass the bundler policy; the fold is an ambiguity-rejection rule only — it never normalizes or rewrites a name, and lookup stays exact byte/case-sensitive after construction. deterministic output (global bytewise sort of canonical logical names, fixed DOS timestamp `$00210000`, fixed deflate level, no extra fields, canonical manifest bytes) — byte-identical rebuild across time is a hard gate; self-validation reopens the temp output through the production loader (raw stored-name byte compare included) before an atomic replace; on failure the previous output survives, temp is removed, exit is nonzero. Release host locates `app.pwb` beside the executable (never CWD), imports no folder store, and fails closed with nonzero exit + refusal marker when the bundle is missing/invalid. The assets layer stays webview-free and rpc-free: protocol set and runtime version are parameter-injected into the loader; only the CLI/host import `pweb.rpc.intf`/`pweb.rpc.support` constants. All pins, the three CI freeze diffs (`b2f04dc4c478c72b1699a954dd52e76b207e918b`, `709bf0fee715d0cf9b8c475b4f801947fc0f4a65`, `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`), and every existing CI gate stay intact verbatim.

**Ask First:** Any change to a frozen interface, wire semantics, protocol version, or error taxonomy; any new dependency or pin; any deviation from the six ratified decisions in Design Notes (Unicode fold policy, large-asset threshold, exclusion policy, example numbering, servable manifest, minRuntime grammar); weakening any existing CI gate; PWB1/SynLZ or any non-ZIP container work.

**Never:** CAP-6b/installers/WebView2 provisioning; CAP-4b/blob/Range/streaming; CAP-7/8/9/10; HTTP/localhost/file:// serving or fallback anywhere in the release path; extraction-to-disk before serving; a second WebView resource handler or privileged origin; frontend compilation inside the bundler (input is an already-built dist); silent normalization of unsafe entry names by the ZIP writer; development fallback (folder store, `app.zip` fixture, `SetHtml`) in the release host; packaging the repository root or reading secret file contents to classify them (name/path classification only).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Happy bundle | React CAP-5 `frontend/dist` | `app.pwb` = generated `manifest.json` + `index.html` + `assets/*`, sorted canonical names, fixed timestamps | N/A |
| Deterministic rebuild | same logical input, later wall-clock, different file mtimes | byte-identical archive (SHA256 equal) | N/A |
| Hostile input name | traversal, backslash, absolute, drive/UNC, ADS, device name, `%`, control/overlong UTF-8, trailing dot/space | build fails before writing; no output touched | per-name error, nonzero exit |
| Collision | `app.js` vs `App.js`; `café.js` vs `CAFÉ.js`; `a` vs `a/b.js`; exact duplicates | build fails per ratified collision policy | nonzero exit |
| Reserved manifest | input dist contains root `manifest.json` | build fails — bundler owns the manifest | nonzero exit |
| Oversized asset | asset above per-asset threshold | build fails naming the asset and the blob-plane escape route | nonzero exit |
| Dev/secret artifact | `.env*`, key/cert names, `.git/`, `node_modules/`, lockfiles, `*.pas` in dist | build fails (classification by name only); `*.map` excluded by default, `--include-sourcemaps` opts in | nonzero exit / logged skip |
| Failed build | injected write/validation failure mid-build | temp file removed; pre-existing `app.pwb` intact; nonzero exit | deterministic cleanup |
| Compat matrix | protocol 1 / unsupported 2 / malformed; minRuntime `<`,`=`,`>` runtime; `0.10.0` vs `0.9.0`; invalid semver; missing block; malformed JSON; unknown additive fields; capability-like fields | load iff predicate holds; unknown fields ignored; capability fields inert | refusal typed; no store created; bundle JS count == 0 |
| Tampered bundle | non-ZIP bytes, truncated archive, no manifest, duplicate manifest entry, missing `index.html`, hostile entry name | loader refuses, native diagnostic, no crash, no fallback | fail closed |
| Release runtime | clean `release/` dir (exe + `app.pwb` + dll only), unrelated CWD | UI boots from `app.pwb` over `pweb://app`; SDK handshake, `isSecureContext===true`, `CalculatorService.Add({a:20,b:22})` → 42; exit 0 | any miss fails the smoke |
| Missing bundle | `app.pwb` absent beside exe | nonzero exit + refusal marker; **no WebView created**, no folder/source fallback | headless-testable |

</frozen-after-approval>

## Code Map

- `src/assets/pweb.assets.support.pas` — `PWebAssetPathValid` (:226) is the one validation truth the bundler reuses per entry; `PWEB_ASSET_DEFAULT_DOCUMENT` (:41); MIME resolver. Read-only.
- `src/assets/pweb.assets.zip.pas` — `TZipAssetStore.IndexAndValidate` (:117): raw `storedName` validation, duplicate/ASCII-case/file-dir collision rejection, 2 GB cap, private `UnZip` lock. The loader builds on this store; the ratified Unicode fold lands here (:170-179 replaces `LowerAscii` fold) and in the bundler.
- `src/assets/pweb.assets.intf.pas` — frozen; do not touch (`TryRead`/`TAssetResponse`).
- `examples/06-assets/mkappzip.pas` — deterministic-ZIP precedent: `FIXED_FILE_AGE = $00210000` (:34), `AddDeflated(name, buf, size, 6, age)` (:66), forward-slash names, size-verified reads. The bundler generalizes this.
- `deps/mormot2/src/core/mormot.core.zip.pas` — `TZipWrite.AddDeflated` (:693); name encoding at `WriteHeader` (:1954-1966): ASCII → byte-exact `StringToAnsi7`, non-ASCII → codepage-dependent `StringToUtf8` + UTF-8 flag — self-validation must byte-compare raw stored names to catch drift; `extraLen=0` on the non-zip64 path (:1951).
- `deps/mormot2/src/core/mormot.core.unicode.pas` — `UpperCaseReference`/`Utf8ICompReference` (:2952-2964): pinned Unicode 10.0 case-folding tables — the deterministic fold source for the ratified collision policy.
- `src/rpc/pweb.rpc.intf.pas` — `PWEB_PROTOCOL_VERSION` (:52), `PWEB_SUPPORTED_PROTOCOLS` (:57); `src/rpc/pweb.rpc.support.pas` — `PWEB_RUNTIME_VERSION = '0.1.0'` (:34). Imported by CLI/host only, injected into the loader as parameters.
- `examples/04-react/reactapp.pas` — host template to clone for the release host: verdict latch (:95-122), binding + handler + navigate wiring (:191-223), teardown order (:224-281). Release host swaps `TFolderAssetStore` for the bundle loader and drops the folder-store import entirely.
- `test/assets/pweb.test.assets.pas` — crafted raw-ZIP hostile-archive helpers (:648) to reuse for tamper fixtures; registration pattern in `test/core/pwebtests.pas` (:33-55, new published proc).
- `test/cap5/run_cap5_smokes.ps1` + `check_cap5_nonetwork.ps1` — conditional hosted PASS/SKIP/FAIL smoke policy and zero-network sweep patterns to mirror for CAP-6.
- `.github/workflows/ci.yml` — append CAP-6 section after `:866` (CAP-5 diagnostics); freeze sweeps (:552-594) and all earlier steps stay verbatim; React dist is already built at `:808`.

## Tasks & Acceptance

**Execution:**
- [x] `test/assets/pweb.test.bundle.pas` (+ registration in `test/core/pwebtests.pas`) — failing-first headless suite: full bundler matrix (creation, required roots, determinism incl. mtime variance, ordering, nested/empty/binary assets, hostile paths, all collision classes, reserved manifest, threshold, secret/exclusion sweep, atomic failure + prior-output preservation, self-validation, `TZipAssetStore` reads output), the four mandated D1 cases (fold-equal reject, non-fold-equal non-ASCII accept, machine-independent verdicts, crafted-ZIP bypass rejected by the store), manifest compat matrix (all rows), tamper fixtures over crafted raw ZIP bytes, loader-refusal proofs (no store ⇒ no JS).
- [x] `src/assets/pweb.assets.bundle.pas` — NEW: canonical manifest record/serialize/strict-parse, strict `X.Y.Z` SemVer compare, parameter-injected compat predicate, typed refusal reasons, deterministic validating bundle writer (temp sibling → self-validate via production reader → atomic `MoveFileEx` replace), bundle loader (`open/validate archive → manifest → compat → require index.html → IAssetStore`). Webview-free and rpc-free.
- [x] `src/assets/pweb.assets.zip.pas` — strengthen construction-time case-collision fold from ASCII to the ratified Unicode policy (D1); no other behavior change; CAP-4 tests stay green.
- [x] `tools/bundler/pwebbundle.pas` — NEW CLI: `pwebbundle <distdir> <out.pwb> [--min-runtime=X.Y.Z] [--max-asset-bytes=N] [--include-sourcemaps]`; deterministic recursive walk sorted by canonical logical path (never FS order), exclusion/secret classification, stamps `protocol` from `PWEB_PROTOCOL_VERSION`, `minRuntime` default `PWEB_RUNTIME_VERSION`.
- [x] `examples/08-release/releaseapp.pas` — NEW release host cloned from `reactapp.pas`: bundle loader over `app.pwb` beside the exe, refusal ⇒ stderr reason + nonzero before any `webview_create`; success ⇒ same verdict latch (handshake/secure/rendered/rpc/42) with marker `releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS`.
- [x] `test/cap6/` — `build_cap6.ps1` (compile bundler+host), `run_cap6_gates.ps1` (headless: build real `app.pwb` from React dist, timed rebuild hash-equality across ≥3 s, isolated `release/` assembly + no-loose-assets check, missing/tampered-bundle refusal runs from unrelated CWD, observational ZIP benchmark to step summary), `check_cap6_nonetwork.ps1` (zero-network sweep over new sources), `run_cap6_smoke.ps1` (conditional hosted release runtime smoke, genuine failure = FAIL).
- [x] `.github/workflows/ci.yml` — append CAP-6 gates (bundler/host compile, pwebtests with bundle cases, headless gates script, nonetwork sweep, conditional smoke, diagnostics upload); no existing step altered.

**Acceptance Criteria:**
- Given the headless suite, when pwebtests runs, then every bundler-matrix, compat-matrix, and tamper row passes deterministically before any runtime host work, and every refusal row proves no `IAssetStore` was produced.
- Given two bundler runs over identical logical input separated by time and differing file mtimes, when hashes are compared, then the archives are byte-identical — locally and in CI.
- Given the clean release directory run from an unrelated CWD, when `releaseapp.exe` starts, then the UI boots solely from `app.pwb` through `pweb://app` with handshake, secure context, and 42, exiting 0; and with `app.pwb` removed it exits nonzero with the refusal marker and no WebView — with zero loose frontend files present either way.
- Given the final tree, when full CI runs, then all CAP-1…CAP-5 gates, the three freeze diffs, and every pin stay green and untouched.

## Spec Change Log

## Design Notes

Six decisions ratified with this spec (D1 **human-ratified 2026-08-12**, closing the deferred CAP-4 finding — `deferred-work.md:7-9`):

- **D1 Unicode collisions (RATIFIED):** entry names remain valid Unicode — v1 is not restricted to ASCII. Any two logical names comparing equal under the pinned mORMot **Unicode 10.0 simple case fold** (`UpperCaseReference`) reject, enforced twice: (1) at bundle construction, (2) at `TZipAssetStore` construction — the second is mandatory so a hand-crafted or tampered `app.pwb` cannot bypass the bundler. The fold is only an ambiguity/collision rejection rule: it never normalizes or rewrites asset names, and lookup stays exact byte/case-sensitive after construction. Rationale: `café.js` + `CAFÉ.js` are byte-distinct ZIP entries yet equal under NTFS `$UpCase`; the pinned compiled-in table (never OS tables) keeps the verdict deterministic across machines and years. Mandated tests: `café.js` vs `CAFÉ.js` ⇒ reject; ordinary non-ASCII distinct names that do not fold equal ⇒ accept; collision verdicts identical across machines (pinned-table source, no OS case API — proven local + CI); hand-crafted ZIP bypassing the bundler ⇒ rejected by `TZipAssetStore`.
- **D2 Large-asset policy:** per-asset threshold, default **32 MiB**, exceeded ⇒ **error** (naming the blob-plane escape route), `--max-asset-bytes` overrides. No `IAssetStore`/streaming change.
- **D3 Exclusion policy:** secret/dev names (`.env`, `.env.*`, `*.pem/key/pfx/p12/crt`, `.git*`, `node_modules/`, lockfiles, `*.pas`, `.DS_Store`, `Thumbs.db`) ⇒ hard error; `*.map` ⇒ excluded by default (logged), `--include-sourcemaps` opts in. Classification by path/name only.
- **D4 Example numbering:** release proof lands in `examples/08-release/`; `07-quickjs` stays reserved per the frozen layout illustration.
- **D5 Manifest is a servable asset:** `pweb://app/manifest.json` serves the manifest like any entry (it holds only public compat metadata); the *input* dist may not contain a root `manifest.json` (bundler owns it).
- **D6 minRuntime grammar:** strict numeric `X.Y.Z` (no prerelease/build suffix); anything else is malformed ⇒ refuse. Canonical manifest bytes are exactly `{"pweb":{"protocol":N,"minRuntime":"X.Y.Z"}}` (no whitespace, fixed key order) so manifest serialization can never cause hash drift.

Loader ordering is the compatibility proof: archive validation and the manifest gate complete before the host ever calls `webview_create`; a refusal path therefore cannot execute bundle JS by construction, and the headless matrix asserts no store object exists on refusal. Self-validation reopens the temp file with the same production loader + `TZipAssetStore` and byte-compares raw stored names against the expected canonical list — closing the `TZipWrite` non-ASCII/codepage hazard regardless of D1's outcome.

## Verification

**Commands:**
- `fpc -MObjFPC -Sh -B -FUbuild/fpc-assets -Fusrc/assets -Fudeps/mormot2/src/... src/assets/pweb.assets.bundle.pas` — expected: compiles with no webview/rpc unit path.
- pwebtests compile+run per CI with `-Futest/assets` — expected: exit 0, prior counts preserved, new bundle cases green.
- `pwsh test/cap6/run_cap6_gates.ps1` — expected: real `app.pwb` from React dist, rebuild hash equal, release layout clean, refusal runs nonzero with markers, benchmark recorded.
- `releaseapp.exe` from clean release dir with `PWEB_SMOKE_AUTOCLOSE_MS` — expected: PASS marker + exit 0; after deleting `app.pwb`: refusal marker + nonzero.
- Push branch; hosted CI — expected: all gates green, freeze sweeps and pins untouched.

## Suggested Review Order

**The bundle contract and the compatibility gate**

- The whole CAP-6 contract in one interface: deterministic, atomic, self-validating writer plus never-raises loader.
  [`pweb.assets.bundle.pas:196`](../../src/assets/pweb.assets.bundle.pas#L196)

- The ratified load predicate: protocol set membership + strict SemVer, never lexicographic.
  [`pweb.assets.bundle.pas:735`](../../src/assets/pweb.assets.bundle.pas#L735)

- Strict manifest parse: unknown/capability-like fields inert, overflow and structure abuse refused.
  [`pweb.assets.bundle.pas:373`](../../src/assets/pweb.assets.bundle.pas#L373)

**Deterministic, atomic writer**

- Validation-before-write: canonical names, D1 fold, D2 threshold, D3 secrets, reserved manifest — all pre-disk.
  [`pweb.assets.bundle.pas:957`](../../src/assets/pweb.assets.bundle.pas#L957)

- The atomic replace: MoveFileExW on Windows, bare POSIX rename elsewhere; prior output survives failure.
  [`pweb.assets.bundle.pas:1210`](../../src/assets/pweb.assets.bundle.pas#L1210)

**D1 Unicode fold — both enforcement points**

- Writer-side fold collision rejection over the pinned Unicode 10.0 tables.
  [`pweb.assets.bundle.pas:1076`](../../src/assets/pweb.assets.bundle.pas#L1076)

- Store-side fold at construction — a hand-crafted archive cannot bypass the bundler.
  [`pweb.assets.zip.pas:174`](../../src/assets/pweb.assets.zip.pas#L174)

**Release host and native refusal surface**

- Loader runs before webview_create — the structural zero-JS-before-acceptance proof.
  [`releaseapp.pas:164`](../../examples/08-release/releaseapp.pas#L164)

- Success path: CAP-4W handler over the bundle store, then navigate — never SetHtml.
  [`releaseapp.pas:240`](../../examples/08-release/releaseapp.pas#L240)

**CLI bundler**

- Wide-API deterministic walk; a mid-enumeration error fails the build, never truncates silently.
  [`pwebbundle.pas:108`](../../tools/bundler/pwebbundle.pas#L108)

- Output-inside-dist refusal and D3 classification/skip/opt-in reporting.
  [`pwebbundle.pas:317`](../../tools/bundler/pwebbundle.pas#L317)

**Gates, tests, CI**

- Golden-bytes pin: committed SHA-256 catches toolchain/dependency byte drift that self-comparison cannot.
  [`pweb.test.bundle.pas:470`](../../test/assets/pweb.test.bundle.pas#L470)

- The four mandated D1 cases, including the crafted-ZIP bundler bypass.
  [`pweb.test.bundle.pas:544`](../../test/assets/pweb.test.bundle.pas#L544)

- Loader compat and tamper matrices — every refusal proves no store exists.
  [`pweb.test.bundle.pas:749`](../../test/assets/pweb.test.bundle.pas#L749)

- Rebuild hash equality across touched mtimes and time, on a scratch copy of the dist.
  [`run_cap6_gates.ps1:74`](../../test/cap6/run_cap6_gates.ps1#L74)

- Native compat refusals end-to-end: foreign-producer protocol-2 and minRuntime bundles, no WebView.
  [`run_cap6_gates.ps1:191`](../../test/cap6/run_cap6_gates.ps1#L191)

- Appended CAP-6 CI section — every earlier step verbatim, conditional hosted smoke policy reused.
  [`ci.yml:867`](../../.github/workflows/ci.yml#L867)
