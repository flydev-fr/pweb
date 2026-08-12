# CAP-5 React over the TypeScript SDK

A real React 18 application that reaches the backend exclusively through
the `@pweb/runtime` TypeScript SDK (`sdk/typescript/`) — never through the
raw CAP-2 primitive:

`React -> invoke()/handshake() -> __pweb_invoke -> scheduler -> policy -> TMormotInvocationBridge -> TRestServer.Uri()`

The page performs `pweb.handshake` (protocol gate), invokes
`CalculatorService.Add` with `{a:20,b:22}`, renders `42`, and reports the
machine verdict. The host gates on
`ok/handshake/secure/rendered/rpc + value 42` plus the worker-thread
proof, and exits 0 only on full success. Assets are served over the
CAP-4 `pweb://app` path (`TFolderAssetStore` over the built `dist/`).

Build the frontend (pinned lockfile, offline esbuild bundle — no dev
server, no CDN). The SDK must be built first: `@pweb/runtime` is a
`file:` link whose exports point at `sdk/typescript/dist/`:

```powershell
cd sdk/typescript
npm ci
npm run build
cd ../../examples/04-react/frontend
npm ci
npm run typecheck
npm run build   # -> dist/
```

Build the host inside the CAP-3U window (`test/cap5/build_cap5_hosts.ps1`
does exactly this for both CAP-5 hosts), stage `webview.dll` next to the
executable, then run:

```powershell
$env:PWEB_SMOKE_AUTOCLOSE_MS = '10000'
.\reactapp.exe examples\04-react\frontend\dist
```

(`pwsh test/cap5/run_cap5_smokes.ps1` performs the staging and both runs
with the machine verdict.)

Expected: the window renders `CalculatorService.Add(20, 22) = 42` and the
log ends with `reactapp: React -> SDK -> scheduler -> mORMot -> 42 over
pweb://app PASS`.

The host is line-identical to `examples/05-pas2js/pas2jsapp.pas` apart
from the window title and log prefix — no backend code branches on
frontend kind.
