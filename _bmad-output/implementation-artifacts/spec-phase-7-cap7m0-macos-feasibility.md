---
title: 'CAP-7M0 — macOS feasibility and architecture lock: measuring the frozen stack on Cocoa/WKWebView before CAP-7M'
type: 'feature'
created: '2026-08-15'
status: 'in-review'
review_loop_iteration: 0
context: []
baseline_commit: '5cb564da741a9e073f30a9d0a76f85e40170f0fc'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-7 requires the same application source on Windows, Linux and macOS behind one contract, and CAP-7L has just closed the Linux half. macOS is the last unknown, and it is **not** a Linux repeat. The pinned webview's Cocoa backend builds its `WKWebViewConfiguration` **and** its `WKWebView` inside `webview_create` (`cocoa_webkit.hh:450,486`), and Apple documents `WKWebView.configuration` as a *copy* whose mutation "doesn't affect the web view's configuration" — so the post-create `BROWSER_CONTROLLER` seam CAP-7L relied on cannot be assumed to exist. Nothing in the repository compiles for Darwin at all: the generated binding hard-fails off WIN64/LINUX (`src/lib/pweb.lib.webview.pas:24-26`), there is no `src/platform/macos/`, no `test/cap7m/`, and no macOS job in `ci.yml`. Committing to a production CAP-7M with the scheme seam, the secure origin, the Objective-C bridge, the toolchain and the bundle layout all unmeasured would repeat the CAP-7L pattern of discovering load-bearing constraints during implementation — on a platform where the dev host cannot run a single test.

**Approach:** Measure, do not implement. Build the exact pinned revision unmodified on native `x86_64-apple-darwin` and `arm64-apple-darwin`; compile the existing single binding surface there; drive a real `NSApplication`/`WKWebView` through a throwaway Objective-C++ probe that exercises the frozen threading contract, the `pweb://app` scheme seam, the `WKURLSchemeTask` lifecycle and the secure-origin question; derive a minimum macOS baseline, a deterministic `.app` layout and explicit CI runner labels from measurement rather than from the runner's defaults. Then **STOP** at Checkpoint 1 with one seam proposal, one bridge proposal and a PASS/BLOCKED verdict for human ratification.

## Boundaries & Constraints

**Always:**
- **Feasibility only.** Every artifact this shard adds is a probe, a gate, a CI job or a measured record. No production macOS adapter exists when this shard closes.
- **The pinned revision, unmodified.** `deps/webview` stays pristine for probes A–D; the CAP-4W patch is Windows-only and must not be applied on the macOS path. Public exports remain exactly **17** on both architectures.
- **One binding declaration surface.** The 17 declarations stay single-source in `src/lib/pweb.lib.webview.pas`, produced only by `src/lib/webview.chet` + `tools/regen-webview-binding.ps1`. A second macOS copy of the declarations, or a hand edit, is forbidden.
- **Native architectures, never Rosetta.** Every gate asserts `uname -m` and `fpc -iTP` before it accepts a result. A Rosetta-hosted execution is never authoritative x64 or arm64 runtime proof.
- **The whole URI, always.** Any request path measurement feeds the complete observed URL to `PWebParseAppUri` (`src/assets/pweb.assets.support.pas:80-81`). No security verdict is derived from a path, a last path component, or a filesystem conversion. Wrong authority must never reach `IAssetStore`.
- **The frozen threading contract is re-proven, never adapted.** Bind callback GUI-affine and enqueue-only; workers call `webview_return` **directly**. `worker → webview_dispatch → webview_return` is forbidden even in a probe.
- **`pweb://app` is the only candidate privileged origin.** Never `file:`, `localhost`, `127.0.0.1`, embedded HTTP, `data:` or `blob:`. No undocumented/private WebKit SPI to obtain secure-context status.
- **Explicit deployment target.** The macOS minimum is passed on every compile and link; the runner's Xcode SDK never decides it silently.
- **No network transport.** JS → Pascal stays `webview_bind` + scheduler, in-process. The scheme handler is an asset transport, not RPC.
- **Windows and Linux stay byte-green.** Every CAP-1…CAP-7L gate keeps passing unchanged; the `windows:` and `linux:` jobs are not restructured.

**Ask First:**
- **Enabling the Darwin platform block in the generated binding.** `src/lib` is hash-pinned twice (`ci.yml:626` against `709bf0fe`, `ci.yml:648` against `4653ba77`), both comparing against the single `cap7l-binding-patch-sha256` key. A Darwin branch changes both diffs and forces that value to be re-derived. Do not silently re-pin.
- **The custom-scheme seam.** Present exactly one of: existing native handle (A) / PWeb-owned Objective-C pre-create seam (B) / minimal upstream patch (C). If C, STOP — do not write the patch before approval.
- **The Objective-C bridge strategy** (FPC native ObjC interop vs a linked `.mm` object vs a shipped dylib) and the **minimum macOS baseline**.
- **Any new pinned toolchain artifact** (FPC for Darwin, a pinned Xcode selection) and any new lock file.

