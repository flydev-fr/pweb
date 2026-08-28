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

# --- CAP-8C multi-principal security corpus + one canonical digest ----------
# The harness record is read FIRST and its overall verdict recorded VERBATIM
# (PASS|FAIL|SKIP) - the navigation_security shape: an honest FAIL goes into
# the evidence and the AGGREGATOR refuses it. On POSIX there is no SKIP (the
# display is real), but the emitter stays honest independent of step order.
mp_file="${repo_root}/build/cap8c/multiprincipal-${target}.json"
[ -f "${mp_file}" ] ||
    die "multiprincipal-${target}.json missing -- the CAP-8C gate has not run in this workspace"
security_corpus="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${mp_file}" | head -n 1)"
case "${security_corpus}" in
    PASS | FAIL | SKIP) ;;
    *) die "multiprincipal-${target}.json carries an unexpected verdict: ${security_corpus}" ;;
esac

# the defense-in-depth counters are REQUIRED whenever the harness actually
# ran (PASS or FAIL): a missing key must DIE, never default to a silent 0 -
# a renamed harness field would otherwise turn these into constant zeroes
# (fail-open). Only a runner-synthesized SKIP record may omit them.
mp_num() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${mp_file}" | head -n 1)"
    [ -n "${v}" ] ||
        die "multiprincipal record carries no '$1' counter -- refusing to default it to 0"
    printf '%s' "${v}"
}
if [ "${security_corpus}" != 'SKIP' ]; then
    cap8c_denied_soa=$(( $(mp_num denied_bridge_login_add) + $(mp_num denied_bridge_plugin_add) ))
    cap8c_opener_nonmain=$(( $(mp_num opener_login) + $(mp_num opener_plugin) + $(mp_num opener_unexpected) ))
    if grep -q '"secure_origin"[[:space:]]*:[[:space:]]*true' "${mp_file}"; then
        cap8c_secure_origin='true'
    elif grep -q '"secure_origin"[[:space:]]*:[[:space:]]*false' "${mp_file}"; then
        cap8c_secure_origin='false'
    else
        die "multiprincipal record carries no 'secure_origin' field -- refusing to default it"
    fi
else
    cap8c_denied_soa=0
    cap8c_opener_nonmain=0
    cap8c_secure_origin='false'
fi

# the canonical decision/counter corpus: its verdict=PASS trailer is required
# ONLY when the harness records PASS - an honest FAIL corpus carries its own
# verdict line and the aggregator refuses through the verdict field
corpus_file="${repo_root}/build/cap8c/security-corpus.txt"
if [ "${security_corpus}" = 'PASS' ]; then
    [ -f "${corpus_file}" ] ||
        die 'security-corpus.txt missing while the harness records PASS'
    head -n 1 "${corpus_file}" | grep -qx 'schema=1' ||
        die 'security-corpus.txt carries no schema=1 header'
    tail -n 1 "${corpus_file}" | grep -qx 'verdict=PASS' ||
        die 'security-corpus.txt does not end in verdict=PASS while the harness records PASS'
    security_corpus_digest="$(file_sha "${corpus_file}")"
elif [ -f "${corpus_file}" ]; then
    security_corpus_digest="$(file_sha "${corpus_file}")"
else
    security_corpus_digest='ABSENT'
fi
printf '[CAP-7F] security_corpus_digest: %s\n' "${security_corpus_digest}"
printf '[CAP-7F] security_corpus: %s (denied_soa=%s opener_nonmain=%s secure=%s)\n' \
    "${security_corpus}" "${cap8c_denied_soa}" "${cap8c_opener_nonmain}" "${cap8c_secure_origin}"

# --- CAP-9A QuickJS invocation-foundation corpus + one canonical digest -----
# Same honesty shape as the CAP-8C block: verdict recorded VERBATIM
# (PASS|FAIL - the harness is fully headless and never SKIPs), required
# counters that DIE rather than default to 0, and the corpus digest as the
# sha256 of build/cap9a/quickjs-corpus.txt, identical on all four targets
# by construction.
qf_file="${repo_root}/build/cap9a/quickjsfoundation-${target}.json"
[ -f "${qf_file}" ] ||
    die "quickjsfoundation-${target}.json missing -- the CAP-9A gate has not run in this workspace"
quickjs_corpus="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${qf_file}" | head -n 1)"
case "${quickjs_corpus}" in
    PASS | FAIL) ;;
    *) die "quickjsfoundation-${target}.json carries an unexpected verdict: ${quickjs_corpus}" ;;
esac
qf_num() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${qf_file}" | head -n 1)"
    [ -n "${v}" ] ||
        die "quickjsfoundation record carries no '$1' counter -- refusing to default it to 0"
    printf '%s' "${v}"
}
cap9a_denied_bridge="$(qf_num denied_bridge_add)"
cap9a_opener_reached="$(qf_num opener_reached)"

qf_corpus_file="${repo_root}/build/cap9a/quickjs-corpus.txt"
if [ "${quickjs_corpus}" = 'PASS' ]; then
    [ -f "${qf_corpus_file}" ] ||
        die 'quickjs-corpus.txt missing while the harness records PASS'
    head -n 1 "${qf_corpus_file}" | grep -qx 'schema=1' ||
        die 'quickjs-corpus.txt carries no schema=1 header'
    tail -n 1 "${qf_corpus_file}" | grep -qx 'verdict=PASS' ||
        die 'quickjs-corpus.txt does not end in verdict=PASS while the harness records PASS'
    quickjs_corpus_digest="$(file_sha "${qf_corpus_file}")"
elif [ -f "${qf_corpus_file}" ]; then
    quickjs_corpus_digest="$(file_sha "${qf_corpus_file}")"
else
    quickjs_corpus_digest='ABSENT'
fi
printf '[CAP-7F] quickjs_corpus_digest: %s\n' "${quickjs_corpus_digest}"
printf '[CAP-7F] quickjs_corpus: %s (denied_bridge=%s opener_reached=%s)\n' \
    "${quickjs_corpus}" "${cap9a_denied_bridge}" "${cap9a_opener_reached}"

# --- CAP-9B1 QuickJS package/module-loader corpus + one canonical digest ----
# Identical honesty shape to the CAP-9A block above: verdict recorded
# VERBATIM (the harness is headless and never SKIPs), required counters
# that DIE rather than default to 0, and the digest as the sha256 of
# build/cap9b1/quickjs-package-corpus.txt - identical on all four targets
# by construction, because every fixture is generated in-process from byte
# constants and no checkout can change what is hashed.
qp_file="${repo_root}/build/cap9b1/quickjspackage-${target}.json"
[ -f "${qp_file}" ] ||
    die "quickjspackage-${target}.json missing -- the CAP-9B1 gate has not run in this workspace"
quickjs_package_corpus="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${qp_file}" | head -n 1)"
case "${quickjs_package_corpus}" in
    PASS | FAIL) ;;
    *) die "quickjspackage-${target}.json carries an unexpected verdict: ${quickjs_package_corpus}" ;;
