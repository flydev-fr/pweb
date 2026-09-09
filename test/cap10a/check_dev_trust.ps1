# CAP-10A: the development-trust decision, pinned mechanically before any
# development code exists.
#
# THE RATIFIED MODEL (SPEC.md "Decided, implementation deferred";
# security-model.md "Navigation policy"):
#
#   the privileged application origin is pweb://app in DEVELOPMENT and in
#   PRODUCTION alike. `pweb dev` will serve the frontend BEHIND that handler
#   rather than re-pointing the privileged origin at 127.0.0.1. React HMR may
#   use ONE narrowly scoped development-only CSP data-channel allowance,
#   ws://127.0.0.1:<native-selected-port>, which is a TRANSPORT exception and
#   never an ORIGIN exception. A production build carries no localhost and no
#   WebSocket allowance of any kind. Pas2JS development needs no WebSocket.
#
# WHY A GATE NOW, WITH NO DEV MODE TO GATE. Because the rule dies the other
# way round: a dev mode is written, an allowance is added "temporarily" to the
# shared profile, and by the time anyone looks the production CSP has a
# localhost entry nobody can date. This script fails the moment the
# PRODUCTION half stops being true, which is the half that matters and the
# only half that exists yet.
#
# Checkout-only: no build, no toolchain, no network. Runs in every platform
# job and on any dev host.
#
# Usage: pwsh test/cap10a/check_dev_trust.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]

# --- 1. the production CSP -------------------------------------------------
# The native policy is attached to EVERY served response and cannot be
# weakened by the bundle (multiple policies combine restrictively), so it is
# the one place a development allowance would have to appear.
$policy = 'src/security/pweb.navigation.policy.pas'
if (-not (Test-Path $policy)) { throw "missing $policy" }
$policyText = [System.IO.File]::ReadAllText($policy)
$cspMatch = [regex]::Match($policyText,
    "PWEB_NATIVE_CSP\s*:\s*RawUtf8\s*=\s*((?:\s*'[^']*'\s*\+?)+)\s*;")
if (-not $cspMatch.Success) {
    throw 'PWEB_NATIVE_CSP could not be read from the navigation policy'
}
# Pascal escapes a quote by doubling it, and the CSP is full of them
# (`default-src ''self''`), so the concatenated literal is un-doubled back
# into the bytes the engine actually receives
$csp = (-join ([regex]::Matches($cspMatch.Groups[1].Value, "'((?:[^']|'')*)'") |
    ForEach-Object { $_.Groups[1].Value })).Replace("''", "'")
$report.Add("production CSP: $csp")

