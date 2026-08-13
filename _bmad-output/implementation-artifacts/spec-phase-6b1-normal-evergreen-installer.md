---
title: 'CAP-6b1 — Windows normal profile: Evergreen Bootstrapper provisioning installer'
type: 'feature'
created: '2026-08-13'
status: 'done'
review_loop_iteration: 0
context: []
baseline_commit: '3d8a10645b932eef9f8e877d39a7de4cc9d1dae2'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-6b0 froze detection, policy, and the artifact lock, but no installer exists: on a WebView2-less machine the CAP-6 release dies at `webview_create` nil with no diagnosis and no provisioning path.

**Approach:** Ratify the first real Microsoft artifact (Evergreen Bootstrapper, bytes acquired 2026-08-13) into `webview2-runtime.lock`; build a per-user Inno Setup 6 `normal` setup.exe that **embeds** the lock-verified Bootstrapper; a compiled Pascal helper (reusing the frozen CAP-6b0 policy functions) runs detect → verify (SHA-256 + Authenticode) → bounded silent execute → mandatory re-probe; the release app gains a native fail-early defensive check. Clean-machine provisioning proof is the authoritative VM gate.

## Boundaries & Constraints

**Always:**
- Reuse frozen CAP-6b0 functions (`PWebWv2ProvisioningDecide`, `PWebWv2ConfirmPostInstall`, `PWebWv2Detect`) — never duplicated in PascalScript; the re-probe verdict outranks the Bootstrapper exit code in both directions; Microsoft documents no exit codes (verified 2026-08-13) so exit codes are observational only.
- Embed model: the build fetches the Bootstrapper through the lock (SHA-pinned; upstream drift ⇒ **build fails**, delete-on-mismatch); before execution the setup helper re-verifies the extracted file: SHA-256 equals the ratified lock digest AND Authenticode is `Valid` with leaf subject exactly `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US`. Authenticode success never weakens SHA pinning.
- Execution: exact verified file path, no `cmd.exe`, args exactly `/silent /install` (learn.microsoft.com distribution doc, retrieved 2026-08-13), `CreateProcessW` + bounded wait (900 s), kill on timeout, capture exit code, delete temp files on failure.
- Per-user install to `%LOCALAPPDATA%\Programs\PWebRelease`; `PrivilegesRequired=lowest`; no elevation to force runtime placement. Runtime ending up per-machine (Microsoft auto-promotion) is NOT a failure: acceptance = per-user app install AND post-provision detector usable.
- Payload = the unchanged CAP-6 release triple `releaseapp.exe + app.pwb + webview.dll`; no loose frontend files; installed-layout gate mirrors the exact-set rule of `run_cap6_gates.ps1`.
- Fail closed (setup aborts before any Launch is possible): initial `detection_error`; verification failure; process-creation failure; timeout; post-probe unusable/absent/below build 1587.
- App-side: `releaseapp` runs the CAP-6b0 detector before `webview_create`; unusable ⇒ distinct stderr marker + nonzero exit; the app never downloads anything.
- CI builds and validates the real setup and fetches the locked Bootstrapper (verified), but never executes it — on the hosted runner the skip path (`AlreadyUsable`) is the proof; genuine provisioning proof comes only from the clean-machine VM gate, never mocked.

**Ask First:** executing the Bootstrapper outside the ratified setup flow; changing the ratified lock bytes; any new Microsoft binary download beyond the locked artifact.

**Never:** no offline/Standalone installer (6b2), no Fixed Runtime (6b3), no three-profile integration (6b4), no CAP-10 CLI, no code signing of setup.exe, no auto-update, no fallbacks (loose assets, browser download page, app-side download), no new frozen interface, no change to CAP-6b0 semantics, CAP-4W patch, pins, `app.pwb` format, or protocol v1.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| N1/N11 usable runtime | detect ⇒ AlreadyUsable | Bootstrapper never invoked; install proceeds | N/A |
| N2 absent runtime | ProvisionRequired; exec exit 0; re-probe usable | success | N/A |
| N3 old runtime (<1587) | ProvisionRequired; re-probe usable | success | N/A |
| N4 exit 0, re-probe unavailable | injected | setup FAILS | re-probe outranks exit code |
| N5 exit nonzero, re-probe usable | injected | frozen `PWebWv2ConfirmPostInstall` verdict (success) | no 6b1 special case |
| N6 initial detection_error | injected | Bootstrapper NOT executed; setup FAILS | fail closed |
| N7 SHA mismatch | tampered payload | never executed; setup FAILS | digests named |
| N8 wrong/missing Authenticode | correct-hash fixture, bad signer / unsigned | never executed; setup FAILS | subject + status named |
| N9 build acquisition failure/drift | upstream bytes differ | build FAILS, download deleted | lock refresh is manual |
| N10 child-process timeout | hung installer | kill + cleanup; setup FAILS | policy documented |
| N12 re-probe below 1587 | injected | setup FAILS | one threshold only |