esac
qp_num() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${qp_file}" | head -n 1)"
    [ -n "${v}" ] ||
        die "quickjspackage record carries no '$1' counter -- refusing to default it to 0"
    printf '%s' "${v}"
}
cap9b1_loadtime_bridge="$(qp_num loadtime_bridge)"
cap9b1_loader_wrong_thread="$(qp_num loader_wrong_thread)"
cap9b1_store_wrong_thread="$(qp_num store_wrong_thread)"
cap9b1_denied_bridge="$(qp_num denied_bridge_add)"
# promoted so the AGGREGATE can cross-check them, not only the harness's
# own verdict
cap9b1_source_open="$(qp_num source_open_after_failure)"
cap9b1_opener_reached="$(qp_num opener_reached)"

qp_corpus_file="${repo_root}/build/cap9b1/quickjs-package-corpus.txt"
if [ "${quickjs_package_corpus}" = 'PASS' ]; then
    [ -f "${qp_corpus_file}" ] ||
        die 'quickjs-package-corpus.txt missing while the harness records PASS'
    head -n 1 "${qp_corpus_file}" | grep -qx 'schema=1' ||
        die 'quickjs-package-corpus.txt carries no schema=1 header'
    tail -n 1 "${qp_corpus_file}" | grep -qx 'verdict=PASS' ||
        die 'quickjs-package-corpus.txt does not end in verdict=PASS while the harness records PASS'
    quickjs_package_digest="$(file_sha "${qp_corpus_file}")"
elif [ -f "${qp_corpus_file}" ]; then
    # the FAIL direction matters too: a corpus still carrying
    # verdict=PASS beside a FAIL record is a disagreement that would
    # otherwise be hashed into the digest and sail through
    tail -n 1 "${qp_corpus_file}" | grep -qx 'verdict=PASS' &&
        die 'quickjs-package-corpus.txt ends in verdict=PASS while the harness records FAIL'
    quickjs_package_digest="$(file_sha "${qp_corpus_file}")"
else
    quickjs_package_digest='ABSENT'
fi
printf '[CAP-7F] quickjs_package_digest: %s\n' "${quickjs_package_digest}"
printf '[CAP-7F] quickjs_package_corpus: %s (loadtime_bridge=%s loader_wrong_thread=%s store_wrong_thread=%s)\n' \
    "${quickjs_package_corpus}" "${cap9b1_loadtime_bridge}" \
    "${cap9b1_loader_wrong_thread}" "${cap9b1_store_wrong_thread}"

# --- CAP-9B2 QuickJS lifecycle/reload corpus + one canonical digest ---------
# Identical honesty shape to the two blocks above: verdict recorded
# VERBATIM (the harness is headless and never SKIPs), required counters
# that DIE rather than default to 0, and the digest as the sha256 of
# build/cap9b2/quickjs-lifecycle-corpus.txt - identical on all four
# targets because every fixture is generated in-process and every
# cross-thread ordering is a rendezvous rather than a delay.
ql_file="${repo_root}/build/cap9b2/quickjslifecycle-${target}.json"
[ -f "${ql_file}" ] ||
    die "quickjslifecycle-${target}.json missing -- the CAP-9B2 gate has not run in this workspace"
quickjs_lifecycle_corpus="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${ql_file}" | head -n 1)"
case "${quickjs_lifecycle_corpus}" in
    PASS | FAIL) ;;
    *) die "quickjslifecycle-${target}.json carries an unexpected verdict: ${quickjs_lifecycle_corpus}" ;;
esac
ql_num() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${ql_file}" | head -n 1)"
    [ -n "${v}" ] ||
        die "quickjslifecycle record carries no '$1' counter -- refusing to default it to 0"
    printf '%s' "${v}"
}
cap9b2_two_active="$(ql_num two_active_generations)"
cap9b2_stale="$(ql_num stale_completion)"
cap9b2_reload_lost_old="$(ql_num reload_lost_old)"
cap9b2_export_wrong_thread="$(ql_num export_wrong_thread)"
cap9b2_quarantine_unexpected="$(ql_num quarantine_unexpected)"
# EXACTLY 1: the deliberately injected last-resort row. Zero would mean
# the quarantine path was never exercised at all.
cap9b2_quarantine_injected="$(ql_num quarantine_injected)"
cap9b2_denied_bridge="$(ql_num denied_bridge_add)"
cap9b2_opener_reached="$(ql_num opener_reached)"

ql_corpus_file="${repo_root}/build/cap9b2/quickjs-lifecycle-corpus.txt"
if [ "${quickjs_lifecycle_corpus}" = 'PASS' ]; then
    [ -f "${ql_corpus_file}" ] ||
        die 'quickjs-lifecycle-corpus.txt missing while the harness records PASS'
    head -n 1 "${ql_corpus_file}" | grep -qx 'schema=1' ||
        die 'quickjs-lifecycle-corpus.txt carries no schema=1 header'
    tail -n 1 "${ql_corpus_file}" | grep -qx 'verdict=PASS' ||
        die 'quickjs-lifecycle-corpus.txt does not end in verdict=PASS while the harness records PASS'
    quickjs_lifecycle_digest="$(file_sha "${ql_corpus_file}")"
elif [ -f "${ql_corpus_file}" ]; then
    tail -n 1 "${ql_corpus_file}" | grep -qx 'verdict=PASS' &&
        die 'quickjs-lifecycle-corpus.txt ends in verdict=PASS while the harness records FAIL'
    quickjs_lifecycle_digest="$(file_sha "${ql_corpus_file}")"
else
    quickjs_lifecycle_digest='ABSENT'
fi
printf '[CAP-7F] quickjs_lifecycle_digest: %s\n' "${quickjs_lifecycle_digest}"
printf '[CAP-7F] quickjs_lifecycle_corpus: %s (two_active=%s stale=%s reload_lost_old=%s quarantine=%s/%s)\n' \
    "${quickjs_lifecycle_corpus}" "${cap9b2_two_active}" "${cap9b2_stale}" \
    "${cap9b2_reload_lost_old}" "${cap9b2_quarantine_injected}" \
    "${cap9b2_quarantine_unexpected}"

# --- CAP-9C1 QuickJS release-package corpus + one canonical digest ----------
# Same honesty shape as the three blocks above, with ONE deliberate
# difference worth stating rather than hiding: the archive's SHA-256, its
# byte length and the generated registry's digest are recorded but are NOT
# four-way compared. CAP-6/CAP-7L already MEASURED that the mORMot static
# DEFLATE object emits different bytes for x86_64-win64 and x86_64-linux
# (pweb.test.bundle.pas pins app.pwb's golden hash per toolchain for
# exactly that reason), so requiring archive equality across targets would
# be requiring something untrue. What IS compared is the SEMANTIC corpus
# and the inventory digest - canonical names, uncompressed lengths and
# content digests - which are toolchain-independent.
qr_file="${repo_root}/build/cap9c1/quickjsrelease-${target}.json"
[ -f "${qr_file}" ] ||
    die "quickjsrelease-${target}.json missing -- the CAP-9C1 gate has not run in this workspace"
