# THE BACKLOG GATE: docs/backlog.md disposes of every ledger entry, exactly
# once, with a verdict from a closed set - and every FIX_NOW row names a
# commit that really closed it.
#
# `_bmad-output/implementation-artifacts/deferred-work.md` is append-only and
# says what was found. `docs/backlog.md` says what is OWED. A worklist derived
# from a ledger is worthless the moment the two drift, and they drift silently:
# an entry appended with no verdict is invisible, and an entry REWORDED under
# an inherited verdict is worse than invisible, because the table then asserts
# a judgement about a claim nobody made.
#
# THE KEY IS <shard>-<ordinal> PLUS THE FIRST EIGHT HEX OF THE SHA-256 OF THE
# ENTRY'S OWN summary LINE, which is the key test/cap10d2/check_cap10_ledger.ps1
# and test/cap11b/check_cap11_ledger.ps1 already use, computed the same way. It
# is deliberately the same: this gate covers every shard those two cover plus
# the 134 entries neither does, so the three tables are one vocabulary and a
# row can be compared across them by eye.
#
#   the ordinal   catches an entry ADDED or REMOVED
#   the digest    catches an entry REWORDED
#
# so an ORPHAN, a STRAY, a COUNT DRIFT and a SILENT REWORD are four different
# failures with four different messages.
#
# AN UNMAPPED SOURCE SPEC IS A REFUSAL, not a skip. The shard map below is the
# whole of what this gate knows how to key; a ledger entry citing a spec that
# is not in it would otherwise be dropped on the floor, which is exactly the
# vacuous-pass shape this repository has measured and refused elsewhere.
#
# IT ALSO RE-MEASURES THE THREE FIX_NOW CLOSURES IN SOURCE. A backlog that only
# records that something was fixed is a document; one that fails when the fix
# is undone is a gate. The three checks are cheap, they read the tree rather
# than the table, and each names the row it protects.
#
# Checkout-only: no toolchain, no network, no display. Needs `git` and the
# repository's history, because a commit id nobody can resolve is not evidence.
# Emits build/backlog/backlog.json and exits nonzero on any violation.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) { $violations.Add($Text); Write-Host "VIOLATION: $Text" }

$ledgerPath  = '_bmad-output/implementation-artifacts/deferred-work.md'
# THE DISPOSITION TABLE IS DATA AND LIVES BESIDE THE GATE, which is the shape
# CAP-11A already uses for `ci-legacy-inventory.tsv` and its siblings. 338 rows
# of key, digest, verdict, owner, commit and reason are a machine's table, and
# putting them in a prose document put that document 60 KB over the
# repository's own documentation budget for a reader who wants the 45 rows that
# are open. `docs/backlog.md` is the human half and carries those 45; this file
# is the whole of the mapping, and the two cannot disagree because the document
# is written from it.
$backlogPath = 'test/backlog/dispositions.tsv'
$docPath     = 'docs/backlog.md'
foreach ($p in $ledgerPath, $backlogPath, $docPath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}

