---
title: 'CAP-9B1 — QuickJS plugin package and deterministic module loader'
type: 'feature'
created: '2026-08-26'
status: 'in-review'
review_loop_iteration: 0
baseline_commit: 'b04caf12bf6af494d9791221da26e8dc0b27085b'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/core-interfaces.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/security-model.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9a-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-9A froze the QuickJS engine, thread ownership, invocation routing, limits and sandbox, but a plugin still arrives only as an in-memory script string posted by the host. There is no package, no manifest and no ES module graph: `Evaluate` uses `JS_EVAL_TYPE_GLOBAL` and a CAP-9A engine registers no module loader, so any `import` fails with `could not load module`.

**Approach:** Add a package/module-loader layer *behind* the frozen CAP-9A engine. A native authoritative descriptor supplies identity, capabilities and the package's `IAssetStore`; a strict `plugin.json` supplies code metadata only. On the owning plugin thread, after the CAP-9A bootstrap, install a private module loader via `JS_SetModuleLoaderFunc` whose normalize callback performs *all* resolution and whose loader callback reads exactly one canonical logical path through `IAssetStore.TryRead`. Package load is atomic. Prove it with a P1–P40 headless matrix over one corpus served by `TFolderAssetStore` and `TZipAssetStore`, digest-equal on all four CI targets.

## Boundaries & Constraints

**Always:**
- The carrier is ONE existing `IAssetStore` per package. The loader depends only on `TryRead` — never on Win32, POSIX, ZIP, any filesystem/archive API, or the CWD.
- Identity is native and only native: `PrincipalKind` is always `pkQuickJS`; `PrincipalId`, `PluginId` and capabilities come from the host-built descriptor. `plugin.json` and JavaScript change none of them and grant nothing.
- Resolution happens entirely in our normalize callback (algorithm in Design Notes); `../` never reaches `IAssetStore`, and the resolved name passes `PWebAssetPathValid` before any lookup.
- Every loader callback, package store read, compile and `JSValue`/`JSContext` touch happens on the owning plugin thread; wrong-thread callbacks and store reads are counted and must be zero. Scheduler workers stay limited to backend invocations.
- Static ES modules only: no CommonJS, `require`, Node/`package.json` resolution, import maps, JSON or native modules, network imports, or `import()` support; nothing pumps the QuickJS job queue.
- Load is atomic. On failure: no module left running, engine destroyed on its owning thread, source Quiesced and Closed, no invocation pending, nothing visible as Running.
- Package/load errors are NATIVE start failures with their own code set, never the nine-code RPC taxonomy. They may carry package-relative module name and QuickJS line/column; never absolute host paths, CWD, native pointers or `JSContext` addresses. Script-visible loader throws are fixed literals with no interpolation.
- Manifest size, per-module size, total source, distinct module count, specifier length and graph depth are bounded BEFORE the QuickJS heap limit is relied on.
- Per-engine module cache only: two plugins loading the same path get isolated instances; no process-global registry; the cache dies with the engine.
- Folder and ZIP carriers produce identical manifest projection, module list, module hashes, import graph, evaluation result, invocation result and corpus digest.
- CAP-9A behaviour is unchanged when no package is configured: Q1–Q30 and `quickjs_corpus_digest` stay green and unmodified. Every CAP-7/CAP-8/CAP-9A gate is retained unweakened, and the aggregator gains `quickjs_package_corpus` (must-PASS) plus four-way `quickjs_package_digest` equality with committed refusal legs.

**Ask First:**
- Any change to `deps/mormot2` (pin stays byte-unchanged; defects are worked around PWeb-side).
- Any change to the seven frozen interfaces, including `IAssetStore.TryRead`'s signature or adding enumeration to it.
- Enabling `import()`, a Promise/job pump, or any dynamic module form.
- Allowing `pweb.invoke` during top-level module evaluation (this spec ratifies: refused).
- Any manifest field beyond the four ratified ones, or accepting a package whose id/entry disagrees with native registration.

