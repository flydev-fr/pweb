# CAP-10C2: the checkout-only cross-checks a running dev loop cannot make
# about itself.
#
# Checkout-only (plus the compiled unit sets the CAP-10B1 and CAP-10C2 builds
# leave): no toolchain, no network, no display. It runs in every platform job
# and on any dev host, BEFORE the gates it protects.
#
# WHAT IT CROSS-CHECKS:
#
#   1. THE BOUNDS, against docs/dev-contract.md. A constant nobody
#      cross-checks is a number somebody typed - the rule
#      pweb.cli.toolchain's own header states.
#   2. THE PIPELINE AND THE DEV LOOP *ARE* LINKED INTO THE CLI. CAP-10C1
#      measured their ABSENCE; `pweb dev` is what makes them public, so the
#      same measurement is required to come out the other way.
#   3. THE DEV UNIT IS ABSENT FROM THE RELEASE HOST'S COMPILED UNIT SET, and
#      the dev MARKER is absent from the release binary's bytes. Two
#      independent measurements of one claim: a directory listing and a byte
#      scan.
#   4. PWEB_NATIVE_CSP IS BYTE-IDENTICAL IN BOTH BINARIES, extracted from
#      each, and carries no transport scheme.
#   5. NO TRANSPORT ALLOWANCE ANYWHERE IN THIS SHARD'S SOURCE: no ws://, no
#      wss://, no localhost, no 127.0.0.1 - as a literal or as a comment.
#   6. NO PLATFORM CONDITIONAL and NO ENVIRONMENT READ in the new CLI units,
#      the CAP-10C1 rule extended to them, and NONE in the dev host either -
#      pweb.webview.host is the ONE allowlisted file in src/webview.
#   7. THE ONE ORIGIN: the dev host names no destination of its own, and the
#      reload seam carries PWEB_HOST_ORIGIN and no parameter.
#
# Emits build/cap10c2/contracts.json and exits nonzero on any violation.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}

$contractPath = 'docs/dev-contract.md'
if (-not (Test-Path $contractPath)) { throw "missing $contractPath" }
$contract = [System.IO.File]::ReadAllText($contractPath)
$toolchainPath = 'tools/pweb/pweb.cli.toolchain.pas'
$toolchain = [System.IO.File]::ReadAllText($toolchainPath)
$devHostPath = 'src/webview/pweb.webview.devhost.pas'
if (-not (Test-Path $devHostPath)) { throw "missing $devHostPath" }
$devHost = [System.IO.File]::ReadAllText($devHostPath)

# --- 1. the bounds, in both places ------------------------------------------
$bounds = [ordered]@{
    PWEB_CLI_DEV_DEBOUNCE_MS = '250'
    PWEB_CLI_DEV_DEBOUNCE_MAX_MS = '5000'
    PWEB_CLI_DEV_SENTINEL_POLL_MS = '60'
    PWEB_CLI_DEV_FIRST_BUILD_MS = '300000'
    PWEB_CLI_DEV_ACK_MS = '30000'
    PWEB_CLI_DEV_SNAPSHOT_TRIES = '5'
    PWEB_CLI_DEV_KEEP_GENERATIONS = '3'
    PWEB_CLI_DEV_MAX_GENERATIONS = '100000'
    PWEB_CLI_DEV_JOIN_MS = '30000'
    PWEB_CLI_DEV_SMALL_FILE_MAX = '4096'
}
foreach ($name in $bounds.Keys) {
    $value = $bounds[$name]
    if ($toolchain -notmatch "(?m)^\s*$([regex]::Escape($name))\s*=\s*$value\s*;") {
        Violation "$toolchainPath does not define $name = $value"
    }
    if ($contract -notmatch "(?m)^\|\s*``$([regex]::Escape($name))``\s*\|\s*$value\s*\|") {
        Violation "$contractPath does not carry $name = $value"
    }
}
# the poller's bound lives with the poller, in the dev host
if ($devHost -notmatch "(?m)^\s*PWEB_DEV_POLL_MS\s*=\s*120\s*;") {
    Violation "$devHostPath does not define PWEB_DEV_POLL_MS = 120"
}
if ($contract -notmatch "(?m)^\|\s*``PWEB_DEV_POLL_MS``\s*\|\s*120\s*\|") {
    Violation "$contractPath does not carry PWEB_DEV_POLL_MS = 120"
}
$facts['bounds'] = $bounds