quickjs_release_corpus="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${qr_file}" | head -n 1)"
case "${quickjs_release_corpus}" in
    PASS | FAIL) ;;
    *) die "quickjsrelease-${target}.json carries an unexpected verdict: ${quickjs_release_corpus}" ;;
esac
qr_num() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${qr_file}" | head -n 1)"
    [ -n "${v}" ] ||
        die "quickjsrelease record carries no '$1' counter -- refusing to default it to 0"
    printf '%s' "${v}"
}
qr_hex() {
    # LENIENT on purpose: on a FAIL record these may be empty, and dying
    # here would mask the harness failure that actually matters. The
    # PASS-guarded shape check below is what refuses a malformed digest.

    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([0-9a-f]*\)\".*/\1/p" \
        "${qr_file}" | head -n 1)"
    printf '%s' "${v}"
}
cap9c1_browser_arrivals="$(qr_num browser_store_arrivals)"
cap9c1_denied_bridge="$(qr_num denied_bridge_add)"
cap9c1_opener_reached="$(qr_num opener_reached)"
cap9c1_tamper_started="$(qr_num tamper_started)"
cap9c1_cwd_dependency="$(qr_num cwd_dependency)"
# reported per target, never compared across them
cap9c1_package_sha="$(qr_hex package_sha256)"
cap9c1_package_bytes="$(qr_num package_bytes)"
cap9c1_registry_sha="$(qr_hex registry_sha256)"
# compared across targets: the archive's MEANING, not its bytes
cap9c1_inventory_digest="$(qr_hex inventory_digest)"
if [ "${quickjs_release_corpus}" = 'PASS' ]; then
    for d in "${cap9c1_inventory_digest}" "${cap9c1_package_sha}" \
             "${cap9c1_registry_sha}"; do
        case "${d}" in
            ????????????????????????????????????????????????????????????????) ;;
            *) die "quickjsrelease carries a malformed digest: '${d}'" ;;
        esac
    done
fi

qr_corpus_file="${repo_root}/build/cap9c1/quickjs-release-corpus.txt"
if [ "${quickjs_release_corpus}" = 'PASS' ]; then
    [ -f "${qr_corpus_file}" ] ||
        die 'quickjs-release-corpus.txt missing while the harness records PASS'
    head -n 1 "${qr_corpus_file}" | grep -qx 'schema=1' ||
        die 'quickjs-release-corpus.txt carries no schema=1 header'
    tail -n 1 "${qr_corpus_file}" | grep -qx 'verdict=PASS' ||
        die 'quickjs-release-corpus.txt does not end in verdict=PASS while the harness records PASS'
    # the staged release payload must exist beside the evidence: a green
    # corpus with no artifacts would be a gate that proved nothing shipped
    for staged in plugins.zip pweb.quickjs.registry.inc LICENSE.quickjs \
                  package-inventory.txt package-build-info.txt; do
        [ -f "${repo_root}/build/quickjs-release/${staged}" ] ||
            die "the CAP-9C1 release staging is missing ${staged} while the harness records PASS"
    done
    quickjs_release_digest="$(file_sha "${qr_corpus_file}")"
elif [ -f "${qr_corpus_file}" ]; then
    tail -n 1 "${qr_corpus_file}" | grep -qx 'verdict=PASS' &&
        die 'quickjs-release-corpus.txt ends in verdict=PASS while the harness records FAIL'
    quickjs_release_digest="$(file_sha "${qr_corpus_file}")"
else
    quickjs_release_digest='ABSENT'
fi
printf '[CAP-7F] quickjs_release_digest: %s\n' "${quickjs_release_digest}"
printf '[CAP-7F] quickjs_release_corpus: %s (browser_store=%s denied_bridge=%s tamper_started=%s cwd=%s)\n' \
    "${quickjs_release_corpus}" "${cap9c1_browser_arrivals}" \
    "${cap9c1_denied_bridge}" "${cap9c1_tamper_started}" \
    "${cap9c1_cwd_dependency}"
printf '[CAP-7F] cap9c1 package sha256=%s bytes=%s (per-target, reported not compared)\n' \
    "${cap9c1_package_sha}" "${cap9c1_package_bytes}"

# --- CAP-9C2 plugin-enabled GUI corpus + one canonical digest ---------------
# The shard's whole point is that the SAME architecture answers on all four
# targets, so unlike the C1 block above there is nothing here that is
# reported-but-not-compared: every field is a semantic verdict. The one
# per-machine fact - whether a file symlink could be created for the
# reparse-point negative - is carried as its own field so the aggregator
# can refuse a waiver instead of hashing one into the digest.
case "${target}" in
    linux-x86_64)
        cap9c2_release_exe="${repo_root}/dist/linux-x64/quickjs-release/quickjsapp" ;;
    macos-x86_64)
        cap9c2_release_exe="${repo_root}/dist/macos-x86_64/PWebQuickJS.app/Contents/MacOS/quickjsapp" ;;
    macos-arm64)
        cap9c2_release_exe="${repo_root}/dist/macos-arm64/PWebQuickJS.app/Contents/MacOS/quickjsapp" ;;
    *) die "CAP-9C2: no release layout is defined for target ${target}" ;;
esac
qg_file="${repo_root}/build/cap9c2/quickjsgui-${target}.json"
[ -f "${qg_file}" ] ||
    die "quickjsgui-${target}.json missing -- the CAP-9C2 gate has not run in this workspace"
quickjs_gui_corpus="$(sed -n 's/.*"overall"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' \
    "${qg_file}" | head -n 1)"
case "${quickjs_gui_corpus}" in
    PASS | FAIL) ;;
    *) die "quickjsgui-${target}.json carries an unexpected verdict: ${quickjs_gui_corpus}" ;;
esac
qg_num() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${qg_file}" | head -n 1)"
    [ -n "${v}" ] ||
        die "quickjsgui record carries no '$1' counter -- refusing to default it to 0"
    printf '%s' "${v}"
}
qg_str() {
    local v
    v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${qg_file}" | head -n 1)"
    printf '%s' "${v}"
}
cap9c2_listeners="$(qg_num listeners)"
cap9c2_reparse="$(qg_str negative_reparse)"
cap9c2_license="$(qg_str license_quickjs_sha256)"

