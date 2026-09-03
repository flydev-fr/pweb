# CAP-10C3: the Pas2JS development-loop gates - PD1..PD15, RD1, T1..T5, PU1
# and the CAP-10C closure legs CL1..CL3.
#
# ONE run of the REAL `pweb dev` on a REAL generated PAS2JS project, driven by
# test/cap10c3/pwebp2jdrv (which spawns it with its own console and delivers a
# real interrupt through the CAP-10C0 helper), plus a second run that ends by
# having its host killed, the headless suite's decision corpus, and the
# checkout-only measurements a running loop cannot make about itself.
#
# WHAT IT NEVER DOES: reimplement a rule. Every refusal it exercises is the
# CLI's own, every digest it compares is one the gate that owns it recorded,
# and every process it looks at it found by MEMBERSHIP or by pid, never by
# name.
#
# Emits build/cap10c3/cli-<target>.json for the CAP-7F aggregation, plus
# build/cap10c3/devpas2js-corpus.txt (from the suite) and the driver reports.
#
# Usage: pwsh test/cap10c3/run_cap10c3_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10c3'
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
# exactly as the CAP-10B2 and CAP-10C1 gates do it and for the same reason:
# the loop resolves tools on PATH by ratified design, and every CI job
# fetches the pinned compiler into deps/ without putting it there.
#
# MEASURED, on hosted run 33787727548: without this block the whole Pas2JS
# driver run answered `tool_not_found frontend.pas2js` in under a second and
# fifteen PD rows read false at once. It passed locally only because the
# LOCAL invocation set PATH in its wrapper - a harness more generous than the
# one under test, which is the CAP-10C2 "stale binary" lesson wearing
# different clothes. The refusal below makes the absence say so at the top.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
    Write-Host "[CAP-10C3] pinned pas2js on PATH: $($pinnedPas2js -join ', ')"
}
$pas2jsOnPath = $null -ne (Get-Command pas2js -ErrorAction SilentlyContinue)
Row 'pas2js_on_path' $(if ($pas2jsOnPath) { 'true' } else { 'false' })
if (-not $pas2jsOnPath) {
    throw ('CAP-10C3 preconditions FAILED: pas2js is not on PATH and no ' +
        'pinned copy exists under deps/ -- every PD leg would read false ' +
        'for one reason, and a gate that reports fifteen failures for one ' +
        'missing tool is a gate nobody can read')
}

