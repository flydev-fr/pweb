# CAP-15C: the source contract cross-checks.
#
# Checkout-only: no build, no toolchain, no network. Everything here is a
# property of the SOURCE that a built image cannot show, and each row is a
# rule the socket door was ratified under rather than a preference:
#
#   K1  the three socket units exist; the DECORATOR carries no mormot.net.*,
#       no compiler conditional, no operating system and no PWEB_DEV, and
#       reuses the fetch origin grammar instead of owning a second one
#   K2  no src file names mormot.net.ws.* or mormot.net.server
#       (mormot_net_ws_files = 0 - the Checkpoint-1 amendment), and the set
#       of src files naming any mormot.net.* unit is exactly the two
#       transports
#   K3  the transport's own rules: OpenBind, the PWeb User-Agent, no proxy,
#       no cookie, no TLS relaxation, the UNIX region spelled `UNIX`; the
#       Darwin configuration rows named in the bridge
#   K4  no ws:// or wss:// URL literal anywhere in src/**, and no loopback
#       host in any socket unit
#   K5  ONE constants home: the TypeScript and Pas2JS SDKs carry the same
#       method names, capability and bounds as src/rpc/pweb.rpc.socket.pas,
#       and the bounds are consistent with one another
#   K6  both templates install the door, attach the policy and arm the two
#       host seams ONLY inside PWEB_NET, with the Darwin/mORMot transport
#       split inside it; both app.services.pas map the four methods to
#       network.socket only there
#   K7  the witness test/cap15c/sockethost.pas carries the same constructs
#   K8  the host seams: the document hook is armed before the guard, the
#       doors are released BEFORE the binding closes and the scheduler
#       drains, a dev generation switch IS a trusted re-navigation, and each
#       platform calls the hook once, after a trusted document verdict
#   K9  no "when CAP-12 brings streaming" promise under docs/, either SDK or
#       the decorator; the CAP-12A measurement where the receive loop lives
#   K10 every test/cap15c program naming the Cocoa socket unit is built by a
#       script that links the bridge object
#   K11 the divergence allowlist carries the transport and the frozen core
#       list carries the decorator
#   K12 the bundler refuses the socket field names
#   K13 the six zero-transport sweeps carry the CAP-15C claim
#   K14 the CAP-5 SDK pattern, parsed back out, still FIRES on the browser
#       primitive and on both socket URL spellings, and passes the SDK's own
#       class names
#   K15 FREEZE: the fetch units, the command layer and the navigation policy
#       are byte-identical to what CAP-15B closed on (LF-normalised)
#   K16 the decorator never grants: it reads the policy, it never writes it
#   K17 the CAP-4 zero-HTTP source proof, parsed out of its inline action and
#       run here, because no local chain runs an inline action
#   K18 every Objective-C++ cancelWithCloseCode: argument is cast to the
#       framework's enum - the one clang error class a non-Mac host can see
#   K19 the Darwin socket adapter masks the FPU traps in its own initialization,
#       because a program may link it without the WebView adapter
#   K20 the socket delegate owns neither its session, its task nor its delegate
#       queue - one teardown path invalidates and releases them
#   K21 every socket entry point of the Cocoa bridge masks the calling
#       thread's FPU traps first - FPC re-arms them on each thread it creates
#   K22 inside PWebCocoaSocket the task ivar is only retained, under
#       @synchronized after a stopping test - never messaged directly
#   K25 the starvation instrument runs at the numbers read from
#       PWebDefaultHostOptions, and adds no worker or slot for the sockets
#
# Usage: pwsh test/cap15c/check_cap15c_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]
function Violation([string]$M) { $violations.Add($M) }
function Read_([string]$P) {
    if (-not (Test-Path $P)) { Violation "missing file: $P"; return '' }
    return [System.IO.File]::ReadAllText($P)
}
function RelPath([string]$Full) {
    return ($Full.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
}

# Pascal comments removed; compiler DIRECTIVES are kept, because a
# conditional is code. Strings are honoured
function StripComments([string]$Text) {
    $out = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq '''') {
            [void]$out.Append($c); $i++
            while ($i -lt $n) {
                [void]$out.Append($Text[$i])
                if ($Text[$i] -eq '''') { $i++; break }
                $i++
            }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '{') {
            if ($i + 1 -lt $n -and $Text[$i + 1] -eq '$') {
                while ($i -lt $n -and $Text[$i] -ne '}') { [void]$out.Append($Text[$i]); $i++ }
                if ($i -lt $n) { [void]$out.Append('}'); $i++ }
                continue
            }
            while ($i -lt $n -and $Text[$i] -ne '}') { $i++ }
            $i++
            continue
        }
        if ($c -eq '(' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq ')')) { $i++ }
            $i += 2
            continue
        }
        [void]$out.Append($c); $i++
    }
    return $out.ToString()
}

$decorator = 'src/rpc/pweb.rpc.socket.pas'
$transport = 'src/rpc/pweb.rpc.socket.mormot.pas'
$darwin = 'src/platform/macos/pweb.platform.cocoa.socket.pas'
$socketUnits = @($decorator, $transport, $darwin)

