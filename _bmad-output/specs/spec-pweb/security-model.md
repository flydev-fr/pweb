# Security model

Companion to `SPEC.md`. Invariant 4: **capability is contextual.** Frozen at Phase 0 because it shapes `ICapabilityPolicy` and the bridge's context object.

## The hook lands early, the policy lands late

Every invocation passes through `ICapabilityPolicy` from the **first bridge, in Phase 2** — long before this model is implemented. By Phase 2 `native.invoke()` is already the real generic pipeline, so `echo` simply travels through `TAllowAllCapabilityPolicy`.

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
  WindowId
  PrincipalId
  PrincipalKind
  Capabilities
  PluginId
  TrustedContent
```

It is attached to the bridge instance, not carried in the payload:

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

`https:` and `mailto:` links open in the system browser. An external page therefore never executes inside a WebView that owns the privileged bridge.

**Open before Phase 10 — the dev-mode hole.** `pweb dev` runs Vite HMR on `127.0.0.1:<ephemeral>`, which the rule above would refuse. Two candidate models: trust that origin explicitly in dev builds only, or proxy the Vite assets behind `pweb://app` so the privileged origin never changes. Not urgent to implement, but the trust model is written down before the CLI ships — a dev mode that quietly relaxes the origin rule is how the rule dies.

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
React MainWindow
        │
        ├──────────┐
        │          │
QuickJS Plugin A   │
        │          │
        ▼          ▼
   InvocationContext
          │
          ▼
   CapabilityPolicy
          │
          ▼
     TRestServer.Uri()
```

The point of doing this now is to avoid two incompatible permission systems later — a thing humanity loves to build the moment it has two spare weeks of planning.
