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
# IT ALSO RE-MEASURES THE FOUR FIX_NOW CLOSURES IN SOURCE. A backlog that only
# records that something was fixed is a document; one that fails when the fix
# is undone is a gate. The four checks are cheap, they read the tree rather
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
    'spec-phase-post-mvp-mormot-repin.md'                  = 'RP'
    'spec-phase-14-cap14a-bundler-csp-refusal.md'          = '14A'
    'spec-phase-14-cap14b-dev-console-surface.md'          = '14B'
    'spec-phase-15-cap15a-network-door-ratification.md'    = '15A'
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

# --- 5. the four FIX_NOW closures, re-measured in source ----------------------
# Recording that something was fixed is a document. Failing when it is undone
# is a gate. Each check names the row it protects.

# 8B-7: ONE RepoRootFromExecutable, and it is the shared one. The entry this
# closes recorded three copies and predicted drift; there were nine and one had
# drifted, so the count is the whole of the claim.
$rrHome = 'test/security/pweb.test.reporoot.pas'
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

# 7M0-6: no bare recursive delete in the six scripts the guard protects, and
# the guard itself is still there. The needles are built by concatenation so
# this file cannot satisfy its own sweep.
$rmGuard = 'tools/pwebrmtree.sh'
$rmProtected = @(
    'test/cap7l/build_cap7l.sh', 'test/cap7l/check_abi.sh',
    'test/cap7l/run_cap7l_gates.sh', 'test/cap7l/run_gui_matrix.sh',
    'test/cap7l/run_release_layout.sh', 'tools/build-webview-so.sh')
if (-not (Test-Path -LiteralPath $rmGuard)) {
    Violation "7M0-6 REGRESSED: the one guarded delete, $rmGuard, is gone"
}
$bareDeletes = @()
$unsourced = @()
foreach ($f in $rmProtected) {
    if (-not (Test-Path -LiteralPath $f)) { Violation "7M0-6: $f is missing"; continue }
    $t = [System.IO.File]::ReadAllText($f)
    if ($t -match ('(?m)(^|[^\w])rm\s+-' + 'rf')) { $bareDeletes += $f }
    if ($t -notmatch 'pweb' + 'rmtree\.sh') { $unsourced += $f }
}
$facts['rmtree_bare_deletes'] = ($bareDeletes -join ',')
$facts['rmtree_unsourced'] = ($unsourced -join ',')
if ($bareDeletes.Count -gt 0) {
    Violation ('7M0-6 REGRESSED: a bare recursive delete is back in ' +
        ($bareDeletes -join ', ') + ' -- every removal names its target AND the ' +
        'root that target must lie inside')
}
if ($unsourced.Count -gt 0) {
    Violation ('7M0-6 REGRESSED: ' + ($unsourced -join ', ') + " no longer source $rmGuard")
}

# --- 5b. the three CAP-15A claims, re-measured in the tree --------------------
# CAP-15A closes 15A-13 in source and asserts two things about test/cap15a in
# four documents. Section 5 above exists because "a backlog that only records
# that something was fixed is a document; one that fails when the fix is undone
# is a gate" - and that argument does not stop applying at the row this shard
# added. These live in their own section, keyed to 15A, rather than widening
# 7M0-6's $rmProtected list: that list is the exact claim a ratified FIX_NOW
# row makes, and growing it would re-word a closure instead of pinning a new
# one.
#
# All three are text reads. No toolchain, no compile, no run - which is what
# lets them sit here at all: 15A-12's ratified reason for keeping the
# instrument out of CI is that a RUN compiles a binary with a widened
# connect-src, and nothing below runs, builds or widens anything.
$cap15aRunner = 'test/cap15a/run_cap15a.sh'
$cap15aRunnerPs = 'test/cap15a/run_cap15a.ps1'