# --- K1: the decorator ---------------------------------------------------------
foreach ($f in $socketUnits) {
    if (-not (Test-Path $f)) { Violation "K1: CAP-15C unit is missing: $f" }
}
$decText = Read_ $decorator
$decCode = StripComments $decText
foreach ($banned in 'mormot.net.', '{$if', '{$else', '{$define', '{$I ',
                    'OSWINDOWS', 'MSWINDOWS', 'DARWIN', 'LINUX', 'UNIX',
                    'PWEB_DEV') {
    if ($decCode.IndexOf($banned, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Violation ("K1: the socket decorator names ${banned}: it is on the " +
            'CAP-7F zero-conditional core list, and its whole claim is that ' +
            'the transport is injected and the door has no development mode')
    }
}
if ($decText -notmatch '\{\$mode ObjFPC\}\{\$H\+\}') {
    Violation "K1: $decorator does not declare {`$mode ObjFPC}{`$H+}"
}
foreach ($needle in 'PWebFetchParseOrigin', 'PWebFetchSameOrigin') {
    if (-not $decCode.Contains($needle)) {
        Violation ("K1: the socket decorator does not call ${needle}: a wss " +
            'URL is authorised by the SAME origin grammar a fetch is, never a second one')
    }
}
$report.Add('K1: the decorator carries no mormot.net.*, no conditional, no OS, no PWEB_DEV, and reuses the fetch grammar')

# --- K2: the mORMot network unit set of src/** ----------------------------------
$srcPascal = @(Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc', '*.pp')
$wsFiles = @()
$netFiles = @()
foreach ($file in $srcPascal) {
    $code = StripComments ([System.IO.File]::ReadAllText($file.FullName))
    $rel = RelPath $file.FullName
    if ($code -match 'mormot\.net\.ws\.|mormot\.net\.server') { $wsFiles += $rel }
    if ($code.Contains('mormot.net.')) { $netFiles += $rel }
}
if ($wsFiles.Count -ne 0) {
    Violation ("K2: $($wsFiles.Count) src file(s) name mormot.net.ws.* or " +
        "mormot.net.server: $($wsFiles -join ', ') -- measured at Checkpoint 1, " +
        'the ws client links the server unit and mishandles a standard peer')
}
$expectedNet = @('src/rpc/pweb.rpc.fetch.mormot.pas', $transport) | Sort-Object
$gotNet = @($netFiles | Sort-Object)
if (($gotNet -join ',') -cne ($expectedNet -join ',')) {
    Violation ("K2: the src files naming a mormot.net.* unit are " +
        "[$($gotNet -join ', ')], expected exactly [$($expectedNet -join ', ')]")
}
$trText = Read_ $transport
$trCode = StripComments $trText
if (-not $trCode.Contains('mormot.net.sock')) {
    Violation 'K2: the socket transport does not stand on mormot.net.sock'
}
if ($trCode -match 'mormot\.net\.(client|http)') {
    Violation 'K2: the socket transport names mormot.net.client or mormot.net.http'
}
$report.Add("K2: mormot_net_ws_files=$($wsFiles.Count); mormot.net.* named by exactly $($gotNet.Count) src file(s)")

# --- K3: the transport's own rules ------------------------------------------------
if ($trCode -notmatch 'OpenBind\s*\(') {
    Violation 'K3: the socket transport does not reach the network through OpenBind'
}
if ($trCode -notmatch "PWEB_SOCKET_USER_AGENT\s*=\s*'PWeb'\s*;") {
    Violation 'K3: the socket transport does not publish exactly User-Agent PWeb'
}
# THE NAME THE CERTIFICATE MUST CARRY. MEASURED on Linux: mORMot's OpenSSL
# layer checks a certificate's name only when TNetTlsContext.HostNamesCsv is
# set, so a zeroed context accepted a TRUSTED certificate issued for another
# host and opened the socket. The transport assigns exactly that one field and
# nothing else of the context - every other field left at its zero value is
# what keeps validation on
if ($trCode -notmatch 'TLS\.HostNamesCsv\s*:=\s*Request\.Host\s*;') {
    Violation ('K3: the socket transport does not hand TLS the host name - on UNIX ' +
        'OpenSSL then checks the chain and NOT the name')
}
$tlsAssigns = @([regex]::Matches($trCode, 'TLS\.(\w+)\s*:=') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if (($tlsAssigns -join ',') -cne 'HostNamesCsv') {
    Violation ("K3: the socket transport assigns TLS field(s) [$($tlsAssigns -join ', ')], " +
        'expected exactly HostNamesCsv')
}
foreach ($banned in 'Proxy', 'Tunnel', 'Cookie') {
    if ($trCode.IndexOf($banned, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Violation "K3: the socket transport code names ${banned}"
    }
}
foreach ($f in $socketUnits) {
    $code = StripComments (Read_ $f)
    foreach ($banned in 'IgnoreCertificateErrors', 'IgnoreTlsCertError',
                        'aIgnoreTlsCertificateErrors', 'AllowDeprecatedTls') {
        if ($code.Contains($banned)) { Violation "K3: $f names the TLS relaxation $banned" }
    }
    if ($code.Contains('PWEB_DEV')) { Violation "K3: $f branches on PWEB_DEV" }
}
$dirs = @([regex]::Matches($trCode, '\{\$[^}]*\}') | ForEach-Object { $_.Value } |
    Where-Object { $_ -notmatch '^\{\$(mode|H\+)' })
if (($dirs -join '|') -cne '{$ifdef UNIX}|{$endif UNIX}') {
    Violation ("K3: the socket transport's conditionals are [$($dirs -join ', ')], " +
        'expected exactly {$ifdef UNIX} / {$endif UNIX} - OSPOSIX is always false outside mormot.defines.inc')
}
# Darwin: the configuration rows 15B section 10 froze, named in the bridge
$mm = Read_ 'src/platform/macos/pweb_cocoa_bridge.mm'
$mmSocket = ''
$at = $mm.IndexOf('PWebCocoaSocket')
if ($at -lt 0) { Violation 'K3: the Cocoa bridge carries no socket transport' }
else { $mmSocket = $mm.Substring($at) }
foreach ($needle in 'webSocketTaskWithRequest', 'HTTPShouldSetCookies',
                    'connectionProxyDictionary', 'willPerformHTTPRedirection',
                    'maximumMessageSize') {
    if (-not $mmSocket.Contains($needle)) {
        Violation "K3: the Darwin socket transport does not name $needle"
    }
}
$report.Add('K3: OpenBind, User-Agent PWeb, no proxy, no cookie, no TLS relaxation, UNIX region only; Darwin rows named')

# --- K4: no socket URL literal, no loopback host in the door ----------------------
$wsLiteral = 0
foreach ($file in $srcPascal) {
    $code = StripComments ([System.IO.File]::ReadAllText($file.FullName))
    foreach ($m in [regex]::Matches($code, "'((?:[^']|'')*)'")) {
        if ($m.Groups[1].Value -match '(?i)wss?://.') {
            $wsLiteral++
            Violation ("K4: a socket URL literal appears in the runtime: " +
                "$(RelPath $file.FullName): $($m.Groups[1].Value)")
        }
    }
}
foreach ($f in $socketUnits) {
    $code = StripComments (Read_ $f)
    foreach ($needle in '127.0.0.1', 'localhost', '[::1]') {
        if ($code.Contains($needle)) {
            Violation ("K4: $f names the loopback host ${needle}: the loopback " +
                'exception is a property of the compiled allowlist, never of the door')
        }
    }
}
$report.Add("K4: $wsLiteral socket URL literal(s) in src/**; no loopback host in the three socket units")

# --- K5: one constants home --------------------------------------------------------
function PascalConst([string]$Code, [string]$Name) {
    $m = [regex]::Match($Code, "(?m)^\s*$Name\s*=\s*([^;]+);")
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value.Trim()
    if ($v -match "^'(.*)'$") { return $Matches[1] }
    if ($v -match '^(\d+)\s+shl\s+(\d+)$') { return [string]([int64]$Matches[1] -shl [int]$Matches[2]) }
    return $v
}
$tsText = Read_ 'sdk/typescript/src/socket.ts'
$p2jCode = StripComments (Read_ 'sdk/pas2js/pweb.native.pas')
function TsConst([string]$Name) {
    $m = [regex]::Match($tsText, "(?m)^export const $Name\s*=\s*([^;]+);")
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim().Trim('"')
}
$pairs = @(
    @('PWEB_METHOD_SOCKET_OPEN', 'PWEB_METHOD_SOCKET_OPEN'),
    @('PWEB_METHOD_SOCKET_SEND', 'PWEB_METHOD_SOCKET_SEND'),
    @('PWEB_METHOD_SOCKET_RECEIVE', 'PWEB_METHOD_SOCKET_RECEIVE'),
    @('PWEB_METHOD_SOCKET_CLOSE', 'PWEB_METHOD_SOCKET_CLOSE'),
    @('PWEB_CAP_NETWORK_SOCKET', 'PWEB_CAP_NETWORK_SOCKET'),
    @('PWEB_SOCKET_MAX_WAIT_MS', 'PWEB_SOCKET_RECEIVE_WAIT_MS'),
    @('PWEB_SOCKET_MAX_MESSAGE', 'PWEB_SOCKET_MAX_MESSAGE'),
    @('PWEB_SOCKET_MAX_PROTOCOLS', 'PWEB_SOCKET_MAX_PROTOCOLS'),
    @('PWEB_SOCKET_MAX_REASON_BYTES', 'PWEB_SOCKET_MAX_REASON_BYTES'))
foreach ($p in $pairs) {
    $native = PascalConst $decCode $p[0]
    $ts = TsConst $p[1]
    $p2j = PascalConst $p2jCode $p[1]
    if ($null -eq $native) { Violation "K5: $decorator does not define $($p[0])"; continue }
    if ($ts -cne $native) {
        Violation "K5: @pweb/runtime $($p[1]) = '$ts', the native $($p[0]) = '$native'"
    }
    if ($p2j -cne $native) {
        Violation "K5: the Pas2JS SDK $($p[1]) = '$p2j', the native $($p[0]) = '$native'"
    }
}
# the queue must be able to hold one message of the largest size, and a
# request must be able to carry one: a bound that cannot fit the bound it
# serves is a door that refuses its own contract
$maxMsg = [int64](PascalConst $decCode 'PWEB_SOCKET_MAX_MESSAGE')
$qBytes = [int64](PascalConst $decCode 'PWEB_SOCKET_QUEUE_BYTES')
$reqBytes = [int64](PascalConst $decCode 'PWEB_SOCKET_REQUEST_BYTES')
if ($qBytes -lt $maxMsg) { Violation "K5: PWEB_SOCKET_QUEUE_BYTES $qBytes < PWEB_SOCKET_MAX_MESSAGE $maxMsg" }
# base64 of the largest binary message, plus the envelope headroom
if ($reqBytes -lt ([int64][math]::Ceiling($maxMsg / 3.0) * 4 + 65536)) {
    Violation "K5: PWEB_SOCKET_REQUEST_BYTES $reqBytes cannot carry a base64 message of $maxMsg bytes"
}
if ([int64](PascalConst $decCode 'PWEB_SOCKET_MAX_WAIT_MS') -ge [int64](PascalConst $decCode 'PWEB_SOCKET_IDLE_MS')) {
    Violation 'K5: the long-poll wait is not shorter than the idle bound - a page that polls could be closed as idle'
}
$report.Add("K5: $($pairs.Count) constants agree across the native unit, @pweb/runtime and the Pas2JS SDK; queue, request and idle bounds consistent")

# --- K6: the templates -------------------------------------------------------------
$programRequired = @('pweb.rpc.socket,', 'TPWebSocketBridge.Create(',
    'PWebSocketNativeTransport', 'socketBridge.AttachPolicy(policy)',
    'options.MaxRequestBytes := PWEB_SOCKET_REQUEST_BYTES',
    'options.Workers := options.Workers + PWEB_SOCKET_MAX_SOCKETS',
    'options.MaxConcurrent := options.MaxConcurrent + PWEB_SOCKET_MAX_SOCKETS',
    'options.DocumentReplacing := socketBridge.DocumentReplacing',
    'options.BeforeDrain := socketBridge.BeforeDrain')
$doorRx = 'pweb\.rpc\.socket|TPWebSocket|PWEB_SOCKET_|socketBridge|PWebSocketNativeTransport|cocoa\.socket'
foreach ($tpl in 'tools/templates/react/src/program.lpr',
                 'tools/templates/pas2js/src/program.lpr') {
    $text = Read_ $tpl
    foreach ($needle in $programRequired) {
        if (-not $text.Contains($needle)) { Violation "K6: $tpl does not carry the CAP-15C construct: $needle" }
    }
    $inNet = $false
    $dar = ''
    $lineNo = 0
    $sawCocoa = $false
    $sawMormot = $false
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_NET\}') { $inNet = $true; continue }
        if ($line -match '\{\$endif\s+PWEB_NET\}') { $inNet = $false; continue }
        if ($inNet -and $line -match '\{\$ifdef\s+DARWIN\}') { $dar = 'darwin'; continue }
        if ($inNet -and $dar -eq 'darwin' -and $line -match '\{\$else\}') { $dar = 'else'; continue }
        if ($line -match '\{\$endif\s+DARWIN\}') { $dar = ''; continue }
        if ($line -match $doorRx) {
            if (-not $inNet) {
                Violation "K6: the generated program names the socket door OUTSIDE PWEB_NET: ${tpl}:${lineNo}"
            }
            if ($line -match 'pweb\.platform\.cocoa\.socket') {
                $sawCocoa = $true
                if ($dar -ne 'darwin') { Violation "K6: ${tpl}:${lineNo} names the Cocoa socket unit outside {`$ifdef DARWIN}" }
            }
            if ($line -match 'pweb\.rpc\.socket\.mormot') {
                $sawMormot = $true
                if ($dar -ne 'else') { Violation "K6: ${tpl}:${lineNo} names the mORMot socket unit outside the non-Darwin branch" }
            }
        }
    }
    if (-not ($sawCocoa -and $sawMormot)) { Violation "K6: $tpl does not name both socket transports" }
}
foreach ($tpl in 'tools/templates/react/src/app.services.pas',
                 'tools/templates/pas2js/src/app.services.pas') {
    $text = Read_ $tpl
    $maps = [regex]::Matches($text,
        'MapMethod\(PWEB_METHOD_SOCKET_(OPEN|SEND|RECEIVE|CLOSE),\s*\[PWEB_CAP_NETWORK_SOCKET\]\)').Count
    if ($maps -ne 4) { Violation "K6: $tpl maps $maps socket method(s) to network.socket, expected 4" }
    $inNet = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_NET\}') { $inNet = $true; continue }
        if ($line -match '\{\$else\}') { $inNet = $false; continue }
        if ($line -match '\{\$endif\s+PWEB_NET\}') { $inNet = $false; continue }
        if ((-not $inNet) -and ($line -match 'PWEB_CAP_NETWORK_SOCKET|PWEB_METHOD_SOCKET|pweb\.rpc\.socket')) {
            Violation "K6: the generated policy names the socket door OUTSIDE PWEB_NET: ${tpl}:${lineNo}"
        }
    }
}
$report.Add('K6: both templates install, attach and arm the socket door only inside PWEB_NET; four methods mapped to network.socket')

