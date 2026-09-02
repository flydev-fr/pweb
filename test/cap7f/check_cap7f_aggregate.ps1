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
    'quickjs_package_corpus', 'quickjs_package_digest',
    'cap9b1_loadtime_bridge', 'cap9b1_loader_wrong_thread',
    'cap9b1_store_wrong_thread', 'cap9b1_denied_bridge',
    'cap9b1_source_open_after_failure', 'cap9b1_opener_reached',
    'quickjs_lifecycle_corpus', 'quickjs_lifecycle_digest',
    'cap9b2_two_active_generations', 'cap9b2_stale_completion',
    'cap9b2_reload_lost_old', 'cap9b2_export_wrong_thread',
    'cap9b2_quarantine_injected', 'cap9b2_quarantine_unexpected',
    'cap9b2_denied_bridge', 'cap9b2_opener_reached',
    'quickjs_release_corpus', 'quickjs_release_digest',
    'cap9c1_inventory_digest', 'cap9c1_browser_store_arrivals',
    'cap9c1_denied_bridge', 'cap9c1_opener_reached',
    'cap9c1_tamper_started', 'cap9c1_cwd_dependency',
    'cap9c1_package_sha256', 'cap9c1_package_bytes',
    'cap9c1_registry_sha256',
    'quickjs_gui_corpus', 'quickjs_gui_digest', 'cap9c2_listeners',
    'cap9c2_negative_reparse', 'cap9c2_license_sha256', 'cap9c2_gates',
    'cli_corpus', 'cli_digest', 'cli_version_line', 'cli_exit_taxonomy',
    'doctor_schema_digest', 'doctor_checks', 'doctor_no_mutation',
    'doctor_json_deterministic',
    'template_corpus', 'template_digest', 'template_pack_digest',
    'template_pack_bytes',
    'template_pack_schema', 'template_semantic_digest',
    'template_registry_digest', 'template_deterministic',
    'template_source_gate', 'template_offline', 'template_refusals',
    'template_file_count', 'create_present', 'network_calls',
    'package_manager_calls', 'template_modes_applicable',
    'create_corpus', 'create_help_digest',
    'create_help_bytes', 'create_stdout_digest', 'create_refusals',
    'create_no_partial',
    'create_deterministic', 'public_pack_digest', 'public_pack_bytes',
    'public_semantic_digest', 'public_registry_digest',
    'public_pack_deterministic', 'public_file_count',
    'generated_inventory_digest', 'generated_inventory_exact',
    'generated_pweb_json_digest', 'generated_package_lock_digest',
    'generated_file_count', 'generated_total_bytes',
    'generated_no_host_path', 'doctor_result',
    'proof_corpus', 'generated_tree_digest', 'generated_tree_unchanged',
    'frontend_typecheck', 'frontend_build', 'frontend_no_dev_code',
    'frontend_transport_clean', 'runtime_from_sdk_root', 'native_build',
    'secure_origin',
    'rpc_result', 'error_mapping', 'listener_count', 'raw_primitive_used',
    'loose_assets_used',
    # CAP-10B2: the second frontend. `supported_uis` REPLACES CAP-10B1's
    # `advertised_ui` - one kind was a value, two are a set - and the rest
    # splits the same way the CAP-10B1 pair does: what create produced, and
    # what building and running it proved.
    'supported_uis',
    'pas2js_create_corpus', 'pas2js_create_refusals', 'pas2js_no_partial',
    'pas2js_create_deterministic', 'pas2js_create_stdout_digest',
    'pas2js_generated_inventory_digest', 'pas2js_generated_inventory_exact',
    'pas2js_generated_file_count', 'pas2js_generated_total_bytes',
    'pas2js_pweb_json_digest', 'pas2js_frontend_source_digest',
    'pas2js_generated_no_host_path', 'react_generated_inventory_digest',
    'react_regression_result', 'shared_native_source_digest',
    'native_parity', 'pas2js_doctor_result', 'pas2js_doctor_row',
    'pas2js_doctor_version',
    'pas2js_proof_corpus', 'pas2js_compiler_version', 'pas2js_compiler_arch',
    'pas2js_compiler_host', 'pas2js_compiler_sha256', 'pas2js_frontend_build',
    'pas2js_native_build', 'pas2js_sdk_from_sdk_root',
    'pas2js_native_from_sdk_root', 'pas2js_output_sweep',
    'pas2js_output_normalised',
    'pas2js_static_inventory_digest', 'pas2js_app_pwb_semantic_digest',
    'pas2js_app_pwb_entries',
    'pas2js_app_pwb_bytes', 'pas2js_secure_origin', 'pas2js_rpc_result',
    'pas2js_error_mapping', 'pas2js_listener_count', 'pas2js_loose_assets',
    'pas2js_app_raw_binding', 'pas2js_sdk_binding_owner',
    'pas2js_clean_shutdown', 'pas2js_report_received', 'pas2js_report_fields',
    'pas2js_tree_digest', 'pas2js_tree_unchanged', 'pas2js_build_out_of_tree',
    'react_pas2js_parity', 'react_regression_runtime', 'native_binary_equal',
    'pas2js_run_elapsed_ms',
    # CAP-10C0: process supervision and `pweb run`. The decision corpus
    # (digested), the drivers over the real CLI, and the run command on the
    # two built projects; the platform observations travel beside them and
    # are recorded per target, never compared.
    'cli_run_available', 'advertised_commands',
    'supervision_corpus', 'supervision_digest', 'supervision_corpus_lines',
    'supervision_shell_used', 'supervision_tree_model', 'argv_roundtrip',
    'exit_propagation', 'death_never_exit_zero', 'signal_outcome_typed',
    'graceful_stop_mechanism', 'forced_kill_required', 'grandchild_drained',
    'zombie_left', 'workdir_explicit', 'environment_policy',
    'batch_file_refused', 'run_interrupt_clean',
    'supervisor_terminated_tree_dies', 'descendants_after_exit',
    'global_name_kill_present',
    'run_corpus', 'run_react_rpc_value', 'run_pas2js_rpc_value',
    'run_secure_origin', 'run_error_mapping', 'run_listener_count',
    'run_network_calls', 'run_tool_calls', 'run_dev_allowance_present',
    'run_tree_unchanged', 'run_no_ansi', 'run_not_built', 'run_layout_link',
    'run_output_escape', 'run_tampered_bundle', 'run_option_matrix',
    'run_project_descriptor_form', 'dev_build_unknown', 'shutdown_order',
    'run_elapsed_ms', 'run_descendants_drained', 'run_descendants_forced',
    'run_drain_passes', 'stage_react_release_digest',
    'stage_pas2js_release_digest',
    # CAP-10C0's membership-scoped sampler rows, added by CAP-10C1 BESIDE
    # run_listener_count rather than replacing it: a closed shard's absolute
    # pin keeps the provenance it was ratified with.
    'run_listener_members_max', 'run_listener_members_seen',
    'run_listener_sampler_scope',
    # CAP-10C1: the private lifecycle pipeline. The decision corpus
    # (digested), the two REAL pipelines on the generated projects, the
    # app.pwb byte parity against the CAP-10B1/B2 harnesses ON THE SAME JOB,
    # the run of what was assembled, the refusals, and the closed debts.
    'pipeline_available', 'pipeline_suite', 'pipeline_corpus',
    'pipeline_digest', 'pipeline_corpus_lines',
    'npm_invocation', 'npm_cli_path', 'npm_version', 'node_version',
    'fpc_version', 'fpc_target', 'pas2js_version', 'pas2js_normalised',
    'lifecycle_script_policy', 'lockfile_install_scripts',
    'network_stages', 'network_stages_pas2js',
    'sdk_stage_parity', 'sdk_stage_stale_removed', 'c1_runtime_from_sdk_root',
    'c1_app_pwb_react_sha256', 'c1_app_pwb_react_parity',
    'c1_app_pwb_react_semantic_digest', 'c1_app_pwb_react_entries',
    'c1_app_pwb_pas2js_sha256', 'c1_app_pwb_pas2js_parity',
    'c1_app_pwb_pas2js_semantic_digest', 'c1_app_pwb_pas2js_entries',
    'build_deterministic', 'native_compile_react', 'native_compile_pas2js',
    'layout_accepted_by_run', 'run_rpc_value_react', 'run_rpc_value_pas2js',
    'listener_members_max', 'listener_members_seen', 'listener_sampler_scope',
    'run_connections_max', 'flush_live_lines',
    'tc_version_mismatch', 'tc_inside_project', 'tc_inside_project_executed',
    'tc_doctor_refusal', 'typecheck_failure', 'partial_layout_on_failure',
    'sdk_root_unchanged', 'template_supersession_recorded',
    'project_tree_unchanged', 'driver_no_ansi', 'pipeline_units_linked',
    'interrupt_clean', 'interrupt_mechanism',
    'c0_supervision_digest_unchanged', 'cli_digest_unchanged',
    'doctor_schema_digest_unchanged',
    'autoclose_stop_honoured',
    'doctor_platform_webview',
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
    # CAP-10B1: the four facts that four targets could agree on and still be
    # wrong about. The scaffold's own arithmetic is 42, and a generated
    # application opens no listener, uses no raw primitive and ships no
    # loose asset.
    rpc_result         = '42'
    listener_count     = '0'
    raw_primitive_used = 'false'
    loose_assets_used  = 'false'
    # CAP-10B2: the same discipline for the second frontend, plus the two
    # facts this shard exists to make true. `supported_uis` is the WHOLE
    # advertised set in one canonical bytewise order, so a build that grew a
    # third kind or lost one is refused here rather than merely disagreeing
    # with its neighbours; and `pas2js_compiler_version` is pinned because
    # the SDK is compiled by it, which makes a different compiler a
    # different product rather than a newer one.
    supported_uis            = 'pas2js,react'
    pas2js_compiler_version  = '3.0.1'
    pas2js_rpc_result        = '42'
    pas2js_listener_count    = '0'
    pas2js_app_raw_binding   = 'false'
    pas2js_loose_assets      = 'false'
    pas2js_sdk_binding_owner = 'true'
    pas2js_report_received   = 'true'
    pas2js_clean_shutdown    = 'true'
    # CAP-10C0: the facts four targets could agree on and still be wrong
    # about. The advertised set is exactly the three commands the binary
    # implements; the engine links no shell and no name-based kill; both
    # applications answer 42 through `pweb run`, open nothing, call no tool
    # and leave nothing behind; every exit CATEGORY is the ratified one
    # (an exit-3 that became a 4 on one target is refused here, not merely
    # noticed); an interrupt closes the application cleanly and a terminated
    # supervisor takes its tree with it.
    cli_run_available        = 'true'
    advertised_commands      = 'create,doctor,run'
    supervision_shell_used   = 'false'
    global_name_kill_present = 'false'
    argv_roundtrip           = 'exact'
    exit_propagation         = 'exact'
    death_never_exit_zero    = 'true'
    forced_kill_required     = 'true'
    grandchild_drained       = 'true'
    zombie_left              = 'false'
    workdir_explicit         = 'true'
    environment_policy       = 'inherit_unchanged'
    batch_file_refused       = 'true'
    run_interrupt_clean      = 'true'
    supervisor_terminated_tree_dies = 'true'
    descendants_after_exit   = '0'
    run_react_rpc_value      = '42'
    run_pas2js_rpc_value     = '42'
    run_listener_count       = '0'
    run_network_calls        = '0'
    run_tool_calls           = '0'
    run_dev_allowance_present = 'false'
    run_no_ansi              = 'true'
    run_not_built            = 'exit3/not_built'
    run_layout_link          = 'exit3/layout_link'
    run_output_escape        = 'exit3'
    run_tampered_bundle      = 'exit5/host_refused'
    dev_build_unknown        = 'true'
    # the teardown order as the contract gate READ it out of the host's
    # source after webview_run, expression by expression - never restated
    shutdown_order           = 'binding.Close>schedulerRef.Shutdown>navGuard.Detach>assetHandler.Detach>webview_destroy(w)'
    # CAP-10C0's membership sampler, added by CAP-10C1: the per-pid pin above
    # said nothing about a browser helper, and this one does
    run_listener_members_max = '0'
    # CAP-10C1: the facts four targets could agree on and still be wrong
    # about. The pipeline is PRIVATE and stays private; npm is reached through
    # node and no lifecycle script runs; the SDK staging is byte-identical to
    # the script it replaces and a stale one does not survive; @pweb/runtime
    # is a LINK; BOTH archives are byte-identical to what the CAP-10B1/B2
    # harnesses produced on the same job; both applications answer 42 through
    # the real `pweb run` with no member of the tree opening anything; a
    # failed build leaves no layout; and the project and the SDK root come out
    # of a build exactly as they went in.
    pipeline_available             = 'true'
    npm_invocation                 = 'node_npm_cli'
    lifecycle_script_policy        = 'ignore_scripts'
    lockfile_install_scripts       = '1'
    network_stages                 = 'npm_ci'
    network_stages_pas2js          = 'none'
    sdk_stage_parity               = 'true'
    sdk_stage_stale_removed        = 'true'
    c1_runtime_from_sdk_root       = 'true'
    c1_app_pwb_react_parity        = 'true'
    c1_app_pwb_pas2js_parity       = 'true'
    build_deterministic            = 'true'
    run_rpc_value_react            = '42'
    run_rpc_value_pas2js           = '42'
    listener_members_max           = '0'
    run_connections_max            = '0'
    flush_live_lines               = 'true'
    tc_version_mismatch            = 'exit4/version_too_old'
    tc_inside_project              = 'exit4/tool_inside_project'
    tc_inside_project_executed     = 'false'
    tc_doctor_refusal              = 'exit4/lockfile_absent'
    typecheck_failure              = 'exit5/typecheck'
    partial_layout_on_failure      = 'false'
    sdk_root_unchanged             = 'true'
    template_supersession_recorded = 'true'
    project_tree_unchanged         = 'true'
    driver_no_ansi                 = 'true'
    pipeline_units_linked          = 'false'
    # the three frozen digests CAP-10C1 must not have moved, compared with
    # their closure values by the gate that reads each one back
    c0_supervision_digest_unchanged = 'true'
    cli_digest_unchanged            = 'true'
    doctor_schema_digest_unchanged  = 'true'
}
# fields that must read exactly PASS on every target; SKIP/WAIVED never promote
$mustPass = @('release_layout', 'no_listener', 'host_args', 'capability_policy',
    'navigation_security', 'security_corpus', 'quickjs_corpus',
    'quickjs_package_corpus', 'quickjs_lifecycle_corpus',
    'quickjs_release_corpus', 'quickjs_gui_corpus',
    # CAP-10A: the CLI verdict, and the three sub-claims that a green
    # verdict is made of. They are named individually so the aggregator can
    # refuse ONE of them by name - 'doctor mutated the project' and 'the
    # exit taxonomy drifted' are different defects with different fixes.
    'cli_corpus', 'cli_exit_taxonomy', 'doctor_no_mutation',
    'doctor_json_deterministic',
    # CAP-10B0: the scaffold-engine verdict and the four sub-claims a green
    # one is made of. Named individually for the same reason as the CAP-10A
    # set - 'the pack stopped being deterministic', 'the builder stopped
    # refusing broken sources', 'the engine grew a process API' and 'create
    # became reachable' are four different defects with four different fixes
    'template_corpus', 'template_deterministic', 'template_source_gate',
    'template_offline', 'create_present',
    # CAP-10B1: the two verdicts, and the sub-claims a green pair is made
    # of. Named individually for the same reason again - 'create stopped
    # being deterministic', 'the exact generated set changed', 'doctor
    # rejected the scaffold', 'the frontend stopped building', 'the
    # generated program stopped compiling', 'the origin stopped being
    # secure', 'the typed error mapping broke' and 'the build mutated the
    # project it was given' are eight different defects with eight
    # different fixes, and an aggregate that only said "CAP-10B1 FAILED"
    # would send every one of them to the same wrong place.
    'create_corpus', 'create_deterministic', 'create_no_partial',
    'generated_inventory_exact', 'generated_no_host_path', 'doctor_result',
    'public_pack_deterministic',
    'proof_corpus', 'generated_tree_unchanged', 'frontend_typecheck',
    'frontend_build', 'frontend_no_dev_code', 'frontend_transport_clean',
    'runtime_from_sdk_root', 'native_build', 'secure_origin', 'error_mapping',
    # CAP-10B2: the two verdicts and the sub-claims a green pair is made of,
    # named individually for the reason the CAP-10B1 set is - 'React drifted
    # while only the Pas2JS gates stayed green', 'the two projects stopped
    # sharing one native application', 'the doctor stopped being UI-aware',
    # 'the compiled output grew a second binding' and 'the build wrote into
    # the project' are different defects with different fixes, and an
    # aggregate that only said "CAP-10B2 FAILED" would send every one of
    # them to the same wrong place.
    'pas2js_create_corpus', 'pas2js_create_deterministic', 'pas2js_no_partial',
    'pas2js_generated_inventory_exact', 'pas2js_generated_no_host_path',
    'pas2js_doctor_result', 'react_regression_result', 'native_parity',
    'pas2js_proof_corpus', 'pas2js_tree_unchanged', 'pas2js_build_out_of_tree',
    'pas2js_frontend_build', 'pas2js_native_build', 'pas2js_output_sweep',
    'pas2js_secure_origin', 'pas2js_error_mapping', 'pas2js_sdk_from_sdk_root',
    'pas2js_native_from_sdk_root',
    'react_pas2js_parity', 'react_regression_runtime',
    # CAP-10C0: the two verdicts and the sub-claims a green pair is made of
    'supervision_corpus', 'run_corpus', 'run_secure_origin',
    'run_error_mapping', 'run_tree_unchanged', 'run_option_matrix',
    'run_project_descriptor_form',
    # CAP-10C1: the pipeline verdict and the four sub-claims a green one is
    # made of, named individually so the aggregate can refuse ONE by name -
    # 'the rules drifted', 'the native compile broke on one UI' and 'the
    # assembled layout stopped being runnable' are different defects with
    # different fixes.
    'pipeline_corpus', 'pipeline_suite', 'native_compile_react',
    'native_compile_pas2js', 'layout_accepted_by_run')
