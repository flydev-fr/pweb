#!/usr/bin/env bash
#
# CAP-7F: the POSIX per-target evidence emitter (schema 1) - Linux x64 and
# macOS (both native architectures), dispatched on uname. The bash sibling
# of test/cap7f/emit_evidence.ps1; the two write the SAME schema so the
# cap7-aggregate job compares structured fields, never localized prose.
#
# HONESTY INVARIANTS (ratified):
#   - every field derives from a check actually executed in the same run:
#     re-executed here (export enumeration, logical inventory, release-layout
#     shape) or read from the committed verdict record of a gate that ran
#     EARLIER IN THE SAME JOB (a failed gate kills the job before this
#     emitter, and the emitter additionally requires the gate's own log or
#     measurement marker to exist rather than trusting step order alone);
#   - a SKIP or WAIVED verdict is recorded as such, never promoted to PASS;
#   - the logical-inventory formula is byte-identical to
#     test/cap7m/run_cap7m_release.sh emit_manifest (rows
#     `entry=<name> size=<bytes> sha256=<lowercase hex>`, LF, LC_ALL=C
#     byte order, directories skipped; logical_inventory_sha256 = SHA-256 of
#     the manifest file bytes). On macOS the manifests ALREADY exist - the
#     release gate emitted them - so they are consumed, cross-checked against
#     the inventory rows, and never re-derived by a second formula copy. On
#     Linux the bundles are REBUILT from the frontend dists (pwebbundle is
#     deterministic per toolchain, proven by the CAP-6/CAP-7M2 rebuild gates)
#     and inventoried with the formula.
#
# bash-3.2-safe throughout (macOS /bin/bash): no self-referencing `local`
# assignments on one line, no array expansion of possibly-empty arrays.
#
# Writes: build/cap7f/evidence.json (+ manifests on Linux).
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7F] %s\n' "$*" >&2; exit 1; }

work="${repo_root}/build/cap7f"
mkdir -p -- "${work}"

# --- strict 'key = value' lock reader ----------------------------------------
lock_read() {
    local file="$1" key="$2" hits value
    hits="$(grep -cE "^${key}[[:space:]]*=" "${file}" || true)"
    [ "${hits}" = '1' ] || die "lock key '${key}' not found exactly once in ${file}"
    value="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "${file}" |
        sed 's/[[:space:]]*$//')"
    [ -n "${value}" ] || die "lock key '${key}' is empty in ${file}"
    printf '%s' "${value}"
}

file_sha() {
    case "$(uname -s)" in
        Darwin) shasum -a 256 "$1" | awk '{ print $1 }' ;;
        *) sha256sum "$1" | awk '{ print $1 }' ;;
    esac
}

# minimal JSON string escaper for interpolated free text (backslash, quote)
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# The logical inventory formula - byte-identical to run_cap7m_release.sh
# emit_manifest (see that script for the bracket-class rationale: unzip
# treats the member name as a PATTERN).
emit_manifest() {
    local pwb="$1" out="$2" entry pattern size sha
    local extracted="${work}/manifest-entry.bin"
    : > "${out}"
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        case "${entry}" in
            */) continue ;;
        esac
        pattern="$(printf '%s' "${entry}" | sed -e 's/[[*?]/[&]/g')"
        unzip -p "${pwb}" "${pattern}" > "${extracted}"
        size="$(wc -c < "${extracted}" | tr -d ' ')"
        sha="$(file_sha "${extracted}")"
        printf 'entry=%s size=%s sha256=%s\n' "${entry}" "${size}" "${sha}" >> "${out}"
    done < <(zipinfo -1 "${pwb}" | LC_ALL=C sort)
    rm -f -- "${extracted}"
    [ -s "${out}" ] || die "logical inventory of ${pwb} came out empty"
}

# Reads one key=value row from a CAP-7M2 inventory file, requiring presence.
inventory_read() {
    local file="$1" key="$2" value
    value="$(sed -n "s/^${key}=//p" "${file}")"
    [ -n "${value}" ] || die "inventory key '${key}' missing in ${file}"
    printf '%s' "${value}"
}

