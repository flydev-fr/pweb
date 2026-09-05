# CAP-11A: the repository gate over the CI structure itself.
#
# It refuses, by name, every way the structure could stop being what was
# ratified. Each section says what it measures and why that measurement exists.
#
# BYTES ARE MEASURED AFTER CRLF->LF NORMALIZATION, not as they sit on disk.
# `.gitattributes` pins `*.sh` to LF but says nothing about `*.yml`, and the
# hosted Windows image ships git with `core.autocrlf=true`, so the same commit
# checks out larger on one leg than on another. A size gate that ran on four
# targets and measured the checkout would disagree with itself - which is the
# exact class of defect this shard exists to remove.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$failures = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) { $script:failures.Add($m); Write-Host "STRUCTURE VIOLATION: $m" }

# --- the ratified numbers ---------------------------------------------------
$MAX_BYTES = 65536      # 64 KB per file under .github/
$MAX_LINES = 1600
$RETENTION = [ordered]@{
    'leg-evidence'         = '90'
    'leg-records'          = '90'
    'leg-release'          = '90'
    'leg-dist'             = '${{ inputs.long_retention && 90 || 14 }}'
    'leg-diagnostics'      = '7'
    'cap7f-platform-matrix' = '90'
    'cap7f-diagnostics-aggregate' = '7'
}
$JOB_TIMEOUTS = [ordered]@{
    'windows' = 135; 'linux' = 45; 'macos-x64' = 75; 'macos-arm64' = 75
}
$AGGREGATE_TIMEOUT = 20
$INVENTORY_TIMEOUT = 10
$PINNED_ACTIONS = @(
    'actions/checkout@11d5960a326750d5838078e36cf38b85af677262',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
    'actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16',
    'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
    'actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57',
    'ilammy/msvc-dev-cmd@0b201ec74fa43914dc39ae48a89fd1d8cb592756'
)
# TWO STATES, BOTH LEGAL, AND THE GATE READS WHICH ONE IT IS IN.
#   twin  - the new caller sits beside the legacy monolith on one commit, which
#           is the migration proof: both structures run, and the aggregate's
#           compared fields are required byte-identical between the two runs.
#   final - the monolith is gone and the caller has taken its name.
# Keying on `ci-matrix.yml` rather than on `ci.yml` is what makes the removal
# commit a pure file move: nothing here has to be edited for the state to flip,
# and `ci_legacy_present` tells the evidence which state a run was in.
$LEG = '.github/workflows/platform-leg.yml'
$MATRIX_CALLER = '.github/workflows/ci-matrix.yml'
if (Test-Path -LiteralPath $MATRIX_CALLER) {
    $CALLER = $MATRIX_CALLER
    $LEGACY = '.github/workflows/ci.yml'
} else {
    $CALLER = '.github/workflows/ci.yml'
    $LEGACY = ''
}