# the layout names, spelled once and read back
$layoutNames = [ordered]@{
    PWEB_CLI_DEV_DIR = 'dev'
    PWEB_CLI_DEV_APP_DIR = 'app'
    PWEB_CLI_DEV_UNIT_DIR = 'units'
    PWEB_CLI_DEV_OBJ_DIR = 'obj'
    PWEB_CLI_DEV_TMP_DIR = '.gen.tmp'
    # the published generations' prefix: a start reclaims every name that is
    # exactly this followed by digits, so the shape is a contract and not an
    # implementation detail of one walk
    PWEB_CLI_DEV_GEN_PREFIX = 'gen-'
    PWEB_CLI_DEV_DEFINE = 'PWEB_DEV'
    PWEB_CLI_DEV_INSTALL_RECORD = 'install-lock.sha256'
    PWEB_CLI_DEV_LOCKFILE = 'package-lock.json'
    PWEB_CLI_DEV_SENTINEL_FILE = 'build-id'
}
foreach ($name in $layoutNames.Keys) {
    $value = $layoutNames[$name]
    if ($toolchain -notmatch "(?m)^\s*$([regex]::Escape($name))\s*=\s*'$([regex]::Escape($value))'\s*;") {
        Violation "$toolchainPath does not define $name = '$value'"
    }
    if (-not $contract.Contains($value)) {
        Violation "$contractPath does not name $value"
    }
}
$facts['layout_names'] = $layoutNames

# --- 2. the pipeline AND the dev loop ARE linked ----------------------------
# THE INVERSION OF THE CAP-10C1 RULE, and the reason it is an inversion
# rather than a deletion: "private" was a measurement over the compiled unit
# set, so "public" has to be the same measurement with the other verdict.
$devUnits = @('devlayout', 'dev')
$pipelineUnits = @('sdkroot', 'stage', 'toolset', 'frontend', 'pack',
    'native', 'layout', 'pipeline')
foreach ($u in ($pipelineUnits + $devUnits)) {
    if (-not (Test-Path "tools/pweb/pweb.cli.$u.pas")) {
        Violation "tools/pweb/pweb.cli.$u.pas is missing"
    }
}
foreach ($u in $devUnits) {
    if (-not $contract.Contains("pweb.cli.$u")) {
        Violation "$contractPath does not name pweb.cli.$u"
    }
}
$cliUnits = 'build/cap10b1/cli-units'
if (Test-Path $cliUnits) {
    $linked = @(Get-ChildItem $cliUnits -File -Filter '*.ppu' |
        ForEach-Object { $_.Name })
    if ($linked.Count -lt 5) {
        Violation "$cliUnits holds no compiled unit set -- run test/cap10b1/build_cap10b1 first"
    }
    foreach ($u in ($pipelineUnits + $devUnits)) {
        if ($linked -notcontains "pweb.cli.$u.ppu") {
            Violation ("the CLI does NOT link pweb.cli.${u}: `pweb dev` is " +
                'public at CAP-10C2 and every unit under it must reach the ' +
                'shipped executable')
        }
    }
    # and the DEV HOST must not: it belongs to a generated application's
    # development build, never to the CLI
    if ($linked -contains 'pweb.webview.devhost.ppu') {
        Violation ('the CLI links pweb.webview.devhost: the development host ' +
            'is a generated application unit and has no business in the CLI')
    }
    $facts['cli_linked_units'] = $linked.Count
    $facts['pipeline_units_linked'] = ([bool](@($linked | Where-Object {
        $_ -match '^pweb\.cli\.(sdkroot|stage|toolset|frontend|pack|native|layout|pipeline)\.ppu$' }).Count -eq 8))
    $facts['dev_units_linked'] = ([bool](@($linked | Where-Object {
        $_ -match '^pweb\.cli\.(dev|devlayout)\.ppu$' }).Count -eq 2))
} else {
    Violation "$cliUnits is missing -- run test/cap10b1/build_cap10b1 first"
}

