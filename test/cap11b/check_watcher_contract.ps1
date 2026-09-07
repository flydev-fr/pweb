# CAP-11B: the watcher's contract, read off its own source.
#
# The watcher's value rests entirely on what it CANNOT do, and none of that is
# observable from a green run: a workflow that quietly gained `issues: write`,
# or that `ci.yml` started calling, or that learned to read its own previous
# report, would look exactly as healthy. So the contract is a SOURCE GATE, and
# it runs on all four platform legs like every other capability's gate - the
# watcher's source, never the watcher's runtime.
#
# What it refuses, by name:
#   permissions   anything but a single workflow-level `contents: read`
#   secrets       any secret reference, any token beyond the default read-only
#   isolation     a reference from ci.yml or platform-leg.yml; a workflow_call;
#                 a `needs:`; a trigger outside the ratified three
#   actions       a `uses:` outside the CAP-11A SHA-pinned allowlist
#   writes        git commit/push/tag, gh pr/issue, a PR action, or any write
#                 into a lock, src/, sdk/, tools/pweb/, tools/setup/, examples/
#   ingestion     download-artifact, gh run download, actions/cache - the
#                 report may never become an input to a verdict
#   retention     an upload class outside the CAP-11A records policy
#   vocabulary    a verdict set that is not exactly the six ratified words
#
# COMMENT LINES ARE STRIPPED BEFORE EVERY SWEEP, and that is not laxity: the
# watcher's own header EXPLAINS that it has no `issues: write` and opens no
# pull request, so a gate that matched raw text would refuse the file for
# saying what it does not do.
#
# Checkout-only: no toolchain, no network, no display.
# Emits build/cap11b/contract.json and exits nonzero on any violation.

param(
    # A sandbox tree to read instead of the repository. Used ONLY by the
    # negative self-test below, which perturbs a copy and requires a refusal.
    [string]$Root,
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$realRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$repoRoot = if ($Root) { (Resolve-Path $Root).Path } else { $realRoot }
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text); Write-Host "VIOLATION: $Text" }

$WATCHER = '.github/workflows/upstream-watch.yml'
$DRIVER  = 'test/cap11b/watch_upstream.ps1'
$ENGINE  = @('test/cap11b/extract_api.ps1', 'test/cap11b/project_binding.ps1',
             'test/cap11b/diff_api.ps1')
$CALLER  = '.github/workflows/ci.yml'
$LEG     = '.github/workflows/platform-leg.yml'
$MAX_BYTES = 65536
$MAX_LINES = 1600
# The CAP-11A allowlist, restated here rather than imported: this gate has to
# hold even if it is the only one that runs.
$PINNED_ACTIONS = @(
    'actions/checkout@11d5960a326750d5838078e36cf38b85af677262',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
    'actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16',
    'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
    'actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57',
    'ilammy/msvc-dev-cmd@0b201ec74fa43914dc39ae48a89fd1d8cb592756'
)
$RATIFIED_VERDICTS = @('unchanged', 'compatible_additive', 'patch_drift',
    'abi_break', 'build_failed', 'inconclusive')
$RATIFIED_TRIGGERS = @('schedule', 'workflow_dispatch', 'push')
# Sorted, because the gate compares a sorted list; the workflow may write them
# in whatever order reads best.
$RATIFIED_PUSH_PATHS = @(
    '.github/workflows/upstream-watch.yml',
    'test/cap11b/**',
    'tools/build-webview-dll.ps1',
    'tools/build-webview-dylib.sh',
    'tools/build-webview-so.sh',
    'tools/get-webview.ps1'
) | Sort-Object
$RATIFIED_CRON = '17 4 * * 1'
$WATCH_RETENTION = '90'

# EVERY PATH IS RESOLVED AGAINST $repoRoot, never left relative. `Set-Location`
# moves PowerShell's location but NOT the process working directory, so
# `[IO.File]::ReadAllText('a/b')` keeps reading the real repository while
# `Test-Path 'a/b'` reads the sandbox - which is exactly what happened: the
# negative self-test below reported every one of its fourteen perturbations
# ACCEPTED, because the gate under test was reading the unperturbed originals.
function Resolve-Under([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $repoRoot $Path)
}
function Read-Norm([string]$Path) {
    return ([System.IO.File]::ReadAllText((Resolve-Under $Path)) -replace "`r`n", "`n")
}
function Get-CodeLines([string]$Path) {
    return @((Read-Norm $Path) -split "`n" | Where-Object { $_ -notmatch '^\s*#' })
}
function Get-Sha256Utf8([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $b = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

$watcherAvailable = $false
foreach ($p in @($WATCHER, $DRIVER) + $ENGINE) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Violation "missing watcher source: $p" }
}
if ((Test-Path -LiteralPath $WATCHER) -and (Test-Path -LiteralPath $DRIVER)) { $watcherAvailable = $true }
if (-not $watcherAvailable) {
    # Nothing below can mean anything without the two files, and a gate that
    # reported PASS over an absent watcher would be the worst outcome here.
    Write-Host '[cap11b] the watcher is not present; every check below is vacuous'
    exit 1
}

