---
title: 'PWeb Phase 5 / CAP-5 frontend SDKs — TypeScript and Pas2JS over one wire'
type: 'feature'
created: '2026-08-11'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'e335656a4aa3ad085321de1cc1c07007753dd61f'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-4-cap4-asset-system.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The proven CAP-2/3/4 pipeline is reachable only through handwritten `window.__pweb_invoke` calls in example pages; no typed frontend SDK exists, so React and Pas2JS applications cannot consume PWeb as a framework.

**Approach:** Two thin SDK adapters over the exact existing primitive — `sdk/typescript/` (`@pweb/runtime`: `invoke<T>`, `handshake()`, `PWebError`) and `sdk/pas2js/pweb.native.pas` (`TJSPromise`-based `Invoke`, `EPWebError`) — plus a real React example (04) and a real Pas2JS example (05), both loaded over `pweb://app` and both invoking `CalculatorService.Add {a:20,b:22}` → `42` through the one existing binding→scheduler→policy→bridge path, with deterministic JS-side test suites, a captured-wire parity proof, pinned toolchains, and minimal CI extension.

## Boundaries & Constraints

**Always:** `code` is the sole normative error discriminator; the nine frozen codes only (`status` informative). Method spelling and argument key casing pass through byte-exact — no normalization, no positional args, args = object or null. Success may be ANY JSON value; `42` and `null` are distinct successes; never truthiness-discriminate. `service_error.data` and `busy` metadata preserved; `internal_error` stays redacted; malformed/unrecognized rejection payloads map locally to `internal_error` without inventing detail. Absent primitive ⇒ immediate local reject `runtime_closed` (never a hung promise, never a fallback transport). `handshake()` = `pweb.handshake` through the same primitive; SDK supported-protocol set {1} cross-checked in CI against `PWEB_PROTOCOL_VERSION`; incompatibility ⇒ `protocol_mismatch`; handshake `capabilities` advisory only — no client-side allow/deny ever. SDK responsibility ends at `window.__pweb_invoke`. All pins (webview, mORMot, FPC 3.2.2, actions-by-SHA) and freeze diffs (`b2f04dc4c478c72b1699a954dd52e76b207e918b`, `709bf0fee715d0cf9b8c475b4f801947fc0f4a65`, `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`) preserved; every existing CI gate kept verbatim. Frontend deps pinned exactly (npm lockfiles committed; pas2js 3.0.1 fetched by checksum-verified script; no floating "latest").

**Ask First:** Any wire/protocol/error-code change; any edit to `src/**`, `test/**` Pascal, or existing examples; any new dependency beyond typescript, react, react-dom, esbuild, @types/react[-dom], pas2js 3.0.1; committing built bundles instead of building in CI; any weakening of a hosted gate.

**Never:** `fetch`/`XMLHttpRequest`/`WebSocket`/localhost/HTTP anywhere in either SDK, or as any RPC path; React dependency inside `@pweb/runtime`; invented `events.ts`/`window.ts` APIs with no backend support; a Pas2JS-specific native route or payload; SDK-side service-schema validation duplicating the backend; blocking emulation in Pas2JS; CAP-4b/6/6b/7/8/9/10 work.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Integer success | `invoke("CalculatorService.Add",{a:20,b:22})` | resolves `42` (both SDKs) | N/A |
| All JSON shapes | object/array/string/boolean/null successes | resolved values pass through unchanged; `null` ≠ error | N/A |
| Error-shaped success | success value `{"code":"forbidden"}` | resolves as success | never re-classified |
| service_error | rejection envelope with structured `data` | typed error: code/status/message/data preserved | no message-text parsing |
| internal_error | redacted envelope, `data:null` | typed error, nothing added | no native detail reconstructed |
| Malformed rejection | non-envelope/unknown-code rejection reason | local typed `internal_error`, generic message | promise always settles |
| Binding absent | plain browser, no `__pweb_invoke` | immediate typed `runtime_closed` reject | no fallback, no hang |
| Handshake | runtime protocol ∉ {1} | typed `protocol_mismatch`; app must not proceed | consistent in both SDKs |
| Wire capture | same logical call from TS and Pas2JS | method byte-identical; args JSON-equivalent; no frontend-kind/identity field | parity gate fails otherwise |
| Runtime gates | React and Pas2JS apps over `pweb://app` | both render, handshake ok, display/report 42, exit 0 | hosted PASS/SKIP/FAIL policy |

</frozen-after-approval>

## Code Map

