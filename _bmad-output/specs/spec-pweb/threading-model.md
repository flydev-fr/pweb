# Threading model

Companion to `SPEC.md`. Invariant 1: **the UI thread is sacred.** Frozen at Phase 0 because it shapes `IInvocationScheduler` and `IInvocationBridge`.

## Basis in upstream

Upstream `webview/webview` states that the thread calling `webview_run()` is the GUI thread, that its functions carry no general thread-safety guarantee, and that `webview_dispatch()` is the way to get back onto that thread. It also documents `webview_return()` as explicitly thread-safe, performing whatever dispatch it needs itself.

Upstream does **not** document which thread invokes a `webview_bind` callback. PWeb therefore treats the callback as UI-affine by internal convention — the safe reading.

## Invocation sources, not WebViews

`IInvocationScheduler` is defined over **invocation sources**, never over WebViews. A source conceptually owns:

- its lifecycle state (`Running → Quiescing → Closed`, see `wire-semantics.md`)
- its completion sink
- its backpressure limits
- its cancellation scope

The WebView binding is one source. QuickJS is a future source. A future native caller may be another. Every source travels the same road:

```text
source → IInvocationScheduler → IInvocationBridge → ICapabilityPolicy → service
```

QuickJS goes **through `IInvocationScheduler`**; it must not call `IInvocationBridge` directly. Consequently `pweb.rpc.intf.pas` remains independent of every `pweb.webview.*` unit.

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
capture an immutable InvocationContext snapshot
enqueue
return
```

Explicitly forbidden inside the callback: SQLite, disk I/O, SOA calls, heavy crypto — anything that can block.

### Synchronous pre-queue rejection — the one ratified exception

The callback may synchronously complete an invocation that **never enters the queue** — `invalid_request` (oversize, malformed, bad grammar), `busy` (queue full), `runtime_closed` — by calling `webview_return()` directly on the callback thread. Everything successfully enqueued completes through the scheduler's completion sink.

**Enqueue is always non-blocking.** A full queue returns `busy` immediately; the GUI callback never waits for queue capacity.

## Exactly-once completion

An invocation has exactly one completion, delivered through an idempotent completion sink (see `wire-semantics.md`):

- first completion wins; later attempts are dropped
- backpressure slots release at completion, not at worker exit
- cancellation completes the invocation with `cancelled`; a late worker result dies at the gate
- a GUI-affine invocation completes from its dispatched GUI closure, through the same sink
- a dispatch that will never run (runtime terminating) is completed-as-cancelled by teardown, and its captured context is freed by the scheduler — never by hoping the GUI loop still runs it

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

## Leases and tokens — two mechanisms, both required

- The **cancellation token** protects invocation/work lifetime. Cooperative only.
- The **handle-use lease** protects the native handle. Every worker-side operation touching a WebView native handle (`webview_return`, `webview_dispatch`, script evaluation) acquires a lease covering **only that short operation — never the whole service execution**. No new leases once the close transition begins; destruction is deferred onto the GUI loop after leases drain; a quiesce timeout never destroys a handle while a lease is held.

The GUI thread never synchronously waits for worker drain — it schedules the deferred close and keeps pumping.

## Ownership at the C boundary

- The object behind `webview_bind` userdata is owned by the binding; its lifetime strictly encloses the interval from `webview_bind` through `webview_unbind`/destroy. Unbind happens on the GUI thread during `Quiescing`, before destroy.
- Each queued invocation owns an **immutable snapshot** of `TInvocationContext`, alive until the invocation completes — a worker never reads window-owned mutable state.
- **Pascal exceptions must never escape any C callback.** Every C callback body (bind, dispatch) is an exception barrier; a failure inside it becomes an `internal_error` completion, never a longjmp across the C frame.

## GUI-affine commands go the other way

For operations that genuinely belong to the GUI thread — `window.setTitle`, `window.minimize`, `window.close`:

```
RPC worker
   ↓
webview_dispatch()
   ↓
GUI operation
```

This is exactly what upstream defines `webview_dispatch()` for: scheduling code on the GUI loop thread. The dispatch is fire-and-forget from the worker's perspective; the invocation completes from the GUI closure through the sink.

`IWebView` operations are GUI-thread-affine unless a method's contract explicitly documents otherwise; cross-thread callers use the dispatch + lease machinery above. `webview_return` remains the specific upstream-documented thread-safe exception.

## Backpressure

Planned from the start, **per invocation source**:

- maximum simultaneous invocations
- maximum queue size

A React UI can produce hundreds of requests with almost artistic ease — and a QuickJS plugin can do the same, which is why the bounds attach to the source, not to the WebView type. Limits are configurable; the mechanism is fixed, the numbers are chosen at implementation time.

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
