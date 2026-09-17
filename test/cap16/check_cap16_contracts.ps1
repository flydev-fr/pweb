# CAP-16: the signal channel's contracts, cross-checked from source.
#
# Checkout-only - no build, no toolchain, no network - so it runs on every
# leg and on any development host, and several of its checks are proven to
# FIRE on a planted copy in the same run.
#
#   K1  THE ONE EVAL SITE: `webview_eval` is called exactly once in src/**,
#       inside PWebHostSignalEval; nothing implements IWebView; proven to
#       fire on a planted second call
#   K2  THE ONE TEMPLATE: PWEB_SIGNAL_EVAL_TEMPLATE is the ratified literal
#       with one placeholder; the script's text appears once in src/**; the
#       eval site passes its own parameter and the channel's drain passes
#       PWebSignalScript's result, and nothing else reaches either
#   K3  the channel unit is platform-free and joins the zero-conditional core
#   K4  ONE CONSTANTS HOME: the native signal constants and both SDKs agree,
#       and the template dispatches the event both SDKs listen for
#   K5  THE HOOKS: single slot, one owner - the channel takes the policy's
#       grants slot, the host derives both seams from it and refuses a
#       composition that also sets one, the socket door no longer takes any
#   K6  NO PARKED WORKER: every wait in a decorator unit sits in a thread
#       body or a teardown path - the bound for an invocation is 0; proven
#       to fire on a planted wait in the socket receive
#   K7  waitMs RETIRED: refused by the door, sent by neither SDK, recorded in
#       the contract
#   K8  THE TEMPLATES compose the channel in every host and seat the socket
#       door on it inside PWEB_NET
#   K9  THE WORDING: the security model and the kernel describe the one
#       injected script, its exact shape and why it is not an authority
#   K10 12-5: the bridge publishes the caller for exactly the Uri() call, the
#       helper takes no owner, and the caller context has one reader
#   K11 FREEZE: the units this shard must not move are byte-identical
#   K12 QuickJS is out of scope: no script unit names the channel
#   K13 the instruments agree with the page: the hostile set, the topics
#
# Usage: pwsh test/cap16/check_cap16_contracts.ps1
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
# conditional is code. Strings are honoured (the CAP-15C helper, verbatim)
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
function PascalConst([string]$Code, [string]$Name) {
    $m = [regex]::Match($Code, "(?m)^\s*$Name\s*=\s*([^;]+);")
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value.Trim()
    if ($v -match "(?s)^'(.*)'$") { return $Matches[1] }
    return $v
}
# the name of the routine each offset of a Pascal text belongs to
function RoutineAt([string]$Code, [int]$Offset) {
    $best = '(unit level)'
    foreach ($m in [regex]::Matches($Code, '(?m)^(procedure|function|constructor|destructor)\s+([A-Za-z_][\w.]*)')) {
        if ($m.Index -le $Offset) { $best = $m.Groups[2].Value } else { break }
    }
    return $best
}