# READ A FILE A LIVE PROCESS IS STILL WRITING - the CAP-10C2 lesson, and the
# reason it is a function: `Start-Process -RedirectStandardError` holds the
# file on Windows, and ReadAllText on it throws a sharing violation for as
# long as the process lives. A leg that swallowed that would only pass while
# the thing it measures was broken.
function ReadLive([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs)
        return $sr.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

# the CAP-10C1 membership-scoped listening-socket sampler, dot-sourced rather
# than reimplemented: one rule, measured in the C0, C1, C2 and C3 gates alike
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

# THE RATIFIED DETECTION MODEL, recorded so four targets can be compared on
# it and so a shard that quietly grew a native watcher would be a divergence
# rather than a diff nobody read
Row 'dev_pas2js_available' 'true'
Row 'change_detection_model' 'cli_content_fingerprint_poll'
Row 'advertised_ui_dev' 'pas2js,react'

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
$pipe = Join-Path $sdk "bin/pwebpipe$exeSuffix"
$suite = Join-Path $work "bin/c3tests$exeSuffix"
$driver = Join-Path $work "bin/pwebp2jdrv$exeSuffix"
$helper = Join-Path $repoRoot "build/cap10c0/bin/pwebchild$exeSuffix"
foreach ($pre in $pweb, $suite, $driver) {
    Require (Test-Path -LiteralPath $pre) `
        "precondition absent: $pre -- run test/cap10c3/build_cap10c3 first"
}
if ($failures.Count -gt 0) {
    throw "CAP-10C3 preconditions FAILED: $($failures.Count)"
}

# --- 1. the headless suite and its corpus -----------------------------------
# /noenter is the WINDOWS switch; the POSIX runner reads it as a FILENAME,
# prints its usage and exits 0 - a green verdict over nothing. So the option
# is passed on Windows only, and the corpus is REQUIRED to carry at least one
# decision whatever the platform.
$suiteLog = Join-Path $work 'c3tests.log'
$suiteArgs = if ($IsWindows) { @('/noenter') } else { @() }
$sp = Start-Process -FilePath $suite -ArgumentList $suiteArgs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $suiteLog `
    -RedirectStandardError (Join-Path $work 'c3tests-stderr.log')
$out = [System.IO.File]::ReadAllText($suiteLog)
Write-Host $out
Row 'dev_pas2js_suite' $(if ($sp.ExitCode -eq 0) { 'PASS' } else { 'FAIL' })
Require ($sp.ExitCode -eq 0) "the CAP-10C3 suite exited $($sp.ExitCode)"

$corpusPath = Join-Path $work 'devpas2js-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite wrote no decision corpus'
if (Test-Path -LiteralPath $corpusPath) {
    $corpusText = [System.IO.File]::ReadAllText($corpusPath).Replace("`r`n", "`n")
    $decisions = @($corpusText -split "`n" | Where-Object {
        ($_ -ne '') -and (-not $_.StartsWith('#')) })
    Row 'dev_pas2js_digest' (Sha256Text $corpusText)
    Row 'dev_pas2js_corpus_lines' "$($decisions.Count)"
    Require ($decisions.Count -ge 20) `
        "the decision corpus carries only $($decisions.Count) decision(s)"
    # NO ABSOLUTE PATH may reach a corpus four targets have to agree on
    $abs = @($decisions | Where-Object { ($_ -match ':[\\/]') -or ($_ -match '\|/') })
    Require ($abs.Count -eq 0) `
        "a corpus line names an absolute path: $($abs | Select-Object -First 1)"
} else {
    Row 'dev_pas2js_digest' 'unmeasured'
    Row 'dev_pas2js_corpus_lines' '0'
}

# --- 2. the contract cross-checks and the ledger, read back -----------------
foreach ($pair in @(@('contracts.json', 'contract cross-checks'),
                    @('ledger.json', 'ledger disposition'))) {
    $p = Join-Path $work $pair[0]
    Require (Test-Path -LiteralPath $p) `
        "the $($pair[1]) record is absent -- run its script first"
}
$contracts = $null
if (Test-Path -LiteralPath (Join-Path $work 'contracts.json')) {
    $contracts = Get-Content (Join-Path $work 'contracts.json') -Raw | ConvertFrom-Json
    Require ("$($contracts.verdict)" -ceq 'PASS') `
        "the CAP-10C3 contract cross-checks did not PASS"
    # T1 and T2, for a PAS2JS project this time
    Row 'dev_pas2js_csp_identical' (Bool ($contracts.csp_identical -eq $true))
    Row 'dev_pas2js_release_dev_free' `
        (Bool (($contracts.release_dev_unit_absent -eq $true) -and
               ($contracts.dev_marker_in_release_binary -eq $false)))
    Row 'dev_pas2js_transport_hits' "$($contracts.transport_hits)"
    Row 'dev_pas2js_watch_api_hits' "$($contracts.watch_api_hits)"
    Require ($contracts.csp_identical -eq $true) `
        'T1: PWEB_NATIVE_CSP is not byte-identical in both pas2js host binaries'
    Require ($contracts.release_dev_unit_absent -eq $true) `
        'T2: the pas2js release unit set carries the development unit'
    Require ($contracts.dev_marker_in_release_binary -eq $false) `
        'T2: the pas2js release binary carries the development argument'
    Require ("$($contracts.transport_hits)" -ceq '0') `
        'T3: a transport origin or call reached this shard'
    Require ("$($contracts.watch_api_hits)" -ceq '0') `
        'a platform file-watch API reached the tree; polling was ratified'
}
$ledger = $null
if (Test-Path -LiteralPath (Join-Path $work 'ledger.json')) {
    $ledger = Get-Content (Join-Path $work 'ledger.json') -Raw | ConvertFrom-Json
    Row 'cap10c_ledger_entries' "$($ledger.ledger_entries)"
    Row 'cap10c_ledger_orphans' "$($ledger.ledger_orphans)"
    Row 'cap10c_closure_recorded' (Bool ("$($ledger.verdict)" -ceq 'PASS'))
    Require ("$($ledger.verdict)" -ceq 'PASS') `
        'CL2: the CAP-10C ledger disposition did not PASS'
    Require ("$($ledger.ledger_orphans)" -ceq '0') `
        "CL2: $($ledger.ledger_orphans) ledger entr(y|ies) have no disposition"
} else {
    Row 'cap10c_ledger_entries' '0'
    Row 'cap10c_ledger_orphans' 'unmeasured'
    Row 'cap10c_closure_recorded' 'false'
}

# --- 3. PU1 / the public surface --------------------------------------------
function RunCli([string[]]$CliArgs, [string]$WorkDir) {
    $so = Join-Path $work 'cli-stdout.txt'
    $se = Join-Path $work 'cli-stderr.txt'
    $p = Start-Process -FilePath $pweb -ArgumentList $CliArgs -Wait -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = [System.IO.File]::ReadAllText($so)
        Err = [System.IO.File]::ReadAllText($se)
    }
}
$cwd = Join-Path $work 'cwd'
New-Item -ItemType Directory -Force $cwd | Out-Null
$surface = $true
foreach ($case in @(
        @{ Args = @('dev', '--project', 'a', '--project', 'b'); Code = 2; Cause = 'duplicate_option' },
        @{ Args = @('dev', '--json');                           Code = 2; Cause = 'option_not_for_command' },
        @{ Args = @('dev', 'extra');                            Code = 2; Cause = 'extra_positional' },
        @{ Args = @('build');                                   Code = 2; Cause = 'unknown_command' })) {
    $r = RunCli $case.Args $cwd
    $ok = ($r.Code -eq $case.Code) -and ($r.Err.Contains($case.Cause))
    if (-not $ok) {
        $surface = $false
        Require $false ("public surface: pweb $($case.Args -join ' ') answered " +
            "$($r.Code)/$($r.Err.Trim()) -- expected $($case.Code)/$($case.Cause)")
    }
}
$devHelp = RunCli @('dev', '--help') $cwd
Require ($devHelp.Code -eq 0) 'dev --help did not exit 0'
Require ($devHelp.Out.Contains('react')) 'dev --help does not advertise react'
Require ($devHelp.Out.Contains('pas2js')) 'dev --help does not advertise pas2js'
Require (-not $devHelp.Out.Contains([char]27)) 'dev --help emitted ANSI'
# and it must no longer say the CAP-10C2 sentence
Require (-not $devHelp.Out.Contains('ONLY. A `pas2js` project is refused')) `
    'dev --help still says this build implements react only'
$mainHelp = RunCli @('--help') $cwd
Require ($mainHelp.Out.Contains('pweb dev ')) '--help does not advertise dev'
Require (-not $mainHelp.Out.Contains('pweb build')) '--help advertises build'
Row 'dev_pas2js_option_matrix' $(if ($surface) { 'PASS' } else { 'FAIL' })
Row 'build_still_unknown_c3' (Bool $surface)
Row 'advertised_commands_c3' 'create,doctor,run,dev'

# --- 4. the project this gate drives, SCAFFOLDED BY THE REAL CLI ------------
# NOT borrowed from another shard's stage. A development loop is a claim about
# what `pweb create` produces TODAY.
$stage = Join-Path $work 'stage'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
New-Item -ItemType Directory -Force $stage | Out-Null
$r = RunCli @('create', 'demo', '--ui', 'pas2js', '--bundle-id', 'com.example.demo') `
    (New-Item -ItemType Directory -Force (Join-Path $stage 'pas2js') | ForEach-Object { $_.FullName })
Require ($r.Code -eq 0) "scaffolding the pas2js project failed: $($r.Code) $($r.Err.Trim())"
$p2j = Join-Path $stage 'pas2js/demo'
$fe = Join-Path $p2j 'frontend'
Require (Test-Path -LiteralPath (Join-Path $fe 'pas2js.cfg')) `
    'the scaffolded pas2js project has no pas2js.cfg'
# the PWEB_DEV region has to be IN the template this build produces, or the
# development host cannot be compiled from it at all
$genProgram = [System.IO.File]::ReadAllText((Join-Path $p2j 'src/demo.lpr'))
Row 'dev_region_in_pas2js_template' (Bool ($genProgram.Contains('PWEB_DEV')))
Require ($genProgram.Contains('PWEB_DEV')) `
    'the generated pas2js program carries no PWEB_DEV region'

# --- 5. PD9 and PD10: the input set refuses BEFORE anything is started ------
# Both are measured on a COPY, so the project the loop later drives is the one
# `pweb create` produced and not one this gate mutated.
function TreeFingerprint([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return '<absent>' }
    $lines = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
            "$rel $($_.Length)"
        })
    $sorted = [string[]]$lines
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return Sha256Text (($sorted -join "`n") + "`n")
}

