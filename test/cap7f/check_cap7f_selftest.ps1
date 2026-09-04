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
#   (c68) create_present=FAIL -> mustPass refusal (the scaffold engine
#         stopped being linked into the CLI that offers `pweb create`)
#   (c69) template_pack_schema=2 -> BAD-SCHEMA refusal (an absolute pin, not
#         merely an agreement)
#   (c70) create_corpus=FAIL -> mustPass refusal
#   (c71) advertised_ui=pas2js on EVERY target -> ABSOLUTE PIN refusal (a
#         template nobody shipped, advertised in unison)
#   (c72) generated_inventory_digest diverging -> equality refusal (the
#         whole claim of CAP-10B1 in one field)
#   (c73) generated_pweb_json_digest diverging -> equality refusal
#   (c74) doctor_result=FAIL -> mustPass refusal (the CAP-10B0
#         `frontend.lockfile` limitation this template exists to close)
#   (c75) frontend_build=FAIL -> mustPass refusal
#   (c76) native_build=FAIL -> mustPass refusal
#   (c77) secure_origin=FAIL -> mustPass refusal
#   (c78) rpc_result=41 on EVERY target -> ABSOLUTE PIN refusal
#   (c79) listener_count=1 on EVERY target -> ABSOLUTE PIN refusal
#   (c80) raw_primitive_used=true on EVERY target -> ABSOLUTE PIN refusal
#   (c81) loose_assets_used=true on EVERY target -> ABSOLUTE PIN refusal
#   (c82) generated_tree_unchanged=FAIL -> mustPass refusal (a build that
#         rewrites its own input has no reproducible output)
#   (c83) create_no_partial=FAIL -> mustPass refusal (a refusal left a
#         partial destination behind)
#   (c84) runtime_from_sdk_root=FAIL -> mustPass refusal (@pweb/runtime
#         came from somewhere the SDK root did not supply)
#   (c85) pas2js_create_corpus rewritten to SKIP -> mustPass refusal
#   (c86) pas2js_generated_inventory_digest diverging -> equality refusal
#         (the whole claim of CAP-10B2 in one field)
#   (c87) pas2js_static_inventory_digest diverging -> equality refusal. This
#         is the field the BOM/CRLF normalisation exists to make satisfiable
#         at all: Pas2JS writes through the host's text layer (MEASURED:
#         UTF-8 BOM + CRLF on Windows, LF on POSIX), so a regression in that
#         step lands here rather than anywhere legible
#   (c88) shared_native_source_digest diverging -> equality refusal (the two
#         UIs stopped being one generated native application)
#   (c89) react_generated_inventory_digest diverging -> equality refusal.
#         THE regression this shard could plausibly hide: it changes the
#         pack, the registry and the CLI the React project is created by
#   (c90) react_regression_result=FAIL -> mustPass refusal
#   (c91) native_parity=FAIL -> mustPass refusal
#   (c92) pas2js_doctor_result=FAIL -> mustPass refusal
#   (c93) pas2js_proof_corpus=FAIL -> mustPass refusal
#   (c94) pas2js_rpc_result=41 on EVERY target -> ABSOLUTE PIN refusal
#   (c95) pas2js_listener_count=1 on EVERY target -> ABSOLUTE PIN refusal
#   (c96) pas2js_app_raw_binding=true on EVERY target -> ABSOLUTE PIN refusal
#   (c97) pas2js_sdk_binding_owner=false on EVERY target -> the OTHER
#         direction of the same rule: not "the application emitted one" but
#         "the one occurrence left the frozen SDK's module"
#   (c98) pas2js_compiler_version=3.0.2 on EVERY target -> ABSOLUTE PIN
#   (c99) pas2js_compiler_arch=x86_64 on macos-arm64 -> TRANSLATED-COMPILER
#         refusal (upstream ships no aarch64 Pas2JS, so an x86_64 one there
#         means Rosetta, which the no-translation invariant refuses)
#   (c100) pas2js_report_fields short one member -> BAD-REPORT-SHAPE refusal
#   (c101) an EMPTY pas2js_generated_inventory_digest on EVERY target ->
#         BAD-DIGEST refusal (the c52/c60 hole, aimed at this shard's own
#         load-bearing field)
#   (c102) pas2js_build_out_of_tree=FAIL -> mustPass refusal
#   (c103) react_pas2js_parity=FAIL -> mustPass refusal
#   (c104) pas2js_create_refusals drifted from 13 -> REFUSALS refusal
#   (c105) pas2js_sdk_from_sdk_root=FAIL -> mustPass refusal (the frontend
#         compiled against this repository's checkout rather than against
#         the staged SDK root)
#   (c106) pas2js_native_from_sdk_root=FAIL -> mustPass refusal (the same
#         model's other half, for the FPC compile)
#   (c107) pas2js_app_pwb_entries=4 -> BAD-BUNDLE-INVENTORY refusal. Five is
#         index.html, the three assets and the manifest.json the BUNDLER
#         owns; four would mean the semantic digest was computed over the
#         dist directory instead of over the archive
#   (c8-c107 additionally assert the refusal came through the EXPECTED branch
#    where one is named)
#   (C3-1 .. C3-19) CAP-10C3, one leg per refusal the Pas2JS development
#    aggregation names: the verdict itself, SKIP promotion, a decision-corpus
#    divergence, pas2js dev unavailable, a different detection model, a
#    platform file-watch API, the RPC value after a switch, a partial or
#    inconsistent generation, the consistency rule not firing, a network
#    call, a listener, a loose asset, dev code in the pas2js release, `build`
#    exposed, a LEDGER ORPHAN, the archive parity with the CAP-10C1
#    pipeline, a React regression, the typed input-set cause, and the
#    advertised frontend set
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
    
