# CAP-6b1 contract cross-checks (the house 1587-cross-check idiom):
# string contracts that two files share must be proven shared, so a
# rename on either side breaks THIS gate instead of silently voiding a
# runtime gate downstream.
#
#   (a) the defensive stderr marker 'WEBVIEW2 RUNTIME UNUSABLE', the
#       CAP-6 42 PASS marker and the CAP-6b3 fixed-runtime markers
#       must appear literally in the producer
#       examples/08-release/releaseapp.pas AND in EVERY registered
#       consumer script that greps them (CAP-6, CAP-6b1, CAP-6b2 and
#       CAP-6b3 gates; an empty consumer set is an error)
#   (b) every WV2PROV_* line prefix that any CAP-6b1 gate, any
#       CAP-6b2 offline gate or either clean-machine gate
#       regex-matches must appear in the helper source
#       tools/setup/pwebwv2prov.pas (the producer)
#   (c) the setup AppId GUID is authored ONCE in the shared identity
#       include tools/setup/pwebappsetup.issi; every gate script that
#       touches the per-user uninstall registry key must carry the
#       exact same GUID literal - a drift on either side breaks this
#       gate, not a runtime gate
#   (d) every WV2FIXED_* line prefix that any CAP-6b3 gate or the
#       fixed profile manifest regex-matches must appear in the helper
#       source tools/setup/pwebwv2fixed.pas (the producer)
#   (e) the fixed profile's verdict-file name is authored once in
#       tools/setup/fixed.iss, is wired to FixedRuntimeGate, is never
#       weakened with skipifsourcedoesntexist, and is carried by every
#       gate script that asserts it stays out of the installed layout
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
            'test/cap6b2/run_offline_clean_machine_gate.ps1',
            'test/cap6b3/run_fixed_setup_gates.ps1',
            'test/cap6b3/run_fixed_clean_machine_gate.ps1',
            'test/cap6b4/run_profile_matrix.ps1'
        )
    },
    # CAP-6b3: the fixed-runtime markers, produced under the
    # PWEB_FIXED_RUNTIME define in the SAME producer file
    @{
        Literal = 'FIXED RUNTIME SELECTED'
        ProducerLiterals = @(': FIXED RUNTIME SELECTED (version=')
        Consumers = @(
            'test/cap6b3/run_fixed_setup_gates.ps1',
            'test/cap6b4/run_profile_matrix.ps1'
        )
    },
    @{
        Literal = 'FIXED RUNTIME REFUSED'
        ProducerLiterals = @(': FIXED RUNTIME REFUSED (status=')
        Consumers = @(
            'test/cap6b3/run_fixed_setup_gates.ps1',
            'test/cap6b3/run_fixed_clean_machine_gate.ps1',
            'test/cap6b4/run_profile_matrix.ps1'
        )
    },
    @{
        Literal = 'FIXED RUNTIME IDENTITY OK '
        ProducerLiterals = @(': FIXED RUNTIME IDENTITY OK ')
        Consumers = @(
            'test/cap6b3/run_fixed_setup_gates.ps1',
            'test/cap6b3/run_fixed_clean_machine_gate.ps1',
            'test/cap6b4/run_profile_matrix.ps1'
        )
    },
    # the post-create refusal: its own marker, because 'FIXED RUNTIME
    # REFUSED' does NOT match it and an identity refusal must never
    # fall into a gate's generic failure branch
    @{
        Literal = 'FIXED RUNTIME IDENTITY REFUSED'
        ProducerLiterals = @(': FIXED RUNTIME IDENTITY REFUSED (status=')
        Consumers = @(
            'test/cap6b3/run_fixed_setup_gates.ps1',
            'test/cap6b4/run_profile_matrix.ps1'
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
    (Join-Path $RepoRoot 'test/cap6b2/run_offline_clean_machine_gate.ps1'),
    # CAP-6b4: the profile matrix reads the provisioning verdict out of
    # the setup log on every switch that LEAVES the fixed profile
    (Join-Path $RepoRoot 'test/cap6b4/run_profile_matrix.ps1')
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

# --- (b2) the CAP-6b3 provisioning BAN is complete ---------------------------
# The fixed-profile gates do not CONSUME a provisioning prefix: they ban
# the whole vocabulary with the bare literal 'WV2PROV_'. A bare literal
# is only a complete ban while EVERY prefix the helper can emit starts
# with it - so that is what gets asserted here, rather than pretending
# these files are prefix consumers (they matched zero prefixes above,
# which would have made their registration a silent no-op).
$produced = [System.Collections.Generic.SortedSet[string]]::new()
foreach ($m in [regex]::Matches($helperSource, 'WV2PROV_[A-Z]+')) {
    [void]$produced.Add($m.Value)
}
if ($produced.Count -eq 0) {
    throw 'the provisioning helper emits no WV2PROV_ prefix - the ban is vacuous'
}
$banConsumers = @(
    'test/cap6b3/run_fixed_setup_gates.ps1',
    'test/cap6b3/run_fixed_clean_machine_gate.ps1'
)
foreach ($rel in $banConsumers) {
    $f = Join-Path $RepoRoot $rel
    if (-not (Test-Path $f)) { throw "ban consumer script missing: $f" }
    if (-not (Get-Content $f -Raw).Contains('WV2PROV_')) {
        throw "$rel lost the bare 'WV2PROV_' provisioning ban"
    }
}
$unbanned = @($produced | Where-Object { -not $_.StartsWith('WV2PROV_', [StringComparison]::Ordinal) })
if ($unbanned) {
    throw ("the bare 'WV2PROV_' ban in the CAP-6b3 gates would MISS the " +
        "helper prefix(es): $($unbanned -join ', ')")
}
Write-Host ("CAP-6b1 contract (b2) PASS ($($banConsumers.Count) CAP-6b3 gates " +
    "ban all $($produced.Count) provisioning prefixes with one literal)")

# --- (c) AppId GUID contract: authored once in the shared identity include ---
# CAP-6b3 moved it one level down, from pwebprovgate.issi into
# pwebappsetup.issi, so the non-provisioning fixed profile shares the
# very same installed-application identity
$issi = Get-Content (Join-Path $RepoRoot 'tools/setup/pwebappsetup.issi') -Raw
# Inno escapes one literal '{' as '{{': AppId={{<GUID>}
$appIdMatch = [regex]::Match($issi, '(?m)^AppId=\{\{([0-9A-Fa-f-]+)\}\s*$')
if (-not $appIdMatch.Success) {
    throw 'pwebappsetup.issi does not author the AppId={{...} directive'
}
$appId = $appIdMatch.Groups[1].Value
# the provisioning include must NOT author a second one: two AppIds
# would be two applications wearing one name
$provIssi = Get-Content (Join-Path $RepoRoot 'tools/setup/pwebprovgate.issi') -Raw
if ($provIssi -match '(?m)^AppId=') {
    throw 'pwebprovgate.issi authors its own AppId - the identity has forked'
}
if ($provIssi -notmatch 'pwebappsetup\.issi') {
    throw 'pwebprovgate.issi does not consume the shared identity include'
}
$fixedIss = Get-Content (Join-Path $RepoRoot 'tools/setup/fixed.iss') -Raw
if ($fixedIss -notmatch 'pwebappsetup\.issi') {
    throw 'fixed.iss does not consume the shared identity include'
}
$appIdConsumers = @(
    'test/cap6b1/run_normal_setup_gates.ps1',
    'test/cap6b2/run_offline_setup_gates.ps1',
    'test/cap6b3/run_fixed_setup_gates.ps1',
    # CAP-6b4: the matrix asserts there is exactly ONE uninstall
    # registration for this AppId across every profile switch
    'test/cap6b4/run_profile_matrix.ps1'
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

# --- (d) WV2FIXED_* prefix contract (CAP-6b3) --------------------------------
$fixedHelperSource = Get-Content (Join-Path $RepoRoot 'tools/setup/pwebwv2fixed.pas') -Raw
$fixedConsumers = @(
    (Join-Path $RepoRoot 'test/cap6b3/build_fixed_setup.ps1'),
    (Join-Path $RepoRoot 'test/cap6b3/run_fixed_setup_gates.ps1'),
    (Join-Path $RepoRoot 'test/cap6b3/run_fixed_clean_machine_gate.ps1'),
    (Join-Path $RepoRoot 'tools/setup/fixed.iss'),
    # CAP-6b4: the matrix consumes the fixed helper's detector and ACL
    # verdicts to prove the shared Evergreen runtime was never touched
    (Join-Path $RepoRoot 'test/cap6b4/run_profile_matrix.ps1')
)
$wantedFixed = [System.Collections.Generic.SortedSet[string]]::new()
foreach ($f in $fixedConsumers) {
    if (-not (Test-Path $f)) { throw "consumer script missing: $f" }
    foreach ($m in [regex]::Matches((Get-Content $f -Raw), 'WV2FIXED_[A-Z]+')) {
        [void]$wantedFixed.Add($m.Value)
    }
}
if ($wantedFixed.Count -eq 0) {
    throw 'no WV2FIXED_ prefixes found in any consumer - the contract check is broken'
}
$missingFixed = @()
foreach ($prefix in $wantedFixed) {
    if (-not $fixedHelperSource.Contains($prefix)) { $missingFixed += $prefix }
}
if ($missingFixed) {
    throw ("fixed helper source does not produce the gate-consumed prefix(es): " +
        ($missingFixed -join ', '))
}
Write-Host ("CAP-6b1 contract (d) PASS ($($wantedFixed.Count) WV2FIXED_ prefixes " +
    'consumed by the CAP-6b3 gates all produced by the fixed helper)')

# --- (e) the fixed profile's verdict-file name (CAP-6b3) ---------------------
# The fixed setup's fail-closed gate is expressed as a verdict FILE: the
# last [Files] entry's external source, written only on success. Its name
# is authored once in fixed.iss, and the gate script asserts that file
# never lands in {app} - so a rename on either side must break THIS gate,
# not silently void the layout assertion downstream.
$fixedIssRaw = Get-Content (Join-Path $RepoRoot 'tools/setup/fixed.iss') -Raw
$verdictMatch = [regex]::Match($fixedIssRaw,
    '(?m)^#define\s+PWEB_VERDICT_FILE\s+"([^"]+)"\s*$')
if (-not $verdictMatch.Success) {
    throw 'fixed.iss does not author the PWEB_VERDICT_FILE define'
}
$verdictName = $verdictMatch.Groups[1].Value
if ($fixedIssRaw -notmatch 'BeforeInstall:\s*FixedRuntimeGate') {
    throw 'fixed.iss does not wire the verdict entry to the FixedRuntimeGate'
}
# anchored on an actual Flags: usage, so the comment explaining WHY the
# flag is absent cannot trip the check that proves it is absent
if ($fixedIssRaw -match '(?m)^\s*Flags:[^\r\n]*skipifsourcedoesntexist') {
    throw ('fixed.iss uses skipifsourcedoesntexist - that flag would turn ' +
        'the missing-verdict FAILURE SIGNAL into a silent skip')
}
$verdictConsumers = @('test/cap6b3/run_fixed_setup_gates.ps1')
# CAP-6b4: the fixed profile's [Files] ORDER around that verdict entry is
# itself a contract (the shared release triple must come AFTER it); it is
# proven by test/cap6b4/check_cap6b4_contracts.ps1 contract (d)
foreach ($rel in $verdictConsumers) {
    $f = Join-Path $RepoRoot $rel
    if (-not (Test-Path $f)) { throw "verdict consumer script missing: $f" }
    if (-not (Get-Content $f -Raw).Contains($verdictName)) {
        throw "$rel does not carry the verdict-file name '$verdictName'"
    }
}
Write-Host ("CAP-6b1 contract (e) PASS (verdict file '$verdictName' authored " +
    "in fixed.iss, gated by FixedRuntimeGate, matched by " +
    "$($verdictConsumers.Count) gate script(s))")

Write-Host 'CAP6B1_CONTRACTS_PASS'
