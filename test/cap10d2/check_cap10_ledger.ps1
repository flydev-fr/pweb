# CAP-10D2 (CL1-CL4): the PHASE-WIDE ledger disposition, the SPEC's CAP-10
# acceptance table, and the eleven hosted runs.
#
# The CAP-10C3 gate did this for three shards. This is the same measurement
# widened to the whole of CAP-10 - ten closed shards plus this one - because a
# phase closure that says "the ledger was reviewed" is a sentence and this is
# what stands behind it.
#
# THE KEY IS <shard>-<ordinal> PLUS THE FIRST EIGHT HEX OF THE SHA-256 OF THE
# ENTRY'S OWN summary LINE, exactly as check_cap10c_ledger.ps1 defines it:
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
# SPEC's CAP-10 acceptance, line by line, each MET with cited evidence or
# DEVIATED with a named ratified reason; eleven hosted runs cited; the CAP-11
# handoff; and docs/index.md cross-linking every contract document including
# the one this shard adds.
#
# Checkout-only: no toolchain, no network, no display.
#
# Emits build/cap10d2/ledger.json and exits nonzero on any violation.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}

$ledgerPath = '_bmad-output/implementation-artifacts/deferred-work.md'
$closurePath = '_bmad-output/implementation-artifacts/cap10-closure-artifact.md'
$specPath = '_bmad-output/specs/spec-pweb/SPEC.md'
foreach ($p in $ledgerPath, $closurePath, $specPath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}

# the ELEVEN shards this closure disposes of, and the spec file that names
# each. A shard added here without its entries being disposed of fails below
# rather than silently widening the scope.
$shards = [ordered]@{
    'spec-phase-10-cap10a-cli-foundation.md'         = '10A'
    'spec-phase-10-cap10b0-scaffold-engine.md'       = 'B0'
    'spec-phase-10-cap10b1-react-scaffold.md'        = 'B1'
    'spec-phase-10-cap10b2-pas2js-scaffold.md'       = 'B2'
    'spec-phase-10-cap10c0-run-supervision.md'       = 'C0'
    'spec-phase-10-cap10c1-lifecycle-pipeline.md'    = 'C1'
    'spec-phase-10-cap10c2-react-dev-loop.md'        = 'C2'
    'spec-phase-10-cap10c3-pas2js-dev-loop.md'       = 'C3'
    'spec-phase-10-cap10d0-public-build-command.md'  = 'D0'
    'spec-phase-10-cap10d1-distributable-artifacts.md' = 'D1'
    'spec-phase-10-cap10d2-sdk-distribution.md'      = 'D2'
}
# the CLOSED SET a disposition may come from. `RESOLVED` means the thing the
# entry describes is done; `RECORDED-ONLY` means it was never work - a
# measured platform limitation, a ratification, a lesson; the rest name the
# shard that inherits it. Anything else is a disposition nobody agreed on.
$allowed = @('RESOLVED', 'RECORDED-ONLY', 'CAP-11', 'CAP-12', 'CAP-13',
             'LATER')

function Sha8([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return (-join ($sha.ComputeHash($bytes) |
            ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
    } finally { $sha.Dispose() }
}

# --- 1. the ledger's own CAP-10 entries -------------------------------------
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
    Violation "$ledgerPath yielded no CAP-10 entry -- the parser or the ledger moved"
}

# --- 2. the closure artifact's disposition table ----------------------------
# one row per entry: | <key> | <digest8> | <DISPOSITION> | <reason> |
$closure = [System.IO.File]::ReadAllText($closurePath)
$rows = [ordered]@{}
$rowRx = '^\|\s*((?:10A|B0|B1|B2|C0|C1|C2|C3|D0|D1|D2)-\d+)\s*\|\s*([0-9a-f]{8})\s*\|\s*([A-Z0-9-]+)\s*\|\s*(.+?)\s*\|\s*$'
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($closurePath)) {
    $lineNo++
    if ($line -match $rowRx) {
        $key = $Matches[1]
        if ($rows.Contains($key)) {
            Violation ("the closure table disposes of $key TWICE (line " +
                "$lineNo): one entry, one judgement")
            continue
        }
        $rows[$key] = [pscustomobject]@{
            Digest = $Matches[2]
            Disposition = $Matches[3]
            Reason = $Matches[4]
            Line = $lineNo
        }
    }
}
$facts['closure_rows'] = $rows.Count

