# CAP-10C0: run the supervision suite and the `pweb run` gates against the
# REAL compiled CLI, and emit this target's evidence.
#
# ONE script for all four targets, as every CAP-10 gate is. It needs what the
# CAP-10B1 and CAP-10B2 proofs left behind - the two generated projects and
# the two release layouts they built - and STAGES them beneath each project's
# own `output` in the layout CAP-10C0 ratified, byte for byte. Nothing is
# rebuilt: `pweb run` is measured on what the private harnesses produced.
#
# WHAT IT PROVES:
#
#   - THE SUITE: S1-S18 against the fixture child, the quoting table, the
#     drain over injected records, the layout rule and its refusals, and the
#     two drivers over the real CLI - a stop signal delivered to a live
#     `pweb run` (R10) and a supervisor terminated under a live application
#     (S11). Its decision corpus is digested into supervision_digest.
#   - THE COMMAND: `pweb run` on the built React and Pas2JS projects from an
#     unrelated working directory, the page's ready report forwarded through
#     the supervisor (42), the listening-socket sampler live against the
#     APPLICATION pid, the descendants drained by membership (from the
#     supervisor's own report) and re-counted by a path-scoped sweep, the
#     project and layout trees digested before and after, no ANSI, and every
#     refusal - not built, a link on the layout chain, a tampered bundle,
#     the option matrix - executed with its cause and its category.
#
# Emits build/cap10c0/cli-<target>.json.
#
# Usage: pwsh test/cap10c0/run_cap10c0_gates.ps1   (POSIX: under a display)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot
# CAP-10C1 ratified this addition: the MEMBERSHIP-scoped sampler runs here
# too, BESIDE the per-pid one below. `run_listener_count` keeps the exact
# provenance it was ratified with ("sampled live against the APPLICATION
# pid") and is not re-baselined; `run_listener_members_max` is the stronger
# claim the CAP-10C0 ledger asked for, measured on the same applications.
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$bin = Join-Path $repoRoot 'build/cap10c0/bin'
$pweb = Join-Path $repoRoot "build/cap10b1/sdk/bin/pweb$exeSuffix"
$suite = Join-Path $bin "c0tests$exeSuffix"
$child = Join-Path $bin "pwebchild$exeSuffix"
foreach ($pre in $pweb, $suite, $child) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw "missing precondition: $pre -- run the build scripts first"
    }
}

if ($IsWindows) { $target = 'windows-x86_64' }
elseif ($IsLinux) { $target = 'linux-x86_64' }
elseif ($IsMacOS) {
    $target = if ((uname -m).Trim() -eq 'arm64') { 'macos-arm64' }
              else { 'macos-x86_64' }
} else { throw 'unsupported host' }
Write-Host "[CAP-10C0] target: $target"

$work = Join-Path $repoRoot 'build/cap10c0'
New-Item -ItemType Directory -Force $work | Out-Null
$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Name, $Value) { $rows[$Name] = $Value }
function Require([bool]$Ok, [string]$What) {
    if (-not $Ok) { $failures.Add($What); Write-Host "GATE FAILURE: $What" }
}
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
function Sha256File([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    return Sha256Text $text
}
# plain .NET, never Get-Item / Get-FileHash: on Unix pwsh treats a dot file
# as HIDDEN and refuses it without -Force (MEASURED on run 33621204892: the
# generated project's .gitattributes broke the digest on Linux)
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
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }

# --- 0. stage the two built projects beneath their own output ---------------
# Everything comes from the B1/B2 proofs, unchanged: the created project
# (build/cap10bN/project/demo) and the release the proof assembled and ran
# (build/cap10bN/release). The stage puts the latter where the CAP-10C0
# layout rule says a build lands: <output>/<target>/release/, with the macOS
# bundle renamed to the identity-derived `<ident>.app`.
function StageProject([string]$Tag, [string]$Source) {
    $sourceProject = Join-Path $repoRoot "build/$Source/project/demo"
    $sourceRelease = Join-Path $repoRoot "build/$Source/release"
    if (-not (Test-Path -LiteralPath (Join-Path $sourceProject 'pweb.json'))) {
        throw "the $Source generated project is absent at $sourceProject"
    }
    if (-not (Test-Path -LiteralPath $sourceRelease)) {
        throw "the $Source release is absent at $sourceRelease -- run its proof first"
    }
    $stage = Join-Path $work "stage/$Tag"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item -LiteralPath $sourceProject -Destination (Join-Path $stage 'demo') -Recurse
    $release = Join-Path $stage "demo/dist/$target/release"
    New-Item -ItemType Directory -Force $release | Out-Null
    if ($IsMacOS) {
        $bundle = Get-ChildItem -LiteralPath $sourceRelease -Directory |
            Where-Object { $_.Name -like '*.app' } | Select-Object -First 1
        if (-not $bundle) { throw "no .app bundle in $sourceRelease" }
        Copy-Item -LiteralPath $bundle.FullName -Destination (Join-Path $release 'demo.app') -Recurse
    } else {
        Get-ChildItem -LiteralPath $sourceRelease -Force |
            Copy-Item -Destination $release -Recurse
    }
    return (Join-Path $stage 'demo')
}
$reactStage = StageProject 'react' 'cap10b1'
$pas2jsStage = StageProject 'pas2js' 'cap10b2'
# the bytes are the proofs' bytes: recorded so the aggregate can see the
# React run measured the CAP-10B1 executable and not a rebuild
Row 'stage_react_release_digest' (TreeDigest (Join-Path $reactStage "dist/$target/release"))
Row 'stage_pas2js_release_digest' (TreeDigest (Join-Path $pas2jsStage "dist/$target/release"))
$reactBefore = TreeDigest $reactStage
$pas2jsBefore = TreeDigest $pas2jsStage