# The CAP-9C2 semantic gate names, in ONE place - the same list the ps1
# emitter and the aggregator's negative self-test carry, so a gate cannot
# be added to the corpus and forgotten by the thing that refuses it. The
# aggregator's rule is deliberately trivial: EVERY field must read exactly
# 'yes' on EVERY target.
cap9c2_gate_fields='ui_rendered ui_add quickjs_add reporting_code
reporting_status reporting_soa_count reporting_denied_bridge opener_reached
same_scheduler same_policy same_bridge same_server
browser_plugin_store_arrivals quickjs_app_store_arrivals
browser_plugin_script_marker raw_channel_source_bytes
quickjs_window_absent quickjs_document_absent
quickjs_webkit_channel_absent quickjs_webview2_channel_absent
quickjs_raw_webview_invoke_absent concurrent_overlap
no_cross_delivery plugin_archive_verified
plugin_inventory_verified neighbour_survived_timeout
ui_survived_timeout reload_generation_changed clean_shutdown
release_layout hostile_running hostile_failed'
cap9c2_gates_json=''
for gate in ${cap9c2_gate_fields}; do
    value="$(qg_str "${gate}")"
    if [ "${quickjs_gui_corpus}" = 'PASS' ] && [ -z "${value}" ]; then
        die "quickjsgui record carries no '${gate}' gate -- refusing to default it"
    fi
    if [ -n "${cap9c2_gates_json}" ]; then
        cap9c2_gates_json="${cap9c2_gates_json},"
    fi
    cap9c2_gates_json="${cap9c2_gates_json}
    \"${gate}\": \"${value}\""
done

qg_corpus_file="${repo_root}/build/cap9c2/quickjs-gui-corpus.txt"
if [ "${quickjs_gui_corpus}" = 'PASS' ]; then
    [ -f "${qg_corpus_file}" ] ||
        die 'quickjs-gui-corpus.txt missing while the gate records PASS'
    head -n 1 "${qg_corpus_file}" | grep -qx 'schema=1' ||
        die 'quickjs-gui-corpus.txt carries no schema=1 header'
    tail -n 1 "${qg_corpus_file}" | grep -qx 'verdict=PASS' ||
        die 'quickjs-gui-corpus.txt does not end in verdict=PASS while the gate records PASS'
    # a green corpus with no assembled release would be a gate that proved
    # nothing shipped
    [ -x "${cap9c2_release_exe}" ] ||
        die "the CAP-9C2 release layout is missing its executable while the gate records PASS"
    quickjs_gui_digest="$(file_sha "${qg_corpus_file}")"
elif [ -f "${qg_corpus_file}" ]; then
    tail -n 1 "${qg_corpus_file}" | grep -qx 'verdict=PASS' &&
        die 'quickjs-gui-corpus.txt ends in verdict=PASS while the gate records FAIL'
    quickjs_gui_digest="$(file_sha "${qg_corpus_file}")"
else
    quickjs_gui_digest='ABSENT'
fi
printf '[CAP-7F] quickjs_gui_digest: %s\n' "${quickjs_gui_digest}"
printf '[CAP-7F] quickjs_gui_corpus: %s (listeners=%s reparse=%s)\n' \
    "${quickjs_gui_corpus}" "${cap9c2_listeners}" "${cap9c2_reparse}"

# ---------------------------- CAP-10A: the CLI foundation --------------------
#
# THREE compared fields and one must-PASS verdict. What is compared is
# deliberately narrow, because most of what a doctor reports is a fact about
# the MACHINE, and comparing those across four runners would be comparing the
# runners: cli_digest is the decision corpus of pure logic over injected
# inputs, doctor_schema_digest is the document SHAPE plus the ordered row set
# and each row's severity, and cli_version_line is the one line that proves
# the same CLI ran everywhere. The per-host observations travel in their own
# field and are never compared.
cli_file="${repo_root}/build/cap10a/cli-${target}.json"
[ -f "${cli_file}" ] ||
    die "cli-${target}.json missing -- the CAP-10A gate has not run in this workspace"
cli_str() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${cli_file}" | head -n 1
}
cli_num() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${cli_file}" | head -n 1
}
cli_corpus="$(cli_str cli_corpus)"
case "${cli_corpus}" in
    PASS | FAIL) ;;
    *) die "cli-${target}.json carries an unexpected verdict: ${cli_corpus}" ;;
esac
cli_digest="$(cli_str cli_digest)"
doctor_schema_digest="$(cli_str doctor_schema_digest)"
cli_version_line="$(cli_str cli_version_line)"
cli_exit_taxonomy="$(cli_str cli_exit_taxonomy)"
doctor_no_mutation="$(cli_str doctor_no_mutation)"
doctor_json_deterministic="$(cli_str doctor_json_deterministic)"
doctor_checks="$(cli_num doctor_checks)"
[ -n "${doctor_checks}" ] || doctor_checks=0
if [ "${cli_corpus}" = 'PASS' ]; then
    # a green verdict with an empty digest would prove nothing, and an empty
    # string compares equal to another empty string on four targets
    for pair in "cli_digest=${cli_digest}" \
                "doctor_schema_digest=${doctor_schema_digest}" \
                "cli_version_line=${cli_version_line}"; do
        case "${pair}" in
            *=) die "the CAP-10A record records PASS with an empty ${pair%%=*}" ;;
        esac
    done
    [ "${doctor_checks}" != '0' ] ||
        die 'the CAP-10A record records PASS with zero doctor rows'
fi
printf '[CAP-7F] cli_digest: %s\n' "${cli_digest}"
printf '[CAP-7F] doctor_schema_digest: %s\n' "${doctor_schema_digest}"
printf '[CAP-7F] cli_corpus: %s (exit_taxonomy=%s no_mutation=%s deterministic=%s checks=%s)\n' \
    "${cli_corpus}" "${cli_exit_taxonomy}" "${doctor_no_mutation}" \
    "${doctor_json_deterministic}" "${doctor_checks}"

# ---------------------------- CAP-10B0: the scaffold engine ------------------
#
# FIVE compared digests and four must-PASS verdicts. Unlike plugins.zip, the
# template PACK ITSELF is compared: CAP-9C1 could not do that because
# mORMot's static DEFLATE object emits different bytes per toolchain
# (MEASURED in CAP-6/CAP-7L), and this pack stores every entry instead, so
# no compressor is reached and the archive is a pure function of names,
# bytes, CRC-32s and a fixed timestamp. If that stops being true the matrix
# says so here rather than nowhere.
#
# template_modes_applicable is deliberately NOT compared: POSIX has file
# modes and Windows does not, which is a fact about the platform and travels
# with the per-target record exactly as the doctor observations do.
tpl_file="${repo_root}/build/cap10b0/tpl-${target}.json"
[ -f "${tpl_file}" ] ||
    die "tpl-${target}.json missing -- the CAP-10B0 gate has not run in this workspace"
tpl_str() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${tpl_file}" | head -n 1
}
tpl_num() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${tpl_file}" | head -n 1
}
template_corpus="$(tpl_str template_corpus)"
case "${template_corpus}" in
    PASS | FAIL) ;;
    *) die "tpl-${target}.json carries an unexpected verdict: ${template_corpus}" ;;