# --- K7: the witness ---------------------------------------------------------------
$witness = Read_ 'test/cap15c/sockethost.pas'
foreach ($needle in 'pweb.rpc.socket', 'pweb.platform.cocoa.socket',
                    'pweb.rpc.socket.mormot', '{$I app.network.inc}',
                    'TPWebSocketBridge.Create', 'PWebSocketNativeTransport',
                    'APP_NETWORK_ORIGINS', 'AttachPolicy') {
    if (-not $witness.Contains($needle)) {
        Violation ("K7: test/cap15c/sockethost.pas does not carry ${needle}: the " +
            'witness must compile what a generated host compiles')
    }
}
$report.Add('K7: the witness carries the template constructs')

# --- K8: the host seams --------------------------------------------------------------
$hostCode = StripComments (Read_ 'src/webview/pweb.webview.host.pas')
function IndexAfter([string]$Text, [string]$Needle, [int]$From) {
    if ($From -lt 0) { return -1 }
    return $Text.IndexOf($Needle, $From, [System.StringComparison]::Ordinal)
}
$arm = IndexAfter $hostCode 'PWebNavTrustedDocumentHook := PWebHostTrustedDocument' 0
$guard = IndexAfter $hostCode 'navGuard := TPWebHostNavGuard.Create' $arm
if ($arm -lt 0 -or $guard -lt 0) {
    Violation 'K8: the document hook is not armed before the navigation guard is installed'
}
$disarm = IndexAfter $hostCode 'PWebNavTrustedDocumentHook := nil' $guard
$drainCall = IndexAfter $hostCode 'Options.BeforeDrain()' $disarm
$bindClose = IndexAfter $hostCode 'binding.Close' $drainCall
$schedStop = IndexAfter $hostCode 'scheduler.Shutdown' $bindClose
if ($disarm -lt 0 -or $drainCall -lt 0 -or $bindClose -lt 0 -or $schedStop -lt 0) {
    Violation ('K8: the teardown order is not: disarm the document hook, ' +
        'BeforeDrain, binding.Close, scheduler.Shutdown -- the doors must ' +
        'release before the CAP-9 drain, and every CAP-9 step keep its place')
}
if ($hostCode -notmatch '(?s)procedure PWebHostReNavigate\b.*?webview_navigate\(w,\s*PWEB_HOST_ORIGIN\)') {
    Violation 'K8: PWebHostReNavigate does not re-navigate to PWEB_HOST_ORIGIN'
}
if ($hostCode -notmatch '(?s)function PWebHostRequestReload\b.*?webview_dispatch\([^;]*@PWebHostReNavigate') {
    Violation ('K8: the development reload is not PWebHostReNavigate - a generation ' +
        'switch must be a trusted re-navigation, or the navigation hook does not close its sockets')
}
foreach ($pf in 'src/platform/windows/pweb.platform.webview2.pas',
                'src/platform/linux/pweb.platform.webkitgtk.pas',
                'src/platform/macos/pweb.platform.cocoa.pas') {
    $text = Read_ $pf
    if ($text -notmatch 'PWebNavTrustedDocumentHook:\s*procedure\s*=\s*nil;') {
        Violation "K8: $pf does not declare the trusted-document hook"
    }
    $lines = [System.IO.File]::ReadAllLines($pf)
    $calls = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'PWebNavTrustedDocumentHook\(\)') {
            $calls++
            $window = ($lines[[math]::Max(0, $i - 3)..$i]) -join "`n"
            if ($window -notmatch 'Kind\s*=\s*pnkDocument') {
                Violation "K8: ${pf}:$($i + 1) calls the document hook without a pnkDocument condition"
            }
            $before = ($lines[[math]::Max(0, $i - 12)..$i]) -join "`n"
            if ($before -notmatch 'pnaAllowTrusted|webkit_policy_decision_use|PWEB_COCOA_NAV_ALLOW') {
                Violation "K8: ${pf}:$($i + 1) calls the document hook before a trusted verdict"
            }
        }
    }
    if ($calls -ne 1) { Violation "K8: $pf calls the document hook $calls time(s), expected 1" }
}
$report.Add('K8: hook armed before the guard; disarm, BeforeDrain, binding.Close, scheduler.Shutdown in order; generation switch is a trusted re-navigation; one hook call per platform')

