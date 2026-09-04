# CAP-10D1: the packaging gates - W1..W8 (Windows), L1..L2 (Linux),
# M1..M3 (macOS), A1..A5 and the long-path bisection.
#
# THE REAL `pweb build --profile`, on a REAL project the REAL `pweb create`
# scaffolded, followed on Windows by a REAL silent install, a REAL launch
# and a REAL silent uninstall, and on POSIX by a REAL extraction that has to
# answer 42. Nothing here drives the packaging driver through a private
# entry point: the whole point of this shard is that a developer reaches it
# by name, so the gate reaches it by name too.
#
# WHAT IT NEVER DOES: reimplement a rule. Every refusal it exercises is the
# CLI's own, every digest it compares is one the gate that owns it recorded,
# and every process it looks at it found by MEMBERSHIP or by pid, never by
# name.
#
# THE SPACED PATH IS BUILT IN, as CAP-10D0 built it in: every project lives
# under a directory whose name carries a space, so the C0-12 (b) quoting
# defect would split every --project and every --profile on every leg.
#
# THE PROJECT IS Pas2JS ON PURPOSE. Packaging is indifferent to the frontend
# kind - it consumes the committed release and nothing else - and a Pas2JS
# build needs no npm, no network and no lockfile, which is the difference
# between a gate that runs in two minutes and one that runs in twenty. The
# claim that packaging is frontend-blind is itself measured: the release
# inventory the archive reproduces is whatever the pipeline committed.
#
# Emits build/cap10d1/cli-<target>.json for the CAP-7F aggregation, plus
# build/cap10d1/pack-corpus.txt (from the suite) and the driver report.
#
# Usage: pwsh test/cap10d1/run_cap10d1_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

# the ONE pwsh argument-quoting helper: every project path here carries a
# space, so this gate depends on it more than any other
. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')
# the CAP-10C1 membership-scoped samplers, dot-sourced rather than
# reimplemented: one rule, measured in the C0, C1, C2, C3, D0 and D1 gates
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10d1'
New-Item -ItemType Directory -Force $work | Out-Null

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Key, [string]$Value) { $rows[$Key] = $Value }
function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        $failures.Add($Message)
        Write-Host "GATE FAILURE: $Message"
    }
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }
function Sha256File([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function SortOrdinal([string[]]$Items) {
    $copy = [string[]]::new($Items.Count)
    [Array]::Copy($Items, $copy, $Items.Count)
    [Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return $copy
}
# the `<rel> <size> <sha256>` projection of a tree, bytewise-sorted - the
# same shape the pipeline's own inventory has, so a reader comparing the two
# sees one form
function InventoryOf([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{ Text = ''; Count = 0 }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $lines.Add("$rel $($f.Length) $(Sha256File $f.FullName)")
    }
    $sorted = SortOrdinal $lines.ToArray()
    return [pscustomobject]@{
        Text = (($sorted -join "`n") + "`n"); Count = $sorted.Count
    }
}
function TargetName {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'arm64' }
        default { 'other' }
    }
    return "$os-$arch"
}
$target = TargetName
Row 'target' $target
Row 'profiles_for_target' $(if ($IsWindows) { 'normal,offline,fixed-runtime' }
                            else { 'archive' })

# THE PINNED Pas2JS IS PUT ON PATH BY THIS GATE, deliberately and visibly,
# exactly as the CAP-10B2, C1, C3 and D0 gates do it and for the same
# reason: the pipeline resolves tools on PATH by ratified design, and every
# CI job fetches the pinned compiler into deps/ without putting it there.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
}
if ($null -eq (Get-Command pas2js -ErrorAction SilentlyContinue)) {
    throw ('CAP-10D1 preconditions FAILED: pas2js is not on PATH and no ' +
        'pinned copy exists under deps/')
}

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
$suite = Join-Path $work "bin/d1tests$exeSuffix"
$driver = Join-Path $work "bin/pwebpackdrv$exeSuffix"
$helper = Join-Path $repoRoot "build/cap10c0/bin/pwebchild$exeSuffix"
foreach ($pre in $pweb, $suite, $driver) {
    Require (Test-Path -LiteralPath $pre) `
        "precondition absent: $pre -- run test/cap10d1/build_cap10d1 first"
}
if ($failures.Count -gt 0) {
    throw "CAP-10D1 preconditions FAILED: $($failures.Count)"
}

function RunCli([string[]]$CliArgs, [string]$WorkDir, [int]$TimeoutMs = 2400000) {
    $so = Join-Path $work 'cli-stdout.txt'
    $se = Join-Path $work 'cli-stderr.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $p = Start-PWebProcess -FilePath $pweb -ArgumentList $CliArgs -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        $p.WaitForExit(10000) | Out-Null
        Require $false "pweb $($CliArgs -join ' ') did not exit inside $TimeoutMs ms"
    }
    $p.WaitForExit()
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
        Err = if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    }
}
function SummaryField([string]$Text, [string]$Field) {
    foreach ($line in ($Text -split "`n")) {
        if ($line -match "^  $([regex]::Escape($Field))\s+(.+?)\s*$") {
            return $Matches[1]
        }
    }
    return ''
}

