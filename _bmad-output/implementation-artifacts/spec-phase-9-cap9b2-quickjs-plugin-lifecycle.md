---
title: 'CAP-9B2 — QuickJS plugin lifecycle, export calls and transactional reload'
type: 'feature'
created: '2026-08-26'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'bc6b1d429d80fbc019ef7ee957089a92b3e115fd'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/threading-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/wire-semantics.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/security-model.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9a-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9b1-final-artifact.md'
---

# CAP-9B2 — QuickJS Plugin Lifecycle, Export Calls and Transactional Reload

Shard spec. Builds one explicit, native-controlled plugin lifecycle around
the frozen CAP-9B1 package generation. Adds no kernel interface, no public
plugin-management API, and nothing script-visible that can touch a
lifecycle.

## Frozen inputs

CAP-8 (capability policy, navigation), CAP-9A (engine/thread/invocation
architecture) and CAP-9B1 (package/module loader) are closed. This shard
takes them as given and changes none of their semantics; the CAP-9A and
CAP-9B1 corpus digests are re-measured as a regression gate rather than
re-baselined.

## Checkpoint-1 measurements (against the pinned tree)

Every decision below rests on a probe run against
`deps/mormot2/res/static/libquickjs` (quickjspp fork, `QUICKJS_VERSION
2021-03-27`, strict NaN boxing, no quickjs-libc), not on reading the
header:

1. **There is no public module-namespace accessor.** `js_get_module_ns` is
   `static` in `quickjs.c:28130`; `quickjs.h` exports only
   `JS_GetModuleName`. There is likewise no `JS_PromiseState`.
2. **A native null-prototype table works as an export surface.**
   `JS_NewObjectProto(cx, JS_NULL)` +
   `JS_DefinePropertyValueStr(global, 'pwebExports', tbl,
   JS_PROP_CONFIGURABLE)`: `toString`/`constructor` lookups return
   undefined, `JS_GetOwnPropertyNames` yields the exact insertion-ordered
   name list, and strict (module) code replacing the table gets
   `TypeError: 'pwebExports' is read-only` while sloppy code's write is a
   silent no-op — the table is unchanged either way.
3. **A prototype attack is real, and sealing closes it.**
   `Object.setPrototypeOf(pwebExports, Object.prototype)` succeeds before
   sealing and makes `toString` callable as an "export".
   `JS_SetPrototype(…, JS_NULL)` then `JS_PreventExtensions` (both rc=1)
   make the prototype swap and any late export both fail with `TypeError:
   object is not extensible`.
4. **The call round-trip works.** `JS_ParseJSON` → `JS_Call` →
   `JS_JSONStringify` returns 42 for `{"a":40,"b":1}`. An `undefined`
   return makes stringify return **undefined, not an exception**; a
   circular result makes it **throw** `TypeError: circular reference`.
5. **Pending jobs are detectable.** After an export doing
   `Promise.resolve().then(…)`, `JS_IsJobPending(rt)` is true and the
   microtask never runs. The brief's "STOP if undetectable" condition does
   not apply.
6. **Promise results need a structural probe.**
   `JSON.stringify(promise)` is `{}`; a callable `then` is the only
   available signal in this pin.
7. **Resource limits bound `JS_Call`.** Armed with `Evaluate('0')`: an
   infinite loop aborts with `InternalError: interrupted` at the CPU
   bound with `TimeoutAborted=yes`; deep recursion gives `InternalError:
   stack overflow`; an 8 MB cap gives `InternalError: out of memory` in
   62 ms. The engine remained usable after each, so tainting is policy,
   not necessity.
8. **Arming is mandatory before every call.** Unarmed, a long call aborts
   on its first interrupt poll (`0ms`, `timeoutAborted=yes`); a short call
   is never polled and returns. Same finding CAP-9B1 made for module
   loading.
9. **A leaked `JSValue` kills the process.** One unfreed value at
   `JS_FreeRuntime` time trips the pinned
   `assert(list_empty(&rt->gc_obj_list))` and aborts with **no catchable
   Pascal exception** (measured `0xE0434353`).

### The ratified export-surface decision

