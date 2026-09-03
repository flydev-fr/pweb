# CAP-10C3 (CL2): every CAP-10C0/C1/C2 deferred item has exactly one
# disposition, and no orphan reaches the closure.
#
# A phase closure that says "the ledger was reviewed" is a sentence. This is
# the measurement behind it: `deferred-work.md` is parsed, every entry whose
# `source_spec` is a CAP-10C0, C1 or C2 spec is keyed, and the CAP-10C
# closure artifact must carry exactly those keys with a disposition from a
# CLOSED SET.
#
# THE KEY IS <shard>-<ordinal> PLUS THE FIRST EIGHT HEX OF THE SHA-256 OF
# THE ENTRY'S OWN summary LINE, and it is two things at once on purpose:
#
#   the ordinal    catches an entry that was ADDED or REMOVED - the ledger is
#                  append-only, so a C0/C1/C2 ordinal is stable, and a count
#                  that moved means somebody edited a closed shard's history
#   the digest     catches an entry that was REWORDED. A disposition is a
#                  judgement about a specific claim, and a claim that changed
#                  needs its judgement read again rather than inherited
#
# So an ORPHAN (an entry with no row), a STRAY (a row with no entry), a COUNT
# DRIFT and a SILENT REWORD are four different failures with four different
# messages, and none of them can be mistaken for the others.
#
# Checkout-only: no toolchain, no network, no display.
#
# Emits build/cap10c3/ledger.json and exits nonzero on any violation.
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
$closurePath = '_bmad-output/implementation-artifacts/cap10c-closure-artifact.md'
foreach ($p in $ledgerPath, $closurePath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}

# the three shards this closure disposes of, and the spec file that names
# each. A shard added here without its entries being disposed of would fail
# below rather than silently widen the scope.
$shards = [ordered]@{
    'spec-phase-10-cap10c0-run-supervision.md'    = 'C0'
    'spec-phase-10-cap10c1-lifecycle-pipeline.md' = 'C1'
    'spec-phase-10-cap10c2-react-dev-loop.md'     = 'C2'
}
# the CLOSED SET a disposition may come from. `RESOLVED` means the thing the
# entry describes is done; `RECORDED-ONLY` means it was never work - a
# measured platform limitation, a ratification, a lesson; the rest name the
# shard that inherits it. Anything else is a disposition nobody agreed on.
$allowed = @('RESOLVED', 'RECORDED-ONLY', 'CAP-10D', 'CAP-11', 'CAP-12',
             'LATER')

function Sha8([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return (-join ($sha.ComputeHash($bytes) |
            ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
    } finally { $sha.Dispose() }
}

# --- 1. the ledger's own C0/C1/C2 entries -----------------------------------
$entries = [ordered]@{}
$counts = @{ 'C0' = 0; 'C1' = 0; 'C2' = 0 }
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
$facts['ledger_c0'] = $counts['C0']
$facts['ledger_c1'] = $counts['C1']
$facts['ledger_c2'] = $counts['C2']
$facts['ledger_entries'] = $entries.Count
if ($entries.Count -eq 0) {
    Violation "$ledgerPath yielded no CAP-10C entry -- the parser or the ledger moved"
}

# --- 2. the closure artifact's disposition table ----------------------------
# one row per entry: | <key> | <digest8> | <DISPOSITION> | <reason> |
$rows = [ordered]@{}
$rowRx = '^\|\s*(C[012]-\d+)\s*\|\s*([0-9a-f]{8})\s*\|\s*([A-Z0-9-]+)\s*\|\s*(.+?)\s*\|\s*$'
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
        Violation ("LEDGER ORPHAN: $key has no disposition in the CAP-10C " +
            'closure artifact -- every C0/C1/C2 entry is either RESOLVED or ' +
            'assigned to a later shard with a reason')
        continue
    }
    $row = $rows[$key]
    if ($row.Digest -cne $entries[$key]) {
        $reworded++
        Violation ("LEDGER ENTRY REWORDED: $key is $($entries[$key]) in the " +
            "ledger and $($row.Digest) in the closure table (line " +
            "$($row.Line)) -- a claim that changed needs its disposition read " +
            'again, not inherited')
    }
    if ($allowed -notcontains $row.Disposition) {
        $badDisposition++
        Violation ("UNKNOWN DISPOSITION for ${key}: '$($row.Disposition)' " +
            "(line $($row.Line)) -- allowed: $($allowed -join ', ')")
    }
    if ($row.Reason.Length -lt 12) {
        Violation ("$key carries a disposition with no reason (line " +
            "$($row.Line)) -- a table of verdicts nobody justified is a table " +
            'nobody can check')
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

# a per-disposition census, for the evidence and for a reader
$census = [ordered]@{}
foreach ($d in $allowed) { $census[$d] = 0 }
foreach ($key in $rows.Keys) {
    $d = $rows[$key].Disposition
    if ($census.Contains($d)) { $census[$d]++ }
}
$facts['disposition_census'] = $census

# --- 4. the closure artifact says what a closure must say -------------------
$closure = [System.IO.File]::ReadAllText($closurePath)
foreach ($phrase in 'CAP-10D handoff', 'hosted', 'supersession',
                    'CAP-10C0', 'CAP-10C1', 'CAP-10C2', 'CAP-10C3') {
    if (-not $closure.Contains($phrase)) {
        Violation "$closurePath does not record: $phrase"
    }
}
# FOUR shards, four rows in the runs table. The three CLOSED shards must each
# cite a real hosted run id; CAP-10C3's own row is `pending` until the commit
# that carries this artifact has a green run of its own to name, exactly as
# CAP-10C1's and CAP-10C2's closures were written. A closure that had only
# three rows would be a closure of three shards, and the gate says which.
$runRows = @([regex]::Matches($closure,
    '(?m)^\|\s*(CAP-10C[0-3])\s*\|\s*`?([0-9a-f]{40}|pending)`?\s*\|\s*(\d{9,11}|pending)\s*\|'))
$facts['run_rows'] = $runRows.Count
$cited = @()
$pending = @()
foreach ($m in $runRows) {
    if ($m.Groups[3].Value -eq 'pending') { $pending += $m.Groups[1].Value }
    else { $cited += "$($m.Groups[1].Value)=$($m.Groups[3].Value)" }
}
$facts['hosted_runs_cited'] = $cited
$facts['hosted_runs_pending'] = $pending
if ($runRows.Count -ne 4) {
    Violation ("$closurePath carries $($runRows.Count) row(s) in its hosted-run " +
        'table; CAP-10C is four shards and its closure names four')
}
foreach ($shard in 'CAP-10C0', 'CAP-10C1', 'CAP-10C2') {
    if ($pending -contains $shard) {
        Violation ("$closurePath leaves $shard's hosted run `pending`: that " +
            'shard is closed and its green run is a fact')
    }
}
# and the docs index cross-links every contract document
$indexPath = 'docs/index.md'
if (-not (Test-Path -LiteralPath $indexPath)) {
    Violation "missing $indexPath"
} else {
    $index = [System.IO.File]::ReadAllText($indexPath)
    foreach ($doc in 'cli-contract.md', 'dev-contract.md',
                     'pipeline-contract.md', 'supervision-contract.md',
                     'template-contract.md', 'kernel.md') {
        if (-not $index.Contains($doc)) {
            Violation "$indexPath does not cross-link $doc"
        }
    }
}

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10c3 | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap10c3/ledger.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10C ledger disposition FAILED: $($violations.Count) violation(s)"
}
Write-Host ("[CAP-10C3] ledger disposition PASS - $($entries.Count) entries, " +
    '0 orphans')
