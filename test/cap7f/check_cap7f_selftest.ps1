# CAP-7F: committed NEGATIVE self-test of the aggregation machinery, run in
# the cap7-aggregate job BEFORE the real aggregation. The aggregator's and
# the divergence sweep's FAILURE branches are the product here - a comparator
# whose red paths were only ever human-verified is a comparator whose red
# paths rot - so every hosted run proves, against copies of the freshly
# downloaded evidence, that:
#
#   (a) one evidence artifact deleted      -> aggregator exits nonzero, no matrix
#   (b) one field perturbed (webview_pin)  -> aggregator exits nonzero, no matrix
#   (c) a PASS field rewritten to SKIP     -> aggregator exits nonzero, no matrix
#   (c2) capability_policy (CAP-8A) rewritten to SKIP -> same refusal
#   (c3) capability_policy_digest diverging on one target -> same refusal
#   (c6) security_corpus (CAP-8C) rewritten to SKIP -> same refusal
#   (c7) security_corpus_digest diverging on one target -> same refusal
#   (c8) cap8c_denied_soa=1 with a PASS corpus -> defense-in-depth refusal
#   (c9) cap8c_opener_nonmain=1 with a PASS corpus -> defense-in-depth refusal
#   (c10) cap8c_secure_origin=false with a PASS corpus -> same refusal
#   (c11) quickjs_corpus (CAP-9A) rewritten to FAIL -> mustPass refusal
#   (c12) quickjs_corpus_digest diverging on one target -> same refusal
#   (c13) cap9a_denied_bridge=1 with a PASS corpus -> defense-in-depth refusal
#   (c14) cap9a_opener_reached=1 with a PASS corpus -> same refusal
#   (c15) quickjs_package_corpus (CAP-9B1) rewritten to FAIL -> mustPass refusal
#   (c16) quickjs_package_digest diverging on one target -> same refusal
#   (c17) cap9b1_loadtime_bridge=1 with a PASS corpus -> defense-in-depth refusal
#   (c18) cap9b1_loader_wrong_thread=1 with a PASS corpus -> same refusal
#   (c19) a non-numeric CAP-9B1 counter -> NON-NUMERIC refusal
#   (c20) quickjs_lifecycle_corpus (CAP-9B2) rewritten to FAIL -> mustPass refusal
#   (c21) quickjs_lifecycle_digest diverging on one target -> same refusal
#   (c22) cap9b2_two_active_generations=1 with a PASS corpus -> defense-in-depth
#   (c23) cap9b2_reload_lost_old=1 with a PASS corpus -> same refusal
#   (c24) cap9b2_quarantine_unexpected=1 with a PASS corpus -> same refusal
#   (c25) cap9b2_quarantine_injected=0 with a PASS corpus -> the OTHER direction:
#         an unexercised last-resort path is refused too
#   (c26) a non-numeric CAP-9B2 counter -> NON-NUMERIC refusal
#   (c27) quickjs_release_corpus (CAP-9C1) rewritten to FAIL -> mustPass refusal
#   (c28) quickjs_release_digest diverging on one target -> same refusal
#   (c29) cap9c1_inventory_digest diverging on one target -> the SEMANTIC
#         equality that survives the archive bytes differing per toolchain
#   (c30) cap9c1_browser_store_arrivals=1 with a PASS corpus -> defense-in-depth
#   (c31) cap9c1_tamper_started=1 with a PASS corpus -> same refusal
#   (c32) cap9c1_cwd_dependency=1 with a PASS corpus -> same refusal
#   (c33) a malformed cap9c1_package_sha256 -> BAD-PACKAGE-SHA refusal, the
#         per-target facts the equality set deliberately does NOT compare
#   (c34) cap9c1_package_bytes=0 with a PASS corpus -> EMPTY-PACKAGE refusal
#   (c35) quickjs_gui_corpus (CAP-9C2) ABSENT -> required-field refusal
#   (c36) quickjs_gui_corpus rewritten to SKIP -> mustPass refusal
#   (c37) quickjs_gui_digest diverging on one target -> equality refusal
#   (c38) browser_plugin_store_arrivals not green -> a pweb://app probe
#         reached the plugin package bytes
#   (c39) browser_plugin_script_marker not green -> plugin source executed
#         as WebView JavaScript
#   (c40) raw_channel_source_bytes not green -> plugin bytes in a browser
#         or native result
#   (c41) reporting_soa_count not green -> denied plugin activity reached
#         the SOA layer
#   (c42) same_scheduler / same_bridge not green -> the UI and the plugins
#         ran on DIFFERENT runtime objects, which CAP-9 refuses even when
#         both answered 42
#   (c43) ui_survived_timeout / neighbour_survived_timeout not green -> a
#         resource-limit failure took the UI or a neighbour with it
#   (c44) a cap9c2_gates member ABSENT -> MISSING-GATE refusal (a renamed
#         field must not read as green)
#   (c45) cap9c2_listeners=1 -> LISTENERS>0 refusal
#   (c46) cap9c2_negative_reparse='waived' -> a waiver never promotes
#   (c47) cap9c2_license_sha256 not the frozen digest -> LICENSE SHA refusal
#   (c48) cli_corpus (CAP-10A) ABSENT -> required-field refusal
#   (c49) cli_corpus rewritten to SKIP -> mustPass refusal
#   (c50) cli_digest diverging on one target -> equality refusal
#   (c51) doctor_schema_digest diverging on one target -> equality refusal
#   (c52) an EMPTY cli_digest on EVERY target with a PASS corpus ->
#         BAD-DIGEST refusal. This leg closes a subtle hole and is why the
#         branch exists at all: four empty strings agree perfectly, so a gate
#         that stopped emitting would look exactly like one that passed
#         everywhere
#   (c53) doctor_no_mutation=FAIL -> mustPass refusal (`pweb doctor` wrote
#         something, which is the one thing that command promises never to do)
#   (c54) cli_exit_taxonomy=FAIL -> mustPass refusal
#   (c55) cli_version_line not the contract shape -> BAD-VERSION-LINE refusal
#   (c56) doctor_checks=0 with a PASS corpus -> NO-ROWS refusal
#   (c57) template_corpus (CAP-10B0) ABSENT -> required-field refusal
#   (c58) template_corpus rewritten to SKIP -> mustPass refusal
#   (c59) template_digest diverging on one target -> equality refusal
#   (c60) an EMPTY template_semantic_digest on EVERY target -> BAD-DIGEST
#         refusal. The c52 hole, aimed at the field that carries the whole
#         cross-target weight now that the archive BYTES are per-OS-family
#         (mORMot stamps the creating OS into `version made by`; MEASURED
#         on run 33093385300 as one hash for windows+linux and another for
#         the two macOS targets, same length and same inventory)
#   (c61) template_semantic_digest diverging -> equality refusal (the
#         archive's MEANING, which must agree even though its bytes do not)
#   (c62) an EMPTY template_pack_digest on EVERY target -> BAD-DIGEST
#         refusal by SHAPE (it is not compared across targets, but it is
#         still the exact archive each target's registry pins)
#   (c63) template_deterministic=FAIL -> mustPass refusal
#   (c64) template_source_gate=FAIL -> mustPass refusal (the builder stopped
#         refusing deliberately broken template sources)
#   (c65) template_refusals drifted from 7 -> REFUSALS refusal
#   (c66) template_offline=FAIL -> mustPass refusal
#   (c67) package_manager_calls=1 -> NOT-OFFLINE refusal
#   (c68) create_absent=FAIL -> mustPass refusal (`pweb create` became
#         reachable, which CAP-10B0 exists to prevent)
#   (c69) template_pack_schema=2 -> BAD-SCHEMA refusal (an absolute pin, not
#         merely an agreement)
#   (c8-c69 additionally assert the refusal came through the EXPECTED branch
#    where one is named)
#   (e) a count-preserving directive swap in an allowlisted file
#                                          -> divergence sweep refuses via the
#                                             FINGERPRINT branch, restore -> green
#   (d) an off-allowlist {$ifdef LINUX} in a temp fixture .pas
#                                          -> divergence sweep exits nonzero,
#                                             and passes again once removed
#
# The mutations happen ONLY on copies under build/cap7f/selftest; the real
# ev/ + inv/ downloads are never touched, and the aggregate's own matrix is
# recreated by the REAL aggregation step that runs after this one.
#
# Usage:
#   pwsh test/cap7f/check_cap7f_selftest.ps1 [-EvidenceRoot ev] [-MacosInventoryRoot inv]
param(
    [string]$EvidenceRoot = 'ev',
    [string]$MacosInventoryRoot = 'inv'
)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
$evSrc = (Resolve-Path $EvidenceRoot).Path
$invSrc = (Resolve-Path $MacosInventoryRoot).Path
$agg = 'test/cap7f/check_cap7f_aggregate.ps1'
$matrix = 'build/cap7f/platform-matrix.json'
New-Item -ItemType Directory -Force build/cap7f | Out-Null
$allowedRoot = (Resolve-Path build/cap7f).Path
$fx = Join-Path $allowedRoot 'selftest'

