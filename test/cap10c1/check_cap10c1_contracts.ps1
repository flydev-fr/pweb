# CAP-10C1: the checkout-only cross-checks a build cannot make about itself.
#
# Checkout-only (plus the compiled unit set the CAP-10B1 build leaves): no
# toolchain, no network, no display. It runs in every platform job and on any
# dev host, BEFORE the gates it protects.
#
# WHAT IT CROSS-CHECKS:
#
#   1. THE BOUNDS AND THE LIBRARY NAMES, against docs/pipeline-contract.md
#      and against webview.lock. A constant nobody cross-checks is a number
#      somebody typed - the rule pweb.cli.toolchain's own header states.
#   2. NO PIPELINE UNIT IS LINKED INTO THE CLI. `pweb` advertises create,
#      doctor and run; the pipeline is private, and "private" has to be a
#      MEASUREMENT over the compiled unit set rather than a claim about a
#      command that happens not to exist yet.
#   3. NO PLATFORM CONDITIONAL, NO NAME-BASED PROCESS PRIMITIVE, NO
#      ENVIRONMENT READ and NO DEVELOPMENT ORIGIN in any pipeline unit. The
#      first keeps the four-target command tables meaningful, the second is
#      the CAP-10C0 rule extended to the new units, the third is what makes
#      the SDK root a parameter rather than an ambient input, and the fourth
#      is CAP-10A's dev-trust rule applied where a dev mode will first want
#      to break it.
#   4. THE PIPELINE UNITS EXIST AND ARE NAMED IN THE CONTRACT, so a unit
#      added without a line in the document fails here.
#
# Emits build/cap10c1/contracts.json and exits nonzero on any violation.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}

$contractPath = 'docs/pipeline-contract.md'
if (-not (Test-Path $contractPath)) { throw "missing $contractPath" }
$contract = [System.IO.File]::ReadAllText($contractPath)
$toolchainPath = 'tools/pweb/pweb.cli.toolchain.pas'
$toolchain = [System.IO.File]::ReadAllText($toolchainPath)

