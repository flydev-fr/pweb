---
title: 'CAP-6b2 — Windows offline profile: Evergreen Standalone Installer provisioning'
type: 'feature'
created: '2026-08-13'
status: 'done'
review_loop_iteration: 0
context: []
baseline_commit: '63685b643c2bd28bedb1c8c43380ede0ac9b1db3'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-6b1's normal profile needs the network (Bootstrapper downloads the runtime), so a WebView2-less offline machine still has no install path; and the deferred large-artifact hashing item blocks verifying the ~210 MB Standalone Installer without loading it whole into memory.

**Approach:** Ratify the x64 Evergreen Standalone Installer (bytes acquired 2026-08-13) as a second `webview2-runtime.lock` artifact; build a per-user offline `setup.exe` that **embeds** it; the unchanged CAP-6b1 helper runs detect → verify (SHA-256 + Authenticode) → bounded silent execute → mandatory re-probe. The only provisioning difference vs normal is the embedded artifact. Convert the shared `PWebWv2FileSha256` to streaming (bounded memory) for both artifacts. Target-side network paths: zero, fail closed, never fall back online.

## Boundaries & Constraints

**Always:**
- Reuse unchanged: CAP-6b0 detector/threshold(1587)/decide/confirm; CAP-6b1 `PWebWv2ProvisionRun` orchestration, `pwebwv2prov` helper CLI, TOCTOU share-read guard, 900 s bound + kill, exit-code-is-observational rule, Authenticode policy (`Valid` AND leaf subject exactly `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` — verified matching the real Standalone artifact 2026-08-13), args `/silent /install` (distribution doc offline section, retrieved 2026-08-13), per-user `{localappdata}\Programs\PWebRelease` `PrivilegesRequired=lowest`, pinned ISCC 6.7.3, release triple payload. Runtime auto-promotion to per-machine is NOT a failure.
- Lock entry uses the frozen schema as-is: `kind = standalone` (frozen enum value; logical name `evergreen-standalone-x64` carries the concept), full facts + `authenticode-subject`; upstream drift ⇒ **build fails**, delete-on-mismatch; refresh stays manual; no "latest accepted automatically".
- Streaming hash: `PWebWv2FileSha256` keeps its exact signature and seam; internals become `TSha256` Init/Update/Final over a fixed buffer (`mormot.crypt.core`, already in uses — no new `-Fu` units); bootstrapper and standalone share it; FIPS `abc` vector retained + multi-chunk large-fixture proof; empty-file fail-closed unchanged.
- Anti-fork: extract the provisioning-gate `[Code]` + define validation of `normal.iss` into a shared include consumed by both `normal.iss` and new `offline.iss` behind a neutral define; `build_normal_setup.ps1` interface untouched; CAP-6b1 gates must stay green as the no-regression proof.
- Offline hard invariant: the offline artifact contains **no Bootstrapper**, no Fixed Runtime tree, no loose frontend files, and no target-side network path (no download primitive in any production 6b2 source; lock URLs are build metadata, not target code). Provisioning failure ⇒ setup fails; never "try the Bootstrapper".
- Payload proof at build time: capture the ISCC compile listing and assert the exact embedded file set (standalone present by locked filename, bootstrapper absent); staged payload re-hashed against the lock before embedding; record final setup size (≥ standalone size; no size-optimization target).
- Packaged independence: gates install from an isolated directory containing only `setup.exe` (no repo/CWD/cache dependence).
- Fail closed exactly as 6b1: initial `detection_error`, digest/signature failure, missing payload, process-create failure, timeout, re-probe unusable/absent/<1587 — all abort before any file installs.
- CI never executes any runtime installer; hosted proof is the skip path; the standalone fetch-verify is a dedicated bounded build-side step; CAP-6b0/6b1 blocks and all freeze checks remain untouched and green.

**Ask First:** executing the Standalone Installer outside the ratified setup flow; changing ratified lock bytes; any Microsoft binary download beyond the two locked artifacts; any signer-policy deviation (present certificate evidence and STOP).

