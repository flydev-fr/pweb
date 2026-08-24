# CAP-8C Phase A: render the four-target topology comparison.
#
# MEASUREMENT ONLY - this summarizer gates nothing and no rendering it
# prints is policy. It searches -Path RECURSIVELY for topology-*.json
# documents written by test/cap8c/topology.pas (or the SKIP records the
# Windows runner writes), attributes each document by the target it
# DECLARES rather than by the directory it was found in - a leg filed under
# the wrong name is refused, not silently re-attributed - and renders the
# fact-by-fact comparison across the four pinned engines. A divergence
# between engines is the KIND OF ANSWER this probe exists to obtain, so it
# can never turn this script red; only being pointed at nothing at all is
# an error, because that means the caller wired it wrong.
#
# Usage:
#   pwsh test/cap8c/summarize_topology.ps1                # reads build/cap8c
#   pwsh test/cap8c/summarize_topology.ps1 -Path ev       # CI: four downloads
param(
    [string]$Path = ''
)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($Path -eq '') {
    $Path = Join-Path $repoRoot 'build/cap8c'
}
if (-not (Test-Path $Path)) {
    throw "summary root does not exist: $Path"
}

$targets = @('windows-x86_64', 'linux-x86_64', 'macos-x86_64', 'macos-arm64')

# the fact rows, in the order the spec's Phase A asks its questions
$factRows = @(
    'second_create_before_run_ok',
    'distinct_instance_handles',
    'prerun_window_first_nonnil',
    'prerun_window_second_nonnil',
    'prerun_windows_distinct',
    'live_window_first_nonnil',
    'live_window_second_nonnil',
    'first_view_loaded',
    'second_view_loaded_during_first_run',
    'userdata_isolated',
    'cross_deliveries',
    'unknown_userdata',
    'concurrent_holds_observed',
    'first_view_resolved',
    'second_view_resolved',
    'liveness_timeout',
    'terminate_second_stopped_run',
    'run_reentries',
    'loop_survived_second_destroy',
    'survivor_functional_after_close',
    'terminate_first_stopped_run',
    'premature_exit_phase',
    'destroy_second_code',
    'destroy_second_postrun_code',
    'destroy_first_postrun_code'
)

# collect every document, attributed by DECLARED target
$docs = @{}
$refused = @()
Get-ChildItem -Path $Path -Recurse -Filter 'topology-*.json' -File |
    ForEach-Object {
        try {
            $doc = Get-Content $_.FullName -Raw | ConvertFrom-Json
        } catch {
            $refused += "$($_.FullName): unparsable ($($_.Exception.Message))"
            return
        }
        if ($null -eq $doc.target -or $doc.probe -ne 'cap8c-topology') {
            $refused += "$($_.FullName): not a cap8c-topology document"
            return
        }
        $declared = [string]$doc.target
        $expectedName = "topology-$declared.json"
        if ($_.Name -ne $expectedName) {
            $refused += "$($_.FullName): declares target '$declared' but is named '$($_.Name)'"
            return
        }
        if ($docs.ContainsKey($declared)) {
            $refused += "$($_.FullName): duplicate document for target '$declared'"
            return
        }
        $docs[$declared] = $doc
    }

function Cell($doc, [string]$fact) {
    if ($null -eq $doc) { return 'MISSING' }
    if ($doc.overall -eq 'SKIP') { return 'SKIP' }
    $facts = $doc.facts
    if ($null -eq $facts) { return '-' }
    $value = $facts.$fact
    if ($null -eq $value) { return 'null' }
    if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
    return [string]$value
}

Write-Host ''
Write-Host '=============== CAP-8C Phase A: multi-WebView topology ==============='
Write-Host "targets present: $($docs.Count)/4"
foreach ($r in $refused) { Write-Host "REFUSED: $r" }
Write-Host ''

$header = '{0,-38}' -f 'fact'
foreach ($t in $targets) { $header += ' {0,-16}' -f ($t -replace 'x86_64', 'x64') }
Write-Host $header
Write-Host ('-' * $header.Length)

$row = '{0,-38}' -f 'overall'
foreach ($t in $targets) {
    $d = $null
    if ($docs.ContainsKey($t)) { $d = $docs[$t] }
    if ($null -eq $d) { $row += ' {0,-16}' -f 'MISSING' }
    else { $row += ' {0,-16}' -f ([string]$d.overall) }
}
Write-Host $row
$row = '{0,-38}' -f 'engine'
foreach ($t in $targets) {
    $d = $null
    if ($docs.ContainsKey($t)) { $d = $docs[$t] }
    if ($null -eq $d) { $row += ' {0,-16}' -f 'MISSING' }
    elseif ($null -eq $d.engine) { $row += ' {0,-16}' -f '-' }
    else { $row += ' {0,-16}' -f ([string]$d.engine) }
}
Write-Host $row
$row = '{0,-38}' -f 'crash_guard'
foreach ($t in $targets) {
    $d = $null
    if ($docs.ContainsKey($t)) { $d = $docs[$t] }
    if ($null -eq $d) { $row += ' {0,-16}' -f 'MISSING' }
    elseif ($null -eq $d.crash_guard) { $row += ' {0,-16}' -f 'none' }
    else { $row += ' {0,-16}' -f ([string]$d.crash_guard) }
}
Write-Host $row

foreach ($fact in $factRows) {
    $row = '{0,-38}' -f $fact
    foreach ($t in $targets) {
        $d = $null
        if ($docs.ContainsKey($t)) { $d = $docs[$t] }
        $row += ' {0,-16}' -f (Cell $d $fact)
    }
    Write-Host $row
}

Write-Host ''
foreach ($t in $targets) {
    if (-not $docs.ContainsKey($t)) {
        Write-Host "NOT MEASURED: $t (no document)"
        continue
    }
    $d = $docs[$t]
    if ($d.overall -eq 'SKIP') {
        Write-Host "NOT MEASURED: $t (runner recorded SKIP)"
    } elseif ($d.overall -ne 'COMPLETE') {
        Write-Host "PARTIAL: $t (crash_guard=$($d.crash_guard); see its timeline)"
    }
}

if ($docs.Count -eq 0) {
    # nothing at all means the caller pointed this at the wrong place - an
    # empty rendering must not look like four MISSING measurements
    throw "no cap8c-topology documents found under $Path"
}
Write-Host ''
Write-Host 'measurement rendering only - the Checkpoint 1 verdict is human-ratified'
