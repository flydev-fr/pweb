# CAP-10C1: drive the PRIVATE lifecycle pipeline on the two real generated
# projects, prove byte parity with the CAP-10B1/B2 harnesses, run what it
# assembled, and emit this target's evidence.
#
# ONE script for all four targets, as every CAP-10 gate is. It needs what the
# CAP-10B1 and CAP-10B2 gates left behind - the two generated projects and
# the two app.pwb archives their proofs produced - and it rebuilds them from
# the SAME sources through the pipeline instead. THE PARITY IS THE POINT: if
# the pipeline's archive differs from the harness's by one byte, the pipeline
# is not doing what the harness did.
#
# WHAT IT PROVES:
#
#   TC1-TC4  the toolchain: npm through node and never npm.cmd, a version
#            that misses its pin refused BEFORE any write, a project-local
#            tool reported and never EXECUTED (proven by a fixture that
#            would leave a marker if it ran), and a doctor refusal adopted
#            with the doctor's own cause;
#   ST1-ST14 the stages: SDK staging byte-identical to tools/stage-ts-sdk.mjs,
#            a stale staging removed rather than merged, npm ci from the
#            committed lockfile with @pweb/runtime a LINK, tsc and a seeded
#            type error, determinism across two runs, app.pwb byte parity,
#            the native compile, `pweb run` on the assembled layout, no
#            release directory after a failure or an interrupt, the project
#            tree unchanged, and the SDK root unwritten;
#   DB1-DB3  the closed debts: the host's lines arriving LIVE, the template
#            supersession recorded, and the membership-scoped sampler;
#   SF1-SF3  the public surface: help unchanged, dev and build still unknown.
#
# Emits build/cap10c1/cli-<target>.json.
#
# Usage: pwsh test/cap10c1/run_cap10c1_gates.ps1   (POSIX: under a display)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot
. (Join-Path $PSScriptRoot 'listener_members.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
$pipe = Join-Path $sdk "bin/pwebpipe$exeSuffix"
$suite = Join-Path $repoRoot "build/cap10c1/bin/c1tests$exeSuffix"
$fakeDir = Join-Path $repoRoot 'build/cap10c1/fake'
foreach ($pre in $pweb, $pipe, $suite,
                 (Join-Path $fakeDir "fpc$exeSuffix"),
                 (Join-Path $repoRoot 'build/cap10b1/project/demo/pweb.json'),
                 (Join-Path $repoRoot 'build/cap10b2/project/demo/pweb.json'),
                 (Join-Path $repoRoot 'build/cap10b1/stage/app.pwb'),
                 (Join-Path $repoRoot 'build/cap10b2/stage/app.pwb')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw "missing precondition: $pre -- run the build scripts and the B1/B2 proofs first"
    }
}

if ($IsWindows) { $target = 'windows-x86_64' }
elseif ($IsLinux) { $target = 'linux-x86_64' }
elseif ($IsMacOS) {
    $target = if ((uname -m).Trim() -eq 'arm64') { 'macos-arm64' }
              else { 'macos-x86_64' }
} else { throw 'unsupported host' }
Write-Host "[CAP-10C1] target: $target"

# THE PINNED Pas2JS IS PUT ON PATH BY THIS GATE, deliberately and visibly,
# exactly as the CAP-10B2 gate does it and for the same reason: the pipeline
# resolves tools on PATH by ratified design, and every CI job fetches the
# pinned compiler into deps/ without putting it there.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
    Write-Host "[CAP-10C1] pinned pas2js on PATH: $($pinnedPas2js -join ', ')"
}

