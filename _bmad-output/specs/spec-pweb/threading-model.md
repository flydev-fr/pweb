# Threading model

Companion to `SPEC.md`. Invariant 1: **the UI thread is sacred.** Frozen at Phase 0 because it shapes `IInvocationScheduler` and `IInvocationBridge`.

## Basis in upstream

Upstream `webview/webview` states that the thread calling `webview_run()` is the GUI thread, that its functions carry no general thread-safety guarantee, and that `webview_dispatch()` is the way to get back onto that thread. It also documents `webview_return()` as explicitly thread-safe, performing whatever dispatch it needs itself.

Upstream does **not** document which thread invokes a `webview_bind` callback. PWeb therefore treats the callback as UI-affine by internal convention — the safe reading.

## Nominal path: RPC on a worker pool

```
                    GUI THREAD
                        │
                  webview_run()
                        │
                        ▼
                  webview_bind()
                        │
              parse / enqueue only
                        │
                        ▼
               ┌─────────────────┐
               │   WORKER POOL   │
               │                 │
               │ capabilities    │
               │ TRestServer.Uri │
               │ SOA / ORM       │
               └────────┬────────┘
                        │
                        ▼
                 webview_return()
                   thread-safe
                        │
                        ▼
                   JS Promise
```

What the bind callback is allowed to do, and nothing more:

```
validate size
copy id / request
capture InvocationContext
enqueue
return
```

Explicitly forbidden inside the callback: SQLite, disk I/O, SOA calls, heavy crypto — anything that can block.

## Return path

Call `webview_return()` from the worker directly. Do **not** do this:

```
worker
  ↓
webview_dispatch()
  ↓
webview_return()
```

It is redundant; `webview_return()` already knows how to get back to the GUI correctly.

## GUI-affine commands go the other way

For operations that genuinely belong to the GUI thread — `window.setTitle`, `window.minimize`, `window.close`:

```
RPC worker
   ↓
webview_dispatch()
   ↓
GUI operation
```

This is exactly what upstream defines `webview_dispatch()` for: scheduling code on the GUI loop thread.

## Backpressure

Planned from the start, per WebView:

- maximum simultaneous invocations
- maximum queue size

A React UI can produce hundreds of requests with almost artistic ease. Limits are configurable; the mechanism is fixed, the numbers are chosen at implementation time.

## Ordering

No ordering guarantee between concurrent invocations. This:

```ts
const a = native.invoke(...);
const b = native.invoke(...);
```

may complete `b` then `a`. That is correct behaviour, not a bug. Callers that need ordering either await sequentially:

```ts
await native.invoke(A);
await native.invoke(B);
```

or rely on transactional semantics provided by the service itself.