bundle_protocol_of() {
    local pwb="$1" manifest protocol
    manifest="$(unzip -p "${pwb}" manifest.json)" ||
        die "unable to read manifest.json from ${pwb}"
    protocol="$(printf '%s' "${manifest}" |
        sed -n 's/.*"protocol"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    [ -n "${protocol}" ] || die "no protocol in ${pwb} manifest.json: ${manifest}"
    printf '%s' "${protocol}"
}

# Turns a LC_ALL=C-sorted newline list into a JSON string array (one line).
json_string_array() {
    local first=1 item out=''
    while IFS= read -r item; do
        [ -n "${item}" ] || continue
        if [ "${first}" = '1' ]; then
            out="\"${item}\""
            first=0
        else
            out="${out}, \"${item}\""
        fi
    done
    printf '[%s]' "${out}"
}

webview_pin="$(lock_read webview.lock commit)"
linux_soname="$(lock_read webview.lock linux-soname)"
soversion="${linux_soname#libwebview.so.}"
case "${soversion}" in
    [0-9]*.[0-9]*) ;;
    *) die "unexpected linux-soname shape: ${linux_soname}" ;;
esac
surface="17/soname ${soversion}"

# fpc must exist and answer: a placeholder would compare EQUAL across
# targets that are all missing the compiler - the false agreement the
# aggregator exists to refuse
command -v fpc >/dev/null 2>&1 ||
    die 'fpc not found on PATH -- the toolchain evidence cannot be emitted'
fpc_version="$(fpc -iV | tr -d '[:space:]')"
[ -n "${fpc_version}" ] || die 'fpc -iV answered nothing'
github_sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
github_run_id="${GITHUB_RUN_ID:-<local>}"

os_name="$(uname -s)"

case "${os_name}" in

