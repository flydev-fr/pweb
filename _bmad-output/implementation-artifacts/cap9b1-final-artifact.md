# CAP-9B1 — Final Artifact: QuickJS Package and Module Loader

CAP-9B1 closes on hosted run **32975110018** (2026-08-26, commit
`e62331d799c809aefe771a48ff4d1010ff6bf815`, branch
`phase/cap-9/b1-plugin-package-loader`, baseline `b04caf1`): all six jobs
green, `cap7 aggregate` recording `quickjs_package_corpus: PASS` on every
target and ONE `quickjs_package_digest`
`4b01cf06677ff52fb26c74b031c72282258f26b7c5b44bd44131586c77209c45` equal
on windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64 — the same
digest independently measured on the Windows dev host, and stable across
three consecutive local runs. The run's commit is the branch head and
contains the final implementation commit `a190677`
(`fix(script): harden the CAP-9B1 package loader per adversarial review`).
The committed negative selftest reported `21 aggregator refusals + 2
divergence refusals` on the same run, so the new refusal branches are
proven red on fixtures before the real aggregation is trusted.

It builds a package/module-loader layer *behind* the frozen CAP-9A engine.
Every claim below is measured — the P1–P40 headless matrix on four
targets, plus a Checkpoint-1 probe against the pinned tree.

## Package carrier
One existing `IAssetStore` per plugin package — no interface change, no
enumeration added, no filesystem/archive/platform API anywhere in the
loader. `TFolderAssetStore` and `TZipAssetStore` (built in memory from the
same bytes) run the identical corpus: every one of the ~60 corpus rows
carries `parity=yes`, and the reference package's outcome digest — module
list, module hashes, import graph, evaluation result, invocation result,
loader/normalize counts, sandbox projection — is identical between the two
carriers. `TPWebScopedAssetStore` confines a package to a native-controlled
prefix of a shared store; a traversing or embedded-traversal prefix is a
construction-time refusal that never echoes the prefix back, and the
sibling package `plugins/other.plugin/secret.js` is unreachable from inside
`plugins/quickjs.calculator/` while remaining readable through the backing
store (so the test proves confinement, not absence).

## Native descriptor
`TPWebQuickJSPackageDescriptor` — a private record, not a new interface —
carries `PrincipalId`, `PluginId`, `PackageStore`, `ExpectedPackageId`,
`ExpectedEntryPoint`, `Capabilities` and both limit sets.
`PrincipalKind` is not a field because it is not a choice: `CreatePackage`
builds the `TInvocationContext` natively (`pkQuickJS`, `WindowId=''`) and
validates the descriptor before the thread exists. Package content reaches
identity nowhere: a package whose code passes
`principalId`/`pluginId`/`capabilities`/`trustedContent` in its invocation
arguments still gets `42|forbidden|invalid_request` — the clean call
succeeds, `pweb.openExternal` is still refused, and the forged-field call
is rejected by the wire grammar, with `opener_reached=0` counted.

## Plugin manifest
`plugin.json` at the fixed package root, exactly
`{"schema":1,"id":…,"version":"X.Y.Z","entry":…}`, read by a hand-written
strict scanner rather than a general JSON parser: whitespace limited to
space/TAB/CR/LF, **no escape sequence accepted in any string** (all three
values are constrained grammars that never need one), duplicate keys,
unknown keys, NUL, control bytes in strings, non-shortest-form UTF-8,
trailing content and a doubled BOM all rejected, size ≤ 64 KiB. The eight
security-authority key names (`allow`, `capabilities`, `permissions`,
`principal`, `principalId`, `pluginId`, `runtimeGrants`, `trustedContent`)
are matched ASCII-case-insensitively and rejected with their own loud code
*before engine creation* — `CAPABILITIES` fails the same way `capabilities`
does, because an unknown-field rejection would be technically correct and
pedagogically useless. Package ids are `[a-z0-9]+(\.[a-z0-9]+)*`, ASCII,
1..64 bytes, exact case, no normalization (a Cyrillic confusable is
refused). Entry authority is **option B**: native `ExpectedEntryPoint` is
authoritative and the manifest must match it byte-exactly.

