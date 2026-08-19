---
title: 'CAP-8B — privileged navigation and native-bridge isolation'
type: 'feature'
created: '2026-08-19'
status: 'in-progress'
review_loop_iteration: 0
baseline_commit: '2a8a4a20f0cb50d0dd0b4d4fbee723eb0aa27cba'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing in the product enforces WHAT may execute inside the WebView that owns the privileged `__pweb_invoke` bridge. `IWebView.Navigate`'s contract calls the `pweb://app`-only rule a "policy reminder (enforced by implementations)" and no implementation enforces it: no platform installs a navigation hook, no response carries a native Content-Security-Policy, and the asset handlers answer `pweb://app/*` requests no matter which frame or document asked. External or opaque content that reaches this WebView would run in a context that reaches CAP-8A's authorized bridge.

**Approach:** One platform-neutral private navigation classifier in `src/security/`, fed by private native hooks in each of the three existing engine adapters (never new units, never a second COM/GObject/ObjC declaration surface), plus a native-owned CSP + `nosniff` + `Referrer-Policy` on trusted asset responses and a private OS external-URI opener with an injectable test seam. The shared release host installs it once; the four-target CI matrix proves one identical decision corpus, zero bridge/SOA reachability from untrusted contexts, and unchanged React/Pas2JS/CAP-8A behaviour. Three MEASUREMENT audits (bridge exposure, navigation event coverage, active-subresource control) run FIRST on all four targets and gate the production design at Checkpoint 1.

## Boundaries & Constraints

**Always:**
- Audits before production: bridge exposure, platform navigation coverage and CSP enforcement are MEASURED on Windows x64, Linux x64, macOS x86_64 and macOS arm64 by real runtime probes; API names are never taken as evidence. Checkpoint 1 presents the measured tables and HALTS.
- Frozen surfaces byte-identical: `src/rpc/*`, `src/webview/*`, `src/security/pweb.capabilities.pas`, `src/security/pweb.capabilities.policy.pas`, `src/assets/pweb.assets.support.pas` (the canonical URI truth), SDK wire, `app.pwb` format, protocol v1, nine-code taxonomy, CAP-13, seven interfaces. No eighth interface, no new public webview export, no second RPC path, no public system-opener interface.
- One classifier, zero platform conditionals, zero engine types in its signatures; trusted-origin decisions come from parsed components via `PWebParseAppUri` — never `StartsWith`, substring, or path-only comparison.
- Fail closed everywhere: an unmapped scheme, an unparseable URI, a callback exception, an absent decision path and an opener failure all deny; a denied navigation never replaces the trusted page and never falls back to internal navigation.
- Every native decision handler/callback is completed exactly once and is an exception barrier (no Pascal exception, no NSException, no GError crosses a C frame).
- Bootstrap `about:blank` is a single-use engine exception per WebView, native state, permanently Armed after the first trusted `pweb://app` navigation — never a general `about:` allowlist entry.
- The external opener passes the exact URI as data through a native API; no shell string, no `cmd.exe`/`/bin/sh`/`system()`, scheme-allowlisted, length-bounded, control-character rejecting, never logging full query strings.
- Test-first; subject-only commit messages; evidence from counters/spies, never inference.

**Ask First:** the Checkpoint-1 ratification of the classification table, the user-activation rule, the exact CSP string, the `src/security/` → `pweb.assets.support` dependency, and the Linux response-header mechanism; any new upstream `deps/webview` patch; any edit to a frozen file or interface; splitting `ci.yml`.