**Never:** production macOS asset handler; final release packaging; signing, notarization or auto-update; CAP-8 navigation security, CAP-10 CLI, CAP-11 matrix/watcher, CAP-12 blobs; an 18th public webview export; a second RPC path, scheduler, permission system or frontend path; changes to `IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `IAssetStore`, `IBlobStore`, `ICapabilityPolicy`, the wire, the error taxonomy or `app.pwb` semantics; Universal 2 as a CAP-7 requirement; mocked WebKit, a browser substitute, or a headless-DOM stand-in for a real `WKWebView`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| M1 (A) | pinned SHA, explicit arch + deployment target | dylib builds against Cocoa/WebKit on each arch; `lipo`/`file` reports exactly that arch | configure/build nonzero → STOP |
| M2 (A) | built dylib | `nm -gU` yields exactly the 17 pinned names on **both** arches, no arch-specific extra or missing export | any diff blocks |
| M3 (A) | built dylib | `otool -L` dependency graph and `otool -D` install-name recorded; `LC_RPATH` behaviour recorded | unrecorded ⇒ incomplete |
| M4 (B) | binding + `test/core/abi_probe.{c,pas}` **unmodified** | 36 facts each side; diff limited to exactly the two documented signedness lines, both 4-byte, all values non-negative | any third delta blocks |
| M5 (B) | `nm`/`dlopen` presence gate | all 17 externals resolve through the Mach-O underscore convention | missing symbol blocks |
| M6 (C) | real `NSApplication` + `WKWebView` on a hosted runner | window appears, HTML renders, `webview_eval` executes, programmatic terminate and user-close both destroy cleanly, repeatable across cycles | crash/hang/leak blocks |
| M7 (D) | `__pweb_invoke` round trip | bind callback thread == GUI thread; service runs on a distinct worker; the worker's **direct** `webview_return` resolves the promise | non-GUI callback ⇒ STOP |
| M8 (D) | 8 concurrent invocations, one forced error, shutdown with one outstanding | all complete exactly once; error rejects with payload intact; shutdown is graceful; callback `id`/`req` proven copy-only | any UAF/double-completion blocks |
| M9 (E) | handler set on `webView.configuration` **after** `webview_create` | MEASURED verdict recorded (expected ineffective per Apple's copy semantics) | ineffective ⇒ seam A refused, not a failure |
| M10 (E) | PWeb-owned pre-create seam, no ABI change, exports still 17 | `pweb://app/index.html` is actually requested by WebKit | ineffective ⇒ escalate to C and STOP |
| M11 (F) | `pweb://app/index.html`, `pweb://app/assets/…` | full observed URL captured verbatim and fed to `PWebParseAppUri` | truncated/normalised URL ⇒ blocker |
| M12 (F) | `pweb://evil/x`, missing authority, `..`, `%2e%2e`, double-encoded, backslash, NUL, malformed `%` | every vector refused by the shared routine; `IAssetStore` never consulted | one leak ⇒ STOP |
| M13 (G) | `startURLSchemeTask` / `stopURLSchemeTask`, cancel mid-response | exact required sequence recorded; no second terminal completion, no callback after stop, no UAF, no double-free | any NSException escaping ⇒ blocker |
| M14 (G) | response body whose Pascal source buffer is poisoned/freed after handoff | measured verdict on whether WebKit copies/retains at handoff; ownership rule stated | undetermined ⇒ incomplete |
| M15 (H) | JS on `pweb://app/index.html` | `{protocol:"pweb:", host:"app", origin:"pweb://app", secure:true}` observed, not inferred | `secure:false` ⇒ report exactly and STOP |
| M16 (I) | explicit `-WM<version>` / `CMAKE_OSX_DEPLOYMENT_TARGET` | binaries carry the intended `LC_BUILD_VERSION` minos; floor justified by measured requirements | SDK-decided minimum ⇒ blocker |
| M17 (J) | both arches | FPC hosts natively, mORMot core compiles, binding compiles, WKWebView runs, worker return path works | one arch failing is reported, never silently dropped |
| M18 (K) | throwaway `.app` around the probe, run from an unrelated CWD | resources resolved from the executable location; no CWD, no `DYLD_LIBRARY_PATH`, no checkout dependency; `otool -L` proves it | any external dependence blocks |
| M19 (L) | each runner label | `uname -m`, `sw_vers`, `xcodebuild -version`, SDK path/version, `fpc -iV`/`-iTP` recorded before any gate is accepted | arch mismatch ⇒ job fails |
| M20 | production-shaped probe run | no `TRestHttpServer`, no listener, no loopback URL; WebKit's own XPC/IPC is not a PWeb transport | any PWeb listener blocks |

