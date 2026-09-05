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
#   - a fetch gets N BOUNDED attempts instead of one unbounded one, and N is a
#     TOTAL across every fallback URL rather than N per URL - so the worst case
#     is N x bound however many mirrors a lock names.
#   - every attempt writes a row - attempt, url, bound, elapsed, bytes, outcome -
#     so a failure names its own shape instead of being read out of a log.
#   - the digest is verified AFTER EVERY COMPLETED ATTEMPT, and a mismatch is
#     NEVER retried and never falls back to another mirror. That is the whole
#     safety argument: a retry may only ever answer a TRANSPORT fault. A
#     completed transfer whose sha256 disagrees with the lock is upstream drift,
#     and drift is a human decision - "ratify a new pin deliberately", as the
#     fetchers have always said. Retrying it would turn a pin into a suggestion.
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
# at 180 s is 9 minutes plus 15 seconds of backoff, inside every step budget
# these fetchers run under - the tightest is 10 minutes - so the bound can never
# be the thing that fires.
$PWEB_FETCH_ATTEMPTS = 3
$PWEB_FETCH_BOUND_SECONDS = 180
# A BACKOFF, because the old curl invocations carried `--retry-delay 5` and
# three attempts inside two seconds against a momentarily-down endpoint is not a
# retry policy. 5 s then 10 s: 15 seconds total, which the bound above accounts
# for.
$PWEB_FETCH_BACKOFF_SECONDS = 5

# ABSOLUTE, resolved once against this script's own location. Several fetchers
# and gates `Push-Location` elsewhere, and a relative row file would then land
# where `check_flake_instrumentation.ps1` does not look - which would report
# `fetch_retry_rows = not_applicable` for a leg that fetched all day.
$PWEB_FETCH_ROWS = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'build/fetch/rows.txt'

# The one marker that separates DRIFT from TRANSPORT. Callers test for it to
# decide whether a fallback URL may be tried; matching English prose in three
# places would let a reworded message silently turn drift into a retry.
$PWEB_FETCH_DRIFT_MARKER = 'PWEBFETCH_UPSTREAM_DRIFT'

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

.PARAMETER Url
One address, or several. Attempts rotate through them, and the ATTEMPT COUNT IS
THE TOTAL: three attempts over two mirrors is three transfers, not six.

.PARAMETER Attempt
A scriptblock performing ONE attempt. It receives ($Url, $OutFile, $TimeoutSec)
and must throw on failure.

.PARAMETER Sha256
The pinned digest. Verified after EVERY completed attempt; a mismatch throws
immediately, is never retried and never falls back to another mirror.

