# CAP-6b1 contract cross-checks (the house 1587-cross-check idiom):
# string contracts that two files share must be proven shared, so a
# rename on either side breaks THIS gate instead of silently voiding a
# runtime gate downstream.
#
#   (a) the defensive stderr marker 'WEBVIEW2 RUNTIME UNUSABLE' must
#       appear literally in BOTH examples/08-release/releaseapp.pas
#       (the producer) and test/cap6/run_cap6_smoke.ps1 (the consumer)
#   (b) every WV2PROV_* line prefix that any CAP-6b1 gate or the
#       clean-machine gate regex-matches must appear in the helper
#       source tools/setup/pwebwv2prov.pas (the producer)
#
# Usage: pwsh -File test/cap6b1/check_cap6b1_contracts.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

# --- (a) defensive-marker contract -------------------------------------------
$Marker = 'WEBVIEW2 RUNTIME UNUSABLE'
$producer = Get-Content (Join-Path $RepoRoot 'examples/08-release/releaseapp.pas') -Raw
$consumer = Get-Content (Join-Path $RepoRoot 'test/cap6/run_cap6_smoke.ps1') -Raw
if (-not $producer.Contains($Marker)) {
    throw "releaseapp.pas lost the literal defensive marker '$Marker'"
}
if (-not $consumer.Contains($Marker)) {
    throw "run_cap6_smoke.ps1 lost the literal defensive marker '$Marker'"
}
Write-Host "CAP-6b1 contract (a) PASS ('$Marker' in producer and consumer)"

# --- (b) WV2PROV_* prefix contract -------------------------------------------
$helperSource = Get-Content (Join-Path $RepoRoot 'tools/setup/pwebwv2prov.pas') -Raw
$consumers = @(
    (Join-Path $RepoRoot 'test/cap6b1/run_normal_setup_gates.ps1'),
    (Join-Path $RepoRoot 'test/cap6b1/run_clean_machine_gate.ps1')
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

Write-Host 'CAP6B1_CONTRACTS_PASS'
