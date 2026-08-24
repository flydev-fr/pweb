#!/usr/bin/env bash
#
# CAP-8B: the real-window privileged-navigation matrix on the POSIX targets -
# Linux x64 (WebKitGTK) and macOS (both native architectures, WKWebView),
# dispatched on uname. The bash sibling of test/cap8b/run_nav_matrix.ps1.
#
# Builds test/cap8b/navmatrix.pas (the PRODUCTION asset handler + navigation
# guard + scheduler + CAP-8A policy + per-platform external opener, with the
# opener's one injectable seam swapped for a counting fake) and runs it
# against the malicious fixture corpus in a REAL WebView window. The host
# joins the driver's observed rows with its native ledger, the guard counters
# and the opener spy, and prints exactly one canonical marker.
#
# There is NO conditional SKIP here, and that is deliberate: the Linux job
# runs under xvfb-run and the macOS runner always has an Aqua session, so a
# real WebView opening is a PRECONDITION and every failure gates - the same
# policy the CAP-7L GUI matrix and the CAP-7M release gates use.
#
# Writes: build/cap8b/nav-matrix.json (overall PASS|FAIL) + the run log.
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

die() { printf '[CAP-8B] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8B] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

work="${repo_root}/build/cap8b"
mkdir -p -- "${work}"
json="${work}/nav-matrix.json"
navlog="${work}/nav-matrix-posix.log"
rm -f -- "${json}"

for pre in test/cap8b/navmatrix.pas \
           test/cap8b/fixture/index.html \
           test/cap8b/fixture/assets/driver.js; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

# the canonical PASS marker, from the one source
pass_marker="$(sed -n "s/^  MARKER_PASS = '\\([^']*\\)';\$/\\1/p" \
    test/cap8b/navmatrix.pas)"
[ -n "${pass_marker}" ] || die 'could not read MARKER_PASS from navmatrix.pas'
printf '[CAP-8B] canonical pass marker: %s\n' "${pass_marker}"

os_name="$(uname -s)"
outdir="${work}/nav-bin"
unitdir="${work}/nav-fpc"
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

    step 'compile navmatrix (production guard + opener over the Linux adapter)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Fusrc/platform/linux \
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
        -Fldeps/mormot2/static/x86_64-linux "-Fl${dist}" -k'-rpath=$ORIGIN' \
        test/cap8b/navmatrix.pas ||
        die 'navmatrix.pas compile FAILED'
    cp -f -- "${dist}/${soname}" "${outdir}/"
    exe="${outdir}/navmatrix"
    ;;

# ============================ macOS (both arches) ============================
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init
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

    step 'compile navmatrix (production guard + opener over the Cocoa adapter)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Fusrc/platform/macos \
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
        test/cap8b/navmatrix.pas ||
        die 'navmatrix.pas compile FAILED'
    # @rpath is @executable_path, so the dylib sits beside the binary
    cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" "${outdir}/"
    exe="${outdir}/navmatrix"
    ;;

*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

# --- run it, from an unrelated CWD (the fixture resolves from the exe) --------
step "run navmatrix in a real window (${target})"
set +e
( cd -- "$(mktemp -d)" && "${exe}" ) > "${navlog}" 2>&1
code=$?
set -e
cat "${navlog}"

if grep -qF "${pass_marker}" "${navlog}"; then
    [ "${code}" -eq 0 ] ||
        die "the PASS marker was printed but the host exited ${code}"
    # nav-matrix.json was written by the host on the PASS path
    [ -f "${json}" ] || die 'PASS marker printed but no nav-matrix.json was written'
    printf '[CAP-8B] nav-matrix verdict: PASS (%s)\n' "${target}"
else
    die "CAP-8B nav-matrix FAILED (exit ${code}) -- see ${navlog}"
fi
