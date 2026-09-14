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
#   K9  the CAP-12 sentence is written where the receive loop lives
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

# --- K9: the CAP-12 sentence ---------------------------------------------------------
foreach ($f in 'docs/cli-contract.md', 'sdk/typescript/src/socket.ts',
               'sdk/pas2js/pweb.native.pas', $decorator) {
    if ((Read_ $f) -notmatch '(?i)only\s+thing\s+that\s+changes') {
        Violation ("K9: $f does not say that when CAP-12 brings streaming the " +
            'receive loop is the only thing that changes')
    }
}
$report.Add('K9: the CAP-12 sentence is in the contract, both SDKs and the decorator')

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
$frozen = [ordered]@{
    'src/rpc/pweb.rpc.fetch.pas'                        = '24c7bfac26336544e24708a8d8c781180c4f4eddd0fb925471d6689d713be493'
    'src/rpc/pweb.rpc.fetch.mormot.pas'                 = 'eaddb32dc5cec4a1be7ad8ef38cf99648f91c099157360a969d0a09ada8e72fe'
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
