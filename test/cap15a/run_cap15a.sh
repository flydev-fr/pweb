#!/usr/bin/env bash
#
# CAP-15A: the outbound-network measurement on the POSIX targets - Linux x64
# (WebKitGTK) and macOS (both native architectures, WKWebView), dispatched on
# uname. The bash sibling of test/cap15a/run_cap15a.ps1, and it MUST stay a
# sibling: the two scripts differ in how they build and run, never in what the
# measurement means - that lives once, in test/cap15a/summarize.js.
#
# Runs the SAME probe twice in a real window:
#
#   baseline  netprobe compiled against the SHIPPED pweb.navigation.policy
#             (connect-src 'self'), which is the product as it stands;
#   widened   netprobe compiled against a GENERATED shim of that unit whose
#             connect-src also names the probe server's origin A.
#
# The shim is produced here by one exact substitution and lives only under
# build/. Nothing widened is ever committed.
#
# Prerequisites:
#   Linux : tools/build-webview-so.sh has staged build/cap7l/webview-dist,
#           node is on PATH, and DISPLAY is set (WSLg, a real session, or
#           run the whole script under xvfb-run -a)
#   macOS : tools/build-webview-dylib.sh has staged the dylib and
#           tools/build-macos-bridge.sh has compiled the Cocoa bridge object
#
# Usage: test/cap15a/run_cap15a.sh [--public-https URL] [--portA N] [--portB N]
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-15A] %s\n' "$*" >&2; exit 1; }

# THE ONE GUARDED RECURSIVE DELETE (deferred-work 7M0-6). This script rebuilds
# its unit and output directories from scratch on every run, and a bare
# `rm -rf -- "${unitdir}"` is the exact shape that ledger closed everywhere
# else: nothing validates the target first, so an unset variable turns it into
# a delete of somewhere else entirely. Sourced, never executed; every removal
# names its target AND the root that target must lie inside.
. "${repo_root}/tools/pwebrmtree.sh"
step() { printf '\n[CAP-15A] === %s\n' "$*"; }

public_https=''
port_a=41597
port_b=41598
# EVERY OPTION IS VALIDATED WHERE IT IS READ, and the reason is that none of
# these values fails loudly downstream. An empty --portA flows into the CSP
# shim text, into the native allowlist literals and into wait_port_free, where
# `/dev/tcp/127.0.0.1/` fails in a way the script reads as "the port is free";
# an unparsable --public-https yields an empty sed capture and the run then
# reports `widened` rows for an origin that was never in the CSP. The
# post-substitution assertion below cannot catch that, because it greps for
# the string it just built. The PowerShell sibling gets this from [int] and
# a typed parameter; this one has to say it.
need_value() { [ $# -ge 2 ] || die "$1 needs a value"; }
check_port() {
    case "$2" in
        ''|*[!0-9]*) die "$1: not a port number: '$2'" ;;
    esac
    [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || die "$1: port out of range: $2"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --public-https) need_value "$@"; public_https="$2"; shift 2 ;;
        --portA) need_value "$@"; check_port "$1" "$2"; port_a="$2"; shift 2 ;;
        --portB) need_value "$@"; check_port "$1" "$2"; port_b="$2"; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
[ "${port_a}" != "${port_b}" ] ||
    die "port A and port B must differ: both are ${port_a} -- origin B is the
control that nothing names, and one port makes every refusal row meaningless"
if [ -n "${public_https}" ]; then
    case "${public_https}" in
        https://?*) : ;;
        *) die "--public-https must be an absolute https URL: '${public_https}'" ;;
    esac
fi

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
command -v node >/dev/null 2>&1 || die 'required tool not found: node'
for pre in test/cap15a/netprobe.pas test/cap15a/probe_server.js \
           test/cap15a/summarize.js test/cap15a/fixture/index.html \
           test/cap15a/fixture/assets/probe.js \
           src/security/pweb.navigation.policy.pas; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

work="${repo_root}/build/cap15a"
mkdir -p -- "${work}"

# --- the widened shim: ONE substitution, asserted unique --------------------
policy='src/security/pweb.navigation.policy.pas'
shim_dir="${work}/shim"
mkdir -p -- "${shim_dir}"
needle="'connect-src ''self''; "
# `|| true` INSIDE the substitution: with zero matches grep exits 1, pipefail
# fails the whole pipeline, and `set -e` then kills the assignment before the
# die below can say why. The diagnostic is the entire point of this assertion
# - it is what tells a reader on a macOS host that the shipped CSP constant
# moved rather than that the script is broken.
occurrences="$( { grep -F -o "${needle}" "${policy}" || true; } | wc -l | tr -d ' ')"
[ "${occurrences}" = '1' ] ||
    die "the connect-src token appears ${occurrences} time(s) in ${policy} -- the CAP-15A shim substitution is no longer exact"
