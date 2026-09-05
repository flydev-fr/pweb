# CAP-11A: the CAP-7F evidence schema is maintained by hand in three places, and
# nothing checked that they agreed. This does.
#
# THE MEASURED COST OF NOT HAVING THIS GATE (ledger, CAP-10D2): on hosted run
# 33957698297 all four platform jobs were green - every gate passed and every new
# row was measured correctly on every target - and `cap7 aggregate` failed with
# `AGGREGATE FAIL: REQUIRED FIELD MISSING/EMPTY` six times per target. The rows
# were in each target's own gate record and were dropped on the way into
# `evidence.json`, because a required row had been added to the aggregator's list
# without being added to both emitters. A whole hosted run - four platform jobs,
# the expensive ones - bought nothing.
#
# THE THREE PLACES, and how each is read:
#   1. test/cap7f/emit_evidence.ps1   the `$evidence = [ordered]@{ ... }` literal
#   2. test/cap7f/emit_evidence.sh    the `evidence.json` heredoc template
#   3. test/cap7f/check_cap7f_aggregate.ps1   the `$required` list
#
# WHAT IT REFUSES: a field an emitter writes that the aggregator does not
# require, and a field the aggregator requires that either emitter does not
# write. Both directions matter - the first is a row nobody reads (which is how a
# field quietly stops being compared), the second is the red run above.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$failures = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) { $script:failures.Add($m); Write-Host "SCHEMA VIOLATION: $m" }

function Read-Norm([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "missing $Path" }
    return (([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n") -split "`n")
}

# --- 1. the PowerShell emitter's ordered hashtable --------------------------
function Get-PsFields([string]$Path) {
    $lines = Read-Norm $Path
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\$evidence = \[ordered\]@\{\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { throw "$Path has no ordered evidence literal" }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\}\s*$') { return $out }
        if ($lines[$i] -match '^\s*#') { continue }
        if ($lines[$i] -match '^\s{4}([a-z][a-z0-9_]*)\s*=') { $out.Add($Matches[1]) }
    }
    throw "${Path}: the evidence literal is not closed"
}

# --- 2. the shell emitter's JSON heredoc ------------------------------------
function Get-ShFields([string]$Path) {
    $lines = Read-Norm $Path
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'evidence\.json"\s*<<EOF\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { throw "$Path has no evidence.json heredoc" }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^EOF\s*$') { return $out }
        if ($lines[$i] -match '^\s{2}"([a-z][a-z0-9_]*)"\s*:') { $out.Add($Matches[1]) }
    }
    throw "${Path}: the evidence.json heredoc is not closed"
}

# --- 3. the aggregator's required list --------------------------------------
function Get-RequiredFields([string]$Path) {
    $lines = Read-Norm $Path
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\$required = @?\(\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { throw "$Path has no required list" }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\)\s*$') { return $out }
        foreach ($m in [regex]::Matches($lines[$i], "'([a-z][a-z0-9_]*)'")) {
            # a comment line may quote a field name in prose; only take the
            # quoted names that sit in the list itself
            if ($lines[$i] -match '^\s*#') { continue }
            $out.Add($m.Groups[1].Value)
        }
    }
    throw "${Path}: the required list is not closed"
}

$ps = Get-PsFields 'test/cap7f/emit_evidence.ps1'
$sh = Get-ShFields 'test/cap7f/emit_evidence.sh'
$req = Get-RequiredFields 'test/cap7f/check_cap7f_aggregate.ps1'

Write-Host "[cap7f] emit_evidence.ps1: $($ps.Count) fields"
Write-Host "[cap7f] emit_evidence.sh : $($sh.Count) fields"
Write-Host "[cap7f] aggregator required: $($req.Count) fields"

foreach ($pair in @(@('emit_evidence.ps1', $ps), @('emit_evidence.sh', $sh), @('check_cap7f_aggregate.ps1', $req))) {
    $dupes = @($pair[1] | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($d in $dupes) { Violation "$($pair[0]) declares '$($d.Name)' $($d.Count) times" }
}

$psSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ps)
$shSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$sh)
$reqSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$req)

# (a) THE RED-RUN DIRECTION. A field the aggregator requires and an emitter does
# not write is exactly what cost run 33957698297, and it is always a defect.
foreach ($f in $req) {
    if (-not $psSet.Contains($f)) { Violation "the aggregator requires '$f'; emit_evidence.ps1 never writes it" }
    if (-not $shSet.Contains($f)) { Violation "the aggregator requires '$f'; emit_evidence.sh never writes it" }
}

# (b) THE TWIN DIRECTION. The two emitters are hand-maintained twins over one
# schema; a row in one and not the other means three targets carry a field and
# the fourth does not, which the aggregator would report as a missing field on
# whichever family lost it.
foreach ($f in $ps) { if (-not $shSet.Contains($f)) { Violation "emit_evidence.ps1 writes '$f'; emit_evidence.sh does not" } }
foreach ($f in $sh) { if (-not $psSet.Contains($f)) { Violation "emit_evidence.sh writes '$f'; emit_evidence.ps1 does not" } }

# (c) THE INFORMATIONAL DIRECTION, pinned rather than refused. Seventeen rows are
# emitted for a human and required of nobody - per-target counts, doctor exits,
# summary strings - and that is a deliberate state closed shards ratified. The
# COUNT is pinned so a NEW unrequired row is refused: a field added to the
# emitters and forgotten in the aggregator's list is a field that silently stops
# being compared, which is the quiet half of the same defect.
$UNREQUIRED_PINNED = 17
$unrequired = @(@($ps) + @($sh) | Sort-Object -Unique | Where-Object { -not $reqSet.Contains($_) })
Write-Host "[cap7f] emitted-but-not-required: $($unrequired.Count) (pinned $UNREQUIRED_PINNED)"
if ($unrequired.Count -ne $UNREQUIRED_PINNED) {
    Violation ("emitted-but-not-required is $($unrequired.Count), pinned at ${UNREQUIRED_PINNED}: " +
        (($unrequired | Select-Object -First 10) -join ', '))
}

New-Item -ItemType Directory -Force build/cap7f | Out-Null
$out = [ordered]@{
    schema            = 1
    fields_ps1        = $ps.Count
    fields_sh         = $sh.Count
    fields_required   = $req.Count
    fields_unrequired = $unrequired.Count
    asymmetry         = $failures.Count
}
$json = ($out | ConvertTo-Json -Depth 3)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap7f/schema-agreement.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CAP-7F SCHEMA AGREEMENT FAILED ($($failures.Count) disagreement(s))"
    exit 1
}
Write-Host "CAP7F_SCHEMA_AGREEMENT_PASS $($ps.Count) fields, three lists, zero asymmetry"
exit 0
