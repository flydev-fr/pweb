# CAP-11A: THE AGGREGATE'S PREMISE, MEASURED FROM THE RUN ITSELF.
#
# `test/cap7f/check_cap7f_aggregate.ps1` compares four targets field by field.
# That comparison only means anything if the four targets ran the SAME step
# sequence, and until CAP-11A that was true by hand-copying: the legacy ci.yml
# declared 155 / 92 / 99 / 99 steps across four jobs, and nothing would have gone
# red if a shard had added a gate to three of them.
#
# This reads the run's OWN jobs through the API and refuses on either of two
# disagreements:
#
#   1. SEQUENCE. The four legs' step-name lists, in order, must be identical.
#      Runner-injected entries (`Set up job`, `Post <name>`, `Complete job`) are
#      dropped - they are the runner's, not ours, and their count depends on how
#      many `uses:` steps actually ran.
#
#   2. APPLICABILITY. Each step's OBSERVED run-set - the legs where it did not
#      report `skipped` - must equal the set declared in
#      `test/cap11a/step-applicability.tsv`. This is the half that keeps the gate
#      from being vacuous: with one sequence file, name equality is true by
#      construction, but an `if:` that silently stopped matching would let a
#      Windows-only gate skip on Windows too and nothing else would notice.
#
# It also extracts, per leg, what the collection block did - because an upload
# failure is exactly the case where the leg's own record cannot reach the
# aggregator, and the run's step outcomes are the one channel it cannot take
# away. `build/cap11a/sequence.json` is what the aggregator then reads to tell
# "leg green, evidence not uploaded" from "leg red".
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$JobsJson = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$TARGETS = @('windows', 'linux', 'macos-x64', 'macos-arm64')
$failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$m) { $script:failures.Add($m); Write-Host "SEQUENCE FAIL: $m" }

# --- the run's jobs ---------------------------------------------------------
if ($JobsJson) {
    if (-not (Test-Path -LiteralPath $JobsJson)) { throw "missing -JobsJson file: $JobsJson" }
    $payload = Get-Content -Raw -LiteralPath $JobsJson | ConvertFrom-Json
} else {
    $raw = & gh api "repos/$Repository/actions/runs/$RunId/jobs?per_page=100" --paginate 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh api failed reading the run's jobs: $raw" }
    # --paginate concatenates one JSON document per page
    $docs = @(($raw -join "`n") -split '(?<=\})\s*(?=\{"total_count")' | Where-Object { $_.Trim() })
    $jobs = @()
    foreach ($d in $docs) { $jobs += @(($d | ConvertFrom-Json).jobs) }
    $payload = [pscustomobject]@{ jobs = $jobs }
}
$jobs = @($payload.jobs)
if ($jobs.Count -eq 0) { throw 'the run reported no jobs' }
Write-Host "[cap11a] run $RunId reports $($jobs.Count) job(s)"

# A reusable workflow called from a matrix produces jobs named
# "<caller job> (<target>) / <called job>", and the called job is named for its
# target. Match on the LAST path segment, exactly: `macos-x64` and `macos-arm64`
# are different tokens and a prefix match would confuse them.
function Get-LegJob([string]$Target) {
    $hit = @($jobs | Where-Object {
        $seg = ($_.name -split '/')[-1].Trim()
        $seg -eq $Target
    })
    if ($hit.Count -eq 1) { return $hit[0] }
    if ($hit.Count -eq 0) { return $null }
    # a re-run inside the same run yields several attempts; take the last
    return @($hit | Sort-Object { [int]$_.id })[-1]
}

# --- extract the authored sequences ----------------------------------------
function Get-AuthoredSteps($Job) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($Job.steps | Sort-Object { [int]$_.number })) {
        $n = [string]$s.name
        if ($n -eq 'Set up job' -or $n -eq 'Complete job') { continue }
        if ($n -like 'Post *') { continue }
        $out.Add([pscustomobject]@{
            Name       = $n
            Conclusion = [string]$s.conclusion
            Started    = $s.started_at
            Completed  = $s.completed_at
        })
    }
    return $out
}

$legs = [ordered]@{}
foreach ($t in $TARGETS) {
    $j = Get-LegJob $t
    if (-not $j) { Fail "no job found for target '$t' in run $RunId"; continue }
    $legs[$t] = [pscustomobject]@{
        Job        = $j
        Conclusion = [string]$j.conclusion
        Steps      = Get-AuthoredSteps $j
    }
    Write-Host ("[cap11a] {0,-12} job={1} conclusion={2} authored_steps={3}" -f
        $t, $j.id, $j.conclusion, $legs[$t].Steps.Count)
}
if ($failures.Count -gt 0) {
    Write-Host 'SEQUENCE REFUSED: a target has no job; nothing below can be measured'
    exit 1
}

