# CAP-5 Pas2JS over the pweb.native SDK

A real Pas2JS-compiled browser application that reaches the backend
exclusively through the `pweb.native` Pas2JS SDK (`sdk/pas2js/`) — the
browser-loaded JS originates from Pas2JS compilation, not handwritten
JavaScript:

`Pas2JS -> PWebInvoke/PWebHandshake -> __pweb_invoke -> scheduler -> policy -> TMormotInvocationBridge -> TRestServer.Uri()`

Identical logical call to the React example — same method spelling
`CalculatorService.Add`, same named arguments `{a:20,b:22}`, same `42` —
through the exact same native primitive, binding, scheduler, policy and
bridge. The captured-wire parity gate in CI proves the two SDKs emit
semantically identical requests.

Build the frontend with the pinned toolchain (`tools/get-pas2js.ps1`
fetches pas2js 3.0.1 by checksum into `deps/pas2js`):

```powershell
pwsh tools/get-pas2js.ps1
pwsh examples/05-pas2js/frontend/build.ps1   # -> frontend/dist/
```

Build the host inside the CAP-3U window (`test/cap5/build_cap5_hosts.ps1`
does exactly this for both CAP-5 hosts), stage `webview.dll` next to the
executable, then run:

```powershell
$env:PWEB_SMOKE_AUTOCLOSE_MS = '10000'
.\pas2jsapp.exe examples\05-pas2js\frontend\dist
```

(`pwsh test/cap5/run_cap5_smokes.ps1` performs the staging and both runs
with the machine verdict.)

Expected: the window renders `CalculatorService.Add(20, 22) = 42` and the
log ends with `pas2jsapp: Pas2JS -> SDK -> scheduler -> mORMot -> 42 over
pweb://app PASS`.

The host is line-identical to `examples/04-react/reactapp.pas` apart from
the window title and log prefix — no backend code branches on frontend
kind.
