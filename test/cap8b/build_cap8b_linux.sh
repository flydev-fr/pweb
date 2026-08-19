#!/usr/bin/env bash
#
# CAP-8B: compile the Linux/WebKitGTK measurement probe.
#
# One translation unit, one binary, no Pascal. The probe is an AUDIT
# INSTRUMENT: it links the pinned libwebview.so and the ratified distro
# WebKitGTK stack, and nothing at all from src/. That is enforced here by
# giving the compile exactly one include path beyond the system ones -
# deps/webview/core/include - so a probe that reached into the product
# would fail this script rather than be discovered later by reading code.
#
# Produces, under build/cap8b/:
#   bin/cap8b_audit_linux    the probe
#   bin/libwebview.so.0.12   the pinned library it records as DT_NEEDED
#
# It also asserts the two things about the probe that a later edit would
# silently drop and that no compiler can catch: the measurement-honesty
# fields of the schema (a DERIVED value must never be emitted in the shape
# of a MEASURED one), and the XTEST guard that keeps a display without the
# extension costing a note instead of the whole artifact.
#
# Prerequisites: tools/build-webview-so.sh has staged
# build/cap7l/webview-dist (the same staged library the CAP-7L flow
# builds - CAP-8B measures the SAME engine binding, so it must not build
# a second one), and the ratified WebKitGTK dev packages are installed.
#
# Usage: test/cap8b/build_cap8b_linux.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-8B] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8B] === %s\n' "$*"; }

cc_bin="${CC:-cc}"
command -v "${cc_bin}" >/dev/null 2>&1 || die "required tool not found: ${cc_bin}"
command -v pkg-config >/dev/null 2>&1 || die 'required tool not found: pkg-config'
command -v readelf >/dev/null 2>&1 || die 'required tool not found: readelf'

dist='build/cap7l/webview-dist'
[ -f "${dist}/libwebview.so" ] ||
    die "staged webview library missing -- run tools/build-webview-so.sh first"
[ -f "${dist}/libwebview.so.0.12" ] ||
    die "staged webview soname missing -- run tools/build-webview-so.sh first"

# ONE RATIFIED STACK, asserted rather than autodetected. webkitgtk-6.0 on
# the machine must fail here instead of being silently preferred.
pkg-config --exists webkit2gtk-4.1 ||
    die 'webkit2gtk-4.1 not found -- install libwebkit2gtk-4.1-dev'
pkg-config --exists gtk+-3.0 ||
    die 'gtk+-3.0 not found -- install libgtk-3-dev'
printf '[CAP-8B] gtk+-3.0       %s\n' "$(pkg-config --modversion gtk+-3.0)"
printf '[CAP-8B] webkit2gtk-4.1 %s\n' "$(pkg-config --modversion webkit2gtk-4.1)"

# libsoup-3.0 is not an extra dependency so much as an admission of one:
# webkit2gtk-4.1 IS the libsoup3 flavour of the API, and SoupMessageHeaders
# is the only public vehicle for a response header on a custom scheme
# (webkit_uri_scheme_request_finish carries none). If it is genuinely
# absent the probe still builds and RECORDS that the CSP header could not
# be delivered - a measured result, never a silent skip.
soup_cflags=''
soup_libs=''
have_soup3=0
if pkg-config --exists libsoup-3.0; then
    have_soup3=1
    soup_cflags="$(pkg-config --cflags libsoup-3.0)"
    soup_libs="$(pkg-config --libs libsoup-3.0)"
    printf '[CAP-8B] libsoup-3.0    %s\n' "$(pkg-config --modversion libsoup-3.0)"
else
    printf '[CAP-8B] libsoup-3.0    ABSENT -- the probe will record that no '
    printf 'response header can be attached on this stack\n'
fi

rm -rf -- build/cap8b/bin
mkdir -p -- build/cap8b/bin

# --- the probe ----------------------------------------------------------------
step 'CAP-8B Linux/WebKitGTK audit probe'
# shellcheck disable=SC2046,SC2086
"${cc_bin}" -O1 -Wall -Wextra -Werror -pthread \
    -DCAP8B_HAVE_SOUP3="${have_soup3}" \
    -Ideps/webview/core/include \
    $(pkg-config --cflags webkit2gtk-4.1 gtk+-3.0) ${soup_cflags} \
    test/cap8b/cap8b_audit_linux.c -o build/cap8b/bin/cap8b_audit_linux \
    -Wl,-rpath,'$ORIGIN' -L"${dist}" -lwebview \
    $(pkg-config --libs webkit2gtk-4.1 gtk+-3.0) ${soup_libs} -ldl ||
    die 'cap8b_audit_linux failed to compile'
