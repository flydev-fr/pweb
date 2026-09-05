# CAP-5 real-frontend runtime smokes, same conditional hosted policy as
# CAP-4W/CAP-4: a genuine failure gates (exit 1); only an absent
# WebView2/desktop session (webview_create nil) records SKIP. Local runs
# stay authoritative.
$ErrorActionPreference = 'Stop'

# clear preconditions beat opaque failures on local runs
foreach ($pre in 'build/webview-dist/webview.dll',
                 'build/cap5/bin/reactapp.exe',
                 'build/cap5/bin/pas2jsapp.exe',
                 'examples/04-react/frontend/dist/index.html',
                 'examples/05-pas2js/frontend/dist/index.html') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- build the frontends " +
            '(npm run build / build.ps1), compile the hosts ' +
            '(test/cap5/build_cap5_hosts.ps1) and build webview.dll first')
    }
}
Copy-Item build/webview-dist/webview.dll build/cap5/bin/ -Force
$env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
# CAP-11A (ledger B1-10, first sighted HERE against the Pas2JS smoke): a
# `state=0` non-report has never said which of three things happened. The
# observer watches from outside the process and types a cause afterwards; the
# runs below are byte-unchanged and an observer failure records
# `observer_error` rather than touching a verdict.
. (Join-Path $PSScriptRoot '..\cap11a\smokeobserve.ps1')
$failed = $false
foreach ($case in @(
    @{ name = 'React'; exe = 'build/cap5/bin/reactapp.exe'
       dist = 'examples/04-react/frontend/dist'
       proc = 'reactapp'
       marker = 'reactapp: React -> SDK -> scheduler -> mORMot -> 42 over pweb://app PASS' },
    @{ name = 'Pas2JS'; exe = 'build/cap5/bin/pas2jsapp.exe'
       dist = 'examples/05-pas2js/frontend/dist'
       proc = 'pas2jsapp'
       marker = 'pas2jsapp: Pas2JS -> SDK -> scheduler -> mORMot -> 42 over pweb://app PASS' })) {
    $observer = Start-PWebSmokeObserver -ProcessName $case.proc `
        -OutFile ("build/cap5/smoke-observations-" +
                  $case.name.ToLowerInvariant() + '.txt') `
        -UserDataDir (Join-Path $env:APPDATA ($case.proc + '.exe'))
    $out = & $case.exe $case.dist 2>&1 | Out-String
    $code = $LASTEXITCODE
    try {
        Stop-PWebSmokeObserver -State $observer -Output $out -ExitCode $code `
            -AutocloseMs 8000 | Out-Null
    } catch { Write-Host "[cap11a] observer error: $($_.Exception.Message)" }
    Write-Host $out
    # keep the transcript for failure diagnostics (uploaded by CI)
    $out | Out-File -Encoding utf8 ("build/cap5/smoke-" +
        $case.name.ToLowerInvariant() + '.log')
    if (($code -eq 0) -and ($out -match [regex]::Escape($case.marker))) {
        $verdict = "PASS - $($case.name) real frontend obtained 42 through the SDK"
    }
    elseif ($out -match 'webview_create \(returned nil') {
        $verdict = "SKIP - no usable WebView2 runtime/desktop session on this runner (exit $code)"
    }
    else {
        $verdict = "FAIL - $($case.name) exit $code or missing CAP-5 PASS marker (see log)"
        $failed = $true
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        "### CAP-5 runtime, $($case.name) (conditional hosted gate)`n$verdict" |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    Write-Host "CAP-5 $($case.name) verdict: $verdict"
}
if ($failed) { exit 1 }
