# CAP-9C1 — Final Artifact: QuickJS Production Package and Trusted Release Loader

CAP-9C1 closes on hosted run **33005408374** (2026-08-26, commit `c1bf9f9`,
branch `phase/cap-9/c1-release-package`, baseline `0624b8a`): all six jobs
green, `cap7 aggregate` recording `quickjs_release_corpus: PASS` on every
target and ONE `quickjs_release_digest` `0f1e9c63b952165bad66681d6cd59675f058152a5da7930693979ab313adeadc` equal on
windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64, beside a
second four-way equality on `cap9c1_inventory_digest`
`203dccbd46f57f8de74928d25f1e06524c30d15754e4f55491f22709a3a6be72` — the
same digests independently measured on the Windows dev host, and stable
across three consecutive local runs. The committed negative selftest
reported `36 aggregator refusals + 2 divergence refusals` on the same
run, so all eight new refusal branches are proven red on fixtures before
the real aggregation is trusted.

It builds a deterministic native-only plugin package and the trusted
loader that consumes it, entirely *behind* the frozen CAP-9A engine,
CAP-9B1 package loader and CAP-9B2 lifecycle. Every claim below is
measured — the C1–C30 headless matrix plus the adversarial rows, on four
targets.

## Package contract
`plugins.zip`, beside the executable, resolved through
`Executable.ProgramFilePath` and never the CWD — the rule `app.pwb`
already follows. Deliberately not `.pwb`: a structurally different
archive must not share the extension of a frozen bundle contract.

One deviation from the brief's layout sketch, ratified at Checkpoint 1:
**`plugin.json` stays inside each plugin root.** The frozen CAP-9B1
loader reads it at the package root and refuses the package with
`plcManifestMissing` without it, so removing it would re-baseline frozen
B1/B2 semantics. It is authority-free either way — the eight
security-authority key names are refused loudly before engine creation,
and `id`/`entry` must match the native descriptor byte-exactly. Each
plugin is confined to `'<PluginId>/'` through the existing
`TPWebScopedAssetStore` over ONE `TZipAssetStore`; no new confinement
mechanism, no `IAssetStore` change.

## Deterministic builder
A private build tool (`tools/quickjs/pwebqjspack.pas` — a fixed argument
shape, not a public CLI) reads the trusted build-time list, walks each
plugin root, resolves the graph, packages it, emits the registry and
stages the license. Two properties matter more than the rest:

**There is no second module resolver anywhere in PWeb.** The packager
resolves each graph by running the PRODUCTION `PWebLoadQuickJSPackage`
over a `TFolderAssetStore` and reading back the authoritative
`TPWebModuleGraph`. The frozen B2 normalize/loader callbacks ARE the
resolver, so a cross-plugin edge, a missing node, a dynamic/URL/bare
import and every depth, count and size bound are refused at build time by
the exact code that refuses them at run time. `c13
cross_plugin_import=yes code=specifier` is that refusal.

**A packaging run cannot produce a backend effect.** Descriptors are
built with the EMPTY capability set, the policy the tool constructs
denies everything, and the bridge it constructs refuses and counts — a
nonzero count aborts the build. Combined with the frozen Loading gate,
the tool is structurally incapable of granting a right or reaching a
service.

Determinism reuses the CAP-6 contract verbatim (global bytewise sort,
`PWEB_BUNDLE_FIXED_FILE_AGE`, `PWEB_BUNDLE_DEFLATE_LEVEL`, zip64 refused,
temp sibling → self-validate → atomic replace) and adds raw stored-name,
timestamp and extra-field compares through `TZipRead`, then an
enumeration and full content compare through the production
`TZipAssetStore`. Every gate stages the payload TWICE and requires all
three artifacts to be byte-identical on that toolchain.

An unreferenced source file is a hard build error naming the exact path
(`c14 unreferenced_source=yes code=source_unreferenced detail=…`), and so
is an entry outside every registered root. The archive inventory is
exactly the graph plus the manifests.