# PD9: a link inside <frontend>/src
$linkProj = Join-Path $work 'refuse-link'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $linkProj
Copy-Item -Recurse -Force -LiteralPath $p2j -Destination $linkProj
$outside = Join-Path $work 'refuse-link-outside'
New-Item -ItemType Directory -Force $outside | Out-Null
[System.IO.File]::WriteAllText((Join-Path $outside 'secret.pas'),
    "unit secret; end.`n", [System.Text.UTF8Encoding]::new($false))
$linkPath = Join-Path $linkProj 'frontend/src/escape'
$linkMade = $false
try {
    if ($IsWindows) {
        New-Item -ItemType Junction -Path $linkPath -Target $outside -ErrorAction Stop | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $outside -ErrorAction Stop | Out-Null
    }
    $linkMade = Test-Path -LiteralPath $linkPath
} catch { $linkMade = $false }
Row 'pd9_link_planted' (Bool $linkMade)
if ($linkMade) {
    $before = TreeFingerprint $linkProj
    $r = RunCli @('dev', '--project', $linkProj) $cwd
    $after = TreeFingerprint $linkProj
    Row 'pd9_exit' "$($r.Code)"
    Row 'pd9_cause' $(if ($r.Err.Contains('dev_input_link')) { 'dev_input_link' } else { 'other' })
    Row 'pd9_nothing_written' (Bool ($before -ceq $after))
    Require ($r.Code -eq 3) "PD9: a link in the input set answered $($r.Code), expected 3"
    Require ($r.Err.Contains('dev_input_link')) `
        'PD9: the refusal does not name dev_input_link'
    Require ($before -ceq $after) 'PD9: the refused run wrote into the project'
} else {
    # MAKING A LINK IS A PRIVILEGE on some hosts. The leg records that it
    # could not plant one rather than claiming a refusal it never exercised -
    # and the RULE is still asserted, by the headless suite's refusal
    # vocabulary and by the contract gate's source check
    Row 'pd9_exit' 'unmeasured'
    Row 'pd9_cause' 'unmeasured'
    Row 'pd9_nothing_written' 'unmeasured'
    Write-Host '[CAP-10C3] PD9: this host would not create a link; leg recorded as unmeasured'
}

# PD10: more files than the ratified bound
$boundProj = Join-Path $work 'refuse-bound'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $boundProj
Copy-Item -Recurse -Force -LiteralPath $p2j -Destination $boundProj
$boundSrc = Join-Path $boundProj 'frontend/src'
for ($i = 1; $i -le 520; $i++) {
    [System.IO.File]::WriteAllText((Join-Path $boundSrc "pad$i.pas"),
        "unit pad$i; end.`n", [System.Text.UTF8Encoding]::new($false))
}
$before = TreeFingerprint $boundProj
$r = RunCli @('dev', '--project', $boundProj) $cwd
$after = TreeFingerprint $boundProj
Row 'pd10_exit' "$($r.Code)"
Row 'pd10_cause' $(if ($r.Err.Contains('dev_input_bound')) { 'dev_input_bound' } else { 'other' })
Row 'pd10_nothing_written' (Bool ($before -ceq $after))
Require ($r.Code -eq 3) "PD10: a set past the bound answered $($r.Code), expected 3"
Require ($r.Err.Contains('dev_input_bound')) `
    'PD10: the refusal does not name dev_input_bound'
Require ($before -ceq $after) 'PD10: the refused run wrote into the project'

# --- 6. the REAL loop: PD1-PD8, PD11, PD13, PD15 ---------------------------
$devDir = Join-Path $p2j "dist/$target/dev"
$releaseDir = Join-Path $p2j "dist/$target/release"

# PD13: the RELEASE tree, digested before and after a development session. A
# freshly scaffolded project has none, and `<absent>` on both sides would be a
# claim about nothing - so one is SEEDED with the shape the CAP-10C1 layout
# commits, and the claim becomes the one the matrix states.
function TreeDigest([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return '<absent>' }
    $lines = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
            "$rel $($_.Length) $(Sha256File $_.FullName)"
        })
    $sorted = [string[]]$lines
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return Sha256Text (($sorted -join "`n") + "`n")
}
New-Item -ItemType Directory -Force $releaseDir | Out-Null
foreach ($seed in @('demo.exe', 'demo', 'app.pwb', 'webview.dll',
                    'libwebview.so.0.12', 'libwebview.dylib')) {
    $p = Join-Path $releaseDir $seed
    if (-not (Test-Path -LiteralPath $p)) {
        [System.IO.File]::WriteAllText($p,
            "CAP-10C3 PD13 seed: a development session must not touch this`n",
            [System.Text.UTF8Encoding]::new($false))
    }
}
$releaseBefore = TreeDigest $releaseDir
Row 'pd13_release_seeded' (Bool ($releaseBefore -cne '<absent>'))
Require ($releaseBefore -cne '<absent>') `
    'PD13: the release tree could not be seeded, so the leg proves nothing'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $devDir

$report = Join-Path $work 'p2jdrv-report.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $report
$drvArgs = @(
    '--pweb', $pweb,
    '--project', $p2j,
    '--source', (Join-Path $fe 'src/app.pas'),
    '--style', (Join-Path $fe 'app.css'),
    '--markup', (Join-Path $fe 'index.html'),
    '--native', (Join-Path $p2j 'src/app.services.pas'),
    '--readme', (Join-Path $p2j 'README.md'),
    '--scenario', 'loop',
    '--report', $report,
    '--cwd', $cwd)
if (Test-Path -LiteralPath $helper) { $drvArgs += @('--helper', $helper) }
$drvOut = Join-Path $work 'p2jdrv-stdout.txt'
$drvErr = Join-Path $work 'p2jdrv-stderr.txt'
$p = Start-Process -FilePath $driver -ArgumentList $drvArgs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $cwd `
    -RedirectStandardOutput $drvOut -RedirectStandardError $drvErr
