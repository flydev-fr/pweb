# CAP-8C: the multi-principal integration harness on Windows/WebView2.
#
# Builds test/cap8c/multiprincipal.pas (the UNCHANGED production scheduler +
# CAP-8A policy + CAP-8B guard/opener + the real mORMot SOA bridge for the
# Main path, with the opener's one injectable seam swapped for a counting
# fake) and runs it. Two legs: a headless NATIVE leg that drives the whole
# multi-principal decision matrix over three registered sources (main, login,
# plugin) and writes the canonical build/cap8c/security-corpus.txt digest
# source, then a GUI leg of two simultaneously live real WebViews proving the
# same policy differentiates two real privileged principals under the full
# CAP-8B guard, with the content-swap and the injected-opener evidence.
#
# The real mORMot SOA bridge means this host, exactly like the CAP-6 release
# host, compiles INSIDE the CAP-3U window (patch-cap3u.ps1 apply -> compile
# with -Xm -dPWEB_CALLMETHOD_UNWIND_PROBE -> restore + verify pristine).
#
# CONDITIONAL HOSTED POLICY, mirrored from test/cap8b/run_nav_matrix.ps1: a
# genuine failure gates (exit 1); only an absent WebView2 runtime / desktop
# session (the GUI leg's webview_create returns nil) records SKIP - the
# native leg still ran and its digest is still written. The SKIP is written
# honestly into build/cap8c/multiprincipal-windows-x86_64.json, where the
# CAP-7F aggregator REFUSES it. Linux and macOS run under a real display and
# never SKIP.
#
# Writes: build/cap8c/multiprincipal-windows-x86_64.json (PASS|FAIL|SKIP),
#         build/cap8c/security-corpus.txt (the digest source) + the run log.
#
# Environment: PWEB_MULTIPRINCIPAL_TIMEOUT_MS overrides the harness's GUI
# watchdog bound (default 45000, capped at 120000) for slow local machines.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap8c | Out-Null
$work = (Resolve-Path build/cap8c).Path
$json = Join-Path $work 'multiprincipal-windows-x86_64.json'
$corpus = Join-Path $work 'security-corpus.txt'
$log = Join-Path $work 'multiprincipal-win.log'
# every output deleted up front: an aborted run must never leave a previous
# run's evidence lying where the emitter or an upload could mistake it
Remove-Item -Force -ErrorAction SilentlyContinue $json, $corpus, $log

foreach ($pre in 'build/webview-dist/webview.dll',
                 'test/cap8c/multiprincipal.pas',
                 'test/cap8c/fixture/main.html',
                 'test/cap8c/fixture/login.html',
                 'test/cap8c/fixture/assets/driver.js',
                 'tools/patch-cap3u.ps1') {
    if (-not (Test-Path $pre)) {
        throw "missing precondition: $pre"
    }
}

# the canonical markers, from the one source
$passConst = @(Select-String -Path test/cap8c/multiprincipal.pas `
    -Pattern "^  MARKER_PASS = '([^']+)';$" -CaseSensitive)
if ($passConst.Count -ne 1) {
    throw "expected one MARKER_PASS constant in multiprincipal.pas, found $($passConst.Count)"
}
$passMarker = $passConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-8C] canonical pass marker: $passMarker"

# --- build multiprincipal.exe INSIDE the CAP-3U window (the release-host
# unit-path set: this harness drives the real mORMot SOA bridge) -------------
New-Item -ItemType Directory -Force build/cap8c/mp-fpc, build/cap8c/mp-bin | Out-Null
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-8C CAP-3U re-apply failed' }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm -dPWEB_CALLMETHOD_UNWIND_PROBE `
        -FUbuild/cap8c/mp-fpc -FEbuild/cap8c/mp-bin `
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets `
        -Fusrc/platform/windows `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
        -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa `
        -Fldeps/mormot2/static/x86_64-win64 `
        test/cap8c/multiprincipal.pas
    if ($LASTEXITCODE -ne 0) { throw 'multiprincipal.pas compile FAILED' }
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-8C CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-8C restore' }

Copy-Item build/webview-dist/webview.dll build/cap8c/mp-bin/ -Force
$env:PWEB_WEBVIEW_DLL = (Resolve-Path build/webview-dist/webview.dll).Path
$exe = (Resolve-Path build/cap8c/mp-bin/multiprincipal.exe).Path

# --- run it, from an unrelated CWD (fixture + output resolve from the exe) ---
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Set-Content -Path $log -Value $out
Write-Host $out

# --- verdict, with the exact conditional-SKIP shape the nav-matrix uses ------
$verdict = 'FAIL'
if ($out -match [regex]::Escape($passMarker)) {
    if ($code -ne 0) { throw "the PASS marker was printed but the host exited $code" }
    $verdict = 'PASS'
} elseif ($code -eq 2 -and (
          $out -match 'GUI leg SKIP' -or $out -match 'GUI SKIP')) {
    # exit 2 = the native leg passed but the GUI leg had no WebView2/desktop
    # session; honest SKIP, refused by the aggregator, never promoted to PASS
    $verdict = 'SKIP'
    Write-Host '[CAP-8C] no usable WebView2 runtime/desktop session - GUI leg SKIP'
} else {
    $verdict = 'FAIL'
}

# the host writes the JSON on every non-crash path; only synthesize on SKIP if
# it somehow did not reach that write
if ($verdict -eq 'SKIP' -and -not (Test-Path $json)) {
    $skip = [ordered]@{
        schema  = 1
        target  = 'windows-x86_64'
        overall = 'SKIP'
    }
    [System.IO.File]::WriteAllText($json,
        ($skip | ConvertTo-Json -Depth 4) + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path $corpus)) {
    throw "CAP-8C: the security-corpus digest source was not written -- see $log"
}
if ($verdict -eq 'FAIL') {
    throw "CAP-8C multiprincipal FAILED (exit $code) -- see $log"
}
Write-Host "[CAP-8C] multiprincipal verdict: $verdict"
