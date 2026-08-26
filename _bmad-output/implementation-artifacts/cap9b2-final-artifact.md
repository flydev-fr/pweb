# CAP-9B2 — Final Artifact: QuickJS Plugin Lifecycle and Reload

CAP-9B2 closes on hosted run **32995412526** (2026-08-26, commit
`78e1359`, branch `phase/cap-9/b2-plugin-lifecycle`, baseline `bc6b1d4`):
all six jobs green, `cap7 aggregate` recording `quickjs_lifecycle_corpus:
PASS (two_active=0 stale=0 reload_lost_old=0 quarantine=1/0)` on every
target and ONE `quickjs_lifecycle_digest`
`6c8d0bd7147cadb384ff06e8841b17212a6a1fa550a978c31d23ba1f1a785131` equal on
windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64 — the same digest
independently measured on the Windows dev host, and stable across three
consecutive local runs. The committed negative selftest reported `28
aggregator refusals + 2 divergence refusals` on the same run, so every new
refusal branch is proven red on fixtures before the real aggregation is
trusted.

Red→green trail, and it is worth recording because the red was in the
EVIDENCE, not the runtime: run 32991851379 came back with three targets on
`621fd00e…` and **macos-x86_64 alone** on `192aed33…`, differing in exactly
two lines — `ledger service_add` and `ledger sources_made`, one lower each.
Both are race-dependent by construction. `sources_made` counts L34's
reload, which consumes a source only when it wins the operation lock
against the concurrent unload — the very race L34 exists to test — and
`service_add` counts L18's held invocation, which the frozen mORMot bridge
refuses *before* reaching the service when `Close` lands ahead of its token
re-check. Both orderings are correct. The L34 *token* had already been
normalised for exactly this reason; the *counters* still leaked the race
into the hash. They are now the invariants that matter
(`service_reached`, `sources_made_positive`,
`held_service_calls_at_most_one`), the exact per-target numbers stay in the
JSON record which the aggregate reports but does not compare, and every
remaining numeric corpus value was then audited to be a per-host sequence,
a zero-invariant, a fixed constant or a deterministic count. Nothing was
weakened: the `svcadd=ok:42` rows already prove the real service was
reached and the generation-id rows already prove each generation got its
own source. Earlier attempts on the same tree were not evidence: the first
push run hit the pre-existing CAP-6 WebView2 GUI-smoke flake
(`state=0; 0=no report received`, every CAP-9 step `skipped`), and its
macOS jobs were cancelled because a redundant dispatched run and the push
run competed for the ref-keyed `cap7m-macos-*-${{ github.ref }}`
concurrency group.

It builds one explicit, native-controlled plugin lifecycle *around* the
frozen CAP-9B1 package generation. Every claim below is measured — the
L1–L40 headless matrix on four targets, plus a Checkpoint-1 probe against
the pinned tree.

## Lifecycle state machine
One private machine on one owner. `ppsCreated → ppsLoading → ppsRunning →
{ppsStaging → ppsCommitting → ppsRunning} → ppsQuiescing → ppsClosed`,
plus `ppsFailed`. Every state *write* happens under `FOpLock` and inside
`FLifeLock`, so while a lifecycle operation runs no other transition can
occur — that single invariant is what makes the rest provable. No state is
inferred from a live thread or a non-nil pointer: `CallExport`'s gate is
the state ordinal, never `FCurrent <> nil`. `ppsClosed` is terminal and
idempotent (`L14`/`L15`). `ppsFailed` accepts only `Unload` — `Reload`
requires `ppsRunning` and `Load` requires `ppsCreated` — so a Failed host
can never silently become Running (`L2`). Lifecycle state reaches
JavaScript nowhere: a plugin cannot reload itself, unload itself, replace
its store, or move its descriptor, principal or capabilities.

## Engine / source ownership
`TPWebQuickJSPlugin` was **promoted, not duplicated**: it is now
explicitly ONE generation — thread, engine, `JSContext`, module cache,
module graph, scheduler source, export surface — and never owns a second
engine. `TPWebQuickJSPluginHost` (`pweb.script.plugin.pas`) is the only new
owner and it owns *generations*, not engines: identity, the generation
counter, the published slot, the state machine. It never touches a
`JSValue` and never references `mormot.lib.quickjs`. Lock order is
`FOpLock → FLifeLock`, never the reverse; `FLifeLock` is never held across
a package load, an export call, a `Quiesce`/`Close`, a drain or a join;
`CallExport` takes only `FLifeLock`, briefly; the plugin thread never takes
either.