# The one deletion in this script, guarded: the target must resolve INSIDE
# build/cap7f (never a symlinked elsewhere, never a mis-spliced path) -
# the cap7m_rm_tree discipline, in PowerShell.
function Remove-FixtureTree {
    if (-not (Test-Path $fx)) { return }
    $resolved = (Resolve-Path $fx).Path
    if (-not ($resolved.StartsWith($allowedRoot + [System.IO.Path]::DirectorySeparatorChar))) {
        throw "refusing to delete '$resolved': outside '$allowedRoot'"
    }
    Remove-Item -Recurse -Force $resolved
}

function Reset-Fixture {
    Remove-FixtureTree
    New-Item -ItemType Directory -Force $fx | Out-Null
    Copy-Item $evSrc (Join-Path $fx 'ev') -Recurse
    Copy-Item $invSrc (Join-Path $fx 'inv') -Recurse
}

# Every refusal this file proves is COUNTED rather than tallied by hand.
# The summary line used to carry a literal, and a literal is exactly what
# this repository keeps refusing elsewhere: CAP-10B0 added thirteen legs and
# the line still said sixty, which is a number nobody cross-checked. It is
# now the count of refusals that actually fired.
$script:AggRefusals = 0
$script:SweepRefusals = 0

function Invoke-AggExpectFail([string]$Label, [string]$ExpectPattern = '') {
    Remove-Item -Force -ErrorAction SilentlyContinue $matrix
    & pwsh -NoProfile -File $agg -EvidenceRoot (Join-Path $fx 'ev') `
        -MacosInventoryRoot (Join-Path $fx 'inv') *> (Join-Path $fx "$Label.log")
    if ($LASTEXITCODE -eq 0) {
        Get-Content (Join-Path $fx "$Label.log") | Write-Host
        throw "selftest ${Label}: the aggregator exited 0 where it must fail"
    }
    if (Test-Path $matrix) {
        throw "selftest ${Label}: a FAILING aggregation wrote a matrix"
    }
    # when the leg targets ONE specific refusal branch, require the refusal
    # to have come through THAT branch - a leg that passes on an unrelated
    # refusal (a typo'd mutation, a stale fixture) proves nothing
    if ($ExpectPattern -ne '') {
        if (-not (Select-String -Path (Join-Path $fx "$Label.log") `
                -Pattern $ExpectPattern -Quiet)) {
            Get-Content (Join-Path $fx "$Label.log") | Write-Host
            throw "selftest ${Label}: the aggregator refused, but not through the expected '$ExpectPattern' branch"
        }
    }
    $script:AggRefusals++
    Write-Host "[CAP-7F] selftest ${Label}: aggregator refused as required (nonzero exit, no matrix)"
}