</frozen-after-approval>

## Code Map

- `src/platform/windows/pweb.platform.webview2.runtime.pas:161,176,183,192,219` -- frozen parser/usability/decide/confirm/detect; seam `:203-211` (assign in try, restore in finally). Read-only.
- `webview2-runtime.lock:21-41` + `tools/get-webview2-runtime.ps1` -- schema; strict parser `:81-210`; fetch-verify sha-first delete-on-mismatch `:234-262`; `-Refresh` `:280-311`; microsoft.com-only `:73-77`. Artifact entry + new optional `authenticode-subject` key land here.
- `test/cap6b/check_wv2lock.ps1:280-298,411` -- `New-ArtifactFixture` pattern + PASS marker; `check_wv2min.ps1:39-43` no-URL list to extend with new Pascal sources.
- `test/platform/pweb.test.webview2runtime.pas:148-166` -- `Det`/`V` injection helpers; registration `test/core/pwebtests.pas:26-29,45-47,75-86` (OSWINDOWS-guarded).
- `examples/08-release/releaseapp.pas:35-56,158-173,223` -- uses list, bundle gate, `WebViewCheckCreated`; defensive check goes before `:223`. Sweep constraints: `test/cap6/check_cap6_nonetwork.ps1:20-22,31-32` (no URL, no `GetCurrentDir`).
- `test/cap6/build_cap6.ps1`, `run_cap6_gates.ps1:144-156` (3-file exact-set layout gate), `run_cap6_smoke.ps1:19,29-40` (PASS marker + SKIP conventions — extend SKIP patterns to recognize the new defensive marker).
- `test/cap4w/check_cap4w.ps1:60-89` -- PowerShell bounded child-process pattern. Pascal has none: new bounded `CreateProcessW` runner required.
- Authenticode prior art: only `Get-AuthenticodeSignature` at `tools/get-webview2-runtime.ps1:296`; deferred signer-pin item `deferred-work.md:19-21` closes here (lock key + WinVerifyTrust in helper).
- `.github/workflows/ci.yml` -- CAP-6b1 block appends after `:967` (CAP-6b0 block `:918-967` is the template); suite compile `:539-545`; CAP-4 sweep list `:461-475`; freeze diffs `:563-598` untouched; upload-artifact pattern `:958-967`. ISCC needs its own `innosetup.lock` + `tools/get-innosetup.ps1` (the wv2 lock refuses non-Microsoft hosts).
- Microsoft facts (learn.microsoft.com distribution doc, retrieved 2026-08-13): `MicrosoftEdgeWebview2Setup.exe /silent /install`; packaging the bootstrapper with the app is a documented option; elevated ⇒ per-machine, non-elevated ⇒ per-user with documented auto-promotion; exit codes undocumented; no published hashes; signer identity undocumented (locally observed evidence in Design Notes).

## Tasks & Acceptance

**Execution:**
- [x] `webview2-runtime.lock` -- add ratified `evergreen-bootstrapper` entry (Design Notes facts) + document optional `authenticode-subject` key -- first real pin.
- [x] `tools/get-webview2-runtime.ps1` -- parse/validate `authenticode-subject`; enforce it in fetch-verify after SHA pass -- build-time second axis.
- [x] `test/cap6b/check_wv2lock.ps1` -- fixture cases: subject key parse, wrong-subject refusal, unsigned refusal, real-lock validation -- N7/N8 build side.
- [x] `src/platform/windows/pweb.platform.webview2.provision.pas` -- new private unit: SHA-256 file digest, WinVerifyTrust + exact-subject check, bounded process runner (900 s, kill, exit capture), orchestration Detect→verify→execute→re-probe using frozen 6b0 fns; injectable seams -- testable core.
- [x] `tools/setup/pwebwv2prov.pas` -- console helper for setup: machine-parsable verdict lines, exit codes for the Inno gate; expected digest/subject arrive as arguments derived from the lock at build time.
- [x] `test/platform/pweb.test.wv2provision.pas` + `test/core/pwebtests.pas` -- N1–N12 via injected seams; register case.
- [x] `tools/setup/normal.iss` -- Inno Setup 6 per-user project: `PrivilegesRequired=lowest`, `{localappdata}\Programs\PWebRelease`, files = release triple + embedded Bootstrapper + helper to `{tmp}`; `PrepareToInstall` runs helper, failure aborts; no Launch entry.
- [x] `innosetup.lock` + `tools/get-innosetup.ps1` -- pinned ISCC 6 provisioning (sha256-verified, silent, bounded) -- pinned 6.7.3 from github.com/jrsoftware, sha256 ratified 2026-08-13.
- [x] `test/cap6b1/build_normal_setup.ps1` + `run_normal_setup_gates.ps1` -- build `dist/windows/normal/setup.exe` (gitignore `/dist/`); gates: layout exact-set, existing-runtime skip path, installed-app smoke reuse, silent uninstall clean.
- [x] `test/cap6b1/run_clean_machine_gate.ps1` -- authoritative VM procedure: BEFORE detector unavailable → setup → Bootstrapper executes → AFTER usable → installed app 42 PASS; evidence transcript format. (Script committed; the VM run itself remains the human gate.)
- [x] `examples/08-release/releaseapp.pas` + `test/cap6/run_cap6_smoke.ps1` -- defensive pre-`webview_create` check (distinct stderr marker, nonzero exit) + smoke SKIP-pattern extension.
- [x] `.github/workflows/ci.yml` -- CAP-6b1 block: compile provision unit + helper, lock/Authenticode fixture tests, ISCC fetch, real setup build, layout + skip-path + smoke gates, diagnostics upload; amend sweep/no-URL/suite-compile lists. (The Authenticode fixture cases run inside the extended CAP-6b0 lock step; the suite-compile paths already covered the new units.)