esac
template_digest="$(tpl_str template_digest)"
template_pack_digest="$(tpl_str template_pack_digest)"
template_pack_bytes="$(tpl_num template_pack_bytes)"
[ -n "${template_pack_bytes}" ] || template_pack_bytes=0
template_pack_schema="$(tpl_str template_pack_schema)"
template_semantic_digest="$(tpl_str template_semantic_digest)"
template_registry_digest="$(tpl_str template_registry_digest)"
template_deterministic="$(tpl_str template_deterministic)"
template_source_gate="$(tpl_str template_source_gate)"
template_offline="$(tpl_str template_offline)"
template_create_present="$(tpl_str create_present)"
template_modes="$(tpl_str template_modes_applicable)"
template_file_count="$(tpl_str template_file_count)"
template_refusals="$(tpl_num template_refusals)"
[ -n "${template_refusals}" ] || template_refusals=0
network_calls="$(tpl_num network_calls)"
[ -n "${network_calls}" ] || network_calls=0
package_manager_calls="$(tpl_num package_manager_calls)"
[ -n "${package_manager_calls}" ] || package_manager_calls=0
if [ "${template_corpus}" = 'PASS' ]; then
    # a green verdict with an empty digest would prove nothing, and an empty
    # string compares equal to another empty string on four targets
    for pair in "template_digest=${template_digest}" \
                "template_pack_digest=${template_pack_digest}" \
                "template_semantic_digest=${template_semantic_digest}" \
                "template_registry_digest=${template_registry_digest}"; do
        case "${pair}" in
            *=) die "the CAP-10B0 record records PASS with an empty ${pair%%=*}" ;;
        esac
    done
    [ "${template_refusals}" = '7' ] ||
        die "the CAP-10B0 record records PASS with ${template_refusals} builder refusals, expected 7"
    [ "${network_calls}" = '0' ] ||
        die 'the CAP-10B0 record records a network call'
    [ "${package_manager_calls}" = '0' ] ||
        die 'the CAP-10B0 record records a package-manager call'
fi
printf '[CAP-7F] template_digest: %s\n' "${template_digest}"
printf '[CAP-7F] template_pack_digest: %s\n' "${template_pack_digest}"
printf '[CAP-7F] template_corpus: %s (deterministic=%s source_gate=%s offline=%s create_present=%s refusals=%s files=%s)\n' \
    "${template_corpus}" "${template_deterministic}" \
    "${template_source_gate}" "${template_offline}" \
    "${template_create_present}" "${template_refusals}" "${template_file_count}"

# --- CAP-10B1: the public create command and the React scaffold --------------
#
# TWO records, because they are two different kinds of claim and only one of
# them needs a toolchain: cli-<target>.json is headless (the advertised
# surface, the refusal matrix, the public pack, and a project created three
# times from three different working directories and required to be
# byte-identical), and proof-<target>.json is the build proof (npm, FPC, a
# real window, and the page's own report of what it observed).
#
# The COMPARED fields are the ones that are a function of the inputs alone.
# The pack BYTES travel per target and are reported side by side rather than
# compared, for the ZIP_OS reason CAP-10B0 measured.
b1_file="${repo_root}/build/cap10b1/cli-${target}.json"
proof_file="${repo_root}/build/cap10b1/proof-${target}.json"
[ -f "${b1_file}" ] ||
    die "cli-${target}.json missing -- the CAP-10B1 gates have not run in this workspace"
[ -f "${proof_file}" ] ||
    die "proof-${target}.json missing -- the CAP-10B1 build proof has not run in this workspace"
b1_str() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${b1_file}" | head -n 1
}
b1_num() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${b1_file}" | head -n 1
}
pf_str() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${proof_file}" | head -n 1
}
pf_num() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${proof_file}" | head -n 1
}
create_corpus="$(b1_str create_corpus)"
proof_corpus="$(pf_str proof_corpus)"
for v in "${create_corpus}" "${proof_corpus}"; do
    case "${v}" in
        PASS | FAIL) ;;
        *) die "the CAP-10B1 records carry an unexpected verdict: ${v}" ;;
    esac
done
# CAP-10B2 renamed this: the CAP-10B1 gate used to emit `advertised_ui` with
# one value and now emits `supported_uis` with the whole set. Reading the old
# name here after the rename gave an empty string, and the empty-digest guard
# below caught it on the first hosted run - which is the guard doing exactly
# what it exists for.
b1_supported_uis="$(b1_str supported_uis)"
create_help_digest="$(b1_str create_help_digest)"
create_help_bytes="$(b1_num create_help_bytes)"
[ -n "${create_help_bytes}" ] || create_help_bytes=0
create_stdout_digest="$(b1_str create_stdout_digest)"
create_refusals="$(b1_num create_refusals)"; [ -n "${create_refusals}" ] || create_refusals=0
create_no_partial="$(b1_str create_no_partial)"
create_deterministic="$(b1_str create_deterministic)"
public_pack_digest="$(b1_str public_pack_digest)"
public_pack_bytes="$(b1_num public_pack_bytes)"; [ -n "${public_pack_bytes}" ] || public_pack_bytes=0
public_semantic_digest="$(b1_str public_semantic_digest)"
public_registry_digest="$(b1_str public_registry_digest)"
public_pack_deterministic="$(b1_str public_pack_deterministic)"
public_file_count="$(b1_str public_file_count)"
generated_inventory_digest="$(b1_str generated_inventory_digest)"
generated_inventory_exact="$(b1_str generated_inventory_exact)"
generated_pweb_json_digest="$(b1_str generated_pweb_json_digest)"
generated_package_lock_digest="$(b1_str generated_package_lock_digest)"
generated_file_count="$(b1_num generated_file_count)"; [ -n "${generated_file_count}" ] || generated_file_count=0
generated_total_bytes="$(b1_num generated_total_bytes)"; [ -n "${generated_total_bytes}" ] || generated_total_bytes=0
generated_no_host_path="$(b1_str generated_no_host_path)"
doctor_result="$(b1_str doctor_result)"
generated_tree_digest="$(pf_str generated_tree_digest)"
generated_tree_unchanged="$(pf_str generated_tree_unchanged)"
frontend_typecheck="$(pf_str frontend_typecheck)"
frontend_build="$(pf_str frontend_build)"
frontend_no_dev_code="$(pf_str frontend_no_dev_code)"
frontend_transport_clean="$(pf_str frontend_transport_clean)"
runtime_from_sdk_root="$(pf_str runtime_from_sdk_root)"
native_build="$(pf_str native_build)"
secure_origin="$(pf_str secure_origin)"
rpc_result="$(pf_num rpc_result)"; [ -n "${rpc_result}" ] || rpc_result=0
error_mapping="$(pf_str error_mapping)"
listener_count="$(pf_num listener_count)"; [ -n "${listener_count}" ] || listener_count=0
raw_primitive_used="$(pf_str raw_primitive_used)"
loose_assets_used="$(pf_str loose_assets_used)"
if [ "${create_corpus}" = 'PASS' ] && [ "${proof_corpus}" = 'PASS' ]; then
    # a green verdict with an empty digest is a proof of nothing, and an
    # empty string compares equal to another empty string on four targets
    for pair in "public_semantic_digest=${public_semantic_digest}" \
                "generated_inventory_digest=${generated_inventory_digest}" \
                "generated_pweb_json_digest=${generated_pweb_json_digest}" \
                "generated_package_lock_digest=${generated_package_lock_digest}" \
                "supported_uis=${b1_supported_uis}"; do
        case "${pair}" in
            *=) die "the CAP-10B1 record records PASS with an empty ${pair%%=*}" ;;
        esac
    done
    [ "${rpc_result}" = '42' ] ||
        die "the CAP-10B1 build proof records PASS with rpc_result=${rpc_result}"
    [ "${listener_count}" = '0' ] ||
        die 'the CAP-10B1 build proof records a listening socket'
