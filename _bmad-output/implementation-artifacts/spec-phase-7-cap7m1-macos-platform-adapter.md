---
title: 'CAP-7M1 — production macOS platform adapter: the measured M0 architecture as a private Cocoa/WKWebView adapter'
type: 'feature'
created: '2026-08-16'
status: 'done'
review_loop_iteration: 0
context: []
baseline_commit: '529f01794fa67e339c38d1fc85c30fc7c6ae0f56'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-7M0 closed with every macOS architectural question **measured** (run `31912129480`: both native arches green) and **nothing production built**. There is no `src/platform/macos/`, no Objective-C++ bridge, no Cocoa adapter, no macOS test case in the suite, and no gate that runs PWeb's own code against a real `WKWebView`. Two blockers sit under that, and only one was visible to M0. First, **`TFolderAssetStore` cannot construct on Darwin at all**: the POSIX branch re-proves confinement by reading `/proc/self/fd/<n>` (`src/assets/pweb.assets.folder.pas:348,355`), macOS has no `/proc`, so `FinalPathOfFd` returns `''` and the constructor raises at `:405-407`. M0 only ever *compiled* that unit — it never constructed a store — so the whole POSIX confinement branch CAP-7L hardened is, today, dead on macOS. Second, every macOS compile and link decision is written **inline at its call site**: `-WM` at 12 sites, `-mmacosx-version-min` at 4, `-arch` at 4, `-Fl`/`-k-L`/`-k-lwebview`/`-k-rpath`/`-framework` each at 2-4 more, with exactly one flag (`-k-no_fixup_chains`) centralized. An adapter added on top of that inherits twenty places for the deployment target to drift.

**Approach:** Promote the exact M0-measured pre-create seam into the smallest production Objective-C++ bridge — one linked `.mm` object exposing a flat private C seam, no second dylib, no ABI change — and a private Pascal adapter under `src/platform/macos/` that reaches `IAssetStore` through the same `PWebParseAppUri` the other two platforms use. Give `FinalPathOfFd` a Darwin body built on `fcntl(F_GETPATH)`, the direct counterpart of `/proc/self/fd` and of Windows' `GetFinalPathNameByHandleW`, leaving every call site and the confinement algorithm byte-identical. Collapse every macOS build decision into one sourced helper. Then prove the whole path — real `WKWebView` → `pweb://app` → production handler → `IAssetStore` → folder **and** ZIP → JS binding → scheduler worker → mORMot → 42 — on `x86_64` and `arm64` separately, with the frozen threading proof, the complete hostile-URI matrix and real symlink confinement tests re-run against the production code rather than a probe.

## Boundaries & Constraints