## Module resolution
All resolution happens in our `JS_SetModuleLoaderFunc` normalize callback,
because the pin hands the specifier through verbatim and joins nothing
(measured). Relative only; `.`/`..` folded in our own stack so `../` never
reaches `IAssetStore`; explicit `.js`/`.mjs`; byte-exact case; NUL/control,
`\`, `:`, `?`, `#`, `%`, `<>"|*` refused; bounded and finally re-checked by
the CAP-4 `PWebAssetPathValid` gate. Measured green: `../shared/unit.js`
from `lib/calculator.js`, and `./lib/../lib/../lib/calc.js` collapsing to
one load. Measured refused before any store read: root escape, parent
escape, bare, absolute, `https:`, `file:`, protocol-relative, query,
fragment, backslash, directory, missing extension, encoded traversal,
`import "std"`, `import "os"`. `./lib/State.js` resolves *and then misses*
the byte-exact store — case is a lookup property, not a syntax property.

## QuickJS module loader
Exactly one seam: `JS_SetModuleLoaderFunc(rt, normalize, loader, self)` on
the public `TQuickJSEngine.rt`, with the plugin arriving through the loader
opaque. No wrapper replacement, no parallel module system. The loader
mirrors quickjs-libc's shape (`JS_Eval(…MODULE or COMPILE_ONLY)` →
`JSValue.Ptr` → free the value) and deliberately does NOT call
`js_module_set_import_meta` (unnecessary, and its `use_realpath` branch
touches the filesystem). Measured on the pin: the source is **copied** at
compile time, so no module can outlive its buffer; cycles terminate; a
module imported twice loads and executes once (`__stateRuns=1`,
`loader=3 normalize=4` for a four-module graph); the module cache is
per-`JSContext`, so two plugins over the same paths get independent
instances. Top-level `await` is a **SyntaxError** in this pin, so entry
evaluation is always synchronous and no half-loaded async entry can exist.

## Store scoping and thread affinity
Every loader callback, package store read, compile and `JSValue` touch
happens on the owning plugin thread — asserted, not assumed. Both callbacks
compare `GetCurrentThreadId()` against the plugin's `ThreadID`; a counting
store records the first reader and refuses any second thread, cross-checked
against `plugin.ThreadID`. Ledger: `loader_wrong_thread=0`,
`store_wrong_thread=0` across the whole matrix.

## Load-time authority
**Refused.** `pweb.invoke` (and therefore `pweb.handshake`, an ordinary
bridge-routed method) throws `runtime_closed` while the package is Loading.
Both options were measured feasible — a native callback *does* run during
top-level module evaluation — so this is policy, implemented as one flag in
`InvokeJson` with the frozen scheduler/policy path untouched. The reference
package records `__loadInvoke=runtime_closed` and the ledger records
`loadtime_bridge=0`, counted by a bridge decorator armed for the duration
of every load in the matrix.

## Dynamic import
Unavailable rather than blocked. Nothing pumps the job queue, so `import()`
returns a promise that never settles and the loader is never called:
`dynamic_import probe=object|pending|1 loader_before=3 loader_after=3`.
Force-pumping in the Checkpoint-1 probe proved `js_dynamic_import_job` →
`JS_RunModule` → `js_host_resolve_imported_module` routes through the SAME
scoped normalize/loader, so it cannot bypass the resolver even if a future
shard adds a pump; the loader additionally seals the graph once
`FLoadState` leaves Loading. Ledgered, with the `JS_ExecutePendingJob(nil)`
null-write hazard found while measuring it.

## Limits
Manifest 64 KiB · module 1 MiB · total source 8 MiB · 256 distinct modules
· specifier 512 bytes · graph depth 64, clamped between host-supplied
values and hard maxima, all charged **before** compilation so an oversized
graph is refused while it is still bytes. Each bound has a dedicated
minimal fixture so only that bound can fire, plus a chain that loads
cleanly under every bound. The depth bound found a real defect during
implementation: `Charge` re-interned each module at depth 0 and flattened
the graph, so a 6-deep chain loaded under `MaxGraphDepth = 3`; fixed and
now proven by `limit_graph_depth`.

## Package error model
Native `TPWebPackageLoadCode` values, never the nine-code RPC taxonomy.
Script-visible loader throws are **fixed literals with no interpolation**
— the pinned `JS_ThrowReferenceError` is varargs in C but typed
`fmt: PAnsiChar`, so an interpolated `%` would consume a vararg that was
never pushed. The exact reason goes to `PackageCode` + a sanitized
printable-ASCII `PackageDetail`, and QuickJS's own diagnostic (bounded,
carrying the package-relative module name and line — `at lib/bad.js:1`)
goes to `PackageError`. No absolute path, CWD, pointer or `JSContext`
address appears in any of them.

