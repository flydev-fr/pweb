# The distribution contract (CAP-10D1)

```
pweb build [--project <path>] [--profile <name>]

  windows-x86_64             normal | offline | fixed-runtime
  linux-x86_64, macos-*      archive
```

`--profile` turns the release directory CAP-10D0 committed into **one thing
somebody else can install or unpack**, under
`<output>/<os>-<arch>/artifacts/<profile>/`, with a `release-index.json` beside
it. Without it, `pweb build` is byte-for-byte
[build-contract.md](build-contract.md).

Everything here is a **contract**. The human prose may be reworded freely;
the option, its values, the identity rules, the artifact layout, the index
shape and the exit codes may not, except by a version bump.

---

## 1. The grammar, and the one question it does not ask

`--profile` takes exactly one of four names, and the accepted set is a
**compiled allowlist that is the same on all four targets**. A parser whose
accepted values differed per platform is precisely the platform-divergent
parsing `cli-contract.md` forbids, so `pweb build --profile normal` *parses*
on Linux — and is then refused by the **command**, with
`profile_not_for_target` and exit 2, before the project is opened.

That separation is why CAP-10D1 adds **no usage cause**: the CAP-10A
taxonomy is still thirteen, and "this host does not have that profile" is a
fact about the machine rather than about the command line.

**The name is `fixed-runtime`, never `fixed`.** It is the value written to
the machine as the HKCU profile marker, `tools/setup/pwebappsetup.issi`
validates that exact spelling case-sensitively, and
`_bmad-output/specs/spec-pweb/deployment.md` names it. A shorter CLI
spelling would put two names on one mode, which is the defect the CAP-6b4
marker gate exists to forbid. `--profile fixed` is refused like
`--profile msix`.

Nothing else is added. `--target`, `--clean`, `--release`/`--debug`,
`--json`, `--watch`, `--install`, `--output` and `--force` are still refused,
and each absence is still a contract rather than an omission.

## 2. Identity, derived from `pweb.json` and from nowhere else

| identifier | rule |
|---|---|
| Inno `AppId` | the `bundleId` **literal** |
| `AppName` | `pweb.json` `name` |
| `AppVersion` | `pweb.json` `version` |
| install directory | `{localappdata}\Programs\<vendor>\<app>` |
| profile marker | `HKCU\Software\PWeb\Apps\<bundleId>`, value `Profile` |
| uninstall registration | Inno's `<AppId>_is1` |
| setup basename | `<name>-<profile>-setup`, never `setup` |
| archive name | `<name>-<version>-<os>-<arch>.tar.gz` |
| `CFBundleIdentifier` | `bundleId` — the CAP-10C1 rule, unchanged |

`<vendor>` is the `bundleId` up to its **last** dot and `<app>` is the last
label. The split is unique, so the pair is a **bijection** with the
identifier: two generated applications with different `bundleId`s can never
land in one install directory, which is exactly what makes the CAP-6b4
stale-tree reclaim safe to inherit. And a project rebuilt keeps its `AppId`,
so it **replaces itself** rather than registering a second product.

**No `AppPublisher`.** Schema 1 states no organisation, and inventing one
from a bundle identifier is the silent derivation `cli-contract.md` refuses
when it refuses to default `--bundle-id`.

**`AppId` is refused above 127 characters**, which is Inno's documented
ceiling and one byte below what schema 1 allows. That is the only descriptor
value that can overflow, and it is refused by name rather than truncated into
somebody else's identity.

**A metacharacter is refused, never escaped.** Every value that becomes a
`/D` define is re-checked against `{ } " ; \ / CR LF NUL` and every control
byte immediately before it is passed. Schema 1's grammars already exclude
all of them, so this is defence in depth — and it refuses because an escaped
identity is a *different* identity, and an installer that quietly installs a
different application is worse than one that will not build.

## 3. The Windows profiles

The CAP-13 mechanics, unchanged. Every profile is a per-user install
(`PrivilegesRequired=lowest`), the three are mutually exclusive **modes of
one product** sharing one `AppId`, one install directory and one marker, and
the provisioning gate, the stale-tree reclaim and the fixed-runtime verdict
gate are the bodies CAP-6b1, CAP-6b2 and CAP-6b3 proved at runtime.

**They are not the same files.** `tools/setup/pwebappsetup.issi` authors its
identity as literals, and two frozen CAP-13 gates require it to keep doing
so (`test/cap6b1/check_cap6b1_contracts.ps1` matches the literal `AppId=`
directive; `test/cap6b4/check_cap6b4_contracts.ps1` pins the marker key), so
a generated application cannot consume that include at all. CAP-10D1
therefore authors a generic set under `tools/setup/app/` and leaves every
CAP-13 file untouched.

**The fork is measured rather than accepted.**
`test/cap10d1/check_cap10d1_contracts.ps1` requires the `[Code]` region of
`tools/setup/app/pwebappprov.issi` to be **byte-identical** to
`tools/setup/pwebprovgate.issi`'s, and `app-fixed.iss`'s to `fixed.iss`'s. A
CAP-13 gate body that moves without its twin is a red step, not a divergence
somebody finds on a user's machine.

