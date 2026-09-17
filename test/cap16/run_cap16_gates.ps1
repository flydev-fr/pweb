# CAP-16: the native -> page signal channel, gated.
#
# The channel: native code bumps a per-topic sequence, the host evaluates ONE
# templated script per tick carrying the coalesced (topic, seq) pairs as a
# `pweb:signal` DOM event, and the page reads through ordinary invocations.
# The socket door sits on it, and its receive never waits.
#
#   S1   the headless suite: the template and its encoder over every byte
#        value, the channel over a fake view (coalescing, pacing, the flood,
#        revocation racing a flood, document replacement, two windows, the
#        hooks), the socket door on the channel with eight quiet sockets and
#        nothing in flight, and the caller principal (12-5) - with the
#        decision corpus hashed so the four targets can be compared
#   K    the contract cross-checks (test/cap16/check_cap16_contracts.ps1),
#        which run BEFORE this script and whose verdict it reads
#   E1   the engine: a natively evaluated script runs under PWEB_NATIVE_CSP
#        while the page's own eval is refused; the order successive scripts
#        arrive in, typed per engine; eighteen hostile topics through the
#        production encoder, exact, with nothing they spell ever run
#   L1   the PRODUCTION host (PWebHostRun) with the real @pweb/runtime: the
#        handshake feature, a refused topic with zero scripts, a signal, a
#        10 000/s flood bounded to R scripts a second with the page's timer
#        watched, a revocation, a reload and its recovery by re-read, a
#        socket echo through the migrated loop, a service blob read by URL
#   X    the starvation rows the CAP-15C step measured on this leg
#   C1   the Linux composition, read back from its record
#
# Emits build/cap16/cli-<target>.json for the CAP-7F aggregation.
#
# Usage: pwsh test/cap16/run_cap16_gates.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap16'
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
function TargetName {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'arm64' }
        default { 'other' }
    }
    return "$os-$arch"
}
function Sha256File([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
}
function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}
$target = TargetName
Row 'target' $target
$legId = if ($IsWindows) { 'windows' } elseif ($IsMacOS) {
    if ($target -eq 'macos-arm64') { 'macos-arm64' } else { 'macos-x64' } } else { 'linux' }

# THE RATE, read from the one constants home rather than typed here
$signalUnit = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src/rpc/pweb.rpc.signal.pas'))
$rm = [regex]::Match($signalUnit, '(?m)^\s*PWEB_SIGNAL_TICKS_PER_SECOND\s*=\s*(\d+)\s*;')
Require $rm.Success 'the tick rate is not a literal in src/rpc/pweb.rpc.signal.pas'
$ticksPerSecond = if ($rm.Success) { [int]$rm.Groups[1].Value } else { 0 }
Row 'signal_ticks_per_second' "$ticksPerSecond"

# --- K: the contracts, read back ------------------------------------------------
$contractsFile = Join-Path $work 'contracts.txt'
$contractsText = if (Test-Path $contractsFile) { [System.IO.File]::ReadAllText($contractsFile) } else { '' }
$contractsPass = $contractsText -match '(?m)^VERDICT: PASS'
Row 'signal_contracts' $(if ($contractsPass) { 'PASS' } else { 'FAIL' })
Require $contractsPass ('K: test/cap16/check_cap16_contracts.ps1 did not PASS - it runs before ' +
    'these gates and its record is build/cap16/contracts.txt')
$es = [regex]::Match($contractsText, '(?m)^eval_sites_release=(\d+)')
Row 'eval_sites_release' $(if ($es.Success) { $es.Groups[1].Value } else { 'missing' })
Require ($rows['eval_sites_release'] -eq '1') "K: eval_sites_release is $($rows['eval_sites_release']), not 1"