## Host export calls
There is **no public module-namespace accessor in this pin** —
`js_get_module_ns` is `static` (`quickjs.c:28130`) and `quickjs.h` exports
only `JS_GetModuleName`. The one route that works, a synthetic
`import * as ns` capture module, was measured at `loader +0` but
`normalize +1` plus one graph edge, both of which are
`quickjs-package-corpus.txt` fields — it would have moved the FROZEN
`quickjs_package_digest`. Ratified instead: a native **null-prototype**
`globalThis.pwebExports`, created before the entry compiles and sealed at
the load commit point (`JS_SetPrototype(null)` → `JS_PreventExtensions` →
name snapshot → delete the global). The seal is not decoration:
`Object.setPrototypeOf(pwebExports, Object.prototype)` *succeeds* before it
and makes `toString` callable as an export; after it both that and any late
export fail with `TypeError: object is not extensible`. An empty export set
is legal, and every CAP-9B1 package has one (`L40`).

`CallExport` rides the existing single-slot mailbox, so it executes only on
the owning plugin thread (`export_wrong_thread=0`); a concurrent second
call returns `peccBusy` synchronously and non-blockingly, the same shape as
the frozen `TryEnqueue`/`perBusy` rule and the reason no lifecycle lock ever
waits on a QuickJS call. Names are `[A-Za-z_][A-Za-z0-9_]*`, ASCII, exact
case, ≤ 64 bytes, no dotted traversal. One JSON argument (≤ 64 KiB), one
JSON result (≤ 1 MiB); `undefined` becomes `'null'` because
`JS_JSONStringify` returns undefined rather than throwing (measured), and a
circular result becomes `peccBadResult` because it *does* throw. The CPU
window is re-armed per call — measured mandatory: unarmed, a long call
aborts on its first interrupt poll. A missing or non-callable export is
`peccNoExport`/`peccNotCallable`, never `method_not_found`. An ordinary
plugin exception is `peccThrew`, sanitized to `Name: message` (never
stack-trace text — a stack overflow produces ~20 KB of frames) and the
generation stays Running (`L7`).

## Async job policy
`JS_IsJobPending(rt)` after **every** call, including one that threw, and a
structural thenable probe on the result — this pin has no
`JS_PromiseState`, and `JSON.stringify(promise)` is `{}`, so the probe is
the only detection that works. Both fail closed and taint
(`L9 async_result`, `L10 pending_jobs`). Nothing pumps the queue; a queued
microtask provably never runs and is freed by `JS_FreeRuntime`. No
`JS_ExecutePendingJob` call was added — the ledgered null-write hazard
stands.

## Unload
Unpublish under `FLifeLock` → `ppsQuiescing` → new calls refused →
`Source.Quiesce` → `Source.Close` → bounded drain → stop → **bounded** join
→ engine destroyed in the thread's own epilogue → `ppsClosed`. `Close`
comes before the drain deliberately: it is what releases a plugin thread
blocked inside synchronous `pweb.invoke` (`L16`). The join waits on
`FExited`, set as the thread's very last act after the engine is gone, so
observing it means `WaitFor` cannot block. The captured export-table
`JSValue` is freed *before* the engine — a leaked value trips the pinned
`assert(list_empty(&rt->gc_obj_list))` and kills the process with no
catchable exception (measured `0xE0434353`).

`L17` is the sharper half: the worker was still parked in the bridge when
its source closed, and releasing it afterwards reaches the service **zero**
times — the frozen mORMot bridge re-checks the cancellation token on entry,
so the exactly-once gate is the second line of defence, not the first.

## Reload staging
Refused unless `ppsRunning`, and refused unless `PrincipalId`, `PluginId`,
`ExpectedPackageId`, capabilities and both limit sets are byte-identical to
the registration (`L21c`–`L21f` each refuse with `identity`); only
`PackageStore` and `ExpectedEntryPoint` may differ. Staging builds a
complete new generation — own source, thread, engine, context, cache,
graph — through CAP-9B1's unchanged atomic loader, with `pweb.invoke`
refused for the whole staged load, so **staging can produce no backend side
effect** while the old generation is still serving. No plugin export is
called during staging.

## Generation commit
Two locked sections, **one** commit point. B1 unpublishes the old
generation and enters `ppsCommitting`; then `Quiesce`, `Close` and a
bounded drain, none of which can fail (all three are non-blocking,
idempotent and exception-guarded, and a drain timeout only decides
free-vs-quarantine); then B2, the commit point, swaps `FCurrent` and the
generation id under one lock. Everything that *can* fail — descriptor,
manifest, modules, engine, thread, source — already happened during
staging, which is why no rollback exists past B1 and none is needed.

