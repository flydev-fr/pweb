---
title: 'PWeb Phase 1 / CAP-1 — raw webview C ABI binding, ABI probe, Windows smoke, minimal CI'
type: 'feature'
created: '2026-08-09'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'b2f04dc4c478c72b1699a954dd52e76b207e918b'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/phase-plan.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/conventions.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** PWeb has frozen contracts but no native boundary: nothing can open a WebView from Pascal, and the most ABI-sensitive component has no guard rail.

**Approach:** Generate (never hand-translate) the complete public C ABI of `webview/webview` at pinned commit `cbbdee44afff22867de9fd88a9fc8350d9bdd399` (17 entry points, from `core/include/webview/api.h` + its public C includes) with chet-cli into the frozen three-unit layout; validate with paired C/Pascal ABI probes; prove with a Windows x64 "Hello PWeb" smoke example; start minimal Windows CI. Human gate cleared and chet-cli authorized by the triggering instruction.

## Boundaries & Constraints

**Always:**
- Upstream pin is immutable: build/fetch only that SHA; never master/latest/tag. Upstream CI at that pin is human-verified green.
- chet-cli is the sole source of ABI declarations; deterministic regeneration via committed `.chet` project (`--save-project`); no `--ignore-parse-errors` for the accepted generation; repairs go through config, `--ctype-map`, or a committed `--script-file` post-process — any surviving manual semantic correction is called out in the final report.
- Raw layer is literal ABI: no mORMot, no IWebView logic, no scheduler/RPC/capability logic; native handles stay opaque; all `webview_error_t` returns stay visible; enum representation must be ABI-measured (prefer integer + consts over Pascal enum if width/signedness would be compiler-dependent).
- ABI facts are measured by compiled probes (C vs Pascal sizes, offsets, enum values, signedness, symbol coverage), not reasoned from declarations.
- Amend Phase-1 docs saying "all 14 entry points" to "complete public C ABI of pinned upstream commit cbbdee44afff22867de9fd88a9fc8350d9bdd399" — a CAP-1 doc correction, not a Phase-0 reopening.
- Preserve upstream MIT license material for any vendored/distributed source or binary.
- CI never fetches a floating ref; ABI tests are not weakened for CI convenience; deferred Phase-0 freeze-isolation sweeps run in CI.

**Ask First:** any change to frozen Phase-0 public signatures (`pweb.rpc.intf.pas`, `pweb.webview.intf.pas`, `pweb.assets.intf.pas`) — STOP and report; maintaining a second handwritten copy of the C ABI to satisfy the three-unit layout — STOP and report; pushing or opening a PR.

**Never:** hand-translating C declarations; translating the C++ wrapper API; `webview_bind` RPC machinery, scheduler, mORMot, IAssetStore, `pweb://` schemes, React/Pas2JS (later phases); mORMot exception types in `WebViewCheck`; a new top-level vendor dir contradicting the frozen layout; loosening Phase-0 contracts because upstream documents something thread-safe; starting Phase 2 after PASS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Generation | pinned headers + committed .chet | Pascal units, zero parse errors, 17/17 entry points, no C++ API | fix includes/defines/ctype-maps or report incompatibility |
| ABI probe | C probe vs Pascal probe, same pinned headers | identical sizes/offsets/enum values/signedness (incl. negative `webview_error_t` codes) | any mismatch = blocker |
| Smoke run | Windows x64 desktop session | window titled "PWeb", visible Hello Pascal/PWeb marker, clean terminate/destroy/exit | every error-returning call checked via `WebViewCheck`; `webview_create` nil handled explicitly |
| CI | push to repo | pinned fetch, regen/verify binding, FPC 3.2.2 compile, headless ABI+layout+symbol tests, freeze-isolation sweeps green | GUI smoke compiled in CI; real run documented as human/local gate if runner lacks desktop session |

</frozen-after-approval>

## Code Map

- `_bmad-output/specs/spec-pweb/SPEC.md:27` -- CAP-1 success criterion; amend "all 14 upstream C entry points" wording (doc-correction task).
- `_bmad-output/specs/spec-pweb/core-interfaces.md:83-92` -- "Upstream C ABI surface (CAP-1)" section listing 14 names; amend to pinned-ABI wording + 17 names.
- `_bmad-output/specs/spec-pweb/phase-plan.md:64-76` -- Phase-1 ABI checklist; drives probe/test content. Cite, don't restate.
- `_bmad-output/specs/spec-pweb/conventions.md` -- frozen tree: binding in `src/lib/` (3 units), tests `test/core/`, example `examples/01-hello/`, CI `.github/workflows/`. No vendor dir → pinned fetch into git-ignored `deps/` + future vendoring reported.
- `src/rpc/pweb.rpc.intf.pas`, `src/webview/pweb.webview.intf.pas`, `src/assets/pweb.assets.intf.pas` -- FROZEN; read-only this phase.
- Pinned upstream: `core/include/webview/api.h` (17 `WEBVIEW_API` fns incl. `webview_get_window`, `webview_init`, `webview_version` beyond historic 14) + `errors.h`, `types.h`, `macros.h`, `version.h` if included. Verify set mechanically after fetch.
- Toolchain (verified on host): ChetCLI 1.0.0 win64 / libclang clang 14.0.0 at `C:\Users\badb\Documents\Embarcadero\Studio\Tools\chet-cli\ChetCLI.exe`; FPC 3.2.2 `C:\dev\IDE\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe`; cmake 4.3.2; MSVC via `VC\Auxiliary\Build\vcvars64.bat` (VS 18 Community). Record versions in report.
- Linkage: upstream `webview::core_shared` DLL (C ABI exports) — least fragile for FPC; no Pascal↔C++ ABI, no static C++ runtime entanglement. Implementation choice, not public contract.