**Never:** CAP-8C multi-principal/multi-window UX, dev-mode Vite/HMR trust, QuickJS, plugins, blobs, HTTP/file fallbacks, private WebKit SPI, a second bridge dylib, a shipped native helper library, a public C ABI change, changes to `ICapabilityPolicy`/`TInvocationContext`/CAP-8A mapping or intersection semantics, moving or duplicating the CAP-8A policy call site, detaching the bridge after untrusted content has begun loading.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Trusted main frame | `pweb://app/`, `pweb://app/<canonical>`, fragment, reload, back/forward, top frame, Armed | AllowTrusted — page loads, RPC unchanged | N/A |
| Wrong authority | `pweb://evil/x`, `pweb://app.evil/`, `pweb://app@evil/`, `pweb://app:1/`, `pweb:///x` | Cancel; trusted page retained; asset handler still answers its constant refusal | never decoded into a permissive value |
| User external | user-activated `https:`/`mailto:` (top frame or `target=_blank`) | Cancel internally + OS opener called exactly once | opener failure ⇒ diagnostic, page stays trusted, no internal fallback |
| Script external | `location = 'https://…'`, `window.open('https://…')` | Cancel; opener NOT called | N/A |
| Other schemes | `http: file: data: javascript: blob: ws: wss: ftp:` + unknown | Cancel, no external side effect | N/A |
| Subframe | any subframe document navigation, including `pweb://app` | denied (navigation hook and/or `frame-src 'none'`) | measured per engine |
| New window | any new-window request other than user `https`/`mailto` | denied; no privileged child WebView | N/A |
| Download | any download request in the privileged WebView | denied | N/A |
| about:blank | engine bootstrap (Bootstrapping) vs any later navigation (Armed) | allowed once / denied thereafter | Armed transition is permanent |
| Active subresource | trusted document requests external script/frame/fetch/object/form | blocked by the native CSP | bundle `<meta>` CSP can only add restrictions |
| Untrusted context | any of the above attempts `__pweb_invoke` or the raw transport | native invocation counter = 0, SOA counter = 0, no bridge result | measured at the lowest exposed transport, not via the SDK symbol |
| Nav during RPC | allowed invocation in flight + external navigation attempt | navigation cancelled; invocation completes exactly once | scheduler cancellation semantics unchanged |
| Callback fault | classifier or adapter raises | deny; handler still completed exactly once | no UAF at teardown |

</frozen-after-approval>

## Code Map

**Frozen / read-only evidence**
- `_bmad-output/specs/spec-pweb/security-model.md:151-172` — the ratified navigation rule (`pweb://app` only; `https:`/`mailto:` to the system browser) and the Phase-10 dev-mode carve-out this shard must NOT begin. `docs/kernel.md:38` restates it.
- `src/webview/pweb.webview.intf.pas:93-97` — `IWebView.Navigate`'s "policy reminder (enforced by implementations, not by this contract's shape)": this shard is that implementation. Contract text unchanged.
- `src/assets/pweb.assets.support.pas:370-429` — `PWebParseAppUri`, the canonical scheme+authority+single-decode+canonical-path truth. **Note :379-395**: scheme AND authority compare case-INSENSITIVELY (`SameAsciiText`, RFC 3986), so `pweb://APP/` parses as trusted today — a Checkpoint-1 ratification item (D3).
- `src/rpc/pweb.rpc.scheduler.pas:689` — the single CAP-8A policy call site. Not moved, not duplicated, not read by this shard.
- `src/security/pweb.capabilities.policy.pas` — CAP-8A engine; byte-untouched.

**Upstream measurements already in the tree (start the audits here, then re-measure)**
- `deps/webview/core/include/webview/detail/engine_base.hh:205-300` — the `window.__webview__` shim and `window[name]` bind script; `:96-124` bind/unbind/onReply.
- `deps/webview/…/backends/cocoa_webkit.hh:248-250` — user script `forMainFrameOnly = true`; `:509-515` the `__webview__` **script message handler**, which WebKit exposes in EVERY frame; `:490-494` upstream owns `setUIDelegate:` (`WebviewWKUIDelegate`, open-panel only) and leaves `navigationDelegate` FREE.
- `deps/webview/…/backends/gtk_webkitgtk.hh:225-234` — user script `WEBKIT_USER_CONTENT_INJECT_TOP_FRAME`; `:293-304` `register_script_message_handler("__webview__")`; only `"destroy"` is connected, so `decide-policy`/`create` are free.
- `deps/webview/…/backends/win32_edge.hh:463-474` — `AddScriptToExecuteOnDocumentCreated` (all frames); `:168-169` upstream takes only `WebMessageReceived` + `PermissionRequested`, leaving `NavigationStarting`, `FrameNavigationStarting`, `NewWindowRequested`, `DownloadStarting` free.
- `tools/cap4w/webview2-custom-scheme.patch` — `pweb` registered with `HasAuthorityComponent`+`TreatAsSecure`; no `SetAllowedOrigins`. Preserve exactly; no new upstream patch without a human gate.