**Never:** no online/Bootstrapper behavior in the offline profile, no Fixed Runtime (6b3), no 6b4 integration, no ARM64/x86, no CAP-10 CLI, no code signing of setup.exe, no auto-update, no elevation to force runtime placement, no second signer policy, no change to CAP-6b0 semantics, CAP-6b1 normal-profile behavior, pins, `app.pwb`, or protocol v1; never weaken the Bootstrapper verification path.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| O1/O14 usable runtime | detect ⇒ AlreadyUsable | standalone never extracted/executed; install proceeds | shared core (N1) |
| O2 absent runtime | ProvisionRequired; exec once exit 0; re-probe usable | success | shared core (N2) |
| O3 old runtime (<1587) | ProvisionRequired; re-probe usable | success | shared core (N3) |
| O4 exit 0, re-probe unusable | injected | setup FAILS | re-probe outranks exit (N4) |
| O5 exit nonzero, re-probe usable | injected | frozen `PWebWv2ConfirmPostInstall` verdict | no 6b2 special case (N5) |
| O6 initial detection_error | injected | never executed; FAIL | shared core (N6) |
| O7 SHA mismatch | tampered payload | never executed; FAIL | + V-leg over real standalone |
| O8 Authenticode mismatch | bad signer/unsigned | never executed; FAIL | + V-legs |
| O9 missing standalone payload | absent file | FAIL, nothing installed | GUARD + abort flow |
| O10 child timeout | hung installer | kill + FAIL | shared core (N10) |
| O11 re-probe build <1587 | injected | FAIL | shared core (N12) |
| O12/O13 no-network / no fallback | offline artifact | zero network paths: static sweep + payload listing + VM harness refuses PASS when network active | new gates |
| S1 streaming digest | multi-chunk fixture + 210 MB artifact | bounded memory; digest == `Get-FileHash` | mismatch still deletes/rejects |

</frozen-after-approval>

## Code Map

- `webview2-runtime.lock:22-69` -- frozen schema (already accepts `kind = standalone`, `arch = x64`, `authenticode-subject`); ratification-comment convention `:51-61`; append the new entry after `:69`. Zero schema change.
- `tools/get-webview2-runtime.ps1` -- reuse as-is: `-Artifact <name>` selection `:308-314`, fetch-verify sha→size→authenticode delete-on-mismatch `:249-298`, `-Refresh` `:316-348`; cross-artifact duplicate-filename rule `:214-223` (ok: different filenames).
- `src/platform/windows/pweb.platform.webview2.provision.pas:228-260` -- `PWebWv2FileSha256` in-memory (`StringFromFile:242`, one-shot `Sha256:250`) → streaming; seam `:146-147,181-195` unchanged; `PWebWv2ProvisionRun:681-830` already artifact-generic (args const `:79` used `:779` — same `/silent /install`, keep name+value; test pins it `pweb.test.wv2provision.pas:497`). `TSha256` Init/Update/Final at `deps/mormot2/src/crypt/mormot.crypt.core.pas:2082-2096`.
- `tools/setup/pwebwv2prov.pas` -- helper reused byte-identical (CLI `:13-58` fully artifact-generic).
- `tools/setup/normal.iss` -- `[Code]` gate `:90-124`, define validation `:41-61`, dontcopy embed model `:80-88`, `[Setup]` identity/scope `:63-78` (same `AppId`, same app) → extract shared include; `offline.iss` sibling consumes it.
- `test/cap6b1/build_normal_setup.ps1` -- template for `test/cap6b2/build_offline_setup.ps1`: ISCC pin `:47-50`, `-Artifact` fetch `:53-57`, lock re-parse `:62-82`, timeout cross-check `:86-94`, staging + re-hash `:107-120`, ISCC `/D` invocation `:123-133`, `lockfacts.psd1` `:195-205`.
- `test/cap6b1/run_normal_setup_gates.ps1` -- template for offline gates: V1–V4 verify-only legs `:101-155`, skip-path Gate 1/2 `:195-232`, installed exact-set `:234-252`, smoke `:254-273` (marker `run_cap6_smoke.ps1:19`), uninstall `:275-310`.
- `test/cap6b1/run_clean_machine_gate.ps1` -- upgrade base for the offline VM harness (transcript grammar `:39-48`); add network-adapter evidence + PASS-refusal when network active.
- `test/cap6b1/check_cap6b1_contracts.ps1:33-36` -- add new gate scripts to `WV2PROV_*` consumers; `test/cap6b/check_wv2min.ps1:41-49` -- add new sources to the no-URL sweep.
- `test/cap6b/check_wv2lock.ps1:295-313` -- `New-ArtifactFixture` template for standalone fixture legs; real-lock validation `:71-85` now proves two artifacts.
- `.github/workflows/ci.yml` -- CAP-6b2 block appends after `:1055` (6b1 block `:972-1055` is the template); job `timeout-minutes: 30` at `:59` needs headroom for the ~210 MB fetch; 6b0/6b1 steps untouched.
- Microsoft facts: distribution doc (retrieved 2026-08-13) — offline deployment uses `MicrosoftEdgeWebView2RuntimeInstaller{X64/X86/ARM64}.exe /silent /install`; non-elevated ⇒ per-user with documented auto-promotion; exit codes undocumented; no published hashes. Artifact facts in Design Notes.