Write-Host "[CAP-10C3] the driver exited $($p.ExitCode)"
Require ($p.ExitCode -eq 0) "the CAP-10C3 driver exited $($p.ExitCode)"
Require (Test-Path -LiteralPath $report) 'the driver wrote no report'

$drv = @{}
if (Test-Path -LiteralPath $report) {
    foreach ($line in [System.IO.File]::ReadAllLines($report)) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $drv[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
    }
}
Require (-not $drv.ContainsKey('driver_error')) `
    "the driver reported $($drv['driver_error'])"
foreach ($k in @('pd1_generation_ready', 'pd1_generation_loaded',
                 'pd1_rpc_and_secure', 'pd2_generation_ready',
                 'pd2_host_pid_unchanged', 'pd3_generation_ready',
                 'pd3_styles_applied', 'pd4_generation_ready',
                 'pd5_broken_published', 'pd5_error_forwarded',
                 'pd5_recovered', 'pd6_burst_edits', 'pd6_monotonic',
                 'pd6_all_generations_loaded', 'pd6_final_value',
                 'pd6_final_content_correct', 'pd7_discarded',
                 'pd7_inconsistent_discarded', 'pd7_recovered',
                 'pd8_outside_published', 'pd11_stop_requested',
                 'pd11_pweb_outcome', 'pd11_pweb_exit',
                 'pd11_descendants_remaining', 'pd11_interrupt_delivered',
                 'pd11_interrupt_to_exit_ms', 'pd5_compile_failures',
                 'pd7_moving_writes', 'generations_ready',
                 'generations_loaded')) {
    Row $k $(if ($drv.ContainsKey($k)) { "$($drv[$k])" } else { 'unmeasured' })
}
foreach ($pin in @(
        @('pd1_generation_ready', 'true'), @('pd1_generation_loaded', 'true'),
        @('pd1_rpc_and_secure', 'true'), @('pd2_generation_ready', 'true'),
        @('pd2_host_pid_unchanged', 'true'), @('pd3_generation_ready', 'true'),
        @('pd3_styles_applied', 'true'), @('pd4_generation_ready', 'true'),
        @('pd5_broken_published', 'false'), @('pd5_error_forwarded', 'true'),
        @('pd5_recovered', 'true'), @('pd6_burst_edits', '5'),
        @('pd6_monotonic', 'true'), @('pd6_all_generations_loaded', 'true'),
        @('pd6_final_value', '47'), @('pd6_final_content_correct', 'true'),
        @('pd7_inconsistent_discarded', 'true'), @('pd7_recovered', 'true'),
        @('pd8_outside_published', 'false'), @('pd11_stop_requested', 'true'),
        @('pd11_pweb_outcome', 'exited'), @('pd11_pweb_exit', '0'),
        @('pd11_descendants_remaining', '0'),
        @('pd11_interrupt_delivered', 'true'))) {
    Require ("$($drv[$pin[0]])" -ceq $pin[1]) `
        ("$($pin[0]) is '$($drv[$pin[0]])', expected '$($pin[1])'")
}
# PD5's other half: a broken source is answered ONCE, not rebuilt forever.
# MEASURED before this bound existed: one bad `const` recompiled the whole
# frontend every few seconds for as long as it stayed broken.
$compileFailures = [int]("0" + "$($drv['pd5_compile_failures'])")
Require (($compileFailures -ge 1) -and ($compileFailures -le 3)) `
    ("PD5: the loop reported $compileFailures compile failure(s) for ONE " +
     'broken source; a failed input state is answered once, not polled')
Row 'dev_pas2js_error_keeps_previous_generation' `
    (Bool ("$($drv['pd5_broken_published'])" -ceq 'false'))
