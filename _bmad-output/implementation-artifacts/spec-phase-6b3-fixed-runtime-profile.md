---
title: 'CAP-6b3 — Windows fixed-runtime profile: bundled WebView2 Fixed Version Runtime'
type: 'feature'
created: '2026-08-13'
status: 'done'
review_loop_iteration: 1
context: []
baseline_commit: 'e7fe7fc4908682243e5f5c17c0603f7203fac134'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-6b1/6b2 both end at an Evergreen runtime the machine owns and updates; frozen/certified/kiosk deployments need PWeb to run on a runtime *they* pin, with zero dependence on any installed Evergreen. Nothing in the stack can express that today: the CAP-4W backend hard-codes `browserExecutableFolder = nullptr`, and — proven by probe — the pinned webview's built-in loader ignores `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` entirely, so a "configured" fixed path silently runs on Evergreen instead.

**Approach:** Ratify the x64 Fixed Version Runtime `151.0.4129.78` as a third `webview2-runtime.lock` artifact (`kind = fixed`); build a per-user `dist/windows/fixed-runtime/setup.exe` that deploys the extracted tree plus the pinned SDK's `WebView2Loader.dll` as ordinary application content and runs **no** provisioning; and add one Windows-private unit that, before `webview_create`, validates the tree, preloads that loader by absolute path, and sets the override — then, after creation, proves the WebView that actually opened is the pinned runtime. Fail-closed at every step; never fall back to Evergreen.

## Boundaries & Constraints

**Always:**
- Selection is `LoadLibraryW(<abs>\WebView2Loader.dll)` **then** `SetEnvironmentVariableW('WEBVIEW2_BROWSER_EXECUTABLE_FOLDER', <abs tree>)`, both strictly before `webview_create`, both ratified at Checkpoint 1 (2026-08-13) after the env-var-only hypothesis was probed and refuted. Zero change to webview/webview, the CAP-4W patch, the 17-export ABI, or the raw Pascal binding.
- Runtime path derives from `Executable.ProgramFilePath` only — never CWD, never an env var, never `app.pwb`, never JS. Fixed mode is chosen by the `PWEB_FIXED_RUNTIME` compile define alone; without it `examples/08-release/releaseapp.pas` compiles byte-equivalently to today.
- Fixed mode owns the variable for the process: it overwrites any inherited value, is set exactly once before any WebView2 environment exists, and is never changed while a WebView lives.
- Fail-closed, no fallback: missing / partial / wrong-version / wrong-arch / inaccessible / UNC / forbidden-shape tree ⇒ typed native diagnostic and nonzero exit **before** `webview_create`. Loader preload failure, or `GetModuleHandleW('WebView2Loader.dll')` not equal to the preloaded handle, is equally fatal. Evergreen presence never rescues any of these.
- Identity is **observed, not inferred**: after `webview_create` and before `webview_navigate`, the environment's `get_BrowserVersionString` must equal the pinned version, else refuse before any content loads. This is the deterministic answer to registry-policy `BrowserExecutableFolder` redirection.
- Windows 10 AppContainer requirement (Fixed Version >= 120, unpackaged Win32) is installer behaviour: grant exactly `S-1-15-2-1` and `S-1-15-2-2` Read+Execute with `(OI)(CI)` on the tree root via native ACL APIs, then verify **by SID** — identity display names are localized and must never be parsed. No write/modify rights, no Everyone. Proven to need no elevation under the ratified per-user scope; if that ever changes, STOP rather than widen scope.
- Anti-fork: extract the neutral `[Setup]` + release-triple `[Files]` from `pwebprovgate.issi` into a shared identity include consumed by it and by `fixed.iss`; same `AppId`, same `{localappdata}\Programs\PWebRelease`, same `PrivilegesRequired=lowest`, same pinned ISCC 6.7.3. CAP-6b1/6b2 gates staying green is the no-regression proof.
- Lock uses the frozen schema as-is (`kind = fixed` + required 4-part `version` already exist); upstream drift ⇒ build fails; refresh stays manual.

**Ask First:** changing the ratified pin bytes or version; any Microsoft binary beyond the three locked artifacts; shipping any file besides the extracted tree and the pinned-SDK `WebView2Loader.dll`; any change to `pweb.lib.webview.pas`, the CAP-4W patch, or installation scope; a signer-policy deviation.

