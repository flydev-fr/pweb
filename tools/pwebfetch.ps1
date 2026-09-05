# CAP-11A: the one bounded-retry wrapper for every pinned-artifact fetch.
#
# THE MEASURED PROBLEM (ledger C3-15, and the CAP-6b entry it points at). The
# CAP-10C3 closure commit's own run, 33799537793, went red on `windows` at
# `Install FPC (pinned Lazarus 3.4 installer, sha256-verified)` with "The action
# has timed out after 20 minutes", on a DOCS-ONLY commit whose parent was green,
# at a step that runs before any source of this repository is compiled. On run
# 33962919229 the same step took 1002 seconds where it normally takes 52. The
# WebView2 Evergreen fetch occupies the same class. Both were re-run and both
# were green, and both cost a hosted run to learn nothing.
#
# WHAT THIS CHANGES, and what it deliberately does not:
#   - a fetch gets N BOUNDED attempts instead of one unbounded one. No single
#     timeout is longer than before: N x bound fits inside the step budget that
#     already existed, so every ceiling moves DOWN.
#   - every attempt writes a row - attempt, url, bound, elapsed, bytes, outcome -
#     so a failure names its own shape instead of being read out of a log.
#   - the digest is verified AFTER EVERY COMPLETED ATTEMPT, and a mismatch is
#     NEVER retried. That is the whole safety argument: a retry may only ever
#     mask a TRANSPORT fault. A completed transfer whose sha256 disagrees with
#     the lock is upstream drift, and drift is a human decision - "re-ratify a
#     new pin deliberately", as the fetchers have always said. Retrying it would
#     turn a pin into a suggestion.
#   - no URL, no lock value and no existing verification changes. The transport
#     stays each fetcher's own (curl where a SourceForge User-Agent measurement
#     made it curl, Invoke-WebRequest elsewhere): this wraps an attempt, it does
#     not replace one.
#
# Dot-source it, then call Invoke-PWebFetch with a scriptblock that performs ONE
# attempt and throws on failure.

# THE RATIFIED BOUNDS. 180 seconds is measured, not chosen: the healthy fetches
# on hosted runners take 3-21 seconds (Inno Setup 3-4 s, the 210 MB Evergreen
# Standalone 4-7 s, the 290 MB Fixed Runtime 7-17 s, pas2js 15-21 s), so 180 is
# an order of magnitude of headroom over the worst healthy case. Three attempts
# at 180 s is 9 minutes, inside every step budget these fetchers run under - the
# tightest is 10 minutes - so the bound can never be the thing that fires.
$PWEB_FETCH_ATTEMPTS = 3
$PWEB_FETCH_BOUND_SECONDS = 180
$PWEB_FETCH_ROWS = 'build/fetch/rows.txt'

function Write-PWebFetchRow {
    param([string]$Row)
    $dir = Split-Path -Parent $PWEB_FETCH_ROWS
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Add-Content -LiteralPath $PWEB_FETCH_ROWS -Value $Row
    Write-Host $Row
}

function Get-PWebFileSha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

<#
.SYNOPSIS
One pinned artifact, fetched with a bounded retry and a row per attempt.

.PARAMETER Attempt
A scriptblock performing ONE attempt. It receives ($Url, $OutFile, $TimeoutSec)
and must throw on failure. It must not retry internally beyond what its own
transport already does within the bound.

.PARAMETER Sha256
The pinned digest. Verified after EVERY completed attempt; a mismatch throws
immediately and is never retried.

