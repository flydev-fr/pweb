---
title: 'CAP-10E — kernel-resolved executable path in every shipped host'
type: 'bugfix'
created: '2026-09-05'
status: 'in-progress'
baseline_commit: '657846d8d8d01d9deaa87d803814568aed29b2af'
review_loop_iteration: 0
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10-closure-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every shipped host locates its trusted files beside its executable through
mORMot's `Executable.ProgramFilePath`, which `mormot.core.os.pas:10008` fills from
`ExpandFileName(ParamStr(0))`. On Windows the RTL's argv is an ANSI conversion of the
command line, so a path carrying a character outside the active code page comes back
mangled and the application refuses to start. Measured on hosted run `33955241980`: the
React application at `<temp>\étude apps\demoreact` printed `app.pwb REFUSED (bundle file
missing)` and exited 1 while the Pas2JS twin at a spaced ASCII root answered 42 in the
same leg, from the same build. This is the third and most consequential instance of the
class D2-12 and D2-13 closed one and two layers further in: those cost a developer a
build, this one stops an end user's application from starting — an install under
`C:\Users\<accented name>\…` refuses at launch.

**Approach:** One shared production helper that asks the KERNEL for the running image
(`GetModuleFileNameW` / `readlink /proc/self/exe` / `_NSGetExecutablePath` + `realpath`),
placed in an existing `src/` unit directory the SDK already hands to the compiler, and
called by every shipped site that resolves a trusted file beside the executable. The two
Windows setup helpers, whose argv carries the accented install directory into the same
RTL layer, get the ratified D2-13 kernel-argv region. `ParamStr(0)` is then pinned out of
shipped code by a source gate, and every superseded digest and divergence row is
re-measured and recorded old → new.

## Boundaries & Constraints

**Always:**
- One rule, one implementation. The helper is the ONLY reader of the running image's path
  in shipped code; the CLI's `PWebCliImageDir` becomes a caller of it, not a twin.
- Fail closed. When the kernel will not answer, the helper returns `''` and every call
  site refuses with a typed diagnostic — never a relative path that the working directory
  could resolve.
- POSIX symlink semantics are RATIFIED as the stricter rule: the kernel path is the REAL
  image, so a host launched through a symlink resolves `app.pwb` / `plugins.zip` beside
  the real executable, never beside the link. Recorded as a supersession of the mechanism
  sentences in the CAP-7L/7M2/7F gate headers and the CAP-9C1 artifact.
