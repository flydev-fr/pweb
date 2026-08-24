#!/usr/bin/env bash
#
# CAP-8C Phase A: the multi-WebView topology probe on the POSIX targets -
# Linux x64 (WebKitGTK) and macOS (both native architectures, WKWebView),
# dispatched on uname. The bash sibling of test/cap8c/run_topology.ps1.
#
# MEASUREMENT ONLY - this runner gates nothing on what the probe MEASURED,
# only on whether a measurement happened at all. It builds
# test/cap8c/topology.pas (a probe host over the frozen 17-export public
# ABI) and runs it in real WebView windows. The probe rewrites
# build/cap8c/topology-<target>.json after every recorded event, so even a
# probe that crashed mid-experiment leaves a valid partial record with a
# crash_guard naming the dying step - and a crash IS a result here.
#
# There is NO conditional SKIP here, and that is deliberate: the Linux job
# runs under xvfb-run and the macOS runner always has an Aqua session, so a
# real WebView opening is a PRECONDITION - the same policy the CAP-8B
# nav-matrix runner uses. A probe that produced no JSON at all fails; a
# probe that crashed AFTER starting to measure exits 0 with the partial
# record, because the record is the product.
#
# Build flags are the run_nav_matrix.sh set (same units, same statics) so a
# probe build failure can never be a toolchain drift mystery.
#
# Writes: build/cap8c/topology-<target>.json + the run log.
#
# Prerequisites:
#   Linux : tools/build-webview-so.sh has staged build/cap7l/webview-dist
#   macOS : tools/build-webview-dylib.sh has staged the dylib and
#           tools/build-macos-bridge.sh has compiled the Cocoa bridge object
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-8C] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8C] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

work="${repo_root}/build/cap8c"
mkdir -p -- "${work}"
topolog="${work}/topology-posix.log"

[ -f test/cap8c/topology.pas ] || die 'missing precondition: test/cap8c/topology.pas'

# the canonical marker, from the one source
done_marker="$(sed -n "s/^  MARKER_DONE = '\\([^']*\\)';\$/\\1/p" \
    test/cap8c/topology.pas)"
[ -n "${done_marker}" ] || die 'could not read MARKER_DONE from topology.pas'
printf '[CAP-8C] canonical done marker: %s\n' "${done_marker}"

os_name="$(uname -s)"
outdir="${work}/topo-bin"
unitdir="${work}/topo-fpc"
rm -rf -- "${outdir}" "${unitdir}"
mkdir -p -- "${outdir}" "${unitdir}"

case "${os_name}" in

# ============================== Linux x64 ====================================
Linux)
    target='linux-x86_64'
    dist='build/cap7l/webview-dist'
    soname='libwebview.so.0.12'
    [ -f "${dist}/${soname}" ] ||
        die "staged webview library missing: ${dist}/${soname} -- run tools/build-webview-so.sh"
    [ -d 'deps/mormot2/static/x86_64-linux' ] ||
        die 'mORMot Linux statics missing -- fetch deps/mormot2 first'
    [ -n "${DISPLAY:-}" ] ||
        die 'no DISPLAY -- run this under xvfb-run -a'
    # the same hosted-runner rendering environment the CAP-7L GUI matrix sets
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export GDK_BACKEND=x11
    export LIBGL_ALWAYS_SOFTWARE=1

    step 'compile the topology probe (frozen public ABI over the Linux adapter)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Fusrc/platform/linux \
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
        -Fldeps/mormot2/static/x86_64-linux "-Fl${dist}" -k'-rpath=$ORIGIN' \
        test/cap8c/topology.pas ||
        die 'topology.pas compile FAILED'
    cp -f -- "${dist}/${soname}" "${outdir}/"
    exe="${outdir}/topology"
    ;;

# ============================ macOS (both arches) ============================
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    # the fpc-level init: PWEB_MACOS_STATIC_DIR and the FPC link arrays are
    # its facts (same measured reasoning as run_nav_matrix.sh)
    pweb_macos_init_fpc
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: ${arch}" ;;
    esac
    [ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
        die "staged webview dylib missing -- run tools/build-webview-dylib.sh"
    [ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
        die 'Cocoa bridge object missing -- run tools/build-macos-bridge.sh'
    [ -d "${PWEB_MACOS_STATIC_DIR}" ] ||
        die "mORMot Darwin statics missing: ${PWEB_MACOS_STATIC_DIR}"

    step 'compile the topology probe (frozen public ABI over the Cocoa adapter)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Fusrc/platform/macos \
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
        test/cap8c/topology.pas ||
        die 'topology.pas compile FAILED'
    # @rpath is @executable_path, so the dylib sits beside the binary
    cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" "${outdir}/"
    exe="${outdir}/topology"
    ;;

*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

json="${work}/topology-${target}.json"
rm -f -- "${json}"

# --- run it, from an unrelated CWD (the output path resolves from the exe) ----
step "run the topology probe in real windows (${target})"
set +e
( cd -- "$(mktemp -d)" && "${exe}" ) > "${topolog}" 2>&1
code=$?
set -e
cat "${topolog}"

# --- verdict: a record is the product, complete or partial -------------------
if [ -f "${json}" ]; then
    if grep -qF "${done_marker}" "${topolog}" && [ "${code}" -ne 0 ]; then
        die "the done marker was printed but the probe exited ${code}"
    fi
    if [ "${code}" -ne 0 ]; then
        printf '[CAP-8C] probe exited %s after writing a partial record - a crash is a RESULT\n' "${code}"
    fi
    printf '[CAP-8C] topology verdict: MEASURED (%s)\n' "${target}"
    printf '[CAP-8C] --- %s ---\n' "${json}"
    cat "${json}"
else
    die "CAP-8C topology probe produced no record (exit ${code}) -- see ${topolog}"
fi