# --- 1. the bounds, in both places ------------------------------------------
$bounds = [ordered]@{
    PWEB_CLI_PIPE_NPM_MS = '600000'
    PWEB_CLI_PIPE_TSC_MS = '300000'
    PWEB_CLI_PIPE_BUILD_MS = '300000'
    PWEB_CLI_PIPE_PACK_MS = '120000'
    PWEB_CLI_PIPE_FPC_MS = '900000'
    PWEB_CLI_PIPE_MAX_FILE_BYTES = '268435456'
    PWEB_CLI_PIPE_MAX_TREE_FILES = '4096'
    PWEB_CLI_PIPE_MAX_TREE_DEPTH = '24'
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

# --- 2. the platform artifact names, against webview.lock -------------------
$lock = @{}
foreach ($line in [System.IO.File]::ReadAllLines('webview.lock')) {
    $t = $line.Trim()
    if (($t -eq '') -or $t.StartsWith('#')) { continue }
    $eq = $t.IndexOf('=')
    if ($eq -gt 0) { $lock[$t.Substring(0, $eq).Trim()] = $t.Substring($eq + 1).Trim() }
}
$libs = [ordered]@{
    PWEB_CLI_WEBVIEW_LIB_LINUX = $lock['linux-soname']
    PWEB_CLI_WEBVIEW_LIB_MACOS = $lock['macos-dylib-versioned']
}
foreach ($name in $libs.Keys) {
    $value = $libs[$name]
    if (($null -eq $value) -or ($value -eq '')) {
        Violation "webview.lock carries no value for $name"
        continue
    }
    if ($toolchain -notmatch "(?m)^\s*$([regex]::Escape($name))\s*=\s*'$([regex]::Escape($value))'\s*;") {
        Violation "$toolchainPath does not define $name = '$value' (webview.lock)"
    }
}
# the Windows library is not in webview.lock: it is what
# tools/build-webview-dll.ps1 produces, so THAT is its source of truth
$dllScript = [System.IO.File]::ReadAllText('tools/build-webview-dll.ps1')
if (-not $dllScript.Contains('webview.dll')) {
    Violation 'tools/build-webview-dll.ps1 no longer names webview.dll'
}
if ($toolchain -notmatch "(?m)^\s*PWEB_CLI_WEBVIEW_LIB_WINDOWS\s*=\s*'webview\.dll'\s*;") {
    Violation "$toolchainPath does not define PWEB_CLI_WEBVIEW_LIB_WINDOWS = 'webview.dll'"
}
# the deployment target the macOS link passes as -WM, already cross-checked
# by CAP-10A against the same lock key - re-read here because this shard is
# the one that now PASSES it to a compiler
if ($lock['macos-deployment-target'] -ne '12.0') {
    Violation ("webview.lock macos-deployment-target is " +
        "'$($lock['macos-deployment-target'])'; PWEB_CLI_MACOS_MIN and the " +
        'pipeline -WM flag are pinned to 12.0')
}
$facts['webview_libs'] = $libs

# --- 3. the pipeline is NOT linked into the CLI -----------------------------
$pipelineUnits = @('sdkroot', 'stage', 'toolset', 'frontend', 'pack',
    'native', 'layout', 'pipeline')
foreach ($u in $pipelineUnits) {
    if (-not (Test-Path "tools/pweb/pweb.cli.$u.pas")) {
        Violation "tools/pweb/pweb.cli.$u.pas is missing"
    }
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
    foreach ($u in $pipelineUnits) {
        if ($linked -contains "pweb.cli.$u.ppu") {
            Violation ("the CLI LINKS pweb.cli.${u}: the lifecycle pipeline is " +
                'private at CAP-10C1 and must not reach the shipped executable')
        }
    }
    $facts['cli_linked_units'] = $linked.Count
    $facts['pipeline_units_linked'] = [bool]@($linked | Where-Object {
        $_ -match '^pweb\.cli\.(sdkroot|stage|toolset|frontend|pack|native|layout|pipeline)\.ppu$' }).Count
} else {
    Violation "$cliUnits is missing -- run test/cap10b1/build_cap10b1 first"
}

# --- 4. the source sweeps over the pipeline units ---------------------------
# a code line, with block comments and // stripped - the CAP-10A shape, and
# it carries the CAP-10C0 ledger's recorded blind spots (a brace inside a
# string literal, a (* *) comment) unchanged rather than pretending otherwise
function Get-CodeLines([string]$Path) {
    $rows = @()
    $inBlock = $false
    $n = 0
    foreach ($raw in [System.IO.File]::ReadLines($Path)) {
        $n++
        $line = $raw
        if ($inBlock) {
            $close = $line.IndexOf('}')
            if ($close -lt 0) { continue }
            $inBlock = $false
            $line = $line.Substring($close + 1)
        }
        while ($true) {
            $open = $line.IndexOf('{')
            if ($open -lt 0) { break }
            $close = $line.IndexOf('}', $open)
            if ($close -lt 0) { $inBlock = $true; $line = $line.Substring(0, $open); break }
            $line = $line.Substring(0, $open) + $line.Substring($close + 1)
        }
        $slash = $line.IndexOf('//')
        if ($slash -ge 0) { $line = $line.Substring(0, $slash) }
        if ($line.Trim() -ne '') {
            $rows += [pscustomobject]@{ Number = $n; Text = $line }
        }
    }
    return $rows
}

$platformRx = [regex]::new(
    '\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|POSIX|OSPOSIX|OSLINUX|OSDARWIN|OSMAC|BSD|ANDROID|CPUX86_64|CPUX64|CPUAARCH64|CPUARM64|AARCH64)\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
# (patterns concatenated so this file cannot match its own source)
$killPatterns = @(
    ('Process32' + 'First'), ('EnumPro' + 'cesses'), ('task' + 'kill'),
    ('Stop-Pro' + 'cess'), ('kill' + 'all'), ('pk' + 'ill'), ('pg' + 'rep'),
    ('FindWindow' + 'W'), ('CreateToolhelp32' + 'Snapshot'))
$envRx = 'GetEnvironmentVariable|getenv\(|GetEnv\(|EnvW\(|environ\b'
$devOriginRx = 'http://127\.0\.0\.1|http://localhost|ws://|wss://'
$conditionals = 0
$envReads = 0
foreach ($u in $pipelineUnits) {
    $path = "tools/pweb/pweb.cli.$u.pas"
    if (-not (Test-Path $path)) { continue }
    $lineNo = 0
    foreach ($raw in [System.IO.File]::ReadLines($path)) {
        $lineNo++
        if ($platformRx.IsMatch($raw)) {
            $conditionals++
            Violation ("PLATFORM CONDITIONAL in a pipeline unit: " +
                "pweb.cli.$u.pas:${lineNo}: $($raw.Trim())")
        }
    }
    foreach ($row in (Get-CodeLines (Join-Path $repoRoot $path))) {
        foreach ($pat in $killPatterns) {
            if ($row.Text.Contains($pat)) {
                Violation ("NAME-BASED PROCESS PRIMITIVE: pweb.cli.$u.pas:" +
                    "$($row.Number): $($row.Text.Trim())")
            }
        }
        if ($row.Text -match $envRx) {
            $envReads++
            Violation ("ENVIRONMENT READ in a pipeline unit: pweb.cli.$u.pas:" +
                "$($row.Number): $($row.Text.Trim()) -- the SDK root and every " +
                'tool are parameters or PATH resolutions, never ambient inputs')
        }
        foreach ($m in [regex]::Matches($row.Text, "'((?:[^']|'')*)'")) {
            if ($m.Groups[1].Value -match $devOriginRx) {
                Violation ("DEVELOPMENT ORIGIN as DATA: pweb.cli.$u.pas:" +
                    "$($row.Number): $($m.Groups[1].Value)")
            }
        }
    }
}
$facts['pipeline_conditionals'] = $conditionals
$facts['pipeline_env_reads'] = $envReads

# --- 5. the ratified npm flags, stated once and read back -------------------
$frontend = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.frontend.pas')
foreach ($flag in "'ci'", "'--no-audit'", "'--no-fund'", "'--ignore-scripts'") {
    if (-not $frontend.Contains($flag)) {
        Violation "pweb.cli.frontend.pas does not carry the ratified npm flag $flag"
    }
}
if ($frontend -match "'install'") {
    Violation 'pweb.cli.frontend.pas names `install`: only `ci` is ratified'
}
foreach ($phrase in 'ci`, never `install', '--ignore-scripts', 'registry_override_present') {
    if (-not $contract.Contains($phrase)) {
        Violation "$contractPath does not record the network policy phrase: $phrase"
    }
}

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10c1 | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap10c1/contracts.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10C1 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-10C1] contract cross-checks PASS'
