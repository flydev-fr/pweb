# CAP-14B: the checkout-only cross-checks a running dev session cannot make
# about itself.
#
# Checkout-only - no toolchain, no network, no display - so it runs in every
# platform job and on any dev host, BEFORE the gate it protects. The one
# optional measurement is `node --check` over the EMITTED shim, which runs
# wherever node resolves and is recorded as an observation elsewhere.
#
# WHAT IT CROSS-CHECKS:
#
#   T1  EVERY CAP-14B ADDITION TO THE RELEASE HOST IS INSIDE A PWEB_DEV
#       CONDITIONAL. This is what makes "the release host is byte-untouched"
#       a property of the source rather than a claim about one build.
#   T2  THE CHANNEL REACHES NO SERVICE. The console unit's uses clause names
#       no rpc unit, no scheduler, no bridge and no capability policy - the
#       compiler's own answer to "can the channel reach native services".
#   T3  NO PLATFORM CONDITIONAL AND NO ENVIRONMENT READ in the console unit:
#       pweb.webview.host stays the ONE allowlisted file in src/webview.
#   T4  THE SHIM CARRIES NO BACKSLASH. MEASURED: a doubled escape in a
#       Pascal literal reached the engine as an invalid character range and
#       threw while the shim was being PARSED, so nothing installed and the
#       channel was silent with no diagnostic anywhere.
#   T5  THE BOUNDS, against docs/dev-contract.md. A constant nobody
#       cross-checks is a number somebody typed.
#   T6  ONE LEVEL VOCABULARY, in the unit, the shim, the headless corpus and
#       the contract document.
#   T7  THE ACKNOWLEDGEMENT IS PARSED ON STDOUT ONLY, and the channel writes
#       to STDERR. Two independent barriers against a page forging the one
#       line the CLI's protocol is made of.
#   T8  NO TRANSPORT, in the unit or in the shim.
#
# Emits build/cap14b/contracts.json and exits nonzero on any violation.
#
# Usage: pwsh test/cap14b/check_cap14b_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }

$hostPath = 'src/webview/pweb.webview.host.pas'
$conPath = 'src/webview/pweb.webview.devconsole.pas'
$devPath = 'src/webview/pweb.webview.devhost.pas'
$cliPath = 'tools/pweb/pweb.cli.dev.pas'
$contractPath = 'docs/dev-contract.md'
$testPath = 'test/core/pweb.test.devconsole.pas'
foreach ($p in $hostPath, $conPath, $devPath, $cliPath, $contractPath, $testPath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}
$hostText = [System.IO.File]::ReadAllText($hostPath)
$conText = [System.IO.File]::ReadAllText($conPath)
$devText = [System.IO.File]::ReadAllText($devPath)
$cliText = [System.IO.File]::ReadAllText($cliPath)
$contract = [System.IO.File]::ReadAllText($contractPath)
$testText = [System.IO.File]::ReadAllText($testPath)

# --- T1: every host addition is inside a PWEB_DEV conditional ---------------
# A LINE SCAN rather than a regex over the whole file, because what has to be
# true is positional: each marker's line must sit at a depth where PWEB_DEV
# is the condition currently open. Nesting is tracked so an unrelated ifdef
# inside the block cannot be mistaken for the block ending.
$markers = @('TPWebHostDevViewProc', 'DevViewReady')
$depth = 0
$devDepth = -1
$lineNo = 0
$inside = @{}
foreach ($m in $markers) { $inside[$m] = @() }
$outside = 0
foreach ($line in [System.IO.File]::ReadLines($hostPath)) {
    $lineNo++
    $opens = [regex]::Matches($line, '\{\$\s*if(n?def|)\b')
    $closes = [regex]::Matches($line, '\{\$\s*endif\b')
    $isDevOpen = $line -match '\{\$\s*ifdef\s+PWEB_DEV\s*\}'
    if ($isDevOpen -and ($devDepth -lt 0)) { $devDepth = $depth }
    $depth += $opens.Count
    foreach ($m in $markers) {
        if ($line -match [regex]::Escape($m)) {
            if (($devDepth -ge 0) -and ($depth -gt $devDepth)) {
                $inside[$m] += $lineNo
            } else {
                $outside++
                Violation ("${hostPath}:${lineNo}: the CAP-14B marker $m is " +
                    'OUTSIDE a PWEB_DEV conditional -- every byte this shard ' +
                    'adds to the release host must vanish at the scanner')
            }
        }
    }
    $depth -= $closes.Count
    if (($devDepth -ge 0) -and ($depth -le $devDepth)) { $devDepth = -1 }
}
$facts['host_markers_outside_pweb_dev'] = $outside
foreach ($m in $markers) {
    $facts["host_marker_$($m.ToLowerInvariant())_lines"] = ($inside[$m] -join ',')
    if ($inside[$m].Count -eq 0) {
        Violation "$hostPath does not carry the CAP-14B marker $m at all"
    }
}
# and the seam runs BEFORE the first navigation, which is the whole reason it
# is placed where it is: a channel armed after the navigate would miss the
# first document
$bindAt = $hostText.IndexOf("binding.Bind('__pweb_invoke'")
$seamAt = $hostText.IndexOf('Options.DevViewReady(')
# the FIRST navigation AFTER the seam: PWebHostReNavigate names the same call
# earlier in the file, and it is the reload seam rather than the first
# navigation this ordering is about
$navAt = if ($seamAt -gt 0) {
    $hostText.IndexOf('webview_navigate(w, PWEB_HOST_ORIGIN)', $seamAt)
} else { -1 }
$facts['seam_after_bind_before_navigate'] =
    (Bool (($bindAt -gt 0) -and ($seamAt -gt $bindAt) -and ($navAt -gt $seamAt)))
