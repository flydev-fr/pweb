# Installs the PINNED Free Pascal Compiler on a macOS build host (CAP-7M0).
#
# The macOS sibling of tools/get-webview.ps1 and tools/get-mormot.ps1, and
# deliberately the same shape: read the lock, fetch the exact pinned artifact,
# verify it BEFORE it is used, assert what the install actually produced, and
# fail loudly on any drift. The pin policy admits no `brew install fpc` (a
# floating pin by construction) and no runner-supplied toolchain.
#
# Written in PowerShell for the same reason CAP-7L kept the Linux fetches in
# PowerShell: the digest-verification logic stays SINGLE-SOURCE across every
# platform instead of growing a bash twin of a security-critical verifier.
# pwsh is preinstalled on the hosted macOS images.
#
# Two things this script does that its Windows/Linux siblings do not need:
#
#   1. It selects Xcode from the pinned candidate list in fpc.lock and
#      exports DEVELOPER_DIR. FPC 3.2.2 predates every Xcode on the image and
#      has open linker failures on some of them, so the toolchain the linker
#      runs under is a pin, not a default.
#   2. It verifies fpc.cfg exists, and regenerates it from FPC's own shipped
#      `samplecfg` if the installer did not. Without it every compile fails
#      with "can't find unit system", which reads as a source problem and is
#      not one.
#
# Usage:  pwsh tools/get-fpc-macos.ps1 [-Force]
#         (from the repository root, on macOS only)

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'fpc.lock'

if ($env:OS -eq 'Windows_NT') { throw 'get-fpc-macos.ps1 runs on macOS only' }
if ((& uname -s).Trim() -ne 'Darwin') {
    throw "get-fpc-macos.ps1 runs on macOS only, host reports $((& uname -s).Trim())"
}

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

$Required = 'version', 'macos-url', 'macos-sha256', 'macos-md5', 'macos-size',
            'macos-volume', 'macos-package', 'macos-compiler-x64',
            'macos-compiler-arm64', 'macos-prefix', 'macos-xcode-candidates',
            'macos-xcode-known-bad'
foreach ($key in $Required) {
    if (-not $Lock[$key]) { throw "fpc.lock: '$key' is required" }
}
if ($Lock['macos-sha256'] -notmatch '^[0-9a-f]{64}$') {
    throw "fpc.lock: macos-sha256 is not a 64-char lowercase hex digest"
}
if ($Lock['macos-md5'] -notmatch '^[0-9a-f]{32}$') {
    throw "fpc.lock: macos-md5 is not a 32-char lowercase hex digest"
}

# --- Xcode: pinned candidate list, never the runner default -------------------
$KnownBad = @($Lock['macos-xcode-known-bad'] -split '\s+' | Where-Object { $_ })
$Candidates = @($Lock['macos-xcode-candidates'] -split '\s+' | Where-Object { $_ })
foreach ($c in $Candidates) {
    if ($KnownBad -contains $c) {
        throw ("fpc.lock lists Xcode $c as both a candidate and known-bad;" +
            ' a known-broken toolchain is never a fallback')
    }
}

