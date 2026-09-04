# CAP-10D0: the public-build gates - B1..B12, L1..L3 and R1..R2.
#
# THE REAL `pweb build`, on REAL projects the REAL `pweb create` scaffolded,
# for both frontend kinds, followed by the REAL `pweb run`. Nothing here
# drives the pipeline through a private driver: the whole point of this
# shard is that a developer can reach it by name, so the gate reaches it by
# name too.
#
# WHAT IT NEVER DOES: reimplement a rule. Every refusal it exercises is the
# CLI's own, every digest it compares is one the gate that owns it recorded,
# and every process it looks at it found by MEMBERSHIP or by pid, never by
# name.
#
# L2a IS BUILT IN RATHER THAN BOLTED ON. Both projects are created inside a
# directory whose name carries a SPACE, so every `--project` this gate hands
# the CLI is a spaced path and the C0-12 (b) quoting defect would split it
# on every leg of every job. That is the cheapest possible place for that
# measurement to live, and it is why it cannot rot.
#
# Emits build/cap10d0/cli-<target>.json for the CAP-7F aggregation, plus
# build/cap10d0/build-corpus.txt (from the suite) and the driver report.
#
# Usage: pwsh test/cap10d0/run_cap10d0_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

# CAP-10D0: the ONE pwsh argument-quoting helper, which this gate depends on
# more than any other - every project path it uses carries a space
. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')
# the CAP-10C1 membership-scoped samplers, dot-sourced rather than
# reimplemented: one rule, measured in the C0, C1, C2, C3 and D0 gates alike
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10d0'
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
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($sha.ComputeHash(
            [System.Text.UTF8Encoding]::new($false).GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
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
function InventoryOf([string]$Root, [string[]]$ExcludePrefixes) {
    $lines = New-Object System.Collections.Generic.List[string]
    $total = 0
    if (-not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{ Text = ''; Count = 0; Bytes = 0 }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $skip = $false
        foreach ($p in $ExcludePrefixes) {
            if (($rel -eq $p) -or $rel.StartsWith($p + '/')) { $skip = $true; break }
        }
        if ($skip) { continue }
        $lines.Add("$rel $($f.Length) $(Sha256File $f.FullName)")
        $total += $f.Length
    }
    $sorted = SortOrdinal $lines.ToArray()
    return [pscustomobject]@{
        Text = (($sorted -join "`n") + "`n"); Count = $sorted.Count; Bytes = $total
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

# THE PINNED Pas2JS IS PUT ON PATH BY THIS GATE, deliberately and visibly,
# exactly as the CAP-10B2, CAP-10C1 and CAP-10C3 gates do it and for the same
# reason: the pipeline resolves tools on PATH by ratified design, and every
# CI job fetches the pinned compiler into deps/ without putting it there.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
    Write-Host "[CAP-10D0] pinned pas2js on PATH: $($pinnedPas2js -join ', ')"
}
$pas2jsOnPath = $null -ne (Get-Command pas2js -ErrorAction SilentlyContinue)
Row 'd0_pas2js_on_path' (Bool $pas2jsOnPath)
if (-not $pas2jsOnPath) {
    throw ('CAP-10D0 preconditions FAILED: pas2js is not on PATH and no ' +
        'pinned copy exists under deps/ -- every pas2js leg would read false ' +
        'for one reason, and a gate that reports a dozen failures for one ' +
        'missing tool is a gate nobody can read')
}

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
$suite = Join-Path $work "bin/d0tests$exeSuffix"
$driver = Join-Path $work "bin/pwebbuilddrv$exeSuffix"
$helper = Join-Path $repoRoot "build/cap10c0/bin/pwebchild$exeSuffix"
foreach ($pre in $pweb, $suite, $driver) {
    Require (Test-Path -LiteralPath $pre) `
        "precondition absent: $pre -- run test/cap10d0/build_cap10d0 first"
}
if ($failures.Count -gt 0) {
    throw "CAP-10D0 preconditions FAILED: $($failures.Count)"
}

function RunCli([string[]]$CliArgs, [string]$WorkDir, [int]$TimeoutMs = 1800000) {
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

# --- 1. the headless suite and its corpus -----------------------------------
# /noenter is the WINDOWS switch; the POSIX runner reads it as a FILENAME,
# prints its usage and exits 0 - a green verdict over nothing. So the option
# is passed on Windows only, and the corpus is REQUIRED to carry at least one
# decision whatever the platform.
$suiteLog = Join-Path $work 'd0tests.log'
$suiteArgs = if ($IsWindows) { @('/noenter') } else { @() }
$sp = Start-PWebProcess -FilePath $suite -ArgumentList $suiteArgs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $suiteLog `
    -RedirectStandardError (Join-Path $work 'd0tests-stderr.log')
Write-Host ([System.IO.File]::ReadAllText($suiteLog))
Row 'build_suite' $(if ($sp.ExitCode -eq 0) { 'PASS' } else { 'FAIL' })
Require ($sp.ExitCode -eq 0) "the CAP-10D0 suite exited $($sp.ExitCode)"

$corpusPath = Join-Path $work 'build-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite wrote no decision corpus'
if (Test-Path -LiteralPath $corpusPath) {
    $corpusText = [System.IO.File]::ReadAllText($corpusPath).Replace("`r`n", "`n")
    $decisions = @($corpusText -split "`n" | Where-Object {
        ($_ -ne '') -and (-not $_.StartsWith('#')) })
    Row 'build_digest' (Sha256Text $corpusText)
    Row 'build_corpus_lines' "$($decisions.Count)"
    Require ($decisions.Count -ge 20) `
        "the decision corpus carries only $($decisions.Count) decision(s)"
    $abs = @($decisions | Where-Object { ($_ -match ':[\\/]') -or ($_ -match '\|/') })
    Require ($abs.Count -eq 0) `
        "a corpus line names an absolute path: $($abs | Select-Object -First 1)"
} else {
    Row 'build_digest' 'unmeasured'
    Row 'build_corpus_lines' '0'
}

# --- 2. the contract cross-checks, read back --------------------------------
$contractsFile = Join-Path $work 'contracts.json'
Require (Test-Path -LiteralPath $contractsFile) `
    'build/cap10d0/contracts.json is absent -- run check_cap10d0_contracts.ps1 first'
if (Test-Path -LiteralPath $contractsFile) {
    $c = Get-Content $contractsFile -Raw | ConvertFrom-Json
    Require ("$($c.verdict)" -ceq 'PASS') 'the CAP-10D0 contract cross-checks did not PASS'
    Row 'build_execute_callers' "$($c.execute_callers)"
    Row 'build_driver_spawns' $(if ("$($c.build_driver_process_apis)" -eq '') { '0' } else { '1' })
    Row 'build_stage_count' "$($c.stage_count)"
    Row 'build_unratified_options' $(
        if ("$($c.unratified_options_present)" -eq '') { 'none' }
        else { "$($c.unratified_options_present)" })
    Row 'gate_quoting_space_path' $(
        if ("$($c.raw_start_process_gates)" -eq '') { 'PASS' } else { 'FAIL' })
} else {
    foreach ($k in 'build_execute_callers', 'build_driver_spawns',
                   'build_stage_count', 'build_unratified_options',
                   'gate_quoting_space_path') {
        Row $k 'unmeasured'
    }
}

# --- 3. B9/B10/B11: the public surface --------------------------------------
$cwd = Join-Path $work 'cwd'
New-Item -ItemType Directory -Force $cwd | Out-Null
$surface = $true
foreach ($case in @(
        @{ Args = @('build', '--project', 'a', '--project', 'b'); Cause = 'duplicate_option' },
        @{ Args = @('build', '--json');                           Cause = 'option_not_for_command' },
        @{ Args = @('build', '--verbose');                        Cause = 'option_not_for_command' },
        @{ Args = @('build', '--no-color');                       Cause = 'option_not_for_command' },
        @{ Args = @('build', '--with-paths');                     Cause = 'option_not_for_command' },
        @{ Args = @('build', '--ui', 'react');                    Cause = 'option_not_for_command' },
        @{ Args = @('build', 'extra');                            Cause = 'extra_positional' },
        # the four options a reader of another build tool reaches for first,
        # and every one of them is an option this grammar does not have
        @{ Args = @('build', '--profile', 'offline');             Cause = 'unknown_option' },
        @{ Args = @('build', '--target', 'linux-x86_64');         Cause = 'unknown_option' },
        @{ Args = @('build', '--clean');                          Cause = 'unknown_option' },
        @{ Args = @('build', '--watch');                          Cause = 'unknown_option' },
        # and a name outside the five is still an unknown COMMAND
        @{ Args = @('publish');                                   Cause = 'unknown_command' })) {
    $r = RunCli $case.Args $cwd 60000
    $ok = ($r.Code -eq 2) -and ($r.Err.Contains($case.Cause))
    if (-not $ok) {
        $surface = $false
        Require $false ("B9: pweb $($case.Args -join ' ') answered " +
            "$($r.Code)/$($r.Err.Trim()) -- expected 2/$($case.Cause)")
    }
}
Row 'build_option_matrix' $(if ($surface) { 'PASS' } else { 'FAIL' })

$mainHelp = RunCli @('--help') $cwd 60000
Require ($mainHelp.Code -eq 0) 'B11: --help did not exit 0'
$advertised = @()
foreach ($c in 'create', 'doctor', 'run', 'dev', 'build') {
    if ($mainHelp.Out -match "(?m)^\s+$c\s") { $advertised += $c }
}
Row 'advertised_commands_d0' ($advertised -join ',')
Require (($advertised -join ',') -ceq 'create,doctor,run,dev,build') `
    "B11: pweb advertises $($advertised -join ',')"
Require (-not $mainHelp.Out.Contains([char]27)) 'B10: --help emitted ANSI when redirected'
$helpOk = $true
foreach ($c in 'create', 'run', 'dev', 'build') {
    $h = RunCli @($c, '--help') $cwd 60000
    if (($h.Code -ne 0) -or $h.Out.Contains([char]27)) {
        $helpOk = $false
        Require $false "B11: pweb $c --help exited $($h.Code) or emitted ANSI"
    }
}
$buildHelp = RunCli @('build', '--help') $cwd 60000
Require ($buildHelp.Out.Contains('pweb build [--project <path>]')) `
    'B11: build --help does not state the grammar'
Row 'build_help_matrix' $(if ($helpOk) { 'PASS' } else { 'FAIL' })
Row 'cli_build_available' (Bool (($advertised -contains 'build') -and $helpOk))

# --- 4. the two projects, created by the REAL CLI, AT A SPACED PATH ---------
# L2a: the directory name carries a space, so every --project below is a
# spaced path and the C0-12 (b) quoting defect would split it here first.
$spaced = Join-Path $work 'space dir'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $spaced
New-Item -ItemType Directory -Force $spaced | Out-Null
Row 'gate_project_path_has_space' (Bool ($spaced.Contains(' ')))
$projects = [ordered]@{}
foreach ($ui in 'react', 'pas2js') {
    $r = RunCli @('create', "demo$ui", '--ui', $ui, '--bundle-id',
        'com.example.demo') $spaced 120000
    Require ($r.Code -eq 0) "B12: create --ui $ui exited $($r.Code): $($r.Err.Trim())"
    $projects[$ui] = Join-Path $spaced "demo$ui"
}
# B12: a generated project still passes its own doctor
foreach ($ui in 'react', 'pas2js') {
    $d = RunCli @('doctor', '--project', $projects[$ui]) $cwd 300000
    Row "doctor_${ui}_exit" "$($d.Code)"
    Require ($d.Code -le 4) "B12: doctor on the $ui project exited $($d.Code)"
}

# the read-only half of each project, digested BEFORE the first build
$mutation = @('frontend/.pweb', 'frontend/node_modules', 'frontend/dist', 'dist')
$treeBefore = [ordered]@{}
foreach ($ui in 'react', 'pas2js') {
    $treeBefore[$ui] = (InventoryOf $projects[$ui] $mutation).Text
}

# --- 5. B1/B2: build each project with the PUBLIC command -------------------
function BuildProject([string]$Ui) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = RunCli @('build', '--project', $projects[$Ui]) $cwd
    $sw.Stop()
    Write-Host "----- $Ui build (exit $($r.Code), $([int]$sw.Elapsed.TotalSeconds) s) -----"
    Write-Host $r.Err
    return $r
}
$builds = [ordered]@{}
foreach ($ui in 'react', 'pas2js') {
    $b = BuildProject $ui
    $builds[$ui] = $b
    Require ($b.Code -eq 0) `
        "B1/B2: pweb build on the $ui project exited $($b.Code): $($b.Err.Trim())"
    # B10: the summary, exactly six fields, and no ANSI or absolute path in
    # any line this CLI wrote
    $own = @(($b.Err -split "`n") | Where-Object { $_ -match '^(pweb: |  )' })
    Require (-not ($b.Err.Contains([char]27))) "B10: $ui build emitted ANSI"
    foreach ($field in 'ui', 'target', 'release', 'app.pwb', 'bytes') {
        Require (($own | Where-Object { $_ -match "^  $field\s" }).Count -eq 1) `
            "B10: the $ui summary has no single '$field' row"
    }
    Require ($b.Err -match '(?m)^pweb: built demo') `
        "B10: the $ui build printed no summary header"
    Require ($b.Err -match '(?m)^pweb: run it with') `
        "B10: the $ui build did not offer `pweb run` after a verified layout"
    $absolute = @($own | Where-Object {
        ($_ -match '(?i)[a-z]:[\\/]') -or ($_ -match '\s/(usr|home|Users|opt|tmp)/') })
    Require ($absolute.Count -eq 0) `
        "B10: a $ui summary line names an absolute path: $($absolute | Select-Object -First 1)"
    # the stage lines, with the contract's own names
    foreach ($stage in 'open', 'toolchain', 'build', 'pack', 'compile',
                       'layout', 'verify') {
        Require ($b.Err -match "(?m)^pweb: $stage`: ok") `
            "B1/B2: the $ui build did not report stage '$stage' ok"
    }
    if ($ui -eq 'react') {
        foreach ($stage in 'stage_sdk', 'install', 'typecheck') {
            Require ($b.Err -match "(?m)^pweb: $stage`: ok") `
                "B1: the react build did not report stage '$stage' ok"
        }
    } else {
        foreach ($stage in 'stage_sdk', 'install', 'typecheck') {
            Require (-not ($b.Err -match "(?m)^pweb: $stage`: start")) `
                "B2: the pas2js build entered the node stage '$stage'"
        }
    }
}
Row 'build_react_exit' "$($builds['react'].Code)"
Row 'build_pas2js_exit' "$($builds['pas2js'].Code)"
Row 'build_network_stages_react' 'install'
Row 'build_network_stages_pas2js' 'none'

# B2, MEASURED rather than declared: a Pas2JS build must make NO network
# connection at all. "The pipeline declares no network stage for pas2js" is
# a statement about a table; this samples the real process tree of a real
# build through the CAP-10C1 membership sampler, which is the same rule the
# C0, C1, C2 and C3 gates use and is never a lookup by process name.
$netSo = Join-Path $work 'net-build-stdout.txt'
$netSe = Join-Path $work 'net-build-stderr.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $netSo, $netSe
$np = Start-PWebProcess -FilePath $pweb -PassThru -NoNewWindow `
    -ArgumentList @('build', '--project', $projects['pas2js']) `
    -WorkingDirectory $cwd -RedirectStandardOutput $netSo `
    -RedirectStandardError $netSe
$netMax = 0
$netMembers = 0
$netSamples = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ((-not $np.HasExited) -and ($sw.ElapsedMilliseconds -lt 1800000)) {
    Start-Sleep -Milliseconds 250
    $members = @(Get-PWebTreeMembers -RootPid $np.Id)
    if ($members.Count -gt $netMembers) { $netMembers = $members.Count }
    $netSamples++
    foreach ($m in $members) {
        $c = Get-PWebConnectionCount -OwnerPid $m
        if ($c -gt $netMax) { $netMax = $c }
    }
}
if (-not $np.HasExited) {
    try { $np.Kill() } catch { }
    $np.WaitForExit(10000) | Out-Null
    Require $false 'B2: the sampled pas2js build did not finish inside 30 minutes'
}
$np.WaitForExit()
Row 'build_pas2js_network_calls' "$netMax"
Row 'build_pas2js_sampler_members' "$netMembers"
Row 'build_pas2js_sampler_samples' "$netSamples"
Require ($np.ExitCode -eq 0) "B2: the sampled pas2js build exited $($np.ExitCode)"
# a sampler that never ran would report a vacuous 0, so its own liveness is
# a requirement rather than an assumption - the CAP-10C1 DB3 discipline
Require ($netSamples -gt 0) 'B2: the network sampler never ran'
Require ($netMembers -gt 0) 'B2: the sampler saw no member of the build tree'
Require ($netMax -eq 0) `
    "B2: a pas2js build opened $netMax network connection(s); it declares no network stage"

# the committed layouts, and the summary values read back out of the output
function ReleaseDirOf([string]$Ui) {
    return (Join-Path (Join-Path (Join-Path $projects[$Ui] 'dist') $target) 'release')
}
function SummaryField([string]$Text, [string]$Field) {
    foreach ($line in ($Text -split "`n")) {
        if ($line -match "^  $([regex]::Escape($Field))\s+(.+?)\s*$") {
            return $Matches[1]
        }
    }
    return ''
}
foreach ($ui in 'react', 'pas2js') {
    $rel = ReleaseDirOf $ui
    Require (Test-Path -LiteralPath $rel) "B1/B2: no release directory for $ui"
    $inv = InventoryOf $rel @()
    Row "release_${ui}_files" "$($inv.Count)"
    Row "release_${ui}_inventory" (Sha256Text $inv.Text)
    $said = SummaryField $builds[$ui].Err 'bytes'
    Require ("$($inv.Bytes)" -ceq $said) `
        "B10: the $ui summary says $said bytes, the layout holds $($inv.Bytes)"
    $relSaid = SummaryField $builds[$ui].Err 'release'
    Require ($relSaid -ceq "dist/$target/release") `
        "B10: the $ui summary names the release as '$relSaid'"
    Row "summary_${ui}_release" $relSaid
    Row "summary_${ui}_app_pwb" (SummaryField $builds[$ui].Err 'app.pwb')
    Row "summary_${ui}_target" (SummaryField $builds[$ui].Err 'target')
}

# B8: the project tree minus the four ratified prefixes is unchanged
$treeOk = $true
foreach ($ui in 'react', 'pas2js') {
    $after = (InventoryOf $projects[$ui] $mutation).Text
    if ($after -cne $treeBefore[$ui]) {
        $treeOk = $false
        Require $false "B8: the $ui project tree changed outside the mutation set"
    }
}
Row 'd0_project_tree_unchanged' (Bool $treeOk)

# --- 6. B1/B2: `pweb run` from an unrelated CWD answers 42 ------------------
function RunApplication([string]$Ui) {
    $so = Join-Path $work "run-$Ui-stdout.txt"
    $se = Join-Path $work "run-$Ui-stderr.txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '20000'
    $runCwd = Join-Path $work 'unrelated-cwd'
    New-Item -ItemType Directory -Force $runCwd | Out-Null
    $p = Start-PWebProcess -FilePath $pweb -PassThru -NoNewWindow `
        -ArgumentList @('run', '--project', $projects[$Ui]) `
        -WorkingDirectory $runCwd -RedirectStandardOutput $so `
        -RedirectStandardError $se
    if (-not $p.WaitForExit(120000)) {
        try { $p.Kill() } catch { }
        $p.WaitForExit(10000) | Out-Null
        Require $false "$Ui`: pweb run did not exit inside 120 s -- a HUNG RUN"
    }
    $p.WaitForExit()
    Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
    $out = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
    # BOTH streams. The application's own lines go to stdout and the
    # supervisor's to stderr, and a run that dies before its first window
    # says why only on the second - which is how a missing display reads as
    # "returned -1" and nothing else. Measured: it cost a hosted run.
    $err = if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    Write-Host "----- $Ui run (stdout) -----"; Write-Host $out
    Write-Host "----- $Ui run (stderr) -----"; Write-Host $err
    $value = -1
    foreach ($line in ($out -split "`n")) {
        # the program identifier is the PROJECT's, not a fixed `demo`: this
        # gate scaffolds demoreact and demopas2js so the two never share an
        # output directory, and a pattern that assumed `demo` would read
        # -1 out of a run that answered 42
        if ($line -match '^\w+: ready (\{.*\})\s*$') {
            $value = ($Matches[1] | ConvertFrom-Json).value
        }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Rpc = $value }
}
foreach ($ui in 'react', 'pas2js') {
    $run = RunApplication $ui
    Row "build_${ui}_rpc_value" "$($run.Rpc)"
    Require ($run.Code -eq 0) "B1/B2: pweb run on the built $ui project exited $($run.Code)"
    Require ($run.Rpc -eq 42) `
        "B1/B2: CalculatorService.Add(20,22) returned $($run.Rpc) after a PUBLIC build"
}

# --- 7. B3/B7: a second build replaces, and is deterministic ----------------
$firstInv = [ordered]@{}
$firstPwb = [ordered]@{}
function BundleIn([string]$ReleaseDir) {
    # the bundle's position differs between a flat layout and a macOS
    # bundle, so it is FOUND rather than restated - and a release that is
    # not there at all answers with no bundle instead of throwing, because
    # the leg that follows is what must say so
    if (-not (Test-Path -LiteralPath $ReleaseDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File -Filter 'app.pwb')
}
foreach ($ui in 'react', 'pas2js') {
    $rel = ReleaseDirOf $ui
    $firstInv[$ui] = (InventoryOf $rel @()).Text
    $bundle = BundleIn $rel
    Require ($bundle.Count -eq 1) "B7: the $ui release holds $($bundle.Count) app.pwb"
    if ($bundle.Count -eq 1) { $firstPwb[$ui] = Sha256File $bundle[0].FullName }
}
$deterministic = $true
$replacedWhole = $true
foreach ($ui in 'react', 'pas2js') {
    $b = BuildProject $ui
    Require ($b.Code -eq 0) "B3: the second $ui build exited $($b.Code)"
    $rel = ReleaseDirOf $ui
    Require (Test-Path -LiteralPath $rel) "B3: no release after the second $ui build"
    # the retired tree is gone, and so is the staging sibling
    $parent = Split-Path -Parent $rel
    foreach ($tmp in '.pweb-old.tmp', '.pweb-release.tmp') {
        if (Test-Path -LiteralPath (Join-Path $parent $tmp)) {
            $replacedWhole = $false
            Require $false "B3: the $ui build left $tmp behind"
        }
    }
    $inv = (InventoryOf $rel @()).Text
    if ($inv -cne $firstInv[$ui]) {
        $deterministic = $false
        Require $false "B7: two $ui builds produced different layout inventories"
    }
    $bundle = BundleIn $rel
    if (($bundle.Count -ne 1) -or
        (-not $firstPwb.Contains($ui)) -or
        ((Sha256File $bundle[0].FullName) -cne $firstPwb[$ui])) {
        $deterministic = $false
        Require $false "B7: two $ui builds produced different app.pwb bytes"
    }
}
Row 'build_replacement_rule' 'stage_aside_rename_reclaim'
Row 'build_replacement_window' 'one_rename_no_release'
Row 'build_never_partial_release' (Bool $replacedWhole)
Row 'd0_build_deterministic' (Bool $deterministic)

# --- 8. B4: a seeded failure leaves the previous release byte-untouched -----
# The pas2js project is the subject: a broken frontend source fails the
# `build` stage, which is five stages before the layout is even assembled.
$b4Project = $projects['pas2js']
$b4Rel = ReleaseDirOf 'pas2js'
$b4Before = (InventoryOf $b4Rel @()).Text
$b4Source = Join-Path $b4Project 'frontend/src/app.pas'
$b4Original = [System.IO.File]::ReadAllText($b4Source)
try {
    # PREPENDED, not appended. MEASURED: text after the unit's final `end.`
    # is ignored by the compiler, so an appended seed produced a SUCCESSFUL
    # build - which then published a release whose page never came up, and
    # the failure surfaced two legs later as "the application never reported
    # ready". A seed that does not seed is worse than no seed at all.
    [System.IO.File]::WriteAllText($b4Source,
        "this is not pascal and never will be`n" + $b4Original,
        [System.Text.UTF8Encoding]::new($false))
    $b4 = RunCli @('build', '--project', $b4Project) $cwd
    Row 'build_failure_exit' "$($b4.Code)"
    Require ($b4.Code -eq 5) `
        "B4: a failing stage child answered $($b4.Code), expected 5"
    Require ($b4.Err -match '(?m)^pweb: build: FAILED') `
        'B4: the failing stage did not name itself'
    $b4After = (InventoryOf $b4Rel @()).Text
    Row 'build_failure_leaves_old_release' (Bool ($b4After -ceq $b4Before))
    Require ($b4After -ceq $b4Before) `
        'B4: a failed build altered the previous release'
    $parent = Split-Path -Parent $b4Rel
    Require (-not (Test-Path -LiteralPath (Join-Path $parent '.pweb-release.tmp'))) `
        'B4: a failed build left its staging tree behind'
} finally {
    [System.IO.File]::WriteAllText($b4Source, $b4Original,
        [System.Text.UTF8Encoding]::new($false))
}

# --- 9. B5: a real interrupt mid-compile ------------------------------------
# THE DRIVER, not this script: a real console control event on Windows needs
# a process with a console of its own, which is the CAP-10C0 mechanism. This
# is the leg that turns CAP-10C1's `interrupt_clean = not_measured` on
# Windows into a measurement on all four targets.
$b5Rel = ReleaseDirOf 'pas2js'
$b5Before = (InventoryOf $b5Rel @()).Text
$drvReport = Join-Path $work 'builddrv-report.txt'
$drvArgs = @('--pweb', $pweb, '--project', $projects['pas2js'],
    '--report', $drvReport, '--cwd', $cwd, '--scenario', 'interrupt',
    '--stage', 'compile')
if (Test-Path -LiteralPath $helper) { $drvArgs += @('--helper', $helper) }
$dp = Start-PWebProcess -FilePath $driver -ArgumentList $drvArgs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $repoRoot `
    -RedirectStandardOutput (Join-Path $work 'builddrv-stdout.txt') `
    -RedirectStandardError (Join-Path $work 'builddrv-stderr.txt')
Require ($dp.ExitCode -eq 0) "B5: the build driver exited $($dp.ExitCode)"
$drv = @{}
if (Test-Path -LiteralPath $drvReport) {
    foreach ($line in [System.IO.File]::ReadAllLines($drvReport)) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $drv[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
    }
}
Row 'build_interrupt_armed' "$($drv['interrupt_armed'])"
Row 'build_interrupt_delivered' "$($drv['interrupt_delivered'])"
Row 'build_interrupt_outcome' "$($drv['pweb_outcome'])"
Row 'build_interrupt_exit' "$($drv['pweb_exit'])"
Row 'build_descendants_after_interrupt' "$($drv['descendants_remaining'])"
Row 'build_driver_ansi_seen' "$($drv['driver_ansi_seen'])"
Require ("$($drv['interrupt_delivered'])" -ceq 'true') `
    'B5: the interrupt was never delivered'
Require ("$($drv['pweb_exit'])" -cne '0') `
    "B5: an interrupted build exited $($drv['pweb_exit']), expected a failure category"
Require ("$($drv['descendants_remaining'])" -ceq '0') `
    "B5: $($drv['descendants_remaining']) descendant(s) survived an interrupted build"
Require ("$($drv['driver_ansi_seen'])" -ceq 'false') `
    'B5: the CLI emitted ANSI on a line of its own'
$b5After = (InventoryOf $b5Rel @()).Text
Row 'build_interrupt_clean' (Bool (
    ($b5After -ceq $b5Before) -and
    ("$($drv['descendants_remaining'])" -ceq '0') -and
    (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $b5Rel) '.pweb-release.tmp')))))