# --- 3. orphan, stray, reword, and the closed set ---------------------------
$orphans = 0
$reworded = 0
$badDisposition = 0
foreach ($key in $entries.Keys) {
    if (-not $rows.Contains($key)) {
        $orphans++
        Violation ("LEDGER ORPHAN: $key has no disposition in the CAP-10 " +
            'closure artifact -- every CAP-10 entry is either RESOLVED, ' +
            'RECORDED-ONLY, or assigned to a later phase with a reason')
        continue
    }
    $row = $rows[$key]
    if ($row.Digest -cne $entries[$key]) {
        $reworded++
        Violation ("LEDGER ENTRY REWORDED: $key is $($entries[$key]) in the " +
            "ledger and $($row.Digest) in the closure table (line " +
            "$($row.Line)) -- a claim that changed needs its disposition " +
            'read again, not inherited')
    }
    if ($allowed -notcontains $row.Disposition) {
        $badDisposition++
        Violation ("UNKNOWN DISPOSITION for ${key}: '$($row.Disposition)' " +
            "(line $($row.Line)) -- allowed: $($allowed -join ', ')")
    }
    if ($row.Reason.Length -lt 12) {
        Violation ("$key carries a disposition with no reason (line " +
            "$($row.Line)) -- a table of verdicts nobody justified is a " +
            'table nobody can check')
    }
}
foreach ($key in $rows.Keys) {
    if (-not $entries.Contains($key)) {
        Violation ("STRAY DISPOSITION: the closure table names $key (line " +
            "$($rows[$key].Line)), which the ledger does not carry")
    }
}
$facts['ledger_orphans'] = $orphans
$facts['ledger_reworded'] = $reworded
$facts['ledger_unknown_disposition'] = $badDisposition

$census = [ordered]@{}
foreach ($d in $allowed) { $census[$d] = 0 }
foreach ($key in $rows.Keys) {
    $d = $rows[$key].Disposition
    if ($census.Contains($d)) { $census[$d]++ }
}
$facts['disposition_census'] = $census

# --- 4. the SPEC's CAP-10 acceptance, line by line --------------------------
# The SPEC states CAP-10 as one intent and one success sentence. The closure
# breaks that sentence into its CLAUSES and answers each with evidence or
# with a named ratified deviation, in a table of the shape:
#     | <clause id> | MET | <evidence> |
#     | <clause id> | DEVIATED | <the ratified reason> |
$specText = [System.IO.File]::ReadAllText($specPath)
$specCap10 = ''
if ($specText -match '(?s)- \*\*CAP-10\*\*(.*?)- \*\*CAP-11\*\*') {
    $specCap10 = $Matches[1].Trim()
}
$facts['spec_cap10_present'] = [bool]($specCap10 -ne '')
# the SPEC writes its acceptance as a bullet list; the leading `- ` is a
# markdown marker and not part of the sentence, so the comparison is over the
# SENTENCE. Everything after it is compared byte for byte.
$intentLine = ''
if ($specCap10 -ne '') {
    $intentLine = $specCap10.Split("`n")[0].Trim()
    if ($intentLine.StartsWith('- ')) { $intentLine = $intentLine.Substring(2) }
}
$facts['spec_intent_line'] = $intentLine
if ($specCap10 -eq '') {
    Violation "$specPath carries no CAP-10 acceptance block"
} elseif (-not $closure.Contains($intentLine)) {
    # the closure quotes the SPEC's own intent line VERBATIM, so a reader can
    # see that the table answers the acceptance that was actually written
    Violation ('the closure artifact does not quote the SPEC CAP-10 intent ' +
        'line verbatim')
}
$specRows = @([regex]::Matches($closure,
    '(?m)^\|\s*(A\d+)\s*\|\s*(MET|DEVIATED)\s*\|\s*(.+?)\s*\|\s*$'))