## Tasks & Acceptance

**Execution:**
- [x] branch `phase/1-cap1-binding` off `phase/0-contracts` -- new branch per instruction (contracts not yet on main).
- [x] `deps/` fetch script (`tools/` or `deps/get-webview.ps1|.sh`) -- exact-SHA fetch of upstream, checksum/SHA verified, git-ignored checkout; record `webview.lock`-style pin file in repo.
- [x] Amend `SPEC.md:27` + `core-interfaces.md` CAP-1 section -- 14→pinned-ABI wording (17 names listed mechanically).
- [x] `chetcli` workflow: inspect headers → include roots/defines → `--dry-run` → generate with `--save-project` → commit `.chet` (+ post-process script if needed) -- produces `src/lib/pweb.lib.webview.pas` (+ `.types`/`.errors` per frozen split; multiple generation steps/ignored symbols/uses clauses acceptable; STOP if split forces a handwritten ABI copy).
- [x] `src/lib/` error helper (`WebViewCheck`) -- central check preserving original `webview_error_t`; explicit nil-handling for `webview_create`; no mORMot types.
- [x] Native probe `test/core/abi_probe.c` (or `.cpp`) + build via cmake/MSVC against pinned headers -- emits sizes/offsets/enum values/signedness machine-readably.
- [x] Pascal probe/tests `test/core/` -- same measurements from generated units + symbol-coverage check (17/17, no C++ API) + callback-typedef convention checks for `webview_dispatch`/`webview_bind`; compare against C probe output.
- [x] Upstream-semantics notes (`src/lib/` doc comments or `docs/`) -- run/dispatch/return/terminate threading, string lifetimes/ownership, userdata lifetimes, WebView2 COM/STA, embedded-NUL — from pinned source only; do not loosen Phase-0 contracts.
- [x] `examples/01-hello/` smoke -- create→check nil→set_title "PWeb"→set_html Hello marker→run→terminate→destroy→clean exit; errors checked.
- [x] `.github/workflows/` Windows CI -- pinned fetch, binding regen/verify, FPC compile, headless ABI/layout/symbol tests, Phase-0 freeze-isolation sweeps (grep-based leak checks + rpc.intf RTL-only compile), smoke compiled (run = documented local gate if needed).
- [x] Adversarial review pass over the 10 mandated angles; then final deliverable report (UPSTREAM/GENERATOR/BINDING/ABI VALIDATION/WINDOWS SMOKE/CI/FREEZE CHECK/VERDICT) ending `CAP-1 PASS` or `CAP-1 NOT READY`, then STOP.

**Acceptance Criteria:**
- Given the committed `.chet` + pin, when regeneration runs twice, then output is byte-identical and contains every pinned public C entry point.
- Given both probes, when compared, then every size/offset/enum/signedness matches; `webview_error_t` is 4-byte signed with negative codes representable.
- Given `git diff` on the three frozen `.intf` units, then zero changes.
- Given the smoke app on Windows x64, then window shows "PWeb"/Hello marker and exits cleanly with no evident leak or unhandled error.
- Given CI workflow, then no floating upstream ref appears anywhere in it.

## Spec Change Log

## Design Notes

- Three-unit split strategy: chetcli emits one unit per `--out`; preferred plan is separate generation passes (types/errors vs functions) with `--ignore-symbol` partitioning + `--uses`, or one generated core unit + thin `pweb.lib.webview.types/errors` re-export units produced by the committed post-process script. Decide during dry-run; the STOP rule guards the hand-copy failure mode.
- `webview_error_t` maps to a plain `Integer`-width type + constants (codes are negative; MISSING_DEPENDENCY=-5 … DUPLICATE=2 range at pin) unless probe proves a Pascal enum safe — kernel/phase-plan already mandate 4-byte signed.
- Callback types must be `cdecl` procedure types with `pointer` userdata so a later exception barrier can wrap them; no exception may cross the C frame (probe includes a compile-level signature check only; runtime barrier is Phase 2).

## Verification

