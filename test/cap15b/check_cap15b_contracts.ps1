# CAP-15B: the source contract cross-checks.
#
# Checkout-only: no build, no toolchain, no network. Everything here is a
# property of the SOURCE that a built image cannot show, and every one of
# them is a rule CAP-15A ratified rather than a preference:
#
#   C1  the two fetch units exist, and the DECORATOR carries no mormot.net.*
#       unit, no compiler conditional and no operating system - the CAP-7F
#       zero-conditional core list gains it
#   C2  EXACTLY ONE file in src/** names `mormot.net.client`, and it is
#       src/rpc/pweb.rpc.fetch.mormot.pas
#   C3  the transport reaches mORMot only through Create + OpenBind. The
#       convenient entry points - OpenUri, OpenOptions, TSimpleHttpClient,
#       HttpGet, HttpPost - inherit THE SYSTEM PROXY through
#       THttpRequestExtendedOptions.Proxy, whose default '' means "use it",
#       so they are forbidden BY NAME (ledger 15A-7)
#   C4  no TLS relaxation identifier appears in the fetch units. The
#       spellings are mORMot's REAL ones - IgnoreCertificateErrors (37
#       occurrences in deps/mormot2), IgnoreTlsCertError (3) and
#       aIgnoreTlsCertificateErrors - and not the one §7.3 named, which
#       occurs in mORMot only as that last parameter name and would have
#       swept vacuously
#   C5  the retry suppression is present: AsRetry := true at the one call
#       site (ledger 15A-4)
#   C6  NO `https://` ORIGIN LITERAL anywhere in src/**. The allowlist is
#       generated into an application, never present in the runtime. Pascal
#       COMMENTS are stripped first: four of them explain what the product
#       refuses, and two of those sit inside quotes within the comment, so a
#       gate that could not tell a literal from its explanation would forbid
#       the explanation
#   C7  the fetch units carry NO PWEB_DEV region and NO full loopback ORIGIN
#       literal, and the two loopback HOSTS are named only by the origin
#       grammar - which is what accepts them. The ratified exception is a
#       property of what is COMPILED INTO the allowlist, not of how the
#       allowlist is compared, so there is no branch here to fence and none
#       to compile in by accident. What a release IMAGE carries is the
#       stronger proof, and it lives in the gates
#   C8  both generated program.lpr templates install the decorator ONLY
#       inside the region the descriptor's origins control, and both
#       app.services.pas templates grant `network.fetch` only there
#   C9  the witness binary test/cap15b/nethost.pas carries the SAME three
#       constructs as the templates, so it cannot drift from what a real
#       generated host compiles
#   C10 the CLI selects the network define from ONE place, exactly as it
#       selects PWEB_DEV, and pushes it IFF the origin set is non-empty
#   C11 the six zero-transport sweeps are RE-SCOPED rather than deleted:
#       each one's header carries the CAP-15B claim
#
# Usage: pwsh test/cap15b/check_cap15b_contracts.ps1
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

