# CAP-10D1 (Windows): stage the packaging kit into the ONE SDK root and
# build the packaging suite and its interrupt driver.
#
# The Windows twin of build_cap10d1.sh, making the identical claims in the
# identical order plus the half only this platform has: the pinned Inno
# Setup compiler, the pinned WebView2 artifacts, the pinned SDK loader and
# the two compiled CAP-13 setup helpers.
#
# NOTHING HERE DOWNLOADS ANYTHING. The pinned artifacts are provisioned by
# tools/get-innosetup.ps1 and tools/get-webview2-runtime.ps1, which CI has
# already run for the CAP-6b1/6b2/6b3 steps; this script COPIES what those
# left under deps/ into the SDK root, and refuses with the script's name
# when one is absent. That is the same refusal `pweb build --profile` makes,
# made one layer earlier so a missing artifact fails the build step rather
# than the gate.
#
# Produces, under build/cap10d1/:
#   iso/    the isolation compiles of pweb.cli.tar and pweb.cli.package
#   bin/    d1tests.exe       the CAP-10D1 suite
#           pwebpackdrv.exe   the real-`pweb build --profile` driver
#
# THE SUITE IS COMPILED WITH -dPWEB_LAYOUT_FAULTS, and it is the ONLY
# compile in this repository that is - see the .sh twin's header.
#
# Usage: pwsh test/cap10d1/build_cap10d1.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$share = Join-Path $sdk 'share/pweb'
foreach ($pre in (Join-Path $sdk 'bin/pweb.exe'),
                 (Join-Path $sdk 'bin/pwebbundle.exe'),
                 (Join-Path $share 'deps/mormot2/src/core/mormot.core.base.pas')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run test/cap10b1/build_cap10b1.ps1 " +
            'and test/cap10c1/build_cap10c1.ps1 first')
    }
}

$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10D1 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10D1] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

# --- 1. the packaging kit: the manifests -------------------------------------
Write-Host '[CAP-10D1] stage the packaging kit into the one SDK root'
$packDir = Join-Path $share 'pack'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $packDir
New-Item -ItemType Directory -Force (Join-Path $packDir 'setup'),
    (Join-Path $packDir 'bin'), (Join-Path $packDir 'lib') | Out-Null
Copy-Item -Force (Join-Path $repoRoot 'tools/setup/app/*') `
    -Destination (Join-Path $packDir 'setup')
foreach ($f in 'app-normal.iss', 'app-offline.iss', 'app-fixed.iss',
                'pwebappid.issi', 'pwebapptriple.issi', 'pwebappprov.issi') {
    if (-not (Test-Path -LiteralPath (Join-Path $packDir "setup/$f"))) {
        throw "kit is missing $f"
    }
}

# --- 2. the two compiled CAP-13 setup helpers --------------------------------
# Built HERE, once, from the frozen tools/setup sources, and SHIPPED in the
# SDK. `pweb build --profile` must not compile PWeb's own sources on a
# user's machine, and an installer whose helper was compiled by whatever fpc
# happened to be on PATH is an installer whose gate is not the ratified one.
Write-Host '[CAP-10D1] compile the two CAP-13 setup helpers into the kit'
New-Item -ItemType Directory -Force build/cap10d1/helper-units,
    build/cap10d1/helper-bin | Out-Null
$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
foreach ($helper in 'pwebwv2prov', 'pwebwv2fixed') {
    # -Fusrc/security is CAP-10E: pweb.platform.webview2.fixed resolves the
    # bundled runtime root through pweb.imagepath, the ONE kernel-resolved
    # image path. Both helpers are compiled with the same line rather than
    # one of them being special-cased, because a per-helper flag list is a
    # list that drifts.
    & fpc -MObjFPC -Sh -B -FUbuild/cap10d1/helper-units `
        -FEbuild/cap10d1/helper-bin -Fusrc/platform/windows -Fusrc/security `
        @mormotCore "tools/setup/$helper.pas"
    if ($LASTEXITCODE -ne 0) { throw "$helper compile FAILED" }
    Copy-Item -Force "build/cap10d1/helper-bin/$helper.exe" `
        -Destination (Join-Path $packDir 'bin')
}

# --- 3. the pinned inputs, copied - never fetched ----------------------------
$loaderSrc = Join-Path $repoRoot ('build/webview-build-cap4w/_deps/' +
    'microsoft_web_webview2-src/build/native/x64/WebView2Loader.dll')
