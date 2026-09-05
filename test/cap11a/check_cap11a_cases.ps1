# CAP-11A: seeded cases for the two pieces whose failure modes are otherwise
# only reachable by spending a hosted run.
#
# WHY THIS FILE EXISTS. Two of the shard's own deliverables were, for a while,
# verified by nothing but their source text:
#
#   1. `check_ci_sequence.ps1` - the gate that measures the aggregate's premise.
#      It has a `-JobsJson` parameter for exactly this purpose and nothing used
#      it. A review built a payload for a perfectly green four-leg run and the
#      gate REFUSED IT: nine collection-retry steps that are skipped on every
#      healthy leg were being held to "observed must equal declared". Every
#      green run would have ended red at `cap7-aggregate` - the failure class
#      this shard exists to remove, discoverable only by paying for a full run.
#
#   2. `smokeobserve.ps1`'s cause rule. Swapping two of its branches leaves all
#      four literals present, the taxonomy check satisfied and the observation
#      file well-formed, so the only gate that mentions the observer stays
#      green while a confidently wrong cause is written into a ratified
#      artifact - the exact CAP-10E lesson the file's own header quotes.
#
# It also pins the PRODUCER/CONSUMER CONTRACT of `build/cap11a/sequence.json`:
# the selftest's e11/e12 legs write that file themselves, so nothing compared
# what `check_ci_sequence.ps1` actually produces against what
# `check_cap7f_aggregate.ps1` reads. Renaming one key would leave both green
# and silently restore the untyped message that cost run 33955241980.
#
# No network, no API, no run: every case is a payload.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap11a/cases'
if (Test-Path -LiteralPath $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null

$failures = New-Object System.Collections.Generic.List[string]
function Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS  $What" }
    else { $script:failures.Add("$What ($Detail)"); Write-Host "  FAIL  $What -- $Detail" }
}

$TARGETS = @('windows', 'linux', 'macos-x64', 'macos-arm64')
$SEQ = Join-Path $PSScriptRoot 'check_ci_sequence.ps1'
$applic = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'step-applicability.tsv') |
    Select-Object -Skip 1 | Where-Object { $_.Trim() } | ForEach-Object {
        $c = $_ -split "`t"
        [pscustomobject]@{ Name = $c[1]; Applies = @($c[2] -split ','); Conditional = ($c[3] -eq 'conditional') }
    })
Write-Host "[cases] the declared sequence is $($applic.Count) steps, $(@($applic | Where-Object { $_.Conditional }).Count) of them conditional"

# --- build a jobs payload from the declared table ---------------------------
# `Perturb` is a scriptblock given ($target, $stepName, $conclusion) that returns
# the conclusion to write - which is how each case bends exactly one thing.
function New-JobsPayload {
    param([scriptblock]$Perturb = $null, [string[]]$Only = $TARGETS)
    $jobs = @()
    $id = 101358272728        # a real job id from this repository: past Int32
    foreach ($t in $Only) {
        $id++
        $steps = @()
        $n = 0
        foreach ($s in $applic) {
            $n++
            $applies = ($s.Applies -contains $t)
            $c = if (-not $applies) { 'skipped' }
                 elseif ($s.Conditional) { 'skipped' }   # a healthy run: no retry, no diagnostics
                 else { 'success' }
            if ($null -ne $Perturb) { $c = & $Perturb $t $s.Name $c }
            if ($c -eq '<drop>') { continue }
            $steps += [ordered]@{
                name = $s.Name; number = $n; conclusion = $c; status = 'completed'
                started_at = '2026-09-06T00:00:00Z'; completed_at = '2026-09-06T00:00:01Z'
            }
        }
        $jobs += [ordered]@{
            id = $id; name = "leg ($t, runner, 60) / $t"; conclusion = 'success'
            status = 'completed'
            steps = (@(@{ name = 'Set up job'; number = 0; conclusion = 'success'; status = 'completed'
                          started_at = $null; completed_at = $null }) + $steps +
                     @(@{ name = 'Complete job'; number = 999; conclusion = 'success'; status = 'completed'
                          started_at = $null; completed_at = $null }))
        }
    }
    return [ordered]@{ total_count = $jobs.Count; jobs = $jobs }
}