# --- K9: the receive loop waits for nothing -----------------------------------------
# CAP-15C wrote "when CAP-12 brings streaming, the receive loop is the only thing
# that changes" into the contract, both SDKs and the decorator. CAP-12A then
# MEASURED that WebView2 withholds a streamed body from the page until it is
# complete, ratified a data plane that is Range-based and not streaming-based,
# and CAP-12 closed on 12B with no streaming route at all
# (cap12-closure-artifact.md). The promise pointed at nothing, so it is refused
# anywhere under docs/, either SDK or the decorator, and the four places that
# carried it must carry the measurement that replaced it. The needle is built by
# concatenation so this file cannot satisfy its own sweep.
#
# THE SWEPT TEXT IS NORMALISED FIRST, because a promise is prose and prose
# wraps: the old socket.ts split "When CAP-12 / * brings streaming" across a
# JSDoc line, which `\s+` alone cannot cross. Comment prefixes at the start
# of a line (` * `, `//`, `#`, `>`) become spaces and a typographic apostrophe
# becomes a straight one, so the needle meets the sentence however it was
# laid out. The sweep is every TRACKED file under docs/ and sdk/ - README,
# tests and all - plus the decorator; build output is not the source.
$k9Promise = '(?i)CAP-12(''s)?\s+(brings\s+)?' + 'streaming|only\s+thing\s+that\s+' + 'changes'
$k9Measured = '(?i)Range-based,\s+not\s+streaming-based'
function K9Text([string]$P) {
    $t = (Read_ $P) -replace '(?m)^\s*(\*|//|#|>)+', ' '
    return $t.Replace([string][char]0x2019, "'")
}
$k9Swept = @(& git ls-files -- docs sdk | Where-Object {
        $_ -match '\.(md|ts|js|mjs|pas|pp|inc|json)$' }) + @($decorator)
if ($k9Swept.Count -lt 20) {
    Violation "K9: the sweep found only $($k9Swept.Count) tracked file(s) under docs/ and sdk/ - git ls-files did not answer"
}
foreach ($f in $k9Swept) {
    if ((K9Text $f) -match $k9Promise) {
        Violation ("K9: $f still says the socket receive loop waits for CAP-12 " +
            'streaming - CAP-12A measured that route impossible on WebView2 and ' +
            'CAP-12 closed without one')
    }
}
foreach ($f in 'docs/cli-contract.md', 'sdk/typescript/src/socket.ts',
               'sdk/pas2js/pweb.native.pas', $decorator) {
    if ((K9Text $f) -notmatch $k9Measured) {
        Violation ("K9: $f does not carry the CAP-12A measurement that replaced " +
            'the streaming promise (a data plane Range-based, not streaming-based)')
    }
}
$report.Add("K9: no CAP-12 streaming promise in $($k9Swept.Count) swept files; the CAP-12A measurement in the contract, both SDKs and the decorator")

# --- K10: half a transport does not link ----------------------------------------------
$harness = @(Get-ChildItem 'test/cap15c' -File -Filter '*.ps1' |
    Where-Object { ([System.IO.File]::ReadAllText($_.FullName)) -match '\bfpc\b' })
$linkPairs = 0
foreach ($src in @(Get-ChildItem 'test/cap15c' -File -Filter '*.pas' |
        Where-Object { ([System.IO.File]::ReadAllText($_.FullName)).Contains('pweb.platform.cocoa.socket') })) {
    $builders = @($harness | Where-Object { ([System.IO.File]::ReadAllText($_.FullName)).Contains($src.Name) })
    if ($builders.Count -eq 0) {
        Violation "K10: test/cap15c/$($src.Name) names the Cocoa socket unit and no harness script compiles it"
        continue
    }
    foreach ($b in $builders) {
        $linkPairs++
        if (-not ([System.IO.File]::ReadAllText($b.FullName)).Contains('pweb_cocoa_bridge.o')) {
            Violation ("K10: test/cap15c/$($b.Name) compiles $($src.Name) and never names " +
                'pweb_cocoa_bridge.o -- on Darwin it links half a transport')
        }
    }
}
$report.Add("K10: $linkPairs source/builder pair(s) naming the Cocoa socket unit, each linking the bridge")

# --- K11: the divergence allowlist -----------------------------------------------------
$div = Read_ 'test/cap7f/check_divergence.ps1'
if ($div -notmatch "'src/rpc/pweb\.rpc\.socket\.mormot\.pas'\s*=\s*@\{\s*directives\s*=\s*2;") {
    Violation 'K11: the divergence allowlist does not ratify the socket transport at 2 directives'
}
$core = [regex]::Match($div, '(?s)\$frozenCore = @\((.*?)\)')
if (-not ($core.Success -and $core.Groups[1].Value.Contains("'src/rpc/pweb.rpc.socket.pas'"))) {
    Violation 'K11: the socket decorator is not on the frozen zero-conditional core list'
}
$report.Add('K11: the transport is allowlisted, the decorator is frozen zero-conditional')

