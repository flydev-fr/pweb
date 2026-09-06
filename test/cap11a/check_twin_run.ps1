# CAP-11A: THE MIGRATION PROOF. One commit, two runs, one answer.
#
# The old single-file workflow and the new structure both fire on the twin
# commit, so the same repository at the same SHA is measured twice by two
# different CI structures. This downloads both runs' `cap7f-platform-matrix`
# artifacts and requires the aggregate's AGREEMENT block - the compared fields,
# the absolute pins and the four-target equality list - to be byte-identical
# between them.
#
# WHAT MAY DIFFER, and why that is not a loophole. The matrix's `targets` block
# is per-target OBSERVATIONS: elapsed times, process ids, sample counts, run
# identifiers. Two runs of one commit legitimately disagree about those and
# always have - the aggregate never compares them across targets either. Every
# field that differs is listed, and any difference OUTSIDE the declared
# observation allowlist is a failure: the point of the proof is that the split
# changed nothing anybody was measuring.
#
# It writes `test/cap11a/twin-run.json`, which is the committed record the
# `ci_twin_run_equal` evidence row reads. Until that file exists the row says
# `pending`, which is the honest word for a proof that has not been made yet.
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$OldRunId,
    [Parameter(Mandatory = $true)][string]$NewRunId,
    [string]$WorkDir = 'build/cap11a/twin'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

# Fields whose value is a fact about ONE EXECUTION rather than about the
# repository. Everything else must be identical.
$OBSERVATION_SUFFIXES = @(
    '_elapsed_ms', '_ms', '_pid', '_pids', '_rows', '_samples', '_count_observed'
)
# EVERY NAME BELOW EARNED ITS PLACE BY MEASUREMENT, not by being inconvenient.
# The Linux legs of the twin finished first and were compared field by field:
# 724 fields on each side, no field present on one side only, and FOURTEEN
# differing values - every one of them a fact about one execution. Ten fall out
# of the suffix rules above; these four are named because their suffixes do not
# say what they are:
#   image_dir_hex          the CAP-10E probe directory carries a per-run random
#                          suffix (`cap10e.RnWQTm` vs `cap10e.DXDvsW`), which is
#                          why the aggregate already records it per target and
#                          compares it across none
#   run_descendants_drained  how many descendants existed when the drain ran
#   pd7_moving_writes      writes observed while a generation was moving - a race
#                          count, and the point of the leg is that the RESULT is
#                          stable, not the count
#   sdk_integrity_seconds  a duration that forgot to end in _ms
$OBSERVATION_FIELDS = @(
    'github_run_id', 'run_elapsed_ms', 'pas2js_run_elapsed_ms',
    'fetch_retry_rows', 'u3_drain_rows', 'flake_nonreport_causes',
    'dev5_burst_edits', 'run_drain_passes',
    'image_dir_hex', 'run_descendants_drained', 'pd7_moving_writes',
    'sdk_integrity_seconds',
    # AND FOUR MORE, each with its own mechanism rather than its own
    # inconvenience. The rule for adding a name here is that a MECHANISM makes
    # the value a fact about one execution; "it differed and I want green" is
    # not one, and every entry below names what varies and why.
    #
    #   run_descendants_forced   how many descendants had to be force-killed.
    #                            `run_descendants_drained` and `run_drain_passes`
    #                            are already here for the same reason and
    #                            differed in the same comparison; this is the
    #                            third counter of one teardown observation.
    #
    #   stage_react_release_digest, stage_pas2js_release_digest
    #                            the staged release layout on WINDOWS is not
    #                            byte-reproducible run to run. MEASURED
    #                            INDEPENDENTLY OF THIS SHARD: the same two
    #                            fields differ between runs 33983841968 and
    #                            33988544531, which are BOTH the legacy
    #                            structure and differ only by a docs-only
    #                            commit. So the split is not what moved them.
    #                            The ledger already records the family - the
    #                            archive's byte-determinism is a per-target,
    #                            per-run claim (D1-9, D2-3), and
    #                            `create_help_digest` differs between families
    #                            for a cause nobody has identified (B1-8).
    #
    #   pas2js_compiler_sha256   on macOS arm64 the pinned pas2js is COMPILED
    #                            natively from the pinned FPC revision, because
    #                            upstream ships an x86_64 binary only and
    #                            Rosetta is banned (CAP-7M2). A binary built on
    #                            the runner is not byte-reproducible, which is
    #                            precisely why the aggregate requires this row
    #                            present on every target and compares it on
    #                            none.
    'run_descendants_forced',
    'stage_react_release_digest', 'stage_pas2js_release_digest',
    'pas2js_compiler_sha256'
)
function Test-Observation([string]$Name) {
    if ($OBSERVATION_FIELDS -contains $Name) { return $true }
    foreach ($s in $OBSERVATION_SUFFIXES) { if ($Name.EndsWith($s)) { return $true } }
    return $false
}

$failures = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) { $script:failures.Add($m); Write-Host "TWIN VIOLATION: $m" }

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force $WorkDir | Out-Null

function Get-Matrix([string]$RunId, [string]$Label) {
    $dir = Join-Path $WorkDir $Label
    New-Item -ItemType Directory -Force $dir | Out-Null
    & gh run download $RunId --repo $Repository --name cap7f-platform-matrix --dir $dir 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "could not download the platform matrix of run $RunId ($Label)" }
    $f = Join-Path $dir 'platform-matrix.json'
    if (-not (Test-Path -LiteralPath $f)) {
        $cand = @(Get-ChildItem -Path $dir -Recurse -File -Filter 'platform-matrix.json')
        if ($cand.Count -eq 0) { throw "run $RunId ($Label) uploaded no platform-matrix.json" }
        $f = $cand[0].FullName
    }
    Write-Host "[cap11a] $Label matrix: $f"
    return (Get-Content -Raw -LiteralPath $f | ConvertFrom-Json)
}