function Invoke-SeqCase {
    param([string]$Label, [object]$Payload)
    $f = Join-Path $work "$Label.json"
    ($Payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $f -Encoding utf8
    & pwsh -NoProfile -File $SEQ -Repository 'seed/seed' -RunId $Label -JobsJson $f `
        *> (Join-Path $work "$Label.log")
    return $LASTEXITCODE
}

# --- S1: a perfectly green four-leg run MUST pass ---------------------------
Write-Host 'S1: a healthy run'
$rc = Invoke-SeqCase 'green' (New-JobsPayload)
Check 'S1 the gate accepts a green run' ($rc -eq 0) `
    "exit $rc -- $((Get-Content (Join-Path $work 'green.log') | Where-Object { $_ -match 'SEQUENCE FAIL' } | Select-Object -First 3) -join ' | ')"

# --- S2: one leg runs a different step name --------------------------------
Write-Host 'S2: a name that differs on one leg'
$rc = Invoke-SeqCase 'renamed' (New-JobsPayload -Perturb {
    param($t, $n, $c)
    if ($t -eq 'linux' -and $n -eq 'Checkout') { return $c }   # keep conclusions
    return $c
})
# rename by editing the payload after the fact - the perturb hook shapes
# conclusions, not names
$f = Join-Path $work 'renamed.json'
$p = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json
$p.jobs[1].steps[3].name = 'Checkout THE WRONG THING'
($p | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $f -Encoding utf8
& pwsh -NoProfile -File $SEQ -Repository 'seed/seed' -RunId 'renamed' -JobsJson $f *> (Join-Path $work 'renamed.log')
$rc = $LASTEXITCODE
Check 'S2 a diverged step name is refused' ($rc -ne 0) "exit $rc"
Check 'S2 the refusal names the differing step' `
    ((Select-String -Path (Join-Path $work 'renamed.log') -Pattern 'differs' -Quiet) -eq $true) ''

# --- S3: a step runs on a leg it does not apply to --------------------------
Write-Host 'S3: applicability drift'
$winOnly = @($applic | Where-Object { $_.Applies.Count -eq 1 -and $_.Applies[0] -eq 'windows' -and -not $_.Conditional })[0].Name
$rc = Invoke-SeqCase 'drift' (New-JobsPayload -Perturb {
    param($t, $n, $c)
    if ($t -eq 'linux' -and $n -eq $winOnly) { return 'success' }
    return $c
}.GetNewClosure())
Check 'S3 a step running off its declared set is refused' ($rc -ne 0) "exit $rc"

# --- S4: a step that should run everywhere is skipped on one leg ------------
Write-Host 'S4: a gate that stopped running on one leg'
$allFour = @($applic | Where-Object { $_.Applies.Count -eq 4 -and -not $_.Conditional })[0].Name
$rc = Invoke-SeqCase 'skipped' (New-JobsPayload -Perturb {
    param($t, $n, $c)
    if ($t -eq 'macos-x64' -and $n -eq $allFour) { return 'skipped' }
    return $c
}.GetNewClosure())
Check 'S4 a gate skipped on one leg is refused' ($rc -ne 0) "exit $rc"

# --- S5: a leg with a failed gate does not cascade into applicability noise --
Write-Host 'S5: one leg red'
$rc = Invoke-SeqCase 'redleg' (New-JobsPayload -Perturb {
    param($t, $n, $c)
    if ($t -ne 'windows') { return $c }
    if ($n -eq $allFour) { return 'failure' }
    # everything after the failure is skipped, as a real runner reports it
    return $c
}.GetNewClosure())
$log = @(Get-Content (Join-Path $work 'redleg.log'))
$held = @($log | Where-Object { $_ -match 'legs held to the declared applicability' })
Check 'S5 a red leg is excluded from the applicability comparison' `
    ((@($held | Where-Object { $_ -notmatch 'windows' })).Count -ge 1) ($held -join ' ')

# --- S6: a target with no job at all ----------------------------------------
Write-Host 'S6: a leg that never started'
$rc = Invoke-SeqCase 'noleg' (New-JobsPayload -Only @('windows', 'linux', 'macos-x64'))
Check 'S6 a missing leg is refused' ($rc -ne 0) "exit $rc"

# --- S7: THE PRODUCER/CONSUMER CONTRACT of sequence.json --------------------
Write-Host 'S7: the sequence record the aggregator reads'
[void](Invoke-SeqCase 'contract' (New-JobsPayload))
$sq = Get-Content -Raw -LiteralPath 'build/cap11a/sequence.json' | ConvertFrom-Json
Check 'S7 the record keys the collection by target name' `
    (@($TARGETS | Where-Object { $sq.collection.PSObject.Properties.Name -contains $_ }).Count -eq 4) `
    (($sq.collection.PSObject.Properties.Name) -join ',')
# the aggregator branches on exactly these two spellings
$aggSrc = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'test/cap7f/check_cap7f_aggregate.ps1'))
foreach ($k in 'status', 'gates_failed') {
    Check "S7 the record carries '$k', which the aggregator reads" `
        ($null -ne $sq.collection.windows.PSObject.Properties[$k]) ''
}
foreach ($v in 'infrastructure', 'gate_failure') {
    Check "S7 the aggregator branches on the '$v' spelling this gate writes" `
        ($aggSrc.Contains("-eq '$v'")) ''
}
Check 'S7 a healthy leg types ok' ("$($sq.collection.linux.status)" -eq 'ok') "$($sq.collection.linux.status)"

# ===========================================================================
# The smoke observer's cause rule, one case per branch.
# ===========================================================================
Write-Host 'C: the non-report cause rule'
. (Join-Path $PSScriptRoot 'smokeobserve.ps1')

function Test-Cause {
    param([string]$Label, [string]$Profile, [string]$Script, [int]$Wv2Max,
          [bool]$HostSeen, [string]$Output, [string]$Expect)
    $dir = Join-Path $work "prof-$Label"
    $state = [pscustomobject]@{
        OutFile = (Join-Path $work "obs-$Label.txt")
        StartUtc = [DateTime]::UtcNow.AddMinutes(-1)
        UserDataDir = ''
        Baseline = 0; Job = $null; Error = ''
    }
    # the profile observations are staged as real files, so the rule is exercised
    # through the same code the drivers run
    if ($Profile -ne 'absent') {
        New-Item -ItemType Directory -Force $dir | Out-Null
        $state.UserDataDir = $dir
        if ($Profile -eq 'true') {
            Set-Content -LiteralPath (Join-Path $dir 'touched.txt') -Value 'x'
        }
        if ($Script -eq 'true') {
            # SEGMENT BY SEGMENT: one string with backslashes is a single
            # directory NAME on POSIX, not three directories.
            $cc = Join-Path (Join-Path (Join-Path $dir 'Default') 'Code Cache') 'js'
            New-Item -ItemType Directory -Force $cc | Out-Null
            Set-Content -LiteralPath (Join-Path $cc 'compiled.bin') -Value 'x'
        }
    }
    # the sample stream the background job would have produced, fed through the
    # production code path rather than a paraphrase of it
    $h = if ($HostSeen) { 1 } else { 0 }
    $obs = Stop-PWebSmokeObserver -State $state -Output $Output -ExitCode 1 `
        -AutocloseMs 8000 -Samples @("t=0 host=$h wv2=$Wv2Max wv2_delta=$Wv2Max title=`"`"")
    Check "C $Label -> $Expect" ($obs.cause -eq $Expect) "got '$($obs.cause)'"
    return $obs
}

# a report line beats every other observation
[void](Test-Cause -Label 'reported' -Profile 'absent' -Script 'absent' -Wv2Max 0 `
    -HostSeen $true -Output "releaseapp report: {}`nFAIL" -Expect 'ran_missed_window')
# script was compiled: it ran
[void](Test-Cause -Label 'compiled' -Profile 'true' -Script 'true' -Wv2Max 2 `
    -HostSeen $true -Output 'FAIL' -Expect 'ran_missed_window')
# the engine wrote profile state and compiled nothing
[void](Test-Cause -Label 'loaded' -Profile 'true' -Script 'false' -Wv2Max 2 `
    -HostSeen $true -Output 'FAIL' -Expect 'loaded_script_never_ran')
# a browser came up and wrote nothing at all
[void](Test-Cause -Label 'neverloaded' -Profile 'false' -Script 'false' -Wv2Max 2 `
    -HostSeen $true -Output 'FAIL' -Expect 'page_never_loaded')
# the profile is unmeasurable and nothing else separates the causes
[void](Test-Cause -Label 'undetermined' -Profile 'absent' -Script 'absent' -Wv2Max 0 `
    -HostSeen $false -Output 'FAIL' -Expect 'undetermined')

New-Item -ItemType Directory -Force build/cap11a | Out-Null
$out = [ordered]@{ schema = 1; sequence_cases = 7; cause_cases = 5; failures = $failures.Count }
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/cases.json'),
    (($out | ConvertTo-Json -Depth 3) -replace "`r`n", "`n") + "`n",
    (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host "CASE FAIL: $f" }
    Write-Host "CAP-11A CASES FAILED ($($failures.Count))"
    exit 1
}
Write-Host 'CAP11A_CASES_PASS 7 sequence cases, 5 cause cases'
exit 0
