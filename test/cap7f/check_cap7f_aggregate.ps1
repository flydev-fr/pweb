# CAP-7F: the final cross-platform aggregator. Consumes the four per-target
# evidence artifacts (windows, linux, macos-x64, macos-arm64) plus the two
# macOS release manifest/inventory artifacts, compares STRUCTURED verdict
# fields - never localized prose - and fails on ANY semantic disagreement:
#
#   - a target's evidence artifact absent            -> fail naming the target
#   - a required field absent or empty               -> fail naming target+field
#   - a field disagreeing across targets             -> fail naming field + both values
#   - a PASS-required field reading SKIP or WAIVED   -> fail (SKIP is never promoted)
#   - the macOS manifests not matching the evidence  -> fail (independent cross-check)
#
# On full agreement it writes build/cap7f/platform-matrix.json - the machine
# form of the CAP-7 closure matrix - and a step summary. On ANY failure it
# writes NO matrix (exit 1): a partial matrix is exactly the artifact that
# would get quoted as if it were the proof.
#
# Existence-check-before-diff pattern copied from the macos-release-inventory
# job (a diff against a missing file must fail the gate, not empty it).
#
# Usage:
#   pwsh test/cap7f/check_cap7f_aggregate.ps1 [-EvidenceRoot ev] [-MacosInventoryRoot inv]
# expecting:
#   <EvidenceRoot>/{windows,linux,macos-x64,macos-arm64}/evidence.json
#   <MacosInventoryRoot>/{x64,arm64}/{manifest,inventory}-{react,pas2js}.txt
param(
    [string]$EvidenceRoot = 'ev',
    [string]$MacosInventoryRoot = 'inv'
)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
$failures = New-Object System.Collections.Generic.List[string]

# artifact-directory name -> the target id its evidence must declare
$targets = [ordered]@{
    'windows'     = 'windows-x86_64'
    'linux'       = 'linux-x86_64'
    'macos-x64'   = 'macos-x86_64'
    'macos-arm64' = 'macos-arm64'
}
# per-target structural expectations (recorded facts that are per-target by
# nature and therefore validated against a map instead of cross-compared)
$expectations = @{
    'windows-x86_64' = @{ os = 'windows'; arch = 'x86_64'; engine = 'WebView2' }
    'linux-x86_64'   = @{ os = 'linux'; arch = 'x86_64'; engine = 'WebKitGTK 4.1' }
    'macos-x86_64'   = @{ os = 'macos'; arch = 'x86_64'; engine = 'WKWebView' }
    'macos-arm64'    = @{ os = 'macos'; arch = 'arm64'; engine = 'WKWebView' }
}
$required = @(
    'schema', 'target', 'os', 'arch', 'fpc', 'cc', 'webview_pin',
    'webview_surface', 'engine', 'exports', 'extra_exports_rtti', 'origin',
    'secure', 'bundle_protocol', 'rpc_add_20_22', 'runtime_provenance',
    'host_args', 'capability_policy', 'capability_policy_digest',
    'navigation_security', 'navigation_policy_digest',
    'security_corpus', 'security_corpus_digest',
    'cap8c_denied_soa', 'cap8c_opener_nonmain', 'cap8c_secure_origin',
    'quickjs_corpus', 'quickjs_corpus_digest',
    'cap9a_denied_bridge', 'cap9a_opener_reached',
    'release_layout', 'no_listener', 'app_pwb_react_sha256',
    'logical_inventory_sha256_react', 'github_sha', 'github_run_id', 'waivers'
)
# absolute pins: equality across targets is not enough - four targets that
# all drifted to protocol 2 would agree perfectly, and this matrix is the
# CLOSURE record of the ratified values, not of whatever consensus emerged
$absolutePins = @{
    bundle_protocol = '1'
    origin          = 'pweb://app'
    secure          = 'true'
    rpc_add_20_22   = '42'
}
# fields that must read exactly PASS on every target; SKIP/WAIVED never promote
$mustPass = @('release_layout', 'no_listener', 'host_args', 'capability_policy',
    'navigation_security', 'security_corpus', 'quickjs_corpus')
