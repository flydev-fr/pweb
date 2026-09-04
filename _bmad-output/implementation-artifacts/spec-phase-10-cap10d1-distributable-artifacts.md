---
title: 'CAP-10D1 — distributable artifacts: `pweb build --profile`'
type: 'feature'
created: '2026-09-04'
status: 'in-progress'
baseline_commit: '9e092c03bcb676ab001f987fbd4a5472cf0fdb5b'
review_loop_iteration: 0
context:
  - '{project-root}/docs/build-contract.md'
  - '{project-root}/docs/pipeline-contract.md'
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/deployment.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `pweb build` produces a *release directory* and stops, and a
release directory is not something a developer can hand to somebody else. The
CAP-13 Windows installers exist and are proven, but they install exactly one
hard-coded application (`PWebRelease`, one literal GUID, one literal install
directory) and are reachable only through a private repository script. Linux
and macOS have no distributable artifact at all, and the macOS signing posture
has never been stated as a promise anybody can read.

**Approach:** Add exactly one option, `pweb build --profile <name>`, turning
the D0 release layout into a distributable artifact under
`<output>/<os>-<arch>/dist/<profile>/` with a `release-index.json` in the
CAP-6b4 minimal shape. On Windows the three CAP-13 profiles are rebuilt for a
*generated* application, every identity derived from `pweb.json` by documented
rules and every input a pinned artifact validated offline; on Linux and macOS
one deterministic archive of the committed release. Without `--profile`,
`pweb build` is byte-for-byte CAP-10D0.

## Boundaries & Constraints

**Always:**

- **One execution path.** Packaging children run through the CAP-10C0 engine
  (`PWebCliExecute`, `pepSupervise`) and nothing else. The enumerated caller
  set grows four → **five** (`dev`, `package`, `pipeline`, `probe`, `run`);
  that supersession is recorded, re-pinned and measured, and
  `pweb.cli.build` still names **no** process API by any spelling.
- **Zero network, by construction.** No URL, no HTTP unit and no fetch call
  site in any unit the packaging path links, swept for every spelling. An
  absent pinned input is a typed exit 4 naming `tools/get-innosetup.ps1` or
  `tools/get-webview2-runtime.ps1`.
- **Identity comes from `pweb.json` and nowhere else**, one deterministic rule
  per platform identifier, documented in `docs/distribution-contract.md`. A
  value carrying an Inno or XML metacharacter is **refused**, never escaped
  into a different identity.
- **Two generated projects with different `bundleId`s never collide** on
  AppId, install directory, profile marker or uninstall registration; one
  project rebuilt replaces itself exactly as CAP-6b4 does.
- The ten stages, their bounds, the mutation set, the release layout and
  `stage_aside_rename_reclaim` are inherited verbatim. Packaging runs **after**
  stage 10, writes only under `<root>/<output>/`, and re-digests the read-only
  project tree around itself exactly as the pipeline does.
- Every claim is emitted per target into `build/cap10d1/cli-<target>.json` and
  aggregated field by field, with a negative self-test leg for every refusal
  the aggregator can make.

**Ask First:** any change to a CAP-13 file
(`tools/setup/{normal,offline,fixed}.iss`,
`pweb{provgate,appsetup,apppayload}.issi`, `pwebwv2{prov,fixed}.pas`) or to a
CAP-6b gate — this shard is designed to need none, so if one proves
unavoidable, HALT; any move of a lock, a pinned digest or a dependency
version; any use of a signing identity, keychain, credential store or
notarization service.

