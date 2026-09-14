# CAP-15C: the native socket door, gated.
#
# The door: `pweb.socketOpen | socketSend | socketReceive | socketClose`
# behind the `network.socket` capability and the SAME native origin
# allowlist the fetch door is compiled with, with `PWEB_NATIVE_CSP`
# unchanged - `connect-src` still `'self'`, byte for byte.
#
#   S1   the headless suite: every contract row through the INJECTED
#        transport, with the transport ENTRY COUNT asserted on each refusal,
#        and the decision corpus hashed so the four targets can be compared
#   L1   the SHIPPED transport through the REAL decorator against
#        test/cap15c/ws_server.js, whose JSONL log is the independent witness:
#        interop with a server that is not mORMot, the refused 3xx, TLS
#        validation, the message and reassembly bounds, both wall-clock
#        deadlines, backpressure with nothing dropped, the idle bound,
#        revocation, document replacement and shutdown before the drain
#
# Emits build/cap15c/cli-<target>.json for the CAP-7F aggregation.
#
# Usage: pwsh test/cap15c/run_cap15c_gates.ps1 [-Public wss://echo.websocket.org]
param([string]$Public = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap15c'
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
$target = TargetName
Row 'target' $target

# --- S1: the headless suite ---------------------------------------------------
$suite = Join-Path $work "bin/cap15ctests$exeSuffix"
Require (Test-Path $suite) "S1: $suite is missing - run build_cap15c.ps1 first"
$corpus = Join-Path $work 'socket-corpus.txt'
Remove-Item -Force $corpus -ErrorAction SilentlyContinue
if ($IsWindows) { & $suite /noenter | Select-Object -Last 4 } else { & $suite | Select-Object -Last 4 }
Row 'suite_exit' "$LASTEXITCODE"
Row 'socket_suite' $(if ("$($rows['suite_exit'])" -eq '0') { 'PASS' } else { 'FAIL' })
Require ($LASTEXITCODE -eq 0) 'S1: the CAP-15C headless suite failed'
Require (Test-Path $corpus) 'S1: the suite wrote no decision corpus'
if (Test-Path $corpus) {
    Row 'socket_corpus_digest' (Sha256File $corpus)
    Row 'socket_corpus_lines' "$(@(Get-Content $corpus).Count)"
}

# --- L1: the shipped transport, live --------------------------------------------
$tls = Join-Path $work 'tls'
if (-not (Test-Path "$tls/cert.pem")) {
    New-Item -ItemType Directory -Force $tls | Out-Null
    & openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tls/key.pem" `
        -out "$tls/cert.pem" -days 30 -subj '/CN=127.0.0.1' `
        -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'openssl could not make the loopback certificate' }
}

function Start-Witness([int]$Port, [string]$Log, [string[]]$Extra) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('node')
    foreach ($a in @('test/cap15c/ws_server.js', "--port=$Port", "--log=$Log",
                     '--stdin-shutdown', '--ttl=900') + $Extra) {
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

# per-target ports: WSL2 forwards loopback, so a Linux run and a Windows run
# on one port could answer each other
$port = if ($IsWindows) { 18761 } elseif ($IsMacOS) { 18781 } else { 18771 }
$tlsPort = $port + 1
$plainLog = Join-Path $work "wire-live-$target.jsonl"
$tlsLog = Join-Path $work "wire-live-tls-$target.jsonl"
$liveOut = Join-Path $work "live-$target.json"
Remove-Item -Force $liveOut -ErrorAction SilentlyContinue
$plain = Start-Witness $port $plainLog @()
$secure = Start-Witness $tlsPort $tlsLog @("--tls-cert=$tls/cert.pem", "--tls-key=$tls/key.pem")
# THE TLS NAME ROWS, Linux only. OpenSSL verifies a certificate's NAME only
# when the transport hands it one, and that was MEASURED missing: a trusted
# certificate issued for another host opened a wss socket. The witness pair
# is trusted through OpenSSL's own SSL_CERT_FILE, scoped to the socketlive
# process below - a hermetic trust that SChannel and NSURLSession have no
# equivalent of, which is why the rows run on Linux and are typed per target
$rightProc = $null
$wrongProc = $null
$nameLogRight = Join-Path $work "wire-live-tls-right-$target.jsonl"
$nameLogWrong = Join-Path $work "wire-live-tls-wrong-$target.jsonl"
if ($IsLinux) {
    foreach ($pair in @(@('right', '/CN=127.0.0.1', 'subjectAltName=IP:127.0.0.1,DNS:127.0.0.1'),
                        @('wrong', '/CN=wrong.example', 'subjectAltName=DNS:wrong.example'))) {
        & openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tls/$($pair[0])-key.pem" `
            -out "$tls/$($pair[0])-cert.pem" -days 2 -subj $pair[1] -addext $pair[2] 2>$null
        if ($LASTEXITCODE -ne 0) { throw "openssl could not make the $($pair[0])-name certificate" }
    }
    Set-Content -NoNewline -Path "$tls/trusted-bundle.pem" -Value (
        (Get-Content -Raw "$tls/right-cert.pem") + (Get-Content -Raw "$tls/wrong-cert.pem"))
    Remove-Item -Force $nameLogRight, $nameLogWrong -ErrorAction SilentlyContinue
    $rightProc = Start-Witness ($port + 3) $nameLogRight @("--tls-cert=$tls/right-cert.pem", "--tls-key=$tls/right-key.pem")
    $wrongProc = Start-Witness ($port + 4) $nameLogWrong @("--tls-cert=$tls/wrong-cert.pem", "--tls-key=$tls/wrong-key.pem")
}
try {
    $liveArgs = @("--port=$port", "--tls-port=$tlsPort", "--out=$liveOut")
    if ($Public -ne '') { $liveArgs += "--public=$Public" }
    if ($IsLinux) {
        $liveArgs += @("--trusted-right-port=$($port + 3)", "--trusted-wrong-port=$($port + 4)")
        $env:SSL_CERT_FILE = "$tls/trusted-bundle.pem"
    }
    & (Join-Path $work "bin/socketlive$exeSuffix") @liveArgs
    $liveExit = $LASTEXITCODE
}
finally {
    if ($IsLinux) { Remove-Item Env:SSL_CERT_FILE -ErrorAction SilentlyContinue }
    foreach ($p in @($plain, $secure, $rightProc, $wrongProc)) {
        if ($null -eq $p) { continue }
        try {
            $p.StandardInput.Close()
            if (-not $p.WaitForExit(5000)) { $p.Kill() }
        } catch { }
    }
}
Row 'live_exit' "$liveExit"
Require ($liveExit -eq 0) 'L1: the live socket program reported a failure'
Require (Test-Path $liveOut) 'L1: the live socket program wrote no evidence'
if (Test-Path $liveOut) {
    $live = Get-Content $liveOut -Raw | ConvertFrom-Json -AsHashtable
    foreach ($k in $live.Keys) { Row $k $live[$k] }
}

