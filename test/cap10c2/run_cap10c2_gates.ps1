# CAP-10C2: the development-loop gates - DEV1..DEV14 and T1..T5.
#
# ONE run of the REAL `pweb dev` on a REAL generated project, driven by
# test/cap10c2/pwebdevdrv (which spawns it with its own console and delivers
# a real interrupt through the CAP-10C0 helper), plus the headless suite's
# decision corpus and the checkout-only measurements a running loop cannot
# make about itself.
#
# WHAT IT NEVER DOES: reimplement a rule. Every refusal it exercises is the
# CLI's own, every digest it compares is one the gate that owns it recorded,
# and every process it looks at it found by MEMBERSHIP or by pid, never by
# name.
#
# Emits build/cap10c2/cli-<target>.json for the CAP-7F aggregation, plus
# build/cap10c2/dev-corpus.txt (from the suite) and the driver's own report.
#
# Usage: pwsh test/cap10c2/run_cap10c2_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10c2'
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

# the four ratified targets, named the way the CLI names them
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

# READ A FILE A LIVE PROCESS IS STILL WRITING.
#
# MEASURED, and it cost a green leg: `Start-Process -RedirectStandardError`
# holds the file on Windows, and `[System.IO.File]::ReadAllText` on it throws
# a sharing violation for as long as the process lives. The DEV14 second-run
# leg polled with ReadAllText inside a try/catch, so every read threw and the
# text stayed empty - and the leg passed anyway, because until the generation
# reclaim landed that run CRASHED, the handle was released, and the very last
# read succeeded. A leg that only works when the thing it measures is broken
# is worse than no leg. FileShare.ReadWrite is what a live log needs.
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
# than reimplemented: one rule, measured in the C0, C1 and C2 gates alike
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

# THE RATIFIED LOOP MODEL, recorded so four targets can be compared on it and
# so a shard that quietly switched to a proxy would be a divergence rather
# than a diff nobody read. CAP-10C2 measured Vite's dev server against the
# frozen pweb://app grammar and refused it: see
# _bmad-output/implementation-artifacts/cap10c2-model-a-spike.md
Row 'dev_loop_model' 'rebuild_and_reload'
Row 'cli_dev_available' 'true'

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
$suite = Join-Path $work "bin/c2tests$exeSuffix"
$driver = Join-Path $work "bin/pwebdevdrv$exeSuffix"
$helper = Join-Path $repoRoot "build/cap10c0/bin/pwebchild$exeSuffix"
foreach ($pre in $pweb, $suite, $driver) {
    Require (Test-Path -LiteralPath $pre) `
        "precondition absent: $pre -- run test/cap10c2/build_cap10c2 first"
}
if ($failures.Count -gt 0) {
    throw "CAP-10C2 preconditions FAILED: $($failures.Count)"
}

# --- 1. the headless suite and its corpus -----------------------------------
# THE INVOCATION IS THE ONE CAP-10C1 HAD TO LEARN: /noenter is the WINDOWS
# switch, and the POSIX runner reads it as a FILENAME, prints its usage and
# exits 0 - a green verdict over nothing. So the option is passed on Windows
# only, and the corpus is REQUIRED to carry at least one decision whatever
# the exit code said.
$suiteLog = Join-Path $work 'c2tests.log'
$corpusPath = Join-Path $work 'dev-corpus.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $corpusPath
if ($IsWindows) { $out = & $suite /noenter 2>&1 | Out-String }
else { $out = & $suite 2>&1 | Out-String }
$suiteCode = $LASTEXITCODE
[System.IO.File]::WriteAllText($suiteLog, $out)
Write-Host $out
Require ($suiteCode -eq 0) 'the CAP-10C2 suite failed'
foreach ($anchor in 'P web dev pure', 'P web dev fs') {
    Require ($out.Contains($anchor)) "the suite never registered '$anchor'"
}
Row 'dev_suite' $(if ($suiteCode -eq 0) { 'PASS' } else { 'FAIL' })
Require (Test-Path -LiteralPath $corpusPath) 'the suite emitted no corpus'
if (Test-Path -LiteralPath $corpusPath) {
    $corpusLines = @([System.IO.File]::ReadAllLines($corpusPath) |
        Where-Object { ($_ -ne '') -and ($_ -notmatch '^#') })
    Row 'dev_digest' (Sha256File $corpusPath)
    Row 'dev_corpus_lines' "$($corpusLines.Count)"
    # THE GUARD CAP-10C1 ADDED AND THIS SHARD INHERITS: a corpus with no
    # decisions is a suite that did not run, whatever its exit code said
    Require ($corpusLines.Count -gt 0) `
        'the CAP-10C2 corpus carries no decision -- the suite did not run'
} else {
    Row 'dev_digest' ''
    Row 'dev_corpus_lines' '0'
}