# --- 1. the headless suite and its corpus -----------------------------------
# /noenter is the WINDOWS switch; the POSIX runner reads it as a FILENAME,
# prints its usage and exits 0 - a green verdict over nothing. So the option
# is passed on Windows only, and the corpus is REQUIRED to carry at least one
# decision whatever the platform.
$suiteLog = Join-Path $work 'd1tests.log'
$suiteArgs = if ($IsWindows) { @('/noenter') } else { @() }
$sp = Start-PWebProcess -FilePath $suite -ArgumentList $suiteArgs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $suiteLog `
    -RedirectStandardError (Join-Path $work 'd1tests-stderr.log')
Write-Host ([System.IO.File]::ReadAllText($suiteLog))
Row 'pack_suite' $(if ($sp.ExitCode -eq 0) { 'PASS' } else { 'FAIL' })
Require ($sp.ExitCode -eq 0) "the CAP-10D1 suite exited $($sp.ExitCode)"

$corpusPath = Join-Path $work 'pack-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite wrote no decision corpus'
if (Test-Path -LiteralPath $corpusPath) {
    $corpusText = [System.IO.File]::ReadAllText($corpusPath).Replace("`r`n", "`n")
    $decisions = @($corpusText -split "`n" | Where-Object {
        ($_ -ne '') -and (-not $_.StartsWith('#')) })
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        Row 'pack_digest' (-join ($sha.ComputeHash(
            [System.Text.UTF8Encoding]::new($false).GetBytes($corpusText)) |
            ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
    Row 'pack_corpus_lines' "$($decisions.Count)"
    Require ($decisions.Count -ge 25) `
        "the decision corpus carries only $($decisions.Count) decision(s)"
    $abs = @($decisions | Where-Object { ($_ -match ':[\\/]') -or ($_ -match '\|/') })
    Require ($abs.Count -eq 0) `
        "a corpus line names an absolute path: $($abs | Select-Object -First 1)"
    # ledger C1-11 (b): the rollback is EXERCISED, not described
    Row 'rollback_seam_exercised' (Bool ($corpusText -match
        '(?m)^rollback\|previous_release_restored\|true$'))
    Require ($corpusText -match '(?m)^rollback\|byte_identical\|true$') `
        'A5: the hadOld rollback did not restore the previous release byte-identically'
} else {
    Row 'pack_digest' 'unmeasured'
    Row 'pack_corpus_lines' '0'
    Row 'rollback_seam_exercised' 'false'
}

# --- 2. the contract cross-checks, read back --------------------------------
$contractsFile = Join-Path $work 'contracts.json'
Require (Test-Path -LiteralPath $contractsFile) `
    'build/cap10d1/contracts.json is absent -- run check_cap10d1_contracts.ps1 first'
if (Test-Path -LiteralPath $contractsFile) {
    $c = Get-Content $contractsFile -Raw | ConvertFrom-Json
    Require ("$($c.verdict)" -ceq 'PASS') 'the CAP-10D1 contract cross-checks did not PASS'
    Row 'pack_execute_callers' "$($c.execute_callers)"
    Row 'pack_build_driver_spawns' $(
        if ("$($c.build_driver_process_apis)" -eq '') { '0' } else { '1' })
    Row 'pack_code_twins' "$($c.code_twins)"
    Row 'pack_pins_checked' "$($c.pins_checked)"
    Row 'pack_pins_mismatched' $(
        if ("$($c.pins_mismatched)" -eq '') { 'none' } else { "$($c.pins_mismatched)" })
    Row 'long_path_bound_chars' "$($c.long_path_bound)"
    # A3: the source half of the no-signing, no-secret claim. `codesign -dv`
    # below is the runtime half, on the only target that has one
    Row 'signing_identity_used' $(
        if ("$($c.signing_or_network_hits)" -eq '') { 'false' } else { 'true' })
    Row 'secrets_read' $(
        if ("$($c.signing_or_network_hits)" -eq '') { '0' } else { '1' })
    Row 'profile_identity_rule' 'bundleid_literal'
    Row 'profile_index_shape' 'cap6b4'
} else {
    foreach ($k in 'pack_execute_callers', 'pack_build_driver_spawns',
                   'pack_code_twins', 'pack_pins_checked',
                   'pack_pins_mismatched', 'long_path_bound_chars',
                   'signing_identity_used', 'secrets_read',
                   'profile_identity_rule', 'profile_index_shape') {
        Row $k 'unmeasured'
    }
}

# --- 3. the public surface --------------------------------------------------
$help = RunCli @('build', '--help') $repoRoot 60000
Require ($help.Code -eq 0) "`pweb build --help` exited $($help.Code)"
Row 'build_profile_available' (Bool ($help.Out -match '--profile'))
Require ($help.Out -match '--profile') '`pweb build --help` does not advertise --profile'
# the ratified names, and the near miss that must NOT be accepted
$badProfile = RunCli @('build', '--profile', 'fixed') $repoRoot 60000
Row 'profile_fixed_shorthand_refused' (Bool ($badProfile.Code -eq 2))
Require ($badProfile.Code -eq 2) `
    "`--profile fixed` exited $($badProfile.Code); the ratified name is fixed-runtime"
# --profile belongs to `build` and to nothing else
$foreignCmd = RunCli @('run', '--profile', 'archive') $repoRoot 60000
Require (($foreignCmd.Code -eq 2) -and
         ($foreignCmd.Err -match 'option_not_for_command')) `
    '--profile is accepted by a command other than build'
Row 'profile_option_scoped_to_build' 'true'

# --- 4. the projects, created by the REAL CLI, AT A SPACED PATH -------------
$spaced = Join-Path $work 'spaced work'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $spaced
New-Item -ItemType Directory -Force $spaced | Out-Null
Row 'gate_project_path_has_space' (Bool ($spaced.Contains(' ')))
$cwd = Join-Path $work 'unrelated-cwd'
New-Item -ItemType Directory -Force $cwd | Out-Null

# two projects with DIFFERENT bundleIds and the SAME shape: the second is
# what makes the collision claim a measurement rather than arithmetic
$created = RunCli @('create', 'demopack', '--ui', 'pas2js',
    '--bundle-id', 'com.example.demopack') $spaced 300000
Require ($created.Code -eq 0) "create demopack exited $($created.Code)"
$created = RunCli @('create', 'altpack', '--ui', 'pas2js',
    '--bundle-id', 'org.other.altpack') $spaced 300000
Require ($created.Code -eq 0) "create altpack exited $($created.Code)"
$projA = Join-Path $spaced 'demopack'
$projB = Join-Path $spaced 'altpack'
function ReleaseDirOf([string]$Proj) {
    return (Join-Path (Join-Path (Join-Path $Proj 'dist') $target) 'release')
}
function DistDirOf([string]$Proj, [string]$Profile) {
    return (Join-Path (Join-Path (Join-Path (Join-Path $Proj 'dist') $target) `
        'artifacts') $Profile)
}

# --- 5. A2: `pweb build` WITHOUT --profile is byte-for-byte CAP-10D0 --------
$plain = RunCli @('build', '--project', $projA) $cwd
Require ($plain.Code -eq 0) "the plain build exited $($plain.Code)"
# THE SUMMARY, BY NAME rather than by count - the CAP-10D0 B10 idiom: the
# five indented rows plus the header line are what that shard froze as six
# fields, and neither of the two CAP-10D1 adds may appear without --profile
foreach ($field in 'ui', 'target', 'release', 'app.pwb', 'bytes') {
    Require ((($plain.Err -split "`n") |
        Where-Object { $_ -match "^  $([regex]::Escape($field))\s" }).Count -eq 1) `
        "A2: the plain summary has no single '$field' row"
}
$extraRows = @(($plain.Err -split "`n") |
    Where-Object { $_ -match '^  (artifact|sha256)\s' })
Row 'd0_summary_extra_rows_without_profile' "$($extraRows.Count)"
Require ($extraRows.Count -eq 0) `
    "A2: a plain build printed $($extraRows.Count) packaging summary row(s)"
# THE ARTIFACT DIRECTORY IS `artifacts`, NOT `dist`. The CAP-10C1 pipeline
# already owns <output>/<target>/dist as the Pas2JS static assembly
# directory, and this gate is what found that on its first real run.
$distRoot = Join-Path (Join-Path (Join-Path $projA 'dist') $target) 'artifacts'
Row 'd0_no_artifacts_without_profile' (Bool (-not (Test-Path -LiteralPath $distRoot)))
Require (-not (Test-Path -LiteralPath $distRoot)) `
    'A2: a build without --profile created an artifacts/ directory'
$releaseBefore = InventoryOf (ReleaseDirOf $projA)
Require ($releaseBefore.Count -gt 0) 'the plain build committed no release'

# --- 6. A1: a profile foreign to this target -------------------------------
$foreignName = if ($IsWindows) { 'archive' } else { 'normal' }
$foreign = RunCli @('build', '--project', $projA, '--profile', $foreignName) $cwd 120000
Row 'profile_foreign_exit' "$($foreign.Code)"
Row 'profile_foreign_cause' $(
    if ($foreign.Err -match 'profile_not_for_target') { 'profile_not_for_target' }
    else { 'other' })
Require ($foreign.Code -eq 2) `
    "A1: --profile $foreignName exited $($foreign.Code); the ratified refusal is 2"
Require ($foreign.Err -match 'profile_not_for_target') `
    'A1: the foreign-profile refusal is not typed profile_not_for_target'
$afterForeign = InventoryOf (ReleaseDirOf $projA)
Require ($afterForeign.Text -ceq $releaseBefore.Text) `
    'A1: a refused profile touched the release'
Require (-not (Test-Path -LiteralPath $distRoot)) `
    'A1: a refused profile created an artifacts/ directory'
Row 'profile_foreign_built_nothing' 'true'

# --- 7. the per-target packaging legs ---------------------------------------
# [string[]] on purpose: PowerShell UNWRAPS a one-element array out of an
# if-expression, so `$profiles[0]` on POSIX would be the character 'a' and
# the re-run below would ask for a profile that does not exist. Measured -
# the gate's own second build exited 2 with profile_unknown
[string[]]$profiles = if ($IsWindows) { @('normal', 'offline', 'fixed-runtime') }
                      else { @('archive') }
$artifacts = [ordered]@{}
$indexes = [ordered]@{}
foreach ($profile in $profiles) {
    $bound = if ($profile -eq 'fixed-runtime') { 3600000 } else { 2400000 }
    $r = RunCli @('build', '--project', $projA, '--profile', $profile) $cwd $bound
    Write-Host "----- $profile (stderr) -----"
    Write-Host $r.Err
    Require ($r.Code -eq 0) "$profile`: the packaging build exited $($r.Code)"
    foreach ($field in 'ui', 'target', 'release', 'app.pwb', 'bytes',
                       'artifact', 'sha256') {
        Require ((($r.Err -split "`n") |
            Where-Object { $_ -match "^  $([regex]::Escape($field))\s" }).Count -eq 1) `
            "$profile`: the summary has no single '$field' row"
    }
    $logical = SummaryField $r.Err 'artifact'
    $sha = SummaryField $r.Err 'sha256'
    $dir = DistDirOf $projA $profile
    $index = Join-Path $dir 'release-index.json'
    Require (Test-Path -LiteralPath $index) "$profile`: no release-index.json"
    if (Test-Path -LiteralPath $index) {
        $doc = Get-Content $index -Raw | ConvertFrom-Json
        # THE CAP-6b4 SHAPE, entry for entry: schema 1 and exactly four keys
        Require ($doc.schema -eq 1) "$profile`: the index is not schema 1"
        Require ($doc.profiles.Count -eq 1) "$profile`: the index names $($doc.profiles.Count) profiles"
        $entry = $doc.profiles[0]
        $keys = SortOrdinal @($entry.PSObject.Properties.Name)
        Require (($keys -join ',') -ceq 'bytes,filename,profile,sha256') `
            "$profile`: the index entry keys are [$($keys -join ',')]"
        Require ($entry.profile -ceq $profile) "$profile`: the index names '$($entry.profile)'"
        $artifactPath = Join-Path $dir $entry.filename
        Require (Test-Path -LiteralPath $artifactPath) `
            "$profile`: the index names an artifact that did not land"
        if (Test-Path -LiteralPath $artifactPath) {
            $real = Sha256File $artifactPath
            Require ($entry.sha256 -ceq $real) `
                "$profile`: the index digest is not the artifact's"
            Require ($entry.bytes -eq (Get-Item -LiteralPath $artifactPath).Length) `
                "$profile`: the index size is not the artifact's"
            Require ($sha -ceq $real) `
                "$profile`: the summary digest is not the artifact's"
            $artifacts[$profile] = $artifactPath
            $indexes[$profile] = $entry
        }
        # the artifact is NEVER named setup.exe, in any casing
        Require (-not ($entry.filename -imatch '^setup\.exe$')) `
            "$profile`: the artifact is named setup.exe"
    }
    Require ($logical -match ("dist/$([regex]::Escape($target))/artifacts/" +
             [regex]::Escape($profile) + '/')) `
        "$profile`: the summary artifact path is '$logical'"
    # W8 / the release is the INPUT and must not move
    $after = InventoryOf (ReleaseDirOf $projA)
    Require ($after.Text -ceq $releaseBefore.Text) `
        "$profile`: packaging altered the release it packaged"
    # and no staging sibling survives
    $targetDir = Join-Path (Join-Path $projA 'dist') $target
    foreach ($sibling in '.pweb-pack.tmp', '.pweb-dist-old.tmp') {
        Require (-not (Test-Path -LiteralPath (Join-Path $targetDir $sibling))) `
            "$profile`: the sibling $sibling survived"
    }
}
Row 'release_untouched_by_packaging' 'true'
Row 'windows_offline_built' $(
    if ($IsWindows) { Bool ($artifacts.Contains('offline')) } else { 'not_applicable' })
Row 'windows_fixed_built' $(
    if ($IsWindows) { Bool ($artifacts.Contains('fixed-runtime')) } else { 'not_applicable' })

# --- 8. W8 / L2: the artifact directory is REPLACED, and deterministically --
$firstProfile = $profiles[0]
$firstSha = if ($artifacts.Contains($firstProfile)) { Sha256File $artifacts[$firstProfile] } else { '' }
$firstDistInv = InventoryOf (DistDirOf $projA $firstProfile)
$again = RunCli @('build', '--project', $projA, '--profile', $firstProfile) $cwd
Require ($again.Code -eq 0) "the second packaging build exited $($again.Code)"
$secondDistInv = InventoryOf (DistDirOf $projA $firstProfile)
Require ($secondDistInv.Count -eq $firstDistInv.Count) `
    'the replaced artifact directory holds a different number of files'
$secondSha = if ($artifacts.Contains($firstProfile)) { Sha256File $artifacts[$firstProfile] } else { '' }
# THE DETERMINISM CLAIM. On POSIX the archive writer is this repository's and
# the bytes must be identical; on Windows the Inno compiler stamps its own
# output and the claim is the INVENTORY's shape, recorded rather than pinned
if ($IsWindows) {
    Row 'archive_deterministic' 'not_applicable'
    Row 'windows_artifact_replaced' (Bool ($secondDistInv.Count -eq $firstDistInv.Count))
} else {
    Row 'archive_deterministic' (Bool ($firstSha -ceq $secondSha))
    Require ($firstSha -ceq $secondSha) `
        'L2: two builds of the same release produced different archive bytes'
    Row 'windows_artifact_replaced' 'not_applicable'
}
$targetDir = Join-Path (Join-Path $projA 'dist') $target
foreach ($sibling in '.pweb-pack.tmp', '.pweb-dist-old.tmp') {
    Require (-not (Test-Path -LiteralPath (Join-Path $targetDir $sibling))) `
        "the sibling $sibling survived the replacement"
}

# --- 9. L1 / M1: the archive's inventory, modes and extracted run -----------
if (-not $IsWindows) {
    $archive = $artifacts['archive']
    $extract = Join-Path $work 'extracted'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $extract
    New-Item -ItemType Directory -Force $extract | Out-Null
    # extracted by the PLATFORM's own tar, never by a reader written here:
    # the claim is that an ordinary tar reads this archive, and a bespoke
    # extractor would be measuring the writer against itself
    Require (($null -ne $archive) -and ($archive -ne '')) `
        'L1/M1: the archive profile produced no artifact to extract'
    $tarArgs = @('-xzf', "$archive", '-C', "$extract")
    & tar @tarArgs
    Require ($LASTEXITCODE -eq 0) 'L1/M1: the archive could not be extracted'
    $stem = [System.IO.Path]::GetFileName($archive) -replace '\.tar\.gz$', ''
    $root = Join-Path $extract $stem
    Require (Test-Path -LiteralPath $root) `
        "L1/M1: the archive has no single top-level directory named $stem"
    $extracted = InventoryOf $root
    # THE PARITY CLAIM: the same relative paths, the same sizes, the same
    # per-file digests as the release the build committed
    Row 'linux_archive_inventory_equals_release' $(
        if ($IsMacOS) { 'not_applicable' } else { Bool ($extracted.Text -ceq $releaseBefore.Text) })
    Row 'macos_archive_inventory_equals_release' $(
        if ($IsMacOS) { Bool ($extracted.Text -ceq $releaseBefore.Text) } else { 'not_applicable' })
    Require ($extracted.Text -ceq $releaseBefore.Text) `
        'L1/M1: the extracted archive is not the release, file for file'
    # the modes, which are the whole reason this writer exists
    $logical = if ($IsMacOS) {
        Join-Path $root "demopack.app/Contents/MacOS/demopack"
    } else {
        Join-Path $root 'demopack'
    }
    # `-c` is GNU and `-f` is BSD, and they are not near-synonyms: `-f` on
    # GNU stat asks about the FILESYSTEM, which is what this leg first
    # reported as a file mode. One reader per family, chosen by target
    $mode = if ($IsMacOS) { (& stat -f '%Lp' $logical) }
            else { (& stat -c '%a' $logical) }
    Row 'archive_program_mode' "$mode"
    Require ("$mode" -eq '755') `
        "L1/M1: the extracted program's mode is $mode, not 755"
    # AND IT RUNS, from an unrelated working directory
    $so = Join-Path $work 'extracted-stdout.txt'
    $se = Join-Path $work 'extracted-stderr.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '20000'
    $ep = Start-PWebProcess -FilePath $logical -PassThru -NoNewWindow `
        -WorkingDirectory $cwd -RedirectStandardOutput $so `
        -RedirectStandardError $se
    if (-not $ep.WaitForExit(180000)) {
        try { $ep.Kill() } catch { }
        $ep.WaitForExit(10000) | Out-Null
        Require $false 'L1/M1: the extracted application did not exit inside 180 s'
    }
    $ep.WaitForExit()
    Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
    $out = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
    Write-Host "----- extracted run (stdout) -----"; Write-Host $out
    Write-Host "----- extracted run (stderr) -----"
    Write-Host $(if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' })
    $value = -1
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^\w+: ready (\{.*\})\s*$') {
            $value = ($Matches[1] | ConvertFrom-Json).value
        }
    }
    Row 'linux_archive_run' $(if ($IsMacOS) { 'not_applicable' } else { "$value" })
    Row 'macos_archive_run' $(if ($IsMacOS) { "$value" } else { 'not_applicable' })
    Require ($value -eq 42) `
        "L1/M1: the extracted application answered $value rather than 42"

    # M2: the signing posture, OBSERVED rather than claimed
    if ($IsMacOS) {
        $app = Join-Path $root 'demopack.app'
        $cs = (& codesign -dv --verbose=4 $app 2>&1 | Out-String)
        [System.IO.File]::WriteAllText((Join-Path $work 'codesign.txt'), $cs)
        $observation = 'unsigned'
        if ($cs -match '(?m)^Signature=adhoc') { $observation = 'adhoc' }
        elseif ($cs -match '(?m)^Authority=') { $observation = 'signed_identity' }
        Row 'macos_codesign_observation' $observation
        Require ($observation -ne 'signed_identity') `
            'M2: the bundle carries a signing identity; this shard signs with none'
        # M3: the bundle identity IS the descriptor's bundleId, and the
        # Info.plist is the CAP-10C1 rule's - unchanged by packaging
        $plist = Join-Path $app 'Contents/Info.plist'
        $plistText = [System.IO.File]::ReadAllText($plist)
        Row 'macos_bundle_identity' (Bool ($plistText -match
            '<key>CFBundleIdentifier</key>\s*<string>com\.example\.demopack</string>'))
        Require ($plistText -match
            '<key>CFBundleIdentifier</key>\s*<string>com\.example\.demopack</string>') `
            'M3: CFBundleIdentifier is not the descriptor bundleId'
    } else {
        Row 'macos_codesign_observation' 'not_applicable'
        Row 'macos_bundle_identity' 'not_applicable'
    }
} else {
    foreach ($k in 'linux_archive_inventory_equals_release',
                   'macos_archive_inventory_equals_release',
                   'archive_program_mode', 'linux_archive_run',
                   'macos_archive_run', 'macos_codesign_observation',
                   'macos_bundle_identity') {
        Row $k 'not_applicable'
    }
}

# --- 10. the Windows-only legs ----------------------------------------------
# W1, W4, W5, W6, W7 and the long-path bisection live in their own file for
# one reason: they are the only legs that INSTALL SOFTWARE on the machine
# running them, and a reader auditing what this gate does to a runner should
# be able to read that half on its own. Every row they set is typed
# `not_applicable` here on the two POSIX families, never left absent - a
# field that exists on one target is a field the aggregator cannot compare.
if ($IsWindows) {
    . (Join-Path $PSScriptRoot 'windows_legs.ps1')
} else {
    foreach ($k in 'windows_install_exit', 'windows_installed_layout',
                   'windows_profile_marker', 'windows_installed_rpc',
                   'windows_uninstall_residue',
                   'windows_normal_install_run_uninstall',
                   'windows_profile_collision',
                   'windows_two_bundleids_side_by_side',
                   'windows_profile_self_replace',
                   'profile_missing_input_exit', 'profile_missing_input_cause',
                   'profile_missing_input_names_script',
                   'profile_drifted_input_exit', 'profile_drifted_input_cause',
                   'profile_iscc_identity_exit', 'profile_iscc_identity_cause',
                   'profile_identity_metacharacter_exit',
                   'profile_identity_metacharacter_refused',
                   'long_path_ok_chars', 'long_path_fail_chars',
                   'long_path_refusal', 'long_path_refusal_cause',
                   'long_path_refusal_exit') {
        Row $k 'not_applicable'
    }
}

# --- 11. A4: a real interrupt during packaging ------------------------------
$drvReport = Join-Path $work 'packdrv-report.txt'
# WHICH CHILD IS INTERRUPTED, and it differs by family because the packaging
# work differs: on Windows the Inno compile is a long child of its own, and
# on POSIX the archive is written IN-PROCESS in milliseconds, so there is no
# packaging child to interrupt at all. The POSIX leg therefore interrupts the
# `compile` stage of the SAME profiled run - which measures the claim that
# matters either way: an interrupted profiled build leaves the previously
# committed artifacts exactly as they were.
$drvStage = if ($IsWindows) { 'iscc' } else { 'compile' }
Row 'pack_interrupt_stage' $drvStage
$drvProfile = $profiles[0]
$beforeDist = InventoryOf (DistDirOf $projA $drvProfile)
$drvArgs = @('--pweb', $pweb, '--project', $projA, '--profile', $drvProfile,
    '--report', $drvReport, '--cwd', $cwd, '--scenario', 'interrupt',
    '--stage', $drvStage)
if (Test-Path -LiteralPath $helper) { $drvArgs += @('--helper', $helper) }
$dp = Start-PWebProcess -FilePath $driver -ArgumentList $drvArgs -PassThru `
    -NoNewWindow -WorkingDirectory $repoRoot `
    -RedirectStandardOutput (Join-Path $work 'packdrv-stdout.txt') `
    -RedirectStandardError (Join-Path $work 'packdrv-stderr.txt')
if (-not $dp.WaitForExit(2400000)) {
    try { $dp.Kill() } catch { }
    $dp.WaitForExit(10000) | Out-Null
    Require $false 'A4: the interrupt driver did not finish'
}
$dp.WaitForExit()
$drv = @{}
if (Test-Path -LiteralPath $drvReport) {
    foreach ($line in (Get-Content $drvReport)) {
        if ($line -match '^([^=]+)=(.*)$') { $drv[$Matches[1]] = $Matches[2] }
    }
}
Row 'pack_interrupt_armed' $(if ($drv.ContainsKey('interrupt_armed')) { $drv['interrupt_armed'] } else { 'false' })
Row 'pack_interrupt_delivered' $(if ($drv.ContainsKey('interrupt_delivered')) { $drv['interrupt_delivered'] } else { 'false' })
Row 'pack_descendants_after_interrupt' $(if ($drv.ContainsKey('descendants_remaining')) { $drv['descendants_remaining'] } else { '-1' })
Row 'pack_driver_ansi_seen' $(if ($drv.ContainsKey('driver_ansi_seen')) { $drv['driver_ansi_seen'] } else { 'true' })
Require ($drv['interrupt_delivered'] -eq 'true') 'A4: no interrupt was delivered'
Require ($drv['descendants_remaining'] -eq '0') `
    "A4: $($drv['descendants_remaining']) descendant(s) survived the interrupt"
Require ($drv['driver_ansi_seen'] -eq 'false') `
    'A4: the CLI emitted ANSI on its own lines'
# THE CLAIM: the previously committed artifacts are exactly as they were
$afterDist = InventoryOf (DistDirOf $projA $drvProfile)
Row 'pack_interrupt_clean' (Bool ($afterDist.Text -ceq $beforeDist.Text))
Require ($afterDist.Text -ceq $beforeDist.Text) `
    'A4: an interrupted packaging run changed the previously committed artifacts'
$afterRelease = InventoryOf (ReleaseDirOf $projA)
Require ($afterRelease.Text -ceq $releaseBefore.Text) `
    'A4: an interrupted packaging run changed the release'
foreach ($sibling in '.pweb-pack.tmp', '.pweb-dist-old.tmp') {
    Require (-not (Test-Path -LiteralPath (Join-Path $targetDir $sibling))) `
        "A4: the sibling $sibling survived the interrupt"
}