$wire = @(Get-Content $plainLog | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json })
$rowOf = @{}
foreach ($w in $wire) {
    if ($w.kind -eq 'upgrade') {
        $rowOf["$($w.id)"] = if ($w.url -match 'row=([a-z0-9_]+)') { $Matches[1] } else { '(none)' }
    }
}
function Of([string]$RowName) {
    return @($wire | Where-Object { $null -ne $_.id -and $rowOf["$($_.id)"] -eq $RowName })
}
function First([object[]]$Items, [string]$Name) {
    return @($Items | Where-Object { $_.event -eq $Name -or $_.kind -eq $Name }) | Select-Object -First 1
}
$upgrades = @($wire | Where-Object { $_.kind -eq 'upgrade' })

# the handshake, as the server saw it
$hs = First (Of 'l_handshake') 'upgrade'
Require ($null -ne $hs) 'L1: the witness never saw the handshake'
if ($hs) {
    Row 'wire_handshake_header_names' ($hs.headerNames -join ',')
    Row 'wire_handshake_user_agent' "$($hs.headers.'user-agent')"
    Row 'wire_handshake_authorization' (Bool ($null -ne $hs.headers.authorization))
    Require ("$($hs.headers.'user-agent')" -eq 'PWeb') 'L1: the handshake published a User-Agent other than PWeb'
    Require ($null -ne $hs.headers.authorization) 'L1: an allowlisted authorization header did not reach the handshake'
    Require ($null -eq $hs.headers.'content-length') 'L1: the handshake GET carried a Content-Length'
}
$origins = @($upgrades | Where-Object { $null -ne $_.headers.origin }).Count
$cookies = @($upgrades | Where-Object { $null -ne $_.headers.cookie }).Count
$proxies = @($upgrades | Where-Object { ($_.headerNames -join ',') -match 'Proxy' }).Count
Row 'wire_origin_headers' "$origins"
Row 'wire_cookie_headers' "$cookies"
Row 'wire_proxy_headers' "$proxies"
Require ($origins -eq 0) 'L1: a handshake carried an Origin header'
Require ($cookies -eq 0) 'L1: a handshake carried a Cookie - including after a Set-Cookie'
Require ($proxies -eq 0) 'L1: a handshake carried a proxy header'