Row 'dev_pas2js_inconsistent_generation_discarded' `
    (Bool ("$($drv['pd7_inconsistent_discarded'])" -ceq 'true'))
Row 'dev_pas2js_generations_observed' "$($drv['generations_ready'])"
Row 'dev_pas2js_rpc_after_switch' "$($drv['pd6_final_value'])"
Row 'dev_pas2js_interrupt_clean' `
    (Bool (("$($drv['pd11_pweb_exit'])" -ceq '0') -and
           ("$($drv['pd11_descendants_remaining'])" -ceq '0')))
Row 'dev_pas2js_descendants_after_stop' "$($drv['pd11_descendants_remaining'])"

# PD13: the release tree, unchanged
$releaseAfter = TreeDigest $releaseDir
Row 'pd13_release_unchanged' (Bool ($releaseBefore -ceq $releaseAfter))
Require ($releaseBefore -ceq $releaseAfter) `
    'PD13: a development session changed the release tree'

# PD11's other half, and PD15: read out of the run's own lines
$lines = @()
if (Test-Path -LiteralPath "$report.lines") {
    $lines = [System.IO.File]::ReadAllLines("$report.lines")
}
$supervisorLines = @($lines | Where-Object { $_ -match '^E\| pweb: ' })
$readyLines = @($supervisorLines | Where-Object {
    $_ -match 'pweb: generation \d+ ready \(\d+ ms\)$' })
$announced = @($readyLines | ForEach-Object {
    if ($_ -match 'generation (\d+) ready') { [int]$Matches[1] } })
$maxGen = 0
if ($announced.Count -gt 0) { $maxGen = ($announced | Measure-Object -Maximum).Maximum }
$exact = ($announced.Count -eq $maxGen) -and
         (@($announced | Sort-Object -Unique).Count -eq $maxGen)
Row 'pd15_generation_lines' "$($announced.Count)"
Row 'pd15_exact_one_line_per_generation' (Bool $exact)
Require $exact `
    "PD15: the announced generations are not 1..N exactly once: $($announced -join ',')"
$ansi = ($supervisorLines -join "`n").Contains([char]27)
Row 'pd15_no_ansi' (Bool (-not $ansi))
Require (-not $ansi) 'PD15: the supervisor emitted ANSI'
# nor may a SUPERVISOR line name an absolute path. A tool's own forwarded
# bytes are the tool's - pas2js names the RTL sources it compiled - and the
# claim is about the lines this CLI writes, which is the scope pwebpipe's
# header already records for a build.
$absolute = @($supervisorLines | Where-Object {
    ($_ -match ':[\\/]') -or ($_ -match '^E\| pweb: /') })