.PARAMETER Shape
Optional: the first bytes an intact artifact begins with (e.g. 'MZ' for a
Windows executable, 'PK' for a zip). A body that does not begin with them is an
interstitial or an error page - a TRANSPORT outcome, retried, and reported by
its own name instead of as a digest mismatch nobody can act on.
#>
function Invoke-PWebFetch {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][scriptblock]$Attempt,
        [string]$Size = '',
        [string]$Shape = '',
        [scriptblock]$Validate = $null,
        [int]$Attempts = $PWEB_FETCH_ATTEMPTS,
        [int]$BoundSeconds = $PWEB_FETCH_BOUND_SECONDS
    )
    $want = $Sha256.ToLowerInvariant()
    for ($i = 1; $i -le $Attempts; $i++) {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -Force -LiteralPath $OutFile }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $outcome = ''
        $bytes = 0
        $got = ''
        try {
            & $Attempt $Url $OutFile $BoundSeconds
            if (-not (Test-Path -LiteralPath $OutFile)) { throw 'the attempt produced no file' }
            $bytes = (Get-Item -LiteralPath $OutFile).Length
            if ($Shape) {
                $expect = [System.Text.Encoding]::ASCII.GetBytes($Shape)
                $head = [byte[]]::new($expect.Length)
                $fs = [IO.File]::OpenRead($OutFile)
                try { $read = $fs.Read($head, 0, $expect.Length) } finally { $fs.Dispose() }
                $okShape = ($read -eq $expect.Length)
                if ($okShape) {
                    for ($k = 0; $k -lt $expect.Length; $k++) {
                        if ($head[$k] -ne $expect[$k]) { $okShape = $false; break }
                    }
                }
                if (-not $okShape) { throw "the body does not begin with '$Shape'" }
            }
            # A body-shaped refusal a prefix cannot express - the macOS disk
            # image has no fixed magic, but an interstitial is HTML and says so.
            # Same class as -Shape: a TRANSPORT outcome, retried, and never
            # confused with drift.
            if ($null -ne $Validate) {
                $verdict = & $Validate $OutFile
                if (-not $verdict) { throw 'the body is not the pinned artifact' }
            }
            # THE DIGEST, EVERY ATTEMPT, BEFORE ANY DECISION TO RETRY
            $got = Get-PWebFileSha256 $OutFile
            if ($Size -and "$bytes" -ne "$Size") {
                $outcome = 'size_mismatch'
                $sw.Stop()
                Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                    "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome sha256=$got url=$Url")
                Remove-Item -Force -LiteralPath $OutFile
                throw ("$Name size is $bytes, the lock pins $Size -- upstream changed; " +
                    'ratify a new pin deliberately (never retried)')
            }
            if ($got -cne $want) {
                $outcome = 'digest_mismatch'
                $sw.Stop()
                Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                    "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome sha256=$got url=$Url")
                Remove-Item -Force -LiteralPath $OutFile
                throw ("$Name sha256 mismatch: expected $want, got $got -- upstream changed; " +
                    'ratify a new pin deliberately (never retried)')
            }
            $outcome = 'ok'
            $sw.Stop()
            Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome sha256=$got url=$Url")
            return
        } catch {
            $sw.Stop()
            $msg = $_.Exception.Message
            if ($outcome -eq 'digest_mismatch' -or $outcome -eq 'size_mismatch') { throw }
            # everything else is TRANSPORT: a timeout, a refused connection, a
            # truncated body, an interstitial. Those are the only outcomes a
            # retry is allowed to answer.
            $outcome = if ($msg -match 'timed out|timeout|TimeoutException|operation was canceled') {
                'transport_timeout'
            } else { 'transport_error' }
            Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome url=$Url msg=" +
                ($msg -replace "`r?`n", ' ' -replace '\s+', ' ').Trim())
            if ($i -eq $Attempts) {
                throw ("$Name could not be fetched in $Attempts bounded attempts of ${BoundSeconds}s: $msg")
            }
        }
    }
}

# The attempt bodies the fetchers use, kept here so the transport each script
# was ratified with stays one line long at its call site.
function New-PWebCurlAttempt {
    param([string[]]$ExtraArgs = @())
    return {
        param($Url, $OutFile, $TimeoutSec)
        $curl = if ($IsWindows) { 'curl.exe' } else { 'curl' }
        & $curl --location --fail --silent --show-error `
            --max-time $TimeoutSec --connect-timeout 30 `
            --output $OutFile -- $Url
        if ($LASTEXITCODE -ne 0) { throw "curl exited $LASTEXITCODE" }
    }.GetNewClosure()
}

function New-PWebWebRequestAttempt {
    return {
        param($Url, $OutFile, $TimeoutSec)
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
    }.GetNewClosure()
}