**Acceptance Criteria:**
- Given hosted CI, when CAP-6b1 gates run, then setup.exe builds from the pinned lock, all new gates pass, the Bootstrapper is never executed in CI, and CAP-1..6b0 gates plus freeze diffs stay green.
- Given a clean machine without WebView2 and with network, when normal setup runs, then the recorded evidence shows detector unavailable → verified Bootstrapper executes → detector usable → installed app prints the 42 PASS marker.
- Given any verification or provisioning failure, when setup runs, then it aborts before completion and no installed launchable app remains.

## Spec Change Log

## Design Notes

**Proposed lock ratification (acquired 2026-08-13 via `-Refresh`, payload kept, NOT executed):** artifact `evergreen-bootstrapper`; kind `bootstrapper`; arch `neutral` (bootstrapper self-selects architecture); url `https://go.microsoft.com/fwlink/p/?LinkId=2124703` (documented "Get the Link" mechanism; verified 301 → Microsoft delivery CDN); filename `MicrosoftEdgeWebview2Setup.exe`; size `1695960`; sha256 `8c4a80540b6bbcbef30a4e8c7d1ac504b6fc09db922b4acdfd85c9d5f6f1050e`; FileVersion 1.3.251.23.

**Authenticode signer policy (closes deferred item):** require signature status `Valid` AND leaf subject exactly `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` (case-sensitive ordinal). Evidence for "smallest stable": observed leaf cert valid 2026-04-16→2027-04-15 (annual renewal ⇒ thumbprint pin breaks yearly); issuer is now `Microsoft Code Signing PCA 2024` (issuer churns across years); root `Microsoft Root Certificate Authority 2011` thumb `8F43288AD272F3103B6FB1428485EA3014C0BCFE` recorded as evidence, not enforced. SHA-256 remains the primary byte-exact anchor; the signer check is an independent second axis.

**Embed vs download-at-install:** embed. Ratified bytes = executed bytes; install-time TLS/drift failures impossible; Microsoft documents packaging; the "build fails on drift" rule lands at build time where a human can re-ratify. Download-at-install is rejected for the normal profile (would make end-user installs fail on upstream drift against an unfixable pin).

**Timeout:** 900 s bounded wait, then kill + fail closed (runtime download ~150 MB on slow links; no Microsoft guidance exists).

**Clean-machine gate:** hosted runners have WebView2, so the VM gate is separate and authoritative. Windows Sandbox is the candidate disposable instance (verify WebView2 absence at gate time); otherwise a throwaway VM image. Evidence transcript is committed with the artifact; CI never claims this proof.

## Verification

**Commands:**
- `pwsh -File tools/get-webview2-runtime.ps1 -Validate` -- lock parses with the new entry and key.
- `pwsh -File test/cap6b/check_wv2lock.ps1` -- fixture matrix incl. new subject cases, all PASS.
- suite compile + `build/test/pwebtests.exe /noenter` -- N1–N12 case green.
- `pwsh -File test/cap6b1/build_normal_setup.ps1` -- fetches locked Bootstrapper, builds `dist/windows/normal/setup.exe`.
- `pwsh -File test/cap6b1/run_normal_setup_gates.ps1` -- layout, skip path, installed smoke, uninstall gates PASS.
- CI on branch -- CAP-6b1 block green, prior gates green, freeze diffs clean.