$Installed = @(Get-ChildItem -Path '/Applications' -Filter 'Xcode*.app' `
    -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
Write-Host "xcode present on this image: $($Installed -join ', ')"

$Selected = $null
foreach ($c in $Candidates) {
    $path = "/Applications/Xcode_$c.app"
    if (Test-Path -LiteralPath $path) { $Selected = $path; break }
}
if (-not $Selected) {
    throw ("no pinned Xcode available: fpc.lock allows [$($Candidates -join ', ')]," +
        " image carries [$($Installed -join ', ')] --" +
        ' ratify a new macos-xcode-candidates value from this evidence')
}

$DeveloperDir = Join-Path $Selected 'Contents/Developer'
if (-not (Test-Path -LiteralPath $DeveloperDir)) {
    throw "selected Xcode has no Contents/Developer: $Selected"
}
$env:DEVELOPER_DIR = $DeveloperDir
if ($env:GITHUB_ENV) {
    "DEVELOPER_DIR=$DeveloperDir" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
}
Write-Host "xcode selected (pinned): $Selected"
& xcodebuild -version
if ($LASTEXITCODE -ne 0) { throw 'xcodebuild -version failed under the pinned DEVELOPER_DIR' }

# --- already installed? -------------------------------------------------------
$Prefix = $Lock['macos-prefix']
$Fpc = Join-Path $Prefix 'bin/fpc'

function Assert-Installed {
    $have = ''
    try { $have = (& $Fpc -iV 2>$null | Out-String).Trim() } catch {}
    if ($have -ne $Lock['version']) {
        throw "installed fpc reports '$have', lock pins '$($Lock['version'])'"
    }
    # BOTH native compilers, on BOTH jobs: a disk image that stopped shipping
    # one of them is a changed artifact, and this is where that is noticed.
    $unitDir = Join-Path $Prefix "lib/fpc/$($Lock['version'])"
    foreach ($key in 'macos-compiler-x64', 'macos-compiler-arm64') {
        $ppc = Join-Path $unitDir $Lock[$key]
        if (-not (Test-Path -LiteralPath $ppc)) {
            throw "pinned artifact did not install $($Lock[$key]) at $ppc"
        }
    }
    # fpc.cfg or nothing compiles; FPC ships samplecfg to generate it
    $cfg = '/etc/fpc.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) {
        $sample = Join-Path $unitDir 'samplecfg'
        if (-not (Test-Path -LiteralPath $sample)) {
            throw "no $cfg and no samplecfg at $sample -- cannot configure FPC"
        }
        Write-Host "no $cfg after install: generating it with FPC's own samplecfg"
        & sudo $sample $unitDir
        if ($LASTEXITCODE -ne 0) { throw 'samplecfg failed' }
        if (-not (Test-Path -LiteralPath $cfg)) { throw "samplecfg did not produce $cfg" }
    }
    $targetCpu = (& $Fpc -iTP | Out-String).Trim()
    $targetOs = (& $Fpc -iTO | Out-String).Trim()
    Write-Host "fpc $have ready at $Fpc (default target $targetOs/$targetCpu)"
}

if ((Test-Path -LiteralPath $Fpc) -and -not $Force) {
    $have = ''
    try { $have = (& $Fpc -iV 2>$null | Out-String).Trim() } catch {}
    if ($have -eq $Lock['version']) {
        Assert-Installed
        exit 0
    }
    Write-Host "fpc present but reports '$have' != '$($Lock['version'])': reinstalling"
}

# --- fetch -------------------------------------------------------------------
$Work = Join-Path $RepoRoot 'build/cap7m/toolchain'
New-Item -ItemType Directory -Force $Work | Out-Null
$Dmg = Join-Path $Work 'fpc-macos.dmg'

# Digest-verify whatever is already at this path BEFORE deciding to fetch.
# A restored CI cache lands exactly here, and re-downloading ~262 MiB on
# every push is the largest avoidable cost in these jobs. Reusing it is only
# safe because the verification below is UNCONDITIONAL: a truncated, stale
# or poisoned cache entry fails in precisely the same way a bad download
# does, so caching can never widen what this script accepts.
$Reused = $false
if (Test-Path -LiteralPath $Dmg) {
    $CachedSize = (Get-Item -LiteralPath $Dmg).Length
    if ("$CachedSize" -eq $Lock['macos-size']) {
        $CachedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Dmg).Hash.ToLowerInvariant()
        if ($CachedSha -eq $Lock['macos-sha256']) {
            Write-Host "reusing the verified local copy at $Dmg"
            $Reused = $true
        }
    }
    if (-not $Reused) {
        Write-Host 'local copy does not match the pin: discarding it'
        Remove-Item -Force -LiteralPath $Dmg
    }
}

if (-not $Reused) {
    # MEASURED (hosted run 31903085050): Invoke-WebRequest against the pinned
    # SourceForge url returned 145464 bytes of HTML instead of the 274206896
    # byte image. SourceForge serves its "your download will start shortly"
    # interstitial to clients whose User-Agent looks like a browser, and
    # PowerShell's default UA does; curl's does not, and gets a 302 to a
    # mirror followed by application/x-apple-diskimage. So the transfer is
    # curl's and the VERIFICATION stays here, which is the half that has to
    # be single-source. curl is preinstalled on every hosted macOS image.
    #
    # The size/sha256/md5 gate below caught the HTML page cleanly, so this is
    # a fetch-reliability fix, not a trust fix: nothing about what the script
    # ACCEPTS changes, and a future interstitial fails exactly as this one did.
    $Urls = @($Lock['macos-url'], $Lock['macos-url-fallback']) |
        Where-Object { $_ }
    $Fetched = $false
    foreach ($Url in $Urls) {
        Write-Host "fetching $Url"
        & curl --location --fail --silent --show-error `
            --retry 3 --retry-delay 5 --retry-connrefused `
            --output $Dmg -- $Url
        if ($LASTEXITCODE -ne 0) {
            Write-Host "curl exited $LASTEXITCODE for $Url"
            continue
        }
        # Reject the interstitial by shape before the digest gate, so the
        # failure names the real cause instead of a size mismatch.
        $Head = [byte[]]::new(512)
        $Stream = [IO.File]::OpenRead($Dmg)
        try { $Read = $Stream.Read($Head, 0, 512) } finally { $Stream.Dispose() }
        $Text = [Text.Encoding]::ASCII.GetString($Head, 0, $Read)
        if ($Text -match '(?i)<!doctype html|<html') {
            Write-Host "$Url served an HTML page, not the disk image"
            continue
        }
        $Fetched = $true
        break
    }
    if (-not $Fetched) {
        throw ('fpc disk image could not be fetched from any pinned url: ' +
            ($Urls -join ', '))
    }
}

$Size = (Get-Item -LiteralPath $Dmg).Length
if ("$Size" -ne $Lock['macos-size']) {
    Remove-Item -Force -LiteralPath $Dmg
    throw "fpc disk image size is $Size, lock pins $($Lock['macos-size'])"
}
$Sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Dmg).Hash.ToLowerInvariant()
$Md5 = (Get-FileHash -Algorithm MD5 -LiteralPath $Dmg).Hash.ToLowerInvariant()
if ($Sha -ne $Lock['macos-sha256']) {
    Remove-Item -Force -LiteralPath $Dmg
    throw ("fpc disk image sha256 mismatch: expected $($Lock['macos-sha256'])," +
        " got $Sha -- upstream changed; ratify a new pin deliberately")
}
if ($Md5 -ne $Lock['macos-md5']) {
    Remove-Item -Force -LiteralPath $Dmg
    throw ("fpc disk image md5 mismatch: expected $($Lock['macos-md5']), got $Md5")
}
Write-Host "fpc disk image verified (sha256 + md5): $Sha"

# --- attach, install, detach --------------------------------------------------
$Mount = Join-Path $Work 'mnt'
if (Test-Path -LiteralPath $Mount) {
    # a mount left behind by an aborted earlier run
    & hdiutil detach $Mount -force 2>$null | Out-Null
    Remove-Item -Recurse -Force -LiteralPath $Mount -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force $Mount | Out-Null

# -nobrowse keeps it out of Finder; -readonly and -noverify keep the attach
# deterministic and quick (the bytes are already verified above).
& hdiutil attach $Dmg -mountpoint $Mount -nobrowse -readonly -noverify -quiet
if ($LASTEXITCODE -ne 0) { throw 'hdiutil attach failed' }

try {
    $Pkg = Join-Path $Mount $Lock['macos-package']
    if (-not (Test-Path -LiteralPath $Pkg)) {
        $found = (Get-ChildItem -LiteralPath $Mount | ForEach-Object { $_.Name }) -join ', '
        throw ("disk image does not carry $($Lock['macos-package']) -- it holds [$found];" +
            ' the pinned artifact changed shape')
    }
    Write-Host "installing $($Lock['macos-package'])"
    & sudo installer -pkg $Pkg -target /
    if ($LASTEXITCODE -ne 0) { throw 'installer failed' }
}
finally {
    & hdiutil detach $Mount -quiet 2>$null | Out-Null
}

Assert-Installed