$work = Join-Path $repoRoot 'build/cap10c1'
New-Item -ItemType Directory -Force $work | Out-Null
$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Name, $Value) { $rows[$Name] = $Value }
function Require([bool]$Ok, [string]$What) {
    if (-not $Ok) { $failures.Add($What); Write-Host "GATE FAILURE: $What" }
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
# plain .NET, never Get-FileHash: on Unix pwsh treats a dot file as HIDDEN
# and refuses it without -Force (MEASURED on CAP-10C0's run 33621204892)
function Sha256Bytes([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
# ORDINAL, never Sort-Object: a culture-aware sort differs between runners
function SortOrdinal([string[]]$Items) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($i in @($Items)) { $list.Add($i) }
    $list.Sort([System.StringComparer]::Ordinal)
    return $list.ToArray()
}
function TreeDigest([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return 'absent' }
    $parts = New-Object System.Collections.Generic.List[string]
    $files = SortOrdinal @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object { $_.FullName })
    foreach ($f in $files) {
        $rel = $f.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
        $parts.Add("$rel|$([System.IO.FileInfo]::new($f).Length)|$(Sha256Bytes $f)")
    }
    return Sha256Text ($parts -join "`n")
}
# the driver's key=value record, read back as a hashtable
function ReadReport([string]$Path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $map[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
    }
    return $map
}

$pipeSeq = 0
function RunPipe([string]$Project, [string]$Tag, [int]$TimeoutMs = 1800000,
                 [string]$ExtraPath = '') {
    $script:pipeSeq++
    $so = Join-Path $work "pipe-$Tag-stdout.txt"
    $se = Join-Path $work "pipe-$Tag-stderr.txt"
    $report = Join-Path $work "report-$Tag.txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se, $report
    $savedPath = $env:PATH
    if ($ExtraPath -ne '') {
        $env:PATH = $ExtraPath + [System.IO.Path]::PathSeparator + $env:PATH
    }
    try {
        $p = Start-Process -FilePath $pipe -PassThru -NoNewWindow `
            -ArgumentList @('--project', $Project, '--report', $report) `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $so -RedirectStandardError $se
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            $p.WaitForExit(10000) | Out-Null
            Require $false "$Tag`: the pipeline did not finish inside ${TimeoutMs}ms and was killed"
        }
        $p.WaitForExit()
    }
    finally { $env:PATH = $savedPath }
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
        Err = if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' }
        Report = ReadReport $report
        ReportPath = $report
    }
}

# --- 0. the two projects, staged out of the B1/B2 gates ---------------------
function StageProject([string]$Tag, [string]$Source) {
    $stage = Join-Path $work "stage/$Tag"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item -Recurse -LiteralPath (Join-Path $repoRoot "build/$Source/project/demo") `
        -Destination (Join-Path $stage 'demo')
    return (Join-Path $stage 'demo')
}
$reactProject = StageProject 'react' 'cap10b1'
$pas2jsProject = StageProject 'pas2js' 'cap10b2'
$sdkBefore = TreeDigest $sdk

# --- 1. the headless suite --------------------------------------------------
$suiteLog = Join-Path $work 'c1tests.log'
& $suite /noenter 2>&1 | Tee-Object -FilePath $suiteLog | Out-Null
$suiteCode = $LASTEXITCODE
Require ($suiteCode -eq 0) "the CAP-10C1 suite FAILED (exit $suiteCode)"
$corpusFile = Join-Path $work 'pipeline-corpus.txt'
Require (Test-Path -LiteralPath $corpusFile) 'the suite emitted no decision corpus'
if (Test-Path -LiteralPath $corpusFile) {
    $corpusText = ([System.IO.File]::ReadAllText($corpusFile)).Replace("`r`n", "`n")
    $corpusLines = @($corpusText -split "`n" | Where-Object {
        ($_ -ne '') -and (-not $_.StartsWith('#')) })
    Row 'pipeline_digest' (Sha256Text $corpusText)
    Row 'pipeline_corpus_lines' $corpusLines.Count
} else {
    Row 'pipeline_digest' ''
    Row 'pipeline_corpus_lines' 0
}
Row 'pipeline_available' 'true'
Row 'pipeline_suite' $(if ($suiteCode -eq 0) { 'PASS' } else { 'FAIL' })

# --- 2. the two real pipelines ---------------------------------------------
$react = RunPipe $reactProject 'react'
Write-Host "----- react driver -----"; Write-Host $react.Err
Require ($react.Code -eq 0) "react: the pipeline exited $($react.Code)"
$pas2js = RunPipe $pas2jsProject 'pas2js'
Write-Host "----- pas2js driver -----"; Write-Host $pas2js.Err
Require ($pas2js.Code -eq 0) "pas2js: the pipeline exited $($pas2js.Code)"

