---
title: 'CAP-9A — QuickJS engine and source-generic invocation foundation'
type: 'feature'
created: '2026-08-25'
status: 'done'
review_loop_iteration: 0
baseline_commit: '1af1b38e92ae684680c876510ceb405823b83f5b'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/wire-semantics.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/threading-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/security-model.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Phase 9 needs plugins/scripts to call the same services as the WebView, but no script engine exists yet. CAP-9A must prove and freeze the QuickJS execution architecture — engine pin/build on four targets, ABI, thread ownership, invocation routing, limits, sandbox — WITHOUT building the CAP-9B packaging/reload product.

**Approach:** Reuse the pinned mORMot QuickJS stack (`TThreadSafeManager.NewEngine` → caller-owned `TQuickJSEngine` on a dedicated per-plugin thread). Add ONE private PWeb unit hosting the engine + an `IInvocationSource`-backed source adapter. Script-facing API is a synchronous `pweb.invoke(method, argsObject)` (plus `pweb.handshake()`): a native callback serializes through a JSON envelope, enqueues via the frozen `TryEnqueue`, blocks the plugin thread on an event the completion sink signals, then a JS shim returns the value or throws a PWebError-shaped object. Two deterministic in-memory principals (calculator allowed / reporting denied) prove policy parity; Q1–Q30 headless matrix runs on all four CI targets with a semantic-equality corpus digest.

## Boundaries & Constraints

**Always:**
- Invocation chain exactly: QuickJS plugin thread → source adapter → `IInvocationSource.TryEnqueue` → frozen scheduler/policy/decorators/`TMormotInvocationBridge` → `TRestServer.Uri()` → completion sink → owning plugin thread → script result/error. One scheduler, one policy, one bridge, one error taxonomy.
- Scheduler workers never touch `JSContext`/`JSValue`; the sink only copies the discriminated result into native-owned data and signals the plugin thread; every QuickJS conversion happens on the owning thread.
- `TInvocationContext` built natively: `pkQuickJS`, native `PrincipalId`/`PluginId`, `WindowId=''`, capabilities snapshot from the CAP-8 policy. Script metadata has zero identity authority.
- Use only APIs present in pinned mORMot `b1a129b0`; high-level `TQuickJSEngine`/`NewEngine`/`Evaluate`/`RegisterMethod`/`TimeoutValue` preferred; low-level use limited to `JS_SetMemoryLimit` + a correctly-typed private re-declaration of `JS_SetMaxStackSize` (pin declares `ctx` first arg; pinned C takes `JSRuntime*` — measured crash, see Design Notes).
- QuickJS source authority is the pinned tree `deps/mormot2/res/static/libquickjs` (quickjspp fork, `QUICKJS_VERSION 2021-03-27`, `JS_STRICT_NAN_BOXING`, no quickjs-libc). Windows/Linux x64 consume the sha256-pinned release `quickjs.o`; both macOS targets deterministically compile the same pinned sources in CI (recorded source hash + toolchain + arch check).
- Error parity: discriminated envelope, never payload-shape sniffing; success `{"code":"forbidden"}` stays success; sync API throws a PWebError-shaped JS object carrying exact code/status/data; QuickJS syntax/runtime errors remain distinct from invocation errors; internal_error stays redacted.
- Sandbox: no `fetch`/`XMLHttpRequest`/`WebSocket`/`EventSource`/`require`/`process`/`std`/`os`/filesystem/spawn/DOM globals — verified mechanically (symbol/link audit) and at runtime; `pweb.openExternal` denied for both reference plugins.
- Limits proven per engine: CPU via pinned `TimeoutValue` interrupt, memory via `JS_SetMemoryLimit`, stack via runtime-typed `JS_SetMaxStackSize`; engine disposable after each limit failure; other plugin unaffected.
- Lifecycle: Quiesce→Close→engine destroyed on owning thread; accepted enqueues complete exactly once (result/error/cancelled) so the plugin thread's bounded wait always terminates; late completions die at the exactly-once gate; per-source backpressure with no cross-source bleed.
- CI: all four targets build/link pinned QuickJS, run ABI probes + Q-matrix, emit `build/cap9a/quickjs-corpus.txt`; aggregator requires `quickjs_corpus` PASS and four-way `quickjs_corpus_digest` equality with refusal legs; CAP-7/CAP-8 jobs unweakened.

