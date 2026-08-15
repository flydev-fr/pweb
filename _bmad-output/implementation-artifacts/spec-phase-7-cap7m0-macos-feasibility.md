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

**The verdict becomes PASS** when both jobs are green: the `webview_*` export
set is exactly the pinned 17 on each arch (the *total* is not equal across
arches — see below), 36 ABI facts with exactly the two documented deltas,
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

**MEASURED, run `31909938201`, and the result is stronger than Apple's
documentation sentence:** seam B ran on every cycle (`precreate_seam_ran=1`)
and served `pweb://app/index.html`, while seam A was accepted **without an
exception** (`postcreate_install_accepted=1`), compared as the **same**
configuration object (`configuration_is_same_object=1`), and was **never
consulted** (`postcreate_hits=0`). Seam A does not fail loudly — it fails
silently, which is the worst shape a wrong seam can have. (The identity term
carries a caveat: pointer equality cannot distinguish "same object" from
"fresh allocation at a freed address"; the load-bearing pair is
accepted-yet-never-consulted. Semantics doc, seam A.)

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

### The one proposed macOS floor — and its measured toolchain consequence

**12.0.** Justified by the only measurement that would make `pweb://app`
viable at all: WebKit treats custom-scheme-handled origins as potentially
trustworthy since commit `1985ef105c30` (bug 223423), first shipped in the
Safari 15 / macOS 12 branch. It also clears arm64's own 11.0 floor. Passed
explicitly on every compile and link (`CMAKE_OSX_DEPLOYMENT_TARGET`,
`-mmacosx-version-min`, FPC `-WM`) and read back out of `LC_BUILD_VERSION`, so
the SDK never decides it silently.

**RATIFY THIS TOO — the floor now has a linker flag attached to it.**
MEASURED, run `31904189177`: **FPC 3.2.2 cannot link on aarch64-darwin at a
deployment target of 12.0 or later** — `ld: pointer not aligned in
'FPC_THREADVARTABLES'+0x4`. Chained fixups (on for every macOS 12+ target)
need 8-byte-aligned pointer data on arm64; FPC 3.2.2 emits that RTL symbol
4-byte aligned. Unconditional, arm64-only, and unavoidable by Xcode choice.
Mechanism, sources and the non-conflation with Lazarus 41570 are in
`docs/wkwebview-macos-semantics.md`, constraint 7.

The decision to ratify, stated as a trade:

- **Taken — `-k-no_fixup_chains`, aarch64 link only.** Keeps `-WM12.0`, so
  `minos` stays 12.0 and the floor survives.
- **Refused — `-WM11.0`**, though it is the better-sourced fix for this exact
  error (MacPorts 68368): it contradicts the floor's own justification, since
  binaries would claim to run on macOS 11 where the secure-origin premise does
  not hold. A tidier build is not worth an unsound support claim.
- **Caveats that belong in the ratification, not a code comment:**
  `-no_fixup_chains` is an `ld_prime` flag with no guaranteed lifetime, and
  `-ld_classic` is *not* a fallback (deprecated Xcode 16, removed Xcode 27).
  If it goes, the answer is a newer FPC, not an older linker.

So the human choice is: accept a one-architecture toolchain workaround to keep
the 12.0 floor, or lower the floor and revisit the secure-origin premise.

### The runner labels

| Job | Label | Expected `uname -m` | Observed |
|---|---|---|---|
| `macos-x64` | `macos-15-intel` | `x86_64` | *pending first run* |
| `macos-arm64` | `macos-15` | `arm64` | *pending first run* |

Asserted three times: at the job level (`CAP7M_EXPECT_ARCH`), in the recording
step, and inside every gate via `assert_native_arch`. The arm64 job also
refuses `sysctl.proc_translated = 1` — a Rosetta-hosted run reports `x86_64`
perfectly honestly and would otherwise be filed as x64 evidence.

### A scope decision that needs ratifying: editing shared asset code

