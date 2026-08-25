# CAP-8C Phase A — multi-WebView topology, measured

What `test/cap8c/topology.pas` **measured**, per target, on hosted run
32748017833 (commit `c14c575`, all seven jobs green; the four
`cap8c-topology-<target>` artifacts and the `cross-target-topology.txt`
rendering are that run's uploads). Nothing here is inferred from API names.

## T1 — the facts every target agrees on

On windows-x86_64, linux-x86_64, macos-x86_64 AND macos-arm64:

- two WebViews are created before the loop, with distinct instance and
  native window handles (`second_create_before_run_ok`,
  `distinct_instance_handles`, `prerun_windows_distinct` all true);
- both remain LIVE concurrently under one `webview_run(first)` — the second
  view completes a JS→native round trip while the first drives the loop
  (`second_view_loaded_during_first_run=true` everywhere);
- same-name bindings on the two instances keep independent userdata and
  deliver only to their own slot: `cross_deliveries=0`, `unknown_userdata=0`,
  `userdata_isolated=true` on all four;
- both views hold CONCURRENTLY OUTSTANDING invocations, each resolved via
  `webview_return` to its own page (`concurrent_holds_observed=true`,
  both `*_view_resolved=true`, `liveness_timeout=false` everywhere).

The preferred topology — two simultaneously live real WebViews on one GUI
thread with independent invocation sources — is therefore SUPPORTED by the
frozen public ABI on all four targets.

## T2 — teardown semantics DIVERGE (the design must respect them)

- `webview_terminate(second)` — thread-global on two engines:
  - macOS both arches: deterministically STOPS the first instance's run
    (`terminate_second_stopped_run=true`, `run_reentries=1`) — `[NSApp stop]`
    is application-global;
  - Windows: NONDETERMINISTIC — false on the hosted run, true on a local
    dev-host run of the same binary (thread-global `PostQuitMessage`
    racing destroy's queue depletion; both interleavings recorded);
  - Linux: false — the quit lands on the second instance's own loop state.
- `webview_destroy(second)` while the loop runs (after re-entry where the
  terminate stopped it):
  - Windows, Linux: clean (`destroy_second_code=0`,
    `loop_survived_second_destroy=true`, `survivor_functional_after_close=true`);
  - macOS both arches: the process DIES inside `webview_destroy(second)` —
    `crash_guard=destroy-second`, `overall=PARTIAL`, timeline truncated at
    "experiment: webview_destroy of the second instance". Mid-loop destroy of
    a second WKWebView instance is NOT survivable through the frozen ABI.
    (Post-loop destroy order consequently went unmeasured there.)

## P1 — proposed ratifications (decided at Checkpoint 1)

- **R-C1 topology**: simultaneous two-window topology, ratified on T1.
- **R-C2 window lifecycle**: production "close LoginWindow" is a
  SOURCE-level operation — quiesce+close the window's invocation source
  (frozen `IInvocationSource` lifecycle), blank the view; the WebView
  instance itself is long-lived. "Reopen" arms the SAME instance with a
  FRESH source + fresh native context (the old context/source cannot
  complete into the new one — exactly the stale-reuse gate). No mid-loop
  `webview_destroy` anywhere (macOS crash, T2); `webview_destroy` runs only
  after the owner's loop exits, reverse creation order; `webview_terminate`
  is called ONLY on the run-owner, ONLY at shutdown (thread-global quit,
  T2).
- **R-C3**: the Windows terminate nondeterminism and the macOS mid-loop
  destroy crash are recorded measured limitations (deferred-work), not
  problems CAP-8C works around with platform conditionals — the shared
  lifecycle model above simply never performs either operation.

## Ratification — Checkpoint 1 (2026-08-24)

Human ratification, binding on Phase B:

- **R-C1 RATIFIED** — simultaneous two-window topology on all four targets.
- **R-C2 RATIFIED** — source-level close/reopen window lifecycle on
  long-lived WebView instances; `webview_destroy` post-loop only, reverse
  creation order; `webview_terminate` owner-only, shutdown-only.
- **R-C3 RATIFIED** — the Windows thread-global-terminate nondeterminism and
  the macOS mid-loop `destroy(second)` process crash are recorded measured
  limitations in deferred-work; no platform-conditional workaround is built.

## Ratification — R-C4 (2026-08-25, post-hosted-measurement)

Hosted run 32770563751 and the arming fix measured a further frozen-surface
constraint: the Cocoa bridge's navigation-guard registry is single-slot per
process (`pweb_cocoa_nav_arm` refuses a second arming; single-shot Attach),
so a second macOS window cannot receive the mandatory CAP-8B guard through
the frozen adapters, and "security only on MainWindow" is forbidden.

**R-C4 RATIFIED** — the human authorizes the MINIMAL private Cocoa-bridge
extension: per-view navigation-guard arming in `pweb_cocoa_bridge.{h,mm}` +
`pweb.platform.cocoa.pas`, mirroring the asset seam's multi-view design.
Constraints: no public C ABI change, no new webview export, no upstream
patch, the shared classifier/CSP/decision logic byte-untouched; the CAP-8B
suites re-run as the regression proof. This is the same human-gate mechanism
CAP-8B itself used to edit these files.
