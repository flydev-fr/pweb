# CAP-10D0 contract cross-checks: the claims a public `pweb build` makes
# about the tree it is added to, measured over the SOURCE.
#
# Checkout-only: no toolchain, no network, no display, no build output. It
# runs in every platform job and on any dev host, before anything is
# compiled, so a violation is a red step rather than a red suite an hour
# later.
#
# WHAT IT MEASURES, and why each one is here rather than in a suite:
#
#   1  ONE EXECUTION PATH. The set of production units that call
#      PWebCliExecute is exactly the four ratified callers - the doctor's
#      probe, `run`, the pipeline and the dev loop - and pweb.cli.build is
#      not among them and names no process API at all. A suite could not
#      say this: it is a claim about units that are NOT reachable.
#   2  NO NEW STAGE, NO MOVED BOUND. The ten stage names and the eight
#      PWEB_CLI_PIPE_* bounds, cross-checked against the contract document.
#   3  THE PUBLIC SURFACE. Five commands in the parser, five in the help,
#      and not one of the options CAP-10D0 deliberately did not ratify.
#   4  THE TWICE-SPELLED NAMES of CAP-10C1's ledger entry (d), at the
#      source, so a unit that stopped being linked cannot make the suite's
#      value comparison vacuous.
#   5  THE QUOTING HELPER IS ADOPTED. No CAP-10 gate calls Start-Process
#      with an argument array any more; every one of them goes through
#      test/cap10d0/psargs.ps1.
#   6  THE DOCUMENTS. docs/build-contract.md exists, docs/index.md
#      cross-links it, and the four contracts that used to say `build` is an
#      unknown command no longer do.
#   7  NOTHING FROM CAP-10D1 OR D2. No profile, installer, archive or
#      signing word reached the build path.
#
# Emits build/cap10d0/contracts.json and exits nonzero on any violation.
#
# Usage: pwsh test/cap10d0/check_cap10d0_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}
function ReadText([string]$Rel) {
    if (-not (Test-Path -LiteralPath $Rel)) { throw "missing $Rel" }
    return [System.IO.File]::ReadAllText($Rel)
}

# --- 1. one execution path --------------------------------------------------
# The engine itself DEFINES PWebCliExecute; every other unit that names it
# CALLS it, and the ratified set of callers is four - one per command family.
# CAP-10D0 adds a fifth command and no fifth caller: `build` reaches a child
# only through pweb.cli.pipeline, which is the whole of the one-caller
# property the CAP-10C closure handed over.
$callers = New-Object System.Collections.Generic.List[string]
foreach ($f in (Get-ChildItem -Path 'tools/pweb' -Filter '*.pas')) {
    if ($f.Name -eq 'pweb.cli.process.pas') { continue }
    $t = [System.IO.File]::ReadAllText($f.FullName)
    if ($t -match 'PWebCliExecute\s*\(') { $callers.Add($f.Name) }
}
$callerList = (($callers | Sort-Object) -join ',')
$facts['execute_callers'] = $callerList
$expectedCallers = 'pweb.cli.dev.pas,pweb.cli.pipeline.pas,' +
    'pweb.cli.probe.pas,pweb.cli.run.pas'
if ($callerList -cne $expectedCallers) {
    Violation ("the set of PWebCliExecute callers is [$callerList]; " +
        "CAP-10D0 inherits [$expectedCallers] and adds none")
}

# and the build driver names NO process API of any kind, by any spelling
$buildSrc = ReadText 'tools/pweb/pweb.cli.build.pas'
$procApis = @('PWebCliExecute', 'PWebCliChildSpawn', 'PWebCliChildWait',
    'PWebCliChildStop', 'PWebCliChildKill', 'CreateProcess', 'ShellExecute',
    'fpExecv', 'fpExecve', 'fpFork', 'popen', 'ExecuteProcess', 'RunCommand')
$hits = @()
foreach ($api in $procApis) {
    if ($buildSrc -match [regex]::Escape($api)) { $hits += $api }
}
$facts['build_driver_process_apis'] = ($hits -join ',')
if ($hits.Count -gt 0) {
    Violation ('pweb.cli.build names a process API: ' + ($hits -join ', ') +
        ' -- the public build driver calls the pipeline and reads a disk')
}
# it also carries no platform conditional: the target arrives as a value
if ($buildSrc -match '\{\$ifdef\s+(OSWINDOWS|UNIX|DARWIN|LINUX)') {
    Violation 'pweb.cli.build carries a platform conditional'
}
$facts['build_driver_conditionals'] =
    ([regex]::Matches($buildSrc, '\{\$if(n?def)?\s')).Count

# --- 2. no new stage, no moved bound ----------------------------------------
$pipeSrc = ReadText 'tools/pweb/pweb.cli.pipeline.pas'
$stageNames = @('open', 'toolchain', 'stage_sdk', 'install', 'typecheck',
    'build', 'pack', 'compile', 'layout', 'verify')