fi
printf '[CAP-10B1] create_corpus: %s (ui=%s refusals=%s files=%s doctor=%s) proof_corpus: %s (rpc=%s listeners=%s)\n' \
    "${create_corpus}" "${b1_supported_uis}" "${create_refusals}" \
    "${generated_file_count}" "${doctor_result}" "${proof_corpus}" \
    "${rpc_result}" "${listener_count}"

# ------------------------- CAP-10B2: the Pas2JS scaffold ---------------------
#
# Two records again, and the same split as CAP-10B1's: cli-<target>.json is
# the headless create matrix (both UIs created, the refusal set including the
# one whose category moved, three working directories required to agree, the
# real doctor on both projects) and proof-<target>.json is the build proof
# (the pinned Pas2JS, the static output, app.pwb, a real window, and the
# page's own report).
#
# `advertised_ui` is GONE from the CAP-10B1 record and `supported_uis` has
# taken its place: one frontend was a value, two are a SET, and a set needs
# one canonical order (bytewise) so four targets compare membership rather
# than presentation.
b2_file="${repo_root}/build/cap10b2/cli-${target}.json"
b2_proof="${repo_root}/build/cap10b2/proof-${target}.json"
[ -f "${b2_file}" ] ||
    die "cap10b2/cli-${target}.json missing -- the CAP-10B2 gates have not run in this workspace"
[ -f "${b2_proof}" ] ||
    die "cap10b2/proof-${target}.json missing -- the CAP-10B2 build proof has not run in this workspace"
b2_str() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${b2_file}" | head -n 1
}
b2_num() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${b2_file}" | head -n 1
}
b2p_str() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "${b2_proof}" | head -n 1
}
b2p_num() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "${b2_proof}" | head -n 1
}
pas2js_create_corpus="$(b2_str pas2js_create_corpus)"
pas2js_proof_corpus="$(b2p_str pas2js_proof_corpus)"
for v in "${pas2js_create_corpus}" "${pas2js_proof_corpus}"; do
    case "${v}" in
        PASS | FAIL) ;;
        *) die "the CAP-10B2 records carry an unexpected verdict: ${v}" ;;
    esac
done
supported_uis="$(b2_str supported_uis)"
# TWO GATES PARSE THE SAME HELP TEXT and both emit the set they read out of
# it. Nothing had required them to agree, so a CAP-10B1 record and a
# CAP-10B2 record could have carried two different advertised sets into one
# evidence file, of which only the second travelled.
[ "${b1_supported_uis}" = "${supported_uis}" ] ||
    die "the CAP-10B1 record advertises '${b1_supported_uis}' and the CAP-10B2 record '${supported_uis}'"
pas2js_create_refusals="$(b2_num pas2js_create_refusals)"
[ -n "${pas2js_create_refusals}" ] || pas2js_create_refusals=0
pas2js_no_partial="$(b2_str pas2js_no_partial)"
pas2js_create_deterministic="$(b2_str pas2js_create_deterministic)"
pas2js_create_stdout_digest="$(b2_str pas2js_create_stdout_digest)"
pas2js_generated_inventory_digest="$(b2_str pas2js_generated_inventory_digest)"
pas2js_generated_inventory_exact="$(b2_str pas2js_generated_inventory_exact)"
pas2js_generated_file_count="$(b2_num pas2js_generated_file_count)"
[ -n "${pas2js_generated_file_count}" ] || pas2js_generated_file_count=0
pas2js_generated_total_bytes="$(b2_num pas2js_generated_total_bytes)"
[ -n "${pas2js_generated_total_bytes}" ] || pas2js_generated_total_bytes=0
pas2js_pweb_json_digest="$(b2_str pas2js_pweb_json_digest)"
pas2js_frontend_source_digest="$(b2_str pas2js_frontend_source_digest)"
pas2js_generated_no_host_path="$(b2_str pas2js_generated_no_host_path)"
react_generated_inventory_digest="$(b2_str react_generated_inventory_digest)"
react_regression_result="$(b2_str react_regression_result)"
shared_native_source_digest="$(b2_str shared_native_source_digest)"
native_parity="$(b2_str native_parity)"
pas2js_doctor_result="$(b2_str pas2js_doctor_result)"
pas2js_doctor_row="$(b2_str pas2js_doctor_row)"
pas2js_doctor_version="$(b2_str pas2js_doctor_version)"
pas2js_compiler_version="$(b2p_str pas2js_compiler_version)"
pas2js_compiler_arch="$(b2p_str pas2js_compiler_arch)"
pas2js_compiler_host="$(b2p_str pas2js_compiler_host)"
pas2js_compiler_sha256="$(b2p_str pas2js_compiler_sha256)"
pas2js_frontend_build="$(b2p_str pas2js_frontend_build)"
pas2js_native_build="$(b2p_str pas2js_native_build)"
pas2js_sdk_from_sdk_root="$(b2p_str pas2js_sdk_from_sdk_root)"
pas2js_native_from_sdk_root="$(b2p_str pas2js_native_from_sdk_root)"
pas2js_app_pwb_entries="$(b2p_num pas2js_app_pwb_entries)"
[ -n "${pas2js_app_pwb_entries}" ] || pas2js_app_pwb_entries=0
pas2js_output_sweep="$(b2p_str pas2js_output_sweep)"
pas2js_output_normalised="$(b2p_str pas2js_output_normalised)"
pas2js_static_inventory_digest="$(b2p_str pas2js_static_inventory_digest)"
pas2js_app_pwb_semantic_digest="$(b2p_str pas2js_app_pwb_semantic_digest)"
pas2js_app_pwb_bytes="$(b2p_num pas2js_app_pwb_bytes)"
[ -n "${pas2js_app_pwb_bytes}" ] || pas2js_app_pwb_bytes=0
pas2js_secure_origin="$(b2p_str pas2js_secure_origin)"
pas2js_rpc_result="$(b2p_num pas2js_rpc_result)"
[ -n "${pas2js_rpc_result}" ] || pas2js_rpc_result=0
pas2js_error_mapping="$(b2p_str pas2js_error_mapping)"
pas2js_listener_count="$(b2p_num pas2js_listener_count)"
[ -n "${pas2js_listener_count}" ] || pas2js_listener_count=0
pas2js_loose_assets="$(b2p_str pas2js_loose_assets)"
pas2js_app_raw_binding="$(b2p_str pas2js_app_raw_binding)"
pas2js_sdk_binding_owner="$(b2p_str pas2js_sdk_binding_owner)"
pas2js_clean_shutdown="$(b2p_str pas2js_clean_shutdown)"
pas2js_report_received="$(b2p_str pas2js_report_received)"
pas2js_report_fields="$(b2p_str pas2js_report_fields)"
pas2js_tree_digest="$(b2p_str pas2js_tree_digest)"
pas2js_tree_unchanged="$(b2p_str pas2js_tree_unchanged)"
pas2js_build_out_of_tree="$(b2p_str pas2js_build_out_of_tree)"
react_pas2js_parity="$(b2p_str react_pas2js_parity)"
react_regression_runtime="$(b2p_str react_regression_runtime)"
native_binary_equal="$(b2p_str native_binary_equal)"
pas2js_run_elapsed_ms="$(b2p_num pas2js_run_elapsed_ms)"
[ -n "${pas2js_run_elapsed_ms}" ] || pas2js_run_elapsed_ms=0
if [ "${pas2js_create_corpus}" = 'PASS' ] && [ "${pas2js_proof_corpus}" = 'PASS' ]; then
    # a green verdict with an empty digest is a proof of nothing, and an
    # empty string compares equal to another empty string on four targets
    for pair in "supported_uis=${supported_uis}" \
                "pas2js_generated_inventory_digest=${pas2js_generated_inventory_digest}" \
                "pas2js_pweb_json_digest=${pas2js_pweb_json_digest}" \
                "pas2js_frontend_source_digest=${pas2js_frontend_source_digest}" \
                "pas2js_static_inventory_digest=${pas2js_static_inventory_digest}" \
                "shared_native_source_digest=${shared_native_source_digest}" \
                "react_generated_inventory_digest=${react_generated_inventory_digest}" \
                "pas2js_compiler_version=${pas2js_compiler_version}"; do
        case "${pair}" in
            *=) die "the CAP-10B2 record records PASS with an empty ${pair%%=*}" ;;
        esac
    done
    [ "${pas2js_rpc_result}" = '42' ] ||
        die "the CAP-10B2 build proof records PASS with pas2js_rpc_result=${pas2js_rpc_result}"
    [ "${pas2js_listener_count}" = '0' ] ||
        die 'the CAP-10B2 build proof records a listening socket'
    [ "${pas2js_compiler_version}" = '3.0.1' ] ||
        die "the CAP-10B2 build proof used Pas2JS ${pas2js_compiler_version}"