## Tasks & Acceptance

**Execution:**
- [x] `webview2-runtime.lock` -- append ratified `evergreen-standalone-x64` entry (Design Notes facts) with ratification comment -- second real pin.
- [x] `test/cap6b/check_wv2lock.ps1` -- fixture legs: standalone-kind entry parse + fetch-verify; real-lock validation asserts both artifacts -- lock side of O7/O8.
- [x] `src/platform/windows/pweb.platform.webview2.provision.pas` -- streaming `PWebWv2FileSha256` (fixed buffer, `TSha256`, signature/seam unchanged); header prose updated to cover both artifacts -- closes deferred item.
- [x] `test/platform/pweb.test.wv2provision.pas` -- streaming cases: multi-chunk deterministic fixture (>2 buffer lengths, digest cross-checked), FIPS vector retained, empty/missing-file legs unchanged -- S1.
- [x] `tools/setup/pwebprovgate.issi` + `tools/setup/normal.iss` -- extract shared provisioning-gate include behind neutral define; normal.iss maps its existing define; 6b1 gates prove identical behavior -- anti-fork.
- [x] `tools/setup/offline.iss` -- offline manifest: same `[Setup]` identity/scope, embeds standalone + helper `dontcopy`, consumes shared include -- the offline profile.
- [x] `test/cap6b2/build_offline_setup.ps1` -- ISCC pin, `-Artifact evergreen-standalone-x64` fetch-verify, staging re-hash, ISCC → `dist/windows/offline/setup.exe`, compile-listing payload assertions (standalone present, no bootstrapper, no fixed tree, no loose frontend), size record, `lockfacts.psd1`.
- [x] `test/cap6b2/run_offline_setup_gates.ps1` -- V1–V4 over the real standalone (V1 = streamed 210 MB accept + three-way subject equality), skip-path install **from isolated dir**, installed exact-set, smoke, uninstall, no `WV2PROV_EXEC` -- hosted proof.
- [x] `test/cap6b2/run_offline_clean_machine_gate.ps1` -- authoritative VM harness: network-adapter evidence, refuses PASS if network active during provisioning, BEFORE/SETUP/AFTER/APP transcript → 42. (Script committed; VM run remains the human gate.)
- [x] `test/cap6b1/check_cap6b1_contracts.ps1` + `test/cap6b/check_wv2min.ps1` -- register new consumers/sources in contract + no-URL sweeps.
- [x] `.github/workflows/ci.yml` -- CAP-6b2 block (bounded standalone fetch, offline build, gates, diagnostics upload); adjust job timeout headroom; 6b0/6b1 blocks byte-untouched.

**Acceptance Criteria:**
- Given hosted CI, when the CAP-6b2 block runs, then offline setup.exe builds from the pinned lock, payload listing proves standalone-present/bootstrapper-absent, all verification legs pass with streamed hashing, the skip path installs/uninstalls cleanly from an isolated dir, no runtime installer executes, and CAP-1..6b1 gates plus freeze diffs stay green.
- Given a WebView2-less machine with network disabled (VM gate), when offline setup runs, then evidence shows detector unavailable → embedded standalone executes → detector usable ≥1587 → installed app prints the 42 PASS marker, and the harness refuses PASS if network was active.
- Given any verification or provisioning failure, when offline setup runs, then it aborts before completion, leaves no installed app and no trusted-looking installer behind, and never attempts a network fallback.

## Spec Change Log

## Design Notes

**Proposed lock ratification (acquired 2026-08-13, payload inspected, NOT executed):** artifact `evergreen-standalone-x64`; kind `standalone`; arch `x64`; url `https://go.microsoft.com/fwlink/?linkid=2124701` (download-page link mechanism; verified 302 → Microsoft delivery CDN); filename `MicrosoftEdgeWebView2RuntimeInstallerX64.exe`; size `209653456`; sha256 `f8d4ab074c22a0cd136434f37c6b34dfb64ebf8a32ce42e03bd8f2a6b51a3892`; authenticode-subject = the ratified CAP-6b1 subject (verified `Valid`, same leaf cert: thumbprint `4028CAD637509D4744B17EC5B42AED8D7A31E6AF`, valid 2026-04-16→2027-04-15, issuer `Microsoft Code Signing PCA 2024` — evidence, not enforced). FileVersion resource `1.3.251.23` is the Edge Update shell, evidence only; runtime version not attributable from the EXE resource (download page displayed 151.0.4129.78 at retrieval) — `version` key omitted per frozen schema (optional for Evergreen).