# --- K12: the bundler ---------------------------------------------------------------
$bundler = StripComments (Read_ 'tools/bundler/pwebbundle.pas')
foreach ($name in 'socket', 'sockets', 'websocket', 'ws', 'wss') {
    if (-not $bundler.Contains("(name = '$name')")) {
        Violation "K12: the bundler does not refuse a top-level ``$name`` field in app.pwb"
    }
}
$report.Add('K12: the bundler refuses socket, sockets, websocket, ws and wss')

# --- K13: the six zero-transport sweeps -----------------------------------------------
$sweeps = @('test/cap7l/check_cap7l_nonetwork.sh',
            'test/cap7m/check_cap7m_nonetwork.sh',
            'test/cap5/check_cap5_nonetwork.ps1',
            'test/cap6/check_cap6_nonetwork.ps1',
            'test/cap9c1/run_quickjsrelease.ps1',
            '.github/actions/cap-4-zero-http-asset-serving-source-proof/action.yml')
foreach ($s in $sweeps) {
    $text = Read_ $s
    if (-not ($text.Contains('pweb.rpc.socket.mormot') -and $text.Contains('network.socket'))) {
        Violation "K13: $s does not carry the CAP-15C claim (pweb.rpc.socket.mormot, network.socket)"
    }
}
$report.Add("K13: all $($sweeps.Count) zero-transport sweeps carry the CAP-15C claim")

# --- K14: the CAP-5 SDK pattern still fires ---------------------------------------------
$cap5 = Read_ 'test/cap5/check_cap5_nonetwork.ps1'
$pm = [regex]::Match($cap5, '(?s)\$network = ((?:''[^'']*''\s*\+?\s*)+)')
if (-not $pm.Success) {
    Violation 'K14: the CAP-5 $network pattern could not be parsed out of its script'
} else {
    $pattern = -join ([regex]::Matches($pm.Groups[1].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
    $rx = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $fire = @('const s = new WebSocket(url);', 'window.WebSocket', 'globalThis.WebSocket',
              'open("ws://example.invalid/")', 'open("wss://example.invalid/")',
              'fetch("/x")', 'XMLHttpRequest')
    $pass = @('export class PWebSocket {', 'TPWebSocket = class', 'new PWebSocket(url)',
              'await invoke(PWEB_METHOD_SOCKET_OPEN, args)')
    $fired = 0
    foreach ($v in $fire) {
        if ($rx.IsMatch($v)) { $fired++ } else { Violation "K14: the CAP-5 pattern does not fire on: $v" }
    }
    foreach ($v in $pass) {
        if ($rx.IsMatch($v)) { Violation "K14: the CAP-5 pattern refuses the SDK's own spelling: $v" }
    }
    $report.Add("K14: the CAP-5 pattern fires on $fired/$($fire.Count) planted shapes and passes the SDK's $($pass.Count) own spellings")
}

# --- K15: the freeze ----------------------------------------------------------------------
#
# RE-PINNED ONCE AFTER THE CAP-15C CLOSURE, with its reason (ledger 15C-29).
# The fetch corrective - its own commit - moved exactly two of these units:
# pweb.rpc.fetch.mormot.pas now assigns TNetTlsContext.HostNamesCsv (15C-1:
# on Linux the zeroed context of v0.2.0 verified a certificate's chain and not
# its name), and pweb.rpc.fetch.pas refuses a raw or escaped NUL before it
# decodes (15C-7). Their CAP-15B closure pins were 24c7bfac... and eaddb32d...;
# the other three units are the CAP-15B closure's bytes, unchanged.
#
# RE-PINNED AGAIN BY CAP-12B, for ONE unit and for the reason that shard
# exists. `pweb.rpc.fetch.pas` is the headline consumer of the blob data
# plane: a declared-origin response between the 1 MiB inline cap and the
# 8 MiB response ceiling used to be the typed refusal
# `response_too_large_to_inline`, and is now a SUCCESS carrying a BlobHandle
# the page reads by URL. Its CAP-15C pin was
# 82aedb926a8a6a77633a6eb82aa3da74a285365602cd44101ce054960e4ec5fb.
#
# WHAT DID NOT MOVE, and that is the half worth saying: the transport, the
# Darwin transport, the command layer and - above all -
# `pweb.navigation.policy.pas` carry the same bytes they did at the CAP-15C
# closure. `PWEB_NATIVE_CSP` is the premise the whole blob namespace rests
# on, and this line is one of the places that proves CAP-12B did not touch it.
$frozen = [ordered]@{
    'src/rpc/pweb.rpc.fetch.pas'                        = 'a158a35aaf247f0c494b779d08953eb10ca38af57144d7fd8d917cebe8ff50e9'
    'src/rpc/pweb.rpc.fetch.mormot.pas'                 = 'ec99cd5bce86921450a4089210935b2cc5d2d50b32818223be0801cced792fbc'
    'src/platform/macos/pweb.platform.cocoa.fetch.pas'  = '1fda306723431e1136db90b3d79f80e0b89d9c23d7110cf9331839be11a98143'
    'src/rpc/pweb.rpc.command.pas'                      = '2b279c63e97e1a09d9398f26b95b1f3abc51ca6ea62f4541391882553056b8cf'
    'src/security/pweb.navigation.policy.pas'           = 'cc90c0e7efe13d56ade5238d5c8eb17cbe7b463c7bd0c57dd26309f9b7070dbb'
}
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    foreach ($f in $frozen.Keys) {
        $text = (Read_ $f).Replace("`r`n", "`n")
        $got = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
            ForEach-Object { $_.ToString('x2') })
        if ($got -cne $frozen[$f]) {
            Violation ("K15: $f is not byte-identical to what CAP-15B closed on " +
                "(LF sha256 $got) -- the socket door was built beside fetch, never through it")
        }
    }
} finally { $sha.Dispose() }
$report.Add("K15: $($frozen.Count) frozen units byte-identical to the CAP-15B closure")

# --- K16: the decorator never grants -------------------------------------------------------
foreach ($banned in 'SetRuntimeGrants', 'RevokeRuntimeGrant', 'ClearRuntimeGrants',
                    'SetAppMaximum', 'SetWindowCapabilities',
                    'SetPrincipalCapabilities', 'MapMethod') {
    if ($decCode.Contains($banned)) {
        Violation "K16: the socket decorator calls ${banned}: it reads the policy and never writes it"
    }
}
if (-not $decCode.Contains('SnapshotCapabilities')) {
    Violation 'K16: the socket decorator does not re-read capabilities through SnapshotCapabilities on a grant change'
}
$report.Add('K16: the decorator reads the policy and never writes it')

