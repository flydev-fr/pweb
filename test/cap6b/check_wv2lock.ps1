# CAP-6b0 fixture-driven gates over tools/get-webview2-runtime.ps1:
# strict lock parsing (malformed line, duplicate key, missing sha256,
# unknown key, key outside a block, bad digest shape, missing schema)
# and the fetch-verify contract (sha256 checked BEFORE any use; a
# mismatched download is deleted and the error names both digests).
# CAP-6b1 adds the authenticode-subject second axis: key parse, the
# unsigned and wrong-subject refusals (correct hash, wrong identity),
# and the real-lock check that the ratified evergreen-bootstrapper pin
# carries the exact Microsoft subject.
#
# Every fixture is generated locally below build/cap6b/fixtures and the
# fetch legs read local payload files via -AllowLocalSource: ZERO
# network is involved, and no Microsoft binary is ever touched here.
#
# Usage: pwsh -File test/cap6b/check_wv2lock.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Tool = Join-Path $RepoRoot 'tools/get-webview2-runtime.ps1'
$Fix = Join-Path $RepoRoot 'build/cap6b/fixtures'
if (Test-Path $Fix) { Remove-Item -Recurse -Force $Fix }
New-Item -ItemType Directory -Force $Fix | Out-Null

$script:Passed = 0