# --- S1: the headless suite ------------------------------------------------------
$suite = Join-Path $work "bin/cap16tests$exeSuffix"
$corpus = Join-Path $work 'signal-corpus.txt'
Remove-Item -Force $corpus -ErrorAction SilentlyContinue
Require (Test-Path $suite) "S1: $suite is missing - run build_cap16.ps1 first"
if (Test-Path $suite) {
    if ($IsWindows) { & $suite /noenter | Select-Object -Last 6 } else { & $suite | Select-Object -Last 6 }
    $suiteExit = $LASTEXITCODE
    Row 'signal_suite' $(if ($suiteExit -eq 0) { 'PASS' } else { 'FAIL' })
    Require ($suiteExit -eq 0) 'S1: the CAP-16 headless suite FAILED'
}
Require (Test-Path $corpus) 'S1: the suite wrote no decision corpus'
$corpusText = ''
if (Test-Path $corpus) {
    Row 'signal_corpus_digest' (Sha256File $corpus)
    Row 'signal_corpus_lines' "$(@(Get-Content $corpus).Count)"
    $corpusText = [System.IO.File]::ReadAllText($corpus)
}
function CorpusHas([string]$Line) { return $corpusText.Contains($Line) }
Row 'socket_receive_waitms' $(if ($contractsPass -and (CorpusHas 'socket|waitMs-25000|invalid_request|through-the-scheduler')) { 'removed' } else { 'PRESENT' })
Require ($rows['socket_receive_waitms'] -eq 'removed') 'S1/K: a receive still honours waitMs'
Row 'socket_no_parked_worker' (Bool (CorpusHas 'socket|8-quiet-sockets|host-defaults-4-4-32|0-in-flight|unrelated-invoke-under-5ms'))
Require ($rows['socket_no_parked_worker'] -eq 'true') 'S1: quiet sockets left an invocation in flight'
Row 'signal_subscribe_forbidden_zero_scripts' (Bool (CorpusHas 'subscribe|not-granted|forbidden|undeclared|forbidden|0-scripts'))
Row 'signal_coalescing' (Bool (CorpusHas 'coalescing|1000-signals|one-dispatch|one-script|one-pair-per-topic|last-seq|declaration-order'))
Row 'signal_revoke_race' (Bool (CorpusHas 'revoke|mid-flood|0-scripts-after-return|other-topic-kept|regrant-needs-resubscribe'))
Row 'signal_document_replacement' (Bool (CorpusHas 'document-replacing|subscriptions-and-queue-gone|other-window-kept|door-told-after'))
Row 'signal_window_isolation' (Bool (CorpusHas 'isolation|two-windows|own-topics-only|window-topic-one-window|per-window-seq'))
Row 'signal_hostile_literal' (Bool ((CorpusHas 'script|encoder|256-single-bytes|printable-ascii|u2028-u2029-escaped|invalid-utf8-replaced') -and
    (CorpusHas 'script|hostile|10-cases-plus-nul|structure-intact|value-exact')))
Row 'signal_hooks_outside_lock' (Bool (CorpusHas 'hooks|grants-document-drain|door-called-after-and-outside-the-lock'))
Row 'caller_principal_suite' (Bool ((CorpusHas 'caller|jobs-snapshot|2mib-log|blob-owned-by-caller|handle=token+url+size+type|bytes-exact') -and
    (CorpusHas 'caller|other-principal|same-answer-as-unknown') -and
    (CorpusHas 'caller|outside-a-call|refused|invalid-owner|nothing-created')))
foreach ($k in 'signal_subscribe_forbidden_zero_scripts', 'signal_coalescing', 'signal_revoke_race',
               'signal_document_replacement', 'signal_window_isolation', 'signal_hostile_literal',
               'signal_hooks_outside_lock', 'caller_principal_suite') {
    Require ($rows[$k] -eq 'true') "S1: the suite did not witness $k"
}
Row 'raw_primitive_used' $(if ($contractsPass) { 'false' } else { 'unproven' })
Require ($rows['raw_primitive_used'] -eq 'false') 'K: the live page uses the raw primitive, or the contracts did not run'