</frozen-after-approval>

## Code Map

**Reusable verbatim — do not fork, do not reimplement.**
- `test/core/abi_probe.c` (122 lines) + `test/core/abi_probe.pas` (157) — the single pinned CAP-1 probe pair, explicitly designed to stay unmodified on every platform. 36 facts, emission order fixed; keys `sizeof.*`, `signed.*`, `enum.*`, `offset.*`, `sizeof.fnptr.*`. Reuse as-is; the Darwin work is a new harness around them. clang needs the same `-Wno-type-limits` gcc needed (`test/cap7l/check_abi.sh:64-71`).
- `src/assets/pweb.assets.support.pas:80-81` `PWebParseAppUri(const Uri: RawUtf8; out LogicalPath: RawUtf8): Boolean` — the only authority/path verdict. Also `:54` `PWebAssetPathValid`, `:66-67` `PWebPercentDecodeOnce`, `:60` `PWebAssetMimeType`. Portable, no `{$ifdef}`.
- `src/assets/pweb.assets.intf.pas:39-42,84-86` — `TAssetResponse` + `IAssetStore.TryRead`, byte-frozen by `ci.yml:602` and `ci.yml:648`. Read-only.
- `src/rpc/*`, `src/webview/*`, `src/security/pweb.capabilities.pas` — byte-frozen by `ci.yml:648`. Read-only.

**Structural models to mirror (shape, not mechanism).**
- `test/cap7l/cap7l_probe.c` (575) — the reference-probe pattern: `MARKER key=value` on stdout, `CAP7L_FAIL cycle=N reason=…` on stderr, exit 0/1/2, watchdog-bounded, page reports its own facts as a JSON object passed through `window.__cap7l_report`. `test/cap4w/cap4w_probe.cpp` (484) is the Windows sibling.
- `test/cap7l/check_abi.sh:64-120` — the order-sensitive fd-3 two-file walk and the exact-2-deltas whitelist. Copy the idiom; `allowed -eq 2` (not `<=`) so a vanished delta also blocks.
- `tools/build-webview-so.sh` (185) — strict lock parser, arch assertion, configure, **re-read `CMakeCache.txt` to prove what was resolved**, build only `webview_core_shared`, assert the exact artifact path and its SONAME, stage with `LICENSE.webview`.
- `test/cap7l/check_webview_exports.sh` (47) — `nm -D --defined-only --format=posix`, sorted, must equal exactly 17. Darwin analogue: `nm -gU`, then strip the Mach-O leading underscore before comparing.
- `examples/08-release/releaseapp.pas:95-99,403-414,441-445` — the `{$ifdef LINUX}`/`{$else}` selection points a future CAP-7M mirrors. **Not touched by this shard.**
- `src/platform/linux/pweb.platform.webkitgtk.pas` (720) — the adapter shape CAP-7M will mirror: `Create`/`Destroy`/`Detach` only, private externals against exact library names, idempotent GUI-thread detach, exception barrier. **Read for structure; write no macOS counterpart here.**

**Needs work.**
- `src/lib/webview.chet:20-33` — `[Platform.MacARM]` and `[Platform.MacIntel]` are `Enabled=0`. Enabling them plus `LibraryName=libwebview.dylib` regenerates the const block at `src/lib/pweb.lib.webview.pas:17-26`. Generator-produced only; `tools/regen-webview-binding.ps1` needs `-ChetCli` (present at `Studio/Tools/chet-cli/ChetCLI.exe`).
- `webview.lock` — needs the macOS baseline block beside the Windows and Linux ones, and `cap7l-binding-patch-sha256` re-derived so it satisfies **both** freeze baselines simultaneously.
- `.github/workflows/ci.yml` (1660 lines, `windows:` at 57, `linux:` at 1423, no matrix, no `needs:`, no job-level `if:`). `on: push/pull_request/workflow_dispatch` with **no branch filter** — a new job runs on every push. Two constraints: the guard at `:140-167` scans `ci.yml` **itself** for `git clone`/`git pull`/`git ls-remote`/`refs/heads`/`refs/tags`/`webview/webview@`, and the Linux guard at `:1466` asserts **every** committed `*.sh` in the repo is index mode `100755`.
- `tools/get-webview.ps1`, `tools/get-mormot.ps1` — already proven cross-platform via `pwsh` on the Linux job (`ci.yml:1520-1526`); reuse unchanged on macOS.