**Production edit sites**
- `src/security/pweb.navigation.policy.pas` — NEW: classifier + per-WebView bootstrap state + the one CSP/header constant (see Tasks).
- `src/platform/windows/pweb.platform.webview2.pas` — `BuildHeaders` :352-356 (add native headers); the minimal pinned COM transcription :101-253 gains real declarations for the existing `Stub_add_NavigationStarting` :156, `Stub_add_FrameNavigationStarting` :166, `Stub_add_NewWindowRequested` :193 slots (slot INDEX unchanged — the `get_BrowserVersionString` precedent at :144), plus `ICoreWebView2_3`/`_4` for `add_DownloadStarting`; `TWebView2AssetHandler` Create/Detach :432-529 is the teardown-order model for the new guard.
- `src/platform/linux/pweb.platform.webkitgtk.pas` — externals block :204-267 gains `g_signal_connect` (`libgobject`), the `decide-policy` decision API and `g_app_info_launch_default_for_uri` (`libgio`); `PWebGtkSchemeRequest` :507-574 and `webkit_uri_scheme_request_finish` :232 must become `…_finish_with_response` + `webkit_uri_scheme_response_*` (+ libsoup3 headers) to carry response headers at all — the measured Linux CSP question (D4). Detach/disown model :661-680 is the guard's model.
- `src/platform/macos/pweb_cocoa_bridge.h` / `.mm` — `serveTask:` header dictionary `.mm:274-283` gains the native headers; NEW C entries for installing a `WKNavigationDelegate` on a view, for the classifier callback out to Pascal (same generation-checked handle model, `.h:47-63`), for `NSWorkspace` external open, and for the deterministic navigation-decision stub surface (mirroring `.h:253-305`).
- `src/platform/macos/pweb.platform.cocoa.pas` — Pascal side of the above (external declarations :373-414, handler class :208-238).
- `examples/08-release/releaseapp.pas` — platform alias block :131-147 gains `TPWebNavigationGuard`; construction between the asset-handler site :772-778 and `webview_navigate` :779; teardown beside `assetHandler.Detach` :836-846; `TReportingBridge.Invoke` :295-322 gains the navigation-security verdict fields.
- `examples/05-pas2js/frontend/src/index.html:14` — the ONLY inline `<script>` served over `pweb://app` in the repo (grep-verified); it must become `/assets/boot.js` (written by `frontend/build.ps1`) so `script-src 'self'` needs no `'unsafe-inline'`.
- `examples/04-react/frontend/src/App.tsx:26-97` and `examples/05-pas2js/frontend/src/p2japp.pas` — verdict objects gain the navsec block; `examples/06-assets/frontend/dist/assets/app.js:29-46` uses same-origin `fetch`, which is the evidence for `connect-src 'self'` over `'none'` (D5).