foreach ($pair in @(@('react', $react), @('pas2js', $pas2js))) {
    $tag = $pair[0]; $r = $pair[1]
    Require ("$($r.Report['pipeline_result'])" -ceq 'ok') `
        "$tag`: pipeline_result is $($r.Report['pipeline_result'])"
    Require ("$($r.Report['project_tree_unchanged'])" -ceq 'true') `
        "$tag`: the pipeline MUTATED the project outside its ratified set"
    # ST12 half: the driver's own lines carry no absolute path, no home
    # directory and no ANSI
    $own = @($r.Err -split "`n" | Where-Object { $_.StartsWith('pweb: ') })
    Require ($own.Count -gt 0) "$tag`: the driver wrote no lines of its own"
    foreach ($line in $own) {
        Require (-not ($line -match '[A-Za-z]:\\|/home/|/Users/')) `
            "$tag`: an absolute path leaked into a driver line: $line"
        Require (-not $line.Contains([char]27)) `
            "$tag`: ANSI in a driver line: $line"
    }
}
Row 'project_tree_unchanged' $(
    if (("$($react.Report['project_tree_unchanged'])" -ceq 'true') -and
        ("$($pas2js.Report['project_tree_unchanged'])" -ceq 'true')) { 'true' }
    else { 'false' })
Row 'driver_no_ansi' 'true'

# TC1: npm through node, and npm.cmd nowhere
Row 'npm_invocation' "$($react.Report['npm_invocation'])"
Require ("$($react.Report['npm_invocation'])" -ceq 'node_npm_cli') `
    "TC1: npm_invocation is $($react.Report['npm_invocation'])"
Require ("$($react.Report['cmd.install'])" -match '^<node> <npm-cli> ci ') `
    "TC1: the install command is $($react.Report['cmd.install'])"