# The shard code per source spec. `10A`, `B0`..`D2`, `11A` and `11B` are the
# codes the two existing ledger gates use and are reproduced unchanged, so a
# key means the same thing in all three tables; the rest are introduced here
# for the phases that never had a closure table.
$shards = [ordered]@{
    'spec-phase-0-contracts.md'                            = 'P0'
    'spec-phase-1-cap1-webview-binding.md'                 = 'P1'
    'spec-phase-4-cap4-asset-system.md'                    = 'P4'
    'spec-phase-5-cap5-frontend-sdks.md'                   = 'P5'
    'spec-phase-6-cap6-release-bundle.md'                  = 'P6'
    'spec-phase-6-cap6-bundler-utf16-argv.md'              = 'P6U'
    'spec-phase-6b0-webview2-runtime-foundation.md'        = '6B0'
    'spec-phase-6b1-normal-evergreen-installer.md'         = '6B1'
    'spec-phase-6b2-offline-evergreen-installer.md'        = '6B2'
    'spec-phase-6b3-fixed-runtime-profile.md'              = '6B3'
    'spec-phase-6b4-windows-profile-integration.md'        = '6B4'
    'spec-phase-7-cap7m0-macos-feasibility.md'             = '7M0'
    'spec-phase-7-cap7m1-macos-platform-adapter.md'        = '7M1'
    'spec-phase-7-cap7m2-macos-release-apps.md'            = '7M2'
    'spec-phase-7-cap7f-final-integration.md'              = '7F'
    'spec-phase-8-cap8a-capability-policy-core.md'         = '8A'
    'spec-phase-8-cap8b-privileged-navigation.md'          = '8B'
    'spec-phase-8-cap8c-multi-principal-integration.md'    = '8C'
    'spec-phase-9-cap9a-quickjs-invocation-foundation.md'  = '9A'
    'spec-phase-9-cap9b1-quickjs-package-module-loader.md' = '9B1'
    'spec-phase-9-cap9b2-quickjs-plugin-lifecycle.md'      = '9B2'
    'spec-phase-9-cap9c1-quickjs-release-package.md'       = '9C1'
    'spec-phase-9-cap9c2-quickjs-gui-release.md'           = '9C2'
    'spec-phase-10-cap10a-cli-foundation.md'               = '10A'
    'spec-phase-10-cap10b0-scaffold-engine.md'             = 'B0'
    'spec-phase-10-cap10b1-react-scaffold.md'              = 'B1'
    'spec-phase-10-cap10b2-pas2js-scaffold.md'             = 'B2'
    'spec-phase-10-cap10c0-run-supervision.md'             = 'C0'
    'spec-phase-10-cap10c1-lifecycle-pipeline.md'          = 'C1'
    'spec-phase-10-cap10c2-react-dev-loop.md'              = 'C2'
    'spec-phase-10-cap10c3-pas2js-dev-loop.md'             = 'C3'
    'spec-phase-10-cap10d0-public-build-command.md'        = 'D0'
    'spec-phase-10-cap10d1-distributable-artifacts.md'     = 'D1'
    'spec-phase-10-cap10d2-sdk-distribution.md'            = 'D2'
    'spec-phase-10-cap10e-kernel-image-path.md'            = '10E'
    'spec-phase-11-cap11a-ci-matrix.md'                    = '11A'
    'spec-phase-11-cap11b-upstream-watcher.md'             = '11B'
}

# THE CLOSED SET. `CLOSED` means the thing the entry describes is done;
# `ACCEPTED` means nothing is owed - a measured limitation, a ratification or
# a lesson; `ROADMAP` is real work with a named owner; `UPSTREAM` belongs to a
# third-party project; `FIX_NOW` was closed by the triage and must prove it.
$allowed = @('FIX_NOW', 'ROADMAP', 'UPSTREAM', 'ACCEPTED', 'CLOSED')

function Sha8([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
    } finally { $sha.Dispose() }
}

# --- 1. the ledger, keyed -----------------------------------------------------
$entries = [ordered]@{}
$counts = [ordered]@{}
foreach ($v in $shards.Values) { $counts[$v] = 0 }
$current = $null
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
    $lineNo++
    if ($line -match '^- source_spec: `[^`]*/([^/`]+)`\s*$') {
        $file = $Matches[1]
        if (-not $shards.Contains($file)) {
            Violation ("UNMAPPED SOURCE SPEC at $ledgerPath line ${lineNo}: $file -- " +
                'this gate cannot key an entry whose spec it does not know, and ' +
                'a spec it silently skipped would be a backlog nobody notices is short')
            $current = $null
            continue
        }
        $current = $shards[$file]
        continue
    }
    if ($line -match '^- source_spec:') {
        Violation "UNPARSED source_spec line at $ledgerPath line ${lineNo}"
        $current = $null
        continue
    }
    if (($null -ne $current) -and ($line -match '^  summary: (.*)$')) {
        $counts[$current]++
        $entries["$current-$($counts[$current])"] = Sha8 $Matches[1]
    }
}
$facts['ledger_entries'] = $entries.Count
if ($entries.Count -eq 0) {
    Violation "$ledgerPath yielded no entry -- the parser or the ledger moved"
}