- `src/webview/pweb.webview.binding.pas:248-252` — transport envelope is `["Method", ArgsObjectOrNull]`; `:351-387` result arms: status 0 ⇒ resolve any JSON value, nonzero ⇒ reject canonical envelope `{code,message,status,data}`. Upstream JS shim: `window.__pweb_invoke(method, argsOrNull)` returns a Promise; rejection reason is the parsed envelope object.
- `src/rpc/pweb.rpc.intf.pas:52-77` — `PWEB_PROTOCOL_VERSION=1`, `PWEB_METHOD_HANDSHAKE='pweb.handshake'`; `:473-499` frozen code/status tables (SDK constants mirror these; CI cross-checks).
- `src/rpc/pweb.rpc.mormot.pas:469-477` — handshake returns `{"protocol":1,"runtime":"0.1.0","capabilities":[...]}`; `:496-504` service_error path (`data` = custom-answer body).
- `examples/06-assets/assetsapp.pas` — host-app template to clone: `:206` binds `__pweb_invoke`, `:214` asset handler + `pweb://app/` navigate, `:93-120` reporting-bridge verdict latch, teardown order `:230-287`.
- `examples/06-assets/frontend/dist/` — committed page fixture pattern; CAP-4 zero-HTTP sweep list in `ci.yml:449-475`.
- `.github/workflows/ci.yml:128-138` — setup-lazarus 3.4 (no pas2js RTL on runner ⇒ pinned fetch required); `:99-126` floating-ref guard; `:554-585` freeze sweeps (keep byte-identical); `:705-742` conditional hosted runtime-gate pattern to reuse.
- `tools/get-webview.ps1` / `webview.lock` — fetch-then-verify pin pattern for the new `tools/get-pas2js.ps1` + `pas2js.lock` (url `https://getpas2js.freepascal.org/downloads/windows/pas2js-win64-x86_64-3.0.1.zip`, sha256 `f039126443a41a697dfa645ef594974f3eec3bd9020b992504f397c95fcb0af2`, unpack → `deps/pas2js`).
- Probe-validated Pas2JS facts (pas2js 3.0.1): `async`/`await(T, promise)` compile and run; SDK `.catch` callback may `raise EPWebError` so `await` sites catch `on E: EPWebError`; `-Tbrowser -Jc -Jirtl.js` emits one self-contained JS; page/harness calls `rtl.run()`.

## Tasks & Acceptance

**Execution:**
- [x] `tools/get-pas2js.ps1` + `pas2js.lock` — checksum-verified fetch of pas2js 3.0.1 into `deps/pas2js` (mirror get-webview.ps1; used locally and in CI).
- [x] `sdk/typescript/` — `@pweb/runtime` package: `src/{index,invoke,errors,handshake,types}.ts`; exact-passthrough `invoke<T>`, primitive detection, envelope→`PWebError{code,status,data}` mapping, `handshake()` + protocol check; `package.json`+`package-lock.json` (typescript pinned exact), strict tsconfig; no runtime deps.
- [x] `sdk/typescript/test/` — `node:test` suite over a fake `__pweb_invoke`: every I/O-matrix row plus exact method/args capture.
- [x] `sdk/pas2js/pweb.native.pas` — `PWebInvoke(method, args): TJSPromise` + `PWebHandshake` (module functions; smallest idiomatic surface); identical envelope mapping via `.catch`-raise `EPWebError`; absent-primitive and malformed-rejection handling identical to TS.
- [x] `sdk/pas2js/test/` — pas2js-compiled harness run under node with the same fake primitive; emits machine-readable results + captured wire JSON; `tools/check-sdk-parity.ps1` (or inline CI step) compares TS vs Pas2JS captures semantically.
- [x] `examples/04-react/` — `frontend/` (react/react-dom/esbuild/typescript pinned, `@pweb/runtime` via `file:`, TSX app: handshake → invoke → render 42 → `example.report`) + `reactapp.pas` host cloned from assetsapp (folder store, verdict: handshake+rpc42+secure+worker-thread).
- [x] `examples/05-pas2js/` — `frontend/` pas2js program using the SDK, same logical call/report; `pas2jsapp.pas` host, same verdict gate.
- [x] `.github/workflows/ci.yml` — append gates: TS SDK typecheck+tests; React build; pas2js fetch+SDK compile+harness tests+frontend build; parity compare; protocol-constant cross-check; zero-network sweep over `sdk/**` and both frontends' committed sources; both runtime smokes under the existing conditional hosted policy. No existing step altered.

**Acceptance Criteria:**
- Given both SDK test suites, when run headless (node), then every I/O-matrix row passes deterministically in both languages — Pas2JS proven by execution, not inspection.
- Given the same logical call from each SDK, when the wire capture is compared, then method is identical, args JSON-equivalent, and no frontend-identifying or trusted-context field exists.
- Given the two runtime examples over `pweb://app`, when run locally (and hosted where a WebView session exists), then each real frontend obtains 42 through the unchanged pipeline and exits 0, with no backend branch on frontend kind.
- Given the final tree, when full CI runs, then all prior CAP-1…CAP-4 gates and the three freeze diffs stay green and all pins are intact.

