# CAP-6b1 contract cross-checks (the house 1587-cross-check idiom):
# string contracts that two files share must be proven shared, so a
# rename on either side breaks THIS gate instead of silently voiding a
# runtime gate downstream.
#
#   (a) the defensive stderr marker 'WEBVIEW2 RUNTIME UNUSABLE' and
#       the CAP-6 42 PASS marker must appear literally in the producer
#       examples/08-release/releaseapp.pas AND in EVERY registered
#       consumer script that greps them (CAP-6, CAP-6b1 and CAP-6b2
#       gates; an empty consumer set is an error)
#   (b) every WV2PROV_* line prefix that any CAP-6b1 gate, any
#       CAP-6b2 offline gate or either clean-machine gate
#       regex-matches must appear in the helper source
#       tools/setup/pwebwv2prov.pas (the producer)
#   (c) the setup AppId GUID is authored ONCE in the shared include
#       tools/setup/pwebprovgate.issi; every gate script that touches
#       the per-user uninstall registry key must carry the exact same
#       GUID literal - a drift on either side breaks this gate, not a
#       runtime gate
#
# Usage: pwsh -File test/cap6b1/check_cap6b1_contracts.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

# --- (a) defensive-marker + 42-marker contracts ------------------------------
# each marker names the literal the CONSUMER scripts grep, plus the
# literal(s) that must sit in the producer source to emit it (the 42
# marker is produced as LOG_PREFIX + tail, so BOTH halves are pinned)
$producer = Get-Content (Join-Path $RepoRoot 'examples/08-release/releaseapp.pas') -Raw
$markerContracts = @(
    @{
        Literal = 'WEBVIEW2 RUNTIME UNUSABLE'
        ProducerLiterals = @('WEBVIEW2 RUNTIME UNUSABLE')
        Consumers = @(
            'test/cap6/run_cap6_smoke.ps1',
            'test/cap6b1/run_clean_machine_gate.ps1',
            'test/cap6b2/run_offline_clean_machine_gate.ps1'
        )
    },
    @{
        Literal = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
        ProducerLiterals = @(
            "LOG_PREFIX = 'releaseapp'",
            ': app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
        )
        Consumers = @(
            'test/cap6/run_cap6_smoke.ps1',
            'test/cap6b1/run_normal_setup_gates.ps1',
            'test/cap6b1/run_clean_machine_gate.ps1',
            'test/cap6b2/run_offline_setup_gates.ps1',
            'test/cap6b2/run_offline_clean_machine_gate.ps1'
        )
    }
)
foreach ($contract in $markerContracts) {
    $literal = $contract.Literal
    foreach ($pl in $contract.ProducerLiterals) {
        if (-not $producer.Contains($pl)) {
            throw "releaseapp.pas lost the producer literal '$pl' behind marker '$literal'"
        }
    }
    if ($contract.Consumers.Count -eq 0) {
        throw "no consumers registered for marker '$literal' - the contract check is broken"
    }
    foreach ($rel in $contract.Consumers) {
        $f = Join-Path $RepoRoot $rel
        if (-not (Test-Path $f)) { throw "consumer script missing: $f" }
        if (-not (Get-Content $f -Raw).Contains($literal)) {
            throw "$rel lost the literal marker '$literal'"
        }
    }
    Write-Host ("CAP-6b1 contract (a) PASS ('$literal' produced and consumed by " +
        "$($contract.Consumers.Count) script(s))")
}

# --- (b) WV2PROV_* prefix contract -------------------------------------------
$helperSource = Get-Content (Join-Path $RepoRoot 'tools/setup/pwebwv2prov.pas') -Raw
$consumers = @(
    (Join-Path $RepoRoot 'test/cap6b1/run_normal_setup_gates.ps1'),
    (Join-Path $RepoRoot 'test/cap6b1/run_clean_machine_gate.ps1'),
    (Join-Path $RepoRoot 'test/cap6b2/run_offline_setup_gates.ps1'),
    (Join-Path $RepoRoot 'test/cap6b2/run_offline_clean_machine_gate.ps1')
)
$wanted = [System.Collections.Generic.SortedSet[string]]::new()
foreach ($f in $consumers) {
    if (-not (Test-Path $f)) { throw "consumer script missing: $f" }
    foreach ($m in [regex]::Matches((Get-Content $f -Raw), 'WV2PROV_[A-Z]+')) {
        [void]$wanted.Add($m.Value)
    }
}
if ($wanted.Count -eq 0) {
    throw 'no WV2PROV_ prefixes found in any consumer - the contract check is broken'
}
$missing = @()
foreach ($prefix in $wanted) {
    if (-not $helperSource.Contains($prefix)) { $missing += $prefix }
}
if ($missing) {
    throw ("helper source does not produce the gate-consumed prefix(es): " +
        ($missing -join ', '))
}
Write-Host ("CAP-6b1 contract (b) PASS ($($wanted.Count) WV2PROV_ prefixes " +
    'consumed by gates all produced by the helper)')

# --- (c) AppId GUID contract: authored once in the shared include ------------
$issi = Get-Content (Join-Path $RepoRoot 'tools/setup/pwebprovgate.issi') -Raw
# Inno escapes one literal '{' as '{{': AppId={{<GUID>}
$appIdMatch = [regex]::Match($issi, '(?m)^AppId=\{\{([0-9A-Fa-f-]+)\}\s*$')
if (-not $appIdMatch.Success) {
    throw 'pwebprovgate.issi does not author the AppId={{...} directive'
}
$appId = $appIdMatch.Groups[1].Value
$appIdConsumers = @(
    'test/cap6b1/run_normal_setup_gates.ps1',
    'test/cap6b2/run_offline_setup_gates.ps1'
)
if ($appIdConsumers.Count -eq 0) {
    throw 'no AppId consumers registered - the contract check is broken'
}
foreach ($rel in $appIdConsumers) {
    $f = Join-Path $RepoRoot $rel
    if (-not (Test-Path $f)) { throw "AppId consumer script missing: $f" }
    if (-not (Get-Content $f -Raw).Contains("{$appId}_is1")) {
        throw ("$rel does not carry the shared-include AppId uninstall key " +
            "literal '{$appId}_is1' - the GUID drifted")
    }
}
Write-Host ("CAP-6b1 contract (c) PASS (AppId $appId authored in the shared " +
    "include and matched by $($appIdConsumers.Count) gate script(s))")

Write-Host 'CAP6B1_CONTRACTS_PASS'
