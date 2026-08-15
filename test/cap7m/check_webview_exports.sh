#!/usr/bin/env bash
#
# CAP-7M0 gate M2: the macOS shared library exports EXACTLY the 17 pinned
# C ABI entry points and nothing else, on EACH native architecture.
#
# The Mach-O sibling of test/cap7l/check_webview_exports.sh (`nm -D
# --defined-only`) and test/cap4w/check_webview_exports.ps1, asserting the
# same invariant for the same reason: deps/webview stays pristine on the
# macOS path (the CAP-4W patch is Windows-only and is never applied here), so
# the public surface may not grow an 18th export. An extra symbol means
# someone patched upstream.
#
# WHY dyld_info AND NOT nm. The Linux gate's `nm -D` reads the DYNAMIC symbol
# table - the list the loader actually publishes. Mach-O's equivalent is the
# EXPORT TRIE, and `dyld_info -exports` is what reads it. `nm -gU` reads the
# static symbol table's global defined entries, which for a C++-built dylib
# can also contain things like ___clang_call_terminate and weak ODR symbols
# that are not exports at all. Gating on nm would therefore fail with
# "someone patched upstream" for a library nobody touched - an actively
# misleading diagnostic, on a runner that bills at 10x, for what is probably
# the single likeliest first-run surprise here.
#
# nm -gU is still run, as a RECORDED cross-check: the difference between the
# two lists is a fact about the artifact worth having, and it is reported
# rather than gated.
#
# ONE MACH-O DIFFERENCE that is not a tooling detail: Mach-O prefixes every C
# symbol with an underscore, so the trie holds `_webview_create`. It is
# stripped before comparing, and a symbol that does NOT carry it is a finding
# rather than something to tolerate - it would mean the name reached the
# export table by some route other than the C ABI.
#
# Usage: test/cap7m/check_webview_exports.sh [path-to-libwebview.0.12.dylib]
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
record_environment

lib="${1:-${dist}/$(lock_get macos-dylib-versioned)}"
[ -f "${lib}" ] || die "webview dylib missing: ${lib} -- run tools/build-webview-dylib.sh first"

expected="$(printf '%s\n' \
    webview_bind webview_create webview_destroy webview_dispatch \
    webview_eval webview_get_native_handle webview_get_window \
    webview_init webview_navigate webview_return webview_run \
    webview_set_html webview_set_size webview_set_title \
    webview_terminate webview_unbind webview_version | LC_ALL=C sort)"

# --- the authoritative list: the export trie ---------------------------------
dyld_info_cmd=''
if command -v dyld_info >/dev/null 2>&1; then
    dyld_info_cmd='dyld_info'
elif xcrun --find dyld_info >/dev/null 2>&1; then
    dyld_info_cmd='xcrun dyld_info'
else
    die 'dyld_info not found (it ships with Xcode 13.3+ / macOS 12+) -- refusing to gate on nm, which reads a different table'
fi

# Output shape:
#   <path> [<arch>]:
#       -exports:
#           offset      symbol
#           0x00003A10  _webview_bind
# Take the symbol column of every row that begins with a hex offset; that
# skips the headers without needing to know their exact wording.
raw="$(${dyld_info_cmd} -exports "${lib}" |
    awk '$1 ~ /^0x[0-9A-Fa-f]+$/ && NF >= 2 { print $2 }' | LC_ALL=C sort -u)"
[ -n "${raw}" ] || die "the export trie of ${lib} is empty -- dyld_info parsed nothing"

# Every exported name must arrive through the Mach-O C convention.
bare="$(printf '%s\n' "${raw}" | grep -v '^_' || true)"
if [ -n "${bare}" ]; then
    printf '[CAP-7M0] exported symbol(s) without the Mach-O underscore:\n' >&2
    printf '  %s\n' ${bare} >&2
    die 'export surface contains a non-C symbol'
fi

actual="$(printf '%s\n' "${raw}" | sed 's/^_//' | LC_ALL=C sort)"
count="$(printf '%s\n' "${actual}" | grep -c . || true)"

if [ "${actual}" != "${expected}" ]; then
    printf '[CAP-7M0] unexpected exports (< missing / > extra):\n' >&2
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") >&2 || true
    die "export surface mismatch: got ${count}, expected 17"
fi

printf '[CAP-7M0] C ABI PASS - exactly 17 unchanged webview exports on %s (%s, export trie)\n' \
    "$(uname -m)" "$(basename -- "${lib}")"

# --- RECORDED, not gated: what the static symbol table additionally holds ----
if command -v nm >/dev/null 2>&1; then
    nm_syms="$(nm -gU "${lib}" 2>/dev/null | awk 'NF > 1 { print $NF }' |
        LC_ALL=C sort -u || true)"
    nm_count="$(printf '%s\n' "${nm_syms}" | grep -c . || true)"
    extra="$(comm -13 <(printf '%s\n' "${raw}") <(printf '%s\n' "${nm_syms}") || true)"
    record_measurement "CAP7M_M2 export_trie=${count} nm_gU=${nm_count}"
    if [ -n "${extra}" ]; then
        printf '[CAP-7M0] RECORDED: nm -gU additionally lists %s non-exported global(s):\n' \
            "$(printf '%s\n' "${extra}" | grep -c . || true)"
        printf '  %s\n' ${extra}
        printf '%s\n' "${extra}" |
            while IFS= read -r s; do
                [ -n "${s}" ] && record_measurement "CAP7M_M2_NM_ONLY ${s}"
            done
    else
        printf '[CAP-7M0] RECORDED: nm -gU and the export trie agree exactly\n'
    fi
fi