Require ($b5After -ceq $b5Before) `
    'B5: an interrupted build altered the previous release'
Require (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $b5Rel) '.pweb-release.tmp'))) `
    'B5: an interrupted build left its staging tree behind'

# --- 10. B6: a build racing a running application ---------------------------
# MEASURED rather than assumed, and DIFFERENT on the two families: `pweb run`
# gives the application the release directory as its working directory. On
# POSIX that directory renames freely and the old application runs to
# completion; on Windows a directory that is a process's current directory
# cannot be renamed at all, so the BUILD is refused and the application is
# untouched. Neither can produce a partial layout, and that is the claim.
$raceRel = ReleaseDirOf 'pas2js'
$raceBefore = (InventoryOf $raceRel @()).Text
$rso = Join-Path $work 'race-run-stdout.txt'
$rse = Join-Path $work 'race-run-stderr.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $rso, $rse
$env:PWEB_SMOKE_AUTOCLOSE_MS = '45000'
$runCwd = Join-Path $work 'unrelated-cwd'
New-Item -ItemType Directory -Force $runCwd | Out-Null
$rp = Start-PWebProcess -FilePath $pweb -PassThru -NoNewWindow `
    -ArgumentList @('run', '--project', $projects['pas2js']) `
    -WorkingDirectory $runCwd -RedirectStandardOutput $rso -RedirectStandardError $rse