foreach ($s in $stageNames) {
    if ($pipeSrc -notmatch "Result := '$s';") {
        Violation "pweb.cli.pipeline no longer names the stage '$s'"
    }
}
$facts['stage_names'] = ($stageNames -join ',')
# the enumeration itself must still hold exactly ten
$enumMatch = [regex]::Match($pipeSrc,
    'TPWebCliStageKind = \(\s*([^)]*)\)')
if (-not $enumMatch.Success) {
    Violation 'TPWebCliStageKind could not be read'
} else {
    $members = @(($enumMatch.Groups[1].Value -split ',') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $facts['stage_count'] = $members.Count
    if ($members.Count -ne 10) {
        Violation ("TPWebCliStageKind has $($members.Count) members; the " +
            'CAP-10C1 pipeline has ten and CAP-10D0 adds none')
    }
}
$toolchain = ReadText 'tools/pweb/pweb.cli.toolchain.pas'
$bounds = [ordered]@{
    PWEB_CLI_PIPE_NPM_MS         = '600000'
    PWEB_CLI_PIPE_TSC_MS         = '300000'
    PWEB_CLI_PIPE_BUILD_MS       = '300000'
    PWEB_CLI_PIPE_PACK_MS        = '120000'
    PWEB_CLI_PIPE_FPC_MS         = '900000'
    PWEB_CLI_PIPE_MAX_FILE_BYTES = '268435456'
    PWEB_CLI_PIPE_MAX_TREE_FILES = '4096'
    PWEB_CLI_PIPE_MAX_TREE_DEPTH = '24'
}
foreach ($k in $bounds.Keys) {
    if ($toolchain -notmatch "$k\s*=\s*$($bounds[$k])\s*;") {
        Violation "$k is not $($bounds[$k]) -- a CAP-10C1 bound moved"
    }
}
$facts['pipe_bounds'] = ($bounds.Keys -join ',')
# the mutation set, at the source: four prefixes and no fifth
$setMatch = [regex]::Match($pipeSrc,
    'function PWebCliMutationSet[\s\S]*?SetLength\(Result,\s*(\d+)\)')
if ((-not $setMatch.Success) -or ($setMatch.Groups[1].Value -ne '4')) {
    Violation 'the project-mutation set is no longer exactly four prefixes'
}
$facts['mutation_prefixes'] = if ($setMatch.Success) {
    [int]$setMatch.Groups[1].Value } else { 0 }

# --- 3. the public surface --------------------------------------------------
$argsSrc = ReadText 'tools/pweb/pweb.cli.args.pas'
$reportSrc = ReadText 'tools/pweb/pweb.cli.report.pas'
foreach ($cmd in 'Create', 'Doctor', 'Run', 'Dev', 'Build') {
    if ($argsSrc -notmatch "pcc$cmd\b") {
        Violation "pweb.cli.args no longer defines pcc$cmd"
    }
}
foreach ($cmd in 'create', 'doctor', 'run', 'dev', 'build') {
    if ($argsSrc -notmatch "token = '$cmd'") {
        Violation "pweb.cli.args does not accept the token '$cmd'"
    }
    if ($reportSrc -notmatch "pweb $cmd") {
        Violation "pweb.cli.report does not advertise 'pweb $cmd'"
    }
}
$facts['advertised_commands'] = 'create,doctor,run,dev,build'
# THE OPTIONS CAP-10D0 DELIBERATELY DID NOT RATIFY. Each absence is a
# contract: an option exposed before its semantics are ratified is an option
# that can never be taken back, and the four below are exactly the ones a
# reader of another build tool reaches for first.
$unratified = @('--profile', '--target', '--clean', '--release', '--debug',
    '--watch', '--install', '--output', '--force')
$present = @()
foreach ($o in $unratified) {
    if ($argsSrc -match "name = '$o'") { $present += $o }
}
$facts['unratified_options_present'] = ($present -join ',')
if ($present.Count -gt 0) {
    Violation ('pweb.cli.args defines an option CAP-10D0 did not ratify: ' +
        ($present -join ', '))
}
# and no new usage cause: the taxonomy is the CAP-10A one
$usageMatch = [regex]::Match($argsSrc, 'TPWebCliUsage = \(\s*([^)]*)\)')
if ($usageMatch.Success) {
    $causes = @(($usageMatch.Groups[1].Value -split ',') |
        ForEach-Object { ($_ -replace '(?s)/{2,}[^\r\n]*', '').Trim() } |
        Where-Object { $_ -match '^pcu' })
    $facts['usage_causes'] = $causes.Count
    if ($causes.Count -ne 13) {
        Violation ("TPWebCliUsage has $($causes.Count) members; CAP-10A " +
            'ratified thirteen and CAP-10D0 adds none')
    }
}

# --- 4. the twice-spelled names (CAP-10C1 ledger (d)) -----------------------
function ConstOf([string]$Rel, [string]$Name) {
    $m = [regex]::Match((ReadText $Rel), "$Name\s*=\s*'([^']*)'")
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}
$pairs = @(
    @{ A = @('tools/pweb/pweb.cli.pack.pas', 'PWEB_PACK_BUNDLE')
       B = @('tools/pweb/pweb.cli.run.pas', 'PWEB_CLI_RUN_BUNDLE') },
    @{ A = @('tools/pweb/pweb.cli.frontend.pas', 'PWEB_FE_NODE_MODULES')
       B = @('tools/pweb/pweb.cli.toolset.pas', 'PWEB_NPM_NODE_MODULES') }
)
foreach ($p in $pairs) {
    $a = ConstOf $p.A[0] $p.A[1]
    $b = ConstOf $p.B[0] $p.B[1]
    if (($null -eq $a) -or ($null -eq $b)) {
        Violation "$($p.A[1]) or $($p.B[1]) could not be read"
    } elseif ($a -cne $b) {
        Violation ("$($p.A[1])='$a' and $($p.B[1])='$b' name one thing and " +
            'disagree -- CAP-10C1 ledger entry (d)')
    }
}
$facts['twice_spelled_pairs'] = $pairs.Count

# --- 5. the quoting helper is adopted ---------------------------------------
# C0-12 (b) / C1-11 (a): `Start-Process -ArgumentList <array>` joins without
# quoting. Every CAP-10 gate now goes through one helper, and this is what
# stops the next one from being written the old way.
$rawCalls = @()
$notAdopted = @()
foreach ($f in (Get-ChildItem -Path 'test' -Recurse -Filter '*.ps1' |
                Where-Object { $_.FullName -match 'cap10' })) {
    $rel = $f.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    $t = [System.IO.File]::ReadAllText($f.FullName)
    if ($t -match '(?m)^\s*[^#\r\n]*Start-Process\s+-FilePath') {
        $rawCalls += $rel
    }
    if (($t -match 'Start-PWebProcess\s+-FilePath') -and
        ($t -notmatch 'psargs\.ps1')) {
        $notAdopted += $rel
    }
}
$facts['raw_start_process_gates'] = ($rawCalls -join ',')
$facts['unsourced_helper_gates'] = ($notAdopted -join ',')
if ($rawCalls.Count -gt 0) {
    Violation ('a CAP-10 gate still calls Start-Process directly: ' +
        ($rawCalls -join ', ') + ' -- a path with a space would split its ' +
        'argument vector')
}
if ($notAdopted.Count -gt 0) {
    Violation ('a CAP-10 gate calls Start-PWebProcess without dot-sourcing ' +
        'the helper: ' + ($notAdopted -join ', '))
}
if (-not (Test-Path -LiteralPath 'test/cap10d0/psargs.ps1')) {
    Violation 'test/cap10d0/psargs.ps1 is absent'
}

# --- 6. the documents -------------------------------------------------------
foreach ($doc in 'docs/build-contract.md', 'docs/index.md') {
    if (-not (Test-Path -LiteralPath $doc)) { Violation "missing $doc" }
}
$index = ReadText 'docs/index.md'
if (-not $index.Contains('build-contract.md')) {
    Violation 'docs/index.md does not cross-link build-contract.md'
}
$buildDoc = ReadText 'docs/build-contract.md'
foreach ($phrase in 'pweb build [--project <path>]',
                    'stage_aside_rename_reclaim',
                    'one_rename_no_release',
                    '.pweb-release.tmp', '.pweb-old.tmp') {
    if (-not $buildDoc.Contains($phrase)) {
        Violation "docs/build-contract.md does not record: $phrase"
    }
}
# the four contracts that used to say `build` is an unknown command
foreach ($doc in 'docs/cli-contract.md', 'docs/pipeline-contract.md',
                 'docs/supervision-contract.md', 'docs/dev-contract.md') {
    $t = ReadText $doc
    if ($t -match 'build`? is (still )?an \*\*unknown command\*\*' -or
        $t -match 'build`? is (still )?an unknown command') {
        Violation ("$doc still says `build` is an unknown command; CAP-10D0 " +
            'exposes it')
    }
}
$facts['docs_superseded'] = 4

# --- 7. nothing from CAP-10D1 or CAP-10D2 -----------------------------------
# The build path must not have grown a profile, an installer, an archive or
# a signature: those are the NEXT shards, and a word that reached this one is
# scope that reached it too.
$d1Words = @('innosetup', 'iss', 'codesign', 'signtool', 'notariz',
    'dmg', 'tarball', 'installer', 'msix')
$leaked = @()
foreach ($w in $d1Words) {
    if ($buildSrc -match "(?i)\b$w") { $leaked += $w }
}
$facts['d1_words_in_build_driver'] = ($leaked -join ',')
if ($leaked.Count -gt 0) {
    Violation ('the build driver names a CAP-10D1/D2 concern: ' +
        ($leaked -join ', '))
}

# --- verdict ----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10d0 | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap10d0/contracts.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10D0 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-10D0] contract cross-checks PASS'