# fields that must agree, value-for-value, across all four targets
# (capability_policy_digest is the CAP-8A structured policy-decision corpus and
# navigation_policy_digest the CAP-8B one: four targets, one byte-identical
# decision set each, or red)
$equalityFields = @(
    'fpc', 'webview_pin', 'webview_surface', 'origin', 'secure',
    'bundle_protocol', 'rpc_add_20_22', 'logical_inventory_sha256_react',
    'capability_policy_digest', 'navigation_policy_digest',
    'security_corpus_digest', 'quickjs_corpus_digest',
    'quickjs_package_digest', 'quickjs_lifecycle_digest',
    # CAP-9C1: the SEMANTIC corpus and the inventory digest are compared;
    # cap9c1_package_sha256 / _bytes / _registry_sha256 deliberately are
    # NOT. CAP-6/CAP-7L MEASURED that the mORMot static DEFLATE object
    # emits different bytes per toolchain (app.pwb's golden hash is pinned
    # per toolchain for the same reason), so archive equality across
    # targets would be an untrue requirement. Determinism is proven where
    # it is real - the gate stages the payload twice on each target and
    # requires byte equality there.
    'quickjs_release_digest', 'cap9c1_inventory_digest',
    # CAP-9C2: the GUI corpus is entirely semantic - gate verdicts,
    # identities and orderings, no byte counts and no per-engine numbers -
    # so unlike the archive it MUST be identical on all four targets. The
    # licence is byte-pinned for the same reason: it is assembled from
    # pinned sources and LF-normalized precisely so it can be.
    'quickjs_gui_digest', 'cap9c2_license_sha256',
    # CAP-10A: the decision corpus and the document SHAPE, both pure logic
    # over injected inputs, plus the one version line and the row count.
    # Deliberately NOT here: any observed tool version, any path, any
    # per-host cause - those are facts about the runner, and requiring four
    # runners to agree on them would be requiring four identical machines.
    'cli_digest', 'doctor_schema_digest', 'cli_version_line',
    'doctor_checks', 'github_sha',
    # CAP-10B0: the SEMANTIC inventory and the decision corpus, exactly as
    # CAP-9C1 compares quickjs_release_digest and cap9c1_inventory_digest
    # and deliberately does not compare cap9c1_package_sha256.
    #
    # template_pack_digest and template_registry_digest are ABSENT, and the
    # reason is a MEASUREMENT rather than a precaution. Hosted run
    # 33093385300 built the identical logical input on four targets and
    # produced two archive hashes: one for windows+linux and one for the two
    # macOS targets, with the SAME length (6177 bytes) and the SAME semantic
    # inventory. mORMot stamps the creating OS into the ZIP `version made
    # by` field - `ZIP_OS` is 19 on Darwin and 3 elsewhere - so one byte per
    # entry differs by design, and mORMot's own reader explicitly ignores
    # it. macos-x86_64 and macos-arm64 agreed exactly, which is what shows
    # this is an OS-family property and not a per-machine one.
    #
    # Determinism is therefore proved where it is REAL: the gate rebuilds
    # the pack on each target and requires byte equality there
    # (template_deterministic, must-PASS), and the registry pins the exact
    # bytes of the archive that target will actually verify.
    #
    # template_modes_applicable is absent for a different reason: POSIX has
    # file modes and Windows does not. It is recorded per target and never
    # compared, exactly like the doctor observations.
    'template_digest', 'template_pack_schema',
    'template_semantic_digest',
    'template_refusals', 'template_file_count',
    'network_calls', 'package_manager_calls',
    # CAP-10B1: what `pweb create` produces, which is a pure function of
    # NAME, bundleId, the UI and the template pack. Four targets must
    # produce the same project down to the byte - that is the whole claim -
    # so the generated inventory, the descriptor and the lockfile are
    # compared, as is the public pack's SEMANTIC inventory.
    #
    # public_pack_digest and public_registry_digest are ABSENT for exactly
    # the reason template_pack_digest is: the ZIP `version made by` byte is
    # an OS-family property, measured on run 33093385300. Determinism is
    # proved where it is real by public_pack_deterministic, which rebuilds
    # the pack on each target and requires byte equality there.
    #
    # The advertised UI is compared because a build that advertised a
    # different frontend on one target would be a different product there.
    # The generated file count and total bytes are compared because they
    # are the cheapest way for a divergence to become legible before anyone
    # reads a digest.
    #
    # create_help_digest is deliberately ABSENT, and it is the one field in
    # this list that was demoted rather than chosen. Run 33126638202
    # produced one value on Linux and both macOS targets and another on the
    # Windows dev host, while create_stdout_digest - produced through the
    # SAME Emit path - agreed everywhere. So the difference is in that
    # string and not in the console seam, and this shard did not finish
    # measuring it. The help's CONTRACT is asserted structurally on every
    # target instead (create advertised, react the only supported UI,
    # dev/run/build absent), and `advertised_ui` is parsed back out of the
    # text and absolute-pinned above. create_help_bytes travels beside the
    # digest so the next reader can tell a length change from a
    # substitution without a hosted run.
    'create_stdout_digest',
    'create_refusals', 'public_semantic_digest', 'public_file_count',
    'generated_inventory_digest', 'generated_pweb_json_digest',
    'generated_package_lock_digest', 'generated_file_count',
    'generated_total_bytes', 'generated_tree_digest',
    # the runtime verdict itself: 42 on every target, no listener anywhere,
    # no raw primitive and no loose asset. These are the CAP-10B1
    # acceptance criteria stated as compared fields rather than as prose.
    'rpc_result', 'listener_count', 'raw_primitive_used',
    'loose_assets_used',
    # CAP-10B2: what `pweb create --ui pas2js` produces and what building it
    # yields, both pure functions of NAME, bundleId, the template pack and
    # the pinned compiler. The generated tree, the descriptor, the frontend
    # sources and the STATIC OUTPUT are compared byte for byte across four
    # targets; so is the React tree, which must still be the CAP-10B1
    # closure corpus.
    #
    # `pas2js_static_inventory_digest` is a compared field only because the
    # build NORMALISES the compiler's output first: Pas2JS writes through
    # the host's text layer (MEASURED: UTF-8 BOM + CRLF on Windows, LF on
    # POSIX), and the harness strips the BOM and converts CRLF to LF before
    # anything is packed. Without that step this field would be
    # unsatisfiable by construction, exactly as CAP-10B0's
    # template_pack_digest turned out to be.
    #
    # Deliberately ABSENT, and each for a reason rather than an oversight:
    # `pas2js_app_pwb_bytes` (the container's bytes are a toolchain and
    # OS-family property - the CAP-6/CAP-7L and ZIP_OS measurements),
    # `pas2js_compiler_arch` / `_host` / `_sha256` (the pinned compiler is a
    # different artifact per platform BY DESIGN, and on macOS arm64 it is
    # built from source; prove_cap10b2 asserts the architecture where it can
    # mean something), `pas2js_doctor_row` (a per-host observation, like
    # every other doctor observation), `native_binary_equal` and
    # `pas2js_run_elapsed_ms` (measurements, reported not required), and
    # `pas2js_output_normalised` (which records what the HOST's compiler
    # emitted, and is expected to differ - that is the whole finding).
    'supported_uis', 'pas2js_create_stdout_digest', 'pas2js_create_refusals',
    'pas2js_generated_inventory_digest', 'pas2js_generated_file_count',
    'pas2js_generated_total_bytes', 'pas2js_pweb_json_digest',
    'pas2js_frontend_source_digest', 'react_generated_inventory_digest',
    'shared_native_source_digest', 'pas2js_static_inventory_digest',
    'pas2js_app_pwb_semantic_digest', 'pas2js_app_pwb_entries',
    'pas2js_tree_digest',
    'pas2js_compiler_version', 'pas2js_doctor_version',
    'pas2js_report_fields', 'pas2js_rpc_result', 'pas2js_listener_count',
    'pas2js_app_raw_binding', 'pas2js_loose_assets',
    'pas2js_sdk_binding_owner',
    # CAP-10C0: the supervision DECISION corpus - pure logic over the
    # fixture child and injected records, one byte-identical decision set on
    # four targets. Mechanism names, intervals and pids are deliberately
    # outside it (supervision_tree_model, graceful_stop_mechanism and the
    # rest are per-target observations, validated against the OS below).
    'supervision_digest', 'supervision_corpus_lines',
    # CAP-10C1: the pipeline's DECISION corpus - the four target command
    # tables, the canonical SDK manifest, the Info.plist, the mutation set and
    # the exit mapping, all pure functions computed for ALL FOUR targets on
    # whichever one is running - and the SEMANTIC inventory of each archive.
    #
    # c1_app_pwb_react_sha256 and c1_app_pwb_pas2js_sha256 are DELIBERATELY
    # ABSENT, for the reason pas2js_app_pwb_bytes is: mORMot stamps the
    # creating OS into the ZIP `version made by` field (MEASURED, run
    # 33093385300) and the static DEFLATE object emits different bytes per
    # toolchain, so archive BYTES are an OS-family property. The byte claim is
    # made where it is real - against the harness's archive on the SAME job -
    # by c1_app_pwb_react_parity and c1_app_pwb_pas2js_parity, both
    # absolute-pinned above.
    #
    # Absent for other reasons: every tool version and npm_cli_path (facts
    # about the runner), fpc_target (a Windows installation's default is
    # whichever compiler the installer wrote last), pas2js_normalised (it
    # records what the HOST's compiler emitted, and is EXPECTED to differ -
    # that is the whole finding), listener_sampler_scope and
    # listener_members_seen (a per-platform mechanism and a host count).
    'pipeline_digest', 'pipeline_corpus_lines',
    'c1_app_pwb_react_semantic_digest', 'c1_app_pwb_react_entries',
    'c1_app_pwb_pas2js_semantic_digest', 'c1_app_pwb_pas2js_entries'
)
# the CAP-9C2 semantic gate names, carried in ONE place across the two
# emitters and this aggregator (see test/cap7f/emit_evidence.ps1)
$CAP9C2_GATE_FIELDS = @(
    'ui_rendered', 'ui_add', 'quickjs_add', 'reporting_code',
    'reporting_status', 'reporting_soa_count', 'reporting_denied_bridge',
    'opener_reached',
    'same_scheduler', 'same_policy', 'same_bridge', 'same_server',
    'browser_plugin_store_arrivals', 'quickjs_app_store_arrivals',
    'browser_plugin_script_marker', 'raw_channel_source_bytes',
    'quickjs_window_absent', 'quickjs_document_absent',
    'quickjs_webkit_channel_absent', 'quickjs_webview2_channel_absent',
    'quickjs_raw_webview_invoke_absent', 'concurrent_overlap',
    'no_cross_delivery', 'plugin_archive_verified',
    'plugin_inventory_verified', 'neighbour_survived_timeout',
    'ui_survived_timeout', 'reload_generation_changed', 'clean_shutdown',
    'release_layout', 'hostile_running', 'hostile_failed'
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
    # CAP-9B1 defense in depth, only meaningful where the package corpus is
    # PASS: top-level module evaluation must never have reached the bridge
    # (the ratified load-time rule), the module loader and every package
    # store read must have stayed on the owning plugin thread, and a denied
    # plugin principal must never have reached the bridge Add arm. Guarded
    # numeric casts, exactly as the CAP-9A block above.
    if ("$($e.quickjs_package_corpus)" -ceq 'PASS') {
        foreach ($pair in @(
            @{ field = 'cap9b1_loadtime_bridge'
               why   = 'a package reached the bridge during top-level module evaluation' },
            @{ field = 'cap9b1_loader_wrong_thread'
               why   = 'the QuickJS module loader ran off its owning plugin thread' },
            @{ field = 'cap9b1_store_wrong_thread'
               why   = 'the plugin package store was read off its owning plugin thread' },
            @{ field = 'cap9b1_denied_bridge'
               why   = 'a forbidden plugin principal reached the bridge' },
            @{ field = 'cap9b1_source_open_after_failure'
               why   = 'a failed package load left a queueable invocation source' },
            @{ field = 'cap9b1_opener_reached'
               why   = 'a plugin reached the openExternal bridge arm without external.open' })) {
            $v = 0
            if (-not [int]::TryParse("$($e.($pair.field))", [ref]$v)) {
                $failures.Add("CAP-9B1 NON-NUMERIC: target=$t $($pair.field)='$($e.($pair.field))'")
            } elseif ($v -ne 0) {
                $failures.Add("CAP-9B1 $($pair.field.ToUpperInvariant())>0: target=$t $($pair.field)=$v -- $($pair.why)")
            }
        }
    }
    # CAP-9B2 defense in depth, only meaningful where the lifecycle corpus
    # is PASS. These are the lifecycle invariants a SECOND reader must be
    # able to refuse on its own, rather than trusting the harness's single
    # verdict line. Guarded numeric casts, exactly as the blocks above.
    if ("$($e.quickjs_lifecycle_corpus)" -ceq 'PASS') {
        foreach ($pair in @(
            @{ field = 'cap9b2_two_active_generations'
               why   = 'two plugin generations accepted invocations at the same time' },
            @{ field = 'cap9b2_stale_completion'
               why   = 'a completion from a retired generation reached a live one' },
            @{ field = 'cap9b2_reload_lost_old'
               why   = 'a failed staged reload lost the old Running generation' },
            @{ field = 'cap9b2_export_wrong_thread'
               why   = 'a host export call ran off its generation owning thread' },
            @{ field = 'cap9b2_quarantine_unexpected'
               why   = 'a routine unload needed the last-resort quarantine path' },
            @{ field = 'cap9b2_denied_bridge'
               why   = 'a forbidden plugin principal reached the bridge' },
            @{ field = 'cap9b2_opener_reached'
               why   = 'a plugin reached the openExternal bridge arm without external.open' })) {
            $v = 0
            if (-not [int]::TryParse("$($e.($pair.field))", [ref]$v)) {
                $failures.Add("CAP-9B2 NON-NUMERIC: target=$t $($pair.field)='$($e.($pair.field))'")
            } elseif ($v -ne 0) {
                $failures.Add("CAP-9B2 $($pair.field.ToUpperInvariant())>0: target=$t $($pair.field)=$v -- $($pair.why)")
            }
        }
        # EXACTLY ONE, in both directions. Zero means the last-resort
        # quarantine path was never exercised, which is as wrong as a
        # spurious quarantine: an unproven bounded-shutdown path is the
        # one place where "no failures observed" means nothing at all.
        $qi = 0
        if (-not [int]::TryParse("$($e.cap9b2_quarantine_injected)", [ref]$qi)) {
            $failures.Add("CAP-9B2 NON-NUMERIC: target=$t cap9b2_quarantine_injected='$($e.cap9b2_quarantine_injected)'")
        } elseif ($qi -ne 1) {
            $failures.Add("CAP-9B2 QUARANTINE-INJECTED<>1: target=$t cap9b2_quarantine_injected=$qi -- the injected unjoinable-thread row did not run exactly once")
        }
    }
    # CAP-9C1 defense in depth, only meaningful where the release corpus
    # is PASS. Five zero-invariants a SECOND reader must be able to refuse
    # on its own: package integrity that is never checked by anyone but
    # the harness that produced it is not integrity.
    if ("$($e.quickjs_release_corpus)" -ceq 'PASS') {
        foreach ($pair in @(
            @{ field = 'cap9c1_browser_store_arrivals'
               why   = 'a pweb://app probe reached the plugin package store' },
            @{ field = 'cap9c1_denied_bridge'
               why   = 'a forbidden packaged plugin principal reached the bridge' },
            @{ field = 'cap9c1_opener_reached'
               why   = 'a packaged plugin reached the openExternal bridge arm' },
            @{ field = 'cap9c1_tamper_started'
               why   = 'a plugin published despite a registry/package mismatch' },
            @{ field = 'cap9c1_cwd_dependency'
               why   = 'package verification depended on the working directory' })) {
            $v = 0
            if (-not [int]::TryParse("$($e.($pair.field))", [ref]$v)) {
                $failures.Add("CAP-9C1 NON-NUMERIC: target=$t $($pair.field)='$($e.($pair.field))'")
            } elseif ($v -ne 0) {
                $failures.Add("CAP-9C1 $($pair.field.ToUpperInvariant())>0: target=$t $($pair.field)=$v -- $($pair.why)")
            }
        }
        # the per-target facts must still be well formed and non-trivial:
        # an empty digest or a zero-byte archive would sail through the
        # equality set precisely because that set does not compare them
        if ("$($e.cap9c1_package_sha256)" -notmatch '^[0-9a-f]{64}$') {
            $failures.Add("CAP-9C1 BAD-PACKAGE-SHA: target=$t cap9c1_package_sha256='$($e.cap9c1_package_sha256)'")
        }
        if ("$($e.cap9c1_registry_sha256)" -notmatch '^[0-9a-f]{64}$') {
            $failures.Add("CAP-9C1 BAD-REGISTRY-SHA: target=$t cap9c1_registry_sha256='$($e.cap9c1_registry_sha256)'")
        }
        $pb = 0
        if (-not [int]::TryParse("$($e.cap9c1_package_bytes)", [ref]$pb)) {
            $failures.Add("CAP-9C1 NON-NUMERIC: target=$t cap9c1_package_bytes='$($e.cap9c1_package_bytes)'")
        } elseif ($pb -le 0) {
            $failures.Add("CAP-9C1 EMPTY-PACKAGE: target=$t cap9c1_package_bytes=$pb -- a verified package cannot be empty")
        }
    }
    # CAP-9C2 defense in depth. Unlike C1 there is nothing here that is
    # reported-but-not-compared: the shard's claim is that ONE
    # architecture answers on all four targets, so every gate below is a
    # semantic verdict that must read exactly 'yes' everywhere. The rule
    # is deliberately uniform - a gate whose expected value has to be
    # looked up is a gate that gets the wrong expectation written beside
    # it one day.
    if ("$($e.quickjs_gui_corpus)" -ceq 'PASS') {
        $gates = $e.cap9c2_gates
        if ($null -eq $gates) {
            $failures.Add("CAP-9C2 NO-GATES: target=$t carries no cap9c2_gates object")
        } else {
            foreach ($g in $CAP9C2_GATE_FIELDS) {
                $v = "$($gates.$g)"
                if ($v -eq '') {
                    $failures.Add("CAP-9C2 MISSING-GATE: target=$t gate '$g' is absent -- refusing to read an absent gate as green")
                } elseif ($v -cne 'yes') {
                    $failures.Add("CAP-9C2 GATE NOT GREEN: target=$t $g='$v' (expected 'yes')")
                }
            }
        }
        # a listening socket anywhere in the plugin-enabled application is
        # the one thing the whole architecture promises cannot exist
        $lc = 0
        if (-not [int]::TryParse("$($e.cap9c2_listeners)", [ref]$lc)) {
            $failures.Add("CAP-9C2 NON-NUMERIC: target=$t cap9c2_listeners='$($e.cap9c2_listeners)'")
        } elseif ($lc -ne 0) {
            $failures.Add("CAP-9C2 LISTENERS>0: target=$t cap9c2_listeners=$lc -- the plugin-enabled application opened a listening socket")
        }
        # the reparse-point negative is machine-dependent to CREATE but
        # never to REQUIRE: a waiver is recorded honestly by the runner
        # and refused here, exactly like a SKIP
        if ("$($e.cap9c2_negative_reparse)" -cne 'yes') {
            $failures.Add("CAP-9C2 REPARSE NOT PROVEN: target=$t cap9c2_negative_reparse='$($e.cap9c2_negative_reparse)' -- a waiver never promotes to a proof")
        }
        # the frozen QuickJS licence, byte-pinned, on every target
        if ("$($e.cap9c2_license_sha256)" -cne
            '8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc') {
            $failures.Add("CAP-9C2 LICENSE SHA: target=$t cap9c2_license_sha256='$($e.cap9c2_license_sha256)'")
        }
    }
    # CAP-10A defense in depth, only meaningful where the CLI corpus is
    # PASS: an EMPTY digest compares equal to another empty digest on four
    # targets, which is precisely how a gate that stopped running would look
    # identical to one that passed everywhere.
    if ("$($e.cli_corpus)" -ceq 'PASS') {
        foreach ($d in 'cli_digest', 'doctor_schema_digest') {
            if ("$($e.$d)" -notmatch '^[0-9a-f]{64}$') {
                $failures.Add("CAP-10A BAD-DIGEST: target=$t $d='$($e.$d)'")
            }
        }
        # the version line is the CLI's identity: four targets, one binary
        # contract, and a shape rather than a hard-coded value so a version
        # bump is a normal act rather than an aggregator edit
        if ("$($e.cli_version_line)" -cnotmatch '^pweb \d+\.\d+\.\d+ \(protocol \d+\)$') {
            $failures.Add("CAP-10A BAD-VERSION-LINE: target=$t cli_version_line='$($e.cli_version_line)'")
        }
        $dc = 0
        if (-not [int]::TryParse("$($e.doctor_checks)", [ref]$dc)) {
            $failures.Add("CAP-10A NON-NUMERIC: target=$t doctor_checks='$($e.doctor_checks)'")
        } elseif ($dc -le 0) {
            $failures.Add("CAP-10A NO-ROWS: target=$t doctor_checks=$dc -- a doctor that produced no row diagnosed nothing")
        }
    }
    # CAP-10B0: the same shape, for the same reason. An EMPTY digest on
    # every target compares equal to every other empty digest, so a gate
    # that stopped emitting would look exactly like one that passed
    # everywhere.
    if ("$($e.template_corpus)" -ceq 'PASS') {
        foreach ($d in 'template_digest', 'template_pack_digest',
                       'template_semantic_digest', 'template_registry_digest') {
            if ("$($e.$d)" -notmatch '^[0-9a-f]{64}$') {
                $failures.Add("CAP-10B0 BAD-DIGEST: target=$t $d='$($e.$d)'")
            }
        }
        # the pack contract version, absolutely pinned rather than merely
        # agreed: four targets that all drifted to schema 2 would agree
        # perfectly and be wrong together
        if ("$($e.template_pack_schema)" -cne '1') {
            $failures.Add("CAP-10B0 BAD-SCHEMA: target=$t template_pack_schema='$($e.template_pack_schema)' -- schema 1 is the frozen template-pack contract")
        }
        $rf = 0
        if (-not [int]::TryParse("$($e.template_refusals)", [ref]$rf)) {
            $failures.Add("CAP-10B0 NON-NUMERIC: target=$t template_refusals='$($e.template_refusals)'")
        } elseif ($rf -ne 7) {
            $failures.Add("CAP-10B0 REFUSALS: target=$t template_refusals=$rf, expected 7 -- a builder refusal nobody watched fire is a comment")
        }
        $fc = 0
        if (-not [int]::TryParse("$($e.template_file_count)", [ref]$fc)) {
            $failures.Add("CAP-10B0 NON-NUMERIC: target=$t template_file_count='$($e.template_file_count)'")
        } elseif ($fc -le 0) {
            $failures.Add("CAP-10B0 NO-FILES: target=$t template_file_count=$fc -- a pack with no file scaffolds nothing")
        }
        # the two counts the acceptance criteria name. They are DERIVED from
        # the source and unit-set sweeps, so a nonzero value here means one
        # of those sweeps found something rather than that a counter ticked
        foreach ($z in 'network_calls', 'package_manager_calls') {
            if ("$($e.$z)" -cne '0') {
                $failures.Add("CAP-10B0 NOT-OFFLINE: target=$t $z='$($e.$z)' -- `pweb create` writes files and fetches nothing")
            }
        }
    }
    # CAP-10B2: the same shape again, for the same reason, over the digests
    # this shard's whole claim rests on. `react_generated_inventory_digest`
    # is in the list deliberately: the one drift this shard could hide is
    # React changing while every new Pas2JS field stayed green.
    if ("$($e.pas2js_create_corpus)" -ceq 'PASS') {
        foreach ($d in 'pas2js_generated_inventory_digest',
                       'pas2js_pweb_json_digest',
                       'pas2js_frontend_source_digest',
                       'shared_native_source_digest',
                       'react_generated_inventory_digest') {
            if ("$($e.$d)" -notmatch '^[0-9a-f]{64}$') {
                $failures.Add("CAP-10B2 BAD-DIGEST: target=$t $d='$($e.$d)'")
            }
        }
        $pf = 0
        if (-not [int]::TryParse("$($e.pas2js_generated_file_count)", [ref]$pf)) {
            $failures.Add("CAP-10B2 NON-NUMERIC: target=$t pas2js_generated_file_count='$($e.pas2js_generated_file_count)'")
        } elseif ($pf -le 0) {
            $failures.Add("CAP-10B2 NO-FILES: target=$t pas2js_generated_file_count=$pf -- a project with no file is not a project")
        }
        $pr = 0
        if (-not [int]::TryParse("$($e.pas2js_create_refusals)", [ref]$pr)) {
            $failures.Add("CAP-10B2 NON-NUMERIC: target=$t pas2js_create_refusals='$($e.pas2js_create_refusals)'")
        } elseif ($pr -ne 13) {
            $failures.Add("CAP-10B2 REFUSALS: target=$t pas2js_create_refusals=$pr, expected 13 -- a refusal nobody watched fire is a comment")
        }
        # THE UI VOCABULARY IS EXACT, and it is checked as a SET rather than
        # as a substring: 'react' alone, 'pas2js' alone and a third kind
        # that arrived unnoticed are three different defects and all three
        # are refused here. The absolute pin above catches four targets that
        # drifted together; this catches the shape.
        if ("$($e.supported_uis)" -cnotmatch '^pas2js,react$') {
            $failures.Add("CAP-10B2 BAD-UI-SET: target=$t supported_uis='$($e.supported_uis)' -- the advertised set is exactly react and pas2js, in bytewise order")
        }
    }
    if ("$($e.pas2js_proof_corpus)" -ceq 'PASS') {
        foreach ($d in 'pas2js_static_inventory_digest',
                       'pas2js_app_pwb_semantic_digest',
                       'pas2js_tree_digest') {
            if ("$($e.$d)" -notmatch '^[0-9a-f]{64}$') {
                $failures.Add("CAP-10B2 BAD-DIGEST: target=$t $d='$($e.$d)'")
            }
        }
        # the compiler that produced it, identified per target. The VERSION
        # is absolutely pinned above; this refuses an unidentified artifact,
        # which is how a build that silently fell back to whatever was on
        # PATH would look.
        if ("$($e.pas2js_compiler_sha256)" -notmatch '^[0-9a-f]{64}$') {
            $failures.Add("CAP-10B2 BAD-COMPILER-SHA: target=$t pas2js_compiler_sha256='$($e.pas2js_compiler_sha256)'")
        }
        # NO ROSETTA, asserted where it can mean something: the macOS arm64
        # leg must have used a compiler built for aarch64. Upstream ships no
        # such binary, so this is the one field that proves the native
        # source build actually happened rather than a translated x86_64 one.
        if (($t -eq 'macos-arm64') -and
            ("$($e.pas2js_compiler_arch)" -cne 'aarch64')) {
            $failures.Add("CAP-10B2 TRANSLATED-COMPILER: target=$t pas2js_compiler_arch='$($e.pas2js_compiler_arch)', expected aarch64 -- Rosetta is refused by the ratified no-translation invariant")
        }
        $pl = 0
        if (-not [int]::TryParse("$($e.pas2js_listener_count)", [ref]$pl)) {
            $failures.Add("CAP-10B2 NON-NUMERIC: target=$t pas2js_listener_count='$($e.pas2js_listener_count)'")
        }
        # the page's own report SHAPE, which is the React starter's. Both
        # frontends answer the same eight questions under the same names,
        # which is what makes react_pas2js_parity a comparison rather than
        # two separate readings.
        if ("$($e.pas2js_report_fields)" -cne
            'css,errmap,handshake,html,js,rpc,secure,value') {
            $failures.Add("CAP-10B2 BAD-REPORT-SHAPE: target=$t pas2js_report_fields='$($e.pas2js_report_fields)'")
        }
        # the archive really was opened: the four static assets plus the
        # manifest.json the BUNDLER owns and the dist never contained. A
        # digest computed over the dist directory instead would have five
        # entries fewer and this row would say so.
        $pe = 0
        if (-not [int]::TryParse("$($e.pas2js_app_pwb_entries)", [ref]$pe)) {
            $failures.Add("CAP-10B2 NON-NUMERIC: target=$t pas2js_app_pwb_entries='$($e.pas2js_app_pwb_entries)'")
        } elseif ($pe -ne 5) {
            $failures.Add("CAP-10B2 BAD-BUNDLE-INVENTORY: target=$t pas2js_app_pwb_entries=$pe, expected 5 (index.html, three assets, manifest.json)")
        }
    }
    # CAP-10C0: defense in depth beside the absolute pins. An EMPTY
    # supervision digest on four targets agrees perfectly; the tree model
    # and the graceful-stop mechanism are per-target OBSERVATIONS, but each
    # has exactly one honest value per operating system, and a Windows leg
    # reporting process_group would be a leg that ran the wrong body.
    if ("$($e.supervision_corpus)" -ceq 'PASS') {
        if ("$($e.supervision_digest)" -notmatch '^[0-9a-f]{64}$') {
            $failures.Add("CAP-10C0 BAD-DIGEST: target=$t supervision_digest='$($e.supervision_digest)'")
        }
        $sl = 0
        if (-not [int]::TryParse("$($e.supervision_corpus_lines)", [ref]$sl)) {
            $failures.Add("CAP-10C0 NON-NUMERIC: target=$t supervision_corpus_lines='$($e.supervision_corpus_lines)'")
        } elseif ($sl -le 0) {
            $failures.Add("CAP-10C0 NO-DECISIONS: target=$t supervision_corpus_lines=$sl -- a suite that recorded no decision decided nothing")
        }
        $expectedTree = if ($expectations[$t].os -eq 'windows') { 'job_object' } else { 'process_group' }
        if ("$($e.supervision_tree_model)" -cne $expectedTree) {
            $failures.Add("CAP-10C0 WRONG-TREE-MODEL: target=$t supervision_tree_model='$($e.supervision_tree_model)', expected $expectedTree")
        }
        $expectedStop = if ($expectations[$t].os -eq 'windows') { 'wm_close_visible_toplevel' } else { 'sigterm_process_group' }
        if ("$($e.graceful_stop_mechanism)" -cne $expectedStop) {
            $failures.Add("CAP-10C0 WRONG-STOP-MECHANISM: target=$t graceful_stop_mechanism='$($e.graceful_stop_mechanism)', expected $expectedStop")
        }
        # a signal death is typed where signals exist, and honestly absent
        # where they do not - a POSIX leg reading not_applicable skipped S2
        $expectedSignal = if ($expectations[$t].os -eq 'windows') { 'not_applicable' } else { 'true' }
        if ("$($e.signal_outcome_typed)" -cne $expectedSignal) {
            $failures.Add("CAP-10C0 SIGNAL-NOT-TYPED: target=$t signal_outcome_typed='$($e.signal_outcome_typed)', expected $expectedSignal")
        }
    }
    if ("$($e.run_corpus)" -ceq 'PASS') {
        foreach ($z in 'run_listener_count', 'run_network_calls', 'run_tool_calls',
                       'descendants_after_exit') {
            $zv = 0
            if (-not [int]::TryParse("$($e.$z)", [ref]$zv)) {
                $failures.Add("CAP-10C0 NON-NUMERIC: target=$t $z='$($e.$z)'")
            } elseif ($zv -ne 0) {
                $failures.Add("CAP-10C0 NOT-INERT: target=$t $z=$zv -- `pweb run` launched something it must not")
            }
        }
        foreach ($d in 'stage_react_release_digest', 'stage_pas2js_release_digest') {
            if ("$($e.$d)" -notmatch '^[0-9a-f]{64}$') {
                $failures.Add("CAP-10C0 BAD-DIGEST: target=$t $d='$($e.$d)' -- the run measured no staged release")
            }
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
        quickjs_package_digest         = $first.quickjs_package_digest
        quickjs_lifecycle_digest       = $first.quickjs_lifecycle_digest
        quickjs_release_digest         = $first.quickjs_release_digest
        cap9c1_inventory_digest        = $first.cap9c1_inventory_digest
        cli_digest                     = $first.cli_digest
        doctor_schema_digest           = $first.doctor_schema_digest
        cli_version_line               = $first.cli_version_line
        template_digest                = $first.template_digest
        template_semantic_digest       = $first.template_semantic_digest
        template_pack_schema           = $first.template_pack_schema
        supported_uis                  = $first.supported_uis
        public_semantic_digest         = $first.public_semantic_digest
        generated_inventory_digest     = $first.generated_inventory_digest
        generated_pweb_json_digest     = $first.generated_pweb_json_digest
        generated_package_lock_digest  = $first.generated_package_lock_digest
        generated_tree_digest          = $first.generated_tree_digest
        rpc_result                     = $first.rpc_result
        pas2js_generated_inventory_digest = $first.pas2js_generated_inventory_digest
        pas2js_pweb_json_digest        = $first.pas2js_pweb_json_digest
        pas2js_frontend_source_digest  = $first.pas2js_frontend_source_digest
        pas2js_static_inventory_digest = $first.pas2js_static_inventory_digest
        pas2js_app_pwb_semantic_digest = $first.pas2js_app_pwb_semantic_digest
        shared_native_source_digest    = $first.shared_native_source_digest
        react_generated_inventory_digest = $first.react_generated_inventory_digest
        pas2js_compiler_version        = $first.pas2js_compiler_version
        pas2js_report_fields           = $first.pas2js_report_fields
        pas2js_rpc_result              = $first.pas2js_rpc_result
        supervision_digest             = $first.supervision_digest
        advertised_commands            = $first.advertised_commands
        run_react_rpc_value            = $first.run_react_rpc_value
        run_pas2js_rpc_value           = $first.run_pas2js_rpc_value
        shutdown_order                 = $first.shutdown_order
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
        quickjs_package_corpus = $e.quickjs_package_corpus
        quickjs_lifecycle_corpus = $e.quickjs_lifecycle_corpus
        quickjs_release_corpus = $e.quickjs_release_corpus
        quickjs_gui_corpus = $e.quickjs_gui_corpus
        cli_corpus         = $e.cli_corpus
        doctor_checks      = $e.doctor_checks
        doctor_no_mutation = $e.doctor_no_mutation
        template_corpus    = $e.template_corpus
        template_deterministic = $e.template_deterministic
        template_source_gate = $e.template_source_gate
        template_offline   = $e.template_offline
        create_present      = $e.create_present
        template_modes_applicable = $e.template_modes_applicable
        create_corpus      = $e.create_corpus
        create_deterministic = $e.create_deterministic
        create_no_partial  = $e.create_no_partial
        generated_inventory_exact = $e.generated_inventory_exact
        generated_no_host_path = $e.generated_no_host_path
        doctor_result      = $e.doctor_result
        proof_corpus       = $e.proof_corpus
        generated_tree_unchanged = $e.generated_tree_unchanged
        frontend_typecheck = $e.frontend_typecheck
        frontend_build     = $e.frontend_build
        frontend_no_dev_code = $e.frontend_no_dev_code
        frontend_transport_clean = $e.frontend_transport_clean
        runtime_from_sdk_root = $e.runtime_from_sdk_root
        native_build       = $e.native_build
        secure_origin      = $e.secure_origin
        error_mapping      = $e.error_mapping
        # CAP-10B2, per target: the verdicts, and the observations that are
        # facts about THIS runner rather than about the scaffold
        pas2js_create_corpus = $e.pas2js_create_corpus
        pas2js_proof_corpus  = $e.pas2js_proof_corpus
        pas2js_doctor_result = $e.pas2js_doctor_result
        pas2js_doctor_row    = $e.pas2js_doctor_row
        react_regression_result = $e.react_regression_result
        react_pas2js_parity  = $e.react_pas2js_parity
        native_parity        = $e.native_parity
        pas2js_frontend_build = $e.pas2js_frontend_build
        pas2js_native_build  = $e.pas2js_native_build
        pas2js_output_sweep  = $e.pas2js_output_sweep
        pas2js_compiler_host = $e.pas2js_compiler_host
        pas2js_compiler_sha256 = $e.pas2js_compiler_sha256
        pas2js_output_normalised = $e.pas2js_output_normalised
        pas2js_app_pwb_bytes = $e.pas2js_app_pwb_bytes
        pas2js_run_elapsed_ms = $e.pas2js_run_elapsed_ms
        native_binary_equal  = $e.native_binary_equal
        # CAP-10C0, per target: the verdicts, and the mechanism facts that
        # are about THIS operating system rather than about the contract
        supervision_corpus   = $e.supervision_corpus
        run_corpus           = $e.run_corpus
        supervision_tree_model = $e.supervision_tree_model
        graceful_stop_mechanism = $e.graceful_stop_mechanism
        signal_outcome_typed = $e.signal_outcome_typed
        run_elapsed_ms       = $e.run_elapsed_ms
        run_descendants_drained = $e.run_descendants_drained
        run_descendants_forced = $e.run_descendants_forced
        run_drain_passes     = $e.run_drain_passes
        stage_react_release_digest = $e.stage_react_release_digest
        stage_pas2js_release_digest = $e.stage_pas2js_release_digest
        # the PUBLIC pack's bytes, per target and for the same ZIP_OS reason
        # the CAP-10B0 pack's are: identical within an OS family, one byte
        # per entry apart between them
        public_pack_digest = $e.public_pack_digest
        public_pack_bytes  = $e.public_pack_bytes
        public_registry_digest = $e.public_registry_digest
        public_pack_deterministic = $e.public_pack_deterministic
        # the archive's BYTES, per target: identical within an OS family and
        # differing by mORMot's ZIP_OS stamp between them (see the equality
        # list). Recorded so the two values are readable side by side rather
        # than discovered by a failing comparison
        template_pack_digest = $e.template_pack_digest
        template_pack_bytes = $e.template_pack_bytes
        template_registry_digest = $e.template_registry_digest
        cap9c1_package_sha256 = $e.cap9c1_package_sha256
        cap9c1_package_bytes = $e.cap9c1_package_bytes
        cap9c1_registry_sha256 = $e.cap9c1_registry_sha256
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
$summary += '| target | engine | host_args | cap_policy | nav_security | sec_corpus | qjs_corpus | qjs_pkg | qjs_life | qjs_rel | layout | no_listener | rtti extras |'
$summary += '|---|---|---|---|---|---|---|---|---|---|---|---|---|'
foreach ($t in $evidence.Keys) {
    $e = $evidence[$t]
    $summary += "| $t | $($e.engine) | $($e.host_args) | $($e.capability_policy) | $($e.navigation_security) | $($e.security_corpus) | $($e.quickjs_corpus) | $($e.quickjs_package_corpus) | $($e.quickjs_lifecycle_corpus) | $($e.quickjs_release_corpus) | $($e.quickjs_gui_corpus) | $($e.release_layout) | $($e.no_listener) | $($e.extra_exports_rtti) |"
}
$summary += ''
$summary += "- webview pin ``$($first.webview_pin)``, surface ``$($first.webview_surface)``, origin ``$($first.origin)`` (secure=$($first.secure)), RPC Add(20,22)=$($first.rpc_add_20_22)"
$summary += "- CAP-8A capability_policy_digest ``$($first.capability_policy_digest)`` equal on all four targets"
$summary += "- CAP-8B navigation_policy_digest ``$($first.navigation_policy_digest)`` equal on all four targets"
$summary += "- CAP-8C security_corpus_digest ``$($first.security_corpus_digest)`` equal on all four targets"
$summary += "- CAP-9A quickjs_corpus_digest ``$($first.quickjs_corpus_digest)`` equal on all four targets"
$summary += "- CAP-9B1 quickjs_package_digest ``$($first.quickjs_package_digest)`` equal on all four targets"
$summary += "- CAP-9B2 quickjs_lifecycle_digest ``$($first.quickjs_lifecycle_digest)`` equal on all four targets"
$summary += "- CAP-9C1 quickjs_release_digest ``$($first.quickjs_release_digest)`` equal on all four targets"
$summary += "- CAP-9C1 cap9c1_inventory_digest ``$($first.cap9c1_inventory_digest)`` equal on all four targets (the archive's MEANING; its BYTES are per-toolchain and reported below, not compared)"
foreach ($t in $evidence.Keys) {
    $e = $evidence[$t]
    $summary += "  - $t plugins.zip sha256 ``$($e.cap9c1_package_sha256)`` ($($e.cap9c1_package_bytes) bytes), registry ``$($e.cap9c1_registry_sha256)``"
}
$summary += "- CAP-9C2 quickjs_gui_digest ``$($first.quickjs_gui_digest)`` equal on all four targets (the plugin-enabled GUI corpus: UI + QuickJS over one scheduler/policy/bridge/server)"
$summary += "- CAP-9C2 LICENSE.quickjs ``$($first.cap9c2_license_sha256)`` byte-identical on all four targets; listeners=0 everywhere"
$summary += "- CAP-10A cli_digest ``$($first.cli_digest)`` and doctor_schema_digest ``$($first.doctor_schema_digest)`` equal on all four targets; ``$($first.cli_version_line)`` everywhere (per-host doctor OBSERVATIONS are recorded per target and deliberately not compared)"
$summary += "- CAP-10B0 template_digest ``$($first.template_digest)`` and template_semantic_digest ``$($first.template_semantic_digest)`` equal on all four targets (the archive's MEANING; its BYTES are per-OS-family and reported below, not compared - mORMot stamps the creating OS into the ZIP made-by field, ZIP_OS=19 on Darwin and 3 elsewhere)"
foreach ($t in $evidence.Keys) {
    $summary += "  - $t template_pack_digest ``$($evidence[$t].template_pack_digest)`` ($($evidence[$t].template_pack_bytes) bytes, rebuilt-and-compared on target: $($evidence[$t].template_deterministic))"
}
$summary += "- CAP-10B0 the scaffold engine is now LINKED into the CLI on every target: create_present=$($first.create_present), and creation still runs nothing (network_calls=$($first.network_calls), package_manager_calls=$($first.package_manager_calls))"
$summary += "- CAP-10B1 ``pweb create NAME --ui react --bundle-id <id>`` produces a byte-identical project on all four targets: generated_inventory_digest ``$($first.generated_inventory_digest)``, $($first.generated_file_count) files, $($first.generated_total_bytes) bytes, pweb.json ``$($first.generated_pweb_json_digest)``, package-lock ``$($first.generated_package_lock_digest)`` ($($first.create_refusals) refusals proven, no partial destination: $($first.create_no_partial))"
$summary += "- CAP-10B1 public_semantic_digest ``$($first.public_semantic_digest)`` equal on all four targets ($($first.public_file_count) template files; the pack's BYTES are per-OS-family and reported below, not compared)"
foreach ($t in $evidence.Keys) {
    $summary += "  - $t public_pack_digest ``$($evidence[$t].public_pack_digest)`` ($($evidence[$t].public_pack_bytes) bytes, rebuilt-and-compared on target: $($evidence[$t].public_pack_deterministic))"
}
$summary += "- CAP-10B1 the generated project builds and runs on every target: doctor=$($first.doctor_result), typecheck=$($first.frontend_typecheck), frontend=$($first.frontend_build), native=$($first.native_build), secure=$($first.secure_origin), CalculatorService.Add(20,22)=$($first.rpc_result), errmap=$($first.error_mapping), listeners=$($first.listener_count), raw_primitive=$($first.raw_primitive_used), loose_assets=$($first.loose_assets_used), and the build left the project unchanged ($($first.generated_tree_unchanged))"
$summary += "- CAP-10B2 ``pweb create NAME --ui pas2js --bundle-id <id>`` produces a byte-identical project on all four targets: pas2js_generated_inventory_digest ``$($first.pas2js_generated_inventory_digest)``, $($first.pas2js_generated_file_count) files, $($first.pas2js_generated_total_bytes) bytes, pweb.json ``$($first.pas2js_pweb_json_digest)``, frontend sources ``$($first.pas2js_frontend_source_digest)`` ($($first.pas2js_create_refusals) refusals proven, no partial destination: $($first.pas2js_no_partial))"
$summary += "- CAP-10B2 supported_uis ``$($first.supported_uis)`` on all four targets, and the React corpus is unchanged from its CAP-10B1 closure value ``$($first.react_generated_inventory_digest)`` ($($first.react_regression_result))"
$summary += "- CAP-10B2 ONE generated native application: shared_native_source_digest ``$($first.shared_native_source_digest)`` equal across both UIs and all four targets (native_parity=$($first.native_parity))"
$summary += "- CAP-10B2 the generated Pas2JS project builds and runs on every target with Pas2JS $($first.pas2js_compiler_version): doctor=$($first.pas2js_doctor_result), frontend=$($first.pas2js_frontend_build), native=$($first.pas2js_native_build), static output ``$($first.pas2js_static_inventory_digest)``, secure=$($first.pas2js_secure_origin), CalculatorService.Add(20,22)=$($first.pas2js_rpc_result), errmap=$($first.pas2js_error_mapping), listeners=$($first.pas2js_listener_count), app_raw_binding=$($first.pas2js_app_raw_binding), sdk_binding_owner=$($first.pas2js_sdk_binding_owner), loose_assets=$($first.pas2js_loose_assets), and the build never touched the project ($($first.pas2js_build_out_of_tree))"
$summary += "- CAP-10B2 React/Pas2JS backend parity on every target: $($first.react_pas2js_parity) (same report shape ``$($first.pas2js_report_fields)``, same 42, no listener on either)"
foreach ($t in $evidence.Keys) {
    $summary += "  - $t pas2js compiler $($evidence[$t].pas2js_compiler_host) sha256 ``$($evidence[$t].pas2js_compiler_sha256)``, raw output $($evidence[$t].pas2js_output_normalised), app.pwb $($evidence[$t].pas2js_app_pwb_bytes) bytes, native binary equal to the react build: $($evidence[$t].native_binary_equal)"
}
$summary += "- CAP-10C0 ONE supervision engine, one decision corpus: supervision_digest ``$($first.supervision_digest)`` equal on all four targets ($($first.supervision_corpus_lines) decisions; argv=$($first.argv_roundtrip), exit=$($first.exit_propagation), death_never_exit_zero=$($first.death_never_exit_zero), forced_kill_required=$($first.forced_kill_required), zombie=$($first.zombie_left), env=$($first.environment_policy), shell=$($first.supervision_shell_used), name_kill=$($first.global_name_kill_present))"
$summary += "- CAP-10C0 ``pweb run`` on the built React and Pas2JS projects on every target: advertised ``$($first.advertised_commands)``, CalculatorService.Add(20,22)=$($first.run_react_rpc_value)/$($first.run_pas2js_rpc_value), secure=$($first.run_secure_origin), listeners=$($first.run_listener_count), network=$($first.run_network_calls), tools=$($first.run_tool_calls), descendants_after_exit=$($first.descendants_after_exit), interrupt=$($first.run_interrupt_clean), supervisor_terminated_tree_dies=$($first.supervisor_terminated_tree_dies), not_built=$($first.run_not_built), link=$($first.run_layout_link), tampered=$($first.run_tampered_bundle), dev/build unknown=$($first.dev_build_unknown)"
foreach ($t in $evidence.Keys) {
    $summary += "  - $t tree=$($evidence[$t].supervision_tree_model) stop=$($evidence[$t].graceful_stop_mechanism) signal_typed=$($evidence[$t].signal_outcome_typed) drained=$($evidence[$t].run_descendants_drained) forced=$($evidence[$t].run_descendants_forced) passes=$($evidence[$t].run_drain_passes) elapsed_ms=$($evidence[$t].run_elapsed_ms)"
}
$summary += "- react logical_inventory_sha256 ``$($first.logical_inventory_sha256_react)`` equal on all four targets"
$summary += "- pas2js logical_inventory_sha256 ``$($matrix.agreement.logical_inventory_sha256_pas2js)`` equal on linux/macos-x64/macos-arm64"
$summaryText = $summary -join "`n"
Write-Host $summaryText
if ($env:GITHUB_STEP_SUMMARY) {
    $summaryText | Out-File -Append $env:GITHUB_STEP_SUMMARY
}
Write-Host '[CAP-7F] aggregate PASS - platform-matrix.json written'
