# Installs the PINNED Free Pascal Compiler on the Windows build host.
#
# The Windows sibling of tools/get-fpc-macos.ps1, deliberately the same shape:
# read the lock, fetch the exact pinned artifact, verify it BEFORE it is used,
# assert what the install actually produced, and fail loudly on any drift.
#
# WHY THIS EXISTS, since "the action worked fine for months" is the obvious
# objection. The job used gcarreno/setup-lazarus, which fetches a package list
# from packages.lazarus-ide.org even when zero packages are requested. On
# 2026-08-16 that host went down: DNS resolves (37.97.187.115 /
# 2a01:7c8:aac1:2f0::1, via both the local resolver and 1.1.1.1) but TCP
# connect fails - curl exit 7, not 6 - for the entire site including www, for
# third parties as well as for us, and the runners get ECONNREFUSED on the
# same address. The Windows gate was held hostage indefinitely by an outage in
# something it did not need, and no PWeb step ran for a whole session.
#
# The installer itself was reachable throughout - the action was successfully
# downloading it from SourceForge, which is where this script gets it. So the
# dependency that broke the build was the package list, not the toolchain, and
# removing the intermediary removes the failure mode. That is the same reason
# every other dependency here is pinned: an unpinned intermediary is an
# AVAILABILITY dependency as much as a supply-chain one.
#
# What does NOT change: this script installs the same Lazarus 3.4 bundle,
# which ships the same FPC 3.2.2, so the `Assert FPC 3.2.2` step after it and
# all 77 other steps are untouched.
#
# Usage:  pwsh tools/get-fpc-windows.ps1 [-Force]
#         (from the repository root, on Windows only)
#
# On success it prints the FPC bin directory on the last line, so the caller
# can add it to the PATH.

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'fpc.lock'

# Deliberately not $IsWindows: that automatic variable does not exist in
# Windows PowerShell 5.1, where it would read as $false.
if ($env:OS -ne 'Windows_NT') { throw 'get-fpc-windows.ps1 runs on Windows only' }

# --- read the lock (strict: any malformed line is an error) -------------------
$Lock = @{}
$LineNo = 0
foreach ($line in Get-Content $LockFile) {
    $LineNo++
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '=') {
        throw "fpc.lock line ${LineNo}: malformed (expected 'key = value'): $line"
    }
    $k, $v = $line -split '=', 2
    $key = $k.Trim()
    if ($Lock.ContainsKey($key)) { throw "fpc.lock: duplicate key '$key'" }
    $Lock[$key] = $v.Trim()
}

$Required = 'version', 'windows-url', 'windows-sha256', 'windows-size',
            'windows-lazarus-version', 'windows-fpc-bindir', 'windows-compiler'
foreach ($key in $Required) {
    if (-not $Lock[$key]) { throw "fpc.lock: '$key' is required" }
}
if ($Lock['windows-sha256'] -notmatch '^[0-9a-f]{64}$') {
    throw 'fpc.lock: windows-sha256 is not a 64-char lowercase hex digest'
}

$Target = Join-Path $RepoRoot 'build\toolchain\lazarus'
# windows-fpc-bindir uses FORWARD slashes in the lock, deliberately: that file
# is parsed by PowerShell, bash and Python, and a backslash is a live escape
# hazard in more than one of them (it produced literal control characters in
# an earlier draft of this pin). GetFullPath normalises the separators here,
# once, so everything downstream - Test-Path, the PATH entry, the messages -
# sees a native Windows path.
$BinDir   = [IO.Path]::GetFullPath((Join-Path $Target $Lock['windows-fpc-bindir']))
$Compiler = Join-Path $BinDir $Lock['windows-compiler']

function Assert-Installed {
    if (-not (Test-Path -LiteralPath $Compiler)) {
        throw "the installer did not produce $Compiler"
    }
    $have = (& $Compiler -iV 2>$null | Out-String).Trim()
    if ($have -ne $Lock['version']) {
        throw "installed fpc reports '$have', fpc.lock pins '$($Lock['version'])'"
    }
    # The job is Win64/x86_64 and CAP-3U asserts exactly that later; catching a
    # 32-bit or otherwise wrong default here names the cause while the
    # installer is still the obvious suspect.
    $targetOs  = (& $Compiler -iTO | Out-String).Trim().ToLowerInvariant()
    $targetCpu = (& $Compiler -iTP | Out-String).Trim().ToLowerInvariant()
    if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
        throw "pinned FPC targets $targetOs/$targetCpu, expected win64/x86_64"
    }
    Write-Host "fpc $have ready at $Compiler (target $targetOs/$targetCpu)"
}

if ((Test-Path -LiteralPath $Compiler) -and -not $Force) {
    $have = ''
    try { $have = (& $Compiler -iV 2>$null | Out-String).Trim() } catch {}
    if ($have -eq $Lock['version']) {
        Assert-Installed
        # last line: the PATH entry the caller needs
        Write-Output $BinDir
        exit 0
    }
    Write-Host "fpc present but reports '$have' != '$($Lock['version'])': reinstalling"
}

# --- fetch --------------------------------------------------------------------
$Work = Join-Path $RepoRoot 'build\toolchain'
New-Item -ItemType Directory -Force $Work | Out-Null
$Installer = Join-Path $Work 'lazarus-setup.exe'