$wfText = Read-Norm $WATCHER
$wfLines = @($wfText -split "`n")
$wfCode = Get-CodeLines $WATCHER

# --- 1. size, so the CAP-11A bound holds for this file too --------------------
$bytes = [Text.Encoding]::UTF8.GetByteCount($wfText)
$lines = $wfLines.Count
if ($bytes -gt $MAX_BYTES) { Violation "$WATCHER is $bytes bytes, over the ratified $MAX_BYTES" }
if ($lines -gt $MAX_LINES) { Violation "$WATCHER is $lines lines, over the ratified $MAX_LINES" }

# --- 2. permissions: exactly one, at workflow level, contents: read ----------
$permBlocks = @($wfCode | Where-Object { $_ -match '^permissions:' })
if ($permBlocks.Count -ne 1) {
    Violation "$WATCHER declares $($permBlocks.Count) workflow-level permissions blocks, expected exactly 1"
}
if ($wfText -notmatch '(?m)^permissions:\n  contents: read\n') {
    Violation "$WATCHER's workflow-level permissions block is not exactly 'contents: read'"
}
$jobPerms = @($wfCode | Where-Object { $_ -match '^\s+permissions:' })
if ($jobPerms.Count -ne 0) {
    Violation "$WATCHER declares a JOB-level permissions block; the workflow-level one is the whole grant"
}
# THE BLOCK IS EXACTLY ONE LINE LONG. `^permissions:\n  contents: read\n` also
# matches a block whose THIRD line grants `issues: write`, so the evidence row
# would read `contents_read` about a workflow that had gained a second grant.
# The separate sweep below still refuses that workflow - but a row computed
# from a weaker predicate than the name it carries is a row nobody can trust.
$permGrants = 0
if ($onePermBlock = [regex]::Match($wfText, '(?m)^permissions:\n((?:  \S.*\n)+)')) {
    if ($onePermBlock.Success) {
        $permGrants = @($onePermBlock.Groups[1].Value -split "`n" | Where-Object { $_.Trim() }).Count
    }
}
$permIsExactlyContentsRead = ($wfText -match '(?m)^permissions:\n  contents: read\n') -and ($permGrants -eq 1)
if (-not $permIsExactlyContentsRead) {
    Violation "$WATCHER's permissions block is not exactly one grant of 'contents: read' ($permGrants grant(s))"
}
$watcherPermissions = if ($permIsExactlyContentsRead) { 'contents_read' } else { 'other' }
foreach ($grant in 'issues: write', 'pull-requests: write', 'contents: write',
         'packages: write', 'id-token: write', 'actions: write', 'permissions: write-all') {
    foreach ($l in $wfCode) {
        if ($l -match [regex]::Escape($grant)) { Violation "$WATCHER grants '$grant'" }
    }
}

# --- 2b. no GitHub expression inside a shell body ---------------------------
# `${{ }}` in a `run:` block is textual substitution BEFORE the shell parses the
# line, so a dispatch input carrying a quote closes the argument and executes
# whatever follows on the runner. Inputs reach a script through `env:`; the
# `${{ }}` that populate `env:`, `if:`, `with:` and `uses:` are fine.
$inRun = $false
$runIndent = 0
for ($i = 0; $i -lt $wfLines.Count; $i++) {
    $l = $wfLines[$i]
    if ($l -match '^(\s*)-?\s*run:\s*\|?\s*$' -or $l -match '^(\s*)run:\s*\|') {
        $inRun = $true; $runIndent = $Matches[1].Length; continue
    }
    if ($inRun) {
        if ($l.Trim() -ne '' -and ($l.Length - $l.TrimStart().Length) -le $runIndent) { $inRun = $false }
        elseif ($l -match '\$\{\{') {
            Violation "$WATCHER interpolates a GitHub expression inside a run: block -- pass it through env: instead: $($l.Trim())"
        }
    }
}

# --- 3. no secret, no token --------------------------------------------------
foreach ($f in @($WATCHER, $DRIVER) + $ENGINE) {
    foreach ($l in (Get-CodeLines $f)) {
        foreach ($needle in 'secrets\.', '^\s*secrets:', 'GITHUB_TOKEN', 'github\.token', 'GH_TOKEN') {
            if ($l -match $needle) { Violation "$f references a token or secret: $($l.Trim())" }
        }
    }
}