**Manual checks (if no CLI):**
- Clean-machine VM gate transcript: BEFORE unavailable / Bootstrapper executed / AFTER usable / installed app 42 PASS.

## Suggested Review Order

**Provisioning core and verification chain**

- Entry point: unit header ratifies orchestration contract, truthfulness rules, and the TOCTOU guard
  [`pweb.platform.webview2.provision.pas:1`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L1)

- Orchestration Detect → verify → execute → mandatory re-probe over the frozen CAP-6b0 policy
  [`pweb.platform.webview2.provision.pas:681`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L681)

- Share-read guard held across hash → signature → CreateProcessW: verified bytes cannot be swapped
  [`pweb.platform.webview2.provision.pas:36`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L36)

- Native WinVerifyTrust check: Valid status AND exact pinned leaf subject, never weakening SHA
  [`pweb.platform.webview2.provision.pas:494`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L494)

- CN-first subject rendering that must byte-match PowerShell's Get-AuthenticodeSignature format
  [`pweb.platform.webview2.provision.pas:410`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L410)

- Bounded runner: 900 s wait, confirmed kill, executed-unknown truthfulness on OS failures
  [`pweb.platform.webview2.provision.pas:177`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L177)

**Artifact ratification and locks**

- First real Microsoft pin: the ratified evergreen-bootstrapper entry
  [`webview2-runtime.lock:62`](../../webview2-runtime.lock#L62)

- New optional authenticode-subject key — the independent second verification axis
  [`webview2-runtime.lock:69`](../../webview2-runtime.lock#L69)

- Fetch-time subject enforcement, deliberately AFTER the SHA-256 pass
  [`get-webview2-runtime.ps1:184`](../../tools/get-webview2-runtime.ps1#L184)

- Pinned ISCC toolchain: sha256 verified before execution, stamp-file cache
  [`get-innosetup.ps1:4`](../../tools/get-innosetup.ps1#L4)

**Installer (normal profile)**

- Per-user scope: lowest privileges, %LOCALAPPDATA%\Programs\PWebRelease, no elevation
  [`normal.iss:68`](../../tools/setup/normal.iss#L68)

- PrepareToInstall runs the compiled helper; nonzero aborts before any file installs
  [`normal.iss:27`](../../tools/setup/normal.iss#L27)

- Helper CLI contract: exit codes, WV2PROV_* lines, --verify-only mode
  [`pwebwv2prov.pas:14`](../../tools/setup/pwebwv2prov.pas#L14)

- Build: lock-verified fetch → embed → ISCC; also builds the abort-probe test setup
  [`build_normal_setup.ps1:1`](../../test/cap6b1/build_normal_setup.ps1#L1)

**App-side defensive check**

- Native fail-early check before webview_create; distinct marker, nonzero exit, no downloads
  [`releaseapp.pas:161`](../../examples/08-release/releaseapp.pas#L161)

- Smoke SKIP recognizes the marker only with a nonzero exit
  [`run_cap6_smoke.ps1:33`](../../test/cap6/run_cap6_smoke.ps1#L33)

**Gates, tests, CI**

- N1–N12 matrix over injected seams, with negative proofs via call counters
  [`pweb.test.wv2provision.pas:226`](../../test/platform/pweb.test.wv2provision.pas#L226)

- Unconditional V1: native accept of the genuine bootstrapper, three-way rendering equality
  [`run_normal_setup_gates.ps1:122`](../../test/cap6b1/run_normal_setup_gates.ps1#L122)

- Gate 6 abort-probe: failing helper aborts the real setup with nothing installed
  [`run_normal_setup_gates.ps1:312`](../../test/cap6b1/run_normal_setup_gates.ps1#L312)

- Authoritative clean-machine VM procedure, evidence transcript always ends with a verdict
  [`run_clean_machine_gate.ps1:1`](../../test/cap6b1/run_clean_machine_gate.ps1#L1)

- ISCC lock fixture matrix, 15 zero-network cases
  [`check_innosetup_lock.ps1:1`](../../test/cap6b1/check_innosetup_lock.ps1#L1)

- Marker and helper-prefix contract cross-checks (house 1587 idiom)
  [`check_cap6b1_contracts.ps1:1`](../../test/cap6b1/check_cap6b1_contracts.ps1#L1)

- Lock fixtures now 46 cases including the Authenticode refusal legs
  [`check_wv2lock.ps1:1`](../../test/cap6b/check_wv2lock.ps1#L1)

- Suite registration, OSWINDOWS-guarded
  [`pwebtests.pas:97`](../../test/core/pwebtests.pas#L97)

- CI CAP-6b1 block: compiles, fixtures, real setup build, gates, diagnostics
  [`ci.yml:972`](../../.github/workflows/ci.yml#L972)