# --- 1. the suite -----------------------------------------------------------
$suiteLog = Join-Path $work 'c0tests.log'
Remove-Item -Force -ErrorAction SilentlyContinue `
    (Join-Path $work 'supervise-corpus.txt'), (Join-Path $work 'supervise-observed.txt')
$env:PWEB_C0_STAGE_REACT = $reactStage
$env:PWEB_C0_PWEB = $pweb
# the host's auto-close SMOKE bound must NOT be armed under the suite: the
# stop-signal drivers bound their runs through the engine (see the contract)
Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
if ($IsWindows) { $out = & $suite /noenter 2>&1 | Out-String }
else { $out = & $suite 2>&1 | Out-String }
$suiteCode = $LASTEXITCODE
[System.IO.File]::WriteAllText($suiteLog, $out)
Write-Host $out
Require ($suiteCode -eq 0) 'the CAP-10C0 suite failed'
foreach ($anchor in 'P web cli pure', 'P web cli supervise', 'P web cli run command') {
    Require ($out.Contains($anchor)) "the suite never registered '$anchor'"
}
Row 'supervision_suite' $(if ($suiteCode -eq 0) { 'PASS' } else { 'FAIL' })
$corpusPath = Join-Path $work 'supervise-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite emitted no corpus'
$corpusLines = @()
if (Test-Path -LiteralPath $corpusPath) {
    Row 'supervision_digest' (Sha256File $corpusPath)
    $corpusLines = @([System.IO.File]::ReadAllLines($corpusPath) | Where-Object { $_ -notmatch '^#' })
    Row 'supervision_corpus_lines' $corpusLines.Count
} else {
    Row 'supervision_digest' ''
    Row 'supervision_corpus_lines' 0
}
# the decisions the aggregate pins, read back OUT of the corpus rather than
# restated: a gate that asserted a value the suite never recorded would be a
# second, softer suite
function CorpusHas([string]$Prefix) { return [bool]@($corpusLines | Where-Object { $_.StartsWith($Prefix) }).Count }
Row 'argv_roundtrip' $(if (CorpusHas 'supervise|argv|18|exact=true') { 'exact' } else { 'FAIL' })
Row 'exit_propagation' $(if ((CorpusHas 'supervise|exit|0|exited|0') -and
    (CorpusHas 'supervise|exit|3|exited|3') -and (CorpusHas 'supervise|exit|255|exited|255') -and
    (CorpusHas 'probe|exit|3|probe_completed|3')) { 'exact' } else { 'FAIL' })
Row 'death_never_exit_zero' (Bool (CorpusHas 'supervise|die|never_exit_zero|true'))
Row 'forced_kill_required' (Bool ((CorpusHas 'supervise|stubborn|timeout|forced') -and
    (CorpusHas 'supervise|stubborn|stop|forced')))
Row 'grandchild_drained' (Bool (CorpusHas 'supervise|spawn|grandchild_member=true|descendants_after_exit=0|alive=false'))
Row 'zombie_left' (Bool (-not (CorpusHas 'supervise|reaped|zombie=false')))
Row 'workdir_explicit' (Bool (CorpusHas 'supervise|cwd|explicit=true|inherited=false'))
Row 'environment_policy' $(if (CorpusHas 'supervise|env|inherited_exact=true|injected=none') { 'inherit_unchanged' } else { 'FAIL' })
Row 'batch_file_refused' (Bool (CorpusHas 'supervise|batch|spawn_refused|batch_file'))
Row 'run_interrupt_clean' (Bool (CorpusHas 'run|interrupt|pweb_exit=0|stop_requested=true|clean_exit=true|forced=false'))
Row 'supervisor_terminated_tree_dies' (Bool (CorpusHas 'run|supervisor-terminated|tree_dies=true'))
Require (CorpusHas 'run|interrupt-ignored|pweb_exit=5|forced=true') 'the forced category was not measured through the real command'
Require (CorpusHas 'run|app-death|pweb_exit=5|never_zero=true') 'the death category was not measured through the real command'
# per-target OBSERVATIONS from the suite: recorded, never compared. The keys
# are PREFIXED so no observation can ever shadow a top-level row of this
# record for a reader that has no notion of nesting (the POSIX emitter)
$observed = [ordered]@{}
$treeModel = ''
$signalTyped = ''
$observedPath = Join-Path $work 'supervise-observed.txt'
if (Test-Path -LiteralPath $observedPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($observedPath)) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) {
            $k = $line.Substring(0, $eq); $v = $line.Substring($eq + 1)
            $observed["obs_$k"] = $v
            if ($k -eq 'tree_model') { $treeModel = $v }
            if ($k -eq 'signal_outcome_typed') { $signalTyped = $v }
        }
    }
}
Row 'supervision_observed' $observed
Row 'supervision_tree_model' $treeModel
Row 'signal_outcome_typed' $signalTyped
Row 'graceful_stop_mechanism' $(if ($IsWindows) { 'wm_close_visible_toplevel' } else { 'sigterm_process_group' })
# the suite's verdict is the SUITE's: a run leg failing below must not
# rewrite what the engine proved, and the two verdicts are pinned apart
Row 'supervision_corpus' $(if (($suiteCode -eq 0) -and ($failures.Count -eq 0)) { 'PASS' } else { 'FAIL' })

# --- 2. the real CLI -------------------------------------------------------
$runCwd = Join-Path $work 'unrelated-cwd'
New-Item -ItemType Directory -Force $runCwd | Out-Null
$runSeq = 0
function RunPweb([string[]]$CliArgs, [int]$TimeoutMs, [string]$AutoCloseMs) {
    $script:runSeq++
    $so = Join-Path $work "run-$script:runSeq-stdout.txt"
    $se = Join-Path $work "run-$script:runSeq-stderr.txt"
    if ($AutoCloseMs -ne '') { $env:PWEB_SMOKE_AUTOCLOSE_MS = $AutoCloseMs }
    else { Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # an UNRELATED working directory, always: run resolves nothing from it
    $p = Start-Process -FilePath $pweb -ArgumentList $CliArgs -PassThru `
        -NoNewWindow -WorkingDirectory $runCwd `
        -RedirectStandardOutput $so -RedirectStandardError $se
    $appPid = 0
    $listeners = 0
    $connections = 0
    $sampled = 0
    $toolChildren = 0
    $memberListeners = 0
    $memberSeen = 0
    while (-not $p.HasExited -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 400
        if ($appPid -eq 0 -and (Test-Path -LiteralPath $se)) {
            foreach ($line in (Get-Content -LiteralPath $se -ErrorAction SilentlyContinue)) {
                if ($line -match '^pweb: started pid (\d+)') { $appPid = [int]$Matches[1] }
            }
        }
        if ($appPid -gt 0) {
            # sampled WHILE the application is live, against ITS pid
            try {
                if ($IsWindows) {
                    $n = @(Get-NetTCPConnection -State Listen -OwningProcess $appPid -ErrorAction SilentlyContinue).Count
                    $u = @(Get-NetUDPEndpoint -OwningProcess $appPid -ErrorAction SilentlyContinue).Count
                    $c = @(Get-NetTCPConnection -OwningProcess $appPid -ErrorAction SilentlyContinue |
                        Where-Object { $_.State -ne 'Listen' }).Count
                } elseif ($IsLinux) {
                    $n = @(ss -ltnp 2>$null | Select-String "pid=$appPid,").Count
                    $u = @(ss -lunp 2>$null | Select-String "pid=$appPid,").Count
                    $c = @(ss -tnp 2>$null | Select-String "pid=$appPid,").Count
                } else {
                    $n = @(lsof -nP -p $appPid 2>$null | Select-String '\(LISTEN\)').Count
                    $u = @(lsof -nP -p $appPid 2>$null | Select-String ' UDP ').Count
                    $c = @(lsof -nP -p $appPid 2>$null | Select-String ' TCP ' | Where-Object { $_ -notmatch 'LISTEN' }).Count
                }
                $sampled++
                if (($n + $u) -gt $listeners) { $listeners = $n + $u }
                if ($c -gt $connections) { $connections = $c }
            } catch { }
            # CAP-10C1: the same question asked of every MEMBER of the tree
            try {
                foreach ($m in @(Get-PWebTreeMembers -RootPid $appPid)) {
                    # $m is a pid; the count is what matters, not its value
                    $mn = Get-PWebListenerCount -OwnerPid $m
                    if ($mn -gt $memberListeners) { $memberListeners = $mn }
                }
                $seen = @(Get-PWebTreeMembers -RootPid $appPid).Count
                if ($seen -gt $memberSeen) { $memberSeen = $seen }
            } catch { }
            # no tool may run under the application: the children of the
            # application pid, by name, are only ever browser processes
            try {
                if ($IsWindows) {
                    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$appPid" -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.Name })
                } else {
                    $kids = @(ps -eo ppid=,comm= 2>$null | ForEach-Object {
                        $f = ($_.Trim() -split '\s+', 2); if ([int]$f[0] -eq $appPid) { $f[1] } })
                }
                foreach ($k in $kids) {
                    if ($k -match '(^|[\\/])(node|npm|pas2js|fpc|git|vite|cmd|sh|bash|pwsh|powershell)(\.exe)?$') { $toolChildren++ }
                }
            } catch { }
        }
    }
    $forced = $false
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
        $p.WaitForExit(10000) | Out-Null
        $forced = $true
    }
    $p.WaitForExit()
    $outText = if (Test-Path -LiteralPath $so) { [System.IO.File]::ReadAllText($so) } else { '' }
    $errText = if (Test-Path -LiteralPath $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    return [pscustomobject]@{
        Code = $p.ExitCode; Out = $outText; Err = $errText; AppPid = $appPid
        Listeners = $listeners; Connections = $connections; Sampled = $sampled
        ToolChildren = $toolChildren; ElapsedMs = [int]$sw.ElapsedMilliseconds
        HarnessKilled = $forced
        MemberListeners = $memberListeners; MemberSeen = $memberSeen
    }
}

# processes whose image lies under a directory, on a component boundary -
# the path-scoped RE-COUNT after a run, beside the supervisor's own report
function ProcessesUnder([string]$Root) {
    $prefix = ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $found = @()
    try {
        if ($IsWindows) {
            $found = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $img = ''
                try { $img = [string]$_.ExecutablePath } catch { $img = '' }
                ($img -ne '') -and $img.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            } | ForEach-Object { "$($_.ProcessId)" })
        } elseif ($IsLinux) {
            foreach ($d in (Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' })) {
                $img = ''
                try { $img = (readlink "/proc/$($d.Name)/exe" 2>$null) } catch { $img = '' }
                if ($img -and $img.StartsWith($prefix)) { $found += $d.Name }
            }
        } else {
            foreach ($line in (ps -axo pid=,comm= 2>$null)) {
                $f = ($line.Trim() -split '\s+', 2)
                if ($f.Count -eq 2 -and $f[1].StartsWith($prefix)) { $found += $f[0] }
            }
        }
    } catch { $found = @() }
    return @($found)
}

function ReadyReport([string]$Stdout) {
    $json = ''
    foreach ($line in ($Stdout -split "`n")) {
        if ($line -match 'demo: ready (\{.*\})\s*$') { $json = $Matches[1] }
    }
    if ($json -eq '') { return $null }
    return ($json | ConvertFrom-Json)
}

