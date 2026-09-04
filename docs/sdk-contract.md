# The SDK distribution contract (CAP-10D2)

```
pweb-sdk-<version>-<os>-<arch>.tar.gz
```

One archive per target, whose extracted tree **is** the
[pipeline-contract.md](pipeline-contract.md) §2 SDK root, complete, so that on
a machine that never built this repository:

```
<sdk>/bin/pweb doctor
<sdk>/bin/pweb create demo --ui react|pas2js --bundle-id com.example.demo
<sdk>/bin/pweb build [--profile …]
<sdk>/bin/pweb run          -> 42
```

works with no checkout in reach.

Everything here is a **contract**. The human prose may be reworded freely;
the shipped set, the manifest's schema and canonical form, the three doctor
rows, the build refusal, the tool-location rule and the installation model
may not, except by a version bump.

---

## 1. Installation is extraction

Unpack the archive. That is the whole of it.

Nothing is written outside the directory you extracted into: **no** `PATH`
entry, **no** registry key, **no** shell profile, **no** file in your home
directory, **no** service, **no** scheduled task and **no** uninstaller.
There is nothing to uninstall — delete the directory.

The archive carries **one** top-level directory,
`pweb-sdk-<version>-<os>-<arch>/`, so an extraction can never scatter files
into the current directory, and two versions never collide. Put the tree
wherever you like and invoke `bin/pweb` by path, or put `bin/` on your own
`PATH` if you want to — that is your decision, not the installer's, because
there is no installer.

**The SDK root is resolved from the running image**, by the one CAP-10B0
anchor rule: `<sdk>/bin/pweb` → `parent(dir(image))`. It is not the working
directory, not an argument and **not an environment variable** — there is no
`PWEB_SDK`, no `PWEB_HOME`, no `PWEB_MORMOT` and no `PWEB_TEMPLATES`, and the
CAP-10B0 and CAP-10D2 contract checks sweep every unit for every spelling. A
build tool that can be pointed at a different framework by exporting a
variable is a build tool whose trusted input is whatever the last shell
profile said it was.

## 2. What ships, and what is only pinned

The SDK ships PWeb's framework, its two frontend SDKs, its bundler, its
dependencies' sources and — on Windows — the packaging kit. **It ships no
compiler.**

| component | decision | why |
|---|---|---|
| `bin/pweb`, `bin/pwebbundle` | **ship** | the product |
| `share/pweb/pweb-templates.zip` | **ship** | the CAP-10B0 pack `pweb create` generates from |
| `share/pweb/src/**` | **ship** | the framework a generated project compiles against |
| `share/pweb/sdk/typescript`, `sdk/pas2js` | **ship** | the two frontend SDKs |
| `share/pweb/deps/mormot2/{src,static/<fpc-target>}` | **ship** | CAP-3U-patched on Windows, with `x64callmethod.obj`; `static/delphi` on Windows only |
| `share/pweb/lib/<os>-<arch>/**` | **ship** | the webview library and, on Windows, the WebView2 loader |
| `share/pweb/pack/**` | **ship**, Windows only | the CAP-10D1 packaging kit and its two compiled CAP-13 helpers |
| `share/pweb/licenses/**` | **ship** | every shipped third-party component's notice, exactly once |
| `share/pweb/sdk-manifest.json` | **ship** | §3 |
| FPC, Node.js, npm | **pin only** | `pweb doctor` requires them; the SDK ships no compiler |
| the Pas2JS compiler | **pin only** | the same rule — and a measured licence fact: the pinned 3.0.1 archive contains no `COPYING.FPC` (see [third-party-licenses.md](third-party-licenses.md)) |
| the Inno Setup compiler | **pin only** | the same rule; 28 MB under jrsoftware's terms |
| the three WebView2 runtime artifacts | **pin only** | 523 MB under Microsoft's distribution terms; the two CAP-10D1 refusals stand |
| `*.lock` | **never shipped**; digests only | [distribution-contract.md](distribution-contract.md) §3 freezes it: the locks carry the vendors' download addresses, and an installed SDK must not put one on anybody's build path. The manifest records each lock's **sha256**, which is provenance without an address |

**`pweb build --profile` on an installed SDK** resolves the Inno Setup
compiler from `<sdk>/share/pweb/deps/innosetup/` and the WebView2 artifacts
from `<sdk>/share/pweb/deps/webview2-runtime/`. Place them there yourself —
the digests are compiled into `pweb.cli.packpins` and are what the build
verifies — and an absent one is the CAP-10D1 refusal, unchanged: typed, exit
4, remediation named, and **never a download**.