# 15A-13: the kept fixture does not carry the shape 7M0-6 closed. Same two
# assertions section 5 makes for its six files, on the file this shard added.
if (-not (Test-Path -LiteralPath $cap15aRunner)) {
    Violation "15A-13: $cap15aRunner is missing"
}
else {
    $c15 = [System.IO.File]::ReadAllText($cap15aRunner)
    # THE SWEEP IS LINE-AWARE, and that is a correction this check earned on
    # its first run: the runner's own comment explains which shape it replaced
    # and quotes it, so a whole-text regex reported a bare delete in a file
    # that has none. A line whose first non-space character is `#` is prose -
    # the rule the B1-8 check above already uses, for the same reason. The
    # needle is still built by concatenation, so this gate's text cannot
    # satisfy the sweep it performs.
    $needle15 = '(^|[^\w])rm\s+-' + 'rf'
    $bare15 = $false
    foreach ($ln in ($c15 -split "`r?`n")) {
        if ($ln -match '^\s*#') { continue }
        if ($ln -match $needle15) { $bare15 = $true; break }
    }
    $facts['cap15a_bare_delete'] = $bare15
    if ($bare15) {
        Violation ('15A-13 REGRESSED: a bare recursive delete is back in ' +
            "$cap15aRunner -- the kept fixture deletes through pweb" + "rmtree.sh")
    }
    if ($c15 -notmatch 'pweb' + 'rmtree\.sh') {
        Violation "15A-13 REGRESSED: $cap15aRunner no longer sources $rmGuard"
    }
}

# 15A-13, the Windows half: the sibling validates its delete target against an
# allowed root before removing it. The repository has no PowerShell equivalent
# of pwebrmtree.sh and thirty other test scripts delete unguarded, so this is
# not a repository-wide rule - it is the claim THIS fixture makes about itself.
if (-not (Test-Path -LiteralPath $cap15aRunnerPs)) {
    Violation "15A-13: $cap15aRunnerPs is missing"
}
else {
    $c15ps = [System.IO.File]::ReadAllText($cap15aRunnerPs)
    if ($c15ps -notmatch 'Assert-' + 'UnderBuildRoot') {
        Violation ("15A-13 REGRESSED: $cap15aRunnerPs no longer validates its " +
            'delete target against an allowed root before removing it')
    }
    # and it still parses, which is the cheap half of "the runner is written"
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $cap15aRunnerPs).Path, [ref]$null, [ref]$errs)
    $facts['cap15a_ps_parse_errors'] = $(if ($null -eq $errs) { 0 } else { $errs.Count })
    if ($facts['cap15a_ps_parse_errors'] -gt 0) {
        Violation ("15A-13: $cap15aRunnerPs does not parse -- " +
            $errs[0].Message)
    }
}

# 15A-12: NEVER A CI STEP. The artifact's FREEZE, test/cap15a/README.md, the
# ledger row and its disposition all say a run compiles a widened CSP and must
# not be a gate. Four documents asserting it and nothing enforcing it is the
# shape this repository refuses everywhere else, so the claim is pinned: no
# workflow, composite action or CI input names the directory.
$ciNamers = @()
if (Test-Path -LiteralPath '.github') {
    foreach ($f in (Get-ChildItem -Path '.github' -Recurse -File -ErrorAction SilentlyContinue)) {
        if ([System.IO.File]::ReadAllText($f.FullName) -match ('test/cap' + '15a')) {
            $ciNamers += $f.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
        }
    }
}
$facts['cap15a_named_in_ci'] = ($ciNamers -join ',')
if ($ciNamers.Count -gt 0) {
    Violation ('15A-12 REGRESSED: ' + ($ciNamers -join ', ') + ' names ' +
        'test/cap15a -- a run of that instrument compiles a binary whose ' +
        'connect-src has been widened, and a gate that compiles a widened CSP ' +
        'is a gate that can normalise one')
}

# reopening condition 1 of the public network decision costs "one run per macOS
# architecture", and that estimate is only true while the instrument still
# fits the tree it reads. The shim rule is the one coupling a CAP-15B commit
# can silently break: both runners substitute the literal connect-src term in
# the shipped policy and assert it occurs EXACTLY ONCE. Reformat or re-space
# that constant and the assertion dies on a macOS host, after the runner has
# been paid for - the CAP-7M0 lesson, met from the other side.
$cspNeedle = "'connect-src ''self''; "
$policySrc = 'src/security/pweb.navigation.policy.pas'
if (-not (Test-Path -LiteralPath $policySrc)) {
    Violation "15A-12: $policySrc is missing"
}
else {
    $pt = [System.IO.File]::ReadAllText($policySrc)
    $hits = 0; $at = 0
    while (($at = $pt.IndexOf($cspNeedle, $at)) -ge 0) { $hits++; $at += $cspNeedle.Length }
    $facts['cap15a_shim_needle_hits'] = $hits
    if ($hits -ne 1) {
        Violation ("15A-12: the CAP-15A shim needle occurs $hits time(s) in " +
            "$policySrc, not once -- both runners die on that assertion, so " +
            'the "one run per macOS architecture" cost in reopening condition 1 ' +
            'has quietly become "repair the instrument first"')
    }
}

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