# --- CAP-10D0: the public build, one negative leg per new refusal --------
# Each of these is a way the matrix could go green over a public build that
# does not work, and each one must go RED. A refusal nobody has watched fire
# is a comment.

Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cli_build_available = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-build-unavailable' 'cli_build_available'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_react_rpc_value = '41'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-rpc-not-42-react' 'build_react_rpc_value'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_pas2js_rpc_value = '0'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-rpc-not-42-pas2js' 'build_pas2js_rpc_value'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_never_partial_release = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-partial-release' 'build_never_partial_release'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_failure_leaves_old_release = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-old-release-altered' 'build_failure_leaves_old_release'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.d0_build_deterministic = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-nondeterministic' 'd0_build_deterministic'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_network_stages_pas2js = 'install'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-network-outside-install' 'build_network_stages_pas2js'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_descendants_after_interrupt = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-descendants-survived' 'build_descendants_after_interrupt'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_interrupt_clean = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-interrupt-dirty' 'build_interrupt_clean'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.release_path_observations_disposed = '5'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-observations-undisposed' 'release_path_observations_disposed'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.d0_project_tree_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-tree-mutated' 'd0_project_tree_unchanged'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.gate_quoting_space_path = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-quoting-regressed' 'gate_quoting_space_path'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.gate_project_path_has_space = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-spaced-path-dropped' 'gate_project_path_has_space'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.advertised_commands_d0 = 'create,doctor,run,dev'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-surface-shrank' 'advertised_commands_d0'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_driver_spawns = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-second-execution-path' 'build_driver_spawns'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_stage_count = '11'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-stage-added' 'build_stage_count'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_unratified_options = '--profile'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-option-ratified-late' 'build_unratified_options'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_replacement_rule = 'copy_over_the_top'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-replacement-rule-moved' 'build_replacement_rule'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.d0_template_supersession_recorded = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-template-unrecorded' 'd0_template_supersession_recorded'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-corpus-skipped' 'build_corpus'
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
$e.create_present = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b0-create-present' 'create_present'

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

# --- (c70) CAP-10B1: the create verdict itself ----------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.create_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-create-corpus' 'create_corpus'

# --- (c71) CAP-10B2: a third frontend falsely advertised -------------------
# an ABSOLUTE pin, not merely an agreement: four targets that all grew a
# `svelte` claim would agree perfectly and be wrong together, and a CLI that
# advertises a template nobody shipped is precisely what CAP-10A refused to
# do with `create` itself.
#
# CAP-10B2 REDIRECTED this leg rather than deleting it. It used to prove
# that a falsely advertised `pas2js` was refused; that template shipped, so
# the same rule is now aimed at the next kind nobody has shipped.
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.supported_uis = 'pas2js,react,svelte'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-extra-ui-advertised' 'ABSOLUTE PIN VIOLATED'

# --- (c72) CAP-10B1: the generated project diverged between targets -------
# the whole claim of this shard in one field: `pweb create` is a function of
# its inputs, and four targets must produce the same bytes
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.generated_inventory_digest = 'deadbeef' + $e.generated_inventory_digest.Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-generated-divergence' 'generated_inventory_digest'