Row 'pd15_no_absolute_path' (Bool ($absolute.Count -eq 0))
Require ($absolute.Count -eq 0) `
    "PD15: a supervisor line names an absolute path: $($absolute | Select-Object -First 1)"
# and NO NETWORK STAGE was declared or run: the react-only stages are named
# not-applicable and no `install:` line exists at all
$stageLine = @($supervisorLines | Where-Object { $_ -match 'not applicable' })
$installLine = @($supervisorLines | Where-Object { $_ -match 'pweb: install: ' })
Row 'dev_pas2js_network_stages' $(if ($installLine.Count -eq 0) { 'none' } else { 'npm_ci' })
Row 'dev_pas2js_network_calls' $(if ($installLine.Count -eq 0) { '0' } else { "$($installLine.Count)" })
Require ($installLine.Count -eq 0) `
    'a pas2js development session ran an install stage; it has no network stage at all'
Require ($stageLine.Count -ge 1) `
    'the loop did not report the react-only stages as not applicable'
Row 'dev_pas2js_watched_input_count' $(
    if (($supervisorLines -join "`n") -match 'over (\d+) input\(s\)') { $Matches[1] }
    else { 'unmeasured' })
# WHAT THE CAP-10C1 ASSEMBLY HAD TO NORMALISE on this target. CAP-10B2
# measured the compiler writing through the host's text layer - BOM and CRLF
# on Windows, LF on POSIX - so this row is EXPECTED to differ across targets
# and is recorded per target, never compared. What it proves is that the
# development loop ran the same assembly the pipeline runs.
Row 'dev_pas2js_normalised' $(
    if (($supervisorLines -join "`n") -match 'assembly: (bom=\w+ cr=\w+)') { $Matches[1] }
    else { 'unmeasured' })
Require ((($supervisorLines -join "`n")) -match 'assembly: bom=') `
    'the loop never reported what the Pas2JS assembly normalised'

# T4: NO LOOSE ASSETS. Two halves: every published generation is one
# frozen-bundler archive and nothing else, and the directory the development
# binary runs from carries the binary and the engine library and NO bundle.
$gens = @()
if (Test-Path -LiteralPath $devDir) {
    $gens = @(Get-ChildItem -LiteralPath $devDir -Directory |
        Where-Object { $_.Name -match '^gen-\d+$' })
}
$onlyArchive = $true
foreach ($g in $gens) {
    $names = @(Get-ChildItem -LiteralPath $g.FullName -Recurse -File -Force |
        ForEach-Object { $_.Name })
    if (($names.Count -ne 1) -or ($names[0] -cne 'app.pwb')) { $onlyArchive = $false }
}
# THE ARITHMETIC OF GENERATION 1, which is the template's own and is 42.
# Every later generation carries a different summand, so a `"value":42`
# report in this run's lines can only be the first one - and PD1's claim is
# that the window opened on the archive the loop packed before it started.
$sawFortyTwo = @($lines | Where-Object { $_ -match '"value":42\b' }).Count -gt 0
Row 'dev_pas2js_rpc_value' $(if ($sawFortyTwo) { '42' } else { 'unmeasured' })
Require $sawFortyTwo `
    'PD1: the page never reported CalculatorService.Add(20,22) = 42'

$appDir = Join-Path $devDir 'app'
$appNames = @()
if (Test-Path -LiteralPath $appDir) {
    $appNames = @(Get-ChildItem -LiteralPath $appDir -Recurse -File -Force |
        ForEach-Object { $_.Name })
}
$devBundleBeside = @($appNames | Where-Object { $_ -ceq 'app.pwb' }).Count -gt 0
$frontendLoose = @($appNames | Where-Object {
    $_ -match '\.(html|css|js|mjs|map|json)$' }).Count -gt 0
Row 'dev_pas2js_app_dir_names' (($appNames | Sort-Object) -join ',')
Row 'dev_pas2js_generation_holds_only_archive' (Bool $onlyArchive)
Row 'dev_pas2js_loose_assets_used' (Bool ($devBundleBeside -or $frontendLoose -or (-not $onlyArchive)))
Require $onlyArchive 'T4: a published generation holds something other than app.pwb'
Require (-not $devBundleBeside) 'T4: an app.pwb sits beside the development binary'
Require (-not $frontendLoose) 'T4: a loose frontend asset sits beside the development binary'
# and no partial generation survived the interrupt
$tmpLeft = Test-Path -LiteralPath (Join-Path $devDir '.gen.tmp')
Row 'pd11_no_partial_generation' (Bool (-not $tmpLeft))
Require (-not $tmpLeft) 'PD11: a .gen.tmp survived the interrupt'

# --- 7. PD12, and the LIVE set ---------------------------------------------
# The listener sample needs a running set, and PD12 needs one it can end from
# outside, so the killhost scenario provides both: the driver waits until the
# set is up, this gate samples it, and the driver then kills the host.
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $devDir
$kreport = Join-Path $work 'p2jdrv-killhost.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $kreport
$kargs = @(
    '--pweb', $pweb, '--project', $p2j,
    '--source', (Join-Path $fe 'src/app.pas'),
    '--style', (Join-Path $fe 'app.css'),
    '--markup', (Join-Path $fe 'index.html'),
    '--scenario', 'killhost',
    '--report', $kreport, '--cwd', $cwd)