# --- (a) one evidence artifact deleted --------------------------------------
Reset-Fixture
Remove-Item (Join-Path $fx 'ev/linux/evidence.json')
Invoke-AggExpectFail 'absent-artifact'

# --- (b) one field perturbed -------------------------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.webview_pin = 'deadbeef' + $e.webview_pin.Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'field-perturbed'

# --- (c) a PASS field rewritten to SKIP --------------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.host_args = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'skip-promotion'

# --- (c2) CAP-8A: capability_policy rewritten to SKIP ------------------------
# the CAP-8A mustPass field gets its own refusal proof: a suite verdict
# downgraded to SKIP must never aggregate as if the policy were proven.
# The property must EXIST in the downloaded evidence before it can be
# perturbed - a missing property would make the mutation itself error
# and the leg would refuse for the wrong reason.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['capability_policy']) {
    throw 'selftest cap-policy-skip: the evidence carries no capability_policy field - the emitters did not record it'
}
$e.capability_policy = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap-policy-skip'

# --- (c3) CAP-8A: capability_policy_digest diverging on ONE target -----------
# cross-target digest EQUALITY gets its own refusal proof (a divergence
# here means the four targets did not compute the same policy decisions,
# which is exactly what the aggregate exists to refuse)
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['capability_policy_digest']) {
    throw 'selftest cap-digest-divergence: the evidence carries no capability_policy_digest field - the emitters did not record it'
}
$e.capability_policy_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap-digest-divergence'

# --- (c4) CAP-8B: navigation_security rewritten to SKIP ----------------------
# the CAP-8B mustPass field gets its own refusal proof: a real-window matrix
# verdict downgraded to SKIP must never aggregate as if the enforcement were
# proven.
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['navigation_security']) {
    throw 'selftest nav-security-skip: the evidence carries no navigation_security field - the emitters did not record it'
}
$e.navigation_security = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'nav-security-skip'

# --- (c5) CAP-8B: navigation_policy_digest diverging on ONE target -----------
# cross-target digest EQUALITY of the CAP-8B decision corpus gets its own
# refusal proof (a divergence means the four targets did not compute the same
# navigation decisions - exactly what the aggregate exists to refuse).
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['navigation_policy_digest']) {
    throw 'selftest nav-digest-divergence: the evidence carries no navigation_policy_digest field - the emitters did not record it'
}
$e.navigation_policy_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'nav-digest-divergence'

# --- (c6) CAP-8C: security_corpus rewritten to SKIP --------------------------
# the CAP-8C mustPass field gets its own refusal proof: a harness verdict
# downgraded to SKIP must never aggregate as if the multi-principal
# enforcement were proven.
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['security_corpus']) {
    throw 'selftest sec-corpus-skip: the evidence carries no security_corpus field - the emitters did not record it'
}
$e.security_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'sec-corpus-skip'

# --- (c7) CAP-8C: security_corpus_digest diverging on ONE target -------------
# cross-target digest EQUALITY of the CAP-8C decision corpus gets its own
# refusal proof (a divergence means the four targets did not compute the same
# multi-principal decisions - exactly what the aggregate exists to refuse).
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['security_corpus_digest']) {
    throw 'selftest sec-digest-divergence: the evidence carries no security_corpus_digest field - the emitters did not record it'
}
$e.security_corpus_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'sec-digest-divergence'

# --- (c8) CAP-8C: a denied principal that reached the SOA bridge -------------
# denied-SOA>0 is the shape of a policy that ran AFTER the bridge instead of
# before it; with the corpus still marked PASS the aggregator must refuse it
# through the defense-in-depth branch, not accept a green corpus over a hole.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap8c_denied_soa']) {
    throw 'selftest cap8c-denied-soa: the evidence carries no cap8c_denied_soa field - the emitters did not record it'
}
$e.cap8c_denied_soa = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap8c-denied-soa' 'DENIED-SOA'

# --- (c9) CAP-8C: a non-Main principal that reached the opener ---------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap8c_opener_nonmain']) {
    throw 'selftest cap8c-opener-nonmain: the evidence carries no cap8c_opener_nonmain field - the emitters did not record it'
}
$e.cap8c_opener_nonmain = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap8c-opener-nonmain' 'NON-MAIN OPENER'

# --- (c10) CAP-8C: secure_origin false with a PASS corpus --------------------
# a privileged document outside the pweb:// origin with the corpus still
# marked PASS must be refused through the dedicated SECURE ORIGIN branch
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap8c_secure_origin']) {
    throw 'selftest cap8c-secure-origin: the evidence carries no cap8c_secure_origin field - the emitters did not record it'
}
$e.cap8c_secure_origin = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap8c-secure-origin' 'SECURE ORIGIN'