function RunLeg([string]$Tag, [string]$Stage, [string]$Before) {
    $r = RunPweb @('run', '--project', $Stage) 90000 '20000'
    Write-Host "----- $Tag stdout -----"; Write-Host $r.Out
    Write-Host "----- $Tag stderr -----"; Write-Host $r.Err
    Require (-not $r.HarnessKilled) "$Tag`: pweb did not exit inside 90 s and was killed by the harness -- a HUNG RUN"
    Require ($r.Code -eq 0) "$Tag`: pweb exited $($r.Code)"
    Require ($r.AppPid -gt 0) "$Tag`: pweb never named the application pid"
    Require ($r.Sampled -gt 0) "$Tag`: the listening-socket sampler never ran: listener_count would be a vacuous 0"
    Require ($r.Listeners -eq 0) "$Tag`: the application opened $($r.Listeners) listener(s)"
    Require ($r.Connections -eq 0) "$Tag`: the application held $($r.Connections) connection(s)"
    Require ($r.ToolChildren -eq 0) "$Tag`: $($r.ToolChildren) tool process(es) ran under the application"
    Require (-not $r.Out.Contains([char]27) -and -not $r.Err.Contains([char]27)) "$Tag`: ANSI emitted when redirected"
    Require ($r.Out.Contains('demo: clean exit')) "$Tag`: the host did not report a clean exit"
    Require ($r.Err.Contains('pweb: application exited 0')) "$Tag`: pweb did not report exit 0"
    Require ($r.Err -match '(?m)^pweb: running dist/[a-z0-9_-]+/release/') "$Tag`: the supervisor line does not name the logical layout"
    Require (-not ($r.Err -match '[A-Za-z]:\\|/home/|/Users/')) "$Tag`: an absolute path leaked into the supervisor's lines"
    $report = ReadyReport $r.Out
    Require ($null -ne $report) "$Tag`: no ready report was forwarded -- NO REPORT RECEIVED"
    $rpc = if ($report) { $report.value } else { -1 }
    $secure = if ($report) { $report.secure -eq $true } else { $false }
    $errmap = if ($report) { $report.errmap -eq $true } else { $false }
    Require ($rpc -eq 42) "$Tag`: CalculatorService.Add returned $rpc"
    Require $secure "$Tag`: the page did not report a secure origin"
    Require $errmap "$Tag`: the page did not report the typed error mapping"
    # descendants: the supervisor's own membership report, then the
    # path-scoped re-count against the release tree
    $survived = 0
    if ($r.Err -match '(?m)^pweb: (\d+) descendant process\(es\) survived') { $survived = [int]$Matches[1] }
    $drained = 0; $forcedCount = -1; $passes = 0
    if ($r.Err -match '(?m)^pweb: drained (\d+) descendant process\(es\) in (\d+) pass\(es\), (\d+) forced') {
        $drained = [int]$Matches[1]; $passes = [int]$Matches[2]; $forcedCount = [int]$Matches[3]
    }
    Require ($survived -eq 0) "$Tag`: $survived descendant(s) survived the drain"
    $under = @(ProcessesUnder (Join-Path $Stage "dist/$target/release"))
    Require ($under.Count -eq 0) "$Tag`: $($under.Count) process(es) still run from the release tree: $($under -join ',')"
    $after = TreeDigest $Stage
    Require ($after -ceq $Before) "$Tag`: pweb run MUTATED the project or its layout"
    return [pscustomobject]@{
        Rpc = $rpc; Secure = $secure; Errmap = $errmap; Listeners = $r.Listeners
        Connections = $r.Connections; ToolChildren = $r.ToolChildren; Survived = $survived
        Drained = $drained; Forced = $forcedCount; Passes = $passes; Under = $under.Count
        Unchanged = ($after -ceq $Before); ElapsedMs = $r.ElapsedMs; AppPid = $r.AppPid
        Ansi = ($r.Out.Contains([char]27) -or $r.Err.Contains([char]27))
        MemberListeners = $r.MemberListeners; MemberSeen = $r.MemberSeen
    }
}