## Spec Change Log

## Design Notes

Binding-absent maps to `runtime_closed` (nearest frozen semantics: the runtime is unreachable; inventing a tenth code is forbidden). Unknown `code` strings and structurally invalid envelopes map to local `internal_error` — protocol v1 defines exactly nine codes, and preserving arbitrary strings would leak unvalidated content into typed surfaces. `handshake()` is an explicit ready-gate the acceptance apps call before first invoke; `invoke()` itself stays ungated because the backend re-validates every call. `events.ts`/`window.ts` are deliberately absent (no backend contract behind them). React example bundles with esbuild to a plain IIFE served as static assets — no dev server, no module CDN; dist is built (CI + locally), not committed.

## Verification

**Commands:**
- `npm ci && npm test` in `sdk/typescript` — expected: typecheck + all node:test cases pass.
- `pwsh tools/get-pas2js.ps1` then pas2js harness compile + `node` run — expected: all cases pass, captures written.
- Parity compare step — expected: semantic equality TS↔Pas2JS.
- `npm run build` (examples/04-react/frontend) and pas2js frontend build — expected: dist produced offline-deterministically from lockfile/pin.
- Local runtime: `reactapp.exe <dist>` / `pas2jsapp.exe <dist>` with `PWEB_SMOKE_AUTOCLOSE_MS` — expected: verdict PASS + 42, exit 0, both.
- Push branch; hosted CI — expected: all gates green, freeze sweeps untouched.

## Suggested Review Order

**The one wire, seen from TypeScript**

- Byte-exact passthrough, local-only guards, immediate `runtime_closed` when the primitive is absent.
  [`invoke.ts:39`](../../sdk/typescript/src/invoke.ts#L39)

- Envelope→typed-error mapping: known code required; malformed reasons become generic `internal_error`.
  [`errors.ts:59`](../../sdk/typescript/src/errors.ts#L59)

- Handshake as ready-gate: set-membership protocol check, validated projection, advisory capabilities.
  [`handshake.ts:39`](../../sdk/typescript/src/handshake.ts#L39)

**The same wire, from Pas2JS**

- Same guards, same primitive, `.catch`-raise makes `await` sites catch typed `EPWebError`.
  [`pweb.native.pas:234`](../../sdk/pas2js/pweb.native.pas#L234)

- Mirror of `toPWebError`, including typed passthrough and the integer-status presence rule.
  [`pweb.native.pas:191`](../../sdk/pas2js/pweb.native.pas#L191)

- Handshake projection strips unknown members — result parity with TypeScript.
  [`pweb.native.pas:286`](../../sdk/pas2js/pweb.native.pas#L286)

**Parity is enforced, not asserted**

- Canonical five-call manifest anchors both captures; only `{method,args}` may cross.
  [`check-sdk-parity.mjs:53`](../../tools/check-sdk-parity.mjs#L53)

- Version, nine codes, statuses, and the binding name cross-checked across all sources.
  [`check_cap5_protocol.ps1:1`](../../test/cap5/check_cap5_protocol.ps1#L1)

**Real frontends over the real pipeline**

- React: handshake → 42 → real-rejection probe (`method_not_found`), all through the SDK.
  [`App.tsx:8`](../../examples/04-react/frontend/src/App.tsx#L8)

- Pas2JS: identical logical flow from compiled Pascal — same probe, same verdict fields.
  [`p2japp.pas:35`](../../examples/05-pas2js/frontend/src/p2japp.pas#L35)

- Host verdict latch: every flag + worker-thread proof; hosts line-identical across frontends.
  [`reactapp.pas:101`](../../examples/04-react/reactapp.pas#L101)

- Binding of the one primitive the SDKs wrap — nothing frontend-specific below this line.
  [`reactapp.pas:201`](../../examples/04-react/reactapp.pas#L201)

**Determinism and gates**

- pas2js pinned by sha256 at a versioned URL; drift fails loudly.
  [`get-pas2js.ps1:1`](../../tools/get-pas2js.ps1#L1)

- Globbed zero-network sweep + raw-primitive-bypass ban over SDKs and frontends.
  [`check_cap5_nonetwork.ps1:1`](../../test/cap5/check_cap5_nonetwork.ps1#L1)

- Appended CAP-5 CI section — every earlier step verbatim; conditional hosted smoke policy reused.
  [`ci.yml:753`](../../.github/workflows/ci.yml#L753)

**Tests last**

- TS suite: all matrix rows, capture identity, runtime-boundary probes.
  [`invoke.test.ts:1`](../../sdk/typescript/test/invoke.test.ts#L1)

- Pas2JS suite: same rows proven by execution under node, plus the capture emitter.
  [`pwebsdktests.pas:1`](../../sdk/pas2js/test/pwebsdktests.pas#L1)
