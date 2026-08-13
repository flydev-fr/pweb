# Lock-driven validator/fetcher for pinned Microsoft WebView2 runtime
# artifacts (CAP-6b0; Authenticode second axis added in CAP-6b1). The
# pins live in webview2-runtime.lock at the repo root; integrity rests
# on the locally ratified sha256 recorded there, never on the URL: a
# rotated remote payload fails the fetch loudly and the download is
# deleted. Artifacts without a sha256 are refused by the parser before
# any network activity can happen. An artifact that additionally pins
# an authenticode-subject is verified on that axis too, AFTER the
# sha256 pass: signature status must be Valid and the leaf subject
# must equal the pin exactly (a valid signature never weakens the pin).
#
# Modes:
#   -Validate            parse + validate the lock only (zero network;
#                        an empty lock with zero artifacts is valid)
#   (default)            fetch + verify every pinned artifact (or the
#                        one named by -Artifact) into -DestDir
#   -Refresh -Artifact x explicit manual ratification workflow: fetch
#                        the artifact WITHOUT verification and print
#                        its computed sha256, byte size and
#                        Authenticode subject for a human to ratify by
#                        editing the lock; this script NEVER writes
#                        the lock file
#
# -LockFile / -DestDir / -AllowLocalSource exist for the fixture tests
# in test/cap6b/check_wv2lock.ps1 (local payloads, zero network); a
# production lock URL must be https on microsoft.com.
#
# Usage: pwsh tools/get-webview2-runtime.ps1 [-Validate] [-Refresh]
#          [-Artifact <name>] [-LockFile <path>] [-DestDir <path>]
#          [-AllowLocalSource]

param(
    [switch]$Validate,
    [switch]$Refresh,
    [string]$Artifact = '',
    [string]$LockFile = '',
    [string]$DestDir = '',
    [switch]$AllowLocalSource
)

$ErrorActionPreference = 'Stop'

# every hard error leaves as ONE raw unwrapped stderr line: exact digests
# and line numbers stay greppable in CI logs and fixture assertions
trap {
    [Console]::Error.WriteLine("get-webview2-runtime: $($_.Exception.Message)")
    exit 1
}