**The `bin/` of a distribution holds exactly two executables.** The staged
SDK root inside this repository also carries `pwebpipe`, the private CAP-10C1
lifecycle driver, because it resolves its root from the running image exactly
as `pweb` does and therefore has to live there. The packager assembles a
**declared component table** rather than filtering a directory, so a private
test driver is never selected, and the gate re-measures that no such binary
reached the manifest.

## 3. The manifest

`share/pweb/sdk-manifest.json`, written by the packager and by nothing else:

```json
{
  "schema": 1,
  "pweb": "0.1.0",
  "protocol": 1,
  "target": "linux-x86_64",
  "templates": { "pack": "…", "inventory": "…", "registry": "…" },
  "locks": [ { "name": "fpc.lock", "sha256": "…" } ],
  "licenses": [ "LICENSE.mormot2.md" ],
  "files": [ { "path": "bin/pweb", "bytes": 1098240, "sha256": "…" } ]
}
```

**Canonical form**, and it is verified rather than trusted: fixed key order,
two-space indent, LF, exactly one trailing newline, and the string escape set
of ECMAScript's `JSON.stringify` — `"`→`\"`, `\`→`\\`,
U+0008/0009/000A/000C/000D→`\b\t\n\f\r`, every other code point below U+0020
→ `\u00xx` in **lowercase** hex, and everything else literal, the solidus and
non-ASCII included. A value is decoded before it is re-encoded, so a
redundant escape normalises; invalid UTF-8 and a lone surrogate are
**refusals**, never repairs.

The reader re-emits what it parsed and requires the result to equal the bytes
on disk, so "canonical" is a measurement rather than a rule the writer is
trusted to have followed. `files` is strictly bytewise ascending by `path`,
which makes a duplicate impossible and makes the inventory digest — sha256
over `<path>|<bytes>|<sha256>` lines — a function of the set rather than of a
walk order.

The manifest does not contain itself: a document cannot carry its own digest.

## 4. Verification, and exactly what it claims

`pweb doctor` gains three rows. They are `required`, and they are
`not_applicable` with cause `sdk_unpackaged` on an SDK root that carries no
manifest — which is what this repository's own staged build tree is, and what
any tree assembled by hand is.

| row | passes when | fails with |
|---|---|---|
| `sdk.manifest` | present, canonical, schema 1 | `sdk_manifest_malformed`, `sdk_manifest_noncanonical`, `sdk_manifest_schema`, `sdk_manifest_value`, `sdk_manifest_encoding`, `sdk_manifest_unreadable` |
| `sdk.integrity` | **every** declared file present, at its declared length, with its declared digest | `sdk_integrity_missing`, `sdk_integrity_bytes`, `sdk_integrity_mismatch`, `sdk_license_missing` |
| `sdk.version` | the manifest's `pweb` equals the running executable's | `sdk_version_mismatch` |

**Verification is full, never sampled.** Measured at 288 files and 38 MB in
**57 ms** on the development host, so a sample would have traded a
deterministic tamper claim for nothing worth having.

**The build refuses before it does anything.** The CAP-10C1 pipeline asks
this question first, inside the `open` stage, *before* the descriptor is
judged, before the read-only tree is digested, before a byte is written and
before a child is spawned — a toolchain that cannot vouch for its own bytes
has no business compiling anything. The refusal is exit **4** with the row's
own cause. Packaging is still not an eleventh stage and `build` still has
**ten**.

### What the model claims, and what it does not

It **catches** a half-copied SDK, a truncated download, an extraction that
lost a file, and a shipped byte that was altered — a patched mORMot unit, a
replaced webview library, a rewritten template pack.

It **does not** catch a manifest that was rewritten to describe the altered
bytes, and it does not notice its own absence. The manifest is not signed,
and compiling its digest into `pweb` was considered and refused: that would
pin one binary to one package and make a re-packaged SDK unusable with the
executable inside it.

**The anchor, ratified:** the manifest is trusted for the *inventory*; the
**compiled CAP-10B0 registry** stays the authority for the template pack, so
the one artifact a user's new project is generated from is anchored in the
executable rather than in a file beside it. The packager additionally refuses
to ship a pack whose digest is not the compiled registry's, so the two
anchors of a package agree by construction.