fi
printf '[CAP-10B2] pas2js_create_corpus: %s (uis=%s refusals=%s files=%s doctor=%s) pas2js_proof_corpus: %s (pas2js=%s/%s rpc=%s listeners=%s parity=%s)\n' \
    "${pas2js_create_corpus}" "${supported_uis}" "${pas2js_create_refusals}" \
    "${pas2js_generated_file_count}" "${pas2js_doctor_result}" \
    "${pas2js_proof_corpus}" "${pas2js_compiler_version}" \
    "${pas2js_compiler_arch}" "${pas2js_rpc_result}" \
    "${pas2js_listener_count}" "${react_pas2js_parity}"

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
  "security_corpus": "${security_corpus}",
  "security_corpus_digest": "${security_corpus_digest}",
  "cap8c_denied_soa": ${cap8c_denied_soa},
  "cap8c_opener_nonmain": ${cap8c_opener_nonmain},
  "cap8c_secure_origin": "${cap8c_secure_origin}",
  "quickjs_corpus": "${quickjs_corpus}",
  "quickjs_corpus_digest": "${quickjs_corpus_digest}",
  "cap9a_denied_bridge": ${cap9a_denied_bridge},
  "cap9a_opener_reached": ${cap9a_opener_reached},
  "quickjs_package_corpus": "${quickjs_package_corpus}",
  "quickjs_package_digest": "${quickjs_package_digest}",
  "cap9b1_loadtime_bridge": ${cap9b1_loadtime_bridge},
  "cap9b1_loader_wrong_thread": ${cap9b1_loader_wrong_thread},
  "cap9b1_store_wrong_thread": ${cap9b1_store_wrong_thread},
  "cap9b1_denied_bridge": ${cap9b1_denied_bridge},
  "cap9b1_source_open_after_failure": ${cap9b1_source_open},
  "cap9b1_opener_reached": ${cap9b1_opener_reached},
  "quickjs_lifecycle_corpus": "${quickjs_lifecycle_corpus}",
  "quickjs_lifecycle_digest": "${quickjs_lifecycle_digest}",
  "cap9b2_two_active_generations": ${cap9b2_two_active},
  "cap9b2_stale_completion": ${cap9b2_stale},
  "cap9b2_reload_lost_old": ${cap9b2_reload_lost_old},
  "cap9b2_export_wrong_thread": ${cap9b2_export_wrong_thread},
  "cap9b2_quarantine_injected": ${cap9b2_quarantine_injected},
  "cap9b2_quarantine_unexpected": ${cap9b2_quarantine_unexpected},
  "cap9b2_denied_bridge": ${cap9b2_denied_bridge},
  "cap9b2_opener_reached": ${cap9b2_opener_reached},
  "quickjs_release_corpus": "${quickjs_release_corpus}",
  "quickjs_release_digest": "${quickjs_release_digest}",
  "cap9c1_inventory_digest": "${cap9c1_inventory_digest}",
  "cap9c1_browser_store_arrivals": ${cap9c1_browser_arrivals},
  "cap9c1_denied_bridge": ${cap9c1_denied_bridge},
  "cap9c1_opener_reached": ${cap9c1_opener_reached},
  "cap9c1_tamper_started": ${cap9c1_tamper_started},
  "cap9c1_cwd_dependency": ${cap9c1_cwd_dependency},
  "cap9c1_package_sha256": "${cap9c1_package_sha}",
  "cap9c1_package_bytes": ${cap9c1_package_bytes},
  "cap9c1_registry_sha256": "${cap9c1_registry_sha}",
  "quickjs_gui_corpus": "${quickjs_gui_corpus}",
  "quickjs_gui_digest": "${quickjs_gui_digest}",
  "cap9c2_listeners": ${cap9c2_listeners},
  "cap9c2_negative_reparse": "${cap9c2_reparse}",
  "cap9c2_license_sha256": "${cap9c2_license}",
  "cap9c2_gates": {${cap9c2_gates_json}
  },
  "cli_corpus": "${cli_corpus}",
  "cli_digest": "${cli_digest}",
  "cli_version_line": "${cli_version_line}",
  "cli_exit_taxonomy": "${cli_exit_taxonomy}",
  "doctor_schema_digest": "${doctor_schema_digest}",
  "doctor_checks": ${doctor_checks},
  "doctor_no_mutation": "${doctor_no_mutation}",
  "doctor_json_deterministic": "${doctor_json_deterministic}",
  "template_corpus": "${template_corpus}",
  "template_digest": "${template_digest}",
  "template_pack_digest": "${template_pack_digest}",
  "template_pack_bytes": "${template_pack_bytes}",
  "template_pack_schema": "${template_pack_schema}",
  "template_semantic_digest": "${template_semantic_digest}",
  "template_registry_digest": "${template_registry_digest}",
  "template_deterministic": "${template_deterministic}",
  "template_source_gate": "${template_source_gate}",
  "template_offline": "${template_offline}",
  "template_refusals": "${template_refusals}",
  "template_file_count": "${template_file_count}",
  "create_present": "${template_create_present}",
  "network_calls": "${network_calls}",
  "package_manager_calls": "${package_manager_calls}",
  "template_modes_applicable": "${template_modes}",
  "create_corpus": "${create_corpus}",
  "create_help_digest": "${create_help_digest}",
  "create_help_bytes": "${create_help_bytes}",
  "create_stdout_digest": "${create_stdout_digest}",
  "create_refusals": "${create_refusals}",
  "create_no_partial": "${create_no_partial}",
  "create_deterministic": "${create_deterministic}",
  "public_pack_digest": "${public_pack_digest}",
  "public_pack_bytes": "${public_pack_bytes}",
  "public_semantic_digest": "${public_semantic_digest}",
  "public_registry_digest": "${public_registry_digest}",
  "public_pack_deterministic": "${public_pack_deterministic}",
  "public_file_count": "${public_file_count}",
  "generated_inventory_digest": "${generated_inventory_digest}",
  "generated_inventory_exact": "${generated_inventory_exact}",
  "generated_pweb_json_digest": "${generated_pweb_json_digest}",
  "generated_package_lock_digest": "${generated_package_lock_digest}",
  "generated_file_count": "${generated_file_count}",
  "generated_total_bytes": "${generated_total_bytes}",
  "generated_no_host_path": "${generated_no_host_path}",
  "doctor_result": "${doctor_result}",
  "proof_corpus": "${proof_corpus}",
  "generated_tree_digest": "${generated_tree_digest}",
  "generated_tree_unchanged": "${generated_tree_unchanged}",
  "frontend_typecheck": "${frontend_typecheck}",
  "frontend_build": "${frontend_build}",
  "frontend_no_dev_code": "${frontend_no_dev_code}",
  "frontend_transport_clean": "${frontend_transport_clean}",
  "runtime_from_sdk_root": "${runtime_from_sdk_root}",
  "native_build": "${native_build}",
  "secure_origin": "${secure_origin}",
  "rpc_result": "${rpc_result}",
  "error_mapping": "${error_mapping}",
  "listener_count": "${listener_count}",
  "raw_primitive_used": "${raw_primitive_used}",
  "loose_assets_used": "${loose_assets_used}",
  "supported_uis": "${supported_uis}",
  "pas2js_create_corpus": "${pas2js_create_corpus}",
  "pas2js_create_refusals": "${pas2js_create_refusals}",
  "pas2js_no_partial": "${pas2js_no_partial}",
  "pas2js_create_deterministic": "${pas2js_create_deterministic}",
  "pas2js_create_stdout_digest": "${pas2js_create_stdout_digest}",
  "pas2js_generated_inventory_digest": "${pas2js_generated_inventory_digest}",
  "pas2js_generated_inventory_exact": "${pas2js_generated_inventory_exact}",
  "pas2js_generated_file_count": "${pas2js_generated_file_count}",
  "pas2js_generated_total_bytes": "${pas2js_generated_total_bytes}",
  "pas2js_pweb_json_digest": "${pas2js_pweb_json_digest}",
  "pas2js_frontend_source_digest": "${pas2js_frontend_source_digest}",
  "pas2js_generated_no_host_path": "${pas2js_generated_no_host_path}",
  "react_generated_inventory_digest": "${react_generated_inventory_digest}",
  "react_regression_result": "${react_regression_result}",
  "shared_native_source_digest": "${shared_native_source_digest}",
  "native_parity": "${native_parity}",
  "pas2js_doctor_result": "${pas2js_doctor_result}",
  "pas2js_doctor_row": "${pas2js_doctor_row}",
  "pas2js_doctor_version": "${pas2js_doctor_version}",
  "pas2js_proof_corpus": "${pas2js_proof_corpus}",
  "pas2js_compiler_version": "${pas2js_compiler_version}",
  "pas2js_compiler_arch": "${pas2js_compiler_arch}",
  "pas2js_compiler_host": "${pas2js_compiler_host}",
  "pas2js_compiler_sha256": "${pas2js_compiler_sha256}",
  "pas2js_frontend_build": "${pas2js_frontend_build}",
  "pas2js_native_build": "${pas2js_native_build}",
  "pas2js_sdk_from_sdk_root": "${pas2js_sdk_from_sdk_root}",
  "pas2js_native_from_sdk_root": "${pas2js_native_from_sdk_root}",
  "pas2js_app_pwb_entries": "${pas2js_app_pwb_entries}",
  "pas2js_output_sweep": "${pas2js_output_sweep}",
  "pas2js_output_normalised": "${pas2js_output_normalised}",
  "pas2js_static_inventory_digest": "${pas2js_static_inventory_digest}",
  "pas2js_app_pwb_semantic_digest": "${pas2js_app_pwb_semantic_digest}",
  "pas2js_app_pwb_bytes": "${pas2js_app_pwb_bytes}",
  "pas2js_secure_origin": "${pas2js_secure_origin}",
  "pas2js_rpc_result": "${pas2js_rpc_result}",
  "pas2js_error_mapping": "${pas2js_error_mapping}",
  "pas2js_listener_count": "${pas2js_listener_count}",
  "pas2js_loose_assets": "${pas2js_loose_assets}",
  "pas2js_app_raw_binding": "${pas2js_app_raw_binding}",
  "pas2js_sdk_binding_owner": "${pas2js_sdk_binding_owner}",
  "pas2js_clean_shutdown": "${pas2js_clean_shutdown}",
  "pas2js_report_received": "${pas2js_report_received}",
  "pas2js_report_fields": "${pas2js_report_fields}",
  "pas2js_tree_digest": "${pas2js_tree_digest}",
  "pas2js_tree_unchanged": "${pas2js_tree_unchanged}",
  "pas2js_build_out_of_tree": "${pas2js_build_out_of_tree}",
  "react_pas2js_parity": "${react_pas2js_parity}",
  "react_regression_runtime": "${react_regression_runtime}",
  "native_binary_equal": "${native_binary_equal}",
  "pas2js_run_elapsed_ms": "${pas2js_run_elapsed_ms}",
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