$channelUnit = 'src/rpc/pweb.rpc.signal.pas'
$socketUnit = 'src/rpc/pweb.rpc.socket.pas'
$hostUnit = 'src/webview/pweb.webview.host.pas'
$channelCode = StripComments (Read_ $channelUnit)
$hostCode = StripComments (Read_ $hostUnit)
$socketCode = StripComments (Read_ $socketUnit)
$srcFiles = @(Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc', '*.pp')

# --- K1: the one eval site ------------------------------------------------------
# a CALL is the identifier followed by an open parenthesis; the binding's
# external declaration is `function webview_eval(` and is excluded by shape
function EvalCalls([string]$Code) {
    return @([regex]::Matches($Code, '(?<![\w.])webview_eval\s*\(') | Where-Object {
        $before = $Code.Substring([math]::Max(0, $_.Index - 12), [math]::Min(12, $_.Index))
        $before -notmatch 'function\s+$'
    })
}
$evalSites = New-Object System.Collections.Generic.List[string]
foreach ($f in $srcFiles) {
    $code = StripComments ([System.IO.File]::ReadAllText($f.FullName))
    foreach ($m in (EvalCalls $code)) {
        $evalSites.Add("$(RelPath $f.FullName)::$(RoutineAt $code $m.Index)")
    }
}
if ($evalSites.Count -ne 1) {
    Violation "K1: src/** calls webview_eval $($evalSites.Count) time(s), expected exactly 1: $($evalSites -join ', ')"
} elseif ($evalSites[0] -ne "${hostUnit}::PWebHostSignalEval") {
    Violation "K1: the one webview_eval call is in $($evalSites[0]), not ${hostUnit}::PWebHostSignalEval"
}
# no implementation of IWebView exists to be a second path
foreach ($f in $srcFiles) {
    $code = StripComments ([System.IO.File]::ReadAllText($f.FullName))
    if ($code -match 'class\s*\([^)]*\bIWebView\b') {
        Violation "K1: $(RelPath $f.FullName) implements IWebView - its Eval would be a second site"
    }
}
# PROVEN TO FIRE: the host with a second call planted must count two
$planted = $hostCode + "`nprocedure Planted; begin webview_eval(nil, 'x'); end;`n"
$plantedCount = @(EvalCalls $planted).Count
if ($plantedCount -ne 2) {
    Violation "K1: the site count did not fire on a planted second call (counted $plantedCount)"
}
$report.Add("K1: eval_sites_release=$($evalSites.Count) ($($evalSites -join ', ')); planted twin counted $plantedCount")
$script:evalSitesRelease = $evalSites.Count

# --- K2: the one template ---------------------------------------------------------
$ratified = 'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:%}))'
$template = PascalConst $channelCode 'PWEB_SIGNAL_EVAL_TEMPLATE'
if ($null -eq $template) {
    # the declaration spans two lines: the name, then the literal
    $m = [regex]::Match($channelCode, "PWEB_SIGNAL_EVAL_TEMPLATE\s*=\s*'([^']*)'\s*;")
    if ($m.Success) { $template = $m.Groups[1].Value }
}
if ($template -cne $ratified) {
    Violation "K2: PWEB_SIGNAL_EVAL_TEMPLATE is '$template', not the ratified '$ratified'"
}
if (([regex]::Matches("$template", '%')).Count -ne 1) {
    Violation 'K2: the template does not carry exactly one placeholder'
}
$scriptText = 'window.dispatchEvent'
$textHits = 0
foreach ($f in $srcFiles) {
    $code = StripComments ([System.IO.File]::ReadAllText($f.FullName))
    $textHits += ([regex]::Matches($code, [regex]::Escape($scriptText))).Count
}
if ($textHits -ne 1) {
    Violation "K2: '$scriptText' appears $textHits time(s) in src/** code, expected once (the template)"
}
# the eval site evaluates its own parameter and nothing else
if ($hostCode -notmatch '(?s)procedure PWebHostSignalEval\(const Window: RawUtf8; const Script: RawUtf8\);.*?webview_eval\(webview_t\(handle\), PAnsiChar\(pointer\(Script\)\)\);') {
    Violation 'K2: PWebHostSignalEval does not hand webview_eval exactly its Script parameter'
}
# the seam is given to the channel and to nothing else
$evalRefs = ([regex]::Matches($hostCode, '@PWebHostSignalEval\b')).Count
if ($evalRefs -ne 1 -or $hostCode -notmatch 'signalView\.Eval\s*:=\s*@PWebHostSignalEval;') {
    Violation "K2: PWebHostSignalEval is referenced $evalRefs time(s); it must reach the channel's view only"
}
# the channel's one caller of its Eval seam, with PWebSignalScript's result
$seamCalls = ([regex]::Matches($channelCode, 'FView\.Eval\(')).Count
if ($seamCalls -ne 1) {
    Violation "K2: the channel calls its Eval seam $seamCalls time(s), expected once (the drain)"
}
if ($channelCode -notmatch '(?s)script\s*:=\s*PWebSignalScript\(pairs\);.*?FView\.Eval\(AWindowId,\s*script\);') {
    Violation 'K2: the drain does not evaluate exactly what PWebSignalScript built'
}
if ($channelCode -notmatch '(?s)function PWebSignalJsonString.*?\(c >= '' ''\) and\s*\(c <= ''~''\) and\s*not \(c in \[''"'', ''\\'', ''<'', ''>'', ''&'', ''''''''\]\)') {
    Violation 'K2: the encoder no longer escapes everything outside printable ASCII and the six breakout characters'
}
$report.Add("K2: the template is the ratified literal with one placeholder; its text appears $textHits time(s) in src/**; the eval site and the drain carry only PWebSignalScript output")

# --- K3: the channel unit is platform-free -------------------------------------------
if ($channelCode -notmatch '\{\$mode ObjFPC\}\{\$H\+\}') { Violation "K3: $channelUnit does not declare {`$mode ObjFPC}{`$H+}" }
if ($channelCode -match '\{\$if') { Violation "K3: $channelUnit carries a compiler conditional" }
foreach ($banned in 'mormot.net.', 'pweb.webview', 'pweb.lib.webview', 'pweb.platform',
                    'OSWINDOWS', 'MSWINDOWS', 'LINUX', 'DARWIN', 'PWEB_DEV') {
    if ($channelCode.Contains($banned)) { Violation "K3: $channelUnit names $banned" }
}
$divergence = Read_ 'test/cap7f/check_divergence.ps1'
if (-not $divergence.Contains("'src/rpc/pweb.rpc.signal.pas'")) {
    Violation 'K3: the channel unit is not on the CAP-7F zero-conditional core list'
}
$report.Add('K3: the channel unit names no webview, no platform, no mormot.net.*, carries no conditional, and is on the zero-conditional core list')

# --- K4: one constants home --------------------------------------------------------------
$tsSignal = Read_ 'sdk/typescript/src/signal.ts'
$p2j = StripComments (Read_ 'sdk/pas2js/pweb.native.pas')
function TsConst([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "(?m)^export const $Name\s*=\s*([^;]+);")
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim().Trim('"')
}
$names = 'PWEB_METHOD_SIGNAL_SUBSCRIBE', 'PWEB_METHOD_SIGNAL_UNSUBSCRIBE',
    'PWEB_SIGNAL_EVENT', 'PWEB_SIGNAL_FEATURE', 'PWEB_SIGNAL_TOPIC_SOCKET',
    'PWEB_SIGNAL_TICKS_PER_SECOND', 'PWEB_SIGNAL_MAX_SUBSCRIPTIONS',
    'PWEB_SIGNAL_MAX_TOPIC_BYTES'
foreach ($n in $names) {
    $native = PascalConst $channelCode $n
    $ts = TsConst $tsSignal $n
    $pas = PascalConst $p2j $n
    if ($null -eq $native) { Violation "K4: $channelUnit does not define $n"; continue }
    if ($ts -cne $native) { Violation "K4: @pweb/runtime $n = '$ts', the native one '$native'" }
    if ($pas -cne $native) { Violation "K4: the Pas2JS SDK $n = '$pas', the native one '$native'" }
}
if (-not "$template".Contains('"' + (PascalConst $channelCode 'PWEB_SIGNAL_EVENT') + '"')) {
    Violation 'K4: the template does not dispatch PWEB_SIGNAL_EVENT'
}
# the bounds are consistent with each other and with the capability bound
$maxTopic = [int](PascalConst $channelCode 'PWEB_SIGNAL_MAX_TOPIC_BYTES')
$capMax = [int](PascalConst (StripComments (Read_ 'src/security/pweb.capabilities.policy.pas')) 'PWEB_CAPABILITY_MAX_BYTES')
if ($maxTopic + 'signal.'.Length -gt $capMax) {
    Violation "K4: a $maxTopic-byte topic's capability would exceed PWEB_CAPABILITY_MAX_BYTES ($capMax)"
}
if ((PascalConst $channelCode 'PWEB_SIGNAL_TICK_MS') -notmatch '^1000 div PWEB_SIGNAL_TICKS_PER_SECOND$') {
    Violation 'K4: PWEB_SIGNAL_TICK_MS is not derived from the tick rate'
}
$report.Add("K4: $($names.Count) constants agree across the channel, @pweb/runtime and the Pas2JS SDK; the template dispatches the SDKs' event")

# --- K5: the hooks ---------------------------------------------------------------------
$grantsWriters = New-Object System.Collections.Generic.List[string]
foreach ($f in $srcFiles) {
    $code = StripComments ([System.IO.File]::ReadAllText($f.FullName))
    # a WRITE of a subscriber; giving the slot back (`:= nil`) is not one
    foreach ($m in [regex]::Matches($code, 'OnGrantsChanged\s*:=\s*(?!nil\b)[@A-Za-z_]')) {
        $grantsWriters.Add("$(RelPath $f.FullName)::$(RoutineAt $code $m.Index)")
    }
}
if (($grantsWriters -join ',') -ne "${channelUnit}::TPWebSignalChannel.AttachPolicy") {
    Violation "K5: the policy's grants slot is taken by [$($grantsWriters -join ', ')], expected only the channel's AttachPolicy"
}
if ($socketCode -match 'procedure\s+TPWebSocketBridge\.AttachPolicy' -or $socketCode.Contains('OnGrantsChanged')) {
    Violation 'K5: the socket door still takes or reads the policy grants slot itself'
}
foreach ($needle in 'documentReplacing := signals.DocumentReplacing;',
                    'beforeDrain := signals.BeforeDrain;',
                    'signals.AttachPolicy(Policy);',
                    'Options.Signals.AttachView(signalView);',
                    'HostDocumentReplacing := documentReplacing;',
                    'beforeDrain();') {
    if (-not $hostCode.Contains($needle)) { Violation "K5: the host does not carry: $needle" }
}
if ($hostCode -notmatch '(?s)if Assigned\(Options\.DocumentReplacing\) or\s*Assigned\(Options\.BeforeDrain\) then\s*raise') {
    Violation 'K5: the host does not refuse a composition that sets a seam the channel owns'
}
if ($socketCode -notmatch 'ASignals\.AttachDoor\(Door\);') {
    Violation 'K5: the socket door does not take the channel''s one door slot'
}
$report.Add('K5: the grants slot has one writer (the channel), the host derives both seams from it and refuses a second owner, the socket door sits on the channel')

# --- K6: no parked worker -------------------------------------------------------------
$decoratorUnits = [ordered]@{
    'src/rpc/pweb.rpc.socket.pas'  = @('TPWebSocketKeeper.Execute', 'TPWebSocketBridge.Destroy', 'TPWebSocketBridge.BeforeDrain')
    'src/rpc/pweb.rpc.signal.pas'  = @('TPWebSignalPacer.Execute', 'TPWebSignalChannel.Destroy', 'TPWebSignalChannel.BeforeDrain')
    'src/rpc/pweb.rpc.fetch.pas'   = @()
    'src/rpc/pweb.rpc.command.pas' = @()
    'src/rpc/pweb.rpc.mormot.pas'  = @()
    'src/rpc/pweb.rpc.caller.pas'  = @()
}
$waitRx = '(?<![\w])(WaitFor|RTLEventWaitFor|Sleep|SleepHiRes|WaitForSingleObject|WaitForThreadTerminate)\s*[\(;]'
function WaitSites([string]$Code) {
    return @([regex]::Matches($Code, $waitRx) | ForEach-Object { RoutineAt $Code $_.Index })
}
$waitCount = 0
foreach ($u in $decoratorUnits.Keys) {
    $code = StripComments (Read_ $u)
    foreach ($r in (WaitSites $code)) {
        $waitCount++
        if ($decoratorUnits[$u] -notcontains $r) {
            Violation "K6: $u waits inside $r - an invocation of a decorator may not wait on anything (bound 0)"
        }
    }
}
# PROVEN TO FIRE: the socket receive with CAP-15C's park put back, right
# where the take begins
$lfSocket = $socketCode.Replace("`r`n", "`n")
$receiveAt = $lfSocket.IndexOf('function TPWebSocketBridge.Receive(', [System.StringComparison]::Ordinal)
$takeAt = if ($receiveAt -ge 0) { $lfSocket.IndexOf('    closeTaken := False;', $receiveAt, [System.StringComparison]::Ordinal) } else { -1 }
$plantedSocket = if ($takeAt -ge 0) { $lfSocket.Insert($takeAt, "    e.Arrived.WaitFor(20);`n") } else { $lfSocket }
$plantedSites = @(WaitSites $plantedSocket)
$firing = @($plantedSites | Where-Object { $decoratorUnits['src/rpc/pweb.rpc.socket.pas'] -notcontains $_ })
if ($firing.Count -lt 1 -or $firing[0] -ne 'TPWebSocketBridge.Receive') {
    Violation "K6: the wait sweep did not fire on a wait planted in TPWebSocketBridge.Receive (found: $($firing -join ', '))"
}
# the transports' waits are the engine's, under their own deadlines - listed
$transportWaits = @(WaitSites (StripComments (Read_ 'src/rpc/pweb.rpc.socket.mormot.pas'))) + @(WaitSites (StripComments (Read_ 'src/rpc/pweb.rpc.fetch.mormot.pas')))
$report.Add("K6: $waitCount wait(s) in the decorator units, all in thread bodies or teardown; planted receive wait fired in $($firing -join ','); transport waits (engine bounds): $($transportWaits.Count)")

# --- K7: waitMs retired --------------------------------------------------------------------
if ($socketCode -notmatch "(?s)if a\[sanWaitMs\]\.Kind <> sakAbsent then\s*if not ArgInteger\(a\[sanWaitMs\], waitMs\) or\s*\(waitMs <> 0\) then\s*exit\(Invalid\('waitMs is retired") {
    Violation 'K7: the socket door does not refuse a nonzero waitMs'
}
# THE SHIPPED SDK, not its suite. The claim is that neither SDK SENDS the
# argument, and a test that proves the door refuses it - or a comment that
# says what replaced it - has to be able to spell the name. Everything a
# consumer compiles is swept; `test/` is where the retirement is asserted.
$sdkShipped = @(& git ls-files -- sdk |
    Where-Object { $_ -match '\.(ts|pas)$' -and $_ -notmatch '(^|/)test/' })
foreach ($f in $sdkShipped) {
    if ((Read_ $f) -match 'waitMs') {
        Violation "K7: $f still names waitMs - neither SDK sends it"
    }
}
if ($sdkShipped.Count -lt 4) {
    Violation "K7: the shipped-SDK sweep covered only $($sdkShipped.Count) file(s)"
}
$cliContract = Read_ 'docs/cli-contract.md'
foreach ($phrase in '`waitMs` is retired', 'pweb.socket', 'PWEB_SOCKET_KEEPALIVE_MS') {
    if (-not $cliContract.Contains($phrase)) { Violation "K7: docs/cli-contract.md does not record: $phrase" }
}
$report.Add('K7: socket_receive_waitms=removed - the door refuses it, neither SDK names it, the contract records it')

# --- K8: the templates ----------------------------------------------------------------------
foreach ($tpl in 'tools/templates/react/src/program.lpr', 'tools/templates/pas2js/src/program.lpr') {
    $text = Read_ $tpl
    foreach ($needle in 'pweb.rpc.signal,', 'signals := TPWebSignalChannel.Create(runtimeBridge, AppSignalTopics);',
                        'runtimeBridge := signals;', 'options.Signals := signals;',
                        'socketBridge.AttachSignals(signals);') {
        if (-not $text.Contains($needle)) { Violation "K8: $tpl does not carry: $needle" }
    }
    foreach ($banned in 'options.DocumentReplacing', 'options.BeforeDrain', 'AttachPolicy') {
        if ($text.Contains($banned)) { Violation "K8: $tpl still sets $banned - the channel owns the seams" }
    }
    # the channel is composed OUTSIDE PWEB_NET, the door's seat INSIDE it
    $inNet = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_NET\}') { $inNet = $true; continue }
        if ($line -match '\{\$endif\s+PWEB_NET\}') { $inNet = $false; continue }
        if ($line -match 'TPWebSignalChannel\.Create|options\.Signals' -and $inNet) {
            Violation "K8: ${tpl}:${lineNo} composes the channel inside PWEB_NET - every host has one"
        }
        if ($line -match 'AttachSignals' -and -not $inNet) {
            Violation "K8: ${tpl}:${lineNo} seats the socket door outside PWEB_NET"
        }
    }
}
foreach ($tpl in 'tools/templates/react/src/app.services.pas', 'tools/templates/pas2js/src/app.services.pas') {
    $text = Read_ $tpl
    foreach ($needle in 'function AppSignalTopics: TRawUtf8DynArray;',
                        'b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_SUBSCRIBE);',
                        'b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_UNSUBSCRIBE);') {
        if (-not $text.Contains($needle)) { Violation "K8: $tpl does not carry: $needle" }
    }
}
$report.Add('K8: both templates compose the channel in every host and seat the socket door on it inside PWEB_NET')