**Never:** no Evergreen/Bootstrapper/Standalone/download/registration path in this profile; no change to CAP-6b0 semantics or CAP-6b1/6b2 behaviour; no Fixed Runtime inside `app.pwb`; no second RPC or asset path; no new public `IWebView` API; no CAP-6b4 integration, CAP-10 CLI, CAP-7, CAP-4b, auto-update, servicing, code signing; no ARM64/x86; no full-tree hashing on ordinary startup.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| F1 valid tree | pinned tree beside exe | selection accepted; WebView opens on pinned runtime | — |
| F2 no Evergreen | detector unavailable | fixed app still runs; no installer invoked | VM gate |
| F3 Evergreen != pinned | Evergreen A, bundled B | observed version == B and browser process image inside the bundled tree | refuse on mismatch |
| F4 hostile inherited env var | parent sets a foreign path | process overwrites it; pinned tree used | readback assert |
| F5 registry `BrowserExecutableFolder` override | policy redirect | deterministic: observed identity != pin ⇒ refuse | post-create check |
| F6 tree missing | folder absent | typed diagnostic, nonzero exit, no `webview_create` | pre-create validation |
| F7 tree partial | `msedgewebview2.exe` or `EBWebView\x64\...` absent | same | pre-create validation |
| F8 version below CAP-4W minimum or != pin | resource version | same | strict 4-part parse, fail closed |
| F9 wrong architecture | PE machine != AMD64 | same | PE header read |
| F10 UNC / network path | `\\host\share\...`, remote drive | rejected | path-shape + drive-type check |
| F11 forbidden path shape | contains `\Edge\Application\`, device/`\\?\` form | rejected | Microsoft-documented restriction |
| F12 broken tree + usable Evergreen | deliberately corrupted tree | app FAILS; Evergreen never used | no fallback, proven |
| F13 required ACL missing | SIDs absent from tree DACL | setup aborts / startup refuses | verify by SID |
| F14 ACL applied | RX + `(OI)(CI)` present | runtime works | — |
| F15 end-to-end | valid install | `pweb://app` secure context, handshake, `Add(20,22)` = 42 | — |
| F16 payload purity | fixed setup.exe | contains neither Bootstrapper nor Standalone Installer | compile-listing assertion |

</frozen-after-approval>

## Code Map