if (-not (Test-Path -LiteralPath $loaderSrc)) {
    throw ("missing pinned WebView2 SDK loader: $loaderSrc -- run " +
        'tools/build-webview-dll.ps1 first (it fetches and hash-verifies ' +
        'the pinned SDK tree). This script never downloads anything.')
}
Copy-Item -Force $loaderSrc -Destination (Join-Path $packDir 'lib')

$depsOut = Join-Path $share 'deps'
$isccSrc = Join-Path $repoRoot 'deps/innosetup'
if (-not (Test-Path -LiteralPath (Join-Path $isccSrc 'ISCC.exe'))) {
    throw ("missing pinned Inno Setup compiler: $isccSrc\ISCC.exe -- run " +
        'tools/get-innosetup.ps1 first. This script never downloads anything.')
}
$isccOut = Join-Path $depsOut 'innosetup'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $isccOut
New-Item -ItemType Directory -Force $isccOut | Out-Null
Copy-Item -Recurse -Force (Join-Path $isccSrc '*') -Destination $isccOut
foreach ($f in 'ISCC.exe', '.pweb-pin') {
    if (-not (Test-Path -LiteralPath (Join-Path $isccOut $f))) {
        throw "the staged Inno Setup kit is missing $f"
    }
}

$wv2Src = Join-Path $repoRoot 'deps/webview2-runtime'
$wv2Out = Join-Path $depsOut 'webview2-runtime'
New-Item -ItemType Directory -Force $wv2Out | Out-Null
# the three artifacts by NAME, parsed from the lock rather than by a
# wildcard: a copy that took whatever was in deps/ would happily stage an
# artifact nobody ratified
$lockLines = Get-Content (Join-Path $repoRoot 'webview2-runtime.lock')
$section = ''
$wanted = @()
foreach ($raw in $lockLines) {
    $line = $raw.Trim()
    if (($line -eq '') -or $line.StartsWith('#')) { continue }
    $k, $v = $line -split '=', 2
    $k = $k.Trim(); $v = $v.Trim()
    if ($k -ceq 'artifact') { $section = $v; continue }
    if (($k -ceq 'filename') -and ($section -ne '')) { $wanted += $v }
}
if ($wanted.Count -ne 3) {
    throw "webview2-runtime.lock declares $($wanted.Count) filenames; three are ratified"
}
foreach ($f in $wanted) {
    $src = Join-Path $wv2Src $f
    if (-not (Test-Path -LiteralPath $src)) {
        throw ("missing pinned WebView2 artifact: $src -- run " +
            'tools/get-webview2-runtime.ps1 first. This script never ' +
            'downloads anything.')
    }
    Copy-Item -Force $src -Destination $wv2Out
}
Write-Host "[CAP-10D1] kit staged: 6 manifests, 2 helpers, 1 loader, 3 pinned artifacts"

# --- 4. the isolation compiles ------------------------------------------------
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10d1/iso, build/cap10d1/test-units, build/cap10d1/bin, `
    build/cap10d1/fixture
New-Item -ItemType Directory -Force build/cap10d1/iso,
    build/cap10d1/test-units, build/cap10d1/bin | Out-Null
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

Write-Host '[CAP-10D1] layering: pweb.cli.tar stands on mORMot alone'
& fpc -MObjFPC -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d1/iso `
    -Futools/pweb @mormotCore tools/pweb/pweb.cli.tar.pas
if ($LASTEXITCODE -ne 0) { throw 'pweb.cli.tar.pas failed its isolation compile' }

Write-Host '[CAP-10D1] layering: pweb.cli.package stands on the engine and the pipeline'
& fpc -MObjFPC -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d1/iso `
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotCore tools/pweb/pweb.cli.package.pas
if ($LASTEXITCODE -ne 0) { throw 'pweb.cli.package.pas failed its isolation compile' }

# --- 5. the suite and the interrupt driver ------------------------------------
Write-Host '[CAP-10D1] the suite (with the rollback fault seam) and the driver'
foreach ($prog in 'd1tests', 'pwebpackdrv') {
    & fpc -Sh -B -dPWEB_LAYOUT_FAULTS -Px86_64 -Twin64 -Xm `
        -FUbuild/cap10d1/test-units -FEbuild/cap10d1/bin -Futools/pweb `
        -Futest/cap10d1 -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotTest $statics "test/cap10d1/$prog.pas"
    if ($LASTEXITCODE -ne 0) { throw "$prog.pas compile FAILED" }
    if (-not (Test-Path -LiteralPath "build/cap10d1/bin/$prog.exe")) {
        throw "expected build/cap10d1/bin/$prog.exe"
    }
}

Write-Host ('[CAP-10D1] kit staged; suite + driver built; both units compile ' +
    'in isolation')