## Native registry
A generated Pascal include compiled with `-Fi`, never shipped as a
runtime file. Three hardening decisions are the substance:

- **Capabilities are absent by design.** They come from the CAP-8 policy
  keyed by `PrincipalId`, so nothing in the packaging path ever sees a
  capability, let alone grants one.
- **Limits are not build-time input.** The generator emits the ratified
  defaults, so a tampered build-time list cannot raise a memory cap or
  switch a CPU bound off. The registry additionally refuses a zero CPU
  bound outright.
- **The constants are pinned read-only.** The include wraps itself in
  `{$PUSH}{$J-}` … `{$POP}`: in Delphi mode typed constants are writeable
  by default, and a trust anchor a stray write can edit at run time is
  not an anchor (`c4 registry_readonly_pin=yes`).

Every field is re-validated against its grammar before emission and every
emitted string must be printable ASCII without a quote — a violation is a
refusal, never an escape. Regeneration is byte-identical (`c4
registry_byte_identical=yes`), with no absolute path, timestamp or host
name in the output. The registry reaches the verifier as a PARAMETER, not
a global, which is what makes every refusal row provable on a mutated
copy.

## Package integrity
Whole-archive SHA-256 plus a semantic inventory digest, in that order,
before the archive is parsed at all. **The check/open race is closed by
construction rather than by locking:** ONE handle, opened refusing
symlink/reparse indirection and anything that is not a regular file, the
size bounded before a byte is read, the buffer filled in 1 MiB chunks
with the digest updated as it fills, and those same bytes handed to
`TZipAssetStore`. There is no second read to race. That is why the
verifier materialises under a 64 MiB cap instead of streaming twice — a
deliberate trade, ledgered.

The refusal matrix is complete and each row fails through its own branch:
missing (`package_missing`), truncated and over-long (`package_size`),
digest mismatch (`package_digest`), structurally invalid with a digest
that MATCHES its bytes so only the parser can refuse (`archive_invalid`),
inventory content mismatch with the whole-archive digest still correct so
only the inventory check can refuse (`inventory_mismatch`), a short
inventory, and a registered entry point absent from the inventory
(`registry`, before any file is opened). On every one of them no store
object escapes (`store=no`) and no plugin thread, engine, scheduler
source or descriptor is ever created.

## Module graph
The registry pins a per-plugin graph digest over the plugin id, entry
point, modules in loader order with their content digests, and the sorted
resolution edges. After a generation loads, the loader recomputes it from
the host's own graph projection and the ALREADY VERIFIED inventory
hashes; a mismatch unloads that plugin and never publishes it (`c11
graph_digest_mismatch code=graph_digest running=no`). The bytes gate runs
strictly earlier, which is what keeps tampered code from executing at
all; the graph digest catches a registry that disagrees with the archive
it loaded.

## Trust boundary
Script content reaches identity nowhere. The `claim` export returns a
forged `{principalId, pluginId, capabilities, trustedContent}` object and
changes nothing: `Add` still returns 42 for the allowed principal, the
denied principal is still refused, and `pweb.openExternal` is still
forbidden with `opener_reached=0`. Package integrity is not
authorization — the reporting plugin sits in the SAME archive, passes the
SAME integrity checks, and is refused `forbidden` with the bridge reached
zero times (`c21 denied_bridge_delta=0`).

## Browser invisibility
Proven both ways, and the limits of each are stated rather than papered
over. **Structurally:** a sweep over every file under `src/platform/`,
`src/webview/` and `examples/08-release/` requires zero references to the
release units or to `plugins.zip` — if a future host ever hands the
package store to a scheme handler, that sweep goes red before any runtime
probe would notice. **Dynamically:** seven probe URIs — the plugin
entries, a lib module, a manifest, `plugins.zip` itself, a
percent-encoded traversal and a `../` escape — go through the frozen
CAP-4 `PWebParseAppUri` into the app bundle store, the exact route a
platform resource handler takes; every one is not-found, the app bundle
carries no plugin entry at all, and the plugin store's arrival counter
does not move (`c22 browser_store_arrivals=0`). The CAP-8B audit's lesson
is the reason that counter exists: an absent public shim is not an
isolation test, so what is asserted is the number of times the browser
side actually reached these bytes. The native loader can still read the
same bytes (`c22 native_read_ok=yes`).