if (Test-Path -LiteralPath $helper) { $kargs += @('--helper', $helper) }
$ko = Join-Path $work 'p2jdrv-killhost-stdout.txt'
$ke = Join-Path $work 'p2jdrv-killhost-stderr.txt'
$kp = Start-Process -FilePath $driver -ArgumentList $kargs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $cwd `
    -RedirectStandardOutput $ko -RedirectStandardError $ke
Write-Host "[CAP-10C3] the killhost driver exited $($kp.ExitCode)"
Require ($kp.ExitCode -eq 0) "the killhost driver exited $($kp.ExitCode)"
$kd = @{}
if (Test-Path -LiteralPath $kreport) {
    foreach ($line in [System.IO.File]::ReadAllLines($kreport)) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $kd[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
    }
}
foreach ($k in @('pd12_set_was_up', 'pd12_kill_delivered', 'pd12_pweb_outcome',
                 'pd12_pweb_exit', 'pd12_descendants_remaining',
                 'pd12_kill_to_exit_ms')) {
    Row $k $(if ($kd.ContainsKey($k)) { "$($kd[$k])" } else { 'unmeasured' })
}
foreach ($pin in @(@('pd12_set_was_up', 'true'), @('pd12_kill_delivered', 'true'),
                   @('pd12_pweb_outcome', 'exited'), @('pd12_pweb_exit', '5'),
                   @('pd12_descendants_remaining', '0'))) {
    Require ("$($kd[$pin[0]])" -ceq $pin[1]) `
        ("$($pin[0]) is '$($kd[$pin[0]])', expected '$($pin[1])'")
}
$ktmp = Test-Path -LiteralPath (Join-Path $devDir '.gen.tmp')
Row 'pd12_no_partial_generation' (Bool (-not $ktmp))
Require (-not $ktmp) 'PD12: a .gen.tmp survived the host death'

# THE ONE ROW THAT SAYS NO PARTIAL OR INCONSISTENT GENERATION EVER REACHED
# THE HOST, composed from the five independent measurements that make it up
# rather than asserted on its own: a broken source published nothing, every
# announced generation was acknowledged, each published one holds exactly the
# archive, and neither ending left a `.gen.tmp` behind.
$noPartial = ("$($drv['pd5_broken_published'])" -ceq 'false') -and
             ("$($drv['pd6_all_generations_loaded'])" -ceq 'true') -and
             $onlyArchive -and (-not $tmpLeft) -and (-not $ktmp)
Row 'dev_pas2js_partial_generation_published' (Bool (-not $noPartial))
Require $noPartial `
    'a partial or inconsistent generation reached the host'

# the LIVE set's listener count, sampled on a run of its own. A Pas2JS
# session has ONE long-lived member, so the sample is the host's descendant
# closure - and `pweb` itself is outside it, covered by the source proofs
# (dev_pas2js_transport_hits, dev_env_reads) and by the CAP-10C0 gates.
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $devDir
$lo = Join-Path $work 'p2j-live-stdout.txt'
$le = Join-Path $work 'p2j-live-stderr.txt'
$lp = Start-Process -FilePath $pweb -ArgumentList @('dev', '--project', $p2j) `
    -PassThru -NoNewWindow -WorkingDirectory $cwd `
    -RedirectStandardOutput $lo -RedirectStandardError $le
$liveDeadline = (Get-Date).AddSeconds(600)
$seen = ''
while (((Get-Date) -lt $liveDeadline) -and (-not $lp.HasExited)) {
    $seen = ReadLive $le
    if (($seen -match '(?m)^pweb: generation 1 ready') -and
        ($seen -match '(?m)^pweb: started pid \d+')) { break }
    Start-Sleep -Milliseconds 500
}
$livePids = @()
if ($seen -match '(?m)^pweb: started pid (\d+)') { $livePids += [int]$Matches[1] }
$listenMax = 0
$membersSeen = 0
$passes = 0
while (($passes -lt 8) -and (-not $lp.HasExited) -and ($livePids.Count -gt 0)) {
    $passes++
    $pass = 0
    foreach ($rootPid in $livePids) {
        $members = @(Get-PWebTreeMembers -RootPid $rootPid)
        $pass += $members.Count
        foreach ($m in $members) {
            $n = Get-PWebListenerCount -OwnerPid $m
            if ($n -gt $listenMax) { $listenMax = $n }
        }
    }
    if ($pass -gt $membersSeen) { $membersSeen = $pass }
    Start-Sleep -Milliseconds 400
}
Row 'dev_pas2js_listener_sampler_scope' (Get-PWebSamplerScope)
Row 'dev_pas2js_listener_members_seen' "$membersSeen"
Row 'dev_pas2js_listener_members_max' "$listenMax"
Require ($membersSeen -gt 0) `
    'the listener sampler saw no member at all, so its zero says nothing'