# ============================== Linux x64 ====================================
Linux)
    for tool in nm unzip zipinfo sha256sum; do
        command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
    done
    target='linux-x86_64'
    arch="$(uname -m)"
    [ "${arch}" = 'x86_64' ] || die "expected x86_64, uname -m says ${arch}"
    lib="${repo_root}/build/cap7l/webview-dist/${linux_soname}"
    [ -f "${lib}" ] || die "built shared library missing: ${lib}"
    release="${repo_root}/dist/linux-x64/release"
    bin="${repo_root}/build/cap7l/bin"
    [ -x "${bin}/pwebbundle" ] || die 'pwebbundle missing -- run test/cap7l/build_cap7l.sh'

    # exports, re-enumerated exactly as the CAP-7L gate reads them
    exports_list="$(nm -D --defined-only --format=posix "${lib}" |
        awk 'NF > 0 { print $1 }' | LC_ALL=C sort)"
    [ -n "${exports_list}" ] || die 'nm -D enumerated no exports'
    exports_json="$(printf '%s\n' "${exports_list}" | json_string_array)"
    extra_rtti=0

    gcc_version="$(gcc -dumpfullversion 2>/dev/null || printf '<absent>')"
    cc_note="gcc ${gcc_version} (libwebview.so built by CMake + gcc; exports re-enumerated via nm -D)"
    engine="WebKitGTK $(lock_read webview.lock linux-webkitgtk-api)"

    # release layout, re-asserted: exactly the ratified four files, the
    # shared-object name taken from the lock rather than spelled twice
    layout_expected="$(printf '%s\n' LICENSE.webview app.pwb "${linux_soname}" releaseapp |
        LC_ALL=C sort | tr '\n' ' ')"
    layout_listing="$(cd -- "${release}" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
    [ "${layout_listing}" = "${layout_expected}" ] ||
        die "release layout is not the ratified four files: got [${layout_listing}] expected [${layout_expected}]"
    release_layout='PASS'

    # no-listener: the L20 runtime gate ran earlier in this job; require its
    # own run log AND marker rather than trusting step order alone
    nonet_log="${repo_root}/build/cap7l/release/nonetwork-run.log"
    [ -f "${nonet_log}" ] ||
        die 'CAP-7L zero-transport run log missing -- check_cap7l_nonetwork.sh has not run in this workspace'
    grep -q 'app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS' "${nonet_log}" ||
        die 'the zero-transport run log carries no PASS marker'
    no_listener='PASS'
    no_listener_prov='runtime-gate (check_cap7l_nonetwork.sh L20, this job; lifetime lsof sampling)'

    # logical inventories: rebuild both bundles from the dists (deterministic
    # per toolchain) and inventory them with the formula
    react_dist="${repo_root}/examples/04-react/frontend/dist"
    p2j_dist="${repo_root}/examples/05-pas2js/frontend/dist"
    [ -f "${react_dist}/index.html" ] || die "react frontend dist missing: ${react_dist}"
    [ -f "${p2j_dist}/index.html" ] || die "pas2js frontend dist missing: ${p2j_dist}"
    rm -f -- "${work}/react.pwb" "${work}/pas2js.pwb"
    "${bin}/pwebbundle" "${react_dist}" "${work}/react.pwb" > "${work}/pwebbundle-react.log" 2>&1 ||
        { cat "${work}/pwebbundle-react.log" >&2; die 'react app.pwb build failed'; }
    "${bin}/pwebbundle" "${p2j_dist}" "${work}/pas2js.pwb" > "${work}/pwebbundle-pas2js.log" 2>&1 ||
        { cat "${work}/pwebbundle-pas2js.log" >&2; die 'pas2js app.pwb build failed'; }
    emit_manifest "${work}/react.pwb" "${work}/manifest-react.txt"
    emit_manifest "${work}/pas2js.pwb" "${work}/manifest-pas2js.txt"
    react_inventory_sha="$(file_sha "${work}/manifest-react.txt")"
    p2j_inventory_sha="$(file_sha "${work}/manifest-pas2js.txt")"
    react_pwb_sha="$(file_sha "${work}/react.pwb")"
    bundle_protocol="$(bundle_protocol_of "${work}/react.pwb")"

    # runtime verdict fields from the CAP-7F args gate (no SKIP on Linux)
    [ -f "${work}/host-args.json" ] ||
        die 'host-args.json missing -- run test/cap7f/run_host_args_gate.sh first'
    grep -q '"overall": "PASS"' "${work}/host-args.json" ||
        die 'the host-args gate did not record PASS on Linux (no SKIP policy here)'
    host_args='PASS'
    grep -q '"secure":true' "${work}/host-args-pass.log" ||
        die 'args-gate PASS log carries no "secure":true page report'
    grep -Eq '"value":42([^0-9]|$)' "${work}/host-args-pass.log" ||
        die 'args-gate PASS log carries no anchored "value":42 page report'
    grep -Fq 'pweb://app' "${work}/host-args-pass.log" ||
        die 'args-gate PASS log never named the pweb://app origin'
    # CAP-8A runtime deny enforcement, re-asserted at evidence time
    grep -q '"denied":true' "${work}/host-args-pass.log" ||
        die 'args-gate PASS log carries no "denied":true page report -- the production policy did not forbid the unmapped probe'
    origin='pweb://app'
    secure='true'
    rpc='42'
    runtime_prov='runtime-gate (CAP-7F args gate PASS leg, this job)'

    waivers='"WebKitGTK/GTK are distro packages the application never installs (ratified CAP-7L dependency, no Linux CAP-13)"'
    ;;

