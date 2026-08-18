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
#   (c2) capability_policy (CAP-8A) rewritten to SKIP -> same refusal
#   (c3) capability_policy_digest diverging on one target -> same refusal
#   (e) a count-preserving directive swap in an allowlisted file
#                                          -> divergence sweep refuses via the
#                                             FINGERPRINT branch, restore -> green
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

# --- (c2) CAP-8A: capability_policy rewritten to SKIP ------------------------
# the CAP-8A mustPass field gets its own refusal proof: a suite verdict
# downgraded to SKIP must never aggregate as if the policy were proven.
# The property must EXIST in the downloaded evidence before it can be
# perturbed - a missing property would make the mutation itself error
# and the leg would refuse for the wrong reason.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['capability_policy']) {
    throw 'selftest cap-policy-skip: the evidence carries no capability_policy field - the emitters did not record it'
}
$e.capability_policy = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap-policy-skip'

# --- (c3) CAP-8A: capability_policy_digest diverging on ONE target -----------
# cross-target digest EQUALITY gets its own refusal proof (a divergence
# here means the four targets did not compute the same policy decisions,
# which is exactly what the aggregate exists to refuse)
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['capability_policy_digest']) {
    throw 'selftest cap-digest-divergence: the evidence carries no capability_policy_digest field - the emitters did not record it'
}
$e.capability_policy_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap-digest-divergence'

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

# --- (e) CAP-8A: a count-preserving directive SWAP inside an allowlisted -----
# file must trip the FINGERPRINT branch, by name. The mutation swaps one
# platform directive for a DIFFERENT platform directive (same count, new
# text) in a working-tree copy that is byte-restored in finally - the
# same in-place discipline as leg (d), and the red path of the CAP-8A
# fingerprint upgrade is machine-proven on every hosted run.
$allowFile = 'tools/bundler/pwebbundle.pas'
$allowOrig = [System.IO.File]::ReadAllBytes((Resolve-Path $allowFile))
try {
    $text = [System.IO.File]::ReadAllText((Resolve-Path $allowFile))
    $m = [regex]::Match($text, '\{\$ifdef OSWINDOWS\}')
    if (-not $m.Success) {
        throw "selftest fingerprint-swap: no {`$ifdef OSWINDOWS} found in $allowFile to swap"
    }
    $mutated = $text.Remove($m.Index, $m.Length).Insert($m.Index, '{$ifdef ANDROID}')
    [System.IO.File]::WriteAllText((Resolve-Path $allowFile), $mutated)
    & pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'fingerprint-swap.log')
    if ($LASTEXITCODE -eq 0) {
        throw 'selftest fingerprint-swap: the sweep exited 0 with a count-preserving substitution present'
    }
    if (-not (Select-String -Path (Join-Path $fx 'fingerprint-swap.log') `
            -Pattern 'ALLOWLIST FINGERPRINT CHANGED' -Quiet)) {
        Get-Content (Join-Path $fx 'fingerprint-swap.log') | Write-Host
        throw 'selftest fingerprint-swap: the sweep refused, but not through the ALLOWLIST FINGERPRINT CHANGED branch'
    }
    Write-Host '[CAP-7F] selftest fingerprint-swap: sweep refused as required (fingerprint branch)'
} finally {
    [System.IO.File]::WriteAllBytes((Resolve-Path $allowFile), $allowOrig)
}

# and it must pass again now that leg (d)'s fixture is gone and leg (e)'s
# swap is byte-restored - a selftest that leaves the sweep red has
# sabotaged the job it runs in
& pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'divergence-restored.log')
if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $fx 'divergence-restored.log') | Write-Host
    throw 'selftest: the divergence sweep does not pass after fixture removal + swap restore'
}

Remove-Item -Force -ErrorAction SilentlyContinue $matrix
Write-Host '[CAP-7F] selftest PASS - 5 aggregator refusals + 2 divergence refusals, all on copies or byte-restored'