# Pascal comments, removed: `//` to end of line, `{ }` and `(* *)`. Strings
# are honoured, so a `//` inside a literal is not a comment
function StripPascalComments([string]$Text) {
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

$decorator = 'src/rpc/pweb.rpc.fetch.pas'
$transport = 'src/rpc/pweb.rpc.fetch.mormot.pas'
$darwin = 'src/platform/macos/pweb.platform.cocoa.fetch.pas'

# --- C1: the decorator is platform-free and transport-free -----------------
foreach ($f in $decorator, $transport, $darwin) {
    if (-not (Test-Path $f)) { Violation "CAP-15B unit is missing: $f" }
}
$decText = Read_ $decorator
$decCode = StripPascalComments $decText
foreach ($banned in 'mormot.net.', '{$ifdef', '{$ifndef', '{$else',
                    'OSWINDOWS', 'DARWIN', 'LINUX', 'MSWINDOWS') {
    if ($decCode.Contains($banned)) {
        Violation ("the fetch decorator names ${banned}: it is on the CAP-7F " +
            'zero-conditional core list and its whole claim is that the ' +
            'transport is injected')
    }
}
# {$mode} and {$H+} are the unit's own dialect, not a conditional
if ($decText -notmatch '\{\$mode ObjFPC\}\{\$H\+\}') {
    Violation "$decorator does not declare {`$mode ObjFPC}{`$H+}"
}
$report.Add('C1: the decorator carries no mormot.net.*, no conditional, no OS')

# --- C2: EXACTLY ONE file in src/** names mormot.net.client ----------------
$netClientFiles = @(Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc' |
    Where-Object { (StripPascalComments ([System.IO.File]::ReadAllText($_.FullName))).Contains('mormot.net.client') } |
    ForEach-Object { ($_.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/' })
if ($netClientFiles.Count -ne 1) {
    Violation ("$($netClientFiles.Count) file(s) in src/** name mormot.net.client, " +
        "expected exactly 1: $($netClientFiles -join ', ')")
} elseif ($netClientFiles[0] -ne $transport) {
    Violation "the one file naming mormot.net.client is $($netClientFiles[0]), not $transport"
}
$report.Add("C2: mormot.net.client is named by exactly one src file ($($netClientFiles -join ','))")

# --- C3/C4/C5: the transport's own rules -----------------------------------
$trText = Read_ $transport
$trCode = StripPascalComments $trText
foreach ($banned in 'OpenUri', 'OpenOptions', 'TSimpleHttpClient',
                    'HttpGet', 'HttpPost') {
    if ($trCode -match "(?<![A-Za-z0-9_])$banned\s*\(") {
        Violation ("the transport CALLS ${banned}: its options carry " +
            'THttpRequestExtendedOptions.Proxy, whose default means "use the ' +
            'system proxy" (ledger 15A-7)')
    }
}
foreach ($banned in 'IgnoreCertificateErrors', 'IgnoreTlsCertError',
                    'aIgnoreTlsCertificateErrors', 'AllowDeprecatedTls') {
    foreach ($f in $decorator, $transport, $darwin) {
        $code = StripPascalComments (Read_ $f)
        if ($code.Contains($banned)) {
            Violation "$f names the TLS relaxation ${banned}"
        }
    }
}
if ($trCode -notmatch 'OpenBind\s*\(') {
    Violation 'the transport does not reach mORMot through OpenBind'
}
# the RAW text, not the stripped code: `{AsRetry=}` is an argument-naming
# comment, which is precisely how this repository makes a bare boolean
# readable at a call site, and stripping comments would strip the marker
if ($trText -notmatch '\{AsRetry=\}true') {
    Violation ('the transport does not pass AsRetry := true - mORMot re-sends ' +
        'a failed request by itself (ledger 15A-4)')
}
if ($trCode -notmatch 'RedirectMax\s*:=\s*0') {
    Violation 'the transport does not set RedirectMax := 0'
}
$report.Add('C3/C4/C5: Create+OpenBind, AsRetry true, RedirectMax 0, no TLS relaxation')

# --- C6: no https:// ORIGIN literal anywhere in src/** ---------------------
# an ORIGIN shape, over code with its comments removed. Four `https://`
# occurrences live in src/** today and every one of them is a comment
$originRx = '^https?://[a-z0-9.\-]+(:\d+)?/?$'
foreach ($file in (Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc')) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
    $code = StripPascalComments ([System.IO.File]::ReadAllText($file.FullName))
    foreach ($m in [regex]::Matches($code, "'((?:[^']|'')*)'")) {
        $v = $m.Groups[1].Value
        if ($v -match $originRx) {
            Violation ("an ORIGIN literal appears in the runtime: ${rel}: $v - " +
                'the allowlist is generated into an application, never present here')
        }
    }
}
$report.Add('C6: no origin literal in src/** (comments stripped first)')

# --- C7: the fetch units carry no loopback literal at all ------------------
foreach ($f in $decorator, $transport, $darwin) {
    $code = StripPascalComments (Read_ $f)
    foreach ($needle in 'http://127.0.0.1', 'http://localhost') {
        if ($code.Contains($needle)) {
            Violation ("$f carries a full loopback ORIGIN literal ${needle}: " +
                'the compiled allowlist is where a loopback origin may live, ' +
                'never the source of the door')
        }
    }
    if ($code.Contains('PWEB_DEV')) {
        Violation "$f branches on PWEB_DEV: the fetch units have no development mode"
    }
}
# the two hosts are named ONLY by the grammar that accepts them - the parser
# and the loopback predicate - and by nothing else in the door
$decOnly = StripPascalComments $decText
foreach ($needle in '127.0.0.1', 'localhost') {
    $hits = ([regex]::Matches($decOnly, [regex]::Escape($needle))).Count
    if ($hits -gt 2) {
        Violation ("the decorator names $needle $hits times: the grammar " +
            'accepts it in exactly two places and nothing else may')
    }
}
foreach ($f in $transport, $darwin) {
    $code = StripPascalComments (Read_ $f)
    foreach ($needle in '127.0.0.1', 'localhost') {
        if ($code.Contains($needle)) {
            Violation "$f names the loopback host ${needle}: only the grammar may"
        }
    }
}
$report.Add('C7: no PWEB_DEV region, no loopback origin literal, hosts named only by the grammar')

# --- C8/C9: the templates, and the witness that must not drift -------------
$templates = @('tools/templates/react/src/program.lpr',
               'tools/templates/pas2js/src/program.lpr')
foreach ($tpl in $templates) {
    $text = Read_ $tpl
    foreach ($needle in 'pweb.rpc.fetch', '{$I app.network.inc}',
                        'TPWebFetchBridge.Create', 'APP_NETWORK_ORIGINS',
                        'PWebFetchNativeTransport') {
        if (-not $text.Contains($needle)) {
            Violation "$tpl does not carry the CAP-15B construct: $needle"
        }
    }
    # and every one of them must be INSIDE the PWEB_NET region
    $inNet = $false
    $sawRegion = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_NET\}') { $inNet = $true; $sawRegion = $true; continue }
        if ($line -match '\{\$endif\s+PWEB_NET\}') { $inNet = $false; continue }
        if ((-not $inNet) -and
            ($line -match 'pweb\.rpc\.fetch|TPWebFetchBridge|APP_NETWORK_|app\.network\.inc')) {
            Violation ("the generated program names the network door OUTSIDE " +
                "its PWEB_NET region: ${tpl}:${lineNo}")
        }
    }
    if (-not $sawRegion) { Violation "$tpl carries no PWEB_NET region" }
}
foreach ($tpl in @('tools/templates/react/src/app.services.pas',
                   'tools/templates/pas2js/src/app.services.pas')) {
    $text = Read_ $tpl
    if (-not $text.Contains('PWEB_CAP_NETWORK_FETCH')) {
        Violation "$tpl does not grant network.fetch under PWEB_NET"
    }
    $inNet = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_NET\}') { $inNet = $true; continue }
        if ($line -match '\{\$else\}') { $inNet = $false; continue }
        if ($line -match '\{\$endif\s+PWEB_NET\}') { $inNet = $false; continue }
        if ((-not $inNet) -and
            ($line -match 'PWEB_CAP_NETWORK_FETCH|PWEB_METHOD_FETCH|pweb\.rpc\.fetch')) {
            Violation ("the generated policy names the door OUTSIDE its " +
                "PWEB_NET region: ${tpl}:${lineNo}")
        }
    }
}
$witness = Read_ 'test/cap15b/nethost.pas'
foreach ($needle in 'pweb.rpc.fetch', '{$I app.network.inc}',
                    'TPWebFetchBridge.Create', 'APP_NETWORK_ORIGINS',
                    'PWebFetchNativeTransport', 'APP_NETWORK_ALLOWLIST_DIGEST') {
    if (-not $witness.Contains($needle)) {
        Violation ("test/cap15b/nethost.pas does not carry ${needle}: the " +
            'witness binary must compile what a generated host compiles, or ' +
            'the image proofs are proofs about the witness')
    }
}
$report.Add('C8/C9: both templates and the witness carry the same fenced region')

# --- C10: the network define reaches a compiler from ONE place -------------
$toolchain = Read_ 'tools/pweb/pweb.cli.toolchain.pas'
if ($toolchain -notmatch "(?m)^\s*PWEB_CLI_NETWORK_DEFINE\s*=\s*'PWEB_NET'\s*;") {
    Violation "pweb.cli.toolchain does not define PWEB_CLI_NETWORK_DEFINE = 'PWEB_NET'"
}
$native = Read_ 'tools/pweb/pweb.cli.native.pas'
if ($native -notmatch "'-d'\s*\+\s*PWEB_CLI_NETWORK_DEFINE") {
    Violation ('pweb.cli.native does not build the network define from ' +
        'PWEB_CLI_NETWORK_DEFINE: the region must be selected in one place')
}
if ($native -notmatch 'if Length\(Project\.NetworkOrigins\) > 0 then') {
    Violation ('pweb.cli.native does not push the network define IFF the ' +
        'origin set is non-empty')
}
$pipeline = Read_ 'tools/pweb/pweb.cli.pipeline.pas'
if (-not $pipeline.Contains('network_origin_loopback_release')) {
    Violation ('pweb.cli.pipeline does not refuse a loopback origin at a ' +
        'RELEASE build - an origin that vanished between `pweb dev` and ' +
        '`pweb build` is a behaviour difference with no message anywhere')
}
$report.Add('C10: PWEB_NET is spelled once and pushed iff origins are declared')

# --- C11: the six zero-transport sweeps are RE-SCOPED ----------------------
$sweeps = @('test/cap7l/check_cap7l_nonetwork.sh',
            'test/cap7m/check_cap7m_nonetwork.sh',
            'test/cap5/check_cap5_nonetwork.ps1',
            'test/cap6/check_cap6_nonetwork.ps1',
            'test/cap9c1/run_quickjsrelease.ps1',
            '.github/actions/cap-4-zero-http-asset-serving-source-proof/action.yml')
foreach ($s in $sweeps) {
    $text = Read_ $s
    if (-not $text.Contains('pweb.rpc.fetch.mormot')) {
        Violation ("$s does not carry the CAP-15B re-scoping: its claim is now " +
            '"no listening socket, no server, no second RPC path, and the only ' +
            'outbound client in the image is pweb.rpc.fetch.mormot, reachable ' +
            'only through network.fetch"')
    }
}
$report.Add("C11: all $($sweeps.Count) zero-transport sweeps carry the re-scoped claim")

# --- C13: the Cocoa bridge compiles under -Werror -Wcomment -----------------
#
# MEASURED, and it cost a hosted macOS leg. This shard's addition to
# `src/platform/macos/pweb_cocoa_bridge.h` documented the transport split in a
# banner comment and wrote the phrase `exactly one file in src/** names
# mormot.net.client`. `src/**` contains `/*`, the banner is a block comment,
# and `test/cap7m1` compiles the bridge with `-Werror`:
#
#   pweb_cocoa_bridge.h:523:53: error: '/*' within block comment
#     [-Werror,-Wcomment]
#
# There is no macOS on the development host, so the only instrument that could
# have caught it before the push is a source rule. This is that rule, and it
# covers BOTH shapes `-Wcomment` refuses: a `/*` opened inside an already-open
# block comment, and a `//` comment continued onto the next line with a
# trailing backslash.
$cocoaSources = @(Get-ChildItem 'src/platform/macos' -File -Include '*.h', '*.mm', '*.m' -Recurse |
    Sort-Object FullName)
$commentHits = 0
foreach ($f in $cocoaSources) {
    $rel = ($f.FullName.Substring($repoRoot.Length).TrimStart([char]92, [char]47)).Replace([char]92, [char]47)
    $inBlock = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
        $lineNo++
        $i = 0
        while ($i -lt $line.Length - 1) {
            $two = $line.Substring($i, 2)
            if ($inBlock) {
                if ($two -eq '*/') { $inBlock = $false; $i += 2; continue }
                if ($two -eq '/*') {
                    $commentHits++
                    Violation ("C13: ${rel}:${lineNo}: '/*' inside an open block " +
                        "comment -- clang refuses this under -Werror,-Wcomment, " +
                        'and the macOS bridge is compiled that way')
                    $i += 2; continue
                }
                $i++; continue
            }
            if ($two -eq '/*') { $inBlock = $true; $i += 2; continue }
            if ($two -eq '//') {
                if ($line.TrimEnd().EndsWith('\')) {
                    $commentHits++
                    Violation ("C13: ${rel}:${lineNo}: a // comment continued by a " +
                        'trailing backslash -- -Wcomment refuses it')
                }
                break
            }
            $i++
        }
    }
}
$report.Add("C13: $($cocoaSources.Count) Cocoa source(s) swept for -Wcomment shapes; $commentHits hit(s)")

# --- C12: the committed mORMot define set IS the pinned one -----------------
#
# `test/cap7f/check_mormot_defines.ps1` refuses an always-false conditional -
# a directive testing a symbol only `mormot.defines.inc` defines, in a file
# that does not include it. That sweep runs in the CHECKOUT-ONLY job beside
# `check_divergence`, which is where it belongs and which has no `deps/`
# tree, so its symbol set is committed as `test/cap7f/mormot-defines.tsv`.
#
# A committed list nothing checks is a list that goes stale silently, and the
# sweep would then keep passing over a symbol mORMot had added. THIS is the
# check: every platform leg carries the real pin (the mORMot fetch runs long
# before this gate), so every platform leg re-derives the set and compares.
# Four targets, four independent corroborations, and a repin that moves the
# set turns all four red until the file is regenerated in the same commit.
$listPath = 'test/cap7f/mormot-defines.tsv'
$definesInc = 'deps/mormot2/src/mormot.defines.inc'
if (-not (Test-Path $listPath)) {
    Violation "$listPath is absent -- the always-false-conditional sweep has no symbol set"
} elseif (-not (Test-Path $definesInc)) {
    Violation ("$definesInc is absent, so the committed define set could not be " +
        'corroborated against the pin -- this gate runs after the mORMot fetch ' +
        'on every leg, and the corroboration is the whole of C12')
} else {
    $committed = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $pinShaClaimed = ''
    foreach ($l in [System.IO.File]::ReadAllLines($listPath)) {
        if ($l -match '^#\s*pin-sha256\s+([0-9a-f]{64})\s*$') { $pinShaClaimed = $Matches[1]; continue }
        if ($l -match '^\s*#' -or $l.Trim() -eq '') { continue }
        [void]$committed.Add($l.Trim())
    }
    $live = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($definesInc),
            '\{\$define\s+([A-Za-z_][A-Za-z0-9_]*)\s*\}',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$live.Add($m.Groups[1].Value)
    }
    $added = @($live | Where-Object { -not $committed.Contains($_) } | Sort-Object)
    $removed = @($committed | Where-Object { -not $live.Contains($_) } | Sort-Object)
    if ($added.Count -gt 0 -or $removed.Count -gt 0) {
        Violation ("C12: $listPath is stale against $definesInc -- added: " +
            "$($added -join ',') removed: $($removed -join ',') -- regenerate " +
            'it in the same commit as the repin')
    }
    # the pin's own bytes, so a repin that reshuffles the file without changing
    # the SET is still visible rather than silently accepted
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $pinShaLive = (-join ($sha.ComputeHash(
            [System.IO.File]::ReadAllBytes($definesInc)) |
            ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
    if ($pinShaClaimed -cne $pinShaLive) {
        Violation ("C12: $listPath claims pin-sha256 $pinShaClaimed and " +
            "$definesInc hashes to $pinShaLive -- the define SET may be " +
            'unchanged, but the file it was derived from is not the one on disk')
    }
    $report.Add("C12: $($live.Count) mORMot defines, committed set equal, pin $($pinShaLive.Substring(0,12))...")
}

# --- verdict ----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap15b | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-15B contract cross-checks')
foreach ($r in $report) { $lines.Add("# $r") }
if ($violations.Count -eq 0) {
    $lines.Add('VERDICT: PASS')
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap15b/contracts.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-15B contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host ('[CAP-15B] contracts PASS - one transport file, no relaxation, ' +
    'no origin literal in the runtime, both templates fenced')
