# CAP-14A contract cross-checks: the properties that are true of the SOURCE
# rather than of a run, and that a gate driving binaries cannot see.
#
#   T1  ONE CALLER. `pweb.assets.htmlpolicy` is named by exactly one unit in
#       the whole product surface - tools/bundler/pwebbundle.pas. That is the
#       ratified layering: the refusal is walk-time policy owned by the CLI,
#       so no production host links it and the writer beside it does not grow.
#   T2  NO OVERRIDE. The bundler's option surface is exactly the four ratified
#       flags. A flag that packed an inline script anyway would be a lie told
#       at build time and paid for at run time, so its absence is measured.
#   T3  ONE VOCABULARY. The six cause tokens appear identically in the unit
#       that defines them, in the gate that drives them, in the contract
#       document that freezes them and in the bundler's README.
#   T4  NO SECOND POLICY. Nothing outside the policy unit re-implements the
#       decision: no other source file spells an inline-script rule.
#   T5  THE CSP IS THE AUTHORITY, unchanged. `PWEB_NATIVE_CSP` still carries
#       `script-src 'self'` with no 'unsafe-inline' - the whole shard is a
#       claim about that string, and a shard that quietly relaxed it to make
#       a corpus pack would have inverted its own point.
#
# An OBSERVATION rather than a gate: when this workspace holds a compiled
# release host, its unit set is read back and recorded. It is per-target by
# construction (only the leg that built the host has one), which is why T1
# above is the gate and this is the corroboration.
#
# Writes build/cap14a/contracts.json. Usage:
#   pwsh test/cap14a/check_cap14a_contracts.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$failures = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) {
    $script:failures.Add($m)
    Write-Host "CONTRACT VIOLATION: $m"
}
function ReadNorm([string]$Path) {
    return [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
}

$policyUnit = 'src/assets/pweb.assets.htmlpolicy.pas'
$bundlerSrc = 'tools/bundler/pwebbundle.pas'
foreach ($f in $policyUnit, $bundlerSrc) {
    if (-not (Test-Path -LiteralPath $f)) { throw "missing $f" }
}

# --- T1: one caller ---------------------------------------------------------
# The whole product surface: src, tools and examples. A test unit naming the
# policy is expected and irrelevant - test/ is not shipped and links nothing
# into a host.
$surface = @(
    (Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc', '*.lpr'),
    (Get-ChildItem tools -Recurse -File -Include '*.pas', '*.inc', '*.lpr'),
    (Get-ChildItem examples -Recurse -File -Include '*.pas', '*.inc', '*.lpr' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' })
) | ForEach-Object { $_ }
$callers = New-Object System.Collections.Generic.List[string]
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    if ($rel -eq $policyUnit) { continue }
    if ((ReadNorm $file.FullName) -match '(?m)^\s*pweb\.assets\.htmlpolicy\b') {
        $callers.Add($rel)
    }
}
$callerList = @($callers | Sort-Object)
if (($callerList -join ',') -cne $bundlerSrc) {
    Violation ("T1: the policy unit is named by [$($callerList -join ', ')]; " +
        "exactly one caller was ratified: $bundlerSrc")
}

# --- T2: no override --------------------------------------------------------
$bundlerText = ReadNorm $bundlerSrc
$opts = @([regex]::Matches($bundlerText, "'(--[a-z0-9-]+)") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$ratifiedOpts = @('--include-sourcemaps', '--max-asset-bytes',
    '--min-runtime', '--verify')
if (($opts -join ',') -cne (($ratifiedOpts | Sort-Object) -join ',')) {
    Violation ("T2: the bundler's option surface is [$($opts -join ', ')], " +
        "not the four ratified flags")
}
# and no environment variable may reopen what the flags do not
foreach ($env_ in @('GetEnvironmentVariable', 'GetEnv', 'getenv')) {
    if ($bundlerText.Contains($env_)) {
        Violation "T2: the bundler reads the environment ($env_)"
    }
}

# --- T3: one vocabulary -----------------------------------------------------
$policyText = ReadNorm $policyUnit
$causes = @([regex]::Matches($policyText, "'(bundle_[a-z_]+)'") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
    Where-Object { $_ -ne 'bundle_html_refused' })
$ratifiedCauses = @('bundle_external_script', 'bundle_html_encoding',
    'bundle_html_unterminated', 'bundle_inline_handler',
    'bundle_inline_script', 'bundle_javascript_url')
if (($causes -join ',') -cne ($ratifiedCauses -join ',')) {
    Violation ("T3: the policy unit defines [$($causes -join ', ')], " +
        "not the six ratified causes")
}
$vocabularyFiles = @(
    'test/cap14a/run_cap14a_gates.ps1',
    'docs/pipeline-contract.md',
    'tools/bundler/README.md'
)
foreach ($vf in $vocabularyFiles) {
    if (-not (Test-Path -LiteralPath $vf)) {
        Violation "T3: missing $vf"
        continue
    }
    $t = ReadNorm $vf
    foreach ($c in $ratifiedCauses) {
        if (-not $t.Contains($c)) { Violation "T3: $vf does not name '$c'" }
    }
}

# --- T4: no second policy ---------------------------------------------------
# Nobody else may decide what the CSP will run. The search is for the
# DECISION, never for the words: `examples/02-js-binding` authors an inline
# `<script>` string into a `webview_set_html` demo that serves no bundle and
# carries no CSP, and a check that flagged HTML AUTHORING would be reporting
# the wrong thing forever. What may not exist twice is the classification -
# a cause token, or the executable-type keywords a second classifier would
# have to name.
$second = New-Object System.Collections.Generic.List[string]
$policyMarkers = @('importmap', 'application/x-ecmascript') + $ratifiedCauses
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    if (($rel -eq $policyUnit) -or ($rel -eq $bundlerSrc)) { continue }
    $t = ReadNorm $file.FullName
    foreach ($m in $policyMarkers) {
        if ($t.Contains($m)) { $second.Add("${rel}::$m"); break }
    }
}
if ($second.Count -gt 0) {
    Violation ("T4: a second inline-script rule appears in " +
        "[$(($second | Sort-Object) -join ', ')]")
}

# --- T5: the authority, unchanged -------------------------------------------
$policySrc = 'src/security/pweb.navigation.policy.pas'
if (-not (Test-Path -LiteralPath $policySrc)) {
    Violation "T5: missing $policySrc"
} else {
    $navText = ReadNorm $policySrc
    if (-not ($navText -match "script-src\s+''self''")) {
        Violation "T5: PWEB_NATIVE_CSP no longer carries script-src 'self'"
    }
    # the CSP's script-src must still carry no 'unsafe-inline'. The style-src
    # one is RATIFIED and must stay, so the test is on the script-src term
    # rather than on the string as a whole
    if ($navText -match "script-src ''self'' ''unsafe-inline''") {
        Violation ("T5: script-src grew 'unsafe-inline' - this shard's whole " +
            'claim is that it has none')
    }
    if (-not ($navText -match "style-src ''self'' ''unsafe-inline''")) {
        Violation ("T5: style-src lost 'unsafe-inline', so the accepted " +
            'inline-style class is no longer ratified')
    }
}

# --- the observation: a compiled host's unit set ----------------------------
$hostUnitDirs = @('build/cap6/host-fpc', 'build/cap7l/units',
    'build/cap7m/units') |
    Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) }
$policyInHost = $false
$hostDirsRead = 0
foreach ($d in $hostUnitDirs) {
    $hostDirsRead++
    if (Test-Path -LiteralPath (Join-Path $repoRoot "$d/pweb.assets.htmlpolicy.ppu")) {
        $policyInHost = $true
        Violation "the release host unit set in $d links the policy unit"
    }
}

New-Item -ItemType Directory -Force build/cap14a | Out-Null
$out = [ordered]@{
    schema             = 1
    policy_callers     = ($callerList -join ',')
    option_surface     = ($opts -join ',')
    causes             = ($causes -join ',')
    second_policy      = $second.Count
    host_unit_dirs     = $hostDirsRead
    policy_unit_in_host = $policyInHost
    violations         = $failures.Count
    verdict            = $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
}
$json = ($out | ConvertTo-Json -Depth 3)
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap14a/contracts.json'),
    ($json -replace "`r`n", "`n") + "`n",
    (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CAP-14A CONTRACT CROSS-CHECKS FAILED ($($failures.Count))"
    exit 1
}
Write-Host ("CAP14A_CONTRACTS_PASS one caller, four options, six causes, " +
    "no second policy, the CSP unchanged")
exit 0