# ============================ macOS (both arches) ============================
Darwin)
    for tool in unzip shasum; do
        command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
    done
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: ${arch}" ;;
    esac
    dylib_versioned="$(lock_read webview.lock macos-dylib-versioned)"
    lib="${repo_root}/build/cap7m/webview-dist/${dylib_versioned}"
    [ -f "${lib}" ] || die "built dylib missing: ${lib}"
    release="${repo_root}/dist/macos-${arch}/release"
    apps="${repo_root}/build/cap7m/release-apps"
    measurements="${repo_root}/build/cap7m/measurements.txt"
    [ -f "${measurements}" ] ||
        die 'build/cap7m/measurements.txt missing -- the CAP-7M gates have not run in this workspace'

    # exports from the EXPORT TRIE (dyld_info), same reader as the M2 gate:
    # nm -gU reads a different, larger table and must not stand in for it
    dyld_info_cmd=''
    if command -v dyld_info >/dev/null 2>&1; then
        dyld_info_cmd='dyld_info'
    elif xcrun --find dyld_info >/dev/null 2>&1; then
        dyld_info_cmd='xcrun dyld_info'
    else
        die 'dyld_info not found -- refusing to enumerate exports from nm, which reads a different table'
    fi
    raw="$(${dyld_info_cmd} -exports "${lib}" |
        awk '$1 ~ /^0x[0-9A-Fa-f]+$/ && NF >= 2 { print $2 }' | LC_ALL=C sort -u)"
    [ -n "${raw}" ] || die "the export trie of ${lib} is empty"
    stripped="$(printf '%s\n' "${raw}" | sed 's/^_//' | LC_ALL=C sort -u)"
    exports_list="$(printf '%s\n' "${stripped}" | grep '^webview_' || true)"
    [ -n "${exports_list}" ] || die 'no webview_* exports in the trie'
    other="$(printf '%s\n' "${stripped}" | grep -v '^webview_' | grep . || true)"
    if [ -n "${other}" ]; then
        # the ratified x86_64 allowance: weak libc++ RTTI records only -
        # RECORDED as a count, never folded into the export set and never
        # counted as drift by the aggregator
        not_rtti="$(printf '%s\n' "${other}" | grep -v '^_ZT[IS]' || true)"
        [ -z "${not_rtti}" ] ||
            die "non-RTTI extra export(s) in the trie: ${not_rtti}"
        extra_rtti="$(printf '%s\n' "${other}" | grep -c . || true)"
    else
        extra_rtti=0
    fi
    exports_json="$(printf '%s\n' "${exports_list}" | json_string_array)"

    clang_line="$(clang --version 2>/dev/null | head -n 1 || printf '<absent>')"
    cc_note="${clang_line} (dylib built by CMake + clang; exports re-enumerated from the export trie via dyld_info)"
    engine='WKWebView'

    # release layout, re-asserted: exactly the two products
    layout_listing="$(cd -- "${release}" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
    [ "${layout_listing}" = 'PWebReleasePas2js.app PWebReleaseReact.app ' ] ||
        die "release dir is not exactly the two products: [${layout_listing}]"
    release_layout='PASS'

    # no-listener: R11 lifetime sampling recorded by the release gate, plus
    # the M20 zero-transport probe's own run log
    grep -q 'CAP7M2 product=react .*listeners=0' "${measurements}" ||
        die 'measurements carry no react listeners=0 record (R11)'
    grep -q 'CAP7M2 product=pas2js .*listeners=0' "${measurements}" ||
        die 'measurements carry no pas2js listeners=0 record (R11)'
    nonet_log="${repo_root}/build/cap7m/nonetwork/nonetwork-run.log"
    [ -f "${nonet_log}" ] ||
        die 'M20 zero-transport run log missing -- check_cap7m_nonetwork.sh has not run in this workspace'
    grep -q 'CAP7M_PROBE_PASS' "${nonet_log}" ||
        die 'the M20 run log carries no CAP7M_PROBE_PASS marker'
    no_listener='PASS'
    no_listener_prov='runtime-gate (CAP-7M2 R11 lifetime lsof sampling + CAP-7M0 M20, this job)'

    # logical inventories: consume the release gate's manifests and
    # cross-check them against the inventory rows the same gate emitted
    for f in manifest-react.txt manifest-pas2js.txt \
             inventory-react.txt inventory-pas2js.txt; do
        [ -f "${apps}/${f}" ] ||
            die "release artifact missing: ${apps}/${f} -- run test/cap7m/run_cap7m_release.sh first"
    done
    react_inventory_sha="$(file_sha "${apps}/manifest-react.txt")"
    p2j_inventory_sha="$(file_sha "${apps}/manifest-pas2js.txt")"
    inv_react_sha="$(inventory_read "${apps}/inventory-react.txt" logical_inventory_sha256)"
    inv_p2j_sha="$(inventory_read "${apps}/inventory-pas2js.txt" logical_inventory_sha256)"
    [ "${react_inventory_sha}" = "${inv_react_sha}" ] ||
        die "react manifest hash ${react_inventory_sha} != inventory row ${inv_react_sha}"
    [ "${p2j_inventory_sha}" = "${inv_p2j_sha}" ] ||
        die "pas2js manifest hash ${p2j_inventory_sha} != inventory row ${inv_p2j_sha}"
    react_pwb_sha="$(inventory_read "${apps}/inventory-react.txt" app_pwb_sha256)"
    bundle_protocol="$(bundle_protocol_of \
        "${release}/PWebReleaseReact.app/Contents/Resources/app.pwb")"

    # runtime verdict fields + host-argument coverage from the release gate's
    # own measurements (the args were executed on macOS by CAP-7M2 itself:
    # LaunchServices --pweb-verdict R3, argv-beats-env R9 warm rerun, bad-arg
    # and R4 refusal-verdict rows)
    grep -q 'CAP7M2 product=react .*direct=pass warm=pass ls=pass' "${measurements}" ||
        die 'measurements carry no react direct/warm/ls PASS record'
    grep -q 'CAP7M2_AUTOCLOSE product=react .*argv_wins=yes' "${measurements}" ||
        die 'measurements carry no react argv_wins=yes record'
    grep -q 'CAP7M2_REFUSALS product=react .*bad_arg=pass refusal_verdict=pass' "${measurements}" ||
        die 'measurements carry no refusal-matrix PASS record'
    host_args='PASS'
    react_log="${apps}/direct-react-1.log"
    [ -f "${react_log}" ] || die "release run log missing: ${react_log}"
    grep -q '"secure":true' "${react_log}" ||
        die 'release run log carries no "secure":true page report'
    grep -Eq '"value":42([^0-9]|$)' "${react_log}" ||
        die 'release run log carries no anchored "value":42 page report'
    grep -Fq 'pweb://app' "${react_log}" ||
        die 'release run log never named the pweb://app origin'
    # CAP-8A runtime deny enforcement on BOTH macOS products: the shared
    # release host runs the same production policy, and both acceptance
    # pages (React SDK and pas2js SDK) carry the same Denied.Probe, so
    # each product's own run log must show the typed forbidden verdict -
    # an allow-all regression reports "denied":false (the probe 404s)
    grep -q '"denied":true' "${react_log}" ||
        die 'react release run log carries no "denied":true page report -- the production policy did not forbid the unmapped probe'
    p2j_log="${apps}/direct-pas2js-1.log"
    [ -f "${p2j_log}" ] || die "release run log missing: ${p2j_log}"
    grep -q '"denied":true' "${p2j_log}" ||
        die 'pas2js release run log carries no "denied":true page report -- the production policy did not forbid the unmapped probe'
    origin='pweb://app'
    secure='true'
    rpc='42'
    runtime_prov='runtime-gate (CAP-7M2 release gates, this job)'

    waivers='"signing/notarization out of scope for CAP-7 (ad-hoc local prep at most, recorded)", "sync scheme-serving only: stop_arrivals=0 recorded as a LIMITATION (deferred to CAP-12)", "cross-toolchain app.pwb identity is LOGICAL (compressed container bytes differ per toolchain by design)"'
    if [ "${arch}" = 'x86_64' ]; then
        waivers="${waivers}, \"x86_64 export trie carries ${extra_rtti} weak libc++ RTTI records beside the 17 (measured CAP-7M0 allowance, not drift)\""
    fi
    ;;

