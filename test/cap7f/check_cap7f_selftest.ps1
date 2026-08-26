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
#   (c8-c26 additionally assert the refusal came through the EXPECTED branch
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
Write-Host '[CAP-7F] selftest PASS - 28 aggregator refusals + 2 divergence refusals, all on copies or byte-restored'
