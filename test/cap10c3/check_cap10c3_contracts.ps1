# CAP-10C3: the checkout-only cross-checks a running Pas2JS dev loop cannot
# make about itself.
#
# Checkout-only (plus the compiled unit sets the CAP-10B1 and CAP-10C3 builds
# leave): no toolchain, no network, no display. It runs in every platform job
# and on any dev host, BEFORE the gates it protects.
#
# WHAT IT CROSS-CHECKS:
#
#   1. THE NEW BOUNDS, against docs/dev-contract.md. A constant nobody
#      cross-checks is a number somebody typed - the rule
#      pweb.cli.toolchain's own header states.
#   2. THE CHANGE DETECTOR IS LINKED INTO THE CLI, and reaches no webview
#      unit: `pweb dev` is public, so pweb.cli.devinputs must be on the
#      shipped executable's compiled unit set exactly as the rest of the loop
#      is.
#   3. NO PLATFORM FILE-WATCH API ANYWHERE IN THE TREE. Polling was ratified,
#      so ReadDirectoryChangesW, inotify, FSEvents and kqueue must not appear
#      in src/ or tools/ at all - not even inside pweb.cli.platform, which is
#      where a "just one small conditional" would otherwise be legal.
#   4. THE PAS2JS RELEASE HOST carries no development unit and no dev marker,
#      and its PWEB_NATIVE_CSP is byte-identical to the development host's.
#      CAP-10C2 proved this for a React project; a generated host is
#      frontend-agnostic by design, and this is where that stops being a
#      design statement.
#   5. NO TRANSPORT ALLOWANCE in this shard's source, and NO PLATFORM
#      CONDITIONAL or ENVIRONMENT READ in the new unit - the CAP-10C1 and
#      CAP-10C2 rules, extended.
#   6. THE REFUSAL PATH SURVIVES: dev_ui_unsupported is still spelled in the
#      loop, still reachable through one predicate, and still documented.
#   7. THE CONTRACTS RECORD THE PAS2JS HALF, and `build` is still absent from
#      the public surface.
#
# Emits build/cap10c3/contracts.json and exits nonzero on any violation.
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
$inputsPath = 'tools/pweb/pweb.cli.devinputs.pas'
if (-not (Test-Path $inputsPath)) { throw "missing $inputsPath" }
$inputs = [System.IO.File]::ReadAllText($inputsPath)
$loopPath = 'tools/pweb/pweb.cli.dev.pas'
$loop = [System.IO.File]::ReadAllText($loopPath)