## Atomic load
`PWebLoadQuickJSPackage` returns a Running plugin or nothing.
On every failure the engine is destroyed on its owning thread, the source
is Quiesced and Closed, and nothing becomes visible as Running — proven on
**every** hostile fixture, not once: the harness enqueues on the source
after each failed load and requires `perClosed`
(`source_open_after_failure=0`, `null_sink_calls=0`).

## Cross-platform corpus / CI
`build/cap9b1/quickjs-package-corpus.txt` (schema 1) carries the manifest
projection, canonical module list, per-module sha256 of the exact prepared
bytes, sorted import-graph edges, evaluation and invocation results,
folder/ZIP parity per row, every hostile decision and the counters. Every
fixture — including invalid UTF-8, an embedded NUL, oversized and CRLF
modules — is generated in-process from byte constants into a temp folder
and an in-memory ZIP, so no checkout's `core.autocrlf` can change what is
hashed. Four new CI steps run the gate before the CAP-7F emitter on
windows/linux/macos-x64/macos-arm64; the emitters record
`quickjs_package_corpus` (must-PASS, never SKIP) and
`quickjs_package_digest` plus four required counters; the aggregator adds
them to the required/must-PASS/four-way-equality sets; the committed
negative selftest grows from 16 to 21 aggregator refusal legs, each proven
to refuse through its named branch. Local digest at closure:
`4b01cf06677ff52fb26c74b031c72282258f26b7c5b44bd44131586c77209c45`,
byte-identical across three consecutive runs on the dev host — the
determinism that four-way equality depends on, measured rather than
assumed.

## Adversarial review
Three independent context-free review layers ran over the full diff after
the sixteen-question challenge in the brief had already been answered
inline. They were worth their cost: they found defects the inline pass
missed, including one that crashed the process.

**Confirmed and fixed (production):**
- **A constructor that raises before `inherited Create` crashes.** Both
  `Create` and `CreatePackage` validated their arguments before
  constructing the `TThread` base; an escaping exception then runs the
  destructor over a never-constructed base (measured:
  `EAccessViolation` at process teardown, reproducible from ANY
  descriptor rejection). Fixed twice over: `PWebLoadQuickJSPackage` now
  validates through a new non-raising
  `PWebValidateQuickJSPackageDescriptor` and never builds a doomed
  object, and both constructors build the base first (suspended, then
  `Start`) so a direct caller's raise is safe too. This was latent in
  the CAP-9A constructor shape as well, and stayed invisible because no
  test had ever constructed a plugin with bad input.
- **A data race on the atomic-failure path**: the plugin's refcounted
  error strings were read before the join, while the plugin thread could
  still be writing them. The join now comes first.
- **`Engine.TimeoutSeconds = 0` could wedge startup**: package loading
  runs plugin code before readiness, so an uninterruptible
  `while (true) {}` entry made `WaitReady` time out and the failure
  path's join block forever. Package descriptors now refuse a zero CPU
  bound — deliberately stricter than the CAP-9A post-script path.
- **`RawUtf8(PAnsiChar)` in both loader callbacks** — the code-page trap
  the rest of this change avoids; now `FastSetString`.
- Size bounds now fire on the RAW asset length before any copy; the
  unit header's claim was also corrected to say what the frozen
  `IAssetStore.TryRead` actually permits. `PackageError` goes through
  the same sanitizer as `PackageDetail` (a blind byte truncation could
  split UTF-8). Two silent fallbacks in the graph became hard failures.
  The edge ledger gained its own bound and geometric growth. `{"schema":01}`,
  a bare `.js` dotfile, an unclamped public manifest call and a scoping
  prefix with no room for a module path are all refused.
- **A package that queues a job at top level is now refused**
  (`plcPendingJobs`) instead of being accepted with a silently dead
  asynchronous half — nothing drains the QuickJS job queue, and adding
  a pump is out of scope. A load interrupted by the CPU bound is now
  diagnosed as `plcTimeout` rather than mis-reported as a compile error.

