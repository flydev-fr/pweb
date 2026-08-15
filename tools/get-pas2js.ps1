# Fetches the pinned Pas2JS release into deps/pas2js (git-ignored).
# The pin lives in pas2js.lock at the repo root. The archive is verified
# against the recorded sha256 BEFORE extraction; any mismatch aborts, so
# an upstream re-roll of the archive can never silently change the
# toolchain. The compiler binary and its RTL come from this checkout only
# -- never from a host-installed Lazarus/FPC pas2js.
#
# CAP-7L makes the BUILD HOST a variable, never the pinned version: the
# Linux host fetches the linux-* artifact of the same Pas2JS 3.0.1 into
# deps/pas2js-linux, so a dev machine sharing one working tree between
# Windows and WSL can hold both toolchains without either clobbering the
# other. The frontend sources, the SDK and the compiler version are
# identical on both, which is what makes the Linux runtime gate a parity
# proof rather than a second frontend path.
#
# Usage: pwsh tools/get-pas2js.ps1 [-Force]

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'pas2js.lock'
$DepsDir  = Join-Path $RepoRoot 'deps'

# Deliberately not $IsWindows: that automatic variable does not exist in
# Windows PowerShell 5.1, where it would read as $false and silently pick
# the Linux artifact.
$OnWindows = ($env:OS -eq 'Windows_NT')
if ($OnWindows) {
    $Target = Join-Path $DepsDir 'pas2js'
    $UrlKey = 'url'
    $ShaKey = 'sha256'
    $RootKey = 'rootdir'
    $BinRelative = 'bin/pas2js.exe'
}
else {
    $Target = Join-Path $DepsDir 'pas2js-linux'
    $UrlKey = 'linux-url'
    $ShaKey = 'linux-sha256'
    $RootKey = 'linux-rootdir'
    $BinRelative = 'bin/pas2js'
}

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

foreach ($key in 'version', $UrlKey, $ShaKey, $RootKey) {
    if (-not $Lock[$key]) { throw "pas2js.lock: '$key' is required" }
}
if ($Lock[$ShaKey] -notmatch '^[0-9a-f]{64}$') {
    throw "pas2js.lock: $ShaKey '$($Lock[$ShaKey])' is not a 64-char hex digest"
}

$Compiler = Join-Path $Target $BinRelative

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

Write-Host "fetching $($Lock[$UrlKey])"
Invoke-WebRequest -Uri $Lock[$UrlKey] -OutFile $Zip -UseBasicParsing

$Actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLowerInvariant()
if ($Actual -ne $Lock[$ShaKey]) {
    Remove-Item -Force $Zip
    throw ("pas2js archive sha256 mismatch: expected $($Lock[$ShaKey])," +
        " got $Actual -- upstream changed; ratify a new pin deliberately")
}

$Staging = Join-Path $DepsDir 'pas2js-staging'
if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
Expand-Archive -Path $Zip -DestinationPath $Staging
Remove-Item -Force $Zip

$Root = Join-Path $Staging $Lock[$RootKey]
if (-not (Test-Path (Join-Path $Root $BinRelative))) {
    throw "pas2js archive layout unexpected: no $($Lock[$RootKey])/$BinRelative"
}
Move-Item -Path $Root -Destination $Target
Remove-Item -Recurse -Force $Staging

if (-not $OnWindows) {
    # Expand-Archive does not carry the POSIX mode bits out of a zip, so
    # the freshly extracted compiler is not executable yet
    & chmod +x $Compiler
    if ($LASTEXITCODE -ne 0) {
        throw "unable to mark the pas2js compiler executable: $Compiler"
    }
}

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
