# Wire semantics

Companion to `SPEC.md`. Everything here is a property of the contract between JS and Pascal, not an implementation detail — so it is settled **before CAP-2**, not discovered during it.

Status legend: **DECIDED** is binding. **CANDIDATE** is a concrete proposal placed here to be attacked in review — better a proposal to massacre than a blank page. A candidate is ratified or replaced before the Phase 0 freeze closes; it is never silently promoted by being implemented.

## Protocol version — DECIDED

`app.pwb` can be updated independently of the native runtime, so the frontend and the backend can drift apart. Version the wire from day one:

```pascal
const
  PWEB_PROTOCOL_VERSION = 1;
```

An internal handshake returns at minimum:

```json
{
  "protocol": 1,
  "runtime": "0.1.0",
  "capabilities": [...]
}
```

No eighth interface is added for this — it lives on the existing bridge.

### Bundle-side declaration — DECIDED

The handshake is not the first line of defence. `manifest.json` inside the bundle declares its own requirements:

```json
{
  "pweb": {
    "protocol": 1,
    "minRuntime": "0.1.0"
  }
}
```

An incompatible bundle is refused **before its JavaScript is loaded at all** — cleaner than waiting for a handshake to fail behind the ceremonial white screen.

## Request grammar and limits — DECIDED

```text
method:
  UTF-8
  non-empty
  bounded length
  canonical Service.Method syntax

arguments:
  JSON object or null

request:
  configurable maximum size
  absolute security ceiling
```

**No raw mORMot route ever appears on the wire.** `UserService.Get` is valid; `/root/UserService.Get` is not. mORMot routing is an implementation detail of `IInvocationBridge`, and leaking it into the wire would make the frontend depend on the backend's routing scheme.

## Error contract — CANDIDATE

Envelope:

```json
{
  "code": "forbidden",
  "message": "Invocation is not allowed",
  "status": 403,
  "data": null
}
```

Stable code set:

```text
invalid_request     method_not_found    forbidden
busy                cancelled           service_error
internal_error      runtime_closed      protocol_mismatch
```

Rules that come with the candidate:

- Real mORMot/FPC exceptions **stay native-side**. The bridge maps them onto `service_error` or `internal_error`; it does not forward exception text, stack, SQL, or internal paths into a rendering context.
- In debug builds only, an optional `debug` block may carry more detail. It is absent from release builds by construction, not by configuration.
- A Pascal-side failure always **rejects** the promise; it never leaves it pending.

To challenge: whether `status` earns its place next to `code`, whether `data` should be typed per code, and whether `busy` (backpressure rejection) deserves a `Retry-After`-style hint.

## Lifecycle and cancellation — CANDIDATE

State model:

```text
Running
   ↓
Quiescing
   ↓
Closed
```

| State | Behaviour |
| --- | --- |
| `Running` | Accepts invocations normally. |
| `Quiescing` | Refuses new invocations, cancels queued ones, signals cancellation to in-flight work. |
| `Closed` | All use of the WebView handle is forbidden. A completion arriving after close is dropped. |

**Hard rule: the GUI thread never waits synchronously for the drain.** A worker command awaiting `webview_dispatch()` while the GUI thread blocks on that same drain is a deadlock, and it is the least reproducible bug the project could ship.

This answers the three cases that block the freeze:

1. *Window disappears mid-invocation* → transition to `Quiescing`, in-flight work is signalled, the caller sees `cancelled`.
2. *Worker completes after `webview_destroy()`* → the state is `Closed`, the completion is dropped, `webview_return()` against a dead handle never executes.
3. *Shutdown ordering* → the state machine owns it; neither thread improvises.

To challenge: the exact mechanism — lease, refcount, or cancellation token in `TInvocationContext` — and whether `Quiescing` needs a bounded timeout before forcing `Closed`.

## Why this precedes the freeze

`IInvocationScheduler` and `IInvocationBridge` cannot have ratified signatures until cancellation and error propagation are settled — both change the method set. Deciding them after CAP-2 means reopening the frozen core, which is exactly what the Phase 0 lock exists to prevent.
