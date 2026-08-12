---
title: 'CAP-6b0 — WebView2 runtime detection and provisioning foundation'
type: 'feature'
created: '2026-08-12'
status: 'done'
review_loop_iteration: 0
context: []
baseline_commit: '039cf0aee18278de59a9e88a7e85fe69f283cea4'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The CAP-4W patched loader hard-rejects any WebView2 runtime whose build (third) version component is < 1587, but `webview_create` returns the same nil for an absent runtime, a too-old runtime, and a missing desktop session — PWeb can neither detect nor diagnose runtime state, and CAP-6b1..6b4 (Evergreen normal/offline installers, fixed-runtime, CAP-13) all need one shared foundation first.

**Approach:** Add one Windows-private detector unit (registry-based per Microsoft's documented detection, with pinned-loader parity), a fail-closed 4-part version parser and usability policy pinned to the CAP-4W minimum (build >= 1587), a provisioning decision model whose frozen invariant is *installer success is never runtime success — usability must be re-probed after install*, and a hash-locked external-artifact format/workflow for future Microsoft binaries. No installer profile is built in this shard.

## Boundaries & Constraints

**Always:**
- Detector is Windows-private code in `src/platform/windows/`; returns a structured result — `available | unavailable | detection_error` — plus, when available, the raw version string, parsed version, and source channel (HKLM/HKCU); it never raises across its boundary.
- Usability = parsed 4-part runtime version with build component >= `1587` (the CAP-4W loader minimum — one threshold, no second one). Malformed version text fails closed: never usable.
- Numeric component comparison only, never lexicographic. CI cross-checks the Pascal minimum constant against `tools/cap4w/webview2-custom-scheme.patch`.
- Policy and provisioning decisions are pure functions over injectable detector-result records (private seam — no interface type); the real OS probe is separable from them.
- Provisioning contract: Detect → `AlreadyUsable | ProvisionRequired | DetectionFailure`; after any future installer run, a mandatory re-probe must report usable, else installation fails.
- Lock format: each artifact carries logical name, distribution kind, architecture, version (when meaningful), authoritative Microsoft URL, expected filename, byte size, SHA-256. Missing or mismatched SHA-256 ⇒ hard fail and delete the download; refresh is an explicit manual workflow; URLs live only in lock files, never in swept sources.

**Ask First:**
- Installer technology (Checkpoint A) and installation scope (Checkpoint B) — ratified by human at this spec's checkpoint before implementation.
- Any download of a Microsoft binary, even a read-only hash probe.

**Never:**
- No installer profile (normal/offline/fixed-runtime), no bootstrapper or standalone-installer execution, no setup.exe, no Fixed Runtime extraction, no CAP-10 CLI.
- No eighth frozen public interface; no WebView2/COM/registry type in any frozen contract; no change to the CAP-4W patch, CAP-6 bundle/loader, protocol v1, any pin, or any frozen unit; the release layout stays exactly `app.pwb` + exe + `webview.dll` (no `WebView2Loader.dll`).
- CI never downloads or installs a runtime; the hosted runner's detected version is diagnostic evidence only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Modern runtime | version `151.0.4129.72` | available + usable | N/A |
| Exact minimum | `1.0.1587.0` | usable | N/A |
| Just below minimum | `1.0.1586.99` | present but NOT usable | distinct from absent |
| Newer than minimum | `1.0.1588.0` | usable | N/A |
| Absent | no reg value / empty / `0.0.0.0` | unavailable → ProvisionRequired | N/A |
| Malformed version | `abc`, `1.2`, `1.2.3.4.5`, garbage | not usable | fail closed, no exception |
| Detection API failure | registry access error | detection_error → DetectionFailure | no crash, no false available |
| Installer succeeded, runtime unusable | injected post-install re-probe | installation FAILED | re-probe verdict outranks exit code |
| Lock hash mismatch | fixture with wrong sha256 | fetch rejected, file deleted | error names both digests |
| Lock malformed / missing sha256 / dup key | fixtures | validator refuses | hard error with line number |

</frozen-after-approval>

## Code Map

- `tools/cap4w/webview2-custom-scheme.patch:78-79` -- source of truth for the minimum: raises loader `api_version` 1150 → **1587**. Read-only.
- `test/cap4w/cap4w_loader_boundary.cpp:40,56-70` -- `static_assert(api_version == 1587)` + reject/accept boundary triple (`1.0.1586.99`/`1.0.1587.0`/`1.0.1588.0`); model for detector boundary tests.
- `deps/webview/core/include/webview/detail/platform/windows/webview2/loader.hh:265-354` (via `tools/get-webview.ps1`) -- pinned loader discovery: HKLM→HKCU `EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` value `EBWebView` (`KEY_WOW64_32KEY`), version = last path component; compares only build component. `version.hh` = `parse_version` semantics.
- `src/platform/windows/pweb.platform.webview2.pas` -- only existing Windows unit (CAP-4W, do not modify); style reference for hand-transcribed Windows code.
- `src/assets/pweb.assets.bundle.pas:262-359` -- `PWebSemVerParse/Compare`: strict fail-closed parser style to mirror; NOT reusable (3-part only, rejects 4-part).
- `tools/get-pas2js.ps1` + `pas2js.lock` -- the lock/fetcher template: strict `key = value` parser throwing with line numbers, `^[0-9a-f]{64}$` digest shape assert, case-sensitive `-cne` compare, delete-on-mismatch, "deliberate ratification" header.
- `test/core/pwebtests.pas:20-84` -- suite registration: `uses` + published proc + `AddCase`; `{$ifdef}` inclusion precedent at :26-31.
- `test/cap6/run_cap6_gates.ps1:148-155` -- release-layout hard gate (3 files only). Read-only constraint.
- `.github/workflows/ci.yml` -- suite compile line :533-546 (add `-Fu` paths); zero-HTTP sweep list :458-484 (add new unit); CAP-6 block ends :913 → append CAP-6b0 block before generic upload :914; freeze diffs :563-594 stay untouched; platform isolation-compile model :449-453.
- `.gitignore:87-88` -- `*.txt` ignored repo-wide; any new tracked `.txt`-suffixed file needs a negation.
- `_bmad-output/specs/spec-pweb/deployment.md` -- ratified Evergreen-first policy (normal→Evergreen, offline→Standalone Evergreen, fixed=opt-in). Read-only.

## Tasks & Acceptance

**Execution:**
- [x] `src/platform/windows/pweb.platform.webview2.runtime.pas` -- new unit: 4-part version record + fail-closed parser; `PWEB_WV2_MIN_BUILD = 1587` constant; detection-result record (status/raw/parsed/channel); registry probe reading the Microsoft-documented `Clients\{F3017226-…}\pv` (HKLM 32-bit view, then HKCU) with the pinned loader's `ClientState\…\EBWebView` walk as cross-check diagnostic; pure policy fn (usable?); pure provisioning fns (decide-from-detection; confirm-post-install requiring usable re-probe). No frozen-interface exposure.
- [x] `test/platform/pweb.test.webview2runtime.pas` -- new suite case: policy/version table (full I/O matrix), injected detector outcomes, provisioning invariant (installer exit 0 + unusable re-probe = failure), real host probe smoke (never throws; logs result), malformed-input safety.
- [x] `test/core/pwebtests.pas` -- register the case (`{$ifdef OSWINDOWS}`-guarded).
- [x] `webview2-runtime.lock` -- new lock file: schema documented in header; no Microsoft artifact entries populated yet (population needs Ask-First approval).
- [x] `tools/get-webview2-runtime.ps1` -- lock parser/validator + fetch-verify (sha256 before any use, delete on mismatch, refuse artifacts without sha256) + explicit `-Refresh` mode printing computed hash/size/Authenticode subject for human ratification; never auto-writes the lock.
- [x] `test/cap6b/check_wv2lock.ps1` -- fixture-driven: valid parse, malformed line, duplicate key, missing sha256, checksum-mismatch rejection (local fixtures, zero network).
- [x] `.github/workflows/ci.yml` -- append CAP-6b0 gate block: isolation compile of the new unit; host detection smoke writing detected version to `$GITHUB_STEP_SUMMARY` (diagnostic; unavailable ⇒ SKIP not FAIL, crash ⇒ FAIL); lock validator/fixture tests; Pascal-constant-vs-patch cross-check (`1587`); failure-diagnostics upload. Amend suite compile line with new `-Fu` paths; add unit to zero-HTTP sweep.

**Acceptance Criteria:**
- Given a version below/at/above `1.0.1587.0`, when policy evaluates, then reject/accept/accept exactly matching the CAP-4W loader boundary.
- Given a present-but-old runtime, when detection+policy run, then the result is distinguishable from absent (the distinction CAP-4W could not report).
- Given an injected installer success with an unusable re-probe, when the provisioning contract evaluates, then the outcome is installation failure.
- Given a lock fixture whose payload hash differs, when fetch-verify runs, then the file is deleted and the error names expected vs actual digests.
- Given hosted CI, when CAP-6b0 gates run, then the runner's detected WebView2 version appears in the step summary as diagnostic, all prior CAP-1..6 gates stay green, and freeze diffs are clean.

## Spec Change Log

## Design Notes

**Official Microsoft facts (all retrieved 2026-08-12, learn.microsoft.com):**
- Detection: registry is documented "Approach 1" (`…\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` value `pv`, HKLM `WOW6432Node` = per-machine, HKCU = per-user; absent/empty/`0.0.0.0` = not installed), co-equal with "Approach 2" `GetAvailableCoreWebView2BrowserVersionString` (WebView2Loader.dll; `HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)` when absent; `CoTaskMemFree` ownership). [concepts/distribution]
- Version strings are 4-part `major.minor.build.patch` (+ optional channel suffix); API compatibility rule: runtime build >= SDK build; `CompareBrowserVersions` is the sanctioned numeric comparator. No dedicated "too old" HRESULT exists — old runtimes surface as `E_NOINTERFACE` at QI or loader not-found. [concepts/versioning, reference/win32/webview2-idl, release-notes/about]
- Bootstrapper `MicrosoftEdgeWebview2Setup.exe`: ~2 MB, needs network, `/silent /install`; elevated ⇒ per-machine, non-elevated ⇒ per-user (auto-promoted when a per-machine Edge Updater exists). Standalone installer `MicrosoftEdgeWebView2RuntimeInstaller{X64/X86/ARM64}.exe`: offline, same switches. **Microsoft publishes no SHA-256 for any of these** ⇒ our lock pins locally computed hashes at ratification, with Authenticode as refresh-time cross-check; a silently changed remote payload then fails verification by construction. [concepts/distribution, evergreen-vs-fixed-version]
- Rationale for registry as canonical here: PWeb never ships `WebView2Loader.dll` (release-layout gate), and the pinned loader's own fallback is the registry walk — so the documented registry check *is* loader parity; the `Clients/pv` (docs) vs `ClientState/EBWebView` (pinned loader) divergence is probed both ways, divergence reported as diagnostic.
- Fixed-runtime constraints recorded for CAP-6b3, not acted on: >250 MB versioned packages, `expand` extraction, `browserExecutableFolder`, Win10 ACL grants (`icacls` app-container SIDs), no registry key, no published hashes.

**Checkpoint A — installer technology:** none was ratified in repo (only an ASCII `setup.exe` diagram label in deployment.md:35). **RATIFIED 2026-08-12 by human: Inno Setup 6** — PascalScript fit, native setup.exe, dual-scope support, pinnable ISCC for deterministic CI. Not installed/adopted in CAP-6b0; baseline for CAP-6b1+.

**Checkpoint B — installation scope:** none was ratified in repo (zero per-user/per-machine/HKLM/elevation evidence). **RATIFIED 2026-08-12 by human: per-user** — `%LOCALAPPDATA%\Programs\<app>`, no elevation, HKCU uninstall ownership; scope fixed by the chosen profile, never inferred from runtime elevation state.

**Reconstructed baseline:** Phases 0–6 CLOSED; CAP-6 PASS at commit `5cced448861708ec94e57236d20135bf35ee7a92`, hosted CI run 31601165998 green (verified). Freeze plan: no frozen unit, pin, ABI, or CI freeze-diff baseline is modified; the new unit is additive, private, and isolation-compiled.

## Verification

**Commands:**
- `fpc -Sh -FUbuild/fpc -Fusrc/lib -Fusrc/platform/windows -FEbuild ... pweb.platform.webview2.runtime.pas` -- expected: isolation compile, zero warnings policy per CI.
- suite compile + `build/test/pwebtests.exe /noenter` -- expected: exit 0 incl. new case.
- `pwsh -File test/cap6b/check_wv2lock.ps1` -- expected: all fixture verdicts, mismatch rejected.
- `pwsh -File tools/get-webview2-runtime.ps1 -Validate` -- expected: lock parses, zero artifacts tolerated.
- CI on branch -- expected: CAP-6b0 block green, prior gates green, freeze diffs clean, detected runner version in step summary.

## Suggested Review Order

**Detector, policy, and provisioning contract**

- Entry point: the unit header ratifies detection mechanism, loader parity, precedence, and the frozen re-probe invariant
  [`pweb.platform.webview2.runtime.pas:1`](../../src/platform/windows/pweb.platform.webview2.runtime.pas#L1)

- Fail-closed 4-part parser; digit bound enforced before any arithmetic
  [`pweb.platform.webview2.runtime.pas:161`](../../src/platform/windows/pweb.platform.webview2.runtime.pas#L161)

- Usability = available AND parsed AND build >= 1587 (single CAP-4W threshold)
  [`pweb.platform.webview2.runtime.pas:176`](../../src/platform/windows/pweb.platform.webview2.runtime.pas#L176)

- Frozen invariant: re-probe verdict outranks installer exit code in both directions
  [`pweb.platform.webview2.runtime.pas:192`](../../src/platform/windows/pweb.platform.webview2.runtime.pas#L192)

- Internal test seam (public-mutable procedural variable; production never assigns)
  [`pweb.platform.webview2.runtime.pas:211`](../../src/platform/windows/pweb.platform.webview2.runtime.pas#L211)

- Real probe: documented Clients\pv walk, HKLM 32-bit view then HKCU, ClientState cross-check as diagnostic
  [`pweb.platform.webview2.runtime.pas:219`](../../src/platform/windows/pweb.platform.webview2.runtime.pas#L219)

**Artifact lock and integrity workflow**

- Lock schema and refusal-first contract (sha256 mandatory, refresh manual, microsoft.com only)
  [`webview2-runtime.lock:1`](../../webview2-runtime.lock#L1)

- Mode exclusivity guards, then strict parser and fetch-verify with delete-on-mismatch
  [`get-webview2-runtime.ps1:48`](../../tools/get-webview2-runtime.ps1#L48)

**CI gates**

- CAP-6b0 gate block: isolation compile, minimum cross-check, lock fixtures, host smoke
  [`ci.yml:918`](../../.github/workflows/ci.yml#L918)

**Tests and probes**

- Seam matrix: fake-hive precedence, sentinels, error escalation, and the pv-drift demonstration
  [`pweb.test.webview2runtime.pas:364`](../../test/platform/pweb.test.webview2runtime.pas#L364)

- 39-case lock fixture matrix incl. traversal, device names, host allowlist, refresh happy path
  [`check_wv2lock.ps1:1`](../../test/cap6b/check_wv2lock.ps1#L1)

- Patch-vs-Pascal 1587 cross-check + no-URL source proof
  [`check_wv2min.ps1:1`](../../test/cap6b/check_wv2min.ps1#L1)

- Suite registration, OSWINDOWS-guarded
  [`pwebtests.pas:76`](../../test/core/pwebtests.pas#L76)
