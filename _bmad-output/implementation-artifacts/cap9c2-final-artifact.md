# CAP-9C2 — Final Artifact: the plugin-enabled desktop application, and the close of CAP-9

CAP-9C2 closes on hosted run **33041381535** (2026-08-27, commit `7a8864b`,
branch `phase/cap-9/c2-gui-release`, baseline `61c7a46`): all six jobs
green, `cap7 aggregate` recording `quickjs_gui_corpus: PASS` on every
target and ONE `quickjs_gui_digest`
`c262c01faf3cb96179948aac9edc5da4c0941ed8751779567e5af18fe85f1e3c`
equal on windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64 —
the same digest independently measured on the Windows dev host. The
committed negative selftest reported `51 aggregator refusals + 2
divergence refusals` on the same run, so all fifteen new refusal
branches are proven red on fixtures before the real aggregation is
trusted.

It puts a real WebView UI and two isolated QuickJS plugins in ONE
desktop process, over ONE scheduler, ONE CAP-8 policy, ONE bridge chain
and ONE mORMot server, in an exact release layout on all four targets —
and it closes the two CAP-9C1 claims that were, by that shard's own
admission, proven only indirectly.

## The topology, and how identity is proven

```
  real WebView UI ──▶ pweb://app ──▶ TypeScript SDK ──┐
                                                      ├─▶ ONE scheduler
  verified plugins.zip ──▶ generated native registry ─┘        │
        └─▶ isolated QuickJS plugin generation                 ▼
                                              ONE CAP-8 policy ─▶ ONE bridge
                                                                 ─▶ ONE mORMot
                                                                 ─▶ Add = 42
```

Both sources answer 42, but CAP-9's contract is one architecture, not
merely equivalent output — so identity is MEASURED four ways and none of
them is "the code only constructs one":

- **`same_scheduler`** is answered by the scheduler ITSELF.
  `TryGetSourceCounts` returns False for a source a scheduler did not
  create, so the gate asks the one scheduler about the UI source and
  about every plugin source, and then asks a SECOND, equally configured
  decoy scheduler the same questions and requires False from all of
  them. Without the decoy row the predicate could answer yes to
  everything and nobody would know.
- **`same_policy` / `same_bridge`** compare an identity token recorded
  when a `pkWindow` invocation is checked against the token recorded
  when a `pkQuickJS` one is, plus an instance count of exactly 1. The
  tokens are small ordinals from a host-private first-seen table; no
  address ever leaves the process.
- **`same_server`** is the one that had to be rewritten after it lied.
  Counting service instances in a constructor counted NOTHING, because
  mORMot instantiates a `sicShared` implementation through the
  non-virtual `TInterfacedObject` constructor — the row read
  `instances=0` and would have read it forever. It now records the
  identity token from INSIDE `Add` and counts mismatches: every `Add`
  that ever ran, from either source, ran on the same object or the row
  goes red.

## The two archives are two security domains

`app.pwb` is browser content served through `pweb://app`. `plugins.zip`
is native package content read only by the QuickJS subsystem. They are
two different variables in `quickjsapp.pas`, each behind its own
counting `IAssetStore` decorator, and neither is ever assigned from the
other. The platform asset handler's constructor takes the APP store at
every one of its three platform call sites; the package loader takes the
PLUGIN store, once.

That is the construction. The measurements are what settle it:

| gate | measured |
|---|---|
| `browser_plugin_store_arrivals` | plugin-store reads during the whole browser-probe window: **0** |
| `browser_app_store_reads` | the app store did serve the page, so the refusals above mean "denied", not "no transport" |
| `quickjs_app_store_arrivals` | app-store reads across every serialized plugin-export window: **0** |
| `plugin_cannot_read_app_index` / `_app_asset` / `_escape_root` | the calculator's own scoped store refuses `index.html`, `assets/app.js` and `../quickjs.reporting/main.js` |
| `plugin_reads_own_module` | and still serves `main.js`, so the confinement is a boundary and not a broken store |

## Browser invisibility, driven from a real page

CAP-9C1 said plainly that two of its claims — "script tags for those
paths never execute" and "raw channels cannot request plugin bytes" —
were proven indirectly because it shipped no host. Both are now driven
through the real platform WebView on all four targets, from the trusted
`pweb://app` document:

- **nine asset probes**, all refused, `assetServed=[]`: `plugins.zip`
  itself, the calculator entry and leaf module, its manifest, the
  reporting entry, a bare `main.js` that exists ONLY inside the archive,
  the archive-root spelling, a percent-encoded `%2e%2e` traversal and a
  `assets/../` escape;
