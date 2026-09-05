# CAP-11A: the bounded-retry fetch helper, proven with SEEDED failures and no
# network at all.
#
# A retry policy that is only ever exercised by real outages is a policy nobody
# has tested. These cases inject the attempt body, so the interesting ones - a
# transport failure that then succeeds, a digest that disagrees, an exhausted
# bound - are deterministic and run on every leg in seconds.
#
# THE CASE THAT MATTERS MOST is DIGEST MISMATCH: it must fail on the FIRST
# attempt and must never be retried. A retry there would let a changed upstream
# be smoothed over by chance, which is the one thing a pinned repository must
# never do.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

. (Join-Path $repoRoot 'tools/pwebfetch.ps1')

$work = Join-Path $repoRoot 'build/cap11a/fetchtest'
if (Test-Path -LiteralPath $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null
$PWEB_FETCH_ROWS = Join-Path $work 'rows.txt'

$failures = New-Object System.Collections.Generic.List[string]
function Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS  $What" }
    else { $script:failures.Add("$What ($Detail)"); Write-Host "  FAIL  $What -- $Detail" }
}
function Get-Rows { if (Test-Path -LiteralPath $PWEB_FETCH_ROWS) { @(Get-Content -LiteralPath $PWEB_FETCH_ROWS) } else { @() } }
function Reset-Rows { if (Test-Path -LiteralPath $PWEB_FETCH_ROWS) { Remove-Item -Force -LiteralPath $PWEB_FETCH_ROWS } }

$payload = 'the pinned bytes'
$goodSha = ''
$tmp = Join-Path $work 'reference.bin'
[System.IO.File]::WriteAllText($tmp, $payload, (New-Object System.Text.UTF8Encoding($false)))
$goodSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
$goodSize = (Get-Item -LiteralPath $tmp).Length

