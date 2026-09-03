# CAP-10C3 (Windows): build the Pas2JS development suite, its driver, and the
# two host binaries of a PAS2JS project.
#
# IT ADDS TO THE ONE STAGED SDK ROOT rather than building a second one:
# build/cap10b1/sdk is completed by test/cap10c1/build_cap10c1.ps1 and
# refreshed by test/cap10c2/build_cap10c2.ps1, and this script only needs
# that same root.
#
# Produces, under build/cap10c3/:
#   iso/            isolation compiles (no binary kept) - the LAYERING proof
#   bin/            c3tests.exe     the CAP-10C3 suite
#                   pwebp2jdrv.exe  the real-`pweb dev` Pas2JS driver
#   release-units/  the PAS2JS RELEASE host's compiled unit set  (T2)
#   dev-units/      the PAS2JS DEVELOPMENT host's compiled unit set (T2)
#   probe/          release-host/ and dev-host/, one binary each (T1, T2)
#
# THE TWO HOSTS ARE THE POINT, and they are a PAS2JS project's this time.
# CAP-10C2 proved the claim for a React project; a generated host is
# frontend-agnostic by design, and this is where that stops being a design
# statement and becomes two files to compare.
#
# Usage: pwsh test/cap10c3/build_cap10c3.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$share = Join-Path $sdk 'share/pweb'
foreach ($pre in (Join-Path $sdk 'bin/pweb.exe'),
                 (Join-Path $sdk 'bin/pwebbundle.exe'),
                 (Join-Path $share 'deps/mormot2/src/core/mormot.core.base.pas'),
                 (Join-Path $share 'sdk/pas2js/pweb.native.pas'),
                 (Join-Path $share 'lib/windows-x86_64/webview.dll')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run test/cap10b1/build_cap10b1.ps1, " +
            'test/cap10c1/build_cap10c1.ps1 and test/cap10c2/build_cap10c2.ps1 first')
    }
}

$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10C3 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10C3] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

# --- 0. the SDK root's src/, refreshed --------------------------------------
# CAP-10C3 changes no src/ unit, but a root staged before CAP-10C2 cannot
# compile a development host at all - and the failure would look like a
# missing unit rather than a stale installation.
Copy-Item -Recurse -Force (Join-Path $repoRoot 'src') `
    (Join-Path $share 'src')
foreach ($u in 'pweb.webview.host.pas', 'pweb.webview.devhost.pas') {
    if (-not (Test-Path -LiteralPath (Join-Path $share "src/webview/$u"))) {
        throw "the staged SDK root does not carry src/webview/$u"
    }
}

# the whole tree, including the fixture directories the suite plants beside
# its own binary (mormot.core.test runs a suite from the executable's
# directory, so `build/cap10c3/fixture` resolves under bin/ while a case is
# running and beside it once the runner has restored the working directory)
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10c3/iso, build/cap10c3/test-units, build/cap10c3/bin, `
    build/cap10c3/release-units, build/cap10c3/dev-units, build/cap10c3/probe
New-Item -ItemType Directory -Force build/cap10c3/iso,
    build/cap10c3/test-units, build/cap10c3/bin, build/cap10c3/release-units,
    build/cap10c3/dev-units, build/cap10c3/probe/release-host,
    build/cap10c3/probe/dev-host | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

# --- 1. layering: the change detector reaches no webview unit ---------------
# `pweb dev` BUILDS and SUPERVISES a window-owning application; it can never
# BE one, because the units that could are not on its path. The new detector
# is compiled in isolation for the same reason CAP-10C2 compiles the loop and
# the layout that way, and beside them so a regression in either shows here.
foreach ($unit in 'devinputs', 'devlayout', 'dev') {
    fpc -MObjFPC -Sh -B -FUbuild/cap10c3/iso `
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotCore `
        "tools/pweb/pweb.cli.$unit.pas"
    if ($LASTEXITCODE -ne 0) {
        throw "pweb.cli.$unit.pas failed its isolation compile"
    }
}

