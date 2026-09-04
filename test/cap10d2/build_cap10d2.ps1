# CAP-10D2 (Windows): stage the licence set into the ONE SDK root and build
# the private SDK packager, the suite and the isolation compiles.
#
# The Windows twin of build_cap10d2.sh, making the identical claims in the
# identical order plus the half only this platform has: the Microsoft
# WebView2 SDK notice, which travels with `webview.dll` because that binary
# embeds upstream's built-in loader.
#
# NOTHING HERE DOWNLOADS ANYTHING. Every licence text is COPIED from the
# place its own material came from - mORMot's checkout, the directory the
# webview build wrote its binary into, and the CAP-9C1 QuickJS package -
# and the one with a ratified digest is verified against it.
#
# Produces, under build/cap10d2/:
#   iso/    the isolation compile of pweb.cli.sdkmanifest
#   bin/    pwebsdk.exe   the private SDK packager
#           d2tests.exe   the CAP-10D2 suite
#
# Usage: pwsh test/cap10d2/build_cap10d2.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$share = Join-Path $sdk 'share/pweb'
foreach ($pre in (Join-Path $sdk 'bin/pweb.exe'),
                 (Join-Path $sdk 'bin/pwebbundle.exe'),
                 (Join-Path $share 'pweb-templates.zip'),
                 (Join-Path $share 'deps/mormot2/src/core/mormot.core.base.pas'),
                 (Join-Path $share 'lib/windows-x86_64/webview.dll'),
                 (Join-Path $share 'pack/setup/app-normal.iss'),
                 (Join-Path $repoRoot 'build/cap10b1/gen/pweb.templates.registry.inc')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run test/cap10b1/build_cap10b1.ps1, " +
            'test/cap10c1/build_cap10c1.ps1 and test/cap10d1/build_cap10d1.ps1 first')
    }
}

$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10D2 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10D2] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

# --- 1. the licence set, from the material's OWN provenance ------------------
# Each text comes from where its own bytes came from, never from a copy this
# script keeps: mORMot's licence from mORMot's checkout, the webview notices
# from the directory the webview build wrote its binary into, and the QuickJS
# notice from the CAP-9C1 package - which is GENERATED from the pinned
# sources and whose digest docs/third-party-licenses.md ratifies, so it is
# verified here rather than trusted.
Write-Host '[CAP-10D2] stage the ratified licence set into the one SDK root'
$licDir = Join-Path $share 'licenses'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $licDir
New-Item -ItemType Directory -Force $licDir | Out-Null

$QUICKJS_NOTICE_SHA =
    '8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc'

function Stage([string]$Source, [string]$Name, [string]$WantSha) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw ("missing licence source: $Source -- CAP-10D2 ships no licence " +
            'text of its own, and a component whose notice cannot be produced ' +
            'from its own provenance is a component that cannot ship')
    }
    if ($WantSha) {
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash.ToLowerInvariant()
        if ($got -cne $WantSha) {
            throw "licence digest drift for ${Name}: expected $WantSha, got $got"
        }
    }
    Copy-Item -Force -LiteralPath $Source -Destination (Join-Path $licDir $Name)
    Write-Host "  $Name <- $Source"
}

Stage (Join-Path $repoRoot 'deps/mormot2/LICENCE.md') 'LICENSE.mormot2.md' ''
Stage (Join-Path $repoRoot 'build/webview-dist/LICENSE.webview') `
    'LICENSE.webview.txt' ''
Stage (Join-Path $repoRoot 'build/webview-dist/LICENSE.webview2sdk') `
    'LICENSE.webview2sdk.txt' ''
Stage (Join-Path $repoRoot 'build/quickjs-release/LICENSE.quickjs') `
    'LICENSE.quickjs.txt' $QUICKJS_NOTICE_SHA

# --- 2. the isolation compile ------------------------------------------------
# pweb.cli.sdkmanifest stands on mORMot and on the two lowest CLI units and
# on nothing else: it is read by the DOCTOR, so a dependency that dragged the
# pipeline or the process engine into it would put the whole build layer
# under a diagnostic.
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10d2/iso, build/cap10d2/pkg-units, build/cap10d2/test-units, `
    build/cap10d2/bin, build/cap10d2/fixture, build/cap10d2/out
New-Item -ItemType Directory -Force build/cap10d2/iso,
    build/cap10d2/pkg-units, build/cap10d2/test-units, build/cap10d2/bin,
    build/cap10d2/out | Out-Null
$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

Write-Host '[CAP-10D2] layering: pweb.cli.sdkmanifest stands on mORMot and the anchor'
& fpc -MObjFPC -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d2/iso `
    -Futools/pweb @mormotCore tools/pweb/pweb.cli.sdkmanifest.pas
if ($LASTEXITCODE -ne 0) {
    throw 'pweb.cli.sdkmanifest.pas failed its isolation compile'
}

# --- 3. the private packager -------------------------------------------------
# It compiles in the SAME generated CAP-10B0 registry the CLI does, so the
# manifest's templates block records what `pweb create` believes rather than
# what happens to be beside it.
Write-Host '[CAP-10D2] the private SDK packager'
& fpc -MObjFPC -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d2/pkg-units `
    -FEbuild/cap10d2/bin -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows -Fibuild/cap10b1/gen @mormotTest $statics `
    tools/pweb/pwebsdk.pas
if ($LASTEXITCODE -ne 0) { throw 'pwebsdk.pas compile FAILED' }
if (-not (Test-Path -LiteralPath 'build/cap10d2/bin/pwebsdk.exe')) {
    throw 'expected build/cap10d2/bin/pwebsdk.exe'
}

# --- 4. the suite ------------------------------------------------------------
Write-Host '[CAP-10D2] the suite'
& fpc -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d2/test-units `
    -FEbuild/cap10d2/bin -Futools/pweb -Futest/cap10d2 -Fusrc/rpc `
    -Fusrc/security -Fusrc/assets -Fusrc/platform/windows @mormotTest `
    $statics test/cap10d2/d2tests.pas
if ($LASTEXITCODE -ne 0) { throw 'd2tests.pas compile FAILED' }
if (-not (Test-Path -LiteralPath 'build/cap10d2/bin/d2tests.exe')) {
    throw 'expected build/cap10d2/bin/d2tests.exe'
}

Write-Host ('[CAP-10D2] licence set staged (4); packager + suite built; ' +
    'the manifest unit compiles in isolation')