# --- (c73) CAP-10B1: the descriptor diverged ------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.generated_pweb_json_digest = 'deadbeef' + $e.generated_pweb_json_digest.Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-descriptor-divergence' 'generated_pweb_json_digest'

# --- (c74) CAP-10B1: doctor rejected the scaffold -------------------------
# the CAP-10B0 `frontend.lockfile` limitation this template exists to close
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.doctor_result = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-doctor' 'doctor_result'

# --- (c75) CAP-10B1: the frontend stopped building ------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.frontend_build = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-frontend-build' 'frontend_build'

# --- (c76) CAP-10B1: the generated native app stopped compiling -----------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.native_build = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-native-build' 'native_build'

# --- (c77) CAP-10B1: the origin stopped being secure ----------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.secure_origin = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-secure-origin' 'secure_origin'

# --- (c78) CAP-10B1: the scaffold's own arithmetic ------------------------
# an ABSOLUTE pin. Four targets agreeing on 41 is four targets being wrong
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.rpc_result = '41'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b1-rpc-result' 'ABSOLUTE PIN VIOLATED'

# --- (c79) CAP-10B1: a generated application opened a listener -----------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.listener_count = '1'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b1-listener' 'ABSOLUTE PIN VIOLATED'

# --- (c80) CAP-10B1: the generated frontend reached the raw primitive ----
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.raw_primitive_used = 'true'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b1-raw-primitive' 'ABSOLUTE PIN VIOLATED'

# --- (c81) CAP-10B1: the release grew a loose asset ----------------------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.loose_assets_used = 'true'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b1-loose-assets' 'ABSOLUTE PIN VIOLATED'

# --- (c82) CAP-10B1: the build mutated the project it was given ----------
# the SDK-root dependency model exists so that it does not have to, and a
# build that rewrites its own input has no reproducible output
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.generated_tree_unchanged = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-tree-mutated' 'generated_tree_unchanged'

# --- (c83) CAP-10B1: a refusal left a partial destination ---------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.create_no_partial = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-partial-destination' 'create_no_partial'

# --- (c84) CAP-10B1: @pweb/runtime came from somewhere else -------------
# the SDK-root dependency model in one field: the package the generated
# frontend imported must be the one the trusted SDK root supplied, resolved
# THROUGH the link npm made rather than read out of the manifest that asked
# for it
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.runtime_from_sdk_root = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b1-runtime-provenance' 'runtime_from_sdk_root'

# ========================== CAP-10B2 (c85-c107) ==========================
#
# Every refusal branch this shard adds, proven red on fixtures before the
# real aggregation is trusted. The pattern is CAP-10B1's: a verdict rewritten
# to FAIL must reach the mustPass branch by name, a digest perturbed on ONE
# target must reach the equality branch by name, and a value drifted on EVERY
# target must reach the absolute-pin branch - because four targets that
# agree can still be wrong together.

# --- (c85) the Pas2JS create verdict itself -------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_create_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-create-corpus' 'pas2js_create_corpus'

# --- (c86) the generated Pas2JS project diverged between targets ----------
# the whole claim of this shard in one field: `pweb create --ui pas2js` is a
# function of its inputs, and four targets must produce the same bytes
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_generated_inventory_digest =
    'deadbeef' + "$($e.pas2js_generated_inventory_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-generated-divergence' 'pas2js_generated_inventory_digest'

# --- (c87) the compiled static output diverged ----------------------------
# this is the field the BOM/CRLF normalisation exists to make satisfiable,
# so a regression in that step lands here rather than anywhere legible
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_static_inventory_digest =
    'deadbeef' + "$($e.pas2js_static_inventory_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-static-divergence' 'pas2js_static_inventory_digest'

# --- (c88) the two UIs stopped sharing one native application -------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.shared_native_source_digest =
    'deadbeef' + "$($e.shared_native_source_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-native-divergence' 'shared_native_source_digest'

# --- (c89) REACT DRIFTED while the Pas2JS fields stayed green -------------
# the one regression this shard could plausibly hide, given that it changes
# the pack, the registry and the CLI the React project is created by
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.react_generated_inventory_digest =
    'deadbeef' + "$($e.react_generated_inventory_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-react-drift' 'react_generated_inventory_digest'