# --- F1: a clean fetch is one attempt and one row ---------------------------
Write-Host 'F1: a healthy fetch'
Reset-Rows
$out = Join-Path $work 'f1.bin'
$script:calls = 0
Invoke-PWebFetch -Name 'f1' -Url 'seed://ok' -OutFile $out -Sha256 $goodSha -Size $goodSize -Attempt {
    param($Url, $OutFile, $TimeoutSec)
    $script:calls++
    [System.IO.File]::WriteAllText($OutFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
}
$rows = @(Get-Rows)
Check 'F1 one attempt' ($script:calls -eq 1) "calls=$($script:calls)"
Check 'F1 one row, outcome ok' (($rows.Count -eq 1) -and ($rows[0] -match 'outcome=ok')) ($rows -join ' | ')
Check 'F1 the row carries attempt, bound, elapsed and bytes' `
    (($rows[0] -match 'attempt=1/3') -and ($rows[0] -match 'bound_s=180') -and
     ($rows[0] -match 'elapsed_ms=\d+') -and ($rows[0] -match 'bytes=\d+')) $rows[0]

# --- F2: a transport failure retries WITHIN the bound and then succeeds -----
Write-Host 'F2: a seeded transport failure, then success'
Reset-Rows
$out = Join-Path $work 'f2.bin'
$script:calls = 0
Invoke-PWebFetch -Name 'f2' -Url 'seed://flaky' -OutFile $out -Sha256 $goodSha -Attempt {
    param($Url, $OutFile, $TimeoutSec)
    $script:calls++
    if ($script:calls -eq 1) { throw 'the operation timed out' }
    [System.IO.File]::WriteAllText($OutFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
}
$rows = @(Get-Rows)
Check 'F2 retried once' ($script:calls -eq 2) "calls=$($script:calls)"
Check 'F2 two rows' ($rows.Count -eq 2) "rows=$($rows.Count)"
Check 'F2 the first row is typed transport_timeout' ($rows[0] -match 'outcome=transport_timeout') $rows[0]
Check 'F2 the second row is ok' ($rows[1] -match 'outcome=ok') $rows[1]
Check 'F2 the file survives' (Test-Path -LiteralPath $out) 'absent'

# --- F3: a DIGEST MISMATCH fails on the first attempt and is never retried ---
Write-Host 'F3: a seeded digest mismatch'
Reset-Rows
$out = Join-Path $work 'f3.bin'
$script:calls = 0
$threw = ''
try {
    Invoke-PWebFetch -Name 'f3' -Url 'seed://drifted' -OutFile $out -Sha256 $goodSha -Attempt {
        param($Url, $OutFile, $TimeoutSec)
        $script:calls++
        [System.IO.File]::WriteAllText($OutFile, 'DIFFERENT bytes', (New-Object System.Text.UTF8Encoding($false)))
    }
} catch { $threw = $_.Exception.Message }
$rows = @(Get-Rows)
Check 'F3 refused' ($threw -ne '') 'no refusal'
Check 'F3 NEVER retried' ($script:calls -eq 1) "calls=$($script:calls) -- a retry may only answer a transport fault"
Check 'F3 one row, typed digest_mismatch' (($rows.Count -eq 1) -and ($rows[0] -match 'outcome=digest_mismatch')) ($rows -join ' | ')
Check 'F3 the refusal names the pin, not the network' ($threw -match 'ratify a new pin deliberately') $threw
Check 'F3 the drifted body is discarded' (-not (Test-Path -LiteralPath $out)) 'the mismatching file was kept'

# --- F4: a SIZE mismatch is the same class as a digest mismatch -------------
Write-Host 'F4: a seeded size mismatch'
Reset-Rows
$out = Join-Path $work 'f4.bin'
$script:calls = 0
$threw = ''
try {
    Invoke-PWebFetch -Name 'f4' -Url 'seed://short' -OutFile $out -Sha256 $goodSha -Size 999999 -Attempt {
        param($Url, $OutFile, $TimeoutSec)
        $script:calls++
        [System.IO.File]::WriteAllText($OutFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
    }
} catch { $threw = $_.Exception.Message }
Check 'F4 refused on the first attempt' ($script:calls -eq 1) "calls=$($script:calls)"
Check 'F4 typed size_mismatch' (@(Get-Rows)[0] -match 'outcome=size_mismatch') (@(Get-Rows) -join ' | ')

# --- F5: exhaustion is bounded, and every attempt has a row -----------------
Write-Host 'F5: a transport fault on every attempt'
Reset-Rows
$out = Join-Path $work 'f5.bin'
$script:calls = 0
$threw = ''
try {
    Invoke-PWebFetch -Name 'f5' -Url 'seed://down' -OutFile $out -Sha256 $goodSha -Attempt {
        param($Url, $OutFile, $TimeoutSec)
        $script:calls++
        throw 'connection refused'
    }
} catch { $threw = $_.Exception.Message }
$rows = @(Get-Rows)
Check 'F5 exactly three attempts' ($script:calls -eq 3) "calls=$($script:calls)"
Check 'F5 three rows' ($rows.Count -eq 3) "rows=$($rows.Count)"
Check 'F5 each row is typed transport_error' (@($rows | Where-Object { $_ -match 'outcome=transport_error' }).Count -eq 3) ($rows -join ' | ')
Check 'F5 the refusal names the bound' ($threw -match '3 bounded attempts of 180s') $threw

# --- F6: a shape refusal is transport, not drift ----------------------------
Write-Host 'F6: an interstitial body'
Reset-Rows
$out = Join-Path $work 'f6.bin'
$script:calls = 0
$threw = ''
try {
    Invoke-PWebFetch -Name 'f6' -Url 'seed://html' -OutFile $out -Sha256 $goodSha -Shape 'MZ' -Attempt {
        param($Url, $OutFile, $TimeoutSec)
        $script:calls++
        [System.IO.File]::WriteAllText($OutFile, '<html>your download will start shortly</html>',
            (New-Object System.Text.UTF8Encoding($false)))
    }
} catch { $threw = $_.Exception.Message }
$rows = @(Get-Rows)
Check 'F6 retried to the bound' ($script:calls -eq 3) "calls=$($script:calls)"
Check 'F6 typed as transport, not as drift' (@($rows | Where-Object { $_ -match 'outcome=transport_error' }).Count -eq 3) ($rows -join ' | ')

# --- F7: the bounds themselves are the ratified ones ------------------------
Write-Host 'F7: the ratified bounds'
Check 'F7 three attempts' ($PWEB_FETCH_ATTEMPTS -eq 3) "$PWEB_FETCH_ATTEMPTS"
Check 'F7 a 180-second per-attempt bound' ($PWEB_FETCH_BOUND_SECONDS -eq 180) "$PWEB_FETCH_BOUND_SECONDS"
# 3 x 180s = 9 minutes, and the tightest step budget these fetchers run under is
# 10 minutes: the retry can never be what makes a step time out.
Check 'F7 attempts x bound fits the tightest step budget (10 min)' `
    (($PWEB_FETCH_ATTEMPTS * $PWEB_FETCH_BOUND_SECONDS) -le 600) `
    "$($PWEB_FETCH_ATTEMPTS * $PWEB_FETCH_BOUND_SECONDS)s"

New-Item -ItemType Directory -Force build/cap11a | Out-Null
$out = [ordered]@{
    schema                  = 1
    fetch_retry_max_attempts = $PWEB_FETCH_ATTEMPTS
    fetch_retry_bound_s      = $PWEB_FETCH_BOUND_SECONDS
    cases                    = 7
    failures                 = $failures.Count
}
$json = ($out | ConvertTo-Json -Depth 3)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/fetchtest.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host "FETCH FAIL: $f" }
    Write-Host "CAP-11A FETCH HELPER FAILED ($($failures.Count) case(s))"
    exit 1
}
Write-Host 'CAP11A_FETCH_PASS 7 cases, retries answer transport only'
exit 0
