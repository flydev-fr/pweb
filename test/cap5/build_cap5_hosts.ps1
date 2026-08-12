# Compiles the CAP-5 host examples (reactapp, pas2jsapp) inside a
# re-applied CAP-3U window. They reuse the real CAP-3 bridge, so the
# pinned mORMot trampoline must be active during their compile; the
# window is restored and re-verified pristine afterwards, leaving every
# earlier CI gate intact.
$ErrorActionPreference = 'Stop'

try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-5 CAP-3U re-apply failed' }
    New-Item -ItemType Directory -Force build/cap5/react-fpc,
        build/cap5/p2j-fpc, build/cap5/bin | Out-Null
    foreach ($app in @(
        @{ fpcDir = 'build/cap5/react-fpc'
           source = 'examples/04-react/reactapp.pas' },
        @{ fpcDir = 'build/cap5/p2j-fpc'
           source = 'examples/05-pas2js/pas2jsapp.pas' })) {
        fpc -MObjFPC -Sh -B -Xm -dPWEB_CALLMETHOD_UNWIND_PROBE `
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
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-5 CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-5 restore' }
if (Test-Path deps/mormot2/src/core/x64callmethod.obj) {
    throw 'CAP-3U object survived CAP-5 restore'
}
Write-Host 'CAP-5 host examples compiled; CAP-3U window restored pristine'