# --- 3. the release host carries no development unit and no dev marker ------
# The dev compile writes into <dev>/units and the release compile into
# <target>/units, which is what makes this a DIRECTORY LISTING rather than an
# inference. Both are produced by test/cap10c2/build_cap10c2.
$facts['release_units_measured'] = $false
$facts['release_dev_unit_absent'] = $null
$releaseUnits = 'build/cap10c2/release-units'
if (Test-Path $releaseUnits) {
    $rel = @(Get-ChildItem $releaseUnits -File -Filter '*.ppu' |
        ForEach-Object { $_.Name })
    $facts['release_units_measured'] = $true
    $facts['release_unit_count'] = $rel.Count
    $facts['release_dev_unit_absent'] = ($rel -notcontains 'pweb.webview.devhost.ppu')
    if ($rel -contains 'pweb.webview.devhost.ppu') {
        Violation ('the RELEASE host links pweb.webview.devhost: the ' +
            'development composition must not exist in a release unit set')
    }
    if ($rel.Count -lt 5) {
        Violation "$releaseUnits holds no compiled unit set"
    }
}
$facts['dev_units_measured'] = $false
$devUnitsDir = 'build/cap10c2/dev-units'
if (Test-Path $devUnitsDir) {
    $dv = @(Get-ChildItem $devUnitsDir -File -Filter '*.ppu' |
        ForEach-Object { $_.Name })
    $facts['dev_units_measured'] = $true
    $facts['dev_host_unit_present'] = ($dv -contains 'pweb.webview.devhost.ppu')
    if ($dv -notcontains 'pweb.webview.devhost.ppu') {
        Violation ('the DEVELOPMENT host does not link pweb.webview.devhost: ' +
            'the -dPWEB_DEV compile did not select the development composition')
    }
}

# the byte scan. The marker is the dev-only argument, which exists in
# exactly one unit and cannot be reached without it
$marker = [System.Text.Encoding]::ASCII.GetBytes('--pweb-dev-root=')
function Test-BytesContain([string]$Path, [byte[]]$Needle) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $limit = $bytes.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $true }
    }
    return $false
}
foreach ($pair in @(
        @('build/cap10c2/probe/release-host', $false, 'the RELEASE host'),
        @('build/cap10c2/probe/dev-host', $true, 'the DEVELOPMENT host'))) {
    $dir = $pair[0]
    if (-not (Test-Path $dir)) { continue }
    $exe = @(Get-ChildItem $dir -File | Where-Object {
        ($_.Extension -eq '.exe') -or ($_.Extension -eq '') } |
        Select-Object -First 1)
    if ($exe.Count -eq 0) { continue }
    $has = Test-BytesContain $exe[0].FullName $marker
    $key = if ($pair[1]) { 'dev_marker_in_dev_binary' }
           else { 'dev_marker_in_release_binary' }
    $facts[$key] = $has
    if ($has -ne $pair[1]) {
        if ($pair[1]) {
            Violation "$($pair[2]) does not carry the development argument string"
        } else {
            Violation ("$($pair[2]) CARRIES the development argument string: " +
                'a release binary must not contain --pweb-dev-root=')
        }
    }
}

# --- 4. PWEB_NATIVE_CSP, byte-identical in both binaries --------------------
# Read from the SOURCE here (the one place it is written) and from the two
# BINARIES by the gate, which is the measurement that cannot be argued with.
$policy = 'src/security/pweb.navigation.policy.pas'
$policyText = [System.IO.File]::ReadAllText($policy)
$cspMatch = [regex]::Match($policyText,
    "PWEB_NATIVE_CSP\s*:\s*RawUtf8\s*=\s*((?:\s*'[^']*'\s*\+?)+)\s*;")