# --- (c90) ...and the verdict that names it -------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.react_regression_result = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-react-regression' 'react_regression_result'

# --- (c91) the generated projects stopped agreeing about the native half --
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.native_parity = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-native-parity' 'native_parity'

# --- (c92) the doctor rejected the Pas2JS scaffold ------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_doctor_result = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-doctor' 'pas2js_doctor_result'

# --- (c93) the build proof itself -----------------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_proof_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-proof-corpus' 'pas2js_proof_corpus'

# --- (c94) the arithmetic, on EVERY target --------------------------------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.pas2js_rpc_result = '41'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-rpc-41' 'ABSOLUTE PIN VIOLATED'

# --- (c95) a listening socket, on EVERY target ----------------------------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.pas2js_listener_count = '1'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-listener' 'ABSOLUTE PIN VIOLATED'

# --- (c96) the application emitted its own raw binding --------------------
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.pas2js_app_raw_binding = 'true'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-app-raw-binding' 'ABSOLUTE PIN VIOLATED'

# --- (c97) the binding stopped being SDK-owned ----------------------------
# the OTHER direction of the same rule: not "the application emitted one"
# but "the one occurrence is no longer inside the frozen SDK's module"
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.pas2js_sdk_binding_owner = 'false'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-binding-owner' 'ABSOLUTE PIN VIOLATED'

# --- (c98) a different Pas2JS, in unison ----------------------------------
# the pin is EXACT because the SDK is compiled by it: a different compiler
# is a different product, not a newer one
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.pas2js_compiler_version = '3.0.2'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-compiler-version' 'ABSOLUTE PIN VIOLATED'

# --- (c99) macOS arm64 ran a TRANSLATED compiler --------------------------
# upstream publishes no aarch64 Pas2JS, so an x86_64 one on the arm64 leg
# means Rosetta - which the ratified no-translation invariant refuses
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_compiler_arch = 'x86_64'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-rosetta' 'TRANSLATED-COMPILER'

# --- (c100) the page reported a different shape ---------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_report_fields = 'css,handshake,html,js,rpc,secure,value'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-report-shape' 'BAD-REPORT-SHAPE'