# fields that must agree, value-for-value, across all four targets
# (capability_policy_digest is the CAP-8A structured policy-decision corpus and
# navigation_policy_digest the CAP-8B one: four targets, one byte-identical
# decision set each, or red)
$equalityFields = @(
    'fpc', 'webview_pin', 'webview_surface', 'origin', 'secure',
    'bundle_protocol', 'rpc_add_20_22', 'logical_inventory_sha256_react',
    'capability_policy_digest', 'navigation_policy_digest',
    'security_corpus_digest', 'quickjs_corpus_digest', 'github_sha'
)
# targets that additionally carry a pas2js logical inventory
$pas2jsTargets = @('linux-x86_64', 'macos-x86_64', 'macos-arm64')

# --- load + per-target validation -------------------------------------------
$evidence = [ordered]@{}
foreach ($dir in $targets.Keys) {
    $file = Join-Path $EvidenceRoot (Join-Path $dir 'evidence.json')
    if (-not (Test-Path $file)) {
        $failures.Add("TARGET ARTIFACT ABSENT: $($targets[$dir]) (expected $file)")
        continue
    }
    try {
        $e = Get-Content $file -Raw | ConvertFrom-Json
    } catch {
        $failures.Add("TARGET EVIDENCE UNPARSEABLE: $($targets[$dir]) ($file): $_")
        continue
    }
    foreach ($field in $required) {
        $v = $e.PSObject.Properties[$field]
        if ($null -eq $v -or $null -eq $v.Value -or "$($v.Value)" -eq '') {
            $failures.Add("REQUIRED FIELD MISSING/EMPTY: target=$($targets[$dir]) field=$field")
        }
    }
    if ($e.schema -ne 1) {
        $failures.Add("SCHEMA MISMATCH: target=$($targets[$dir]) schema=$($e.schema), expected 1")
    }
    if ($e.target -ne $targets[$dir]) {
        $failures.Add("TARGET IDENTITY MISMATCH: artifact dir '$dir' declares target '$($e.target)', expected '$($targets[$dir])'")
    }
    $evidence[$targets[$dir]] = $e
}