# --- 2. the contract cross-checks, read back --------------------------------
$contractsFile = Join-Path $work 'contracts.json'
Require (Test-Path -LiteralPath $contractsFile) `
    'build/cap10c2/contracts.json is absent -- run check_cap10c2_contracts.ps1 first'
if (Test-Path -LiteralPath $contractsFile) {
    $contracts = Get-Content $contractsFile -Raw | ConvertFrom-Json
    Require ("$($contracts.verdict)" -ceq 'PASS') `
        "the CAP-10C2 contract cross-checks report $($contracts.verdict)"
    # T2: MEASURED, never asserted - a directory listing and a byte scan
    Row 'release_dev_unit_absent' (Bool ($contracts.release_dev_unit_absent -eq $true))
    Row 'dev_marker_in_release' (Bool ($contracts.dev_marker_in_release_binary -eq $true))
    Row 'dev_marker_in_dev' (Bool ($contracts.dev_marker_in_dev_binary -eq $true))
    Row 'dev_units_linked' (Bool ($contracts.dev_units_linked -eq $true))
    Row 'pipeline_units_linked_c2' (Bool ($contracts.pipeline_units_linked -eq $true))
    Require ($contracts.release_dev_unit_absent -eq $true) `
        'T2: the release host links the development unit'
    Require ($contracts.dev_marker_in_release_binary -eq $false) `
        'T2: the release binary carries the development argument string'
    Require ($contracts.dev_marker_in_dev_binary -eq $true) `
        'T2: the development binary does NOT carry the development argument'
    Row 'dev_transport_hits' "$($contracts.transport_hits)"
    Require ("$($contracts.transport_hits)" -eq '0') `
        'T3: a transport allowance appears in this shard''s source'
    Row 'dev_conditionals' "$($contracts.dev_conditionals)"
    Row 'dev_env_reads' "$($contracts.dev_env_reads)"
}

# --- 3. T1: PWEB_NATIVE_CSP, byte-identical in BOTH binaries ---------------
# Extracted from each BINARY, not from the source: what has to be identical
# is what the two processes will send, and only the bytes can say that.
function ExtractCsp([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # the CSP is one ASCII run beginning with `default-src 'self'`; it is
    # found by its own opening bytes and read to the first NUL or non-ASCII
    $needle = [System.Text.Encoding]::ASCII.GetBytes("default-src 'self'")
    $limit = $bytes.Length - $needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $sb = New-Object System.Text.StringBuilder
        $k = $i
        while (($k -lt $bytes.Length) -and ($bytes[$k] -ge 0x20) -and
               ($bytes[$k] -le 0x7E)) {
            [void]$sb.Append([char]$bytes[$k])
            $k++
        }
        return $sb.ToString()
    }
    return ''
}
$relExe = @(Get-ChildItem (Join-Path $work 'probe/release-host') -File `
    -ErrorAction SilentlyContinue |
    Where-Object { ($_.Extension -eq '.exe') -or ($_.Extension -eq '') } |
    Select-Object -First 1)
$devExe = @(Get-ChildItem (Join-Path $work 'probe/dev-host') -File `
    -ErrorAction SilentlyContinue |
    Where-Object { ($_.Extension -eq '.exe') -or ($_.Extension -eq '') } |
    Select-Object -First 1)
if (($relExe.Count -eq 1) -and ($devExe.Count -eq 1)) {
    $cspRelease = ExtractCsp $relExe[0].FullName
    $cspDev = ExtractCsp $devExe[0].FullName
    Row 'csp_release' $cspRelease
    Row 'csp_identical' (Bool (($cspRelease -ne '') -and ($cspRelease -ceq $cspDev)))
    Require ($cspRelease -ne '') 'T1: no CSP could be read from the release binary'
    Require ($cspRelease -ceq $cspDev) `
        'T1: PWEB_NATIVE_CSP differs between the release and the development binary'
    $bad = @()
    foreach ($banned in 'ws:', 'wss:', 'localhost', '127.0.0.1', 'http:') {
        if ($cspRelease.Contains($banned)) { $bad += $banned }
    }
    # `none`, never the empty string. The aggregator requires every field it
    # carries to be NON-EMPTY - which is how a field a target silently failed
    # to emit is told apart from one it measured - so a row whose ratified
    # value is "nothing found" has to SAY nothing found, exactly as
    # `network_stages_pas2js` says `none`. An empty value here failed the
    # required-field check on all four targets at once.
    Row 'csp_transport_terms' $(if ($bad.Count -eq 0) { 'none' }
                                else { $bad -join ',' })
    Require ($bad.Count -eq 0) `
        "T1: the CSP carries $($bad -join ',')"
    # T5: the ONE origin, in both binaries
    Row 'dev_origin' 'pweb://app/'
} else {
    Row 'csp_identical' 'unmeasured'
    Require $false 'T1: the two host binaries are absent -- run build_cap10c2 first'
}

