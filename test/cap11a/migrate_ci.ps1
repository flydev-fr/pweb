# CAP-11A: the one-shot migration from the single 265 KB `.github/workflows/ci.yml`
# to ONE step sequence (`.github/workflows/platform-leg.yml`) plus one composite
# action per step (`.github/actions/<slug>/action.yml`).
#
# THIS IS A MIGRATION TOOL, NOT A GENERATOR IN THE PIPELINE. After the migration
# the reusable workflow IS the source; nothing re-renders it. It is committed as
# the RECORD of how the new structure was produced, so a reviewer asking "did any
# step change?" can re-run it against the legacy file (from git history after the
# removal commit) and diff, instead of reading 5,824 lines twice.
#
# WHAT IT PRESERVES, and how that is checkable afterwards:
#   - every step NAME, verbatim. Names that differ across platforms stay DIFFERENT
#     steps, each `if:`-guarded to the targets that had it - merging them would
#     have renamed a gate, and a renamed gate is a gate somebody cannot find.
#   - every step BODY, byte-identical after ONE declared normalization: the common
#     leading indent. A workflow step sits at 6 spaces and a composite-action step
#     at 4, so the block dedents by two and the script text inside a `run: |`
#     block scalar is unchanged (block scalars are indentation-relative).
#   - every `shell:`, `if:` and `timeout-minutes:`, and every leading comment
#     block attached above a step.
#   - the ORDER. The four job orders merge into one linear order with zero
#     conflicts and each leg's subsequence equals its current order exactly;
#     the script refuses if that ever stops being true.
#
# WHAT IT DELIBERATELY RESTRUCTURES (the one ratified exception, ledger
# "NO GATE MAY DEPEND ON AN UPLOAD HAVING SUCCEEDED"): the 61 interleaved
# `actions/upload-artifact` steps do not enter the sequence. Their path sets are
# unioned per artifact CLASS into the collection block emitted at the end of the
# leg. `test/cap11a/ci-migration-map.tsv` records where each one went.
#
# Usage:
#   pwsh -File test/cap11a/migrate_ci.ps1 [-LegacyCi .github/workflows/ci.yml]
#                                         [-OutRoot .]
param(
    [string]$LegacyCi = '.github/workflows/ci.yml',
    [string]$OutRoot = '.'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$PLATFORMS = @('windows', 'linux', 'macos-x64', 'macos-arm64')

# ---------------------------------------------------------------------------
# writers: LF only, UTF-8 without BOM. `.yml` is NOT pinned to LF in
# .gitattributes, so a CRLF write here would produce files whose committed bytes
# depend on whose machine ran the migration.
# ---------------------------------------------------------------------------
function Write-TextLf([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    $lf = $Text -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Sha16([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 16)
    } finally { $sha.Dispose() }
}

# Remove the indentation every non-empty line shares. This is THE declared
# normalization: it is what makes a 6-space workflow step and a 4-space
# composite-action step comparable, and it changes no character inside a line.
function Remove-CommonIndent([string[]]$Lines) {
    $min = [int]::MaxValue
    foreach ($l in $Lines) {
        if ($l.Trim() -eq '') { continue }
        $n = $l.Length - $l.TrimStart(' ').Length
        if ($n -lt $min) { $min = $n }
    }
    if ($min -eq [int]::MaxValue) { $min = 0 }
    return @($Lines | ForEach-Object {
        if ($_.Length -ge $min) { $_.Substring($min) } else { $_.TrimStart(' ') }
    })
}

function Add-Indent([string[]]$Lines, [int]$N) {
    $pad = ' ' * $N
    return @($Lines | ForEach-Object { if ($_.Trim() -eq '') { '' } else { $pad + $_ } })
}

# ---------------------------------------------------------------------------
# parse: jobs, and their steps with leading comment blocks attached
# ---------------------------------------------------------------------------
$src = [System.IO.File]::ReadAllText((Resolve-Path $LegacyCi).Path) -split "`r?`n"

$jobStart = [ordered]@{}
$order = @()
for ($i = 0; $i -lt $src.Count; $i++) {
    if ($src[$i] -match '^  ([a-z0-9_-]+):\s*$') {
        $j = $Matches[1]
        if ($j -in @('push', 'pull_request', 'workflow_dispatch')) { continue }
        $jobStart[$j] = $i
        $order += $j
    }
}
if ($order.Count -ne 6) { throw "expected 6 jobs in $LegacyCi, found $($order.Count): $($order -join ', ')" }

function Get-JobSteps([string]$Job) {
    $start = $jobStart[$Job]
    $k = $order.IndexOf($Job)
    $end = if ($k + 1 -lt $order.Count) { $jobStart[$order[$k + 1]] } else { $src.Count }
    $nameIdx = @()
    for ($i = $start; $i -lt $end; $i++) {
        if ($src[$i] -match '^      - name: (.*)$') { $nameIdx += $i }
    }
    $steps = @()
    for ($k2 = 0; $k2 -lt $nameIdx.Count; $k2++) {
        $i = $nameIdx[$k2]
        # leading comment block: contiguous blank/`      #` lines above the name
        $lead = $i
        while ($lead - 1 -ge $start -and ($src[$lead - 1].Trim() -eq '' -or $src[$lead - 1] -match '^      #')) {
            $lead--
        }
        # the step ends where the NEXT step's leading comment block begins
        if ($k2 + 1 -lt $nameIdx.Count) {
            $stop = $nameIdx[$k2 + 1]
            while ($stop - 1 -ge $i -and ($src[$stop - 1].Trim() -eq '' -or $src[$stop - 1] -match '^      #')) {
                $stop--
            }
        } else {
            $stop = $end
        }
        $bodyLines = @()
        if ($stop - 1 -ge $i + 1) {
            $rawB = @($src[($i + 1)..($stop - 1)])
            $bEnd = $rawB.Count - 1
            while ($bEnd -ge 0 -and $rawB[$bEnd].Trim() -eq '') { $bEnd-- }
            if ($bEnd -ge 0) { $bodyLines = @($rawB[0..$bEnd]) }
        }
        $leadLines = @()
        if ($lead -lt $i) {
            $raw = @($src[$lead..($i - 1)])
            $a = 0; $b = $raw.Count - 1
            while ($a -le $b -and $raw[$a].Trim() -eq '') { $a++ }
            while ($b -ge $a -and $raw[$b].Trim() -eq '') { $b-- }
            if ($a -le $b) { $leadLines = @($raw[$a..$b]) }
        }
        $keys = @{}
        foreach ($l in $bodyLines) {
            if ($l -match '^        ([a-z-]+):(.*)$') {
                if (-not $keys.ContainsKey($Matches[1])) { $keys[$Matches[1]] = $Matches[2].Trim() }
            }
        }
        $norm = Remove-CommonIndent $bodyLines
        # the body WITHOUT the two keys that move to the sequence step. This is
        # what a composite action can carry, so it is what the migration map
        # compares - and it survives the deletion of the legacy file, which the
        # full body does not.
        $stripped = @($norm | Where-Object {
            $_ -notmatch '^if:' -and $_ -notmatch '^timeout-minutes:' -and
            $_ -notmatch '^continue-on-error:' })
        $steps += [pscustomobject]@{
            Job      = $Job
            Name     = $src[$i].Substring('      - name: '.Length)
            Lead     = $leadLines
            Body     = $bodyLines
            NormBody = $norm
            BodySha  = Get-Sha16 ($norm -join "`n")
            StripSha = Get-Sha16 ($stripped -join "`n")
            Shell    = if ($keys.ContainsKey('shell')) { $keys['shell'] } else { $null }
            If       = if ($keys.ContainsKey('if')) { $keys['if'] } else { $null }
            Timeout  = if ($keys.ContainsKey('timeout-minutes')) { $keys['timeout-minutes'] } else { $null }
            ContinueOnError = if ($keys.ContainsKey('continue-on-error')) { $keys['continue-on-error'] } else { $null }
            Uses     = if ($keys.ContainsKey('uses')) { $keys['uses'] } else { $null }
            IsUpload = (($bodyLines -join "`n") -like '*uses: actions/upload-artifact*')
            PureUses = ($keys.ContainsKey('uses') -and -not ($bodyLines -join "`n").Contains('run:'))
            Line     = $i + 1
        }
    }
    return $steps
}

$byJob = [ordered]@{}
foreach ($j in $PLATFORMS) { $byJob[$j] = Get-JobSteps $j }

Write-Host ('[migrate] parsed ' + (($PLATFORMS | ForEach-Object { "$_=$($byJob[$_].Count)" }) -join ' ') + ' steps')

# ---------------------------------------------------------------------------
# 1. the legacy inventory - the committed snapshot CI7 stays checkable against
# ---------------------------------------------------------------------------
$inv = New-Object System.Collections.Generic.List[string]
$inv.Add(("job`tordinal`tname`tshell`tif`tcontinue_on_error`ttimeout`tkind`tbody_sha256_16`tbody_stripped_sha256_16`tlegacy_line"))
foreach ($j in $PLATFORMS) {
    $n = 0
    foreach ($s in $byJob[$j]) {
        $n++
        $kind = if ($s.IsUpload) { 'upload' } elseif ($s.PureUses) { 'uses' } else { 'run' }
        $inv.Add(($j, $n, $s.Name, ($s.Shell ?? ''), ($s.If ?? ''), ($s.ContinueOnError ?? ''), ($s.Timeout ?? ''), $kind, $s.BodySha, $s.StripSha, $s.Line) -join "`t")
    }
}
Write-TextLf (Join-Path $OutRoot 'test/cap11a/ci-legacy-inventory.tsv') (($inv -join "`n") + "`n")
Write-Host "[migrate] wrote test/cap11a/ci-legacy-inventory.tsv ($($inv.Count - 1) rows)"

# ---------------------------------------------------------------------------
# 2. the merged order - one linear sequence, refusing on any conflict
# ---------------------------------------------------------------------------
$seqNames = @($byJob[$PLATFORMS[0]] | ForEach-Object { $_.Name })
$jobNames = @{}
foreach ($j in $PLATFORMS) { $jobNames[$j] = @($byJob[$j] | ForEach-Object { $_.Name }) }

$allNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($j in $PLATFORMS) { foreach ($n in $jobNames[$j]) { [void]$allNames.Add($n) } }

$pred = @{}
foreach ($n in $allNames) { $pred[$n] = New-Object System.Collections.Generic.HashSet[string] }
foreach ($j in $PLATFORMS) {
    $ns = $jobNames[$j]
    for ($i = 0; $i -lt $ns.Count; $i++) {
        for ($k = 0; $k -lt $i; $k++) { [void]$pred[$ns[$i]].Add($ns[$k]) }
    }
}
$merged = New-Object System.Collections.Generic.List[string]
$done = New-Object System.Collections.Generic.HashSet[string]
$remaining = New-Object System.Collections.Generic.HashSet[string]
foreach ($n in $allNames) { [void]$remaining.Add($n) }
# LOCALITY, not just correctness: any topological order preserves every leg's own
# order (asserted below), but one that jumps between legs on every step would make
# the sequence unreadable. Preferring to continue the leg the last step came from
# keeps each platform's head and each shard's block contiguous.
$lastJob = $PLATFORMS[0]
while ($remaining.Count -gt 0) {
    $picked = $null
    $probe = @($lastJob) + @($PLATFORMS | Where-Object { $_ -ne $lastJob })
    foreach ($j in $probe) {
        foreach ($n in $jobNames[$j]) {
            if (-not $remaining.Contains($n)) { continue }
            $ok = $true
            foreach ($p in $pred[$n]) { if (-not $done.Contains($p)) { $ok = $false; break } }
            if ($ok) { $picked = $n; $lastJob = $j; break }
        }
        if ($picked) { break }
    }
    if (-not $picked) {
        throw "step-order conflict: the four job orders cannot be merged into one sequence ($($remaining.Count) steps unresolved)"
    }
    $merged.Add($picked); [void]$done.Add($picked); [void]$remaining.Remove($picked)
}
foreach ($j in $PLATFORMS) {
    $sub = @($merged | Where-Object { $jobNames[$j] -contains $_ })
    if (($sub -join "`u{1}") -ne ($jobNames[$j] -join "`u{1}")) {
        throw "merged order would REORDER the $j leg - refusing"
    }
}
Write-Host "[migrate] merged order: $($merged.Count) distinct step names, no reorder on any leg"

# ---------------------------------------------------------------------------
# 3. slugs, applicability, and the per-name platform map
# ---------------------------------------------------------------------------
$byName = [ordered]@{}
foreach ($n in $merged) {
    $m = [ordered]@{}
    foreach ($j in $PLATFORMS) {
        $s = $byJob[$j] | Where-Object { $_.Name -eq $n }
        if ($s) { $m[$j] = $s }
    }
    $byName[$n] = $m
}

$usedSlug = @{}
function Get-Slug([string]$Name) {
    $s = $Name.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 72) {
        $s = $s.Substring(0, 72)
        $cut = $s.LastIndexOf('-')
        if ($cut -gt 40) { $s = $s.Substring(0, $cut) }
        $s = $s.Trim('-')
    }
    $base = $s
    $n = 2
    while ($usedSlug.ContainsKey($s)) { $s = "$base-$n"; $n++ }
    $usedSlug[$s] = $true
    return $s
}

function Get-Applicability([string[]]$Targets) {
    $set = @($PLATFORMS | Where-Object { $Targets -contains $_ })
    if ($set.Count -eq 4) { return $null }
    if ($set.Count -eq 3) {
        $missing = @($PLATFORMS | Where-Object { $set -notcontains $_ })
        return "inputs.target != '$($missing[0])'"
    }
    return (($set | ForEach-Object { "inputs.target == '$_'" }) -join ' || ')
}

# ---------------------------------------------------------------------------
# 4. emit the composite actions and collect the sequence entries
# ---------------------------------------------------------------------------
$actionsRoot = Join-Path $OutRoot '.github/actions'
if (Test-Path -LiteralPath $actionsRoot) { Remove-Item -Recurse -Force $actionsRoot }

$seq = New-Object System.Collections.Generic.List[object]
$map = New-Object System.Collections.Generic.List[string]
$map.Add("legacy_job`tlegacy_name`tlegacy_line`tdisposition`tnew_location")
$applic = New-Object System.Collections.Generic.List[string]
$applic.Add("ordinal`tname`tapplies_to")

$uploadSteps = New-Object System.Collections.Generic.List[object]
$ordinal = 0

foreach ($name in $merged) {
    $m = $byName[$name]
    $targets = @($m.Keys)
    $first = $m[$targets[0]]

    if ($first.IsUpload) {
        foreach ($t in $targets) { $uploadSteps.Add($m[$t]) }
        continue
    }

    $ordinal++
    $slug = Get-Slug $name

    # timeout: identical everywhere, or the tightest declared one (never the
    # loosest - a migration may not lengthen a bound, and it may not drop one)
    $timeouts = @($targets | ForEach-Object { $m[$_].Timeout } | Where-Object { $_ })
    $timeout = $null
    if ($timeouts.Count -gt 0) {
        $timeout = ($timeouts | ForEach-Object { [int]$_ } | Measure-Object -Minimum).Minimum
    }

    $entry = [pscustomobject]@{
        Ordinal   = $ordinal
        Name      = $name
        Slug      = $slug
        Targets   = $targets
        If        = $first.If
        Timeout   = $timeout
        Applies   = Get-Applicability $targets
        ContinueOnError = $first.ContinueOnError
        Lead      = $first.Lead
        Inline    = $first.PureUses
        NeedsInput = $false
    }

    if ($entry.Inline) {
        # a pure `uses:` step stays INLINE in the sequence. Checkout MUST: a
        # local composite action cannot be resolved before the repository is in
        # the workspace, and the others gain nothing from the indirection.
        $variants = @($targets | Group-Object { $m[$_].BodySha })
        if ($variants.Count -ne 1) {
            throw ("inline uses: step '" + $name + "' has divergent bodies across targets - not supported")
        }
        $entry | Add-Member -NotePropertyName InlineBody -NotePropertyValue $first.NormBody
        foreach ($t in $targets) {
            $map.Add(($t, $name, $m[$t].Line, 'inline', ".github/workflows/platform-leg.yml step $ordinal") -join "`t")
        }
    } else {
        $groups = @($targets | Group-Object { $m[$_].BodySha } | Sort-Object { $PLATFORMS.IndexOf($_.Group[0]) })
        $entry.NeedsInput = ($groups.Count -gt 1)
        $al = New-Object System.Collections.Generic.List[string]
        # THE STEP'S OWN COMMENTS TRAVEL WITH ITS BODY, not with the sequence. The
        # sequence file is the LIST - names, applicability and budgets - and it stays
        # readable in one screenful per shard only because the reasoning lives here,
        # beside the thing it reasons about.
        if ($entry.Lead.Count -gt 0) {
            foreach ($l in (Remove-CommonIndent $entry.Lead)) { $al.Add($l) }
            $al.Add('')
        }
        $al.Add("name: '$($name -replace "'", "''")'")
        $al.Add("description: 'CAP-11A: the body of the `"$($name -replace '"', '\"')`" step of the one platform-leg sequence.'")
        if ($entry.NeedsInput) {
            $al.Add('inputs:')
            $al.Add('  target:')
            $al.Add("    description: 'windows | linux | macos-x64 | macos-arm64'")
            $al.Add('    required: true')
        }
        $al.Add('runs:')
        $al.Add('  using: composite')
        $al.Add('  steps:')
        foreach ($g in $groups) {
            $gt = @($PLATFORMS | Where-Object { $g.Group -contains $_ })
            $body = $m[$gt[0]].NormBody
            $cond = if ($entry.NeedsInput) { Get-Applicability $gt } else { $null }
            # `if:` on the composite step is only about WHICH BODY, never about
            # whether the step runs: the sequence's own `if:` already decided that.
            $stepLines = New-Object System.Collections.Generic.List[string]
            $stepLines.Add("- name: $($gt -join ', ')")
            if ($cond) { $stepLines.Add("  if: `${{ $cond }}") }
            foreach ($b in $body) {
                # the step's own `if:`/`timeout-minutes:` live on the SEQUENCE step,
                # never inside the action (composite steps support neither faithfully)
                # `if:`, `timeout-minutes:` and `continue-on-error:` live on the
                # SEQUENCE step: the first two because a composite action cannot
                # carry them faithfully, and the third because GitHub ACCEPTS it
                # inside a composite action and ignores it - which would have
                # turned three best-effort GUI smokes into blocking gates.
                if ($b -match '^if:' -or $b -match '^timeout-minutes:' -or
                    $b -match '^continue-on-error:') { continue }
                $stepLines.Add(('  ' + $b).TrimEnd())
            }
            foreach ($l in (Add-Indent $stepLines 4)) { $al.Add($l) }
            foreach ($t in $gt) {
                $map.Add(($t, $name, $m[$t].Line, 'action', ".github/actions/$slug/action.yml") -join "`t")
            }
        }
        Write-TextLf (Join-Path $actionsRoot "$slug/action.yml") (($al -join "`n") + "`n")
    }
    $seq.Add($entry)
}

Write-Host "[migrate] emitted $((Get-ChildItem -Recurse -File -Path $actionsRoot).Count) composite actions"

# ---------------------------------------------------------------------------
# 5. the collection block: the 61 interleaved uploads, unioned per class
# ---------------------------------------------------------------------------
# CLASSES, and why each exists:
#   evidence     the four `cap7f-evidence-<target>` sets the aggregate reads
#   release      the two macOS inventory sets the release-inventory job reads
#   dist         the SDK archive and its manifest - the shipped product
#   records      every per-shard corpus a human downloads; nothing consumes them
#   diagnostics  `if: failure()` only, unchanged in purpose
$CLASS_OF = [ordered]@{
    'cap7f-evidence'   = 'evidence'
    'cap7m2-release'   = 'release'
    'pweb-sdk'         = 'dist'
}
function Get-ArtifactName([object]$Step) {
    foreach ($l in $Step.NormBody) {
        if ($l -match '^\s*name:\s*(\S+)\s*$') { return $Matches[1] }
    }
    throw "upload step '$($Step.Name)' declares no artifact name"
}
function Get-ArtifactPaths([object]$Step) {
    $out = @(); $inPath = $false
    foreach ($l in $Step.NormBody) {
        if ($l -match '^\s*path:\s*\|\s*$') { $inPath = $true; continue }
        if ($inPath) {
            if ($l.Trim() -eq '') { continue }
            if ($l -notmatch '^\s{2,}') { break }
            $out += $l.Trim()
        }
    }
    return $out
}
$classPaths = [ordered]@{ evidence = @(); release = @(); dist = @(); records = @(); diagnostics = @() }
$classIfNoFiles = @{ evidence = 'error'; release = 'error'; dist = 'warn'; records = 'warn'; diagnostics = 'ignore' }
foreach ($s in $uploadSteps) {
    $an = Get-ArtifactName $s
    $cls = 'records'
    if ($s.If -eq 'failure()') { $cls = 'diagnostics' }
    else {
        foreach ($k in $CLASS_OF.Keys) { if ($an.StartsWith($k)) { $cls = $CLASS_OF[$k]; break } }
    }
    $classPaths[$cls] += Get-ArtifactPaths $s
    $map.Add(($s.Job, $s.Name, $s.Line, "collection:$cls", "leg-$cls-`${target}") -join "`t")
}
foreach ($k in @($classPaths.Keys)) {
    $classPaths[$k] = @($classPaths[$k] | Sort-Object -Unique)
}
Write-Host ('[migrate] collection classes: ' + (($classPaths.Keys | ForEach-Object { "$_=$($classPaths[$_].Count) paths" }) -join ' '))
$classPaths | ConvertTo-Json -Depth 4 |
    Set-Content -NoNewline -Encoding utf8 (Join-Path $OutRoot 'test/cap11a/collection-paths.json')

Write-TextLf (Join-Path $OutRoot 'test/cap11a/ci-migration-map.tsv') (($map -join "`n") + "`n")

# ---------------------------------------------------------------------------
# 6. the sequence file
# ---------------------------------------------------------------------------
$RETENTION = @{ evidence = 90; release = 90; records = 90; dist = "`${{ inputs.long_retention && 90 || 14 }}"; diagnostics = 7 }
$UPLOAD_PIN = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4'
$ATTEMPTS = 3

$w = New-Object System.Collections.Generic.List[string]
$w.Add('# CAP-11A: THE ONE STEP SEQUENCE.')
$w.Add('#')
$w.Add('# Every platform leg runs THIS list, in this order. A step that cannot run on a')
$w.Add('# target carries an `if:` and appears in the run as `skipped` - never absent -')
$w.Add('# so the four legs extract to four IDENTICAL step-name sequences, which is the')
$w.Add('# premise `test/cap7f/check_cap7f_aggregate.ps1` exists to check and which')
$w.Add('# `test/cap11a/check_ci_sequence.ps1` measures from the run itself.')
$w.Add('#')
$w.Add('# Step BODIES live in `.github/actions/<slug>/action.yml`, one per step, because')
$w.Add('# `timeout-minutes` is unsupported on a composite-action step but supported on a')
$w.Add('# workflow step that `uses:` one - grouping several steps per action would have')
$w.Add('# deleted the per-step budgets that catch a hang while still letting the')
$w.Add('# collection block below run.')
$w.Add('#')
$w.Add('# NOTHING IS UPLOADED UNTIL EVERY GATE HAS RUN. The collection block is the last')
$w.Add('# thing on the leg, every one of its steps is `if: always()`, and its failure is')
$w.Add('# typed as infrastructure and forfeits no verdict (ledger: "NO GATE MAY DEPEND ON')
$w.Add('# AN UPLOAD HAVING SUCCEEDED", measured on hosted run 33955241980).')
$w.Add('')
$w.Add('name: platform leg')
$w.Add('')
$w.Add('on:')
$w.Add('  workflow_call:')
$w.Add('    inputs:')
foreach ($inp in @(
        @('target', 'string', 'true', 'windows | linux | macos-x64 | macos-arm64'),
        @('runner', 'string', 'true', 'the runs-on label for this target'),
        @('timeout_minutes', 'number', 'true', 'job backstop; the per-step budgets are the protection'),
        @('expect_arch', 'string', 'false', 'CAP7M_EXPECT_ARCH, asserted by the macOS gates'),
        @('runner_label', 'string', 'false', 'CAP7M_RUNNER_LABEL, asserted by the macOS gates'),
        @('long_retention', 'boolean', 'false', 'keep the distribution artifacts 90 days instead of 14'))) {
    $w.Add("      $($inp[0]):")
    $w.Add("        description: '$($inp[3])'")
    $w.Add("        type: $($inp[1])")
    $w.Add("        required: $($inp[2])")
}
$w.Add('')
$w.Add('permissions:')
$w.Add('  contents: read')
$w.Add('')
$w.Add('jobs:')
$w.Add('  leg:')
$w.Add('    name: ${{ inputs.target }}')
$w.Add('    runs-on: ${{ inputs.runner }}')
$w.Add('    timeout-minutes: ${{ inputs.timeout_minutes }}')
$w.Add('    env:')
$w.Add('      PWEB_CI_TARGET: ${{ inputs.target }}')
$w.Add('      CAP7M_EXPECT_ARCH: ${{ inputs.expect_arch }}')
$w.Add('      CAP7M_RUNNER_LABEL: ${{ inputs.runner_label }}')
$w.Add('    steps:')

# The CAP-11A repository gates. They run on EVERY leg, like every other contract
# check in this repository, because their evidence rows are per-target and four
# targets that disagree about the structure of the workflow they are running is
# exactly the kind of divergence this shard exists to make visible. They are
# placed immediately before the first CAP-7F evidence emitter: the emitter reads
# their records.
$CAP11A_GATES = @(
    @{ Name = 'CAP-11A structure gate (sizes, retention, timeouts, concurrency, no artifact read)'
       Script = 'test/cap11a/check_ci_structure.ps1'; Timeout = 5 },
    @{ Name = 'CAP-11A migration map - every legacy step accounted for'
       Script = 'test/cap11a/check_migration_map.ps1'; Timeout = 5 },
    @{ Name = 'CAP-7F evidence schema agreement (both emitters and the aggregator)'
       Script = 'test/cap7f/check_schema_agreement.ps1'; Timeout = 5 },
    @{ Name = 'CAP-11A bounded fetch retry - seeded transport, digest and exhaustion cases'
       Script = 'test/cap11a/check_pwebfetch.ps1'; Timeout = 5 },
    @{ Name = 'CAP-11A flake instrumentation (non-report cause, U3 drain order, fetch rows)'
       Script = 'test/cap11a/check_flake_instrumentation.ps1'; Timeout = 5 }
)
$gatesEmitted = $false
$emitted = New-Object System.Collections.Generic.List[object]

foreach ($e in $seq) {
    if (-not $gatesEmitted -and $e.Name.StartsWith('CAP-7F emit the')) {
        foreach ($g in $CAP11A_GATES) {
            $emitted.Add(@{ Name = $g.Name; Applies = ($PLATFORMS -join ',') })
            $w.Add("      - name: $($g.Name)")
            $w.Add("        timeout-minutes: $($g.Timeout)")
            $w.Add('        shell: pwsh')
            $w.Add('        run: |')
            $w.Add("          pwsh -NoProfile -File $($g.Script)")
            $w.Add("          if (`$LASTEXITCODE -ne 0) { throw '$($g.Name) FAILED' }")
            $w.Add('')
        }
        $gatesEmitted = $true
    }
    $emitted.Add(@{ Name = $e.Name; Applies = ($e.Targets -join ',') })
    if ($e.Inline -and $e.Lead.Count -gt 0) {
        foreach ($l in (Add-Indent (Remove-CommonIndent $e.Lead) 6)) { $w.Add($l) }
    }
    $w.Add("      - name: $($e.Name)")
    $conds = @()
    if ($e.If) { $conds += $e.If }
    if ($e.Applies) { $conds += $e.Applies }
    if ($conds.Count -gt 0) { $w.Add("        if: `${{ $($conds -join ' && ') }}") }
    if ($e.Timeout) { $w.Add("        timeout-minutes: $($e.Timeout)") }
    if ($e.ContinueOnError) { $w.Add("        continue-on-error: $($e.ContinueOnError)") }
    if ($e.Inline) {
        foreach ($b in $e.InlineBody) {
            if ($b -match '^if:' -or $b -match '^timeout-minutes:' -or
                $b -match '^continue-on-error:') { continue }
            $w.Add(('        ' + $b).TrimEnd())
        }
    } else {
        $w.Add("        uses: ./.github/actions/$($e.Slug)")
        if ($e.NeedsInput) {
            $w.Add('        with:')
            $w.Add('          target: ${{ inputs.target }}')
        }
    }
    $w.Add('')
}

if (-not $gatesEmitted) { throw 'no CAP-7F evidence emitter found - the CAP-11A gates have no anchor' }

# --- the collection block ---------------------------------------------------
$w.Add('      # ===================== CAP-11A COLLECTION BLOCK =====================')
$w.Add('      # The ONLY uploads on this leg, and they come after EVERY gate. Each')
$w.Add('      # class is attempted at most three times; an attempt runs only when the')
$w.Add('      # one before it failed, and none of them can fail the leg. The typing')
$w.Add('      # step then writes what actually happened, so "leg green, evidence not')
$w.Add('      # uploaded" is a state the aggregate can name instead of a leg that')
$w.Add('      # merely lost thirty steps.')
$emitted.Add(@{ Name = 'CAP-11A stage the collection and measure it'; Applies = ($PLATFORMS -join ',') })
$w.Add('      - name: CAP-11A stage the collection and measure it')
$w.Add('        if: always()')
$w.Add('        timeout-minutes: 10')
$w.Add('        shell: pwsh')
$w.Add('        run: |')
$w.Add('          pwsh -NoProfile -File test/cap11a/stage_collection.ps1 -Target "${{ inputs.target }}" -JobStatus "${{ job.status }}"')
$w.Add('          if ($LASTEXITCODE -ne 0) { throw ''CAP-11A collection staging FAILED'' }')
$w.Add('')
foreach ($cls in @('evidence', 'records', 'release', 'dist', 'diagnostics')) {
    if ($classPaths[$cls].Count -eq 0) { continue }
    $n = if ($cls -eq 'diagnostics') { 1 } else { $ATTEMPTS }
    for ($a = 1; $a -le $n; $a++) {
        $id = "collect_${cls}_$a"
        $cond = if ($cls -eq 'diagnostics') { 'failure()' } else { 'always()' }
        if ($a -gt 1) { $cond = "always() && steps.collect_${cls}_$($a - 1).outcome == 'failure'" }
        if ($cls -eq 'release') { $cond = "$cond && (inputs.target == 'macos-x64' || inputs.target == 'macos-arm64')" }
        $w.Add("      - name: CAP-11A collect the leg $cls (attempt $a of $n)")
        $w.Add("        id: $id")
        $w.Add("        if: `${{ $cond }}")
        $w.Add('        continue-on-error: true')
        $w.Add('        timeout-minutes: 15')
        $w.Add("        uses: $UPLOAD_PIN")
        $w.Add('        with:')
        $w.Add("          name: leg-$cls-`${{ inputs.target }}")
        $w.Add("          if-no-files-found: $($classIfNoFiles[$cls])")
        $w.Add("          retention-days: $($RETENTION[$cls])")
        $w.Add('          overwrite: true')
        $w.Add("          path: build/cap11a/collect/$cls")
        $w.Add('')
        $applies = if ($cls -eq 'release') { 'macos-x64,macos-arm64' } else { ($PLATFORMS -join ',') }
        $emitted.Add(@{ Name = "CAP-11A collect the leg $cls (attempt $a of $n)"; Applies = $applies })
    }
}
$w.Add('      # NEVER fails the leg: a leg that passed its gates and could not reach the')
$w.Add('      # artifact service is green with `evidence_uploaded=false`, and the')
$w.Add('      # aggregate refuses while NAMING it infrastructure. A leg that failed a')
$w.Add('      # gate is red for that gate, which is a different sentence.')
$emitted.Add(@{ Name = 'CAP-11A type the collection outcome'; Applies = ($PLATFORMS -join ',') })
$w.Add('      - name: CAP-11A type the collection outcome')
$w.Add('        if: always()')
$w.Add('        timeout-minutes: 5')
$w.Add('        shell: pwsh')
$w.Add('        env:')
foreach ($cls in @('evidence', 'records', 'release', 'dist')) {
    if ($classPaths[$cls].Count -eq 0) { continue }
    for ($a = 1; $a -le $ATTEMPTS; $a++) {
        $w.Add("          PWEB_UP_${cls}_${a}: `${{ steps.collect_${cls}_$a.outcome }}")
    }
}
$w.Add('        run: |')
$w.Add('          pwsh -NoProfile -File test/cap11a/type_collection.ps1 -Target "${{ inputs.target }}"')
$w.Add('          if ($LASTEXITCODE -ne 0) { throw ''CAP-11A collection typing FAILED'' }')

# a duplicate step name would make the extracted sequence ambiguous, and the
# applicability check would then be comparing the wrong row
$dupes = @($emitted | Group-Object { $_.Name } | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -gt 0) {
    throw ("duplicate step name(s) in the sequence: " + (($dupes | ForEach-Object { $_.Name }) -join '; '))
}
$n2 = 0
foreach ($e in $emitted) { $n2++; $applic.Add(($n2, $e.Name, $e.Applies) -join "`t") }
Write-TextLf (Join-Path $OutRoot 'test/cap11a/step-applicability.tsv') (($applic -join "`n") + "`n")
Write-Host "[migrate] wrote ci-migration-map.tsv ($($map.Count - 1) rows) and step-applicability.tsv ($($applic.Count - 1) rows)"

Write-TextLf (Join-Path $OutRoot '.github/workflows/platform-leg.yml') (($w -join "`n") + "`n")
# ---------------------------------------------------------------------------
# 7. docs/ci-migration.md - old step -> new location, for every one of them
# ---------------------------------------------------------------------------
$d = New-Object System.Collections.Generic.List[string]
$d.Add('# The CI migration map (CAP-11A)')
$d.Add('')
$d.Add('`.github/workflows/ci.yml` was one file of 271,637 bytes and 5,824 lines')
$d.Add('carrying six jobs, and the four platform jobs declared 155, 92, 99 and 99 steps')
$d.Add('that were kept in step by copying. CAP-11A replaced it with **one sequence** -')
$d.Add('`.github/workflows/platform-leg.yml`, called four times from')
$d.Add('`.github/workflows/ci.yml` - and **one composite action per step** under')
$d.Add('`.github/actions/`. This table says where each legacy step went.')
$d.Add('')
$d.Add('## How to resolve a `ci.yml:<line>` citation')
$d.Add('')
$d.Add('Ratified artifacts cite the legacy file by line number and **stay as written**:')
$d.Add('a closed shard records what it measured, and rewriting its citations would be')
$d.Add('rewriting its record.')
$d.Add('')
$d.Add('**Resolve by STEP NAME, not by line number.** A line number was only ever true')
$d.Add('of the file at the commit that cited it - `ci.yml` grew by ~160 KB across CAP-8')
$d.Add('to CAP-10, so `ci.yml:630` means different things in a CAP-7M0 artifact and in a')
$d.Add('CAP-10D2 one. The step NAME is stable, and it is what this table is keyed on. So:')
$d.Add('')
$d.Add('1. `git show <the citing commit>:.github/workflows/ci.yml` - the file is intact at')
$d.Add('   every commit up to and including the twin-run commit, and every commit before')
$d.Add('   it. Read the cited line there.')
$d.Add('2. Scroll up to that line''s `- name:` - that is the step it belongs to.')
$d.Add('3. Find that name in the table below and read across to the new location.')
$d.Add('')
$d.Add('The *Legacy lines* column carries the line numbers as of the twin-run commit, so a')
$d.Add('citation made against that commit resolves directly;')
$d.Add('`test/cap11a/ci-legacy-inventory.tsv` carries the same numbers in machine form.')
$d.Add('')
$d.Add('## The one ratified restructuring')
$d.Add('')
$d.Add('Every step keeps its name, its body, its `shell:`, its `if:`, its')
$d.Add('`timeout-minutes:` and its position on its own leg. The single exception is the')
$d.Add('**61 interleaved `actions/upload-artifact` steps** (103 rows, one per job). They')
$d.Add('do not enter the sequence: an upload between two gates is how hosted run')
$d.Add('`33955241980` cost the macos-x64 leg about thirty later steps and two capability')
$d.Add('verdicts. Their declared paths are unioned per class into the collection block at')
$d.Add('the end of the leg, and `test/cap11a/collection-paths.json` is that union.')
$d.Add('')
$d.Add('| legacy artifact | class | now inside |')
$d.Add('|---|---|---|')
$seenArt = @{}
foreach ($s in $uploadSteps) {
    $an = Get-ArtifactName $s
    if ($seenArt.ContainsKey($an)) { continue }
    $seenArt[$an] = $true
    $cls = 'records'
    if ($s.If -eq 'failure()') { $cls = 'diagnostics' }
    else { foreach ($k in $CLASS_OF.Keys) { if ($an.StartsWith($k)) { $cls = $CLASS_OF[$k]; break } } }
    $d.Add("| ``$an`` | $cls | ``leg-$cls-<target>``, at each file's repository-relative path |")
}
$d.Add('')
$d.Add('## Every step')
$d.Add('')
$d.Add('| legacy step | legs | legacy lines | new location |')
$d.Add('|---|---|---|---|')
foreach ($name in $merged) {
    $m = $byName[$name]
    $rows = @($map | Where-Object { ($_ -split "`t")[1] -ceq $name })
    if ($rows.Count -eq 0) { continue }
    $legs = (@($m.Keys) -join ', ')
    $lines = ((@($m.Keys) | ForEach-Object { $m[$_].Line }) -join ', ')
    $loc = (($rows | ForEach-Object { ($_ -split "`t")[4] }) | Sort-Object -Unique) -join ', '
    $esc = $name -replace '\|', '\|'
    $d.Add("| ``$esc`` | $legs | $lines | ``$loc`` |")
}
$d.Add('')
$d.Add('## The two consumer jobs')
$d.Add('')
$d.Add('`macos-release-inventory` and `cap7-aggregate` moved from `ci.yml` into')
$d.Add('`.github/workflows/ci.yml` (the caller) unchanged in what they check. Both now')
$d.Add('read the per-leg collection artifacts rather than the per-shard ones, and the')
$d.Add('aggregate gained `test/cap11a/check_ci_sequence.ps1`, which measures the premise')
$d.Add('the whole comparison rests on: that the four legs ran the same step sequence.')
Write-TextLf (Join-Path $OutRoot 'docs/ci-migration.md') (($d -join "`n") + "`n")
Write-Host "[migrate] wrote docs/ci-migration.md ($($d.Count) lines)"

$bytes = (Get-Item (Join-Path $OutRoot '.github/workflows/platform-leg.yml')).Length
Write-Host "[migrate] wrote .github/workflows/platform-leg.yml ($($seq.Count) sequence steps, $bytes bytes, $($w.Count) lines)"

# the declared post-migration amendments, so one command reproduces everything
& (Join-Path $PSScriptRoot 'apply_amendments.ps1')
Write-Host '[migrate] DONE'