# --- E1: the engine ----------------------------------------------------------------
$probeBin = Join-Path $work "bin/evalprobe$exeSuffix"
$probeOut = Join-Path $work "evalprobe-$legId.json"
Remove-Item -Force $probeOut -ErrorAction SilentlyContinue
Require (Test-Path $probeBin) "E1: $probeBin is missing - run build_cap16.ps1 first"
if (Test-Path $probeBin) {
    & $probeBin
    Row 'evalprobe_exit' "$LASTEXITCODE"
    Require ($LASTEXITCODE -eq 0) 'E1: the engine probe reported a failure'
}
$probe = $null
if (Test-Path $probeOut) {
    $probe = Get-Content -Raw $probeOut | ConvertFrom-Json
} else {
    Require $false "E1: the engine probe wrote no $probeOut"
}
$page = Get-Field $probe 'page'
$nativeEvals = [int](Get-Field $probe 'native_evals')
$received = [int](Get-Field $page 'received')
Row 'eval_engine' "$(Get-Field $probe 'engine')"
Row 'eval_page_csp' "eval=$(Get-Field $page 'cspEval') function=$(Get-Field $page 'cspFunction') inline=$(Get-Field $page 'cspInline')"
Row 'eval_received' "$received/$nativeEvals"
$underCsp = ($null -ne $page) -and ("$(Get-Field $page 'cspEval')" -eq 'blocked') -and
    ("$(Get-Field $page 'cspFunction')" -eq 'blocked') -and ("$(Get-Field $page 'cspInline')" -eq 'blocked') -and
    ($nativeEvals -gt 0) -and ($received -eq $nativeEvals)
Row 'eval_under_csp' (Bool $underCsp)
Require $underCsp "E1: a native script did not run under PWEB_NATIVE_CSP while the page's own eval was refused ($($rows['eval_page_csp']), $($rows['eval_received']))"
function OrderWord($O) {
    if ($null -eq $O) { return 'missing' }
    if ([int](Get-Field $O 'count') -ne [int](Get-Field $probe 'k')) { return "incomplete_$(Get-Field $O 'count')" }
    if ((Get-Field $O 'inOrder') -eq $true) { return 'in_order' }
    return 'reordered'
}
$dispatchOrder = OrderWord (Get-Field $page 'dispatch')
$burstOrder = OrderWord (Get-Field $page 'burst')
# TYPED PER ENGINE, not gated on its answer: the sequence number is what the
# SDK trusts either way. What is gated is that every script arrived
Row 'eval_ordering' "dispatch=$dispatchOrder burst=$burstOrder"
Require ($dispatchOrder -in 'in_order', 'reordered' -and $burstOrder -in 'in_order', 'reordered') `
    "E1: an ordering row is not typed: $($rows['eval_ordering'])"
$hostileExact = [int](Get-Field $page 'hostileExact')
$hostileCases = [int](Get-Field $probe 'hostile_cases')
Row 'eval_hostile_exact' "$hostileExact/$hostileCases"
Row 'eval_hostile_ran' "$(Get-Field $page 'pwned')"
Require ($hostileCases -gt 0 -and $hostileExact -eq $hostileCases) "E1: a hostile topic did not arrive exactly ($($rows['eval_hostile_exact']))"
Require ("$(Get-Field $page 'pwned')" -eq 'False') 'E1: something a hostile topic spelled RAN'
Row 'eval_trusted_events' "$(Get-Field $page 'trustedEvents')"

# --- L1: the production host ----------------------------------------------------------
function Start-Witness([int]$Port, [string]$Log) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('node')
    foreach ($a in @('test/cap15c/ws_server.js', "--port=$Port", "--log=$Log",
                     '--stdin-shutdown', '--ttl=900')) {
        $psi.ArgumentList.Add($a)
    }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $repoRoot
    $p = [System.Diagnostics.Process]::Start($psi)
    $line = $p.StandardOutput.ReadLine()
    if ($line -notmatch 'listening') { throw "the witness on $Port did not start: $line" }
    return $p
}
# per-target ports: WSL2 forwards loopback
$port = if ($IsWindows) { 18766 } elseif ($IsMacOS) { 18786 } else { 18776 }
$liveBin = Join-Path $work "bin/signallive$exeSuffix"
$liveOut = Join-Path $work "live-$legId.json"
$verdict = Join-Path $work "live-verdict-$legId.txt"
Remove-Item -Force $liveOut, $verdict -ErrorAction SilentlyContinue
Require (Test-Path $liveBin) "L1: $liveBin is missing - run build_cap16.ps1 first"
if (Test-Path $liveBin) {
    $witness = Start-Witness $port (Join-Path $work "wire-live-$legId.jsonl")
    try {
        $env:PWEB_CAP16_WS_PORT = "$port"
        & $liveBin "--pweb-verdict=$verdict" '--pweb-autoclose-ms=120000'
        Row 'live_exit' "$LASTEXITCODE"
    } finally {
        Remove-Item Env:PWEB_CAP16_WS_PORT -ErrorAction SilentlyContinue
        try {
            $witness.StandardInput.Close()
            if (-not $witness.WaitForExit(5000)) { $witness.Kill() }
        } catch { }
    }
    Require ($rows['live_exit'] -eq '0') 'L1: the live program reported a failure'
}
$live = $null
if (Test-Path $liveOut) { $live = Get-Content -Raw $liveOut | ConvertFrom-Json }
Require ($null -ne $live) "L1: the live program wrote no $liveOut"
$lp = Get-Field $live 'page'
$features = @(Get-Field $lp 'features')
Row 'signal_channel_available' (Bool (($features -contains 'signal') -and ((Get-Field $lp 'tickArrived') -eq $true)))
Require ($rows['signal_channel_available'] -eq 'true') 'L1: the channel did not advertise itself or deliver a signal'
Row 'signal_latency_ms' "$(Get-Field $lp 'tickLatencyMs')"
Row 'signal_denied' "$(Get-Field $lp 'denied') scripts=$(Get-Field $lp 'deniedEvals')"
Require ($rows['signal_denied'] -eq 'forbidden scripts=0') "L1: a topic the window may not read was not refused with zero scripts: $($rows['signal_denied'])"
$flood = Get-Field $lp 'flood'
$floodEvals = [int](Get-Field $flood 'evals')
$floodMs = [int](Get-Field $flood 'durationMs')
$floodSent = [int](Get-Field $flood 'sent')
$eps = if ($floodMs -gt 0) { [math]::Round($floodEvals * 1000.0 / $floodMs, 3) } else { -1 }
Row 'signal_flood_sent' "$floodSent"
Row 'signal_flood_scripts' "$floodEvals"
Row 'signal_flood_evals_per_s' ([double]$eps).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
Require ($floodSent -ge 10000) "L1: the flood sent only $floodSent signals - the bound is not proven against a flood"
Require ($floodEvals -ge 1 -and $floodEvals * 1000 -le $floodMs * $ticksPerSecond) `
    "L1: $floodEvals scripts while the flood ran $floodMs ms - more than $ticksPerSecond a second"
