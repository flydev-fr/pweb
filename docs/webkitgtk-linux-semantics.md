# WebKitGTK/Linux semantics for the pinned webview commit

Pinned commit: `cbbdee44afff22867de9fd88a9fc8350d9bdd399` (see `webview.lock`).
Companion to `webview-upstream-semantics.md`, which records the same kind of
facts for the Windows/WebView2 backend. Every statement below was **measured**
on the ratified Linux baseline, not transcribed from documentation:

```
GTK 3 (gtk+-3.0) + WebKitGTK API 4.1 (webkit2gtk-4.1, libsoup3)
x86_64, glibc, FPC 3.2.2/3.2.3
```

The baseline is pinned in `webview.lock` (`linux-webkitgtk-api`,
`linux-gtk-api`, `linux-soname`) and **asserted** at build time — upstream's
`pkg_search_module` fallback chain (`webkitgtk-6.0 → 4.1 → 4.0`) must never be
the thing that decides which engine the product is built against.

## The seam: no upstream patch, still 17 exports

The Linux port reaches `pweb://app` through the native handle upstream already
exposes. Nothing in `deps/webview` is patched, and the public C ABI stays at
exactly 17 entry points (`test/cap7l/check_webview_exports.sh`, `nm -D`).

```
webview_get_native_handle(w, BROWSER_CONTROLLER)  -> WebKitWebView*
  webkit_web_view_get_context                     -> WebKitWebContext*
  webkit_web_context_get_security_manager
      register_uri_scheme_as_secure("pweb")
      register_uri_scheme_as_cors_enabled("pweb")
  webkit_web_context_register_uri_scheme("pweb", handler, cell, destroy)
```

On GTK the `BROWSER_CONTROLLER` handle **is** the `WebKitWebView` (it is the
same pointer as `UI_WIDGET`). `webview_create` builds that view and navigates
nowhere, so the whole sequence fits between `webview_create` and the first
`webview_navigate` — which is exactly where the examples attach it.

Measured result, stated by JavaScript on the loaded page rather than inferred
from "it rendered":

```json
{"protocol":"pweb:","host":"app","origin":"pweb://app","secure":true}
```

CSS applied (computed style compared against a known value),
`fetch('pweb://evil/x')` refused. This is the same classification Windows gets
from `HasAuthorityComponent` + `TreatAsSecure`, reproduced under `xvfb-run`
with `DISPLAY` set and `WAYLAND_DISPLAY` unset — the hosted-runner condition.

## Five constraints that are not obvious, and cost a day each if rediscovered

### 1. A URI scheme can be registered ONCE per context, and never removed

`webkit_web_context_register_uri_scheme` refuses a second registration of the
same scheme on the same context:

```
CRITICAL **: Cannot register URI scheme pweb more than once
```

It leaves the **first** handler installed, and WebKitGTK 4.1 offers no
unregister call to undo it with. Upstream creates its views with
`webkit_web_view_new()`, which uses the shared **default** context — so the
second window in a process, and far more commonly the second create/destroy
cycle of a repeated-lifecycle test, hits this immediately.

Consequence for the adapter (`src/platform/linux/pweb.platform.webkitgtk.pas`):
teardown is a **disown**, not a removal. The callback's `user_data` is a heap
cell holding an owner pointer; `Detach` clears the owner with one interlocked
store, after which the callback answers a constant error finish for every
request. A later handler on the same context **re-owns** the installed cell
instead of registering again. Two live handlers on one context are refused
outright — a single callback cannot honestly serve two stores.

### 2. The destroy-notify runs after FPC's heap is gone

GLib finalises the default `WebKitWebContext` from a **libc atexit handler**:

```
__run_exit_handlers -> g_object_unref -> (WebKit) -> our GDestroyNotify
```

