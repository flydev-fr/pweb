# CAP-6 release runtime smoke, same conditional hosted policy as
# CAP-4/CAP-5: a genuine failure gates (exit 1); only an absent
# WebView2/desktop session (webview_create nil) records SKIP. Local
# runs stay authoritative. The host runs from an UNRELATED CWD with
# nothing but exe + app.pwb + dll in its directory - the UI must boot
# solely from the bundle over pweb://app.
$ErrorActionPreference = 'Stop'

foreach ($pre in 'build/cap6/release/releaseapp.exe',
                 'build/cap6/release/app.pwb',
                 'build/cap6/release/webview.dll') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- run " +
            'test/cap6/run_cap6_gates.ps1 first (it assembles the release dir)')
    }
}

$exe = (Resolve-Path build/cap6/release/releaseapp.exe).Path
$marker = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
$env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
# CAP-11A (ledger B1-10, B2-16, D1-15): a `state=0` non-report has never said
# WHICH of three things happened. The observer watches from outside the process
# and types a cause afterwards; the run below is byte-unchanged, and an observer
# that fails records `observer_error` instead of touching this gate's verdict.
. (Join-Path $PSScriptRoot '..\cap11a\smokeobserve.ps1')
$observer = Start-PWebSmokeObserver -ProcessName 'releaseapp' `
    -OutFile 'build/cap6/smoke-observations.txt' `
    -UserDataDir (Join-Path $env:APPDATA 'releaseapp.exe')
Push-Location ([System.IO.Path]::GetTempPath())  # unrelated CWD
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
$observed = $null
try {
    $observed = Stop-PWebSmokeObserver -State $observer -Output $out -ExitCode $code `
        -AutocloseMs 8000
} catch { Write-Host "[cap11a] observer error: $($_.Exception.Message)" }
Write-Host $out
$out | Out-File -Encoding utf8 build/cap6/smoke-release.log

if (($code -eq 0) -and ($out -match [regex]::Escape($marker))) {
    $verdict = 'PASS - release layout booted the UI from app.pwb and returned 42'
    $failed = $false
}
elseif (($out -match 'WEBVIEW2 RUNTIME UNUSABLE') -and ($code -ne 0)) {
    # CAP-6b1 defensive pre-webview_create check: the app now reports
    # an absent/too-old/undetectable runtime with its own diagnosable
    # marker AND a nonzero exit BEFORE webview_create can return nil.
    # The marker with exit 0 is an inconsistent state and falls through
    # to FAIL below - a refusal that does not refuse is a defect.
    $verdict = "SKIP - CAP-6b1 defensive check reported the runtime unusable on this runner (exit $code)"
    $failed = $false
}
elseif ($out -match 'webview_create \(returned nil') {
    $verdict = "SKIP - no usable WebView2 runtime/desktop session on this runner (exit $code)"
    $failed = $false
}
else {
    $verdict = "FAIL - exit $code or missing CAP-6 PASS marker (see log)"
    $failed = $true
}
if ($env:GITHUB_STEP_SUMMARY) {
    "### CAP-6 release runtime (conditional hosted gate)`n$verdict" |
        Out-File -Append $env:GITHUB_STEP_SUMMARY
}
Write-Host "CAP-6 release verdict: $verdict"
if ($failed) { exit 1 }