function Read-Norm([string]$Path) {
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

# THE LEGACY MONOLITH IS EXCLUDED FROM THE BOUNDS, and only it, and only while
# it exists. During the twin run BOTH structures are present on one commit on
# purpose - that is the migration proof - and holding the file being replaced to
# the bound its replacement exists to meet would make the proof unrunnable. On
# the final HEAD there is nothing to exclude and every file under `.github/` is
# measured, which `ci_legacy_present = false` records.
$files = @(Get-ChildItem -Path .github -Recurse -File |
    Where-Object { (-not $LEGACY) -or
        ($_.FullName.Substring($repoRoot.Length + 1).Replace([char]92, [char]47) -ne $LEGACY) } |
    Sort-Object FullName)
if ($files.Count -lt 100) { Violation "only $($files.Count) files under .github/ -- the structure is not in place" }

# --- 1. size and line bounds ------------------------------------------------
$maxSeen = 0; $maxSeenFile = ''
foreach ($f in $files) {
    $text = Read-Norm $f.FullName
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($text)
    $lines = ($text -split "`n").Count
    if ($bytes -gt $maxSeen) { $maxSeen = $bytes; $maxSeenFile = $f.FullName.Substring($repoRoot.Length + 1) }
    if ($bytes -gt $MAX_BYTES) {
        Violation ("$($f.FullName.Substring($repoRoot.Length + 1)) is $bytes bytes, over the ratified $MAX_BYTES")
    }
    if ($lines -gt $MAX_LINES) {
        Violation ("$($f.FullName.Substring($repoRoot.Length + 1)) is $lines lines, over the ratified $MAX_LINES")
    }
}
Write-Host "[cap11a] $($files.Count) files under .github/, largest $maxSeen bytes ($maxSeenFile), bound $MAX_BYTES"

# --- 2. the two workflows exist and the legacy monolith is not both here and there
foreach ($p in @($CALLER, $LEG)) {
    if (-not (Test-Path -LiteralPath $p)) { Violation "missing $p" }
}
$legacyPresent = ([bool]$LEGACY) -and (Test-Path -LiteralPath $LEGACY)
Write-Host "[cap11a] caller: $CALLER"
Write-Host "[cap11a] legacy monolith present: $legacyPresent (true only during the twin run)"
if ($legacyPresent) {
    # While both structures exist the legacy file must be BYTE-UNTOUCHED, or the
    # twin run compares the new structure against something this shard edited.
    $legacyLines = ((Read-Norm $LEGACY) -split "`n").Count
    if ($legacyLines -ne 5825) {
        Violation "the legacy monolith is $legacyLines lines, not the 5,825 the twin run compares against"
    }
}

# --- 3. concurrency, permissions, triggers on the caller --------------------
$callerText = Read-Norm $CALLER
if ($callerText -notmatch '(?m)^concurrency:') { Violation "$CALLER declares no concurrency group" }
if ($callerText -notmatch '(?m)^\s*group: ci-\$\{\{ github\.ref \}\}') { Violation "$CALLER concurrency group is not the ratified ci-<ref>" }
if ($callerText -notmatch "cancel-in-progress: \`$\{\{ github\.ref_name != 'main' \}\}") {
    Violation "$CALLER cancel-in-progress is not the ratified off-the-default-branch form"
}
if ($callerText -notmatch '(?m)^permissions:') { Violation "$CALLER declares no permissions block" }
$legText = Read-Norm $LEG
if ($legText -notmatch '(?m)^permissions:') { Violation "$LEG declares no permissions block" }
if ($legText -notmatch '(?m)^\s*workflow_call:') { Violation "$LEG is not a reusable workflow" }

# --- 4. per-job timeouts equal the ratified values --------------------------
foreach ($t in $JOB_TIMEOUTS.Keys) {
    $want = $JOB_TIMEOUTS[$t]
    if ($callerText -notmatch "(?s)target: $([regex]::Escape($t))\s*\n\s*runner: [^\n]+\n\s*timeout: $want\b") {
        Violation "the $t matrix row does not declare the ratified timeout $want"
    }
}
if ($callerText -notmatch "(?s)cap7-aggregate:.*?timeout-minutes: $AGGREGATE_TIMEOUT\b") {
    Violation "the aggregate job does not declare the ratified timeout $AGGREGATE_TIMEOUT"
}
if ($callerText -notmatch "(?s)macos-release-inventory:.*?timeout-minutes: $INVENTORY_TIMEOUT\b") {
    Violation "the release-inventory job does not declare the ratified timeout $INVENTORY_TIMEOUT"
}

# --- 5. retention: every upload declares exactly its class's ratified value --
# Anchored on the UPLOAD step, never on a `name:` line: the caller's download
# steps name the same artifacts and carry no retention, and a gate that read
# those would report a violation that is not one.
foreach ($p in @($CALLER, $LEG)) {
    $lines = (Read-Norm $p) -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch 'uses:\s*actions/upload-artifact@') { continue }
        $hi = [Math]::Min($i + 10, $lines.Count - 1)
        $window = ($lines[$i..$hi] -join "`n")
        if ($window -notmatch '(?m)^\s*name:\s*(.+?)\s*$') {
            Violation "$p has an upload step at line $($i + 1) with no artifact name"
            continue
        }
        $art = ($Matches[1] -replace '-\$\{\{.*$', '').Trim()
        $cls = $null
        foreach ($k in $RETENTION.Keys) { if ($art -eq $k) { $cls = $k; break } }
        if (-not $cls) {
            Violation "$p uploads '$art', which belongs to no ratified retention class"
            continue
        }
        if ($window -notmatch '(?m)^\s*retention-days: (.+)$') {
            Violation "$p artifact '$art' declares no retention-days"
            continue
        }
        $got = $Matches[1].Trim()
        if ($got -cne $RETENTION[$cls]) {
            Violation "$p artifact '$art' retention is '$got', ratified '$($RETENTION[$cls])'"
        }
    }
}