- Windows: the image path from the kernel is FINAL. The helper follows no link and adds no
  `\\?\` prefix (the CAP-6b3 shape policy refuses that form). Whatever refusal exists today
  at the reader stays exactly as it is.
- Every superseded divergence row and frozen digest is RE-MEASURED and recorded old → new
  with its reason. Never "unchanged" by assumption — including the rows expected not to move.
- The four targets answer the same decisions (semantic equality), with per-target
  observations recorded separately.

**Ask First:**
- Any change to what is loaded, from where relative to the executable, the digest checks,
  the CAP-9C1 startup trust chain, the CAP-13 profile semantics, the CSP, the origin, any
  frozen interface or any pin.
- Any new top-level `src/` directory, any change to `PWEB_SDK_UNIT_DIRS`, the SDK ship
  table, or the repository layout frozen in `docs/kernel.md`.

**Never:**
- No second implementation of the image-path rule anywhere in shipped code.
- No new reparse/junction refusal in the host's bundle reader: adding one would change
  which file is loaded on previously-green layouts, which this shard is forbidden to do.
  The junction behaviour is MEASURED and recorded, not legislated.
- No widening into `tools/quickjs/pwebqjspack.pas` or `tools/pweb/pwebtemplates.pas`:
  they carry the same latent argv class, do not ship in the SDK, and are already ledgered
  with their own owner.
- No CAP-11A, CAP-11B or CAP-12 work.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Non-ASCII install root, Windows | host at `<temp>\étude apps\demo\…` | image path carries the accent verbatim; `app.pwb` found; RPC answers 42 | N/A |
| Non-ASCII root, Linux | host at `<tmp>/étude apps/…` | identical decision, 42 | N/A |
| Non-NFC root, macOS | directory name composed NFD (`e` + U+0301) | image path resolves; 42; the returned composition is RECORDED, not assumed | N/A |
| POSIX symlink launch | `<other>/host` → `<real>/host`, `app.pwb` beside BOTH | the bundle beside the REAL image is loaded; the one beside the link is not | N/A |
| Windows junction on chain | `C:\link` junction → `C:\real`, host launched via `C:\link\host.exe` | MEASURED and recorded; the helper resolves nothing further | N/A |
| Windows path > MAX_PATH | image directory longer than 260 chars | the path is returned untruncated (32767-wide buffer); the run outcome is MEASURED | recorded with its cause, CAP-10D1 `long_path_refusal` vocabulary |
| Kernel refuses to answer | `GetModuleFileNameW` = 0 / `readlink` fails | helper returns `''`; every call site refuses with a typed marker and a nonzero exit | fail closed, never CWD-relative |
| Fixed profile, accented `/DIR=` | setup installs under `<accented>\PWebRelease` | the runtime directory resolves, the application answers 42, uninstall leaves nothing | typed refusal on any step |

</frozen-after-approval>

## Code Map

**The defect's root**
- `deps/mormot2/src/core/mormot.core.os.pas:10008` — `ProgramFileName := ExpandFileName(ParamStr(0))`,
  `:10009` `ProgramFilePath := ExtractFilePath(ProgramFileName)`. READ-ONLY: a pinned dependency,
  never patched.

**Shipped image-path sites (the audited N = 5 readers, 8 lines)**
- `src/webview/pweb.webview.host.pas:704-710` — `PWebHostLoadBundle`; `:707` DARWIN
  `Contents/Resources`, `:710` beside the executable. The release-host composition every
  generated application is built from.
- `src/script/pweb.script.release.pas:1578-1583` — `PWebReleaseDirectory`, the plugins.zip /
  plugin root. Guarded downstream by `AbsoluteDirectory` (`:1560-1577`), which already refuses `''`.
- `src/platform/windows/pweb.platform.webview2.fixed.pas:635-648` — `PWebWv2FixedRuntimeRoot`,
  the Fixed Runtime directory; already refuses `''` at `:644`. Its unit header (`:14`) and the
  interface comment (`:286`) name `Executable.ProgramFilePath` and must be re-worded.
  **AUDIT CORRECTION:** the brief named `tools/setup/pwebwv2fixed.pas` as this site; that
  program takes the runtime root as an ARGUMENT and reads no image path (see below).
- `examples/08-release/releaseapp.pas:645-670` — `LoadReleaseBundle`; `:657` DARWIN, `:660` else.
- `examples/07-quickjs/quickjsapp.pas:908-930` — `AppBundleFile` (`:913`, `:916`) and
  `PackageDirectory` (`:925`).

**Shipped argv sites in `tools/setup/` (the same RTL layer, on E4's own path)**
- `tools/setup/pwebwv2fixed.pas:170-240` — `Mode/Target/Second/LogFile` from `ParamStr(1..4)`.
  The fixed profile's `.iss` passes `ExpandConstant('{app}\…')` here, so an accented `/DIR=`
  reaches the identical D2-13 conversion. Windows-only program.
- `tools/setup/pwebwv2prov.pas:210-255` — the same, for the Evergreen provisioning gate.
- `tools/setup/fixed.iss:215`, `tools/setup/app/app-fixed.iss:150`, `tools/setup/pwebprovgate.issi:173`,
  `tools/setup/app/pwebappprov.issi:131` — the `ExpandConstant('{app}')` callers. READ-ONLY
  (CAP-10D1 `check_cap10d1_contracts.ps1:513-527` pins three literals in this tree).

**The CLI's existing half of the fix (D2-12), and the reuse point**
- `tools/pweb/pweb.cli.platform.pas:1041-1075` — Windows `PWebCliImageDir`, `GetModuleFileNameW`,
  the exact shape to lift.
- `tools/pweb/pweb.cli.platform.pas:2318-2327` — POSIX `PWebCliImageDir`, still
  `Executable.ProgramFilePath`.
- `tools/pweb/pweb.cli.platform.pas:600-630` — the "SHARED BODIES" section whose header already
  states the rule this shard applies; `PWebCliExeDir` (`:612`) is the single caller, and it
  canonicalises through `PWebCliCanonicalDir` (Windows `GetFinalPathNameByHandleW`, POSIX
  `O_DIRECTORY` + fd-final-path), which already resolves every link — so the CLI's FINAL answer
  does not move on POSIX.
- `tools/pweb/pweb.cli.platform.pas:610-618` — `W()`/`U()`, the SynUnicode ↔ RawUtf8 pair.

**Where the helper may live (layering evidence)**
- `docs/kernel.md` "Toolchain & conventions" — repository layout and unit naming FROZEN:
  `pweb.<area>[.<role>].pas`; platform units are `pweb.platform.<engine>.pas`. No new
  top-level `src/` directory.
- `test/cap7f/check_divergence.ps1:29-31` and `:229-233` — `src/platform/**` is skipped
  WHOLESALE because each unit there is ONE platform's body; a three-body unit there would hide
  three real regions from the sweep.
- `tools/pweb/pweb.cli.sdkroot.pas:89-93` — `PWEB_SDK_UNIT_DIRS = ('lib','rpc','security','webview','assets')`,
  plus `src/platform/<os>`: the five directories the SDK stages and hands to the compiler.
  `src/security` is among them, and is on the `-Fu` line of every build that compiles any of the
  five sites (`test/cap5`, `cap6`, `cap6b3:239`, `cap7l:109,122`, `cap7m:141`, `cap8b`, `cap8c`,
  `cap9*`, `cap10*`, `ci.yml:343,364-365`, and the CLI's own `build_cap10b1.*:99,110`).
- `tools/pweb/pwebsdk.pas:157` — `share/pweb/src` is an `skTree` ship entry, so a new file under
  it ships automatically and `ShipTableDigest` (`:444-470`) does not move.

**Divergence allowlist rows this shard must re-ratify (measured baseline: 206 conditionals, PASS)**
- `test/cap7f/check_divergence.ps1:72` `examples/08-release/releaseapp.pas` = 38 / `8ee3c908…`
- `:79` `examples/07-quickjs/quickjsapp.pas` = 34 / `4be277b3…`
- `:100` `src/webview/pweb.webview.host.pas` = 42 / `23fcee78…`
- `:120` `src/script/pweb.script.release.pas` = 10 / `218a2592…`
- `:148` `tools/pweb/pweb.cli.platform.pas` = 36 / `e1fcbe24…`
- `:66-186` the allowlist body — a NEW row for the helper unit goes here.
- `tools/setup/` is NOT on the swept surface (`:224-226` `$pascalRoots`), so the two setup
  helpers need no row.

**Gates to extend (test surface, not frozen)**
- `test/cap10d2/run_cap10d2_gates.ps1:871-940` — CM7, the accented project root; it BUILDS and
  deliberately stops before `run`, naming this defect. `:756-782` is the run-and-read-42 shape to
  reuse. `:503` `clean_machine_path_non_ascii` is the existing non-ASCII vocabulary.
- `test/cap6b3/build_fixed_setup.ps1:185-255` and the CAP-6b3 profile matrix (I1-I3, S1-S6,
  F1-F4, U1-U3) — the `/DIR=` install to parameterise.
- `test/cap7l/run_release_layout.sh:1-100` — the Linux release layout, the four-entry assertion
  and the CWD-elsewhere launch; its header (`:8`, `:70`) names `Executable.ProgramFilePath`.
- `test/cap7m/check_release_layout.sh` — the macOS `.app` twin.
- `test/cap9c2/run_quickjsgui.ps1:420-460` / `run_quickjsgui.sh:267` — the QuickJS GUI corpus and
  the `Executable.ProgramFilePath` anchor grep that will need re-pointing.
- `test/cap7f/emit_evidence.ps1` / `emit_evidence.sh` / `check_cap7f_aggregate.ps1` — where the new
  `image_path_*` rows are emitted and compared across the four targets.
- `test/cap7f/run_host_args_gate.sh:94` — another header naming the old mechanism.
- `.github/workflows/ci.yml` — jobs `windows` (`:57`), `linux` (`:2531`), `macos-x64` (`:3513`),
  `macos-arm64` (`:4546`), `cap7-aggregate` (`:5577`).

**Read-only evidence**
- `_bmad-output/implementation-artifacts/deferred-work.md:864-865` — the D2 entry that measured
  this defect, names the four sites and the fix shape. Entries here are FROZEN by
  `test/cap10d2/check_cap10_ledger.ps1:122`; append, never edit.
- `_bmad-output/implementation-artifacts/cap10-closure-artifact.md` — CAP-10D2 PASS, CAP-10 closed,
  D2-13 RESOLVED on run `33962919229` (commit `2e2903c0`).
- `src/assets/pweb.assets.bundle.pas:921-950` — `PWebBundleLoadFile` is `FileExists` +
  `TZipAssetStore`: it refuses NOTHING reparse-related. `src/script/pweb.script.release.pas:1600+`
  `ReadAndHashOnce` DOES refuse a reparse point on `plugins.zip` itself. This asymmetry is
  pre-existing and out of this shard's freeze.

## Tasks & Acceptance

**Execution:**

- [ ] `src/security/pweb.imagepath.pas` — NEW unit. `PWebImageFile: TFileName` and
      `PWebImageDir: TFileName` (trailing delimiter), three whole platform bodies: Windows
      `GetModuleFileNameW(0, …)` over a 32767-wide buffer then one UTF-16 → UTF-8 → `string`
      conversion; Linux `readlink('/proc/self/exe')`; Darwin `_NSGetExecutablePath` + `realpath`.
      Uses nothing but the RTL and `mormot.core.base`/`.unicode` so every layer can reach it.
      Returns `''` on any kernel refusal. — one rule, reachable from `src/`, `examples/` and
      `tools/` alike without a new unit directory.
- [ ] `src/webview/pweb.webview.host.pas` — `PWebHostLoadBundle` reads `PWebImageDir`; refuse with
      a distinct stderr marker and a nonzero exit when it is `''`. — the release host every
      generated application is built from.
- [ ] `src/script/pweb.script.release.pas` — `PWebReleaseDirectory` returns `PWebImageDir`. — the
      plugin root; `AbsoluteDirectory` already refuses `''`.
- [ ] `src/platform/windows/pweb.platform.webview2.fixed.pas` — `PWebWv2FixedRuntimeRoot` reads
      `PWebImageDir`; unit header and interface comment re-worded to name the helper. — the Fixed
      Runtime directory.
- [ ] `examples/08-release/releaseapp.pas` — `LoadReleaseBundle`, both branches. — acceptance host.
- [ ] `examples/07-quickjs/quickjsapp.pas` — `AppBundleFile` and `PackageDirectory`. — acceptance host.
- [ ] `tools/pweb/pweb.cli.platform.pas` — delete both `PWebCliImageDir` platform bodies, add ONE
      shared body over `PWebImageDir` in the existing SHARED BODIES section. — the CLI becomes a
      caller, not a twin.
- [ ] `tools/setup/pwebwv2fixed.pas`, `tools/setup/pwebwv2prov.pas` — the ratified D2-13 kernel-argv
      reader (`GetCommandLineW` + `CommandLineToArgvW`, `ArgCount`/`ArgStr` keeping ParamCount/ParamStr
      semantics exactly); no conditional, both are Windows-only programs. — an accented `/DIR=`
      otherwise reaches the identical ANSI conversion, and E4 cannot pass without it.
- [ ] `test/cap10e/imageprobe.pas` — NEW four-target probe printing `image_path_source`, the helper's
      file and directory, the CLI's `PWebCliImageDir` answer, byte-equality of the two, the observed
      Unicode composition, and the path length. — E9 and `image_path_source=kernel` evidence.
- [ ] `test/cap10e/check_image_path.ps1` — NEW checkout-only source gate over `src/**`,
      `tools/setup/**`, `tools/pweb/**`, `tools/bundler/**`, `examples/**`, `sdk/**`: zero
      `ParamStr(0)`, zero `Executable.ProgramFilePath` outside the helper, `ParamStr(i>0)` only in
      the named argv readers, and exactly one implementation of the helper. Comment-stripped. — E8.
- [ ] `test/cap10e/run_cap10e_gates.ps1` (+ `.sh` twin where the leg is POSIX-only) — E2, E5, E6, E7:
      the release host at an accented directory on four targets; the POSIX symlink launch with a
      decoy `app.pwb` beside the link; the Windows junction-on-chain measurement; the Windows
      long-path measurement. — the per-site legs the brief requires.
- [ ] `test/cap10d2/run_cap10d2_gates.ps1` — CM7 grows: React AND Pas2JS created, built AND RUN at
      the accented root on Windows; POSIX legs at their own accented root, macOS composing the name
      NFD and recording what comes back. Retire the comment that names this defect as unfixed. — E1.
- [ ] `test/cap9c2/run_quickjsgui.ps1` / `run_quickjsgui.sh` — the QuickJS host at an accented
      directory; `plugins.zip` found; `ui_add=42`, `quickjs_add=42` unchanged; the
      `Executable.ProgramFilePath` anchor grep re-pointed at the helper. — E3.
- [ ] `test/cap6b3/build_fixed_setup.ps1` and the CAP-6b3 profile matrix — parameterise the install
      directory so the same gate body runs with an accented `/DIR=`; runtime directory resolves,
      application answers 42, uninstall clean with the path-scoped drain. — E4, parameterised, not copied.
- [ ] `test/cap7l/run_release_layout.sh`, `test/cap7m/check_release_layout.sh`,
      `test/cap7f/run_host_args_gate.sh` — the accented-directory and symlink cases, and the header
      sentences that name the superseded mechanism. — E2/E5 on POSIX.
- [ ] `test/cap7f/check_divergence.ps1` — the new allowlist row for the helper, and every touched
      row re-ratified with its MEASURED count and fingerprint plus the reason. — supersession.
- [ ] `test/cap7f/emit_evidence.ps1`, `emit_evidence.sh`, `check_cap7f_aggregate.ps1` — carry and
      compare the new `image_path_*` rows on four targets; both emitters, never one.
- [ ] `.github/workflows/ci.yml` — wire the CAP-10E gates into all four target jobs and the
      aggregate; add `-Fusrc/security` to the two setup-helper compiles and any other build that
      now reaches the helper.
- [ ] `docs/kernel.md`, `docs/distribution-contract.md`, `docs/sdk-contract.md` — record the
      kernel-resolved image-path rule and the POSIX symlink semantics where the trusted-location
      model is written down.
- [ ] `_bmad-output/implementation-artifacts/deferred-work.md` — APPEND the closure entry for the
      D2 defect and any measured finding this shard names but does not own.

**Acceptance Criteria:**
- Given a React and a Pas2JS application built from the extracted SDK at a spaced AND accented
  root, when each is run on all four targets, then both answer 42 and `image_path_source=kernel`.
- Given the release host, the QuickJS host and the Windows fixed-runtime profile installed under an
  accented directory, when each is run, then the trusted file beside the executable is found and
  the ratified verdicts are unchanged.
- Given a POSIX host reached through a symlink with a decoy `app.pwb` beside the link, when it
  starts, then the bundle beside the REAL image is the one loaded, and the gate records
  `symlink_rule=real_image`.
- Given the source gate, when it runs on the checkout, then `paramstr0_path_sites=0` and the helper
  is the only reader of the running image's path in shipped code.
- Given every CAP-6, 6b1–6b4, 7L, 7M2, 8, 9 and 10 gate, when they run on the new digests, then all
  are green and every digest that moved is recorded old → new with its reason.
- Given the four target jobs, when the aggregate compares them, then every CAP-10E decision row is
  semantically equal across targets, with per-target observations recorded separately.

## Design Notes

**Why `src/security/pweb.imagepath.pas` and not `src/platform/`.** `docs/kernel.md` freezes the
repository layout and reserves `pweb.platform.<engine>.pas` for engine bodies, so no new top-level
`src/` directory and no non-engine unit in `src/platform/`. The sweep skips `src/platform/**`
wholesale precisely because each unit there is ONE platform's body — a three-body unit there would
hide three real conditional regions from the very gate that exists to catch them. `src/security` is
one of the five `PWEB_SDK_UNIT_DIRS` the SDK already stages and hands to the compiler, and it is on
the `-Fu` line of every build that compiles any of the five sites, so a generated application gets
the helper with ZERO change to `pweb.cli.sdkroot.pas`, `pweb.cli.native.pas`, the ship table or the
SDK layout. And the unit is a trusted-location primitive: it is the root of the CAP-9C1 startup
trust chain, which is what `src/security` holds.

**The symlink supersession is a real behaviour change, and it is the stricter one.**
`ExpandFileName(ParamStr(0))` makes a path absolute without resolving links; `/proc/self/exe` and
`realpath` resolve them. So a host launched through `/tmp/x/host → /opt/app/host` reads
`/opt/app/app.pwb` after this shard and read `/tmp/x/app.pwb` before it — a writable directory can
no longer decide which bundle a trusted binary loads. E5 measures exactly that, with a decoy
`app.pwb` beside the link. The CLI's own final answer does not move on POSIX, because
`PWebCliCanonicalDir` already resolves every link.

**The junction claim is corrected rather than asserted.** `PWebBundleLoadFile` is `FileExists` plus
`TZipAssetStore` — it refuses nothing reparse-related — while CAP-9C1's `ReadAndHashOnce` DOES
refuse a reparse point on `plugins.zip`. No host refuses a junction on the DIRECTORY chain today.
Making one refuse would change which file is loaded on previously-green layouts, which the freeze
forbids. E6 therefore measures both cases and records them: a junction on the chain is transparent
(the same file, spelled through the link the loader was given), and a bundle FILE that is itself a
link is accepted by the host and refused by the plugin reader. If that asymmetry survives the
measurement it is appended to the ledger with its owner named, not silently claimed as refused.

**Windows string safety.** `mormot.core.os` sets `DefaultSystemCodePage` to `CP_UTF8` for the whole
process, which is exactly why the ANSI argv bytes are later read as UTF-8 and collapse to U+FFFD.
The helper therefore converts the kernel's UTF-16 answer to UTF-8 once and hands back a `TFileName`
whose bytes the RTL's own W-API wrappers convert back losslessly — the same route the D2-13 bundler
fix takes. `ExtractFilePath` stays safe on those bytes because every UTF-8 continuation byte is
`>= $80` and can never be mistaken for a separator.

## Verification

**Commands:**
- `pwsh -File test/cap7f/check_divergence.ps1` — expected: PASS, with the new row and every
  re-ratified count/fingerprint measured from this tree (baseline before the shard: 206 conditionals).
- `pwsh -File test/cap10e/check_image_path.ps1` — expected: `paramstr0_path_sites=0`,
  `programfilepath_sites=0` outside the helper, one helper implementation.
- `wsl -- bash -lc 'test/cap10e/run_cap10e_gates.sh'` and the Linux release-layout and CAP-9C2 legs
  under WSL — expected: green BEFORE any push; the Linux and shared POSIX code is validated locally,
  never one hosted run per mistake.
- `& 'C:\dev\IDE\fpc-fixed-3.2.3\bin\x86_64-win64\ppcx64.exe'` via the existing `test/cap*/build_*.ps1`
  scripts — expected: every Windows compile clean on the dev host before pushing.
- The four hosted target jobs plus `cap7-aggregate` — expected: green, with `image_path_source=kernel`
  and semantic equality on every CAP-10E decision row.

**Manual checks:**
- `git diff --stat` over `src/`, `examples/`, `tools/setup/`, `tools/pweb/`, `sdk/` — expected: the
  helper, the five image-path readers, the two setup-helper argv readers and the one CLI body, and
  nothing else.