# --- R1 / R2 / R3 / R11 / R12 / R13 -----------------------------------------
$react = RunLeg 'R1 react' $reactStage $reactBefore
$pas2js = RunLeg 'R2 pas2js' $pas2jsStage $pas2jsBefore
Row 'run_react_rpc_value' $react.Rpc
Row 'run_pas2js_rpc_value' $pas2js.Rpc
Row 'run_secure_origin' $(if ($react.Secure -and $pas2js.Secure) { 'PASS' } else { 'FAIL' })
Row 'run_error_mapping' $(if ($react.Errmap -and $pas2js.Errmap) { 'PASS' } else { 'FAIL' })
Row 'run_listener_count' ([Math]::Max($react.Listeners, $pas2js.Listeners))
Row 'run_listener_members_max' ([Math]::Max($react.MemberListeners, $pas2js.MemberListeners))
Row 'run_listener_members_seen' ([Math]::Max($react.MemberSeen, $pas2js.MemberSeen))
Row 'run_listener_sampler_scope' (Get-PWebSamplerScope)
Require ([Math]::Max($react.MemberSeen, $pas2js.MemberSeen) -gt 0) 'the membership sampler saw no tree member: run_listener_members_max would be a vacuous 0'
Require ([Math]::Max($react.MemberListeners, $pas2js.MemberListeners) -eq 0) 'a tree member opened a listener'
Row 'run_network_calls' ([Math]::Max($react.Connections, $pas2js.Connections))
Row 'run_tool_calls' ($react.ToolChildren + $pas2js.ToolChildren)
Row 'descendants_after_exit' ([Math]::Max($react.Survived, $pas2js.Survived) + [Math]::Max($react.Under, $pas2js.Under))
# react,pas2js pairs as ONE string: the POSIX emitter reads scalars only
Row 'run_descendants_drained' "$($react.Drained),$($pas2js.Drained)"
Row 'run_descendants_forced' "$($react.Forced),$($pas2js.Forced)"
Row 'run_drain_passes' "$($react.Passes),$($pas2js.Passes)"
Row 'run_tree_unchanged' $(if ($react.Unchanged -and $pas2js.Unchanged) { 'PASS' } else { 'FAIL' })
Row 'run_no_ansi' (Bool (-not ($react.Ansi -or $pas2js.Ansi)))
Row 'run_unrelated_cwd' 'true'
Row 'run_elapsed_ms' "$($react.ElapsedMs),$($pas2js.ElapsedMs)"
# MEASURED, not restated: the development-trust sweep's own verdict (it runs
# before this gate in every job, and its record must exist - an absent
# record is a failure, never a clean 'false'), and the teardown order the
# contract gate pinned in the host's source
$devTrust = Join-Path $repoRoot 'build/cap10a/dev-trust.txt'
if (Test-Path -LiteralPath $devTrust) {
    $verdict = @([System.IO.File]::ReadAllLines($devTrust) | Where-Object { $_ -match '^VERDICT: ' })
    $devClean = ($verdict.Count -eq 1) -and ($verdict[0] -match '^VERDICT: PASS')
    Require $devClean "the development-trust sweep did not pass: $($verdict -join ' ')"
    Row 'run_dev_allowance_present' (Bool (-not $devClean))
} else {
    Require $false 'build/cap10a/dev-trust.txt is absent -- run test/cap10a/check_dev_trust.ps1 first'
    Row 'run_dev_allowance_present' 'unmeasured'
}
$contractsEarly = Join-Path $work 'contracts.json'
if (Test-Path -LiteralPath $contractsEarly) {
    $ce = Get-Content -LiteralPath $contractsEarly -Raw | ConvertFrom-Json
    Row 'shutdown_order' "$($ce.shutdown_order)"
} else {
    Row 'shutdown_order' 'unmeasured'
}