### The inputs, and the refusal that is not a download

| input | where | how it is verified |
|---|---|---|
| Inno Setup 6 | `<sdk>/share/pweb/deps/innosetup/ISCC.exe`, and nowhere else | the `.pweb-pin` stamp equals `innosetup.lock`'s installer sha256, **and** the binary announces `Inno Setup 6 Command-Line Compiler` |
| the bootstrapper / standalone / cabinet | `<sdk>/share/pweb/deps/webview2-runtime/` | sha256 then byte size, byte-exact against the pin |
| `WebView2Loader.dll` | `<sdk>/share/pweb/pack/lib/` | sha256 then byte size |
| the two CAP-13 setup helpers | `<sdk>/share/pweb/pack/bin/` | present; compiled once at SDK staging time |
| the generic manifests | `<sdk>/share/pweb/pack/setup/` | present |

**`pweb build` downloads nothing, ever.** There is no URL, no HTTP unit and
no fetch call site in any unit the packaging path links — the locks that
carry the vendors' addresses are repository build metadata and are never
shipped into an SDK. An absent input is a typed **exit 4** whose remediation
names `tools/get-innosetup.ps1` or `tools/get-webview2-runtime.ps1`, and a
present input whose digest has drifted is **exit 4** as well: nothing is
fetched to "repair" it.

That refusal happens in the **preflight, before the pipeline runs**. A
developer whose machine lacks the 212 MB standalone installer learns it in
one second rather than after a fifteen-minute build.

### What each profile embeds

- **normal** — the release triple, the pinned Evergreen **Bootstrapper** and
  the provisioning helper. Nothing else.
- **offline** — the same, with the pinned Evergreen **Standalone Installer**
  in place of the bootstrapper. No bootstrapper, no runtime tree, no network
  path of any kind, and no "try the bootstrapper instead" fallback.
- **fixed-runtime** — the release triple, the pinned cabinet **expanded** into
  `{app}\runtime\webview2`, the pinned SDK loader inside that tree, and the
  post-install ACL/Authenticode verdict gate.

The cabinet is expanded from bytes whose sha256 was verified against the pin
**before** `expand` was spawned, and expanding a cabinet is deterministic —
so the tree that lands is the ratified tree. CAP-6b3's build script
additionally Authenticode-verifies the freshly expanded tree because it
expands a cabinet it has just re-fetched; that axis is not re-derived here.
The axis that protects a **user** is the one over the **deployed** bytes, and
that is the unchanged gate inside the installer.

## 4. The Linux and macOS archive

One `.tar.gz` of the committed release, under a single top-level
`<name>-<version>-<os>-<arch>/` directory. **Written by PWeb**, not by an
external tool:

- entries bytewise name-sorted, `mtime 0`, `uid`/`gid` 0, `uname`/`gname`
  empty, plain ustar with no PAX records;
- mode `0755` on the program, the shared library and every directory, `0644`
  on everything else — read from the release's own execute bit, never from a
  name;
- gzipped through mORMot, whose header carries no timestamp and no stored
  filename.

Two builds of the same release therefore produce **byte-identical**
archives. Two alternatives were measured and refused, and the suite keeps
measuring them so the choice cannot decay into a preference: the frozen
CAP-6 ZIP writer has no Unix mode plane (`extFileAttr` is the MS-DOS one), so
an extracted program would lose its execute bit; and `tar(1)` has
`--sort=name` on GNU and not on macOS's bsdtar, so one rule would have become
three.

**WebKitGTK stays a runtime requirement, not a bundled one.** The archive
carries the same statement `pweb doctor` makes, and
`_bmad-output/specs/spec-pweb/deployment.md` records why: on Linux the engine
is a distribution package, and installing it is the user's or the packager's
job. There is no `.desktop` file, no AppImage, no `.deb`, no `.rpm` and no
Flatpak in v1.

## 5. The macOS signing posture

`deployment.md` ratifies it: *code signing, notarization and auto-update are
not PWeb's concern; `pweb build` produces artifacts and stops.* What that
means for somebody who receives the archive, stated plainly:

> The bundle is **not signed with a Developer ID and not notarized**. It runs
> on the machine that built it and on any machine it reaches without passing
> through quarantine. A copy downloaded by a browser carries
> `com.apple.quarantine`, and Gatekeeper will refuse it until the user
> removes that attribute or right-click-opens it. On arm64 the linker applies
> an **ad-hoc** signature, which satisfies the kernel's page-signing
> requirement and asserts no identity whatsoever.

`macos_codesign_observation` records what `codesign -dv --verbose=4` says on
each target — `adhoc`, `unsigned` or `signed_identity` — and the third is a
**gate failure**: nothing in this shard may sign with an identity.

**There is no `--sign`, no identity lookup, no keychain access and no
credential read** — not in `pweb.json`, not in the environment, not on a
command line. A later shard may add identity signing behind an explicit
option once a secret model exists outside the descriptor.

## 6. Where the artifact lands, and how it replaces one