The ES-named-export route was measured feasible: a synthetic capture
module `import * as ns from "./main.js"` resolves with `loader +0` (the
entry is resident under its `JS_Eval` filename) but **`normalize +1`** and
one extra module-graph edge. `normalize=` and the sorted edge list are
both `quickjs-package-corpus.txt` fields, so that route would move the
frozen `quickjs_package_digest` on all four targets.

**Ratified: the native `pwebExports` table**, which is additive, involves
no resolver or store, and leaves the CAP-9B1 corpus byte-identical
(verified: `4b01cf06…` unchanged after implementation).

## Ownership

`TPWebQuickJSPlugin` is promoted, not duplicated: it is now explicitly
**one generation** — thread, engine, `JSContext`, module cache, module
graph, scheduler source, export surface. It never reloads itself and never
owns a second engine.

`TPWebQuickJSPluginHost` (`src/script/pweb.script.plugin.pas`) is the only
new owner, and it owns **generations**, not engines: plugin identity, the
per-host generation counter, the published-generation slot and the state
machine. It never touches a `JSValue` and never references
`mormot.lib.quickjs`.

## State machine

`ppsCreated → ppsLoading → ppsRunning → {ppsStaging → ppsCommitting →
ppsRunning} → ppsQuiescing → ppsClosed`, plus `ppsFailed`.

- One transition owner (the host, under `FLifeLock`).
- No state inferred from a live thread or a non-nil pointer.
- `ppsClosed` is terminal and idempotent.
- `ppsFailed` accepts **only** `Unload`: `Reload` requires `ppsRunning`
  and `Load` requires `ppsCreated`, so Failed never becomes Running.
- `CallExport` is accepted only in `ppsRunning`.
- Lifecycle state is never exposed to JavaScript.

### Lock discipline

`FOpLock` (serialises Load/Reload/Unload/taint-reap; **may** be held across
blocking staging) → `FLifeLock` (state + publication only; **never** held
across a package load, an export call, a source Quiesce/Close, a drain or
a join). Never the reverse. `CallExport` takes only `FLifeLock`, briefly.
The plugin thread never takes either lock.

## Host-to-plugin calls

`pwebExports` is created natively before the entry module compiles; package
modules register callables on it during load. At the load commit point —
still on the plugin thread, still Loading — native code re-imposes the null
prototype, makes the object non-extensible, snapshots the names and deletes
the global. An empty export set is legal.

`CallExport` posts a typed job onto the existing single-slot mailbox, so it
runs only on the owning plugin thread. A concurrent second call returns
`peccBusy` synchronously and non-blockingly — the same shape as the frozen
`TryEnqueue`/`perBusy` rule, and the reason no lifecycle lock ever waits on
a QuickJS call.

- **Grammar:** `[A-Za-z_][A-Za-z0-9_]*`, ASCII, exact case, 1..64 bytes. No
  dotted traversal.
- **Argument:** one `TPWebJson` value or `'null'`, ≤ 64 KiB. **Result:**
  JSON, ≤ 1 MiB; `undefined` maps to `'null'`.
- **Failure taxonomy:** `TPWebExportCallCode`, private, never the nine-code
  RPC taxonomy. A missing or non-callable export is `peccNoExport` /
  `peccNotCallable`, never `method_not_found`.
- **Ordinary exception:** `peccThrew`, sanitized `Name: message` (never
  stack-trace text — a stack overflow produces ~20 KB of frames), and the
  generation stays Running.
- **Resource limit:** `peccResourceLimit`, generation tainted, bounded
  unload, host lands in `ppsFailed`.

## Async policy

`JS_IsJobPending` is checked after **every** call, including one that
threw; a thenable result is refused structurally. Both taint. Nothing calls
`JS_ExecutePendingJob` (the ledgered null-write hazard stands). CAP-9A's
`PostScript`/`Eval` diagnostic path keeps its CAP-9A behaviour and is
explicitly not the production call API.

## Unload

Unpublish under `FLifeLock` → `ppsQuiescing` → new calls refused →
`Source.Quiesce` → `Source.Close` (which releases a plugin thread blocked
in synchronous `pweb.invoke`) → bounded drain of in-flight calls → stop and
**bounded** join on `FExited` → engine destroyed in the thread's own
epilogue → `ppsClosed`. Idempotent.

## Bounded shutdown and quarantine