# --- K17: the CAP-4 zero-HTTP source proof, mirrored where it can run ------------
#
# MEASURED, and it cost the Windows leg of hosted run 34901915886. The CAP-4
# source proof lives INLINE in its composite action, not in a script, so no
# local chain ever runs it - and this shard's trusted-document hook comment in
# `src/platform/windows/pweb.platform.webview2.pas` said "socket door", a word
# that proof forbids on the raw line. The file list and the pattern are PARSED
# OUT OF THE ACTION rather than copied, so this mirror cannot disagree with the
# gate it mirrors; a change to the action's shape is a violation here, never a
# silent skip.
$cap4Action = '.github/actions/cap-4-zero-http-asset-serving-source-proof/action.yml'
$cap4Text = (Read_ $cap4Action) -replace "`r`n", "`n"
$filesBlock = [regex]::Match($cap4Text, '(?s)\$cap4Files = @\((.*?)\)')
$patternBlock = [regex]::Match($cap4Text, '(?s)\$forbidden = ((?:''[^'']*''\s*\+?\s*)+)')
if (-not ($filesBlock.Success -and $patternBlock.Success)) {
    Violation ("K17: $cap4Action no longer exposes `$cap4Files and `$forbidden in the " +
        'shapes this mirror parses -- update the mirror in the same commit')
} else {
    $cap4Files = @([regex]::Matches($filesBlock.Groups[1].Value, "'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value })
    $cap4Pattern = -join ([regex]::Matches($patternBlock.Groups[1].Value, "'([^']*)'") |
        ForEach-Object { $_.Groups[1].Value })
    $cap4Rx = [regex]::new($cap4Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $cap4Hits = 0
    $cap4Swept = 0
    foreach ($f in $cap4Files) {
        # built frontend outputs are absent in a checkout; the action sweeps
        # them on the leg that built them, and this mirror sweeps what exists
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $cap4Swept++
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadLines((Resolve-Path -LiteralPath $f).Path)) {
            $lineNo++
            if ($cap4Rx.IsMatch($line)) {
                $cap4Hits++
                Violation ("K17: ${f}:${lineNo}: forbidden CAP-4 transport pattern -- " +
                    "$($line.Trim())")
            }
        }
    }
    $report.Add("K17: the CAP-4 source proof mirrored - $cap4Swept of $($cap4Files.Count) file(s) present and swept, $cap4Hits hit(s)")
}

# --- K18: an Objective-C++ close code is the framework's enum, never an int -----
#
# MEASURED, and it cost both macOS legs of hosted run 34901915886: under
# Objective-C++ `cancelWithCloseCode:` takes `NSURLSessionWebSocketCloseCode`,
# and clang refuses an int literal for it (`cannot initialize a parameter of
# type 'NSURLSessionWebSocketCloseCode' with an rvalue of type 'int'`). No
# host here compiles the bridge, so the rule is a source rule: every argument
# is cast explicitly.
$mmPath = 'src/platform/macos/pweb_cocoa_bridge.mm'
$mmLines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $mmPath).Path)
$closeSites = 0
for ($i = 0; $i -lt $mmLines.Count; $i++) {
    foreach ($m in [regex]::Matches($mmLines[$i], 'cancelWithCloseCode:\s*(\S)')) {
        $closeSites++
        $rest = $mmLines[$i].Substring($m.Index + 'cancelWithCloseCode:'.Length).TrimStart()
        if (-not $rest.StartsWith('(NSURLSessionWebSocketCloseCode)')) {
            Violation ("K18: ${mmPath}:$($i + 1): cancelWithCloseCode: is not passed an " +
                'explicit (NSURLSessionWebSocketCloseCode) -- clang refuses an int there under Objective-C++')
        }
    }
}
$report.Add("K18: $closeSites cancelWithCloseCode: site(s) in the Cocoa bridge, each cast to NSURLSessionWebSocketCloseCode")

# --- K19: the Darwin socket adapter masks the FPU traps itself ------------------
#
# MEASURED on macos-x64 of hosted run 34941125057: the Darwin socket transport
# opened, echoed text, binary and 1 MiB, reassembled fragments and refused the
# handshakes it must - and then `socketlive` died with `EInvalidOp: Invalid
# floating point operation` raised inside a system framework. FPC leaves the
# FPU trapping on exceptional results, and Apple's frameworks compute through
# them legally. `pweb.platform.cocoa.pas` masks them in its initialization,
# for the reason its comment gives - linking that unit IS the decision to host
# WebKit in this process - but a program that links the socket adapter and not
# the WebView adapter never ran that line. The same reasoning therefore applies
# to the socket adapter: linking it IS the decision to run NSURLSession's
# WebSocket code, so its own initialization calls the same bridge entry point.
$cocoaSocket = StripComments (Read_ $darwin)
$init = [regex]::Match($cocoaSocket, '(?s)\binitialization\b(.*?)\bend\.\s*$')
if (-not $init.Success) {
    Violation ("K19: $darwin has no initialization section -- a program that links the " +
        'socket adapter without the WebView adapter runs NSURLSession with the FPU traps live')
} elseif ($init.Groups[1].Value -notmatch '\bpweb_cocoa_mask_fpu_traps\b') {
    Violation ("K19: $darwin does not call pweb_cocoa_mask_fpu_traps in its initialization -- " +
        'measured: EInvalidOp inside the framework on hosted macos-x64')
}
$report.Add('K19: the Darwin socket adapter masks the FPU traps in its own initialization')

# --- K20: the socket delegate owns neither its session nor its delegate queue -----
#
# MEASURED on hosted run 34947294257: with the FPU traps masked, macos-arm64
# died with `EAccessViolation` inside a system library at the same point
# macos-x64 had died with `EInvalidOp` - a few milliseconds after a run of
# REFUSED handshakes. `PWebCocoaSocket` was the session's delegate AND owned
# the session, its task and its delegate queue, and its `dealloc` released all
# three. After a refused open the session holds the last reference to its
# delegate and drops it when invalidation completes, ON its own delegate
# queue - so `dealloc` released the session and that queue from inside the
# session's own teardown. The CAP-15B fetch half, measured green on Darwin,
# never does that: its delegate owns nothing, and the calling thread
# invalidates the session and releases the queue. The rule is that shape:
# the socket's `dealloc` releases none of the three, and one teardown helper
# releases them from the calling thread.
$mmSock = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath 'src/platform/macos/pweb_cocoa_bridge.mm').Path) -replace "`r`n", "`n"
$implAt = $mmSock.IndexOf('@implementation PWebCocoaSocket')
if ($implAt -lt 0) {
    Violation 'K20: the Cocoa bridge has no @implementation PWebCocoaSocket'
} else {
    $implText = $mmSock.Substring($implAt)
    $dealloc = [regex]::Match($implText, '(?s)- \(void\)dealloc \{(.*?)\n\}')
    if (-not $dealloc.Success) {
        Violation 'K20: PWebCocoaSocket has no dealloc this rule can read'
    } else {
        foreach ($owned in 'session', 'queue', 'task') {
            if ($dealloc.Groups[1].Value -match ('\[\s*' + $owned + '\s+release\s*\]')) {
                Violation ("K20: PWebCocoaSocket's dealloc releases its $owned -- the session drops its " +
                    'delegate on its own queue when invalidation completes, so this releases the session ' +
                    'from inside its own teardown (measured: EAccessViolation on macos-arm64)')
            }
        }
    }
    $invalidates = [regex]::Matches($implText, 'invalidateAndCancel').Count
    if (($implText -notmatch 'static void pweb_socket_teardown\(') -or ($invalidates -ne 1)) {
        Violation ("K20: the socket section invalidates its session in $invalidates place(s), expected " +
            'exactly one - inside pweb_socket_teardown - so every exit path releases the session the same way')
    }
}
$report.Add('K20: the socket delegate releases no session, queue or task; one teardown path invalidates and releases them')