# --- (c11) CAP-9A: quickjs_corpus rewritten to FAIL --------------------------
# the CAP-9A mustPass field gets its own refusal proof: a QuickJS harness
# verdict downgraded to FAIL must never aggregate as if the invocation
# foundation were proven ('FAIL', not 'SKIP': the harness is fully headless
# and never SKIPs, so the honest bad verdict is FAIL).
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_corpus']) {
    throw 'selftest quickjs-corpus-fail: the evidence carries no quickjs_corpus field - the emitters did not record it'
}
$e.quickjs_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-corpus-fail' 'REQUIRED-PASS'

# --- (c12) CAP-9A: quickjs_corpus_digest diverging on ONE target -------------
# cross-target digest EQUALITY of the CAP-9A decision corpus gets its own
# refusal proof (a divergence means the four targets did not compute the same
# QuickJS invocation decisions - exactly what the aggregate exists to refuse).
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_corpus_digest']) {
    throw 'selftest quickjs-digest-divergence: the evidence carries no quickjs_corpus_digest field - the emitters did not record it'
}
$e.quickjs_corpus_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-digest-divergence'

# --- (c13) CAP-9A: a denied QuickJS principal that reached the bridge --------
# denied-bridge>0 with the corpus still marked PASS is the shape of a policy
# that ran after the bridge; the refusal must come through the dedicated
# CAP-9A defense-in-depth branch.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9a_denied_bridge']) {
    throw 'selftest cap9a-denied-bridge: the evidence carries no cap9a_denied_bridge field - the emitters did not record it'
}
$e.cap9a_denied_bridge = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9a-denied-bridge' 'CAP-9A DENIED-BRIDGE'

# --- (c14) CAP-9A: a plugin that reached the openExternal bridge arm ---------
# neither reference plugin holds external.open, so opener_reached>0 with a
# PASS corpus must refuse through the dedicated CAP-9A opener branch.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9a_opener_reached']) {
    throw 'selftest cap9a-opener-reached: the evidence carries no cap9a_opener_reached field - the emitters did not record it'
}
$e.cap9a_opener_reached = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9a-opener-reached' 'CAP-9A OPENER REACHED'

# --- (c15) CAP-9B1: quickjs_package_corpus rewritten to FAIL -----------------
# the CAP-9B1 mustPass field gets its own refusal proof: a package/module
# loader verdict downgraded to FAIL must never aggregate as if deterministic
# package loading were proven ('FAIL', not 'SKIP': the harness is fully
# headless and never SKIPs).
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_package_corpus']) {
    throw 'selftest quickjs-package-fail: the evidence carries no quickjs_package_corpus field - the emitters did not record it'
}
$e.quickjs_package_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-package-fail' 'REQUIRED-PASS'

# --- (c16) CAP-9B1: quickjs_package_digest diverging on ONE target -----------
# cross-target digest EQUALITY of the package/module corpus gets its own
# refusal proof: a divergence means one target resolved a different module
# graph, hashed different module bytes, or reached a different folder/ZIP
# decision - exactly the dev/prod and platform drift this shard exists to
# make impossible.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_package_digest']) {
    throw 'selftest quickjs-package-divergence: the evidence carries no quickjs_package_digest field - the emitters did not record it'
}
$e.quickjs_package_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-package-divergence'

# --- (c17) CAP-9B1: a package that reached the bridge while Loading ----------
# loadtime_bridge>0 with a PASS corpus is the shape of top-level module code
# producing backend side effects before the package was accepted; the refusal
# must come through the dedicated CAP-9B1 defense-in-depth branch.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b1_loadtime_bridge']) {
    throw 'selftest cap9b1-loadtime-bridge: the evidence carries no cap9b1_loadtime_bridge field - the emitters did not record it'
}
$e.cap9b1_loadtime_bridge = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b1-loadtime-bridge' 'CAP9B1_LOADTIME_BRIDGE'

# --- (c18) CAP-9B1: the module loader running off its owning thread ----------
# loader_wrong_thread>0 with a PASS corpus means a scheduler worker resolved,
# read or compiled plugin source - the one thing the engine-thread affinity
# rule exists to forbid.
# The six CAP-9B1 counters share ONE loop body in the aggregator, so the legs
# here exercise that body's two arms rather than every field: c17/c18 drive
# the >0 arm and c19 drives the [int]::TryParse arm. The harness itself gates
# on all six before any of them can reach the evidence at all.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b1_loader_wrong_thread']) {
    throw 'selftest cap9b1-loader-thread: the evidence carries no cap9b1_loader_wrong_thread field - the emitters did not record it'
}
$e.cap9b1_loader_wrong_thread = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b1-loader-thread' 'CAP9B1_LOADER_WRONG_THREAD'

# --- (c19) CAP-9B1: a counter that is not a number ---------------------------
# the OTHER arm of the shared loop body: a counter that cannot be parsed must
# refuse rather than silently compare as 0, which is how a fail-open default
# would look from the outside.
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b1_store_wrong_thread']) {
    throw 'selftest cap9b1-non-numeric: the evidence carries no cap9b1_store_wrong_thread field - the emitters did not record it'
}
$e.cap9b1_store_wrong_thread = 'n/a'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b1-non-numeric' 'CAP-9B1 NON-NUMERIC'