function Invoke-Tool {
    param([string[]]$ToolArgs)
    $out = & pwsh -NoProfile -File $Tool @ToolArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Assert-Pass {
    param($R, [string]$What)
    if ($R.Code -ne 0) {
        throw "expected success for ${What}, got exit $($R.Code): $($R.Out)"
    }
    Write-Host "PASS: $What"
    $script:Passed++
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

# --- deterministic local payload standing in for a Microsoft binary ---------
$Payload = Join-Path $Fix 'payload.bin'
$bytes = [byte[]](0..4095 | ForEach-Object { ($_ * 7) -band 0xff })
[IO.File]::WriteAllBytes($Payload, $bytes)
$GoodHash = (Get-FileHash -Algorithm SHA256 -Path $Payload).Hash.ToLowerInvariant()
$GoodSize = (Get-Item $Payload).Length
# lock values embed the payload path; escape for here-string interpolation
$PayloadUrl = $Payload -replace '\\', '/'

function New-Fixture {
    param([string]$Name, [string]$Body)
    $path = Join-Path $Fix $Name
    # utf8: interpolated payload paths must survive non-ASCII checkouts
    Set-Content -LiteralPath $path -Value $Body -NoNewline -Encoding utf8
    $path
}

# --- 1) the real repository lock validates and carries the CAP-6b1
# --- ratified bootstrapper pin with its authenticode-subject axis ------------
$r = Invoke-Tool @('-Validate')
Assert-Pass $r 'repository webview2-runtime.lock validates'
if ($r.Out -notmatch 'schema 1') { throw "repo lock summary missing schema: $($r.Out)" }
# \r?$ keeps the anchors CRLF-safe on autocrlf checkouts
$repoLock = Get-Content (Join-Path $RepoRoot 'webview2-runtime.lock') -Raw
if ($repoLock -notmatch '(?m)^artifact = evergreen-bootstrapper\r?$') {
    throw 'repo lock is missing the ratified evergreen-bootstrapper artifact'
}
if ($repoLock -notmatch '(?m)^authenticode-subject = CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US\r?$') {
    throw 'repo lock is missing the ratified Microsoft authenticode-subject pin'
}
Write-Host 'PASS: repo lock pins evergreen-bootstrapper with the Microsoft subject axis'
$script:Passed++

# --- 2) valid fixture lock: parses, fetches and verifies a local payload ----
$valid = New-Fixture 'valid.lock' @"
schema = 1
artifact = evergreen-bootstrapper-test
kind = bootstrapper
arch = neutral
url = $PayloadUrl
filename = fetched-payload.bin
size = $GoodSize
sha256 = $GoodHash
"@
$dest = Join-Path $Fix 'dest-valid'
$r = Invoke-Tool @('-Validate', '-LockFile', $valid, '-AllowLocalSource')
Assert-Pass $r 'valid fixture lock validates'
$r = Invoke-Tool @('-LockFile', $valid, '-DestDir', $dest, '-AllowLocalSource')
Assert-Pass $r 'valid fixture lock fetch-verify succeeds'
$fetched = Join-Path $dest 'fetched-payload.bin'
if (-not (Test-Path $fetched)) { throw 'verified payload missing from dest' }
$check = (Get-FileHash -Algorithm SHA256 -Path $fetched).Hash.ToLowerInvariant()
if ($check -cne $GoodHash) { throw 'verified payload bytes drifted' }
Write-Host 'PASS: verified payload landed with the expected name and bytes'
$script:Passed++

# --- 3) malformed line: hard error naming the line ---------------------------
$bad = New-Fixture 'malformed-line.lock' @"
schema = 1
artifact = broken
kind bootstrapper
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r 'line 3.*malformed' 'malformed line refused with line number'

# --- 4) duplicate key inside one artifact: hard error naming the line -------
$bad = New-Fixture 'dup-key.lock' @"
schema = 1
artifact = duplicated
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = x.bin
size = $GoodSize
sha256 = $GoodHash
sha256 = $GoodHash
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 9.*duplicate key 'sha256'" 'duplicate key refused with line number'

# --- 5) missing sha256: the artifact is refused before any fetch ------------
$bad = New-Fixture 'missing-sha.lock' @"
schema = 1
artifact = unpinned
kind = standalone
arch = x64
url = $PayloadUrl
filename = x.bin
size = $GoodSize
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 2.*missing required key 'sha256'" 'artifact without sha256 refused'
$dest = Join-Path $Fix 'dest-unpinned'
$r = Invoke-Tool @('-LockFile', $bad, '-DestDir', $dest, '-AllowLocalSource')
Assert-Refused $r "missing required key 'sha256'" 'fetch of unpinned artifact refused'
if (Test-Path $dest) { throw 'unpinned fetch created a destination' }
Write-Host 'PASS: unpinned artifact fetched nothing'
$script:Passed++

# --- 6) checksum mismatch: rejected, file deleted, both digests named --------
$wrongHash = '0' * 64
$bad = New-Fixture 'wrong-sha.lock' @"
schema = 1
artifact = tampered
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = tampered.bin
size = $GoodSize
sha256 = $wrongHash
"@
$dest = Join-Path $Fix 'dest-tampered'
$r = Invoke-Tool @('-LockFile', $bad, '-DestDir', $dest, '-AllowLocalSource')
Assert-Refused $r 'sha256 mismatch' 'checksum mismatch rejected'
if ($r.Out -notmatch [regex]::Escape($wrongHash)) {
    throw "mismatch error does not name the expected digest: $($r.Out)"
}
if ($r.Out -notmatch [regex]::Escape($GoodHash)) {
    throw "mismatch error does not name the actual digest: $($r.Out)"
}
foreach ($leftover in @('tampered.bin', 'tampered.bin.download')) {
    if (Test-Path (Join-Path $dest $leftover)) {
        throw "mismatched download survived as $leftover"
    }
}
Write-Host 'PASS: mismatch error names both digests and the download was deleted'
$script:Passed++

# --- 7) size mismatch: rejected and deleted too ------------------------------
$bad = New-Fixture 'wrong-size.lock' @"
schema = 1
artifact = short
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = short.bin
size = 1
sha256 = $GoodHash
"@
$dest = Join-Path $Fix 'dest-short'
$r = Invoke-Tool @('-LockFile', $bad, '-DestDir', $dest, '-AllowLocalSource')
Assert-Refused $r 'size mismatch' 'size mismatch rejected'
foreach ($leftover in @('short.bin', 'short.bin.download')) {
    if (Test-Path (Join-Path $dest $leftover)) {
        throw "size-mismatched download survived as $leftover"
    }
}
Write-Host 'PASS: size mismatch deleted the download'
$script:Passed++

# --- 8) remaining parser refusals over one-line fixtures ---------------------
$bad = New-Fixture 'bad-digest.lock' @"
schema = 1
artifact = shouty
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = x.bin
size = $GoodSize
sha256 = $($GoodHash.ToUpperInvariant())
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r 'not a 64-char lowercase hex digest' 'uppercase digest refused (case-sensitive pin)'

$bad = New-Fixture 'unknown-key.lock' @"
schema = 1
artifact = novel
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = x.bin
size = $GoodSize
sha256 = $GoodHash
mirror = somewhere
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 9.*unknown key 'mirror'" 'unknown key refused with line number'

$bad = New-Fixture 'stray-key.lock' @"
schema = 1
kind = bootstrapper
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 2.*outside an artifact block" 'stray key refused'

$bad = New-Fixture 'no-schema.lock' @"
artifact = early
kind = bootstrapper
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "'schema = 1' must precede" 'artifact before schema refused'

$bad = New-Fixture 'dup-artifact.lock' @"
schema = 1
artifact = twin
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = x.bin
size = $GoodSize
sha256 = $GoodHash
artifact = twin
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 9.*duplicate artifact name 'twin'" 'duplicate artifact name refused'

# --- 9) https-only guard: local url without -AllowLocalSource refused --------
$r = Invoke-Tool @('-Validate', '-LockFile', $valid)
Assert-Refused $r 'url must be https' 'non-https url refused outside fixture mode'

# --- 10) schema-level refusals ------------------------------------------------
$bad = New-Fixture 'schema-two.lock' @"
schema = 2
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "unsupported schema '2'" 'unknown schema version refused'

$bad = New-Fixture 'schema-dup.lock' @"
schema = 1
schema = 1
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 2.*duplicate key 'schema'" 'duplicate schema line refused'

$bad = New-Fixture 'no-schema-at-all.lock' @"
# only comments live here

# and blank lines
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "required key 'schema' is missing" 'comments-only lock refused'

$bad = New-Fixture 'empty-value.lock' @"
schema = 1
artifact = hollow
arch =
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "line 3.*empty value for 'arch'" 'empty value refused with line number'

# --- 11) artifact-field refusals ---------------------------------------------
function New-ArtifactFixture {
    param([string]$Name, [string]$Kind = 'bootstrapper',
        [string]$Arch = 'x64', [string]$Size = '',
        [string]$Filename = 'x.bin', [string]$Url = '',
        [string]$ExtraLines = '')
    if ($Size -eq '') { $Size = "$GoodSize" }
    if ($Url -eq '') { $Url = $PayloadUrl }
    New-Fixture $Name @"
schema = 1
artifact = probe
kind = $Kind
arch = $Arch
url = $Url
filename = $Filename
size = $Size
sha256 = $GoodHash
$ExtraLines
"@
}

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'bad-kind.lock' -Kind 'zip'),
    '-AllowLocalSource')