```
<output>/<os>-<arch>/
  release/                        the run layout, UNTOUCHED by packaging
  artifacts/<profile>/
    <artifact>
    release-index.json
```

`release/` is digested before and after packaging and required unchanged
(`pack_release_altered`, exit 6): the artifact describes the release, and a
packager that edited it would be describing something else.

`artifacts/<profile>/` is replaced by the **CAP-10D0 rule, unchanged** —
`stage_aside_rename_reclaim`: staged in `.pwpack.tmp`, the existing
directory renamed aside to `.pwold.tmp`, the staged one renamed into
place, the retired one reclaimed. A rename that would replace an existing
path is never used, on either family, and a failed commit puts the previous
artifacts back.

`release-index.json` is the CAP-6b4 seam, in its schema-1 shape and
deliberately minimal:

```json
{
  "schema": 1,
  "profiles": [
    { "profile": "archive",
      "filename": "demo-0.1.0-linux-x86_64.tar.gz",
      "bytes": 1749676,
      "sha256": "…" }
  ]
}
```

No path, no version, no timestamp and no build metadata — and it is written
from the artifact **this run just measured**, never from whatever happens to
be on disk.

## 7. What it prints

The CAP-10D0 summary, with two more fields **and only when a profile was
given** — six without, eight with, never a field that is present and empty:

```
pweb: built demo
  ui           pas2js
  target       linux-x86_64
  release      dist/linux-x86_64/release
  app.pwb      487f732b…
  bytes        5298584
  artifact     dist/linux-x86_64/artifacts/archive/demo-0.1.0-linux-x86_64.tar.gz
  sha256       c6d52d18…
pweb: run it with `pweb run`
```

## 8. Exit codes

[pipeline-contract.md](pipeline-contract.md) §9, unchanged, and no seventh:

| code | packaging causes |
|---|---|
| 2 | `profile_unknown`, `profile_not_for_target` — nothing is built |
| 3 | `pack_identity_refused`, `pack_identity_too_long`, and the Windows `project_root_too_long` |
| 4 | `pack_iscc_missing`, `pack_iscc_identity`, `pack_input_missing`, `pack_input_digest`, `pack_kit_missing`, `pack_expand_missing`, `pack_sdk_unresolved` |
| 5 | `pack_child_failed` (the child's real typed status is printed), `pack_interrupted` |
| 6 | `pack_stage_failed`, `pack_artifact_missing`, `pack_archive_refused`, `pack_commit_failed`, `pack_release_altered`, `pack_mutation` |

## 9. One execution path, still

Packaging children run through the CAP-10C0 engine and through nothing else,
in the supervise profile, with the same sink, stop check, descendant drain
and typed outcome mapping every pipeline stage gets. The enumerated set of
units that call it grows from four to **five** — `pweb.cli.dev`,
`pweb.cli.package`, `pweb.cli.pipeline`, `pweb.cli.probe`, `pweb.cli.run` —
and the count was never the invariant: *one engine, an enumerated caller
set, and a build driver that spawns nothing* is, and all three are measured
on every leg.

Packaging is **not** an eleventh stage. The ten stages, their order and their
bounds are inherited verbatim, and a pipeline that knew about profiles would
be a pipeline this shard had renegotiated.

## 10. Cross-links

| document | what it freezes |
|---|---|
| [build-contract.md](build-contract.md) | the public build command, the release replacement rule and the six-field summary |
| [pipeline-contract.md](pipeline-contract.md) | the ten stages, their bounds, the SDK root, the mutation set and the release layout |
| [cli-contract.md](cli-contract.md) | the command surface, `pweb.json` schema 1 and the six exit codes |
| [supervision-contract.md](supervision-contract.md) | the one child-process engine every packaging child runs through |
| [sdk-contract.md](sdk-contract.md) | the SDK distribution these pinned inputs are resolved out of, and the manifest that verifies it |

## 11. Corrections recorded at CAP-10D2

Three statements in this document had drifted from the shipped code between
CAP-10D1's last commit and its closure, and CAP-10D2 measured them rather
than inheriting them. **Nothing in the product moved; the document did.**

| what it said | what the code says | where |
|---|---|---|
| the artifact directory is `dist/<profile>/` | `artifacts/<profile>/` — `PWEB_PACK_ARTIFACTS`, because `<output>/<target>/dist` is already the Pas2JS static assembly directory the frozen CAP-10C1 pipeline owns | §6, §7 |
| the staging siblings are `.pweb-pack.tmp` and `.pweb-dist-old.tmp` | `.pwpack.tmp` and `.pwold.tmp` — `PWEB_PACK_STAGE` and `PWEB_PACK_OLD`, shortened because the fixed-runtime profile's deepest cabinet entry is 119 characters and every character of the staging path is one fewer a project root may have | §6 |
| the Inno Setup compiler is resolved from the SDK, "else PATH" | from `<sdk>/share/pweb/deps/innosetup/ISCC.exe` **and nowhere else**: `pweb.cli.package` has no PATH branch for it at all, which is the CAP-10D2 tool-location rule stated in [sdk-contract.md](sdk-contract.md) §5 | §3 |