**This shard now edits `src/assets/pweb.assets.folder.pas`, which is shared
production code, not probe scaffolding.** Stating that plainly because it is
the one change here that a reasonable reviewer might place outside the
shard's boundary.

MEASURED, run `31908958453`: the isolation compile fails on Darwin because
FPC 3.2.2's Darwin BaseUnix declares neither `O_DIRECTORY` nor `O_NOFOLLOW`,
though its Linux BaseUnix declares both. Both call sites are confinement
code — a file passed as the asset root, and a symlink swapped in between the
walk and the open (semantics doc, constraint 10).

**Recommended — declare the two constants** (`{$ifdef DARWIN}`, in the
interface, no call site touched) and verify them every run against the
runner's `<fcntl.h>` with a zero-delta paired probe. It is a portability
constant block, not a macOS asset handler, so it reads as inside the shard's
"MAY add" list.

**The alternative — drop `pweb.assets.folder.pas` from M0's compile set** and
hand the whole question to CAP-7M. That keeps this shard's diff confined to
`test/cap7m/` and `tools/`, at a specific cost: CAP-7M would then begin with
an *unmeasured unknown in confinement-critical code* — precisely the class of
discovery-during-implementation this shard exists to prevent, and precisely
how CAP-7L's expensive surprises arose.

Recommending the constants for that reason. If the human prefers the
alternative, the revert is mechanical: remove the interface block and drop
the unit from `build_cap7m.sh`'s isolation list; the probe pair can stay,
since it measures the SDK either way.

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

By class; the fixes are in the files, and the ones with lasting design
consequences are written up in `docs/wkwebview-macos-semantics.md`:

- **Four gates could not run, or could pass while measuring nothing** —
  `.gitignore:87` (`*.txt`) made `uri_vectors.txt` unaddable; the vector loop,
  the M8 loop and both uploads passed vacuously on empty input. Every count is
  now asserted *before* the thing it counts is compared (ratified 44 for
  vectors, cycle count for per-cycle markers). The CAP-7L silent-skip defect,
  in four new places.
- **Six wrong verdicts rather than missing ones** — M14 and the abort were
  ANDed into `out.ok`, so the *informative* answer would have aborted the
  shard; M9 came from a page-side boolean that is constant `false`; the abort
  could never fire because `fetch` resolves at `didReceiveResponse`; the
  Rosetta guard sat on the arm64 job where it is unreachable; the export gate
  read the static symbol table; the fact-count equality ignored blank lines.
- **Five lifetime/hang defects** — no terminate on failure and no deadline on
  the shutdown itself; the `dispatch_after` block charged exceptions to the
  next cycle's frame; the task set was never reset though addresses are
  reused; `strtol(req + 1, …)` overran an empty `req`.
- **Eight toolchain/environment gaps** — `DEVELOPER_DIR` unasserted; the pin
  never compared to the checkout; no `LC_VERSION_MIN_MACOSX` fallback; the
  environment recorded after three gates had been believed, to stdout only;
  the FPC version hardcoded instead of read from `fpc.lock`; one Delphi
  residue symbol of two checked; the translation enforced only on the dev host
  until `check_binding_surface.ps1` gained section 3b.
- **Seven correctness/cost/reporting** — all three `DYLD_*` stripped in M18's
  negative half; signing and quarantine facts recorded (never performed);
  sweep coverage asserted over `test/cap7m/`; all cycles run and aggregate;
  M6 gained the RSS leak bound the matrix always promised; job-level
  `concurrency` and a `fpc.lock`-keyed cache for the 262 MiB image.
- **One claim downgraded rather than fixed** — `id_ptr_reused` cannot support
  "proven copy-only" (a `0` is indistinguishable from an allocator that did
  not reuse an address, and strengthening it means re-reading a possibly-freed
  buffer on purpose). Recorded as evidence, never asserted on.

### Round 2 — first hosted run (`31904189177`), two measured findings