## Failure preservation
Thirteen staged-reload failure rows, each asserting the old generation is
still published, still Running, still answering byte-for-byte, with the
generation id unmoved and `commits=0`: malformed manifest, a
security-authority manifest field, entry syntax error, missing entry,
missing module, invalid UTF-8, embedded NUL, manifest-id mismatch, an
export name outside the host grammar, an export name containing an embedded
NUL, a source factory that produces nothing, a source that is registered
but already closed, and four descriptor-identity refusals.
`reload_lost_old=0`, `staging_failures=12`.

## Cross-generation isolation
`L23`–`L27`: the generation id changes and is never reused, source identity
and `JSContext` change, the module cache resets (the new generation
re-evaluates its graph), changed module behaviour is observed, and old
global state is **absent** (`seen=ok:"undefined"` after a reload that
followed a deliberate `leak`). `L27` makes the commit window genuinely
observable rather than sampled by luck: a call that merely parks in the
bridge is released by `Close`, so the window would last microseconds —
`holdThenSpin` runs away *after* its invocation returns, so the in-flight
count stays 1 and the window lasts a real, bounded time. In it, a call
returns `unavailable`: `two_active_generations=0`. The runaway then ends on
generation 1's CPU bound and its taint reap discovers its generation has
already been replaced — which is exactly why generations are identified by
**id, never by pointer**: a recycled allocation could otherwise make a
pointer comparison match the wrong generation.

## Multi-plugin isolation
`L35`–`L37`: two hosts, both starting at generation 1 — a process-global
counter would have shown up immediately. Plugin A's globals are invisible
in B, three reloads of A leave B's generation, behaviour and invocation
path untouched, an A-side exception does not reach B, and unloading A
leaves B fully functional including `Add → 42` through the real bridge.

## Resource-limit shutdown
CPU, memory and stack limits inside `JS_Call` all taint the generation and
close it, bounded (`L11`–`L13`), with the host landing in `ppsFailed` and
refusing further calls. `L18` unloads *during* an infinite loop with the
rendezvous guaranteeing the call is really in flight: the CPU bound ends it
and the unload is **clean**. `L38` injects the last-resort path with **no
production test hook** — a real infinite-loop export under a 5 s CPU bound,
unloaded with a 50 ms join budget. The result is `quarantined`, never a
clean-close claim; nothing is freed — not the instance, its events, its
source reference or its graph — and the harness then proves the leaked
thread ended later *without ever freeing it*
(`exited_later=yes still_leaked=1`). `Destroy` raises rather than free a
quarantined plugin, so the object leaks by choice instead of being handed to
a live thread. An undrained generation is quarantined unconditionally for
the same reason. No thread is ever forcibly terminated.

## Cross-platform corpus / CI
`build/cap9b2/quickjs-lifecycle-corpus.txt` (schema 1, 142 lines) carries
the state transitions, generation ids and deltas, the sealed export
snapshot, every reload decision, the unload outcomes, the quarantine
ledger, the pending-job and Promise results, the A/B isolation rows, `Add`
and denied results, and the counters. Every fixture is generated in-process
from byte constants, and every cross-thread ordering is a bridge
rendezvous rather than a delay. Rows whose outcome is a scheduling detail —
which of two racing lifecycle operations won the lock — record a
**normalised** token, because writing the winner into the corpus would make
the digest differ between targets for no semantic reason.

Four new CI steps run the gate before the CAP-7F emitter on
windows/linux/macos-x64/macos-arm64; the emitters record
`quickjs_lifecycle_corpus` (must-PASS, never SKIP) and
`quickjs_lifecycle_digest` plus eight required counters; the aggregator
adds them to the required / must-PASS / four-way-equality sets and gains
seven zero-counter refusals plus an **exactly-one** check on
`cap9b2_quarantine_injected` — zero means the last-resort path was never
exercised, which is as wrong as a spurious quarantine. The committed
negative selftest grows from 21 to 28 aggregator refusal legs, each proven
red on fixtures.

## Adversarial review
The sixteen challenge questions were answered against the code, and the
diff was then re-read for defects the questions do not cover. Four were
confirmed and fixed:

- **`JS_GPN_ENUM_ONLY` hid non-enumerable exports.** A package using
  `Object.defineProperty` put an export visibly in the table that the
  snapshot never listed, so the host answered `no_export` for something
  plainly there. The snapshot is now the table's own-property set.