## Plugin startup
Ratified: independent publication after whole-package verification.
Archive corruption, a digest mismatch or an inventory mismatch rejects
the COMPLETE package before any thread exists; past that gate one
plugin's failure fails only that plugin. `c27` proves it with a
byte-perfect archive in which one plugin's CODE fails — built through a
raw-module escape the tool itself would refuse, because that is the only
honest way to reach the case: the broken plugin reports
`code=load package=evaluate running=no`, the healthy one answers
`ok:42`, and `running=1`. `c26` proves the same for a blown resource
bound: a runaway export ends on its CPU limit (`resource_limit`), the
tainted generation refuses the next call (`unavailable`), the host lands
in `failed`, and the neighbour is untouched.

## License
`LICENSE.quickjs`, assembled from the pinned mORMot subtree with nothing
fabricated: the leading notice block of all seventeen pinned files that
participate in the static build (the `compile-all.sh` amalgamation inputs
plus every pinned header they include), each labelled with its path and
the SHA-256 of its LF-normalized bytes, under a factual provenance header
naming `QUICKJS_VERSION 2021-03-27` and the mORMot pin
`b1a129b09197b6b9fb67c6d4d2a13445987a3fe1`. One canonicalization is
applied and the artifact says so about itself: line terminators become
LF, because the pinned sources check out CRLF on Windows and LF elsewhere
and this artifact must be byte-identical on four targets. `c30` verifies
presence, LF-only, the exact MIT permission sentence, the recorded pin,
seventeen sections and all seventeen digests against the pinned files
themselves — an independent check, not a re-run of the generator.

## Cross-platform CI
Four new steps, one per platform job, before the CAP-7F emitters. Each
builds the packager, stages the payload twice and requires byte equality
on that toolchain, compiles the harness WITH the generated registry
include — so "the registry compiles on every target" is proven by the
gate rather than asserted — stages `plugins.zip` beside the executable so
the production location rule is exercised for real, and runs the matrix
from an unrelated working directory.

**What is compared across targets, and what deliberately is not.**
CAP-6/CAP-7L already MEASURED that the mORMot static DEFLATE object emits
different bytes for x86_64-win64 and x86_64-linux — `app.pwb`'s golden
hash is pinned per toolchain for exactly that reason. Requiring archive
equality across targets would therefore be requiring something untrue,
and the closure run confirms it independently for this archive: THREE
distinct DEFLATE outputs across four targets, with the two Darwin arches
agreeing exactly as CAP-7M1 found for `app.pwb`.

| target | plugins.zip sha256 | bytes | generated registry sha256 |
|---|---|---|---|
| windows-x86_64 | `9aaedad766d17acad5100cdac3545550954407f5bcca096bf0be3a06df4350af` | 2798 | `3f9d8ce511d619b0c68f07787ca563b7f013e2cedea399dd7f25a1e46a6198d8` |
| linux-x86_64 | `b0d1530996ffe3170c5788fa3852f95929f0982f5c335c9a66afdc168f571941` | 2787 | `950498e08777cfe627d2397ca5ff980c2534c200341fdfe6273dde9961194a6d` |
| macos-x86_64 | `bac775523790952e782b33b3c2285ceaa22311e82a60cf1d13893d57ec43206f` | 2798 | `c09cc3475e91f4317df8505d4a83e5ee50a528ec2a71683847fe4e7c01812c40` |
| macos-arm64 | `bac775523790952e782b33b3c2285ceaa22311e82a60cf1d13893d57ec43206f` | 2798 | `c09cc3475e91f4317df8505d4a83e5ee50a528ec2a71683847fe4e7c01812c40` |