foreach ($t in $evidence.Keys) {
    $e = $evidence[$t]
    $exp = $expectations[$t]
    foreach ($k in @('os', 'arch', 'engine')) {
        if ("$($e.$k)" -cne $exp[$k]) {
            $failures.Add("FIELD DISAGREES WITH THE TARGET MAP: target=$t field=$k value='$($e.$k)' expected='$($exp[$k])'")
        }
    }
    foreach ($f in $mustPass) {
        $v = "$($e.$f)"
        if ($v -in @('SKIP', 'WAIVED')) {
            $failures.Add("SKIP/WAIVED NEVER PROMOTES: target=$t field=$f reads '$v' where the matrix requires PASS")
        }
        elseif ($v -cne 'PASS') {
            $failures.Add("REQUIRED-PASS FIELD NOT PASS: target=$t field=$f value='$v'")
        }
    }
    foreach ($f in $absolutePins.Keys) {
        $v = "$($e.$f)"
        if ($v -cne $absolutePins[$f]) {
            $failures.Add("ABSOLUTE PIN VIOLATED: target=$t field=$f value='$v' pinned='$($absolutePins[$f])'")
        }
    }
    # the export surface: exactly 17 webview_* names, no strays
    $ex = @($e.exports)
    if ($ex.Count -ne 17) {
        $failures.Add("EXPORT COUNT: target=$t has $($ex.Count) exports, expected exactly 17")
    }
    foreach ($name in $ex) {
        if ($name -cnotmatch '^webview_[a-z_]+$') {
            $failures.Add("EXPORT NAME SHAPE: target=$t exports '$name'")
        }
    }
    # CAP-8C defense in depth, only meaningful where the corpus is PASS (a
    # SKIP/FAIL already failed mustPass above): a denied principal must never
    # have reached the SOA bridge, only the Main principal may reach the
    # opener, and every privileged document must run in the secure origin.
    # The numeric casts are GUARDED: a non-numeric value becomes a named
    # failure entry, never a mid-validation crash that hides the other rows.
    if ("$($e.security_corpus)" -ceq 'PASS') {
        $soaVal = 0
        if (-not [int]::TryParse("$($e.cap8c_denied_soa)", [ref]$soaVal)) {
            $failures.Add("CAP-8C NON-NUMERIC: target=$t cap8c_denied_soa='$($e.cap8c_denied_soa)'")
        } elseif ($soaVal -ne 0) {
            $failures.Add("CAP-8C DENIED-SOA>0: target=$t cap8c_denied_soa=$soaVal -- a forbidden principal reached the bridge")
        }
        $openerVal = 0
        if (-not [int]::TryParse("$($e.cap8c_opener_nonmain)", [ref]$openerVal)) {
            $failures.Add("CAP-8C NON-NUMERIC: target=$t cap8c_opener_nonmain='$($e.cap8c_opener_nonmain)'")
        } elseif ($openerVal -ne 0) {
            $failures.Add("CAP-8C NON-MAIN OPENER: target=$t cap8c_opener_nonmain=$openerVal -- a non-Main principal (or an unexpected URI) reached the opener")
        }
        if ("$($e.cap8c_secure_origin)" -cne 'true') {
            $failures.Add("CAP-8C SECURE ORIGIN false: target=$t cap8c_secure_origin='$($e.cap8c_secure_origin)'")
        }
    }
    # CAP-9A defense in depth, only meaningful where the corpus is PASS: a
    # denied QuickJS principal must never have reached the bridge Add arm,
    # and no plugin may have reached the pweb.openExternal bridge arm at
    # all (neither reference plugin holds external.open). Guarded numeric
    # casts, exactly as the CAP-8C block above.
    if ("$($e.quickjs_corpus)" -ceq 'PASS') {
        $qjsDenied = 0
        if (-not [int]::TryParse("$($e.cap9a_denied_bridge)", [ref]$qjsDenied)) {
            $failures.Add("CAP-9A NON-NUMERIC: target=$t cap9a_denied_bridge='$($e.cap9a_denied_bridge)'")
        } elseif ($qjsDenied -ne 0) {
            $failures.Add("CAP-9A DENIED-BRIDGE>0: target=$t cap9a_denied_bridge=$qjsDenied -- a forbidden QuickJS principal reached the bridge")
        }
        $qjsOpener = 0
        if (-not [int]::TryParse("$($e.cap9a_opener_reached)", [ref]$qjsOpener)) {
            $failures.Add("CAP-9A NON-NUMERIC: target=$t cap9a_opener_reached='$($e.cap9a_opener_reached)'")
        } elseif ($qjsOpener -ne 0) {
            $failures.Add("CAP-9A OPENER REACHED: target=$t cap9a_opener_reached=$qjsOpener -- a QuickJS plugin reached the openExternal bridge arm without external.open")
        }
    }
}

# --- cross-target equality ---------------------------------------------------
if ($evidence.Count -eq $targets.Count -and $failures.Count -eq 0) {
    $names = @($evidence.Keys)
    $ref = $evidence[$names[0]]
    foreach ($f in $equalityFields) {
        foreach ($t in $names[1..($names.Count - 1)]) {
            $a = "$($ref.$f)"
            $b = "$($evidence[$t].$f)"
            if ($a -cne $b) {
                $failures.Add("FIELD DISAGREES: $f -- $($names[0])='$a' vs ${t}='$b'")
            }
        }
    }
    # export SET equality (order-independent; the emitters already sort)
    $refSet = (@($ref.exports) | Sort-Object) -join ','
    foreach ($t in $names[1..($names.Count - 1)]) {
        $set = (@($evidence[$t].exports) | Sort-Object) -join ','
        if ($set -cne $refSet) {
            $failures.Add("EXPORT SET DISAGREES: $($names[0])=[$refSet] vs ${t}=[$set]")
        }
    }
    # pas2js logical inventory: present and equal where the target ships it
    $p2jRef = $null
    foreach ($t in $pas2jsTargets) {
        $v = "$($evidence[$t].logical_inventory_sha256_pas2js)"
        if (-not $v) {
            $failures.Add("REQUIRED FIELD MISSING/EMPTY: target=$t field=logical_inventory_sha256_pas2js")
            continue
        }
        if ($null -eq $p2jRef) { $p2jRef = @{ t = $t; v = $v } }
        elseif ($v -cne $p2jRef.v) {
            $failures.Add("FIELD DISAGREES: logical_inventory_sha256_pas2js -- $($p2jRef.t)='$($p2jRef.v)' vs ${t}='$v'")
        }
    }
}

