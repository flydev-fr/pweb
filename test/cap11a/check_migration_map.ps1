# CAP-11A: every step of the legacy workflow is accounted for, and its body is
# the same bytes it was.
#
# WHY IT READS A COMMITTED SNAPSHOT RATHER THAN THE OLD FILE. The old
# `.github/workflows/ci.yml` is removed in its own commit, and a gate that
# needed it would stop working exactly when the migration finished. So the
# migration recorded what the 445 legacy steps WERE -
# `test/cap11a/ci-legacy-inventory.tsv`, name and body digest per step - and
# this compares the new structure against that snapshot forever after.
#
# THE ONE NORMALIZATION. A workflow step sits at six spaces and a
# composite-action step at four, so bodies are compared after removing the
# indent every line of a block shares. Nothing inside a line changes, and a
# `run: |` block scalar is indentation-relative, so the script text is
# identical. `if:` and `timeout-minutes:` are compared separately because they
# move to the SEQUENCE step - a composite action cannot carry a timeout.
#
# THE ONE RATIFIED EXCEPTION. The 61 interleaved `actions/upload-artifact` steps
# are not in the sequence. They were the defect: an upload between two gates
# meant a gate could be skipped because an upload failed (hosted run
# 33955241980, thirty steps lost on macos-x64). Their path sets are unioned into
# the collection block, and this gate checks that every one of their declared
# paths survives in `test/cap11a/collection-paths.json` - a path that quietly
# stopped being collected would be evidence nobody would miss until they looked
# for it.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$failures = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) { $script:failures.Add($m); Write-Host "MIGRATION VIOLATION: $m" }

$PLATFORMS = @('windows', 'linux', 'macos-x64', 'macos-arm64')
$LEG = '.github/workflows/platform-leg.yml'
$DOC = 'docs/ci-migration.md'

