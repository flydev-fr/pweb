# webview/webview upstream semantics at the pinned commit

Pinned commit: `cbbdee44afff22867de9fd88a9fc8350d9bdd399` (see `webview.lock`).
Every statement below was read or measured in the **pinned source**, with file
references into the pinned tree (`deps/webview/...` after
`tools/get-webview.ps1`). Nothing here loosens a Phase-0 contract; where
upstream is more permissive than our frozen threading model, the frozen model
still governs (`_bmad-output/specs/spec-pweb/threading-model.md`).

Scope of "complete public C ABI": `api.h` plus the public C headers it
includes (`errors.h`, `types.h`, `macros.h`) — 17 entry points at this pin.
`version.h` contains compile-time version macros only, is not included by
`api.h`, and defines no ABI entry point or type; its exclusion from the
generated binding is deliberate (the macros would add surface without ABI).

These notes exist because the generated binding (`src/lib/`) intentionally
carries no upstream comments: `chet-cli`'s comment passthrough produces
Pascal that FPC rejects (dangling section keywords), so comments are stripped
at generation. The pinned headers stay the authority; this file records the
semantics Phase 2 depends on.

## Threading

- **`webview_run`** (`detail/backends/win32_edge.hh`, `run_impl`): blocking
  Win32 `GetMessageW` loop on the calling thread. Must run on the thread that
  called `webview_create` (WebView2 is bound to that STA thread).
- **`webview_terminate`** (`win32_edge.hh:401`): `PostQuitMessage(0)`.
  **Measured pitfall:** `PostQuitMessage` posts `WM_QUIT` to the *calling*
  thread's message queue. Called from a background thread it does **not**
  stop the GUI loop on Windows, despite the `api.h` remark that it is "safe
  to call from another background thread" (safe, yes — effective, no).
  Verified live during the CAP-1 smoke: a direct background-thread
  `webview_terminate` left the window open; routing it through
  `webview_dispatch` closed it. Cross-thread shutdown must travel
  worker -> `webview_dispatch` -> `webview_terminate` on the GUI thread —
  exactly the frozen threading model's direction of travel.
- **`webview_dispatch`** (`win32_edge.hh:405`): `PostMessageW(WM_APP,
  new dispatch_fn_t)` to a hidden message window — genuinely thread-safe and
  cross-thread on Windows. The closure runs on the GUI thread in `WndProc`
  (`win32_edge.hh:689`).
- **`webview_return`** (`c_api_impl.hh:243` -> `engine_base::resolve`):
  internally forwards through `dispatch(...)`, i.e. it only *posts* work; the
  JS-side resolution happens later on the GUI thread. This is what makes the
  frozen model's "workers call `webview_return()` directly" rule sound.
- All other entry points have **no thread-safety guarantee** (`api.h`
  comment on `webview_dispatch`); treat them as GUI-thread-affine, matching
  the frozen `IWebView` affinity rule.

## String lifetimes and ownership

- **Inbound `const char*` parameters** (`set_title`, `navigate`, `set_html`,
  `init`, `eval`, `bind` name, `return` id/result): converted to
  `std::string` inside the call (`c_api_impl.hh` passes them to
  `std::string`-taking C++ methods synchronously). The caller may free the
  buffer as soon as the C function returns. In particular
  **`webview_return` copies `id` and `result` before returning**
  (`c_api_impl.hh:243-251` -> `resolve(const std::string&, int,
  const std::string&)`, which captures copies into the dispatched closure,
  `engine_base.hh:119-130`). A runtime poisoned-buffer proof requires a live
  JS binding round-trip and lands with Phase 2's bind machinery; the source
  path above is unambiguous at this pin.
- **Bind-callback `id`/`req`**: the C shim passes `seq.c_str()` /
  `req.c_str()` of `std::string`s owned by the engine's message handler
  (`c_api_impl.hh:217-233`). They are valid **only during the callback** —
  copy immediately, before returning. Never stash the pointers.
- **`webview_version()`**: returns a pointer to a process-lifetime constant
  (`c_api_impl.hh:43-47`, `library_version_info`) — never free it.

## Userdata lifetimes

- **`webview_bind` `arg`**: stored in `binding_ctx_t` (`engine_base.hh:60`)
  until `webview_unbind` or instance destruction. Upstream never frees it —
  the caller owns it and must keep it alive while the binding exists.
- **`webview_dispatch` `arg`**: captured in a heap-allocated closure that is
  deleted after execution (`win32_edge.hh:689-693`). **If the dispatched
  closure never runs** (loop already quit, message window destroyed before
  the message is processed) the closure — and any cleanup the callback would
  have done for `arg` — is dropped: upstream depletes the queue on the
  destroy path only for owned windows (`win32_edge.hh:356-360`,
  `deplete_run_loop_event_queue`). Consequence for Phase 2: do not make
  dispatch closures the sole owner of resources; the scheduler's completion
  sink, not a dispatch closure, owns invocation state on the terminate path.

## WebView2 COM/STA expectations

- With a **null window** (upstream creates and owns the window), upstream
  itself calls `CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)` on the
  creating thread (`win32_edge.hh:519`, `com_init_wrapper.hh:74-91`), and
  uninitializes on destruction. `RPC_E_CHANGED_MODE` (thread already MTA)
  surfaces as an exception -> `webview_create` returns `NULL`.
- With an **existing window handle**, the host app is expected to have
  called `CoInitializeEx` with `COINIT_APARTMENTTHREADED` **before**
  `webview_create` (`api.h:50-53`, `win32_edge.hh:883-886`).
- WebView2 controller creation pumps a nested message loop inside
  `webview_create` until initialization completes (`win32_edge.hh:763-775`);
  a `WM_QUIT` during that pump aborts with `WEBVIEW_ERROR_CANCELED`.

## Embedded NUL

- The entire C ABI is `const char*` / NUL-terminated: an embedded NUL
  truncates at the first NUL on every boundary (all conversions go through
  `std::string(const char*)`). **No entry point can transport embedded
  NULs.** Pascal-side conversions must therefore reject or refuse strings
  containing #0 rather than silently truncating — this feeds the frozen wire
  rule "method: UTF-8, no embedded NUL" (`wire-semantics.md`); enforcement
  lives above the raw layer (Phase 2).

## Error codes

- `webview_error_t` is a 4-byte signed enum at this pin (measured by the
  paired ABI probes, `test/core/abi_probe.c` / `abi_probe.pas`): codes
  `-5..-1` are failures, `0` success, `1..2` informational
  (`WEBVIEW_ERROR_DUPLICATE` from `webview_bind` on a name collision,
  `WEBVIEW_ERROR_NOT_FOUND` from `webview_unbind` on a missing binding —
  `engine_base.hh:87-117`).
- Every C entry point is wrapped in `api_filter` (`c_api_impl.hh:49-78`):
  C++ exceptions are caught at the ABI boundary and mapped to codes; unknown
  exceptions become `WEBVIEW_ERROR_UNSPECIFIED`. No exception crosses the C
  ABI outward — and the same must hold inward: no Pascal exception may cross
  a callback frame (barrier rule, `threading-model.md`).
- **`webview_create` failure is `NULL`, not a code** (`c_api_impl.hh:91-103`
  discards the specific error). `WebViewCheckCreated`
  (`src/lib/pweb.lib.webview.errors.pas`) handles the nil explicitly and
  deliberately reports `WEBVIEW_ERROR_UNSPECIFIED` because the real code is
  unrecoverable at the C ABI.