# --- R4: --project at the descriptor, from the same unrelated CWD -----------
$r4 = RunPweb @('run', '--project', (Join-Path $reactStage 'pweb.json')) 60000 '3000'
Require ($r4.Code -eq 0) "R4: --project <descriptor> exited $($r4.Code)"
Require ($r4.Err.Contains('pweb: application exited 0')) 'R4: not a clean run'
Row 'run_project_descriptor_form' $(if ($r4.Code -eq 0) { 'PASS' } else { 'FAIL' })

# --- R5: not built - no build attempted, nothing mutated --------------------
$unbuilt = Join-Path $work 'stage/unbuilt'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $unbuilt
Copy-Item -LiteralPath (Join-Path $repoRoot 'build/cap10b1/project/demo') -Destination $unbuilt -Recurse
$unbuiltBefore = TreeDigest $unbuilt
$r5 = RunPweb @('run', '--project', $unbuilt) 30000 ''
Require ($r5.Code -eq 3) "R5: an unbuilt project must exit 3, got $($r5.Code)"
Require ($r5.Err.Contains('run refused: not_built')) 'R5: the cause is not not_built'
Require ($r5.Err.Contains("dist/$target/release/")) 'R5: the missing component is not named logically'
Require ($r5.Err.Contains('run builds nothing')) 'R5: the refusal does not say that run builds nothing'
Require (-not ($r5.Err -match '[A-Za-z]:\\|/home/|/Users/|/tmp/')) 'R5: an absolute path leaked into the refusal'
Require ((TreeDigest $unbuilt) -ceq $unbuiltBefore) 'R5: the unbuilt project was mutated'
Require (-not (Test-Path -LiteralPath (Join-Path $unbuilt 'dist'))) 'R5: an output directory appeared'
Row 'run_not_built' $(if (($r5.Code -eq 3) -and $r5.Err.Contains('not_built')) { 'exit3/not_built' } else { 'FAIL' })

