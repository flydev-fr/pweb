# CAP-11B (CL1): the PHASE-WIDE ledger disposition, the SPEC's CAP-11
# acceptance, the two hosted runs, and the CAP-12 handoff.
#
# The same measurement test/cap10d2/check_cap10_ledger.ps1 makes for CAP-10,
# narrowed to this phase's two shards. A phase closure that says "the ledger
# was reviewed" is a sentence; this is what stands behind it.
#
# THE KEY IS <shard>-<ordinal> PLUS THE FIRST EIGHT HEX OF THE SHA-256 OF THE
# ENTRY'S OWN summary LINE, exactly as the CAP-10 gates define it:
#
#   the ordinal    catches an entry ADDED or REMOVED - the ledger is
#                  append-only, so a closed shard's ordinal is stable, and a
#                  count that moved means somebody edited its history
#   the digest     catches an entry REWORDED. A disposition is a judgement
#                  about a specific claim, and a claim that changed needs its
#                  judgement read again rather than inherited
#
# So an ORPHAN, a STRAY, a COUNT DRIFT and a SILENT REWORD are four different
# failures with four different messages.
#
# It also requires what only a PHASE closure can be required to have: the
# SPEC's CAP-11 acceptance answered clause by clause with cited evidence or a
# named ratified deviation; both hosted runs cited; the CAP-12 handoff; and
# docs/index.md cross-linking every contract document including the one this
# shard adds.
#
# Checkout-only: no toolchain, no network, no display.
# Emits build/cap11b/ledger.json and exits nonzero on any violation.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) { $violations.Add($Text); Write-Host "VIOLATION: $Text" }

$ledgerPath  = '_bmad-output/implementation-artifacts/deferred-work.md'
$closurePath = '_bmad-output/implementation-artifacts/cap11-closure-artifact.md'
$specPath    = '_bmad-output/specs/spec-pweb/SPEC.md'
foreach ($p in $ledgerPath, $closurePath, $specPath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}

# The TWO shards this closure disposes of, and the spec file that names each.
$shards = [ordered]@{
    'spec-phase-11-cap11a-ci-matrix.md'         = '11A'
    'spec-phase-11-cap11b-upstream-watcher.md'  = '11B'
}
# The CLOSED SET a disposition may come from. `RESOLVED` means the thing the
# entry describes is done; `RECORDED-ONLY` means it was never work - a measured
# limitation, a ratification, a lesson; the rest name the shard that inherits
# it. Anything else is a disposition nobody agreed on.
$allowed = @('RESOLVED', 'RECORDED-ONLY', 'CAP-12', 'CAP-13', 'LATER')

function Sha8([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
    } finally { $sha.Dispose() }
}

# --- 1. the ledger's own CAP-11 entries --------------------------------------
$entries = [ordered]@{}
$counts = @{}
foreach ($k in $shards.Values) { $counts[$k] = 0 }
$current = $null
foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
    if ($line -match '^- source_spec: `[^`]*/([^/`]+)`\s*$') {
        $file = $Matches[1]
        $current = if ($shards.Contains($file)) { $shards[$file] } else { $null }
        continue
    }
    if ($line -match '^- source_spec:') { $current = $null; continue }
    if (($null -ne $current) -and ($line -match '^  summary: (.*)$')) {
        $counts[$current]++
        $key = "$current-$($counts[$current])"
        $entries[$key] = Sha8 $Matches[1]
    }
}
foreach ($k in $shards.Values) { $facts["ledger_$k"] = $counts[$k] }
$facts['ledger_entries'] = $entries.Count
if ($entries.Count -eq 0) {
    Violation "$ledgerPath yielded no CAP-11 entry -- the parser or the ledger moved"
}
foreach ($k in $shards.Values) {
    if ($counts[$k] -eq 0) { Violation "the ledger carries no $k entry at all" }
}

# --- 2. the closure artifact's disposition table -----------------------------
# one row per entry: | <key> | <digest8> | <DISPOSITION> | <reason> |
$closure = [System.IO.File]::ReadAllText($closurePath)
$rows = [ordered]@{}
$rowRx = '^\|\s*((?:11A|11B)-\d+)\s*\|\s*([0-9a-f]{8})\s*\|\s*([A-Z0-9-]+)\s*\|\s*(.+?)\s*\|\s*$'
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($closurePath)) {
    $lineNo++
    if ($line -match $rowRx) {
        $key = $Matches[1]
        if ($rows.Contains($key)) {
            Violation "the closure table disposes of $key TWICE (line $lineNo): one entry, one judgement"
            continue
        }
        $rows[$key] = [pscustomobject]@{
            Digest = $Matches[2]; Disposition = $Matches[3]
            Reason = $Matches[4]; Line = $lineNo
        }
    }
}
$facts['closure_rows'] = $rows.Count

