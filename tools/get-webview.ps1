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

# --- read the lock -----------------------------------------------------------
$Lock = @{}
foreach ($line in Get-Content $LockFile) {
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $k, $v = $line -split '=', 2
    $Lock[$k.Trim()] = $v.Trim()
}

$Url = $Lock['url']
$Sha = $Lock['commit']
if (-not $Url -or -not $Sha) { throw "webview.lock: 'url' and 'commit' are required" }
if ($Sha -notmatch '^[0-9a-f]{40}$') { throw "webview.lock: commit '$Sha' is not a full 40-char SHA" }

# --- fetch the exact SHA -----------------------------------------------------
if ((Test-Path $Checkout) -and $Force) { Remove-Item -Recurse -Force $Checkout }

if (-not (Test-Path (Join-Path $Checkout '.git'))) {
    New-Item -ItemType Directory -Force $Checkout | Out-Null
    git -C $Checkout init --quiet
    git -C $Checkout remote add origin $Url
}

$Current = git -C $Checkout rev-parse --verify --quiet HEAD
if ($Current -ne $Sha) {
    # Fetch only the pinned commit. No branch names, no tags, no HEAD.
    git -C $Checkout fetch --quiet --depth 1 origin $Sha
    if ($LASTEXITCODE -ne 0) { throw "git fetch of pinned SHA $Sha failed" }
    git -C $Checkout -c advice.detachedHead=false checkout --quiet --force $Sha
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned SHA $Sha failed" }
}

# git content addressing already guarantees the tree matches the commit SHA;
# verify it anyway, then cross-check the recorded header checksums.
$Head = git -C $Checkout rev-parse HEAD
if ($Head -ne $Sha) { throw "checkout mismatch: HEAD=$Head expected=$Sha" }

# --- verify recorded header checksums ---------------------------------------
$Failed = $false
foreach ($key in $Lock.Keys | Where-Object { $_ -like 'sha256:*' }) {
    $Rel  = $key.Substring(7)
    $Path = Join-Path $Checkout $Rel
    if (-not (Test-Path $Path)) { Write-Error "pinned file missing: $Rel"; $Failed = $true; continue }
    $Hash = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($Hash -ne $Lock[$key]) {
        Write-Error "checksum mismatch for ${Rel}: got $Hash expected $($Lock[$key])"
        $Failed = $true
    }
}
if ($Failed) { throw 'pinned header checksum verification failed' }

Write-Host "webview pinned checkout OK: $Sha"
Write-Host "  at $Checkout"