$ready = $false
for ($i = 0; ($i -lt 60) -and (-not $rp.HasExited); $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $rso) {
        try {
            # `\w+: ready` and not `demo: ready`: the program identifier is
            # the PROJECT's, and demopas2js does not contain `demo: `
            if ((Get-Content -LiteralPath $rso -Raw -ErrorAction SilentlyContinue) -match '(?m)^\w+: ready \{') {
                $ready = $true; break
            }
        } catch { }
    }
}
Require $ready 'B6: the application never reported ready inside the arming window'
$raceBuild = RunCli @('build', '--project', $projects['pas2js']) $cwd
if (-not $rp.WaitForExit(120000)) {
    try { $rp.Kill() } catch { }
    $rp.WaitForExit(10000) | Out-Null
}
$rp.WaitForExit()
Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
$raceOut = if (Test-Path $rso) { [System.IO.File]::ReadAllText($rso) } else { '' }
$raceErr = if (Test-Path $rse) { [System.IO.File]::ReadAllText($rse) } else { '' }
Write-Host "----- race run (stdout) -----"; Write-Host $raceOut
Write-Host "----- race run (stderr) -----"; Write-Host $raceErr
$raceValue = -1
foreach ($line in ($raceOut -split "`n")) {
    if ($line -match '^\w+: ready (\{.*\})\s*$') {
        $raceValue = ($Matches[1] | ConvertFrom-Json).value
    }
}
Row 'build_race_run_exit' "$($rp.ExitCode)"
Row 'build_race_run_rpc' "$raceValue"
Row 'build_race_build_exit' "$($raceBuild.Code)"
if ($IsWindows) {
    Row 'build_replace_while_running' 'windows_refused_layout_reclaim'
    Require ($raceBuild.Code -eq 6) `
        ("B6: a build racing a running application answered $($raceBuild.Code) " +
         'on Windows, expected 6 (the release directory is the running ' +
         'application''s working directory and cannot be renamed)')
    Require ($raceBuild.Err.Contains('layout_reclaim_failed')) `
        'B6: the refusal did not name layout_reclaim_failed'
    Require ((InventoryOf $raceRel @()).Text -ceq $raceBefore) `
        'B6: a refused build altered the release a running application is using'
} else {
    Row 'build_replace_while_running' 'posix_old_runs_to_completion'
    Require ($raceBuild.Code -eq 0) `
        "B6: a build racing a running application exited $($raceBuild.Code) on POSIX"
}
Require ($rp.ExitCode -eq 0) `
    "B6: the application racing a build exited $($rp.ExitCode)"
Require ($raceValue -eq 42) `
    "B6: the running application answered $raceValue rather than running to completion"