# --- K9: the wording -----------------------------------------------------------------------
$model = Read_ '_bmad-output/specs/spec-pweb/security-model.md'
$kernel = Read_ 'docs/kernel.md'
foreach ($phrase in '## The one injected script', $ratified, 'PWebHostSignalEval',
                    'carries no authority', 'pweb:signal', 'signal.<topic>') {
    if (-not $model.Contains($phrase)) { Violation "K9: security-model.md does not carry: $phrase" }
}
foreach ($phrase in 'PWEB_SIGNAL_EVAL_TEMPLATE', 'one `webview_eval`', 'not an authority channel') {
    if (-not $kernel.Contains($phrase)) { Violation "K9: docs/kernel.md does not carry: $phrase" }
}
$report.Add('K9: the security model and the kernel describe the one injected script, its shape and why it grants nothing')

# --- K10: 12-5 --------------------------------------------------------------------------------
$mormotCode = StripComments (Read_ 'src/rpc/pweb.rpc.mormot.pas')
if ($mormotCode -notmatch '(?s)previous := CallerContext;\s*CallerContext := @Context;\s*try\s*FServer\.Uri\(call\);\s*finally\s*CallerContext := previous;') {
    Violation 'K10: the bridge does not publish the caller for exactly the Uri() call'
}
$readers = @([regex]::Matches($mormotCode, '(?<![\w])CallerContext(?!\s*:=)') | ForEach-Object { RoutineAt $mormotCode $_.Index } | Sort-Object -Unique)
if (($readers -join ',') -ne 'PWebCallerPrincipal,TMormotInvocationBridge.Invoke') {
    Violation "K10: the caller context is read by [$($readers -join ', ')], expected PWebCallerPrincipal (and the bridge saving it)"
}
if ($mormotCode -notmatch 'function Invoke\(const Context: TInvocationContext;\s*const Method: Utf8String; const Args: TPWebJson;\s*const Token: ICancellationToken\): TPWebInvocationResult;') {
    Violation 'K10: the bridge signature moved'
}
$callerCode = StripComments (Read_ 'src/rpc/pweb.rpc.caller.pas')
if ($callerCode -notmatch 'function PWebCallerBlobPut\(const Store: IBlobStore;\s*const Content: RawByteString; const ContentType: RawUtf8;\s*out Handle: RawUtf8; out Ceiling: TPWebBlobCeiling\): Boolean;') {
    Violation 'K10: PWebCallerBlobPut is not the ratified owner-free signature'
}
if ($callerCode -notmatch 'PWebCallerPrincipal\(owner\)') {
    Violation 'K10: PWebCallerBlobPut does not take its owner from the caller context'
}
$report.Add('K10: the caller is published around Uri() only, has one reader, and the blob helper takes no owner')

