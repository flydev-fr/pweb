# examples/07-quickjs — the plugin-enabled acceptance application

`quickjsapp` is the CAP-9 acceptance artifact: ONE desktop process in
which a real platform WebView and two isolated QuickJS plugins reach the
same mORMot service through the same runtime.

```
  real WebView UI ──▶ pweb://app ──▶ TypeScript SDK ──┐
                                                      ├─▶ ONE scheduler
  verified plugins.zip ──▶ generated native registry ─┘        │
        └─▶ isolated QuickJS plugin generation                 ▼
                                              ONE CAP-8 policy ─▶ ONE bridge
                                                                 ─▶ ONE mORMot
                                                                 ─▶ Add = 42
```

The WebView and QuickJS are **invocation sources**, nothing more. There is
no plugin-specific RPC route, no second permission system and no second
scheduler — and that is a measured fact, not a diagram: the gate asks the
scheduler itself whether it created both sources, and asks a second,
equally configured scheduler the same question to prove the predicate
discriminates.

## Layout

| path | what it is |
|---|---|
| `quickjsapp.pas` | the plugin-enabled host |
| `frontend/` | the acceptance page: the canonical CAP-5 `App` imported unmodified, plus the CAP-9C2 browser-invisibility probes |
| `plugins.trusted` | the build-time plugin list — build-time only, never shipped, carries no capability and no resource bound |
| `plugins/quickjs.calculator/` | the allowed principal (`calculator.add`) |
| `plugins/quickjs.reporting/` | the denied principal (`parking.read`) |

## Two archives, two security domains

`app.pwb` is browser content served through `pweb://app`. `plugins.zip` is
native package content read only by the QuickJS subsystem. They are two
different variables in `quickjsapp.pas`, each behind its own counting
store, and neither is ever assigned from the other. The browser cannot
reach the package — nine probe URIs, four script tags, an iframe, an image
and the raw engine channel all come back refused with the plugin store's
arrival counter at zero — and the plugins cannot reach the app bundle.

## Building and running it

The package, the generated registry and `LICENSE.quickjs` come from the
CAP-9C1 packager; the layout and the whole acceptance run come from one
gate:

```
pwsh -File test/cap9c1/run_quickjsrelease.ps1   # stages build/quickjs-release/
cd examples/07-quickjs/frontend && npm ci && npm run build && cd -
pwsh -File test/cap9c2/run_quickjsgui.ps1       # layout + real-GUI acceptance
```

On Linux and macOS the same two gates are `test/cap9c1/run_quickjsrelease.sh`
and `test/cap9c2/run_quickjsgui.sh` (run the latter under `xvfb-run -a` on
Linux).

## What it is not

No plugin discovery, no directory scanning, no file watching, no automatic
reload, no installation or update path, no signed third-party packages, no
public plugin format or API, and no network of any kind. Every lifecycle
transition is a native call made by trusted host code, and the runtime
trusts only the registry compiled into the executable.