Assert-Refused $r "unknown kind 'zip'" 'unknown kind refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'bad-arch.lock' -Arch 'mips'),
    '-AllowLocalSource')
Assert-Refused $r "unknown arch 'mips'" 'unknown arch refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'zero-size.lock' -Size '0'),
    '-AllowLocalSource')
Assert-Refused $r 'not a positive byte count' 'size = 0 refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'nonnum-size.lock' -Size 'twelve'),
    '-AllowLocalSource')
Assert-Refused $r 'not a positive byte count' 'non-numeric size refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'fixed-no-version.lock' -Kind 'fixed'),
    '-AllowLocalSource')
Assert-Refused $r 'requires a pinned version' 'fixed runtime without version refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'fixed-bad-version.lock' -Kind 'fixed' `
        -ExtraLines 'version = banana'),
    '-AllowLocalSource')
Assert-Refused $r 'not a 4-part dotted version' 'malformed version refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'traversal-name.lock' `
        -Filename '../evil.exe'),
    '-AllowLocalSource')
Assert-Refused $r 'not a bare safe filename' 'path-traversal filename refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'off-host.lock' `
        -Url 'https://webview2.example.com/installer.exe'))
Assert-Refused $r 'must be https on a microsoft.com host' 'non-microsoft https host refused'