# --- independent manifest cross-checks, ALL targets --------------------------
# The evidence's logical_inventory_sha256 must equal the SHA-256 of the
# manifest ARTIFACT the same job uploaded beside it - a field is never
# taken at its word when the bytes it summarizes are sitting in the run.
foreach ($check in @(
    @{ dir = 'windows'; target = 'windows-x86_64'; frontends = @('react') },
    @{ dir = 'linux'; target = 'linux-x86_64'; frontends = @('react', 'pas2js') })) {
    foreach ($fe in $check.frontends) {
        $manifest = Join-Path $EvidenceRoot (Join-Path $check.dir "manifest-$fe.txt")
        if (-not (Test-Path $manifest)) {
            $failures.Add("MANIFEST ARTIFACT ABSENT: $manifest")
            continue
        }
        if (-not $evidence.Contains($check.target)) { continue }
        $manifestSha = (Get-FileHash $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        $evField = "logical_inventory_sha256_$fe"
        $evSha = "$($evidence[$check.target].$evField)"
        if ($manifestSha -cne $evSha) {
            $failures.Add("FIELD DISAGREES: $evField ($($check.target)) -- evidence='$evSha' vs manifest-artifact sha256='$manifestSha'")
        }
    }
}

# macOS additionally cross-checks the inventory ROW the release gate wrote -
# three sources, one value, or the aggregate is red.
foreach ($pair in @(@{ dir = 'x64'; target = 'macos-x86_64' },
                    @{ dir = 'arm64'; target = 'macos-arm64' })) {
    foreach ($fe in @('react', 'pas2js')) {
        $manifest = Join-Path $MacosInventoryRoot (Join-Path $pair.dir "manifest-$fe.txt")
        $inventory = Join-Path $MacosInventoryRoot (Join-Path $pair.dir "inventory-$fe.txt")
        foreach ($f in @($manifest, $inventory)) {
            if (-not (Test-Path $f)) {
                $failures.Add("MACOS INVENTORY ARTIFACT ABSENT: $f")
            }
        }
        if (-not ((Test-Path $manifest) -and (Test-Path $inventory))) { continue }
        if (-not $evidence.Contains($pair.target)) { continue }
        $manifestSha = (Get-FileHash $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        $invRow = @(Select-String -Path $inventory -Pattern '^logical_inventory_sha256=(.+)$')
        if ($invRow.Count -ne 1) {
            $failures.Add("MACOS INVENTORY ROW ABSENT: logical_inventory_sha256 in $inventory")
            continue
        }
        $invSha = $invRow[0].Matches[0].Groups[1].Value
        $evField = "logical_inventory_sha256_$fe"
        $evSha = "$($evidence[$pair.target].$evField)"
        if ($manifestSha -cne $evSha) {
            $failures.Add("FIELD DISAGREES: $evField ($($pair.target)) -- evidence='$evSha' vs manifest-artifact sha256='$manifestSha'")
        }
        if ($invSha -cne $evSha) {
            $failures.Add("FIELD DISAGREES: $evField ($($pair.target)) -- evidence='$evSha' vs inventory row='$invSha'")
        }
    }
}

# --- verdict -----------------------------------------------------------------
if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "AGGREGATE FAIL: $f" }
    if ($env:GITHUB_STEP_SUMMARY) {
        ("### CAP-7F aggregate: FAIL`n" +
         (($failures | ForEach-Object { "- $_" }) -join "`n")) |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    throw "CAP-7F aggregation FAILED: $($failures.Count) disagreement(s); no matrix written"
}

# --- the matrix --------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap7f | Out-Null
$first = $evidence[$($evidence.Keys | Select-Object -First 1)]
$matrix = [ordered]@{
    schema     = 1
    github_sha = $first.github_sha
    agreement  = [ordered]@{
        fpc                            = $first.fpc
        webview_pin                    = $first.webview_pin
        webview_surface                = $first.webview_surface
        exports                        = @($first.exports)
        origin                         = $first.origin
        secure                         = $first.secure
        bundle_protocol                = $first.bundle_protocol
        rpc_add_20_22                  = $first.rpc_add_20_22
        capability_policy_digest       = $first.capability_policy_digest
        navigation_policy_digest       = $first.navigation_policy_digest
        security_corpus_digest         = $first.security_corpus_digest
        quickjs_corpus_digest          = $first.quickjs_corpus_digest
        logical_inventory_sha256_react = $first.logical_inventory_sha256_react
        logical_inventory_sha256_pas2js = $evidence['linux-x86_64'].logical_inventory_sha256_pas2js
    }
    targets    = [ordered]@{}
}
foreach ($t in $evidence.Keys) {
    $e = $evidence[$t]
    $matrix.targets[$t] = [ordered]@{
        os                 = $e.os
        arch               = $e.arch
        engine             = $e.engine
        cc                 = $e.cc
        extra_exports_rtti = $e.extra_exports_rtti
        host_args          = $e.host_args
        capability_policy  = $e.capability_policy
        navigation_security = $e.navigation_security
        security_corpus    = $e.security_corpus
        quickjs_corpus     = $e.quickjs_corpus
        release_layout     = $e.release_layout
        no_listener        = $e.no_listener
        runtime_provenance = $e.runtime_provenance
        github_run_id      = $e.github_run_id
        waivers            = @($e.waivers)
    }
}
$json = $matrix | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText(
    (Join-Path (Resolve-Path build/cap7f).Path 'platform-matrix.json'),
    $json + "`n", [System.Text.UTF8Encoding]::new($false))

$summary = @()
$summary += '### CAP-7F aggregate: PASS - four targets, field-by-field agreement'
$summary += ''
$summary += '| target | engine | host_args | cap_policy | nav_security | sec_corpus | qjs_corpus | layout | no_listener | rtti extras |'
$summary += '|---|---|---|---|---|---|---|---|---|---|'
foreach ($t in $evidence.Keys) {
    $e = $evidence[$t]
    $summary += "| $t | $($e.engine) | $($e.host_args) | $($e.capability_policy) | $($e.navigation_security) | $($e.security_corpus) | $($e.quickjs_corpus) | $($e.release_layout) | $($e.no_listener) | $($e.extra_exports_rtti) |"
}
$summary += ''
$summary += "- webview pin ``$($first.webview_pin)``, surface ``$($first.webview_surface)``, origin ``$($first.origin)`` (secure=$($first.secure)), RPC Add(20,22)=$($first.rpc_add_20_22)"
$summary += "- CAP-8A capability_policy_digest ``$($first.capability_policy_digest)`` equal on all four targets"
$summary += "- CAP-8B navigation_policy_digest ``$($first.navigation_policy_digest)`` equal on all four targets"
$summary += "- CAP-8C security_corpus_digest ``$($first.security_corpus_digest)`` equal on all four targets"
$summary += "- CAP-9A quickjs_corpus_digest ``$($first.quickjs_corpus_digest)`` equal on all four targets"
$summary += "- react logical_inventory_sha256 ``$($first.logical_inventory_sha256_react)`` equal on all four targets"
$summary += "- pas2js logical_inventory_sha256 ``$($matrix.agreement.logical_inventory_sha256_pas2js)`` equal on linux/macos-x64/macos-arm64"
$summaryText = $summary -join "`n"
Write-Host $summaryText
if ($env:GITHUB_STEP_SUMMARY) {
    $summaryText | Out-File -Append $env:GITHUB_STEP_SUMMARY
}
Write-Host '[CAP-7F] aggregate PASS - platform-matrix.json written'