libc runs atexit handlers **after** FPC's unit finalization has already shut
the heap manager down. An earlier revision allocated the registration cell
with `New` and released it with `Dispose` in that callback. The observable
result was a completely successful run — verdict PASS, `clean exit` printed —
that then exited **217** (FPC's unhandled-exception code) with no message,
because `Dispose` faulted inside the dead heap.

So: the cell is a **GLib** allocation released with `g_free`, and the table
tracking it is **static** storage, not a dynamic array (whose backing store is
also gone by then). Nothing in that callback may touch the FPC heap or any
managed type.

### 3. FPC leaves the FPU traps unmasked; GTK cannot survive that

FPC starts a Linux process with the SSE and x87 invalid-operation,
divide-by-zero and overflow traps **unmasked**. GTK, Cairo, Pango and WebKit
all compute with NaNs, infinities and denormals as ordinary intermediate
values, so the first such computation traps inside a C frame with no handler:

```
FAIL: EInvalidOp: Invalid floating point operation
```

— immediately, before one pixel or one asset is served. The adapter masks the
six exceptions in its `initialization`, because linking that unit *is* the
decision to host WebKitGTK in the process.

It does so through the System primitives (`Set8087CW`, `SetSSECSR`), **not**
`math.SetExceptionMask`. Measured: pulling in the `math` unit reintroduced the
217 exit above, because `math`'s finalization restores the FPU control words
while mORMot's units — which initialise earlier and therefore finalise later —
then go on doing floating point with the traps live again. Owning the two
registers directly leaves nothing to unwind.

### 4. `webkit_uri_scheme_request_get_path()` discards the authority

For `pweb://evil/x` it returns `/x`. Using it would hand a wrong-authority
request to `IAssetStore` as though it named a legitimate asset.

This matters far more on GTK than on Windows: a WebView2 filter is registered
as `pweb://app/*`, so a wrong authority never reaches the handler at all,
whereas a GTK URI scheme is registered **scheme-wide** and the wrong authority
really does arrive. Only `..._get_uri()` is ever consulted, and the whole URI
goes to `PWebParseAppUri`, which is the only thing that checks the authority.

### 5. A refusal has no status code

`webkit_uri_scheme_request_finish` carries no HTTP status. A refusal is
`webkit_uri_scheme_request_finish_error`, which makes `fetch()` **reject**,
where WebView2 answers a constant 404 with an empty body.

Both mean "refused, nothing served", and the shared frontend fixture accepts
either shape (`examples/06-assets/frontend/dist/assets/app.js`). The Pascal
adapter uses one constant `GError` for every refusal — wrong authority,
non-canonical path, missing asset and internal failure are indistinguishable
to the page, exactly like the Windows constant 404.

## Linkage, sonames and the release layout

- `cmake -DWEBVIEW_WEBKITGTK_API=4.1` on the pinned commit resolves
  `webkit2gtk-4.1 2.52.3` + `gtk+-3.0 3.24.41`, C++11, and builds
  `libwebview.so.0.12.0` with SONAME `libwebview.so.0.12`, exactly 17
  default-visibility exports and no version script. The two CAP-4W-patched
  files are Windows-only and inert here.
- **FPC records the SONAME as `DT_NEEDED`, not the chet `LibraryName`.** The
  binding says `external 'libwebview.so'`; the linker reads the SONAME out of
  that file and writes `libwebview.so.0.12`. So the release layout ships the
  **versioned** name, and the bare `.so` is a dev-only link-time convenience.
- `-k'-rpath=$ORIGIN'` yields `RUNPATH=$ORIGIN`. The application then runs from
  an unrelated working directory with only the `.so` beside it and no
  `LD_LIBRARY_PATH` at all (proven with `env -u LD_LIBRARY_PATH` and `cd /`).
- Hiding the library fails deterministically and names it:

  ```
  releaseapp: error while loading shared libraries: libwebview.so.0.12:
  cannot open shared object file: No such file or directory
  ```

  with exit **127** — the same model as a missing `webview.dll` on Windows.
- The private WebKitGTK/GLib externals are declared against exact distro
  sonames (`libwebkit2gtk-4.1.so.0`, `libgio-2.0.so.0`, `libgobject-2.0.so.0`,
  `libglib-2.0.so.0`) and FPC records those verbatim as `DT_NEEDED`. Every one
  of them is proven present with `nm -D` by `test/cap7l/check_abi.sh`.

## Threading

The frozen model holds unchanged, and was re-proven on this backend:

- the bind callback runs on the **GUI thread**;
- a detached worker calling `webview_return` **directly** resolves the JS
  promise — eight concurrent invocations all resolve, exactly once each;
- no GTK call runs on the worker, because upstream's `webview_return` forwards
  through `engine_base::resolve` → `dispatch` → `g_idle_add_full`.

`webview_dispatch` remains the only cross-thread route for anything else, and
the watchdog in `test/cap7l/cap7l_probe.c` uses it to terminate.

## The one documented ABI delta

MSVC types every C enum as signed `int`; gcc picks unsigned when no enumerator
is negative. So the Linux C probe reports

```
signed.webview_hint_t=0                 (Pascal binding: 1)
signed.webview_native_handle_kind_t=0   (Pascal binding: 1)
```

while `webview_error_t` — which has negative enumerators — is signed on both.
Width is 4 bytes everywhere and every transported value is `0..3`, so the
calling convention is untouched. `test/cap7l/check_abi.sh` compares all 36
facts and permits **exactly** those two lines with exactly those values; the
14-fact WebKitGTK/GLib probe pair permits **no** delta at all.

## Bundle bytes are per-toolchain, not universal

`app.pwb` is deterministic — same inputs on the same toolchain always produce
the same bytes, and `WriterDeterminism` proves it on each platform — but the
DEFLATE stream comes from the mORMot static compression object for the target,
and the `x86_64-linux` and `x86_64-win64` statics do not emit byte-identical
output for identical input. The golden-bytes pin in
`test/assets/pweb.test.bundle.pas` therefore carries one measured constant per
toolchain. Cross-platform byte-identical bundles are **not** a property this
project has ever claimed, and are not one it currently has.
