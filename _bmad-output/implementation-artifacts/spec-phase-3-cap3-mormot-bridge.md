---
title: 'PWeb Phase 3 / CAP-3 — real mORMot bridge: TRestServer.Uri() in-process, exact-case routing, frozen result/error mapping'
type: 'feature'
created: '2026-08-10'
status: 'done'
review_loop_iteration: 0
baseline_commit: '2c68d3e8fadd317e21c07207f4d1132aa97c4ac8'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/wire-semantics.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The CAP-2 pipeline is proven end to end but the bridge is a dummy: no invocation reaches a real service. The PWeb concept — JS → scheduler → policy → mORMot SOA → resolved promise with zero network — is still unproven.

**Approach:** Implement the one concrete `IInvocationBridge` for mORMot (`TMormotInvocationBridge` in `src/rpc/pweb.rpc.mormot.pas` per frozen conventions): exact-case method catalog from mORMot service metadata, `TRestUriParams` → `TRestServer.Uri()` in-process dispatch, translation of mORMot responses into the frozen `TPWebInvocationResult`, runtime-owned `pweb.echo`/`pweb.handshake`, a real registered `ICalculatorService`, headless gating integration tests, runtime example `examples/03-mormot-rpc/`, and zero-network proof gates. Gate: `CalculatorService.Add {"A":20,"B":22}` resolves to `42`.

## Boundaries & Constraints

**Always:**
- CAP-2 pipeline untouched: the policy call site stays in the scheduler worker; no second policy invocation, no relocation, no bypass. The byte-identical canonical `Service.Method` that passed policy enters the bridge.
- Study the PINNED mORMot (`deps/mormot2`), never memory: probe `TRestServer.Uri` first, record observed facts in this artifact, adapt the bridge to observed behavior. PWeb's public contract never mimics accidental mORMot wire details.
- In-process only: `TRestUriParams` → `TRestServer.Uri()`. mORMot's HTTP-shaped statuses/URIs are an in-memory dispatch mechanism, not a transport.
- Exact-case exposure check BEFORE `Uri()` — the pinned router is case-insensitive — rejecting any case variant as `method_not_found` before SOA. Catalog from mORMot public metadata, never hard-coded, no second registration framework.
- Args stay valid JSON (object or `'null'`, never `''`); each `InBody` gets a unique writable buffer (`UniqueRawUtf8`) after final assignment before `Uri()` — mORMot parses `InBody` in place.
- Bridge returns only the frozen discriminated `TPWebInvocationResult`; success `CalculatorService.Add` → `42`, NOT `{"result":42}`; discrimination never sniffs payload shape.
- Error mapping uses only the frozen nine-code taxonomy via existing helpers; never expose class names, stacks, paths, SQL, route details, unit names, or pointers; never parse human exception text. `service_error` flows only through an explicit intentional channel; mORMot 403s map to `internal_error` (policy is the only `forbidden` producer).
- `pweb.*` runtime-owned: `pweb.echo` preserved; `pweb.handshake` returns exactly `{protocol, runtime, capabilities}` (smallest truthful capabilities); an app service surfacing as `pweb` is refused at startup.
- Token checked before entering mORMot (cancelled → service never called); inside the synchronous `Uri()` cancellation stays cooperative — no thread termination; CAP-2 exactly-once completion remains authoritative.
- `Uri()` executes on scheduler workers only — never bind/GUI/dispatch callbacks; zero GUI assumptions in the bridge; concurrent `Uri()` exercised for real.
- Explicit `TRestServer` ownership; shutdown order sources Close → scheduler `Shutdown`/drain → bridge/server destruction; a worker never calls `Uri()` on a destroyed server.
- Bridge unit depends on `pweb.rpc.intf`, `pweb.rpc.support`, mORMot only — no `pweb.webview.*`, no webview C ABI, no HTTP server classes; QuickJS must reuse it unchanged.
- CI: every CAP-1/CAP-2 gate preserved verbatim; new gates per Tasks; interactive runs stay best-effort/non-gating. House patterns per `conventions.md` and kernel.

**Ask First:** any change to a frozen Phase-0 public signature (STOP AND REPORT instead); no safe/stable pinned mechanism for deliberate service errors compatible with the frozen `service_error` contract (STOP AND REPORT, never invent a brittle string convention); pushing, merging, or starting Phase 4.

**Never:** modify `src/rpc/pweb.rpc.intf.pas`, `src/webview/pweb.webview.intf.pas`, `src/assets/pweb.assets.intf.pas`, `src/lib/*`; redesign CAP-2 scheduler/binding/lifecycle; an eighth core interface; `TRestHttpServer`/`TRestClientHttp`/`THttpServer`/loopback/listener/named-pipe RPC/localhost anything; slash syntax or raw mORMot URIs on the wire; positional-array args; case folding or parameter-name normalization; Phase-4+ scope (assets, `pweb://app`, blobs, React/Pas2JS SDK, ZIP, real capability policy, QuickJS, CLI, provisioning, non-Windows, event bus, OpenAPI, auth protocol); Phase-8 capability vocabulary design.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Gate | `CalculatorService.Add` `{"A":20,"B":22}` | success value `42` (naked JSON number) | N/A |
| Named binding | args object, any property order | bound by name to Pascal params | N/A |
| Null args, no-input method | `'null'` | success (mORMot absent-input form) | N/A |
| Null/missing args, method with inputs | `'null'` to `Add` | pinned behavior recorded by probe; with `optErrorOnMissingParam` on the fixture → invalid_request | frozen message, no mORMot errorText |
| Malformed binding | wrong types / unknown names (option set) | mORMot 406 | `invalid_request`, mORMot text redacted |
| Unknown service / unknown method | `NoSuch.Add`, `CalculatorService.Nope` | rejected by exact catalog, `Uri()` never called | `method_not_found` |
| Case variant | `calculatorservice.Add`, `CalculatorService.add`, `CALCULATORSERVICE.ADD` | rejected BEFORE SOA despite case-insensitive mORMot router | `method_not_found` |
| Success shapes | scalar / object / `{"code":"forbidden"}` object | success verbatim; payload never re-discriminated | N/A |
| Deliberate domain failure | service raises `EPWebServiceError(msg, dataJson)` | `service_error`, `data` = the service-authored JSON | only sanctioned channel |
| Unexpected exception | service raises any other exception | `internal_error`, `data:null`, frozen default message | no class/path/detail leak |
| Cancelled pre-dispatch | token cancelled before bridge entry | `cancelled`; service never executes | N/A |
| Concurrency | N parallel `Add`/`SlowAdd` | all correct, concurrent `Uri()` proven thread-safe | N/A |
| `pweb.echo` / `pweb.handshake` | any principal | echo args verbatim / frozen `{protocol,runtime,capabilities}` | unknown `pweb.*` → `method_not_found` |
| pweb shadowing | app registers service surfacing as `pweb` | refused at bridge construction (startup) | Pascal exception at call site |
| Server lifetime | shutdown while `SlowAdd` in flight | drain completes before server destruction; no use-after-free | late result dies at CAP-2 gate |