$allCommands = @()
foreach ($r in @($react, $pas2js)) {
    foreach ($k in $r.Report.Keys) {
        if ($k.StartsWith('cmd.')) { $allCommands += "$($r.Report[$k])" }
    }
}
foreach ($c in $allCommands) {
    Require (-not ($c -match '\.cmd(\s|$)|\.bat(\s|$)')) `
        "TC1: a batch file reached a command vector: $c"
}
Row 'lifecycle_script_policy' "$($react.Report['lifecycle_script_policy'])"
Require ("$($react.Report['cmd.install'])".Contains('--ignore-scripts')) `
    'ST14: the install command does not carry --ignore-scripts'
Row 'network_stages' "$($react.Report['network_stages'])"
Row 'network_stages_pas2js' "$($pas2js.Report['network_stages'])"
Require ("$($pas2js.Report['network_stages'])" -ceq '') `
    'ST13: a Pas2JS pipeline declared a network stage'
Row 'npm_cli_path' "$($react.Report['npm_cli_path'])"
Row 'npm_version' "$($react.Report['npm_version'])"
Row 'node_version' "$($react.Report['node_version'])"
Row 'fpc_version' "$($react.Report['fpc_version'])"
Row 'fpc_target' "$($react.Report['pipeline_fpc_target'])"
Row 'pas2js_version' "$($pas2js.Report['pas2js_version'])"
Row 'pas2js_normalised' (
    "bom=$($pas2js.Report['pas2js_had_bom']) cr=$($pas2js.Report['pas2js_had_cr'])")

# ST14 basis: the policy is ratified against a MEASUREMENT of the pinned tree
$lockText = [System.IO.File]::ReadAllText(
    (Join-Path $reactProject 'frontend/package-lock.json'))
$installScripts = @([regex]::Matches($lockText, '"hasInstallScript"\s*:\s*true')).Count
Row 'lockfile_install_scripts' $installScripts
Require ($installScripts -le 1) `
    ("ST14: the pinned tree now carries $installScripts install script(s); " +
     'the --ignore-scripts ratification was measured against exactly one')

# --- 3. ST1/ST2: the staged SDK ---------------------------------------------
$stagedSdk = Join-Path $reactProject 'frontend/.pweb/sdk/typescript'
$scriptOut = Join-Path $work 'stage-reference'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scriptOut
& node tools/stage-ts-sdk.mjs (Join-Path $sdk 'share/pweb/sdk/typescript') $scriptOut |
    Out-Null
Require ($LASTEXITCODE -eq 0) 'ST1: the reference staging script failed'
$parity = (TreeDigest $stagedSdk) -ceq (TreeDigest $scriptOut)
Row 'sdk_stage_parity' (Bool $parity)
Require $parity `
    'ST1: the Pascal SDK staging is not byte-identical to tools/stage-ts-sdk.mjs'

# ST2: a stale file does not survive a re-stage
$stale = Join-Path $stagedSdk 'STALE.d.ts'
[System.IO.File]::WriteAllText($stale, "export declare const gone: 1;`n")
$reactAgain = RunPipe $reactProject 'react2'
Require ($reactAgain.Code -eq 0) "ST2: the second react pipeline exited $($reactAgain.Code)"
Row 'sdk_stage_stale_removed' (Bool (-not (Test-Path -LiteralPath $stale)))
Require (-not (Test-Path -LiteralPath $stale)) `
    'ST2: a stale file survived the SDK staging - the destination was MERGED'

# ST3: @pweb/runtime is a LINK to the staged SDK, never a fetched package
$linked = Join-Path $reactProject 'frontend/node_modules/@pweb/runtime'
Require (Test-Path -LiteralPath $linked) 'ST3: npm did not provide @pweb/runtime'
function CanonicalDir([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
}
$actualTarget = ''
if (Test-Path -LiteralPath $linked) {
    # npm makes a JUNCTION on Windows and a symlink on POSIX, and
    # Resolve-Path does not follow a junction - the reparse TARGET is what
    # this question is actually about
    $item = Get-Item -LiteralPath $linked -Force
    if ($item.ResolvedTarget) { $actualTarget = CanonicalDir $item.ResolvedTarget }
    elseif ($item.Target) { $actualTarget = CanonicalDir $item.Target }
    else { $actualTarget = CanonicalDir $linked }
}
$linkOk = $actualTarget -ceq (CanonicalDir $stagedSdk)
Row 'runtime_from_sdk_root' (Bool $linkOk)
Require $linkOk `
    "ST3: @pweb/runtime resolved to '$actualTarget', expected the staged SDK"

# --- 4. ST5/ST6: determinism, and the parity that is this shard's point -----
$appPwb = @{
    react = Join-Path $reactProject "dist/$target/app.pwb"
    pas2js = Join-Path $pas2jsProject "dist/$target/app.pwb"
}
$harness = @{
    react = Join-Path $repoRoot 'build/cap10b1/stage/app.pwb'
    pas2js = Join-Path $repoRoot 'build/cap10b2/stage/app.pwb'
}
foreach ($ui in 'react', 'pas2js') {
    Require (Test-Path -LiteralPath $appPwb[$ui]) "ST6: $ui produced no app.pwb"
    if ((Test-Path -LiteralPath $appPwb[$ui]) -and
        (Test-Path -LiteralPath $harness[$ui])) {
        $mine = Sha256Bytes $appPwb[$ui]
        $theirs = Sha256Bytes $harness[$ui]
        Row "app_pwb_${ui}_sha256" $mine
        Row "app_pwb_${ui}_parity" (Bool ($mine -ceq $theirs))
        Require ($mine -ceq $theirs) `
            ("ST6: the $ui app.pwb differs from the CAP-10B$(if ($ui -eq 'react') { '1' } else { '2' }) " +
             "harness's: $mine vs $theirs")
        # the SEMANTIC inventory, which four targets CAN agree on. The raw
        # archive cannot: mORMot stamps the creating OS into the ZIP
        # `version made by` byte (MEASURED, run 33093385300) and the static
        # DEFLATE object emits different bytes per toolchain
        $zipRows = New-Object System.Collections.Generic.List[string]
        $zip = [System.IO.Compression.ZipFile]::OpenRead($appPwb[$ui])
        try {
            $names = SortOrdinal @($zip.Entries |
                Where-Object { -not $_.FullName.EndsWith('/') } |
                ForEach-Object { $_.FullName })
            foreach ($name in $names) {
                $entry = $zip.GetEntry($name)
                $ms = [System.IO.MemoryStream]::new()
                $s = $entry.Open()
                try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $bytes = $ms.ToArray(); $ms.Dispose()
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $hex = -join ($sha.ComputeHash($bytes) |
                        ForEach-Object { $_.ToString('x2') })
                } finally { $sha.Dispose() }
                $zipRows.Add("entry=$name size=$($bytes.Length) sha256=$hex")
            }
        } finally { $zip.Dispose() }
        Row "app_pwb_${ui}_semantic_digest" (Sha256Text (($zipRows -join "`n") + "`n"))
        Row "app_pwb_${ui}_entries" $zipRows.Count
    }
}
# ST5: two runs of the same project produce the same archive
$reactTwice = (Sha256Bytes $appPwb['react'])
Row 'build_deterministic' (Bool ($reactTwice -ceq $rows['app_pwb_react_sha256']))
Require ($reactTwice -ceq $rows['app_pwb_react_sha256']) `
    'ST5: two runs of the react pipeline produced different app.pwb bytes'

Row 'native_compile_react' $(
    if ("$($react.Report['stage.compile'])" -match '\|true\|') { 'PASS' } else { 'FAIL' })
Row 'native_compile_pas2js' $(
    if ("$($pas2js.Report['stage.compile'])" -match '\|true\|') { 'PASS' } else { 'FAIL' })
Row 'fpc_command' "$($react.Report['cmd.compile'])"
Require ("$($react.Report['cmd.compile'])".Contains('<sdk>/share/pweb/deps/mormot2/src')) `
    'ST7: the native compile does not name the SDK root''s mORMot'
Require (-not ("$($react.Report['cmd.compile'])".Contains('deps/mormot2/static/delphi'))) `
    'ST7: the compile names a static directory it should reach relatively'

# --- 5. ST8 / DB1 / DB3: run what the pipeline assembled --------------------
function RunApplication([string]$Project, [string]$Tag) {
    $so = Join-Path $work "run-$Tag-stdout.txt"
    $se = Join-Path $work "run-$Tag-stderr.txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '20000'
    $runCwd = Join-Path $work 'unrelated-cwd'
    New-Item -ItemType Directory -Force $runCwd | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $pweb -PassThru -NoNewWindow `
        -ArgumentList @('run', '--project', $Project) `
        -WorkingDirectory $runCwd -RedirectStandardOutput $so -RedirectStandardError $se
    $appPid = 0
    $membersSeen = 0
    $listenerMax = 0
    $connMax = 0
    $sampled = 0
    $readyWhileAlive = $false
    while (-not $p.HasExited -and ($sw.ElapsedMilliseconds -lt 90000)) {
        Start-Sleep -Milliseconds 400
        if ($appPid -eq 0 -and (Test-Path -LiteralPath $se)) {
            foreach ($line in (Get-Content -LiteralPath $se -ErrorAction SilentlyContinue)) {
                if ($line -match '^pweb: started pid (\d+)') { $appPid = [int]$Matches[1] }
            }
        }
        # DB1: the host's report has to arrive WHILE the host is alive. Before
        # CAP-10C1 it could not on Linux and macOS - FPC block-buffers a pipe -
        # and a dev loop waiting for it would have waited for the process it
        # was supervising to die
        if (-not $readyWhileAlive -and (Test-Path -LiteralPath $so)) {
            try {
                if ((Get-Content -LiteralPath $so -Raw -ErrorAction SilentlyContinue) -match 'demo: ready \{') {
                    $readyWhileAlive = $true
                }
            } catch { }
        }
        if ($appPid -gt 0) {
            $members = @(Get-PWebTreeMembers -RootPid $appPid)
            if ($members.Count -gt $membersSeen) { $membersSeen = $members.Count }
            $sampled++
            foreach ($m in $members) {
                $n = Get-PWebListenerCount -OwnerPid $m
                if ($n -gt $listenerMax) { $listenerMax = $n }
                $c = Get-PWebConnectionCount -OwnerPid $m
                if ($c -gt $connMax) { $connMax = $c }
            }
        }
    }
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
        $p.WaitForExit(10000) | Out-Null
        Require $false "$Tag`: pweb run did not exit inside 90 s -- a HUNG RUN"
    }
    $p.WaitForExit()
    Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
    $out = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
    $err = if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    Write-Host "----- $Tag run -----"; Write-Host $out; Write-Host $err
    $value = -1
    foreach ($line in ($out -split "`n")) {
        if ($line -match 'demo: ready (\{.*\})\s*$') {
            $value = ($Matches[1] | ConvertFrom-Json).value
        }
    }
    return [pscustomobject]@{
        Code = $p.ExitCode; Rpc = $value; Listeners = $listenerMax
        Connections = $connMax; Members = $membersSeen; Sampled = $sampled
        ReadyLive = $readyWhileAlive; Out = $out; Err = $err
    }
}
$runReact = RunApplication $reactProject 'react'
$runPas2js = RunApplication $pas2jsProject 'pas2js'
foreach ($pair in @(@('react', $runReact), @('pas2js', $runPas2js))) {
    $tag = $pair[0]; $r = $pair[1]
    Require ($r.Code -eq 0) "ST8 $tag`: pweb run exited $($r.Code)"
    Require ($r.Rpc -eq 42) "ST8 $tag`: CalculatorService.Add returned $($r.Rpc)"
    Require ($r.Sampled -gt 0) `
        "DB3 $tag`: the membership sampler never ran: the counts would be a vacuous 0"
    Require ($r.Members -gt 0) "DB3 $tag`: the sampler saw no tree member at all"
    Require ($r.Listeners -eq 0) "ST8 $tag`: a tree member opened $($r.Listeners) listener(s)"
    Require ($r.ReadyLive) `
        "DB1 $tag`: the host's ready report did not arrive while the host was alive"
}
Row 'run_rpc_value_react' $runReact.Rpc
Row 'run_rpc_value_pas2js' $runPas2js.Rpc
Row 'listener_members_max' ([Math]::Max($runReact.Listeners, $runPas2js.Listeners))
Row 'listener_members_seen' ([Math]::Max($runReact.Members, $runPas2js.Members))
Row 'listener_sampler_scope' (Get-PWebSamplerScope)
Row 'run_connections_max' ([Math]::Max($runReact.Connections, $runPas2js.Connections))
Row 'flush_live_lines' (Bool ($runReact.ReadyLive -and $runPas2js.ReadyLive))
Row 'layout_accepted_by_run' $(
    if (($runReact.Code -eq 0) -and ($runPas2js.Code -eq 0)) { 'PASS' } else { 'FAIL' })

# --- 6. TC2 / TC3 / TC4: the refusals ---------------------------------------
function RefusalLeg([string]$Tag, [string]$Project, [string]$ExtraPath) {
    $before = TreeDigest $Project
    $r = RunPipe $Project $Tag 300000 $ExtraPath
    $after = TreeDigest $Project
    Require ($before -ceq $after) "$Tag`: a refusing pipeline WROTE into the project"
    return $r
}
# TC2: a compiler that misses its pin. The fixture answers 1.0.0 to
# everything, so the doctor's toolchain.fpc row fails and the pipeline
# adopts its cause - at stage 2, before anything is written
$tc2Project = StageProject 'tc2' 'cap10b1'
$env:PWEBFAKE_MARKER = Join-Path $work 'fake-executed.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $env:PWEBFAKE_MARKER
$tc2 = RefusalLeg 'tc2' $tc2Project $fakeDir
Row 'tc_version_mismatch' "exit$($tc2.Code)/$($tc2.Report['pipeline_cause'])"
Require ($tc2.Code -eq 4) "TC2: a version mismatch answered $($tc2.Code), expected 4"
Require ("$($tc2.Report['pipeline_result'])" -ceq 'toolchain') `
    "TC2: the refusal came from $($tc2.Report['pipeline_result']), expected toolchain"

# TC3: the same fixture INSIDE the project root - reported, and NEVER
# executed, which the marker file it would write proves by its absence
$tc3Project = StageProject 'tc3' 'cap10b1'
$tc3Tools = Join-Path $tc3Project 'toolbox'
New-Item -ItemType Directory -Force $tc3Tools | Out-Null
Copy-Item -Force -LiteralPath (Join-Path $fakeDir "fpc$exeSuffix") -Destination $tc3Tools
if (-not $IsWindows) { & chmod +x (Join-Path $tc3Tools "fpc$exeSuffix") }
Remove-Item -Force -ErrorAction SilentlyContinue $env:PWEBFAKE_MARKER
$tc3 = RunPipe $tc3Project 'tc3' 300000 $tc3Tools
Row 'tc_inside_project' "exit$($tc3.Code)/$($tc3.Report['pipeline_cause'])"
Require ($tc3.Code -eq 4) "TC3: a project-local tool answered $($tc3.Code), expected 4"
Require ("$($tc3.Report['pipeline_cause'])" -ceq 'tool_inside_project') `
    "TC3: the cause is $($tc3.Report['pipeline_cause'])"
Row 'tc_inside_project_executed' (Bool (Test-Path -LiteralPath $env:PWEBFAKE_MARKER))
Require (-not (Test-Path -LiteralPath $env:PWEBFAKE_MARKER)) `
    'TC3: the project-local tool was EXECUTED - it left its marker'
Remove-Item Env:PWEBFAKE_MARKER -ErrorAction SilentlyContinue

# TC4: a doctor refusal, adopted with the doctor's own cause
$tc4Project = StageProject 'tc4' 'cap10b1'
Remove-Item -Force (Join-Path $tc4Project 'frontend/package-lock.json')
$tc4 = RunPipe $tc4Project 'tc4' 300000
Row 'tc_doctor_refusal' "exit$($tc4.Code)/$($tc4.Report['pipeline_cause'])"
Require ($tc4.Code -eq 4) "TC4: a doctor refusal answered $($tc4.Code), expected 4"
Require ("$($tc4.Report['pipeline_cause'])" -ceq 'lockfile_absent') `
    "TC4: the cause is $($tc4.Report['pipeline_cause']), expected the doctor's own"

# --- 7. ST4 / ST9: a seeded failure leaves no layout ------------------------
$st9Project = StageProject 'st9' 'cap10b1'
$appTsx = Join-Path $st9Project 'frontend/src/App.tsx'
[System.IO.File]::WriteAllText($appTsx,
    ([System.IO.File]::ReadAllText($appTsx) +
     "`nconst pwebSeededTypeError: number = `"not a number`";`n"))
$st9 = RunPipe $st9Project 'st9'
Row 'typecheck_failure' "exit$($st9.Code)/$($st9.Report['pipeline_result'])"
Require ($st9.Code -eq 5) "ST4: a type error answered $($st9.Code), expected 5"
Require ("$($st9.Report['pipeline_result'])" -ceq 'typecheck') `
    "ST4: the failing stage is $($st9.Report['pipeline_result'])"
$st9Release = Join-Path $st9Project "dist/$target/release"
$st9Stage = Join-Path $st9Project "dist/$target/.pweb-release.tmp"
Row 'partial_layout_on_failure' (Bool ((Test-Path -LiteralPath $st9Release) -or
    (Test-Path -LiteralPath $st9Stage)))
Require (-not (Test-Path -LiteralPath $st9Release)) `
    'ST9: a failed pipeline left a release directory'
Require (-not (Test-Path -LiteralPath $st9Stage)) `
    'ST9: a failed pipeline left its staging directory'

# --- 8. ST12: the SDK root is READ-ONLY to a build ---------------------------
$sdkAfter = TreeDigest $sdk
Row 'sdk_root_unchanged' (Bool ($sdkBefore -ceq $sdkAfter))
Require ($sdkBefore -ceq $sdkAfter) `
    'ST12: the pipeline WROTE into the SDK root it builds against'

# --- 9. DB2 / SF1: the ledger and the public surface ------------------------
$ledger = [System.IO.File]::ReadAllText(
    (Join-Path $repoRoot '_bmad-output/implementation-artifacts/deferred-work.md'))
$supersession = $ledger.Contains('CAP-10C1') -and
    $ledger.Contains('TEMPLATE SUPERSESSION')
Row 'template_supersession_recorded' (Bool $supersession)
Require $supersession `
    'DB2: deferred-work.md carries no CAP-10C1 TEMPLATE SUPERSESSION entry'

$help = (& $pweb '--help' 2>&1 | Out-String)
$helpCode = $LASTEXITCODE
$advertised = @()
foreach ($c in 'create', 'doctor', 'run') {
    if ($help -match "(?m)^\s+$c\s") { $advertised += $c }
}
Row 'advertised_commands' ($advertised -join ',')
Require (($advertised -join ',') -ceq 'create,doctor,run') `
    "SF1: pweb advertises $($advertised -join ',')"
foreach ($absent in 'dev', 'build') {
    & $pweb $absent 2>&1 | Out-Null
    Require ($LASTEXITCODE -eq 2) `
        "SF1: pweb $absent exited $LASTEXITCODE, expected 2 (unknown command)"
}
Row 'dev_build_unknown' 'true'
Row 'pipeline_units_linked' 'false'

# --- 10. the verdict and the evidence ---------------------------------------
Row 'target' $target
Row 'pipeline_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10C1] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10C1 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10C1] gates PASS on $target"