# --- 4. the triggers are exactly the ratified three --------------------------
$onIdx = -1
for ($i = 0; $i -lt $wfLines.Count; $i++) { if ($wfLines[$i] -match '^on:\s*$') { $onIdx = $i; break } }
if ($onIdx -lt 0) { Violation "$WATCHER has no top-level 'on:' block" }
else {
    $triggers = @()
    for ($i = $onIdx + 1; $i -lt $wfLines.Count; $i++) {
        # A comment or a blank line at column zero is not the end of the block.
        # Reading one as the end reports every ratified trigger as missing.
        if ($wfLines[$i].Trim() -eq '' -or $wfLines[$i] -match '^\s*#') { continue }
        if ($wfLines[$i] -match '^\S') { break }
        if ($wfLines[$i] -match '^  ([a-z_]+):') { $triggers += $Matches[1] }
    }
    $extra = @($triggers | Where-Object { $RATIFIED_TRIGGERS -cnotcontains $_ })
    foreach ($t in $extra) { Violation "$WATCHER declares the unratified trigger '$t'" }
    foreach ($t in $RATIFIED_TRIGGERS) {
        if ($triggers -cnotcontains $t) { Violation "$WATCHER is missing the ratified trigger '$t'" }
    }
    # `push` MUST be path-filtered, AND THE FILTER'S CONTENTS ARE THE POINT.
    # `paths: ['**']` satisfies "has a filter" while producing exactly what the
    # filter exists to prevent: an unpinned upstream build on every commit to
    # the repository. The ratified list is the watcher's own sources.
    if ($triggers -ccontains 'push') {
        $pm = [regex]::Match($wfText, '(?m)^  push:\n    paths:\n((?:      - .*\n)+)')
        if (-not $pm.Success) { Violation "$WATCHER's push trigger has no paths: filter" }
        else {
            $got = @($pm.Groups[1].Value -split "`n" | Where-Object { $_.Trim() } |
                ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim().Trim("'").Trim('"') } | Sort-Object)
            if (($got -join ',') -cne ($RATIFIED_PUSH_PATHS -join ',')) {
                Violation ("$WATCHER's push paths are [" + ($got -join ',') +
                    '], ratified [' + ($RATIFIED_PUSH_PATHS -join ',') + ']')
            }
        }
    }
}

# --- 4b. the schedule, the concurrency and the matrix shape ------------------
# docs/watcher-contract.md freezes these; without a gate the cron could become
# `* * * * *`, `cancel-in-progress` could start cancelling on `main`, or
# `fail-fast` could let one target's failure delete the other three's answers -
# and every other check here would still pass.
if ($wfText -notmatch "(?m)^\s*- cron: '$([regex]::Escape($RATIFIED_CRON))'\s*$") {
    Violation "$WATCHER's schedule is not the ratified '$RATIFIED_CRON'"
}
if ($wfText -notmatch '(?m)^\s*group: upstream-watch-\$\{\{ github\.ref \}\}\s*$') {
    Violation "$WATCHER's concurrency group is not the ratified upstream-watch-<ref>"
}
if ($wfText -notmatch "cancel-in-progress: \`$\{\{ github\.ref_name != 'main' \}\}") {
    Violation "$WATCHER's cancel-in-progress is not the ratified off-the-default-branch form"
}
if ($wfText -notmatch '(?m)^\s*fail-fast: false\s*$') {
    Violation "$WATCHER does not declare fail-fast: false -- one target's failure would delete the other three's answers"
}
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    if ($wfText -notmatch "(?m)^\s*- target: $([regex]::Escape($t))\s*$") {
        Violation "$WATCHER does not watch the target '$t'"
    }
}
# THE ONE PLACE THE REPORT IS PUBLISHED. The driver writes the job summary only
# when this is set, so the case gate's nine drivers on an ordinary leg publish
# nothing; if the workflow stopped setting it, the weekly run would go quiet
# instead of loud, which is the failure nobody would notice.
if ($wfText -notmatch "(?m)^\s*PWEB_WATCH_PUBLISH: '1'\s*$") {
    Violation "$WATCHER does not set PWEB_WATCH_PUBLISH -- the watcher's own run would publish no job summary"
}
if ($wfCode -match 'workflow_call') { Violation "$WATCHER declares workflow_call; it must not be callable" }
foreach ($l in $wfCode) {
    if ($l -match '^\s+needs:') { Violation "$WATCHER declares a needs: dependency: $($l.Trim())" }
}