That table is the whole argument for generating the registry per target:
a committed archive digest could not have been true on more than one row
of it. The gate compares the SEMANTIC corpus and the inventory digest,
which are toolchain-independent, and REPORTS these per target. The
reported fields are not left unchecked: the aggregate refuses a malformed
digest or a zero-byte package on its own, which is the leg that keeps a
reported-but-not-compared field from becoming a field nobody reads.

`LICENSE.quickjs` is the counter-example that proves the LF decision was
necessary and sufficient: `8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc`
on ALL FOUR targets, assembled from pinned sources that check out CRLF on
Windows and LF everywhere else.

The emitters record `quickjs_release_corpus` (must-PASS, never SKIP),
two four-way digests and five zero-counters; the aggregator gains five
zero-counter refusals plus three well-formedness refusals, and the
committed negative selftest grows from 28 to 36 legs. The divergence
sweep's swept surface grows to include `tools/quickjs/`.

## Adversarial review
The sixteen challenge questions were answered against the code, and the
diff was then re-read for defects the questions do not cover. Five were
confirmed and fixed, and three of them only because the questions forced
a second look:

- **The generated registry was writeable at run time.** In Delphi mode a
  typed constant is writeable by default, so the compiled package digest
  — the entire trust anchor — sat in mutable memory. The include now
  wraps itself in `{$PUSH}{$J-}` … `{$POP}`, and a row asserts the pin is
  present in the emitted text.
- **The read-and-hash function was one body stitched from conditionals**,
  with a `try` opened separately in each arm and the common path
  following. It compiled and worked, but security code whose control flow
  is hard to follow is a defect in itself; it is now two whole platform
  bodies, the ratified `TFolderAssetStore` shape, and the divergence count
  fell from 16 to 10.
- **`tools/quickjs/` was outside the divergence sweep.** A build tool that
  decides what ships is production surface; the swept surface now
  includes it, and both new files carry ratified counts and fingerprints.
- **The POSIX runner expanded possibly-empty arrays under `set -u`**,
  which bash 3.2 (macOS `/bin/bash`) refuses — it happened to work only
  because the array that is empty on Linux is non-empty on Darwin. One
  per-platform `compile_pas` function replaced the shared arrays.
- **The POSIX open cast the system string to a byte string** and
  classified a failure by an errno constant whose defining unit varies.
  It now converts through `StringToUtf8` and classifies with
  `FileExists`, which is also correct for a symlink refused by
  `O_NOFOLLOW`.

Three questions produced new evidence rather than fixes, because the
answer was yes-in-principle and needed a row: a hand-built archive whose
module imports a SIBLING plugin (refused at run time by the frozen
resolver, `q8 package=specifier`, neighbour unaffected); an archive
carrying a root the compiled registry never registered (refused as a
whole before any file is opened, `q9 code=registry`); and a DIFFERENT
perfectly valid archive offered against the compiled pin (`q11`,
refused). A fourth added the mirror of the unreferenced-file rule — a
graph node the walk never produced (`c14 graph_node_not_walked`).

**Recorded rather than dressed up:** `prcRegistryEmit` cannot fire
through the public API, because emission re-runs the whole registry gate
first and every registry string is already a constrained grammar. The
injection rows therefore record `code=registry`, the FIRST gate, and
assert exactly that. It stays as the last line between a future
unvalidated field and generated Pascal — the same category as CAP-9B1's
`plcThread`/`plcEngine`.

**A silent RTL defect found during bring-up**, ledgered because it cost
real time and will cost it again: the FPC RTL `FindFirst` on Windows
refused the packager's concatenated root with `ERROR_PATH_NOT_FOUND`
while mORMot's own `DirectoryExists` accepted the very same bytes, so the
failure surfaced as "plugin source root is empty" rather than as an
error. `tools/bundler/pwebbundle.pas` already carries the identical
finding in a comment; the packager now uses the wide Win32 API on
Windows, as it does.