# --- (c20) CAP-9B2: quickjs_lifecycle_corpus rewritten to FAIL ---------------
# the CAP-9B2 mustPass field gets its own refusal proof: a lifecycle verdict
# downgraded to FAIL must never aggregate as if bounded unload, transactional
# reload and generation isolation were proven ('FAIL', not 'SKIP': the
# harness is fully headless and never SKIPs).
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_lifecycle_corpus']) {
    throw 'selftest quickjs-lifecycle-fail: the evidence carries no quickjs_lifecycle_corpus field - the emitters did not record it'
}
$e.quickjs_lifecycle_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-lifecycle-fail' 'REQUIRED-PASS'

# --- (c21) CAP-9B2: quickjs_lifecycle_digest diverging on ONE target ---------
# cross-target digest EQUALITY of the lifecycle corpus gets its own refusal
# proof: a divergence means one target took a different lifecycle decision -
# a different unload outcome, a different reload verdict, a different
# generation sequence - which is precisely the platform-specific lifecycle
# semantics this shard forbids.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_lifecycle_digest']) {
    throw 'selftest quickjs-lifecycle-divergence: the evidence carries no quickjs_lifecycle_digest field - the emitters did not record it'
}
$e.quickjs_lifecycle_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-lifecycle-divergence'

# --- (c22) CAP-9B2: two generations accepting invocations -------------------
# the single most important lifecycle invariant, and the one a reader cannot
# recover from the corpus text alone.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b2_two_active_generations']) {
    throw 'selftest cap9b2-two-active: the evidence carries no cap9b2_two_active_generations field - the emitters did not record it'
}
$e.cap9b2_two_active_generations = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b2-two-active' 'CAP9B2_TWO_ACTIVE_GENERATIONS'

# --- (c23) CAP-9B2: a failed staging that lost the old generation ------------
# the transactional guarantee itself: a reload that fails must leave the old
# generation Running and unchanged, so this counter is the one a regression
# in the staging path would move first.
# The seven CAP-9B2 zero-counters share ONE loop body in the aggregator, so
# c22/c23/c24 drive its >0 arm and c26 drives the [int]::TryParse arm; c25
# covers the SEPARATE exactly-one check that sits beside the loop. The
# harness gates on all of them before any can reach the evidence.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b2_reload_lost_old']) {
    throw 'selftest cap9b2-reload-lost-old: the evidence carries no cap9b2_reload_lost_old field - the emitters did not record it'
}
$e.cap9b2_reload_lost_old = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b2-reload-lost-old' 'CAP9B2_RELOAD_LOST_OLD'

# --- (c24) CAP-9B2: a routine unload that needed the quarantine path ---------
# quarantine is the last resort. A run in which an ORDINARY unload had to
# leak a generation is a run whose bounded-shutdown budget no longer holds,
# even though every other verdict would still read PASS.
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b2_quarantine_unexpected']) {
    throw 'selftest cap9b2-quarantine-unexpected: the evidence carries no cap9b2_quarantine_unexpected field - the emitters did not record it'
}
$e.cap9b2_quarantine_unexpected = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b2-quarantine-unexpected' 'CAP9B2_QUARANTINE_UNEXPECTED'

# --- (c25) CAP-9B2: the last-resort path never exercised ---------------------
# the OTHER direction, which no zero-counter can express: an injected
# quarantine count of 0 means the unjoinable-thread path was never taken, so
# "no quarantine failures" would be a statement about a path nothing ran.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b2_quarantine_injected']) {
    throw 'selftest cap9b2-quarantine-missing: the evidence carries no cap9b2_quarantine_injected field - the emitters did not record it'
}
$e.cap9b2_quarantine_injected = 0
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b2-quarantine-missing' 'QUARANTINE-INJECTED'

# --- (c26) CAP-9B2: a counter that is not a number ---------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9b2_export_wrong_thread']) {
    throw 'selftest cap9b2-non-numeric: the evidence carries no cap9b2_export_wrong_thread field - the emitters did not record it'
}
$e.cap9b2_export_wrong_thread = 'n/a'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9b2-non-numeric' 'CAP-9B2 NON-NUMERIC'

# --- (c27) CAP-9C1: quickjs_release_corpus rewritten to FAIL -----------------
# the CAP-9C1 mustPass field gets its own refusal proof: a release verdict
# downgraded to FAIL must never aggregate as if whole-package verification,
# browser invisibility and the tamper matrix were proven ('FAIL', not
# 'SKIP': the harness is fully headless and never SKIPs).
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_release_corpus']) {
    throw 'selftest quickjs-release-fail: the evidence carries no quickjs_release_corpus field - the emitters did not record it'
}
$e.quickjs_release_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-release-fail' 'REQUIRED-PASS'

# --- (c28) CAP-9C1: quickjs_release_digest diverging on ONE target -----------
# cross-target equality of the SEMANTIC release corpus. A divergence means
# one target reached a different packaging or verification decision, which
# is exactly the per-platform package trust semantics this shard forbids.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_release_digest']) {
    throw 'selftest quickjs-release-divergence: the evidence carries no quickjs_release_digest field - the emitters did not record it'
}
$e.quickjs_release_digest = '0' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'quickjs-release-divergence'

# --- (c29) CAP-9C1: cap9c1_inventory_digest diverging on ONE target ----------
# the SECOND equality, and the one that has to carry the weight the archive
# bytes cannot: plugins.zip is deterministic per toolchain but not across
# them (MEASURED for app.pwb in pweb.test.bundle.pas), so the inventory -
# canonical names, uncompressed lengths, content digests - is what proves
# the four targets packaged the same MEANING.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c1_inventory_digest']) {
    throw 'selftest cap9c1-inventory-divergence: the evidence carries no cap9c1_inventory_digest field - the emitters did not record it'
}
$e.cap9c1_inventory_digest = 'a' * 64
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c1-inventory-divergence'

