# Fetches the pinned Pas2JS release into deps/pas2js (git-ignored).
# The pin lives in pas2js.lock at the repo root. The archive is verified
# against the recorded sha256 BEFORE extraction; any mismatch aborts, so
# an upstream re-roll of the archive can never silently change the
# toolchain. The compiler binary and its RTL come from this checkout only
# -- never from a host-installed Lazarus/FPC pas2js.
#
# Usage: pwsh tools/get-pas2js.ps1 [-Force]

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'pas2js.lock'
$DepsDir  = Join-Path $RepoRoot 'deps'
$Target   = Join-Path $DepsDir 'pas2js'

# --- read the lock (strict: any malformed line is an error) -------------------
$Lock = @{}
$LineNo = 0
foreach ($line in Get-Content $LockFile) {
    $LineNo++
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '=') {
        throw "pas2js.lock line ${LineNo}: malformed (expected 'key = value'): $line"
    }
    $k, $v = $line -split '=', 2
    $Lock[$k.Trim()] = $v.Trim()
}

foreach ($key in 'version', 'url', 'sha256', 'rootdir') {
    if (-not $Lock[$key]) { throw "pas2js.lock: '$key' is required" }
}
if ($Lock['sha256'] -notmatch '^[0-9a-f]{64}$') {
    throw "pas2js.lock: sha256 '$($Lock['sha256'])' is not a 64-char hex digest"
}

$Compiler = Join-Path $Target 'bin/pas2js.exe'

if ((Test-Path $Target) -and $Force) { Remove-Item -Recurse -Force $Target }

if (Test-Path $Compiler) {
    # a corrupt cached binary must fall through to a refetch, not abort
    $Have = ''
    try { $Have = (& $Compiler -iV 2>$null | Out-String).Trim() } catch {}
    if ($Have -eq $Lock['version']) {
        Write-Host "pas2js $Have already present at $Target"
        exit 0
    }
    Write-Host "pas2js cache unusable or version drift ('$Have' != '$($Lock['version'])'): refetching"
    Remove-Item -Recurse -Force $Target
}
if (Test-Path $Target) {
    # partial earlier install (no compiler): clear it so Move-Item below
    # never nests the fresh tree inside a stale directory
    Remove-Item -Recurse -Force $Target
}

New-Item -ItemType Directory -Force $DepsDir | Out-Null
$Zip = Join-Path $DepsDir 'pas2js-download.zip'
if (Test-Path $Zip) { Remove-Item -Force $Zip }

Write-Host "fetching $($Lock['url'])"
Invoke-WebRequest -Uri $Lock['url'] -OutFile $Zip -UseBasicParsing

$Actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLowerInvariant()
if ($Actual -ne $Lock['sha256']) {
    Remove-Item -Force $Zip
    throw ("pas2js archive sha256 mismatch: expected $($Lock['sha256'])," +
        " got $Actual -- upstream changed; ratify a new pin deliberately")
}

$Staging = Join-Path $DepsDir 'pas2js-staging'
if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
Expand-Archive -Path $Zip -DestinationPath $Staging
Remove-Item -Force $Zip

$Root = Join-Path $Staging $Lock['rootdir']
if (-not (Test-Path (Join-Path $Root 'bin/pas2js.exe'))) {
    throw "pas2js archive layout unexpected: no $($Lock['rootdir'])/bin/pas2js.exe"
}
Move-Item -Path $Root -Destination $Target
Remove-Item -Recurse -Force $Staging

$Have = (& $Compiler -iV).Trim()
if ($Have -ne $Lock['version']) {
    throw "fetched pas2js reports version '$Have', lock pins '$($Lock['version'])'"
}
foreach ($rtl in 'packages/rtl/src/system.pas', 'packages/rtl/src/js.pas',
                 'packages/rtl/src/rtl.js') {
    if (-not (Test-Path (Join-Path $Target $rtl))) {
        throw "pas2js RTL incomplete: missing $rtl"
    }
}
Write-Host "pas2js $Have ready at $Target"