*)
    die "unsupported platform for this emitter: ${os_name}"
    ;;
esac

# --- CAP-8A capability-policy verdict + decision digest (both POSIX targets) --
# capability-policy.txt is written by the pwebtests CAP-8A suite that ran
# earlier in this job (run_cap7l_gates.sh / run_cap7m_gates.sh; a failed
# suite kills the job before this emitter). Its sha256 is the cross-target
# policy-decision digest the aggregator requires to be identical on all
# four targets; the file's own verdict line is required too.
cap_policy_file="${work}/capability-policy.txt"
[ -f "${cap_policy_file}" ] ||
    die 'capability-policy.txt missing -- the CAP-8A pwebtests suite has not run in this workspace'
head -n 1 "${cap_policy_file}" | grep -qx 'schema=1' ||
    die 'capability-policy.txt carries no schema=1 header'
tail -n 1 "${cap_policy_file}" | grep -qx 'verdict=PASS' ||
    die 'capability-policy.txt does not end in verdict=PASS'
capability_policy='PASS'
capability_policy_digest="$(file_sha "${cap_policy_file}")"
printf '[CAP-7F] capability_policy_digest: %s\n' "${capability_policy_digest}"

# --- CAP-8B navigation-security verdict + navigation-decision digest ---------
# navigation-policy.txt is written by the pwebtests CAP-8B suite that ran
# earlier in this job (run_cap7l_gates.sh / run_cap7m_gates.sh). Its sha256 is
# the cross-target navigation-decision digest the aggregator requires
# identical on all four targets; the file's own verdict line is required too.
nav_policy_file="${work}/navigation-policy.txt"
[ -f "${nav_policy_file}" ] ||
    die 'navigation-policy.txt missing -- the CAP-8B pwebtests suite has not run in this workspace'