# --- 12. A2 (second half): the CAP-10D0 corpus did not move -----------------
$d0File = Join-Path $repoRoot "build/cap10d0/cli-$target.json"
if (Test-Path -LiteralPath $d0File) {
    $d0 = Get-Content $d0File -Raw | ConvertFrom-Json
    # THE CAP-10D0 CLOSURE VALUE, pinned. CAP-10D1 touched pweb.cli.layout
    # (the test-only seam) and pweb.cli.pipeline (the long-path refusal), and
    # this is the row that says neither of them moved a decision the public
    # build had already frozen.
    Row 'd0_corpus_without_profile_unchanged' (Bool (
        "$($d0.build_digest)" -ceq
        '1d5230a9959ae6c6db8ce0014d2ef254316c621a95054aa7f6dc8cf3ff08fb18'))
    Row 'd0_build_digest' "$($d0.build_digest)"
    Require ("$($d0.build_digest)" -ceq
        '1d5230a9959ae6c6db8ce0014d2ef254316c621a95054aa7f6dc8cf3ff08fb18') `
        ("A2: build_digest moved to $($d0.build_digest); CAP-10D0 closed on " +
         '1d5230a9…ff08fb18 and CAP-10D1 changes no decision it froze')
} else {
    Row 'd0_corpus_without_profile_unchanged' 'unmeasured'
    Row 'd0_build_digest' 'unmeasured'
}

# --- 13. A5: the ledger, disposed -------------------------------------------
$artifact = '_bmad-output/implementation-artifacts/cap10d1-final-artifact.md'
$disposed = 0
if (Test-Path -LiteralPath $artifact) {
    $t = [System.IO.File]::ReadAllText($artifact)
    foreach ($item in 'C1-11 (a)', 'C1-11 (b)', 'C1-11 (f)', 'long path') {
        if ($t.Contains($item)) { $disposed++ }
    }
}
Row 'ledger_items_disposed' "$disposed"

# --- 14. the verdict and the evidence ---------------------------------------
Row 'pack_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$json = ($rows | ConvertTo-Json -Depth 4) + "`n"
[System.IO.File]::WriteAllText((Join-Path $work "cli-$target.json"), $json,
    [System.Text.UTF8Encoding]::new($false))
Write-Host $json
if ($failures.Count -gt 0) {
    Write-Host "`n[CAP-10D1] $($failures.Count) failure(s):"
    foreach ($f in $failures) { Write-Host "  - $f" }
    throw "CAP-10D1 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10D1] gates PASS on $target"