**Ask First:**
- Any need to patch files under `deps/mormot2` (pin is frozen; the stack-size mistype is worked around PWeb-side, not patched).
- Any second QuickJS source pin (only if a pinned source file provably cannot compile on one target — otherwise STOP semantics).
- Promoting the Promise API instead of the ratified synchronous model.

**Never:**
- Plugin directory scanning, installation, filesystem/ZIP/network script loading, hot reload, ES module resolver, CAP-10 CLI (all CAP-9B+).
- Direct QuickJS→bridge/mORMot/WebView/HTTP paths; second scheduler/bridge/permission model; new core interface; changes to the seven frozen interfaces or `pweb.rpc.intf.pas`.
- `VariantInvoke` (does not exist in mORMot); quickjs-libc linking or `std`/`os` registration; default `external.open` for plugins; positional args; method/key case normalization.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Allowed invoke | calculator plugin, `pweb.invoke("CalculatorService.Add",{a:20,b:22})` | returns `42` via scheduler/policy/mORMot | N/A |
| Denied invoke | reporting plugin, same call | throws PWebError code=`forbidden` status=403; bridge/SOA counters 0 | thrown JS object, not Pascal leak |
| openExternal | either plugin | `forbidden` (no `external.open` granted) | same |
| Success-shaped-as-error | service returns `{"code":"forbidden"}` | plain successful object | no shape sniffing |
| Null success | service returns null | JS `null` returned | never `undefined` |
| service_error | domain failure | throws code=`service_error` with exact `data` | data preserved verbatim |
| internal_error | service raises | throws redacted `internal_error` | no exception text/class leak |
| Malformed method | `pweb.invoke("not a method",null)` | `invalid_request` synchronously (pre-queue) | thrown PWebError |
| Backpressure | source queue full | `busy`; other plugin's source unaffected | thrown PWebError |
| Quiesce/Close during wait | in-flight invocation, source Quiesce→Close | wait resolves `cancelled`/`runtime_closed` per frozen lifecycle; engine destroyed on owning thread; late worker result dropped | bounded wait, no touch of destroyed context |
| Infinite loop | `for(;;){}` with TimeoutValue | interrupted; engine reusable/disposable; other plugin unaffected | EQuickJSEngine contained |
| Deep recursion / over-allocation | stack/memory limits set | safe JS error, engine disposable | no process crash (measured after runtime-typed fix) |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.intf.pas` — FROZEN contracts; `pkQuickJS` already in `TPWebPrincipalKind` (:157); `IInvocationSource.TryEnqueue` (:387), `IInvocationCompletion` (:284), `PWEB_ENQUEUE_ERROR` (:465), code/status tables (:473–:499). READ-ONLY.
- `src/rpc/pweb.rpc.scheduler.pas` — production scheduler; policy at single call site `ExecuteItem` (:689), forbidden-before-routing (:698), exception→internal_error, exactly-once `CompleteOnce`. READ-ONLY.
- `src/rpc/pweb.rpc.mormot.pas` — `TMormotInvocationBridge` (`TRestServer.Uri` path, handshake at :469). READ-ONLY.
- `src/rpc/pweb.rpc.support.pas` — `PWebValidMethod/Args/Context`, `PWebErrorResult`, `PWEB_DEFAULT_ERROR_MESSAGE`. Reuse.
- `src/security/pweb.capabilities.policy.pas` — CAP-8A builder/policy: `SetAppMaximum`, `SetPrincipalCapabilities`, `MapMethod`, `RegisterZeroCapMethod`, `SnapshotCapabilities` (:682), runtime grants (:709–:794). READ-ONLY, consumed as-is.
- `test/cap8c/multiprincipal.pas` — reference wiring: policy+bridge decorators+scheduler+plugin source (:1400–:1415), `RunOn` enqueue/wait pattern (:838), corpus emission (`Emit` :661, `build/cap8c/security-corpus.txt`), counting-bridge zero-activity proof. Template for cap9a harness; also hosts `pweb.openExternal` decorator pattern (`examples/08-release/releaseapp.pas:236` `TReportingBridge`).
- `test/cap7f/emit_evidence.ps1|.sh`, `check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1` — evidence corpus plumbing (`security_corpus_digest` model) to extend with `quickjs_corpus`/`quickjs_corpus_digest` + refusal legs.
- `.github/workflows/ci.yml` — four platform jobs (windows :57, linux :1644, macos-x64 :2013, macos-arm64 :2442) + `cap7-aggregate` (:2876); add cap9a steps mirroring cap8c-multiprincipal steps (:1543, :1931, :2360, :2734).
- `deps/mormot2/src/script/mormot.script.core.pas` — `TThreadSafeManager.NewEngine` (:567): standalone caller-owned engine, `NeverExpire`, `AfterCreate` on calling thread, `fManager=nil` ⇒ no pool/expiry/Destroy-raise hazards (pooled path Destroy raises on unreleased engines :385–:399 — avoid). `ThreadSafeCall` FPU bracket (:701).
- `deps/mormot2/src/script/mormot.script.quickjs.pas` — `TQuickJSEngine` (:101): `AfterCreate` creates runtime+context+interrupt handler (:284), `Evaluate` (:331), `RegisterMethod` variant callback (:388), `TimeoutValue` seconds (:173), callback exception→JS InternalError (:275).
- `deps/mormot2/src/lib/mormot.lib.quickjs.pas` — `JSValueRaw=UInt64` under `JS_STRICT_NAN_BOXING` (:105), static `{$L}` only Linux/Windows FPC (:1729–:1753, no OSDARWIN clause), `JS_SetMemoryLimit` (:944), **`JS_SetMaxStackSize` mistyped `ctx` first param (:950) — pinned C header `quickjs.h:464` takes `JSRuntime*`**; `JS_SetInterruptHandler` (:1442). READ-ONLY (workaround lives PWeb-side).
- `deps/mormot2/src/mormot.defines.inc` — `LIBQUICKJSSTATIC` auto-defined FPC Linux-Intel (:994) + Windows-Intel (:1013/:1017) only; darwin-arm defines `NOLIBCSTATIC` (:1030) ⇒ `pas_malloc` family (mormot.lib.static.pas :257–:301, guarded :214) absent there — PWeb must export them on aarch64-darwin.
- `deps/mormot2/static/<target>/` — sha256-pinned release statics: `quickjs.o` present for x86_64-win64 + x86_64-linux; ABSENT for x86_64-darwin and aarch64-darwin.
- `deps/mormot2/res/static/libquickjs/` — pinned sources (`cutils.c libbf.c libregexp.c libunicode.c quickjs.c` + headers; amalgamation = `cat` per `compile-all.sh`; flags `-DCONFIG_BIGNUM -DJS_STRICT_NAN_BOXING -DCONFIG_JSX -DCONFIG_DEBUGGER`, no quickjs-libc; heap→`pas_*` via `cutils.h:96–:117`).
- `mormot.lock` — pin `b1a129b09197b6b9fb67c6d4d2a13445987a3fe1` + statics sha256. READ-ONLY.

## Tasks & Acceptance

**Execution:**
- [x] `src/script/pweb.script.quickjs.pas` — NEW single unit (adapter+host; separation adds nothing): `TPWebQuickJSPlugin` = dedicated `TThread` owning one `NewEngine` `TQuickJSEngine`, one registered `IInvocationSource`, native immutable `TInvocationContext` (pkQuickJS), `__pweb_invoke_json` native callback (validate → TryEnqueue → bounded event wait → JSON envelope string), bootstrap shim defining `pweb.invoke`/`pweb.handshake` (JSON.parse envelope; throw PWebError object on `ok:false`), per-engine limits (TimeoutValue, `JS_SetMemoryLimit`, private runtime-typed `JS_SetMaxStackSize` external), Quiesce/Close/unload sequence destroying the engine on its thread. Darwin: `{$L}` of CI-built `quickjs.o` + (aarch64 only) `pas_malloc/pas_calloc/pas_free/pas_realloc/pas_malloc_usable_size/pas_assertfailed` exports mirroring `mormot.lib.static`.
- [x] `tools/build_quickjs_darwin.sh` — NEW deterministic clang build of the pinned amalgamation for x86_64/arm64 darwin; records source sha256 + clang version; verifies arch (`lipo -info`) and absence of unexpected exports; refuses non-pinned input (STOP semantics).
- [x] `test/cap9a/quickjsfoundation.pas` — NEW headless harness: ABI probes (SizeOf/alignment/paired C-header constants + value-kind round-trips incl. 53-bit boundary, refcount lifetime, cdecl callback thread-ID asserts), two concurrent plugin threads (calculator allowed / reporting denied), Q1–Q30 matrix, corpus `build/cap9a/quickjs-corpus.txt` (platform-neutral lines only).
- [x] `test/cap9a/abiprobe.c` — NEW paired C probe compiled where CI has the matching toolchain (gcc/mingw/clang) against pinned headers: `sizeof(JSValue)`, tag constants, cdecl callback signature echo; Pascal side cross-checks.
- [x] `test/cap9a/run_quickjsfoundation.ps1` + `.sh` — NEW runners mirroring cap8c pattern (build with `-dLIBQUICKJSSTATIC` where not auto-defined, `-Fl` per target, run, verify corpus written).
- [x] `test/cap7f/emit_evidence.ps1|.sh` — extend: `quickjs_corpus` PASS/FAIL + `quickjs_corpus_digest` (sha256 of corpus) fields.
- [x] `test/cap7f/check_cap7f_aggregate.ps1` — require `quickjs_corpus` PASS on four targets + digest equality; refusal branches (missing field, SKIP, divergence).
- [x] `test/cap7f/check_cap7f_selftest.ps1` — add negative legs for the new refusals.
- [x] `.github/workflows/ci.yml` — add per-target cap9a steps (macOS jobs run `build_quickjs_darwin.sh` first); wire corpus into evidence upload; keep CAP-7/8 steps untouched.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` — append: CAP-9B script/package loading + modules + hot reload; Promise invocation API candidate; upstream mORMot `JS_SetMaxStackSize` signature bug report (strip proprietary context before filing).