if (-not (($bindAt -gt 0) -and ($seamAt -gt $bindAt) -and ($navAt -gt $seamAt))) {
    Violation ('the dev view seam is not between the invocation bind and the ' +
        'first navigation')
}

# --- T2: the channel reaches no service -------------------------------------
# The uses clause, read as a clause: what the unit may name is a closed list,
# so a future edit that reached for the bridge would have to change THIS.
$usesMatch = [regex]::Match($conText,
    '(?s)\ninterface\s*\n\s*uses\s*(.*?);')
if (-not $usesMatch.Success) {
    Violation "$conPath has no readable interface uses clause"
} else {
    $uses = @($usesMatch.Groups[1].Value -split ',' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $facts['console_uses'] = ($uses -join ',')
    $allowed = @('sysutils', 'mormot.core.base', 'mormot.core.os',
        'mormot.core.unicode', 'mormot.core.text', 'mormot.core.buffers',
        'pweb.lib.webview')
    foreach ($u in $uses) {
        if ($allowed -notcontains $u) {
            Violation ("$conPath uses $u -- the console channel is a ONE-WAY " +
                'diagnostic sink and its unit list is closed')
        }
    }
    $facts['console_uses_count'] = $uses.Count
}
# and the whole file names none of the service path, in any position
foreach ($forbidden in 'pweb.rpc', 'IInvocationBridge', 'IInvocationScheduler',
                       'ICapabilityPolicy', 'TInvocationContext',
                       'pweb.capabilities', 'pweb.assets') {
    if ($conText.Contains($forbidden)) {
        Violation ("$conPath names $forbidden -- the channel must not be able " +
            'to reach a service even by accident')
    }
}
$facts['console_service_references'] = 0

# --- T3: no platform conditional, no environment read -----------------------
$platformRx = [regex]::new(
    '\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|POSIX|OSPOSIX|OSLINUX|OSDARWIN|OSMAC|BSD|ANDROID|CPUX86_64|CPUX64|CPUAARCH64|CPUARM64|AARCH64)\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$envRx = 'GetEnvironmentVariable|getenv\(|GetEnv\(|EnvW\(|environ\b'
$conditionals = 0
$envReads = 0
$lineNo = 0
foreach ($line in [System.IO.File]::ReadLines($conPath)) {
    $lineNo++
    if ($platformRx.IsMatch($line)) {
        $conditionals++
        Violation "PLATFORM CONDITIONAL in the console unit: ${conPath}:${lineNo}"
    }
    if ($line -match $envRx) {
        $envReads++
        Violation "ENVIRONMENT READ in the console unit: ${conPath}:${lineNo}"
    }
}
$facts['console_conditionals'] = $conditionals
$facts['console_env_reads'] = $envReads

# --- T4: the shim carries no backslash --------------------------------------
# Scoped to the SHIM_JS literals: the surrounding COMMENT is where this
# repository explains what it forbids, and a check that could not tell a
# literal from its explanation would forbid the explanation.
$shimMatch = [regex]::Match($conText, "(?s)SHIM_JS\s*=\s*(.*?);\s*\r?\n")
if (-not $shimMatch.Success) {
    Violation "$conPath does not carry a readable SHIM_JS constant"
} else {
    $shimSrc = $shimMatch.Groups[1].Value
    $shimText = (-join ([regex]::Matches($shimSrc, "'((?:[^']|'')*)'") |
        ForEach-Object { $_.Groups[1].Value })).Replace("''", "'")
    $facts['shim_literal_bytes'] = $shimText.Length
    $facts['shim_backslashes'] = ([regex]::Matches($shimText, '\\')).Count
    # THE DIGEST IS OF THE REASSEMBLED SOURCE LITERAL, not of the emitted
    # file, and that is deliberate: it is a pure function of this checkout
    # that EVERY leg can compute with no toolchain and no earlier gate having
    # run. MEASURED on the linux leg, where digesting the emitted file left
    # the row EMPTY because the headless suite that writes it had not run -
    # and an empty row in a four-target equality set is a disagreement whose
    # cause is nowhere near where it is reported.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $b = [System.Text.UTF8Encoding]::new($false).GetBytes($shimText)
        $facts['shim_sha256'] =
            (-join ($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
    if ($shimText.Contains('\')) {
        Violation ('the shim literal carries a backslash: a Pascal literal ' +
            'carries no escapes, so a doubled one is invisible here and fatal ' +
            'in the engine -- it threw while the shim was being PARSED')
    }
    if ($shimText.Length -lt 500) {
        Violation 'the shim literal could not be reassembled from its parts'
    }
    # the shim is the ONLY place the bound placeholders exist
    foreach ($ph in '%BIND%', '%MAXT%', '%MAXB%', '%MAXP%', '%IVL%') {
        if (-not $shimText.Contains($ph)) {
            Violation "the shim does not carry the placeholder $ph"
        }
    }
}

# --- T5: the bounds, in both places -----------------------------------------
$bounds = [ordered]@{
    PWEB_DEV_CONSOLE_MAX_TEXT = '1024'
    PWEB_DEV_CONSOLE_MAX_ORIGIN = '512'
    PWEB_DEV_CONSOLE_MAX_METHOD = '32'
    PWEB_DEV_CONSOLE_MAX_BATCH = '32'
    PWEB_DEV_CONSOLE_FLUSH_MS = '50'
    PWEB_DEV_CONSOLE_MAX_PENDING = '256'
    PWEB_DEV_CONSOLE_MAX_PAYLOAD = '98304'
    PWEB_DEV_CONSOLE_MAX_BATCHES = '64'
    PWEB_DEV_CONSOLE_LINE_MAX = '3072'
}
foreach ($name in $bounds.Keys) {
    $value = $bounds[$name]
    if ($conText -notmatch "(?m)^\s*$([regex]::Escape($name))\s*=\s*$value\s*;") {
        Violation "$conPath does not define $name = $value"
    }
    if ($contract -notmatch "(?m)^\|\s*``$([regex]::Escape($name))``\s*\|\s*$value\s*\|") {
        Violation "$contractPath does not carry $name = $value"
    }
}
$facts['bounds'] = $bounds
# the line bound has to leave room under the supervisor's own
$runLineMax = 4096
if ([int]$bounds['PWEB_DEV_CONSOLE_LINE_MAX'] -ge $runLineMax) {
    Violation ('the console line bound is not under PWEB_CLI_RUN_LINE_MAX: a ' +
        'line the supervisor truncates is a line whose end nobody sees')
}
$facts['line_headroom_bytes'] =
    ($runLineMax - [int]$bounds['PWEB_DEV_CONSOLE_LINE_MAX'])

# --- T6: one level vocabulary -----------------------------------------------
$levels = @('log', 'info', 'warn', 'error', 'debug', 'uncaught', 'rejection',
    'dropped')
# the array literal is READ and parsed rather than string-matched: it wraps,
# and a check that depended on where it wrapped would be a check of the
# formatting rather than of the vocabulary
$tableMatch = [regex]::Match($conText,
    "(?s)PWEB_DEV_CONSOLE_LEVELS\s*:\s*array\[[^\]]*\]\s*of\s*RawUtf8\s*=\s*\((.*?)\)\s*;")
if (-not $tableMatch.Success) {
    Violation "$conPath does not carry a readable level table"
} else {
    $declared = @([regex]::Matches($tableMatch.Groups[1].Value, "'([^']*)'") |
        ForEach-Object { $_.Groups[1].Value })
    $facts['declared_levels'] = ($declared -join ',')
    if (($declared -join ',') -cne ($levels -join ',')) {
        Violation ("$conPath declares the level table as " +
            ($declared -join ',') + ' rather than the ratified ' +
            ($levels -join ','))
    }
}
$csv = ($levels -join ',')
foreach ($pair in @(@($testPath, $testText), @($contractPath, $contract))) {
    if (-not $pair[1].Contains($csv)) {
        Violation "$($pair[0]) does not carry the level vocabulary $csv"
    }
}
$facts['levels'] = $csv
$facts['level_count'] = $levels.Count

# --- T7: stdout for the protocol, stderr for the page -----------------------
if ($cliText -notmatch 'if\s+Stream\s*=\s*pcsStdOut\s+then') {
    Violation ("$cliPath does not restrict the acknowledgement parse to " +
        'stdout: a page logging `x: generation 999 loaded` would otherwise ' +
        "advance the CLI's generation counter")
}
$facts['ack_parsed_on_stdout_only'] = (Bool ($cliText -match
    'if\s+Stream\s*=\s*pcsStdOut\s+then'))
if ($conText -notmatch 'FileWrite\(THandle\(StdErrorHandle\)') {
    Violation "$conPath does not write its lines to StdErrorHandle"
}
foreach ($forbidden in 'WriteLn(', 'Write(Output', 'WriteLn(Output') {
    if ($conText.Contains($forbidden)) {
        Violation ("$conPath uses $forbidden -- the channel writes ONE whole " +
            "line with ONE FileWrite to stderr, because FPC's text layer is " +
            'not thread-safe and the generation poller already writes there')
    }
}
$facts['console_writes_stderr_only'] = (Bool ($conText -notmatch 'WriteLn\('))

# --- T8: no transport, in either language -----------------------------------
$originRx = 'ws://|wss://|localhost|127\.0\.0\.1'
$openRx = 'createServer|new\s+WebSocket|\.listen\(|TCrtSocket|WinSock|BSD_SOCKET|XMLHttpRequest|fetch\('
$transportHits = 0
foreach ($f in $conPath, $devPath) {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        foreach ($m in [regex]::Matches($line, "'((?:[^']|'')*)'")) {
            if ($m.Groups[1].Value -match $originRx) {
                $transportHits++
                Violation "TRANSPORT ORIGIN AS DATA: ${f}:${lineNo}"
            }
        }
        if ($line -match $openRx) {
            $transportHits++
            Violation "TRANSPORT CALL: ${f}:${lineNo}: $($line.Trim())"
        }
    }
}
$facts['transport_hits'] = $transportHits

# --- T9: the emitted shim, held to a real parser ----------------------------
# OPTIONAL by design: node is not a precondition of this gate, and the four
# platform legs that do carry it are enough to make a parse failure loud.
$shimFile = 'build/cap7f/dev-console-shim.js'
$facts['shim_parse_checked'] = $false
if ((Test-Path -LiteralPath $shimFile) -and
    ($null -ne (Get-Command node -ErrorAction SilentlyContinue))) {
    & node --check $shimFile 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $facts['shim_parse_checked'] = $true
    $facts['shim_parses'] = (Bool $ok)
    if (-not $ok) {
        Violation ("the EMITTED shim does not parse as JavaScript -- this is " +
            'the exact defect that made this check necessary')
    }
    $facts['shim_emitted_sha256'] =
        (Get-FileHash -LiteralPath $shimFile -Algorithm SHA256).Hash.ToLowerInvariant()
}

# --- T10: the composition wires it, and only the dev one --------------------
if ($devText -notmatch 'opts\.DevViewReady\s*:=\s*@PWebDevConsoleInstall') {
    Violation "$devPath does not install the console channel"
}
if ($devText -notmatch 'PWebDevConsoleShutdown') {
    Violation "$devPath does not shut the console channel down"
}
if ($devText -notmatch 'PWebDevConsoleConfigure\(Options\.LogPrefix\)') {
    Violation "$devPath does not configure the channel's prefix"
}
# and NOTHING else in the repository selects it
$selectors = @()
foreach ($f in (Get-ChildItem -Recurse -File -Path 'src', 'tools', 'examples' `
        -Include '*.pas', '*.lpr', '*.inc' -ErrorAction SilentlyContinue)) {
    $t = [System.IO.File]::ReadAllText($f.FullName)
    if ($t -match '(?m)^\s*pweb\.webview\.devconsole\s*[,;]') {
        $selectors += ($f.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/')
    }
}
$facts['console_selected_by'] = ($selectors -join ',')
if (($selectors.Count -ne 1) -or
    ($selectors[0] -cne 'src/webview/pweb.webview.devhost.pas')) {
    Violation ('the console unit is selected by ' + $selectors.Count +
        ' unit(s); exactly one - the development composition - may select it')
}

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap14b | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap14b/contracts.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-14B contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-14B] contract cross-checks PASS'