function Read-Norm([string]$Path) { return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n") }
function Get-Sha16([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant().Substring(0, 16)
    } finally { $sha.Dispose() }
}
function Remove-CommonIndent([string[]]$Lines) {
    $min = [int]::MaxValue
    foreach ($l in $Lines) {
        if ($l.Trim() -eq '') { continue }
        $n = $l.Length - $l.TrimStart(' ').Length
        if ($n -lt $min) { $min = $n }
    }
    if ($min -eq [int]::MaxValue) { $min = 0 }
    return @($Lines | ForEach-Object { if ($_.Length -ge $min) { $_.Substring($min) } else { $_.TrimStart(' ') } })
}

# --- the three committed records -------------------------------------------
foreach ($p in @('test/cap11a/ci-legacy-inventory.tsv', 'test/cap11a/ci-migration-map.tsv',
                 'test/cap11a/collection-paths.json', 'test/cap11a/step-applicability.tsv', $LEG)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}
$inv = @(Get-Content -LiteralPath 'test/cap11a/ci-legacy-inventory.tsv' | Select-Object -Skip 1 |
    Where-Object { $_.Trim() } | ForEach-Object {
        $c = $_ -split "`t"
        if ($c.Count -lt 11) { Violation "malformed inventory row: $_"; return }
        [pscustomobject]@{ Job = $c[0]; Ordinal = [int]$c[1]; Name = $c[2]; Shell = $c[3]
                           If = $c[4]; ContinueOnError = $c[5]; Timeout = $c[6]
                           Kind = $c[7]; BodySha = $c[8]; StripSha = $c[9]; Line = $c[10] }
    })
$map = @(Get-Content -LiteralPath 'test/cap11a/ci-migration-map.tsv' | Select-Object -Skip 1 |
    Where-Object { $_.Trim() } | ForEach-Object {
        $c = $_ -split "`t"
        if ($c.Count -lt 5) { Violation "malformed migration row: $_"; return }
        [pscustomobject]@{ Job = $c[0]; Name = $c[1]; Line = $c[2]; Disposition = $c[3]; Location = $c[4] }
    })
Write-Host "[cap11a] legacy inventory: $($inv.Count) steps; migration map: $($map.Count) rows"
if ($inv.Count -ne 445) { Violation "the legacy inventory holds $($inv.Count) steps, not the 445 the migration recorded" }

# --- 1. every legacy step has exactly one disposition -----------------------
foreach ($s in $inv) {
    $hit = @($map | Where-Object { $_.Job -eq $s.Job -and $_.Name -ceq $s.Name })
    if ($hit.Count -eq 0) { Violation "legacy step $($s.Job)/'$($s.Name)' is in no migration row"; continue }
    if ($hit.Count -gt 1) { Violation "legacy step $($s.Job)/'$($s.Name)' has $($hit.Count) migration rows" }
}
foreach ($m in $map) {
    $hit = @($inv | Where-Object { $_.Job -eq $m.Job -and $_.Name -ceq $m.Name })
    if ($hit.Count -eq 0) { Violation "migration row $($m.Job)/'$($m.Name)' names no legacy step" }
}

# --- 2. the sequence carries every non-upload step, with its keys -----------
$legLines = (Read-Norm $LEG) -split "`n"
$stepStarts = @()
for ($i = 0; $i -lt $legLines.Count; $i++) {
    if ($legLines[$i] -match '^      - name: (.*)$') { $stepStarts += ,@($i, $Matches[1]) }
}
$seq = @{}
for ($k = 0; $k -lt $stepStarts.Count; $k++) {
    $start = $stepStarts[$k][0]
    $end = if ($k + 1 -lt $stepStarts.Count) { $stepStarts[$k + 1][0] } else { $legLines.Count }
    # a step with a name line and no body would reverse the range and hash two
    # unrelated lines as its body
    $body = if ($end -gt $start + 1) { @($legLines[($start + 1)..($end - 1)]) } else { @() }
    while ($body.Count -gt 0 -and $body[-1].Trim() -eq '') { $body = $body[0..($body.Count - 2)] }
    $seq[$stepStarts[$k][1]] = [pscustomobject]@{
        Index = $k + 1
        Body  = Remove-CommonIndent @($body | Where-Object { $_ -notmatch '^\s*#' })
    }
}
Write-Host "[cap11a] the sequence declares $($seq.Count) steps"

function Get-SeqKey([object]$Step, [string]$Key) {
    foreach ($l in $Step.Body) { if ($l -match "^$([regex]::Escape($Key)):\s*(.*)$") { return $Matches[1].Trim() } }
    return ''
}

foreach ($s in @($inv | Where-Object { $_.Kind -ne 'upload' })) {
    if (-not $seq.ContainsKey($s.Name)) {
        Violation "legacy step $($s.Job)/'$($s.Name)' is absent from the sequence"
        continue
    }
    $step = $seq[$s.Name]
    # timeout: preserved, or tightened where the legacy legs disagreed. NEVER
    # loosened, and never dropped.
    $got = Get-SeqKey $step 'timeout-minutes'
    if ($s.Timeout) {
        if (-not $got) { Violation "'$($s.Name)' lost its $($s.Timeout)-minute budget" }
        elseif ([int]$got -gt [int]$s.Timeout) {
            Violation "'$($s.Name)' budget went from $($s.Timeout) to $got minutes"
        }
    }
    # the step's own `if:` (only `always()` occurs) must still be there, ANDed
    # with the applicability the split introduced
    if ($s.If) {
        $sif = Get-SeqKey $step 'if'
        if ($sif -notlike "*$($s.If)*") { Violation "'$($s.Name)' lost its condition '$($s.If)'" }
    }
    # `continue-on-error` is the one key GitHub ACCEPTS inside a composite action
    # and silently ignores. A best-effort GUI smoke that lost it would become a
    # blocking gate, and the run would look like a new regression.
    if ($s.ContinueOnError) {
        $sce = Get-SeqKey $step 'continue-on-error'
        if ($sce -cne $s.ContinueOnError) {
            Violation "'$($s.Name)' lost continue-on-error: $($s.ContinueOnError)"
        }
    }
}

# --- 3. bodies are byte-identical -------------------------------------------
# THE AMENDMENT TABLE, and why one exists. Two legacy bodies pointed AT the file
# this shard replaces, so preserving them byte-for-byte would have preserved a
# broken reference. `test/cap11a/post-migration-amendments.tsv` names each such
# body, says why, and carries the digest it is allowed to have - so an amended
# step is still pinned, just to a different number, and a body edited without
# being declared here still trips this gate.
$AMEND = @{}
$amendFile = 'test/cap11a/post-migration-amendments.tsv'
if (Test-Path -LiteralPath $amendFile) {
    foreach ($r in @(Get-Content -LiteralPath $amendFile | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
        $c = $r -split "`t"
        if ($c.Count -lt 4) { Violation "malformed amendment row: $r"; continue }
        foreach ($j in ($c[1] -split ',')) { $AMEND["$($j.Trim())|$($c[0])"] = $c[3].Trim() }
    }
}
Write-Host "[cap11a] $($AMEND.Count) declared post-migration amendment(s)"

# AN AMENDMENT THAT MATCHES NOTHING IS A ROW NOBODY CHECKS. Every declaration
# above is keyed `job|name`, and the loop below only ever LOOKS one up - so a
# row naming a step that is not in the migration map (a step this repository
# ADDED to the sequence after the migration, which is the other thing this
# table has to be able to record) would sit here being ignored, and its digest
# would assert nothing at all. Each row must therefore answer to one of two
# things: a legacy step in the migration map, or a step that exists in the
# sequence today - and in the second case its digest is measured here, against
# the same stripped-body rule the legacy comparison uses.
$mapKeys = @{}
foreach ($m in $map) { $mapKeys["$($m.Job)|$($m.Name)"] = $true }
$addedChecked = 0
foreach ($k in @($AMEND.Keys)) {
    if ($mapKeys.ContainsKey($k)) { continue }
    $parts = $k -split '\|', 2
    $aName = $parts[1]
    if (-not $seq.ContainsKey($aName)) {
        Violation ("declared amendment '$aName' ($($parts[0])) names neither a legacy step " +
            'nor a step in the sequence today -- a declaration nothing answers to is a ' +
            'digest that pins nothing')
        continue
    }
    # the step is in the sequence and uses a composite action; measure the
    # branch body exactly as the legacy comparison does
    $aSlug = ($aName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $af = ".github/actions/$aSlug/action.yml"
    if (-not (Test-Path -LiteralPath $af)) {
        Violation "declared amendment '$aName' names a missing action: $af"
        continue
    }
    $alines = (Read-Norm $af) -split "`n"
    $bstart = @()
    for ($i = 0; $i -lt $alines.Count; $i++) {
        if ($alines[$i] -match '^    - name: (.*)$') { $bstart += , @($i, $Matches[1]) }
    }
    if ($bstart.Count -eq 0) { Violation "$af declares no composite step"; continue }
    $bEnd = if ($bstart.Count -gt 1) { $bstart[1][0] } else { $alines.Count }
    $abody = @($alines[($bstart[0][0] + 1)..($bEnd - 1)] |
        Where-Object { $_ -notmatch '^\s*if:\s*\$\{\{ inputs\.target' })
    while ($abody.Count -gt 0 -and $abody[-1].Trim() -eq '') { $abody = $abody[0..($abody.Count - 2)] }
    $agot = Get-Sha16 ((Remove-CommonIndent $abody) -join "`n")
    if ($agot -ne $AMEND[$k]) {
        Violation "added step '$aName' action body digest $agot != declared $($AMEND[$k]) in $af"
    }
    $addedChecked++
}
Write-Host "[cap11a] $addedChecked declared amendment(s) for steps ADDED after the migration"

$amended = 0
$checked = 0
foreach ($m in @($map | Where-Object { $_.Disposition -eq 'action' -or $_.Disposition -eq 'inline' })) {
    $sArr = @($inv | Where-Object { $_.Job -eq $m.Job -and $_.Name -ceq $m.Name })
    if ($sArr.Count -eq 0) { continue }
    $s = $sArr[0]
    $want = $s.StripSha
    $isAmended = $AMEND.ContainsKey("$($m.Job)|$($m.Name)")
    if ($isAmended) { $want = $AMEND["$($m.Job)|$($m.Name)"]; $amended++ }
    if ($m.Disposition -eq 'inline') {
        if (-not $seq.ContainsKey($m.Name)) { continue }
        $body = @($seq[$m.Name].Body | Where-Object { $_ -notmatch '^if:' -and $_ -notmatch '^timeout-minutes:' })
        $got = Get-Sha16 ((Remove-CommonIndent $body) -join "`n")
        if ($got -ne $want) {
            Violation "'$($m.Name)' ($($m.Job)) inline body digest $got != expected $want"
        }
        $checked++
        continue
    }
    $af = $m.Location
    if (-not (Test-Path -LiteralPath $af)) { Violation "'$($m.Name)' names a missing action: $af"; continue }
    $alines = (Read-Norm $af) -split "`n"
    # the composite's branches: `    - name: <targets>` down to the next one
    $bstart = @()
    for ($i = 0; $i -lt $alines.Count; $i++) {
        if ($alines[$i] -match '^    - name: (.*)$') { $bstart += ,@($i, $Matches[1]) }
    }
    if ($bstart.Count -eq 0) { Violation "$af declares no composite step"; continue }
    $branch = $null
    foreach ($b in $bstart) {
        $t = @($b[1] -split ',\s*')
        if ($bstart.Count -eq 1 -or ($t -contains $m.Job)) { $branch = $b; break }
    }
    if (-not $branch) { Violation "$af has no branch for $($m.Job)"; continue }
    $k = [array]::IndexOf(@($bstart | ForEach-Object { $_[0] }), $branch[0])
    $end = if ($k + 1 -lt $bstart.Count) { $bstart[$k + 1][0] } else { $alines.Count }
    $body = @($alines[($branch[0] + 1)..($end - 1)] | Where-Object { $_ -notmatch '^\s*if:\s*\$\{\{ inputs\.target' })
    while ($body.Count -gt 0 -and $body[-1].Trim() -eq '') { $body = $body[0..($body.Count - 2)] }
    $got = Get-Sha16 ((Remove-CommonIndent $body) -join "`n")
    if ($got -ne $want) {
        Violation "'$($m.Name)' ($($m.Job)) action body digest $got != expected $want in $af"
    }
    $checked++
}
Write-Host "[cap11a] $checked step bodies compared ($amended against a declared amendment, $($checked - $amended) against the legacy digest)"

# --- 4. every legacy upload path is still collected -------------------------
$spec = Get-Content -Raw -LiteralPath 'test/cap11a/collection-paths.json' | ConvertFrom-Json
$allPaths = New-Object System.Collections.Generic.HashSet[string]
foreach ($c in $spec.PSObject.Properties.Name) { foreach ($p in @($spec.$c)) { [void]$allPaths.Add($p) } }
$uploadRows = @($map | Where-Object { $_.Disposition -like 'collection:*' })
Write-Host "[cap11a] $($uploadRows.Count) legacy upload steps folded into $($spec.PSObject.Properties.Name.Count) classes, $($allPaths.Count) distinct paths"
# 103 rows because an upload step exists once per job; 61 DISTINCT names.
$uploadNames = @($uploadRows | ForEach-Object { $_.Name } | Sort-Object -Unique)
if ($uploadRows.Count -ne 103) { Violation "the map folds $($uploadRows.Count) upload rows, not the 103 the migration recorded" }
if ($uploadNames.Count -ne 61) { Violation "the map folds $($uploadNames.Count) distinct upload steps, not the 61 the migration recorded" }
foreach ($c in $spec.PSObject.Properties.Name) {
    if (@($spec.$c).Count -eq 0) { Violation "collection class '$c' collects nothing" }
}
# EVERY LEGACY UPLOAD PATH, held to the union. The header has always claimed
# this; until now it checked only that the classes were non-empty, which is a
# different and much weaker sentence. `legacy-upload-paths.tsv` is the record
# the migration made of what each upload declared.
$lupPath = 'test/cap11a/legacy-upload-paths.tsv'
if (-not (Test-Path -LiteralPath $lupPath)) {
    Violation "missing $lupPath -- the legacy upload paths cannot be checked"
} else {
    $lup = @(Get-Content -LiteralPath $lupPath | Select-Object -Skip 1 |
        Where-Object { $_.Trim() } | ForEach-Object { , ($_ -split "`t") })
    $lost = New-Object System.Collections.Generic.List[string]
    foreach ($r in $lup) {
        if ($r.Count -lt 4) { Violation "malformed upload-path row: $($r -join '|')"; continue }
        if (-not $allPaths.Contains($r[3])) { $lost.Add("$($r[1]) :: $($r[3])") }
    }
    if ($lost.Count -gt 0) {
        Violation ("$($lost.Count) legacy upload path(s) are collected by nothing, e.g. '$($lost[0])'")
    } else {
        Write-Host "[cap11a] all $($lup.Count) legacy upload paths survive in the collection union"
    }
}

# --- 5. the migration document names every legacy step ----------------------
if (-not (Test-Path -LiteralPath $DOC)) {
    Violation "missing $DOC"
} else {
    $docText = Read-Norm $DOC
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($inv | ForEach-Object { $_.Name } | Sort-Object -Unique)) {
        if (-not $docText.Contains($n)) { $missing.Add($n) }
    }
    if ($missing.Count -gt 0) {
        Violation "$DOC does not name $($missing.Count) legacy step(s), e.g. '$($missing[0])'"
    } else {
        Write-Host "[cap11a] $DOC names all $(@($inv | ForEach-Object { $_.Name } | Sort-Object -Unique).Count) distinct legacy step names"
    }
}

New-Item -ItemType Directory -Force build/cap11a | Out-Null
$out = [ordered]@{
    schema             = 1
    legacy_steps       = $inv.Count
    mapped_steps       = $map.Count
    sequence_steps     = $seq.Count
    bodies_compared    = $checked
    bodies_amended     = $amended
    uploads_folded     = $uploadRows.Count
    collection_paths   = $allPaths.Count
    violations         = $failures.Count
}
$json = ($out | ConvertTo-Json -Depth 4)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/migration.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CAP-11A MIGRATION MAP FAILED ($($failures.Count) violation(s))"
    exit 1
}
Write-Host "CAP11A_MIGRATION_PASS legacy=$($inv.Count) bodies=$checked uploads=$($uploadRows.Count)"
exit 0