# --- (c30) CAP-9C1: a browser probe that reached the package store ----------
# the CAP-8B lesson made mechanical: an absent public shim is not isolation,
# and this counter is the only place a SECOND reader can see that a
# pweb://app request actually arrived at the plugin bytes.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c1_browser_store_arrivals']) {
    throw 'selftest cap9c1-browser-arrival: the evidence carries no cap9c1_browser_store_arrivals field - the emitters did not record it'
}
$e.cap9c1_browser_store_arrivals = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c1-browser-arrival' 'CAP9C1_BROWSER_STORE_ARRIVALS'

# --- (c31) CAP-9C1: a plugin published despite a registry mismatch ----------
# the whole trust chain in one counter: if a generation can publish while
# its compiled graph digest disagrees with the archive it loaded, package
# integrity has become decorative.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c1_tamper_started']) {
    throw 'selftest cap9c1-tamper-started: the evidence carries no cap9c1_tamper_started field - the emitters did not record it'
}
$e.cap9c1_tamper_started = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c1-tamper-started' 'CAP9C1_TAMPER_STARTED'

# --- (c32) CAP-9C1: verification that depended on the working directory -----
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c1_cwd_dependency']) {
    throw 'selftest cap9c1-cwd: the evidence carries no cap9c1_cwd_dependency field - the emitters did not record it'
}
$e.cap9c1_cwd_dependency = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c1-cwd' 'CAP9C1_CWD_DEPENDENCY'

# --- (c33) CAP-9C1: a malformed per-target package digest -------------------
# cap9c1_package_sha256 is deliberately NOT in the equality set, so nothing
# else would notice it going empty or non-hex. This leg is what keeps the
# fields the aggregate only REPORTS from becoming fields nobody checks.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c1_package_sha256']) {
    throw 'selftest cap9c1-bad-sha: the evidence carries no cap9c1_package_sha256 field - the emitters did not record it'
}
$e.cap9c1_package_sha256 = 'not-a-digest'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c1-bad-sha' 'CAP-9C1 BAD-PACKAGE-SHA'

# --- (c34) CAP-9C1: a verified package that weighs nothing ------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c1_package_bytes']) {
    throw 'selftest cap9c1-empty-package: the evidence carries no cap9c1_package_bytes field - the emitters did not record it'
}
$e.cap9c1_package_bytes = 0
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c1-empty-package' 'CAP-9C1 EMPTY-PACKAGE'

# --- (c35) CAP-9C2: the GUI corpus absent -----------------------------------
# The first thing a shard's evidence loses when a step is quietly dropped
# from CI is the field itself, so the aggregator must refuse an ABSENT
# corpus as loudly as a failing one.
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['quickjs_gui_corpus']) {
    throw 'selftest cap9c2-absent: the evidence carries no quickjs_gui_corpus field - the emitters did not record it'
}
$e.PSObject.Properties.Remove('quickjs_gui_corpus')
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-absent' 'quickjs_gui_corpus'

# --- (c36) CAP-9C2: the GUI corpus reading SKIP -----------------------------
# a real WebView opens on every one of the four runners, so a SKIP here is
# a gate that stopped running, never a machine that could not run it
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.quickjs_gui_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-skip' 'SKIP/WAIVED NEVER PROMOTES'

# --- (c37) CAP-9C2: the GUI digest diverging on one target ------------------
# the corpus is entirely semantic, so a divergence is a real architectural
# difference between two targets - never a toolchain artefact
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.quickjs_gui_digest = ('0' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-digest' 'FIELD DISAGREES: quickjs_gui_digest'

# --- (c38) CAP-9C2: a browser probe that reached the plugin package store ---
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cap9c2_gates']) {
    throw 'selftest cap9c2-browser-arrival: the evidence carries no cap9c2_gates object - the emitters did not record it'
}
$e.cap9c2_gates.browser_plugin_store_arrivals = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-browser-arrival' 'CAP-9C2 GATE NOT GREEN'

# --- (c39) CAP-9C2: plugin source that executed as browser JavaScript -------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.browser_plugin_script_marker = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-script-marker' 'browser_plugin_script_marker'

# --- (c40) CAP-9C2: plugin source bytes in a browser or native result -------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.raw_channel_source_bytes = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-source-bytes' 'raw_channel_source_bytes'

# --- (c41) CAP-9C2: denied plugin activity that reached the SOA layer -------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.reporting_soa_count = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-denied-soa' 'reporting_soa_count'

# --- (c42) CAP-9C2: the UI and the plugins on DIFFERENT runtime objects -----
# CAP-9's contract is one architecture, not merely equivalent output, so a
# second scheduler/policy/bridge/server is a failure even if every value
# still came back 42
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.same_scheduler = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-same-scheduler' 'same_scheduler'

Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.same_bridge = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-same-bridge' 'same_bridge'

# --- (c43) CAP-9C2: a resource-limit failure that took the UI with it -------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.ui_survived_timeout = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-ui-timeout' 'ui_survived_timeout'

Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.neighbour_survived_timeout = 'no'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-neighbour-timeout' 'neighbour_survived_timeout'

# --- (c44) CAP-9C2: a gate that vanished from the record --------------------
# an ABSENT gate must refuse exactly like a red one: the failure mode this
# closes is a field quietly renamed in the runner and read as green here
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_gates.PSObject.Properties.Remove('same_server')
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-missing-gate' 'CAP-9C2 MISSING-GATE'