# --- 5. isolation from the matrix --------------------------------------------
$watcherInMatrix = $false
foreach ($f in @($CALLER, $LEG)) {
    if (-not (Test-Path -LiteralPath $f)) { Violation "missing $f"; continue }
    foreach ($l in (Get-CodeLines $f)) {
        if ($l -match 'upstream-watch') {
            Violation "$f references the watcher: $($l.Trim())"
            $script:watcherInMatrix = $true
        }
    }
}
# The mirror: no composite action may call it either.
foreach ($a in @(Get-ChildItem -Path .github/actions -Recurse -File -Filter action.yml -ErrorAction SilentlyContinue)) {
    if ((Read-Norm $a.FullName) -match 'upstream-watch') {
        Violation "$($a.FullName.Substring($repoRoot.Length + 1)) references the watcher"
        $watcherInMatrix = $true
    }
}

# --- 6. every `uses:` is local or SHA-pinned in the allowlist -----------------
foreach ($l in $wfCode) {
    if ($l -notmatch '^\s*uses:\s*(\S+)') { continue }
    $u = $Matches[1]
    if ($u.StartsWith('./')) {
        $actionDir = $u.Substring(2)
        if (-not (Test-Path -LiteralPath (Join-Path $actionDir 'action.yml'))) {
            Violation "$WATCHER uses a local action that does not exist: $u"
        }
        continue
    }
    if ($PINNED_ACTIONS -notcontains $u) { Violation "$WATCHER uses an unratified action: $u" }
}

# --- 7. nothing that writes, pushes, opens or ingests -------------------------
$FORBIDDEN = @(
    @{ p = 'git\s+commit';        why = 'the watcher must never commit' },
    @{ p = 'git\s+push';          why = 'the watcher must never push' },
    @{ p = 'git\s+tag';           why = 'the watcher must never tag' },
    @{ p = 'gh\s+pr\b';           why = 'the watcher must never open a pull request' },
    @{ p = 'gh\s+issue\b';        why = 'the watcher must never write an issue' },
    @{ p = 'gh\s+api\b';          why = 'the watcher takes no API beyond the checkout' },
    @{ p = 'create-pull-request'; why = 'the watcher must never open a pull request' },
    @{ p = 'peter-evans/';        why = 'the watcher must never open a pull request' },
    @{ p = 'download-artifact';   why = 'the report may never become an input to a verdict' },
    @{ p = 'gh\s+run\s+download'; why = 'the report may never become an input to a verdict' },
    @{ p = 'actions/cache';       why = 'a cached previous answer would be an input to a verdict' },
    # INVOKED, not merely named: project_binding.ps1 writes the sentence
    # "regenerate ONLY via tools/regen-webview-binding.ps1" into the header of
    # the unit it projects, which is the opposite of calling it.
    @{ p = '(&|-File\s+\S*)regen-webview-binding'; why = 'the binding is never regenerated by the watcher' }
)
foreach ($f in @($WATCHER, $DRIVER) + $ENGINE) {
    foreach ($l in (Get-CodeLines $f)) {
        foreach ($x in $FORBIDDEN) {
            if ($l -match $x.p) { Violation "$f`: $($x.why) -- $($l.Trim())" }
        }
    }
}
# WRITES INTO A FROZEN TREE. READING src/lib is the projector's whole job - it
# reuses the committed platform block verbatim and copies the two alias view
# units out of it - so only the WRITE TARGET is swept. Backtick continuations
# are joined first, because `Copy-Item -LiteralPath <src>` and its
# `-Destination <dst>` routinely sit on two physical lines and a per-line sweep
# would read the source path as if it were the destination.
$WRITE_VERBS = 'Set-Content|Out-File|WriteAllText|WriteAllLines|WriteAllBytes|Add-Content|AppendAllText|Move-Item|Remove-Item|New-Item|Copy-Item'
# PLAIN SUBSTRINGS, compared with String.Contains, not regexes. These are file
# paths carrying quotes, dots and backslashes, and every one of those is a
# regex metacharacter: the first version of this list was written as patterns
# and silently matched nothing, which the negative self-test below is what
# caught.
$FROZEN = @('webview.lock', 'mormot.lock', "'src/", '"src/', 'src\lib',
    'sdk/', 'tools/pweb', 'tools/setup', 'examples/', 'webview.chet')
