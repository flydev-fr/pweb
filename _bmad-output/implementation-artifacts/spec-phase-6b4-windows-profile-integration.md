---
title: 'CAP-6b4 — Windows profile integration: one product, three deployment modes, CAP-13 closure'
type: 'feature'
created: '2026-08-14'
status: 'in-review'
review_loop_iteration: 0
context: []
baseline_commit: '41692720e24f785819bdb9f670e626cc30d7d277'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-6b1/6b2/6b3 each ship a working profile, but they are three installers of one product with no integration: nothing records WHICH profile is installed, installing an Evergreen profile over a fixed one orphans the ~690 MB `runtime\webview2` tree forever, a failed `normal→fixed` switch was MEASURED to leave the fixed-mode binary behind with no tree (a broken install), every profile still emits the appcompat-shimmed basename `setup.exe`, and there is no single entry point that produces all three artifacts.

**Approach:** Integrate — invent no WebView2 mechanism. Ratify one product identity (one AppId, one install dir, profiles as mutually-exclusive modes) with a deterministic HKCU profile marker written by Inno's own `[Registry]` phase as the commit point; reclaim the stale Fixed tree with Inno's own `[InstallDelete]`, which runs strictly after the frozen `PrepareToInstall` Evergreen gate; reorder the fixed profile's `[Files]` so the shared release triple lands AFTER its verdict gate, making a failed switch leave the source install byte-identical; give each profile a distinct setup basename; and add one private build orchestrator plus one integration matrix that closes CAP-13.

## Boundaries & Constraints

