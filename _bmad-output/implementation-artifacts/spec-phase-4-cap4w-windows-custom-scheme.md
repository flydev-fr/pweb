---
title: 'CAP-4W Windows custom-scheme seam'
type: 'feature'
created: '2026-08-11'
status: 'done'
baseline_commit: '3a9ff2b7fa7d82345002f613fb86d58384452a3e'
review_loop_iteration: 0
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/deployment.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-4 is blocked because pinned webview creates WebView2 with null environment options under SDK 1.0.1150.38, so `pweb://app` cannot be registered before environment creation.

**Approach:** Keep webview at `cbbdee44afff22867de9fd88a9fc8350d9bdd399`, pin SDK 1.0.1587.40, and apply a reproducible private Windows patch registering `pweb` before environment creation. Prove the unchanged 17-function C ABI can render a resource response through its borrowed controller.

## Boundaries & Constraints

**Always:** Preserve frozen contracts/raw binding byte-for-byte; use `HasAuthorityComponent=TRUE`, `TreatAsSecure=TRUE`, no `AllowedOrigins`, exact `pweb://app/*` filtering, checked HRESULTs, exception barriers, and unregister → release owned COM → webview destroy. The patch is transactional, idempotent, exact-state checked, restorable, and limited to the Windows backend/loader. Preserve the original CAP-4 NOT READY result.

**Ask First:** Any SDK newer than 1.0.1587.40; any upstream file beyond the Windows environment/loader integration; any need for `AllowedOrigins`; any public ABI or frozen-file change.

**Never:** Change the upstream commit, public webview exports, privileged origin, core interfaces, or CAP-3/CAP-3U; add HTTP/localhost/file fallback; implement IAssetStore, ZIP/folder assets, blob/Range, CAP-5, or another WebView wrapper.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| App navigation | `pweb://app/probe` | HTML and same-origin JS are intercepted; JS reports rendered PASS | Any COM/navigation/callback failure fails |
| Authority isolation | `pweb://other-host/probe` | App handler is not invoked and content is not trusted | Deterministic negative verdict; no fallback |
| Scheme isolation | unrelated HTTPS navigation | Handler count stays unchanged | Never synthesize PWeb content |
| Old runtime | runtime API below 1587 | Environment creation fails explicitly | No retry into another transport |
| Teardown | live event/COM state | Event removed before state/references are released | Never destroy with live registration |

</frozen-after-approval>

## Code Map

- `webview.lock` — immutable upstream SHA and new exact SDK dependency pin.
- `deps/webview/cmake/webview.cmake:3` — existing cache override seam; read-only dependency evidence, not the canonical pin edit.
- `deps/webview/core/include/webview/detail/backends/win32_edge.hh:743-760` — patched target: checked scheme/options and non-null environment argument.
- `deps/webview/core/include/webview/detail/platform/windows/webview2/loader.hh:342-345` — patched target: reject runtime API below 1587.
- `tools/patch-cap3u.ps1` — transactional exact-state/restore precedent only.
- `tools/build-webview-dll.ps1` — pass exact SDK override and require patched state.
- `test/core/check_binding_surface.ps1` — mechanical 17-export/header/raw-binding freeze gate.
- `test/cap4w/` — private C++ controller/resource/lifecycle probe; no IAssetStore.
- `.github/workflows/ci.yml` — preserve ordering; add patch/build/ABI/compile coverage and evidence-based GUI policy.

## Tasks & Acceptance

**Execution:**
- [x] `test/cap4w/` — add failing probe first for HTML, subresource, isolation, unregister, and repeated lifecycle.
- [x] `webview.lock`, `tools/cap4w/webview2-custom-scheme.patch`, `tools/patch-cap4w-webview.ps1` — pin SDK 1.0.1587.40 and install/restore only the exact audited two-file dependency delta transactionally.
- [x] `tools/build-webview-dll.ps1` — pass quoted SDK pin, verify patch, and stage DLL/licenses.
- [x] `.github/workflows/ci.yml` — add CAP-4W integrity, ABI, probe compile/headless checks, and evidence-based GUI policy without weakening existing gates.
- [x] `_bmad-output/implementation-artifacts/spec-phase-4-cap4w-windows-custom-scheme.md` — append pins, patch, runtime/lifetime/regression/CI/freeze results; preserve original CAP-4 NOT READY evidence.

**Acceptance Criteria:**
- Given pristine pinned upstream, when the patch is applied twice and restored, then only the exact Windows backend/loader delta exists, the second apply is idempotent, and restore matches the pinned git tree.
- Given SDK 1.0.1587.40 and a supporting runtime, when the unchanged C API navigates to `pweb://app/probe`, then HTML/JS render, wrong authority/HTTPS are not served, and repeated unregister/destroy cycles pass.
- Given the corrected DLL, when CAP-1/2/3 gates run with CAP-3U preparation where required, then the raw surface remains 17 functions and all existing results stay green.