# -AllowLocalSource only admits LOCAL payload paths - it must never
# authorize a fetch from a foreign https host
$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'off-host-fixture.lock' `
        -Url 'https://evil.example/x.exe'),
    '-AllowLocalSource')
Assert-Refused $r 'must be https on a microsoft.com host' 'foreign https host refused even in fixture mode'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'reserved-name.lock' `
        -Filename 'CON'),
    '-AllowLocalSource')
Assert-Refused $r 'reserved Windows device name' 'reserved device filename refused'

$r = Invoke-Tool @('-Validate',
    '-LockFile', (New-ArtifactFixture 'reserved-name-ext.lock' `
        -Filename 'nul.exe'),
    '-AllowLocalSource')
Assert-Refused $r 'reserved Windows device name' 'reserved device filename with extension refused'

$bad = New-Fixture 'dup-filename.lock' @"
schema = 1
artifact = first
kind = bootstrapper
arch = x64
url = $PayloadUrl
filename = Same.bin
size = $GoodSize
sha256 = $GoodHash
artifact = second
kind = standalone
arch = x86
url = $PayloadUrl
filename = same.bin
size = $GoodSize
sha256 = $GoodHash
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r "duplicates artifact 'first'" 'duplicate filename across artifacts refused'

# --- 12) mode exclusivity -----------------------------------------------------
$r = Invoke-Tool @('-Validate', '-Refresh', '-Artifact', 'x',
    '-LockFile', $valid, '-AllowLocalSource')
Assert-Refused $r 'mutually exclusive' '-Validate with -Refresh refused'

$r = Invoke-Tool @('-Refresh', '-LockFile', $valid, '-AllowLocalSource')
Assert-Refused $r '-Refresh requires -Artifact' '-Refresh without -Artifact refused'

# --- 13) -Refresh happy path over the local payload: prints the true
# --- facts and NEVER writes the lock file -------------------------------------
$lockBefore = (Get-FileHash -Algorithm SHA256 -Path $valid).Hash
$dest = Join-Path $Fix 'dest-refresh'
$r = Invoke-Tool @('-Refresh', '-Artifact', 'evergreen-bootstrapper-test',
    '-LockFile', $valid, '-DestDir', $dest, '-AllowLocalSource')
Assert-Pass $r '-Refresh over a local payload succeeds'
if ($r.Out -notmatch "sha256\s*=\s*$([regex]::Escape($GoodHash))") {
    throw "refresh did not print the payload sha256: $($r.Out)"
}
if ($r.Out -notmatch "size\s*=\s*$GoodSize\b") {
    throw "refresh did not print the payload size: $($r.Out)"
}
if ($r.Out -notmatch 'never writes it') {
    throw "refresh did not state the never-writes contract: $($r.Out)"
}
$lockAfter = (Get-FileHash -Algorithm SHA256 -Path $valid).Hash
if ($lockAfter -cne $lockBefore) { throw '-Refresh modified the lock file' }
Write-Host 'PASS: -Refresh printed true facts and left the lock byte-identical'
$script:Passed++

# --- 14) CAP-6b1 authenticode-subject axis over local fixtures ----------------
# parse leg: the optional key is accepted and validated in shape
$subj = New-Fixture 'subject-ok.lock' @"
schema = 1
artifact = signed-probe
kind = bootstrapper
arch = neutral
url = $PayloadUrl
filename = signed.bin
size = $GoodSize
sha256 = $GoodHash
authenticode-subject = CN=PWeb Fixture Signer, O=PWeb, C=US
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $subj, '-AllowLocalSource')
Assert-Pass $r 'authenticode-subject key parses and validates'

$bad = New-Fixture 'subject-garbage.lock' @"
schema = 1
artifact = mispinned
kind = bootstrapper
arch = neutral
url = $PayloadUrl
filename = x.bin
size = $GoodSize
sha256 = $GoodHash
authenticode-subject = not a distinguished name
"@
$r = Invoke-Tool @('-Validate', '-LockFile', $bad, '-AllowLocalSource')
Assert-Refused $r 'must be an X\.500 subject starting with CN=' `
    'malformed authenticode-subject refused'

# unsigned refusal (N8 build side): the payload passes the sha256 pin
# but carries no signature at all - the fetch must refuse it, name the
# status and the expected subject, and delete the download
$dest = Join-Path $Fix 'dest-unsigned'
$r = Invoke-Tool @('-LockFile', $subj, '-DestDir', $dest, '-AllowLocalSource')
Assert-Refused $r 'authenticode refused' 'unsigned payload refused despite sha256 pass'
if ($r.Out -notmatch [regex]::Escape('CN=PWeb Fixture Signer, O=PWeb, C=US')) {
    throw "unsigned refusal does not name the expected subject: $($r.Out)"
}
if ($r.Out -notmatch 'status=NotSigned|status=UnknownError|status=Incompatible') {
    throw "unsigned refusal does not name the signature status: $($r.Out)"
}
foreach ($leftover in @('signed.bin', 'signed.bin.download')) {
    if (Test-Path (Join-Path $dest $leftover)) {
        throw "authenticode-refused download survived as $leftover"
    }
}
Write-Host 'PASS: unsigned refusal named status + subject and deleted the download'
$script:Passed++

# wrong-subject refusal (N8 build side): a REAL validly signed binary
# (the running pwsh host executable, Microsoft-signed) against a pin
# for a different signer - correct hash, wrong identity, refused
$pwshExe = (Get-Command pwsh).Source
$pwshSize = (Get-Item $pwshExe).Length
if ($pwshSize -le 0) {
    # an AppExecLink or store stub would be a zero-byte reparse point:
    # pinning that would silently degrade this leg into a second
    # unsigned test - refuse loudly instead
    throw "pwsh.exe at $pwshExe is zero bytes (AppExecLink stub?) - cannot build the wrong-subject fixture"
}
$pwshHash = (Get-FileHash -Algorithm SHA256 -Path $pwshExe).Hash.ToLowerInvariant()
$pwshUrl = $pwshExe -replace '\\', '/'
$wrongSigner = New-Fixture 'subject-wrong.lock' @"
schema = 1
artifact = wrong-signer
kind = bootstrapper
arch = neutral
url = $pwshUrl
filename = wrongsigner.bin
size = $pwshSize
sha256 = $pwshHash
authenticode-subject = CN=PWeb Fixture Wrong Signer, O=PWeb, C=US
"@
$dest = Join-Path $Fix 'dest-wrong-signer'
$r = Invoke-Tool @('-LockFile', $wrongSigner, '-DestDir', $dest, '-AllowLocalSource')
Assert-Refused $r 'authenticode refused' 'wrong-subject signer refused despite sha256 pass'
if ($r.Out -notmatch [regex]::Escape('CN=PWeb Fixture Wrong Signer, O=PWeb, C=US')) {
    throw "wrong-subject refusal does not name the expected subject: $($r.Out)"
}
# the refusal must prove the payload WAS validly signed (status=Valid,
# only the identity was wrong) - otherwise this leg silently degrades
# into a second unsigned test and the wrong-subject axis goes unproven
if ($r.Out -notmatch 'status=Valid') {
    throw "wrong-subject refusal does not show a Valid signature (leg degraded?): $($r.Out)"
}
foreach ($leftover in @('wrongsigner.bin', 'wrongsigner.bin.download')) {
    if (Test-Path (Join-Path $dest $leftover)) {
        throw "wrong-subject download survived as $leftover"
    }
}
Write-Host 'PASS: wrong-subject refusal named the pinned subject and deleted the download'
$script:Passed++

Write-Host "CAP6B0_WV2LOCK_PASS cases=$($script:Passed)"