# --- 1. the new bounds, in both places ---------------------------------------
$bounds = [ordered]@{
    PWEB_CLI_DEV_POLL_MS = '250'
    PWEB_CLI_DEV_MAX_INPUT_FILES = '512'
    PWEB_CLI_DEV_MAX_INPUT_DEPTH = '16'
    PWEB_CLI_DEV_INPUT_FILE_MAX = '4194304'
    PWEB_CLI_DEV_INPUT_PATH_MAX = '512'
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
$facts['bounds'] = $bounds
# and the CAP-10C2 bounds this loop REUSES must still be the C2 values: a
# shard that quietly retuned the debounce for its own frontend would be a
# shard with two debounces
foreach ($pair in @(@('PWEB_CLI_DEV_DEBOUNCE_MS', '250'),
                    @('PWEB_CLI_DEV_DEBOUNCE_MAX_MS', '5000'),
                    @('PWEB_CLI_DEV_SNAPSHOT_TRIES', '5'),
                    @('PWEB_CLI_DEV_KEEP_GENERATIONS', '3'))) {
    if ($toolchain -notmatch "(?m)^\s*$($pair[0])\s*=\s*$($pair[1])\s*;") {
        Violation ("$toolchainPath moved the CAP-10C2 bound $($pair[0]): the " +
            'Pas2JS loop reuses it verbatim and must not retune it')
    }
}

# --- 2. the change detector is linked, and is webview-free -------------------
$cliUnits = 'build/cap10b1/cli-units'
$facts['devinputs_linked'] = $null
if (Test-Path $cliUnits) {
    $linked = @(Get-ChildItem $cliUnits -File -Filter '*.ppu' |
        ForEach-Object { $_.Name })
    $facts['devinputs_linked'] = ($linked -contains 'pweb.cli.devinputs.ppu')
    if ($linked -notcontains 'pweb.cli.devinputs.ppu') {
        Violation ('the CLI does NOT link pweb.cli.devinputs: `pweb dev` is ' +
            'public and every unit under it must reach the shipped executable')
    }
} else {
    Violation "$cliUnits is missing -- run test/cap10b1/build_cap10b1 first"
}
# the detector must not reach a webview unit, a process unit or the pipeline:
# it walks files and hashes them, and nothing else
foreach ($banned in 'pweb.webview', 'pweb.cli.process', 'pweb.cli.pipeline',
                    'pweb.cli.dev;') {
    if ($inputs -match "(?m)^\s*$([regex]::Escape($banned))") {
        Violation "$inputsPath uses $banned -- the detector is a walk, not a loop"
    }
}
# and it must SPAWN nothing
if ($inputs -match 'PWebCliExecute|CreateProcess|fpExecve|fork\(') {
    Violation "$inputsPath runs a child: pweb.cli.dev is the only unit that may"
}

# --- 3. no platform file-watch API anywhere ----------------------------------
# POLLING WAS RATIFIED. Three native APIs would be three bodies in
# pweb.cli.platform, three semantics and three ways for one loop to behave
# differently on four targets - for an input set of five files. This gate is
# what keeps that a decision rather than a preference: the identifiers must
# not appear as CODE anywhere under src/ or tools/.
$watchRx = 'ReadDirectoryChangesW|FindFirstChangeNotification|inotify_init|' +
    'inotify_add_watch|FSEventStreamCreate|kqueue\(|EVFILT_VNODE'
$watchHits = 0
foreach ($file in (Get-ChildItem src, tools -Recurse -File `
        -Include '*.pas', '*.inc', '*.mm', '*.h', '*.c')) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        # a COMMENT that names one is how this repository explains what it
        # refused; what must not exist is the call
        $code = $line
        $cut = $code.IndexOf('//')
        if ($cut -ge 0) { $code = $code.Substring(0, $cut) }
        if ($code -match $watchRx) {
            $watchHits++
            Violation ("PLATFORM FILE-WATCH API at ${rel}:${lineNo}: " +
                "$($line.Trim()) -- CAP-10C3 ratified polling, and a native " +
                'watcher is three bodies with three semantics')
        }
    }
}
$facts['watch_api_hits'] = $watchHits

# --- 4. the PAS2JS release host: no dev unit, no dev marker, one CSP ---------
$facts['release_units_measured'] = $false
$releaseUnits = 'build/cap10c3/release-units'
if (Test-Path $releaseUnits) {
    $rel = @(Get-ChildItem $releaseUnits -File -Filter '*.ppu' |
        ForEach-Object { $_.Name })
    $facts['release_units_measured'] = $true
    $facts['release_unit_count'] = $rel.Count
    $facts['release_dev_unit_absent'] =
        ($rel -notcontains 'pweb.webview.devhost.ppu')
    if ($rel -contains 'pweb.webview.devhost.ppu') {
        Violation ('the PAS2JS RELEASE host links pweb.webview.devhost: the ' +
            'development composition must not exist in a release unit set')
    }
    if ($rel.Count -lt 5) { Violation "$releaseUnits holds no compiled unit set" }
}
$devUnitsDir = 'build/cap10c3/dev-units'
if (Test-Path $devUnitsDir) {
    $dv = @(Get-ChildItem $devUnitsDir -File -Filter '*.ppu' |
        ForEach-Object { $_.Name })
    $facts['dev_host_unit_present'] = ($dv -contains 'pweb.webview.devhost.ppu')
    if ($dv -notcontains 'pweb.webview.devhost.ppu') {
        Violation ('the PAS2JS DEVELOPMENT host does not link ' +
            'pweb.webview.devhost: -dPWEB_DEV did not select the development ' +
            'composition')
    }
}

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
function Probe-Exe([string]$Dir) {
    if (-not (Test-Path $Dir)) { return $null }
    $exe = @(Get-ChildItem $Dir -File | Where-Object {
        ($_.Extension -eq '.exe') -or ($_.Extension -eq '') } |
        Select-Object -First 1)
    if ($exe.Count -eq 0) { return $null }
    return $exe[0].FullName
}
$releaseExe = Probe-Exe 'build/cap10c3/probe/release-host'
$devExe = Probe-Exe 'build/cap10c3/probe/dev-host'
if ($releaseExe) {
    $has = Test-BytesContain $releaseExe $marker
    $facts['dev_marker_in_release_binary'] = $has
    if ($has) {
        Violation ('the PAS2JS RELEASE host CARRIES the development argument ' +
            'string: a release binary must not contain --pweb-dev-root=')
    }
}
if ($devExe) {
    $has = Test-BytesContain $devExe $marker
    $facts['dev_marker_in_dev_binary'] = $has
    if (-not $has) {
        Violation ('the PAS2JS DEVELOPMENT host does not carry the ' +
            'development argument string')
    }
}
# the CSP, read from the SOURCE (the one place it is written) and required
# present in BOTH binaries' bytes - which is the comparison that cannot be
# argued with
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
        if ($csp.Contains($banned)) { Violation "PWEB_NATIVE_CSP contains '$banned'" }
    }
    $cspBytes = [System.Text.Encoding]::ASCII.GetBytes($csp)
    $inRelease = $null; $inDev = $null
    if ($releaseExe) { $inRelease = Test-BytesContain $releaseExe $cspBytes }
    if ($devExe) { $inDev = Test-BytesContain $devExe $cspBytes }
    $facts['csp_in_pas2js_release'] = $inRelease
    $facts['csp_in_pas2js_dev'] = $inDev
    $facts['csp_identical'] = (($inRelease -eq $true) -and ($inDev -eq $true))
    if (($releaseExe -and -not $inRelease) -or ($devExe -and -not $inDev)) {
        Violation ('PWEB_NATIVE_CSP is not present byte-for-byte in both ' +
            'pas2js host binaries: the development CSP must be the release CSP')
    }
}

# --- 5. no transport, no platform conditional, no environment read ----------
$shardFiles = @(
    'tools/pweb/pweb.cli.devinputs.pas',
    'tools/pweb/pweb.cli.dev.pas',
    'tools/templates/pas2js/src/program.lpr',
    'tools/templates/pas2js/frontend/src/app.pas',
    'tools/templates/pas2js/frontend/pas2js.cfg'
)
$originRx = 'ws://|wss://|localhost|127\.0\.0\.1'
$openRx = 'createServer|new\s+WebSocket|\.listen\(|TCrtSocket|WinSock|BSD_SOCKET'
$literalForms = @("'((?:[^']|'')*)'", '"([^"]*)"', '`([^`]*)`')
$transportHits = 0
foreach ($f in $shardFiles) {
    if (-not (Test-Path $f)) {
        Violation "CAP-10C3 source file is missing: $f"
        continue
    }
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        foreach ($form in $literalForms) {
            foreach ($m in [regex]::Matches($line, $form)) {
                if ($m.Groups[1].Value -match $originRx) {
                    $transportHits++
                    Violation ("TRANSPORT ORIGIN AS DATA in a CAP-10C3 source " +
                        "file: ${f}:${lineNo}: $($m.Groups[1].Value)")
                }
            }
        }
        if ($line -match $openRx) {
            $transportHits++
            Violation "TRANSPORT CALL in a CAP-10C3 source file: ${f}:${lineNo}"
        }
    }
}
$facts['transport_hits'] = $transportHits

$platformRx = [regex]::new(
    '\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|POSIX|OSPOSIX|OSLINUX|OSDARWIN|OSMAC|BSD|ANDROID|CPUX86_64|CPUX64|CPUAARCH64|CPUARM64|AARCH64)\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$envRx = 'GetEnvironmentVariable|getenv\(|GetEnv\(|EnvW\(|environ\b'
$conditionals = 0
$envReads = 0
foreach ($f in @('tools/pweb/pweb.cli.devinputs.pas',
                 'tools/pweb/pweb.cli.dev.pas')) {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        if ($platformRx.IsMatch($line)) {
            $conditionals++
            Violation "PLATFORM CONDITIONAL in a CAP-10C3 unit: ${f}:${lineNo}"
        }
        if ($line -match $envRx) {
            $envReads++
            Violation "ENVIRONMENT READ in a CAP-10C3 unit: ${f}:${lineNo}"
        }
    }
}
$facts['dev_conditionals'] = $conditionals
$facts['dev_env_reads'] = $envReads

# --- 6. the refusal path survives -------------------------------------------
# CAP-10C3 implements the second of two ratified frontend kinds, so no
# ratified `ui` reaches dev_ui_unsupported today. It stays anyway, behind ONE
# predicate, because the day schema 1 ratifies a third kind the loop must
# refuse it rather than start something it cannot finish.
if ($loop -notmatch 'function\s+PWebCliDevUiSupported\(') {
    Violation "$loopPath does not declare PWebCliDevUiSupported"
}
if ($loop -notmatch "'dev_ui_unsupported'") {
    Violation ("$loopPath no longer carries the dev_ui_unsupported refusal: " +
        'it must survive for the next frontend kind')
}
if ($loop -notmatch 'if\s+not\s+PWebCliDevUiSupported\(Project\.Ui\)\s+then') {
    Violation ("$loopPath does not refuse on PWebCliDevUiSupported: the " +
        'question must be asked in exactly one place')
}
# and the SDK layout must be selected by the descriptor's own ui, not by a
# literal - the CAP-10C2 loop passed False unconditionally, which is exactly
# what this shard had to change
if ($loop -notmatch 'PWebCliSdkLayout\(Os,\s*Arch,\s*Project\.Ui\s*=\s*puiPas2js') {
    Violation ("$loopPath does not resolve the SDK layout from the project's " +
        'own ui: a pas2js build needs the pas2js SDK, not the TypeScript one')
}

# --- 7. the contracts record the Pas2JS half, and build is advertised -------
foreach ($phrase in 'cli_content_fingerprint_poll', 'dev_input_link',
                    'dev_input_bound', 'PWebCliDevInputScan',
                    'pweb.cli.devinputs', 'dev_ui_unsupported') {
    if (-not $contract.Contains($phrase)) {
        Violation "$contractPath does not record: $phrase"
    }
}
$cli = [System.IO.File]::ReadAllText('docs/cli-contract.md')
foreach ($phrase in 'pweb dev [--project <path>]', 'rebuild-and-reload',
                    'ratified, unused', 'cap10c2-model-a-spike.md',
                    'rebuild-and-reload for BOTH UIs',
                    'cap10c-closure-artifact.md') {
    if (-not $cli.Contains($phrase)) {
        Violation "docs/cli-contract.md does not record: $phrase"
    }
}
# CAP-10D0 EXPOSED `build`, so this check is INVERTED rather than deleted -
# the same discipline CAP-10C2 applied to pipeline_units_linked and CAP-10C3
# to dev11. What it asserted was that the help text and the implemented
# surface agree; it asserts that still, from the other side.
$report = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.report.pas')
if ($report -notmatch "'\s*pweb build") {
    Violation ('pweb.cli.report does not advertise `pweb build`: CAP-10D0 ' +
        'exposes it, and a command that is implemented and unlisted is the ' +
        'same defect as one that is listed and unimplemented')
}
# and both UIs are advertised where a reader looks
if ($report -notmatch "PWEB_CLI_UI_REACT \+ ' and ' \+[\s\S]{0,80}PWEB_CLI_UI_PAS2JS") {
    Violation ('the usage banner does not advertise both frontend kinds for ' +
        '`dev`')
}
$facts['build_available'] = ($report -match "'\s*pweb build")

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10c3 | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap10c3/contracts.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10C3 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-10C3] contract cross-checks PASS'
