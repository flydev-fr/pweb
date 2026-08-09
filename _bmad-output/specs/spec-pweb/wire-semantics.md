# Wire semantics

Companion to `SPEC.md`. Everything here is a property of the contract between JS and Pascal, not an implementation detail — so it is settled **before CAP-2**, not discovered during it.

Status: everything below is **DECIDED**. The candidates originally placed here to be attacked were ratified — with amendments — by the Phase 0 adversarial review (2026-08-09). Nothing remains a candidate.

## Protocol version — DECIDED

`app.pwb` can be updated independently of the native runtime, so the frontend and the backend can drift apart. Version the wire from day one:

```pascal
const
  PWEB_PROTOCOL_VERSION = 1;
```

The runtime conceptually exposes a **set** of supported protocols — `SupportedProtocols = {1}` today — so the compatibility predicate below never degenerates into an ordering comparison. The runtime version string is **SemVer by contract**.

The handshake is a runtime-owned method on the existing bridge — `pweb.handshake`, no eighth interface — returning at minimum:

```json
{
  "protocol": 1,
  "runtime": "0.1.0",
  "capabilities": [...]
}
```

Handshake `capabilities` are **advisory UI metadata only**. Authorization remains server-side and is evaluated for every invocation; an SDK must never enforce, cache-then-trust, or grant from this snapshot.

### Bundle-side declaration and load predicate — DECIDED

The handshake is not the first line of defence. `manifest.json` inside the bundle declares its own requirements:

```json
{
  "pweb": {
    "protocol": 1,
    "minRuntime": "0.1.0"
  }
}
```

The bundle is loaded **iff**:

```text
bundle.pweb.protocol ∈ runtime.SupportedProtocols
AND
SemVer(runtime.version) >= SemVer(bundle.pweb.minRuntime)
```

Rules:

- Version comparison is SemVer ordering, **never lexicographic** (`"0.10.0" > "0.9.0"`).
- A malformed or absent `pweb` block in a production bundle means **refuse**.
- The check runs **before any JavaScript from the bundle executes**.
- Refusal renders a native/runtime-owned error surface — never HTML or JS from the rejected bundle.

## Request grammar and limits — DECIDED

```text
method:
  UTF-8
  non-empty
  no embedded NUL
  bounded length
  case-sensitive, exact canonical spelling
  application form: Service.Method
  runtime-reserved namespace: pweb.*

arguments:
  JSON object or null
  NAMED ARGUMENTS ONLY in protocol v1 — no positional array form

request:
  configurable maximum size
  absolute security ceiling
```

**Reserved namespace.** Methods whose first segment is `pweb` are runtime-owned — `pweb.handshake`, `pweb.echo`. Applications may not register `pweb.*` methods; the runtime refuses such a registration at startup.

**Named arguments are the wire contract.** `{"a": 20, "b": 22}`, never `[20, 22]`. Parameter names are therefore part of the public RPC contract: renaming a Pascal RPC parameter is a breaking API change, subject to the same compatibility discipline as renaming the method itself.

**One canonicalization point.** The method is parsed, validated, and canonicalized exactly once, before policy. The identical canonical value is then supplied to `ICapabilityPolicy` and to the `IInvocationBridge` router. Method comparison is case-sensitive and exact; the mORMot adapter must reject case variants even where mORMot itself would resolve them case-insensitively.

**No raw mORMot route ever appears on the wire.** `UserService.Get` is valid; `/root/UserService.Get` is not. mORMot routing is an implementation detail of `IInvocationBridge`, and leaking it into the wire would make the frontend depend on the backend's routing scheme.

## Error contract — DECIDED

Envelope:

```json
{
  "code": "forbidden",
  "message": "Invocation is not allowed",
  "status": 403,
  "data": null
}
```

Stable code set for protocol v1 — nine codes, deliberately without `unauthorized` (no bridge authentication step exists that would naturally produce it):

```text
invalid_request     method_not_found    forbidden
busy                cancelled           service_error
internal_error      runtime_closed     protocol_mismatch
```

**`code` is the only normative discriminator.** `status` is informative/derived, frozen with protocol v1 by the table below; SDK and application logic switch on `code`, never on `status`.

| code | status (informative) |
| --- | --- |
| `invalid_request` | 400 |
| `method_not_found` | 404 |
| `forbidden` | 403 |
| `busy` | 429 |
| `cancelled` | 499 |
| `service_error` | 422 |
| `internal_error` | 500 |
| `runtime_closed` | 503 |
| `protocol_mismatch` | 426 |