The dylib built on **both** architectures and produced `measurements.txt`.
Both findings are real facts about the platform, not script defects, and both
are written up in the semantics doc (constraints 7 and 8):

1. **The export surface differs between architectures** — arm64 exports 17,
   x86_64 exports 25. The eight extras are libc++ `_ZTI…`/`_ZTS…` typeinfo
   records for upstream's `std::function` instantiations; they are weak,
   carry no code and cannot be invoked. The gate now asserts what the contract
   actually says — the `webview_*` set is exactly 17 on both arches, every
   other export is `^_ZT[IS]`, and the full list is recorded per arch as
   `CAP7M_EXPORTS`. **No compiler flag was added to make the count match**:
   `-fvisibility=hidden` would change how the pinned upstream is built,
   diverge from Windows and Linux, and hide a measured fact.
2. **FPC 3.2.2 cannot link on aarch64 at the 12.0 floor** — chained fixups
   versus `FPC_THREADVARTABLES` alignment. Fixed with `-k-no_fixup_chains` on
   the aarch64 link only, which preserves the floor; `-WM11.0` was refused
   because it would contradict the floor's own justification. This is a
   Checkpoint 1 ratification item, above, not an implementation detail.

### Round 3 — run `31905105454`: Pascal links and runs on both arches

Both round-2 fixes worked. The chained-fixups mitigation is now **MEASURED,
not predicted**, the contract-based export gate passes on both arches, and
**M4 passes on both**: 36 facts, exactly the two documented signedness deltas,
the same pair Linux permits — clang types the enums the way gcc does.

One further platform difference, identical on both arches: **a Mach-O load
command records USE, where ELF's `DT_NEEDED` records LINKAGE.** `abi_probe`
deliberately references nothing, so on Darwin it correctly carries no
`LC_LOAD_DYLIB`, and the gate was asserting a Linux property that does not
exist here — CAP-7L's write-up of `DT_NEEDED = libwebview.so.0.12`, measured
off that very probe, does not transfer. Constraint 9 in the semantics doc,
cross-referenced to CAP-7L's paragraph.

The three obligations were separated rather than merged:

- the absence is **recorded** (`CAP7M_M5 binary=abi_probe references_dylib=no`),
  not asserted, and neither `abi_probe.pas` nor `abi_probe.c` was touched —
  that pair is the pinned CAP-1 probe, and making it call in to satisfy a gate
  would change what it measures. No `-needed_library` either: forcing a load
  command onto a binary that references nothing fabricates the measurement.
- **M5 is satisfied by `dlopen` + `dlsym`**, the stronger proof and the one
  the gate's name already promised. Asserted from both sides: the bare name
  must resolve, the trie spelling `_webview_create` must not.
- **The load command is asserted on `cap7m_probe`**, which really calls in and
  whose `@rpath/libwebview.0.12.dylib` PROBE K depends on. Any binary carrying
  one must name that path; `signature_pin` (17 addresses taken, none called)
  and `uri_oracle` are recorded either way — checked against the source.

### Round 4 — human review: these scripts stop deleting

The objection was not that the `rm -rf` calls were unguarded; it was that the
scripts delete **at all**. A CI runner checks out fresh, so the wipe bought
nothing there — it only ever served repeated local runs, and it paid for that
convenience with a recursive delete on the default path of a file CI executes
as a program.

**The default path now deletes nothing.** `cap7m_prepare_dir` creates an
absent directory, uses an empty one, and REFUSES a non-empty one — naming it
and saying to pass `--clean` or remove it. A stale tree is a loud refusal
instead of a choice between a silently stale measurement and a destructive
cleanup. `--clean` is opt-in per invocation, accepted by
`tools/build-webview-dylib.sh`, `build_cap7m.sh`, `check_abi.sh` and
`run_cap7m_probes.sh`, and is the only route to a removal — which then still
goes through `cap7m_rm_tree`. The CI jobs call every gate WITHOUT it, with a
comment at each of the eight call sites saying why.