if (-not $cspMatch.Success) {
    Violation 'PWEB_NATIVE_CSP could not be read from the navigation policy'
} else {
    $csp = (-join ([regex]::Matches($cspMatch.Groups[1].Value, "'((?:[^']|'')*)'") |
        ForEach-Object { $_.Groups[1].Value })).Replace("''", "'")
    $facts['native_csp'] = $csp
    foreach ($banned in 'ws:', 'wss:', 'localhost', '127.0.0.1', 'http:') {
        if ($csp.Contains($banned)) {
            Violation "PWEB_NATIVE_CSP contains '$banned'"
        }
    }
    # THE CSP IS NOT SELECTED BY A CONDITIONAL. One constant, one definition:
    # a development build that could pick a second policy would make the
    # byte-identity claim a coincidence
    if ([regex]::Matches($policyText, 'PWEB_NATIVE_CSP\s*:\s*RawUtf8\s*=').Count -ne 1) {
        Violation ('PWEB_NATIVE_CSP is defined more than once: the policy must ' +
            'have exactly one definition, so both binaries carry the same bytes')
    }
    if ($policyText -match '(?m)\{\$ifdef[^}]*PWEB_DEV') {
        Violation 'the navigation policy branches on PWEB_DEV'
    }
}

# --- 5. no transport allowance in this shard's source -----------------------
# ONLY A STRING LITERAL COUNTS, which is the rule check_dev_trust.ps1 already
# established and for the same reason: a comment that NAMES a transport is how
# this repository explains what it refuses, and a gate that could not tell a
# literal from its explanation would forbid the explanation. What must not
# exist is the transport as DATA - or as a call that would open one.
$shardFiles = @(
    'src/webview/pweb.webview.devhost.pas',
    'tools/pweb/pweb.cli.dev.pas',
    'tools/pweb/pweb.cli.devlayout.pas',
    'tools/templates/react/frontend/vite.config.ts',
    'tools/templates/react/frontend/pweb-build.d.ts',
    'tools/templates/react/src/program.lpr'
)
$originRx = 'ws://|wss://|localhost|127\.0\.0\.1'
# a call that would OPEN one, in either language. These are identifiers and
# never appear in this shard's prose, so they are scanned raw
$openRx = 'createServer|new\s+WebSocket|\.listen\(|TCrtSocket|WinSock|BSD_SOCKET'
$literalForms = @("'((?:[^']|'')*)'", '"([^"]*)"', '`([^`]*)`')
$transportHits = 0
foreach ($f in $shardFiles) {
    if (-not (Test-Path $f)) {
        Violation "CAP-10C2 source file is missing: $f"
        continue
    }
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        foreach ($form in $literalForms) {
            foreach ($m in [regex]::Matches($line, $form)) {
                if ($m.Groups[1].Value -match $originRx) {
                    $transportHits++
                    Violation ("TRANSPORT ORIGIN AS DATA in a CAP-10C2 source " +
                        "file: ${f}:${lineNo}: $($m.Groups[1].Value)")
                }
            }
        }
        if ($line -match $openRx) {
            $transportHits++
            Violation "TRANSPORT CALL in a CAP-10C2 source file: ${f}:${lineNo}: $($line.Trim())"
        }
    }
}
$facts['transport_hits'] = $transportHits