</frozen-after-approval>

## Code Map

**PWeb (read first — frozen or load-bearing):**
- `src/rpc/pweb.rpc.intf.pas` — FROZEN. `IInvocationBridge`:333 (sync worker call, discriminated result, no mORMot types), `ICancellationToken`:258, error tables :465-499, `PWEB_JSON_NULL`:77, `PWEB_METHOD_HANDSHAKE`/`ECHO`:70-71, `PWEB_PROTOCOL_VERSION`:52.
- `src/rpc/pweb.rpc.support.pas` — helpers to REUSE: `PWebSuccessResult`/`PWebErrorResult`/`PWebDefaultErrorResult`:83-86, `PWEB_DEFAULT_ERROR_MESSAGE`:42. EXTEND (additive only): `EPWebServiceError` (Message + `DataJson: TPWebJson`) and `PWEB_RUNTIME_VERSION = '0.1.0'`.
- `src/rpc/pweb.rpc.scheduler.pas` — DO NOT MODIFY. Policy call site `ExecuteItem`:673-720 (policy→bridge, canonical method, exception⇒internal_error); `Shutdown`:722 (drain guarantee the server lifetime rests on).
- `src/rpc/pweb.rpc.bridge.dummy.pas` — CAP-2 dummy, untouched; pattern for bridge-side token observation and invoke recording.
- `src/security/pweb.capabilities.pas` — allow-all policy, reused as-is.
- `test/rpc/pweb.test.scheduler.pas` — exports shared fixtures (`TTestCompletion`, `TestContext`, `TPWebSchedulerFixture`); mirror this sharding pattern. `test/core/pwebtests.pas` — runner to extend.
- `examples/02-js-binding/jsbinding.pas` — template for example 03: page → `__pweb_invoke`, `TReportingBridge` decorator for machine verdict + exit code, `PWEB_SMOKE_AUTOCLOSE_MS`, teardown order binding.Close → scheduler.Shutdown → webview_destroy.
- `.github/workflows/ci.yml` — keep every step verbatim; test-suite compile :186-198 gets the extra mORMot unit dirs; example steps :268-304 are the model for example 03.
- `_bmad-output/specs/spec-pweb/conventions.md` — frozen name `src/rpc/pweb.rpc.mormot.pas`; example dir `examples/03-mormot-rpc/`.

**Pinned mORMot (deps/mormot2 @ b1a129b, verified by reading — probe confirms at runtime):**
- `mormot.rest.core.pas` — `TRestUriParams`:1196 (Url/Method/InHead/InBody/OutHead/OutBody/OutStatus/RestAccessRights), `Init`:3801; `TRestUriContext.Error`:4307 wraps non-2xx into `{"errorCode":N,"errorText":"..."}`.
- `mormot.rest.server.pas` — `Uri`:7896 (503 when shutdown; router lookup fail → 400 `Invalid URI`; `RestAccessRights^` DEREFERENCED :7993 — must set `@SUPERVISOR_ACCESS_RIGHTS`, `mormot.orm.core.pas`:4937); `HandleUriError`:7886 (`EInterfaceFactory`→406, else 500 with `ObjectToJsonDebug` CLASS-NAME LEAK; `OnErrorUri` hook may take over by returning false); router case-insensitive `rtoCaseInsensitiveUri`:6178; routes `root/Interface.Method` AND `root/Interface/Method`:4746-4748; success wrapper `ServiceResultStart/End`:3377-3409 → `{"result":[...]}`, no `,"id"` for sicShared; `Authenticate`:2983 short-circuits true when auth not handled; `TRestServerFullMemory.CreateWithOwnModel`:1991.
- `mormot.soa.server.pas` — `ExecuteMethod`:1365: binding failure → 406 (:1539) with detail text (REDACT); service exception propagates uncaught to `Uri`'s handler (⇒ `OnErrorUri` fires on the calling worker thread — the deliberate-error channel); `TServiceCustomAnswer` → verbatim body + custom status (:1546-1556).
- `mormot.soa.core.pas` — `TServiceContainerInterfaceMethod`:672 (`InterfaceDotMethodName` exact spelling, `InterfaceService`, indexes 0..3 = pseudo-methods `SERVICE_PSEUDO_METHOD_COUNT`) — the exact-case catalog source.
- `mormot.core.interfaces.pas` — `ExecuteJson`:7699: accepts `[...]` and `{...}`; named matching CASE-INSENSITIVE (`IdemPropName`:7635); body `'null'` ⇒ absent input (:7713); `optErrorOnMissingParam`:2231 errors on unknown names/absent input; missing individual params silently default; method flags expose `imfResultIsServiceCustomAnswer`; `TInterfaceMethod.Args` names for multi-output mapping.
- Toolchain: x64 FPC = `C:\dev\IDE\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe` (PATH `fpc` is i386!); statics `deps/mormot2/static/x86_64-win64`; extra unit dirs needed: `rest`, `orm`, `soa`, `db`, plus existing `core/lib/crypt/net`.

## mORMot Probe — pinned `b1a129b09197b6b9fb67c6d4d2a13445987a3fe1`

Executed locally on 2026-08-10 with FPC 3.2.2 x86_64 against an isolated `TRestServerFullMemory`, a normally registered `ICalculatorService`, `TRestUriParams`, `@SUPERVISOR_ACCESS_RIGHTS`, and a uniquely owned `InBody`. No HTTP/network unit, client, server, or listener was used.

| Probe | Observed pinned result |
| --- | --- |
| `Add` named / reordered args | `200`, `{"result":[42]}` |
| lower-case argument names | accepted case-insensitively, `200`, `{"result":[42]}` (normal mORMot result wrapper) |
| no-arg function with `null` | `200`, `{"result":[7]}` |
| `Add` with `null` | `406`, leaking mORMot binding text |
| missing `B`, even with `optErrorOnMissingParam` | service executed with default `B=0`; `200`, `20` |
| unknown extra name | `406`, leaking mORMot binding text |
| string supplied for integer | service executed with coerced/default `A=0`; `200`, `22` |
| trailing-comma object | accepted and service executed; `200`, `42` |
| unknown service / method | `400`, `Invalid URI` envelope |
| wrong service / method case | accepted and service executed; `200`, `42` |
| `TServiceCustomAnswer` status 422 | body passed verbatim as the explicit domain-error channel |
| implementation raises `Exception` | process terminates with Windows exception `0xE0434353`; no `Uri()` result |