# --- K21: every socket entry point masks the FPU traps of the thread calling it ---
#
# MEASURED on macos-x64 of hosted run 34947294257: with the traps masked by the
# adapter's initialization, the Darwin transport got FURTHER than the run
# before - past the refused handshakes, the cookie pair, the untrusted TLS
# refusal and both message-bound rows - and then died with `EInvalidOp` inside
# a system framework again. FPU state is PER THREAD, and FPC re-applies its
# trapping control word to every thread it creates: the initialization masked
# the MAIN thread only, while the decorator's keeper thread and the scheduler
# workers call release, close and send from Pascal threads of their own. So
# every C entry point of the socket transport masks the calling thread's traps
# through `pweb_cocoa_mask_fpu_traps` before it sends a single Objective-C
# message.
$mmK21 = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath 'src/platform/macos/pweb_cocoa_bridge.mm').Path)
$entryNames = @('pweb_cocoa_socket_open', 'pweb_cocoa_socket_send',
                'pweb_cocoa_socket_close', 'pweb_cocoa_socket_release')
$entriesChecked = 0
foreach ($name in $entryNames) {
    $start = -1
    for ($i = 0; $i -lt $mmK21.Count; $i++) {
        if ($mmK21[$i] -match ('^(int|void)\s+' + [regex]::Escape($name) + '\s*\(')) { $start = $i; break }
    }
    if ($start -lt 0) {
        Violation "K21: the Cocoa bridge defines no $name"
        continue
    }
    # the body opens on the first line that ends the signature with ') {'
    $open = -1
    for ($i = $start; $i -lt [math]::Min($mmK21.Count, $start + 12); $i++) {
        if ($mmK21[$i] -match '\)\s*\{\s*$') { $open = $i; break }
    }
    if ($open -lt 0) {
        Violation "K21: the body of $name could not be located"
        continue
    }
    $entriesChecked++
    $masked = $false
    for ($i = $open + 1; $i -lt $mmK21.Count; $i++) {
        $line = $mmK21[$i]
        if ($line -match '\bpweb_cocoa_mask_fpu_traps\s*\(\s*\)') { $masked = $true; break }
        # anything that can reach Foundation before the mask is the defect
        if ($line -match '@autoreleasepool|@try|@synchronized|\[[A-Za-z_][A-Za-z0-9_>\-]*\s+[A-Za-z]|^\}') { break }
    }
    if (-not $masked) {
        Violation ("K21: $name does not mask the calling thread's FPU traps before its first " +
            'Objective-C message -- measured: EInvalidOp on macos-x64 from a Pascal thread')
    }
}
$report.Add("K21: $entriesChecked socket entry point(s) in the Cocoa bridge, each masking the calling thread's FPU traps first")

# --- K22: a callback never messages the task the teardown is releasing ------------
#
# MEASURED on macos-arm64 of hosted run 34952410904: with the ownership and the
# per-thread FPU fixes in, `socketlive` still died with `EAccessViolation` - at
# the SAME instruction offset inside a system library as the run before
# (`...C3F64` against `...CF3F64` under a different ASLR slide), the signature
# of `objc_msgSend` on a freed object. The receive completion handler, on an
# NSURLSession thread, sent `closeCode`, `closeReason` and
# `cancelWithCloseCode:` to `self->task` with no lock, and `armReceive` armed
# `task` with none, while the decorator's keeper thread - a Pascal thread -
# released a closed socket through `pweb_socket_teardown`, which detaches the
# task under the lock and releases it outside it. A handler that had already
# loaded `self->task` then messaged freed memory. The rule: inside
# `@implementation PWebCocoaSocket`, the task ivar is only ever RETAINED, under
# `@synchronized` after a `stopping` test; every other message goes to that
# retained local.
$mmK22 = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath 'src/platform/macos/pweb_cocoa_bridge.mm').Path)
$k22Start = -1
$k22End = -1
for ($i = 0; $i -lt $mmK22.Count; $i++) {
    if ($k22Start -lt 0 -and $mmK22[$i] -match '^@implementation PWebCocoaSocket\b') { $k22Start = $i; continue }
    if ($k22Start -ge 0 -and $mmK22[$i] -match '^@end\b') { $k22End = $i; break }
}
$taskMessages = 0
if ($k22Start -lt 0 -or $k22End -lt 0) {
    Violation 'K22: the Cocoa bridge has no complete @implementation PWebCocoaSocket to sweep'
} else {
    for ($i = $k22Start; $i -lt $k22End; $i++) {
        if ($mmK22[$i] -notmatch '\[\s*(self->)?task\s+[A-Za-z]') { continue }
        $taskMessages++
        $isRetain = $mmK22[$i] -match '\[\s*(self->)?task\s+retain\s*\]'
        $guarded = $false
        for ($j = $i; $j -gt $k22Start; $j--) {
            if ($j -lt $i -and $mmK22[$j] -match '^- \(') { break }
            if ($mmK22[$j] -match '@synchronized\s*\(') {
                $guarded = (($mmK22[$j..$i]) -join "`n") -match '\bstopping\b'
                break
            }
        }
        if (-not ($isRetain -and $guarded)) {
            Violation ("K22: src/platform/macos/pweb_cocoa_bridge.mm:$($i + 1): the task ivar is messaged " +
                'other than to retain it under @synchronized after a stopping test -- measured: ' +
                'objc_msgSend on a freed task when the keeper thread released the socket')
        }
    }
}
$report.Add("K22: $taskMessages task-ivar message(s) in PWebCocoaSocket, each a retain under @synchronized after a stopping test")

# --- K23: a thread the framework owns leaves a Pascal callback with its traps masked ---
#
# MEASURED on macos-x64 of hosted run 34952410904: with every entry point
# masking its caller (K21), `socketlive` still died with `EInvalidOp` inside a
# system framework. The entry points mask PASCAL threads; the sink callbacks -
# ROOM, DELIVER, CLOSED - run Pascal code on NSURLSession's and libdispatch's
# threads. FPC 3.2.2 rtl/unix/cthreads.pp: the first threadvar a thread FPC
# did not create touches goes through CRelocateThreadvar -> HookThread ->
# InitThread(1000000000), and rtl/inc/thread.inc InitThread begins
# `SysResetFPU; SysInitFPU` - the TRAPPING control word, installed on the
# framework's own thread by the first `try` in a callback, and left there when
# the callback returns into Foundation. So every sink call in the bridge is
# followed, before control leaves the statement that made it, by
# `pweb_cocoa_mask_fpu_traps()`.
$mmK23 = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath 'src/platform/macos/pweb_cocoa_bridge.mm').Path)
$sinkCalls = 0
for ($i = 0; $i -lt $mmK23.Count; $i++) {
    if ($mmK23[$i] -notmatch '\bsink\.(room|deliver|closed)\s*\(') { continue }
    $sinkCalls++
    $remasked = $false
    for ($j = $i + 1; $j -lt [math]::Min($mmK23.Count, $i + 3); $j++) {
        if ($mmK23[$j] -match '\bpweb_cocoa_mask_fpu_traps\s*\(\s*\)') { $remasked = $true; break }
    }
    if (-not $remasked) {
        Violation ("K23: src/platform/macos/pweb_cocoa_bridge.mm:$($i + 1): a sink call returns into the " +
            'framework without re-masking the FPU traps FPC armed on its thread -- measured: ' +
            'EInvalidOp on macos-x64 after every entry point masked its caller')
    }
}
if ($sinkCalls -lt 3) {
    Violation "K23: the Cocoa bridge makes $sinkCalls sink call(s); ROOM, DELIVER and CLOSED were expected"
}
$report.Add("K23: $sinkCalls sink call(s) in the Cocoa bridge, each followed by a re-mask of the FPU traps")