**Embed vs adjacent:** embed (recommendation, mirrors ratified 6b1 embed decision): ratified bytes = shipped bytes; a lone `setup.exe` is the whole offline deliverable; Inno LZMA2 handles the size (~200 MB output; the payload is already compressed).

**CI budget:** ~210 MB fetch on hosted runners ≈ 1–3 min; dedicated step timeout + modest job-timeout bump; the lock-keyed caching idea stays deferred (`deferred-work.md:25-27`).

## Verification

**Commands:**
- `pwsh -File tools/get-webview2-runtime.ps1 -Validate` -- lock parses with two artifacts.
- `pwsh -File test/cap6b/check_wv2lock.ps1` -- fixture matrix incl. standalone legs PASS.
- suite compile + `build/test/pwebtests.exe /noenter` -- provisioning matrix + streaming cases green.
- `pwsh -File test/cap6b1/build_normal_setup.ps1` + `run_normal_setup_gates.ps1` -- normal profile unchanged after include extraction.
- `pwsh -File test/cap6b2/build_offline_setup.ps1` -- offline setup builds; payload assertions PASS.
- `pwsh -File test/cap6b2/run_offline_setup_gates.ps1` -- V-legs, isolated-dir skip path, layout, smoke, uninstall PASS.
- CI on branch -- CAP-6b2 block green, all prior gates green, freeze diffs clean.

**Manual checks (if no CLI):**
- Offline clean-machine VM gate transcript: network disabled → BEFORE unavailable → standalone executed from embedded payload → AFTER usable → installed app 42 PASS. (Outstanding human gate; CAP-6b1's equivalent is waived/outstanding per deferred-work ledger.)

## Suggested Review Order

**Shared provisioning gate (anti-fork core)**

- Entry point: neutral installer contract — one include, two profiles, zero forked flow
  [`pwebprovgate.issi:10`](../../tools/setup/pwebprovgate.issi#L10)

- PrepareToInstall gate unchanged from 6b1, now authored once behind the include
  [`pwebprovgate.issi:110`](../../tools/setup/pwebprovgate.issi#L110)

- Offline manifest is only a define mapping — the profile difference is the artifact
  [`offline.iss:27`](../../tools/setup/offline.iss#L27)

**Artifact ratification**

- Second real Microsoft pin: the evergreen-standalone-x64 entry, full facts + signer
  [`webview2-runtime.lock:85`](../../webview2-runtime.lock#L85)

**Streaming integrity**

- Streamed SHA-256: fixed 1 MiB buffer, handle-safe, closes the deferred item
  [`pweb.platform.webview2.provision.pas:283`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L283)

- Chunk-read seam pins boundedness — a whole-file revert now fails the suite
  [`pweb.platform.webview2.provision.pas:244`](../../src/platform/windows/pweb.platform.webview2.provision.pas#L244)

- S1 case: multi-chunk fixture, read-count and read-size assertions, FIPS vector kept
  [`pweb.test.wv2provision.pas:92`](../../test/platform/pweb.test.wv2provision.pas#L92)

**Offline build and payload proof**

- ISCC compile-listing assertions: standalone present, no Bootstrapper, no Fixed tree
  [`build_offline_setup.ps1:207`](../../test/cap6b2/build_offline_setup.ps1#L207)

- SetupSha recorded so the VM gate can refuse unratified transported bytes
  [`build_offline_setup.ps1:248`](../../test/cap6b2/build_offline_setup.ps1#L248)

**Hosted gates**

- Packaged independence: install from an isolated dir holding only setup.exe
  [`run_offline_setup_gates.ps1:250`](../../test/cap6b2/run_offline_setup_gates.ps1#L250)

**Clean-machine harness**

- Network polled during the provisioning interval; Up or unknowable refuses PASS
  [`run_offline_clean_machine_gate.ps1:178`](../../test/cap6b2/run_offline_clean_machine_gate.ps1#L178)

- Transported setup.exe must hash-match the recorded build before it may run
  [`run_offline_clean_machine_gate.ps1:286`](../../test/cap6b2/run_offline_clean_machine_gate.ps1#L286)

**Contracts, sweeps, CI**

- AppId authored once in the include; gate literals cross-checked against it
  [`check_cap6b1_contracts.ps1:107`](../../test/cap6b1/check_cap6b1_contracts.ps1#L107)

- No-download-primitive sweep over production sources; lock metadata stays exempt
  [`check_wv2min.ps1:89`](../../test/cap6b/check_wv2min.ps1#L89)

- CAP-6b2 CI block: bounded fetch, build, gates; 6b0/6b1 blocks byte-untouched
  [`ci.yml:1061`](../../.github/workflows/ci.yml#L1061)