Require ($listenMax -eq 0) `
    "a member of the live pas2js development set held $listenMax listening socket(s)"
if (-not $lp.HasExited) { $lp.Kill($true) }
$lp.WaitForExit(30000) | Out-Null

# --- 8. PD14: the archive parity that is this shard's point -----------------
# gen-1's app.pwb against the CAP-10C1 pipeline's, for the SAME sources. The
# pipeline is driven by the CAP-10C1 private driver, which is the only thing
# in the tree that calls it - `pweb build` is still an unknown command.
#
# IT IS MEASURED ON THE RUN ABOVE, which stops at generation 1, and NOT on
# the driven session. MEASURED on hosted run 33790870889: the driven session
# publishes six generations, so the bounded cleanup removes gen-1, gen-2 and
# gen-3 the moment generation 6 is acknowledged - and the leg failed with
# "generation 1 is absent" on Linux while passing on Windows, where the
# running host still had the archive open and the removal quietly failed.
# A parity claim measured on a generation the loop is entitled to delete is
# a claim that depends on the platform's unlink semantics; measured on a
# one-generation run it depends on nothing.
$genOne = Join-Path $devDir 'gen-1/app.pwb'
$pipeBundle = Join-Path $p2j "dist/$target/app.pwb"
Require (Test-Path -LiteralPath $genOne) `
    'PD14: the one-generation run left no gen-1/app.pwb to compare'
Require (Test-Path -LiteralPath $pipe) `
    'PD14: the CAP-10C1 pipeline driver is absent -- run its build first'
if ((Test-Path -LiteralPath $genOne) -and (Test-Path -LiteralPath $pipe)) {
    $pr = Start-Process -FilePath $pipe -ArgumentList @('--project', $p2j) `
        -Wait -PassThru -NoNewWindow -WorkingDirectory $cwd `
        -RedirectStandardOutput (Join-Path $work 'pipe-stdout.txt') `
        -RedirectStandardError (Join-Path $work 'pipe-stderr.txt')
    Require ($pr.ExitCode -eq 0) `
        "PD14: the CAP-10C1 pipeline exited $($pr.ExitCode) on the pas2js project"
    if (Test-Path -LiteralPath $pipeBundle) {
        $mine = Sha256File $genOne
        $theirs = Sha256File $pipeBundle
        Row 'dev_pas2js_gen1_sha256' $mine
        Row 'dev_pas2js_app_pwb_parity' (Bool ($mine -ceq $theirs))
        Require ($mine -ceq $theirs) `
            ("PD14: generation 1's archive differs from the CAP-10C1 " +
             "pipeline's: $mine vs $theirs")
    } else {
        Row 'dev_pas2js_gen1_sha256' 'unmeasured'
        Row 'dev_pas2js_app_pwb_parity' 'false'
        Require $false 'PD14: the pipeline produced no app.pwb'
    }
} else {
    Row 'dev_pas2js_gen1_sha256' 'unmeasured'
    Row 'dev_pas2js_app_pwb_parity' 'false'
}

# --- 9. RD1: the React loop is unchanged ------------------------------------
# The CAP-10C2 gates run on this same job and record their own verdict; this
# reads it back and pins the decision digest, so a shard that moved a React
# decision while adding a Pas2JS one is refused here by name.
$c2File = Join-Path $repoRoot "build/cap10c2/cli-$target.json"
if (Test-Path -LiteralPath $c2File) {
    $c2 = Get-Content $c2File -Raw | ConvertFrom-Json
    $devClosure = '09cc2b1c1c2c6b103d88c744fd0a861818f43e55d76f852d6472f155ce0b7df6'
    Row 'rd1_dev_digest_unchanged' (Bool ("$($c2.dev_digest)" -ceq $devClosure))
    Row 'rd1_dev_suite' "$($c2.dev_suite)"
    Require ("$($c2.dev_digest)" -ceq $devClosure) `
        ("RD1: dev_digest moved to $($c2.dev_digest); CAP-10C2 closed on " +
         "$devClosure -- the React decisions must not move")
    Require ("$($c2.dev_suite)" -ceq 'PASS') 'RD1: the CAP-10C2 dev suite did not PASS'
} else {
    Row 'rd1_dev_digest_unchanged' 'unmeasured'
    Row 'rd1_dev_suite' 'unmeasured'
    Require $false 'RD1: the CAP-10C2 record is absent -- its gates have not run here'
}
# and the CAP-10C1 pipeline digest, re-measured
$c1File = Join-Path $repoRoot "build/cap10c1/cli-$target.json"
if (Test-Path -LiteralPath $c1File) {
    $c1 = Get-Content $c1File -Raw | ConvertFrom-Json
    $pipeClosure = 'f890424a5ef95646b9a48355819e32f49e608c7f5ecc4e69766b4182978e839a'
    Row 'c3_pipeline_digest_unchanged' (Bool ("$($c1.pipeline_digest)" -ceq $pipeClosure))
    Require ("$($c1.pipeline_digest)" -ceq $pipeClosure) `
        "pipeline_digest moved to $($c1.pipeline_digest); CAP-10C1 closed on $pipeClosure"
} else {
    Row 'c3_pipeline_digest_unchanged' 'unmeasured'
    Require $false 'the CAP-10C1 record is absent -- its gates have not run here'
}

# --- verdict and evidence ---------------------------------------------------
Row 'dev_pas2js_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($rows | ConvertTo-Json -Depth 6)
if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10C3 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10C3] pas2js development-loop gates PASS on $target"
