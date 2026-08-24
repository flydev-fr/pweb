# CAP-8B: the real-window privileged-navigation matrix on Windows/WebView2.
#
# Builds test/cap8b/navmatrix.pas (the production asset handler + navigation
# guard + scheduler + CAP-8A policy + external opener, with the opener's one
# injectable seam swapped for a counting fake) and runs it against the
# malicious fixture corpus in a REAL WebView2 window. The driver performs the
# whole B-matrix - external location/window.open/anchor/form/download
# navigations, trusted and untrusted iframes, the CSP subresource probes, the
# capability-authorized external opens and the RPC/navigation race - and the
# host joins the page's observed rows with its native ledger, the guard
# counters and the opener spy.
#
# CONDITIONAL HOSTED POLICY, mirrored from test/cap6/run_cap6_smoke.ps1 and
# test/cap7f/run_host_args_gate.ps1: a genuine failure gates (exit 1); only an
# absent WebView2 runtime / desktop session (webview_create returns nil)
# records SKIP. The SKIP is written honestly into build/cap8b/nav-matrix.json,
# where the CAP-7F aggregator REFUSES it - a runner regression turns the
# aggregate red, never green. Linux and macOS run under a real display and
# never SKIP.
#
# The canonical PASS marker is grepped from the MARKER_PASS constant in
# navmatrix.pas (single source, same discipline as the args gate).
#
# Writes: build/cap8b/nav-matrix.json (overall PASS|FAIL|SKIP) + the run log.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap8b | Out-Null
$work = (Resolve-Path build/cap8b).Path
$json = Join-Path $work 'nav-matrix.json'
$log = Join-Path $work 'nav-matrix-win.log'
Remove-Item -Force -ErrorAction SilentlyContinue $json

foreach ($pre in 'build/webview-dist/webview.dll',
                 'test/cap8b/navmatrix.pas',
                 'test/cap8b/fixture/index.html',
                 'test/cap8b/fixture/assets/driver.js') {
    if (-not (Test-Path $pre)) {
        throw "missing precondition: $pre"
    }
}

# the canonical markers, from the one source
$passConst = @(Select-String -Path test/cap8b/navmatrix.pas `
    -Pattern "^  MARKER_PASS = '([^']+)';$" -CaseSensitive)
if ($passConst.Count -ne 1) {
    throw "expected one MARKER_PASS constant in navmatrix.pas, found $($passConst.Count)"
}
$passMarker = $passConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-8B] canonical pass marker: $passMarker"

# --- build navmatrix.exe (same unit-path set as the CAP-6 release host, but
# WITHOUT the CAP-3U window: navmatrix uses a counting bridge, not the mORMot
# SOA bridge, so it needs no interfaces patch) --------------------------------
New-Item -ItemType Directory -Force build/cap8b/nav-fpc, build/cap8b/nav-bin | Out-Null
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FUbuild/cap8b/nav-fpc -FEbuild/cap8b/nav-bin `
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets `
    -Fusrc/platform/windows `
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net `
    -Fldeps/mormot2/static/x86_64-win64 `
    test/cap8b/navmatrix.pas
if ($LASTEXITCODE -ne 0) { throw 'navmatrix.pas compile FAILED' }
Copy-Item build/webview-dist/webview.dll build/cap8b/nav-bin/ -Force
$env:PWEB_WEBVIEW_DLL = (Resolve-Path build/webview-dist/webview.dll).Path
$exe = (Resolve-Path build/cap8b/nav-bin/navmatrix.exe).Path

# --- run it, from an unrelated CWD (the fixture resolves from the exe, never
# the working directory) ------------------------------------------------------
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Set-Content -Path $log -Value $out
Write-Host $out

# --- verdict, with the exact conditional-SKIP shape the smoke uses -----------
$verdict = 'FAIL'
if ($out -match [regex]::Escape($passMarker)) {
    if ($code -ne 0) {
        throw "the PASS marker was printed but the host exited $code"
    }
    $verdict = 'PASS'
} elseif ($out -match 'webview_create \(returned nil' -or
          $out -match 'WEBVIEW2 RUNTIME UNUSABLE') {
    # a runner with no WebView2/desktop session - honest SKIP, refused by the
    # aggregator, never promoted to PASS
    if ($code -eq 0) {
        throw 'inconsistent: a nil-create marker with a zero exit'
    }
    $verdict = 'SKIP'
    Write-Host '[CAP-8B] no usable WebView2 runtime/desktop session - SKIP'
} else {
    $verdict = 'FAIL'
}

# the host already wrote nav-matrix.json on the PASS/FAIL paths; on SKIP it may
# not have reached that point, so the verdict record is (re)written here as the
# single source the emitter reads
if ($verdict -eq 'SKIP' -or -not (Test-Path $json)) {
    $skip = [ordered]@{
        schema  = 1
        target  = 'windows-x86_64'
        overall = $verdict
    }
    [System.IO.File]::WriteAllText($json,
        ($skip | ConvertTo-Json -Depth 4) + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

if ($verdict -eq 'FAIL') {
    throw "CAP-8B nav-matrix FAILED (exit $code) -- see $log"
}
Write-Host "[CAP-8B] nav-matrix verdict: $verdict"
