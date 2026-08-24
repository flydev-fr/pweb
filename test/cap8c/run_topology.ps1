# CAP-8C Phase A: the multi-WebView topology probe on Windows/WebView2.
#
# MEASUREMENT ONLY - this runner gates nothing on what the probe MEASURED,
# only on whether a measurement happened at all. It builds
# test/cap8c/topology.pas (a probe host over the frozen 17-export public ABI,
# no scheduler, no policy, no asset handler - the questions are about the
# ENGINE) and runs it in real WebView2 windows. The probe rewrites
# build/cap8c/topology-windows-x86_64.json after every recorded event, so
# even a probe that crashed mid-experiment leaves a valid partial record
# with a crash_guard naming the dying step - and a crash IS a result here.
#
# Verdict policy, mirrored from the CAP-8B audit runner it replaces in
# spirit:
#   MEASURED - a topology JSON exists (complete or partial): exit 0
#   SKIP     - no WebView2 runtime / desktop session (webview_create nil):
#              an honest SKIP record is written, exit 0 - the summary shows
#              the target as unmeasured, never as measured
#   FAIL     - the probe could not build or produced no JSON: exit 1
#
# Build flags are the run_nav_matrix.ps1 set (same units, same statics) so
# a probe build failure can never be a toolchain drift mystery.
#
# Writes: build/cap8c/topology-windows-x86_64.json + the run log.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap8c | Out-Null
$work = (Resolve-Path build/cap8c).Path
$json = Join-Path $work 'topology-windows-x86_64.json'
$log = Join-Path $work 'topology-win.log'
Remove-Item -Force -ErrorAction SilentlyContinue $json

foreach ($pre in 'build/webview-dist/webview.dll',
                 'test/cap8c/topology.pas') {
    if (-not (Test-Path $pre)) {
        throw "missing precondition: $pre"
    }
}

# the canonical marker, from the one source
$doneConst = @(Select-String -Path test/cap8c/topology.pas `
    -Pattern "^  MARKER_DONE = '([^']+)';$" -CaseSensitive)
if ($doneConst.Count -ne 1) {
    throw "expected one MARKER_DONE constant in topology.pas, found $($doneConst.Count)"
}
$doneMarker = $doneConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-8C] canonical done marker: $doneMarker"

# --- build topology.exe (the nav-matrix unit-path set: the platform adapter
# is linked for its FPU/display preflight initialization only - every
# measurement goes through the 17 frozen exports) -----------------------------
New-Item -ItemType Directory -Force build/cap8c/topo-fpc, build/cap8c/topo-bin | Out-Null
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FUbuild/cap8c/topo-fpc -FEbuild/cap8c/topo-bin `
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets `
    -Fusrc/platform/windows `
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net `
    -Fldeps/mormot2/static/x86_64-win64 `
    test/cap8c/topology.pas
if ($LASTEXITCODE -ne 0) { throw 'topology.pas compile FAILED' }
Copy-Item build/webview-dist/webview.dll build/cap8c/topo-bin/ -Force
$exe = (Resolve-Path build/cap8c/topo-bin/topology.exe).Path

# --- run it, from an unrelated CWD (the output path resolves from the exe,
# never the working directory) ------------------------------------------------
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Set-Content -Path $log -Value $out
Write-Host $out

# --- verdict -----------------------------------------------------------------
if (Test-Path $json) {
    # a measurement happened; complete or partial, the JSON is the record
    if (($out -match [regex]::Escape($doneMarker)) -and ($code -ne 0)) {
        throw "the done marker was printed but the probe exited $code"
    }
    if ($code -ne 0) {
        Write-Host "[CAP-8C] probe exited $code after writing a partial record - a crash is a RESULT"
    }
    Write-Host "[CAP-8C] topology verdict: MEASURED"
    Write-Host "[CAP-8C] --- $json ---"
    Get-Content $json | Write-Host
} elseif ($out -match 'webview_create \(returned nil' -or
          $out -match 'WEBVIEW2 RUNTIME UNUSABLE') {
    # a runner with no WebView2/desktop session - an honest SKIP record the
    # summary renders as "not measured", never as a measurement
    if ($code -eq 0) {
        throw 'inconsistent: a nil-create marker with a zero exit'
    }
    $skip = [ordered]@{
        schema  = 1
        probe   = 'cap8c-topology'
        target  = 'windows-x86_64'
        overall = 'SKIP'
    }
    [System.IO.File]::WriteAllText($json,
        ($skip | ConvertTo-Json -Depth 4) + "`n",
        [System.Text.UTF8Encoding]::new($false))
    Write-Host '[CAP-8C] no usable WebView2 runtime/desktop session - SKIP'
} else {
    throw "CAP-8C topology probe produced no record (exit $code) -- see $log"
}