- **four script tags** — classic and `type="module"`. The module form on
  the LEAF module is the load-bearing one: it is the only module in the
  corpus with no import of its own, so it is the only one whose top
  level would actually run if the bytes were ever served. That is also
  where the browser-execution marker lives, and
  `browser_plugin_script_marker` asserts the global stays absent after
  every attempt has settled;
- **an iframe and an image** for the non-script subresource shapes;
- **the raw engine channel** — `window.__webview__.call`, one level
  below the bound global, which CAP-8B measured reachable from the
  trusted top document on every engine. Three plausible plugin-read
  method names go through it and three through the public SDK. All six
  are refused, and the refusal CODES are recorded rather than forced:
  `pweb.plugin.read` and `pweb.plugins.getSource` fail the frozen
  method grammar at the enqueue gate (`invalid_request` — an earlier
  refusal than the policy's), while the well-formed unmapped
  `PluginService.Read` reaches the policy and is `forbidden`. Both read
  no bytes; pretending they were the same code would be tidier and less
  true.

Every response and every error is scanned for three things: plugin
source tokens, an absolute path or the archive name, and any 64-hex run
that could be a digest. `sourceBytes`, `leakedPath` and `leakedDigest`
are all 0.

Inside QuickJS the complement is asserted from the sandbox rather than
inferred: `window`, `document`, `webkit`, `chrome`, `external`, `fetch`,
`std`, `os`, `__pweb_invoke` and `__pweb_invoke_json` are all
`undefined`, the marker global is `undefined`, and `pweb` is an object.
Nothing in the sandbox was changed to make that true — the shim already
deletes the raw callback at bootstrap, and `__pweb_invoke` is the
WEBVIEW binding name, never registered on a plugin engine.

## Concurrency that is a counter, not a coincidence

The UI and a plugin are forced to overlap by a barrier INSIDE
`CalculatorService.Add`: both invocations must be in the one service
instance at the same time before either may leave. `peak_in_service`
reaches 2 and the bridge independently records that an arrival of one
principal kind found the other already in flight. No sleep produces any
of it.

Two rounds run. The first uses DISTINGUISHING operands — the UI asks
`Add(1,2)` and the plugin asks `Add(5,6)` — so a crossed completion
would show up as a swapped number rather than as two identical 42s;
`no_cross_delivery` asserts neither result appears on the other side.
The second is the canonical `Add(20,22)` from both.

The plugin call is issued only once the bridge has actually SEEN the UI
invocation. That handshake is not politeness: a plugin blocked in a
synchronous `pweb.invoke` is still inside its own `Evaluate` call, so a
slow peer would be answered by the plugin's CPU bound instead of by the
barrier.

## Containment in the real GUI process

| leg | outcome |
|---|---|
| CPU bound (`runaway`) | `resource_limit`, generation tainted, next call `unavailable`, host `failed` |
| neighbour | calculator still answers 42 |
| UI | still answers 42, over a fresh invocation on the real transport |
| memory bound (`memhog`) | `resource_limit`; UI still 42 and the scheduler still usable |
| reload | generation id 1 → 2, result stays 42, UI works during and after |
| unload | reporting unloaded; UI and calculator unaffected |

The CPU leg costs the ratified `TimeoutSeconds = 10` once per target and
is deliberately the only such leg; the exhaustive limit corpus belongs to
CAP-9A/B2 and is re-run green in the same job.

## Startup is fail-closed, and the negatives prove it on the real layout

The order is: resolve and validate `app.pwb` from the executable/bundle
location → resolve `plugins.zip` the same way → whole-archive SHA-256 →
semantic inventory → registry coherence → services → policy → bridge →
scheduler → plugin manager → publish → WebView → navigate → gates.
Everything through registry coherence happens before the first service
exists.

The negative matrix mutates `plugins.zip` in the ASSEMBLED release and
re-launches the shipped binary: missing (`package_missing`), truncated
and over-long (`package_size`), same-length-different-bytes so only the
digest can refuse it (`package_digest`), and a symlink where a regular
file must be (`package_unreadable`). Each requires a controlled nonzero
exit, the typed marker, `webviews_created=0` and `soa_calls=0` read from
the process itself, and no PASS marker anywhere. The layout is then
restored and proven green again, so no later row is vacuous.

Two ratified rows are NOT reachable from outside a compiled host and are
recorded as such rather than quietly omitted: a structurally invalid
archive whose digest MATCHES its bytes, and an inventory/registry
disagreement behind a correct digest. Both need the registry to be a
PARAMETER so the expectation can be mutated instead of the bytes, which
is exactly how CAP-9C1 proves them, in the same job. The corpus carries
`negative_inventory_and_registry=cap9c1` so a reader is never left to
infer coverage that is not there.

## The hostile-package harness, and why it is a second program

`archive_valid = true, running_plugins = 1, failed_plugins = 1` is
structurally unreachable from the shipped host, and that is a property of
the design: its compiled registry pins one archive digest, so a
substituted archive fails as a WHOLE, and the private packager refuses to
build a plugin whose graph will not load because it resolves every graph
by running the production loader. `test/cap9c2/quickjsgui.pas` therefore
builds both the archive and its matching registry — CAP-9C1's `c27`
mechanism, reused — and drives them in front of a REAL WebView.

It shares every production component that matters: the deterministic
archive writer, the registry assembler, the whole-package verifier, the
package manager, the B2 lifecycle owner, the scheduler, the CAP-8 policy,
the mORMot bridge and the platform WebView adapters. There is no second
verifier and no second registry generator in it.

- **H1** — one valid plugin beside one whose CODE fails
  (`code=load package=compile`): `running=1 failed=1`, healthy plugin
  answers 42, failed one never published, and its SOURCE is closed —
  asked of the scheduler, which stops tracking a source at `pssClosed`,
  so exactly as many of the leg's minted sources remain owned as there
  are running plugins.
- **H2** — a plugin importing an app asset path: refused at the package
  root (`package=specifier`, `main.js -> ../../index.html`), never
  published, with the app store's counter unmoved. There is no
  cross-store fallback to fall back to.

The real WebView answers 42 before, between and after both legs.

## Release layouts

Exact sets, enumerating files AND directories AND symlinks — "smallest
possible" is a claim that rots silently otherwise.

| target | layout |
|---|---|
| windows-x86_64 | `quickjsapp.exe app.pwb plugins.zip webview.dll LICENSE.webview LICENSE.webview2sdk LICENSE.quickjs` |
| linux-x86_64 | `quickjsapp app.pwb plugins.zip libwebview.so.0.12 LICENSE.webview LICENSE.quickjs` |
| macos-x86_64 / macos-arm64 | `PWebQuickJS.app/Contents/{Info.plist, MacOS/{quickjsapp, libwebview.0.12.dylib}, Resources/{app.pwb, plugins.zip, LICENSE.webview, LICENSE.quickjs}}` |

The generated registry is compiled in with `-Fi` and asserted ABSENT
from every layout. No loose `plugin.json`, `main.js`, module file,
plugin folder, frontend dist or compiler output survives the exact-set
comparison. The CAP-6/CAP-7L/CAP-7M2 layouts and the three CAP-13
installer profiles are byte-untouched: the plugin-enabled layout is a
separate directory, and CAP-10 owns deciding which generated
applications include plugins.

## Corpus supersession, stated plainly

Extending the shipped acceptance plugins with the exports a real GUI
process needs — the browser-execution marker, the `env` probe, `memhog`,
`runaway` and `alive` — necessarily moved every value derived from those
bytes. The CAP-9C1 CONTRACT is unchanged and its full gate is re-run
green against the extended corpus; what moved is measurement.

| value | CAP-9C1 (superseded) | CAP-9C2 |
|---|---|---|
| `cap9c1_inventory_digest` (four-way) | `203dccbd46f57f8de74928d25f1e06524c30d15754e4f55491f22709a3a6be72` | `12e279ab4b6c6b7fb946f622966893fd2d913cb2d5759b3a937875e30f112ed3` |
| `quickjs_release_digest` (four-way) | `0f1e9c63b952165bad66681d6cd59675f058152a5da7930693979ab313adeadc` | `715bd605c90676c7851c247611363117f5b5666b5f39bee9d9aa830e0e56bada` |
| calculator graph digest | `615e347ff44c9f10668be46d52b62ba18f04850a95f224ead7ccd223ca3a8163` | `9305a37a9b6f6953729d6a7c0e83a2820acdad3fee5d840152a37f90efc90d01` |
| reporting graph digest | `9758afdb9979fecbdf2569fb06dbb937143e239f069cb51f3b33af2a34ab5dbc` | `e1ecb50fef4f334db4ea3edcd08ef8847c44238b393f5f6d67a2dd8155f4c6b7` |
| `LICENSE.quickjs` | `8310e7a6…fbe2fc` | **unchanged** — it derives from the mORMot pin, not the corpus |

The per-target archive bytes moved with them and still show exactly the
shape CAP-9C1 measured: three distinct DEFLATE outputs across four
targets, with the two Darwin arches agreeing.

| target | plugins.zip sha256 | bytes | generated registry sha256 |
|---|---|---|---|
| windows-x86_64 | `84ee814c9b98eed579595135d018c76bc3df47f134588faa153ba4330895429b` | 4282 | `2acd2a356aaf97062232d04e48f4ea84ff59e0e32f32156d26e1761fabfca767` |
| linux-x86_64 | `d0bb61cfd7edb1c99271d549eea7ad955d915e1ce73e9072473e2bbeafcab0f3` | 4260 | `43b78899f369d1d729b313380145c6d4497712a77e0afb16bc0f31f41ab05ec2` |
| macos-x86_64 | `a06e9c17ec841af686bad31367a3d46f603adec87b79710897cac1e1cc1f4d44` | 4282 | `eb10b08a202cd308d8296e5c3917305f28a67920a15e652e82a64f1d6010cfdd` |
| macos-arm64 | `a06e9c17ec841af686bad31367a3d46f603adec87b79710897cac1e1cc1f4d44` | 4282 | `eb10b08a202cd308d8296e5c3917305f28a67920a15e652e82a64f1d6010cfdd` |

## Evidence design

The corpus is split from the log ON PURPOSE. The CORPUS carries only
what must be identical on every target — a gate's verdict, an identity,
an ordering — because it is hashed into one digest the aggregator
requires equal on all four. The LOG carries the same row plus its
measured detail, which is exactly the part that legitimately differs:
how many asset reads a particular engine made, what a result JSON looked
like. Hashing the detail would turn honest per-engine variation into a
cross-target failure.

Thirty-one semantic gates travel individually into `cap9c2_gates` so the
aggregator can refuse one BY NAME instead of only noticing that a digest
moved, and the rule it applies is deliberately trivial: every field must
read exactly `yes` on every target, and an ABSENT field is refused like a
red one. The one machine-dependent fact — whether a file symlink could
be created for the reparse-point negative — is carried as its own field
which the aggregator requires to read `yes`, so a waiver is recorded
honestly by the runner and never promotes, exactly like a SKIP.

## Adversarial review

The eighteen challenge questions were answered against the code, and
three produced new gates rather than citations: a source sweep proving
`quickjsapp.pas` names no `GetCurrentDir`/`SetCurrentDir`/`ChDir` and
does resolve from `Executable.ProgramFilePath`, and a sweep over both
programs proving no `FindFirst`/`FindNext`/watch API appears anywhere —
properties of ALL inputs, which no runtime test can establish.

Four defects were found and fixed, and three of them were found only
because a row was failing that should not have been:

- **The service barrier never waited.** Its loop re-signalled the event
  it was waiting on, so a 20-second budget was spent in microseconds and
  `concurrent_overlap` reported "no overlap" for a run that had simply
  never waited. Both waits are now written against `GetTickCount64`.
- **The render gate counted attempts instead of seconds.** Each probe
  returns as soon as its own report lands, so "sixty attempts" collapsed
  to about three seconds — long enough for React to mount on a fast
  developer machine and not on a hosted runner, where every other row
  was green and this one alone was red. Same defect as the barrier, same
  fix.
- **`same_server` counted nothing.** See above: a constructor count on a
  `sicShared` mORMot implementation is always zero, and a gate that can
  only ever read zero is worse than no gate.
- **The acceptance page came up blank.** Importing the canonical CAP-5
  `App` across the example boundary made node resolve its `react` from
  `examples/04-react/frontend/node_modules` while the importing page
  resolved its own — two React instances in one bundle, "invalid hook
  call" during the first render, no build error and no console anyone
  reads. `build.mjs` now pins the three shared packages through esbuild
  `alias`. The `ui_rendered` gate was hardened at the same time to
  require BOTH acceptance elements rather than a non-empty document: the
  empty-body false positive is what hid it.

**And one confirmed SECURITY defect, in production code, found exactly
where this shard was told to look.** Question 5 — "can a plugin package
fall back to loose source files?" — generalises to "can the package be
reached through indirection?", and the CAP-9C2 negative matrix is the
first thing that ever pointed a REAL symlinked `plugins.zip` at a REAL
Windows release layout. The host accepted it and exited 0.

`pweb.script.release.pas` opened the archive with
`CreateFileW(..., OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0)` and then
refused `FILE_ATTRIBUTE_REPARSE_POINT` on the resulting handle. Without
`FILE_FLAG_OPEN_REPARSE_POINT`, Windows FOLLOWS the link and returns a
handle to the TARGET — whose attributes naturally carry no reparse bit —
so the check could never fire, and the archive was read through the
indirection the check exists to refuse. The POSIX body was always
correct (`O_NOFOLLOW`), and CAP-9C1 shipped the check believing both
were. Practical exposure is bounded by the digest, which still had to
match, so the reachable case is redirecting the package to another
location holding a byte-identical archive; the point is that a
documented refusal was inoperative on one platform for a whole shard.
Fixed by adding the flag, which is a no-op on an ordinary file and
preserves the one-handle/no-second-read property exactly. `negative_reparse`
is now a required-`yes` aggregator field on all four targets, so it can
never silently regress.

The neighbouring `TFolderAssetStore` was checked for the same shape and
does not have it: it re-proves confinement by comparing the kernel's
FINAL normalized path of the open handle against the expected path,
which also covers junctions and 8.3 aliases. That precedent is why the
minimal flag fix was preferred here over re-deriving a second mechanism.

One platform defect surfaced on the hosted Linux runner and is worth
recording because it is the first of its kind here: CAP-9C2 is the first
Linux binary linking BOTH the pinned `quickjs.o` and `libwebview`.
`quickjs.o` references `__divti3`, a libgcc intrinsic; with quickjs alone
the linker resolved it from the `libgcc_s` it pulls in implicitly, but
once libwebview joined the line `ld` refused with `libgcc_s.so.1: error
adding symbols: DSO missing from command line`. Naming it (`-k-lgcc_s`)
is the documented fix.

## Regressions

On the closure run the frozen digests are byte-identical to their
recorded closure values on all four targets: `quickjs_corpus_digest`
(CAP-9A), `quickjs_package_digest` (CAP-9B1), `quickjs_lifecycle_digest`
(CAP-9B2), `security_corpus_digest` and `capability_policy_digest`
(CAP-8), and `navigation_policy_digest` (CAP-8B). The CAP-9C1 gate is
re-run green against the extended corpus; its two four-way digests moved
by deliberate supersession and are tabulated above. `pwebtests` passes,
the CAP-7 release regressions pass unchanged, and the divergence sweep
reports 118 platform conditionals (84 + 34 for the new host), all inside
the ratified allowlist.

## Freeze check

Seven interfaces, `pweb.rpc.intf.pas`, scheduler/source lifecycle,
`TInvocationContext`, CAP-8 policy/navigation, bridge + mORMot adapter,
error taxonomy, protocol v1, SDK wire, `app.pwb` schema and golden
corpus, platform adapters, the JSValue ABI, the mORMot and QuickJS pins,
the CAP-9A engine/thread/invocation model, the CAP-9B1 package/module
contract, the CAP-9B2 lifecycle/reload contract and the CAP-9C1
plugins.zip/registry/integrity contract: untouched.
`examples/08-release/releaseapp.pas` and `examples/04-react/**` are
byte-untouched. No new public interface, no new native WebView export,
no new RPC method, and nothing that reads plugin content over the wire.

`src/` carries **exactly one** CAP-9C2 change, and it is the security fix
above: one flag added to one `CreateFileW` call inside
`pweb.script.release.pas`, so that the reparse-point refusal the unit
already documented becomes reachable on Windows. No signature, no code,
no diagnostic string and no contract moves — the refusal was always
specified as `package_unreadable` / 'reparse point refused'; it simply
could not happen. The CAP-9C1 gate re-runs green with byte-identical
digests after it, which is what confirms the change is inert for every
legitimate archive, and the divergence sweep is unmoved at 118
conditionals because the constant went inside the existing
`{$ifdef WINDOWS}` body rather than adding a region.

## Known limitations / deferred

See `deferred-work.md` (CAP-9C2 entries): the deliberate corpus
supersession; the two negative rows unreachable from outside a compiled
host; the CAP-13 boundary; the machine-dependent reparse leg; no
plugin-enabled Pas2JS product; the cross-example React resolution
hazard; the division of proof with CAP-9B2 for late completions and
two-active-generation; the forced-barrier measurement shape; and the
`ci.yml` documentation-budget overage carried forward (167 KB).