**Never:**
- Filesystem or network APIs exposed to QuickJS; arbitrary host paths reachable from a specifier; code from CWD or network.
- Plugin discovery/scanning, directory watching, installation/update, signed packages, lifecycle hooks, reload/unload as a product feature (CAP-9B2), release packaging (CAP-9C).
- A new public kernel interface, a second RPC path, a second permission system, or a parallel module system alongside QuickJS's own.
- Capabilities, principals, plugin ids or trust flags inside `plugin.json` — such keys are rejected loudly, before engine creation.
- Silent normalization: no case folding, extension probing, implicit `index.js`, directory import, or URI decoding of specifiers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Valid package loads | descriptor + store with `plugin.json`, `main.js`, `lib/*`, `shared/*` | manifest projected, entry + graph compiled and evaluated on the plugin thread, plugin Running | N/A |
| Duplicate import | `lib/state.js` imported by `main.js` and by `lib/calculator.js` | loader called once, body executes once, second resolve is a cache hit | N/A |
| Parent-relative inside root | `../shared/unit.js` from `lib/calculator.js` | resolves to `shared/unit.js`; store sees only that path | N/A |
| Refused specifiers | root escape, bare, absolute, URL, `?query`, `#frag`, backslash, no extension, directory | refused in normalize; store never consulted | `plcSpecifier`; script sees a fixed literal |
| Case mismatch | `./lib/Calc.js` where only `lib/calc.js` exists | resolves to `lib/Calc.js`; byte-exact store lookup misses | `plcModuleMissing` |
| Security-authority manifest keys | `capabilities` / `allow` / `principalId` / `trustedContent` | rejected BEFORE engine creation; effective rights unchanged | `plcManifestForbiddenField` |
| Manifest disagrees with native | `id` or `entry` ≠ descriptor expectation | rejected before engine creation | `plcManifestId` / `plcEntryMismatch` |
| Manifest malformed | bad syntax, duplicate key, unknown key, bad UTF-8, oversized | rejected | `plcManifestSyntax` / `…DuplicateKey` / `…UnknownField` / `…Encoding` / `…TooLarge` |
| Module source encoding | invalid UTF-8 or embedded NUL / BOM / empty / CRLF | first two refused before compile; BOM stripped once, empty accepted, line endings preserved verbatim | `plcModuleEncoding` |
| Graph exceeds a bound | module >1 MiB, total >8 MiB, >256 modules, depth >64, specifier >512 B | refused deterministically at that bound | `plcModuleTooLarge` / `plcTotalSource` / `plcModuleCount` / `plcDepth` / `plcSpecifier` |
| Syntax error in an imported module | `lib/bad.js` | load fails carrying package-relative name + line | `plcCompile`, no host path in the text |
| `pweb.invoke` during top-level eval | entry calls it while Loading | throws PWebError `runtime_closed`; zero bridge/SOA activity | counted; ledger must stay zero |
| `pweb.invoke` after a successful load | exported function invoked by the host | CAP-9A verbatim: `CalculatorService.Add` → 42 | denied plugin still `forbidden`/403 |
| Failed load | any of the above | no engine alive, source Quiesced+Closed, no pending invocation, not Running | atomic |
| `import("./x.js")` | dynamic import at any point | promise never settles (no job pump); module never loaded | routing proven through the same scoped normalize/loader |

</frozen-after-approval>

## Code Map

Every claim below was measured at plan time on Windows x64 / FPC 3.2.2 with a throwaway probe against the pinned tree — not inferred from reading.

**Pinned engine seam (read-only)**
- `deps/mormot2/src/lib/mormot.lib.quickjs.pas:1450` — `JS_SetModuleLoaderFunc(rt, normalize, loader, opaque)`; callback types at `:733-740`. This is the ONLY seam needed: `TQuickJSEngine.rt`/`.cx` are public (`deps/mormot2/src/script/mormot.script.quickjs.pas:145,148`), so no wrapper replacement.
- `mormot.lib.quickjs.pas:1080,1083` — normalize MUST return a `js_malloc`'d NUL-terminated buffer; QuickJS `js_free`s it (`deps/mormot2/res/static/libquickjs/quickjs.c:27691`).
- `quickjs.c:27656` `js_host_resolve_imported_module` — with a normalize function set, QuickJS does **no** path joining: it passes `(base = importing module's canonical name, spec = specifier VERBATIM)`. Measured: `../shared/unit.js`, bare `lodash`, `https://evil.example/x.js` and `../../etc/passwd` all arrive unmodified, so the resolver sees and refuses them; there is no fallback path anywhere.
- `mormot.lib.quickjs.pas:1543-1575` — `js_init_module_std`/`js_init_module_os`/`js_module_loader` sit under `{$ifdef QUICKJSLIBC}` and are not linked. Measured: `import * as std from "std"` reaches our normalize like any other specifier.
- `deps/mormot2/res/static/libquickjs/quickjs-libc.c` `js_module_loader` — the loader shape to mirror: `JS_Eval(…, JS_EVAL_TYPE_MODULE or JS_EVAL_FLAG_COMPILE_ONLY)` → `JSValue.Ptr` → free the value. Measured: **QuickJS copies the source** — wiping every Pascal buffer and forcing GC before evaluation still yields the right result, so no source-lifetime problem exists.
- Pin behaviours that shape the design, all measured: top-level `await` is a **SyntaxError** in this pin (`2021-03-27`), so entry evaluation is always synchronous and no pending-promise entry state can exist; `import()` enqueues a job (`quickjs.c:28634`) and with no pump never settles and never calls the loader — force-pumped, it routes through the *same* scoped normalize/loader, so it cannot bypass the resolver; `JS_ExecutePendingJob(rt, pctx)` **writes through `pctx`** and AVs on `nil` (the binding carries a "TODO: check" comment) — never call it.
- `mormot.script.quickjs.pas:331` `TQuickJSEngine.Evaluate` is the only public API that arms the interrupt (`fTimeoutStartTickSec` is protected). Measured: evaluating a module without a prior `Evaluate` aborts instantly with `InternalError: interrupted` / `TimeoutAborted=True`.

