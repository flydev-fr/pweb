# Fetches the pinned webview/webview commit into deps/webview (git-ignored).
# The pin lives in webview.lock at the repo root; this script never fetches
# a branch, a tag, or any floating ref -- only the exact SHA.
#
# Usage: pwsh tools/get-webview.ps1 [-Force]
#
# CAP-11B adds ONE optional input, and the pinned path above is what runs when
# it is absent. `-Ref <ref>` fetches that ref into a SEPARATE checkout,
# deps/webview-watch, for the upstream watcher to measure. It exists so the
# watcher can look at upstream head WITHOUT the lock moving: nothing here
# writes webview.lock, and the pinned checkout is never touched in ref mode.
#
# The recorded header checksums are deliberately NOT verified in ref mode.
# They pin the PINNED commit; asserting them against another commit would
# refuse every head that is not byte-identical to the pin, which is the exact
# question the watcher exists to answer rather than to reject.
#
# `-PrintPlan` resolves every path and mode, prints them, touches nothing and
# exits 0. It is what test/cap11b/check_ref_input.ps1 compares byte-for-byte
# against the recorded pinned plan, so "the ref input changed nothing when
# absent" is a comparison rather than a claim.
#
# Usage: pwsh tools/get-webview.ps1 [-Force] [-Ref <ref>] [-PrintPlan]