**Commands:**
- `pwsh tools/regen-webview-binding.ps1` (committed pipeline: `chetcli run src/lib/webview.chet` + committed post-process) -- expected: exit 0, no parse errors, stable output (run twice, diff empty).
- `fpc.exe -MObjFPC -Sh -B` each `src/lib/` unit + test programs -- expected: compile clean, FPC 3.2.2-compatible.
- C probe exe vs Pascal probe exe -- expected: identical ABI report lines (diff empty).
- `grep -ri "mormot\|TRest\|react\|pas2js\|quickjs\|synlz" src/lib/` -- expected: no hits.
- `git diff --stat phase/0-contracts -- src/rpc src/webview src/assets` -- expected: empty (freeze intact).
- Smoke: run `examples/01-hello` binary locally -- expected: window opens, marker visible, clean shutdown (human-visible check).

## Suggested Review Order

**Raw ABI binding (the deliverable's core)**

- Entry point: generated unit header — pin provenance, `{$PACKRECORDS C}`, `{$MINENUMSIZE 4}`, regenerate-only warning.
  [`pweb.lib.webview.pas:13`](../../src/lib/pweb.lib.webview.pas#L13)

- All 17 cdecl externals begin here; opaque `webview_t`, `PAnsiChar` for `const char*`.
  [`pweb.lib.webview.pas:78`](../../src/lib/pweb.lib.webview.pas#L78)

- Callback typedefs for dispatch/bind — cdecl + `Pointer` userdata, exception-barrier-wrappable later.
  [`pweb.lib.webview.pas:91`](../../src/lib/pweb.lib.webview.pas#L91)

- Version structs as C-packed records with fixed `AnsiChar` arrays.
  [`pweb.lib.webview.pas:69`](../../src/lib/pweb.lib.webview.pas#L69)

**Regeneration pipeline & pin reproducibility**

- Canonical regen: chetcli run + deterministic post-process; refuses double-processing.
  [`regen-webview-binding.ps1:5`](../../tools/regen-webview-binding.ps1#L5)

- Committed chetcli project — the sole translation configuration.
  [`webview.chet:1`](../../src/lib/webview.chet#L1)

- Single source of pin truth: SHA + six header checksums.
  [`webview.lock:4`](../../webview.lock#L4)

- Exact-SHA fetch; dirty-tree force-restore; vacuous-checksum guard.
  [`get-webview.ps1:37`](../../tools/get-webview.ps1#L37)

**ABI validation (measured, not reasoned)**

- C probe: all 17 prototypes re-declared — header drift breaks the MSVC compile.
  [`abi_probe.c:20`](../../test/core/abi_probe.c#L20)

- Pascal probe mirrors 36 facts (sizes, offsets, enum values, per-field signedness).
  [`abi_probe.pas:1`](../../test/core/abi_probe.pas#L1)

- Typed procedural consts pin every Pascal external signature at compile time.
  [`signature_pin.pas:6`](../../test/core/signature_pin.pas#L6)

- Mechanical surface extraction from pinned api.h vs list vs declared externals.
  [`check_binding_surface.ps1:3`](../../test/core/check_binding_surface.ps1#L3)

- Dynamic 17/17 export coverage against the pinned-source DLL.
  [`symbol_coverage.pas:1`](../../test/core/symbol_coverage.pas#L1)

**Error layer**

- `WebViewCheck` raises only on negative codes, preserves the original code; nil-create handled.
  [`pweb.lib.webview.errors.pas:65`](../../src/lib/pweb.lib.webview.errors.pas#L65)

- Runtime helper behavior locked by 36 assertions.
  [`error_helper_test.pas:1`](../../test/core/error_helper_test.pas#L1)

**Smoke example**

- Dispatch-routed terminate — required at this pin (`PostQuitMessage` posts to the calling thread).
  [`hello.pas:15`](../../examples/01-hello/hello.pas#L15)

- Interlocked fetch-and-clear closes the auto-close race; bounded wait, no destroy-after-timeout.
  [`hello.pas:73`](../../examples/01-hello/hello.pas#L73)

**CI**

- Floating-ref guard over fetch/build scripts and the workflow itself.
  [`ci.yml:44`](../../.github/workflows/ci.yml#L44)

- Freeze-isolation sweeps: surface check, RTL-only compiles, byte-diff against baseline.
  [`ci.yml:156`](../../.github/workflows/ci.yml#L156)

- Best-effort smoke run — PASS/SKIP/FAIL visible, authoritative gate stays local.
  [`ci.yml:194`](../../.github/workflows/ci.yml#L194)

**Docs & peripherals**

- Measured upstream semantics at the pin, incl. the terminate pitfall.
  [`webview-upstream-semantics.md:27`](../../docs/webview-upstream-semantics.md#L27)

- MIT + WebView2 SDK license preservation.
  [`third-party-licenses.md:1`](../../docs/third-party-licenses.md#L1)

- CAP-1 wording corrected from "14 entry points" to pinned complete C ABI.
  [`core-interfaces.md:83`](../specs/spec-pweb/core-interfaces.md#L83)