**Measured environment facts carried in (do not rediscover).**
- Runner labels available today: `macos-15-intel` / `macos-26-intel` (x86_64, standard tier) and `macos-15` / `macos-26` / `macos-latest` (arm64). `macos-13` and its `-large` variants were retired 2025-12-04; `macos-14` dies 2026-11-02; `macos-latest-large` is x64, not arm64.
- Hosted macOS runners have a real WindowServer/Aqua session — no Xvfb analogue is needed — but a non-bundled Mach-O must set `NSApplicationActivationPolicyRegular` to present a window, which upstream already does at `cocoa_webkit.hh:428-436`.
- FPC 3.2.2's `fpc-3.2.2.intelarm64-macosx.dmg` installs **native** `ppcx64` and `ppca64`. Deployment target is `-WM<version>`. There are open, unresolved FPC linker failures on recent Xcode (aarch64 + Xcode 16.3 → `ld` exit −11; Intel + Xcode 16.2 build failure), so the Xcode selection is a measured variable, not a default.
- mORMot statics for `x86_64-darwin` and `aarch64-darwin` are already inside the pinned `mormot2static.tgz`.

## Tasks & Acceptance

**Execution:**
- [x] `src/lib/webview.chet`, `src/lib/pweb.lib.webview.pas` -- enable the two macOS platforms and regenerate via `tools/regen-webview-binding.ps1` -- PROBE B needs the binding to compile on Darwin, and it must come from the generator, never a hand edit.
- [x] `webview.lock` -- add the macOS baseline block (dylib name, install-name/rpath strategy, deployment target, both runner labels) and re-derive `cap7l-binding-patch-sha256` so both freeze baselines agree -- the macOS baseline is pinned like every other dependency.
- [x] `fpc.lock` + `tools/get-fpc-macos.ps1` -- NEW: exact-version, platform-qualified, sha256-verified acquisition of the FPC 3.2.2 macOS artifact, plus the pinned Xcode selection -- the pin policy admits no `brew install` and no runner-default toolchain.
- [x] `tools/build-webview-dylib.sh` -- NEW: configure with explicit `CMAKE_OSX_ARCHITECTURES` + `CMAKE_OSX_DEPLOYMENT_TARGET`, assert the cache, build `webview_core_shared`, assert the Mach-O arch and record install-name/`LC_RPATH`, stage with `LICENSE.webview` -- nothing about the artifact may be decided by the host.
- [x] `test/cap7m/check_webview_exports.sh` -- NEW: `nm -gU`, underscore-stripped, exactly 17 on each arch -- PROBE A's export gate.
- [x] `test/cap7m/check_abi.sh` -- NEW: run the unmodified CAP-1 probe pair on Darwin, permit exactly the two documented signedness deltas, add a Mach-O symbol-presence gate -- PROBE B.
- [x] `test/cap7m/cap7m_probe.mm` -- NEW: the throwaway Objective-C++ feasibility probe carrying PROBES C, D, E, F, G and H in one bounded binary, emitting `CAP7M_* key=value` markers -- one real WKWebView proves the seam, the threading contract and the origin together or not at all.
- [x] `test/cap7m/build_cap7m.sh`, `test/cap7m/run_cap7m_probes.sh` -- NEW: compile binding, mORMot core and probe on the native arch with the explicit deployment target; assert `uname -m` and `fpc -iTP` first; drive the probe -- PROBES I and J, and the anti-Rosetta gate.
- [x] `test/cap7m/check_release_layout.sh` -- NEW: assemble a throwaway `.app` around the probe, run it from an unrelated CWD with no `DYLD_LIBRARY_PATH`, prove resolution via `@executable_path`/`@rpath` with `otool` -- PROBE K, measured before any layout is frozen.
- [x] `test/cap7m/check_cap7m_nonetwork.sh` -- NEW: source sweep plus a runtime listening-socket sample over the probe -- the no-network-transport invariant holds in feasibility too.
- [x] `.github/workflows/ci.yml` -- NEW sibling jobs `macos-x64:` and `macos-arm64:` on the two recorded labels, recording macOS/Xcode/SDK/FPC/arch before each gate; `windows:` and `linux:` byte-untouched -- separate jobs, no matrix, per repo convention.
- [x] `docs/wkwebview-macos-semantics.md` -- NEW: the measured record, mirroring `docs/webkitgtk-linux-semantics.md` -- measured facts, surprises and the constraints that are not obvious.
- [x] `_bmad-output/implementation-artifacts/spec-phase-7-cap7m0-macos-feasibility.md` -- carry the Checkpoint 1 report and the PASS/BLOCKED verdict in this artifact -- it is the canonical closure record, as CAP-7L's was.

Two files beyond the task list, each because a task on it could not be met
honestly without it:

- [x] `test/cap7m/uri_oracle.pas` + `uri_vectors.txt` -- M11 feeds the observed URL to `PWebParseAppUri`, which is Pascal, from a probe that is Objective-C++. Giving the probe a parser would fork the one validator; instead it serves an exact full-string allowlist, prints every URL verbatim, and this program renders every verdict through the shared routine.
- [x] `test/cap7m/cap7m_common.sh` -- the anti-Rosetta and `fpc -iTP` assertions are required of *every* gate; copied into seven scripts they would eventually differ in one.

**Acceptance Criteria:**
- Given the pinned revision and an explicit deployment target, when both macOS jobs run, then a real `WKWebView` opens on each native architecture and every probe A–L produces a recorded measurement rather than an inference.
- Given the measurements, when Checkpoint 1 is presented, then it names exactly one scheme-seam proposal, exactly one Objective-C bridge proposal, one proposed macOS floor, both runner labels with their observed `uname -m`, and one verdict — `CAP-7M0 PASS — MACOS FEASIBILITY LOCKED` or `CAP-7M0 BLOCKED`.
- Given this shard is merged, when the Windows and Linux jobs run, then every CAP-1…CAP-7L gate is still green and both freeze sweeps agree on the re-derived `src/lib` hash.
- Given Checkpoint 1 is reached, when the shard stops, then no production macOS adapter, packaging, signing or navigation-security code exists in the tree.

## Spec Change Log

- **2026-08-15 — the regeneration pipeline gained a Darwin platform-symbol
  translation.** The Code Map assumed enabling the two `[Platform.Mac*]`
  sections would produce a usable Darwin branch; it does not. Handled in the
  committed post-process, never in the generated unit — "Found while building
  the instrument", item 1.

## Design Notes

**The seam is the whole architectural question, and it is not the Linux one.** Upstream calls `objc::msg_send(get_class("WKWebViewConfiguration"), selector("new"))` at `cocoa_webkit.hh:450` and passes the result straight into `initWithFrame:configuration:` at `:486` — both inside `webview_create`. Apple's documented copy semantics for `WKWebView.configuration` mean the post-create route must be *measured and expected to fail* (M9), not assumed. The smallest seam that does not touch the ABI is therefore a PWeb-owned Objective-C class-method override installed **before** `webview_create`, using only the public Objective-C runtime and the public `setURLSchemeHandler:forURLScheme:`. Measure A first, propose B, escalate to C only with evidence.

**Secure origin — evidence exists, measurement still decides.** WebKit's `SecurityOrigin.cpp` `shouldTreatAsPotentiallyTrustworthy` returns true for `schemeIsHandledBySchemeHandler(protocol)` since commit `1985ef105c30` (2021-03-19, bug 223423, "Custom scheme handled origins should be considered secure"), first shipped in the Safari 15 / macOS 12 branch; WebKit's own live test asserts `secure` for a **non-localhost** custom-scheme host. That is why `pweb://app` is plausible where the `tauri://localhost` / `capacitor://localhost` generation needed the localhost host. It is code evidence, not a field measurement on macOS 15/26 — M15 must still print the object, and a `secure:false` result is a STOP, not a waiver.

**`WKURLSchemeTask` is exception-throwing, unlike GIO.** Apple documents an `NSException` for: a second response after completion, data before a response, finish before a response, finish/fail after either, and **any** callback after `stopURLSchemeTask:`. Nothing in the GLib model carries over. M13/M14 must establish the exact terminal-state guard PWeb will need, and prove no NSException escapes into a C++ or Pascal frame.

**Both freeze sweeps hash the same key.** `ci.yml:626` and `ci.yml:648` diff `src/lib` from two different baselines and compare both against `cap7l-binding-patch-sha256`. That only works while the two diffs are identical. Adding the Darwin branch keeps them identical, but the value must be re-derived with the same normalisation the steps use (strip trailing `\r`, join with `\n`, one trailing `\n`, UTF-8 no BOM).

**Cost and cadence.** The repo is private and `on: push` has no branch filter, so every push runs four jobs; standard macOS minutes bill at 10× the included-minute rate. Batch probe changes per push rather than iterating one gate at a time.

## Verification

**Commands:**
- `pwsh -NoProfile -File tools/regen-webview-binding.ps1` -- expected: regenerating twice is byte-identical; the platform block gains Darwin and nothing else changes.
- `tools/build-webview-dylib.sh` -- expected: dylib built for the requested arch only, cache asserts the Cocoa backend, install-name and `otool -L` recorded.
- `test/cap7m/check_webview_exports.sh` -- expected: exactly 17 `webview_*` symbols, identical set on both arches.
- `test/cap7m/check_abi.sh` -- expected: 36 facts each side, exactly 2 documented signedness deltas, 0 blocking.
- `test/cap7m/build_cap7m.sh && test/cap7m/run_cap7m_probes.sh` -- expected: every probe marker present; `uname -m` matches the job's architecture.
- `test/cap7m/check_release_layout.sh` -- expected: the `.app` runs from an unrelated CWD with no `DYLD_LIBRARY_PATH`.
- `test/cap7m/check_cap7m_nonetwork.sh` -- expected: no PWeb listener, no HTTP URL.
- The `windows:` and `linux:` jobs -- expected: unchanged and green, including both freeze sweeps.