**Test / CI edit sites**
- `test/security/pweb.test.capabilities.pas:75-79, 936-1010` — `PWEB_CAP8A_DIGEST_FILE` + `DecisionDigest`: the exact template for the new navigation corpus (`schema=1` … `verdict=PASS`, LF only, pure decisions).
- `test/core/pwebtests.pas:48-69,121` — case registration.
- `test/cap7l/cap7l_probe.c:60-105`, `test/cap4w/cap4w_probe.cpp`, `test/cap7m/cap7m_probe.mm` — the reference-probe shape the audit probes copy (page states its own facts; nothing inferred from "it rendered").
- `test/cap7l/run_gui_matrix.sh`, `test/cap7m/run_cap7m_runtime.sh`, `test/cap6/run_cap6_smoke.ps1` — where the per-platform runtime matrices hang.
- `test/cap7f/emit_evidence.ps1:239-274` + `emit_evidence.sh` + `check_cap7f_aggregate.ps1:50-76` (`$required`, `$mustPass`, `$equalityFields`, `$absolutePins`) + `check_cap7f_selftest.ps1` — add `navigation_security` + `navigation_policy_digest` exactly as `capability_policy` was added.
- `test/cap7f/check_divergence.ps1:66-80` — `$allow` must be re-ratified (count + fingerprint) for `examples/08-release/releaseapp.pas`; the new `src/security/` unit stays off the allowlist, i.e. zero platform conditionals.
- `.github/workflows/ci.yml` — four target jobs + `cap7-aggregate`; add `-Futest/security` peers already exist from CAP-8A.

## Tasks & Acceptance

**Execution — Phase A (audits; ends at Checkpoint 1, HALT):**
- [x] `test/cap8b/` — audit probes per engine (Windows C++ / Linux C / macOS ObjC++, mirroring the CAP-4W/7L/7M reference probes) plus one shared Pascal audit host, emitting `build/cap8b/audit-<target>.json`: (1) bridge exposure for the seven contexts (trusted top document, same-origin iframe, `pweb://evil` iframe, `data:` iframe, `about:blank` iframe, opened window, top-level external attempt) recording shim presence, RAW transport reachability, native-callback arrival and observable initiator; (2) navigation-hook coverage — for each of top-level, subframe, redirect, `target=_blank`/`window.open`, form submit, history, reload, download, programmatic `location`, user-activated anchor: does the proposed hook OBSERVE it and can it CANCEL before execution, and is user-activation distinguishable; (3) CSP-header enforcement on the custom scheme (external script, external frame, external fetch, `<object>`, form action, `base-uri`, worker) plus whether a bundle `<meta>` CSP can weaken it; (4) whether the engine performs an initial internal `about:blank`.
- [x] `.github/workflows/ci.yml` — temporary audit steps on all four targets that build, run and upload the probes, plus the `cap8b-audit-summary` job that downloads all four and renders the cross-target tables; run the branch hosted and collect the four artifacts.
- [x] **Checkpoint 1** — present BRIDGE EXPOSURE / NAVIGATION EVENT COVERAGE / NAVIGATION CLASSIFICATION TABLE / USER-ACTIVATION RULE / FRAME & NEW-WINDOW RULE / INITIAL ABOUT:BLANK / NATIVE SECURITY HEADERS / SYSTEM OPENER / FILES & CODE MAP, with decisions D1–D8 (below), and `CAP-8B PLAN READY` or `CAP-8B PLAN BLOCKED`. HALT for human ratification. STOP if any target cannot cancel untrusted main-frame or subframe content before execution, or if the header mechanism must diverge.