# --- 4. DEV9: the development binary refuses without its root ---------------
# WITH AN app.pwb BESIDE IT, which is the whole point: a dev binary that fell
# back to the production rule would load the wrong thing silently.
if ($devExe.Count -eq 1) {
    $probeDir = $devExe[0].DirectoryName
    $beside = Join-Path $probeDir 'app.pwb'
    if (-not (Test-Path -LiteralPath $beside)) {
        [System.IO.File]::WriteAllBytes($beside,
            [System.Text.Encoding]::ASCII.GetBytes('PK not-a-real-archive'))
    }
    $so = Join-Path $work 'dev9-stdout.txt'
    $se = Join-Path $work 'dev9-stderr.txt'
    $p = Start-Process -FilePath $devExe[0].FullName -Wait -PassThru `
        -NoNewWindow -WorkingDirectory $probeDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    $devErr = [System.IO.File]::ReadAllText($se)
    Row 'dev9_exit' "$($p.ExitCode)"
    Row 'dev9_refused' (Bool ($devErr.Contains('DEV REFUSED') -and
        $devErr.Contains('dev_root_absent')))
    Require ($p.ExitCode -ne 0) 'DEV9: the dev binary did not refuse'
    Require ($devErr.Contains('dev_root_absent')) `
        'DEV9: the refusal does not name dev_root_absent'
    # and it must NEVER have reached the bundle loader
    Require (-not $devErr.Contains('app.pwb REFUSED')) `
        'DEV9: the dev binary reached PWebHostLoadBundle and looked at the beside-exe bundle'
    Row 'dev9_never_loaded_beside_bundle' `
        (Bool (-not $devErr.Contains('app.pwb REFUSED')))
}

# --- 5. DEV12 / the public surface ------------------------------------------
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
        @{ Args = @('dev', '--verbose');                        Code = 2; Cause = 'option_not_for_command' },
        @{ Args = @('build');                                   Code = 2; Cause = 'unknown_command' })) {
    $r = RunCli $case.Args $cwd
    $ok = ($r.Code -eq $case.Code) -and ($r.Err.Contains($case.Cause))
    if (-not $ok) {
        $surface = $false
        Require $false ("DEV12: pweb $($case.Args -join ' ') answered " +
            "$($r.Code)/$($r.Err.Trim()) -- expected $($case.Code)/$($case.Cause)")
    }
}
$devHelp = RunCli @('dev', '--help') $cwd
Require ($devHelp.Code -eq 0) 'DEV12: dev --help did not exit 0'
Require ($devHelp.Out.Contains('react')) 'DEV12: dev --help does not advertise React'
Require ($devHelp.Out.Contains('pas2js')) 'DEV12: dev --help does not name the refusal'
Require (-not $devHelp.Out.Contains([char]27)) 'DEV12: dev --help emitted ANSI'
$mainHelp = RunCli @('--help') $cwd
Require ($mainHelp.Out.Contains('pweb dev ')) '--help does not advertise dev'
Require (-not $mainHelp.Out.Contains('pweb build')) '--help advertises build'
Row 'dev_option_matrix' $(if ($surface) { 'PASS' } else { 'FAIL' })
Row 'advertised_commands_c2' 'create,doctor,run,dev'
Row 'build_still_unknown' (Bool $surface)

# --- 5b. the two projects this gate drives, SCAFFOLDED BY THE REAL CLI ------
# NOT borrowed from another shard's stage. A development loop is a claim
# about what `pweb create` produces TODAY, and a stage another gate left
# behind is a stage built from whatever template that gate's own run
# carried - which is exactly how this gate first measured a frontend with
# no completion sentinel in it and blamed the loop.
$stage = Join-Path $work 'stage'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($ui in 'react', 'pas2js') {
    $r = RunCli @('create', 'demo', '--ui', $ui, '--bundle-id', 'com.example.demo') `
        (Join-Path $stage $ui | ForEach-Object {
            New-Item -ItemType Directory -Force $_ | Out-Null; $_ })
    Require ($r.Code -eq 0) `
        "scaffolding the $ui project failed: $($r.Code) $($r.Err.Trim())"
}
$react = Join-Path $stage 'react/demo'
$p2j = Join-Path $stage 'pas2js/demo'
Require (Test-Path -LiteralPath (Join-Path $react 'frontend/vite.config.ts')) `
    'the scaffolded React project has no vite.config.ts'
# the completion sentinel has to be IN the template this build produces, or
# the loop is waiting for something nothing writes
$viteConfig = [System.IO.File]::ReadAllText(
    (Join-Path $react 'frontend/vite.config.ts'))
Row 'dev_sentinel_in_template' (Bool ($viteConfig.Contains('pweb-dev-sentinel')))
Require ($viteConfig.Contains('pweb-dev-sentinel')) `
    'the generated vite.config.ts carries no pweb-dev-sentinel plugin'