# a 3xx is refused and never followed
$redirectHits = @($upgrades | Where-Object { $rowOf["$($_.id)"] -like 'l_redirect*' }).Count
$followed = @($upgrades | Where-Object { $_.url -match 'from=redirect' }).Count
Row 'handshake_redirect_hits' "$redirectHits"
Row 'handshake_redirects_followed' "$followed"
Require ($followed -eq 0) 'L1: a handshake redirect was FOLLOWED'
Require ("$($rows['live_redirect'])" -eq 'service_error:handshake_refused:redirect') 'L1: a 3xx handshake was not refused as a redirect'

# every client frame masked; the page never pinged
$unmasked = @($wire | Where-Object { $_.event -eq 'client_frame_unmasked' }).Count
$clientPings = @($wire | Where-Object { $_.event -eq 'client_ping' }).Count
Row 'wire_unmasked_client_frames' "$unmasked"
Row 'wire_client_initiated_pings' "$clientPings"
Require ($unmasked -eq 0) 'L1: a client frame reached the wire unmasked'
Require ($clientPings -eq 0) 'L1: the client sent a ping of its own'

# the server's ping was answered with its own payload
$pong = First (Of 'l_ping') 'client_pong'
Row 'wire_pong_payload' "$(if ($pong) { $pong.payload } else { 'none' })"
Require ($pong -and $pong.payload -eq 'probe-1') 'L1: the server ping was not answered natively'

# the page's close reached the wire with its code and reason
$pc = First (Of 'l_handshake') 'client_close'
Row 'wire_page_close' "$(if ($pc) { "$($pc.code)/$($pc.reason)" } else { 'none' })"
Require ($pc -and $pc.code -eq 4000 -and $pc.reason -eq 'done') 'L1: the page close did not reach the wire as 4000/done'

# BACKPRESSURE: reading stopped - the server's writes were blocked for most of
# the three seconds the page did not poll - and nothing was dropped
$fd = First (Of 'l_flood') 'flood_done'
Row 'wire_flood_sent' "$(if ($fd) { $fd.sent } else { 'none' })"
Row 'wire_flood_longest_block_ms' "$(if ($fd) { $fd.longestBlockMs } else { 'none' })"
Require ($fd -and $fd.sent -eq 1024) 'L1: the flood did not complete'
Require ($fd -and $fd.longestBlockMs -ge 2000) 'L1: the server was never blocked for the stall - reading did not stop'
$fm = First (Of 'l_flood') 'flood_client_message'
Row 'wire_flood_page_message_at_sent' "$(if ($fm) { $fm.floodSent } else { 'none' })"
Require ($fm -and $fm.floodSent -lt 1024) 'L1: a page send did not reach the wire while reading had stopped'
Row 'backpressure_no_drop' (Bool (("$($rows['live_bp_received'])" -eq '1024') -and ("$($rows['live_bp_gaps'])" -eq '0') -and ("$($rows['live_bp_corrupt'])" -eq '0')))
Require ($rows['backpressure_no_drop'] -eq 'true') 'L1: a message was dropped, reordered or corrupted under backpressure'

# the reassembly bound: the server stopped being read long before 64 MiB
$cf = First (Of 'l_contflood') 'contflood_sent'
Row 'wire_contflood_sent_bytes' "$(if ($cf) { $cf.total } else { 'none' })"
Require ($cf -and $cf.closed -eq $true -and $cf.total -lt 67108864) 'L1: a 64 MiB reassembly was read to the end'