## 5. The tool-location rule — one rule, no fallback chain

Whether a tool is resolved from the SDK root or from `PATH` is a **compiled
property of the tool**, not a search:

| tool | resolved from | absent means |
|---|---|---|
| `pwebbundle` | the SDK root, walked component by component | `sdk_bundler_missing`, exit 4 |
| the Inno Setup compiler | `<sdk>/share/pweb/deps/innosetup/`, walked | `pack_iscc_missing`, exit 4 |
| `fpc`, `node`, `pas2js` | `PATH`, by the CAP-10A rule | the doctor's own row fails |

**No tool is in both columns**, so there is no chain to fall back along, and
both halves are measured at the source: the units that walk the SDK never
call the `PATH` resolver, and the `PATH` resolver never names an SDK-shipped
tool. A `pwebbundle` of another version earlier on `PATH` changes nothing,
and the clean-machine gate proves it with a decoy.

## 6. The packager

`tools/pweb/pwebsdk.pas`, a **private trusted-build tool** in the
`pwebtemplates` pattern. There is **no** `pweb sdk` command and no public
option: the command surface is still the five CAP-10D0 closed it at.

```
pwebsdk --sdk <staged sdk root> --repo <checkout> --out <dir>
```

It reads two trees it was told to read and writes the two artifacts it was
told to write. It starts no process, opens no socket, names no URL, and reads
no environment variable — all four measured at the source, with concatenated
needles so the sweep cannot satisfy itself.

**What it refuses**, each with its own cause: a reparse point anywhere
(`sdk_reparse_point` — trusted build input is read, never followed); a
`.env`, an `.npmrc`, a `.netrc`, a credential-shaped name or a `node_modules`
(`sdk_secret_path`); a compiled artifact inside a **source** tree
(`sdk_build_output`); a component the staged root does not carry
(`sdk_component_missing`); an absent repository lock (`sdk_lock_missing`); a
missing (`sdk_license_missing`) or unratified (`sdk_license_unratified`)
licence; a pack that is not the one the compiled registry describes
(`sdk_template_pack_mismatch`). The **dirty-tree** refusal lives in
`check_cap10d2_contracts.ps1`, where every other git-dependent check in this
repository lives: a Pascal build tool spawns nothing, so it cannot ask git
anything, and a packager that took a `--dirty` flag would be taking somebody's
word for it.

**The writer is CAP-10D1's**, unchanged: a POSIX ustar written here and
gzipped through mORMot, entries bytewise name-sorted, `mtime 0`, `uid`/`gid`
0, empty `uname`/`gname`, no PAX records, mode `0755` on `bin/*`, on every
directory and on every file whose on-disk execute bit is set, `0644`
otherwise.

**`tar.gz` on all four targets, Windows included.** The two ZIP writers in
this repository have no Unix mode plane (`extFileAttr` is the MS-DOS one), so
a Windows-only ZIP would have been a second writer with a second determinism
claim and a second inventory comparison — the "one rule would become three"
CAP-10D1 measured when it refused `tar(1)`. `tar.exe` has been in Windows'
System32 since 10 1803 and Windows 11's Explorer opens `.tar.gz`.

**Determinism** is a property of the output, not a flag: two packaging runs
of one commit on one target produce a byte-identical manifest, a byte-equal
inventory digest and a byte-identical archive, and the gate measures all
three on every leg.

## 7. Exit codes

[pipeline-contract.md](pipeline-contract.md) §9, unchanged, and no seventh.
Every integrity refusal is **4** — *the machine cannot build it* — because a
half-copied installation is a fact about the machine, and pointing a user at
their own project for it would be the wrong diagnosis.

## 8. Cross-links

| document | what it freezes |
|---|---|
| [pipeline-contract.md](pipeline-contract.md) | the ten stages, their bounds, the SDK root layout and the mutation set |
| [cli-contract.md](cli-contract.md) | the command surface, `pweb.json` schema 1, the doctor report and the six exit codes |
| [build-contract.md](build-contract.md) | the public build command and the release replacement rule |
| [distribution-contract.md](distribution-contract.md) | `pweb build --profile`, the identity rules and the pinned packaging inputs |
| [template-contract.md](template-contract.md) | the trusted template pack and the compiled registry that anchors it |
| [third-party-licenses.md](third-party-licenses.md) | the machine-readable shipped licence subset |