Require ([int64](Get-Field $lp 'floodLastSeq') -eq $floodSent) 'L1: the page did not end the flood on its last sequence'
$ji = Get-Field $lp 'jitterIdle'
$jf = Get-Field $lp 'jitterFlood'
# AN OBSERVATION, not a gate: a 10 ms page timer's worst lateness at rest and
# under the flood, on this runner
Row 'gui_jitter_ms' "idle=$(Get-Field $ji 'maxLateMs') flood=$(Get-Field $jf 'maxLateMs')"
Row 'signal_revoke' "subscriptions=$(Get-Field (Get-Field $lp 'revoke') 'subsAfter') delivered_after=$(Get-Field $lp 'ticksAfterRevoke')"
Require ($rows['signal_revoke'] -eq 'subscriptions=0 delivered_after=0') "L1: a revocation did not stop delivery: $($rows['signal_revoke'])"
$resub = [int64](Get-Field $lp 'resubscribed')
$recovered = Get-Field $lp 'recovered'
Row 'signal_navigation' "subscriptions_after=$(Get-Field $lp 'subsAtPhase2') lost=$(Get-Field $recovered 'missed') recovered_seq=$(Get-Field $lp 'phase2Seq')"
Require ("$(Get-Field $lp 'subsAtPhase2')" -eq '0') 'L1: a replaced document kept a subscription'
Require ([int64](Get-Field $recovered 'missed') -eq 5 -and [int64](Get-Field $lp 'phase2Seq') -eq $resub + 5) `
    "L1: the signals lost across the reload were not recovered by the re-read: $($rows['signal_navigation'])"
Row 'socket_signal_echo' "$(Get-Field $lp 'socketEcho')"
Require ($rows['socket_signal_echo'] -eq 'cap16-echo') "L1: the socket did not echo through the migrated loop: $($rows['socket_signal_echo'])"
$blobOk = ([int](Get-Field $lp 'blobStatus') -eq 200) -and
    ([int64](Get-Field $lp 'blobBytes') -eq [int64](Get-Field $live 'blob_bytes')) -and
    ([int64](Get-Field $lp 'blobFnv') -eq [int64](Get-Field $live 'blob_fnv')) -and
    ([int](Get-Field (Get-Field $lp 'blobHandle') 'token') -eq 32)
Row 'caller_principal_blob' (Bool ($blobOk -and ($rows['caller_principal_suite'] -eq 'true')))
Require ($rows['caller_principal_blob'] -eq 'true') 'L1: a service blob for the caller was not read back by URL, byte for byte'
Row 'live_grants_slot_released' "$(Get-Field $live 'grants_slot_released')"
Require ("$(Get-Field $live 'grants_slot_released')" -eq 'True') 'L1: the host left the policy grants slot taken after its drain'

# --- X: the starvation rows the CAP-15C step measured -----------------------------------
$c15c = Join-Path $repoRoot "build/cap15c/cli-$target.json"
if ($IsMacOS) {
    Row 'starvation_n4_ms' 'not_applicable'
    Row 'starvation_n8_ms' 'not_applicable'
} elseif (-not (Test-Path $c15c)) {
    Row 'starvation_n4_ms' 'missing'
    Row 'starvation_n8_ms' 'missing'
    Require $false "X: $c15c is missing - the CAP-15C step runs before this one"
} else {
    $s = Get-Content -Raw $c15c | ConvertFrom-Json
    foreach ($n in 4, 8) {
        $v = "$(Get-Field $s "socket_starvation_n$n")"
        $m = [regex]::Match($v, '^served latency_ms=(\d+\.\d{3}) .* in_flight=0 ')
        Row "starvation_n${n}_ms" $(if ($m.Success) { $m.Groups[1].Value } else { 'unproven' })
        Require ($m.Success -and [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture) -lt 5.0) `
            "X: starvation at N=$n is not closed on this leg: '$v'"
    }
}