**Acceptance Criteria:**
- Given the four hosted CI targets, when cap9a runs, then every target builds/links the pinned QuickJS, ABI probes pass (`JSValueRaw`=8 bytes etc.), Q1–Q30 pass, and ONE `quickjs_corpus_digest` is equal four-way.
- Given the denied reporting plugin, when it invokes `CalculatorService.Add` and `pweb.openExternal`, then both throw forbidden/403 with zero bridge/SOA/opener activity (counted, not assumed).
- Given plugin A saturating its source, when plugin B invokes, then B's bounds are unaffected (Q26); given source Quiesce/Close mid-invocation, then the waiting plugin thread resolves per frozen lifecycle and its engine is destroyed on its own thread with a late completion dropped (Q16–Q19).
- Given runtime-grant revocation for the calculator principal, when the next invocation runs, then it is forbidden while an in-flight one keeps its captured snapshot (Q28–Q29).
- Given the closure commit, when CAP-7/CAP-8 jobs and the divergence sweep run, then they remain green and frozen files byte-unchanged.

## Design Notes

- **Ownership (measured):** pooled `ThreadSafeEngine()` is wrong-shaped (expiry pool; `TThreadSafeManager.Destroy` raises on unreleased engines). `NewEngine` gives caller-owned, `NeverExpire`, created-on-calling-thread engines with `fManager=nil` — one shared app-lifetime `TThreadSafeManager(TQuickJSEngine)` mints them; each plugin thread creates AND frees its own engine ⇒ strict thread affinity, full runtime/context isolation per plugin, no shared-context boundary.
- **Sync over Promise (measured):** plugin engines run on dedicated non-scheduler threads, so a bounded native wait is legal; exactly-once completion guarantees wait termination through Quiesce/Close/Shutdown. Promise needs `JS_NewPromiseCapability`+`JS_Call`+job pump+cross-enqueue JSValue rooting — a large low-level surface the pinned high-level wrapper does not expose. Sync needs zero extra JSValue lifetime management. Promise recorded as deferred candidate.
- **JSON envelope over variant round-trip:** native callback returns ONE JSON string `{"ok":true,"value":<verbatim-json>}` / `{"ok":false,"error":{code,status,message,data}}`; shim `JSON.parse`s it. Exact key case/order, null vs undefined, and success-shaped-like-error all preserved without DocVariant conversion fidelity risks (local probe P9 passed: method case + arg keys verbatim).
- **Pin defect (measured, Win x64):** calling pinned `JS_SetMaxStackSize(ctx,…)` corrupts the context → AV under allocation pressure (exit 0xC0000005); correctly-typed private external `(rt,…)` makes stack+memory+timeout limits all fail safe with clean destroy. Do NOT call the mistyped binding anywhere.
- **Local Windows probe results (dev host):** static link OK; `SizeOf(JSValueRaw)=SizeOf(JSValue)=8`; sandbox globals all `undefined`; infinite loop interrupted at `TimeoutValue=1s`; recursion bounded; OOM safe on fresh engine; 5× create/evaluate/destroy clean.
- **Timeout applies per `Evaluate` call** (interrupt handler polls `GetTickSec`, 1 s granularity) — set before each plugin script execution; the native wait inside `__pweb_invoke_json` is bounded separately (defensive cap ⇒ internal_error, normally unreachable given exactly-once).