# --- K11: the freeze ------------------------------------------------------------------------
$frozen = [ordered]@{
    'src/rpc/pweb.rpc.fetch.pas'                       = 'a158a35aaf247f0c494b779d08953eb10ca38af57144d7fd8d917cebe8ff50e9'
    'src/rpc/pweb.rpc.fetch.mormot.pas'                = 'ec99cd5bce86921450a4089210935b2cc5d2d50b32818223be0801cced792fbc'
    'src/platform/macos/pweb.platform.cocoa.fetch.pas' = '1fda306723431e1136db90b3d79f80e0b89d9c23d7110cf9331839be11a98143'
    'src/assets/pweb.blobs.intf.pas'                   = '3302431305f90172c58a7a166e00cbec8d92d726c7a1d35ccdc09bab0d7d6055'
    'src/assets/pweb.blobs.memory.pas'                 = '9dfa80fb10aa90a8b05597fb289137e656b4c7660f9f258e12241d8ce2903df6'
    'src/assets/pweb.blobs.protocol.pas'               = 'c4c7b98997deb4478294a9e4b6ebfce16b04e0319997514c4d32506087e3d1e0'
    'src/security/pweb.navigation.policy.pas'          = 'cc90c0e7efe13d56ade5238d5c8eb17cbe7b463c7bd0c57dd26309f9b7070dbb'
    'src/security/pweb.capabilities.policy.pas'        = '6d0ef19667c7902c863ba61ac083b7411a2b6eb04abdb9626486c8f56eb812f8'
    'src/webview/pweb.webview.intf.pas'                = '924a3ccf90440d249def1cdee2739427835fea37da5ce58811fa59470bacef1c'
    'src/rpc/pweb.rpc.intf.pas'                        = 'f3f658dfb7f8aadb95ed49683a80859dacb4d3809255542675382fd6e0539fb4'
    'src/rpc/pweb.rpc.scheduler.pas'                   = '6820487fc71d7be42786f45877ab375821eca1fd571f9bd36fc8fc5a6610a1d1'
    'src/webview/pweb.webview.binding.pas'             = '2f1b58fe9721fdd034f33607b91c11d9b26a2e74126c49bf2a3b13f3f837aece'
    'src/rpc/pweb.rpc.command.pas'                     = '2b279c63e97e1a09d9398f26b95b1f3abc51ca6ea62f4541391882553056b8cf'
    'src/assets/pweb.assets.intf.pas'                  = '2f86ff6e03f7e43dcee51723f006f856a379283a2afa8a5ff4e43bfb27e3fa74'
}
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    foreach ($f in $frozen.Keys) {
        $text = (Read_ $f).Replace("`r`n", "`n")
        $got = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
            ForEach-Object { $_.ToString('x2') })
        if ($got -cne $frozen[$f]) {
            Violation "K11: $f is not byte-identical to what CAP-16 froze (LF sha256 $got)"
        }
    }
} finally { $sha.Dispose() }
$intfCode = StripComments (Read_ 'src/webview/pweb.webview.intf.pas')
$webviewMethods = @([regex]::Matches(([regex]::Match($intfCode, '(?s)IWebView = interface.*?\bend;')).Value, '(?m)^\s*(procedure|function)\s+(\w+)') | ForEach-Object { $_.Groups[2].Value })
if (($webviewMethods -join ',') -ne 'SetTitle,SetSize,Navigate,SetHtml,Eval,Run,Terminate,Dispatch') {
    Violation "K11: IWebView's method set is [$($webviewMethods -join ', ')]"
}
if ((PascalConst (StripComments (Read_ 'src/rpc/pweb.rpc.intf.pas')) 'PWEB_PROTOCOL_VERSION') -ne '1') {
    Violation 'K11: PWEB_PROTOCOL_VERSION moved'
}
$report.Add("K11: $($frozen.Count) frozen units byte-identical (the CSP's navigation policy among them); IWebView is its eight methods; protocol 1")

