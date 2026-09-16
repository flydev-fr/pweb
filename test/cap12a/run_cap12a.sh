#!/usr/bin/env bash
#
# CAP-12A: the blob data-plane measurement on the POSIX targets - Linux x64
# (WebKitGTK) and macOS (both native architectures, WKWebView), dispatched on
# uname. The bash sibling of test/cap12a/run_cap12a.ps1, and it MUST stay a
# sibling: the two scripts differ in how they build and run, never in what a
# row means - that lives once, in test/cap12a/summarize.js.
#
# NOTHING HERE MAY BECOME A CI STEP. The run puts a throwaway store behind
# the production pweb://app seam, and a gate that does that is a gate that
# can normalise it. It is a measurement instrument, run by hand.
#
# Prerequisites:
#   Linux : tools/build-webview-so.sh has staged build/cap7l/webview-dist,
#           node is on PATH, and DISPLAY is set (WSLg, a real session, or
#           run the whole script under xvfb-run -a)
#   macOS : tools/build-webview-dylib.sh has staged the dylib and
#           tools/build-macos-bridge.sh has compiled the Cocoa bridge object.
#           THE DARWIN LEG HAS NEVER BEEN RUN - see README.md.
#
# Usage: test/cap12a/run_cap12a.sh [--timeout-ms N] [--debug]
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-12A] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-12A] === %s\n' "$*"; }

# THE ONE GUARDED RECURSIVE DELETE (deferred-work 7M0-6). This script rebuilds
# its unit and output directories on every run, and a bare `rm -rf -- "${dir}"`
# is the exact shape that ledger closed everywhere else: nothing validates the
# target first, so an unset variable turns it into a delete of somewhere else.
# Sourced, never executed; every removal names its target AND the root that
# target must lie inside.
. "${repo_root}/tools/pwebrmtree.sh"

timeout_ms=600000
debug=0
need_value() { [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout-ms)
            need_value "$@"
            case "$2" in
                ''|*[!0-9]*) die "--timeout-ms: not a number: '$2'" ;;
            esac
            [ "$2" -ge 10000 ] && [ "$2" -le 1200000 ] ||
                die "--timeout-ms out of range (10000..1200000): $2"
            timeout_ms="$2"; shift 2 ;;
        --debug) debug=1; shift ;;
        *) die "unknown option: $1" ;;
    esac
done

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
command -v node >/dev/null 2>&1 || die 'required tool not found: node'
for pre in test/cap12a/blobprobe.pas test/cap12a/blobsource.pas \
           test/cap12a/summarize.js test/cap12a/fixture/index.html \
           test/cap12a/fixture/assets/probe.js \
           src/assets/pweb.assets.support.pas \
           src/security/pweb.navigation.policy.pas; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

work="${repo_root}/build/cap12a"
mkdir -p -- "${work}"

os_name="$(uname -s)"
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
    ;;
Darwin)
    die 'the Darwin leg of this spike is NOT the blobprobe host: WKWebView
needs its own instrument, test/cap12a/cap12a_probe.mm, driven by
test/cap12a/run_cap12a_macos.sh. See test/cap12a/README.md.'
    ;;
*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

unitdir="${work}/fpc-${target}"
outdir="${work}/bin-${target}"
pweb_rm_tree "${unitdir}" "${repo_root}/build"
pweb_rm_tree "${outdir}" "${repo_root}/build"
mkdir -p -- "${unitdir}" "${outdir}"

step "compile blobprobe (${target})"
fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
    -Futest/cap12a -Fusrc/lib -Fusrc/assets -Fusrc/security -Fusrc/webview \
    -Fusrc/rpc -Futest/security "${platform_units[@]}" \
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
    "${link_flags[@]}" \
    test/cap12a/blobprobe.pas > "${work}/build-${target}.log" 2>&1 ||
    { tail -40 "${work}/build-${target}.log"; die 'blobprobe.pas compile FAILED'; }
cp -f -- "${dist}/${soname}" "${outdir}/"

step "run blobprobe in a real window (${target})"
export PWEB_CAP12A_TIMEOUT_MS="${timeout_ms}"
[ "${debug}" = '1' ] && export PWEB_CAP12A_DEBUG=1
set +e
( cd -- "${outdir}" && ./blobprobe ) > "${work}/run-${target}.log" 2>&1
code=$?
set -e
tail -20 "${work}/run-${target}.log"
[ "${code}" -eq 0 ] || die "blobprobe exited ${code}"

step 'summarize'
node test/cap12a/summarize.js --work "${work}"
node test/cap12a/summarize.js --work "${work}" --json \
    > "${work}/summary.json"
printf '[CAP-12A] summary: %s\n' "${work}/summary.json"