# --- 1. the four sequences are identical ------------------------------------
$names = @{}
foreach ($t in $TARGETS) { $names[$t] = @($legs[$t].Steps | ForEach-Object { $_.Name }) }
$ref = $names[$TARGETS[0]]
foreach ($t in $TARGETS[1..3]) {
    $a = $ref; $b = $names[$t]
    if ($a.Count -ne $b.Count) {
        Fail "step COUNT differs: $($TARGETS[0])=$($a.Count) vs $t=$($b.Count)"
        $onlyA = @($a | Where-Object { $b -notcontains $_ })
        $onlyB = @($b | Where-Object { $a -notcontains $_ })
        if ($onlyA) { Write-Host "  only on $($TARGETS[0]): $(($onlyA | Select-Object -First 8) -join ' | ')" }
        if ($onlyB) { Write-Host "  only on ${t}: $(($onlyB | Select-Object -First 8) -join ' | ')" }
        continue
    }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -cne $b[$i]) {
            Fail "step $($i + 1) differs: $($TARGETS[0])='$($a[$i])' vs $t='$($b[$i])'"
            break
        }
    }
}
$seqDigest = ''
if ($failures.Count -eq 0) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($ref -join "`n"))
        $seqDigest = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    Write-Host "[cap11a] four identical sequences of $($ref.Count) steps, digest $seqDigest"
}

# --- 2. observed applicability equals the declared table --------------------
$tsv = Join-Path $PSScriptRoot 'step-applicability.tsv'
if (-not (Test-Path -LiteralPath $tsv)) { throw "missing $tsv -- the declared per-step platform applicability" }
$declared = [ordered]@{}
$rows = @(Get-Content -LiteralPath $tsv | Select-Object -Skip 1)
foreach ($r in $rows) {
    if (-not $r.Trim()) { continue }
    $p = $r -split "`t"
    if ($p.Count -lt 3) { continue }
    $declared[$p[1]] = @($p[2] -split ',')
}
Write-Host "[cap11a] declared applicability for $($declared.Count) steps"

$observed = [ordered]@{}
foreach ($t in $TARGETS) {
    foreach ($s in $legs[$t].Steps) {
        if (-not $observed.Contains($s.Name)) { $observed[$s.Name] = New-Object System.Collections.Generic.List[string] }
        if ($s.Conclusion -ne 'skipped') { $observed[$s.Name].Add($t) }
    }
}
# A leg that went RED stops early, so every step after the failure reports
# `skipped` for a reason that has nothing to do with applicability. Only a
# leg with NO FAILED STEP can be held to the declared set.
#
# The test cannot be "did the last step run": the collection block is
# `if: always()`, so its steps run on a red leg too and the last step's
# conclusion says nothing about whether the gates in front of it did.
$complete = @($TARGETS | Where-Object {
    @($legs[$_].Steps | Where-Object { $_.Conclusion -eq 'failure' }).Count -eq 0 })

Write-Host "[cap11a] legs held to the declared applicability: [$($complete -join ',')]"

foreach ($n in $observed.Keys) {
    if (-not $declared.Contains($n)) {
        Fail "step '$n' ran but is not in step-applicability.tsv"
        continue
    }
    $exp = @($TARGETS | Where-Object { $declared[$n] -contains $_ })
    $got = @($TARGETS | Where-Object { $observed[$n] -contains $_ })
    $expC = @($exp | Where-Object { $complete -contains $_ })
    $gotC = @($got | Where-Object { $complete -contains $_ })
    if (($expC -join ',') -cne ($gotC -join ',')) {
        Fail "step '$n' applicability: declared [$($expC -join ',')] observed [$($gotC -join ',')]"
    }
}
foreach ($n in $declared.Keys) {
    if (-not $observed.Contains($n)) { Fail "declared step '$n' is absent from every leg's run" }
}