head -n 1 "${nav_policy_file}" | grep -qx 'schema=1' ||
    die 'navigation-policy.txt carries no schema=1 header'
tail -n 1 "${nav_policy_file}" | grep -qx 'verdict=PASS' ||
    die 'navigation-policy.txt does not end in verdict=PASS'
navigation_policy_digest="$(file_sha "${nav_policy_file}")"
printf '[CAP-7F] navigation_policy_digest: %s\n' "${navigation_policy_digest}"

# navigation_security: the real-window matrix verdict, from the record
# test/cap8b/run_nav_matrix.sh wrote earlier in this job. On POSIX there is no
# SKIP - the display is real - so anything but PASS is a failure by then.
# The gate writes into ITS workspace (build/cap8b), not this emitter's.
nav_matrix_file="${repo_root}/build/cap8b/nav-matrix.json"
[ -f "${nav_matrix_file}" ] ||
    die 'nav-matrix.json missing -- the CAP-8B nav-matrix gate has not run in this workspace'
navigation_security="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${nav_matrix_file}" | head -n 1)"
case "${navigation_security}" in
    PASS | FAIL | SKIP) ;;
    *) die "nav-matrix.json carries an unexpected verdict: ${navigation_security}" ;;
esac
printf '[CAP-7F] navigation_security: %s\n' "${navigation_security}"

# ---------------------------- write the evidence -----------------------------
# every interpolated free-text value goes through json_escape: the toolchain
# banner lines especially are nobody's to promise quote-free
cc_note="$(json_escape "${cc_note}")"
engine_json="$(json_escape "${engine}")"
runtime_prov="$(json_escape "${runtime_prov}")"
no_listener_prov="$(json_escape "${no_listener_prov}")"
fpc_json="$(json_escape "${fpc_version}")"
surface_json="$(json_escape "${surface}")"
pin_json="$(json_escape "${webview_pin}")"
cat > "${work}/evidence.json" <<EOF
{
  "schema": 1,
  "target": "${target}",
  "os": "$(printf '%s' "${os_name}" | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/')",
  "arch": "${arch}",
  "fpc": "${fpc_json}",
  "cc": "${cc_note}",
  "webview_pin": "${pin_json}",
  "webview_surface": "${surface_json}",
  "engine": "${engine_json}",
  "exports": ${exports_json},
  "extra_exports_rtti": ${extra_rtti},
  "origin": "${origin}",
  "secure": "${secure}",
  "bundle_protocol": "${bundle_protocol}",
  "rpc_add_20_22": "${rpc}",
  "runtime_provenance": "${runtime_prov}",
  "host_args": "${host_args}",
  "capability_policy": "${capability_policy}",
  "capability_policy_digest": "${capability_policy_digest}",
  "navigation_security": "${navigation_security}",
  "navigation_policy_digest": "${navigation_policy_digest}",
  "release_layout": "${release_layout}",
  "no_listener": "${no_listener}",
  "no_listener_provenance": "${no_listener_prov}",
  "app_pwb_react_sha256": "${react_pwb_sha}",
  "logical_inventory_sha256_react": "${react_inventory_sha}",
  "logical_inventory_sha256_pas2js": "${p2j_inventory_sha}",
  "github_sha": "${github_sha}",
  "github_run_id": "${github_run_id}",
  "waivers": [${waivers}]
}
EOF

printf '[CAP-7F] evidence.json written for %s (host_args=%s, rtti_extras=%s)\n' \
    "${target}" "${host_args}" "${extra_rtti}"