# modes are mutually exclusive; invalid combinations fail loudly before
# the lock is even read
if ($Validate -and $Refresh) {
    throw 'invalid mode: -Validate and -Refresh are mutually exclusive'
}
if ($Refresh -and ($Artifact -eq '')) {
    throw '-Refresh requires -Artifact <name>: refreshing is a deliberate, single-artifact act'
}
if ($Validate -and ($Artifact -ne '')) {
    throw 'invalid mode: -Validate takes no -Artifact (it always validates the whole lock)'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($LockFile -eq '') { $LockFile = Join-Path $RepoRoot 'webview2-runtime.lock' }
if ($DestDir -eq '') { $DestDir = Join-Path $RepoRoot 'deps/webview2-runtime' }

$KnownKinds = @('bootstrapper', 'standalone', 'fixed')
$KnownArchs = @('x64', 'x86', 'arm64', 'neutral')
$ArtifactKeys = @('kind', 'arch', 'version', 'url', 'filename', 'size', 'sha256',
    'authenticode-subject')
$RequiredKeys = @('kind', 'arch', 'url', 'filename', 'size', 'sha256')

# culture-invariant case folding: exotic locales (e.g. Turkish dotless
# i) must never change what the allowlists accept
$InvariantIgnoreCase =
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

function Test-MicrosoftUrl {
    param([string]$Url)
    [regex]::IsMatch($Url,
        '^https://([a-z0-9-]+\.)*microsoft\.com(/|$)', $InvariantIgnoreCase)
}

# --- strict lock parser: any malformed input is a hard error with its
# --- line number; nothing is ever silently skipped or defaulted -------------
function Read-Wv2Lock {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "webview2-runtime.lock not found: $Path"
    }
    $lockName = Split-Path -Leaf $Path
    $schema = ''
    $artifacts = @()
    $current = $null
    $lineNo = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNo++
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') {
            throw "$lockName line ${lineNo}: malformed (expected 'key = value'): $line"
        }
        $k, $v = $line -split '=', 2
        $k = $k.Trim()
        $v = $v.Trim()
        if ($k -eq '') {
            throw "$lockName line ${lineNo}: malformed (empty key): $line"
        }
        if ($v -eq '') {
            throw "$lockName line ${lineNo}: malformed (empty value for '$k')"
        }
        if ($k -ceq 'schema') {
            if ($schema -ne '') {
                throw "$lockName line ${lineNo}: duplicate key 'schema'"
            }
            if ($null -ne $current) {
                throw "$lockName line ${lineNo}: 'schema' must precede every artifact"
            }
            if ($v -cne '1') {
                throw "$lockName line ${lineNo}: unsupported schema '$v' (expected 1)"
            }
            $schema = $v
            continue
        }
        if ($k -ceq 'artifact') {
            if ($schema -eq '') {
                throw "$lockName line ${lineNo}: 'schema = 1' must precede every artifact"
            }
            if ($artifacts | Where-Object { $_.name -ceq $v }) {
                throw "$lockName line ${lineNo}: duplicate artifact name '$v'"
            }
            $current = [ordered]@{ name = $v; line = $lineNo }
            $artifacts += $current
            continue
        }
        if ($ArtifactKeys -cnotcontains $k) {
            throw "$lockName line ${lineNo}: unknown key '$k'"
        }
        if ($null -eq $current) {
            throw "$lockName line ${lineNo}: key '$k' outside an artifact block"
        }
        if ($current.Contains($k)) {
            throw "$lockName line ${lineNo}: duplicate key '$k' in artifact '$($current.name)'"
        }
        $current[$k] = $v
    }
    if ($schema -eq '') { throw "${lockName}: required key 'schema' is missing" }
    foreach ($art in $artifacts) {
        foreach ($key in $RequiredKeys) {
            if (-not $art.Contains($key)) {
                throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                    " is missing required key '$key'")
            }
        }
        if ($KnownKinds -cnotcontains $art.kind) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " has unknown kind '$($art.kind)'")
        }
        if ($KnownArchs -cnotcontains $art.arch) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " has unknown arch '$($art.arch)'")
        }
        if ($art.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " sha256 '$($art.sha256)' is not a 64-char lowercase hex digest")
        }
        if ($art.size -notmatch '^[1-9][0-9]*$') {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " size '$($art.size)' is not a positive byte count")
        }
        if ($art.kind -ceq 'fixed' -and -not $art.Contains('version')) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " is a fixed runtime and requires a pinned version")
        }
        if ($art.Contains('version') -and
            ($art.version -notmatch '^[0-9]{1,9}(\.[0-9]{1,9}){3}$')) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " version '$($art.version)' is not a 4-part dotted version")
        }
        # optional CAP-6b1 second verification axis: when pinned, the
        # subject must look like an X.500 DN starting at the leaf CN -
        # a free-form value could never match a real signer and would
        # only hide a mis-edit of the lock
        if ($art.Contains('authenticode-subject') -and
            ($art.'authenticode-subject' -cnotmatch '^CN=\S')) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " authenticode-subject '$($art.'authenticode-subject')' must be" +
                " an X.500 subject starting with CN=")
        }
        # a hostile lock line must never be able to write outside
        # DestDir: bare conservative filenames only
        if ($art.filename -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$') {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " filename '$($art.filename)' is not a bare safe filename")
        }
        # Windows reserved device names survive the charset check but
        # can hijack file creation: refuse them by base name
        if ([regex]::IsMatch(($art.filename -split '\.', 2)[0],
            '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', $InvariantIgnoreCase)) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " filename '$($art.filename)' is a reserved Windows device name")
        }
        # every https URL must live on a Microsoft host - fixture mode
        # included: -AllowLocalSource only additionally admits LOCAL
        # (non-https) payload paths, it never authorizes a foreign
        # https host, so no fixture lock can trigger a real fetch
        if (-not (Test-MicrosoftUrl $art.url)) {
            if (($art.url -match '^https://') -or -not $AllowLocalSource) {
                throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                    " url must be https on a microsoft.com host")
            }
        }
    }
    $seenNames = @{}
    foreach ($art in $artifacts) {
        $fn = $art.filename.ToLowerInvariant()
        if ($seenNames.Contains($fn)) {
            throw ("$lockName line $($art.line): artifact '$($art.name)'" +
                " filename '$($art.filename)' duplicates artifact" +
                " '$($seenNames[$fn])'")
        }
        $seenNames[$fn] = $art.name
    }
    [pscustomobject]@{ Schema = $schema; Artifacts = $artifacts }
}

