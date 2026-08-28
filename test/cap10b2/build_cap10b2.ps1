# CAP-10B2: build the ONE artifact this shard needs that CAP-10B1's build
# does not already produce - a `pweb` whose compiled registry describes the
# react template and nothing else.
#
# WHY A SECOND CLI EXISTS AT ALL. CAP-10B2 moved `ptcTemplateUnknown` from
# exit 2 to exit 4, because with a two-value compiled allowlist the code can
# no longer be caused by a command line: reaching it means the pack this
# installation carries does not describe a template this build advertises,
# which is the same class of fact as `sdk_share_missing` and `pack_size`.
#
# That reasoning is only worth as much as the measurement behind it. The
# refusal cannot be provoked with the shipped CLI - its registry knows
# pas2js - so this script builds one that does not: a filtered copy of the
# trusted source with the pas2js template removed, its own pack, its own
# generated registry, and a `pweb` compiled against it. run_cap10b2_gates
# then runs `create demo --ui pas2js` against THAT executable and requires
# exit 4 with `template_unknown`. A refusal nobody has watched fire is a
# comment.
#
# NOTHING SHIPPED COMES FROM HERE. This executable exists to be refused by,
# it is never the CLI any other gate measures, and it lives under its own
# build directory so it cannot be picked up by one.
#
# Produces, all under build/cap10b2/:
#   react-only/source/               the filtered trusted source
#   react-only/gen/pweb.templates.registry.inc
#   react-only/sdk/bin/pweb.exe      the react-only CLI
#   react-only/sdk/share/pweb/pweb-templates.zip
#
# Usage: pwsh test/cap10b2/build_cap10b2.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$builder = 'build/cap10b0/bin/pwebtemplates.exe'
if (-not (Test-Path $builder)) {
    throw ("$builder missing -- run test/cap10b0/build_cap10b0.ps1 first " +
        '(CAP-10B2 reuses the CAP-10B0 pack builder rather than shipping a second one)')
}
if (-not (Test-Path 'deps/mormot2/src/core/mormot.core.base.pas')) {
    throw 'deps/mormot2 missing -- run tools/get-mormot.ps1 first'
}
$targetOs = (fpc -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10B2 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10B2] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

$work = 'build/cap10b2/react-only'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'build/cap10b2'
New-Item -ItemType Directory -Force "$work/gen", "$work/cli-units",
    "$work/sdk/bin", "$work/sdk/share/pweb" | Out-Null

# --- 1. the filtered trusted source ----------------------------------------
# BOTH halves, because the builder cross-checks the list against the
# directory in both directions: a declared template whose files are gone is
# an error, and a directory nobody declared is an error too.
$source = Join-Path $repoRoot "$work/source"
Copy-Item -Recurse -Force (Join-Path $repoRoot 'tools/templates') $source
Remove-Item -Recurse -Force (Join-Path $source 'pas2js')

# the list, minus the `template = pas2js` block. Its COMMENT banner is left
# in place: comments are ignored by the grammar, and a filter that also
# rewrote prose would be a filter nobody could read the output of.
$listPath = Join-Path $source 'templates.list'
$kept = New-Object System.Collections.Generic.List[string]
$dropping = $false
foreach ($line in [System.IO.File]::ReadAllLines($listPath)) {
    if ($line -match '^template\s*=\s*(\S+)\s*$') {
        $dropping = ($Matches[1] -ceq 'pas2js')
    }
    if (-not $dropping) { $kept.Add($line) }
}
[System.IO.File]::WriteAllText($listPath, (($kept -join "`n") + "`n"),
    [System.Text.UTF8Encoding]::new($false))
if ((Get-Content -Raw $listPath) -match '(?m)^template\s*=\s*pas2js\s*$') {
    throw 'the react-only source still declares the pas2js template'
}

# --- 2. its pack and its generated registry --------------------------------
& $builder --source $source `
    --pack "$work/sdk/share/pweb/pweb-templates.zip" `
    --registry "$work/gen/pweb.templates.registry.inc" `
    --include public
if ($LASTEXITCODE -ne 0) { throw 'the react-only pack build FAILED' }

# --- 3. the CLI, compiled against THAT registry ----------------------------
$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FU"$work/cli-units" -FE"$work/sdk/bin" `
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows -Fi"$work/gen" @mormotCore `
    -Fldeps/mormot2/static/x86_64-win64 tools/pweb/pweb.pas
if ($LASTEXITCODE -ne 0) { throw 'the react-only CLI compile FAILED' }

foreach ($artifact in "$work/gen/pweb.templates.registry.inc",
                      "$work/sdk/bin/pweb.exe",
                      "$work/sdk/share/pweb/pweb-templates.zip") {
    if (-not (Test-Path $artifact)) { throw "expected $artifact" }
}
Write-Host '[CAP-10B2] the react-only CLI and its pack are built'