$met = 0
$deviated = 0
foreach ($m in $specRows) {
    if ($m.Groups[2].Value -eq 'MET') { $met++ } else { $deviated++ }
    if ($m.Groups[3].Value.Length -lt 20) {
        Violation ("SPEC acceptance $($m.Groups[1].Value) carries no evidence")
    }
}
$facts['spec_lines_met'] = $met
$facts['spec_lines_deviated'] = $deviated
$facts['spec_lines_total'] = $specRows.Count
if ($specRows.Count -lt 6) {
    Violation ("the closure's SPEC acceptance table has $($specRows.Count) " +
        'row(s); CAP-10 states one intent and three success clauses, and the ' +
        'closure answers each of them plus the constraints CAP-10 touches')
}

# --- 5. the eleven hosted runs, and the handoff -----------------------------
$runRows = @([regex]::Matches($closure,
    '(?m)^\|\s*(CAP-10(?:A|B0|B1|B2|C0|C1|C2|C3|D0|D1|D2))\s*\|\s*`?([0-9a-f]{7,40}|pending)`?\s*\|\s*(\d{9,11}|pending)\s*\|'))
$facts['run_rows'] = $runRows.Count
$cited = @()
$pending = @()
foreach ($m in $runRows) {
    if ($m.Groups[3].Value -eq 'pending') { $pending += $m.Groups[1].Value }
    else { $cited += "$($m.Groups[1].Value)=$($m.Groups[3].Value)" }
}
$facts['hosted_runs_cited'] = $cited.Count
$facts['hosted_runs'] = $cited -join ','
$facts['hosted_runs_pending'] = $pending -join ','
if ($runRows.Count -ne 11) {
    Violation ("$closurePath carries $($runRows.Count) row(s) in its " +
        'hosted-run table; CAP-10 is eleven shards and its closure names eleven')
}
foreach ($shard in 'CAP-10A', 'CAP-10B0', 'CAP-10B1', 'CAP-10B2', 'CAP-10C0',
                   'CAP-10C1', 'CAP-10C2', 'CAP-10C3', 'CAP-10D0', 'CAP-10D1') {
    if ($pending -contains $shard) {
        Violation ("$closurePath leaves $shard's hosted run ``pending``: that " +
            'shard is closed and its green run is a fact')
    }
}
foreach ($phrase in 'CAP-11 handoff', 'supersession', 'must not touch',
                    'known limitation') {
    if (-not $closure.Contains($phrase)) {
        Violation "$closurePath does not record: $phrase"
    }
}

# --- 6. the docs index cross-links every contract ---------------------------
$indexPath = 'docs/index.md'
if (-not (Test-Path -LiteralPath $indexPath)) {
    Violation "missing $indexPath"
} else {
    $index = [System.IO.File]::ReadAllText($indexPath)
    foreach ($doc in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') `
            -Filter '*-contract.md' -File | ForEach-Object { $_.Name })) {
        if (-not $index.Contains($doc)) {
            Violation "$indexPath does not cross-link $doc"
        }
    }
    foreach ($doc in 'kernel.md', 'third-party-licenses.md', 'sdk-contract.md') {
        if (-not $index.Contains($doc)) {
            Violation "$indexPath does not cross-link $doc"
        }
    }
}
if (-not (Test-Path -LiteralPath 'docs/sdk-contract.md')) {
    Violation 'CL4: docs/sdk-contract.md is absent'
}

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force (Join-Path $repoRoot 'build/cap10d2') | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap10d2/ledger.json'),
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10 ledger disposition FAILED: $($violations.Count) violation(s)"
}
Write-Host ("[CAP-10D2] phase ledger disposition PASS - $($entries.Count) " +
    'entries, 0 orphans')
