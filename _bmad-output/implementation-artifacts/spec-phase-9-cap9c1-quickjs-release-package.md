---
title: 'CAP-9C1 — Deterministic QuickJS production package and trusted release loader'
type: 'feature'
created: '2026-08-26'
status: 'done'
review_loop_iteration: 0
baseline_commit: '0624b8a20b80455bf41c7f3dad97f985ebb5f86c'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/security-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/deployment.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-6-cap6-release-bundle.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9b1-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9b2-final-artifact.md'
---

# CAP-9C1 — Deterministic QuickJS Production Package and Trusted Release Loader

Shard spec. Produces and consumes ONE deterministic native-only plugin
archive. It adds no kernel interface, no public package format, no
discovery, no watching, no installation and no signatures, and it does
not close CAP-9.

## Frozen inputs

CAP-8, CAP-9A, CAP-9B1 and CAP-9B2 are closed and verified from
repository evidence: hosted runs 32863002073 (`bd4c041`), 32975110018
(`e62331d`) and 32995412526 (`78e1359`), all `success`, all three
commits ancestors of this baseline. Their digests
(`quickjs_corpus_digest`, `quickjs_package_digest`,
`quickjs_lifecycle_digest`, `security_corpus_digest`) are re-measured as
a regression gate, never re-baselined.

## The production path this shard builds

```
trusted build-time plugin list
    -> deterministic native-only plugin archive
    -> generated native-trusted package identity (compiled in)
    -> runtime whole-package integrity verification
    -> TZipAssetStore
    -> one confined TPWebScopedAssetStore per plugin
    -> B1 descriptor / source validation
    -> B2 module graph + lifecycle
    -> pweb.invoke -> scheduler -> CAP-8 policy -> mORMot -> 42
```

## Checkpoint-1 decisions (human-ratified 2026-08-26)

**D1 — package name `plugins.zip`.** Not `.pwb`: `app.pwb` carries a
frozen bundle contract (`manifest.json` + `index.html` + the CAP-6
compatibility predicate) and a structurally different archive must not
share its extension. Located at `Executable.ProgramFilePath`, the same
executable-relative rule `app.pwb` already follows.

**D2 — `plugin.json` STAYS inside each plugin root.** This deviates from
the brief's layout sketch and was ratified explicitly. The frozen CAP-9B1
loader reads `PWEB_PACKAGE_MANIFEST` at the package root and refuses the
package with `plcManifestMissing` without it; removing it would
re-baseline frozen B1/B2 semantics. It carries no authority: the eight
security-authority key names are refused loudly before engine creation,
and `id`/`entry` must match the native descriptor byte-exactly. Layout:

```
plugins.zip
├── quickjs.calculator/{plugin.json, main.js, lib/*.js}
└── quickjs.reporting/{plugin.json, main.js, lib/*.js}
```

Confinement reuses the existing `TPWebScopedAssetStore` with prefix
`'<PluginId>/'` over ONE `TZipAssetStore`.

**D3 — integrity: whole-archive SHA-256 + a semantic inventory digest**,
both compiled into the generated registry. TOCTOU is closed by
construction rather than by locking: ONE handle, the file read once in
bounded chunks with the digest updated as the buffer fills, and those
same bytes handed to `TZipAssetStore`. There is no second read to race.
Symlink/reparse indirection is refused (`O_NOFOLLOW` on POSIX,
`FILE_ATTRIBUTE_REPARSE_POINT` on Windows).

**MEASURED CONSTRAINT that shapes the evidence.** CAP-6/CAP-7L already
pinned `app.pwb`'s golden hash PER TOOLCHAIN because the mORMot static
DEFLATE object does not emit byte-identical output for x86_64-win64 and
x86_64-linux. Therefore: `plugins.zip` bytes and the archive SHA are
per-target facts, recorded and reported but never four-way compared; the
generated registry is built PER TARGET at build time and never
committed; and what the cross-target gate compares is the SEMANTIC
corpus and the inventory digest, which are toolchain-independent.

**D4 — the generated native registry** is a Pascal include compiled with
`-Fi`, carrying only trusted constants: package file name, package
SHA-256 and byte length, inventory digest, the complete inventory, and
per plugin `PluginId`, `PrincipalId`, archive root, entry point, package
id, module-graph digest, module count, source bytes and both limit sets.
Three hardening decisions inside it:

1. **Capabilities are NOT in the registry.** They come from the CAP-8
   policy keyed by `PrincipalId`, so the packaging path never sees a
   capability and cannot grant one.
2. **Limits are NOT configurable from the build-time list.** The
   generator emits the ratified defaults, so a tampered build-time file
   cannot raise a memory cap or switch a CPU bound off.
3. The registry is passed as a **parameter record**, not read from a
   global, so every refusal branch is provable on a mutated copy.

The include wraps its constants in `{$PUSH}{$J-}` … `{$POP}`: in Delphi
mode typed constants are writeable by default, and a trust anchor a
stray write can edit at run time is not an anchor.

Build-time input is `examples/07-quickjs/plugins.trusted`, in the
repository's existing `key = value` lock-file grammar, read by a strict
hand-written scanner (ASCII, no escapes, bounded, `#` comments, keys
exactly once per block, unknown keys are hard errors, the eight
security-authority key names refused with their own loud code).

**D5 — no second module resolver.** The packager resolves each graph by
running the PRODUCTION `PWebLoadQuickJSPackage` over a folder store and
reading back the authoritative `TPWebModuleGraph`. The frozen B2
normalize/loader callbacks ARE the resolver, so cross-plugin edges,
missing nodes, dynamic/URL/bare imports and every bound are refused at
build time by the same code that refuses them at run time. Packaging
descriptors carry the EMPTY capability set, and a packaging run that
reaches the invocation bridge even once aborts the build.