**PWeb production (to extend)**
- `src/script/pweb.script.quickjs.pas` — CAP-9A host. `Execute` (`:578`) creates the engine, applies limits, registers `__pweb_invoke_json`, evaluates `PWEB_QUICKJS_BOOTSTRAP` (`:434`); the package load slots in immediately after, on the same thread, before `RTLEventSetEvent(FReady)`. `InvokeJson` (`:536`) gains the Loading gate. The wrong-thread counter and explicit `GetCurrentThreadId()` call note (`:551`) are reused verbatim for the loader callbacks. `Unload` (`:697`) already does Quiesce→Close→join with the engine freed in `Execute`'s epilogue — the atomic-failure path reuses it.
- `src/assets/pweb.assets.support.pas` — `PWebAssetPathValid` (`:226`) already rejects `..`, `.`, empty segments, NUL/controls, `\`, `:`, `%`, `<>"|?*`, device names, trailing dot/space and overlong UTF-8, and bounds length. Reuse it as the final gate on every resolved module name. Its private `StrictUtf8` (`:108`) is the one UTF-8 truth and must be exposed additively as `PWebStrictUtf8` for manifest and module-source validation.
- `src/assets/pweb.assets.intf.pas` — frozen `IAssetStore.TryRead` and its canonical-path contract. `src/assets/pweb.assets.zip.pas:88` `CreateFromBuffer` makes the ZIP leg buildable in memory.
- `src/rpc/pweb.rpc.intf.pas:185` `TInvocationContext`, `:153` `pkQuickJS` (already present), `:70` `PWEB_METHOD_HANDSHAKE` — routed through the bridge (`src/rpc/pweb.rpc.mormot.pas:469`), so handshake is an ordinary invocation and the Loading gate covers it too.

**Test / CI shape to mirror**
- `test/cap9a/quickjsfoundation.pas` — corpus/JSON/marker conventions, `TARGET_ID` block, in-source constants only. `test/cap9a/run_quickjsfoundation.ps1` / `.sh` — runner shape (precondition list, marker extraction, output wipe, run from an unrelated CWD, CAP-3U window on the mORMot-bridge build).
- `test/assets/pweb.test.assets.pas:341-380` — the folder-fixture + in-memory `TZipWrite` twin-carrier setup to copy; `test/cap7m/cap7m_runtime.pas:100,390` — the `FIXED_FILE_AGE` archive-determinism note.
- `test/cap7f/emit_evidence.ps1:391-428` / `.sh`, `check_cap7f_aggregate.ps1:58,74,83,178,314,332,352,359`, `check_cap7f_selftest.ps1:241-268` — exactly where the new `quickjs_package_corpus` / `quickjs_package_digest` fields and their two refusal legs go.
- `.github/workflows/ci.yml:1557,1973,2438` — the three places the CAP-9A gate is wired per platform. `test/cap7f/check_divergence.ps1:79` — the platform-directive allowlist; new units carry no platform `{$ifdef}` and need no entry.

## Tasks & Acceptance

