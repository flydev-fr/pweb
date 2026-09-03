# CAP-10B0: compile the scaffold engine, build the template pack, and stage
# the SDK layout the suite resolves against.
#
# Produces, all under build/cap10b0/:
#   iso/         isolation compiles (no binary kept) - the LAYERING proof
#   bin/         pwebtemplates.exe   the trusted pack builder
#   gen/         pweb.templates.registry.inc  the GENERATED trust anchor
#   sdk/bin/     tpltests.exe        the suite, staged where an SDK puts a
#                                    binary, so PWebCliSdkRoot resolves the
#                                    same way it will in an installation
#   sdk/share/pweb/pweb-templates.zip  the pack, where an SDK puts its data
#
# THE STAGED LAYOUT IS THE POINT. The suite's own executable sits in
# <root>/bin, so the resolver under test is the production resolver walking
# the production shape rather than a second code path that exists only for
# tests.
#
# LAYERING IS PROVEN BY THE COMPILER, exactly as the CAP-6/CAP-7/CAP-10A
# scripts do it: each isolation compile is given only the unit paths its
# layer may see. Two claims are worth naming:
#
#   - the four engine units compile with the CLI + assets layers and
#     NOTHING else: no webview unit, no mORMot REST/SOA path, no network
#     unit. A scaffolding engine that could open a socket is a scaffolding
#     engine somebody will one day make download a template;
#   - the ORDER below is itself a claim: sdk, then template, then scaffold,
#     then write. Each compiles alone against what precedes it, so the
#     dependency direction is enforced rather than described.
#
# Usage: pwsh test/cap10b0/build_cap10b0.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

if (-not (Test-Path 'deps/mormot2/src/core/mormot.core.base.pas')) {
    throw 'deps/mormot2 missing -- run tools/get-mormot.ps1 first'
}

# CAP-10C2: the SELECTED target, not the compiler's default - both compiles
# below already name `-Px86_64 -Twin64`, so the default decides nothing here,
# and on a Windows host carrying both compilers it is regularly win32/i386.
# That made this script throw before doing anything, and a gate downstream
# then compared a STALE pack and reported it as non-deterministic. CAP-10C1
# ratified the rule: check the target that is selected.
$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10B0 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10B0] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10b0/iso, build/cap10b0/tool-units, build/cap10b0/test-units, `
    build/cap10b0/bin, build/cap10b0/gen, build/cap10b0/sdk
New-Item -ItemType Directory -Force build/cap10b0/iso,
    build/cap10b0/tool-units, build/cap10b0/test-units, build/cap10b0/bin,
    build/cap10b0/gen, build/cap10b0/sdk/bin,
    build/cap10b0/sdk/share/pweb | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

# --- 1. layering: the engine never sees a webview or a host unit ----------
foreach ($unit in 'sdk', 'template', 'scaffold', 'write') {
    fpc -MObjFPC -Sh -B -FUbuild/cap10b0/iso `
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotCore `
        "tools/pweb/pweb.cli.$unit.pas"
    if ($LASTEXITCODE -ne 0) {
        throw "pweb.cli.$unit.pas failed its isolation compile"
    }
}

# --- 2. the trusted pack builder ------------------------------------------
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FUbuild/cap10b0/tool-units -FEbuild/cap10b0/bin `
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotCore $statics `
    tools/pweb/pwebtemplates.pas
if ($LASTEXITCODE -ne 0) { throw 'pwebtemplates.pas compile FAILED' }

# --- 3. the pack and the generated registry -------------------------------
# --include all: CAP-10B0 ships one PRIVATE fixture, and the suite has to be
# able to reach it. CAP-10B1 builds the public release pack from the same
# list with --include public.
& build/cap10b0/bin/pwebtemplates.exe `
    --source tools/templates `
    --pack build/cap10b0/sdk/share/pweb/pweb-templates.zip `
    --registry build/cap10b0/gen/pweb.templates.registry.inc `
    --include all
if ($LASTEXITCODE -ne 0) { throw 'the template pack build FAILED' }

# --- 4. the suite, compiled WITH the generated registry -------------------
# -Fibuild/cap10b0/gen is how the generated trust anchor gets compiled in:
# "the registry the build produced compiles" is a claim this line makes and
# the compiler either honours or refuses.
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10b0/test-units -FEbuild/cap10b0/sdk/bin `
    -Futools/pweb -Futest/cap10b0 -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows -Fibuild/cap10b0/gen @mormotTest $statics `
    test/cap10b0/tpltests.pas
if ($LASTEXITCODE -ne 0) { throw 'tpltests.pas compile FAILED' }

foreach ($artifact in 'build/cap10b0/bin/pwebtemplates.exe',
                      'build/cap10b0/gen/pweb.templates.registry.inc',
                      'build/cap10b0/sdk/bin/tpltests.exe',
                      'build/cap10b0/sdk/share/pweb/pweb-templates.zip') {
    if (-not (Test-Path $artifact)) { throw "expected $artifact" }
}
Write-Host '[CAP-10B0] engine + builder + pack + registry + suite built; layering compiles clean'