$old = Get-Matrix $OldRunId 'old'
$new = Get-Matrix $NewRunId 'new'
# a matrix from a run that predates one of these blocks would throw a
# property-not-found under StrictMode instead of a named refusal
foreach ($pair in @(@('old', $old), @('new', $new))) {
    foreach ($k in 'github_sha', 'agreement', 'targets') {
        if (-not $pair[1].PSObject.Properties[$k]) {
            throw "the $($pair[0]) matrix carries no '$k'; it is not a comparable platform matrix"
        }
    }
}

# --- 1. the same commit, or nothing below means anything --------------------
if ("$($old.github_sha)" -cne "$($new.github_sha)") {
    Violation ("the two runs are not the same commit: old=$($old.github_sha) new=$($new.github_sha) " +
        '-- a twin run compares one commit measured twice, not two commits')
}
Write-Host "[cap11a] both runs are commit $($old.github_sha)"

# --- 2. the AGREEMENT block, byte for byte ----------------------------------
function ConvertTo-Flat([object]$Obj, [string]$Prefix = '') {
    $out = [ordered]@{}
    foreach ($p in $Obj.PSObject.Properties) {
        $k = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        if ($null -ne $p.Value -and $p.Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($e in (ConvertTo-Flat $p.Value $k).GetEnumerator()) { $out[$e.Key] = $e.Value }
        } elseif ($null -ne $p.Value -and $p.Value -is [System.Array]) {
            # ELEMENTS ARE SERIALISED, not stringified. An array of objects
            # joined with `-join` renders every element as its type name, so two
            # different arrays would compare equal and a real difference between
            # the old and new matrices would be invisible to the proof.
            $out[$k] = (@($p.Value | ForEach-Object {
                if ($null -ne $_ -and $_ -is [System.Management.Automation.PSCustomObject]) {
                    ($_ | ConvertTo-Json -Compress -Depth 6)
                } else { "$_" }
            }) -join '|')
        } else {
            $out[$k] = "$($p.Value)"
        }
    }
    return $out
}
$oa = ConvertTo-Flat $old.agreement
$na = ConvertTo-Flat $new.agreement
$agreementFields = 0
foreach ($k in $oa.Keys) {
    $agreementFields++
    if (-not $na.Contains($k)) { Violation "AGREEMENT field '$k' is absent from the new structure's matrix"; continue }
    if ($oa[$k] -cne $na[$k]) {
        Violation "AGREEMENT field '$k' differs: old='$($oa[$k])' new='$($na[$k])'"
    }
}
foreach ($k in $na.Keys) {
    if (-not $oa.Contains($k)) { Violation "AGREEMENT field '$k' appeared only in the new structure's matrix" }
}
Write-Host "[cap11a] $agreementFields compared fields checked"

# --- 3. the per-target blocks, with observations allowed to differ ----------
$ot = ConvertTo-Flat $old.targets
$nt = ConvertTo-Flat $new.targets
$observed = New-Object System.Collections.Generic.List[string]
$targetFields = 0
foreach ($k in $ot.Keys) {
    $targetFields++
    if (-not $nt.Contains($k)) { Violation "per-target field '$k' is absent from the new structure's matrix"; continue }
    if ($ot[$k] -cne $nt[$k]) {
        $leaf = ($k -split '\.')[-1]
        if (Test-Observation $leaf) {
            $observed.Add("$k old='$($ot[$k])' new='$($nt[$k])'")
        } else {
            Violation "per-target field '$k' differs and is NOT typed as an observation: old='$($ot[$k])' new='$($nt[$k])'"
        }
    }
}
foreach ($k in $nt.Keys) {
    if (-not $ot.Contains($k)) { Violation "per-target field '$k' appeared only in the new structure's matrix" }
}
Write-Host "[cap11a] $targetFields per-target fields checked, $($observed.Count) differing observation(s)"
foreach ($o in ($observed | Select-Object -First 20)) { Write-Host "  observation differs: $o" }

# --- the committed record ---------------------------------------------------
$equal = ($failures.Count -eq 0)
$record = [ordered]@{
    schema             = 1
    equal              = $equal
    repository         = $Repository
    commit             = "$($old.github_sha)"
    old_run            = $OldRunId
    old_structure      = '.github/workflows/ci.yml (one file, six jobs)'
    new_run            = $NewRunId
    new_structure      = '.github/workflows/ci-matrix.yml + platform-leg.yml + .github/actions/**'
    agreement_fields   = $agreementFields
    target_fields      = $targetFields
    observations_differing = @($observed)
    violations         = @($failures)
}
# THE RECORD IS ONLY COMMITTED WHEN THE PROOF HOLDS. A `twin-run.json` saying
# `equal: false` in the source tree would be a proof-shaped file that proves the
# opposite; the failing comparison belongs in the log and in the build tree.
$json = ($record | ConvertTo-Json -Depth 6)
$dest = if ($equal) { Join-Path $repoRoot 'test/cap11a/twin-run.json' }
        else { Join-Path $repoRoot 'build/cap11a/twin-run-FAILED.json' }
New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
[System.IO.File]::WriteAllText($dest, ($json -replace "`r`n", "`n") + "`n",
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[cap11a] wrote $dest (equal=$equal)"

if (-not $equal) {
    Write-Host ''
    Write-Host "CAP-11A TWIN RUN NOT EQUAL ($($failures.Count) violation(s))"
    exit 1
}
Write-Host "CAP11A_TWIN_RUN_EQUAL old=$OldRunId new=$NewRunId fields=$agreementFields"
exit 0