**Always:**
- ONE product: AppId `{7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57}`, `{localappdata}\Programs\PWebRelease`, `PrivilegesRequired=lowest`, pinned ISCC 6.7.3 — unchanged and still authored once in `pwebappsetup.issi`.
- Profile marker: `HKCU\Software\PWeb\PWebRelease` value `Profile` ∈ exactly `normal | offline | fixed-runtime`, authored once from `PWEB_PROFILE`, written in `[Registry]` (after all `[Files]`, therefore after the fixed profile's verdict gate) and removed by `uninsdeletevalue`/`uninsdeletekeyifempty`. `PWEB_PROFILE` becomes REQUIRED and its value is validated at preprocess time — no silent default. Never in `app.pwb`, JS, localStorage, CWD, or inferred from "the tree exists".
- Payload ownership: `app.pwb` + `webview.dll` are byte-identical across all three profiles; `releaseapp.exe` is the same source built per mode (`-dPWEB_FIXED_RUNTIME` only for fixed); `runtime\webview2\**` is fixed-only installed payload; the Bootstrapper/Standalone are setup payload (`dontcopy`), never installed.
- Switch transactionality, all Inno-native, nothing hand-rolled: leaving fixed ⇒ frozen `PrepareToInstall` proves the target Evergreen runtime FIRST (a refusal touches zero files), then `[InstallDelete]` reclaims the tree, then payload, then the marker commits. Entering fixed ⇒ tree lands, CAP-6b3's verdict gate verifies the DEPLOYED tree (signers + ACL by SID, unchanged), then the shared triple, then the marker commits. No `DelTree`, no `RegDeleteKey`, no manual cleanup anywhere.
- Setup basenames become `PWebRelease-Normal-Setup.exe` / `PWebRelease-Offline-Setup.exe` / `PWebRelease-FixedRuntime-Setup.exe`, authored in the `.iss` (the build scripts drop `/Fsetup`); no artifact may be named `setup.exe`. `deployment.md` was verified NOT to freeze that basename.
- User data (`%APPDATA%\releaseapp.exe`, the WebView2 default) is SHARED across profiles and PRESERVED by uninstall; installer cleanup distinguishes installation payload from user data, and no uninstaller may touch it. Shared Evergreen is NEVER uninstalled by anything this repo ships.
- Prior external gates are AGGREGATED from repository evidence, never re-performed and never upgraded: CAP-6b1 clean-machine = PASS (transcript), CAP-6b2 offline VM = WAIVED, CAP-6b3 Gate B/C = WAIVED. `WAIVED` stays `WAIVED`.
- CI: one CAP-6b4 block invoking committed scripts under `test/cap6b4/` and `tools/`; no new inline PowerShell body in `ci.yml`; every prior CAP-1..6b3 step stays byte-untouched and green. Two distinct budget rules: each STEP budget must exceed the sum of the bounded waits its own script can spend — that is the real protection, because a hang caught by the step still lets the `if: failure()` diagnostics uploads run — while the JOB budget is only a backstop, held well under the 360-minute hosted ceiling and deliberately NOT chasing the step sum, since a job-level timeout cancels every remaining step including those uploads.

**Ask First:** any change to the ratified AppId, install location or install scope; any WebView2 detection/provisioning/Fixed-selection semantics; any new Microsoft artifact; a second installer technology; anything that would make a waived gate read as performed.

**Never:** no CAP-7, CAP-8, CAP-10 CLI, auto-update or code signing; no change to CAP-6b0 detector/policy, CAP-6b1/6b2 provisioning semantics, CAP-6b3 Fixed selection/identity/ACL semantics, the CAP-4W patch, any pin, `app.pwb`, the 17-entry ABI or protocol v1; no per-profile AppIds; no user-data redesign or recursive user-data deletion; no cross-profile fallback.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| I1/I2/I3 | fresh install of each profile | exit 0; marker exact; installed set exact; app → 42 (fixed also OBSERVES the pin) | — |
| S1/S2 | normal↔offline | exit 0; marker flips; no tree ever; one uninstall registration; 42 | — |
| S3/S4 | normal/offline → fixed | tree installed+verified; marker `fixed-runtime`; observed identity == pin; browser image inside the tree; 42 | — |
| S5/S6 | fixed → normal/offline | Evergreen proven first; tree GONE; marker flips; Evergreen-mode app; 42 | — |
| F1/F2 | fixed → normal/offline, provisioning helper fails | setup nonzero BEFORE any file op; fixed install byte-identical; tree intact; marker still `fixed-runtime`; app still 42 | fail closed |
| F3 | normal/offline → fixed, post-install gate fails | setup nonzero; Inno's own rollback; NO tree, NO half-install; source triple byte-identical; marker still the source | measured, not assumed |
| F4 | any failed switch | marker equals the SOURCE profile — never the target, never absent | commit is the last step |
| U1/U2/U3 | uninstall each profile | `{app}` gone, uninstall key gone, marker gone, tree gone (fixed); user data PRESERVED; Evergreen untouched | — |
| Isolation | each produced setup | normal = triple+Bootstrapper; offline = triple+Standalone; fixed = triple+tree; each excludes the other two profiles' artifacts | build fails |
| Marker drift | `PWEB_PROFILE` absent/unknown | ISCC `#error` at compile time | no silent default |

</frozen-after-approval>

## Code Map

- `tools/setup/pwebappsetup.issi:44-87` -- shared identity. `PWEB_PROFILE` default `:54-56` becomes a required+validated define; `OutputBaseFilename=setup` `:79` becomes `{#PWEB_SETUP_BASENAME}`; the release-triple `[Files]` `:82-87` MOVES OUT to a new payload include; gains `#define PWEB_RUNTIME_SUBDIR "runtime\webview2"` and the `[Registry]` marker. AppId `:65` untouched.
- `tools/setup/pwebapppayload.issi` -- NEW: the release triple `[Files]`, authored once, `#include`d at the position each profile needs (last for fixed).
- `tools/setup/pwebprovgate.issi:81-87` -- includes the identity include; add `#include "pwebapppayload.issi"` + `[InstallDelete] Type: filesandordirs; Name: "{app}\{#PWEB_RUNTIME_SUBDIR}"`. `PrepareToInstall` `:90-123` UNCHANGED — it already is the Evergreen prerequisite gate. Guards `:56-73` unchanged.
- `tools/setup/fixed.iss:107-149` -- `PWEB_PROFILE "fixed"`→`"fixed-runtime"`, add `PWEB_SETUP_BASENAME`, `DestDir` `:133` uses `{#PWEB_RUNTIME_SUBDIR}`, and `#include "pwebapppayload.issi"` moves AFTER the verdict entry `:147-149`. `FixedRuntimeGate` `:165-227` untouched.
- `tools/setup/normal.iss:20-23`, `offline.iss:30-33` -- add `PWEB_SETUP_BASENAME` only.
- `test/cap6b1/build_normal_setup.ps1:125-133,201`, `test/cap6b2/build_offline_setup.ps1:187-196,260`, `test/cap6b3/build_fixed_setup.ps1:376-388,580` -- drop `'/Fsetup'`, resolve the new basename; listing/payload proofs and `lockfacts.psd1` keys otherwise unchanged (`AbortProbeExe` `/Fabortprobe` stays).
- `test/cap6b1/run_normal_setup_gates.ps1:44,54`, `run_clean_machine_gate.ps1:11,70`, `test/cap6b2/run_offline_setup_gates.ps1:50,60`, `run_offline_clean_machine_gate.ps1:27,102`, `test/cap6b3/run_fixed_setup_gates.ps1:55,66,158-161`, `run_fixed_clean_machine_gate.ps1:13,76` -- setup path/basename only; every assertion stays as the no-regression proof. `run_fixed_setup_gates.ps1:158-161` copies into the isolated dir under the new name.
- `test/cap6b3/run_fixed_setup_gates.ps1:81-114` `Invoke-Bounded`, `:287-369` browser-image identity watch, `:408-436` broken-tree legs, `:452-491` uninstall poll -- the reusable patterns the CAP-6b4 matrix copies (the ledgered harness-duplication item stays ledgered; do not refactor five gate scripts here).
- `test/cap6b1/check_cap6b1_contracts.ps1:181-222` AppId contract (register the new matrix script), `:253-285` verdict-file contract. `test/cap6b/check_wv2min.ps1:41-56,79-85,119-127` -- register `pwebapppayload.issi` in all three sweeps.
- `.github/workflows/ci.yml:59-70` job budget 300 (sum 283); CAP-6b4 steps insert after `:1218`, before the `cap1-diagnostics` catch-all `:1220`. `:1093-1117` is the step template.
- `build/cap6b4/inno-probe/` (throwaway, gitignored) -- the ISCC 6.7.3 measurements this design rests on; results in Design Notes.
- Read-only evidence: `_bmad-output/specs/spec-pweb/deployment.md` (no `setup.exe` freeze), `deferred-work.md:52-54` (AppId/orphan finding), `:55-57` (user data), `:64-66` (appcompat), `:43-48,67-69` (gate PASS/WAIVED records).

## Tasks & Acceptance

**Execution:**
- [x] `tools/setup/pwebappsetup.issi` + `tools/setup/pwebapppayload.issi` -- require+validate `PWEB_PROFILE`, require `PWEB_SETUP_BASENAME`, author `PWEB_RUNTIME_SUBDIR` and the `[Registry]` marker, split the triple into the payload include -- one authoritative identity and marker, no silent default.
- [x] `tools/setup/pwebprovgate.issi` -- consume the payload include; add the `[InstallDelete]` tree reclaim -- kills the ~690 MB orphan, after the frozen provisioning gate.
- [x] `tools/setup/fixed.iss` + `normal.iss` + `offline.iss` -- profile names, setup basenames, and the fixed profile's payload include moved AFTER the verdict entry -- the measured fix for F3.
- [x] `test/cap6b1/build_normal_setup.ps1`, `test/cap6b2/build_offline_setup.ps1`, `test/cap6b3/build_fixed_setup.ps1` -- drop `/Fsetup`, follow the new basename -- appcompat hazard resolved at the source.
- [x] `test/cap6b1/run_normal_setup_gates.ps1`, `test/cap6b1/run_clean_machine_gate.ps1`, `test/cap6b2/run_offline_setup_gates.ps1`, `test/cap6b2/run_offline_clean_machine_gate.ps1`, `test/cap6b3/run_fixed_setup_gates.ps1`, `test/cap6b3/run_fixed_clean_machine_gate.ps1` -- basename/path only -- prior gates stay the no-regression proof.
- [x] `tools/build-windows-profiles.ps1` -- NEW private orchestrator: validate locks, build the three profiles in order, emit `dist/windows/release-index.json` (profile, filename, bytes, sha256 only); `-IndexOnly` for CI; documents the CAP-10 seam -- one entry point, and it is NOT `pweb build`.
- [x] `test/cap6b4/check_cap6b4_contracts.ps1` -- NEW: marker key/value/profile-name single-source contract, basename contract + no artifact named `setup.exe`, runtime-subdir single source, fixed `[Files]` ordering proof, no-Evergreen-uninstall-path sweep, no-user-data-deletion sweep.
- [x] `test/cap6b4/build_switch_probes.ps1` -- NEW: build the offline abort probe through the documented `PWEB_PROV_HELPER` hook (F2) and export `build/cap6b4/switchfacts.psd1` consolidating the three `lockfacts.psd1` -- one parse point for the matrix.
- [x] `test/cap6b4/run_profile_isolation.ps1` -- NEW: mechanical isolation over the three recorded ISCC listings + size envelopes + release-index integrity -- the isolation matrix.
- [x] `test/cap6b4/run_profile_matrix.ps1` -- NEW: one optimal chain covering I1–I3, S1–S6, F1–F4, U1–U3 with the ratified assertions per row, including user-data preservation and the shared-Evergreen-untouched proof -- the CAP-13 acceptance evidence.
- [x] `test/cap6b/check_wv2min.ps1` + `test/cap6b1/check_cap6b1_contracts.ps1` -- register every new source and consumer -- sweeps stay complete.
- [x] `.github/workflows/ci.yml` -- CAP-6b4 block (contracts, switch probes, isolation, matrix, orchestrator index, diagnostics) + job budget arithmetic -- hosted proof.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append: RESOLVED for the AppId/orphan and appcompat findings; the ratified user-data policy; and any measured residual -- append-only, never rewrite.

**Acceptance Criteria:**
- Given hosted CI, when the CAP-6b4 block runs, then all three artifacts build under their new basenames, isolation/install/switch/failure/uninstall matrices pass, every CAP-1..6b3 gate and freeze diff stays green, and no step installs or uninstalls the runner's Evergreen runtime.
- Given the CAP-6b3 clean-machine gate transcript is still absent, when CAP-6b4 reports, then its runtime-gate section shows CAP-6b1 PASS and CAP-6b2/6b3 WAIVED as distinct verdicts, never merged into "tested".
- Given any repository-evidence precondition were missing, when CAP-6b4 starts, then it STOPS rather than assuming closure.

## Spec Change Log

**2026-08-14 — frozen CI budget clause amended by human ratification.** The
clause required the job budget to exceed the sum of declared step budgets AND
stay under the 360-minute hosted ceiling — arithmetically impossible once the
untouchable CAP-1..6b3 steps (283 min) met the matrix's honest bounded-wait sum
(113.5 min). The alternatives were budgets below their own scripts' sums, which
breaks the other half of the rule and kills healthy runs, or a second CI job
duplicating the ~290 MB fetch, ~690 MB expansion and three ISCC compiles. The
clause now states the two rules apart: per-step budgets are the protection; the
job budget is a backstop kept under 360 so a job-level timeout never cancels the
`if: failure()` uploads. Known-bad state avoided: a job ceiling firing first and
discarding exactly the evidence needed to diagnose the hang. KEEP: the per-step
rule, and that each step budget derive from its script's declared table.

**2026-08-14 — adversarial review, all findings patched (no frozen-intent
change beyond the clause above).** Five review layers over the full diff. The
findings that changed *behaviour* rather than wording:

- **The stale-tree reclaim could delete a directory this product never
  installed.** `{app}` is user-redirectable on an interactive run, so an
  unconditional `[InstallDelete]` on `{app}\runtime\webview2` would recursively
  delete any folder that merely happened to contain that path. The reclaim is
  now gated by `PWebOwnsInstallDir` (our own uninstaller present in `{app}`),
  measured to evaluate after `PrepareToInstall` and before the first file entry.
- **The reclaim left an empty `{app}\runtime` behind forever** — the Evergreen
  install never recorded the intermediate directory, so no uninstaller removed
  it, and every gate enumerated `-Recurse -File` and could not see it. A
  `dirifempty` entry follows the leaf entry, and the matrix now asserts
  directory-level cleanliness and that `{app}` itself disappears.
- **`PWEB_SETUP_BASENAME` was guarded for absence but not value**, so
  `/DPWEB_SETUP_BASENAME=setup` compiled cleanly and emitted exactly the
  appcompat-shimmed `setup.exe` this shard exists to eliminate. Now an ISPP
  `#error` in any casing, proven by compile probe.
- **The prior-gate aggregation proved nothing.** Its distinctness check was
  computed from hardcoded expectations in the same file; it now derives each
  verdict from the ledger text it reads, and keys CAP-6b3 on a stable token plus
  the record's own `source_spec` rather than a prose fragment.
- **Evergreen installs were bounded at 60 s** against a provisioning helper
  whose ratified internal wait is 900 s — on any machine that actually
  provisions, a correct setup would have been killed and reported as a defect.
  Phase 0 now asserts a usable Evergreen runtime as a precondition (so no setup
  in the chain can provision) and uses CAP-6b1's ratified 300 s.
- **A failed switch out of `normal` was never exercised** — F3 ran only from
  `offline` while three comments claimed `normal → fixed`. Row F3b added.
- **Failed-switch rows asserted only a nonzero exit**, not that the rollback was
  Inno's own; they now assert `Rolling back changes` /
  `Uninstallation process succeeded` as CAP-6b3 gate 10 does, plus
  zero file operations for the `PrepareToInstall` refusals.
- The marker prose was corrected: it is an install record for migration,
  diagnostics and tests, and explicitly NOT the reclaim's ownership signal — it
  is per-user, says nothing about which directory `{app}` points at, and the
  pre-CAP-6b4 fixed install the reclaim most needs to migrate carries none.

## Design Notes

**Measured with the pinned ISCC 6.7.3** (`build/cap6b4/inno-probe/`, throwaway, distinct AppId/dir/registry key, gitignored). The design rests on these observations, not on assumption:

| probe | result |
|---|---|
| `[InstallDelete]` of the tree, over an install that has one | tree gone, exit 0, and `PrepareToInstall` ran BEFORE it (logged `tree present at PrepareToInstall = 1`) |
| `[Registry]` marker | written after `[Files]`, flips per profile, removed by uninstall together with its parent key |
| `PrepareToInstall` refusal over an installed profile | exit 7, **zero** file operations — payload, tree, marker, uninstall registration all untouched |
| failed gate, common payload BEFORE it (today's order) | exit 5, Inno rollback removes the tree — but the pre-existing common payload stays OVERWRITTEN with the target profile's copy |
| failed gate, common payload AFTER it (ratified order) | exit 5, Inno rollback removes the tree, and the source install's payload/marker/registration are **byte-identical to pre-switch** |

That fourth row is the whole reason the fixed profile's `[Files]` order changes: with it, a failed `normal→fixed` switch would leave a fixed-mode `releaseapp.exe` with no runtime tree and a marker still reading `normal` — exactly the mixed, broken install the failure matrix exists to forbid. The gate's own guarantee is unweakened: it still runs after the entire runtime tree has landed, which is the only thing it verifies.

**Measured residual**, stated in full in the `[InstallDelete]` header of `tools/setup/pwebprovgate.issi` and ledgered in `deferred-work.md`: leaving fixed, the tree is reclaimed before the marker commits, so a later failure in that same run leaves a stale marker — never the dangerous class, because the surviving binary is Evergreen-mode and its runtime was already proven usable.

## Verification

**Commands:**
- `pwsh -File test/cap6b4/check_cap6b4_contracts.ps1` -- marker/basename/subdir/ordering contracts and both sweeps PASS.
- `pwsh -File tools/build-windows-profiles.ps1` -- three profiles build under the new basenames; `dist/windows/release-index.json` written.
- `pwsh -File test/cap6b4/run_profile_isolation.ps1` -- payload isolation exact for all three.
- `pwsh -File test/cap6b4/build_switch_probes.ps1` then `run_profile_matrix.ps1` -- I1–I3, S1–S6, F1–F4, U1–U3 PASS.
- `pwsh -File test/cap6b1/run_normal_setup_gates.ps1`, `test/cap6b2/run_offline_setup_gates.ps1`, `test/cap6b3/run_fixed_setup_gates.ps1` -- unchanged verdicts after the include/basename changes.
- `pwsh -File test/cap6b/check_wv2min.ps1`, `test/cap6b1/check_cap6b1_contracts.ps1`, `test/cap6b/check_wv2lock.ps1` -- sweeps and contracts PASS.
- CI on branch -- CAP-6b4 block green, all prior gates green, freeze diffs clean.

**Manual checks (if no CLI):**
- `deferred-work.md` shows CAP-6b2/6b3 gates still as WAIVED, distinct from CAP-6b1's PASS.

## Suggested Review Order

**Product and profile identity**

- Entry point: the marker is the commit point, and the prose says exactly what it is and is not
  [`pwebappsetup.issi:175`](../../tools/setup/pwebappsetup.issi#L175)

- `PWEB_PROFILE` required and validated case-sensitively — a default would stamp a wrong mode on a user's machine
  [`pwebappsetup.issi:113`](../../tools/setup/pwebappsetup.issi#L113)

- The basename guard that closes the appcompat hazard in any casing
  [`pwebappsetup.issi:128`](../../tools/setup/pwebappsetup.issi#L128)

- The one runtime-subdir literal both the fixed profile and the reclaim derive from
  [`pwebappsetup.issi:151`](../../tools/setup/pwebappsetup.issi#L151)

**Profile switching — the whole design in two files**

- The stale-tree reclaim: Inno's own machinery, ordering as the safety property, residual stated not implied
  [`pwebprovgate.issi:95`](../../tools/setup/pwebprovgate.issi#L95)

- Ownership gate — `{app}` is user-redirectable, so the reclaim proves it is our install first
  [`pwebprovgate.issi:169`](../../tools/setup/pwebprovgate.issi#L169)

- The measured fix: the shared triple lands AFTER the verdict gate, so a failed switch is byte-identical
  [`fixed.iss:183`](../../tools/setup/fixed.iss#L183)

- The gate entry it now follows — unchanged CAP-6b3 semantics, verifying the fully-landed tree
  [`fixed.iss:166`](../../tools/setup/fixed.iss#L166)

- The release triple, authored once, positioned by whichever profile includes it
  [`pwebapppayload.issi:56`](../../tools/setup/pwebapppayload.issi#L56)

**Acceptance evidence**

- The switch/failure/uninstall chain: every row asserts marker, payload, tree and registration
  [`run_profile_matrix.ps1:304`](../../test/cap6b4/run_profile_matrix.ps1#L304)

- A failed switch must leave the source install byte-identical — the assertion F3/F3b turn on
  [`run_profile_matrix.ps1:214`](../../test/cap6b4/run_profile_matrix.ps1#L214)

- Tree reclaim proven at directory level, so an empty leftover cannot read as clean
  [`run_profile_matrix.ps1:235`](../../test/cap6b4/run_profile_matrix.ps1#L235)

- Prior gates AGGREGATED from the ledger, verdicts derived from what was read — never upgraded
  [`check_cap6b4_contracts.ps1:567`](../../test/cap6b4/check_cap6b4_contracts.ps1#L567)

- The `[Files]` order proof, computed over directives so a comment cannot invert it
  [`check_cap6b4_contracts.ps1:431`](../../test/cap6b4/check_cap6b4_contracts.ps1#L431)

- Payload exclusivity per profile, by full relative path
  [`run_profile_isolation.ps1:117`](../../test/cap6b4/run_profile_isolation.ps1#L117)

**Peripherals**

- The private orchestrator and the CAP-10 seam it documents — not `pweb build`
  [`build-windows-profiles.ps1:142`](../../tools/build-windows-profiles.ps1#L142)

- The offline abort probe, built through the documented test hook only
  [`build_switch_probes.ps1:88`](../../test/cap6b4/build_switch_probes.ps1#L88)

- The re-ratified Evergreen Bootstrapper pin, superseded digest recorded
  [`webview2-runtime.lock:52`](../../webview2-runtime.lock#L52)
