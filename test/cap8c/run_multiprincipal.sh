#!/usr/bin/env bash
#
# CAP-8C: the multi-principal integration harness on the POSIX targets -
# Linux x64 (WebKitGTK) and macOS (both native architectures, WKWebView),
# dispatched on uname. The bash sibling of test/cap8c/run_multiprincipal.ps1.
#
# Builds test/cap8c/multiprincipal.pas (the UNCHANGED production scheduler +
# CAP-8A policy + CAP-8B guard/opener + the real mORMot SOA bridge for the
# Main path, with the opener's one injectable seam swapped for a counting
# fake) and runs its two legs: the headless NATIVE decision matrix over three
# sources (main, login, plugin) - which writes the canonical
# build/cap8c/security-corpus.txt digest source - and the GUI leg of two
# simultaneously live real WebViews with the content-swap + injected-opener
# evidence.
#
# Unlike Windows, POSIX needs NO CAP-3U patch window: the mORMot x64
# call-method trampoline is a Win64-only concern (the release host compiles
# its SOA path directly on Linux and macOS, build_cap7l.sh / the CAP-7M
# release build). This runner therefore mirrors run_nav_matrix.sh with the
# full mORMot SOA unit set added.
#
# NO conditional SKIP: the Linux job runs under xvfb-run and the macOS runner
# always has an Aqua session, so a real WebView opening is a PRECONDITION and
# every failure gates - the same policy as the CAP-8B nav-matrix runner.
#
# Writes: build/cap8c/multiprincipal-<target>.json (PASS|FAIL),
#         build/cap8c/security-corpus.txt (the digest source) + the run log.
#
# Environment: PWEB_MULTIPRINCIPAL_TIMEOUT_MS overrides the harness's GUI
# watchdog bound (default 45000, capped at 120000) for slow local machines.
#
# Prerequisites:
#   Linux : tools/build-webview-so.sh has staged build/cap7l/webview-dist
#   macOS : tools/build-webview-dylib.sh has staged the dylib and
#           tools/build-macos-bridge.sh has compiled the Cocoa bridge object
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-8C] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8C] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

work="${repo_root}/build/cap8c"
mkdir -p -- "${work}"
corpus="${work}/security-corpus.txt"
mplog="${work}/multiprincipal-posix.log"
# every output deleted up front (the per-target json again once the target is
# known): an aborted run must never leave a previous run's evidence lying
# where the emitter or an upload could mistake it
rm -f -- "${corpus}" "${mplog}" "${work}"/multiprincipal-*.json

for pre in test/cap8c/multiprincipal.pas \
           test/cap8c/fixture/main.html \
           test/cap8c/fixture/login.html \
           test/cap8c/fixture/assets/driver.js; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

pass_marker="$(sed -n "s/^  MARKER_PASS = '\\([^']*\\)';\$/\\1/p" \
    test/cap8c/multiprincipal.pas)"
[ -n "${pass_marker}" ] || die 'could not read MARKER_PASS from multiprincipal.pas'
printf '[CAP-8C] canonical pass marker: %s\n' "${pass_marker}"

os_name="$(uname -s)"
outdir="${work}/mp-bin"
unitdir="${work}/mp-fpc"
rm -rf -- "${outdir}" "${unitdir}"
mkdir -p -- "${outdir}" "${unitdir}"

mormot_units=(
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa
)

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
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export GDK_BACKEND=x11
    export LIBGL_ALWAYS_SOFTWARE=1

    step 'compile multiprincipal (production runtime + real SOA bridge, Linux adapter)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Fusrc/platform/linux "${mormot_units[@]}" \
        -Fldeps/mormot2/static/x86_64-linux "-Fl${dist}" -k'-rpath=$ORIGIN' \
        test/cap8c/multiprincipal.pas ||
        die 'multiprincipal.pas compile FAILED'
    cp -f -- "${dist}/${soname}" "${outdir}/"
    exe="${outdir}/multiprincipal"
    ;;

# ============================ macOS (both arches) ============================
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
        die "staged webview dylib missing -- run tools/build-webview-dylib.sh"
    [ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
        die 'Cocoa bridge object missing -- run tools/build-macos-bridge.sh'
    [ -d "${PWEB_MACOS_STATIC_DIR}" ] ||
        die "mORMot Darwin statics missing: ${PWEB_MACOS_STATIC_DIR}"

    step 'compile multiprincipal (production runtime + real SOA bridge, Cocoa adapter)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
        -Fusrc/platform/macos "${mormot_units[@]}" \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
        test/cap8c/multiprincipal.pas ||
        die 'multiprincipal.pas compile FAILED'
    cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" "${outdir}/"
    exe="${outdir}/multiprincipal"
    ;;

*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

json="${work}/multiprincipal-${target}.json"
rm -f -- "${json}"

step "run multiprincipal in two real windows + native leg (${target})"
set +e
( cd -- "$(mktemp -d)" && "${exe}" ) > "${mplog}" 2>&1
code=$?
set -e
cat "${mplog}"

[ -f "${corpus}" ] ||
    die "the security-corpus digest source was not written -- see ${mplog}"

if grep -qF "${pass_marker}" "${mplog}"; then
    [ "${code}" -eq 0 ] ||
        die "the PASS marker was printed but the host exited ${code}"
    [ -f "${json}" ] || die 'PASS marker printed but no multiprincipal JSON was written'
    printf '[CAP-8C] multiprincipal verdict: PASS (%s)\n' "${target}"
else
    die "CAP-8C multiprincipal FAILED (exit ${code}) -- see ${mplog}"
fi