**D6 — an unreferenced source file is a hard build error** naming the
exact path, and so is an entry outside every registered root. The
archive inventory is exactly the graph plus the manifests.

**D7 — independent plugin publication after whole-package
verification.** Archive corruption, a digest mismatch or an inventory
mismatch rejects the COMPLETE package before any thread exists. Past
that gate one plugin's failure fails only that plugin; the loader
reports an exact per-plugin result either way.

**D8 — staging** is `build/quickjs-release/` holding `plugins.zip`, the
generated registry include, `LICENSE.quickjs`, `package-inventory.txt`
and `package-build-info.txt`. CAP-9C2 places them into the final
layouts; no installer profile and no `.app` layout is touched here.

**D9 — the license artifact** is assembled from the pinned mORMot
subtree by extracting the leading notice block of every file that
participates in the static build (the `compile-all.sh` amalgamation
inputs plus every pinned header they include), each labelled with its
path and the SHA-256 of its LF-normalized bytes, under a factual
provenance header naming the mORMot pin and `QUICKJS_VERSION`. Nothing
is fabricated. One canonicalization is applied and stated in the
artifact itself: line terminators become LF, because the pinned sources
check out CRLF on Windows and LF elsewhere and the artifact must be
byte-identical on four targets.

**D10 — reuse the CAP-6 ZIP primitives, do not extract its writer.**
`PWebBundleWrite` is app.pwb POLICY wrapped around generic mechanics.
The plugin packager reuses every generic piece — `PWebAssetPathValid`,
`UpperCaseReference`, `PWEB_BUNDLE_FIXED_FILE_AGE`,
`PWEB_BUNDLE_DEFLATE_LEVEL`, `TZipWrite.AddDeflated`, the raw
stored-name compare, temp-sibling → self-validate → atomic replace,
`TZipAssetStore` as the production reader — and keeps its own policy.
app.pwb is therefore byte-identical BY CONSTRUCTION, not merely by test.

## Production surface

Two new units, no new kernel interface:

- `src/script/pweb.script.release.pas` — engine-free: registry types,
  trusted-list scanner, canonical inventory and digests, deterministic
  archive writer, Pascal registry emitter, whole-package verifier.
- `src/script/pweb.script.startup.pas` — `TPWebQuickJSPackageLoader`
  (verified registry + store → native descriptors → one CAP-9B2 host per
  plugin → per-plugin startup results) and the build-time graph
  resolution that drives the same production loader.

Two ADDITIVE read-only accessors on frozen classes, both stated in the
freeze check because they are additions to frozen files:

- `TZipAssetStore.EntryCount` / `.EntryName` — enumeration of one
  already-verified archive's own validated index. `IAssetStore` is
  unchanged and gained nothing; without it, "the inventory is exactly
  this" would be an inference from the whole-archive digest rather than
  a check. It is not discovery: it never enumerates a filesystem.
- `TPWebQuickJSPluginHost.GraphProjection` — the published generation's
  module graph as canonical text, so the loader can compare the graph it
  got against the graph its compiled registry pinned instead of
  inferring one from the other.

Tooling: `tools/quickjs/pwebqjspack.pas` (a private build tool with a
fixed argument shape — NOT a public CLI), the shipped plugin corpus
under `examples/07-quickjs/` with its `.gitattributes` LF pin, and the
CAP-9C1 gate.

## Test matrix

`test/cap9c1/quickjsrelease.pas`, C1–C30 plus the adversarial rows,
headless, four targets, one digest. The PRODUCTION package is the one
the repository ships (built by the packager, read through the registry
that same tool generated); every HOSTILE fixture is generated in process
from byte constants. Three rows deserve naming:

- **C9** builds a structurally invalid archive AND a registry whose
  digest and length match it exactly, so the archive parser has to be
  what refuses — the digest cannot mask it.
- **C10** mutates the registry's inventory while leaving the whole-archive
  digest correct, which is the only shape in which the inventory check
  can be the sole line of defence.
- **C27** packages a byte-perfect archive in which one plugin's CODE
  fails, through a raw-module escape the tool itself would refuse. That
  is the only way to exercise the ratified startup semantics honestly.

## CI

Four new steps, one per platform job, before the CAP-7F emitters. Each
stages the release payload TWICE and requires byte-identical output on
that toolchain, compiles the harness WITH the generated registry
include, stages `plugins.zip` beside the executable and runs the matrix
from an unrelated working directory. The emitters record
`quickjs_release_corpus` (must-PASS, never SKIP), `quickjs_release_digest`
and `cap9c1_inventory_digest` (both four-way equality), five
zero-counters, and the per-target archive/registry facts (reported, not
compared). The aggregator gains the required / must-PASS / equality
entries, five zero-counter refusals and three well-formedness refusals
on the fields it deliberately does not compare. The committed negative
selftest grows from 28 to 36 aggregator refusal legs. The divergence
sweep's swept surface grows to include `tools/quickjs/`.

## Out of scope (ratified Never list for this shard)

Plugin discovery, directory scanning, file watching, automatic hot
reload, installation or update, signed third-party packages, a public
plugin package format or API, a public CLI, network fetching, loading
arbitrary paths, modifying `app.pwb` or placing plugin code inside it,
exposing plugin code through `pweb://app`, modifying Windows setup
profiles or macOS `.app` layouts, and closing CAP-9. CAP-9C2 owns the
final release layouts.