**Manual checks (if no CLI):**
- `git diff 709bf0fe -- src/lib` and `git diff 4653ba77 -- src/lib` produce the same patch, and its normalised SHA256 equals the re-pinned `cap7l-binding-patch-sha256`.
- `git -C deps/webview status --porcelain` is empty on the macOS path.
- `git ls-files -s -- '*.sh'` shows mode `100755` for every new `test/cap7m/*.sh` and `tools/build-webview-dylib.sh`.

## Checkpoint 1

### VERDICT: WITHHELD — the instrument is complete, the measurement is not taken

The acceptance criterion begins *"Given the measurements"*. The dev host is
Windows, no macOS machine was in reach, and a shard whose purpose is to
replace inference with measurement cannot close on inference about itself.
What exists is the instrument — every gate, pin and marker, with the parts a
Windows host *can* execute already executed (below). What is missing is one
run of `macos-x64` and `macos-arm64`.

**The verdict becomes PASS** when both jobs are green: 17/17 exports in the
export trie on each arch, 36 ABI facts with exactly the two documented deltas,
`CAP7M_M10 precreate_seam_ran=1` in every cycle with `pweb://app/index.html`
served, `CAP7M_M7 … worker_distinct=1` and `CAP7M_M8 echoes=8 errors=1
outstanding=1` once per cycle, `"secure":true` in `CAP7M_REPORT`,
`caught_exceptions=0`, a determinate `CAP7M_M14 ownership=…`, zero URI leaks,
`CAP7M_M6_LEAK` growth within budget, and `CAP7M_M18` running from `/` with no
`DYLD_*` hint of any kind.

**The verdict becomes BLOCKED** on any of: `"secure":false` (M15 — reported
exactly, never waived); the pre-create seam never running or `pweb://app`
never being requested (M10 — which escalates to seam C, and the patch is not
written before ratification); an NSException reaching the C++ boundary (M13);
a URI the probe served that `PWebParseAppUri` rejects (M12); resident-size
growth past the M6 budget across cycles; or FPC 3.2.2 failing to link under
both pinned Xcode candidates on either arch.

**Three results are RECORDED, never gated**, because each is informative in
both directions and folding a measurement into a pass condition turns "we
learned something" into "the shard failed": `CAP7M_M9 seam_a_effective`
(whether the post-create route works — expected `no`), `CAP7M_M14 ownership`
(whether WebKit copies the body at handoff; "retains" is the answer that tells
CAP-7M its adapter must hold the source buffer alive), and `CAP7M_M13
abort_delivered`. M14 must still be *determinate* — the matrix says
undetermined ⇒ incomplete.

### The one scheme-seam proposal

**Seam B — a PWeb-owned pre-create override of `+[WKWebViewConfiguration
new]`**, added with `class_addMethod` on that class's own metaclass, doing
`[[cls alloc] init]` then the public `setURLSchemeHandler:forURLScheme:`
before returning. `deps/webview` stays pristine, the ABI does not change,
exports stay at 17.

Seam A is measured, not assumed: M9 installs a handler for its own `pwebpost`
scheme on what `webView.configuration` returns, compares that object's
identity against the configuration `webview_create` actually used, and has the
page report whether it is ever consulted. Seam C is not written and must not
be.

### The one Objective-C bridge proposal

**A linked Objective-C++ object: one `.mm` translation unit, compiled by clang
at build time, exposing a small C ABI to Pascal and linked into the FPC
executable.** Not FPC's native ObjC interop, and not a shipped dylib.

The deciding argument is M13, not taste. `WKURLSchemeTask` raises
`NSException` for five documented mistakes, and an `NSException` unwinding
into a Pascal frame is undefined behaviour, not an error path — so the
exception barrier must be an Objective-C frame, and `@try`/`@catch` cannot be
written in Pascal at all. Given that a `.mm` unit is mandatory anyway, FPC's
ObjC interop adds a second overlapping mechanism (and FPC 3.2.2 ships no
WebKit units for `WKWebView`/`WKURLSchemeHandler`), while a dylib adds a
shipped, signed, versioned artifact for a problem a linked object solves.

### The one proposed macOS floor