cp -f -- "${dist}/libwebview.so.0.12" build/cap8b/bin/

# --- the same linkage assertions the CAP-7L binaries carry --------------------
# MEASURED there and re-asserted here: the linker records the SONAME, and
# the probe must find its library beside itself rather than through the
# working directory.
needed="$(readelf -d build/cap8b/bin/cap8b_audit_linux |
    sed -n 's/.*NEEDED.*\[\(libwebview[^]]*\)\].*/\1/p' | head -n 1)"
[ "${needed}" = 'libwebview.so.0.12' ] ||
    die "probe records DT_NEEDED '${needed}', expected libwebview.so.0.12"
runpath="$(readelf -d build/cap8b/bin/cap8b_audit_linux |
    sed -n 's/.*RUNPATH.*\[\(.*\)\].*/\1/p' | head -n 1)"
[ "${runpath}" = '$ORIGIN' ] ||
    die "probe RUNPATH is '${runpath}', expected \$ORIGIN (no CWD dependence)"

# The probe is an instrument, not a product component. The compile above
# gives it exactly one project include path; this asserts the other half of
# the same claim, that it pulls in exactly one project header and nothing
# else - no src/ unit, no shared fixture, no second copy of the corpus.
bad_includes="$(grep -nE '^[[:space:]]*#[[:space:]]*include[[:space:]]*"' \
    test/cap8b/cap8b_audit_linux.c | grep -v 'webview/api\.h' || true)"
[ -z "${bad_includes}" ] || {
    printf '%s\n' "${bad_includes}" >&2
    die 'the probe includes a project header other than webview/api.h'
}

# --- the measurement contract, asserted rather than trusted -------------------
# None of this is a compiler error if it regresses; all of it silently
# turns the artifact into a cross-target comparison that means nothing, or
# (the XTEST pair) into no artifact at all.
step 'measurement-contract assertions'
probe='test/cap8b/cap8b_audit_linux.c'
require_token() {
    grep -qF -- "$1" "${probe}" || die "the probe no longer contains $1 -- $2"
}
# THE ESCAPED SPELLING, DELIBERATELY. An earlier revision asserted the bare
# `"user_initiated_basis"`, which matches only the PROSE in this file's header
# comment - the emitters write \"user_initiated_basis\", where a backslash
# sits exactly where that pattern looks for the closing quote. Deleting the
# whole emission would have left the build green so long as the comment
# survived: a gate protecting a comment, which is the precise inversion of
# what it was added for. Each pattern below carries the trailing `\":` so it
# can only match an emitter.
require_token '\"user_initiated_basis\":' \
    'every event must state HOW its user_initiated was obtained'
require_token '\"user_initiated_semantics\":' \
    'the document must carry the one sentence that heads that column'
require_token '\"policy\":' \
    'every event must say whether its hook can REFUSE or only observe'
require_token '\"detail\":' \
    'every event must carry its free-form per-hook string'
# captured rather than piped into a second grep: a `grep -q` that exits on
# its first match can SIGPIPE the producer, and under pipefail that reads as
# a failed assertion rather than a satisfied one
null_row="$(grep -A2 -F -- 'user_initiated\": %s' "${probe}" || true)"
case "${null_row}" in
    *'"null"'*) : ;;
    *) die 'user_initiated must be emitted as null, never false, on a row the engine was never asked' ;;
esac
require_token 'XTestQueryExtension' \
    'the X SERVER must be asked before any XTest faking call: libXtst on a server without the extension prints and exit(1)s, losing every phase already measured'
require_token 'XSetExtensionErrorHandler' \
    'the non-exiting extension error handler is the second half of that guard'
require_token 'webkit_policy_decision_download' \
    'the download hook is reachable only if an undisplayable response is converted rather than ignored'
require_token 'g_downloadEventsSeen' \
    'download_hook_available must report an OBSERVED firing'
! grep -qF -- 'g_downloadHookAvailable' "${probe}" ||
    die 'download_hook_available is being written from an API lookup again'
printf '[CAP-8B] measurement contract: PASS\n'

printf '\n[CAP-8B] build_cap8b_linux: PASS (DT_NEEDED=%s RUNPATH=%s soup3=%s)\n' \
    "${needed}" "${runpath}" "${have_soup3}"
printf '[CAP-8B] run it under a virtual display:\n'
printf '[CAP-8B]   xvfb-run -a build/cap8b/bin/cap8b_audit_linux build/cap8b/linux.json\n'