foreach ($f in @($WATCHER, $DRIVER) + $ENGINE) {
    $joined = [regex]::Replace((Read-Norm $f), "\x60[ \t]*\n[ \t]*", ' ')
    foreach ($l in ($joined -split "`n")) {
        if ($l -match '^\s*#') { continue }
        if ($l -notmatch $WRITE_VERBS -and $l -notmatch '(^|\s)(>|>>)\s') { continue }
        # For a copy, the write target is what follows -Destination and nothing
        # else. For every other verb the whole statement is the target.
        $target = $l
        if ($l -match 'Copy-Item') {
            $dm = [regex]::Match($l, '-Destination\s+(?<d>.*)$')
            $target = if ($dm.Success) { $dm.Groups['d'].Value } else { $l }
        }
        # `$fz`, NOT `$frozen`: PowerShell variable names are case-INSENSITIVE,
        # so `foreach ($frozen in $FROZEN)` assigns to the very array it is
        # iterating. The enumerator survives the first pass, but by the second
        # write-verb line $FROZEN is the last element - a plain string - and the
        # loop then runs exactly once, over 'webview.chet'. The gate looked
        # perfectly healthy and checked one pattern out of ten; the negative
        # self-test is what found it.
        foreach ($fz in $FROZEN) {
            if ($target.Contains($fz)) { Violation "$f writes into a frozen path: $($l.Trim())" }
        }
        # A WRITE TO ANY LOCK, in the one place this sweep lives. It used to be
        # duplicated in check_ref_input.ps1 over a separately-maintained list of
        # "the watcher's sources", so a file added to one list and not the other
        # was unswept by both while each looked thorough.
        if ($target -match '\.lock\b' -or $target -match '\.chet\b') {
            Violation "$f writes a pin: $($l.Trim())"
        }
    }
}

# --- 7b. NOTHING READS THE WATCHER'S REPORT ---------------------------------
# "the report is never an input to a build" is only half proved by refusing
# `download-artifact` inside the watcher: the other half is that nothing in the
# repository reads the report the watcher leaves on disk. `build/cap11b/watch/`
# is the driver's own output directory, and the driver is the only file allowed
# to name it. The gate records (`contract.json`, `refinput.json`, `cases.json`,
# `ledger.json`) sit beside it and ARE read by the emitters - those are gate
# verdicts about the watcher's source, never the watcher's answer about
# upstream, and the distinction is exactly what this separates.
$WATCH_OUT = 'build/cap11b/watch'
$readers = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -Path test, .github, tools -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.ps1', '.sh', '.yml', '.yaml', '.pas') })) {
    $rel = $f.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    # The driver OWNS the directory; this gate has to name it to check it.
    if ($rel -eq $DRIVER -or $rel -eq 'test/cap11b/check_watcher_contract.ps1') { continue }
    $codeLines = @(Get-CodeLines $rel)
    for ($i = 0; $i -lt $codeLines.Count; $i++) {
        if (-not $codeLines[$i].Contains($WATCH_OUT)) { continue }
        # PUBLISHING IS NOT CONSUMING. The watcher's own upload step names the
        # directory as an artifact `path:`, which is the report leaving the
        # runner - the opposite of the report coming back in. Only the upload's
        # own path list is exempt, and only in the watcher.
        # THE WATCHER'S OWN JOB IS THE PRODUCER AND THE PUBLISHER. It names the
        # directory to upload it and to assert it exists, and neither is the
        # report becoming an input. What it may NOT do is branch on the answer,
        # which is checked separately below.
        if ($rel -eq $WATCHER) { continue }
        [void]$readers.Add("$rel`: $($codeLines[$i].Trim())")
    }
}
foreach ($r in $readers.ToArray()) {
    Violation "the watcher's report is named outside the driver -- it may never be an input: $r"
}
# THE WORKFLOW MAY NOT ACT ON THE VERDICT. Reading it into the log is how the
# run says what it found; turning it into a `throw`, an `exit` or an `if:` would
# make a verdict redden the job, which is the one thing the contract forbids
# outright. `$r.verdict` on a Write-Host line is fine; on a branch it is not.
foreach ($l in $wfCode) {
    if ($l -notmatch 'verdict') { continue }
    if ($l -match '\bthrow\b' -or $l -match '\bexit\s' -or $l -match '^\s*if:') {
        Violation "$WATCHER branches on the verdict -- a verdict may never redden the job: $($l.Trim())"
    }
}

# --- 7c. the driver measures the PINNED checkout on both sides --------------
# `deps/` is git-ignored, so a `git status` over the repository says nothing
# about `deps/webview`; and the watcher legitimately writes inside `deps/`, into
# its own `deps/webview-watch`. The one thing that separates those two facts is
# the driver measuring the pinned checkout before and after, and refusing to
# apply a patch to it. Both are required to be present.
foreach ($needle in 'pinned_checkout_untouched', 'Get-PinnedCheckoutState',
                    'the watcher refuses to patch the pinned checkout') {
    if ((Read-Norm $DRIVER) -notmatch [regex]::Escape($needle)) {
        Violation "$DRIVER no longer proves the pinned checkout is untouched: '$needle' is gone"
    }
}