`cap7m_rm_tree` survives unchanged as the last line of defence, for `--clean`
and for the one deletion that remains on a default path: the `mktemp`
staging trap in `check_release_layout.sh`, which removes a directory it
created itself in `TMPDIR` and would otherwise leak a bundle per run. That
one passes its allowed root explicitly, initialises `staging=''` before the
trap is installed, and calls the guard in a subshell so a refusal warns
rather than replacing the script's exit status.

`tools/build-webview-dylib.sh` carries both functions as a self-contained
copy: a build tool sourcing a file under `test/` would invert the dependency.

**Verified — 21 controls against both copies, 21/21 each.** Every path handed
to the functions lived inside a `mktemp -d` sandbox; `${repo_root}` was
pointed at a sandbox subdirectory so even the DEFAULT allowed root could not
name anything real, and the repository root was never an input. `die` was
defined exactly as the scripts define it — printf to stderr, then `exit 1`.

Refusals: empty target, `/`, the fake repo root, the allowed root bare and
slash-suffixed, `..` escaping and `..` inside, `.` basename, unresolvable
parent, explicitly empty allowed root, and the `buildkit`-vs-`build` prefix
trap. Allowances: a legitimate subdirectory, a `report..old` filename, a
not-yet-existing target. For `cap7m_prepare_dir`: absent creates, empty
proceeds, non-empty refuses **with its content verified still present
afterwards**, a file where a directory belongs refuses, an empty argument
refuses, `--clean` empties it, and `--clean` still cannot escape the allowed
root (its content verified untouched). The `--clean` flag parser was checked
separately over seven argument shapes, including one containing a space.

The same pre-existing shape in `tools/build-webview-so.sh` and five
`test/cap7l/*.sh` scripts is out of scope — ledgered in `deferred-work.md`
with all seven line numbers and with the assert-empty-unless-`--clean` design
named as the pattern to lift.

### Round 5 — run `31908958453`: M4/M5 pass, the frontier moves to M17

M4 and M5 now pass on both arches. The next failure was **not** the `.mm`
probe but the Pascal isolation compile: `O_DIRECTORY` and `O_NOFOLLOW` are
undeclared by FPC 3.2.2's Darwin BaseUnix although its Linux BaseUnix
declares both, so the POSIX branch CAP-7L hardened does not compile on
Darwin. Written up as constraint 10; the scope question it raises is above,
under "A scope decision that needs ratifying".

The constants were declared rather than the branch weakened, and the values
are **verified, not transcribed**: `test/cap7m/abi_probe_fcntl.c` prints what
`<fcntl.h>` defines on the runner, `abi_probe_fcntl.pas` prints what the unit
declares, and `check_abi.sh` diffs them with zero permitted deltas. The
asymmetry is the point — a wrong `O_DIRECTORY` stops the store constructing,
while a wrong `O_NOFOLLOW` quietly stops refusing symlinks with every test
still green.

The initial values come from Apple's published `xnu` `bsd/sys/fcntl.h`
(`O_NOFOLLOW 0x00000100`, `O_DIRECTORY 0x00100000`), not from recollection —
and the probe is what makes that provenance irrelevant from the first run
onward, since a disagreement with the actual SDK blocks.

### Round 6 — run `31909456486`: the link line, and a hypothesis that did not hold

`pweb.assets.folder.pas` compiles on Darwin; the frontier moved to the
`signature_pin` **link**. All 17 symbols undefined — `signature_pin` takes
every entry point's address, where `abi_probe` references none and linked
cleanly. The same asymmetry as constraint 9, seen from the other side.

Fixed by passing `-k-L<dist> -k-lwebview` to every FPC binary that references
a webview symbol, mirroring the clang line that already worked for the
ObjC++ probe. The message was also split: a LINK failure now says the library
did not reach the linker, because "binding signatures drifted" is the one
thing that failure did not mean.