**Execution:**
- [x] `src/assets/pweb.assets.support.pas` -- expose the existing private `StrictUtf8` as `PWebStrictUtf8` (pure addition, body unchanged) -- keeps ONE UTF-8 truth for paths, manifest and module source.
- [x] `src/script/pweb.script.package.pas` -- NEW pure unit, no QuickJS dependency: `TPWebPackageLimits` + defaults/hard maxima; `TPWebPackageLoadCode` + text table; `TPWebPackageManifest`; `PWebPackageIdValid`; `PWebPackageEntryValid`; `PWebParsePluginManifest` (strict scanner); `PWebResolveModuleSpecifier`; `PWebPrepareModuleSource` (BOM-once, strict UTF-8, NUL refusal); `TPWebScopedAssetStore` -- headless-testable without an engine.
- [x] `src/script/pweb.script.quickjs.pas` -- add `TPWebQuickJSPackageDescriptor` (native authority), the private normalize/loader callbacks with thread assertions and graph accounting, the arm-then-compile-then-evaluate entry step inside `Execute`, the Loading gate in `InvokeJson`, and `PWebLoadQuickJSPackage` (atomic; nil + code + native detail on failure) -- CAP-9A paths unchanged when no descriptor is supplied.
- [x] `test/cap9b1/quickjspackage.pas` -- NEW P1–P40 harness: generates the reference package and every hostile fixture from in-source byte constants into a temp folder AND an in-memory ZIP, runs both carriers through the real scheduler / CAP-8A policy / mORMot bridge, covers every I/O-matrix row, and writes `build/cap9b1/quickjs-package-corpus.txt` (schema 1: manifest projection, module list, module hashes, import-graph hash, hostile decisions, counters, `verdict=PASS`) plus `quickjspackage-<target>.json`.
- [x] `test/cap9b1/run_quickjspackage.ps1` + `run_quickjspackage.sh` -- runners mirroring the CAP-9A pair.
- [x] `test/cap7f/emit_evidence.ps1` + `emit_evidence.sh` -- record `quickjs_package_corpus` (PASS|FAIL, never SKIP), `quickjs_package_digest`, and the load-time-invocation and denied-bridge ledgers.
- [x] `test/cap7f/check_cap7f_aggregate.ps1` -- add both fields to the required / must-PASS / equal-across-targets sets and the summary table.
- [x] `test/cap7f/check_cap7f_selftest.ps1` -- two committed refusal legs: `quickjs_package_corpus` forced FAIL, and `quickjs_package_digest` diverging on one target.
- [x] `.github/workflows/ci.yml` -- run the CAP-9B1 gate before the CAP-7F emitter on all four platform jobs, with uploads and diagnostics mirroring CAP-9A.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append what CAP-9B1 leaves to CAP-9B2/CAP-9C (lifecycle/reload, discovery, signed packages, `import()`/Promise pump) and the `JS_ExecutePendingJob(nil)` null-write hazard found in the pin.

**Acceptance Criteria:**
- Given a package whose `plugin.json` matches the native descriptor, when it loads through either carrier, then the plugin reaches Running, the CAP-9A `CalculatorService.Add` path still returns 42, and both carriers produce byte-identical corpus lines.
- Given any hostile fixture in the I/O matrix, when it loads, then the load fails with the stated code, the engine is destroyed on its owning thread, the source is Closed, no invocation is pending, and the plugin never becomes Running.
- Given a package that calls `pweb.invoke` during top-level evaluation, when it loads, then the call throws `runtime_closed`, bridge and SOA counters stay zero, and the load still succeeds if nothing else fails.
- Given two plugins loading the same logical module path, when both run, then their module instances and globals are independent and no module executes in the wrong engine.
- Given the full matrix on windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64, then `quickjs_package_corpus` is PASS on all four and one `quickjs_package_digest` is equal across all four, while every CAP-7/CAP-8/CAP-9A gate and digest is unchanged.
- Given the whole change, when the freeze sweep runs, then the seven interfaces, `pweb.rpc.intf.pas`, scheduler/source lifecycle, CAP-8 policy/navigation semantics, the mORMot and QuickJS pins, the JSValue ABI, the error taxonomy, protocol v1, the SDK wire, `app.pwb` and the platform adapters are untouched.

## Spec Change Log

## Design Notes

**Why normalize owns all resolution.** With a normalize function installed the specifier arrives verbatim and QuickJS joins nothing (measured). One function therefore decides, from `(base, spec)`, the single canonical path the store will ever see; `..` is folded in our stack and never reaches `IAssetStore`.

```
Resolve(base, spec):
  reject unless spec starts './' or '../'      -> bare/absolute/scheme refused
  reject NUL/ctrl, '\', ':', '?', '#', '%', <>"|*
  join dir(base) + spec                         (dir('main.js') = '')
  fold: '.' skip | '' reject | '..' pop-or-REJECT | else push
  rebuild with '/'; require '.js'/'.mjs'; bound 512 bytes
  require PWebAssetPathValid(result)            -> the CAP-4 fail-closed gate
```
Measured on the candidate implementation: `../shared/unit.js` from `lib/calc.js` → `shared/unit.js`; `./lib/../lib/../lib/calc.js` → `lib/calc.js`, loaded once; `../outside.js`, `lodash`, `/lib/calc.js`, `.\lib\calc.js`, `./lib/calc.js?x=1`, `./lib/calc.js#a`, `./lib/`, `./lib/calc` → all refused before any store read; `./lib/Calc.js` resolves and then misses the byte-exact store, which is the correct layering (case is a lookup property, not a syntax property).