# --- transfer one artifact payload to a temp file (https or, for the
# --- fixture tests only, a local path) ---------------------------------------
function Copy-Wv2Payload {
    param($Art, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -Force -LiteralPath $OutFile }
    if ($Art.url -match '^https://') {
        Invoke-WebRequest -Uri $Art.url -OutFile $OutFile -UseBasicParsing `
            -TimeoutSec 300
    }
    elseif ($AllowLocalSource) {
        if (-not (Test-Path -LiteralPath $Art.url)) {
            throw "artifact '$($Art.name)': local source not found: $($Art.url)"
        }
        Copy-Item -LiteralPath $Art.url -Destination $OutFile
    }
    else {
        throw "artifact '$($Art.name)': url is not https: $($Art.url)"
    }
}

# --- fetch + verify: sha256 first (BEFORE any use), then size; any
# --- mismatch deletes the download and fails naming both values --------------
function Get-Wv2Artifact {
    param($Art, [string]$Dir)
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $final = Join-Path $Dir $Art.filename
    $tmp = "$final.download"
    try {
        Copy-Wv2Payload $Art $tmp
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
        if ($actual -cne $Art.sha256) {
            throw ("artifact '$($Art.name)' sha256 mismatch: expected $($Art.sha256)," +
                " got $actual -- download deleted; upstream changed, ratify a new" +
                " pin deliberately (-Refresh)")
        }
        $bytes = (Get-Item -LiteralPath $tmp).Length
        if ($bytes -ne [long]$Art.size) {
            throw ("artifact '$($Art.name)' size mismatch: expected $($Art.size)" +
                " bytes, got $bytes -- download deleted")
        }
        # CAP-6b1 second axis, checked AFTER the sha256 pass: a pinned
        # authenticode-subject additionally requires an embedded
        # signature with status Valid and this exact leaf subject
        # (case-sensitive ordinal). A valid signature can never weaken
        # the byte-exact sha256 pin above - both axes must pass.
        $axes = 'sha256 OK'
        if ($Art.Contains('authenticode-subject')) {
            $sig = Get-AuthenticodeSignature -FilePath $tmp
            $subject = 'unsigned'
            if ($null -ne $sig.SignerCertificate) {
                $subject = $sig.SignerCertificate.Subject
            }
            if (("$($sig.Status)" -cne 'Valid') -or
                ($subject -cne $Art.'authenticode-subject')) {
                throw ("artifact '$($Art.name)' authenticode refused:" +
                    " status=$($sig.Status), subject=$subject -- expected status" +
                    " Valid with leaf subject exactly" +
                    " $($Art.'authenticode-subject') -- download deleted")
            }
            $axes = 'sha256 + authenticode OK'
        }
        if (Test-Path -LiteralPath $final) { Remove-Item -Force -LiteralPath $final }
        Move-Item -LiteralPath $tmp -Destination $final
        Write-Host "artifact '$($Art.name)' verified: $final ($bytes bytes, $axes)"
    }
    catch {
        # no partial or unverified *.download bytes ever survive ANY
        # failure path (transfer abort, hash mismatch, size mismatch)
        if (Test-Path -LiteralPath $tmp) { Remove-Item -Force -LiteralPath $tmp }
        throw
    }
}

$lock = Read-Wv2Lock $LockFile

if ($Validate) {
    Write-Host ("webview2-runtime lock OK: schema $($lock.Schema)," +
        " $($lock.Artifacts.Count) artifact(s) pinned")
    exit 0
}

$selected = $lock.Artifacts
if ($Artifact -ne '') {
    $selected = @($lock.Artifacts | Where-Object { $_.name -ceq $Artifact })
    if ($selected.Count -eq 0) {
        throw "no artifact named '$Artifact' in $LockFile"
    }
}

if ($Refresh) {
    foreach ($art in $selected) {
        $refreshDir = Join-Path $DestDir 'refresh'
        New-Item -ItemType Directory -Force $refreshDir | Out-Null
        $candidate = Join-Path $refreshDir "$($art.filename).refresh"
        try {
            Copy-Wv2Payload $art $candidate
        }
        catch {
            if (Test-Path -LiteralPath $candidate) {
                Remove-Item -Force -LiteralPath $candidate
            }
            throw
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash.ToLowerInvariant()
        $bytes = (Get-Item -LiteralPath $candidate).Length
        $sig = Get-AuthenticodeSignature -FilePath $candidate
        $subject = 'unsigned'
        if ($null -ne $sig.SignerCertificate) {
            $subject = $sig.SignerCertificate.Subject
        }
        Write-Host "refresh facts for artifact '$($art.name)' (NOT verified, NOT ratified):"
        Write-Host "  url          = $($art.url)"
        Write-Host "  filename     = $($art.filename)"
        Write-Host "  size         = $bytes"
        Write-Host "  sha256       = $hash"
        Write-Host "  authenticode = $($sig.Status); subject = $subject"
        Write-Host "  payload kept for inspection at $candidate"
        Write-Host ('ratify by editing webview2-runtime.lock manually;' +
            ' this script never writes it.')
    }
    exit 0
}

if ($selected.Count -eq 0) {
    Write-Host 'webview2-runtime lock pins no artifact yet: nothing to fetch'
    exit 0
}
foreach ($art in $selected) {
    Get-Wv2Artifact $art $DestDir
}