**Confirmed and fixed (evidence).** The third layer demonstrated each gap
with a mutation that left the whole matrix green: the schema and SemVer
checks, the whole `PWebClampPackageLimits` behaviour, `MaxSpecifierBytes`
and the rejected-descriptor arm could each be deleted with P1–P40 still
passing. All now have legs, as do `plcEvaluate` (the one failure mode
where attacker code has already run), the C1-control rule, a doubled BOM
and a dotfile module. The parsed manifest, the previously-dead
`LoadTimeInvokes` counter, and `PluginId`/`TrustedContent` as the bridge
received them are now observed rather than assumed. Engine text can no
longer reach a corpus line (it would have surfaced a target hiccup as an
opaque digest mismatch); a fatal exception can no longer ship
`verdict=PASS` beside `overall=FAIL`; and `source_open_after_failure` and
`opener_reached` are promoted into the evidence so the aggregate can
cross-check them. The selftest gained the non-numeric leg its own comment
had claimed.

**Deferred** (ledgered, not this shard's): O(n²) graph lookup at the 4096
hard cap, a carrier-side materialisation bound, whether module source
should have its own UTF-8 validator permitting C1, and the same
`-match`/`mktemp` weaknesses in CAP-9A's runners.

**Rejected:** reusing `pecRuntimeClosed` for the load-time refusal (the
brief ratified it, and the nine-code taxonomy is frozen), and fixtures
for `plcThread`/`plcEngine` (unreachable without fault injection).

## Regressions
On the closure run, `quickjs_corpus_digest`
`601b86ffd24d5642174758120d58d240da6e5cc0d4e0cc3a40b3ec0847e7909f` is
**byte-identical** to the CAP-9A closure value on all four targets — the
strongest available proof that the CAP-9A engine/thread/scheduler path is
unchanged, and it held through the constructor restructure the adversarial
review forced. `security_corpus_digest`
`c5fc378bc3c6eb6aa6db753e35287db5cb7ed6332aeac77b75767919e5adbdf4` and
`capability_policy_digest`
`23b87da524b158f4b1a8ca53057ad794f485086257997534b426b28334bddb2f` are
likewise unchanged from the CAP-8 closure, so no CAP-7/CAP-8/CAP-9A gate
was weakened to let this shard through. `macos-x86_64` reports 8
`extra_exports_rtti`, exactly as it did on the CAP-9A closure run
(32863002073) — pre-existing and untouched by CAP-9B1. `pwebtests`
2419/2419 assertions pass after the `pweb.assets.support` change. The
divergence sweep reports 68 platform conditionals inside the unchanged
allowlist — both new units carry no platform `{$ifdef}` at all. The CAP-9A
runners needed one line each (`-Fusrc/assets`), since the QuickJS unit now
uses `pweb.assets.intf`.

## Freeze check
Seven interfaces, `pweb.rpc.intf.pas`, scheduler/source lifecycle,
`TInvocationContext`, CAP-8 policy/navigation semantics, bridge + mORMot
adapter, error taxonomy, protocol v1, SDK wire, `app.pwb`, platform
adapters, the JSValue ABI, the mORMot pin (`b1a129b0`, `src`/`res`
pristine) and the QuickJS source pin: untouched. `IAssetStore.TryRead` is
unchanged and gained no enumeration. CAP-9B1 adds two units and one
additive export (`PWebStrictUtf8`, the existing private validator
published so manifest, module source and asset paths share one UTF-8
truth); no new public kernel interface.

## Known limitations / deferred
See `deferred-work.md` (CAP-9B1 entries): CAP-9B2 owns the lifecycle state
machine, stop/start/reload, discovery, watching, installation and signed
packages; dynamic `import()` stays unavailable pending a ratified Promise/
job pump; the `JS_ExecutePendingJob(nil)` null-write hazard is recorded so
nobody adds the first call carelessly; the `ci.yml` documentation-budget
overage is carried forward (153 KB) alongside the ratified 23 KB spec
overage. Five review findings are deferred rather than fixed here: the
O(n²) graph lookup that only matters near the 4096-module hard cap; a
carrier-side materialisation bound, which needs `IAssetStore` ratification
because the frozen `TryRead` has no size or streaming form; whether module
source should have its own UTF-8 validator permitting the C1 block; and
the `-match`/`mktemp` weaknesses that remain in CAP-9A's own runners.

**CAP-9B1 PASS — QUICKJS PACKAGE AND MODULE LOADER FROZEN**