# --- K24: a close frame sent just before release gets the release grace ---------------
#
# MEASURED on macos-x64 of hosted run 34958316754, the first Darwin run of
# `socketlive` to reach its end: every client-side row passed, and the witness
# saw neither the page's 4000/done nor the 1001 of the two sockets released by
# BeforeDrain. `cancelWithCloseCode:reason:` only SCHEDULES the close frame;
# the decorator calls Release straight after Close (ReleaseEntry), or as soon
# as the page takes its close event (Receive), and `pweb_socket_teardown`
# cancelled the task and invalidated its session at once - racing the frame
# onto the wire. The mORMot transport gives a close queued just before release
# RELEASE_GRACE_MS to reach the wire (`WsRelease`); the Darwin release now gives
# the same grace, ended early by the task settling, and this rule pins both the
# shape and that the two graces are one number.
$mmK24 = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath 'src/platform/macos/pweb_cocoa_bridge.mm').Path) -replace "`r`n", "`n"
$mormotK24 = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath 'src/rpc/pweb.rpc.socket.mormot.pas').Path)
function Get-CBody([string]$Text, [string]$Name) {
    $head = [regex]::Match($Text, '(?m)^(int|void)\s+' + [regex]::Escape($Name) + '\s*\([^)]*\)\s*\{')
    if (-not $head.Success) { return $null }
    $end = [regex]::Match($Text.Substring($head.Index), '(?m)^\}')
    if (-not $end.Success) { return $null }
    return $Text.Substring($head.Index, $end.Index + 1)
}
$graceMormot = [regex]::Match($mormotK24, 'RELEASE_GRACE_MS\s*=\s*(\d+)\s*;')
$graceBridge = [regex]::Match($mmK24, '(?m)^#define\s+PWEB_COCOA_SOCKET_RELEASE_GRACE_MS\s+(\d+)\s*$')
if (-not $graceMormot.Success) {
    Violation 'K24: pweb.rpc.socket.mormot.pas no longer declares RELEASE_GRACE_MS'
} elseif (-not $graceBridge.Success) {
    Violation 'K24: the Cocoa bridge defines no PWEB_COCOA_SOCKET_RELEASE_GRACE_MS'
} elseif ($graceBridge.Groups[1].Value -ne $graceMormot.Groups[1].Value) {
    Violation "K24: the Darwin release grace is $($graceBridge.Groups[1].Value) ms and the mORMot one $($graceMormot.Groups[1].Value) ms"
}
$releaseBody = Get-CBody $mmK24 'pweb_cocoa_socket_release'
if ($null -eq $releaseBody) {
    Violation 'K24: the body of pweb_cocoa_socket_release could not be located'
} else {
    $teardownAt = $releaseBody.IndexOf('pweb_socket_teardown(')
    $graceAt = $releaseBody.IndexOf('PWEB_COCOA_SOCKET_RELEASE_GRACE_MS')
    if ($teardownAt -lt 0 -or $graceAt -lt 0 -or $graceAt -gt $teardownAt) {
        Violation ('K24: pweb_cocoa_socket_release tears the task down without first giving a sent close ' +
            'frame the release grace -- measured: 4000/done and 1001 never reached the witness on macos-x64')
    }
}
$closeBody = Get-CBody $mmK24 'pweb_cocoa_socket_close'
if ($null -eq $closeBody -or $closeBody -notmatch 'closeSent\s*=\s*1') {
    Violation 'K24: pweb_cocoa_socket_close does not record that a close frame was scheduled'
}
if ($mmK24 -notmatch 'closeSettled\s*=\s*1') {
    Violation 'K24: nothing in the Cocoa bridge records that a socket task settled, so the grace cannot end early'
}
$report.Add("K24: the Darwin release gives a scheduled close frame the mORMot transport's $($graceMormot.Groups[1].Value) ms grace before teardown")

# --- K25: the starvation is measured at the host's own numbers ------------------------
# test/cap15c/socketstarve.pas asks whether parked receives starve an unrelated
# invocation UNDER THE RATIFIED HOST DEFAULTS, and it is only that measurement
# while the numbers are the host's. So the runner must read them out of
# PWebDefaultHostOptions rather than type them, and the program must hand them
# to the scheduler and the source untouched: a worker or a slot added for the
# sockets - which is what the network template does (15C-6) - would hide the
# very shape the rows exist to show.
$starveSrc = 'test/cap15c/socketstarve.pas'
$starveCode = StripComments (Read_ $starveSrc)
foreach ($needle in @(
        'TInvocationScheduler\.Create\(\s*policyRef\s*,\s*doorRef\s*,\s*Workers\s*\)',
        'limits\.MaxConcurrent\s*:=\s*Slots\s*;',
        'limits\.MaxQueueSize\s*:=\s*QueueBound\s*;')) {
    if ($starveCode -notmatch $needle) {
        Violation ("K25: $starveSrc does not hand the host's numbers to the " +
            "scheduler untouched (expected $needle)")
    }
}
if ($starveCode -match 'PWEB_SOCKET_MAX_SOCKETS\s*\)?\s*[-+*]|[-+*]\s*PWEB_SOCKET_MAX_SOCKETS') {
    Violation "K25: $starveSrc does arithmetic with the socket bound - a worker added for the sockets is the workaround the measurement must not carry"
}
$starveRunner = Read_ 'test/cap15c/run_cap15c_gates.ps1'
if (($starveRunner -notmatch "'src/webview/pweb\.webview\.host\.pas'") -or
    ($starveRunner -notmatch 'function PWebDefaultHostOptions') -or
    ($starveRunner -notmatch '--workers=\$\(\$defaults\.Workers\)') -or
    ($starveRunner -notmatch '--slots=\$\(\$defaults\.MaxConcurrent\)') -or
    ($starveRunner -notmatch '--queue=\$\(\$defaults\.MaxQueueSize\)')) {
    Violation ('K25: run_cap15c_gates.ps1 does not pass the starvation instrument the ' +
        'three numbers it read from PWebDefaultHostOptions')
}
if ($starveRunner -match '--(workers|slots|queue)=\d') {
    Violation 'K25: run_cap15c_gates.ps1 passes the starvation instrument a typed number'
}
$report.Add('K25: the starvation instrument runs at the three numbers the runner reads from PWebDefaultHostOptions, and adds nothing for the sockets')

# --- verdict ---------------------------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap15c | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-15C contract cross-checks')
foreach ($r in $report) { $lines.Add("# $r") }
if ($violations.Count -eq 0) {
    $lines.Add('VERDICT: PASS')
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap15c/contracts.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
foreach ($r in $report) { Write-Host "[CAP-15C] $r" }
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-15C contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-15C] contracts PASS - one door, no ws client unit, no socket URL in the runtime, both templates fenced, fetch frozen'
