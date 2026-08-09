# Fetches the pinned webview/webview commit into deps/webview (git-ignored).
# The pin lives in webview.lock at the repo root; this script never fetches
# a branch, a tag, or any floating ref -- only the exact SHA.
#
# Usage: pwsh tools/get-webview.ps1 [-Force]

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'webview.lock'
$DepsDir  = Join-Path $RepoRoot 'deps'
$Checkout = Join-Path $DepsDir 'webview'

# --- read the lock (strict: any malformed line is an error) -------------------
$Lock = @{}
$LineNo = 0
foreach ($line in Get-Content $LockFile) {
    $LineNo++
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '=') {
        throw "webview.lock line ${LineNo}: malformed (expected 'key = value'): $line"
    }
    $k, $v = $line -split '=', 2
    $Lock[$k.Trim()] = $v.Trim()
}

$Url = $Lock['url']
$Sha = $Lock['commit']
if (-not $Url -or -not $Sha) { throw "webview.lock: 'url' and 'commit' are required" }
if ($Sha -notmatch '^[0-9a-f]{40}$') { throw "webview.lock: commit '$Sha' is not a full 40-char SHA" }

$ShaKeys = @($Lock.Keys | Where-Object { $_ -like 'sha256:*' })
if ($ShaKeys.Count -eq 0) {
    throw 'webview.lock: no sha256: entries -- checksum verification would be vacuous'
}

# --- fetch the exact SHA -----------------------------------------------------
if ((Test-Path $Checkout) -and $Force) { Remove-Item -Recurse -Force $Checkout }

if (-not (Test-Path (Join-Path $Checkout '.git'))) {
    New-Item -ItemType Directory -Force $Checkout | Out-Null
    git -C $Checkout init --quiet
    git -C $Checkout remote add origin $Url
}
else {
    # keep the remote in sync with the lock so a URL change is never ignored
    git -C $Checkout remote set-url origin $Url
    if ($LASTEXITCODE -ne 0) { throw 'git remote set-url failed' }
}

$Current = git -C $Checkout rev-parse --verify --quiet HEAD
if ($Current -ne $Sha) {
    # Fetch only the pinned commit. No branch names, no tags, no HEAD.
    git -C $Checkout fetch --quiet --depth 1 origin $Sha
    if ($LASTEXITCODE -ne 0) { throw "git fetch of pinned SHA $Sha failed" }
    git -C $Checkout -c advice.detachedHead=false checkout --quiet --force $Sha
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned SHA $Sha failed" }
}

# Even when HEAD already matches, the working tree may have been modified
# locally. Only a handful of headers are checksummed below but the WHOLE tree
# feeds the DLL build, so restore a pristine tree whenever it is dirty.
$Dirty = git -C $Checkout status --porcelain
if ($Dirty) {
    Write-Host 'pinned checkout modified locally -- restoring pristine tree'
    git -C $Checkout checkout --force --quiet $Sha
    if ($LASTEXITCODE -ne 0) { throw 'git checkout --force failed while cleaning' }
    git -C $Checkout clean -fdxq
    if ($LASTEXITCODE -ne 0) { throw 'git clean failed while cleaning' }
    $Dirty = git -C $Checkout status --porcelain
    if ($Dirty) { throw 'pinned checkout still dirty after clean' }
}

# git content addressing already guarantees the tree matches the commit SHA;
# verify it anyway, then cross-check the recorded header checksums.
$Head = git -C $Checkout rev-parse HEAD
if ($Head -ne $Sha) { throw "checkout mismatch: HEAD=$Head expected=$Sha" }

# --- verify recorded header checksums ---------------------------------------
$Failures = @()
foreach ($key in $ShaKeys) {
    $Rel  = $key.Substring(7)
    $Path = Join-Path $Checkout $Rel
    if (-not (Test-Path $Path)) { $Failures += "pinned file missing: $Rel"; continue }
    $Hash = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($Hash -ne $Lock[$key]) {
        $Failures += "checksum mismatch for ${Rel}: got $Hash expected $($Lock[$key])"
    }
}
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { [Console]::Error.WriteLine("ERROR: $f") }
    throw "pinned header checksum verification failed ($($Failures.Count) finding(s))"
}

Write-Host "webview pinned checkout OK: $Sha ($($ShaKeys.Count) checksums verified)"
Write-Host "  at $Checkout"