## Verification

**Commands:**
- `pwsh test/cap9a/run_quickjsfoundation.ps1` — expected: Q1–Q30 PASS, `build/cap9a/quickjs-corpus.txt` written (Windows dev host).
- `pwsh test/cap8c/run_multiprincipal.ps1` + `pwsh test/cap7f/check_divergence.ps1` — expected: CAP-8 regression + divergence sweep stay green.
- Aggregator negative tests against fixture copies (field removed / digest mutated) — expected: refusal naming target/field; genuine downloads — PASS.
- Hosted CI on the shard branch — expected: all jobs green incl. four-way `quickjs_corpus_digest` equality.

## Suggested Review Order

**Engine host + source adapter (the shard's production surface)**

- The whole architecture in one header: ownership, sync model, envelope, limits, lifecycle.
  [`pweb.script.quickjs.pas:1`](../../src/script/pweb.script.quickjs.pas#L1)

- The one native callback: validate -> frozen TryEnqueue -> bounded wait -> JSON envelope.
  [`pweb.script.quickjs.pas:536`](../../src/script/pweb.script.quickjs.pas#L536)

- The completion sink: worker copies + signals only; result published before the done flag.
  [`pweb.script.quickjs.pas:396`](../../src/script/pweb.script.quickjs.pas#L396)

- Engine created AND destroyed on the plugin thread; per-script CPU bound never silently disabled.
  [`pweb.script.quickjs.pas:578`](../../src/script/pweb.script.quickjs.pas#L578)

- Frozen teardown order: Quiesce -> Close -> join; guarded against constructor-failure paths.
  [`pweb.script.quickjs.pas:691`](../../src/script/pweb.script.quickjs.pas#L691)

**Pin workarounds (measured defects, mORMot untouched)**

- The correctly-typed `JS_SetMaxStackSize` external - the pinned binding corrupts the context.
  [`pweb.script.quickjs.pas:275`](../../src/script/pweb.script.quickjs.pas#L275)

- Darwin link block: CI-built object + aarch64 `pas_*` exports (widened vs the pin's cardinal).
  [`pweb.script.quickjs.pas:208`](../../src/script/pweb.script.quickjs.pas#L208)

**Script-facing surface**

- The bootstrap shim: `pweb.invoke`/`pweb.handshake`, throw-on-error, raw callback removed from globals.
  [`pweb.script.quickjs.pas:439`](../../src/script/pweb.script.quickjs.pas#L439)

**Darwin build determinism**

- Pin gate (HEAD + tree cleanliness), exact upstream amalgamation, arch check, fail-closed libc audit.
  [`build_quickjs_darwin.sh:1`](../../tools/build_quickjs_darwin.sh#L1)

**The Q1-Q30 proof**

- The matrix map and determinism contract of the corpus digest.
  [`quickjsfoundation.pas:3`](../../test/cap9a/quickjsfoundation.pas#L3)

- Counting bridge: per-principal ledgers, held-call barrier, late-worker rendezvous fact.
  [`quickjsfoundation.pas:470`](../../test/cap9a/quickjsfoundation.pas#L470)

- Lifecycle legs q16-q19: Close mid-wait -> cancelled; deterministic late-completion rendezvous.
  [`quickjsfoundation.pas:1128`](../../test/cap9a/quickjsfoundation.pas#L1128)

- CAP-8A policy wiring: two pkQuickJS principals, explicit empty set for the denied one.
  [`quickjsfoundation.pas:529`](../../test/cap9a/quickjsfoundation.pas#L529)

- ABI section: sizes, pinned tags, 53-bit boundary, refcount round-trip, engine churn.
  [`quickjsfoundation.pas:736`](../../test/cap9a/quickjsfoundation.pas#L736)

**Evidence chain (must-PASS, four-way digest)**

- Windows emitter: verbatim verdict, required counters, corpus digest.
  [`emit_evidence.ps1:386`](../../test/cap7f/emit_evidence.ps1#L386)

- Aggregator: mustPass + equality + the CAP-9A defense-in-depth refusals.
  [`check_cap7f_aggregate.ps1:173`](../../test/cap7f/check_cap7f_aggregate.ps1#L173)

- Selftest legs c11-c14: every new refusal branch proven red on fixtures.
  [`check_cap7f_selftest.ps1:1`](../../test/cap7f/check_cap7f_selftest.ps1#L1)

**Peripherals**

- Windows runner: CAP-3U window, honest ABI-diff skip on broken toolchains.
  [`run_quickjsfoundation.ps1:1`](../../test/cap9a/run_quickjsfoundation.ps1#L1)

- POSIX runner: linux pinned-object audit; darwin build-then-link; paired C ABI diff always gates.
  [`run_quickjsfoundation.sh:1`](../../test/cap9a/run_quickjsfoundation.sh#L1)

- Paired C probe against the pinned headers.
  [`abiprobe.c:1`](../../test/cap9a/abiprobe.c#L1)

- The four platform-job gates (windows/linux/macos-x64/macos-arm64) + diagnostics paths.
  [`ci.yml:1561`](../../.github/workflows/ci.yml#L1561)

- Divergence-sweep allowlist entry for the one new platform-conditional file.
  [`check_divergence.ps1:77`](../../test/cap7f/check_divergence.ps1#L77)
