# CAP-11A: type the leg's collection outcome.
#
# WHY THIS STEP EXISTS, measured rather than imagined. On hosted run 33955241980
# the macos-x64 leg's `CAP-9C1 upload the macOS x64 release record` failed after
# five internal retries against GitHub's own artifact service. It was an ordinary
# blocking step, so about thirty later steps were SKIPPED - the whole CAP-10C1
# and CAP-10D2 gate chains - and the aggregator then had no evidence to compare
# for a target whose gates had never been run at all. One infrastructure timeout
# cost a target its verdict on every capability after it.
#
# THIS STEP NEVER FAILS THE LEG. That is the point, not an oversight:
#   - a leg that passed its gates and could not reach the artifact service is
#     GREEN, with `evidence_uploaded=false` recorded here;
#   - a leg that failed a gate is RED for that gate;
# and those are two different sentences that the aggregate must be able to say
# apart. It refuses to aggregate in both cases - but it names which.
#
# The per-attempt outcomes arrive as PWEB_UP_<class>_<n> environment variables
# fed from `steps.<id>.outcome`, so the row records what the runner observed and
# not what this script assumes. Per-attempt elapsed times are not knowable from
# inside a sibling step; `test/cap11a/check_ci_sequence.ps1` reads them from the
# run's own step timings in the aggregate job, where they are exact.
param(
    [Parameter(Mandatory = $true)][string]$Target
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$MAX_ATTEMPTS = 3
$CLASSES = @('evidence', 'records', 'release', 'dist')
# the classes whose loss costs a verdict; the rest are convenience
$REQUIRED = @('evidence')

$staged = @{}
$stagePath = 'build/cap11a/collection-bytes.json'
if (Test-Path -LiteralPath $stagePath) {
    $s = Get-Content -Raw -LiteralPath $stagePath | ConvertFrom-Json
    foreach ($c in $s.classes.PSObject.Properties.Name) { $staged[$c] = $s.classes.$c }
}

$rows = New-Object System.Collections.Generic.List[object]
$uploaded = $true
$anyInfrastructure = $false

foreach ($cls in $CLASSES) {
    $attempts = 0
    $outcome = 'not_attempted'
    for ($a = 1; $a -le $MAX_ATTEMPTS; $a++) {
        $v = [Environment]::GetEnvironmentVariable("PWEB_UP_${cls}_$a")
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        # a step that never ran reports '' or 'skipped'; only a step that ran
        # contributes an attempt
        if ($v -eq 'skipped') { continue }
        $attempts++
        $outcome = $v
        if ($v -eq 'success') { break }
    }
    $bytes = 0; $files = 0
    if ($staged.ContainsKey($cls)) { $bytes = [int64]$staged[$cls].bytes; $files = [int]$staged[$cls].files }
    $ok = ($outcome -eq 'success') -or ($outcome -eq 'not_attempted' -and $files -eq 0)
    if (-not $ok) {
        $anyInfrastructure = $true
        if ($REQUIRED -contains $cls) { $uploaded = $false }
    }
    $rows.Add([ordered]@{
        class    = $cls
        attempts = $attempts
        max      = $MAX_ATTEMPTS
        files    = $files
        bytes    = $bytes
        outcome  = $outcome
    })
    Write-Host ("[cap11a] upload {0,-10} attempts={1}/{2} files={3,-5} bytes={4,-12} outcome={5}" -f
        $cls, $attempts, $MAX_ATTEMPTS, $files, $bytes, $outcome)
}

# THREE STATES, because two were not enough. `infrastructure` means the
# EVIDENCE never arrived, which is what forfeits a verdict; `partial` means some
# other class did not, which costs a human a download and nobody a gate; `ok`
# means everything landed. Collapsing the middle one into `ok` would have let a
# lost SDK archive go unnamed anywhere.
$status = if (-not $uploaded) { 'infrastructure' }
          elseif ($anyInfrastructure) { 'partial' }
          else { 'ok' }
$out = [ordered]@{
    schema            = 1
    target            = $Target
    upload_model      = 'final_step_bounded_retry'
    upload_max_attempts = $MAX_ATTEMPTS
    evidence_uploaded = $uploaded
    upload_status     = $status
    rows              = $rows
}
New-Item -ItemType Directory -Force build/cap11a | Out-Null
$json = ($out | ConvertTo-Json -Depth 5)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/collection.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @("### CAP-11A collection ($Target): $status")
    foreach ($r in $rows) {
        $lines += "- ``$($r.class)``: attempts $($r.attempts)/$($r.max), $($r.files) files, $($r.bytes) bytes, $($r.outcome)"
    }
    ($lines -join "`n") | Out-File -Append $env:GITHUB_STEP_SUMMARY
}

if (-not $uploaded) {
    # LOUD, and still exit 0. The leg's own conclusion belongs to its gates.
    Write-Host '##[warning]CAP-11A: the leg evidence could not be uploaded after every attempt.'
    Write-Host '##[warning]This is INFRASTRUCTURE, not a gate. The aggregate will name it.'
}
Write-Host "[cap11a] collection typed for ${Target}: upload_status=$status evidence_uploaded=$uploaded"
exit 0