# the natively decided closes, all 1001 on the wire
foreach ($n in 'l_idle', 'l_revoke', 'l_navigation', 'l_drain_a', 'l_drain_b') {
    $c = First (Of $n) 'client_close'
    Row "wire_${n}_close" "$(if ($c) { $c.code } else { 'none' })"
    Require ($c -and $c.code -eq 1001) "L1: $n did not close with 1001 on the wire"
}
Row 'idle_close_typed' (Bool ("$($rows['live_idle_category'])" -eq 'idle'))
Row 'revoke_closes_all' (Bool (("$($rows['live_revoke_open_after_call'])" -eq '0') -and ("$($rows['live_revoke_send_after'])" -eq 'service_error:socket_not_found')))
Row 'close_on_navigation' (Bool ("$($rows['live_navigation_send_after'])" -eq 'service_error:socket_not_found'))
Require ($rows['idle_close_typed'] -eq 'true') 'L1: the idle close was not typed idle'
Require ($rows['revoke_closes_all'] -eq 'true') 'L1: revocation did not close the socket before the revoking call returned'
Require ($rows['close_on_navigation'] -eq 'true') 'L1: document replacement did not close the socket'

# TLS validation: the self-signed witness saw no upgrade at all
$tlsWire = @(Get-Content $tlsLog | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json })
$tlsUpgrades = @($tlsWire | Where-Object { $_.kind -eq 'upgrade' }).Count
Row 'wire_tls_upgrades' "$tlsUpgrades"
Require ($tlsUpgrades -eq 0) 'L1: an untrusted certificate reached an HTTP upgrade'

# TLS NAME VERIFICATION, typed per target. On Linux it is MEASURED: the
# control (a trusted certificate naming 127.0.0.1) must open, and a trusted
# certificate naming another host must be refused before any HTTP upgrade.
if ($IsLinux) {
    $right = "$($rows['live_tls_trusted_right_name'])"
    $wrong = "$($rows['live_tls_trusted_wrong_name'])"
    $wrongWire = @()
    if (Test-Path $nameLogWrong) {
        $wrongWire = @(Get-Content $nameLogWrong | Where-Object { $_ -ne '' } |
            ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.kind -eq 'upgrade' })
    }
    Row 'wire_tls_wrong_name_upgrades' "$($wrongWire.Count)"
    Require ($right -eq 'success') ("L1: the trusted right-name control did not open ($right) - " +
        'without it the wrong-name refusal proves nothing')
    Require ($wrong -eq 'service_error:tls_failed') ("L1: a trusted certificate naming ANOTHER host " +
        "was answered $wrong, not service_error:tls_failed")
    Require ($wrongWire.Count -eq 0) 'L1: a certificate naming another host reached an HTTP upgrade'
    Row 'tls_name_verification' $(if (($right -eq 'success') -and ($wrong -eq 'service_error:tls_failed') -and ($wrongWire.Count -eq 0)) {
        'measured_wrong_name_refused' } else { 'VIOLATED' })
} elseif ($IsWindows) {
    Row 'tls_name_verification' 'schannel_automatic_validation_against_target_name'
} else {
    Row 'tls_name_verification' 'nsurlsession_default_server_trust_evaluation'
}

Row 'raw_frame_standard_server' (Bool (("$($rows['live_echo_text'])" -eq 'true') -and ("$($rows['live_echo_binary'])" -eq 'true') -and ("$($rows['live_echo_1mib'])" -eq 'true') -and ("$($rows['live_fragment_text_sha'])" -eq 'true')))
Require ($rows['raw_frame_standard_server'] -eq 'true') 'L1: raw-frame interop with a standard server did not hold'