## Spec Change Log

- 2026-08-11 — Implemented and locally verified the approved CAP-4W-only correction. No frozen intent or CAP-4 asset scope was changed.
- 2026-08-11 — Review fixes made the CMake probe trackable, isolated patch-script process exit, serialized patch/restore, pinned the extracted SDK tree, added a headless 1587 boundary gate, tightened probe source/navigation/teardown checks, and made genuine hosted probe failures gating while retaining evidence-based infrastructure SKIP.

## Design Notes

The seam cannot live in Pascal because the controller appears only after creation. SDK 1.0.1587.40 already builds unchanged upstream. The patch uses SDK environment-options/custom-scheme implementations and raises the private loader minimum 1150 → 1587. The probe owns acquired CoreWebView2/environment references but never releases the borrowed controller.

Original result: **CAP-4 NOT READY** because SDK 1.0.1150.38 supported only file/http/https resource interception and upstream passed null options. CAP-4 stays blocked until CAP-4W passes.

## Verification

**Commands:**
- `cmake ... '-DWEBVIEW_MSWEBVIEW2_VERSION=1.0.1587.40' ...` — unchanged pinned source and patched source both build.
- `tools/patch-cap4w-webview.ps1` apply/twice/restore — exact state, idempotence, and restoration pass.
- `pwsh -NoProfile -File test/core/check_binding_surface.ps1` plus ABI probes — exactly 17 public functions and byte-compatible layouts.
- `test/cap4w` runner — render, isolation, unregister, and repeated lifecycle pass locally.
- Existing CAP-1/2 suite and CAP-3U-prepared CAP-3 suite — no regressions.

**Manual checks (if hosted GUI is unavailable):**
- Run the CAP-4W visible smoke locally and require the machine-readable rendered verdict; hosted CI reports compile/ABI coverage without claiming runtime PASS.

## CAP-4W Implementation Evidence

### Baseline and blocker preservation

- CAP-4W started from PWeb commit `3a9ff2b7fa7d82345002f613fb86d58384452a3e`.
- The original **CAP-4 NOT READY** result above remains the historical record: upstream SDK 1.0.1150.38 had no custom-scheme environment API and the pinned backend passed null environment options.
- CAP-4 asset stores were not implemented or resumed. CAP-4W only repairs the private Windows pre-environment seam.

### Exact dependency correction

- Upstream webview remains `cbbdee44afff22867de9fd88a9fc8350d9bdd399`.
- The old upstream default is `1.0.1150.38`; the selected PWeb Windows SDK pin is the minimum requested stable version, `1.0.1587.40`. Unmodified pinned upstream and the patched backend both compiled against it, so no newer SDK was needed.
- Downloaded SDK NuGet SHA-256: `cd5e34264aaa497d672f391fbdfb4fd4defc7f7a3e72cfe6090717dd063f27e4`.
- Deterministic ordinal-path 83-file extracted SDK tree SHA-256: `96309ee87acbe5ae033797b9041cdc1578e1cc7e87ee5d051e609dcb4563a971`; package and extracted tree are both checked before compilation.
- Canonical patch SHA-256: `ae5177ba2bcc461365e82d40d42fd2d1fb1058ab322d00e93ed4013436f7137c`.
- The patch changes only `win32_edge.hh` and the private WebView2 `loader.hh`: it creates SDK environment options, registers `pweb` with authority and secure treatment, passes non-null options into environment creation, and raises the private minimum runtime API from 1150 to 1587.
- Apply twice, restore to pinned git objects, reapply twice, exact-diff verification, concurrent-operation serialization, and unknown-state rejection all passed. Restore does not use a backup.

### Custom scheme and controller seam

- `CoreWebView2EnvironmentOptions` is queried for `ICoreWebView2EnvironmentOptions4`; every allocation/QI/property/registration HRESULT is checked.
- `CoreWebView2CustomSchemeRegistration(L"pweb")` uses `HasAuthorityComponent=TRUE` and `TreatAsSecure=TRUE`, with no `AllowedOrigins`.
- The installed Evergreen runtime was `151.0.4129.72`. Direct navigation to `pweb://app/probe` succeeded, same-origin `/probe.js` loaded, and the script required `window.isSecureContext === true` before posting `CAP-4W PASS`.
- A runtime below API 1587 is rejected by the private loader before environment creation; `webview_create` returns nil and there is no alternate transport. A committed platform-private headless gate now proves below-boundary rejection plus exact/above-boundary acceptance against the pinned loader.
- After creation the probe uses only the existing `WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER` route. The controller pointer stays borrowed; acquired CoreWebView2/environment interfaces are PWeb-owned COM references.

### Resource and lifetime proof