# --- 8. the upload: one class, the records retention -------------------------
$uploads = 0
for ($i = 0; $i -lt $wfLines.Count; $i++) {
    if ($wfLines[$i] -notmatch 'uses:\s*actions/upload-artifact@') { continue }
    $uploads++
    $hi = [Math]::Min($i + 10, $wfLines.Count - 1)
    $window = ($wfLines[$i..$hi] -join "`n")
    if ($window -notmatch '(?m)^\s*name:\s*upstream-watch-') {
        Violation "$WATCHER uploads an artifact that is not in the watcher's own class"
    }
    if ($window -notmatch "(?m)^\s*retention-days: $WATCH_RETENTION\s*$") {
        Violation "$WATCHER's upload does not declare the ratified retention-days: $WATCH_RETENTION"
    }
}
if ($uploads -ne 1) { Violation "$WATCHER declares $uploads uploads, expected exactly 1" }

# --- 9. the verdict vocabulary, read out of the driver -----------------------
$driverText = Read-Norm $DRIVER
$vm = [regex]::Match($driverText, '(?s)\$VERDICTS = @\(\s*(?<body>.*?)\s*\)')
$vocab = @()
if (-not $vm.Success) { Violation "$DRIVER declares no `$VERDICTS array" }
else {
    $vocab = @($vm.Groups['body'].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") } |
        Where-Object { $_ -ne '' })
    if (($vocab -join ',') -cne ($RATIFIED_VERDICTS -join ',')) {
        Violation ("the verdict vocabulary is [" + ($vocab -join ',') + "], ratified [" +
            ($RATIFIED_VERDICTS -join ',') + ']')
    }
}
# The digest is over the SORTED set, so four targets comparing it are comparing
# the vocabulary and not the order it happens to be written in.
$vocabDigest = Get-Sha256Utf8 (((@($vocab | Sort-Object)) -join "`n") + "`n")

# The driver must always exit 0. A watcher whose exit code carried the verdict
# would fail a job for news.
if ($driverText -notmatch '(?m)^exit 0\s*$') {
    Violation "$DRIVER has no unconditional 'exit 0' -- the verdict must live in the report, never in the exit code"
}
foreach ($l in (Get-CodeLines $DRIVER)) {
    if ($l -match '^\s*exit\s+[1-9]') { Violation "$DRIVER can exit nonzero: $($l.Trim())" }
}

# --- 10. the declared platform patch set matches the repository --------------
# The driver says Windows is the only target that patches upstream. That claim
# is checked against the file it names and against the two ratified steps that
# prove the other three carry none, so a patch added for a platform without
# also being declared here could not silently become `not_applicable`.
if ($driverText -notmatch "(?m)^\s*'windows'\s*=\s*'tools/cap4w/webview2-custom-scheme\.patch'") {
    Violation "$DRIVER does not declare the Windows platform patch"
}
if (-not (Test-Path -LiteralPath 'tools/cap4w/webview2-custom-scheme.patch')) {
    Violation 'the declared Windows platform patch does not exist'
}
foreach ($proof in 'cap-7l-deps-webview-carries-no-linux-patch', 'cap-7m0-deps-webview-carries-no-macos-patch') {
    if (-not (Test-Path -LiteralPath ".github/actions/$proof/action.yml")) {
        Violation "the step that proves a platform carries no patch is gone: $proof"
    }
}

# --- 10b. no loop variable shadows the collection it iterates ----------------
# PowerShell variable names are case-INSENSITIVE, so `foreach ($frozen in
# $FROZEN)` writes to the array it is walking: the first pass is correct and
# every later one iterates a single string. It is invisible in a green run and
# it silently deleted nine of ten checks in this very file. Comment lines are
# excluded, because the paragraph above explains the defect by quoting it.
foreach ($f in @($WATCHER, $DRIVER) + $ENGINE + @('test/cap11b/check_cap11b_cases.ps1',
        'test/cap11b/check_ref_input.ps1', 'test/cap11b/check_watcher_contract.ps1',
        'test/cap11b/check_cap11_ledger.ps1')) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    foreach ($l in (Get-CodeLines $f)) {
        $lm = [regex]::Match($l, 'foreach\s*\(\s*\$(?<v>[A-Za-z_][A-Za-z0-9_]*)\s+in\s+\$(?<c>[A-Za-z_][A-Za-z0-9_]*)\s*\)')
        if (-not $lm.Success) { continue }
        if ($lm.Groups['v'].Value -ieq $lm.Groups['c'].Value) {
            Violation "$f`: the loop variable shadows the collection it iterates: $($l.Trim())"
        }
    }
}