## Regressions
On the closure run, `quickjs_lifecycle_digest` `6c8d0bd7147cadb384ff06e8841b17212a6a1fa550a978c31d23ba1f1a785131`,
`quickjs_package_digest`
`4b01cf06677ff52fb26c74b031c72282258f26b7c5b44bd44131586c77209c45` and
`quickjs_corpus_digest`
`601b86ffd24d5642174758120d58d240da6e5cc0d4e0cc3a40b3ec0847e7909f` are
**byte-identical** to the CAP-9B2, CAP-9B1 and CAP-9A closure values on
all four targets — which is the proof that both additive accessors are
genuinely additive: `TZipAssetStore.EntryCount`/`.EntryName` moved no
CAP-4/CAP-6 behaviour and `TPWebQuickJSPluginHost.GraphProjection` moved
no lifecycle behaviour. `security_corpus_digest`
`c5fc378bc3c6eb6aa6db753e35287db5cb7ed6332aeac77b75767919e5adbdf4` and
`capability_policy_digest`
`23b87da524b158f4b1a8ca53057ad794f485086257997534b426b28334bddb2f` are
likewise unchanged from the CAP-8 closure. `pwebtests` 2419/2419
assertions pass — the suite that carries `app.pwb`'s per-toolchain golden
hash, so C17 is proven by the gate that owns it rather than by a copy.
The divergence sweep reports 84 platform conditionals (68 + 10 + 6), all
inside the ratified allowlist.

## Freeze check
Seven interfaces, `pweb.rpc.intf.pas`, scheduler/source lifecycle,
`TInvocationContext`, CAP-8 policy/navigation, bridge + mORMot adapter,
error taxonomy, protocol v1, SDK wire, `app.pwb` schema and golden
corpus, platform adapters, the JSValue ABI, the mORMot pin (`b1a129b0`,
`src`/`res` pristine) and the QuickJS source pin: untouched. The three
Phase-0 contract units are byte-identical to baseline
`b2f04dc4c478c72b1699a954dd52e76b207e918b`. `IAssetStore.TryRead` is
unchanged and gained no enumeration — the two ADDITIVE read-only
accessors this shard adds are on CONCRETE classes and are named here
because they are additions to frozen files:
`TZipAssetStore.EntryCount`/`.EntryName` (enumeration of one
already-verified archive's own validated index, so the exact-inventory
requirement is a check rather than an inference from the digest; it never
enumerates a filesystem) and
`TPWebQuickJSPluginHost.GraphProjection` (the published generation's
graph as canonical text, read under `FLifeLock` exactly like
`ExportNames`). Neither changes any existing behaviour, and the three
frozen QuickJS digests prove it. No new public kernel interface, no new
permission path, no new RPC path.

## Known limitations / deferred
See `deferred-work.md` (CAP-9C1 entries): CAP-9C2 owns the final release
layouts and the CAP-9 closure; discovery, watching, installation, update,
signed third-party packages, a public package format and a public CLI
remain unbuilt by ratified decision; the archive is deterministic per
toolchain and not across them, which is why the registry is generated per
target; `prcRegistryEmit` is unreachable through the public API; the
verifier materialises under a 64 MiB cap by design; the linear
cross-check scans only matter far above the ratified bounds; and the
`ci.yml` documentation-budget overage is carried forward (160 KB).

Two browser-invisibility claims in the brief are proven INDIRECTLY and
are worth naming: "script tags for those paths never execute" and "raw
WebKit/WebView channels cannot request plugin-store bytes" are not driven
through a real WebView here, because CAP-9C1 ships no host — what is
proven is that the plugin store is never handed to a handler
(structurally, over the whole platform surface) and that the app store
answers not-found on the exact CAP-4 route a handler takes, with zero
arrivals counted. A GUI probe belongs with CAP-9C2, where a real release
host exists to drive.