# --- K12: QuickJS is out of scope --------------------------------------------------------------
foreach ($f in @(Get-ChildItem src/script -File -Filter '*.pas')) {
    if ((StripComments ([System.IO.File]::ReadAllText($f.FullName))).Contains('pweb.rpc.signal')) {
        Violation "K12: $(RelPath $f.FullName) names the signal channel - QuickJS subscriptions are out of scope (9A-2)"
    }
}
$report.Add('K12: no script unit names the channel (QuickJS out of scope, 9A-2)')

# --- K13: the instruments agree with their pages ------------------------------------------------
$probe = StripComments (Read_ 'test/cap16/evalprobe.pas')
$probePage = Read_ 'test/cap16/fixture/probe/probe.js'
$nativeCases = ([regex]::Matches($probe, '(?m)^\s*Hostile\[\d+\]\s*:=')).Count
$pageCases = ([regex]::Match($probePage, '(?s)var HOSTILE = \[(.*?)\n  \];')).Groups[1].Value -split "`n" | Where-Object { $_.Trim() -ne '' } | Measure-Object | Select-Object -ExpandProperty Count
if ($nativeCases -ne [int](PascalConst $probe 'HOSTILE_COUNT') -or $pageCases -ne $nativeCases) {
    Violation "K13: the probe has $nativeCases hostile case(s), HOSTILE_COUNT $(PascalConst $probe 'HOSTILE_COUNT'), the page $pageCases"
}
if ((Read_ 'test/cap16/fixture/live/live.js') -match '__pweb_invoke') {
    Violation 'K13: the live page calls the raw primitive - raw_primitive_used must stay false'
}
$report.Add("K13: $nativeCases hostile cases on both sides of the probe; the live page uses the SDK only")

# --- verdict ---------------------------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap16 | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-16 contract cross-checks')
foreach ($r in $report) { $lines.Add("# $r") }
$lines.Add("eval_sites_release=$($script:evalSitesRelease)")
if ($violations.Count -eq 0) {
    $lines.Add('VERDICT: PASS')
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap16/contracts.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
foreach ($r in $report) { Write-Host "[CAP-16] $r" }
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-16 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-16] contracts PASS - one eval site, one template, one owner per hook, no parked worker, waitMs retired'