# --- C1: the Linux composition ----------------------------------------------------------------
$compFile = Join-Path $work 'composition-linux-x86_64.json'
$compKeys = 'signal_composition', 'signal_composition_updates', 'signal_composition_rpc_result',
    'signal_composition_listener_members', 'signal_composition_image_template',
    'signal_composition_image_dev_console', 'signal_composition_raw_primitive'
if ($IsLinux -and (Test-Path $compFile)) {
    $comp = Get-Content -Raw $compFile | ConvertFrom-Json
    foreach ($p in $comp.PSObject.Properties) { Row $p.Name "$($p.Value)" }
    Require ("$($comp.signal_composition)" -ceq 'PASS') 'C1: the signal composition smoke failed'
} elseif ($IsLinux) {
    Row 'signal_composition' 'FAIL'
    Require $false 'C1: the signal composition smoke left no record - test/cap16/prove_cap16_composition.sh runs before this gate on Linux'
} else {
    foreach ($k in $compKeys) { Row $k 'not_applicable' }
}

# --- evidence ------------------------------------------------------------------------------
Row 'cap16_failures' "$($failures.Count)"
$out = Join-Path $work "cli-$target.json"
$rows | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 $out
Write-Host "[CAP-16] $($rows.Count) rows -> $out"
foreach ($k in 'eval_sites_release', 'eval_under_csp', 'eval_ordering', 'signal_flood_evals_per_s',
               'gui_jitter_ms', 'starvation_n4_ms', 'starvation_n8_ms', 'socket_receive_waitms',
               'socket_no_parked_worker', 'caller_principal_blob', 'raw_primitive_used') {
    Write-Host ("[CAP-16] {0} = {1}" -f $k, $rows[$k])
}
if ($failures.Count -gt 0) {
    Write-Host "[CAP-16] FAILED: $($failures.Count) gate failure(s)"
    exit 1
}
Write-Host '[CAP-16] PASS'