**12.0.** Justified by the only measurement that would make `pweb://app`
viable at all: WebKit treats custom-scheme-handled origins as potentially
trustworthy since commit `1985ef105c30` (bug 223423), first shipped in the
Safari 15 / macOS 12 branch. It also clears arm64's own 11.0 floor. Passed
explicitly on every compile and link (`CMAKE_OSX_DEPLOYMENT_TARGET`,
`-mmacosx-version-min`, FPC `-WM`) and read back out of `LC_BUILD_VERSION`, so
the SDK never decides it silently.

### The runner labels

| Job | Label | Expected `uname -m` | Observed |
|---|---|---|---|
| `macos-x64` | `macos-15-intel` | `x86_64` | *pending first run* |
| `macos-arm64` | `macos-15` | `arm64` | *pending first run* |

Asserted three times: at the job level (`CAP7M_EXPECT_ARCH`), in the recording
step, and inside every gate via `assert_native_arch`. The arm64 job also
refuses `sysctl.proc_translated = 1` — a Rosetta-hosted run reports `x86_64`
perfectly honestly and would otherwise be filed as x64 evidence.

### Ask-First items, all taken, none ratified

1. **The Darwin platform block.** Enabled and regenerated through the
   committed pipeline; `cap7l-binding-patch-sha256` re-derived to
   `255927608d7e6b1172211ddb8ce9e0057699ec117c6d0455c4c0c789d7d81988`,
   **verified identical from BOTH baselines** (`709bf0fe`, `4653ba77`) — the
   one property that keeps the two-sweep arrangement working. Not silently
   re-pinned: this line is the record of it.
2. **The scheme seam, the bridge strategy and the macOS floor** — one proposal
   each, above.
3. **New toolchain pins and a new lock file.** `fpc.lock` is new. The FPC
   artifact is pinned by sha256 `05d4510c…41ba8b7d` **measured from the
   downloaded bytes**, cross-checked against the md5 SourceForge publishes for
   the same file (`50babbde…3250d0`) and against its exact byte length. Xcode
   is an ordered candidate list `16.4 16.1`, with `16.3`/`16.2` recorded as
   `macos-xcode-known-bad` and excluded rather than kept as fallbacks.

## Implementation record

### Executed on the dev host (Windows), and passing

- `pwsh tools/regen-webview-binding.ps1` — run twice, byte-identical output.
  The diff to `src/lib` is six added lines in the platform block and four in
  `webview.chet`; nothing else moved.
- Both freeze sweeps re-derived with the exact normalisation `ci.yml` uses:
  `709bf0fe` and `4653ba77` produce the **same** patch hash, re-verified after
  every later edit.
- `pwsh test/core/check_binding_surface.ps1` — PASS, now including the new
  section 3b, which was **proven able to fail**: reintroducing
  `MACOS64`/`CPUARM64` into the generated unit produced three findings and
  exit 1, and regeneration restored PASS and the unchanged freeze hash.
- `ppcx64` compile of the binding and of `test/core/abi_probe.pas` for Win64
  (36 facts) — the Windows branch is unaffected by the Darwin branches.
- `uri_oracle.pas` compiled with FPC and run over all 44 vectors:
  **44/44 verdicts as ratified**, including the case-folding,
  default-document, single-decode, userinfo, port and double-encoding rows,
  and again over a CRLF copy of the file.
- The M11/M12 cross-check exercised end to end against a synthetic probe log
  and the real oracle, by **extracting the shipping code by line range rather
  than retyping it**. Five controls: clean run passes; header-only, truncated
  and one-wrong-expectation vector files each fail with a specific message;
  an injected `serve pweb://evil/x` is caught. The anchored URI parse was
  separately shown to keep the true verdict on a URL containing
  ` verdict=serve url=…`, and to reject a malformed line or an embedded tab
  rather than misparse it.
- `test/cap7m/summarize_cap7m.sh` rendered against fixture data, and against
  an empty tree (it runs under `if: always()`, so it must survive a job that
  measured nothing — it does, reporting each fact as `_not recorded_`).
- `bash -n` over all nine shell scripts; all three PowerShell scripts parsed;
  the zero-transport sweep and its new coverage assertion run locally;
  `ci.yml` parsed as YAML (4 jobs) and scanned with the Windows guard's own
  regex; `git diff --numstat` confirms `ci.yml` is **append-only** (414 added,
  0 removed), so `windows:` and `linux:` are byte-untouched.

### Found while building the instrument

1. **The generated Darwin branch would not have compiled** — Delphi symbols
   where FPC needs its own. Written up in
   `docs/wkwebview-macos-semantics.md`, "Six constraints", item 4.