param(
    [switch]$Force,
    [string]$Ref,
    [switch]$PrintPlan
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

# --- CAP-11B: the one optional input, resolved in one place ------------------
# AN EXPLICIT EMPTY REF IS A REFUSAL, never a silent fall-back to pinned mode.
# `-Ref ''` reaching here as "no ref" would send a watcher fetch into
# `deps/webview` - the pinned checkout - which is the one outcome this input
# exists to make impossible.
if ($PSBoundParameters.ContainsKey('Ref') -and [string]::IsNullOrWhiteSpace($Ref)) {
    throw '-Ref was given an empty value; omit it for the pinned path'
}
$RefMode = -not [string]::IsNullOrWhiteSpace($Ref)
if ($RefMode) {
    $Checkout  = Join-Path $DepsDir 'webview-watch'
    $FetchSpec = $Ref.Trim()
}
else {
    $FetchSpec = $Sha
}

if ($PrintPlan) {
    # THE RESOLVED $Checkout, never a literal restating it. A plan that printed
    # its own idea of the path would still say `deps/webview-watch` after the
    # assignment above was broken, and the mirror check in
    # test/cap11b/check_ref_input.ps1 - whose whole job is to notice a ref plan
    # pointing at the pinned tree - would be comparing prose to prose.
    $planCheckout = $Checkout.Substring($RepoRoot.Length + 1).Replace('\', '/')
    $plan = @(
        'script=tools/get-webview.ps1'
        "mode=$(if ($RefMode) { 'ref' } else { 'pinned' })"
        "url=$Url"
        "fetch_spec=$FetchSpec"
        "checkout=$planCheckout"
        "verify_pinned_header_checksums=$(if ($RefMode) { 'false' } else { 'true' })"
        "checksum_rows=$($ShaKeys.Count)"
        "assert_head_equals_pin=$(if ($RefMode) { 'false' } else { 'true' })"
    )
    foreach ($line in $plan) { [Console]::Out.Write($line + "`n") }
    exit 0
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
if ($RefMode) {
    # THE ONE NETWORK STEP THE WATCHER TAKES. A ref, resolved by the remote,
    # fetched into its own checkout and never into the pinned one. Always
    # refetched: `-Ref HEAD` means "whatever upstream head is right now", and a
    # cached answer from last week would be a stale measurement wearing a
    # fresh timestamp.
    git -C $Checkout fetch --quiet --depth 1 origin $FetchSpec
    if ($LASTEXITCODE -ne 0) { throw "git fetch of ref '$FetchSpec' failed" }
    git -C $Checkout -c advice.detachedHead=false checkout --quiet --force FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "git checkout of ref '$FetchSpec' failed" }
}
elseif ($Current -ne $Sha) {
    # Fetch only the pinned commit. No branch names, no tags, no HEAD.
    git -C $Checkout fetch --quiet --depth 1 origin $Sha
    if ($LASTEXITCODE -ne 0) { throw "git fetch of pinned SHA $Sha failed" }
    git -C $Checkout -c advice.detachedHead=false checkout --quiet --force $Sha
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned SHA $Sha failed" }
}
$Resolved = if ($RefMode) { (git -C $Checkout rev-parse HEAD).Trim() } else { $Sha }

# Even when HEAD already matches, the working tree may have been modified
# locally. Only a handful of headers are checksummed below but the WHOLE tree
# feeds the DLL build, so restore a pristine tree whenever it is dirty.
$Dirty = git -C $Checkout status --porcelain
if ($Dirty) {
    Write-Host 'pinned checkout modified locally -- restoring pristine tree'
    git -C $Checkout checkout --force --quiet $Resolved
    if ($LASTEXITCODE -ne 0) { throw 'git checkout --force failed while cleaning' }
    git -C $Checkout clean -fdxq
    if ($LASTEXITCODE -ne 0) { throw 'git clean failed while cleaning' }
    $Dirty = git -C $Checkout status --porcelain
    if ($Dirty) { throw 'pinned checkout still dirty after clean' }
}

# git content addressing already guarantees the tree matches the commit SHA;
# verify it anyway, then cross-check the recorded header checksums.
$Head = git -C $Checkout rev-parse HEAD
if (-not $RefMode) {
    if ($Head -ne $Sha) { throw "checkout mismatch: HEAD=$Head expected=$Sha" }
}

# --- verify recorded header checksums ---------------------------------------
# The recorded value is the sha256 of the file with LF line endings, i.e. of
# the UPSTREAM BLOB CONTENT, so one pin is correct on every host.
#
# It has to be normalised rather than hashed raw. Git for Windows defaults to
# core.autocrlf=true, so this checkout materialises these headers with CRLF
# while a Linux checkout materialises them with LF - the same commit, two
# different byte streams, and a raw hash can only ever match one of them.
# CAP-7L is simply the first thing to run this verifier off Windows; the pin
# was host-specific from the day it was recorded.
#
# This does not weaken the pin in any way that matters: the authoritative
# identity is the exact commit SHA asserted above, these checksums are a
# cross-check on top of it, and the only difference a normalised hash can
# miss is the line endings the consumer's own git config just chose.
function Get-NormalisedSha256([string]$Path) {
    # byte level on purpose - no text decode, no encoding round-trip, no BOM
    # guessing; only the two-byte CRLF sequence collapses to LF, exactly
    # reversing what autocrlf did on checkout
    $bytes = [IO.File]::ReadAllBytes($Path)
    $out = [byte[]]::new($bytes.Length)
    $n = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if (($bytes[$i] -eq 13) -and ($i + 1 -lt $bytes.Length) -and
            ($bytes[$i + 1] -eq 10)) { continue }
        $out[$n] = $bytes[$i]
        $n++
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($out, 0, $n)
    }
    finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
}

if ($RefMode) {
    # The recorded checksums pin the PINNED commit. Comparing them against
    # another commit would refuse every head that differs from the pin - which
    # is the question the watcher is asking, not an error. The DIFF reports
    # which headers moved; that is a measurement, and this would be a refusal.
    $when = (git -C $Checkout log -1 --format=%cI).Trim()
    Write-Host "webview ref checkout OK: $Head ($when)"
    Write-Host "  ref '$FetchSpec' at $Checkout (pinned checkout untouched)"
    exit 0
}

$Failures = @()
foreach ($key in $ShaKeys) {
    $Rel  = $key.Substring(7)
    $Path = Join-Path $Checkout $Rel
    if (-not (Test-Path $Path)) { $Failures += "pinned file missing: $Rel"; continue }
    $Hash = Get-NormalisedSha256 $Path
    if ($Hash -cne $Lock[$key]) {
        $Failures += "checksum mismatch for ${Rel}: got $Hash expected $($Lock[$key])"
    }
}
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { [Console]::Error.WriteLine("ERROR: $f") }
    throw "pinned header checksum verification failed ($($Failures.Count) finding(s))"
}

Write-Host "webview pinned checkout OK: $Sha ($($ShaKeys.Count) checksums verified)"
Write-Host "  at $Checkout"