> Amendment (2026-08-09, human freeze review): `protocol_mismatch` status changed 505 → 426 (Upgrade Required) before any implementation shipped; protocol v1 freezes it at 426.

Rules:

- **`service_error.data` is the sanctioned application-defined channel** for structured domain errors, authored deliberately by service code:

  ```json
  {
    "code": "service_error",
    "message": "Insufficient funds",
    "status": 422,
    "data": {
      "domainCode": "insufficient_funds"
    }
  }
  ```

- **Unhandled exceptions map to `internal_error` with `data: null`.** Real mORMot/FPC exceptions stay native-side. Release builds never expose Pascal exception class names, stack traces, SQL, filesystem paths, or other implementation detail across the bridge.
- `busy` may carry an optional retry hint: `data.retryAfterMs` (number). All other codes carry `data: null` in release builds, except `service_error` as above.
- In debug builds only, an optional `debug` block may carry more detail. It is absent from release builds by construction, not by configuration, and is never part of the stable public contract.
- A Pascal-side failure always **rejects** the promise; it never leaves it pending.

### The bridge result is discriminated — DECIDED

`IInvocationBridge` returns a discriminated result:

```text
Success(any valid JSON value)   |   Error(canonical error envelope)
```

It must **not** return an ambiguous raw JSON string whose meaning depends on WebView transport status. The WebView source maps the two arms onto `webview_return`'s status; QuickJS and native sources map the same discriminated result using their own transport semantics. A success value that happens to look like an error envelope is still a success.

## Lifecycle and cancellation — DECIDED

The lifecycle belongs to an **invocation source** — a WebView binding is one source, a QuickJS host a future other — not to the WebView type:

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
| `Quiescing` | Refuses new invocations immediately. Queued invocations are completed as `cancelled`. In-flight work receives cooperative cancellation and may finish. |
| `Closed` | All use of the source's native handle is forbidden. A late completion attempt is swallowed by the exactly-once gate; it never touches the handle. |

**Exactly-once completion.** An invocation has exactly one completion, delivered through an idempotent **completion sink**: the first completion wins, subsequent attempts are dropped, and backpressure slots are released at completion — not when worker execution ends. Cancellation completes the invocation with `cancelled`; a late worker result is discarded by the gate.

**Two mechanisms, both required — they protect different things:**

- **Cancellation token** — protects invocation/work lifetime. Cooperative: in-flight work observes it; nothing is forcibly aborted.
- **Handle-use lease** — protects the native handle. Every worker-side operation touching a WebView native handle (`webview_return`, `webview_dispatch`, script evaluation) acquires a lease covering **only that short native-handle operation, never the whole service execution**. No new leases are granted once the close transition begins. WebView destruction is **deferred onto the GUI loop** and runs only after outstanding handle-use leases have drained. A quiesce timeout must never destroy a native handle while a lease is held — because leases are short, that drain is bounded and quick.

**Hard rule: the GUI thread never waits synchronously for the drain.** It schedules the deferred destruction; it does not block on it. A worker command awaiting `webview_dispatch()` while the GUI thread blocks on that same drain is a deadlock, and it is the least reproducible bug the project could ship.

**Bounded quiesce timeout.** `Quiescing` has a bounded, configurable timeout before forcing the close transition; its default value is an implementation detail, not part of the wire protocol. Forcing the transition means in-flight work loses the ability to acquire new leases — its eventual completion dies at the gate without touching the handle.

**Source shutdown vs runtime shutdown are distinct events** that reuse the same primitives. Closing one source (a window) quiesces that source only. Whole runtime/scheduler shutdown quiesces every source, drains the worker pool, and only then releases the service layer — so no worker can reach a freed service.

This answers the three cases that blocked the freeze:

1. *Window disappears mid-invocation* → its source enters `Quiescing`; the token is signalled; the promise is completed `cancelled` through the sink; a later worker result is dropped by the exactly-once gate.
2. *Worker completes after `webview_destroy()`* → the lease acquisition fails; the completion attempt dies without executing `webview_return()` against a dead handle.
3. *Shutdown ordering* → the state machine and the lease own it; destruction is deferred onto the GUI loop after handle-use leases drain; neither thread improvises.

## Why this preceded the freeze

`IInvocationScheduler` and `IInvocationBridge` could not have ratified signatures until cancellation and error propagation were settled — both change the method set. They now are: the signatures are written against the exactly-once sink, the token/lease pair, and the discriminated result above. Deciding them after CAP-2 would have meant reopening the frozen core, which is exactly what the Phase 0 lock exists to prevent.
