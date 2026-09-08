# CAP-3 real mORMot RPC smoke

This example visibly and mechanically proves:

`JavaScript -> webview_bind -> scheduler -> policy -> TMormotInvocationBridge -> TRestServer.Uri() -> webview_return`

The page calls `CalculatorService.Add` with `{a:20,b:22}` and must render
`42 — PASS`. The process exits successfully only when the page reports `42`
and the service ran on a scheduler worker rather than the GUI thread.

Nothing has to be prepared first. Until the 2026-09-08 mORMot pin move this
compile had to run inside a patch window (`tools/patch-cap3u.ps1`), because
FPC 3.2.2 emitted no Win64 unwind metadata for mORMot's asm `CallMethod` and
returned `Currency` from the wrong register. The pin carries upstream
`896f1c1c` and `790154af`, and `test/cap3u` is what keeps both honest.

```powershell
$compiler = (Get-Command ppcx64 -ErrorAction Stop).Source
New-Item -ItemType Directory -Force build/fpc-cap3-example,build/example3 | Out-Null
& $compiler -MObjFPC -Sh -B -Xm `
  -FUbuild/fpc-cap3-example -Fusrc/lib -Fusrc/rpc -Fusrc/security `
  -Fusrc/webview -Fideps/mormot2/src -Fudeps/mormot2/src/core `
  -Fudeps/mormot2/src/lib -Fudeps/mormot2/src/crypt `
  -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
  -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest `
  -Fudeps/mormot2/src/soa -Fldeps/mormot2/static/x86_64-win64 `
  -FEbuild/example3 examples/03-mormot-rpc/mormotrpc.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3 example compile failed' }
Copy-Item build/webview-dist/webview.dll build/example3/
$env:PWEB_SMOKE_AUTOCLOSE_MS='3000'
build/example3/mormotrpc.exe
```

No HTTP server, REST client, socket, listener, or localhost endpoint exists.
The `TRestServer` is invoked directly in-process and is released only after
the scheduler has drained.