**The proposed mechanism did not survive checking, and I did not adopt it.**
The reasoning offered was that FPC emits no `-l` for `external` on Mach-O.
FPC 3.2.2's own source says otherwise: `t_bsd.pas:355-369` emits `-l<lib>`
from `SharedLibFiles`, `:132` puts Darwin on the direct-command-line path,
and `t_linux.pas:565-576` is the **same code** on the platform that works.
The observed `symbol(s) not found` (rather than `library not found for -l…`)
also rules out a wrongly-spelled `-l`. The live candidate is that
`SharedLibFiles` is empty for this build; why, is open.

So the fix ships and the mechanism is recorded rather than asserted:
`build_cap7m.sh` now runs one `fpc -va` link with the explicit flags
**withheld** and records what FPC passed unaided as `CAP7M_LINKLINE`. The
doc marks the failure MEASURED and the mechanism EXPECTED.

One consequence worth stating because it was not obvious: linking
`abi_probe` with the explicit `-l` too — for consistency, so the two stop
differing by accident — means a load command appearing on it is no longer
evidence about how `external` binds. `CAP7M_LINKLINE` is now the instrument
that keeps constraint 9's mechanism observable, and the M5 record says
`linked_with_explicit_l=yes` so no later reader misreads it.

### Round 7 — run `31909938201`: the probe ran, and M0's question is answered

`cap7m_probe.mm` compiled, linked and **ran against a real WKWebView on both
architectures**. Nearly everything the shard set out to measure came back:

| | Measured |
|---|---|
| M15 secure origin | `{"protocol":"pweb:","host":"app","origin":"pweb://app","secure":true}` |
| M10 / M9 seam | B ran every cycle; A accepted, same object, **never consulted** |
| M7 / M8 threading | `gui_affine=1 worker_distinct=1 direct_return=1`; `echoes=8 errors=1 outstanding=1` |
| M13 lifecycle | `stops=1 caught_exceptions=0 poststop_throws=1 abort_delivered=1` |
| M14 ownership | `handoff=original-bytes` — WebKit copies at handoff |
| M6 leak | `growth_kb=352` against a `65536` budget |
| M11 / M12 | every hostile vector refused; 6 served / 9 refused per cycle |
| M6 shutdown | both shapes clean |

**One assertion failed, and it was a real finding rather than a probe bug.**
`fetch('pweb://app/probe.css')` reported `ok: false` even though the handler
served it and `css:true` proved the stylesheet applied. Cause: the handler
replied with a bare `NSURLResponse`, which carries no status code, so
`fetch()` sees `status: 0`. Fixed by replying with `NSHTTPURLResponse`
(200, HTTP/1.1, `Content-Type` + `Content-Length`) for served assets; the
refusal path stays `didFailWithError:`, which is the measured Darwin refusal
shape. Written up as constraint 12, with a three-platform status table —
the refusal story is the same everywhere, the SERVING story differs on all
three — and with the consequence that CAP-12's blob plane needs it harder,
since `Range` (206/416/`Content-Range`) has nowhere to live without a status.

A trap worth recording from the fix itself: `Content-Length` must be OMITTED,
not merely wrong, on a response whose body stays open. The M13 cancellation
case declares no length — a declared length never delivered makes `fetch()`
reject on a truncated body and report `aborted` whether or not the abort
arrived, which would have turned a working measurement into a tautology.

M14's result licenses a simplification for CAP-7M (no need to keep the source
buffer alive until `didFinish`) but the poisoned-buffer case should be kept
as a regression rather than relied on: it is one measurement, on one
OS/toolchain pair, of an API that documents no such contract, and the failure
mode if it ever changes is silent corruption of served assets.

### Known risk

The `.mm` probe still has not compiled — run `31904189177` stopped at the
Pascal link, upstream of it. A clang diagnostic under `-Wall -Wextra -Werror`
remains the likeliest next failure, and round 1 added roughly 150 lines of
Objective-C++. macOS minutes bill at 10x, so batch fixes rather than iterating
gate by gate.
