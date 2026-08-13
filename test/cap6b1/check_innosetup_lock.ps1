# CAP-6b1 fixture-driven gates over tools/get-innosetup.ps1, modeled
# on test/cap6b/check_wv2lock.ps1: strict lock parsing (malformed
# line, unknown key, duplicate key, bad digest shape, missing keys),
# the verify-BEFORE-execute contract (a sha256 or size mismatch
# deletes the download and aborts before any execution attempt - the
# target toolchain dir is never created), the URL allowlist (foreign
# https refused even in fixture mode), and the sha-stamp cache
# (pin-matching cache reused with no re-download; stamp drift
# reprovisions from scratch).
#
# Every fixture is generated locally below build/cap6b1/is-fixtures
# and every payload is a local file via -AllowLocalSource: ZERO
# network, and no installer is ever executed here (the only
# pass-verification flow exercised is the cache hit, which exits
# before any fetch or execution by construction).
#
# Usage: pwsh -File test/cap6b1/check_innosetup_lock.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Tool = Join-Path $RepoRoot 'tools/get-innosetup.ps1'
$Fix = Join-Path $RepoRoot 'build/cap6b1/is-fixtures'
if (Test-Path $Fix) { Remove-Item -Recurse -Force $Fix }
New-Item -ItemType Directory -Force $Fix | Out-Null

$script:Passed = 0

