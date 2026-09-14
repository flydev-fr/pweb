# CAP-15C Checkpoint 1: two candidate WebSocket transports, one row suite,
# and a server that is not mORMot, with that server's log as the witness.
#
# This is a MEASUREMENT RUN, not a gate. It builds test/cap15c/wsspike.pas,
# starts two instances of test/cap15c/ws_server.js - plain ws under the
# PWEB_DEV loopback rule, and wss on a self-signed loopback certificate that
# a client with validation ON must refuse - runs the spike once PER TRANSPORT
# in its OWN process (so each transport's peak-memory rows start from its own
# baseline, not from the other's high-water mark), stops both servers through
# their stdin so their logs are flushed rather than killed, and joins the
# spike's rows with what the server actually saw on the wire.
#
#   m.*   mORMot's THttpClientWebSockets in raw-frame mode (the brief's shape)
#   r.*   RFC 6455 framing written over mormot.net.sock's TCrtSocket
#
# Output: build/cap15c/<leg>/spike-<target>.json
#
# Usage: pwsh test/cap15c/run_cap15c_spike.ps1 [-Public wss://echo.websocket.org]
#
# -Public is an OBSERVATION and never a gate: one live wss round trip to a
# public echo endpoint per transport, recorded as what it returned.
param([string]$Public = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x86_64' }
    'Arm64' { 'arm64' }
    default { 'other' }
}
$target = "$os-$arch"
$leg = if ($IsWindows) { 'win' } else { $os }
$work = "build/cap15c/$leg"
New-Item -ItemType Directory -Force "$work/units", "$work/bin" | Out-Null

# --- build ------------------------------------------------------------------
$static = if ($IsWindows) { 'deps/mormot2/static/x86_64-win64' }
    elseif ($IsMacOS) {
        if ($arch -eq 'arm64') { 'deps/mormot2/static/aarch64-darwin' }
        else { 'deps/mormot2/static/x86_64-darwin' }
    }
    else { 'deps/mormot2/static/x86_64-linux' }
$fpcArgs = @('-MObjFPC', '-Sh', "-FU$work/units", "-FE$work/bin",
    '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
    '-Fudeps/mormot2/src/net', "-Fl$static")
if ($IsWindows) { $fpcArgs = @('-Px86_64', '-Twin64') + $fpcArgs }
Write-Host "[CAP-15C] compiling test/cap15c/wsspike.pas for $target"
& fpc @fpcArgs 'test/cap15c/wsspike.pas' | Select-Object -Last 2
if ($LASTEXITCODE -ne 0) { throw 'wsspike compile FAILED' }
$exe = Join-Path $work ('bin/wsspike' + $(if ($IsWindows) { '.exe' } else { '' }))

