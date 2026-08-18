# CAP-7F: committed NEGATIVE self-test of the aggregation machinery, run in
# the cap7-aggregate job BEFORE the real aggregation. The aggregator's and
# the divergence sweep's FAILURE branches are the product here - a comparator
# whose red paths were only ever human-verified is a comparator whose red
# paths rot - so every hosted run proves, against copies of the freshly
# downloaded evidence, that:
#
#   (a) one evidence artifact deleted      -> aggregator exits nonzero, no matrix
#   (b) one field perturbed (webview_pin)  -> aggregator exits nonzero, no matrix
#   (c) a PASS field rewritten to SKIP     -> aggregator exits nonzero, no matrix
#   (d) an off-allowlist {$ifdef LINUX} in a temp fixture .pas
#                                          -> divergence sweep exits nonzero,
#                                             and passes again once removed
#
# The mutations happen ONLY on copies under build/cap7f/selftest; the real
# ev/ + inv/ downloads are never touched, and the aggregate's own matrix is
# recreated by the REAL aggregation step that runs after this one.
#
# Usage:
#   pwsh test/cap7f/check_cap7f_selftest.ps1 [-EvidenceRoot ev] [-MacosInventoryRoot inv]
param(
    [string]$EvidenceRoot = 'ev',
    [string]$MacosInventoryRoot = 'inv'
)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
$evSrc = (Resolve-Path $EvidenceRoot).Path
$invSrc = (Resolve-Path $MacosInventoryRoot).Path
$agg = 'test/cap7f/check_cap7f_aggregate.ps1'
$matrix = 'build/cap7f/platform-matrix.json'
New-Item -ItemType Directory -Force build/cap7f | Out-Null
$allowedRoot = (Resolve-Path build/cap7f).Path
$fx = Join-Path $allowedRoot 'selftest'

# The one deletion in this script, guarded: the target must resolve INSIDE
# build/cap7f (never a symlinked elsewhere, never a mis-spliced path) -
# the cap7m_rm_tree discipline, in PowerShell.
function Remove-FixtureTree {
    if (-not (Test-Path $fx)) { return }
    $resolved = (Resolve-Path $fx).Path
    if (-not ($resolved.StartsWith($allowedRoot + [System.IO.Path]::DirectorySeparatorChar))) {
        throw "refusing to delete '$resolved': outside '$allowedRoot'"
    }
    Remove-Item -Recurse -Force $resolved
}

function Reset-Fixture {
    Remove-FixtureTree
    New-Item -ItemType Directory -Force $fx | Out-Null
    Copy-Item $evSrc (Join-Path $fx 'ev') -Recurse
    Copy-Item $invSrc (Join-Path $fx 'inv') -Recurse
}

function Invoke-AggExpectFail([string]$Label) {
    Remove-Item -Force -ErrorAction SilentlyContinue $matrix
    & pwsh -NoProfile -File $agg -EvidenceRoot (Join-Path $fx 'ev') `
        -MacosInventoryRoot (Join-Path $fx 'inv') *> (Join-Path $fx "$Label.log")
    if ($LASTEXITCODE -eq 0) {
        Get-Content (Join-Path $fx "$Label.log") | Write-Host
        throw "selftest ${Label}: the aggregator exited 0 where it must fail"
    }
    if (Test-Path $matrix) {
        throw "selftest ${Label}: a FAILING aggregation wrote a matrix"
    }
    Write-Host "[CAP-7F] selftest ${Label}: aggregator refused as required (nonzero exit, no matrix)"
}

# --- (a) one evidence artifact deleted --------------------------------------
Reset-Fixture
Remove-Item (Join-Path $fx 'ev/linux/evidence.json')
Invoke-AggExpectFail 'absent-artifact'

# --- (b) one field perturbed -------------------------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.webview_pin = 'deadbeef' + $e.webview_pin.Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'field-perturbed'

# --- (c) a PASS field rewritten to SKIP --------------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.host_args = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'skip-promotion'

# --- (d) divergence sweep must refuse an off-allowlist conditional -----------
$fixturePas = 'src/zz_cap7f_selftest_fixture.pas'
Remove-Item -Force -ErrorAction SilentlyContinue $fixturePas
try {
    Set-Content $fixturePas ('unit zz_cap7f_selftest_fixture; ' +
        '{$ifdef LINUX} interface {$endif LINUX} implementation end.')
    & pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'divergence-negative.log')
    if ($LASTEXITCODE -eq 0) {
        throw 'selftest divergence-negative: the sweep exited 0 with an off-allowlist conditional present'
    }
    Write-Host '[CAP-7F] selftest divergence-negative: sweep refused as required'
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $fixturePas
}
# and it must pass again now that the fixture is gone - a selftest that
# leaves the sweep red has sabotaged the job it runs in
& pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'divergence-restored.log')
if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $fx 'divergence-restored.log') | Write-Host
    throw 'selftest: the divergence sweep does not pass after fixture removal'
}

Remove-Item -Force -ErrorAction SilentlyContinue $matrix
Write-Host '[CAP-7F] selftest PASS - 3 aggregator refusals + divergence refusal, all on copies'