# --- 6. no platform conditional, no environment read, no name-based kill ----
$platformRx = [regex]::new(
    '\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|POSIX|OSPOSIX|OSLINUX|OSDARWIN|OSMAC|BSD|ANDROID|CPUX86_64|CPUX64|CPUAARCH64|CPUARM64|AARCH64)\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$envRx = 'GetEnvironmentVariable|getenv\(|GetEnv\(|EnvW\(|environ\b'
$conditionals = 0
$envReads = 0
foreach ($f in @('tools/pweb/pweb.cli.dev.pas',
                 'tools/pweb/pweb.cli.devlayout.pas',
                 'src/webview/pweb.webview.devhost.pas')) {
    if (-not (Test-Path $f)) { continue }
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        if ($platformRx.IsMatch($line)) {
            $conditionals++
            Violation "PLATFORM CONDITIONAL in a CAP-10C2 unit: ${f}:${lineNo}: $($line.Trim())"
        }
        if ($line -match $envRx) {
            $envReads++
            Violation ("ENVIRONMENT READ in a CAP-10C2 unit: ${f}:${lineNo} -- " +
                'the SDK root, every tool and the development mode are ' +
                'parameters or PATH resolutions, never ambient inputs')
        }
    }
}
$facts['dev_conditionals'] = $conditionals
$facts['dev_env_reads'] = $envReads

# --- 7. one origin, and one reload seam -------------------------------------
$hostPath = 'src/webview/pweb.webview.host.pas'
$hostText = [System.IO.File]::ReadAllText($hostPath)
if ($hostText -notmatch 'function\s+PWebHostRequestReload\s*:\s*Boolean') {
    Violation "$hostPath does not declare PWebHostRequestReload: Boolean"
}
# the re-navigation callback must name PWEB_HOST_ORIGIN and no other string
$reNav = [regex]::Match($hostText,
    'procedure\s+PWebHostReNavigate\([^)]*\);\s*cdecl;\s*begin(.*?)\bend;',
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $reNav.Success) {
    Violation "$hostPath does not carry the PWebHostReNavigate callback"
} elseif ($reNav.Groups[1].Value -notmatch 'webview_navigate\(w,\s*PWEB_HOST_ORIGIN\)') {
    Violation ('the re-navigation callback does not navigate to ' +
        'PWEB_HOST_ORIGIN: the privileged origin is the only destination')
}
# the dev host must reach the origin only through that seam
if ($devHost -match 'webview_navigate') {
    Violation ('the development host calls webview_navigate directly rather ' +
        'than through PWebHostRequestReload')
}
if ($devHost -notmatch "PWEB_DEV_ARG_ROOT\s*=\s*'--pweb-dev-root='") {
    Violation "$devHostPath does not define PWEB_DEV_ARG_ROOT = '--pweb-dev-root='"
}
# and it must REFUSE without it, before the production loader is reachable
if ($devHost -notmatch 'PWebDevParseRoot') {
    Violation "$devHostPath does not parse the development root"
}
if ($devHost -notmatch 'dev_root_absent') {
    Violation "$devHostPath does not carry the dev_root_absent refusal"
}
# the production host's own bundle rule must still be the nil rule
if ($hostText -notmatch 'if\s+Store\s*<>\s*nil\s+then') {
    Violation ("$hostPath does not select PWebHostLoadBundle on a nil store: " +
        'nil MUST mean the production rule')
}
# `pweb run` must never resolve a dev layout
$runText = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.run.pas')
if ($runText -match "PWEB_CLI_DEV_DIR|'dev'") {
    Violation ('pweb.cli.run names the development directory: `pweb run` ' +
        'resolves PWEB_CLI_RUN_RELEASE and nothing else')
}

# --- 8. the contract names its own units and its own rules ------------------
foreach ($phrase in 'dev_ui_unsupported', 'PWebHostRequestReload',
                    'ConsumedArgs', 'PWebBundleLoadFile', 'pweb://app',
                    'ratified, unused', 'rebuild-and-reload',
                    'published by one rename', 'writeBundle') {
    if (-not $contract.Contains($phrase)) {
        Violation "$contractPath does not record: $phrase"
    }
}
$cli = [System.IO.File]::ReadAllText('docs/cli-contract.md')
foreach ($phrase in 'pweb dev [--project <path>]', 'dev_ui_unsupported',
                    'rebuild-and-reload', 'ratified, unused',
                    'cap10c2-model-a-spike.md') {
    if (-not $cli.Contains($phrase)) {
        Violation "docs/cli-contract.md does not record: $phrase"
    }
}

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10c2 | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap10c2/contracts.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10C2 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-10C2] contract cross-checks PASS'