- The only filter is `pweb://app/*`. `pweb://other-host/probe` and `https://cap4w.invalid/` completed navigation without incrementing the PWeb handler count.
- The app navigation produced exactly two handler calls: HTML plus same-origin JavaScript. The native memory streams returned deterministic content types and the JS-rendered verdict.
- COM callbacks catch all C++ exceptions. The PASS message is accepted only from `pweb://app/probe`, unexpected app-filter requests fail, and both negative navigations must report failure. Teardown checks removal of navigation, message, and resource event tokens, removes the resource filter, releases callback objects and owned COM references, then calls `webview_destroy`; its failure fallback retains callback state through synchronous destruction.
- Ten consecutive create/navigate/render/unregister/destroy cycles passed; a final three-cycle run also passed after adding the secure-context assertion.

### ABI and regression proof

- `dumpbin /exports` reported exactly the original 17 public webview functions; public upstream C headers and the Pascal raw binding are unchanged.
- CAP-1 binding surface/purity/isolation checks passed; C/Pascal ABI layout probes matched all 36 facts. The CAP-1/CAP-2 headless suite passed 595 assertions with zero failures.
- Existing corrected-DLL GUI smokes passed: SetHtml printed `hello: clean exit`; the JS binding reported all invocations correct and a clean exit.
- FPC 3.2.2 Win64 CAP-3U passed its PE unwind gate and `12/12` runtime matrix before CAP-3. CAP-3 then passed `124/124` headless assertions, and its real JS → scheduler → in-process mORMot → JS example returned 42 and exited cleanly. CAP-3U was restored afterward.

### CI, network, and freeze evidence

- CI now verifies the exact commit, patch apply/idempotence/restore/reapply/unknown-state rejection, SDK package/tree pins, private loader boundary, 17-export ABI, and CAP-4W probe compilation. Its GUI attempt records PASS/SKIP/FAIL: a genuine probe failure gates, while only an initial `webview_create` failure with no completed cycle is an infrastructure SKIP. Local runtime remains authoritative.
- The edited CI YAML and all CAP-4W PowerShell files parse locally, and the headless/compile CI-equivalent gate passes. Hosted CI has not run for these unpushed changes, so no hosted runtime PASS is claimed.
- New CAP-4W sources contain no localhost, loopback, file navigation, HTTP server, socket, blob/Range implementation, public webview extension, or fallback. The sole HTTPS literal is the negative handler-isolation test.
- All `src/` production code is unchanged from the CAP-4W baseline. The historical Phase-0/1/2 boundary is byte-identical to `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`; `src/lib` is byte-identical to its CAP-1 baseline; CAP-3/CAP-3U sources and the mORMot pin are unchanged.

### Remaining scope

- Hosted GUI custom-scheme execution remains best-effort because a desktop session is not guaranteed; local runtime evidence is authoritative.
- Evergreen provisioning and enforcing the minimum runtime during deployment remain later deployment work.
- Folder/ZIP `IAssetStore`, asset path handling, and MIME behavior remain CAP-4 work and were not started here. Blob/Range remains deferred to CAP-4b and is off the Phase-5 critical path.

## Suggested Review Order

**Windows custom-scheme seam**

- Start with the exact two-file upstream correction establishing the privileged origin.
  [`webview2-custom-scheme.patch:19`](../../tools/cap4w/webview2-custom-scheme.patch#L19)

- Confirm the dependency version, package hash, and extracted-tree pin.
  [`webview.lock:9`](../../webview.lock#L9)

**Reproducible dependency state**

- Review exact-state recognition, exclusive serialization, restore, and transactional rollback.
  [`patch-cap4w-webview.ps1:98`](../../tools/patch-cap4w-webview.ps1#L98)

- Verify package and ordinal-tree integrity before the compiler consumes the SDK.
  [`build-webview-dll.ps1:44`](../../tools/build-webview-dll.ps1#L44)

**Runtime and lifetime proof**

- Follow controller acquisition, origin isolation, response creation, and guarded teardown.
  [`cap4w_probe.cpp:171`](../../test/cap4w/cap4w_probe.cpp#L171)

- Check the headless below/exact/above minimum-runtime boundary test.
  [`cap4w_loader_boundary.cpp:38`](../../test/cap4w/cap4w_loader_boundary.cpp#L38)

- Confirm subprocess timeout enforcement and local authoritative execution.
  [`check_cap4w.ps1:41`](../../test/cap4w/check_cap4w.ps1#L41)

**ABI and automation**

- Validate strict parsing of all 17 exports, including forwarded rows.
  [`check_webview_exports.ps1:46`](../../test/cap4w/check_webview_exports.ps1#L46)

- Review hosted patch integrity, headless boundary, and conditional GUI verdict policy.
  [`ci.yml:56`](../../.github/workflows/ci.yml#L56)

- Confirm CMake remains tracked despite the repository-wide text-file ignore.
  [`.gitignore:88`](../../.gitignore#L88)

- Preserve the canonical patch bytes across Windows checkout settings.
  [`.gitattributes:2`](../../.gitattributes#L2)
