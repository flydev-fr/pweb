# CAP-11A: the post-migration amendments, applied as code rather than by hand.
#
# The migration is byte-faithful by construction, which is exactly the problem
# for a body that POINTED AT the file being replaced: preserving it verbatim
# would preserve a broken reference. ONE such body exists - the Windows
# floating-upstream-ref guard, which named `ci.yml` in its own file list; the
# Linux and macOS guards never did. It is declared in
# `test/cap11a/post-migration-amendments.tsv` with the digest it is allowed to
# have, and it is applied HERE so that
# `pwsh test/cap11a/migrate_ci.ps1` reproduces the whole new structure in one
# command - amendments included - and a reviewer can diff the result.
#
# Idempotent: an already-amended file is left alone.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

function Edit-File([string]$Path, [string]$Old, [string]$New, [string]$Note) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "missing amendment target: $Path" }
    # NORMALISED ON BOTH SIDES. This script and its target can be checked out
    # with different line endings - `.gitattributes` says nothing about `.yml` -
    # and a CRLF target would make every `Contains` here answer false.
    $raw = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $Old = $Old -replace "`r`n", "`n"
    $New = $New -replace "`r`n", "`n"
    if ($raw.Contains($New)) { Write-Host "[amend] already applied: $Note"; return }
    if (-not $raw.Contains($Old)) { throw "amendment target text not found in ${Path}: $Note" }
    $raw = $raw.Replace($Old, $New)
    [System.IO.File]::WriteAllText($Path, ($raw -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[amend] applied: $Note"
}

# --- 1. the Windows floating-upstream-ref guard -----------------------------
# It named `.github/workflows/ci.yml`, which WAS the whole workflow. The
# workflow is now one caller, one reusable sequence and one composite action per
# step, so the guard sweeps the TREE - with its own existence floor, because an
# enumeration that silently returned nothing would pass forever.
$old = @'
        $files = 'tools/get-webview.ps1', 'tools/get-mormot.ps1',
                 'tools/build-webview-dll.ps1',
                 'tools/patch-cap4w-webview.ps1',
                 'tools/get-fpc-windows.ps1',
                 '.github/workflows/ci.yml'
'@
$new = @'
        $files = @('tools/get-webview.ps1', 'tools/get-mormot.ps1',
                   'tools/build-webview-dll.ps1',
                   'tools/patch-cap4w-webview.ps1',
                   'tools/get-fpc-windows.ps1',
                   'tools/pwebfetch.ps1')
        # CAP-11A: the guard used to name `.github/workflows/ci.yml`, which was
        # the whole workflow. The workflow is now one caller, one reusable
        # sequence and one composite action per step, so the guard sweeps the
        # TREE - and a tree sweep needs its own existence precondition, because
        # an enumeration that silently returned nothing would pass forever. The
        # floor is deliberately far below the real count (170 files) so it
        # refuses an empty or half-checked-out tree without becoming a second
        # place the step count has to be maintained.
        $ciFiles = @(Get-ChildItem -Path .github -Recurse -File -Include *.yml |
                     ForEach-Object { $_.FullName })
        if ($ciFiles.Count -lt 100) {
          throw "guard: only $($ciFiles.Count) workflow/action files found under .github/"
        }
        $files += $ciFiles
'@
Edit-File '.github/actions/guard-no-floating-upstream-ref-in-fetch-build-path/action.yml' `
    $old $new 'the floating-upstream-ref guard sweeps the workflow tree'

# --- 2. the CAP-4 dual-mode GUI smoke -------------------------------------
# MEASURED DURING THIS SHARD, on the twin run's own control leg: hosted run
# 33996400159 failed here with `FAIL: page/runtime verdict was not successful
# (state=0; 0=no report received)` on `assetsapp[folder]`, and `assetsapp[zip]`
# - the same binary, the same runner, ten seconds later - passed. That is the
# B1-10/B2-16/D1-15 non-report on a FOURTH driver, which the three ledgered
# sightings had not reached. The brief named the CAP-5 and CAP-6 smokes because
# those were the sightings on record; the evidence says this one belongs too,
# and instrumenting three of four would have left the next person meeting it
# with the same silence.
$old4 = @'
        Copy-Item build/webview-dist/webview.dll build/cap4/example/
        $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
'@
$new4 = @'
        Copy-Item build/webview-dist/webview.dll build/cap4/example/
        $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
        # CAP-11A: the non-report observer, wrapped so it can never fail this
        # gate. See test/cap11a/smokeobserve.ps1 for the rule and its limits.
        $obsLoaded = $false
        try { . test/cap11a/smokeobserve.ps1; $obsLoaded = $true }
        catch { Write-Host "[cap11a] observer could not be loaded: $($_.Exception.Message)" }
'@
Edit-File '.github/actions/cap-4-dual-mode-runtime-best-effort-local-gate-authoritative/action.yml' `
    $old4 $new4 'the CAP-4 dual-mode smoke loads the non-report observer'

$old4b = @'
          $out = & build/cap4/example/assetsapp.exe $mode $target 2>&1 | Out-String
          $code = $LASTEXITCODE
'@
$new4b = @'
          $obs = $null
          if ($obsLoaded) {
            try {
              $obs = Start-PWebSmokeObserver -ProcessName 'assetsapp' `
                -OutFile "build/cap4/smoke-observations-$mode.txt" `
                -UserDataDir (Join-Path $env:APPDATA 'assetsapp.exe')
            } catch { Write-Host "[cap11a] observer could not start: $($_.Exception.Message)" }
          }
          $out = & build/cap4/example/assetsapp.exe $mode $target 2>&1 | Out-String
          $code = $LASTEXITCODE
          try {
            if ($obs) {
              Stop-PWebSmokeObserver -State $obs -Output $out -ExitCode $code `
                -AutocloseMs 8000 | Out-Null
            }
          } catch { Write-Host "[cap11a] observer error: $($_.Exception.Message)" }
'@
Edit-File '.github/actions/cap-4-dual-mode-runtime-best-effort-local-gate-authoritative/action.yml' `
    $old4b $new4b 'the CAP-4 dual-mode smoke types a non-report cause'

Write-Host '[amend] done'