# --- R6: a link on the layout chain is refused, never followed -------------
$linked = Join-Path $work 'stage/linked'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $linked
Copy-Item -LiteralPath (Join-Path $repoRoot 'build/cap10b1/project/demo') -Destination $linked -Recurse
New-Item -ItemType Directory -Force (Join-Path $linked 'dist') | Out-Null
$linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
New-Item -ItemType $linkType -Path (Join-Path $linked "dist/$target") `
    -Target (Join-Path $reactStage "dist/$target") | Out-Null
$r6 = RunPweb @('run', '--project', $linked) 30000 ''
Require ($r6.Code -eq 3) "R6: a linked layout must exit 3, got $($r6.Code)"
Require ($r6.Err.Contains('run refused: layout_link')) "R6: the cause is not layout_link: $($r6.Err)"
Require (-not ($r6.Err -match '[A-Za-z]:\\|/home/|/Users/|/tmp/')) 'R6: an absolute path leaked into the refusal'
Row 'run_layout_link' $(if (($r6.Code -eq 3) -and $r6.Err.Contains('layout_link')) { 'exit3/layout_link' } else { 'FAIL' })
# the escape variant: `output` naming a path outside the root is a
# DESCRIPTOR refusal (CAP-10A), before any layout exists
$escaped = Join-Path $work 'stage/escaped'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $escaped
Copy-Item -LiteralPath (Join-Path $repoRoot 'build/cap10b1/project/demo') -Destination $escaped -Recurse
$desc = [System.IO.File]::ReadAllText((Join-Path $escaped 'pweb.json'))
[System.IO.File]::WriteAllText((Join-Path $escaped 'pweb.json'),
    $desc.Replace('"output": "dist"', '"output": "../dist"'), [System.Text.UTF8Encoding]::new($false))
$r6b = RunPweb @('run', '--project', $escaped) 30000 ''
Require ($r6b.Code -eq 3) "R6: an escaping output must exit 3, got $($r6b.Code)"
Require (-not ($r6b.Err -match '[A-Za-z]:\\|/home/|/Users/|/tmp/')) 'R6: an absolute path leaked into the descriptor refusal'
Row 'run_output_escape' $(if ($r6b.Code -eq 3) { 'exit3' } else { 'FAIL' })

# --- R9: the application's own nonzero exit, through the real command ------
# the fixture child stands in for the built application: launched with no
# argument and no PWEBCHILD_MODE it exits 64, and `pweb run` must answer 5
# with the real status printed (the forced and signal-death rows of the
# same category are driven by the suite, which can deliver the stop signal)
$exitProject = Join-Path $work 'stage/exit64'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $exitProject
Copy-Item -LiteralPath (Join-Path $repoRoot 'build/cap10b1/project/demo') -Destination $exitProject -Recurse
$exitRelease = Join-Path $exitProject "dist/$target/release"
$exitExe = if ($IsMacOS) { Join-Path $exitRelease 'demo.app/Contents/MacOS/demo' } else { Join-Path $exitRelease "demo$exeSuffix" }
$exitBundle = if ($IsMacOS) { Join-Path $exitRelease 'demo.app/Contents/Resources/app.pwb' } else { Join-Path $exitRelease 'app.pwb' }
New-Item -ItemType Directory -Force (Split-Path -Parent $exitExe), (Split-Path -Parent $exitBundle) | Out-Null
Copy-Item -LiteralPath $child -Destination $exitExe
[System.IO.File]::WriteAllText($exitBundle, 'PK', [System.Text.UTF8Encoding]::new($false))
if ($IsMacOS) {
    [System.IO.File]::WriteAllText((Join-Path $exitRelease 'demo.app/Contents/Info.plist'), '<plist/>', [System.Text.UTF8Encoding]::new($false))
}
Remove-Item Env:PWEBCHILD_MODE -ErrorAction SilentlyContinue
$r9 = RunPweb @('run', '--project', $exitProject) 60000 ''
Write-Host "----- R9 stderr -----"; Write-Host $r9.Err
Require ($r9.Code -eq 5) "R9: an application exit 64 must map to 5, got $($r9.Code)"
Require ($r9.Err.Contains('pweb: application exited 64')) 'R9: the real status was not printed'
Row 'run_app_nonzero' $(if (($r9.Code -eq 5) -and $r9.Err.Contains('pweb: application exited 64')) { 'exit5/64' } else { 'FAIL' })

# --- R7 / R9: a tampered bundle - the host refuses, run reports the status ----
$tampered = Join-Path $work 'stage/tampered'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tampered
Copy-Item -LiteralPath $reactStage -Destination $tampered -Recurse
$bundlePath = if ($IsMacOS) { Join-Path $tampered "dist/$target/release/demo.app/Contents/Resources/app.pwb" }
              else { Join-Path $tampered "dist/$target/release/app.pwb" }
$bytes = [System.IO.File]::ReadAllBytes($bundlePath)
for ($i = 0; $i -lt [Math]::Min(64, $bytes.Length); $i++) { $bytes[$i] = 0 }
[System.IO.File]::WriteAllBytes($bundlePath, $bytes)
$r7 = RunPweb @('run', '--project', $tampered) 60000 '5000'
Write-Host "----- R7 stderr -----"; Write-Host $r7.Err
Require ($r7.Code -eq 5) "R7: a refused bundle must map to exit 5, got $($r7.Code)"
Require ($r7.Err.Contains('app.pwb REFUSED')) 'R7: the host did not refuse the bundle'
Require ($r7.Err -match '(?m)^pweb: application exited [1-9]') 'R7: the real nonzero status was not printed'
Require (-not $r7.Out.Contains('demo: ready')) 'R7: bundle JS executed despite the refusal'
Row 'run_tampered_bundle' $(if (($r7.Code -eq 5) -and $r7.Err.Contains('app.pwb REFUSED')) { 'exit5/host_refused' } else { 'FAIL' })

# --- R14 and the public surface -------------------------------------------
function ExpectUsage([string]$Tag, [string[]]$CliArgs, [int]$Code, [string]$Cause) {
    $r = RunPweb $CliArgs 30000 ''
    Require ($r.Code -eq $Code) "$Tag`: expected exit $Code, got $($r.Code)"
    if ($Cause -ne '') {
        Require ($r.Err.Contains($Cause)) "$Tag`: expected cause $Cause in: $($r.Err)"
    }
    return ($r.Code -eq $Code)
}
$surface = $true
$surface = (ExpectUsage 'R14 duplicate' @('run', '--project', 'a', '--project', 'b') 2 'duplicate_option') -and $surface
$surface = (ExpectUsage 'R14 json' @('run', '--json') 2 'option_not_for_command') -and $surface
$surface = (ExpectUsage 'R14 verbose' @('run', '--verbose') 2 'option_not_for_command') -and $surface
$surface = (ExpectUsage 'R14 no-color' @('run', '--no-color') 2 'option_not_for_command') -and $surface
$surface = (ExpectUsage 'R14 with-paths' @('run', '--with-paths') 2 'option_not_for_command') -and $surface
$surface = (ExpectUsage 'R14 ui' @('run', '--ui', 'react') 2 'option_not_for_command') -and $surface
$surface = (ExpectUsage 'R14 operand' @('run', 'extra') 2 'extra_positional') -and $surface
$surface = (ExpectUsage 'R14 unknown' @('run', '--watch') 2 'unknown_option') -and $surface
$surface = (ExpectUsage 'C2 dev' @('dev') 2 'unknown_command') -and $surface
$surface = (ExpectUsage 'C2 build' @('build') 2 'unknown_command') -and $surface
$surface = (ExpectUsage 'C2 dev --help' @('dev', '--help') 2 'unknown_command') -and $surface
$help = RunPweb @('--help') 30000 ''
Require ($help.Code -eq 0) '--help did not exit 0'
foreach ($cmd in 'pweb create ', 'pweb doctor ', 'pweb run ') {
    Require ($help.Out.Contains($cmd)) "--help does not list $cmd"
}
foreach ($absent in 'pweb dev', 'pweb build') {
    Require (-not $help.Out.Contains($absent)) "--help advertises $absent"
}
$runHelp = RunPweb @('run', '--help') 30000 ''
Require ($runHelp.Code -eq 0) 'run --help did not exit 0'
Require ($runHelp.Out.Contains('pweb run [--project <path>]')) 'run --help does not state the grammar'
Require ($runHelp.Out.Contains('Run builds nothing')) 'run --help does not state that run builds nothing'
Require (-not $runHelp.Out.Contains([char]27)) 'run --help emitted ANSI'
Row 'cli_run_available' (Bool ($runHelp.Code -eq 0))
Row 'advertised_commands' 'create,doctor,run'
Row 'run_option_matrix' $(if ($surface) { 'PASS' } else { 'FAIL' })
Row 'dev_build_unknown' (Bool $surface)

# --- the shell-free proof at the source and the link (S13 / S16) ----------
$contracts = Join-Path $work 'contracts.json'
if (Test-Path -LiteralPath $contracts) {
    $c = Get-Content -LiteralPath $contracts -Raw | ConvertFrom-Json
    Row 'supervision_shell_used' (Bool ($c.links_fpc_process -eq $true))
    Row 'global_name_kill_present' (Bool ($c.global_name_kill_present -eq $true))
    Require ($c.verdict -ceq 'PASS') 'the contract gate did not pass'
} else {
    Require $false 'build/cap10c0/contracts.json is absent -- run check_cap10c0_contracts.ps1 first'
    Row 'supervision_shell_used' 'unmeasured'
    Row 'global_name_kill_present' 'unmeasured'
}

# --- the verdict and the evidence ---------------------------------------
Row 'target' $target
Row 'run_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
Row 'run_clean_exit' $(if ($failures.Count -eq 0) { 'true' } else { 'false' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($rows | ConvertTo-Json -Depth 6)
if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10C0 gates FAILED on $target ($($failures.Count) failure(s))"
}
Write-Host "[CAP-10C0] gates PASS on $target"
