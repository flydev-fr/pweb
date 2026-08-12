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
Push-Location ([System.IO.Path]::GetTempPath())  # unrelated CWD
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Write-Host $out
$out | Out-File -Encoding utf8 build/cap6/smoke-release.log

if (($code -eq 0) -and ($out -match [regex]::Escape($marker))) {
    $verdict = 'PASS - release layout booted the UI from app.pwb and returned 42'
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
