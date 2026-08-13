# Fetches the pinned Inno Setup 6 compiler into deps/innosetup
# (git-ignored) for the CAP-6b1 normal-profile setup build. The pin
# lives in innosetup.lock at the repo root. The installer is verified
# against the recorded sha256 (and byte size) BEFORE it is executed -
# an unverified binary is never run - and any mismatch deletes the
# download and aborts. The install itself is silent, per-user,
# PORTABLE (no uninstaller, no file associations) and bounded: a hung
# installer is killed and the fetch fails.
#
# ISCC.exe carries no machine-readable version resource, so the
# verified installer sha256 is recorded in <target>/.pweb-pin as the
# toolchain identity: the cache is reused only while that stamp equals
# the lock pin (no re-download), and a stamp drift reprovisions from
# scratch. The 'Inno Setup 6 Command-Line Compiler' banner is
# additionally asserted after provisioning.
#
# -LockFile / -TargetDir / -AllowLocalSource exist for the fixture
# matrix in test/cap6b1/check_innosetup_lock.ps1 (local payloads, zero
# network): -AllowLocalSource only admits LOCAL (non-https) source
# paths, it never authorizes a non-allowlisted https host.
#
# Usage: pwsh tools/get-innosetup.ps1 [-Force] [-LockFile <path>]
#          [-TargetDir <path>] [-AllowLocalSource]

param(
    [switch]$Force,
    [string]$LockFile = '',
    [string]$TargetDir = '',
    [switch]$AllowLocalSource
)

$ErrorActionPreference = 'Stop'

trap {
    [Console]::Error.WriteLine("get-innosetup: $($_.Exception.Message)")
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($LockFile -eq '') { $LockFile = Join-Path $RepoRoot 'innosetup.lock' }
if ($TargetDir -eq '') { $TargetDir = Join-Path $RepoRoot 'deps/innosetup' }
$Target = $TargetDir
$Stamp = Join-Path $Target '.pweb-pin'
$Iscc = Join-Path $Target 'ISCC.exe'
$InstallTimeoutMs = 600000
$KnownKeys = @('version', 'url', 'size', 'sha256')

# --- read the lock (strict: malformed, duplicate or unknown keys are
# --- hard errors naming their line) ------------------------------------------
$Lock = @{}
$LineNo = 0
if (-not (Test-Path -LiteralPath $LockFile)) {
    throw "innosetup.lock not found: $LockFile"
}
$lockName = Split-Path -Leaf $LockFile
foreach ($line in Get-Content -LiteralPath $LockFile) {
    $LineNo++
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '=') {
        throw "$lockName line ${LineNo}: malformed (expected 'key = value'): $line"
    }
    $k, $v = $line -split '=', 2
    $k = $k.Trim()
    $v = $v.Trim()
    if ($k -eq '') {
        throw "$lockName line ${LineNo}: malformed (empty key): $line"
    }
    if ($v -eq '') {
        throw "$lockName line ${LineNo}: malformed (empty value for '$k')"
    }
    if ($KnownKeys -cnotcontains $k) {
        throw "$lockName line ${LineNo}: unknown key '$k'"
    }
    if ($Lock.Contains($k)) {
        throw "$lockName line ${LineNo}: duplicate key '$k'"
    }
    $Lock[$k] = $v
}
foreach ($key in $KnownKeys) {
    if (-not $Lock[$key]) { throw "${lockName}: '$key' is required" }
}
if ($Lock['sha256'] -cnotmatch '^[0-9a-f]{64}$') {
    throw "${lockName}: sha256 '$($Lock['sha256'])' is not a 64-char lowercase hex digest"
}
if ($Lock['size'] -notmatch '^[1-9][0-9]*$') {
    throw "${lockName}: size '$($Lock['size'])' is not a positive byte count"
}
# the toolchain may come only from the vendor's own release channels;
# -AllowLocalSource additionally admits LOCAL (non-https) payload
# paths for the fixture matrix, never a foreign https host
$AllowedUrl = ($Lock['url'] -cmatch
    '^https://(github\.com/jrsoftware/|([a-z0-9-]+\.)*jrsoftware\.org/)')