# --- 2. the disposition table -------------------------------------------------
# six tab-separated columns, a header line, one row per entry:
#   key  digest  verdict  owner  commit  reason
$rows = [ordered]@{}
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($backlogPath)) {
    $lineNo++
    if ($line -eq '') { continue }
    if ($lineNo -eq 1) {
        if ($line -ne "key`tdigest`tverdict`towner`tcommit`treason") {
            Violation "$backlogPath does not open with the ratified header row"
        }
        continue
    }
    $c = $line -split "`t"
    if ($c.Count -ne 6) {
        Violation "$backlogPath line ${lineNo} has $($c.Count) column(s), not 6"
        continue
    }
    $key = $c[0]
    if ($rows.Contains($key)) {
        Violation "$backlogPath disposes of $key TWICE (line $lineNo): one entry, one verdict"
        continue
    }
    if ($c[1] -notmatch '^[0-9a-f]{8}$') {
        Violation "$backlogPath line ${lineNo}: '$($c[1])' is not an eight-hex digest"
        continue
    }
    if ($c[4] -notmatch '^([0-9a-f]{7,40}|-)$') {
        Violation "$backlogPath line ${lineNo}: '$($c[4])' is neither a commit id nor '-'"
        continue
    }
    $rows[$key] = [pscustomobject]@{
        Digest = $c[1]; Verdict = $c[2]; Owner = $c[3]
        Commit = $c[4]; Reason = $c[5]; Line = $lineNo
    }
}
$facts['backlog_rows'] = $rows.Count

# --- 3. orphan, stray, reword, and the closed set -----------------------------
$orphans = 0; $reworded = 0; $badVerdict = 0
foreach ($key in $entries.Keys) {
    if (-not $rows.Contains($key)) {
        $orphans++
        Violation ("LEDGER ORPHAN: $key has no row in $backlogPath -- every entry is " +
            'CLOSED, ACCEPTED, or open with a bucket, an owner and a reason')
        continue
    }
    $row = $rows[$key]
    if ($row.Digest -cne $entries[$key]) {
        $reworded++
        Violation ("LEDGER ENTRY REWORDED: $key is $($entries[$key]) in the ledger and " +
            "$($row.Digest) in $backlogPath (line $($row.Line)) -- a claim that changed " +
            'needs its verdict read again, not inherited')
    }
    if ($allowed -notcontains $row.Verdict) {
        $badVerdict++
        Violation "UNKNOWN VERDICT for ${key}: '$($row.Verdict)' (line $($row.Line)) -- allowed: $($allowed -join ', ')"
    }
    if ($row.Owner.Length -lt 4) {
        Violation ("$key names no owner (line $($row.Line)) -- an open item nobody owns " +
            'is an item nobody will do')
    }
    if ($row.Reason.Length -lt 12) {
        Violation ("$key carries a verdict with no reason (line $($row.Line)) -- a table of " +
            'verdicts nobody justified is a table nobody can check')
    }
}
foreach ($key in $rows.Keys) {
    if (-not $entries.Contains($key)) {
        Violation "STRAY ROW: $backlogPath names $key (line $($rows[$key].Line)), which the ledger does not carry"
    }
}
$facts['orphans'] = $orphans
$facts['reworded'] = $reworded
$facts['unknown_verdict'] = $badVerdict

$census = [ordered]@{}
foreach ($v in $allowed) { $census[$v] = 0 }
foreach ($key in $rows.Keys) { if ($census.Contains($rows[$key].Verdict)) { $census[$rows[$key].Verdict]++ } }
$facts['census'] = $census
# OPEN means WORK IS OWED, which is why ACCEPTED is not in the sum: an entry
# whose honest answer is a measurement has an owner only if somebody wants to
# change the answer. The document says forty-five are open and this is the
# arithmetic behind that number, so the two cannot drift apart.
$open = 0
foreach ($v in 'FIX_NOW', 'ROADMAP', 'UPSTREAM') { $open += $census[$v] }
$facts['open_work'] = $open
$facts['accepted_no_work_owed'] = $census['ACCEPTED']