# --- the rows the SUITE decided, read back from its corpus ---------------------
#
# Some rows no live exchange can make honestly - ownership across two
# principals, the authority rule over every scheme and port trick, the
# window-closed seam. The headless suite writes each corpus line only after
# the assertions behind it held, so the line IS the row's witness.
$corpusText = if (Test-Path $corpus) { [System.IO.File]::ReadAllText($corpus) } else { '' }
function CorpusHas([string]$Line) { return $corpusText.Contains($Line) }
Row 'principal_isolation' (Bool (CorpusHas 'ownership|foreign-send-receive-close|socket_not_found|same-as-unknown|0-transport'))
Require ($rows['principal_isolation'] -eq 'true') 'S1: a second principal could reach a socket it does not own'
$authority = (CorpusHas 'url|wss://api.example.com:443|open|target=/') -and
    (CorpusHas 'url|wss://api.example.com:8443/feed|invalid_request|opens=0') -and
    (CorpusHas 'url|ws://api.example.com/feed|invalid_request|opens=0') -and
    (CorpusHas 'url|wss://api.example.com.evil.example/feed|invalid_request|opens=0') -and
    (CorpusHas 'url|ws://127.0.0.1:5173/hmr|open|dev-loopback') -and
    (CorpusHas 'url|release-allowlist|ws://127.0.0.1:5173/hmr|invalid_request|opens=0')
Row 'wss_authority_rule' $(if ($authority) { 'https_origin_authorises_wss_by_parsed_components;http_loopback_origin_authorises_ws;default_ports_canonical' } else { 'VIOLATED' })
Require $authority 'S1: the wss authority rule did not hold on every scheme, port and host row'
Row 'frame_bound_both_directions' (Bool ((CorpusHas 'send|text-over-1mib|invalid_request|sends=0') -and (CorpusHas 'close|message_too_large|1009')))
Require ($rows['frame_bound_both_directions'] -eq 'true') 'S1: the 1 MiB message bound is not enforced in both directions'
Row 'sockets_per_host_bound' (Bool (CorpusHas 'limit|fifth-socket|socket_limit|opens=4'))
Require ($rows['sockets_per_host_bound'] -eq 'true') 'S1: a fifth socket was opened'
Row 'socket_policy_absent_forbidden' (Bool ((CorpusHas 'policy|absent-from-appmaximum|forbidden|opens=0') -and (CorpusHas 'policy|fetch-only|socket-open|forbidden|opens=0')))
Require ($rows['socket_policy_absent_forbidden'] -eq 'true') 'S1: a principal without network.socket reached the door'

# A DEVELOPMENT GENERATION SWITCH IS A TRUSTED RE-NAVIGATION. The dev host
# publishes a generation through `PWebHostRequestReload`, which dispatches
# `webview_navigate(PWEB_HOST_ORIGIN)`; that navigation is classified like any
# other, and a trusted document verdict calls the one hook that closes the
# window's sockets. The row is the conjunction of its witnesses: the contract
# gate pins the reload path and the hook placement (K8), the suite pins the
# seam closing exactly that window's sockets, and L1 pins the shipped
# transport putting 1001 on the wire for it. On Linux the composition smoke
# adds the fourth: a real window's reload closing a real socket.
$contractsFile = Join-Path $work 'contracts.txt'
$contractsPass = (Test-Path $contractsFile) -and
    ([System.IO.File]::ReadAllText($contractsFile) -match '(?m)^VERDICT: PASS')
Row 'close_on_generation_switch' (Bool ($contractsPass -and
    (CorpusHas 'lifecycle|document-replacing|window-closed|other-window-untouched') -and
    ("$($rows['close_on_navigation'])" -eq 'true')))
Require ($rows['close_on_generation_switch'] -eq 'true') ('a generation switch is not proven to close the ' +
    'window''s sockets - test/cap15c/check_cap15c_contracts.ps1 runs before these gates and must PASS')

# --- B1-B4: the socket door in a BUILT IMAGE ----------------------------------
. (Join-Path $repoRoot 'test/cap15c/hostproofs.ps1')
Invoke-Cap15cHostProofs -RepoRoot $repoRoot -Work $work -Rows $rows -Failures $failures

