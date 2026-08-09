# 02-js-binding — JS ↔ Pascal invocation pipeline (CAP-2)

The Phase 2 runtime example: a WebView page fires **multiple concurrent
invocations** through the real pipeline — `TWebViewBinding` →
`IInvocationScheduler` → `TAllowAllCapabilityPolicy` → dummy bridge —
and renders the resolved/rejected promises. Completions travel
worker → `webview_return` directly (thread-safe at the pinned commit),
never through the GUI thread.

This RUN is the **documented human/local gate** for CAP-2: CI compiles
the example and attempts a best-effort, non-gating auto-closing run;
the authoritative pass is a human watching the window locally.

## Build

From the repository root (after `tools/get-webview.ps1`,
`tools/get-mormot.ps1` and `tools/build-webview-dll.ps1`):

```powershell
New-Item -ItemType Directory -Force build/fpc2, build/example2 | Out-Null
fpc -Sh -FUbuild/fpc2 -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview `
  -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
  -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net `
  -FEbuild/example2 examples/02-js-binding/jsbinding.pas
Copy-Item build/webview-dist/webview.dll build/example2/
```

## Run

```powershell
build/example2/jsbinding.exe                       # window stays until closed
$env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'              # unattended: auto-close
build/example2/jsbinding.exe
```

`PWEB_SMOKE_AUTOCLOSE_MS=<n>` closes the window after *n* milliseconds
(capped at 60000) via background thread → `webview_dispatch` →
`webview_terminate` on the GUI thread — the only cross-thread terminate
that works on Windows at the pinned commit
(`docs/webview-upstream-semantics.md`).

## What to observe

- The window opens and lists, as they resolve **concurrently**:
  - eight `pweb.echo` round trips, each verified in JS against its own
    payload;
  - one `test.delay` (token-observing delayed success);
  - one `test.fail` rejecting with the canonical error envelope
    (`code: service_error`, `data.domainCode: scripted`) — its rejection
    is the expected outcome and renders green.
- The status line ends with
  **`ALL 10 concurrent invocations completed correctly`**.

## Exit code

The page reports its final tally back through the pipeline itself (one
last `example.report` invocation intercepted by a bridge decorator), so
the process exit code reflects what actually happened in the page:

| Exit | Meaning |
| --- | --- |
| 0 | Page reported ALL invocations correct, teardown clean (`jsbinding: clean exit`). |
| 1 | Page reported failed invocations, or no verdict arrived before auto-close, or any teardown step failed. |

Closing the window manually before the page finishes (no auto-close
set) prints a warning instead of failing — the human saw the page, the
tally simply never arrived.