# --- 11. the macOS export rule and the pinned entry points cannot drift ------
# The driver applies the CAP-7M rule itself (that gate sources a harness the
# watcher does not have). These two lists must therefore stay equal, or the
# watcher would be measuring a different surface than the matrix does.
$m7 = Read-Norm 'test/cap7m/check_webview_exports.sh'
$m7Names = @([regex]::Matches($m7, '\bwebview_[a-z_]+\b') | ForEach-Object { $_.Value } |
    Sort-Object -Unique)
$bindingNames = @([regex]::Matches((Read-Norm 'src/lib/pweb.lib.webview.pas'),
    "name _PU \+ '(webview_[a-z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($bindingNames.Count -ne 17) {
    Violation "the committed binding declares $($bindingNames.Count) external entry points, expected 17"
}
$missing = @($bindingNames | Where-Object { $m7Names -cnotcontains $_ })
foreach ($x in $missing) { Violation "test/cap7m/check_webview_exports.sh does not name the entry point $x" }

$summary = [ordered]@{
    schema                            = 1
    watcher_available                 = $watcherAvailable.ToString().ToLowerInvariant()
    watcher_permissions               = $watcherPermissions
    watcher_in_matrix                 = $watcherInMatrix.ToString().ToLowerInvariant()
    watcher_verdict_vocabulary        = ($vocab -join ',')
    watcher_verdict_vocabulary_digest = $vocabDigest
    watcher_workflow_bytes            = $bytes
    watcher_workflow_lines            = $lines
    watcher_uploads                   = $uploads
    watcher_retention_days            = $WATCH_RETENTION
    binding_entry_points              = $bindingNames.Count
    violations                        = $violations.ToArray()
}
Write-Host ''
Write-Host "[cap11b] watcher: $bytes bytes / $lines lines, permissions=$watcherPermissions, in_matrix=$watcherInMatrix"
Write-Host "[cap11b] vocabulary: $($vocab -join ', ')"
Write-Host "[cap11b] vocabulary digest: $vocabDigest"

# =============================================================================
# THE NEGATIVE SELF-TEST. A gate that has only ever said PASS has never been
# shown to refuse anything, and every rule above is exactly the kind that stops
# working silently. Each case below copies the sources into a sandbox, makes
# ONE named change, and requires this same script to exit nonzero over it.
# =============================================================================
$refusals = 0
if (-not $NoSelfTest -and $violations.Count -eq 0) {
    $sandboxRoot = Join-Path $realRoot 'build/cap11b/selftest'
    if (Test-Path -LiteralPath $sandboxRoot) { Remove-Item -Recurse -Force -LiteralPath $sandboxRoot }
    $CASES = @(
        @{ n = 'permissions-write';  f = $WATCHER; from = 'permissions:
  contents: read'; to = 'permissions:
  contents: write' },
        @{ n = 'issues-write';       f = $WATCHER; from = 'permissions:
  contents: read'; to = 'permissions:
  contents: read
  issues: write' },
        @{ n = 'secret-reference';   f = $WATCHER; from = '      - name: Checkout'; to = '      - name: Checkout
        env:
          T: ${{ secrets.SOMETHING }}' },
        @{ n = 'workflow-call';      f = $WATCHER; from = '  workflow_dispatch:'; to = '  workflow_call:
  workflow_dispatch:' },
        @{ n = 'unratified-trigger'; f = $WATCHER; from = '  workflow_dispatch:'; to = '  pull_request:
  workflow_dispatch:' },
        @{ n = 'push-unfiltered';    f = $WATCHER; from = '  push:
    paths:'; to = '  push:
    branches:' },
        @{ n = 'called-by-ci';       f = $CALLER;  from = 'jobs:'; to = 'jobs:
  watch:
    uses: ./.github/workflows/upstream-watch.yml' },
        @{ n = 'unpinned-action';    f = $WATCHER; from = '      - name: Checkout'; to = '      - name: Something
        uses: some/action@v1

      - name: Checkout' },
        @{ n = 'report-ingestion';   f = $WATCHER; from = '      - name: Checkout'; to = '      - name: Previous
        uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16

      - name: Checkout' },
        @{ n = 'retention-moved';    f = $WATCHER; from = 'retention-days: 90'; to = 'retention-days: 7' },
        @{ n = 'vocabulary-short';   f = $DRIVER;  from = "    'build_failed',
"; to = '' },
        @{ n = 'driver-exits-nonzero'; f = $DRIVER; from = 'exit 0
'; to = 'exit 1
' },
        @{ n = 'driver-pushes';      f = $DRIVER;  from = '$stages = New-Object'; to = 'git push origin HEAD
$stages = New-Object' },
        @{ n = 'driver-writes-src';  f = $DRIVER;  from = '$stages = New-Object'; to = 'Set-Content -LiteralPath ''src/lib/x.pas'' -Value ''x''
$stages = New-Object' },
        @{ n = 'report-read-by-leg'; f = $LEG; from = '    steps:'; to = '    steps:
      - name: read the last watch
        run: cat build/cap11b/watch/report.json' },
        @{ n = 'pinned-checkout-unmeasured'; f = $DRIVER;
           from = 'pinned_checkout_untouched = $pinnedCheckoutUntouched';
           to = 'pinned_checkout_measured = $true' },
        # --- the rules the adversarial review added, each proved to refuse ---
        @{ n = 'expression-in-run';  f = $WATCHER;
           from = '          $ref = if ($env:PWEB_WATCH_REF)';
           to = '          $ref = ''${{ inputs.ref }}''
          $unused = if ($env:PWEB_WATCH_REF)' },
        @{ n = 'push-paths-widened'; f = $WATCHER;
           from = "      - 'tools/get-webview.ps1'"; to = "      - '**'" },
        @{ n = 'cron-moved';         f = $WATCHER;
           from = "    - cron: '17 4 * * 1'"; to = "    - cron: '* * * * *'" },
        @{ n = 'fail-fast-on';       f = $WATCHER;
           from = '      fail-fast: false'; to = '      fail-fast: true' },
        @{ n = 'verdict-branch';     f = $WATCHER;
           from = '          Write-Host "verdict: $($r.verdict)';
           to = '          if ($r.verdict -ne ''unchanged'') { throw $r.verdict }
          Write-Host "verdict: $($r.verdict)' },
        @{ n = 'driver-writes-lock'; f = $DRIVER;
           from = '$stages = New-Object';
           to = 'Set-Content -LiteralPath ''webview.lock'' -Value ''x''
$stages = New-Object' }
    )
    # The files a sandbox needs. `.github/actions/*/action.yml` is copied
    # because the local `uses:` existence check reads it.
    $copySpec = @($WATCHER, $DRIVER, $CALLER, $LEG,
        'test/cap7m/check_webview_exports.sh', 'src/lib/pweb.lib.webview.pas',
        'tools/cap4w/webview2-custom-scheme.patch') + $ENGINE
    foreach ($case in $CASES) {
        $sb = Join-Path $sandboxRoot $case.n
        foreach ($rel in $copySpec) {
            $dst = Join-Path $sb $rel
            New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
            [IO.File]::WriteAllText($dst, (Read-Norm (Join-Path $realRoot $rel)), [Text.UTF8Encoding]::new($false))
        }
        foreach ($a in @(Get-ChildItem -Path (Join-Path $realRoot '.github/actions') -Recurse -File -Filter action.yml)) {
            $rel = $a.FullName.Substring($realRoot.Length + 1).Replace('\', '/')
            $dst = Join-Path $sb $rel
            New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
            [IO.File]::WriteAllText($dst, (Read-Norm $a.FullName), [Text.UTF8Encoding]::new($false))
        }
        $target = Join-Path $sb $case.f
        $text = Read-Norm $target
        $from = ($case.from -replace "`r`n", "`n")
        if (-not $text.Contains($from)) {
            Violation "self-test '$($case.n)': its anchor is not in $($case.f) -- the case would perturb nothing"
            continue
        }
        [IO.File]::WriteAllText($target, ($text -replace [regex]::Escape($from), ($case.to -replace "`r`n", "`n")),
            [Text.UTF8Encoding]::new($false))
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $realRoot
        foreach ($a in @('-NoProfile', '-File', $PSCommandPath, '-Root', $sb, '-NoSelfTest')) {
            [void]$psi.ArgumentList.Add($a)
        }
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) {
            Violation "self-test '$($case.n)': the gate ACCEPTED a perturbed watcher"
            Write-Host $o
        }
        else { $refusals++ }
    }
    Write-Host "[cap11b] self-test: $refusals of $($CASES.Count) perturbations refused"
}

$summary['selftest_refusals'] = $refusals
$summary['violations'] = $violations.ToArray()
New-Item -ItemType Directory -Force (Join-Path $realRoot 'build/cap11b') | Out-Null
[IO.File]::WriteAllText((Join-Path $realRoot 'build/cap11b/contract.json'),
    (($summary | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    Write-Host "[cap11b] WATCHER CONTRACT FAILED ($($violations.Count) violation(s))"
    exit 1
}
Write-Host '[cap11b] watcher contract PASS'
exit 0