widened="'connect-src ''self'' http://127.0.0.1:${port_a} ws://127.0.0.1:${port_a}"
if [ -n "${public_https}" ]; then
    # scheme://authority of the public target, nothing more: a CSP source is
    # an origin and a path in one would be silently ignored
    public_origin="$(printf '%s' "${public_https}" |
        sed -n 's#^\([a-z][a-z0-9+.-]*://[^/?#]*\).*#\1#p')"
    # an empty capture here would put NOTHING in the CSP while netprobe still
    # allows the origin natively, so the widened rows would record a refusal
    # that reads as an engine finding
    [ -n "${public_origin}" ] ||
        die "unparsable --public-https, no scheme://authority in: '${public_https}'"
    widened="${widened} ${public_origin}"
fi
widened="${widened}; "
# awk with a literal, non-regex replacement: index/substr, never sub(), so no
# character in either string can be read as a pattern
NEEDLE="${needle}" WIDENED="${widened}" awk '
BEGIN { n = ENVIRON["NEEDLE"]; w = ENVIRON["WIDENED"]; ln = length(n) }
{
    i = index($0, n)
    if (i > 0)
        print substr($0, 1, i - 1) w substr($0, i + ln)
    else
        print
}' "${policy}" > "${shim_dir}/pweb.navigation.policy.pas"
grep -qF "${widened}" "${shim_dir}/pweb.navigation.policy.pas" ||
    die 'the shim substitution produced no widened connect-src'
printf '[CAP-15A] shim written: %s\n' "${shim_dir}/pweb.navigation.policy.pas"

# --- per-platform build recipe ---------------------------------------------
os_name="$(uname -s)"
openssl_flag=()
case "${os_name}" in
Linux)
    target='linux-x86_64'
    dist='build/cap7l/webview-dist'
    soname='libwebview.so.0.12'
    [ -f "${dist}/${soname}" ] ||
        die "staged webview library missing: ${dist}/${soname} -- run tools/build-webview-so.sh"
    [ -d 'deps/mormot2/static/x86_64-linux' ] ||
        die 'mORMot Linux statics missing -- fetch deps/mormot2 first'
    [ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run under xvfb-run -a or WSLg'
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export GDK_BACKEND=x11
    export LIBGL_ALWAYS_SOFTWARE=1
    platform_units=(-Fusrc/platform/linux)
    link_flags=(-Fldeps/mormot2/static/x86_64-linux "-Fl${dist}" -k'-rpath=$ORIGIN')
    # mORMot reaches TLS on POSIX through OpenSSL only, and only when the
    # unit is LINKED: the measurement says so either way, and says which
    if ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.3'; then
        openssl_flag=(-dCAP15A_OPENSSL)
        printf '[CAP-15A] libssl.so.3 present: building with -dCAP15A_OPENSSL\n'
    else
        printf '[CAP-15A] libssl.so.3 NOT found: the build carries no TLS provider\n'
    fi
    ;;
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: ${arch}" ;;
    esac
    [ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
        die 'staged webview dylib missing -- run tools/build-webview-dylib.sh'
    [ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
        die 'Cocoa bridge object missing -- run tools/build-macos-bridge.sh'
    platform_units=(-Fusrc/platform/macos)
    link_flags=("${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}")
    ;;
*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

# `${arr[@]+"${arr[@]}"}` AND NOT `"${arr[@]}"`, in the fpc line below. Under
# `set -u`, bash 3.2 - which is the system bash macOS still ships, and macOS is
# the target this script has never run on - treats an EMPTY array expansion as
# an unbound variable and aborts. `shim_arg` is empty in baseline mode and
# `openssl_flag` is empty whenever OpenSSL is absent, so the Darwin leg would
# have died on `unbound variable` before compiling anything, on a host somebody
# had already paid for. `platform_units` and `link_flags` are never empty on
# either branch and keep the plain form.
build_probe() {
    local mode="$1" unitdir="${work}/fpc-$1" outdir="${work}/bin-$1"
    local shim_arg=()
    pweb_rm_tree "${unitdir}" "${repo_root}/build"
    pweb_rm_tree "${outdir}" "${repo_root}/build"
    mkdir -p -- "${unitdir}" "${outdir}"
    [ "${mode}" = 'widened' ] && shim_arg=("-Fu${shim_dir}")
    step "compile netprobe (${mode})"
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        ${shim_arg[@]+"${shim_arg[@]}"} ${openssl_flag[@]+"${openssl_flag[@]}"} \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Futest/security "${platform_units[@]}" \
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
        "${link_flags[@]}" \
        test/cap15a/netprobe.pas > "${work}/build-${mode}.log" 2>&1 ||
        { tail -30 "${work}/build-${mode}.log"; die "netprobe.pas (${mode}) compile FAILED"; }
    case "${os_name}" in
    Linux)  cp -f -- "${dist}/${soname}" "${outdir}/" ;;
    Darwin) cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" "${outdir}/" ;;
    esac
}

for mode in baseline widened; do build_probe "${mode}"; done

# --- run -------------------------------------------------------------------
export PWEB_CAP15A_PORT_A="${port_a}"
export PWEB_CAP15A_PORT_B="${port_b}"
export PWEB_CAP15A_PUBLIC_HTTPS="${public_https}"

# WSL with mirrored networking shares the Windows loopback, so a probe server
# from the sibling run on the OTHER platform can still hold the port for a
# moment. MEASURED: the second leg of a Windows-then-Linux sequence died with
# EADDRINUSE. Waiting is the fix; failing would make the order of the two legs
# load-bearing.
port_busy() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 1
    exec 3<&- 2>/dev/null || true
    return 0
}

