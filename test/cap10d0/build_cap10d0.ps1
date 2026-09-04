# CAP-10D0 (Windows): build the public-build suite and its driver.
#
# IT ADDS TO THE ONE STAGED SDK ROOT rather than building a second one:
# build/cap10b1/sdk is completed by test/cap10c1/build_cap10c1.ps1, and this
# script needs only that same root.
#
# Produces, under build/cap10d0/:
#   iso/            the isolation compile of pweb.cli.build - the LAYERING
#                   proof that the public build driver stands on the
#                   pipeline and on file operations, and on nothing else
#   bin/            d0tests.exe       the CAP-10D0 suite
#                   pwebbuilddrv.exe  the real-`pweb build` driver
#
# THE DRIVER IS THE POINT ON THIS PLATFORM. CAP-10C1's ST10 leg measured an
# interrupted pipeline on POSIX and recorded `interrupt_clean = not_measured`
# on Windows, because a console control event there needs the CAP-10C0
# helper. A public `build` is the command a developer actually presses
# Ctrl+C on, so this driver is what makes that measurement exist here.
#
# Usage: pwsh test/cap10d0/build_cap10d0.ps1
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
    throw "CAP-10D0 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10D0] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

# the whole tree, including the fixture directories the suite plants beside
# its own binary (mormot.core.test runs a suite from the executable's
# directory, so `build/cap10d0/fixture` resolves under bin/ while a case is
# running and beside it once the runner has restored the working directory)
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10d0/iso, build/cap10d0/test-units, build/cap10d0/bin, `
    build/cap10d0/fixture
New-Item -ItemType Directory -Force build/cap10d0/iso,
    build/cap10d0/test-units, build/cap10d0/bin | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

# --- 1. layering: the build driver compiles on its own ----------------------
# It calls PWebCliRunPipeline and reads a disk. If it ever grew a second way
# to run a child, this compile would drag in the units that do - and
# check_cap10d0_contracts.ps1 makes the same claim over the SOURCE, so the
# two together catch both a new dependency and a new spelling of an old one.
Write-Host '[CAP-10D0] layering: pweb.cli.build stands on the pipeline alone'
& fpc -MObjFPC -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d0/iso `
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotCore tools/pweb/pweb.cli.build.pas
if ($LASTEXITCODE -ne 0) {
    throw 'pweb.cli.build.pas failed its isolation compile'
}

# --- 2. the suite and the real-`pweb build` driver --------------------------
Write-Host '[CAP-10D0] the suite and the real-`pweb build` driver'
foreach ($prog in 'd0tests', 'pwebbuilddrv') {
    # -Fusrc/platform/windows: pweb.cli.platform uses the ratified CAP-6b0
    # WebView2 detector on this platform and on no other, which is the same
    # asymmetry test/cap10c1 and test/cap10c3 carry. Without it the compile
    # dies on `Can't find unit pweb.platform.webview2.runtime`, which names
    # the missing PATH rather than the missing unit.
    & fpc -Sh -B -Px86_64 -Twin64 -Xm -FUbuild/cap10d0/test-units `
        -FEbuild/cap10d0/bin -Futools/pweb -Futest/cap10d0 -Fusrc/rpc `
        -Fusrc/security -Fusrc/assets -Fusrc/platform/windows `
        @mormotTest $statics "test/cap10d0/$prog.pas"
    if ($LASTEXITCODE -ne 0) { throw "$prog.pas compile FAILED" }
    if (-not (Test-Path -LiteralPath "build/cap10d0/bin/$prog.exe")) {
        throw "expected build/cap10d0/bin/$prog.exe"
    }
}

Write-Host ('[CAP-10D0] suite + driver built; the build driver compiles in ' +
    'isolation')