# --- (c45) CAP-9C2: a listening socket in the plugin-enabled application ----
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_listeners = 1
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-listeners' 'CAP-9C2 LISTENERS>0'

# --- (c46) CAP-9C2: a waived reparse-point negative -------------------------
# the runner records a waiver honestly; this is the leg that proves the
# aggregator never promotes one
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_negative_reparse = 'waived'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-reparse-waived' 'CAP-9C2 REPARSE NOT PROVEN'

# --- (c47) CAP-9C2: a licence that is not the frozen one --------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap9c2_license_sha256 = ('a' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap9c2-license' 'CAP-9C2 LICENSE SHA'

# --- (c48) CAP-10A: the CLI corpus absent -----------------------------------
# the first thing a shard's evidence loses when a step is quietly dropped
# from CI is the field itself
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['cli_corpus']) {
    throw 'selftest cap10a-absent: the evidence carries no cli_corpus field - the emitters did not record it'
}
$e.PSObject.Properties.Remove('cli_corpus')
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10a-absent' 'cli_corpus'

# --- (c49) CAP-10A: the CLI corpus reading SKIP -----------------------------
# the CLI suite is headless on every target: a SKIP is a gate that stopped
# running, never a machine that could not run it
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cli_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10a-skip' 'SKIP/WAIVED NEVER PROMOTES'