function Invoke-Tool {
    param([string[]]$ToolArgs)
    $out = & pwsh -NoProfile -File $Tool @ToolArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Assert-Refused {
    param($R, [string]$Pattern, [string]$What)
    if ($R.Code -eq 0) {
        throw "expected refusal for ${What}, got success: $($R.Out)"
    }
    if ($R.Out -notmatch $Pattern) {
        throw "refusal for $What does not match '$Pattern': $($R.Out)"
    }
    Write-Host "PASS: $What (refused: $Pattern)"
    $script:Passed++
}

function New-Fixture {
    param([string]$Name, [string]$Body)
    $path = Join-Path $Fix $Name
    Set-Content -LiteralPath $path -Value $Body -NoNewline -Encoding utf8
    $path
}

# deterministic local payload standing in for the installer download
$Payload = Join-Path $Fix 'installer-payload.bin'
$bytes = [byte[]](0..2047 | ForEach-Object { ($_ * 11) -band 0xff })
[IO.File]::WriteAllBytes($Payload, $bytes)
$GoodHash = (Get-FileHash -Algorithm SHA256 -Path $Payload).Hash.ToLowerInvariant()
$GoodSize = (Get-Item $Payload).Length
$PayloadUrl = $Payload -replace '\\', '/'

# --- 1) the real repository innosetup.lock parses (validation only:
# --- point the target at a fixture dir with a matching stamp so the
# --- cache hit exits BEFORE any network fetch could happen) ------------------
$repoLockPath = Join-Path $RepoRoot 'innosetup.lock'
$repoSha = ((Get-Content $repoLockPath | Where-Object { $_ -match '^sha256' }) -split '=', 2)[1].Trim()
$cacheDir = Join-Path $Fix 'repo-cache'
New-Item -ItemType Directory -Force $cacheDir | Out-Null
Set-Content (Join-Path $cacheDir 'ISCC.exe') 'stand-in' -NoNewline
Set-Content (Join-Path $cacheDir '.pweb-pin') $repoSha -NoNewline -Encoding ascii
$r = Invoke-Tool @('-TargetDir', $cacheDir)
if (($r.Code -ne 0) -or ($r.Out -notmatch 'already provisioned')) {
    throw "repo lock validation via cache hit failed (exit $($r.Code)): $($r.Out)"
}
Write-Host 'PASS: repository innosetup.lock parses (cache-hit validation, zero network)'
$script:Passed++

# --- 2) sha256 mismatch: refused, download deleted, target never
# --- created - verification provably precedes any execution attempt ----------
$bad = New-Fixture 'wrong-sha.lock' @"
version = 6.7.3
url = $PayloadUrl
size = $GoodSize
sha256 = $('0' * 64)
"@
$tgt = Join-Path $Fix 'tgt-wrong-sha'
$r = Invoke-Tool @('-LockFile', $bad, '-TargetDir', $tgt, '-AllowLocalSource')
Assert-Refused $r 'sha256 mismatch' 'checksum mismatch rejected before execution'
if ($r.Out -notmatch [regex]::Escape($GoodHash)) {
    throw "mismatch error does not name the actual digest: $($r.Out)"
}
if (Test-Path (Join-Path $Fix 'innosetup-download.exe')) {
    throw 'mismatched download survived'
}
if (Test-Path $tgt) { throw 'mismatched fetch created a target toolchain dir' }
Write-Host 'PASS: sha mismatch deleted the download and never created the target'
$script:Passed++

# --- 3) size mismatch: same fail-closed shape --------------------------------
$bad = New-Fixture 'wrong-size.lock' @"
version = 6.7.3
url = $PayloadUrl
size = 1
sha256 = $GoodHash
"@
$tgt = Join-Path $Fix 'tgt-wrong-size'
$r = Invoke-Tool @('-LockFile', $bad, '-TargetDir', $tgt, '-AllowLocalSource')
Assert-Refused $r 'size mismatch' 'size mismatch rejected before execution'
if (Test-Path (Join-Path $Fix 'innosetup-download.exe')) {
    throw 'size-mismatched download survived'
}
if (Test-Path $tgt) { throw 'size-mismatched fetch created a target dir' }
Write-Host 'PASS: size mismatch deleted the download and never created the target'
$script:Passed++

# --- 4) parser refusals -------------------------------------------------------
$bad = New-Fixture 'malformed.lock' @"
version = 6.7.3
url no equals sign here
"@
$r = Invoke-Tool @('-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r 'line 2.*malformed' 'malformed line refused with line number'

$bad = New-Fixture 'unknown-key.lock' @"
version = 6.7.3
url = $PayloadUrl
size = $GoodSize
sha256 = $GoodHash
mirror = somewhere
"@
$r = Invoke-Tool @('-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 5.*unknown key 'mirror'" 'unknown key refused with line number'

$bad = New-Fixture 'dup-key.lock' @"
version = 6.7.3
version = 6.7.4
"@
$r = Invoke-Tool @('-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 2.*duplicate key 'version'" 'duplicate key refused'

$bad = New-Fixture 'shouty-sha.lock' @"
version = 6.7.3
url = $PayloadUrl
size = $GoodSize
sha256 = $($GoodHash.ToUpperInvariant())
"@
$r = Invoke-Tool @('-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r 'not a 64-char lowercase hex digest' 'uppercase digest refused'

$bad = New-Fixture 'missing-sha.lock' @"
version = 6.7.3
url = $PayloadUrl
size = $GoodSize
"@
$r = Invoke-Tool @('-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "'sha256' is required" 'missing sha256 refused'

# --- 5) URL allowlist: foreign https refused even in fixture mode ------------
$bad = New-Fixture 'foreign-url.lock' @"
version = 6.7.3
url = https://evil.example/innosetup.exe
size = $GoodSize
sha256 = $GoodHash
"@
$r = Invoke-Tool @('-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r 'must be https on github\.com/jrsoftware' `
    'foreign https host refused even in fixture mode'

$bad = New-Fixture 'local-no-switch.lock' @"
version = 6.7.3
url = $PayloadUrl
size = $GoodSize
sha256 = $GoodHash
"@
$r = Invoke-Tool @('-LockFile', $bad)
Assert-Refused $r 'must be https on github\.com/jrsoftware' `
    'local url refused outside fixture mode'

# --- 6) sha-stamp cache: pin-matching cache reused with NO re-download
# --- (the url is a nonexistent path: any fetch attempt would fail) -----------
$cached = New-Fixture 'cached.lock' @"
version = 6.7.3
url = $Fix/does-not-exist.bin
size = $GoodSize
sha256 = $GoodHash
"@
$tgt = Join-Path $Fix 'tgt-cached'
New-Item -ItemType Directory -Force $tgt | Out-Null
Set-Content (Join-Path $tgt 'ISCC.exe') 'stand-in' -NoNewline
Set-Content (Join-Path $tgt '.pweb-pin') $GoodHash -NoNewline -Encoding ascii
$r = Invoke-Tool @('-LockFile', $cached, '-TargetDir', $tgt, '-AllowLocalSource')
if (($r.Code -ne 0) -or ($r.Out -notmatch 'already provisioned')) {
    throw "matching stamp was not reused (exit $($r.Code)): $($r.Out)"
}
Write-Host 'PASS: matching sha stamp reused the cache without any fetch'
$script:Passed++

# --- 7) stamp drift: reprovisions from scratch (cache torn down, then
# --- the impossible fetch fails loudly - proving the re-fetch WAS
# --- attempted and no stale toolchain survives a pin bump) -------------------
Set-Content (Join-Path $tgt '.pweb-pin') ('f' * 64) -NoNewline -Encoding ascii
$r = Invoke-Tool @('-LockFile', $cached, '-TargetDir', $tgt, '-AllowLocalSource')
Assert-Refused $r 'local source not found' 'stamp drift triggered a reprovision fetch'
if ($r.Out -notmatch 'reprovisioning') {
    throw "stamp drift did not announce reprovisioning: $($r.Out)"
}
if (Test-Path $tgt) {
    throw 'stale toolchain survived a stamp drift (fail-closed teardown missing)'
}
Write-Host 'PASS: stamp drift tore down the stale cache and attempted a fresh fetch'
$script:Passed++

Write-Host "CAP6B1_INNOSETUP_LOCK_PASS cases=$($script:Passed)"