# --- (c101) an EMPTY Pas2JS digest on EVERY target ------------------------
# the c52/c60 hole, aimed at this shard's own load-bearing field: four empty
# strings agree perfectly, so a gate that stopped emitting would look
# exactly like one that passed everywhere
Reset-Fixture
foreach ($t in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$t/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.pas2js_generated_inventory_digest = ''
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10b2-empty-digest' 'BAD-DIGEST'

# --- (c102) the build wrote into the project it was given ------------------
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_build_out_of_tree = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-build-in-tree' 'pas2js_build_out_of_tree'

# --- (c103) React and Pas2JS stopped agreeing at runtime -------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.react_pas2js_parity = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-parity' 'react_pas2js_parity'

# --- (c104) the refusal set shrank ----------------------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_create_refusals = '12'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-refusal-count' 'REFUSALS'

# --- (c105) the frontend compiled against the checkout, not the SDK root ---
# the SDK-root dependency model for the Pas2JS half, in one field: the ONE
# PWeb unit path the compiler is handed must be the staged SDK, and this
# repository's own sdk/pas2js must not appear among the arguments at all
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_sdk_from_sdk_root = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-sdk-provenance' 'pas2js_sdk_from_sdk_root'

# --- (c106) the NATIVE compile used the checkout, not the SDK root --------
# the other half of the same model, and the half that had gone unmeasured on
# both shards until a review pointed out that the CAP-10B1 POSIX proof could
# quietly go back to naming the repository's src/ with everything still green
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_native_from_sdk_root = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-native-provenance' 'pas2js_native_from_sdk_root'

# --- (c107) the app.pwb inventory lost an entry ---------------------------
# five entries: index.html, the three assets, and the manifest.json the
# BUNDLER owns. Four would mean the semantic digest was computed over the
# dist directory rather than over the archive - which is what it used to be
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_app_pwb_entries = '4'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10b2-bundle-inventory' 'BAD-BUNDLE-INVENTORY'

# ========================== CAP-10C0 (c108-c121) =========================
#
# Every refusal the supervision aggregate adds, proven red on fixtures
# before the real aggregation is trusted: a verdict rewritten to SKIP must
# reach the mustPass branch, the decision corpus perturbed on ONE target
# must reach the equality branch, a value drifted on EVERY target must reach
# the absolute-pin branch, and the per-target defense-in-depth branches must
# each refuse by name.

# --- (c108) the supervision verdict rewritten to SKIP ---------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.supervision_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c0-supervision-corpus' 'supervision_corpus'

# --- (c109) the run verdict rewritten to FAIL -----------------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.run_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c0-run-corpus' 'run_corpus'

# --- (c110) the decision corpus diverged on one target -------------------
# the whole engine claim in one field: pure logic over the fixture child
# and injected records must decide identically on four targets
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.supervision_digest = 'deadbeef' + "$($e.supervision_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c0-decision-divergence' 'supervision_digest'

# --- (c111) an EMPTY decision digest on EVERY target ----------------------
# the c52/c60/c101 hole, aimed at this shard's load-bearing field
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.supervision_digest = ''
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-empty-digest' 'CAP-10C0 BAD-DIGEST'

# --- (c112) shell execution observed, in unison ---------------------------
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.supervision_shell_used = 'true'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-shell-used' 'supervision_shell_used'

# --- (c113) a descendant survived the drain, on every target --------------
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.descendants_after_exit = '1'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-descendants' 'descendants_after_exit'

# --- (c114) a descendant survived on ONE target, beside a PASS verdict ----
# the defense-in-depth branch: not the pin (three targets still read 0)
# but the per-target NOT-INERT refusal
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.descendants_after_exit = '2'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c0-descendants-one-target' 'NOT-INERT'

# --- (c115) a development allowance present, in unison --------------------
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.run_dev_allowance_present = 'true'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-dev-allowance' 'run_dev_allowance_present'

# --- (c116) a listener under `pweb run`, in unison -------------------------
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.run_listener_count = '1'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-listener' 'run_listener_count'

# --- (c117) the React run answered 41 on every target ---------------------
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.run_react_rpc_value = '41'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-rpc-drift' 'run_react_rpc_value'

# --- (c118) the exit CATEGORY diverged: not-built became a 4 in unison ----
# different human text must never alter the category, and neither may a
# platform: the pin carries the category and the cause together
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.run_not_built = 'exit4/not_built'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-exit-category' 'run_not_built'

# --- (c119) a name-based kill primitive present, in unison ----------------
Reset-Fixture
foreach ($leg in 'windows', 'linux', 'macos-x64', 'macos-arm64') {
    $f = Join-Path $fx "ev/$leg/evidence.json"
    $e = Get-Content $f -Raw | ConvertFrom-Json
    $e.global_name_kill_present = 'true'
    $e | ConvertTo-Json -Depth 4 | Set-Content $f
}
Invoke-AggExpectFail 'cap10c0-name-kill' 'global_name_kill_present'

# --- (c120) a Windows leg that ran the wrong tree body --------------------
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.supervision_tree_model = 'process_group'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c0-tree-model' 'WRONG-TREE-MODEL'

# --- (c121) a POSIX leg that never typed a signal death -------------------
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.signal_outcome_typed = 'not_applicable'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c0-signal-typed' 'SIGNAL-NOT-TYPED'

# --- CAP-10C1: the lifecycle-pipeline refusal branches -----------------------
# Every new aggregator rule is proven RED on a fixture before the real
# aggregation is trusted with it. Each leg names the branch it targets, so a
# leg that passes on an unrelated refusal proves nothing.

# (c44) the pipeline verdict rewritten to FAIL -> mustPass refusal
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pipeline_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-corpus' 'pipeline_corpus'

# (c45) the app.pwb BYTE parity against the CAP-10B1 harness lost -> the one
# claim this whole shard exists to make
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.c1_app_pwb_react_parity = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-parity' 'c1_app_pwb_react_parity'

# (c46) the Pas2JS SEMANTIC inventory diverging on one target -> the equality
# that survives the archive bytes differing per OS family
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.c1_app_pwb_pas2js_semantic_digest = 'deadbeef' +
    "$($e.c1_app_pwb_pas2js_semantic_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-semantic-divergence' 'c1_app_pwb_pas2js_semantic_digest'

# (c47) a MEMBER of the supervised tree opening a listener -> the upgrade the
# CAP-10C0 ledger asked for, refused where the per-pid count said nothing
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.listener_members_max = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-listener-member' 'listener_members_max'

# (c48) the lifecycle-script policy relaxed -> an unreviewed install script
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.lifecycle_script_policy = 'allow'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-script-policy' 'lifecycle_script_policy'

# (c49) a network stage where a Pas2JS build must have none
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.network_stages_pas2js = 'npm_ci'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-offline-pas2js' 'network_stages_pas2js'

# (c50) a failed build leaving a layout behind
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.partial_layout_on_failure = 'true'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-partial-layout' 'partial_layout_on_failure'

# (c51) the pipeline NOT linked into the shipped CLI.
#
# INVERTED BY CAP-10C2, exactly as the pin it guards was. CAP-10C1 froze the
# lifecycle pipeline as PRIVATE and this leg perturbed `pipeline_units_linked`
# to `true` to prove the aggregator refused a pipeline that had leaked into
# the executable. `pweb dev` calls that pipeline, so the pin is now `true`
# and the OLD mutation is no longer a mutation at all - the leg passed
# vacuously and then failed, because the aggregator correctly exited 0 on a
# fixture it had no reason to refuse.
#
# The claim is the same one, read the other way: the measurement must still
# be MADE, and a build whose CLI does not carry the units it now needs is
# refused. A shard that inverts a pin owns its negative leg too.
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pipeline_units_linked = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-private-surface' 'pipeline_units_linked'

# (c52) the project mutated outside its ratified writable set
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.project_tree_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-project-mutation' 'project_tree_unchanged'

# (c53) the assembled layout answering something other than 42
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.run_rpc_value_pas2js = '41'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-rpc-drift' 'run_rpc_value_pas2js'

# (c54) the pipeline's DECISION corpus diverging on one target -> the four
# target command tables, the canonical manifest and the exit mapping are pure
# functions, so a divergence is a rule that moved rather than a host that
# differs
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pipeline_digest = 'deadbeef' + "$($e.pipeline_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c1-decision-divergence' 'pipeline_digest'

# --- CAP-10C2: the development-loop refusal branches -------------------------
# Same rule as every shard before it: a new aggregator refusal is proven RED on
# a fixture before the real aggregation is trusted with it, and each leg names
# the branch it targets so a leg that passes on an unrelated refusal proves
# nothing. The legs are chosen one per CLAIM rather than one per pin: the pins
# share a code path, the claims do not.

# (c55) the development verdict rewritten to FAIL -> mustPass refusal
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-corpus' 'dev_corpus'

# (c56) the headless suite's verdict rewritten to FAIL
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_suite = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-suite' 'dev_suite'

# (c57) THE DEV MODEL DIVERGING on one target -> the loop's decision corpus is
# a pure function, so a difference is a rule that moved
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_digest = 'deadbeef' + "$($e.dev_digest)".Substring(8)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-decision-divergence' 'dev_digest'

# (c58) a target running a DIFFERENT loop model -> the spike's verdict bypassed
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_loop_model = 'vite_proxy'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-loop-model' 'dev_loop_model'

# (c59) the CSP diverging between the development and the release binary
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.csp_identical = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-csp-divergence' 'csp_identical'

# (c60) a TRANSPORT allowance appearing -> the `ws://127.0.0.1` the model-A
# spike refused, added "temporarily" to a profile
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_transport_hits = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-transport' 'dev_transport_hits'

# (c61) DEVELOPMENT CODE IN THE RELEASE BINARY
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.release_dev_unit_absent = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-release-dev-unit' 'release_dev_unit_absent'

# (c62) the development MARKER string found in the release binary
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_marker_in_release = 'true'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-release-dev-marker' 'dev_marker_in_release'

# (c63) a generation switch that RESTARTED the host -> the whole claim
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev2_host_pid_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-host-restarted' 'dev2_host_pid_unchanged'

# (c64) a BROKEN rebuild reaching the host
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev4_broken_published = 'true'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-broken-published' 'dev4_broken_published'

# (c65) the burst's LAST edit not being the one that survived
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev5_final_content_correct = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-burst-content' 'dev5_final_content_correct'

# (c66) the generations no longer strictly one apart -> a gap or a repeat
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev5_burst_monotonic = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-burst-monotonic' 'dev5_burst_monotonic'

# (c67) A PARTIAL GENERATION surviving a stop
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev6_no_partial_generation = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-partial-generation' 'dev6_no_partial_generation'

# (c68) DESCENDANTS SURVIVING the stop
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev6_descendants_remaining = '2'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-descendants' 'dev6_descendants_remaining'

# (c69) THE INTERRUPT NOT MEASURED CLEAN -> the row CAP-10C1 could not write
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_interrupt_clean = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-interrupt' 'dev_interrupt_clean'

# (c70) a member of the LIVE development set opening a listener
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_listener_members_max = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-listener' 'dev_listener_members_max'

# (c71) a LOOSE ASSET in the development layout
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_loose_assets_used = 'true'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-loose-assets' 'dev_loose_assets_used'

# (c72) A MEMBER ENDED FROM OUTSIDE answering something other than 5
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev7_pweb_exit = '0'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-host-death-category' 'dev7_pweb_exit'

# (c73) the WATCHER dying and the loop carrying on regardless
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev8_pweb_exit = '0'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-watcher-death-category' 'dev8_pweb_exit'

# (c74) `build` UNAVAILABLE -> CAP-10D0 inverted this leg with the row
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_available = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-build-unavailable' 'build_available'

# (c75) a target on which `pweb dev` does NOT implement the second frontend
# kind. CAP-10C2 asserted the opposite here - that a pas2js project was
# refused with its typed cause - and CAP-10C3 inverted the row rather than
# deleting it, so the negative leg is inverted with it
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev11_pas2js_supported = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-pas2js-supported' 'dev11_pas2js_supported'

# (c76) the development binary loading the bundle BESIDE it -> the fallback
# DEV9 exists to prove absent
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev9_never_loaded_beside_bundle = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-beside-bundle' 'dev9_never_loaded_beside_bundle'

# (c77) a development session that TOUCHED the release tree
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev10_release_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-release-touched' 'dev10_release_unchanged'

# (c78) the CAP-10C1 pipeline decision corpus moved under this shard -> the
# one row that says CAP-10C2 changed nothing it promised not to
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.c1_pipeline_digest_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c2-c1-digest-moved' 'c1_pipeline_digest_unchanged'

# --- CAP-10C3: one negative leg per refusal the aggregator now names --------
# Every row the CAP-10C3 aggregation refuses on is proved RED here, on a
# fixture, before the real aggregation is trusted with it - the discipline
# CAP-10C2 paid for by shipping pins with no matching legs.

# (C3-1) the Pas2JS development verdict itself
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_corpus = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-corpus-fail' 'dev_pas2js_corpus'

# (C3-2) SKIP is never promoted, for the new verdict either
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_suite = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-suite-skip' 'dev_pas2js_suite'

# (C3-3) one target's DECISION corpus drifting from the other three
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_digest = ('0' * 64)
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-digest-divergence' 'dev_pas2js_digest'

# (C3-4) pas2js development UNAVAILABLE on a target
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_available = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-unavailable' 'dev_pas2js_available'

# (C3-5) a target running a DIFFERENT detection model
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.change_detection_model = 'native_watcher'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-detection-model' 'change_detection_model'

# (C3-6) a platform file-watch API appearing in the tree
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_watch_api_hits = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-watch-api' 'dev_pas2js_watch_api_hits'

# (C3-7) the page's own arithmetic wrong after a generation switch
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_rpc_after_switch = '41'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-rpc-after-switch' 'dev_pas2js_rpc_after_switch'

# (C3-8) a PARTIAL or INCONSISTENT generation reaching the host
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_partial_generation_published = 'true'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-partial-generation' 'dev_pas2js_partial_generation_published'

# (C3-9) the consistency rule silently no longer firing
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_inconsistent_generation_discarded = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-consistency-rule' 'dev_pas2js_inconsistent_generation_discarded'

# (C3-10) a Pas2JS session reaching the NETWORK, which it has no stage for
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_network_calls = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-network' 'dev_pas2js_network_calls'

# (C3-11) a member of the live set holding a LISTENER
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_listener_members_max = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-listener' 'dev_pas2js_listener_members_max'

# (C3-12) a LOOSE asset in development
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_loose_assets_used = 'true'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-loose-assets' 'dev_pas2js_loose_assets_used'

# (C3-13) DEV CODE IN THE PAS2JS RELEASE binary
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_release_dev_free = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-release-dev-code' 'dev_pas2js_release_dev_free'

# (C3-14) `build` UNAVAILABLE, measured again by the closing shard
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_available_c3 = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-build-unavailable' 'build_available_c3'

# (C3-15) A LEDGER ORPHAN - the gate over the disposition table
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cap10c_ledger_orphans = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-ledger-orphan' 'cap10c_ledger_orphans'

# (C3-16) the development archive DIFFERING from the pipeline's - the claim
# this shard exists to make about what a generation is
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.dev_pas2js_app_pwb_parity = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-archive-parity' 'dev_pas2js_app_pwb_parity'

# (C3-17) the REACT loop regressing while the Pas2JS one was added
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.rd1_dev_digest_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-react-regression' 'rd1_dev_digest_unchanged'

# (C3-18) the typed input-set refusal drifting to an untyped one
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pd9_cause = 'other'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-input-link-cause' 'pd9_cause'

# (C3-20) the pinned compiler not on PATH when the loop ran - the reason
# every other PD row would read false, named once instead of fifteen times
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.pas2js_on_path = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-pas2js-path' 'pas2js_on_path'

# (C3-19) the advertised frontend set losing a kind or growing one
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.advertised_ui_dev = 'react'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10c3-advertised-ui' 'advertised_ui_dev'

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


# --- CAP-10D0: the public build, one negative leg per new refusal --------
# Each of these is a way the matrix could go green over a public build that
# does not work, and each one must go RED. A refusal nobody has watched fire
# is a comment.

Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.cli_build_available = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-build-unavailable' 'cli_build_available'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_react_rpc_value = '41'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-rpc-not-42-react' 'build_react_rpc_value'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_pas2js_rpc_value = '0'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-rpc-not-42-pas2js' 'build_pas2js_rpc_value'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_never_partial_release = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-partial-release' 'build_never_partial_release'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_failure_leaves_old_release = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-old-release-altered' 'build_failure_leaves_old_release'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.d0_build_deterministic = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-nondeterministic' 'd0_build_deterministic'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_network_stages_pas2js = 'install'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-network-outside-install' 'build_network_stages_pas2js'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_descendants_after_interrupt = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-descendants-survived' 'build_descendants_after_interrupt'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_interrupt_clean = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-interrupt-dirty' 'build_interrupt_clean'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.release_path_observations_disposed = '5'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-observations-undisposed' 'release_path_observations_disposed'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.d0_project_tree_unchanged = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-tree-mutated' 'd0_project_tree_unchanged'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.gate_quoting_space_path = 'FAIL'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-quoting-regressed' 'gate_quoting_space_path'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.gate_project_path_has_space = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-spaced-path-dropped' 'gate_project_path_has_space'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.advertised_commands_d0 = 'create,doctor,run,dev'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-surface-shrank' 'advertised_commands_d0'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_driver_spawns = '1'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-second-execution-path' 'build_driver_spawns'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_stage_count = '11'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-stage-added' 'build_stage_count'
Reset-Fixture
$f = Join-Path $fx 'ev/linux/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_unratified_options = '--profile'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-option-ratified-late' 'build_unratified_options'
Reset-Fixture
$f = Join-Path $fx 'ev/windows/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_replacement_rule = 'copy_over_the_top'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-replacement-rule-moved' 'build_replacement_rule'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-x64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.d0_template_supersession_recorded = 'false'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-template-unrecorded' 'd0_template_supersession_recorded'
Reset-Fixture
$f = Join-Path $fx 'ev/macos-arm64/evidence.json'
$e = Get-Content $f -Raw | ConvertFrom-Json
$e.build_corpus = 'SKIP'
$e | ConvertTo-Json -Depth 4 | Set-Content $f
Invoke-AggExpectFail 'cap10d0-corpus-skipped' 'build_corpus'
Remove-Item -Force -ErrorAction SilentlyContinue $matrix
# a floor, so a leg that silently stops running is caught. It is deliberately
# NOT an equality: adding a refusal branch is normal and should not require
# editing this line, while LOSING one is the failure worth naming
if ($script:AggRefusals -lt 200) {
    throw ("selftest: only $($script:AggRefusals) aggregator refusals fired, " +
        'expected at least 200 -- a negative leg stopped running')
}
if ($script:SweepRefusals -lt 2) {
    throw ("selftest: only $($script:SweepRefusals) divergence refusals fired, " +
        'expected at least 2')
}
Write-Host ("[CAP-7F] selftest PASS - $($script:AggRefusals) aggregator " +
    "refusals + $($script:SweepRefusals) divergence refusals, all on copies " +
    'or byte-restored')