# --- 6. only the six pinned actions, and every `uses:` is pinned by SHA -----
$allYml = @(Get-ChildItem -Path .github -Recurse -File -Filter *.yml)
foreach ($f in $allYml) {
    foreach ($l in (Read-Norm $f.FullName) -split "`n") {
        if ($l -notmatch '^\s*uses:\s*(\S+)') { continue }
        $u = $Matches[1]
        if ($u.StartsWith('./')) { continue }          # a local action or workflow
        if ($PINNED_ACTIONS -notcontains $u) {
            Violation ("$($f.FullName.Substring($repoRoot.Length + 1)) uses an unratified action: $u")
        }
    }
}

# --- 6b. keys GitHub accepts inside a composite action and silently IGNORES --
# `timeout-minutes` and `continue-on-error` are workflow-step keys. A composite
# action carrying either parses, runs, and does nothing with it - which is how a
# per-step budget or a best-effort smoke would quietly become something else.
# They belong on the sequence step, and this refuses them anywhere else.
foreach ($f in @(Get-ChildItem -Path .github/actions -Recurse -File -Filter action.yml -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($repoRoot.Length + 1)
    foreach ($l in (Read-Norm $f.FullName) -split "`n") {
        if ($l -match '^\s+(timeout-minutes|continue-on-error):') {
            Violation "$rel carries '$($Matches[1])' inside a composite action, where GitHub ignores it"
        }
    }
}

# --- 7. UP1: no gate reads an artifact --------------------------------------
# `download-artifact` may appear ONLY in the caller, and only in the two jobs
# whose whole purpose is to consume what the legs produced. A leg step that
# downloaded an artifact would be a gate depending on an upload, which is the
# defect this shard was given.
if ((Read-Norm $LEG) -match 'download-artifact') {
    Violation 'the platform leg reads an artifact -- a gate may never depend on an upload'
}
$actionDownloads = @()
foreach ($f in @(Get-ChildItem -Path .github/actions -Recurse -File -Filter action.yml -ErrorAction SilentlyContinue)) {
    if ((Read-Norm $f.FullName) -match 'download-artifact') {
        $actionDownloads += $f.FullName.Substring($repoRoot.Length + 1)
    }
}
foreach ($a in $actionDownloads) { Violation "$a reads an artifact -- a gate may never depend on an upload" }
$gateReadsArtifact = $actionDownloads.Count + (@(if ((Read-Norm $LEG) -match 'download-artifact') { 1 } else { 0 })[0])

# --- 8. every upload on a leg is inside the collection block, and the block is last
$legLines = (Read-Norm $LEG) -split "`n"
$stepIdx = @()
for ($i = 0; $i -lt $legLines.Count; $i++) {
    if ($legLines[$i] -match '^      - name: (.*)$') { $stepIdx += ,@($i, $Matches[1]) }
}
$firstCollect = -1
for ($k = 0; $k -lt $stepIdx.Count; $k++) {
    if ($stepIdx[$k][1] -like 'CAP-11A stage the collection*') { $firstCollect = $k; break }
}
if ($firstCollect -lt 0) { Violation "$LEG has no collection block" }
else {
    for ($k = 0; $k -lt $stepIdx.Count; $k++) {
        $start = $stepIdx[$k][0]
        $end = if ($k + 1 -lt $stepIdx.Count) { $stepIdx[$k + 1][0] } else { $legLines.Count }
        $body = ($legLines[$start..($end - 1)] -join "`n")
        if ($body -match 'upload-artifact' -and $k -lt $firstCollect) {
            Violation "step '$($stepIdx[$k][1])' uploads BEFORE the collection block"
        }
        if ($k -gt $firstCollect -and $body -notmatch 'CAP-11A') {
            Violation "step '$($stepIdx[$k][1])' comes AFTER the collection block"
        }
    }
    $tail = @($stepIdx[$firstCollect..($stepIdx.Count - 1)] | ForEach-Object { $_[1] })
    if ($tail[-1] -ne 'CAP-11A type the collection outcome') {
        Violation "the last step of a leg is '$($tail[-1])', not the collection typing step"
    }
    Write-Host "[cap11a] collection block: $($tail.Count) steps, last on the leg"
}

# --- 9. every collect attempt is bounded and cannot fail the leg ------------
$attemptSteps = @($stepIdx | Where-Object { $_[1] -like 'CAP-11A collect the leg *' })
foreach ($s in $attemptSteps) {
    $k = [array]::IndexOf(@($stepIdx | ForEach-Object { $_[1] }), $s[1])
    $start = $s[0]
    $end = if ($k + 1 -lt $stepIdx.Count) { $stepIdx[$k + 1][0] } else { $legLines.Count }
    $body = ($legLines[$start..($end - 1)] -join "`n")
    if ($body -notmatch 'continue-on-error: true') {
        Violation "collection step '$($s[1])' can fail the leg"
    }
    if ($s[1] -notmatch '\(attempt (\d+) of (\d+)\)') {
        Violation "collection step '$($s[1])' does not declare its attempt bound"
    } elseif ([int]$Matches[1] -gt [int]$Matches[2] -or [int]$Matches[2] -gt 3) {
        Violation "collection step '$($s[1])' exceeds the ratified bound of 3 attempts"
    }
}
Write-Host "[cap11a] $($attemptSteps.Count) collection attempt steps, all bounded and non-blocking"

# --- the record the evidence emitters read ----------------------------------
$legBytes = [System.Text.Encoding]::UTF8.GetByteCount((Read-Norm $LEG))
$callerBytes = [System.Text.Encoding]::UTF8.GetByteCount((Read-Norm $CALLER))
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $retText = (($RETENTION.Keys | ForEach-Object { "$_=$($RETENTION[$_])" }) -join ';')
    $retDigest = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($retText))) -replace '-', '').ToLowerInvariant()
    $toText = (($JOB_TIMEOUTS.Keys | ForEach-Object { "$_=$($JOB_TIMEOUTS[$_])" }) -join ';') +
              ";aggregate=$AGGREGATE_TIMEOUT;inventory=$INVENTORY_TIMEOUT"
    $toDigest = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($toText))) -replace '-', '').ToLowerInvariant()
} finally { $sha.Dispose() }

New-Item -ItemType Directory -Force build/cap11a | Out-Null
$out = [ordered]@{
    schema                  = 1
    ci_file_count           = $files.Count
    ci_file_max_bytes       = $maxSeen
    ci_file_bound_bytes     = $MAX_BYTES
    ci_file_bound_lines     = $MAX_LINES
    ci_leg_bytes            = $legBytes
    ci_caller_bytes         = $callerBytes
    ci_legacy_present       = $legacyPresent
    upload_model            = 'final_step_bounded_retry'
    upload_max_attempts     = 3
    gate_reads_artifact     = $gateReadsArtifact
    retention_policy_digest = $retDigest
    ci_timeouts_digest      = $toDigest
    ci_timeouts             = $toText
    violations              = $failures.Count
}
$json = ($out | ConvertTo-Json -Depth 5)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/structure.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CAP-11A STRUCTURE FAILED ($($failures.Count) violation(s))"
    exit 1
}
Write-Host "CAP11A_STRUCTURE_PASS leg=$legBytes B caller=$callerBytes B max=$maxSeen B gate_reads_artifact=$gateReadsArtifact"
exit 0