The exception outcome is a pinned FPC/Win64 ABI blocker. `TInterfaceMethodExecuteRaw.RawExecute` has a Pascal `try/except` (`deps/mormot2/src/core/mormot.core.interfaces.pas:7447-7504`), but invokes the implementation through the custom Win64 `CallMethod` assembler/`nostackframe` trampoline (`:7123-7197`). That frame has no Win64 unwind metadata, so a service exception cannot reach `RawExecute`, `TRestServer.Uri()`'s handler, or `OnErrorUri`. The probe also repeated with `optIgnoreException` plus an execution interceptor; the process still terminated before the interceptor. This is the same FPC/Win64 `CallMethod` limitation documented by mORMot upstream. A custom native unwind trampoline, patched dependency, different compiler/target, or mandatory per-service catch wrapper would be an architectural/toolchain change and is not authorized by CAP-3.

Therefore production implementation is blocked before bridge code: the frozen contract requires unexpected service exceptions to return redacted `internal_error`, but the pinned required path can currently terminate the process. `TServiceCustomAnswer` safely covers deliberate `service_error`; it does not solve unexpected exceptions.

## Tasks & Acceptance

**Execution:**
- [x] Probe (ignored scratchpad): drove a real registered service through `TRestServer.Uri()` and recorded exact pinned behavior above. The probe disproved the planned `OnErrorUri` exception channel on FPC Win64.
- [x] **BLOCKER RESOLVED BY CAP-3U — production bridge work still requires explicit user resumption:** provide a supported, preservation-tested way for exceptions raised by arbitrary interface-service implementations to cross the pinned FPC Win64 `CallMethod` trampoline and be mapped to `internal_error`, without changing a frozen PWeb signature or weakening the required error contract.
- [ ] `src/rpc/pweb.rpc.support.pas` — additive `PWEB_RUNTIME_VERSION` only. Deliberate domain errors use pinned `TServiceCustomAnswer` status 422 with validated JSON; do not invent `EPWebServiceError` or overwrite `OnErrorUri`.
- [ ] `src/rpc/pweb.rpc.mormot.pas` — after the blocker is resolved, implement `TMormotInvocationBridge` with unambiguous transferred server ownership, immutable exact-case service/method and parameter metadata, strict JSON/key validation before `Uri()`, runtime-owned `pweb.*`, `UniqueRawUtf8`, response unwrapping, frozen error helpers, and no transport/UI dependency. `TServiceCustomAnswer` 422 is the sole explicit `service_error` channel. Raised implementation exceptions must become redacted `internal_error`; a process-terminating path is forbidden.
- [ ] `test/rpc/pweb.test.mormot.bridge.pas` — after resolution, cover scalar/object/multi-output success, strict named argument validation before execution, handshake, explicit custom-answer service errors, and an actually raising implementation method that returns redacted `internal_error` without terminating the process.
- [ ] `test/rpc/pweb.test.mormot.routing.pas` — tests 5-10, 19: unknown service/method; three case-variant rejections proven BEFORE SOA (impl invoke counter untouched); exact-case accepted; byte-identical canonical method observed by a recording decorator; `pweb`-shadow registration refused; raw-URI/slash grammar never reaches the bridge (scheduler gate regression).
- [ ] `test/rpc/pweb.test.mormot.integration.pas` — tests 15-18, 21-22 runtime side: full scheduler+allow-all+real bridge headless pipeline → `42`; cancelled-before-dispatch never executes service; ≥8 concurrent real `Uri()` calls (distinct worker threads ≠ main thread); `SlowAdd` in flight across `Shutdown` → drain completes, then bridge release frees server, no AV, late completion dies at gate.
- [ ] `test/core/pwebtests.pas` — add published `MormotBridge` proc registering the three new cases; every CAP-1/CAP-2 case untouched.
- [ ] `examples/03-mormot-rpc/mormotrpc.pas` — self-contained: own `ICalculatorService` (Add) + impl recording thread id, real bridge (+ example-local `TReportingBridge` for `example.report` verdict → exit code), page fires `CalculatorService.Add {"A":20,"B":22}` showing `42` + several concurrent calls; after loop: thread-id ≠ GUI check and in-process zero-listener check (`GetExtendedTcpTable` v4+v6 filtered on own PID, documented) both affect exit code; teardown binding.Close → Shutdown → destroy → bridge release. Example 02 untouched.
- [ ] `.github/workflows/ci.yml` — add: webview-free bridge compile (no `-Fusrc/webview`/`-Fusrc/lib`, mORMot dirs only); extend pwebtests compile with rest/orm/soa/db dirs (suite gating incl. new cases); zero-network sweep (grep PWeb-owned `src/ test/ examples/` for `TRestHttpServer|TRestClientHttp|THttpServer|mormot\.rest\.http|mormot\.net\.(server|client|http)` in uses/idents — deps/ excluded); example 03 compile gating + best-effort non-gating run. Every existing step byte-preserved.
- [ ] Adversarial review over the mandated attack list (case bypass, raw URI injection, param normalization, malformed JSON reaching execution, raw wrapper/exception escape, policy bypass/duplication, payload-shape misdiscrimination, GUI-thread execution, server freed under worker, double completion, accidental HTTP, pweb collision, hidden WebView dep); update this artifact (probe record + Suggested Review Order); final report MORMOT PROBE / IMPLEMENTATION / ROUTING / RESULT+ERROR MAPPING / TESTS / RUNTIME SMOKE / ZERO-NETWORK / CI / FREEZE CHECK / KNOWN LIMITATIONS ending exactly `CAP-3 PASS` or `CAP-3 NOT READY`; then STOP — no push, no merge, no Phase 4.

**Acceptance Criteria:**
- Given the branch, when `git diff main -- src/rpc/pweb.rpc.intf.pas src/webview/pweb.webview.intf.pas src/assets/pweb.assets.intf.pas src/lib src/rpc/pweb.rpc.scheduler.pas src/webview/pweb.webview.binding.pas` runs, then only allowed files changed (frozen units + CAP-2 scheduler/binding byte-identical).
- Given `pwebtests.exe /noenter`, then all CAP-1 + CAP-2 + the 22 mandated CAP-3 assertions pass headlessly with a real `TRestServer` and zero sockets.
- Given `pweb.rpc.mormot.pas` compiled with no `src/webview`/`src/lib` unit path, then it compiles — bridge is transport-neutral.
- Given the example on Windows x64, when the page runs, then `42` renders, the verdict travels back through the pipeline, service thread ≠ GUI thread, and the process owns no listening TCP socket during execution.
- Given CI, then all prior gates are intact and the new bridge/tests/sweep/example-compile gates are green and gating.