- **An embedded NUL in an export name aliased another export.**
  `JS_AtomToCString` truncates at the NUL, so a name spelled
  `add` + U+0000 + `x` collapsed to `add` and would have resolved a real
  export's spelling. The snapshot now reads through the atom's string and
  compares its true byte length.
- **A registered-but-closed source produced a silently dead generation.**
  `RegisterSource` returns a `pssClosed` source once the scheduler is
  shutting down (frozen, fail-closed by design); a generation published
  over one loads perfectly and then answers `runtime_closed` to
  everything — Running by the state machine, dead in fact. Staging now
  refuses it.
- **`Integer(n)` of a `Cardinal` export count could go negative** and slip
  past the bound; the comparison happens before the narrowing.

Two more were caught during bring-up by the matrix rather than by
inspection, and both deserve recording because neither was visible in
review: `for i := 0 to n - 1` with a `Cardinal` zero count underflows to
four billion iterations over freed memory — on the *normal* empty-export
path that every CAP-9B1 package takes; and two corpus values
(`L17`'s service delta and `L27`'s mid-commit token) were race-dependent
rather than deterministic, which four-way digest equality would have
surfaced only as an opaque mismatch on some future run.

**Also corrected:** `L17` originally asserted the released late worker
reached the service exactly once. It reaches it **zero** times, because the
frozen bridge re-checks the cancellation token — the test was wrong, not
the runtime, and the stronger fact is now what the corpus records.

## Regressions
On the closure run, `quickjs_package_digest`
`4b01cf06677ff52fb26c74b031c72282258f26b7c5b44bd44131586c77209c45` and
`quickjs_corpus_digest`
`601b86ffd24d5642174758120d58d240da6e5cc0d4e0cc3a40b3ec0847e7909f` are
**byte-identical** to the CAP-9B1 and CAP-9A closure values on all four
targets — the strongest available proof that the export table is genuinely
additive and that the CAP-9A engine/thread/scheduler path is untouched,
measured after implementation rather than assumed. `security_corpus_digest`
`c5fc378bc3c6eb6aa6db753e35287db5cb7ed6332aeac77b75767919e5adbdf4` and
`capability_policy_digest`
`23b87da524b158f4b1a8ca53057ad794f485086257997534b426b28334bddb2f` are
likewise unchanged from the CAP-8 closure, so no CAP-7/CAP-8/CAP-9A/CAP-9B1
gate was weakened to let this shard through. `pwebtests` 2419/2419
assertions. The freeze-isolation sweep passes (17/17 exports, raw-layer
purity, freeze isolation). The divergence sweep reports 68 platform
conditionals inside the unchanged allowlist — both new/changed script units
carry no platform `{$ifdef}` at all. `macos-x86_64` reports 8
`extra_exports_rtti`, exactly as it did on the CAP-9A and CAP-9B1 closure
runs — pre-existing and untouched by CAP-9B2.

## Freeze check
Seven interfaces, `pweb.rpc.intf.pas`, scheduler/source lifecycle,
`TInvocationContext`, CAP-8 policy/navigation, bridge + mORMot adapter,
error taxonomy, protocol v1, SDK wire, `app.pwb`, platform adapters, the
JSValue ABI, the mORMot pin (`b1a129b0`, `src`/`res` pristine) and the
QuickJS source pin: untouched — verified file-by-file against the CAP-9B1
closure commit. The entire production change is confined to `src/script`.
`pweb` keeps exactly `invoke` + `handshake`; `pwebExports` is a separate
global created only on the package path, so the CAP-9A corpus cannot see
it. Two native package-load codes were appended (`plcExportName`,
`plcExportCount`) to CAP-9B1's private code set, which is deliberately not
the nine-code RPC taxonomy. No new public kernel interface.

## Known limitations / deferred
See `deferred-work.md` (CAP-9B2 entries): CAP-9C owns release packaging and
the CAP-9 closure; plugin discovery, watching, installation, update and
signed packages remain unbuilt by ratified decision; ES named exports await
either a pin patch exporting the namespace accessor or a re-baselined
CAP-9B1 digest; the `JSValue`-leak process-abort hazard is recorded so
nobody captures a value without freeing it on the owning thread; resource-
limit classification is a pin-text match with no API alternative, resolving
ambiguity towards the limit; CAP-9A's `PostScript`/`Eval` diagnostic path
keeps its CAP-9A behaviour and gains no pending-job gate; and the `ci.yml`
documentation-budget overage is carried forward (158 KB).

**CAP-9B2 PASS — QUICKJS PLUGIN LIFECYCLE AND RELOAD FROZEN**