# --- 4. every FIX_NOW names a commit, and every other row names none -----------
# A FIX_NOW row is the one kind that asserts work was DONE in this repository,
# so it is the one kind that can be checked against the repository. A commit id
# that resolves to nothing is a claim nobody can follow.
$shallow = 'unknown'
try { $shallow = (& git rev-parse --is-shallow-repository 2>$null | Out-String).Trim() } catch { $shallow = 'unknown' }
$facts['shallow_repository'] = $shallow
if ($shallow -eq 'true') {
    Violation ('the checkout is SHALLOW, so a closing commit cannot be resolved -- ' +
        'this gate refuses rather than recording an unverified pass; fetch the ' +
        'history (actions/checkout fetch-depth: 0) before running it')
}
$fixNowVerified = 0
foreach ($key in $rows.Keys) {
    $row = $rows[$key]
    if ($row.Verdict -eq 'FIX_NOW') {
        if ($row.Commit -eq '-') {
            Violation "FIX_NOW $key names no closing commit (line $($row.Line))"
            continue
        }
        if ($shallow -eq 'true') { continue }
        $null = & git cat-file -e "$($row.Commit)^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Violation ("FIX_NOW $key names commit $($row.Commit) (line $($row.Line)), " +
                'which this repository does not carry')
            continue
        }
        & git merge-base --is-ancestor $row.Commit HEAD 2>$null
        if ($LASTEXITCODE -ne 0) {
            Violation ("FIX_NOW $key names commit $($row.Commit) (line $($row.Line)), " +
                'which is not an ancestor of HEAD -- a closure on a branch nobody ' +
                'merged has not closed anything here')
            continue
        }
        $fixNowVerified++
    }
    elseif ($row.Commit -ne '-') {
        Violation ("$key is $($row.Verdict) and names commit $($row.Commit) (line " +
            "$($row.Line)) -- only a FIX_NOW closes something in this repository")
    }
}
$facts['fix_now_commits_verified'] = $fixNowVerified

# --- 4b. the human document carries every open row, and claims the right counts
# `docs/backlog.md` is written FROM the table above, so the two agreeing is a
# property rather than a coincidence - but only until somebody edits one of
# them. An open item that fell out of the document is an item nobody reads,
# which is the failure this whole exercise exists to prevent.
$doc = [System.IO.File]::ReadAllText($docPath)
$missingFromDoc = @()
foreach ($key in $rows.Keys) {
    if ($rows[$key].Verdict -notin @('FIX_NOW', 'ROADMAP', 'UPSTREAM')) { continue }
    if ($doc -notmatch ('(?m)\|\s*`' + [regex]::Escape($key) + '`\s*\|')) { $missingFromDoc += $key }
}
$facts['open_rows_missing_from_doc'] = ($missingFromDoc -join ',')
if ($missingFromDoc.Count -gt 0) {
    Violation ("$docPath does not carry $($missingFromDoc.Count) open row(s): " +
        ($missingFromDoc -join ', ') + ' -- the document is the half a human reads')
}
foreach ($claim in @(
        @{ Text = "| ``FIX_NOW`` | $($census['FIX_NOW']) |";  What = 'FIX_NOW' }
        @{ Text = "| ``UPSTREAM`` | $($census['UPSTREAM']) |"; What = 'UPSTREAM' }
        @{ Text = "| ``ROADMAP`` | $($census['ROADMAP']) |";  What = 'ROADMAP' }
        @{ Text = "| ``ACCEPTED`` | $($census['ACCEPTED']) |"; What = 'ACCEPTED' }
        @{ Text = "| ``CLOSED`` | $($census['CLOSED']) |";    What = 'CLOSED' })) {
    if (-not $doc.Contains($claim.Text)) {
        Violation ("$docPath does not state the measured $($claim.What) count " +
            "($($census[$claim.What])) -- a summary that disagrees with its own " +
            'table is worse than no summary')
    }
}

# --- 5. the three FIX_NOW closures, re-measured in source ---------------------
# Recording that something was fixed is a document. Failing when it is undone
# is a gate. Each check names the row it protects.

# 8B-7: ONE RepoRootFromExecutable, and it is the shared one. The entry this
# closes recorded three copies and predicted drift; there were nine and one had
# drifted, so the count is the whole of the claim.
$rrHome = 'test/core/pweb.test.reporoot.pas'
$rrSites = @()
foreach ($d in 'src', 'tools', 'test', 'examples') {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in (Get-ChildItem -Path $d -Recurse -File -Include '*.pas', '*.inc', '*.lpr' -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
        # the DEFINITION, not a call: the needle is built by concatenation so
        # this gate's own text cannot satisfy the sweep it performs
        if ([System.IO.File]::ReadAllText($f.FullName) -match
            ('(?m)^function ' + 'RepoRootFromExecutable' + ':')) { $rrSites += $rel }
    }
}
$facts['reporoot_definitions'] = ($rrSites -join ',')
if ($rrSites.Count -ne 1) {
    Violation ("8B-7 REGRESSED: RepoRootFromExecutable is defined in $($rrSites.Count) " +
        "place(s) [$($rrSites -join ', ')] -- the row says one shared helper")
}
elseif ($rrSites[0] -ne $rrHome) {
    Violation "8B-7 REGRESSED: the one definition is $($rrSites[0]), not $rrHome"
}