## Spec Change Log

- 2026-08-10 — The real pinned FPC Win64 probe contradicted the draft's assumed `OnErrorUri` exception path. Recorded exact routing/binding/result behavior, replaced the invented exception-based domain channel with public `TServiceCustomAnswer`, and blocked implementation because arbitrary service exceptions terminate across mORMot's unwind-less `CallMethod` frame instead of reaching `TRestServer.Uri()` error mapping. KEEP: exact-case catalog, strict pre-dispatch validation, zero-network route, scheduler policy order, discriminated result mapping, and shutdown ownership requirements.
- 2026-08-11 — CAP-3U review hardening preserved the passing Currency/unwind ABI logic while closing verification gaps: explicit patched-vs-pristine compile modes, upper-32-bit pointer and positional stack/register fingerprints, stack-argument exception unwinds, measured concurrent service overlap, exact internal-link object provenance plus `.xdata`/`SET_FPREG` checks, interrupted-transaction restore recovery, target assertions/idempotency/diagnostic retention in CI, and upstream source/license attribution. KEEP: the pristine Currency differential, exact final-PE coverage, 1000-unwind/concurrency stress, transactional locked-pin restore, unchanged CAP-1/CAP-2 baseline, and prohibition on resuming CAP-3 without explicit user direction.

## Design Notes