# Digest-verify whatever is already at this path BEFORE deciding to fetch, so a
# restored cache is reused without ever widening what is accepted: a truncated,
# stale or poisoned entry fails below exactly as a bad download would.
$Reused = $false
if (Test-Path -LiteralPath $Installer) {
    $CachedSize = (Get-Item -LiteralPath $Installer).Length
    if ("$CachedSize" -eq $Lock['windows-size']) {
        $CachedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Installer).Hash.ToLowerInvariant()
        if ($CachedSha -eq $Lock['windows-sha256']) {
            Write-Host "reusing the verified local copy at $Installer"
            $Reused = $true
        }
    }
    if (-not $Reused) {
        Write-Host 'local copy does not match the pin: discarding it'
        Remove-Item -Force -LiteralPath $Installer
    }
}

if (-not $Reused) {
    # curl, for the reason measured on the macOS side: SourceForge answers a
    # browser-shaped User-Agent with a "your download will start shortly"
    # interstitial, and PowerShell's default UA is browser-shaped. curl's is
    # not. The transfer is curl's; the VERIFICATION below stays here, which is
    # the half that has to be single-source. curl is preinstalled on the
    # windows-latest image.
    $Urls = @($Lock['windows-url'], $Lock['windows-url-fallback']) |
        Where-Object { $_ }
    $Fetched = $false
    foreach ($Url in $Urls) {
        Write-Host "fetching $Url"
        & curl.exe --location --fail --silent --show-error `
            --retry 3 --retry-delay 5 --retry-connrefused `
            --output $Installer -- $Url
        if ($LASTEXITCODE -ne 0) {
            Write-Host "curl exited $LASTEXITCODE for $Url"
            continue
        }
        # Reject an interstitial BY SHAPE before the digest gate, so the
        # failure names the real cause instead of a size mismatch. A Windows
        # installer begins with the PE/MZ magic.
        $Head = [byte[]]::new(2)
        $Stream = [IO.File]::OpenRead($Installer)
        try { $Read = $Stream.Read($Head, 0, 2) } finally { $Stream.Dispose() }
        if (($Read -lt 2) -or ($Head[0] -ne 0x4D) -or ($Head[1] -ne 0x5A)) {
            Write-Host "$Url did not serve a Windows executable (no MZ header)"
            continue
        }
        $Fetched = $true
        break
    }
    if (-not $Fetched) { throw 'could not fetch the pinned Lazarus installer' }
}

$Size = (Get-Item -LiteralPath $Installer).Length
if ("$Size" -ne $Lock['windows-size']) {
    Remove-Item -Force -LiteralPath $Installer
    throw "lazarus installer size is $Size, lock pins $($Lock['windows-size'])"
}
$Sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Installer).Hash.ToLowerInvariant()
if ($Sha -ne $Lock['windows-sha256']) {
    Remove-Item -Force -LiteralPath $Installer
    throw ("lazarus installer sha256 mismatch: expected $($Lock['windows-sha256'])," +
        " got $Sha -- upstream changed; ratify a new pin deliberately")
}
Write-Host "lazarus installer verified (sha256): $Sha"

# --- install ------------------------------------------------------------------
# Inno Setup (confirmed: the binary carries the Inno Setup / JR.Inno.Setup
# markers), so these are its documented silent switches - and the same ones
# gcarreno/setup-lazarus invoked:
#   /VERYSILENT  no UI at all
#   /SP-         no "this will install..." prompt
#   /DIR=        install location, kept inside build/ so it is git-ignored
# NO recursive delete on the default path, matching the rule the macOS gates
# now follow (cap7m_prepare_dir in test/cap7m/cap7m_common.sh): absent is
# created, empty is used, NON-EMPTY is a loud refusal. -Force is opt-in and is
# the only route to a removal. CI checks out fresh, so it never needs -Force;
# the wipe only ever served repeated local runs, and it is not worth a
# recursive delete on the default path of a script CI runs as a program.
#
# The containment check is the last line of defence: $Target is built from
# $PSScriptRoot and cannot realistically escape build\, but nothing here
# should be one empty variable away from deleting somewhere else.
$BuildRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'build'))
$TargetFull = [IO.Path]::GetFullPath($Target)
if (-not $TargetFull.StartsWith($BuildRoot + [IO.Path]::DirectorySeparatorChar)) {
    throw "refusing to touch '$TargetFull': outside '$BuildRoot'"
}
if (Test-Path -LiteralPath $Target) {
    $Existing = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue)
    if ($Existing.Count -gt 0) {
        if (-not $Force) {
            throw ("$Target already exists and is not empty. Re-using it would " +
                'let the installer merge into a previous install. Re-run with ' +
                '-Force, or remove the directory yourself.')
        }
        Write-Host "-Force: removing stale $Target"
        Remove-Item -Recurse -Force -LiteralPath $Target
    }
}
New-Item -ItemType Directory -Force $Target | Out-Null

Write-Host "installing to $Target"
$Proc = Start-Process -FilePath $Installer -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SP-', "/DIR=$Target"
)
if ($Proc.ExitCode -ne 0) {
    throw "the Lazarus installer exited $($Proc.ExitCode)"
}

Assert-Installed
# last line: the PATH entry the caller needs
Write-Output $BinDir