2. **`WEBVIEW_API` becomes `inline` in a C++ translation unit** that declares
   neither `WEBVIEW_SHARED` nor `WEBVIEW_STATIC` (`macros.h:45-60`), so all 17
   prototypes would have been inline functions with no definition.
   `test/cap4w/CMakeLists.txt:33` already passes `-DWEBVIEW_SHARED` for
   exactly this reason; `build_cap7m.sh` now does too.
3. **`class_getClassMethod` would have swizzled `+new` process-wide** — the
   seam uses `class_addMethod` on the class's own metaclass and refuses to act
   on an inherited Method. Written up in the semantics doc, seam B.
4. **`webview_eval` is asynchronous.** Reading the injected global right after
   the binding's promise resolves is a race that passes on an idle runner and
   fails on a busy one. The page now waits for the injected code to say so,
   with a bounded fallback.
5. **Two portability bugs that only bite on macOS**, both caught by the dry
   run: BSD `sed` does not expand `\t` in a replacement (the observed-URI
   table would have been separated by a literal `t`), and `awk -v` expands
   escape sequences in its assignment (`pweb://app/a\b` arrived as
   `a<backspace>` and matched nothing). Now `awk` and `ENVIRON` respectively.
6. **A substring match over-reported the "vectors that reached the handler"
   record** — `pweb://` matched as a prefix of `pweb://evil/x`. Now an exact
   whole-line match against the URL column alone.

### Review round 1 — 30 findings, all applied

Grouped by what they were, since the fixes live in the files themselves:

- **Four gates could not run or could pass while measuring nothing.**
  `.gitignore:87` (`*.txt`) made `uri_vectors.txt` unaddable, so the first
  macOS run would have died on a missing gate input; the vector loop, the M8
  loop and both measurement uploads all passed vacuously on empty input. Every
  count is now asserted *before* the thing it counts is compared, against a
  ratified 44 for the vectors and against the cycle count for the per-cycle
  markers — the CAP-7L silent-skip defect, found in four new places.
- **Six measurements would have produced a wrong verdict rather than a
  missing one.** M14 and the abort were ANDed into the page's `ok`, so the
  *informative* answer ("WebKit keeps the pointer") would have aborted the
  shard; M9 was derived from a page-side boolean that is constant `false` by
  construction; the AbortController could never fire because `fetch` resolves
  at `didReceiveResponse`; the Rosetta guard sat on the arm64 job where it is
  unreachable instead of the x64 job it protects; the export gate read `nm
  -gU` (static table) instead of the export trie; and the fact-count equality
  used `grep -c .`, which ignores blank lines.
- **Five lifetime and hang defects.** The watchdog did not terminate on
  failure and had no deadline covering the shutdown itself; the `dispatch_after`
  block charged its exceptions to the *next* cycle's stack frame; the tracked-task
  set was never reset between cycles although task addresses are reused; and
  `strtol(req + 1, …)` read past the terminator on an empty `req`.
- **Eight toolchain and environment gaps.** `DEVELOPER_DIR` was never
  asserted, so a skipped selection step would have built under a possibly
  known-bad Xcode while the record said "runner default"; the pinned commit
  was never compared to the actual checkout; the deployment-target read-back
  lacked the `LC_VERSION_MIN_MACOSX` fallback on exactly the binaries most
  likely to need it; `record_environment` ran after three gates had already
  been believed and wrote only to stdout; the FPC version was hardcoded rather
  than read from `fpc.lock`; the residue guard checked one Delphi symbol of
  two; and the translation was enforced only by a dev-host script until
  `check_binding_surface.ps1` gained section 3b.
- **Seven correctness, cost and reporting improvements.** All three `DYLD_*`
  hints are now stripped in the negative half of M18; signing and quarantine
  facts are *recorded* (never performed); the sweep list is asserted to cover
  everything under `test/cap7m/`; the probe runs all cycles and aggregates
  instead of returning at the first failure; M6 gained the RSS leak bound the
  matrix always promised; and the two macOS jobs gained job-level
  `concurrency` and a `fpc.lock`-keyed cache for the 262 MiB disk image.
- **One claim was downgraded rather than fixed.** `id_ptr_reused` cannot
  support "proven copy-only": a `0` is indistinguishable from an allocator
  that simply did not reuse an address, and the only way to strengthen it
  would be to re-read a possibly-freed buffer on purpose. It is now recorded
  as evidence and never asserted on, and the wording in the semantics doc says
  exactly what is measured.

### Known risk

The `.mm` probe has never been compiled: no macOS host was available. Its
logic, markers and surrounding gates were verified as far as a Windows host
allows, but a clang diagnostic under `-Wall -Wextra -Werror` is the likeliest
first-run failure — cheap, but macOS minutes bill at 10x, so batch any fix
rather than iterating gate by gate.