if (-not $AllowedUrl) {
    if (($Lock['url'] -match '^https://') -or -not $AllowLocalSource) {
        throw ("${lockName}: url must be https on github.com/jrsoftware" +
            " or jrsoftware.org: $($Lock['url'])")
    }
}

# --- cached toolchain: reused only while the stamp equals the pin ------------
if ((Test-Path $Target) -and $Force) { Remove-Item -Recurse -Force $Target }
if ((Test-Path -LiteralPath $Iscc) -and (Test-Path -LiteralPath $Stamp)) {
    $have = (Get-Content -LiteralPath $Stamp -Raw).Trim()
    if ($have -ceq $Lock['sha256']) {
        Write-Host "Inno Setup $($Lock['version']) already provisioned at $Target (pin $have)"
        exit 0
    }
    Write-Host "Inno Setup cache pin drift ('$have' != '$($Lock['sha256'])'): reprovisioning"
}
if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }

$DownloadDir = Split-Path -Parent $Target
New-Item -ItemType Directory -Force $DownloadDir | Out-Null
$Installer = Join-Path $DownloadDir 'innosetup-download.exe'
if (Test-Path $Installer) { Remove-Item -Force $Installer }

try {
    if ($Lock['url'] -match '^https://') {
        Write-Host "fetching $($Lock['url'])"
        Invoke-WebRequest -Uri $Lock['url'] -OutFile $Installer -UseBasicParsing `
            -TimeoutSec 300
    }
    else {
        # fixture mode only (-AllowLocalSource validated above)
        if (-not (Test-Path -LiteralPath $Lock['url'])) {
            throw "local source not found: $($Lock['url'])"
        }
        Copy-Item -LiteralPath $Lock['url'] -Destination $Installer
    }

    # verify BEFORE executing anything: an unverified binary never runs
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Installer).Hash.ToLowerInvariant()
    if ($actual -cne $Lock['sha256']) {
        throw ("innosetup installer sha256 mismatch: expected $($Lock['sha256'])," +
            " got $actual -- download deleted; upstream changed, ratify a new pin" +
            ' deliberately')
    }
    $bytes = (Get-Item -LiteralPath $Installer).Length
    if ($bytes -ne [long]$Lock['size']) {
        throw ("innosetup installer size mismatch: expected $($Lock['size'])" +
            " bytes, got $bytes -- download deleted")
    }

    # silent, per-user, portable, bounded; /DIR is quoted so target
    # paths containing spaces survive Start-Process argument joining
    $proc = Start-Process -FilePath $Installer -ArgumentList `
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', `
        '/CURRENTUSER', '/PORTABLE=1', "/DIR=`"$Target`"" -PassThru
    if (-not $proc.WaitForExit($InstallTimeoutMs)) {
        $proc.Kill($true)
        $proc.WaitForExit()
        throw "innosetup installer exceeded ${InstallTimeoutMs}ms and was killed"
    }
    if ($proc.ExitCode -ne 0) {
        throw "innosetup installer failed with exit $($proc.ExitCode)"
    }
}
finally {
    if (Test-Path -LiteralPath $Installer) {
        Remove-Item -Force -LiteralPath $Installer
    }
}

if (-not (Test-Path -LiteralPath $Iscc)) {
    throw "innosetup install produced no ISCC.exe at $Iscc"
}
# ISCC exits nonzero without arguments; only the banner matters here
$banner = & $Iscc 2>&1 | Out-String
if ($banner -notmatch 'Inno Setup 6 Command-Line Compiler') {
    throw "provisioned ISCC.exe does not announce Inno Setup 6: $banner"
}
Set-Content -LiteralPath $Stamp -Value $Lock['sha256'] -NoNewline -Encoding ascii
Write-Host "Inno Setup $($Lock['version']) ready at $Target (pin $($Lock['sha256']))"