# --- 6. DEV11: a pas2js project is refused, and NOTHING is written ----------
if (Test-Path -LiteralPath $p2j) {
    $before = @(Get-ChildItem -LiteralPath $p2j -Recurse -File -Force |
        ForEach-Object { "$($_.FullName)|$($_.Length)" }) -join "`n"
    $r = RunCli @('dev', '--project', $p2j) $cwd
    $after = @(Get-ChildItem -LiteralPath $p2j -Recurse -File -Force |
        ForEach-Object { "$($_.FullName)|$($_.Length)" }) -join "`n"
    Row 'dev11_exit' "$($r.Code)"
    Row 'dev11_cause' $(if ($r.Err.Contains('dev_ui_unsupported')) { 'dev_ui_unsupported' } else { 'other' })
    Row 'dev11_nothing_written' (Bool ($before -ceq $after))
    Require ($r.Code -eq 3) "DEV11: pweb dev on a pas2js project exited $($r.Code), expected 3"
    Require ($r.Err.Contains('dev_ui_unsupported')) `
        'DEV11: the refusal does not name dev_ui_unsupported'
    Require ($before -ceq $after) 'DEV11: the refused run wrote into the project'
} else {
    Row 'dev11_exit' 'unmeasured'
    Row 'dev11_cause' 'unmeasured'
    Row 'dev11_nothing_written' 'unmeasured'
    Require $false 'DEV11: the Pas2JS project was not scaffolded'
}

# --- 7. the REAL loop: DEV1, DEV2, DEV3, DEV4, DEV6, DEV10, DEV13, DEV14 ----
if (Test-Path -LiteralPath $react) {
    $devDir = Join-Path $react "dist/$target/dev"
    $releaseDir = Join-Path $react "dist/$target/release"
    # DEV10: the RELEASE tree, digested before and after a development
    # session. A development session must not touch it in any way.
    function TreeDigest([string]$Root) {
        if (-not (Test-Path -LiteralPath $Root)) { return '<absent>' }
        $lines = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            ForEach-Object {
                $rel = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
                "$rel $($_.Length) $(Sha256File $_.FullName)"
            })
        $sorted = [string[]]$lines
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $text = (($sorted -join "`n") + "`n")
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return -join ($sha.ComputeHash(
                [System.Text.UTF8Encoding]::new($false).GetBytes($text)) |
                ForEach-Object { $_.ToString('x2') })
        } finally { $sha.Dispose() }
    }
    # DEV10: a freshly scaffolded project has NO release directory, and
    # `<absent>` on both sides would be a claim about nothing - a session
    # that never looked cannot be distinguished from one that did not touch.
    # So a release tree is SEEDED here, with the shape and the names the
    # CAP-10C1 layout commits, and the claim becomes the one the matrix
    # states: a development session leaves that tree byte-identical. The
    # CONTENT is deliberately synthetic - the pipeline's own release is
    # measured by the CAP-10C1 gate on this same job, and rebuilding it here
    # would cost a second npm/tsc/vite/fpc pass to prove a property about
    # bytes nobody reads.
    New-Item -ItemType Directory -Force $releaseDir | Out-Null
    foreach ($seed in @('demo.exe', 'demo', 'app.pwb', 'webview.dll',
                        'libwebview.so.0.12', 'libwebview.dylib')) {
        $p = Join-Path $releaseDir $seed
        if (-not (Test-Path -LiteralPath $p)) {
            [System.IO.File]::WriteAllText($p,
                "CAP-10C2 DEV10 seed: a development session must not touch this`n",
                [System.Text.UTF8Encoding]::new($false))
        }
    }
    $releaseBefore = TreeDigest $releaseDir
    Row 'dev10_release_seeded' (Bool ($releaseBefore -cne '<absent>'))
    Require ($releaseBefore -cne '<absent>') `
        'DEV10: the release tree could not be seeded, so the leg proves nothing'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $devDir

    $report = Join-Path $work 'devdrv-report.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $report
    $drvArgs = @(
        '--pweb', $pweb,
        '--project', $react,
        '--source', (Join-Path $react 'frontend/src/App.tsx'),
        '--style', (Join-Path $react 'frontend/src/app.css'),
        '--report', $report,
        '--cwd', $cwd)
    if (Test-Path -LiteralPath $helper) { $drvArgs += @('--helper', $helper) }
    $drvOut = Join-Path $work 'devdrv-stdout.txt'
    $drvErr = Join-Path $work 'devdrv-stderr.txt'
    $p = Start-Process -FilePath $driver -ArgumentList $drvArgs -Wait -PassThru `
        -NoNewWindow -WorkingDirectory $cwd `
        -RedirectStandardOutput $drvOut -RedirectStandardError $drvErr
    Write-Host "[CAP-10C2] the driver exited $($p.ExitCode)"
    Require ($p.ExitCode -eq 0) "the CAP-10C2 driver exited $($p.ExitCode)"
    Require (Test-Path -LiteralPath $report) 'the driver wrote no report'
    if (Test-Path -LiteralPath $report) {
        $drv = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($report)) {
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) { $drv[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
        }
        foreach ($k in $drv.Keys) { Row $k $drv[$k] }
        foreach ($pin in @(
                @('dev1_generation_ready', 'true'), @('dev1_generation_loaded', 'true'),
                @('dev1_rpc_and_secure', 'true'),
                @('dev3_generation_ready', 'true'), @('dev3_generation_loaded', 'true'),
                @('dev3_styles_applied', 'true'),
                @('dev2_generation_ready', 'true'), @('dev2_generation_loaded', 'true'),
                @('dev2_rpc_and_secure', 'true'),
                @('dev2_host_pid_unchanged', 'true'),
                @('dev4_broken_published', 'false'), @('dev4_recovered', 'true'),
                @('dev5_burst_edits', '5'),
                @('dev5_burst_monotonic', 'true'),
                @('dev5_all_generations_loaded', 'true'),
                @('dev5_final_value', '47'),
                @('dev5_final_content_correct', 'true'),
                @('dev6_stop_requested', 'true'),
                @('dev6_pweb_outcome', 'exited'), @('dev6_pweb_exit', '0'),
                @('dev6_descendants_remaining', '0'))) {
            Require ("$($drv[$pin[0]])" -ceq $pin[1]) `
                "$($pin[0]) is '$($drv[$pin[0]])', expected '$($pin[1])'"
        }
    }

    # DEV6: no partial generation survives the stop
    $tmpLeft = Test-Path -LiteralPath (Join-Path $devDir '.gen.tmp')
    Row 'dev6_no_partial_generation' (Bool (-not $tmpLeft))
    Require (-not $tmpLeft) 'DEV6: a .gen.tmp survived the interrupt'

    # THE ROW CAP-10C1 COULD NOT WRITE. There, `interrupt_clean` was measured
    # on the three POSIX targets and recorded `not_measured` on Windows,
    # because a console control event needs the helper the CAP-10C0 suite
    # owns. This shard drives that helper, so the row is measured on ALL
    # FOUR - and it is one row rather than four, so a leg that half-held
    # cannot read as a pass.
    $interruptClean = (
        ("$($drv['dev6_interrupt_delivered'])" -ceq 'true') -and
        ("$($drv['dev6_pweb_outcome'])" -ceq 'exited') -and
        ("$($drv['dev6_pweb_exit'])" -ceq '0') -and
        ("$($drv['dev6_descendants_remaining'])" -ceq '0') -and
        (-not $tmpLeft))
    Row 'dev_interrupt_clean' (Bool $interruptClean)
    Row 'dev_interrupt_mechanism' $(
        if ($IsWindows) { 'console_ctrl_c_event' } else { 'sigint' })
    Require $interruptClean `
        'the interrupt was not clean: see the dev6_* rows for which half failed'

    # DEV5: the generations are MONOTONIC and each holds exactly one archive
    $gens = @(Get-ChildItem -LiteralPath $devDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^gen-\d+$' } |
        ForEach-Object { [int]($_.Name.Substring(4)) } | Sort-Object)
    Row 'dev5_generation_count' "$($gens.Count)"
    Row 'dev5_generations' ($gens -join ',')
    $monotonic = $true
    for ($i = 1; $i -lt $gens.Count; $i++) {
        if ($gens[$i] -le $gens[$i - 1]) { $monotonic = $false }
    }
    Row 'dev5_monotonic' (Bool $monotonic)
    Require $monotonic 'DEV5: the published generations are not monotonic'
    $onlyArchive = $true
    foreach ($g in $gens) {
        $gd = Join-Path $devDir "gen-$g"
        $files = @(Get-ChildItem -LiteralPath $gd -Recurse -File -Force |
            ForEach-Object { $_.Name })
        if (($files.Count -ne 1) -or ($files[0] -cne 'app.pwb')) {
            $onlyArchive = $false
        }
    }
    Row 'dev4_generation_holds_only_archive' (Bool $onlyArchive)
    Require $onlyArchive `
        'T4: a published generation holds something other than app.pwb'

    # T4: NO LOOSE ASSETS IN DEVELOPMENT EITHER. Two halves, and both have to
    # hold: every published generation is one frozen-bundler archive and
    # nothing else (above), and the directory the development binary runs
    # from carries the binary and the engine library and NO bundle - so there
    # is not even a beside-the-executable archive for a host to fall back to,
    # which is the other half of DEV9's claim stated as a layout.
    $appDir = Join-Path $devDir 'app'
    $appNames = @()
    if (Test-Path -LiteralPath $appDir) {
        $appNames = @(Get-ChildItem -LiteralPath $appDir -Recurse -File -Force |
            ForEach-Object { $_.Name })
    }
    $devBundleBeside = @($appNames | Where-Object { $_ -ceq 'app.pwb' }).Count -gt 0
    $frontendLoose = @($appNames | Where-Object {
        $_ -match '\.(html|css|js|mjs|tsx?|map|json)$' }).Count -gt 0
    Row 'dev_app_dir_names' (($appNames | Sort-Object) -join ',')
    Row 'dev_loose_assets_used' (Bool ($devBundleBeside -or $frontendLoose -or
        (-not $onlyArchive)))
    Require (-not ($devBundleBeside -or $frontendLoose)) `
        ("T4: the development run directory carries a loose asset or a " +
         "beside-the-executable bundle: $($appNames -join ', ')")

    # DEV10: the release tree, untouched
    $releaseAfter = TreeDigest $releaseDir
    Row 'dev10_release_digest' $releaseBefore
    Row 'dev10_release_unchanged' (Bool ($releaseBefore -ceq $releaseAfter))
    Require ($releaseBefore -ceq $releaseAfter) `
        'DEV10: the release tree changed across a development session'

    # DEV13: no ANSI on either stream, and EXACTLY ONE `generation N ready`
    # line per published generation
    $errText = [System.IO.File]::ReadAllText($drvErr)
    $lines = @()
    if (Test-Path -LiteralPath "$report.lines") {
        $lines = [System.IO.File]::ReadAllLines("$report.lines")
    }
    $supervisorLines = @($lines | Where-Object { $_ -match '^E\| pweb: ' })
    $readyLines = @($supervisorLines | Where-Object {
        $_ -match 'pweb: generation \d+ ready \(\d+ ms\)$' })
    # EXACTLY ONE LINE PER GENERATION, and the sequence has no gap and no
    # repeat. Comparing the line count with the number of DIRECTORIES was
    # wrong by construction and only looked right while a session published
    # no more than PWEB_CLI_DEV_KEEP_GENERATIONS: the bounded cleanup removes
    # generations behind the keep window, so the directories on disk are a
    # SUFFIX of the announced sequence and never the whole of it. MEASURED on
    # linux-x86_64: four announced, three on disk, and a gate that called
    # that a defect.
    $announced = @($readyLines | ForEach-Object {
        if ($_ -match 'pweb: generation (\d+) ready \(') { [int]$Matches[1] } })
    $maxGen = 0
    if ($announced.Count -gt 0) {
        $maxGen = ($announced | Measure-Object -Maximum).Maximum
    }
    $exact = ($announced.Count -eq $maxGen) -and
             (@($announced | Sort-Object -Unique).Count -eq $maxGen) -and
             ($maxGen -gt 0)
    Row 'dev13_generation_lines' "$($readyLines.Count)"
    Row 'dev13_generations_announced' ($announced -join ',')
    Row 'dev13_exact_one_line_per_generation' (Bool $exact)
    Require $exact `
        ("DEV13: the announced generations are not 1..N exactly once: " +
         "$($announced -join ',')")
    # and what survived on disk is a suffix of it, inside the keep window
    $keep = 3
    $survivors = @($gens | Sort-Object)
    $suffixOk = ($survivors.Count -le ($keep + 1)) -and
                (($survivors.Count -eq 0) -or
                 ($survivors[-1] -eq $maxGen))
    Row 'dev13_survivors_are_a_suffix' (Bool $suffixOk)
    Require $suffixOk `
        ("DEV13: the surviving generations $($survivors -join ',') are not " +
         "the newest $keep..$($keep + 1) of 1..$maxGen")
    $ansi = ($supervisorLines -join "`n").Contains([char]27)
    Row 'dev13_no_ansi' (Bool (-not $ansi))
    Require (-not $ansi) 'DEV13: the supervisor emitted ANSI'
    # nor may a supervisor line name an absolute path
    $absolute = @($supervisorLines | Where-Object {
        ($_ -match ':[\\/]') -or ($_ -match '^E\| pweb: /') })
    Row 'dev13_no_absolute_path' (Bool ($absolute.Count -eq 0))
    Require ($absolute.Count -eq 0) `
        "DEV13: a supervisor line names an absolute path: $($absolute | Select-Object -First 1)"

    # DEV14: the FIRST run installs (a freshly scaffolded project has no
    # node_modules), writes the record, and a SECOND decision over the same
    # tree must come out `skipped`. The decision is taken by the very
    # function the loop takes it with, so what is measured is the rule and
    # not a second implementation of it.
    $installLine = @($supervisorLines | Where-Object { $_ -match 'install: ' })
    Row 'dev14_first_install_line' `
        (($installLine | Select-Object -First 1) -replace '^E\| ', '')
    $record = Join-Path $react 'frontend/.pweb/dev/install-lock.sha256'
    Row 'dev14_install_record_written' (Bool (Test-Path -LiteralPath $record))
    Require (Test-Path -LiteralPath $record) `
        'DEV14: the install record was not written after a successful install'
    Row 'network_stages_dev' $(
        if (($installLine -join '') -match 'skipped') { 'none' } else { 'npm_ci' })
    # the second decision: `pweb dev` again on the same project, stopped at
    # once. Its install line must read `skipped`, and its `network_stages`
    # is therefore `none` - which is the DEV14 claim.
    $so2 = Join-Path $work 'dev14-stdout.txt'
    $se2 = Join-Path $work 'dev14-stderr.txt'
    $p2 = Start-Process -FilePath $pweb `
        -ArgumentList @('dev', '--project', $react) -PassThru `
        -NoNewWindow -WorkingDirectory $cwd `
        -RedirectStandardOutput $so2 -RedirectStandardError $se2
    $deadline = (Get-Date).AddSeconds(240)
    $seen = ''
    while (((Get-Date) -lt $deadline) -and (-not $p2.HasExited)) {
        Start-Sleep -Milliseconds 500
        $seen = ReadLive $se2
        if ($seen -match 'install: (skipped|start)') { break }
    }
    # --- the LIVE set: no member of it may hold a listening socket ---------
    # This run is already up, so it is the one that gets sampled rather than
    # a fourth `pweb dev` started to be looked at. BOTH members are sampled
    # by the pid the loop prints for each: on POSIX the CAP-10C0 engine put
    # each child at the head of its OWN process group, so `pgid == pid` is
    # exact for the host AND for the watcher; on Windows each is the root of
    # its own descendant closure. `pweb` itself is outside the sample and is
    # covered by the source proofs (dev_transport_hits, dev_env_reads) and
    # by the CAP-10C0 gates that measure the supervisor.
    $liveDeadline = (Get-Date).AddSeconds(300)
    while (((Get-Date) -lt $liveDeadline) -and (-not $p2.HasExited)) {
        $seen = ReadLive $se2
        if (($seen -match '(?m)^pweb: generation 1 ready') -and
            ($seen -match '(?m)^pweb: started pid \d+') -and
            ($seen -match '(?m)^pweb: watch: started pid \d+')) { break }
        Start-Sleep -Milliseconds 500
    }
    $livePids = @()
    foreach ($rx in '(?m)^pweb: started pid (\d+)',
                    '(?m)^pweb: watch: started pid (\d+)') {
        if ($seen -match $rx) { $livePids += [int]$Matches[1] }
    }
    $listenMax = 0
    $membersSeen = 0
    $passes = 0
    while (($passes -lt 8) -and (-not $p2.HasExited) -and
           ($livePids.Count -gt 0)) {
        $passes++
        $pass = 0
        foreach ($rootPid in $livePids) {
            $members = @(Get-PWebTreeMembers -RootPid $rootPid)
            $pass += $members.Count
            # every member, not the root alone: the CAP-10C1 upgrade exists
            # because a browser helper that opened a socket was outside a
            # per-pid count
            foreach ($m in $members) {
                $n = Get-PWebListenerCount -OwnerPid $m
                if ($n -gt $listenMax) { $listenMax = $n }
            }
        }
        if ($pass -gt $membersSeen) { $membersSeen = $pass }
        Start-Sleep -Milliseconds 400
    }
    Row 'dev_listener_sampler_scope' (Get-PWebSamplerScope)
    Row 'dev_listener_members_seen' "$membersSeen"
    Row 'dev_listener_members_max' "$listenMax"
    # a sampler that never sampled reports a clean zero for any host, so the
    # count of members it SAW is required as well as the count of listeners
    Require ($membersSeen -gt 0) `
        'the listener sampler saw no member at all, so its zero says nothing'
    Require ($listenMax -eq 0) `
        "a member of the live development set held $listenMax listening socket(s)"
    if (-not $p2.HasExited) { $p2.Kill($true) }
    $p2.WaitForExit(30000) | Out-Null
    Row 'dev14_second_install_line' $(
        if ($seen -match '(?m)^pweb: (install: .*)$') { $Matches[1] } else { 'unmeasured' })
    Row 'dev14_second_run_skipped_install' (Bool ($seen -match 'install: skipped'))
    Require ($seen -match 'install: skipped') `
        ('DEV14: a second run with node_modules present and the lockfile ' +
         'unchanged ran npm ci again')

    # --- 7b. DEV7 and DEV8: one member ended from OUTSIDE the loop ----------
    # Each is its own supervised run, because each has a DIFFERENT ending and
    # a run has exactly one. The member is ended with TerminateProcess /
    # SIGKILL - never through the supervisor's ladder, which is the graceful
    # path DEV6 already measures - so the loop meets a member that died
    # rather than one it asked to stop.
    foreach ($kill in @(
            @{ scenario = 'killhost';    prefix = 'dev7' },
            @{ scenario = 'killwatcher'; prefix = 'dev8' })) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $devDir
        $kreport = Join-Path $work "devdrv-$($kill.scenario).txt"
        Remove-Item -Force -ErrorAction SilentlyContinue $kreport
        $kargs = @(
            '--pweb', $pweb,
            '--project', $react,
            '--source', (Join-Path $react 'frontend/src/App.tsx'),
            '--style', (Join-Path $react 'frontend/src/app.css'),
            '--scenario', $kill.scenario,
            '--report', $kreport,
            '--cwd', $cwd)
        if (Test-Path -LiteralPath $helper) { $kargs += @('--helper', $helper) }
        $ko = Join-Path $work "devdrv-$($kill.scenario)-stdout.txt"
        $ke = Join-Path $work "devdrv-$($kill.scenario)-stderr.txt"
        $kp = Start-Process -FilePath $driver -ArgumentList $kargs -Wait -PassThru `
            -NoNewWindow -WorkingDirectory $cwd `
            -RedirectStandardOutput $ko -RedirectStandardError $ke
        Write-Host "[CAP-10C2] the $($kill.scenario) driver exited $($kp.ExitCode)"
        Require ($kp.ExitCode -eq 0) `
            "the $($kill.scenario) driver exited $($kp.ExitCode)"
        if (Test-Path -LiteralPath $kreport) {
            $kd = @{}
            foreach ($line in [System.IO.File]::ReadAllLines($kreport)) {
                $eq = $line.IndexOf('=')
                if ($eq -gt 0) { $kd[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
            }
            Row "$($kill.prefix)_set_was_up"   "$($kd['kill_set_was_up'])"
            Row "$($kill.prefix)_kill_delivered" "$($kd['kill_delivered'])"
            Row "$($kill.prefix)_pweb_outcome" "$($kd['kill_pweb_outcome'])"
            Row "$($kill.prefix)_pweb_exit"    "$($kd['kill_pweb_exit'])"
            Row "$($kill.prefix)_descendants_remaining" `
                "$($kd['kill_descendants_remaining'])"
            Row "$($kill.prefix)_kill_to_exit_ms" "$($kd['kill_to_exit_ms'])"
            foreach ($pin in @(
                    @("kill_set_was_up", 'true'),
                    @("kill_delivered", 'true'),
                    @("kill_pweb_outcome", 'exited'),
                    @("kill_pweb_exit", '5'),
                    @("kill_descendants_remaining", '0'))) {
                Require ("$($kd[$pin[0]])" -ceq $pin[1]) `
                    ("$($kill.prefix): $($pin[0]) is '$($kd[$pin[0]])', " +
                     "expected '$($pin[1])'")
            }
            # the OTHER member has to be gone too: a loop that lost one
            # member and left the other running is the failure these two
            # legs exist to catch, and the drain's own count is the proof
        } else {
            Row "$($kill.prefix)_pweb_exit" 'unmeasured'
            Require $false "$($kill.prefix): the driver wrote no report"
        }
        # neither ending may leave a half-built generation behind
        $ktmp = Test-Path -LiteralPath (Join-Path $devDir '.gen.tmp')
        Row "$($kill.prefix)_no_partial_generation" (Bool (-not $ktmp))
        Require (-not $ktmp) `
            "$($kill.prefix): a .gen.tmp survived the member's death"
    }
}

# --- 8. the frozen digests this shard must not have moved -------------------
$c1File = Join-Path $repoRoot "build/cap10c1/cli-$target.json"
if (Test-Path -LiteralPath $c1File) {
    $c1 = Get-Content $c1File -Raw | ConvertFrom-Json
    $pipeClosure = 'f890424a5ef95646b9a48355819e32f49e608c7f5ecc4e69766b4182978e839a'
    Row 'c1_pipeline_digest_unchanged' (Bool ("$($c1.pipeline_digest)" -ceq $pipeClosure))
    Require ("$($c1.pipeline_digest)" -ceq $pipeClosure) `
        ("pipeline_digest moved to $($c1.pipeline_digest); CAP-10C1 closed on " +
         "$pipeClosure -- PWebCliFpcCommand must not move")
    Row 'c1_app_pwb_react_unchanged' "$($c1.c1_app_pwb_react_semantic_digest)"
} else {
    Row 'c1_pipeline_digest_unchanged' 'unmeasured'
    Require $false 'the CAP-10C1 record is absent -- its gates have not run here'
}

# --- verdict and evidence ---------------------------------------------------
Row 'dev_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($rows | ConvertTo-Json -Depth 6)
if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10C2 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10C2] development-loop gates PASS on $target"