**Never:** no `--sign`, identity lookup, keychain access, notarization or
credential read anywhere — not in `pweb.json`, the environment or a command
line; no new `pweb.json` field (schema 1 is frozen; growth is a bump); no
change to the CAP-13 provisioning gate, the fixed-runtime lock model, the
installer semantics or the `.issi` includes' behaviour; no change to the D0
grammar beyond `--profile`, the C1 stages, the C0 resolver or exit mapping,
the release layout, the dev loop, dev host, seam, CSP, privileged origin, the
seven interfaces, the adapters or any pin; no `.deb`, `.rpm`, AppImage,
Flatpak, DMG or `.desktop` (`deployment.md`, *Out of scope*); no SDK packaging
(CAP-10D2); no writing outside the mutation set and `<output>`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Exit |
|---|---|---|---|
| Windows normal | pinned bootstrapper + ISCC staged | ten stages, then one installer at `<output>/windows-x86_64/dist/normal/<name>-normal-setup.exe` + `release-index.json`; summary gains `artifact` and `sha256` | 0 |
| Windows offline | `--profile offline` | built from the validated Standalone Installer; embedded payload set exactly triple + standalone + helper | 0 |
| Windows fixed | `--profile fixed-runtime` | cabinet sha256-verified, expanded under `.pweb-pack.tmp`, installer built with the CAP-13 verdict gate unchanged | 0 |
| POSIX archive | `--profile archive` | one `<name>-<version>-<os>-<arch>.tar.gz` whose inventory and per-file digests equal `release/`, modes 0755/0644, byte-identical across two builds | 0 |
| Profile foreign to target | `--profile archive` on Windows | `profile_not_for_target`, **nothing built**, refused before the project is opened | 2 |
| Pinned input absent | no standalone under the SDK's `deps/webview2-runtime` | `pack_input_missing`, remediation names `tools/get-webview2-runtime.ps1`, network calls sampled 0, the pipeline never runs | 4 |
| Pinned input drifted | staged artifact whose sha256 ≠ the pin | `pack_input_digest`; nothing is fetched to "repair" it | 4 |
| ISCC absent / wrong identity | no `ISCC.exe`, `.pweb-pin` ≠ `innosetup.lock`, or no `Inno Setup 6` banner | `pack_iscc_missing` / `pack_iscc_identity`, remediation names `tools/get-innosetup.ps1` | 4 |
| Identity metacharacter | a value carrying `{`, `}`, `"`, `;`, `\`, CR or LF | `pack_identity_refused` naming the field; never escaped | 3 |
| AppId too long | `bundleId` of 128 bytes on Windows | `pack_identity_too_long` — Inno's AppId ceiling is 127 | 3 |
| Long project root | Windows root above the measured bound | `project_root_too_long`, **before any child runs**, with or without `--profile` | 3 |
| Packaging child fails | ISCC exits nonzero | the child's real typed status printed, previous `dist/<profile>/` byte-identical | 5 |
| Ctrl+C during packaging | real stop mid-ISCC | staging reclaimed, previous artifacts untouched, descendants 0 | 5 |
| No `--profile` | `pweb build` | byte-for-byte CAP-10D0: six summary fields, no `dist/`, D0 corpus digest unchanged | 0 |

</frozen-after-approval>

## Code Map

### The authority this shard inherits (read-only)

- `docs/build-contract.md` §1–§7 — the D0 grammar,
  `stage_aside_rename_reclaim`, the failure table, the six-field summary.
  **Extended, never rewritten.**
- `docs/pipeline-contract.md` §3, §4, §8, §9 — stages and bounds, mutation
  set, release layout, exit categories. Verbatim.
- `docs/cli-contract.md` §2 *Grammars* (the `name`, `bundleId`, `version`
  regexes every identifier derives from), §3 *Executable resolution*, §4.
- `_bmad-output/specs/spec-pweb/deployment.md` §*Three `pweb build` profiles*
  — **the names are `normal | offline | fixed-runtime`** — and §*Out of scope*
  — signing, notarization, auto-update, `.deb`/`.rpm`/AppImage/Flatpak. That
  section *is* the D1 posture; this shard states it, it does not decide it.
- `cap10d0-final-artifact.md` §4 (the handoff), §5 (the three ledger items).

### The CAP-13 mechanics reused, and why they cannot be reused *as-is*

- `tools/setup/pwebappsetup.issi` `[Setup]`/`[Registry]` — `AppId`, `AppName`,
  `DefaultDirName` and `PWEB_MARKER_KEY` are **literals**, and two frozen
  gates require them to stay literals:
  `test/cap6b1/check_cap6b1_contracts.ps1:196-236` matches
  `(?m)^AppId=\{\{([0-9A-Fa-f-]+)\}\s*$` in that file, and
  `test/cap6b4/check_cap6b4_contracts.ps1:107-135` pins the marker key.
  `pwebapppayload.issi` names `releaseapp.exe` literally. **Turning any of
  them into a define breaks a CAP-13 gate** — the justification for a generic
  set under `tools/setup/app/`, with every CAP-13 file untouched. Anti-fork is
  not abandoned but **measured**: `check_cap10d1_contracts.ps1` requires
  `app/pwebappprov.issi`'s `[Code]` byte-identical to `pwebprovgate.issi`'s,
  and the same for `fixed.iss`'s `FixedRuntimeGate`.
- `tools/setup/pwebprovgate.issi` — `PrepareToInstall`, `PWebOwnsInstallDir`,
  the `[InstallDelete]` reclaim; `tools/setup/fixed.iss` `[Files]` — the order
  (runtime tree → verdict gate → release triple) whose reason CAP-6b4 records.
  Both application-neutral, reproduced and asserted.
- `tools/build-windows-profiles.ps1:140-190` — the `release-index.json`
  schema-1 shape and the publish-only-what-this-build-produced rule. **The
  seam CAP-6b4 left for CAP-10; consumed here, not redesigned.**
- `test/cap6b1/build_normal_setup.ps1:149-200` — the `/D` set and the
  `Compressing:` payload-listing proof;
  `test/cap6b3/build_fixed_setup.ps1:270-400` — `expand -F:*`, the tree name,
  `WebView2Loader.dll`, `lzma2/fast`, `SolidCompression=no`.
- `tools/get-innosetup.ps1:104-170` — `.pweb-pin` holds the verified installer
  sha256; the banner is `Inno Setup 6 Command-Line Compiler`.
  `tools/get-webview2-runtime.ps1:249-306` — `-Validate` is a **lock parse
  only**; the digest check lives in `Get-Wv2Artifact`. D1 reproduces that
  verification (sha256 then size, byte-exact, refuse on mismatch) in Pascal
  and performs no transfer at all.

### Pinned inputs and their locks (cited, never restated)

- `innosetup.lock` (`version`, `sha256`) — the compiler identity.
- `webview2-runtime.lock:98-104` bootstrapper, `:132-138` standalone-x64,
  `:168-175` fixed-runtime-x64 (`filename`, `size`, `sha256`, `version`,
  `authenticode-subject`). `pweb.cli.packpins` mirrors those fields and only
  those; the contract check parses the lock and requires equality.
- `webview.lock:9-11` — `webview2-sdk = 1.0.1587.40` and its tree digest. The
  loader at
  `build/webview-build-cap4w/_deps/microsoft_web_webview2-src/build/native/x64/WebView2Loader.dll`
  hashes to `24ce662f5e19393e…ec8c6d61` (158648 bytes): **the one new D1
  ratification, anchored to that SDK version pin.**
- `src/platform/windows/pweb.platform.webview2.provision.pas` —
  `PWEB_WV2_INSTALL_TIMEOUT_MS = 900000`, the single source of the helper wait.

### The CLI units this shard touches

- `pweb.cli.args.pas:124` `TPWebCliCommand`, `:127` `TPWebCliUsage` (thirteen
  causes — **unchanged**), `:150` `TPWebCliArgs`, `:219` `PWebCliParseArgs`.
  `--profile` copies the `--project` value discipline; the compiled allowlist
  accepts all four values **on every target**, so one grammar stays identical
  on four platforms.
- `pweb.cli.build.pas` — `TPWebCliBuildResult`, `PWebCliRunBuild`: a profile
  input, the preflight-before-pipeline order, two measurement fields. Still no
  process API, still no platform conditional.
- `pweb.cli.pipeline.pas:419-489` `RunStage` (the one engine call),
  `PWebCliMutationSet`, `PWebCliPipeRedactions`, `PWebCliPipeTreeLines`; the
  `open` stage gains the long-path refusal as ordinary runtime code.
- `pweb.cli.layout.pas:266-296` — the `hadOld` rollback between the two
  renames: the fault seam goes exactly there.
- `pweb.cli.probe.pas:103-113` `PWebCliResolveTool` / `PWebCliProbeTool` — the
  CAP-10A resolver, reused for ISCC and `expand`.
- `pweb.cli.sdkroot.pas:97-156` — **`TPWebSdkLayoutRefusal` does not grow**:
  packaging inputs resolve lazily in the preflight, so an SDK with no
  packaging kit still builds.
- `pweb.cli.platform.pas:205,243,264` `PWebCliExecutableBit`,
  `PWebCliWriteNewFile(…, SetExecBit)`, `PWebCliRenameDir`;
  `pweb.cli.stage.pas:71-127` `PWebCliArgPath`, `PWebCliCommandText`,
  `PWebCliPipe{EnsureDir,RemoveTree,CopyFile,TreeLines}`.
- `pweb.cli.report.pas:124` banner, `:352` `PWebCliBuildHelp`; `pweb.pas:735`
  `RunBuild`, `:174`/`:184` `Emit`/`EmitErr` — the only writers (ledger **f**).
- `deps/mormot2/src/core/mormot.core.zip.pas:931,1361` — `GZHEAD`, `GZWrite`;
  `mormot.crypt.core` `Sha256` for every digest.

### Gates, corpus and CI

- `test/cap10d0/run_cap10d0_gates.ps1:24-160` — the gate this shard models
  itself on (`Row`/`Require`/`Bool`, `InventoryOf`, `TargetName`, `RunCli`,
  the pinned pas2js PATH block, the spaced-path root); `test/cap10d0/psargs.ps1`
  — the mandatory `Start-PWebProcess` helper the D1 gate dot-sources.
- `test/cap10d0/check_cap10d0_contracts.ps1` — **three superseded rows**:
  `execute_callers` four → five (§1); the bounds table gains the long-path
  constant (§2); `--profile` leaves the unratified list (§3). §7's D1 word
  sweep stays on `pweb.cli.build.pas` and is *widened* to require those words
  in `pweb.cli.package.pas` and nowhere else.
- `test/cap10c1/run_cap10c1_gates.ps1:795-815` — the `$cliClosure` pin;
  `--profile` moves `cli_digest`, recorded as CAP-10D0 moved it.
- `test/cap7f/check_cap7f_aggregate.ps1:286` `$required`, `:639`
  `$absolutePins`, `:670` `$mustPass`, `:961` per-target; and
  `check_cap7f_selftest.ps1` — one negative leg per new refusal.
- `test/cap10c3/check_cap10c_ledger.ps1:203-215` — the `docs/index.md` rule.
- `.github/workflows/ci.yml:57` windows (already provisions `deps/innosetup`
  and all three WebView2 artifacts at steps 1207/1272/1343), `:2421` linux,
  `:3298`/`:4226` macos, `:5152` cap7-aggregate.

## Tasks & Acceptance

**Execution:**

*Production — the CLI*

- [ ] `tools/pweb/pweb.cli.packpins.pas` — NEW. The compiled pins (the three
      WebView2 artifacts' filename/size/sha256/subject, the fixed version and
      tree name, the loader digest, the Inno pin and banner literal, the
      provisioning timeout). **No URL, ever**; each cross-checked against its
      lock by the contract check.
- [ ] `tools/pweb/pweb.cli.tar.pas` — NEW. A deterministic ustar writer +
      mORMot `GZWrite`: bytewise-sorted names, `mtime 0`, `uid/gid 0`, empty
      `uname/gname`, `0755` for the program, the shared library and every
      `.app` directory and `0644` otherwise, no PAX records, one top-level
      `<name>-<version>-<os>-<arch>/`. Pure; testable without a filesystem.
- [ ] `tools/pweb/pweb.cli.package.pas` — NEW. Profile vocabulary; identity
      derivation; the preflight (ISCC + pinned artifacts, zero network); the
      `/D` vectors; the supervised children (ISCC, `expand`) through
      `PWebCliExecute`; the archive driver; `release-index.json`; the
      `stage_aside_rename_reclaim` commit of `dist/<profile>/`; the
      before/after read-only-tree digest. **The only new engine caller.**
- [ ] `tools/pweb/pweb.cli.args.pas` — `--profile`, the `--project` value
      discipline, a compiled four-value allowlist, `pcuOptionNotForCommand`
      for every command but `build`. **No new usage cause.**
- [ ] `tools/pweb/pweb.cli.build.pas` — take the profile, preflight **before**
      `PWebCliRunPipeline`, call `PWebCliRunPackage` after a successful build,
      record `ArtifactLogical` + `ArtifactSha256`.
- [ ] `tools/pweb/pweb.cli.pipeline.pas` — the Windows long-path refusal at
      `open` (`project_root_too_long`, `ppcProject`), the bound beside the
      other eight in `pweb.cli.toolchain.pas`.
- [ ] `tools/pweb/pweb.cli.layout.pas` — the rollback fault seam between the
      two renames under `{$ifdef PWEB_LAYOUT_FAULTS}`; absent from every
      production build command, and that absence swept.
- [ ] `tools/pweb/{pweb.cli.report.pas,pweb.pas}` — `--profile` in the banner
      and `build --help`; the two extra summary fields only when a profile was
      given; the typed refusals.

*Production — the generic setup manifests*

- [ ] `tools/setup/app/pwebappid.issi` — NEW. `[Setup]` identity + `[Registry]`
      marker, every value a required define with **no default**, plus the
      `setup`-basename ban and the profile-set validation in the CAP-6b4
      case-sensitive `Pos()` form.
- [ ] `tools/setup/app/pwebapptriple.issi` — NEW. The generated release triple
      from `PWEB_APP_EXE` / `PWEB_APP_BUNDLE` / `PWEB_APP_LIB`.
- [ ] `tools/setup/app/pwebappprov.issi` — NEW. The provisioning body; its
      `[Code]` byte-identical to `tools/setup/pwebprovgate.issi`'s.
- [ ] `tools/setup/app/app-{normal,offline,fixed}.iss` — NEW. Thin profile
      heads; `app-fixed.iss` reproduces the CAP-6b3 `[Files]` order and
      `FixedRuntimeGate` under the same measured-identity rule.

*Tests, gates and CI*

- [ ] `test/cap10d1/build_cap10d1.{ps1,sh}` — NEW. Stage the packaging kit into
      `build/cap10b1/sdk` (`share/pweb/deps/{innosetup,webview2-runtime}`,
      `share/pweb/pack/{setup,bin,lib}`); isolation-compile `pweb.cli.package`
      and `pweb.cli.tar`; build `d1tests` and `pwebpackdrv`.
- [ ] `test/cap10d1/{pweb.test.pack.pas,d1tests.pas}` — NEW. Headless: identity
      derivation and every metacharacter refusal; the tar writer's
      determinism, modes and inventory; the index shape; the `hadOld` rollback
      under the fault seam (**ledger b**); the profile/target matrix; the two
      measured archive-writer refusals. Emits `build/cap10d1/pack-corpus.txt`.
- [ ] `test/cap10d1/pwebpackdrv.pas` — NEW. The A4 interrupt driver
      (`pwebbuilddrv` pattern).
- [ ] `test/cap10d1/check_cap10d1_contracts.ps1` — NEW. Pins vs locks; five
      engine callers; the `[Code]` twin equality with CAP-13; no
      signing/credential/keychain/network spelling on the packaging path; no
      `SignTool=`/`SignedUninstaller=` in any D1 manifest; the fault define
      absent from every production build command; the D0 supersessions; the
      `docs/index.md` cross-link.
- [ ] `test/cap10d1/run_cap10d1_gates.ps1` — NEW. W1–W8, L1–L2, M1–M3, A1–A5,
      the long-path bisection, and the evidence file.
- [ ] `test/cap10d0/check_cap10d0_contracts.ps1`, `test/cap10c1/run_cap10c1_gates.ps1`,
      `test/cap7f/{check_cap7f_aggregate.ps1,check_cap7f_selftest.ps1,emit_evidence.{ps1,sh}}`
      — the recorded supersessions, the new required fields, absolute pins,
      must-pass rows and negative legs.
- [ ] `.github/workflows/ci.yml` — the D1 build/contracts/gates/upload block in
      all four platform jobs, after the D0 block, with per-step budgets.
- [ ] `docs/{distribution-contract.md (NEW),index.md,build-contract.md,cli-contract.md}`
      — the contract, its cross-link, `--profile` where the grammar is stated.
- [ ] `deferred-work.md` — the disposition of C1-11 (a), (b), (f) and the
      long-path item, appended.

**Acceptance Criteria:**

- Given a generated project on the hosted Windows runner, when
  `--profile normal` runs, then an installer and a schema-1
  `release-index.json` land under `dist/normal/`, a silent per-user install
  then a launch answers **42**, a silent uninstall leaves no residue after the
  CAP-6b3 path-scoped drain, and `release/` is byte-identical throughout.
- Given two projects with different `bundleId`s, when both normal installers
  run, then both are present with distinct install directories, HKCU markers
  and uninstall registrations; and a rebuilt project replaces itself rather
  than adding a second registration.
- Given a Linux or macOS project, when `--profile archive` runs twice, then
  the archive's inventory and per-file digests equal `release/`, the two
  archives are **byte-identical**, and an extracted copy answers **42** from
  an unrelated working directory.
- Given any target, when `pweb build` runs without `--profile`, then the D0
  corpus digest is unchanged, no `dist/` is created and the summary carries
  exactly six fields.
- Given the source gate and the runtime sampler, then
  `signing_identity_used = false`, `secrets_read = 0` and
  `profile_inputs_network_calls = 0` on all four targets.
- Given the hosted CI, then CAP-10D0, C0–C3, B0–B2, 10A, 6b1–6b4, 7L/7M2 and
  8/9 gates are green, the freeze checks and `check_dev_trust` pass, and the
  aggregator accepts four targets with no SKIP promoted.

## Spec Change Log

## Design Notes

### The grammar, and why the profile name is `fixed-runtime`

```
pweb build [--project <path>] [--profile <name>]

  windows-x86_64            normal | offline | fixed-runtime
  linux-x86_64, macos-*     archive
```

The shard brief writes `fixed`. The **canonical** name is `fixed-runtime`:
`deployment.md` names it, `pwebappsetup.issi` validates
`|normal|offline|fixed-runtime|` case-sensitively, that string *is* the value
written to the machine as the profile marker, and
`check_cap6b4_contracts.ps1:121` pins it. `fixed` would put a second name on
one thing and make the CLI's vocabulary disagree with the machine's record —
the defect the CAP-6b4 marker gate exists to prevent — so `--profile fixed` is
refused like `--profile svelte`.

**The parser is target-agnostic.** All four values are accepted on every
platform, because a parser whose accepted set differed per platform is exactly
the platform-divergent parsing CAP-10A forbids. The *build command* then
refuses a foreign profile with `profile_not_for_target` and exit 2, before the
project is opened — which is why the usage taxonomy stays at thirteen causes.

### Identity, derived once

| identifier | rule | why |
|---|---|---|
| Inno `AppId` | the `bundleId` **literal** | deterministic, no GUID generation, already a strict grammar; refused above 127 bytes, Inno's ceiling |
| `AppName` / `AppVersion` | `pweb.json` `name` / `version` | the one stated display identity; strict `X.Y.Z` |
| `DefaultDirName` | `{localappdata}\Programs\<vendor>\<app>`, `<vendor>` = `bundleId` up to its last dot, `<app>` = the last label | the decomposition is unique, so two `bundleId`s can never share an install directory — which is what keeps `PWebOwnsInstallDir`'s reclaim safe |
| profile marker | `HKCU\Software\PWeb\Apps\<bundleId>`, value `Profile` | PWeb's namespace, one key per project, three levels `uninsdeletekeyifempty` |
| uninstall key | Inno's `<AppId>_is1` | one registration per `bundleId`; a rebuild replaces itself |
| setup basename | `<name>-<profile>-setup` | never `setup`, validated in the include as CAP-6b4 validates it |
| `CFBundleIdentifier` | `bundleId` | the CAP-10C1 `Info.plist` rule, **unchanged** |

Every value is re-checked against `{`, `}`, `"`, `;`, `\`, `/`, CR, LF and any
byte outside its schema-1 grammar immediately before it becomes a `/D` define.
Schema 1 already refuses all of them, so this is defence in depth — and it
**refuses**, never escapes: an escaped identity is a different identity, and
an installer that quietly installs a different application is worse than one
that will not build.

**The setup basename is a define here and a literal there.** CAP-6b4 ratified
"the `.iss` authors `PWEB_SETUP_BASENAME`, the build script parses it, never
`/F`" so one manifest owns one artifact name; a generated application's name
cannot be a literal in a shared manifest. D1 inverts the direction and keeps
the property that mattered — the include still **validates** it and still
refuses `setup` in any casing, so nothing this tool produces is ever
appcompat-shimmed.

### The archive: a deterministic ustar, written here

Three candidates, weighed against "inventory parity, correct modes,
byte-determinism, one rule on two families":

- **the frozen `pwebbundle` writer** — ZIP through mORMot's `TZipWrite`, whose
  `extFileAttr` is `$A0`, MS-DOS attributes with no Unix mode plane
  (`mormot.core.zip.pas:341,1574`). An extracted program loses its execute
  bit. **Refused: cannot carry the required modes.**
- **a supervised `tar`** — GNU tar has `--sort=name`, macOS's bsdtar does not;
  two argument vectors, two byte streams. **Refused: one rule becomes three.**
- **a PWeb-authored ustar + mORMot `GZWrite`** — no external tool, no family
  divergence, determinism by construction: `mtime 0`, `uid/gid 0`, empty
  `uname`/`gname`, bytewise-sorted names, fixed modes, and a gz header mORMot
  already emits with **no timestamp** (`GZHEAD = (GZ_MAGIC, 0, 0)`,
  `mormot.core.zip.pas:931`). **Ratified.**

Both refusals are *measured* by the suite rather than asserted. The macOS
`.app` needs nothing more: the ad-hoc signature the linker applies on arm64
lives **inside** the Mach-O (`LC_CODE_SIGNATURE`), so tar preserves it and
`codesign -dv` on an extracted copy still answers — where a `ditto` zip adds
`__MACOSX` entries the inventory comparison would have to explain away.

### The macOS posture, stated as a promise

`deployment.md` §*Out of scope* already ratifies it. D1 states what it means
for somebody who receives the archive:

> The bundle is **not signed with a Developer ID and not notarized**. It runs
> on the machine that built it and on any machine it reaches without passing
> through quarantine. A copy downloaded by a browser carries
> `com.apple.quarantine` and Gatekeeper refuses it until the user removes the
> attribute or right-click-opens it. On arm64 the linker applies an **ad-hoc**
> signature, which satisfies the kernel's page-signing requirement and asserts
> no identity whatsoever.

`macos_codesign_observation` records `adhoc`, `unsigned` or `signed_identity`
per target from `codesign -dv --verbose=4`; `signed_identity` is a gate
failure, because nothing here may sign with an identity.

### Where packaging sits, and the one-caller property

```
pweb build --profile P
  0 profile vs target        exit 2, nothing opened
  1 open the project         exit 3
  2 long-path refusal (Win)  exit 3, no child yet
  3 packaging PREFLIGHT      exit 3/4, no child, no build
  4 install the stop handler
  5 PWebCliRunPipeline       stages 1..10, unchanged
  6 PWebCliRunPackage        supervised children, commit, index
  7 the summary              six fields, plus two when a profile was given
```

The preflight runs **before** the pipeline on purpose: a developer whose
machine lacks the pinned standalone installer learns it in one second rather
than after a fifteen-minute React build. It resolves, probes and writes
nothing.

`pweb.cli.package` calls `PWebCliExecute` directly, in `pepSupervise`, with
the same sink, stop check, tree drain and typed outcome mapping the pipeline
uses — so the enumerated caller set becomes **five**. The count was never the
invariant; *one engine, an enumerated caller set, and a build driver that
spawns nothing* is, and all three are re-measured. Exporting the pipeline's
nested `RunStage` was considered and refused: it closes over `res`, `ctx`,
`prefixes` and `tokens`, and refactoring a frozen unit's spine to avoid moving
a count is the worse trade.

### The three inherited ledger items, and the long path

- **C1-11 (a) — the toolset collapse.** Closes **RECORDED-ONLY** on a second
  measurement. The entry survived to D1 on the hypothesis that a profile
  selection would need "a resolution without the requirement graph". It does —
  and gets one from `PWebCliResolveTool`/`PWebCliProbeTool`, the CAP-10A
  primitive already sitting below `PWebCliResolveToolset`. The preflight
  resolves ISCC without touching the toolset, so the duplication is still on
  no path that needs collapsing. Measured: `pweb.cli.package` names
  `PWebCliResolveToolset` zero times.
- **C1-11 (b) — the `hadOld` rollback.** Closes on a fault-injection seam:
  `{$ifdef PWEB_LAYOUT_FAULTS}` arms a hook between the two renames; the suite
  arms it, requires `plrCommit`, then requires the **previous release back in
  place and byte-identical**. Exactly one compile command passes that define,
  and the contract check sweeps every other build command and CI step for it.
- **C1-11 (f) — the per-call-site `Flush`.** Closes as **not needed**, the
  reason turned from an observation into a measurement: D1 adds no unflushed
  call site either, and the contract check now asserts no unit under
  `tools/pweb/` writes to `Output`/`ErrOutput` outside `pweb.pas`'s two
  flushing helpers, so a gate fails if one appears.
- **The Windows long path** (owner: the pinned pas2js compiler). D1 cannot fix
  the compiler; it can stop it being the thing that fails. The gate
  **measures** the bound on the hosted runner by building one Pas2JS project
  at three root lengths, records the largest that builds and the smallest that
  fails, and pins `PWEB_CLI_PIPE_MAX_ROOT_CHARS` strictly between them. The
  refusal fires at `open`, before anything is written or spawned — on `build`
  and `dev` alike.

### Zero network, proven three ways

**By construction** — no unit on the packaging path links an HTTP client and no
URL exists in `pweb.cli.packpins` (the locks keep the URLs, and the locks are
not shipped into the SDK). **By sweep** — the contract check sweeps every
packaging unit and D1 manifest for every spelling of a transfer
(`Invoke-WebRequest`, `THttpClient`, `winhttp`, `curl`, `wget`, `http://`,
`DownloadFile`, `URLDownloadToFile`, …). **By sampling** — the gate samples the
real packaging process tree through the CAP-10C1 membership sampler while ISCC
runs, the sampler's own liveness required so a vacuous zero cannot pass.

Every evidence row a target cannot measure is typed `not_applicable`, never
absent: a field on one target only is a field the aggregator cannot compare.

## Verification

**Commands (Windows host):**

- `pwsh -File test/cap10d1/check_cap10d1_contracts.ps1` — PASS, 0 violations.
- `pwsh -File test/cap10d1/build_cap10d1.ps1` — kit staged; `pweb.cli.package`
  and `pweb.cli.tar` compile in isolation; `d1tests` + `pwebpackdrv` produced.
- `pwsh -File test/cap10d1/run_cap10d1_gates.ps1` — every W/A row green in
  `build/cap10d1/cli-windows-x86_64.json`.
- `pwsh -File test/cap10d0/run_cap10d0_gates.ps1` — `build_digest` unchanged.
- `pwsh -File test/cap6b1/check_cap6b1_contracts.ps1` and
  `test/cap6b4/check_cap6b4_contracts.ps1` — PASS: no CAP-13 file moved.

**Commands (POSIX, under WSL — green here before any push):**

- `wsl test/cap10d1/build_cap10d1.sh` — both isolation compiles clean (3.2.3).
- `wsl xvfb-run -a pwsh -File test/cap10d1/run_cap10d1_gates.ps1` —
  `linux_archive_inventory_equals_release`, `linux_archive_run = 42`,
  `archive_deterministic = true`.

**Manual checks:**

- macOS x86_64 and arm64 are hosted-only: read `macos_codesign_observation`
  and `macos_archive_run` out of both macOS jobs' uploaded corpora before
  claiming the posture is measured.
- `long_path_bound_chars` must lie strictly between the recorded building and
  failing root lengths; if it does not, the constant is a guess.
