# Security model

Companion to `SPEC.md`. Invariant 4: **capability is contextual.** Frozen at Phase 0 because it shapes `ICapabilityPolicy` and the bridge's context object.

## The hook lands early, the policy lands late

Every invocation passes through `ICapabilityPolicy` from the **first bridge, in Phase 2** — long before this model is implemented. By Phase 2 `native.invoke()` is already the real generic pipeline, so `pweb.echo` simply travels through `TAllowAllCapabilityPolicy`.

Phase 8 then swaps the policy implementation. It never touches the RPC plumbing:

```
Phase 2   bridge → ICapabilityPolicy (TAllowAllCapabilityPolicy) → handler
Phase 8   bridge → ICapabilityPolicy (the model below)           → service
           ^^^^^^ unchanged
```

Retrofitting an authorization call site into a working RPC path is exactly the surgery this avoids.

## Capability grammar — v1

```text
[a-z0-9]+(\.[a-z0-9]+)*
```

**Exact matching only.** No wildcards, no regex, no implicit inheritance. `parking.read` authorises `parking.read` and nothing else — it does not imply `parking.read.details`, and `parking.*` is not a thing.

The authorization engine must be as unimaginative as possible: every clever matching rule is a future privilege-escalation bug wearing a convenience costume.

## What the policy receives — DECIDED

`ICapabilityPolicy` receives the **native invocation context plus the canonical method** — the same canonicalized value the router receives, produced by the single parse/validate/canonicalize point (`wire-semantics.md`). The method→capability mapping lives inside the policy implementation and its trusted configuration source; it never appears on the wire. Rules:

- **Unknown/unmapped method ⇒ deny.** Fail closed, always.
- **The policy runs before routing.** A refusal never touches the SOA layer; `forbidden` outranks `method_not_found`.
- The capability grammar above governs the vocabulary of the policy's configuration, not the wire's method syntax.

## Two levels, not one

Neither a purely static manifest nor purely runtime scoping. Both:

```
Static manifest
      =
ABSOLUTE MAXIMUM

Runtime context
      =
EFFECTIVE SUBSET
```

```
EffectiveCapabilities =
    AppMaximum
  ∩ PrincipalCapabilities
  ∩ WindowCapabilities
  ∩ RuntimeGrants
```

The manifest can only ever take rights away from what a principal is granted — it never grants.

**Intersection defaults — DECIDED:**

- An absent/unconfigured optional factor means **unrestricted** (the full set — no additional restriction).
- An explicitly configured **empty** set means **no rights**.
- `AppMaximum` is mandatory and explicit — an app without a ceiling has no capabilities.

**`AppMaximum` is a native trust anchor.** It comes from the executable, or from configuration at the same trust level as the executable. It is **never** granted or enlarged by `app.pwb`: the updatable bundle declares compatibility metadata only and cannot grant itself capabilities — otherwise whoever swaps the bundle both supplies the JavaScript and raises its own ceiling.

## Worked example

App manifest (the ceiling):

```
settings.read
settings.write
parking.read
parking.write
filesystem.read
window.control
```

`MainWindow`:

```
settings.read
settings.write
parking.read
parking.write
window.control
```

`LoginWindow`:

```
settings.read
window.control
```

`ReportingPlugin`:

```
parking.read
```

## Origin is never taken from JavaScript

The upstream `webview_bind` callback receives only:

```
request id
JSON request
user argument
```

There is no origin in its C contract. So this must never be trusted:

```json
{
  "origin": "pweb://app",
  "method": "filesystem.delete"
}
```

Pascal believing a JS-supplied origin would be security in the style of a "do not enter" sign.

## The context is built natively

```pascal
TInvocationContext
  WindowId       // optional / not-applicable for non-window principals (QuickJS, system)
  PrincipalId
  PrincipalKind
  Capabilities
  PluginId
  TrustedContent
```

It is built natively and attached at the binding, never carried in the payload. **Each enqueued invocation captures an immutable snapshot of it that stays alive until the invocation completes** — a worker never reads window-owned mutable state (see `threading-model.md`):

```
TWebView
   │
   └── TWebViewBindingContext
          │
          ├── Principal = MainWindow
          └── Capabilities = [...]
```

JavaScript sends `method + arguments`. Everything else comes from Pascal.

## Navigation policy (MVP rule)

```
Privileged WebView
    ↓
navigation allowed only to
pweb://app/...
```

**A privileged WebView never navigates to external content.** Every external navigation it attempts is cancelled, `https:` and `mailto:` included, and no navigation callback ever reaches an operating-system opener.

Approved `https:` and `mailto:` URIs may be handed to the operating system **only** through an explicit capability-authorized runtime invocation — `pweb.openExternal`, mapped to the capability `external.open` and checked by `ICapabilityPolicy` before the bridge, exactly like any other method. An external page therefore never executes inside a WebView that owns the privileged bridge, and opening one is an authorization decision rather than an inference from a gesture.

**Why not a gesture.** CAP-8B measured, on all four targets, that no engine reports user activation honestly: WebView2's `IsUserInitiated` and WebKitGTK's `is_user_gesture` are both TRUE for a navigation issued in the continuation of a `webview_bind` promise — the ordinary shape of a PWeb page — because the runtime resolves that promise through the engine's script-execution API, and WKWebView publishes no gesture flag at all. Every engine therefore has a different irreducible false positive, so "the user clicked" is not a decidable question and cannot be an authorization input. The classifier carries `UserActivated` for diagnostics only and is forbidden to read it.

**DECIDED — dev-mode trust model (implementation lands with Phase 10).** The privileged origin is `pweb://app` in development and production alike: `pweb dev` proxies/serves the Vite assets **behind `pweb://app`** rather than re-pointing the privileged origin at `127.0.0.1:<ephemeral>`. Vite HMR may use a narrowly scoped, development-only WebSocket connection (`ws://127.0.0.1:<selected-port>`) — a dev-only **transport** exception, never a privileged-**origin** exception. Production builds contain no localhost/WebSocket HMR allowance of any kind. Recorded now, implemented at Phase 10 — a dev mode that quietly relaxes the origin rule is how the rule dies.

If embedded external content is ever needed:

```
ExternalWebView
    │
    └── Capabilities = []
```

or an explicitly authorized, microscopic set.

## Principals

```
pkWindow
pkPlugin
pkSystem
pkQuickJS
```

Plugins are first-class principals, so QuickJS (CAP-9) reuses this system unchanged:

```
React MainWindow      QuickJS Plugin A
        │                  │
        ▼                  ▼
   InvocationContext (immutable snapshot per invocation)
          │
          ▼
   IInvocationScheduler
          │
          ▼
   IInvocationBridge
          │
          ▼
   ICapabilityPolicy
          │
          ▼
     TRestServer.Uri()
```

Every principal — WebView window or QuickJS plugin — enters through `IInvocationScheduler`; no principal calls `IInvocationBridge` directly.

The point of doing this now is to avoid two incompatible permission systems later — a thing humanity loves to build the moment it has two spare weeks of planning.