# --- 3. orphan, stray, reword, and the closed set ----------------------------
$orphans = 0; $reworded = 0; $badDisposition = 0
foreach ($key in $entries.Keys) {
    if (-not $rows.Contains($key)) {
        $orphans++
        Violation ("LEDGER ORPHAN: $key has no disposition in the CAP-11 closure artifact -- " +
            'every CAP-11 entry is either RESOLVED, RECORDED-ONLY, or assigned to a later phase with a reason')
        continue
    }
    $row = $rows[$key]
    if ($row.Digest -cne $entries[$key]) {
        $reworded++
        Violation ("LEDGER ENTRY REWORDED: $key is $($entries[$key]) in the ledger and " +
            "$($row.Digest) in the closure table (line $($row.Line)) -- a claim that changed " +
            'needs its disposition read again, not inherited')
    }
    if ($allowed -notcontains $row.Disposition) {
        $badDisposition++
        Violation "UNKNOWN DISPOSITION for ${key}: '$($row.Disposition)' (line $($row.Line)) -- allowed: $($allowed -join ', ')"
    }
    if ($row.Reason.Length -lt 12) {
        Violation ("$key carries a disposition with no reason (line $($row.Line)) -- " +
            'a table of verdicts nobody justified is a table nobody can check')
    }
}
foreach ($key in $rows.Keys) {
    if (-not $entries.Contains($key)) {
        Violation "STRAY DISPOSITION: the closure table names $key (line $($rows[$key].Line)), which the ledger does not carry"
    }
}
$facts['ledger_orphans'] = $orphans
$facts['ledger_reworded'] = $reworded
$facts['ledger_unknown_disposition'] = $badDisposition
$census = [ordered]@{}
foreach ($d in $allowed) { $census[$d] = 0 }
foreach ($key in $rows.Keys) { if ($census.Contains($rows[$key].Disposition)) { $census[$rows[$key].Disposition]++ } }
$facts['disposition_census'] = $census

# --- 4. the SPEC's CAP-11 acceptance, clause by clause -----------------------
$specText = [System.IO.File]::ReadAllText($specPath)
$specCap11 = ''
if ($specText -match '(?s)- \*\*CAP-11\*\*(.*?)- \*\*CAP-12\*\*') { $specCap11 = $Matches[1].Trim() }
$facts['spec_cap11_present'] = [bool]($specCap11 -ne '')
$intentLine = ''
if ($specCap11 -ne '') {
    $intentLine = $specCap11.Split("`n")[0].Trim()
    if ($intentLine.StartsWith('- ')) { $intentLine = $intentLine.Substring(2) }
}
$facts['spec_intent_line'] = $intentLine
if ($specCap11 -eq '') { Violation "$specPath carries no CAP-11 acceptance block" }
elseif (-not $closure.Contains($intentLine)) {
    Violation 'the closure artifact does not quote the SPEC CAP-11 intent line verbatim'
}
$specRows = @([regex]::Matches($closure, '(?m)^\|\s*(A\d+)\s*\|\s*(MET|DEVIATED)\s*\|\s*(.+?)\s*\|\s*$'))
$met = 0; $deviated = 0
foreach ($m in $specRows) {
    if ($m.Groups[2].Value -eq 'MET') { $met++ } else { $deviated++ }
    if ($m.Groups[3].Value.Length -lt 20) { Violation "SPEC acceptance $($m.Groups[1].Value) carries no evidence" }
}
$facts['spec_lines_met'] = $met
$facts['spec_lines_deviated'] = $deviated
$facts['spec_lines_total'] = $specRows.Count
if ($specRows.Count -lt 4) {
    Violation ("the closure's SPEC acceptance table has $($specRows.Count) row(s); CAP-11 states one " +
        'intent and two success clauses, and the closure answers each of them plus the constraint it touches')
}

# --- 5. the two hosted runs, and the handoff ---------------------------------
$runRows = @([regex]::Matches($closure,
    '(?m)^\|\s*(CAP-11(?:A|B)(?:[^|]*)?)\|\s*`?([0-9a-f]{7,40}|pending)`?\s*\|\s*(\d{9,11}|pending)\s*\|'))