foreach ($banned in 'ws:', 'wss:', 'localhost', '127.0.0.1', 'http:') {
    if ($csp.Contains($banned)) {
        $violations.Add("the production CSP contains '$banned': $csp")
    }
}
foreach ($required in "default-src 'self'", "connect-src 'self'",
                      "script-src 'self'", "frame-ancestors 'none'") {
    if (-not $csp.Contains($required)) {
        $violations.Add("the production CSP no longer carries `"$required`"")
    }
}

# --- 2. the privileged origin ---------------------------------------------
# pweb://app is the only trusted origin, and it is decided by PARSED
# components in PWebNavTrustedUri. What this gate adds is that no production
# source has grown a SECOND origin that looks privileged.
$devOrigins = 'http://127\.0\.0\.1|http://localhost|ws://127\.0\.0\.1|' +
    'ws://localhost|wss://'
$surface = @(
    (Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc', '*.h', '*.mm'),
    (Get-ChildItem examples -Recurse -File -Include '*.pas' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' }),
    (Get-ChildItem tools -Recurse -File -Include '*.pas'),
    (Get-ChildItem sdk -Recurse -File -Include '*.ts', '*.pas' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' })
) | ForEach-Object { $_ }
# only a STRING LITERAL counts. A comment that names a development origin is
# how this repository explains what it refuses - pweb.navigation.policy's own
# header records that every wss:// was blocked on all four targets - and a
# gate that could not tell a literal from its explanation would forbid the
# explanation. What must not exist is the origin as DATA.
$literalForms = @("'((?:[^']|'')*)'", '"([^"]*)"', '`([^`]*)`')
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        foreach ($form in $literalForms) {
            foreach ($m in [regex]::Matches($line, $form)) {
                if ($m.Groups[1].Value -match $devOrigins) {
                    $violations.Add(("a development origin appears as DATA on " +
                        "the production surface: ${rel}:${lineNo}: " +
                        $m.Groups[1].Value))
                }
            }
        }
    }
}

# --- 3. the canonical wording -----------------------------------------------
# security-model.md must describe the SHIPPED CAP-8B result: a privileged
# WebView never navigates to external content, and an approved https/mailto
# URI reaches the operating system only through a capability-authorized
# runtime invocation. The pre-CAP-8B wording said the links "open in the
# system browser", which describes a navigation-time behaviour CAP-8B
# measured to be undecidable and removed.
$model = '_bmad-output/specs/spec-pweb/security-model.md'
if (-not (Test-Path $model)) { throw "missing $model" }
$modelText = [System.IO.File]::ReadAllText($model)
foreach ($phrase in
    'never navigates to external content',
    'capability-authorized',
    'pweb.openExternal') {
    if (-not $modelText.Contains($phrase)) {
        $violations.Add(("security-model.md does not carry the ratified " +
            "CAP-8B wording: `"$phrase`" is absent"))
    }
}
# and it must NOT still promise the gesture-based opener
if ($modelText -match '(?m)^\s*`https:`\s+and\s+`mailto:`\s+links\s+open\s+in\s+the\s+system\s+browser') {
    $violations.Add('security-model.md still describes the removed ' +
        'gesture-based opener behaviour')
}

# --- 4. the dev contract is WRITTEN DOWN ------------------------------------
# A decision that exists only in a reviewer's memory is not ratified. The
# public contract document must state the invariant, the single exception and
# its production exclusion, so CAP-10C implements what was agreed rather than
# what it can remember.
$contract = 'docs/cli-contract.md'
if (-not (Test-Path $contract)) { throw "missing $contract" }
$contractText = [System.IO.File]::ReadAllText($contract)
foreach ($phrase in 'pweb://app', 'ws://127.0.0.1', 'never an origin exception',
                    'no production build') {
    if (-not $contractText.Contains($phrase)) {
        $violations.Add(("docs/cli-contract.md does not record the dev-trust " +
            "decision: `"$phrase`" is absent"))
    }
}

# --- 5. CAP-10C2: the DEVELOPMENT half, now that it exists ------------------
# Sections 1-4 pinned the production half before any development code
# existed, which was the whole point: the rule dies when a dev mode is
# written and an allowance is added "temporarily" to a shared profile. The
# dev mode is written now, so this section pins what CAP-10C2 decided.
#
# The source sweep in section 2 already covers src/** and tools/**, so a
# ws:// or a 127.0.0.1 literal appearing in the dev loop or the dev host is
# ALREADY a violation above. What is added here is the positive half: the
# development composition exists, it navigates to nothing but the one
# privileged origin, it selects its mode natively, and the ratified-but-
# unused WebSocket allowance is still ratified, still unused, and still
# absent from every profile.
$devHost = 'src/webview/pweb.webview.devhost.pas'
# CAP-14B: the console surface is part of the development trust surface, so
# it is required present and swept exactly as the rest of it is
$devConsole = 'src/webview/pweb.webview.devconsole.pas'
$devLoop = 'tools/pweb/pweb.cli.dev.pas'
$devLayout = 'tools/pweb/pweb.cli.devlayout.pas'
$devInputs = 'tools/pweb/pweb.cli.devinputs.pas'
$devContract = 'docs/dev-contract.md'
foreach ($f in $devHost, $devConsole, $devLoop, $devLayout, $devInputs, $devContract) {
    if (-not (Test-Path $f)) {
        $violations.Add("CAP-10C development surface is missing: $f")
    }
}
if (Test-Path $devHost) {
    $devHostText = [System.IO.File]::ReadAllText($devHost)
    # THE ONE NAVIGATION. The dev host must not call webview_navigate at
    # all: re-navigation goes through PWebHostRequestReload, which carries
    # PWEB_HOST_ORIGIN and no parameter, so a development build has no way
    # to name a second destination even by accident.
    if ($devHostText -match 'webview_navigate') {
        $violations.Add(('the development host calls webview_navigate ' +
            'directly: the ratified switch is PWebHostRequestReload, whose ' +
            'only destination is PWEB_HOST_ORIGIN'))
    }
    if (-not $devHostText.Contains('PWebHostRequestReload')) {
        $violations.Add('the development host does not use PWebHostRequestReload')
    }
    # it must SERVE a packed bundle and never a folder: a dev store that
    # could read loose files is a dev store with a different path grammar
    if (-not $devHostText.Contains('PWebBundleLoadFile')) {
        $violations.Add(('the development host does not open its generations ' +
            'through the frozen PWebBundleLoadFile'))
    }
    foreach ($banned in 'pweb.assets.folder', 'TFolderAssetStore') {
        if ($devHostText.Contains($banned)) {
            $violations.Add("the development host reaches a FOLDER store: $banned")
        }
    }
}
# CAP-14B: THE CONSOLE SURFACE IS A ONE-WAY DIAGNOSTIC SINK, and the whole of
# that claim is what it cannot name. It reaches no service, opens nothing and
# navigates nowhere; a future edit that reached for the bridge, the scheduler
# or a second destination would have to change THIS list first.
if (Test-Path $devConsole) {
    $devConsoleText = [System.IO.File]::ReadAllText($devConsole)
    foreach ($banned in 'pweb.rpc', 'IInvocationBridge', 'IInvocationScheduler',
                        'ICapabilityPolicy', 'pweb.capabilities',
                        'pweb.assets', 'webview_navigate', 'webview_eval',
                        'TFolderAssetStore') {
        if ($devConsoleText.Contains($banned)) {
            $violations.Add(("the development console surface names ${banned}: " +
                'it is a ONE-WAY diagnostic sink and reaches no service, no ' +
                'store and no destination'))
        }
    }
    # and it is a DEVELOPMENT unit: nothing outside the development
    # composition may select it
    if (-not $devHostText.Contains('pweb.webview.devconsole')) {
        $violations.Add(('the development host does not select ' +
            'pweb.webview.devconsole: the console surface has exactly one ' +
            'caller and it is the development composition'))
    }
}
# THE MODE IS NATIVE-CONTROLLED. PWEB_DEV reaches a compiler from the CLI's
# own argument builder and from nowhere else - not from pweb.json, not from
# a frontend file, not from an environment variable.
$native = 'tools/pweb/pweb.cli.native.pas'
if (Test-Path $native) {
    $nativeText = [System.IO.File]::ReadAllText($native)
    if (-not ($nativeText -match "'-d'\s*\+\s*PWEB_CLI_DEV_DEFINE")) {
        $violations.Add(('pweb.cli.native does not build the development ' +
            'define from PWEB_CLI_DEV_DEFINE: the mode must be spelled once ' +
            'and reach the compiler from this one place'))
    }
}
$toolchain = 'tools/pweb/pweb.cli.toolchain.pas'
if (Test-Path $toolchain) {
    $toolchainText = [System.IO.File]::ReadAllText($toolchain)
    if ($toolchainText -notmatch "(?m)^\s*PWEB_CLI_DEV_DEFINE\s*=\s*'PWEB_DEV'\s*;") {
        $violations.Add("$toolchain does not define PWEB_CLI_DEV_DEFINE = 'PWEB_DEV'")
    }
}
# and no environment variable may select it, anywhere on the surface
$modeEnvRx = 'PWEB_DEV_ROOT|PWEB_MODE|PWEB_DEVELOPMENT'
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        if ($line -match 'GetEnvironmentVariable|getenv') {
            if ($line -match $modeEnvRx) {
                $violations.Add(("the development mode is read from the " +
                    "ENVIRONMENT at ${rel}:${lineNo} -- the mode is " +
                    'native-controlled and arrives on a compiler command line'))
            }
        }
    }
}
# THE PRODUCTION TEMPLATE STILL SELECTS THE PRODUCTION HOST. The generated
# program.lpr may name the development composition only inside its
# PWEB_DEV region, which is what makes a release build unable to link it.
# BOTH templates, since CAP-10C3: `pweb dev` implements both ratified
# frontend kinds, so both generated programs carry the region and both have
# to keep it fenced. Checking one would leave the other free to drift.
foreach ($tpl in 'tools/templates/react/src/program.lpr',
                 'tools/templates/pas2js/src/program.lpr') {
    if (-not (Test-Path $tpl)) {
        $violations.Add("a generated program template is missing: $tpl")
        continue
    }
    $inDev = $false
    $sawRegion = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_DEV\}') {
            $inDev = $true; $sawRegion = $true; continue
        }
        if ($line -match '\{\$else\}') { $inDev = $false; continue }
        if ($line -match '\{\$endif\s+PWEB_DEV\}') { $inDev = $false; continue }
        if ((-not $inDev) -and
            ($line -match 'devhost|PWebDevHostRun')) {
            $violations.Add(("the generated program names the development " +
                "composition OUTSIDE its PWEB_DEV region: ${tpl}:${lineNo}"))
        }
    }
    if (-not $sawRegion) {
        $violations.Add(("$tpl carries no PWEB_DEV region: `pweb dev` " +
            'implements both frontend kinds and neither generated program ' +
            'can be built in development mode without one'))
    }
}
# THE RATIFIED-BUT-UNUSED ALLOWANCE. CAP-10C2 chose rebuild-and-reload, so
# ws://127.0.0.1:<port> is still ratified in the contract, still unused, and
# still absent from every profile. Its presence in the DOCUMENT is required
# (section 4); its absence from every SOURCE profile is section 2. This pins
# the third thing: the contract must record that the shipped dev loop does
# not use it, so a reader cannot mistake a ratification for an implementation.
#
# CAP-10C3 pins the FINAL wording, now that both loops exist. Three claims,
# and the document must carry each of them as text a reader can find:
#
#   both UIs use rebuild-and-reload  - not "react does and pas2js will"
#   the allowance is ratified, unused and pinned absent - for BOTH
#   the model-A spike is the REASON  - a refusal on measured data, cited by
#                                      file, so the next shard starts from it
foreach ($phrase in 'rebuild-and-reload',
                    'rebuild-and-reload for BOTH UIs',
                    'ratified, unused',
                    'pinned absent from every profile — for both UIs',
                    'cap10c2-model-a-spike.md') {
    if (-not $contractText.Contains($phrase)) {
        $violations.Add(("docs/cli-contract.md does not record the final " +
            "CAP-10C development-trust wording: `"$phrase`" is absent"))
    }
}
# and the DEV CONTRACT must say the same of the Pas2JS half: no WebSocket,
# no listener, and a detector that is a bounded poll rather than a transport
foreach ($phrase in 'cli_content_fingerprint_poll',
                    'No platform file-watch API exists anywhere') {
    $devContractText = [System.IO.File]::ReadAllText($devContract)
    if (-not $devContractText.Contains($phrase)) {
        $violations.Add(("docs/dev-contract.md does not record the CAP-10C3 " +
            "detection decision: `"$phrase`" is absent"))
    }
}
$report.Add('CAP-10C: rebuild-and-reload for BOTH UIs; the ws:// allowance stays ratified, unused and absent')

# --- 6. CAP-15B: the NATIVE OUTBOUND DOOR, and the two things pinned apart --
#
# CAP-15A ratified door A - `pweb.fetch` behind the `network.fetch`
# capability and a native origin allowlist compiled into each application -
# and refused door B, which would have widened `connect-src` per
# application. Section 1 above is unchanged and is now LOAD-BEARING FOR A
# SECOND REASON: it is the mechanical proof that door B was not taken. The
# CSP and the native door are pinned APART, so widening one can never be
# mistaken for widening the other.
# Pascal comments, removed, so that the CAP-15B checks below read CODE. The
# repository's own rule, stated in section 2: a comment that names something
# the product refuses is how this repository EXPLAINS the refusal, and a
# gate that could not tell a literal from its explanation would forbid the
# explanation.
function Strip15bComments([string]$Text) {
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
            # a compiler directive is CODE, not a comment
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
$fetchDecorator = 'src/rpc/pweb.rpc.fetch.pas'
$fetchTransport = 'src/rpc/pweb.rpc.fetch.mormot.pas'
$fetchDarwin = 'src/platform/macos/pweb.platform.cocoa.fetch.pas'
$decText = if (Test-Path $fetchDecorator) { [System.IO.File]::ReadAllText($fetchDecorator) } else { '' }
foreach ($f in $fetchDecorator, $fetchTransport, $fetchDarwin) {
    if (-not (Test-Path $f)) {
        $violations.Add("CAP-15B outbound surface is missing: $f")
    }
}
# NO `https://` ORIGIN LITERAL ANYWHERE IN src/**. The allowlist is
# GENERATED into an application at build time and compiled in as a Pascal
# literal; the runtime carries none. Section 2's literal extractor is reused
# and its rule is the same: only a literal counts, and an origin SHAPE at
# that - `https:///x` in a comment is this repository explaining what it
# refuses, and a gate that could not tell the two apart would forbid the
# explanation.
$originShape = '^https?://[a-z0-9.\-]+(:\d+)?/?$'
foreach ($file in (Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc')) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        # a comment line explains; it never ships as data
        if ($line -match '^\s*(//|\{|\(\*)') { continue }
        foreach ($m in [regex]::Matches($line, "'((?:[^']|'')*)'")) {
            if ($m.Groups[1].Value -match $originShape) {
                $violations.Add(("an ORIGIN literal appears in the runtime: " +
                    "${rel}:${lineNo}: " + $m.Groups[1].Value))
            }
        }
    }
}
# THE LOOPBACK EXCEPTION IS NOT A REGION, and the fetch units carry no
# PWEB_DEV branch at all - which is stronger than fencing one, because there
# is no branch to compile in by accident. The ratified exception is a
# property of WHAT IS COMPILED INTO the allowlist: the descriptor accepts
# it, `pweb doctor` names it, and a RELEASE `pweb build` refuses it by name.
#
# The grammar DOES name the two loopback hosts, because the grammar is what
# accepts them, so the pin is exact rather than absolute: they may appear
# ONLY inside the two grammar functions, and NO FULL LOOPBACK ORIGIN literal
# may appear anywhere in the fetch units. What a release IMAGE carries is a
# separate, stronger proof (test/cap15b, release_relaxation_literals), and
# that sweep is required to FIRE on a dev image so it cannot pass vacuously.
foreach ($f in $fetchDecorator, $fetchTransport, $fetchDarwin) {
    if (-not (Test-Path $f)) { continue }
    $code = Strip15bComments ([System.IO.File]::ReadAllText($f))
    foreach ($needle in 'http://127.0.0.1', 'http://localhost') {
        if ($code.Contains($needle)) {
            $violations.Add(("$f carries a full loopback ORIGIN literal " +
                "${needle}: the compiled allowlist is where a loopback " +
                'origin may live, never the source of the door'))
        }
    }
    if ($code -match '\{\$ifdef[^}]*PWEB_DEV') {
        $violations.Add("$f branches on PWEB_DEV: the fetch units have no development mode")
    }
}
# and the two hosts are named ONLY by the grammar
$decCodeOnly = Strip15bComments $decText
foreach ($needle in '127.0.0.1', 'localhost') {
    $hits = ([regex]::Matches($decCodeOnly, [regex]::Escape($needle))).Count
    if ($hits -gt 2) {
        $violations.Add(("the fetch decorator names $needle $hits times: the " +
            'origin grammar accepts it in exactly two places - the parser ' +
            'and the loopback predicate - and nothing else may'))
    }
}
foreach ($f in $fetchTransport, $fetchDarwin) {
    if (-not (Test-Path $f)) { continue }
    $code = Strip15bComments ([System.IO.File]::ReadAllText($f))
    foreach ($needle in '127.0.0.1', 'localhost') {
        if ($code.Contains($needle)) {
            $violations.Add("$f names the loopback host ${needle}: only the grammar may")
        }
    }
}
# EXACTLY ONE FILE in src/** names mormot.net.client, and it is the mORMot
# transport. On Darwin the seam is filled by the adapter instead, so that
# file is not even on the compiled unit set - which is the point of
# injecting the transport rather than conditionalising it.
$netClient = @(Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc' |
    Where-Object { (Strip15bComments ([System.IO.File]::ReadAllText($_.FullName))).Contains('mormot.net.client') } |
    ForEach-Object { ($_.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/' })
if ($netClient.Count -ne 1) {
    $violations.Add(("$($netClient.Count) file(s) in src/** name " +
        "mormot.net.client, expected exactly 1: $($netClient -join ', ')"))
} elseif ($netClient[0] -ne $fetchTransport) {
    $violations.Add("the one file naming mormot.net.client is $($netClient[0])")
}
# THE DECORATOR IS PLATFORM-FREE. It joins the CAP-7F zero-conditional core
# list: no mormot.net.*, no compiler conditional, no operating system.
if (Test-Path $fetchDecorator) {
    $decCode = Strip15bComments $decText
    foreach ($banned in 'mormot.net.', 'OSWINDOWS', 'MSWINDOWS') {
        if ($decCode.Contains($banned)) {
            $violations.Add("the fetch decorator names ${banned}")
        }
    }
    if ($decCode -match '\{\$ifdef') {
        $violations.Add('the fetch decorator carries a compiler conditional')
    }
}
# BOTH GENERATED PROGRAMS install the door only inside the region the
# descriptor's origins control - the same shape, and the same rule, as the
# PWEB_DEV region section 5 pins.
foreach ($tpl in 'tools/templates/react/src/program.lpr',
                 'tools/templates/pas2js/src/program.lpr') {
    if (-not (Test-Path $tpl)) { continue }
    $inNet = $false
    $sawNet = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_NET\}') { $inNet = $true; $sawNet = $true; continue }
        if ($line -match '\{\$endif\s+PWEB_NET\}') { $inNet = $false; continue }
        if ((-not $inNet) -and
            ($line -match 'pweb\.rpc\.fetch|TPWebFetchBridge|APP_NETWORK_')) {
            $violations.Add(("the generated program names the network door " +
                "OUTSIDE its PWEB_NET region: ${tpl}:${lineNo}"))
        }
    }
    if (-not $sawNet) {
        $violations.Add(("$tpl carries no PWEB_NET region: the outbound door " +
            'is installed iff the descriptor declared an origin, and that is ' +
            'a compile-time property of the generated program'))
    }
}
# and the PUBLIC CONTRACT records the decision, so CAP-15B implemented what
# was agreed rather than what it could remember
foreach ($phrase in 'pweb.fetch', 'network.fetch', 'never an origin exception',
                    'schema 2') {
    if (-not $contractText.Contains($phrase)) {
        $violations.Add(("docs/cli-contract.md does not record the CAP-15B " +
            "outbound decision: `"$phrase`" is absent"))
    }
}
$report.Add('CAP-15B: the door is native, the CSP did not move, and the two are pinned apart')

# --- verdict ----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10a | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-10A development-trust gate')
foreach ($r in $report) { $lines.Add("# $r") }
if ($violations.Count -eq 0) {
    $lines.Add('VERDICT: PASS (production trust profile carries no dev allowance)')
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap10a/dev-trust.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-10A dev-trust gate FAILED: $($violations.Count) violation(s)"
}
Write-Host ('[CAP-10A] dev trust PASS - pweb://app is the only privileged ' +
    'origin and the production profile carries no HMR allowance')