# --- (c50) CAP-10A: the decision corpus diverging on one target -------------
# every line of that corpus is the verdict of platform-independent logic, so
# a divergence is a real behavioural difference between two builds of the
# same parser - never a toolchain artefact
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cli_digest = ('0' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10a-cli-digest' 'FIELD DISAGREES: cli_digest'

# --- (c51) CAP-10A: the doctor JSON SHAPE diverging on one target -----------
# the shape and the row set are platform-independent by construction; the
# OBSERVATIONS are not compared at all, which is exactly why this one must be
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.doctor_schema_digest = ('1' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10a-schema-digest' 'FIELD DISAGREES: doctor_schema_digest'

# --- (c52) CAP-10A: an EMPTY digest with a PASS corpus ----------------------
# the failure this closes is subtle and is why the branch exists: an empty
# digest compares EQUAL to another empty digest on four targets, so a gate
# that stopped emitting would look exactly like one that passed everywhere
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.cli_digest = ''
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10a-empty-digest' 'CAP-10A BAD-DIGEST'

# --- (c53) CAP-10A: doctor mutated the project -----------------------------
# "diagnostic only" is the whole promise of the command; the runner measures
# it by hashing the tree before and after, and this is the leg that proves a
# recorded FAIL is refused rather than read past
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.doctor_no_mutation = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10a-mutation' 'doctor_no_mutation'

# --- (c54) CAP-10A: the exit taxonomy drifted ------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cli_exit_taxonomy = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10a-exit-taxonomy' 'cli_exit_taxonomy'

# --- (c55) CAP-10A: a version line that is not the contract shape ----------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.cli_version_line = 'pweb (dev build)'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10a-version-line' 'CAP-10A BAD-VERSION-LINE'

# --- (c56) CAP-10A: a doctor that produced no row --------------------------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.doctor_checks = 0
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10a-no-rows' 'CAP-10A NO-ROWS'

# --- (c57) CAP-10B0: the scaffold corpus absent -----------------------------
# same first failure as c48, for the same reason: the field itself is what a
# quietly dropped CI step loses first
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
if ($null -eq $e.PSObject.Properties['template_corpus']) {
    throw 'selftest cap10b0-absent: the evidence carries no template_corpus field - the emitters did not record it'
}
$e.PSObject.Properties.Remove('template_corpus')
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-absent' 'template_corpus'

# --- (c58) CAP-10B0: the scaffold corpus reading SKIP -----------------------
# the scaffold suite is headless on every target: a SKIP is a gate that
# stopped running, never a machine that could not run it
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.template_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-skip' 'SKIP/WAIVED NEVER PROMOTES'

# --- (c59) CAP-10B0: the decision corpus diverging on one target ------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.template_digest = ('2' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-digest' 'FIELD DISAGREES: template_digest'

# --- (c60) CAP-10B0: an EMPTY semantic digest on EVERY target ---------------
# the c52 hole aimed at the field that now carries the whole cross-target
# weight. template_pack_digest is deliberately NOT compared across targets
# (mORMot stamps the creating OS into `version made by`, MEASURED on run
# 33093385300 as one hash for windows+linux and another for the two macOS
# targets, same length and same inventory), so the semantic digest is what
# must never be allowed to go quietly empty
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.template_semantic_digest = ''
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b0-empty-semantic' 'CAP-10B0 BAD-DIGEST'

# --- (c61) CAP-10B0: the SEMANTIC inventory diverging on one target ---------
# the archive's meaning, as opposed to its weight. If the bytes ever have to
# stop being compared, THIS is the field that still has to agree
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.template_semantic_digest = ('4' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-semantic-digest' 'FIELD DISAGREES: template_semantic_digest'

# --- (c62) CAP-10B0: an EMPTY per-target pack digest -----------------------
# the pack hash is not COMPARED across targets, but it is still the exact
# archive each target's registry pins - so an empty one is a gate that
# stopped emitting, and is refused by shape rather than by equality
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.template_pack_digest = ''
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b0-empty-digest' 'CAP-10B0 BAD-DIGEST'

# --- (c63) CAP-10B0: the pack stopped being deterministic ------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.template_deterministic = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-nondeterministic' 'template_deterministic'

# --- (c64) CAP-10B0: the builder stopped refusing broken sources -----------
# seven deliberately broken template sources are staged on every leg; a
# refusal nobody has watched fire is a comment
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.template_source_gate = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-source-gate' 'template_source_gate'

# --- (c65) CAP-10B0: a refusal count that drifted --------------------------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.template_refusals = '6'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b0-refusals' 'CAP-10B0 REFUSALS'

# --- (c66) CAP-10B0: the engine stopped being offline ----------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.template_offline = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-offline' 'template_offline'

# --- (c67) CAP-10B0: a package-manager call in a creation path -------------
# the count is DERIVED from the source and unit-set sweeps, so a nonzero
# value means one of those sweeps found something
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.package_manager_calls = '1'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b0-package-manager' 'CAP-10B0 NOT-OFFLINE'

# --- (c68) CAP-10B0: `pweb create` became reachable ------------------------
# CAP-10B0 ships an ENGINE and no command. This is the leg that keeps the
# next shard from exposing one by accident
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.create_absent = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-create-present' 'create_absent'

# --- (c69) CAP-10B0: the template-pack schema drifted ----------------------
# an ABSOLUTE pin, not merely an agreement: four targets that all moved to
# schema 2 would agree perfectly and be wrong together
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.template_pack_schema = '2'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b0-pack-schema' 'CAP-10B0 BAD-SCHEMA'

# --- (d) divergence sweep must refuse an off-allowlist conditional -----------
$fixturePas = 'src/zz_cap7f_selftest_fixture.pas'
Remove-Item -Force -ErrorAction SilentlyContinue $fixturePas
try {
    Set-Content $fixturePas ('unit zz_cap7f_selftest_fixture; ' +
        '{$ifdef LINUX} interface {$endif LINUX} implementation end.')
    & pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'divergence-negative.log')
    if ($LASTEXITCODE -eq 0) {
        throw 'selftest divergence-negative: the sweep exited 0 with an off-allowlist conditional present'
    }
    $script:SweepRefusals++
    Write-Host '[CAP-7F] selftest divergence-negative: sweep refused as required'
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $fixturePas
}

# --- (e) CAP-8A: a count-preserving directive SWAP inside an allowlisted -----
# file must trip the FINGERPRINT branch, by name. The mutation swaps one
# platform directive for a DIFFERENT platform directive (same count, new
# text) in a working-tree copy that is byte-restored in finally - the
# same in-place discipline as leg (d), and the red path of the CAP-8A
# fingerprint upgrade is machine-proven on every hosted run.
$allowFile = 'tools/bundler/pwebbundle.pas'
$allowOrig = [System.IO.File]::ReadAllBytes((Resolve-Path $allowFile))
try {
    $text = [System.IO.File]::ReadAllText((Resolve-Path $allowFile))
    $m = [regex]::Match($text, '\{\$ifdef OSWINDOWS\}')
    if (-not $m.Success) {
        throw "selftest fingerprint-swap: no {`$ifdef OSWINDOWS} found in $allowFile to swap"
    }
    $mutated = $text.Remove($m.Index, $m.Length).Insert($m.Index, '{$ifdef ANDROID}')
    [System.IO.File]::WriteAllText((Resolve-Path $allowFile), $mutated)
    & pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'fingerprint-swap.log')
    if ($LASTEXITCODE -eq 0) {
        throw 'selftest fingerprint-swap: the sweep exited 0 with a count-preserving substitution present'
    }
    if (-not (Select-String -Path (Join-Path $fx 'fingerprint-swap.log') `
            -Pattern 'ALLOWLIST FINGERPRINT CHANGED' -Quiet)) {
        Get-Content (Join-Path $fx 'fingerprint-swap.log') | Write-Host
        throw 'selftest fingerprint-swap: the sweep refused, but not through the ALLOWLIST FINGERPRINT CHANGED branch'
    }
    $script:SweepRefusals++
    Write-Host '[CAP-7F] selftest fingerprint-swap: sweep refused as required (fingerprint branch)'
} finally {
    [System.IO.File]::WriteAllBytes((Resolve-Path $allowFile), $allowOrig)
}

# and it must pass again now that leg (d)'s fixture is gone and leg (e)'s
# swap is byte-restored - a selftest that leaves the sweep red has
# sabotaged the job it runs in
& pwsh -NoProfile -File test/cap7f/check_divergence.ps1 *> (Join-Path $fx 'divergence-restored.log')
if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $fx 'divergence-restored.log') | Write-Host
    throw 'selftest: the divergence sweep does not pass after fixture removal + swap restore'
}

Remove-Item -Force -ErrorAction SilentlyContinue $matrix
# a floor, so a leg that silently stops running is caught. It is deliberately
# NOT an equality: adding a refusal branch is normal and should not require
# editing this line, while LOSING one is the failure worth naming
if ($script:AggRefusals -lt 73) {
    throw ("selftest: only $($script:AggRefusals) aggregator refusals fired, " +
        'expected at least 73 -- a negative leg stopped running')
}
if ($script:SweepRefusals -lt 2) {
    throw ("selftest: only $($script:SweepRefusals) divergence refusals fired, " +
        'expected at least 2')
}
Write-Host ("[CAP-7F] selftest PASS - $($script:AggRefusals) aggregator " +
    "refusals + $($script:SweepRefusals) divergence refusals, all on copies " +
    'or byte-restored')