wait_port_free() {
    local p="$1" i=0
    while port_busy "${p}"; do
        i=$((i + 1))
        [ "${i}" -gt 40 ] && die "port ${p} is still in use after 10s"
        sleep 0.25
    done
}

run_mode() {
    local mode="$1"
    local log="${work}/requests-${target}-${mode}.jsonl"
    local srvout="${work}/server-${mode}.log"
    local exe="${work}/bin-${mode}/netprobe"
    local srv_pid tmpdir code i
    rm -f -- "${log}" "${srvout}"
    wait_port_free "${port_a}"
    wait_port_free "${port_b}"
    node test/cap15a/probe_server.js --portA "${port_a}" --portB "${port_b}" \
        --log "${log}" > "${srvout}" 2>&1 &
    srv_pid=$!
    # shellcheck disable=SC2064
    trap "kill ${srv_pid} 2>/dev/null || true" RETURN
    i=0
    while [ "${i}" -lt 100 ]; do
        grep -q 'PROBE_READY' "${srvout}" 2>/dev/null && break
        kill -0 "${srv_pid}" 2>/dev/null || die 'the probe server exited early'
        sleep 0.15
        i=$((i + 1))
    done
    grep -q 'PROBE_READY' "${srvout}" 2>/dev/null ||
        die 'the probe server never reported PROBE_READY'
    step "run netprobe in a real window (${target}, ${mode})"
    tmpdir="$(mktemp -d)"
    set +e
    ( cd -- "${tmpdir}" && "${exe}" ) > "${work}/run-${mode}.log" 2>&1
    code=$?
    set -e
    cat "${work}/run-${mode}.log"
    kill "${srv_pid}" 2>/dev/null || true
    wait "${srv_pid}" 2>/dev/null || true
    srv_pid=''
    pweb_rm_tree "${tmpdir}" "$(dirname -- "${tmpdir}")"
    [ "${code}" -eq 0 ] || die "netprobe (${mode}) exited ${code}"
}

for mode in baseline widened; do run_mode "${mode}"; done

# THE WIDENED SHIM DOES NOT SURVIVE THE RUN. `${shim_dir}` holds a file with
# the SAME UNIT NAME as the shipped policy and a deliberately weakened CSP;
# nothing commits it, but leaving it in the working tree means any later build
# that happens to put that directory on a unit path compiles a widened
# connect-src and says nothing. "Nothing widened is ever committed" was the
# property this spike claimed; "nothing widened survives the run" is the
# stronger one, and it costs one line.
pweb_rm_tree "${shim_dir}" "${repo_root}/build"

# --- join: one summarizer, both platforms ----------------------------------
step 'join the host reports with the wire log'
node test/cap15a/summarize.js --work "${work}" --target "${target}" \
    --portA "${port_a}" --portB "${port_b}" ||
    die 'CAP-15A: the baseline invariant did not hold'
printf '[CAP-15A] summary: %s\n' "${work}/summary-${target}.json"
