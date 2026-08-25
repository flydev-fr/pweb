# CAP-9A — Final Artifact: QuickJS Invocation Foundation

CAP-9A closes on hosted run **32863002073** (2026-08-25, commit `bd4c041`,
branch `phase/cap-9/a-quickjs-foundation`): all six jobs green, `cap7
aggregate` recording `quickjs_corpus: PASS (denied_bridge=0
opener_reached=0)` on every target and ONE `quickjs_corpus_digest`
`601b86ffd24d5642174758120d58d240da6e5cc0d4e0cc3a40b3ec0847e7909f` equal on
windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64 — the same digest
independently measured on the Windows dev host. Red→green trail: 32857758203
(darwin SDK gaps: PATH_MAX/js_std_dump_error prelude; audit false-positive on
the moved `js_std_eval_binary`), 32861042021 (POSIX pointer-sized TThreadID
vs bare ObjFPC function reference), then green with one CAP-5 Pas2JS
GUI-smoke flake rerun (a pre-existing step CAP-9A does not touch).

## QuickJS pin / build
Source authority is the pinned mORMot tree `b1a129b0`
(`res/static/libquickjs`): the quickjspp fork, `QUICKJS_VERSION 2021-03-27`,
BIGNUM+JSX+debugger, `JS_STRICT_NAN_BOXING` forced, quickjs-libc excluded,
heap/assert routed to `pas_*`. Windows/Linux x64 consume the sha256-pinned
release `quickjs.o`; the release ships NO darwin object and the pinned
defines never set `LIBQUICKJSSTATIC` on darwin, so both macOS targets build
the exact upstream amalgamation deterministically in CI
(`tools/build_quickjs_darwin.sh`: pin gate on HEAD + tree cleanliness,
recorded amalgamation/prelude sha256 + clang + arch, `lipo` check,
fail-closed module-registration audit). The committed `-include` prelude
(`tools/quickjs_darwin_prelude.h`) bridges the two macOS-SDK-only gaps
(PATH_MAX location; `js_std_dump_error` prototype, implemented Pascal-side)
with the pinned sources byte-untouched. QuickJS is MIT (Bellard/Gordon +
c-smile fork) — license text joins release artifacts with the CAP-9B/10
packaging work.

## ABI
`SizeOf(JSValueRaw)=SizeOf(JSValue)=8` under strict NaN boxing, pinned tag
constants (uninit=0 … string=11), 53-bit boundary semantics, string refcount
round-trip and cdecl callback ABI — corpus-pinned four-way, plus the paired
C probe (`test/cap9a/abiprobe.c` against the pinned headers) diffed
line-by-line against the Pascal set on Linux (gcc) and both macOS (clang);
on Windows the sha256 statics pin stands where no credible gcc exists
(honest skip, POSIX always gates).

## mORMot engine integration
High-level only where viable: `TThreadSafeManager.NewEngine` mints
caller-owned `NeverExpire` engines (the pooled `ThreadSafeEngine()` expiry
path is deliberately unused — wrong ownership shape, measured Destroy-raise
hazard); `TQuickJSEngine.Evaluate`/`RegisterMethod`/`TimeoutValue` carry the
whole script surface. Low-level use is exactly two calls: `JS_SetMemoryLimit`
and a PRIVATE correctly-typed re-declaration of `JS_SetMaxStackSize` — the
pinned binding mistypes its first parameter as `JSContext` where the pinned
C takes `JSRuntime*` (measured 0xC0000005 under allocation pressure; the pin
is untouched, the workaround is unit-local and shadows the import). Upstream
reports ledgered: the stack-size signature and the `pas_malloc(cardinal)`
truncation companion (PWeb's own aarch64-darwin exports are PtrUInt-widened
with an overflow-guarded calloc). No parallel wrapper, no `VariantInvoke`.

## Engine / thread ownership
One plugin → one dedicated `TPWebQuickJSPlugin` thread → one caller-owned
engine (own runtime+context, created AND destroyed on that thread — pinned
by `engine_destroyed_on_owner=yes` and zero wrong-thread callback counters
in the corpus) → one frozen `IInvocationSource`. No shared global context
anywhere; isolation is per-runtime.

## Script invocation API (ratified synchronous model)
`pweb.invoke(method, argsObject|null)` + `pweb.handshake()` via a
native-evaluated bootstrap shim; the hidden `__pweb_invoke_json` callback
validates → `TryEnqueue` → bounded event wait → ONE JSON envelope string the
shim parses — exact key case/order, null-vs-undefined and
success-shaped-like-error preserved without DocVariant round-trips; the raw
callback is deleted from globals and `pweb` is frozen. Errors throw a
PWebError-shaped object (name/code/status/message/data); escaping proven on
a message carrying quote+backslash+control (q07b). The Promise model was
measured and deferred (needs the low-level Promise/job-pump surface the
pinned wrapper does not expose) — ledgered.