- `webview2-runtime.lock:93+` -- append `webview2-fixed-runtime-x64`; schema unchanged (`kind = fixed` enum `:28`, `version` required for fixed at `tools/get-webview2-runtime.ps1:171-173`). Ratified facts in Design Notes.
- `test/cap6b/check_wv2lock.ps1:85-87` and `:99-104` -- **hard-fails today**: asserts exactly `2 artifact(s)` and exactly 2 `authenticode-subject` lines. Bump to 3 and add `^artifact = webview2-fixed-runtime-x64$` / `^kind = fixed$` anchors beside `:90-98`. New fixture legs append after `:632` using `New-ArtifactFixture` (`:316-334`, `-Kind 'fixed' -ExtraLines 'version = 1.2.3.4'`); refusal legs for fixed already exist at `:356-365`.
- `src/platform/windows/pweb.platform.webview2.fixed.pas` -- NEW Windows-private unit. Reuse verbatim from `pweb.platform.webview2.provision.pas`: `PWebWv2FileSha256` (`:283-364`), `PWebWv2HashChunkRead` (`:277-281`), `PWebWv2AuthenticodeCheck` (`:598-658`) + `SignerLeafSubject` (`:514-596`), `PWEB_WV2_HASH_CHUNK_BYTES` (`:105-110`). Do **not** reference `PWEB_WV2_BOOTSTRAPPER_ARGS`, `PWebWv2RunProcessBounded` (`:678-768`) or `PWebWv2ProvisionRun` (`:785-934`). Threshold from `pweb.platform.webview2.runtime.pas:84`; strict parser `PWebWv2VersionParse:250-311`. Conventions: header block before `unit`, ordinal-0 failure states, public-mutable procedural seams (`:225-244`), Win32 `external` declarations in the implementation section, `Executable.ProgramFilePath` (mormot.core.os) as the only exe-dir idiom in the repo. **First ACL code in the repo** — no house idiom exists.
- `src/platform/windows/pweb.platform.webview2.pas:126` -- turn `Stub_get_BrowserVersionString` into the real declaration and add one private helper that walks the already-proven borrowed-controller chain (`:361-384`) to return the observed version. Nothing outside fixed mode calls it.
- `examples/08-release/releaseapp.pas:161-178,251-253` -- `CheckWebView2RuntimeUsable` is the pre-create seam. Under `{$ifdef PWEB_FIXED_RUNTIME}` replace it with fixed validation+selection and add the post-create identity check between `webview_create` (`:253`) and `webview_navigate` (`:271`); `{$else}` branch stays byte-identical.
- `tools/setup/pwebappsetup.issi` -- NEW: neutral `[Setup]` + release-triple `[Files]` extracted from `pwebprovgate.issi:81-103` (AppId `:82`, DefaultDirName `:87`, `PrivilegesRequired=lowest` `:90`, x64 `:91-92`, compression `:94-95`, `OutputBaseFilename` `:96`). Optional `PWEB_COMPRESSION`/`PWEB_SOLID` overrides defaulting to today's values so normal/offline are unchanged. `pwebprovgate.issi` keeps only its provisioning `[Files]` `:106-107` and `[Code]` `:109-143` (its five `#error` guards `:52-66` make it unusable by a non-provisioning profile).
- `tools/setup/fixed.iss` -- NEW adapter (`normal.iss:17-23` / `offline.iss:27-33` shape): `PWEB_PROFILE "fixed"`, includes the identity include, adds `[Files]` for `runtime\webview2\` with `recursesubdirs createallsubdirs`, and an `[Code]` `CurStepChanged` that applies+verifies the ACL. No provisioning include, no `[Run]`, no `[Icons]`.
- `test/cap6b3/build_fixed_setup.ps1` -- from `test/cap6b2/build_offline_setup.ps1`: ISCC pin `:58-61`, lock re-parse `:69-101`, reuse-after-re-verify `:114-149`, recursive staging wipe `:165-168`, staged re-hash `:175-181`, ISCC + `Tee-Object` listing `:187-194`, `lockfacts.psd1` `:252-265`. **Invert `:228-230`** (it throws when `msedgewebview2` appears — exactly what this profile embeds), carve the runtime subtree out of the loose-frontend regex `:231-234` (the tree is full of `.js`/`.json`), and key the exact-set proof on **full relative paths**, not the unique-basename collapse at `:206-210`. Adds `expand -F:*` extraction and tree-manifest generation.
- `test/cap6b3/run_fixed_setup_gates.ps1` -- from `test/cap6b2/run_offline_setup_gates.ps1`: `Invoke-Bounded` `:72-105`, isolated-dir install `:241-283`, exact installed set `:285-312` (must grow to cover the tree), smoke `:314-333`, uninstall `:335-370`.
- `test/cap6b3/run_fixed_clean_machine_gate.ps1` -- from `test/cap6b1/run_clean_machine_gate.ps1` (transcript grammar `:42-48`); BEFORE must show Evergreen **unavailable**, and no `WV2PROV_EXEC` may ever appear.
- Registrations: `test/cap6b/check_wv2min.ps1:41-51` (no-URL) and `:72-84` (no-download-primitive) — add the new unit, `fixed.iss`, `pwebappsetup.issi`, new test unit; `test/cap6b1/check_cap6b1_contracts.ps1:48-54` (42-marker consumers), `:115-118` (AppId consumers) and `:110` (AppId now parsed from the new include); `test/core/pwebtests.pas:26-30,46-49,89-98,122-125` (suite case); `test/cap6/check_cap6_nonetwork.ps1:10-15` (releaseapp.pas already listed; fallback ban `:30-38` must still pass).
- `.github/workflows/ci.yml` -- CAP-6b3 block inserts **after `:1128`, before `:1130`** (the `cap1-diagnostics` catch-all must stay last); mirror `:1080-1128`; bump job `timeout-minutes: 45` at `:63` and its comment `:59-62`. New YAML text must avoid the floating-ref guard literals swept at `:112-139`. Freeze sweeps `:574-605` cover only the `.intf` units, `src/lib` and four frozen units — nothing CAP-6b3 touches.

## Tasks & Acceptance

**Execution:**
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append two entries: CAP-6b1 clean-machine gate **CLEARED** by the genuine `CAP6B1_CLEAN_MACHINE_PASS` transcript (2026-08-13 21:11:12Z), superseding its waiver; CAP-6b2 offline clean-machine gate **waived** by explicit user decision 2026-08-13. Append-only; never rewrite prior entries.
- [x] `webview2-runtime.lock` -- append the ratified `webview2-fixed-runtime-x64` entry with its ratification comment.
- [x] `test/cap6b/check_wv2lock.ps1` -- three-artifact real-lock assertions + `kind = fixed` happy-path/fetch-verify/selection fixture legs.
- [x] `src/platform/windows/pweb.platform.webview2.fixed.pas` -- resolve (exe-dir only), validate (existence, local non-UNC drive, forbidden shapes incl. `\Edge\Application\`, required files, strict 4-part version == pin and >= 1587, PE machine AMD64, ACL by SID), select (preload loader by absolute path, assert module identity, set + read back the variable), and a deterministic tree-manifest writer/verifier over the streamed digest. Pure functions behind injectable seams.
- [x] `test/platform/pweb.test.wv2fixed.pas` + `test/core/pwebtests.pas` -- unit cases for every pure validation branch (F6-F11, F13) with on-disk fixtures and seam restore; register the case.
- [x] `src/platform/windows/pweb.platform.webview2.pas` -- real `get_BrowserVersionString` + private observed-identity helper; no behaviour change for existing callers.
- [x] `examples/08-release/releaseapp.pas` -- `{$ifdef PWEB_FIXED_RUNTIME}` pre-create validation/selection and post-create identity refusal with typed markers; `{$else}` path untouched.
- [x] `tools/setup/pwebappsetup.issi` + `tools/setup/pwebprovgate.issi` -- extract the neutral identity include; provisioning include consumes it.
- [x] `tools/setup/fixed.iss` -- fixed profile manifest: runtime tree as deployment content, native ACL apply+verify, no provisioning.
- [x] `test/cap6b3/build_fixed_setup.ps1` -- locked fetch, `expand -F:*`, tree validation + manifest, ISCC to `dist/windows/fixed-runtime/setup.exe`, full-relative-path payload assertions (tree present; Bootstrapper and Standalone Installer absent), size record, `lockfacts.psd1`.
- [x] `test/cap6b3/run_fixed_setup_gates.ps1` + `run_fixed_clean_machine_gate.ps1` -- isolated-dir install, installed layout, ACL-by-SID verification, observed-identity smoke to 42, broken-tree no-fallback negative leg, uninstall; authoritative VM harness.
- [x] `test/cap6b/check_wv2min.ps1` + `test/cap6b1/check_cap6b1_contracts.ps1` -- register every new source/gate/AppId consumer.
- [x] `.github/workflows/ci.yml` -- CAP-6b3 block with bounded fetch, extraction, manifest validation, build, gates, diagnostics; job timeout headroom; 6b0/6b1/6b2 blocks byte-untouched.

**Acceptance Criteria:**
- Given hosted CI, when the CAP-6b3 block runs, then the fixed setup builds from the pinned lock, the payload listing proves the runtime tree present and both Evergreen installers absent, the fixed-selection unit tests pass, the installed layout and ACL verify by SID, and every CAP-1..6b2 gate plus all freeze diffs stay green.
- Given a machine with a usable Evergreen runtime, when the installed fixed app launches, then the observed environment version equals the pinned runtime and the browser process image lies inside the bundled tree; and when that tree is deliberately broken, the app fails before `webview_create` and never opens on Evergreen.
- Given any validation failure, when the fixed app starts, then it emits a typed native diagnostic, exits nonzero, creates no browser window, and performs no network activity of any kind.

## Spec Change Log

**2026-08-14 — adversarial review round 1, all findings patched (no
frozen-intent change).** Twenty-one findings, all applied. The ones that
changed *behaviour* rather than wording:

- **ACL verification was incomplete.** Only the two AppContainer SIDs were
  mask-checked, so any *other* trustee could hold write on the tree and
  verification still passed — the test's own baseline (`AU:(OICI)(FA)`)
  proved it. Verification now refuses an allow-ACE granting any
  write/modify/delete bit to a **broad** trustee (`S-1-1-0`, `S-1-5-11`,
  `S-1-5-32-545`, `S-1-5-4`); the owner, SYSTEM and Administrators keep
  write, which a per-user install requires. The test baseline moved to
  OWNER RIGHTS (`OW`), and broad-write refusal is now a proven case.
- **"No Everyone" narrowed to "no Everyone *write*".** A benign inherited
  Everyone-read ACE — common on managed images — used to abort setup and
  permanently block startup. Diagnostics now name each ACE's
  inherited-vs-explicit origin.
- **Unhandled ACE types are refused, not skipped**, and an
  `INHERIT_ONLY_ACE` no longer counts as satisfying the grant.
- **Reparse-point roots are refused** (`wv2fsPathShape`), matching the
  manifest walk's existing refusal below the root.
- **Every versioned tree binary is pinned**, not just `msedgewebview2.exe`:
  a tree mixing the pinned browser image with a foreign `msedge.dll` or
  `EmbeddedBrowserWebView.dll` is now refused, with a mixed-tree test case.
- **Validation order fixed** so an absent bundle reports `tree_missing`
  (F6) rather than `drive` (F10) — the gates key on those step texts.
- **The observed-identity refusal is a typed verdict** carrying
  `wv2fsIdentity`, so the post-create marker uses the same `status=/step=`
  grammar as every pre-create refusal, and the marker is now registered in
  the contract gate.
- **The signer axis is enforced at install time**, natively: the setup's
  post-install gate verifies the five critical binaries that *landed*
  against the ratified leaf subject before granting the ACL. The header's
  claim about reusing `PWebWv2AuthenticodeCheck` is now true, and the
  header states exactly where each axis is enforced.
- **The fail-closed abort chain is proven, not asserted in a comment**: the
  build produces an abort-probe setup through the documented
  `PWEB_ACL_HELPER` hook, and a gate leg runs it. Building that leg
  *measured* Inno 6.7.3 rather than assuming it, and found a real product
  defect: an exception raised in `CurStepChanged(ssPostInstall)` is **not**
  a rollback and does **not** make `setup.exe` exit nonzero — by then every
  file is copied, the per-user uninstall key is written, and the log says
  "Installation process succeeded". A failed verification would therefore
  have left an entry in Programs & Features pointing at a directory the
  profile had just deleted. The failure branch now undoes the installation
  itself — `{app}` **and** the HKCU uninstall key (the key path derived
  from the shared `AppId` at run time, never duplicated) — and the gate
  asserts that resulting state rather than an exit code Inno never
  produces.
- **Gate 7 can no longer absorb a defect as a SKIP**: a nil
  `webview_create` in fixed mode is only a SKIP once the Evergreen control
  host has failed the same way on the same machine.
- **The build-side version assertion runs through the helper**, so build and
  runtime read the numeric `VS_FIXEDFILEINFO` through one code path.
- `--pin` and `--validate` now use distinct line prefixes and keys so a
  compiled-in constant can never be grepped as an observed fact; `--validate`
  is wired into a gate leg; the clean-machine gate's post-kill wait is
  bounded; CI step budgets exceed their scripts' internal sums and the job
  budget exceeds the sum of the steps.

The `AceCount - 1` "underflow" was reviewed and **rejected**: `AceCount` is a
`Word`, so an empty DACL simply skips the loop and lands on the
"both SIDs required" refusal. Only its wording changed — it now names the
ACE count so an empty DACL reads truthfully.

**2026-08-14 — implementation notes (no frozen-intent change).** Three
mechanism decisions were made while implementing the Code Map; each stays
inside the ratified boundaries and is recorded here rather than silently:

1. **`tools/setup/pwebwv2fixed.pas` (new compiled helper).** The Code Map put
   the ACL apply/verify in the new Pascal unit and the `CurStepChanged` gate in
   `fixed.iss`. Inno's PascalScript cannot bridge the two: it has no pointer
   arithmetic, so a DACL cannot be walked (and therefore *verified by SID*)
   there at all. The installer therefore reaches the ratified native code
   through a compiled console helper — exactly the `pwebwv2prov.exe` idiom the
   provisioning profiles already use. It is embedded `Flags: dontcopy`,
   extracted to `{tmp}`, never installed (gate 4 proves it never lands in
   `{app}`), and the gates reuse it for ACL-by-SID, manifest and Evergreen-
   detect observations. Zero ACL logic exists outside
   `pweb.platform.webview2.fixed.pas`.
2. **Tree manifest is a build/gate artifact, never installed and never hashed
   at startup.** The writer/verifier live in the unit as ratified; the build
   writes `build/cap6b3/tree.manifest` and self-verifies it, and the gates
   re-verify the *installed* tree against it. Ordinary startup validates
   shape/version/architecture/ACL only, honouring "no full-tree hashing on
   ordinary startup".
3. **Directory enumeration uses the wide Win32 API directly** (the ratified
   `pwebbundle`/`TFolderAssetStore` precedent). The RTL Ansi `FindFirst` layer
   was observed returning `ERROR_PATH_NOT_FOUND` for a perfectly valid path in
   this unit's link context — the exact codepage-state hazard that precedent
   documents — so the manifest walk goes straight to
   `FindFirstFileW`/`FindNextFileW`, refuses reparse points, and fails loudly
   on any mid-enumeration error instead of truncating.

Profile-scoped compression measured locally: `lzma2/fast` + `SolidCompression=no`
compiles the ~690 MB tree in **23 s** of ISCC wall time and yields a 276 MB
`setup.exe`. The shared `lzma2`/solid defaults are untouched, so CAP-6b1/6b2
compile byte-identically.

## Design Notes

**Ratified pin (Checkpoint 1, 2026-08-13; acquired, extracted and inspected, never executed):** artifact `webview2-fixed-runtime-x64`; kind `fixed`; arch `x64`; version `151.0.4129.78`; url `https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/355004fc-ebbc-42d3-b319-d43be39f8d39/Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64.cab`; filename `Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64.cab`; size `304135089`; sha256 `d4c8864a764bc3ff015f7b644e1f9d022ba8a73ab470447398dda0cc9e75ab92`; authenticode-subject = the ratified CAP-6b1/6b2 subject (container verified `Valid`). Extracts under `expand -F:*` to one folder `Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64` — 256 files, 689 841 950 bytes — containing `msedgewebview2.exe`, `msedge.dll` and `EBWebView\x64\EmbeddedBrowserWebView.dll`, all FileVersion `151.0.4129.78`. **The package ships no `WebView2Loader.dll`**, hence the pinned-SDK one.

**Signer policy for the tree:** the critical binaries (`msedgewebview2.exe`, `msedge.dll`, `msedge_elf.dll`, `EBWebView\x64\EmbeddedBrowserWebView.dll`, `WebView2Loader.dll`) are `Valid` with the exact ratified `CN=Microsoft Corporation, …` subject and are enforced on that axis. Eleven redistributables (CRT, `d3dcompiler_47`, `dxil`, `mspdf`, `widevinecdm`) legitimately carry `CN=Microsoft Windows, O=Microsoft Corporation, …`; that second Microsoft subject is accepted for non-critical files and recorded as evidence.

**Probe evidence backing the seam** (`build/cap6b3/probe/`, throwaway, gitignored): with Evergreen 151.0.4129.78 installed and a bundled 150.0.4078.105 tree — env-var-only ⇒ observed 151.0.4129.78 from `…\EdgeWebView\Application\…` (silent Evergreen use); preload + env-var ⇒ observed 150.0.4078.105 and browser process image inside the bundled tree, with `secure:true`, handshake and 42. Missing / empty / partial trees each ⇒ `webview_create` nil, never Evergreen.

**Installed layout:** `{app}\releaseapp.exe`, `app.pwb`, `webview.dll`, `runtime\webview2\WebView2Loader.dll`, `runtime\webview2\Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64\…`. The loader lives inside the runtime folder so it can only ever be loaded by explicit absolute path, never by DLL search order.

**Compression:** the tree is ~690 MB uncompressed; measure ISCC wall time locally before fixing the CI step budget, and use the profile-scoped compression override rather than changing the shared defaults.

## Verification

**Commands:**
- `pwsh -File tools/get-webview2-runtime.ps1 -Validate` -- lock parses with three artifacts.
- `pwsh -File test/cap6b/check_wv2lock.ps1` -- fixture matrix incl. fixed legs PASS.
- `pwsh -File test/cap6b/check_wv2min.ps1` -- no-URL / no-download sweeps cover the new sources.
- suite compile + `build/test/pwebtests.exe /noenter` -- fixed validation matrix green.
- `pwsh -File test/cap6b3/build_fixed_setup.ps1` -- setup builds; payload assertions PASS.
- `pwsh -File test/cap6b3/run_fixed_setup_gates.ps1` -- install, layout, ACL-by-SID, observed identity, 42, no-fallback negative leg, uninstall PASS.
- `pwsh -File test/cap6b1/run_normal_setup_gates.ps1` and `test/cap6b2/run_offline_setup_gates.ps1` -- unchanged after the include extraction.
- CI on branch -- CAP-6b3 block green, all prior gates green, freeze diffs clean.

**Manual checks (if no CLI):**
- Fixed clean-machine VM transcript: detector unavailable -> no installer executed -> app launches on the bundled runtime -> observed version == pin -> 42 PASS.

## Suggested Review Order

**Runtime selection (the entry point)**

- The whole design in one call: validate, preload the loader, set the override — all before `webview_create`
  [`pweb.platform.webview2.fixed.pas:1900`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L1900)

- The pin that everything else compares against; a changed package needs re-ratification
  [`pweb.platform.webview2.fixed.pas:130`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L130)

- Runtime root derives from the executable path only — never CWD, never an env var
  [`pweb.platform.webview2.fixed.pas:635`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L635)

- The fail-closed validation ladder: shape, drive, files, version, architecture, ACL
  [`pweb.platform.webview2.fixed.pas:1630`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L1630)

**Observed identity — the answer to registry redirection**

- Identity is asked of the environment that actually opened, not inferred from the path
  [`pweb.platform.webview2.pas:288`](../../src/platform/windows/pweb.platform.webview2.pas#L288)

- The stub slot became its real declaration; the vtable index is unchanged
  [`pweb.platform.webview2.pas:144`](../../src/platform/windows/pweb.platform.webview2.pas#L144)

- Post-create refusal lands between `webview_create` and `webview_navigate`
  [`pweb.platform.webview2.fixed.pas:1908`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L1908)

**Windows 10 AppContainer ACL — the first ACL code in this repo**

- Grants only Read+Execute with `(OI)(CI)` to the two documented SIDs
  [`pweb.platform.webview2.fixed.pas:1041`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L1041)

- Verification walks the DACL by SID: broad-write trustees and unknown ACE types fail closed
  [`pweb.platform.webview2.fixed.pas:1129`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L1129)

- Signer axis enforced on the installed critical binaries, before the grant
  [`pweb.platform.webview2.fixed.pas:939`](../../src/platform/windows/pweb.platform.webview2.fixed.pas#L939)

**Profile selection and installer**

- One compile define picks the profile; no deployment content can flip it
  [`releaseapp.pas:167`](../../examples/08-release/releaseapp.pas#L167)

- Application identity authored once, now shared by all three profiles
  [`pwebappsetup.issi:1`](../../tools/setup/pwebappsetup.issi#L1)

- Runtime tree ships as ordinary deployment content — no provisioning include at all
  [`fixed.iss:96`](../../tools/setup/fixed.iss#L96)

- Measured: an `ssPostInstall` exception is not an Inno rollback, so the gate undoes the install itself
  [`fixed.iss:124`](../../tools/setup/fixed.iss#L124)

**Build-time integrity**

- Signer axis over the critical binaries before anything is packaged
  [`build_fixed_setup.ps1:322`](../../test/cap6b3/build_fixed_setup.ps1#L322)

- Payload proved by full relative path; both Evergreen installers must be absent
  [`build_fixed_setup.ps1:42`](../../test/cap6b3/build_fixed_setup.ps1#L42)

**No-fallback gates**

- A broken tree must fail on a host that has a usable Evergreen runtime
  [`run_fixed_setup_gates.ps1:437`](../../test/cap6b3/run_fixed_setup_gates.ps1#L437)

- SKIP only survives if the Evergreen control host fails the same way on the same machine
  [`run_fixed_setup_gates.ps1:375`](../../test/cap6b3/run_fixed_setup_gates.ps1#L375)

- The failing post-install gate must leave no app, no tree and no uninstall key
  [`run_fixed_setup_gates.ps1:540`](../../test/cap6b3/run_fixed_setup_gates.ps1#L540)

**Peripherals**

- Unit matrix over the pure validation branches, on real fixtures and real DACLs
  [`pweb.test.wv2fixed.pas:1`](../../test/platform/pweb.test.wv2fixed.pas#L1)

- The authoritative human gate; still without a transcript
  [`run_fixed_clean_machine_gate.ps1:1`](../../test/cap6b3/run_fixed_clean_machine_gate.ps1#L1)

- Third artifact, frozen schema, no floating "latest"
  [`webview2-runtime.lock:93`](../../webview2-runtime.lock#L93)