$facts['run_rows'] = $runRows.Count
$cited = @(); $pending = @()
foreach ($m in $runRows) {
    if ($m.Groups[3].Value -eq 'pending') { $pending += $m.Groups[1].Value.Trim() }
    else { $cited += "$($m.Groups[1].Value.Trim())=$($m.Groups[3].Value)" }
}
$facts['hosted_runs_cited'] = $cited.Count
$facts['hosted_runs'] = $cited -join ','
$facts['hosted_runs_pending'] = $pending -join ','
if ($runRows.Count -lt 2) {
    Violation "$closurePath carries $($runRows.Count) row(s) in its hosted-run table; CAP-11 is two shards and its closure names both"
}
# A CLOSED shard's green run is a fact and may never read `pending`. THIS
# shard's own row may, and only until its closure commit: the run that proves
# CAP-11B is the run of the commit that carries this table, so the id cannot be
# in the file that produces it. The same ordering CAP-10D2 used for its own row.
foreach ($closed in 'CAP-11A') {
    if (@($pending | Where-Object { $_ -like "$closed*" }).Count -gt 0) {
        Violation "$closurePath leaves $closed's hosted run ``pending``: that shard is closed and its green run is a fact"
    }
}
# CASE-INSENSITIVE, deliberately: these are subjects the closure has to cover,
# not strings it has to spell a particular way. A section titled "KNOWN
# LIMITATIONS" records exactly what "known limitation" asks for.
foreach ($phrase in 'CAP-12 handoff', 'supersession', 'must not touch',
                    'known limitation', 'sdk_own_license') {
    if ($closure -inotmatch [regex]::Escape($phrase)) { Violation "$closurePath does not record: $phrase" }
}

# --- 6. the docs index cross-links every contract, including the new one -----
$indexPath = 'docs/index.md'
if (-not (Test-Path -LiteralPath $indexPath)) { Violation "missing $indexPath" }
else {
    $index = [System.IO.File]::ReadAllText($indexPath)
    foreach ($doc in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Filter '*-contract.md' -File |
            ForEach-Object { $_.Name })) {
        if (-not $index.Contains($doc)) { Violation "$indexPath does not cross-link $doc" }
    }
    foreach ($doc in 'kernel.md', 'third-party-licenses.md', 'watcher-contract.md') {
        if (-not $index.Contains($doc)) { Violation "$indexPath does not cross-link $doc" }
    }
}
if (-not (Test-Path -LiteralPath 'docs/watcher-contract.md')) {
    Violation 'CL1: docs/watcher-contract.md is absent -- the watcher has no contract document'
}

# --- 7. the three CAP-11A flakes keep a current state ------------------------
# The closure has to say where each of them stands NOW, including whether the
# instrumentation has been observed firing since it landed. "Instrumented" is
# not a state; "instrumented and not seen since" and "instrumented and seen on
# run N" are.
foreach ($flake in 'state=0', 'U3 uninstall residue', 'pinned-installer fetch') {
    if ($closure -inotmatch [regex]::Escape($flake)) {
        Violation "$closurePath does not carry the current state of the flake: $flake"
    }
}

# --- 8. the mORMot watcher decision, MEASURED rather than restated -----------
# CAP-11B ledgered a mORMot head watcher instead of building one. That is a
# decision the closure records, and this reads it back off the repository so a
# later shard cannot ship one without the row moving with it: `built` the day a
# workflow watches mORMot, `ledgered` while the ledger carries the reason and no
# such workflow exists, `undecided` if neither is true.
# A workflow that merely NAMES mORMot is the pinned fetch every leg does; what
# would make a watcher is a workflow or driver dedicated to watching it.
$mormotWorkflows = @(Get-ChildItem -Path .github/workflows -File -Filter '*.yml' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -imatch 'mormot' -and $_.Name -imatch 'watch' })
$mormotWorkflows += @(Get-ChildItem -Path test -Recurse -File -Filter 'watch_mormot*.ps1' -ErrorAction SilentlyContinue)
$ledgerText = [System.IO.File]::ReadAllText($ledgerPath)
$mormotLedgered = $ledgerText -imatch 'THE mORMot HEAD WATCHER IS LEDGERED RATHER THAN BUILT'
$facts['mormot_watcher'] = if ($mormotWorkflows.Count -gt 0) { 'built' }
                           elseif ($mormotLedgered) { 'ledgered' }
                           else { 'undecided' }
if ($facts['mormot_watcher'] -eq 'undecided') {
    Violation 'the mORMot head watcher is neither built nor ledgered with a reason -- CAP-11B owed a decision either way'
}

$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
New-Item -ItemType Directory -Force (Join-Path $repoRoot 'build/cap11b') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11b/ledger.json'),
    (($facts | ConvertTo-Json -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    Write-Host "[cap11b] CAP-11 ledger disposition FAILED: $($violations.Count) violation(s)"
    exit 1
}
Write-Host "[cap11b] phase ledger disposition PASS - $($entries.Count) entries, 0 orphans"
exit 0