## Scheduler source
The frozen `RegisterSource`/`TryEnqueue`/exactly-once/Quiesce/Close path,
untouched: malformed grammar rejects pre-queue (q09), positional args
invalid_request (q10), busy under saturation with zero cross-source bleed
(q26/q27), Close mid-wait resolves cancelled and the released late worker's
result dies at the gate — measured through a deterministic bridge-return
rendezvous, sink deliveries exactly 1 (q16/q17); closed source →
runtime_closed (q18); the real bridge observes the cancelled token and never
reaches the service (ledger service_add=6 vs calc_bridge_add=7, both
digest-pinned).

## Principal / capability model
`pkQuickJS` was already in the frozen enum — zero interface change. Two
native principals (`plugin:calculator` with `calculator.add`;
`plugin:reporting` with the explicit empty set), contexts built natively
with `WindowId=''`, per-invocation snapshots through the CAP-8A policy:
allowed Add→42 through the real `TRestServer.Uri()`; denied → forbidden/403
with ZERO bridge/SOA activity (counted; aggregator refuses >0); forged
identity fields in Args change nothing (q25); `pweb.openExternal` forbidden
for both (opener_reached=0 refused-if-nonzero); revocation hits the NEXT
invocation while the in-flight one keeps its snapshot (q28/q29).

## Result / error parity
The nine-code taxonomy verbatim: shaped success stays success (q05), null
success is JS null never undefined (q06), service_error data verbatim
(q07/q07b), internal_error redacted (q08), method_not_found on the zero-cap
404 route (q09b), engine syntax/runtime errors remain engine errors distinct
from invocation errors (q13/q14), exact-case policy (q15) and verbatim echo
round-trip.

## Resource limits
Per engine: CPU via the pinned `TimeoutValue` interrupt (a script posted
without its own bound keeps the plugin's limit — never silently disabled),
memory via `JS_SetMemoryLimit`, stack via the runtime-typed call. Infinite
loop interrupted with the other plugin unaffected (q20), engine reusable
after (q21), recursion and over-allocation contained with hang-timeouts
counted as failures (q22/q23), disposable engine destroyed on its owner,
5× create/evaluate/destroy churn clean (q24).

## Sandbox surface
No quickjs-libc: runtime proof (q12 — fetch/XHR/WebSocket/EventSource/
require/process/std/os/document/window/spawn/setTimeout all undefined) plus
mechanical audits targeting the real module-registration surface
(`js_init_module_std/os`, `js_std_add_helpers`, `js_std_loop`): nm on the
pinned Linux object, the darwin build's own fail-closed audit, the Windows
sha256 pin. The pinned patch's deliberately moved `js_std_eval_binary`
helper is documented as harmless (measured false-positive, corrected).

## Lifecycle / unload / cross-plugin isolation
Quiesce→Close→stop→join with the engine freed in the thread epilogue;
constructor-failure paths guarded; the bounded native wait always terminates
via frozen exactly-once completion. Two concurrent plugin engines, distinct
runtimes/sources/principals, no result or capability bleed, one plugin's
timeout/saturation/unload leaving the other fully functional (q19/q20/q26).

## Cross-platform CI
Four platform jobs run the gate before the CAP-7F emitters; evidence carries
`quickjs_corpus` (must-PASS) + `quickjs_corpus_digest` (four-way equality)
+ `cap9a_denied_bridge`/`cap9a_opener_reached` (refused if nonzero); the
committed negative selftest proves all four new refusal branches red on
fixtures (16 aggregator + 2 divergence legs total). CAP-7/CAP-8 jobs
unweakened — `security_corpus_digest c5fc378b…` unchanged from the CAP-8
closure on the same run.

## Freeze check
Seven interfaces, `pweb.rpc.intf.pas`, scheduler/source lifecycle,
`TInvocationContext`, CAP-8 policy/navigation semantics, bridge + mORMot
adapter, error taxonomy, protocol v1, SDK wire, `app.pwb`, platform
adapters, webview ABI and the mORMot pin: untouched (the divergence sweep's
one new allowlist entry is the CAP-9A unit's own darwin link block). CAP-9A
adds one invocation-source implementation behind the frozen interfaces.

## Known limitations / deferred
See `deferred-work.md` (CAP-9A entries): CAP-9B owns script/package loading,
plugin metadata, ES modules, hot reload and production lifecycle; the
Promise API candidate; the two upstream mORMot reports (strip proprietary
context before filing); `ci.yml` documentation-budget overage carried
forward. The CAP-5 Pas2JS GUI smoke flaked once on the closure run's first
attempt (rerun green) — pre-existing, outside CAP-9A scope.

**CAP-9A PASS — QUICKJS INVOCATION FOUNDATION FROZEN**