.PARAMETER Shape
Optional: the first bytes an intact artifact begins with ('MZ' for a Windows
executable, 'PK' for a zip, 'MSCF' for a cabinet). A body that does not begin
with them is an interstitial or an error page - a TRANSPORT outcome, retried,
and reported by its own name instead of as a digest mismatch nobody can act on.
#>
function Invoke-PWebFetch {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][scriptblock]$Attempt,
        [string]$Size = '',
        [string]$Shape = '',
        [scriptblock]$Validate = $null,
        [int]$Attempts = $PWEB_FETCH_ATTEMPTS,
        [int]$BoundSeconds = $PWEB_FETCH_BOUND_SECONDS
    )
    if ($Attempts -lt 1) { throw "${Name}: attempts must be at least 1, got $Attempts" }
    if ($BoundSeconds -lt 1) { throw "${Name}: the per-attempt bound must be at least 1 second" }
    $urls = @($Url | Where-Object { $_ })
    if ($urls.Count -lt 1) { throw "${Name}: no url to fetch from" }
    $want = $Sha256.ToLowerInvariant()

    for ($i = 1; $i -le $Attempts; $i++) {
        $u = $urls[($i - 1) % $urls.Count]
        if ($i -gt 1) { Start-Sleep -Seconds ($PWEB_FETCH_BACKOFF_SECONDS * ($i - 1)) }
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -Force -LiteralPath $OutFile }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $outcome = ''
        $bytes = 0
        $got = ''
        try {
            & $Attempt $u $OutFile $BoundSeconds
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
                    "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome sha256=$got url=$u")
                Remove-Item -Force -LiteralPath $OutFile
                throw ("$PWEB_FETCH_DRIFT_MARKER $Name size is $bytes, the lock pins $Size -- " +
                    'upstream changed; ratify a new pin deliberately (never retried)')
            }
            if ($got -cne $want) {
                $outcome = 'digest_mismatch'
                $sw.Stop()
                Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                    "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome sha256=$got url=$u")
                Remove-Item -Force -LiteralPath $OutFile
                throw ("$PWEB_FETCH_DRIFT_MARKER $Name sha256 mismatch: expected $want, got $got -- " +
                    'upstream changed; ratify a new pin deliberately (never retried)')
            }
            $outcome = 'ok'
            $sw.Stop()
            Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome sha256=$got url=$u")
            return
        } catch {
            $sw.Stop()
            $msg = $_.Exception.Message
            # drift never retries and never falls back
            if ($msg -like "*$PWEB_FETCH_DRIFT_MARKER*") { throw }
            # everything else is TRANSPORT: a timeout, a refused connection, a
            # truncated body, an interstitial. Those are the only outcomes a
            # retry is allowed to answer. curl reports a timeout as exit 28, and
            # the stall this shard exists to instrument IS a curl timeout - so
            # the code is named here rather than left to match English.
            $outcome = if ($msg -match 'exit 28\b|timed out|timeout|TimeoutException|operation was canceled') {
                'transport_timeout'
            } else { 'transport_error' }
            Write-PWebFetchRow ("fetch name=$Name attempt=$i/$Attempts bound_s=$BoundSeconds " +
                "elapsed_ms=$($sw.ElapsedMilliseconds) bytes=$bytes outcome=$outcome url=$u msg=" +
                ($msg -replace "`r?`n", ' ' -replace '\s+', ' ').Trim())
            if ($i -eq $Attempts) {
                throw ("$Name could not be fetched in $Attempts bounded attempts of ${BoundSeconds}s " +
                    "over $($urls.Count) url(s): $msg")
            }
        }
    }
}

# The attempt bodies the fetchers use, kept here so the transport each script
# was ratified with stays one line long at its call site.
function New-PWebCurlAttempt {
    return {
        param($Url, $OutFile, $TimeoutSec)
        # `$env:OS`, not `$IsWindows`: the latter is undefined under Windows
        # PowerShell 5.1 and would throw under StrictMode.
        $curl = if ($env:OS -eq 'Windows_NT') { 'curl.exe' } else { 'curl' }
        # --max-time is the real bound. curl's own --retry is deliberately NOT
        # used: the retry lives one level up, where it writes a row.
        & $curl --location --fail --silent --show-error `
            --max-time $TimeoutSec --connect-timeout 30 `
            --output $OutFile -- $Url
        if ($LASTEXITCODE -ne 0) {
            $why = switch ($LASTEXITCODE) {
                28 { 'operation timeout' }
                7 { 'failed to connect' }
                18 { 'partial transfer' }
                35 { 'TLS handshake' }
                56 { 'receive error' }
                default { 'transfer error' }
            }
            throw "curl exit $LASTEXITCODE ($why)"
        }
    }.GetNewClosure()
}

function New-PWebWebRequestAttempt {
    return {
        param($Url, $OutFile, $TimeoutSec)
        # A WATCHDOG, because `-TimeoutSec` does not reliably bound a STALLED
        # BODY: PowerShell streams `-OutFile` with the response headers read
        # first, so the parameter governs the headers and a body that stops
        # arriving can hang past it. The four fetchers on this transport include
        # the two largest downloads in the repository, which is exactly where a
        # stall was measured.
        $job = Start-Job -ScriptBlock {
            param($u, $o, $t)
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -TimeoutSec $t
        } -ArgumentList $Url, $OutFile, $TimeoutSec
        try {
            if (-not (Wait-Job -Job $job -Timeout $TimeoutSec)) {
                throw "the transfer timed out after ${TimeoutSec}s"
            }
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            if ($job.State -eq 'Failed') { throw 'the transfer failed' }
        } finally {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()
}