The join waits on `FExited`, set as the thread's very last act. On timeout
the generation is **quarantined**: nothing it may still touch is freed —
not the instance, its events, its source reference or its graph — and it
moves to a process-level ledger. `Destroy` raises rather than free a
quarantined plugin, so the object leaks by choice instead of being handed
to a live thread. No thread is ever forcibly terminated. An undrained
generation is quarantined unconditionally for the same reason. The host
never reports a clean close when quarantine was required.

## Transactional reload

Refused unless `ppsRunning`, and refused unless `PrincipalId`, `PluginId`,
`ExpectedPackageId`, capabilities and both limit sets are byte-identical to
the registration. Only `PackageStore` and `ExpectedEntryPoint` may differ.
Manifest version stays descriptive: same, higher and lower are all
accepted.

**A. Stage** (outside every lock): a new source from the host's factory, a
new thread/engine/context/cache/graph, loaded through CAP-9B1's unchanged
atomic loader. `pweb.invoke` stays refused for the whole staged load, so
staging produces no backend side effect. Any failure leaves the old
generation published, Running and unaltered.

**B. Commit** — two locked sections, **one** commit point:

1. Lock #1: state `ppsCommitting`, `FCurrent := nil`. The old generation
   stops accepting; the new one is not published. `CallExport` returns
   `peccUnavailable`.
2. Outside the lock: `Quiesce`, `Close`, bounded drain. **Nothing here can
   fail** — all three are non-blocking, idempotent and exception-guarded,
   and a drain timeout only decides free-vs-quarantine.
3. Lock #2 — **the commit point**: `FCurrent := staged`, new generation id,
   `ppsRunning`.
4. Retire the old generation.

Every operation that can fail happens during staging, which is why no
rollback exists past lock #1 and none is needed.

## Generations

Per-host monotonic id from 1 (per host, so plugin A's counter can never
perturb plugin B). New generation ⇒ new source, sink set, `JSContext`,
module cache, graph and token. No state migration of any kind: no globals,
module cache entries, `JSValue`s, pending jobs, closures or native
pointers cross. `GenerationId` is lifecycle metadata with no authority;
runtime grants stay keyed by `PrincipalId` through the frozen CAP-8 policy,
snapshotted per invocation.

Generations are identified by **id, never by pointer**, when a tainting
call reaps: a concurrent reload may already have freed that object, and a
recycled allocation could make a pointer comparison match the wrong
generation.

## Test matrix

`test/cap9b2/quickjslifecycle.pas`, L1–L40, headless, four targets, one
digest. Every cross-thread ordering is a bridge rendezvous, never a delay.
Rows whose outcome is a scheduling detail (which of two racing lifecycle
operations won the lock) record a **normalised** token, because writing the
winner into the corpus would make the digest differ between targets for no
semantic reason.

Two rows deserve naming:

- **L27** makes the commit window observable on purpose. A call that merely
  parks in the bridge is released by the source Close, so the drain — and
  therefore `ppsCommitting` — lasts microseconds. `holdThenSpin` runs away
  *after* its invocation returns, so the in-flight count stays 1 until the
  CPU bound fires and the window lasts a bounded, real amount of time.
- **L38** injects the last-resort quarantine with **no production test
  hook**: a real infinite-loop export under a 5 s CPU bound, unloaded with
  a 50 ms join budget. The harness then proves the leaked thread ended
  later without ever freeing it.

## CI

Four new steps, one per platform job, before the CAP-7F emitters. The
emitters record `quickjs_lifecycle_corpus` (must-PASS, never SKIP),
`quickjs_lifecycle_digest` (four-way equality) and eight required counters.
The aggregator adds them to the required / must-PASS / equality sets and
gains seven zero-counter refusals plus an **exactly-one** check on
`cap9b2_quarantine_injected` — zero means the last-resort path was never
exercised, which is as wrong as a spurious quarantine. The committed
negative selftest grows from 21 to 28 aggregator refusal legs.

## Out of scope (ratified Never list for this shard)

Plugin discovery, directory scanning, file watching, automatic hot reload,
installation or update, signed packages, a public plugin-management API,
QuickJS Promise RPC, dynamic `import()`, timers or an event loop,
filesystem/network/process APIs, a second scheduler or bridge, packaging
plugins into the release, and CAP-9C.
