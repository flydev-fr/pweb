# CAP-10C0: compile everything the Windows supervision gates run.
#
# Produces, all under build/cap10c0/:
#   iso/    isolation compiles (no binary kept) - the LAYERING proof
#   bin/    c0tests.exe        the CAP-10C0 suite (pure + engine + run)
#           pwebchild.exe      the deliberately badly behaved fixture child
#
# THE CLI ITSELF IS NOT BUILT HERE. There is ONE `pweb`, compiled by
# test/cap10b1/build_cap10b1.ps1 where its trust anchor is generated, and
# every shard's gates measure that executable. CAP-10C0 changed what it
# links (pweb.cli.process, pweb.cli.run, and a pweb.cli.probe re-based on the
# engine) and nothing about where it is built.
#
# LAYERING IS PROVEN BY THE COMPILER, as every CAP-10 build does it: the two
# new units are compiled with only the unit paths their layer may see. The
# claim worth naming: the execution engine and the run command compile with
# NO webview unit path at all. `pweb run` launches a window-owning process;
# it can never BE one, because the units that could are not on its path.
#
# Usage: pwsh test/cap10c0/build_cap10c0.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

if (-not (Test-Path 'deps/mormot2/src/core/mormot.core.base.pas')) {
    throw 'deps/mormot2 missing -- run tools/get-mormot.ps1 first'
}
$builtCli = 'build/cap10b1/sdk/bin/pweb.exe'
if (-not (Test-Path $builtCli)) {
    throw ("$builtCli missing -- run test/cap10b1/build_cap10b1.ps1 first. " +
        'The CLI carries a generated template registry and is built where ' +
        'that registry is produced.')
}

# CAP-10C2: the SELECTED target, not the compiler.s default - every compile
# below names it explicitly, so the default decides nothing, and on a Windows
# host carrying both compilers it is regularly win32/i386. CAP-10C1 ratified
# the rule; this script simply had not followed it.
$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10C0 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10C0] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10c0/iso, build/cap10c0/test-units, build/cap10c0/bin
New-Item -ItemType Directory -Force build/cap10c0/iso, build/cap10c0/test-units,
    build/cap10c0/bin | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

# --- 1. layering: the engine and the run command are webview-free ---------
# (pweb.cli.platform still uses src/platform/windows for the ratified CAP-6b0
# WebView2 DETECTOR, which reads the registry and opens nothing.)
foreach ($unit in 'process', 'run') {
    fpc -MObjFPC -Sh -B -FUbuild/cap10c0/iso `
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotCore `
        "tools/pweb/pweb.cli.$unit.pas"
    if ($LASTEXITCODE -ne 0) {
        throw "pweb.cli.$unit.pas failed its isolation compile"
    }
}

# --- 2. the suite and its fixture -----------------------------------------
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10c0/test-units -FEbuild/cap10c0/bin `
    -Futools/pweb -Futest/cap10c0 -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotTest $statics `
    test/cap10c0/c0tests.pas
if ($LASTEXITCODE -ne 0) { throw 'c0tests.pas compile FAILED' }

# RTL-only by design: a fixture that shared code with the thing it tests
# would be measuring the code against itself
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10c0/test-units -FEbuild/cap10c0/bin `
    test/cap10c0/pwebchild.pas
if ($LASTEXITCODE -ne 0) { throw 'pwebchild.pas compile FAILED' }

foreach ($exe in 'c0tests.exe', 'pwebchild.exe') {
    if (-not (Test-Path "build/cap10c0/bin/$exe")) {
        throw "expected build/cap10c0/bin/$exe"
    }
}
Write-Host '[CAP-10C0] c0tests + pwebchild built; layering compiles clean'
