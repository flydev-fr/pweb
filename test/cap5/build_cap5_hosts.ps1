# Compiles the CAP-5 host examples (reactapp, pas2jsapp) against the PRISTINE
# pinned mORMot. They reuse the real CAP-3 bridge, so they drive mORMot's
# Win64 asm CallMethod; until the 2026-09-08 pin move that meant compiling
# inside a window opened by tools/patch-cap3u.ps1 and restored afterwards.
# The pin now carries upstream 896f1c1c (the Win64 SEH unwind) and 790154af
# (Currency in RAX), so there is no window, no patch and nothing to restore -
# and test/cap3u is the gate that keeps the upstream fix honest.
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force build/cap5/react-fpc,
    build/cap5/p2j-fpc, build/cap5/bin | Out-Null
foreach ($app in @(
    @{ fpcDir = 'build/cap5/react-fpc'
       source = 'examples/04-react/reactapp.pas' },
    @{ fpcDir = 'build/cap5/p2j-fpc'
       source = 'examples/05-pas2js/pas2jsapp.pas' })) {
    fpc -MObjFPC -Sh -B -Xm `
        ('-FU' + $app.fpcDir) -FEbuild/cap5/bin `
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview `
        -Fusrc/assets -Fusrc/platform/windows `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core `
        -Fudeps/mormot2/src/lib -Fudeps/mormot2/src/crypt `
        -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
        -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest `
        -Fudeps/mormot2/src/soa `
        -Fldeps/mormot2/static/x86_64-win64 `
        $app.source
    if ($LASTEXITCODE -ne 0) {
        throw "CAP-5 host compile failed: $($app.source)"
    }
}
Write-Host 'CAP-5 host examples compiled against the pristine pinned mORMot'