# --- 2. the suite and the driver -------------------------------------------
foreach ($prog in 'c3tests', 'pwebp2jdrv') {
    fpc -Px86_64 -Twin64 -Sh -B `
        -FUbuild/cap10c3/test-units -FEbuild/cap10c3/bin `
        -Futools/pweb -Futest/cap10c3 -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotTest $statics `
        "test/cap10c3/$prog.pas"
    if ($LASTEXITCODE -ne 0) { throw "$prog.pas compile FAILED" }
}

# --- 3. the TWO host binaries, of a PAS2JS project -------------------------
# scaffolded here by the REAL CLI, so what is compiled is what a developer's
# project would be - not a fixture that resembles one.
$probeGen = 'build/cap10c3/probe/gen'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $probeGen
New-Item -ItemType Directory -Force $probeGen | Out-Null
Push-Location $probeGen
try {
    & (Join-Path $sdk 'bin/pweb.exe') create demo --ui pas2js `
        --bundle-id com.example.demo
    if ($LASTEXITCODE -ne 0) { throw 'scaffolding the probe project FAILED' }
}
finally { Pop-Location }
$proj = Join-Path $repoRoot "$probeGen/demo"

$sdkArgs = @(
    "-Fu$proj/src",
    "-Fu$share/src/lib", "-Fu$share/src/rpc", "-Fu$share/src/security",
    "-Fu$share/src/webview", "-Fu$share/src/assets",
    "-Fu$share/src/platform/windows",
    "-Fi$share/deps/mormot2/src",
    "-Fu$share/deps/mormot2/src/core", "-Fu$share/deps/mormot2/src/lib",
    "-Fu$share/deps/mormot2/src/crypt", "-Fu$share/deps/mormot2/src/net",
    "-Fu$share/deps/mormot2/src/db", "-Fu$share/deps/mormot2/src/orm",
    "-Fu$share/deps/mormot2/src/rest", "-Fu$share/deps/mormot2/src/soa",
    "-Fl$share/deps/mormot2/static/x86_64-win64")

# the RELEASE host: the production compile, exactly as the pipeline runs it
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
    -FUbuild/cap10c3/release-units -FEbuild/cap10c3/probe/release-host `
    @sdkArgs "$proj/src/demo.lpr"
if ($LASTEXITCODE -ne 0) { throw 'the RELEASE host compile FAILED' }

# the DEVELOPMENT host: the same command plus -dPWEB_DEV, into its OWN unit
# and object directories - which is what keeps the release unit set clean
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm -dPWEB_DEV `
    -FUbuild/cap10c3/dev-units -FEbuild/cap10c3/probe/dev-host `
    @sdkArgs "$proj/src/demo.lpr"
if ($LASTEXITCODE -ne 0) { throw 'the DEVELOPMENT host compile FAILED' }

# the webview library, beside BOTH probe binaries. It is a load-time import,
# so a host that cannot find it dies before main() and the dev-root refusal -
# which happens before anything webview-related exists - would never be
# reached.
foreach ($probe in 'release-host', 'dev-host') {
    Copy-Item -Force `
        -LiteralPath (Join-Path $share 'lib/windows-x86_64/webview.dll') `
        -Destination (Join-Path $repoRoot "build/cap10c3/probe/$probe")
}

foreach ($artifact in 'build/cap10c3/bin/c3tests.exe',
                      'build/cap10c3/bin/pwebp2jdrv.exe',
                      'build/cap10c3/probe/release-host/demo.exe',
                      'build/cap10c3/probe/dev-host/demo.exe',
                      'build/cap10c3/dev-units/pweb.webview.devhost.ppu') {
    if (-not (Test-Path $artifact)) { throw "expected $artifact" }
}
if (Test-Path 'build/cap10c3/release-units/pweb.webview.devhost.ppu') {
    throw ('the PAS2JS RELEASE unit set carries pweb.webview.devhost -- the ' +
        'development composition must be unreachable from a release build')
}
Write-Host ('[CAP-10C3] suite + driver + both pas2js host binaries built; ' +
    'layering compiles clean')