# --- 11. L1: the Windows long path ------------------------------------------
# C0-12 (a). MEASURED on the hosted runner with a deliberately long project
# path, and typed `not_applicable` elsewhere rather than silently absent: a
# field that only exists on one target is a field the aggregator cannot
# compare.
if (-not $IsWindows) {
    Row 'long_path_rule' 'not_applicable'
    Row 'long_path_project_chars' '0'
    Row 'long_path_exit' 'not_applicable'
    Row 'long_path_cause' 'not_applicable'
    Row 'long_path_stage' 'not_applicable'
} else {
    # a chain long enough that <root>/dist/<target>/release/demo.exe passes
    # MAX_PATH comfortably
    $deep = $work
    while ($deep.Length -lt 200) {
        $deep = Join-Path $deep 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }
    New-Item -ItemType Directory -Force $deep -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path -LiteralPath $deep)) {
        Row 'long_path_rule' 'unmeasured_no_deep_directory'
        Row 'long_path_project_chars' "$($deep.Length)"
        Row 'long_path_exit' 'unmeasured'
        Row 'long_path_cause' 'unmeasured'
        Row 'long_path_stage' 'unmeasured'
    } else {
        $lp = RunCli @('create', 'demolp', '--ui', 'pas2js', '--bundle-id',
            'com.example.demo') $deep 120000
        $lpProject = Join-Path $deep 'demolp'
        Row 'long_path_project_chars' "$($lpProject.Length)"
        if ($lp.Code -ne 0) {
            Row 'long_path_rule' 'create_refused'
            Row 'long_path_exit' "$($lp.Code)"
            Row 'long_path_cause' (($lp.Err -split "`n")[0].Trim())
            Row 'long_path_stage' 'create'
        } else {
            $lb = RunCli @('build', '--project', $lpProject) $cwd
            Row 'long_path_exit' "$($lb.Code)"
            $cause = ''
            # WHICH STAGE, not only which cause. `stage_exited` says a child
            # answered nonzero and nothing about which tool did; C0-12 (a)
            # asks whether the CLI's own spawn is the obstacle or somebody
            # else's, and only the stage name distinguishes the two.
            $lpStage = ''
            foreach ($line in ($lb.Err -split "`n")) {
                if ($line -match '^pweb: build failed: (\S+)') { $cause = $Matches[1] }
                if ($line -match '^pweb: (\w+): FAILED ') { $lpStage = $Matches[1] }
            }
            Row 'long_path_stage' $(if ($lpStage -eq '') { 'none' } else { $lpStage })
            Row 'long_path_cause' $(if ($cause -eq '') { 'none' } else { $cause })
            Row 'long_path_rule' $(
                if ($lb.Code -eq 0) { 'builds_end_to_end' }
                elseif ($cause -ne '') { "typed_refusal_$cause" }
                else { 'untyped_failure' })
            # WHATEVER the measurement says, an UNTYPED failure is the one
            # answer C0-12 (a) exists to prevent
            Require ($lb.Code -eq 0 -or $cause -ne '') `
                'L1: a long path failed without a typed cause'
        }
    }
}

# --- 12. L3: the six release-path observations, disposed --------------------
$artifact = '_bmad-output/implementation-artifacts/cap10d0-final-artifact.md'
$disposed = 0
if (Test-Path -LiteralPath $artifact) {
    $t = [System.IO.File]::ReadAllText($artifact)
    foreach ($item in 'C1-11 (a)', 'C1-11 (b)', 'C1-11 (c)', 'C1-11 (d)',
                      'C1-11 (e)', 'C1-11 (f)') {
        if ($t.Contains($item)) { $disposed++ }
    }
}
Row 'release_path_observations_disposed' "$disposed"
Require ($disposed -eq 6) `
    "L3: $disposed of the six CAP-10C1 release-path observations are disposed of"
Row 'd0_template_supersession_recorded' (Bool (
    (Test-Path -LiteralPath $artifact) -and
    ([System.IO.File]::ReadAllText($artifact).Contains('06e47ba8'))))

# --- 13. the verdict and the evidence ---------------------------------------
Row 'build_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$json = ($rows | ConvertTo-Json -Depth 4) + "`n"
[System.IO.File]::WriteAllText((Join-Path $work "cli-$target.json"), $json,
    [System.Text.UTF8Encoding]::new($false))
Write-Host $json
if ($failures.Count -gt 0) {
    Write-Host "`n[CAP-10D0] $($failures.Count) failure(s):"
    foreach ($f in $failures) { Write-Host "  - $f" }
    throw "CAP-10D0 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10D0] gates PASS on $target"