**Always:**
- **The measured M0 architecture is the design.** Seam B (pre-create override of `+[WKWebViewConfiguration new]` on that class's own metaclass, via `class_addMethod`), `NSHTTPURLResponse` for served assets, `didFailWithError:` for every refusal, claim-once terminal-state guarding, `-k-no_fixup_chains` on aarch64 links only, `@rpath/libwebview.0.12.dylib` + an application-supplied `@executable_path` rpath. Reopen none of it without contradictory **runtime** evidence.
- **The pinned revision, unmodified.** `deps/webview` stays pristine on the macOS path; the CAP-4W patch is Windows-only. Exactly **17** `webview_*` exports on both architectures; the only other permitted exports are the M0-measured weak `^_ZT[IS]` C++ RTTI records (8 on x86_64, 0 on arm64). No 18th export, ever.
- **One binding declaration surface.** The 17 declarations stay single-source in `src/lib/pweb.lib.webview.pas`, generator-produced. A second macOS copy is forbidden. The bridge's private C seam is **not** a webview ABI extension and never names a `webview_*` symbol.
- **The whole URI, always.** Every request feeds `[[task request] URL] absoluteString` — the complete absolute URL — to `PWebParseAppUri`. No path accessor, no last component, no filesystem path is ever built in the adapter. Wrong authority never reaches `IAssetStore`, and a counting store proves it.
- **No exception crosses a boundary, in either direction.** No Pascal exception leaves the resolve callback; no Objective-C exception leaves the private C seam. Refusals are one constant outcome with no reason attached and no native text.
- **The bridge never holds a raw Pascal object pointer.** Ownership crosses as a 64-bit generation-checked handle resolved through a Pascal-side registry, so a stale handle is *unresolvable* rather than dangling.
- **Native architectures, never Rosetta.** Every gate asserts `uname -m`, `sysctl.proc_translated`, `hw.optional.arm64` and `fpc -iTP` before it accepts a result.
- **The deployment target is passed, never inherited.** `12.0` on every compile and every link, read back out of `LC_BUILD_VERSION` on every produced Mach-O together with its architecture.
- **Every macOS build decision lives in exactly one file.** Adding a second place for the deployment target, the arch, the rpath, the frameworks or the library flags is the defect this shard exists to remove.
- **Windows and Linux stay green.** The POSIX folder-store change must be a Darwin-only branch with byte-identical Linux behaviour; the frozen contracts, the scheduler, the bridge, the wire and `app.pwb` are untouched.

**Ask First:**
- **The Darwin `F_GETPATH` branch in `src/assets/pweb.assets.folder.pas`.** M0 ratified two Darwin *constants*; this adds a hand-declared `fcntl` external and a new constant to shared production security code. Unavoidable — without it the folder store cannot construct on macOS and acceptance item 9 is unreachable — but it is a shared-code delta and is ratified at Checkpoint 1, not assumed.
- **Editing the `windows:` job.** Renaming the lock key rewrites the exact freeze-sweep steps whose byte-stability CAP-7M0's acceptance asserted. Taking the ledgered `[ -f ]` existence precondition for the floating-ref guards in the same edit is proposed with it.
- **The synchronous-handler consequence.** A handler that serves entirely inside `startURLSchemeTask:` on the main thread makes most of the documented races *structurally impossible* rather than merely tested. If chunked or deferred delivery is wanted (CAP-12's `Range` plane will need it), that is a different design and is not invented here.
- **Any new pinned toolchain artifact, lock key or lock file.**

**Never:** release `.app` packaging, signing, notarization or auto-update; React/Pas2JS macOS acceptance applications; touching `examples/`; CAP-8 navigation security, CAP-10 CLI, CAP-11 matrix, CAP-12 blobs; an 18th public export; a second Pascal ABI declaration set; a second shipped dylib; a patch to upstream webview; private/undocumented WebKit SPI; any HTTP, localhost, `file:`, `data:` or `blob:` fallback; a macOS-specific URI canonicalization rule; a macOS-specific scheduler or invocation bridge; changes to `IWebView`, `IWebViewBinding`, `IInvocationBridge`, `IInvocationScheduler`, `IAssetStore`, `IBlobStore`, `ICapabilityPolicy`, the wire, the error taxonomy or `app.pwb`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| P1 seam runs | adapter armed, then `webview_create` | seam invocation count strictly increased; `Attach` accepts | count unchanged ⇒ raise at `Attach`, never a silent no-op |
| P2 seam-A refusal | handler installed post-create on `webView.configuration` | still never consulted (M0 `postcreate_hits=0`) | production must not use it; asserted by absence of any post-create install |
| P3 main document | `pweb://app/index.html` | `NSHTTPURLResponse` 200, exact bytes, deterministic `Content-Type`, `Content-Length` | store miss ⇒ `didFailWithError:` |
| P4 root mapping | `pweb://app` and `pweb://app/` | `index.html`, mapped in the URI layer only | — |
| P5 subresource status | page `fetch('pweb://app/probe.css')` | `r.ok === true`, `r.status === 200` | bare `NSURLResponse` ⇒ status 0 ⇒ gate fails |
| P6 zero-byte asset | asset of length 0 | 200, `Content-Length: 0`, empty body, `fetch` resolves | never a NULL-pointer `NSData` |
| P7 NUL/binary asset | 4096 bytes covering every byte value | bytes delivered byte-identically | any truncation blocks |
| P8 wrong authority | `pweb://evil/x`, `pweb:///x` | refused; **counting store records zero `TryRead` calls** | one call ⇒ blocker |
| P9 hostile paths | `..`, `%2e%2e`, `%252e%252e`, `a\b`, `a%00b`, `a%zz`, `a%25b`, `user@app`, `app:8080`, trailing `.`, wrong case | every one refused by `PWebParseAppUri` | a served URI the routine rejects ⇒ blocker |
| P10 query/fragment | `pweb://app/index.html?x=1#y` | cut before decode; serves `index.html` | — |
| P11 missing asset | `pweb://app/missing.txt` | `didFailWithError:` — indistinguishable from every other refusal | no reason text, no path ever reaches the page |
| P12 double terminal | two completion attempts on one task | second suppressed by the claim gate; counter records the suppression | any `NSException` reaching the C seam ⇒ blocker |
| P13 post-stop callback | callback attempted after `stopURLSchemeTask:` | suppressed before the call is made | never suppressed only by `@catch` |
| P14 idempotent cancel | `stopURLSchemeTask:` twice for one task | second is a no-op | — |
| P15 disowned handler | task arrives after `Detach` | refused; **no callback reaches Pascal**; handle unresolvable | resolving a released handle ⇒ blocker |
| P16 teardown with tasks live | `Detach` while the live-task set is non-empty | every live task claimed and failed; set empty afterwards; GUI thread never blocks | leaked registry entry ⇒ blocker |
| P17 secure origin | JS on `pweb://app/index.html` | `{protocol:"pweb:", host:"app", origin:"pweb://app", secure:true}` **stated by the page** | `secure:false` ⇒ blocker, never waived |
| P18 threading | `__pweb_invoke` round trip | bind callback on the GUI thread; service on a distinct worker; worker's **direct** `webview_return` resolves | any WebKit/AppKit call from a worker ⇒ blocker |
| P19 RPC | `CalculatorService.Add({a:20,b:22})` | `42`, over folder **and** ZIP, on **both** arches | — |
| P20 concurrency | 8 concurrent invocations + 1 forced error + 1 outstanding at shutdown | each completes exactly once; error rejects with payload intact; teardown drains | double completion or UAF ⇒ blocker |
| P21 folder confinement | symlinked dir segment, symlinked final file, case variants, glob metacharacters, dir-as-asset, file-as-dir | every one refused; nested asset and root document still served | one escape ⇒ blocker |
| P22 unrelated CWD | store rooted at an absolute path, process CWD `/` | identical verdicts | any CWD dependence ⇒ blocker |
| P23 lifecycle | repeated create → install → load → bind → 42 → terminate **or** window close → destroy | both shutdown shapes clean; RSS growth within the M0 budget | crash, hang or runaway growth ⇒ blocker |
| P24 linkage | `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH` all unset, CWD `/` | resolves through `@executable_path`; missing dylib is a deterministic non-zero abort naming the dylib | resolution via any `DYLD_*` ⇒ blocker |
| P25 Mach-O shape | every Pascal and ObjC++ output | `arch` == the job's arch, `minos` == 12.0 | either wrong ⇒ blocker |
| P26 lock key | `webview.lock` | new key present; **old key absent**; both freeze sweeps agree from both baselines | old key present anywhere ⇒ gate fails |

</frozen-after-approval>

## Code Map

**Reusable verbatim — do not fork, do not reimplement.**
- `src/assets/pweb.assets.support.pas:80-81` `PWebParseAppUri` — the *only* authority/path verdict; plus `:54`, `:60`, `:41`, `:43`. Portable, no `{$ifdef}`.
- `src/assets/pweb.assets.intf.pas:39-42,84-86`; `src/rpc/*`, `src/webview/*`, `src/security/pweb.capabilities.pas` — byte-frozen by `ci.yml:622,668`. Read-only.
- `src/lib/pweb.lib.webview.pas:17-33` — the four-branch platform block; both Darwin arms map to `libwebview.dylib`, `_PU = ''`. Generator-produced only.
- `test/cap7m/cap7m_probe.mm` — **kept and kept running** as the platform-fact regression (`poststop_throws`, `abort_delivered`, `handoff`, `seam_a_effective`). Production must not depend on those answers; a silent change to them must still fail a gate.
- `test/cap7m/uri_oracle.pas` + `uri_vectors.txt` (44 vectors, `<expect> <uri>`, count pinned at `run_cap7m_probes.sh:256`) — reused unchanged by the production runtime gate.
- `test/cap7m/cap7m_common.sh` — `assert_native_arch` `:211`, `assert_fpc_target` `:244`, `record_environment` `:336`, `cap7m_prepare_dir` `:67`, `cap7m_rm_tree` `:132`, lock readers `:183`.

**Structural models to mirror (shape, not mechanism).**
- `src/platform/linux/pweb.platform.webkitgtk.pas` — the adapter shape: one shared request-decision function in the interface (`:147`, `:153`), disown-on-detach via an interlocked store (`:661-680`), constant refusal, exception barrier in the callback (`:507-574`). `src/platform/windows/pweb.platform.webview2.pas:432-529` for `Create`/`Detach`/`Destroy` ordering and borrowed-vs-owned.
- `examples/06-assets/assetsapp.pas:159-261` — the complete production wiring the harness reproduces (mORMot server → `TMormotInvocationBridge` → `TInvocationScheduler` → `RegisterSource` → `TWebViewBinding` → `Bind('__pweb_invoke', TPWebEnvelopeHandler…)`) and `:262-319` the teardown order (binding `Close` → scheduler `Shutdown` → handler `Detach` → `webview_destroy`). `frontend/dist/assets/app.js` is the verdict-page pattern; **`examples/` is read-only for this shard**.
- `test/cap7l/run_cap7l_gates.sh:65-148` — the POSIX confinement gate: real `ln -s` for a symlinked directory (`:77`) and file (`:78`), a heredoc'd probe with 12 assertions (`:112-131`) including the fnmatch-metacharacter cases. Direct mirror target; **no macOS equivalent exists**.
- `test/core/pwebtests.pas:17-42,44-62,124-135` — the `{$ifdef LINUX} AddCase([...])` registration precedent. The gate greps the humanised published-method name, so name the Darwin method for the marker.
- `test/cap7m/build_cap7m.sh:235-242` — the clang++ line the bridge compile mirrors (`-std=c++17 -fno-objc-arc -Wall -Wextra -Werror -DWEBVIEW_SHARED`, Cocoa + WebKit).

**Needs work — the shard's real surface.**
- `src/assets/pweb.assets.folder.pas:346-359` — `PWEB_PROC_SELF_FD` + `FinalPathOfFd`, **unguarded**. Darwin body needed. The `{$ifdef DARWIN}` interface block already exists at `:51-83` (`O_DIRECTORY`, `O_NOFOLLOW`) and is where `F_GETPATH` and the path-buffer bound join it. Call sites `:401` (constructor) and `:484` (open-descriptor re-proof) must not change. The single POSIX/Windows split is `:118`/`:318`/`:545`; there is no Darwin branch in the implementation today.
- `test/assets/pweb.test.assets.pas:382` — `Setup` constructs `TFolderAssetStore` and therefore *raises on Darwin*, taking `TTestAssetStores` down before any assertion. Fixing `FinalPathOfFd` unblocks the existing 10 published tests on macOS. The suite has **no** symlink fixture anywhere (`:387-399` is a Windows `mklink /J` junction; `RootConfinement` early-exits off Windows at `:809-810`), no unrelated-CWD case, and no final-component-symlink case — those are new and belong in the macOS gate, mirroring CAP-7L.
- `webview.lock:74` `cap7l-binding-patch-sha256 = 255927608d7e6b1172211ddb8ce9e0057699ec117c6d0455c4c0c789d7d81988` — read literally by `ci.yml:647-651` and `:682-686`. Ledgered as a misnomer in `deferred-work.md:103-105`; rename target ratified as `srclib-platform-patch-sha256`. **The value is preserved** — the patch does not change, only the key naming it.
- `.github/workflows/ci.yml` (2105) — `windows:` 57, `linux:` 1440, `macos-x64:` 1709, `macos-arm64:` 1932. The floating-ref guard file lists at `:1742-1748` and `:1952-1958` must gain every new script; `:140-167` (windows) and `:1466-1471` (linux) still lack the `[ -f ]` precondition (`deferred-work.md:100-102`). `:1483-1489` asserts **every** committed `*.sh` is index mode `100755`. `.gitignore:87` ignores `*.txt`.
- **Flag inventory to collapse.** Every macOS flag except one is written inline, all of it in two files: `test/cap7m/build_cap7m.sh` (`-WM` ×10, `-arch`, `-mmacosx-version-min`, `-Fl` ×4, `-k-L`, `-k-lwebview`, `-k-rpath`, `-k@executable_path` ×3, and the only `-framework`/`-Wl,-rpath`/`-L`/`-lwebview` in the tree, at `:237-241`) and `test/cap7m/check_abi.sh` (`-WM` ×2 at `:103,231`; `-arch`/`-mmacosx-version-min` ×3 at `:84,219,339`; the link set at `:104-106`). Plus `CMAKE_OSX_ARCHITECTURES`/`CMAKE_OSX_DEPLOYMENT_TARGET` at `build-webview-dylib.sh:306-307`. Only `-k-no_fixup_chains` is centralized (`cap7m_common.sh:313-328`). `deployment_target` is fetched independently four times, `host_arch` three, and the arch→mORMot-static-dir map exists twice (`build_cap7m.sh:58-62`, `cap7m_common.sh:255-259`). `tools/build-webview-dylib.sh:63-185` deliberately duplicates the helper functions so a build tool does not depend on `test/` — the new helper therefore lives under `tools/`, preserving that direction.

**Measured facts carried in (run `31912129480`, all four jobs green; do not rediscover).** macOS 15.7.7, Xcode 16.4, SDK 15.5, Apple clang 17.0.0, FPC 3.2.2 on both Darwin targets. Exports: arm64 `17/17/other=0`, x86_64 `25/17/other=8` (all `^_ZT[IS]`). `minos=12.0` everywhere; `install_name=@rpath/libwebview.0.12.dylib`; `LC_RPATH=@executable_path`; `O_RDONLY=0 O_NOFOLLOW=256 O_DIRECTORY=1048576`; `fpc_emits_l_webview=no`, so the explicit `-k-L`/`-k-lwebview` is load-bearing; missing dylib ⇒ `exit 134`. `configuration_is_same_object` came back `1,1,0` across three cycles — pointer identity is unreliable exactly as the semantics doc warns, and only `postcreate_hits=0` is load-bearing.

## Tasks & Acceptance

**Execution:**
- [x] `_bmad-output/implementation-artifacts/spec-phase-7-cap7m0-macos-feasibility.md` -- record the CAP-7M0 PASS verdict against run `31912129480` and set `status: done` -- M1 rests on M0's measurements and must not rest on an artifact that says WITHHELD. **DONE before dispatch (commit `docs(cap-7m0)`); do not redo.**
- [x] `webview.lock` -- rename `cap7l-binding-patch-sha256` to `srclib-platform-patch-sha256`, value byte-preserved, comment updated -- the key named one platform for a patch that now carries three.
- [x] `.github/workflows/ci.yml` -- point both freeze sweeps at the new key, add a gate that FAILS if the old key still appears in `webview.lock`, and take the ledgered `[ -f ]` existence precondition for the `windows:` and `linux:` floating-ref guards -- a rename with no rejection gate leaves the old name working by accident.
- [x] `tools/macos-buildenv.sh` -- NEW: the single source for the deployment target, the native arch, the mORMot static dir, the clang flags, the FPC compile and link flags (including `-k-no_fixup_chains`, the frameworks, the rpath, `-k-L`/`-k-lwebview` and the bridge object), and `pweb_macos_assert_macho` -- one place for every decision, or the deployment target drifts across twenty.
- [x] `test/cap7m/cap7m_common.sh`, `test/cap7m/build_cap7m.sh`, `test/cap7m/check_abi.sh`, `tools/build-webview-dylib.sh` -- consume the helper and delete every inline flag, the duplicated arch mapping and the duplicated static-dir mapping -- the centralization is only real once nothing else writes a flag.
- [x] `src/platform/macos/pweb_cocoa_bridge.h` -- NEW: the flat private C seam (asset struct, resolve callback typedef, install/create/arm/disown/release/stats). No WebKit or Objective-C type crosses it.
- [x] `src/platform/macos/pweb_cocoa_bridge.mm` -- NEW: the pre-create `+[WKWebViewConfiguration new]` override on that class's own metaclass, the `WKURLSchemeHandler`, the explicit New/Serving/Completed/Cancelled task state machine with claim-once terminals, the autorelease-pool discipline and the `@try/@catch` barrier at every seam entry -- the exception barrier must be an Objective-C frame; Pascal cannot express one.
- [x] `tools/build-macos-bridge.sh` -- NEW: compile the `.mm` to an object with the centralized flags and assert the object's arch -- one shipped dylib, one linked object, nothing else.
- [x] `src/platform/macos/pweb.platform.cocoa.pas` -- NEW: `TCocoaAssetHandler` (`Create(store)` arms before `webview_create`; `Attach(webview)` proves the seam ran; idempotent `Detach`), the generation-checked handle registry, the `cdecl` resolve callback with its exception barrier, and the shared `PWebCocoaResolveAssetUri`/`PWebCocoaContentType` the gates call directly -- the adapter's whole request decision in one place, testable headless.
- [x] `src/assets/pweb.assets.folder.pas` -- give `FinalPathOfFd` a `{$ifdef DARWIN}` body over a hand-declared `fcntl(F_GETPATH)`, adding `F_GETPATH` and the path bound to the existing Darwin interface block -- call sites and algorithm unchanged; without it the store cannot construct on macOS.
- [x] `test/cap7m/abi_probe_fcntl.c`, `test/cap7m/abi_probe_fcntl.pas` -- add `F_GETPATH` and the path bound to the paired probe, keeping zero permitted deltas and the fixed emission order -- a wrong `F_GETPATH` fails loudly; the point is that it cannot fail quietly.
- [x] `test/platform/pweb.test.cocoa.pas` -- NEW: headless `TSynTestCase` over `PWebCocoaResolveAssetUri` (hostile matrix, counting store proving wrong-host never reads), the content-type fallback, and the task state machine driven deterministically through the bridge with a stub task (double terminal, post-stop, idempotent cancel, disowned handler) -- the state machine must be provable without a window.
- [x] `test/core/pwebtests.pas` -- register the Darwin case beside the Linux one -- same suite, same runner, one more platform.
- [x] `test/cap7m/cap7m_runtime.pas` -- NEW: the production runtime harness. Real `NSApplication`/`WKWebView`, the production adapter, folder **and** ZIP stores, the frozen scheduler/binding/mORMot path to 42, both shutdown shapes, repeated cycles, and the page's own verdict object -- no probe substitutes for the real wiring.
- [x] `test/cap7m/fixture/` -- NEW: minimal HTML/CSS/JS plus a zero-byte and an all-byte-values asset, and the ZIP built from the same corpus -- one corpus, two stores, so parity is a property the gate exercises.
- [x] `test/cap7m/run_cap7m_gates.sh` -- NEW: the headless leg -- the full `pwebtests` suite on Darwin, and a real-symlink folder-confinement probe mirroring `test/cap7l/run_cap7l_gates.sh:65-148` plus the final-symlink and unrelated-CWD cases Linux does not have.
- [x] `test/cap7m/run_cap7m_runtime.sh` -- NEW: the GUI leg -- drive the harness in both store modes for N cycles, assert the secure-origin object, the RPC 42 marker, the threading facts, zero suppressed-terminal anomalies and an empty task registry, cross-check every observed URI through `uri_oracle`, and re-run the whole thing from `/` with all three `DYLD_*` stripped.
- [x] `.github/workflows/ci.yml` -- extend both macOS jobs with the bridge build, the headless gates and the runtime gates; add every new script to both floating-ref guard lists; keep `cap7m_probe` running as the platform regression -- two independent jobs, no matrix, no mocked WKWebView.
- [x] `docs/wkwebview-macos-semantics.md` -- record the new constraints: `/proc/self/fd` has no Darwin equivalent and what replaced it; the bridge's handle-not-pointer ownership model; what a synchronous main-thread handler does and does not make raceable -- the surprises belong where the next reader looks.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- close the two entries this shard resolves (the lock-key misnomer, the vacuous guard loops) and ledger what it defers -- append-only, and closure is recorded, not silent.

**Acceptance Criteria:**
- Given the production adapter and a real `WKWebView`, when both macOS jobs run, then the full path `pweb://app` → production handler → `IAssetStore` → folder **and** ZIP → JS binding → scheduler worker → mORMot → **42** completes on `x86_64` and on `arm64` separately, with the secure-origin object stated by the page in every cycle.
- Given the shard is merged, when the `windows:` and `linux:` jobs run, then every CAP-1…CAP-7L gate is still green, both freeze sweeps agree from their original baselines against the renamed key, and the old key name appears nowhere in `webview.lock`.
- Given any produced Mach-O on either job, when it is inspected, then its architecture is the job's architecture and its `minos` is `12.0`, and no macOS compile or link flag is written anywhere but the one helper.
- Given a released or never-armed handler, when WebKit calls back, then the handle does not resolve, no Pascal code runs, the task is refused, and no exception crosses either boundary — proven deterministically and in a real `WKWebView`.
- Given this shard closes, when the tree is inspected, then no release packaging, signing, `.app` bundling, React/Pas2JS macOS application or CAP-8/10/11/12 code exists in it.

## Implementation record

**GREEN — run `31953707173`, all four jobs, commit `1886121`.** `windows`,
`linux-x64`, `macos-x64` and `macos-arm64` all succeeded, every step of both
macOS jobs included.

CI moved to the **public** `flydev-fr/poueb` mirror partway through: the
private repository hit a hard GitHub Actions billing stop (run `31920869910`
started none of its four jobs — *"recent account payments have failed or your
spending limit needs to be increased"*). Public repositories get free standard
runners and `macos-15`/`macos-15-intel` are standard, so the mirror runs the
identical workflow at no cost. The branch is pushed to both remotes; the
authoritative history and the freeze belong on the private one.

**Measured, both architectures, run `31953707173`:**

| | x86_64 | arm64 |
|---|---|---|
| `webview_*` exports / total | 17 / 25 (8 weak `_ZT[IS]`) | 17 / 17 |
| deployment target | `pinned=12.0 minos=12.0` | same |
| bridge object | `minos=12.0 seam_text_exports=19` | same |
| PWeb suite on Darwin | `0 / 2,302` | `0 / 2,302` |
| Cocoa adapter case | `0 / 731` | `0 / 731` |
| folder confinement | `vectors=14 cwd_independent=yes` | same |
| URI cross-check, per store | `observed=60 served=21 refused=39 leaks=0` | same |
| per-view seam read-back | `ours` (folder, zip, stripped) | same |
| FPU traps | `traps_masked=1` (all three legs) | same |
| RSS growth vs 65536 budget | 332 / 224 / 312 KiB | 352 / 208 / 208 KiB |
| unrelated CWD + stripped `DYLD_*` | `cwd=/ dyld_hints=stripped result=pass` | same |
| threading, every cycle | `gui_affine=1 worker_distinct=1 direct_return=1` | same |
| shutdown shapes | `terminate` and `window-close`, `clean=1` | same |
| M0 regression | `seam_a_effective=no`, `ownership=webkit-copies-at-handoff` | same |

`CAP7M1_PASS store=folder cycles=3` and `store=zip cycles=3` on both. The
page's `"ok":true` — asserted once per cycle per store — is the conjunction of
the secure-origin object, the complete hostile matrix, the zero-byte and
all-byte assets, concurrency, the rejected invocation with its payload intact,
and `CalculatorService.Add({a:20,b:22}) === 42`.

**Six defects found, five of them invisible to any other platform.** In order:
`pweb.test.binding.pas` guarded `baseunix` with `{$ifdef LINUX}`, so the
guard-page proof did not compile on Darwin; `pweb.test.bundle.pas` compared
Darwin against the **Windows** golden digest (the two Darwin statics agree
with each other, so macOS needs one constant where Windows and Linux need one
each); `run_cap7m_gates.sh` never created the directories FPC's `-FU`/`-FE`
refuse to create themselves; FPC leaves the FPU **trapping** and WebKit
computes on NaNs, killing every cycle with `EInvalidOp` (constraint 16);
`local a="$1" b="${a}x"` does not work under macOS's bash 3.2, which expands
every word before assigning any; and the zero-transport sweep list had gone
stale, which also revealed that the sweep covered **no `src/` file at all** on
macOS while the Linux sibling had always swept its adapter.

**Superseded record.** The earlier state of this section reported the shard
HALTED at `472db3b` with the runtime leg never once executed. That is no
longer true and is kept only as history: the runtime leg is the part now
carrying the most evidence.

| | Evidence |
|---|---|
| Pinned dylib, exactly 17 `webview_*` exports, ABI probes M4/M5 | run `31918375036` |
| Production ObjC++ bridge compiles under `-Wall -Wextra -Werror`; private-seam export gate passes | `CAP7M1_BRIDGE arch=… minos=12.0 seam_text_exports=18` |
| `fcntl(F_GETPATH)` round trip: C side == the production Pascal routine | `CAP7M_FCNTL fcntl.F_GETPATH_ROUNDTRIP=/Users/runner/work/pweb/pweb/webview.lock`, identical on x86_64 **and** aarch64 — the variadic-ABI risk is measured, not assumed |
| Darwin fcntl constants, zero permitted delta | `O_RDONLY=0 O_NOFOLLOW=256 O_DIRECTORY=1048576 F_GETPATH=50 PATH_BOUND=1024` |
| Whole Pascal stack compiles **and links**: adapter, harness, test case, suite + bridge | run `31919274985` |
| Full PWeb suite on Darwin | run `31920073153`: **0 / 2,302 assertions failed** |
| Cocoa adapter test case | **0 / 731**: hostile URI matrix 129, canonical resolution 19, wrong-authority-never-reaches-store 4, content-type parity 13, response-body lifetime 520, handle-registry generations 13, seam confinement 2, task state machine 31 |
| Acceptance criterion 3, gated rather than asserted in prose | `CAP7M1 M3: 11 scripts carry no inline macOS flag` |
| Windows and Linux regressions | green in runs `31919274985` and `31920073153` |

**Outstanding, never run once.** The folder-confinement probe, the entire
real-`WKWebView` runtime leg (secure origin, RPC 42 over folder and ZIP, the
threading proof, lifecycle cycles, the unrelated-CWD/`DYLD_*` rerun), the
retained M0 probe and the bundle-layout gate. The last commit before the halt
— `472db3b`, creating the folder probe's `-FU`/`-FE` output directories — is
itself unverified.

**Three defects that only Darwin could surface**, all pre-existing, none
caused by the adapter: `pweb.test.binding.pas` guarded `baseunix` with
`{$ifdef LINUX}`, so the guard-page proof did not compile there;
`pweb.test.bundle.pas` compared Darwin against the **Windows** golden digest
(the two Darwin statics agree with each other, so macOS needs one constant
where Windows and Linux need one each); and `run_cap7m_gates.sh` never created
the directories FPC's `-FU`/`-FE` refuse to create themselves.

**A Windows flake, confirmed as a flake rather than assumed to be one.** Run
`31918375036` failed `CAP-6b3 fixed setup gates` with *"uninstall left 12
file(s) behind: d3dcompiler_47.dll, dxcompiler.dll, dxil.dll, ffmpeg.dll,
mip_core_gn.dll…"* — WebView2 Fixed Runtime DLLs, in a path this shard does
not touch (`git diff --name-only` against the baseline shows no `cap6b`,
setup, WebView2 or InnoSetup file changed). It passed on both later runs. No
PWeb runtime code was changed to chase it.

## Design Notes

**The adapter's shape differs from its siblings, and the difference is forced.** Windows and Linux construct their handler *after* `webview_create` because both engines expose a post-create seam. Cocoa does not: upstream builds the `WKWebViewConfiguration` and the `WKWebView` inside `webview_create` (`cocoa_webkit.hh:450,486`), and M0 measured seam A being **accepted, compared equal, and never consulted** — the worst shape a wrong seam can take. So the macOS adapter is two-phase:

```pascal
handler := TCocoaAssetHandler.Create(store);   // arms the pre-create seam
w := WebViewCheckCreated(webview_create(0, nil));
handler.Attach(w);                             // raises unless the seam RAN
...
handler.Detach;                                // disown, then webview_destroy
```

`Attach` exists to answer adversarial question 1 structurally: it compares the bridge's seam-invocation counter across `webview_create` and raises if it did not move. A seam that silently stopped running can never again present as success.

**Ownership crosses as a handle, never as a pointer.** The bridge stores a `uint64_t` packing a slot index and a generation counter; the Pascal registry bumps the generation on both claim and release, so a handle from a freed handler resolves to `nil` rather than to whatever now occupies the slot. That is strictly stronger than the Linux adapter's interlocked owner pointer, and it is what makes "no callback after handler destruction" a property of the *representation* rather than of the teardown order. `Detach` disowns first (the bridge stops calling out), then claims and fails every live task, then releases the Objective-C objects — and only then may `webview_destroy` run.

**The response body is the bridge's the moment it is handed over.** Pascal `malloc`s a copy and transfers it through the seam; the bridge wraps it with `dataWithBytesNoCopy:length:freeWhenDone:YES` so `NSData` owns and frees it. This is deliberately **independent of M0's `handoff=original-bytes` measurement**: production is correct whether WebKit copies at handoff or retains the pointer. The measurement stays a gate anyway — `cap7m_probe.mm` keeps running — because a silent change there is exactly the class of platform drift that would otherwise surface as corrupted assets in someone's application. A zero-length asset still allocates, and is delivered as an empty `NSData` with an honest `Content-Length: 0`.

**Served assets get `NSHTTPURLResponse`; refusals get `didFailWithError:`.** M0's constraint 12 is the reason: a bare `NSURLResponse` loads the resource perfectly while `fetch()` reports `status: 0, ok: false`. Refusal stays the measured Darwin shape and carries no reason, no path and no native text — one outcome for wrong authority, non-canonical path, missing asset and internal failure alike, exactly as Windows answers a constant 404 and Linux a constant `GError`.

**`FinalPathOfFd` gains a Darwin body, not a Darwin algorithm.** `fcntl(fd, F_GETPATH, buf)` is the direct counterpart of `readlink("/proc/self/fd/N")` and of Windows' `GetFinalPathNameByHandleW`: it answers *what did I actually open*. Both call sites — the constructor's one-time root canonicalization and the open-descriptor re-proof in `ReadWholeFile` — keep their exact shape, so Linux and Windows behaviour is byte-identical and the confinement algorithm is unchanged. Two Darwin differences must be recorded rather than assumed away: macOS resolves firmlinks, so a root under `/tmp` canonicalizes to `/private/tmp/...` (which is why the root is canonicalized through the descriptor in the first place, and why the gate's own fixtures must compare on `pwd -P`); and an unlinked file reports its last path with no `(deleted)` marker, unlike Linux. Neither is an escape — the fd was opened `O_NOFOLLOW` at a walked-and-lstat'd path — but the difference is real and belongs in the semantics doc.

**A synchronous main-thread handler is a feature, and the honest claim is narrow.** Every request is resolved and completed inside `startURLSchemeTask:` on the main thread, so `stopURLSchemeTask:` cannot interleave with serving, and most of the documented race surface is structurally absent rather than merely untested. The state machine is still built and still gated — because "structurally absent" is a property of *this* implementation that a future chunked or deferred delivery would remove, and because the invariants are cheap to hold and expensive to retrofit. It is proven two ways: deterministically, by driving the bridge with a stub task (double terminal suppressed, post-stop suppressed, cancel idempotent, disowned handler inert); and in a real `WKWebView`, by terminating and by closing the window while a page is loading, asserting zero suppressed-terminal anomalies, zero caught exceptions and an empty registry at teardown. If the real leg records zero `stopURLSchemeTask:` arrivals, that is reported as a limitation of what the real leg proves — never dressed up as a passing race test.

## Verification

**Commands (hosted, both `macos-15-intel` and `macos-15`):**
- `tools/build-webview-dylib.sh` -- expected: one arch slice, `minos 12.0`, install name `@rpath/`, WebKit framework present.
- `test/cap7m/check_webview_exports.sh` -- expected: `webview_*` set exactly 17 on both arches; every other export `^_ZT[IS]`.
- `test/cap7m/check_abi.sh` -- expected: 36 facts with exactly the 2 documented signedness deltas; fcntl block **zero** deltas including the new `F_GETPATH`; 17 bare `dlsym` resolutions, 0 underscored.
- `tools/build-macos-bridge.sh && test/cap7m/build_cap7m.sh` -- expected: bridge object and every Pascal binary carry the job's arch and `minos 12.0`; `LC_LOAD_DYLIB` is `@rpath/libwebview.0.12.dylib` wherever it exists; `LC_RPATH` is `@executable_path`.
- `test/cap7m/run_cap7m_gates.sh` -- expected: `pwebtests` reports zero failed assertions with the Darwin case present; the folder probe refuses every symlink, case-variant and glob vector and serves the confined ones, from an unrelated CWD.
- `test/cap7m/run_cap7m_runtime.sh` -- expected: per cycle and per store mode, the secure-origin object, `42`, GUI-affine callback with a distinct worker and a direct return, 8+1+1 completions, both shutdown shapes, zero anomalies, zero URI leaks against `uri_oracle`.
- `test/cap7m/run_cap7m_probes.sh 3` -- expected: unchanged M0 platform facts (`precreate_seam_ran=1`, `seam_a_effective=no`, `poststop_throws=1`, `ownership=webkit-copies-at-handoff`).
- `test/cap7m/check_release_layout.sh` and `check_cap7m_nonetwork.sh` -- expected: runs from `/` with all three `DYLD_*` stripped; no owned listener.
- The `windows:` and `linux:` jobs -- expected: green, including both freeze sweeps against the renamed key.

**Manual checks (if no CLI):**
- `git grep -n 'cap7l-binding-patch-sha256'` returns hits only in frozen `_bmad-output/` artifacts, never in `webview.lock` or `ci.yml`.
- `git diff 709bf0fe -- src/lib` and `git diff 4653ba77 -- src/lib` still produce the same patch, whose normalised SHA256 still equals the preserved value.
- `git ls-files -s -- '*.sh'` shows mode `100755` for every new script.
- `git -C deps/webview status --porcelain` is empty.