# B2-15: both template .gitattributes cover *.cfg, and they stay byte-identical.
$gaReact = 'tools/templates/react/gitattributes'
$gaPas2js = 'tools/templates/pas2js/gitattributes'
if ((Test-Path -LiteralPath $gaReact) -and (Test-Path -LiteralPath $gaPas2js)) {
    $rb = [System.IO.File]::ReadAllBytes($gaReact)
    $pb = [System.IO.File]::ReadAllBytes($gaPas2js)
    $identical = ($rb.Length -eq $pb.Length)
    if ($identical) {
        for ($i = 0; $i -lt $rb.Length; $i++) { if ($rb[$i] -ne $pb[$i]) { $identical = $false; break } }
    }
    $facts['template_gitattributes_identical'] = $identical
    if (-not $identical) {
        Violation ('B2-15 REGRESSED: the two template .gitattributes are no longer ' +
            'byte-identical, which is the property their parity gate ratified')
    }
    $covers = ([System.IO.File]::ReadAllText($gaReact) -match '(?m)^\*\.cfg\s+text\s+eol=lf\s*$')
    $facts['template_gitattributes_covers_cfg'] = $covers
    if (-not $covers) {
        Violation ('B2-15 REGRESSED: the template .gitattributes no longer opts *.cfg ' +
            'back into text, so a generated pas2js.cfg is binary again')
    }
}
else { Violation 'B2-15: a template .gitattributes is missing' }

# B1-8: the CAP-10B1 gate no longer captures through Start-Process redirection
# (which drops empty lines on Unix), and the aggregate compares the field again.
$b1Gate = 'test/cap10b1/run_cap10b1_gates.ps1'
if (Test-Path -LiteralPath $b1Gate) {
    $t = [System.IO.File]::ReadAllText($b1Gate)
    # a REAL call, not the paragraph that explains why there is none: a line
    # whose first non-space character is `#` is prose
    $lossy = ($t -match '(?m)^\s*[^#\r\n]*Start-\w*Process[^\r\n]*-RedirectStandardOutput')
    $facts['b1_gate_lossy_capture'] = $lossy
    if ($lossy) {
        Violation ('B1-8 REGRESSED: ' + $b1Gate + ' captures stdout through ' +
            'Start-Process redirection again, which drops every empty line on Unix')
    }
}
else { Violation "B1-8: $b1Gate is missing" }
$agg = 'test/cap7f/check_cap7f_aggregate.ps1'
if (Test-Path -LiteralPath $agg) {
    # THE ANCHOR IS THE LIST, NOT THE FILE, and the first draft of this check
    # got that wrong in a way its own negative leg caught: the aggregator keeps
    # `$required` (present on every target) and `$equalityFields` (EQUAL across
    # four) in one file, and both names appear in both lists - so a needle
    # matched anywhere in the text reported `true` for a field removed from the
    # comparison. That is the CAP-10D0 lesson about two lists that read alike
    # and mean opposite things, met from the checking side.
    $aggText = [System.IO.File]::ReadAllText($agg)
    $eqAt = $aggText.IndexOf('$equalityFields')
    $needle = "'" + 'create_help_digest' + "'\s*,\s*'" + 'create_help_bytes' + "'"
    $compared = ($eqAt -ge 0) -and
                ($aggText.Substring($eqAt) -match $needle)
    $facts['create_help_compared'] = $compared
    if (-not $compared) {
        Violation ('B1-8 REGRESSED: create_help_digest and create_help_bytes are no ' +
            "longer in the four-target equality list of $agg")
    }
}
else { Violation "B1-8: $agg is missing" }

# --- 6. verdict ---------------------------------------------------------------
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
New-Item -ItemType Directory -Force (Join-Path $repoRoot 'build/backlog') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/backlog/backlog.json'),
    (($facts | ConvertTo-Json -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    Write-Host "[backlog] backlog gate FAILED: $($violations.Count) violation(s)"
    exit 1
}
Write-Host ("[backlog] PASS - $($entries.Count) ledger entries, 0 orphans, " +
    "$open open ($($census['FIX_NOW']) fix-now, $($census['ROADMAP']) roadmap, " +
    "$($census['UPSTREAM']) upstream); $($census['ACCEPTED']) accepted, " +
    "$($census['CLOSED']) closed")
exit 0