# --- tls material: a self-signed loopback certificate -------------------------
$tls = 'build/cap15c/tls'
if (-not (Test-Path "$tls/cert.pem")) {
    New-Item -ItemType Directory -Force $tls | Out-Null
    & openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tls/key.pem" `
        -out "$tls/cert.pem" -days 30 -subj '/CN=127.0.0.1' `
        -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'openssl could not make the loopback certificate' }
}

# --- the witnesses ------------------------------------------------------------
function Start-Witness([int]$Port, [string]$Log, [string[]]$Extra) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('node')
    foreach ($a in @('test/cap15c/ws_server.js', "--port=$Port", "--log=$Log",
                     '--stdin-shutdown', '--ttl=1800') + $Extra) {
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

# distinct ports per leg: WSL2 forwards loopback to Windows, so a Linux run and
# a Windows run listening on one port could answer each other
$port = if ($IsWindows) { 18741 } else { 18751 }
$tlsPort = $port + 1
$plainLog = "$work/wire-plain.jsonl"
$tlsLog = "$work/wire-tls.jsonl"
$plain = Start-Witness $port $plainLog @()
$secure = Start-Witness $tlsPort $tlsLog @("--tls-cert=$tls/cert.pem", "--tls-key=$tls/key.pem")
$exits = [ordered]@{}
try {
    foreach ($t in 'raw', 'mormot') {
        $spikeArgs = @("--transport=$t", "--port=$port", "--tls-port=$tlsPort",
            "--out=$work/spike-rows-$t.json")
        if ($Public -ne '') { $spikeArgs += "--public=$Public" }
        & $exe @spikeArgs
        $exits[$t] = "$LASTEXITCODE"
    }
}
finally {
    foreach ($p in @($plain, $secure)) {
        try {
            $p.StandardInput.Close()
            if (-not $p.WaitForExit(5000)) { $p.Kill() }
        } catch { }
    }
}

# --- join the spike's rows with the wire ---------------------------------------
$rows = [ordered]@{ target = $target; 'r.spike_exit' = $exits['raw']; 'm.spike_exit' = $exits['mormot'] }
foreach ($t in 'raw', 'mormot') {
    $spike = Get-Content "$work/spike-rows-$t.json" -Raw | ConvertFrom-Json -AsHashtable
    foreach ($k in $spike.Keys) { $rows[$k] = $spike[$k] }
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

foreach ($pair in @(@('r_', 'r.'), @('m_', 'm.'))) {
    $tag = $pair[0]
    $k = $pair[1]
    $ups = @($wire | Where-Object { $_.kind -eq 'upgrade' -and $rowOf["$($_.id)"] -like "$tag*" })
    $rows["${k}wire_upgrades"] = "$($ups.Count)"
    $rows["${k}wire_any_origin_header"] = "$(@($ups | Where-Object { $null -ne $_.headers.origin }).Count)"
    $rows["${k}wire_any_cookie_header"] = "$(@($ups | Where-Object { $null -ne $_.headers.cookie }).Count)"
    $rows["${k}wire_any_proxy_header"] = "$(@($ups | Where-Object { ($_.headerNames -join ',') -match 'Proxy' }).Count)"
    $ids = @($ups | ForEach-Object { "$($_.id)" })
    $rows["${k}wire_unmasked_client_frames"] = "$(@($wire | Where-Object { $_.event -eq 'client_frame_unmasked' -and $ids -contains "$($_.id)" }).Count)"
    $rows["${k}wire_client_initiated_pings"] = "$(@($wire | Where-Object { $_.event -eq 'client_ping' -and $ids -contains "$($_.id)" }).Count)"

    $hs = First (Of "${tag}handshake") 'upgrade'
    if ($hs) {
        $rows["${k}wire_hs_header_names"] = ($hs.headerNames -join ',')
        $rows["${k}wire_hs_authorization_forwarded"] = "$($null -ne $hs.headers.authorization)"
        $rows["${k}wire_hs_custom_x_header_forwarded"] = "$($null -ne $hs.headers.'x-spike-row')"
        $rows["${k}wire_hs_offered_protocol_header"] = "$($hs.headers.'sec-websocket-protocol')"
        $rows["${k}wire_hs_content_length_header"] = "$($hs.headers.'content-length')"
        $rows["${k}wire_hs_user_agent"] = "$($hs.headers.'user-agent')"
    }
    $c = First (Of "${tag}handshake") 'client_close'
    if ($c) { $rows["${k}wire_hs_client_close"] = "$($c.code)/$($c.reason)" }
    $m = @(Of "${tag}handshake" | Where-Object { $_.event -eq 'client_message' })
    $rows["${k}wire_hs_client_message_lengths"] = (($m | ForEach-Object { $_.len }) -join ',')

    $rows["${k}wire_redirect_hits"] = "$(@(Of "${tag}redirect" | Where-Object { $_.kind -eq 'upgrade' }).Count)"
    $e = First (Of "${tag}server_close") 'close_echo'
    if ($e) { $rows["${k}wire_server_close_echo_code"] = "$($e.code)" }
    $pp = First (Of "${tag}ping") 'client_pong'
    if ($pp) { $rows["${k}wire_ping_pong_payload"] = "$($pp.payload)" }
    $rows["${k}wire_fragment_ping_events"] = ((Of "${tag}fragment_ping" | ForEach-Object { if ($_.event) { $_.event } else { $_.kind } }) -join ',')

    $fb = First (Of "${tag}flood") 'flood_first_block'
    if ($fb) {
        $rows["${k}wire_flood_first_block_after_ms"] = "$($fb.afterMs)"
        $rows["${k}wire_flood_first_block_seq"] = "$($fb.seq)"
        $rows["${k}wire_flood_first_block_bytes_written"] = "$($fb.bytesWritten)"
    }
    $fd = First (Of "${tag}flood") 'flood_done'
    if ($fd) {
        $rows["${k}wire_flood_sent"] = "$($fd.sent)"
        $rows["${k}wire_flood_blocks"] = "$($fd.blocks)"
        $rows["${k}wire_flood_longest_block_ms"] = "$($fd.longestBlockMs)"
        $rows["${k}wire_flood_ms"] = "$($fd.ms)"
    }
    $fm = First (Of "${tag}flood") 'flood_client_message'
    if ($fm) { $rows["${k}wire_flood_client_message_at_sent"] = "$($fm.floodSent)" }
    $fr = First (Of "${tag}flood_release_parked") 'flood_done'
    if ($fr) { $rows["${k}wire_flood_release_parked_sent"] = "$($fr.sent)/closed=$($fr.closed)" }

    $ic = First (Of "${tag}idle") 'client_close'
    if ($ic) { $rows["${k}wire_idle_client_close"] = "$($ic.code) after $($ic.afterMs) ms" }
    foreach ($n in 'noack_explicit', 'noack_implicit', 'idle', 'flood_release_parked', 'noread') {
        $x = First (Of "${tag}$n") 'client_close'
        $pe = First (Of "${tag}$n") 'tcp_peer_end'
        $t = First (Of "${tag}$n") 'tcp_closed'
        $rows["${k}wire_${n}_close_code"] = if ($x) { "$($x.code)" } else { 'none' }
        $rows["${k}wire_${n}_tcp_peer_end_after_ms"] = if ($pe) { "$($pe.afterMs)" } else { 'none' }
        $rows["${k}wire_${n}_tcp_closed_after_ms"] = if ($t) { "$($t.afterMs)" } else { 'open' }
    }
    $cf = First (Of "${tag}contflood") 'contflood_sent'
    if ($cf) { $rows["${k}wire_contflood_sent_total"] = "$($cf.total)"; $rows["${k}wire_contflood_closed_early"] = "$($cf.closed)" }
    $bo = First (Of "${tag}bigframe_over_bound") 'tcp_closed'
    if ($bo) { $rows["${k}wire_bigframe_over_bound_tcp_closed_after_ms"] = "$($bo.afterMs)" }
    $ac = First (Of "${tag}after_cookie") 'upgrade'
    if ($ac) { $rows["${k}wire_after_cookie_cookie_header"] = "$($null -ne $ac.headers.cookie)" }
    $nr = @(Of "${tag}noread" | Where-Object { $_.event -eq 'client_message' })
    $rows["${k}wire_noread_messages_seen"] = "$($nr.Count)"
}
$rows['wire_redirect_followed_hits'] = "$(@($wire | Where-Object { $_.kind -eq 'upgrade' -and $_.url -match 'from=redirect' }).Count)"

$tlsWire = @(Get-Content $tlsLog | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json })
$rows['wire_tls_upgrades'] = "$(@($tlsWire | Where-Object { $_.kind -eq 'upgrade' }).Count)"
$rows['wire_tls_client_errors'] = ((@($tlsWire | Where-Object { $_.kind -eq 'tls_client_error' }) | ForEach-Object { $_.code }) -join ',')

$outPath = "$work/spike-$target.json"
$rows | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 $outPath
Write-Host "[CAP-15C] $($rows.Count) rows -> $outPath"