# --- B5: the bundler refuses a socket field in app.pwb --------------------------
$bundler = Join-Path $work "bin/pwebbundle$exeSuffix"
Require (Test-Path $bundler) 'B5: the bundler is not built - run build_cap15c.ps1 first'
if (Test-Path $bundler) {
    $dist = Join-Path $work 'bundle-dist'
    Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $dist 'data') | Out-Null
    Set-Content -NoNewline -Path (Join-Path $dist 'index.html') `
        -Value "<!doctype html><html><head><title>t</title></head><body></body></html>`n"
    # NESTED application data with a socket-shaped key is not a manifest
    Set-Content -NoNewline -Path (Join-Path $dist 'data/config.json') `
        -Value "{`"socket`":`"application data, not a manifest`"}`n"
    $clean = Join-Path $work 'clean.pwb'
    Remove-Item -Force $clean -ErrorAction SilentlyContinue
    & $bundler $dist $clean 2>&1 | Out-Null
    $cleanOk = ($LASTEXITCODE -eq 0)
    Row 'bundler_nested_socket_field_accepted' (Bool $cleanOk)
    Require $cleanOk 'B5: the bundler refused nested application data'
    $allRefused = $true
    foreach ($field in 'socket', 'sockets', 'websocket', 'ws', 'wss') {
        Set-Content -NoNewline -Path (Join-Path $dist 'app.json') `
            -Value "{`"name`":`"x`",`"$field`":[`"wss://evil.example`"]}`n"
        $outPwb = Join-Path $work "refused-$field.pwb"
        Remove-Item -Force $outPwb -ErrorAction SilentlyContinue
        $bundlerOut = (& $bundler $dist $outPwb 2>&1 | Out-String)
        $refused = ($LASTEXITCODE -ne 0) -and ($bundlerOut -match 'network_field_in_bundle') -and
            (-not (Test-Path $outPwb))
        if (-not $refused) { $allRefused = $false }
        Require $refused "B5: the bundler accepted a '$field' field in app.pwb"
        Remove-Item -Force (Join-Path $dist 'app.json') -ErrorAction SilentlyContinue
    }
    Row 'bundler_refuses_socket_field' (Bool $allRefused)
}

# --- C1: the composition, mechanised once on the Linux leg ------------------------
#
# test/cap15c/prove_cap15c_composition.sh is the day-one path for the socket
# door - create, declare an origin, build, run, and the page opens a socket
# through @pweb/runtime. Linux-only on purpose, for the CAP-15B reason; every
# other target emits `not_applicable`, which is a VALUE.
$compFile = Join-Path $work 'composition-linux-x86_64.json'
if ($IsLinux -and (Test-Path $compFile)) {
    $comp = Get-Content -Raw $compFile | ConvertFrom-Json
    foreach ($p in $comp.PSObject.Properties) { Row $p.Name "$($p.Value)" }
    Require ("$($comp.socket_composition)" -ceq 'PASS') 'C1: the socket composition smoke failed'
} elseif ($IsLinux) {
    Row 'socket_composition' 'FAIL'
    Require $false ('C1: the socket composition smoke left no record - ' +
        'test/cap15c/prove_cap15c_composition.sh runs before this gate on Linux')
} else {
    foreach ($k in 'socket_composition', 'socket_composition_open', 'socket_composition_echo',
                   'socket_composition_navigation_close', 'socket_composition_shutdown_close',
                   'socket_composition_rpc_ok') {
        Row $k 'not_applicable'
    }
    foreach ($k in 'socket_composition_rpc_result', 'socket_composition_listener_members',
                   'socket_composition_client_sockets') {
        Row $k '0'
    }
}

# --- the seven Darwin rows, typed where they are not measured -------------------
#
# socketlive writes them on macOS only, READ BACK from the task and its
# session. Every other target says `not_applicable` by name, so a macOS leg
# that silently stopped writing them could not pass for one that never had to.
if (-not $IsMacOS) {
    foreach ($k in 'darwin_socket_opens', 'darwin_socket_redirects_offered',
                   'darwin_socket_proxy_dict_empty', 'darwin_socket_cookie_storage_nil',
                   'darwin_socket_should_set_cookies', 'darwin_socket_open_on_main_thread',
                   'darwin_socket_maximum_message_size') {
        Row $k 'not_applicable'
    }
}

# --- evidence -------------------------------------------------------------------
Row 'cap15c_failures' "$($failures.Count)"
$out = Join-Path $work "cli-$target.json"
$rows | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 $out
Write-Host "[CAP-15C] $($rows.Count) rows -> $out"
if ($failures.Count -gt 0) {
    Write-Host "[CAP-15C] FAILED: $($failures.Count) gate failure(s)"
    exit 1
}
Write-Host '[CAP-15C] PASS'
