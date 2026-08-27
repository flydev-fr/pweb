# CAP-10A: compile everything the Windows CLI gates run.
#
# Produces, all under build/cap10a/:
#   iso/    isolation compiles (no binary kept) - the LAYERING proof
#   bin/    pweb.exe            the public CLI
#           clitests.exe        the CAP-10A suite (C/P/D matrices)
#           probechild.exe      the deliberately badly behaved probe fixture
#
# LAYERING IS PROVEN BY THE COMPILER, exactly as the CAP-6/CAP-7 scripts do
# it: each isolation compile is given only the unit paths its layer may see,
# so a dependency creeping the wrong way fails here rather than being
# discovered later by reading code. Two claims are worth naming:
#
#   - pweb.rpc.command compiles with the rpc + security + assets layers and
#     NOTHING else: no webview unit, no platform unit, no mORMot server,
#     REST or SOA path. The reusable runtime-command layer is a bridge
#     decorator, not a host;
#   - the CLI compiles with NO webview unit path at all. `pweb doctor` can
#     never open a window, because the units that could are not on its path.
#
# No CAP-3U window is needed or opened: the CLI drives no mORMot interface
# service, so the Win64 CallMethod trampoline is irrelevant to it.
#
# Usage: pwsh test/cap10a/build_cap10a.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

if (-not (Test-Path 'deps/mormot2/src/core/mormot.core.base.pas')) {
    throw 'deps/mormot2 missing -- run tools/get-mormot.ps1 first'
}

$targetOs = (fpc -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10A expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10A] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10a/iso, build/cap10a/cli-units, build/cap10a/test-units, build/cap10a/bin
New-Item -ItemType Directory -Force build/cap10a/iso, build/cap10a/cli-units,
    build/cap10a/test-units, build/cap10a/bin | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

# --- 1. layering: the reusable runtime-command layer is webview-free -------
fpc -MObjFPC -Sh -B -FUbuild/cap10a/iso `
    -Fusrc/rpc -Fusrc/security -Fusrc/assets @mormotCore `
    src/rpc/pweb.rpc.command.pas
if ($LASTEXITCODE -ne 0) {
    throw 'pweb.rpc.command.pas failed its webview-free isolation compile'
}

# --- 2. layering: the CLI never sees a webview or a platform-host unit -----
# (pweb.cli.platform DOES use src/platform/windows for the ratified CAP-6b0
# WebView2 DETECTOR, which reads the registry and opens nothing.)
foreach ($unit in 'args', 'toolchain', 'paths', 'project', 'probe',
                  'doctor', 'report') {
    fpc -MObjFPC -Sh -B -FUbuild/cap10a/iso `
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotCore `
        "tools/pweb/pweb.cli.$unit.pas"
    if ($LASTEXITCODE -ne 0) {
        throw "pweb.cli.$unit.pas failed its isolation compile"
    }
}

# --- 3. the CLI itself, into its OWN unit directory ------------------------
# The separate -FU is what makes the no-network proof mechanical rather than
# a claim: build/cap10a/cli-units then contains EXACTLY the units the CLI
# links, and check_cap10a_contracts.ps1 requires none of them to be a
# networking unit. Sharing a unit directory with the test suite (which does
# pull mormot.net through mormot.core.test) would destroy that evidence.
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FUbuild/cap10a/cli-units -FEbuild/cap10a/bin `
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotCore $statics `
    tools/pweb/pweb.pas
if ($LASTEXITCODE -ne 0) { throw 'pweb.pas compile FAILED' }

# --- 4. the suite and its fixture -----------------------------------------
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10a/test-units -FEbuild/cap10a/bin `
    -Futools/pweb -Futest/cap10a -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotTest $statics `
    test/cap10a/clitests.pas
if ($LASTEXITCODE -ne 0) { throw 'clitests.pas compile FAILED' }

# RTL-only by design: a fixture that shared code with the thing it tests
# would be measuring the code against itself
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10a/test-units -FEbuild/cap10a/bin `
    test/cap10a/probechild.pas
if ($LASTEXITCODE -ne 0) { throw 'probechild.pas compile FAILED' }

foreach ($exe in 'pweb.exe', 'clitests.exe', 'probechild.exe') {
    if (-not (Test-Path "build/cap10a/bin/$exe")) {
        throw "expected build/cap10a/bin/$exe"
    }
}
Write-Host '[CAP-10A] pweb + clitests + probechild built; layering compiles clean'