**Execution — Phase B (production; only after ratification):**
- [ ] `src/security/pweb.navigation.policy.pas` — NEW: `TPWebNavKind`/`TPWebNavAction`/`TPWebNavBootstrap`/`TPWebNavRequest`; pure `PWebClassifyNavigation`; stateful per-WebView `TPWebNavigationPolicy` (Decide + permanent Armed transition + decision counters); the native `PWEB_NATIVE_CSP` / `PWEB_NATIVE_SECURITY_HEADERS` constants; the `TPWebExternalOpener` seam type. Zero platform conditionals, zero engine types, `PWebParseAppUri` for every trusted-origin verdict.
- [ ] `test/security/pweb.test.navigation.pas` — NEW headless suite: the full classification matrix (every B1–B23 row as a classifier decision), prefix/authority-confusion vectors, bootstrap single-use, exception fail-closed, opener-seam call counting; and `NavigationDigest`, writing `build/cap7f/navigation-policy.txt` (`schema=1`, one line per `uri|kind|frame|newwindow|useractivation|bootstrap → action`, `verdict=PASS`, LF only). Register in `pwebtests`.
- [ ] `src/platform/windows/pweb.platform.webview2.pas` — native security headers on asset responses; `TWebView2NavigationGuard` over `NavigationStarting` / `FrameNavigationStarting` / `NewWindowRequested` / `DownloadStarting`, cancelling before commit, exception-barriered, CAP-4W teardown order, borrowed controller untouched, no new export, CAP-13 selection untouched.
- [ ] `src/platform/linux/pweb.platform.webkitgtk.pas` — native security headers through the response API ratified at Checkpoint 1; `TWebKitGtkNavigationGuard` over `decide-policy` (navigation-action, new-window-action, response) with an EXPLICIT use/ignore for every decision (never the default handler) and the `create` signal denied; extend `test/cap7l/abi_probe_gtk.*` and `check_abi.sh` for every new symbol/callback.
- [ ] `src/platform/macos/pweb_cocoa_bridge.{h,mm}` + `src/platform/macos/pweb.platform.cocoa.pas` — native security headers in `serveTask:`; a public-API `WKNavigationDelegate` installed early enough that no untrusted document commits, every decision handler called exactly once; `NSWorkspace` opener; deterministic stub surface for the decision state machine. No private SPI, no second dylib, no public C ABI change.
- [ ] `examples/08-release/releaseapp.pas` + `examples/0{4,5}` frontends — install the guard in the shared host with a platform-neutral alias and the shared classifier (no platform policy table); move the pas2js inline bootstrap into `/assets/boot.js`; both pages add the navsec verdict block (external blocked, wrong authority blocked, frame blocked, CSP enforced, trusted page retained) beside the existing `secure`/`handshake`/`42`/`denied` facts.
- [ ] `test/cap8b/run_nav_matrix.{ps1,sh}` + the malicious fixture corpus — the real-window B1–B33 matrix on each target, including the bridge-isolation proof at the LOWEST transport found in Phase A, injected-opener determinism, and the RPC/navigation race.
- [ ] `.github/workflows/ci.yml`, `test/cap7f/emit_evidence.{ps1,sh}`, `check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1`, `check_divergence.ps1` — replace the temporary audit steps with the production gates on all four targets; add `navigation_security` (must-PASS) and `navigation_policy_digest` (equality across four targets); re-ratify the `releaseapp.pas` divergence count+fingerprint; one negative self-test leg.
- [ ] `_bmad-output/implementation-artifacts/deferred-work.md` — append the shard's residuals (measured limitations, any waived row, ci.yml size).

**Acceptance Criteria:**
- Given each of the four targets, when the audit probes run, then bridge exposure, navigation coverage and CSP enforcement are recorded as MEASURED values and Checkpoint 1 halts on them.
- Given the ratified table, when the headless suite runs on all four targets, then `navigation-policy.txt` is byte-identical (one digest) and the aggregator rejects any disagreement, any missing target, `secure=false`, an opener call for a script navigation, an allowed wrong authority, an unenforced CSP, or a SKIP promoted to PASS.
- Given a real window on each target, when untrusted main-frame, subframe, new-window, redirect, form and download requests are attempted, then none executes, the trusted page remains active, and the native invocation and SOA counters stay at 0.
- Given a user-activated `https`/`mailto` link, when clicked, then the internal navigation is cancelled and the injected opener is called exactly once; given the same URI assigned by script, then it is cancelled and the opener is never called.
- Given an invocation in flight, when an external navigation is attempted and cancelled, then the invocation still completes exactly once; given a denied invocation with a concurrent navigation attempt, then no bridge/SOA activity and no lifecycle corruption.
- Given the release runtime on all four targets, when the page reports, then `secure=true`, `handshake=true`, `Add=42`, `Denied.Probe=forbidden/403` and the navsec block are all true, CAP-8A/CAP-7/CAP-13 gates stay green, the frozen surfaces diff clean, and hosted CI is fully green.

## Design Notes

Decisions D1–D8 are PROPOSED here and ratified (or replaced) at Checkpoint 1 against the measurements:

- **D1 — one classifier, adapters map events.** `PWebClassifyNavigation` is pure over `(Uri, Kind, TopFrame, NewWindow, UserInitiated, Bootstrap)`; the corpus is a function of those inputs only, so cross-target identity is structural rather than coincidental. How each engine DERIVES `UserInitiated` is platform metadata reported separately (WebView2 `IsUserInitiated`; WebKitGTK `webkit_navigation_action_is_user_gesture`; WKWebView public `WKNavigationType` — no `_isUserInitiated` SPI).
- **D2 — layering.** The classifier lives in `src/security/` and depends on `pweb.assets.support` (hence `mormot.core.base`). CAP-8A's "`src/security/` is RTL-only" stays true of `pweb.capabilities.policy.pas`, which is untouched. The alternative — a second URI parser — is refused outright.
- **D3 — authority case.** `PWebParseAppUri` folds case per RFC 3986, so `pweb://APP/` is trusted today; every engine normalises host case before the event fires. Proposal: keep ONE truth (the canonical parser) rather than a stricter second rule that would disagree with the asset layer. Ratify explicitly, because the intent asked for `pweb://APP/` to be rejected.
- **D4 — Linux headers.** `webkit_uri_scheme_request_finish` carries no headers; only `webkit_uri_scheme_request_finish_with_response` + `webkit_uri_scheme_response_set_http_headers` (WebKitGTK ≥ 2.36, libsoup3 `SoupMessageHeaders`) can. That adds `libsoup-3.0.so.0` to the hand-declared private surface and to the ABI probe. If Checkpoint 1 measures CSP as unenforced there, STOP rather than diverge.
- **D5 — `connect-src`.** `'none'` blocks SAME-ORIGIN `fetch` too, which existing CAP-4 gates depend on (`examples/06-assets/.../app.js` and the macOS fixture probe). Proposal: `connect-src 'self'` — it still blocks every external connection and every `ws:`/`wss:` — with the difference stated rather than silently taken.
- **D6 — subframes.** If an engine cannot distinguish main frame from subframe in its navigation hook (a real WebKitGTK 4.1 risk), `frame-src 'none'` is the primary subframe defence and the navigation hook denies every non-`pweb://app` URI regardless of frame. Both are then required, and both are gated.
- **D7 — new windows.** Cancelling in the navigation hook is expected to prevent the child WebView on all three engines, so the macOS `WKUIDelegate` — owned by upstream for its open panel — is NOT replaced. Verify by measurement; if it must be touched, that is a Checkpoint-1 escalation.
- **D8 — bootstrap.** WKWebView and WebKitGTK appear to start with no document at all; WebView2 reports `about:blank` as its initial source. The single-use Bootstrapping→Armed exception is therefore expected to be Windows-only and possibly unnecessary. Measure before writing the exception at all — an exception nothing needs is an exception nothing tests.

## Verification

**Commands:**
- Isolation: `fpc -Fusrc/assets -Fu<mormot> src/security/pweb.navigation.policy.pas` — expected: compiles with no webview, no engine and no platform conditional.
- Headless: the pwebtests compile line plus `-Futest/security`, then `build/test/pwebtests.exe /noenter` — expected: exit 0, the new cases listed, zero failed assertions, `build/cap7f/navigation-policy.txt` written ending `verdict=PASS`.
- `pwsh test/cap7f/check_divergence.ps1` — expected: PASS with the re-ratified `releaseapp.pas` count+fingerprint and no entry for the new `src/security/` unit.
- `git diff --exit-code src/rpc/ src/webview/ src/security/pweb.capabilities.pas src/security/pweb.capabilities.policy.pas src/assets/pweb.assets.support.pas deps/webview` — expected: clean.
- Per-target runtime matrices (`test/cap8b/run_nav_matrix.*`) and the release smokes — expected: all rows PASS, native/SOA counters 0 for untrusted contexts.
- Push the branch → hosted CI: six jobs green including `cap7-aggregate`, with `navigation_security = PASS` and one shared `navigation_policy_digest` on all four targets.