**Ratified decisions.**
- *Entrypoint authority:* option **B** — native `ExpectedEntryPoint` is authoritative; `plugin.json`'s `entry` must equal it byte-exactly. Removes a mutable startup choice.
- *Manifest:* exactly `{"schema":1,"id":…,"version":"X.Y.Z","entry":…}` at the fixed package-root path `plugin.json`. Strict hand-written scanner, not a general JSON parser: whitespace limited to space/TAB/CR/LF; **no escape sequences accepted in any string** (all three values are constrained grammars that never need one); duplicate keys, unknown keys and the eight security-authority keys (`allow`, `capabilities`, `permissions`, `principal`, `principalId`, `pluginId`, `runtimeGrants`, `trustedContent`) rejected, the last with their own loud code; `schema` must be the integer `1`; ≤ 64 KiB; strict UTF-8; optional BOM stripped once.
- *Package-id grammar:* `[a-z0-9]+(\.[a-z0-9]+)*`, ASCII, 1..64 bytes, exact case, no normalization — descriptive metadata that must match `ExpectedPackageId`; native `PrincipalId`/`PluginId` stay authoritative.
- *Load-time invocation:* **refused**. `pweb.invoke` (and therefore `pweb.handshake`) throws `runtime_closed` while Loading. Measured feasible either way — a native callback does run during top-level module evaluation — so this is policy: a package that is not yet accepted must produce no backend side effects, and the gate is one flag in `InvokeJson`, auditable in one place.
- *Dynamic import:* **unavailable**, not specially blocked. Nothing pumps the job queue, so `import()` returns a promise that never settles and the loader is never called; force-pumping proved it routes through the same scoped resolver, so it cannot bypass it even if a future shard adds a pump. Top-level `await` is a SyntaxError in this pin, so no half-loaded async entry exists.
- *Limits:* manifest 64 KiB; module 1 MiB; total source 8 MiB; 256 distinct modules; specifier 512 bytes; graph depth 64. Depth is tracked in normalize (`depth(child) = depth(base)+1`, entry = 0); the module-count cap independently bounds the native `js_resolve_module` recursion, since a chain of N modules needs N distinct modules.
- *Error text:* the loader throws fixed literals (`pweb: module not found`, `pweb: invalid module specifier`) with no interpolation, for the varargs reason above. The exact module name and reason are recorded natively and surface in the package-load failure, which is where a host wants them.

**Two pin behaviours not to rediscover.** (1) The interrupt is armed only by `Evaluate`, so the package load must call `FEngine.Evaluate('0', 'pweb-arm.js')` before compiling the entry or the first module opcode aborts (measured); one armed window then covers manifest → entry → whole graph. (2) `js_module_set_import_meta` is deliberately NOT called: it is unnecessary and its `use_realpath` branch touches the filesystem, so `import.meta` carries no `file://` name at all.

**Fixtures are generated, never committed.** Hostile cases include invalid UTF-8, embedded NUL, oversized and CRLF modules; committed files would be at the mercy of `core.autocrlf` and would break module-hash parity between a Windows and a POSIX checkout. The harness writes every fixture from in-source byte constants into a temp folder and builds the ZIP from the same bytes, so both carriers are byte-identical by construction on all four targets — the discipline CAP-9A used for its scripts.

## Verification

**Commands:**
- `pwsh -NoProfile -File test/cap9b1/run_quickjspackage.ps1` -- expected: `quickjspackage: QUICKJS PACKAGE PASS`, exit 0, corpus written ending in `verdict=PASS`.
- `pwsh -NoProfile -File test/cap9a/run_quickjsfoundation.ps1` -- expected: CAP-9A still PASS with an unchanged `quickjs-corpus.txt` digest.
- `pwsh -NoProfile -File test/cap7f/check_cap7f_selftest.ps1` -- expected: every refusal leg red on its fixture, including the two new CAP-9B1 legs.
- `git -C deps/mormot2 status --porcelain` -- expected: empty (pin untouched).
- `pwsh -NoProfile -File test/cap7f/check_divergence.ps1` -- expected: no new platform-directive divergence.

**Manual checks:**
- `build/cap9b1/quickjs-package-corpus.txt` shows, for both carriers, the same manifest projection, module list, module hashes and import-graph hash, with its parity line reading identical.
- The corpus counters `loader_wrong_thread`, `store_wrong_thread`, `loadtime_bridge` and `denied_bridge` are all `0`.
