# CAP-11A: the post-migration amendments, applied as code rather than by hand.
#
# The migration is byte-faithful by construction, which is exactly the problem
# for a body that POINTED AT the file being replaced: preserving it verbatim
# would preserve a broken reference. Two such bodies exist, they are declared in
# `test/cap11a/post-migration-amendments.tsv` with the digest each is allowed to
# have, and they are applied HERE so that
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
    $raw = [System.IO.File]::ReadAllText($Path)
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

Write-Host '[amend] done'