# --- 3. NO STEP DISAPPEARED OR REORDERED, measured from the run -------------
# The source-level proof is `check_migration_map.ps1`; this is the same claim
# read off the machine that ran it. For each leg, the legacy job's non-upload
# step names must appear IN ORDER as a subsequence of the steps that actually
# RAN on that leg. Insertions are expected - the CAP-11A gates and the
# collection block are new - and a subsequence test allows exactly those while
# refusing a removal or a swap.
$legacy = @{}
$invPath = Join-Path $PSScriptRoot 'ci-legacy-inventory.tsv'
if (Test-Path -LiteralPath $invPath) {
    foreach ($r in @(Get-Content -LiteralPath $invPath | Select-Object -Skip 1)) {
        if (-not $r.Trim()) { continue }
        $c = $r -split "`t"
        if ($c.Count -lt 11) { continue }
        if ($c[7] -eq 'upload') { continue }   # the one ratified restructuring
        if (-not $legacy.ContainsKey($c[0])) { $legacy[$c[0]] = New-Object System.Collections.Generic.List[string] }
        $legacy[$c[0]].Add($c[2])
    }
} else {
    Fail "missing $invPath -- the legacy order cannot be checked"
}
foreach ($t in $TARGETS) {
    if (-not $legacy.ContainsKey($t)) { continue }
    if ($complete -notcontains $t) {
        Write-Host "[cap11a] $t did not run to completion; its legacy order is not checked"
        continue
    }
    $ran = @($legs[$t].Steps | Where-Object { $_.Conclusion -ne 'skipped' } | ForEach-Object { $_.Name })
    $i = 0
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($n in $legacy[$t]) {
        $found = $false
        while ($i -lt $ran.Count) {
            if ($ran[$i] -ceq $n) { $found = $true; $i++; break }
            $i++
        }
        if (-not $found) { $missing.Add($n) }
    }
    if ($missing.Count -gt 0) {
        Fail ("$t lost or reordered $($missing.Count) legacy step(s), first: '$($missing[0])'")
    } else {
        Write-Host "[cap11a] $t runs all $($legacy[$t].Count) of its legacy steps, in order"
    }
}

# --- 4. what the collection block did, per leg ------------------------------
# The one channel an upload failure cannot take away.
$collection = [ordered]@{}
foreach ($t in $TARGETS) {
    $steps = $legs[$t].Steps
    $gateSteps = @($steps | Where-Object { $_.Name -notlike 'CAP-11A collect the leg *' -and $_.Name -ne 'CAP-11A type the collection outcome' -and $_.Name -ne 'CAP-11A stage the collection and measure it' })
    $gateFailed = @($gateSteps | Where-Object { $_.Conclusion -eq 'failure' })
    $attempts = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($steps | Where-Object { $_.Name -like 'CAP-11A collect the leg *' })) {
        if ($s.Conclusion -eq 'skipped') { continue }
        $elapsed = $null
        if ($s.Started -and $s.Completed) {
            $elapsed = [int](([datetime]$s.Completed - [datetime]$s.Started).TotalMilliseconds)
        }
        $cls = if ($s.Name -match 'collect the leg (\w+) \(attempt (\d+)') { $Matches[1] } else { 'unknown' }
        $att = if ($s.Name -match '\(attempt (\d+)') { [int]$Matches[1] } else { 0 }
        $attempts.Add([ordered]@{
            class = $cls; attempt = $att; outcome = $s.Conclusion; elapsed_ms = $elapsed
        })
    }
    $evidenceOk = @($attempts | Where-Object { $_.class -eq 'evidence' -and $_.outcome -eq 'success' }).Count -gt 0
    $status = if ($gateFailed.Count -gt 0) { 'gate_failure' }
              elseif (-not $evidenceOk) { 'infrastructure' }
              else { 'ok' }
    $collection[$t] = [ordered]@{
        job_conclusion    = $legs[$t].Conclusion
        gates_failed      = @($gateFailed | ForEach-Object { $_.Name })
        evidence_uploaded = $evidenceOk
        status            = $status
        attempts          = $attempts
    }
    Write-Host ("[cap11a] {0,-12} status={1,-15} evidence_uploaded={2} upload_attempts={3}" -f
        $t, $status, $evidenceOk, $attempts.Count)
}

New-Item -ItemType Directory -Force build/cap11a | Out-Null
$out = [ordered]@{
    schema             = 1
    run_id             = $RunId
    repository         = $Repository
    ci_sequence_digest = $seqDigest
    step_count         = $ref.Count
    steps              = $ref
    collection         = $collection
    failures           = @($failures)
}
$json = ($out | ConvertTo-Json -Depth 8)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/sequence.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($env:GITHUB_STEP_SUMMARY) {
    $l = @("### CAP-11A sequence: $(if ($failures.Count -eq 0) { 'four identical legs' } else { 'DIVERGED' })",
           "- steps per leg: $($ref.Count)", "- digest: ``$seqDigest``")
    foreach ($t in $TARGETS) { $l += "- ``$t``: $($collection[$t].status)" }
    ($l -join "`n") | Out-File -Append $env:GITHUB_STEP_SUMMARY
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CAP-11A SEQUENCE FAILED ($($failures.Count) disagreement(s))"
    exit 1
}
Write-Host 'CAP11A_SEQUENCE_PASS'
exit 0
