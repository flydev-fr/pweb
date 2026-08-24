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