- **Deliberate service_error channel:** pinned `TServiceCustomAnswer` safely returns status 422 plus an application-authored body without raising through the broken trampoline. The bridge must validate that body as JSON, use the frozen default service-error message, and place the body only in `service_error.data`; invalid JSON becomes redacted `internal_error`.
- **Unexpected exception blocker:** `OnErrorUri`, `optIgnoreException`, and execution interceptors are downstream of the unwind failure and cannot recover it. No arbitrary exception-message parsing or custom SEH swallowing is acceptable. Any future resolution needs an explicit toolchain/dependency decision and a deterministic raising-service regression on Windows x64.
- **Result translation:** default routing wrapper `{"result":[...]}` is unwrapped by the bridge (owner of translation): single output → naked value (the `42` gate); multiple outputs → JSON object keyed by mORMot RTTI parameter names (named outputs mirror the named-args wire philosophy — nothing invented). mORMot's case-insensitive input-name matching is pinned behavior, recorded, not tightened.
- **Ownership:** bridge owns the `TRestServer` (when `aOwnsServer`), freed in `Destroy`; the owner releases its bridge reference only after `Shutdown` returns — combined with the scheduler's drain guarantee this makes `Uri()`-after-free impossible. Registration happens before bridge construction; the catalog is an immutable snapshot (later ServiceDefine unsupported, documented).
- Naming: task text suggested `pweb.rpc.bridge.mormot.pas`; frozen `conventions.md` explicitly names `pweb.rpc.mormot.pas` — conventions win ("repository-conventional naming" is sanctioned). Class name `TMormotInvocationBridge` (transport-neutral; phase-plan's old `TWebViewInvocationBridge` sketch is superseded by the CAP-3 mandate).

## Verification

**Commands:**
- `& 'C:\dev\IDE\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe' -Sh -B -FUbuild\fpc-cap3 -Fusrc\rpc -Fusrc\security -Fideps\mormot2\src -Fudeps\mormot2\src\core -Fudeps\mormot2\src\lib -Fudeps\mormot2\src\crypt -Fudeps\mormot2\src\net -Fudeps\mormot2\src\db -Fudeps\mormot2\src\orm -Fudeps\mormot2\src\rest -Fudeps\mormot2\src\soa -Fldeps\mormot2\static\x86_64-win64 src\rpc\pweb.rpc.mormot.pas` — compiles with NO src/webview, NO src/lib path after the blocker is resolved.
- pwebtests compile (extended paths) + `build\test\pwebtests.exe /noenter` — exit 0.
- Zero-network sweep grep over `src/ test/ examples/` — no forbidden identifier outside deps/.
- `git diff --exit-code main -- src/rpc/pweb.rpc.intf.pas src/webview/pweb.webview.intf.pas src/assets/pweb.assets.intf.pas src/lib` — empty.
- Example 03 built and run locally — `42` visible, verdict + thread + zero-listener checks drive exit code (authoritative local gate; CI best-effort).

## CAP-3U — FPC Win64 `CallMethod` Unwind Correction

CAP-3U is a dependency/toolchain preservation gate only. It does not authorize the production `IInvocationBridge`, Calculator example, strict method catalog, result unwrapping, or PWeb error mapping. All remaining CAP-3 tasks above stay deferred until CAP-3U reaches `CAP-3U PASS — CAP-3 UNBLOCKED` and the user explicitly resumes CAP-3.

### Corrective evidence supplied after the original blocker

- Pinned dependency remains `b1a129b09197b6b9fb67c6d4d2a13445987a3fe1`; compiler remains FPC 3.2.2 Win64.
- Original `CallMethod` was observed at VA `0x10002F560`, RVA `0x2F560`, range `0x2F560..0x2F5F0`. The PE exception directory existed, but no `RUNTIME_FUNCTION` entry covered that range (`.pdata` jumped from the preceding `0x2F510..0x2F555` function to `0x2F600`). The exception-code spelling is diagnostic-only, not a contract.
- `tools/cap3u/x64callmethod.asm` is a MASM replacement using `PROC FRAME`, `.pushreg`, `.setframe`, and `.endprolog`, with RBP established before dynamic RSP movement. Audit against `TCallMethodArgs` and the pinned implementation found normal-call equivalence: record offsets `00h/08h/10h/18h/38h/58h/60h`, 256-byte `MAX_EXECSTACK`, reversed qword stack copy, RCX/RDX/R8/R9 and XMM0..3 restoration, 32-byte shadow space, RAX result, the then-audited XMM0 result handling for result kinds 8/9/10, and R12 preservation. **Superseded for Currency by the focused continuation:** the pristine differential demonstrated that FPC 3.2.2 Win64 returns `imvCurrency` in RAX, so the final replacement copies XMM0 only for `imvDouble`/`imvDateTime`.
- The experimental final map proved `x64callmethod` at VA `0x100051770`, size `0x92`, with contributed `.xdata` at `0x1001F7050` size `0x0c` and `.pdata` at `0x100217274` size `0x0c`. `dumpbin /unwindinfo` showed a `RUNTIME_FUNCTION` RVA range `0x51770..0x51802`, frame register RBP, and unwind codes for RBP/R12.
- Experimental runtime preserved Add (`200`, `{"result":[42]}`) and `TServiceCustomAnswer` (`422`, `{"domainCode":"probe"}`); a raised `Exception` crossed the replacement trampoline, reached the mORMot interceptor once, and did not terminate the process. The probe's `200/result=[]` exception response is not PWeb semantics and is not accepted as the final CAP-3 behavior.

### CAP-3U code map

- `tools/cap3u/x64callmethod.asm` — committed MASM source of truth; generated OBJ remains ignored.
- `tools/patch-cap3u.ps1` — exact-pin preparation and idempotent restore; must recognize only pristine-pinned or exact-CAP-3U-patched dependency states and operate transactionally.
- `test/cap3u/cap3u_unwind.pas` — dedicated, network-free `TRestServer.Uri()` regression executable; deliberately separate from unchanged `pwebtests` so CAP-1/CAP-2 remain an independent baseline.
- `test/cap3u/check_unwind.ps1` — OBJ/final-PE symbol, section, map, and `RUNTIME_FUNCTION` coverage gate.
- `.github/workflows/ci.yml` — CAP-3U preparation/build/binary/runtime gate before any compilation can create or reuse `mormot.core.interfaces.ppu`; existing baseline steps remain unchanged after verified restore.

### CAP-3U execution tasks

- [x] `tools/patch-cap3u.ps1` — derive the full pin from `mormot.lock`; require Windows x64; reject any dependency state except pinned source plus the known `static/` release-asset differences or the exact generated CAP-3U state; assemble and validate a temporary COFF x64 OBJ before mutating source; recognize the exact conditional patch rather than marker substrings; atomically install source/OBJ and roll back on failure. Accept explicit `-Ml64Path`, then resolve MSVC `ml64.exe` from PATH/Visual Studio; never vendor it. `-Restore` is idempotent, restores the target from the locked commit, removes OBJ/temporary backup/dedicated PPUs, verifies the dependency state, and never trusts stale backup content.
- [x] `tools/cap3u/x64callmethod.asm` — retain audited ABI behavior and unwind directives. Keep hard-coded layout/enum/MAX_EXECSTACK assumptions guarded by the exact mORMot pin and source-shape validation. The define must be Windows-x64-only; POSIX x64 must never select the COFF object.
- [x] `test/cap3u/cap3u_unwind.pas` — register one genuine interface service on `TRestServerFullMemory` and drive every call via thread-local `TRestUriParams`/`Uri()` with `UniqueRawUtf8` after final body assignment. Emit twelve deterministic case verdicts and a final `CAP3U: 12/12 PASS`; any mismatch exits nonzero. Cover: Add 42; signed/unsigned/pointer-sized integer returns supported by RTTI; XMM floating arguments; Double/TDateTime/Currency return kinds; ten integer stack arguments; mixed integer/floating register+stack arguments; no-argument call with JSON null; exact status-422 custom answer; ordinary `Exception` reaching `smsError` and `OnErrorUri` without process death; service/Uri/caller finally markers; exactly 1000 sequential raise/unwind/handler cycles; and four or more independent threads mixing success and raise calls with exact aggregate counters and zero worker failures. A known success after exception/stress proves continued process integrity.
- [x] `test/cap3u/check_unwind.ps1` — before launching the raising executable, validate OBJ machine x64, public `x64callmethod`, non-empty `.pdata`/`.xdata`, and the final link map's `READOBJECT`, code contribution, and retained `.pdata`/`.xdata`. Parse `dumpbin /unwindinfo` (or equivalent pinned MSVC output) and require an exact final-PE `RUNTIME_FUNCTION` begin/end match for the mapped `x64callmethod` range, nonzero unwind info, frame register RBP, and saved RBP/R12 codes. Merely finding a PE exception directory or adjacent broad entry is insufficient.
- [x] `.github/workflows/ci.yml` — immediately after pinned mORMot fetch, FPC assertion, and the pinned MSVC environment step: assert no stale `mormot.core.interfaces.ppu`; run preparation; compile with direct FPC's authoritative internal-link path, explicit repository `deps/mormot2` paths, clean dedicated `-FUbuild/cap3u/fpc`, `-B`, `-Xm`, and `-dPWEB_CALLMETHOD_UNWIND_PROBE`; assert map/unit provenance contains no global Lazarus mORMot package; run binary gate before the raising suite; run all twelve cases; restore in `finally`; verify pristine dependency source; then run every existing CAP-1/CAP-2 step unchanged and without the CAP-3U define. Add the required explanatory FPC 3.2.2 Win64 comment.
- [x] Freeze and documentation — diff Phase-0/1/2 paths against `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`; append actual ABI, exception, stress, concurrency, binary, CI, and freeze results here without erasing the original failure; report exactly one CAP-3U verdict and stop.

### CAP-3U acceptance

- All twelve runtime cases pass on FPC 3.2.2 Win64 against the repository-pinned mORMot checkout, including exactly 1000 sequential exception cycles and deterministic concurrent success/exception counts.
- The raising test proves process survival, `smsError` interception, `OnErrorUri`, service cleanup, mORMot outer cleanup, and caller `finally`; no swallowing convention is imposed on application services.
- The final executable, not just the OBJ, has exact `RUNTIME_FUNCTION` coverage over `x64callmethod` and retains the replacement object's `.pdata`/`.xdata`.
- Direct build provenance proves the tested `mormot.core.interfaces` came from `deps/mormot2`, not a globally installed Lazarus package, and a stale PPU cannot mask the patch or define.
- Existing CAP-1/CAP-2 suite passes after restore; Phase-0/1/2 frozen paths are byte-identical to their baselines; no mORMot pin, frozen public interface, PWeb semantic, HTTP/network path, or CAP-3 production source changes.

### CAP-3U known limitation to preserve

The replacement is deliberately specific to the pinned FPC Win64 `CallMethod` ABI and does not repair other private assembly paths such as mORMot's separate `x64FakeStub`. CAP-3U proves the real interface-service `TRestServer.Uri()` path only. Any pin/compiler/target change requires revalidation rather than assuming these private offsets and enum ordinals remain stable.

### CAP-3U execution result — 2026-08-11

- Preparation and restore were exercised against the full `mormot.lock` pin. The preparation script accepted only the pristine pinned source or its exact generated CAP-3U state, validated an x64 COFF object with public `x64callmethod` plus non-empty `.text$mn`, `.pdata`, and `.xdata`, was idempotent on a repeated preparation, and restored the pinned source while removing generated object, temporary, backup, and dedicated PPU artifacts.
- A direct FPC 3.2.2 Win64 build with `-B`, `-Xm`, `-dPWEB_CALLMETHOD_UNWIND_PROBE`, explicit repository mORMot unit paths, and a clean dedicated unit directory produced the required internal-linker map evidence: `READOBJECT .\\deps\\mormot2\\src\\core\\x64callmethod.obj`, a `0x92`-byte code contribution, and retained `0x0c`-byte `.pdata` and `.xdata` contributions. The final PE contained an exact `RUNTIME_FUNCTION` range for `x64callmethod` and unwind metadata declaring an RBP frame with saved RBP and R12.
- Runtime cases for Add, signed/unsigned/pointer-sized integer returns, XMM arguments, Double and TDateTime returns, ten stack arguments, mixed register/stack arguments, JSON-null no-argument dispatch, exact 422 custom answer, exception propagation through `smsError` and `OnErrorUri`, all service/URI/caller finally markers, exactly 1000 sequential exception cycles, four concurrent worker threads with exact aggregate counts, and post-stress success passed. The mandatory matrix result was `CAP3U: 11/12 FAIL` solely because Currency returned `{"result":[0]}` instead of `{"result":[1234.5678]}`.
- **Historical diagnosis, superseded by the focused continuation:** disassembly identified a pinned ABI contradiction rather than a JSON expectation or harness defect. FPC generated `TCap3UProbe.CurrencyResult` by loading the scaled Currency integer into RAX; its interface wrapper only adjusted `Self` and tail-jumped, without copying RAX to XMM0. At that point both the original pinned `CallMethod` and the unwind-only replacement copied XMM0 over the valid RAX result for result kind 10. The later authorized differential established the correct pinned convention and changed only the replacement's Currency handling.
- An external-linker `-Xe` diagnostic build passed the binary checker but failed before program entry with Windows status `0xC0000139`: pinned `mormot.lib.sspi.pas` imports `MsiEnumProductA`, while the system MSI API exports `MsiEnumProductsA`. This unrelated retained import is absent with the internal linker, so no tracked `-Xe` CI change was made.
- No knowingly failing CI gate was added, no Currency assertion was weakened or removed, and the MASM source was not changed from the supplied resKind 8/9/10 behavior. The dependency was restored after testing. The Phase-0/1/2 freeze check against `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5` passed.
- The unchanged CAP-1/CAP-2 suite was not rebuilt after this ABI blocker met the explicit stop condition. Its most recent verified pre-CAP-3U baseline remains 595 assertions with zero failures; the current frozen-file diff is empty.

CAP-3U STILL BLOCKED

### CAP-3U focused continuation — demonstrated FPC Win64 Currency ABI

The 11/12 result above is retained as historical evidence. The user has explicitly distinguished the successful unwind correction from the newly exposed pinned mORMot/FPC Win64 Currency defect and authorized this focused continuation only; CAP-3 production remains prohibited.

- First run the nonzero Currency service test through pristine pinned `CallMethod`, without `PWEB_CALLMETHOD_UNWIND_PROBE`, and record the result. Then run the unchanged unwind-only trampoline and record the same call. If pristine does not reproduce the zero result, stop with `CAP-3U STILL BLOCKED`.
- If both paths reproduce the same zero result, correct only `tools/cap3u/x64callmethod.asm` for the demonstrated FPC 3.2.2 Win64 ABI: retain the RAX-derived `res64` value for `imvCurrency`; copy XMM0 only for `imvDouble` and `imvDateTime`. Do not manually edit canonical pinned mORMot source outside the generated conditional patch mechanism.
- Rerun the full twelve-case `TRestServer.Uri()` matrix and require `Currency = 1234.5678` plus 12/12. Rerun the exact final-PE unwind gate before raising tests, single exception/interceptor/error/finally checks, exactly 1000 sequential unwinds, concurrent mixed success/raise stress, and post-stress Add.
- Transactionally restore the pinned dependency, prove the source pristine and generated OBJ absent, rebuild/run the unchanged CAP-1/CAP-2 suite without the define, and repeat the frozen Phase-0/1/2 diff against `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`.
- Only after all local gates are green, add an early Windows CI CAP-3U step using FPC's authoritative internal-link path: prepare before any mORMot PPU, compile with `-B -Xm -dPWEB_CALLMETHOD_UNWIND_PROBE`, run the binary gate before the runtime matrix, always restore in `finally`, then run every existing baseline step without the define. The unrelated diagnostic `-Xe` import failure is not a requirement.
- Final documentation must explicitly separate: (A) missing original Win64 unwind metadata; (B) the pre-existing Currency RAX result overwritten from XMM0; and (C) the final FPC Win64 trampoline with unwind metadata plus the demonstrated Currency return convention. End with exactly one current CAP-3U verdict and stop without resuming CAP-3.

### CAP-3U focused continuation result — 2026-08-11

- **A — missing original unwind metadata:** the pristine pinned FPC 3.2.2 Win64 run still terminated at the first ordinary service exception with process exit `-532262845`, after its earlier cases completed. The replacement's unwind behavior remained independently proven by the exception handler/finally case, exactly 1000 sequential raises, four concurrent mixed success/raise workers, and the post-stress Add.
- **B — pre-existing Currency result defect:** the required nonzero `CurrencyResult` call returned status 200 with `{"result":[0]}` through pristine pinned `CallMethod`. The unchanged unwind-only replacement returned the identical zero and completed the matrix at 11/12, authorizing the focused correction. FPC 3.2.2 Win64 returns Currency's scaled integer in RAX; treating result kind 10 like Double/TDateTime overwrote that valid value from XMM0.
- **C — final pinned trampoline:** `tools/cap3u/x64callmethod.asm` now retains the captured RAX value for `imvCurrency` and copies XMM0 only for `imvDouble` and `imvDateTime`, while preserving the audited frame, argument, stack, register, and unwind behavior. The full real `TRestServer.Uri()` matrix produced `CAP3U: 12/12 PASS`, including `Currency = 1234.5678`, interceptor/`OnErrorUri`/service-URI-caller finally evidence, 1000/1000 sequential unwinds, exact concurrent counters, zero worker failures, and successful post-stress Add.
- The final internal-link PE gate passed before the raising executable ran: the map recorded `READOBJECT`, a non-empty `0x8f` replacement code contribution, retained `.pdata`/`.xdata`, and an exact `RUNTIME_FUNCTION` range `0005BAB0..0005BB3F` with nonzero unwind info, RBP frame, and saved RBP/R12.
- Preparation was transactionally restored after the runtime gate. The dependency source matches `b1a129b09197b6b9fb67c6d4d2a13445987a3fe1`, the generated OBJ is absent, and no non-static dependency changes remain. The unchanged CAP-1/CAP-2 suite was rebuilt from fresh PPUs without `PWEB_CALLMETHOD_UNWIND_PROBE` and passed 595/595 assertions. The Phase-0/1/2 freeze diff against `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5` is empty.
- CI now runs CAP-3U immediately after the FPC assertion and pinned MSVC environment: it rejects stale PPUs, prepares the exact-pin patch, compiles with FPC's internal linker and repository-only mORMot provenance, executes the final-PE binary gate before the twelve runtime cases, and always restores in `finally`. All pre-existing CAP-1/CAP-2 steps remain byte-identical and follow without the define. YAML and embedded PowerShell parsing passed locally; the CI-hosted run remains pending until the workflow executes remotely.

### CAP-3U consolidated review hardening result — 2026-08-11

- The compile guard rejected an unqualified CAP-3U build. `CAP3U_PRISTINE_DIFFERENTIAL` was the sole intentional override: against pristine pinned `CallMethod`, the upper-32-bit pointer and noncommutative integer/mixed positional cases passed, Currency again returned status 200 with `{"result":[0]}`, and the process terminated with `-532262845` on the first ten-argument `RaiseOrdinary` call. The production regression build required `PWEB_CALLMETHOD_UNWIND_PROBE`; defining both modes is a compile-time error.
- The strengthened final-PE gate passed on the authoritative internal-link path only. It matched exactly one normalized `READOBJECT` for the supplied repository OBJ, retained non-empty `.pdata`/`.xdata`, found the exact `RUNTIME_FUNCTION` range `0005C090..0005C11F`, proved its unwind-info RVA lies inside the OBJ's mapped `.xdata`, and required the RBP frame, `SET_FPREG`, and saved RBP/R12 codes. External-linker `LOAD` provenance is no longer accepted.
- The strengthened real `TRestServer.Uri()` matrix produced `CAP3U: 12/12 PASS`. It covered the full decimal `PtrUInt` value `1311768467463790320`, noncommutative register/stack fingerprints, exception propagation through a ten-argument method with its fingerprint validated before every raise, exactly 1000 sequential unwind/handler/finally cycles, exact concurrent counts of 100 successes and 100 raises, and post-stress Add. The atomic barrier/active counter recorded `ready=4 peak=4 active=0`, proving actual in-service overlap.
- Preparation succeeded twice with identical generated state. Restore recovered a deliberately simulated interrupted state with the target missing plus recognized transaction/OBJ artifacts, then a second restore succeeded from pristine. The final patched restore and second pristine restore also passed; canonical source matches locked `HEAD`, the generated OBJ and transaction files are absent, and no unrelated non-static dependency change remains.
- The unchanged CAP-1/CAP-2 suite was rebuilt from fresh PPUs without the CAP-3U define and passed 595/595 assertions. The Phase-0/1/2 freeze diff against `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5` is empty.
- CI now asserts FPC target `win64/x86_64` before mutation, prepares twice, gates binary evidence before runtime, persists compile/binary/runtime/map diagnostics, restores twice in `finally`, and verifies the lock against dependency `HEAD` without duplicating the pin. Existing CAP-1/CAP-2 commands remain after restore and without the define. YAML, embedded CI PowerShell, patch script, and binary-checker parsing passed locally; the hosted CI run remains pending.
- `tools/cap3u/x64callmethod.asm` now credits its mORMot `CallMethod` source and the MPL 1.1/GPL 2.0/LGPL 2.1 tri-license exactly as established by `deps/mormot2/LICENCE.md`; the passing ABI instructions are unchanged by this attribution.

CAP-3U PASS — CAP-3 UNBLOCKED

## Suggested Review Order

**Corrected trampoline**

- Start with the unwind-aware frame and preserved Win64 service-call ABI.
  [`x64callmethod.asm:14`](../../tools/cap3u/x64callmethod.asm#L14)

- Review the intentional Currency exception to mORMot's broken XMM0 assumption.
  [`x64callmethod.asm:74`](../../tools/cap3u/x64callmethod.asm#L74)

**Transactional preparation**

- Verify the exact pinned-source conditional generated around the original implementation.
  [`patch-cap3u.ps1:113`](../../tools/patch-cap3u.ps1#L113)

- Check interrupted-state recovery before canonical source restoration.
  [`patch-cap3u.ps1:200`](../../tools/patch-cap3u.ps1#L200)

- Confirm generated COFF validation precedes dependency mutation.
  [`patch-cap3u.ps1:258`](../../tools/patch-cap3u.ps1#L258)

**Binary proof**

- Require exact internal-link object provenance instead of basename-only evidence.
  [`check_unwind.ps1:114`](../../test/cap3u/check_unwind.ps1#L114)

- Bind the exact runtime-function entry to mapped xdata and RBP unwind codes.
  [`check_unwind.ps1:189`](../../test/cap3u/check_unwind.ps1#L189)

**Runtime preservation matrix**

- Enforce mutually exclusive patched and intentional-pristine compilation modes.
  [`cap3u_unwind.pas:11`](../../test/cap3u/cap3u_unwind.pas#L11)

- Exercise stack-argument exceptions through the corrected trampoline.
  [`cap3u_unwind.pas:227`](../../test/cap3u/cap3u_unwind.pas#L227)

- Review twelve ABI, unwind, stress, overlap, and post-stress verdicts.
  [`cap3u_unwind.pas:388`](../../test/cap3u/cap3u_unwind.pas#L388)

**CI integration**

- Run preparation, binary proof, runtime matrix, and restore before baseline compilation.
  [`ci.yml:98`](../../.github/workflows/ci.yml#L98)

## CAP-3 implementation result — 2026-08-11

The closed CAP-3U invariant was consumed as a build prerequisite and was not reopened. All real interface-service builds below ran only after `tools/patch-cap3u.ps1`, with FPC 3.2.2 Win64, `-B -Xm`, fresh dedicated PPU directories, and `-dPWEB_CALLMETHOD_UNWIND_PROBE`. The dependency was restored afterward; its source matches `b1a129b09197b6b9fb67c6d4d2a13445987a3fe1` and generated `x64callmethod.obj` is absent.

### MORMOT BRIDGE

- Added `src/rpc/pweb.rpc.mormot.pas`. `TMormotInvocationBridge` depends on neutral RPC units and mORMot core/ORM/REST/SOA only; it has no raw WebView, binding, HTTP-client/server, or application-service dependency.
- Registration completes before bridge construction. Construction snapshots and sorts an immutable exact-case catalog, copies method routes/input names/value kinds, excludes mORMot pseudo-method indices, rejects an application `pweb` namespace collision, and transfers optional server ownership only after successful setup.
- Invocation performs no authorization. The existing scheduler remains the sole `ICapabilityPolicy.IsAllowed(Context, CanonicalMethod)` call site and invokes the bridge afterward on its worker.

### STRICT ROUTING

- Public spelling is exactly one-dot `Service.Method`. Exact catalog lookup rejects service/method case variants and unknown routes as `method_not_found` before `Uri()`.
- `pweb.echo` and `pweb.handshake` remain runtime-owned. Unknown `pweb.*` names never reach mORMot; registering an `Ipweb` service is refused at bridge construction.
- Catalog methods with input kinds that cannot yet be validated fully are excluded fail-closed instead of exposing mORMot coercion/default behavior.

### ARGUMENT VALIDATION

- Inputs are strict JSON named objects, or literal `null` only for zero-input methods. Parsing is case-sensitive and rejects malformed JSON, trailing commas, duplicate names, missing/extra names, and wrong-case names.
- Metadata checks boolean/string/date/numeric/raw-JSON/variant values before dispatch. Signed `Integer`, `Cardinal`, signed `Int64`, unsigned QWord, and Currency conversions are range checked. The Add regression rejects string numerics and `2147483648` before `Uri()`.
- Reordered exact named arguments are accepted. Runtime built-ins also reject non-object shapes and duplicate keys. `pweb.handshake` reports the immutable native context capability snapshot; JavaScript cannot inject those fields.

### RESULT NORMALIZATION

- Calls create `TRestUriParams` with POST, JSON content type, supervisor access rights, `llfInProcess`, and a unique mutable body, then call `TRestServer.Uri()` synchronously.
- The pinned `{"result":[...]}` wrapper is interpreted against output metadata. `CalculatorService.Add` returns naked JSON `42`; one-output JSON `null` remains literal `null`; zero outputs normalize to `null`; multiple outputs use mORMot's metadata names.
- Arbitrary transport-shaped mORMot responses are never returned as successful PWeb values.

### ERROR MAPPING

- Bad public grammar/argument shape maps to `invalid_request`; exact-case misses map to `method_not_found`; pre-dispatch cancellation maps to `cancelled`.
- A cataloged `TServiceCustomAnswer` method returning status 422 plus strict JSON maps to `service_error` with the explicit structured domain body in `data`.
- Any unexpected service exception, invalid status, invalid wrapper, or invalid domain body maps to the default redacted `internal_error`. Tests require the exact default message, `data = null`, no exception class, marker, path, or implementation text, and successful reuse of the same server/bridge after `Boom`.
- No human-readable mORMot error text is parsed to choose a normative PWeb code. No `unauthorized` code was added; `protocol_mismatch` remains the frozen code/status-426 mapping.

### THREADING

- The real service thread differs from the main/GUI thread, and eight scheduled `SlowAdd` calls prove overlapping real `Uri()` execution on the existing worker pool.
- Cancellation is checked at bridge entry and again immediately before `Uri()`. Once `Uri()` begins it is never aborted. Shutdown preserves CAP-2 semantics: the source completes as cancelled while the synchronous service finishes, workers drain, and only then may the bridge-owned server be destroyed.
- Tests observe owned and non-owned server destruction and prove exactly-once completion across the drain boundary.

### TESTS

- Dedicated WebView-free `cap3tests.exe`: 124/124 assertions, zero failures. Coverage includes Add 42, wrapper removal, exact case, reordered args, every required pre-URI rejection, integer range, null, runtime methods, structured domain failure, redacted exception/same-server survival, both cancellation checks, policy placement, worker identity, concurrency, drain, and ownership.
- Prepared combined `pwebtests.exe`: 719/719 assertions, zero failures — the unchanged 595 CAP-1/CAP-2 assertions plus 124 CAP-3 assertions.
- After transactional restore and without `PWEB_CALLMETHOD_UNWIND_PROBE`, the unchanged CAP-1/CAP-2 suite rebuilt from fresh Win64 PPUs and passed 595/595.

### RUNTIME SMOKE

- Added `examples/03-mormot-rpc`. Its page calls `window.__pweb_invoke('CalculatorService.Add',{a:20,b:22})` through the existing binding and scheduler, renders `42 — PASS`, and returns its automated verdict through the same scheduler using an example-local reporting decorator.
- The local Win64 run emitted `mormotrpc: CalculatorService.Add -> 42 on scheduler worker PASS`, then `mormotrpc: clean exit`, with exit code 0. Missing verdict, wrong value/thread, auto-close thread failure, teardown failure, or unhandled invocation failure produces a nonzero verdict.

### ZERO-NETWORK PROOF

- The production bridge directly invokes `TRestServer.Uri()` and creates no HTTP transport, REST client, socket, listener, localhost endpoint, or URL fetch.
- The fail-closed source sweep over every new CAP-3 production/test/example Pascal file found no forbidden network/server/client/loopback pattern. The bridge's standalone compile has no `src/webview` or `src/lib` path.

### CI

- The existing CAP-3U step still rejects stale mORMot interface PPUs, prepares twice, compiles the binary/runtime proof, checks final-PE unwind metadata, runs 12/12, and restores in `finally`.
- While that same prepared state is active, CI now deletes the dedicated CAP-3 build subtree, compiles the transport-neutral bridge, builds/runs the 124-assertion headless suite, compiles example 03, and runs the zero-network sweep. The later GUI run is best-effort with an explicit PASS marker; example compilation is gating.
- After restore, the unchanged CAP-1/CAP-2 baseline and existing ABI/freeze/smoke gates remain. CI YAML parsed locally; the hosted workflow run is pending remote execution.

### FREEZE CHECK

- `git diff --exit-code 4653ba77ef03f0a37b0b0c4205ed6ecfe7e0f5` is empty for the frozen Phase-0 interfaces, CAP-1 raw ABI layer, CAP-2 scheduler/dummy bridge/capability policy/WebView binding, and asset interface.
- No mORMot pin, FPC minimum, frozen public signature/error code, method grammar, named-only contract, policy placement, or capability trust rule changed.

### KNOWN LIMITATIONS

- The catalog is an immutable post-registration snapshot; later service registration is intentionally unsupported.
- Complex input kinds whose nested values cannot yet be validated exactly (enum, set, record, object, dynamic array, and interface/callback inputs) are excluded fail-closed from the public catalog. The CAP-3 reference scalar/RawJson surface is fully validated; adding a complex kind requires a metadata-complete validator and tests.
- Cancellation remains cooperative after synchronous `Uri()` begins. The hosted Windows CI execution and environments without a usable desktop/WebView2 runtime remain external validation conditions; local FPC 3.2.2 Win64 gates and the authoritative GUI smoke passed.

CAP-3 PASS
