#!/usr/bin/env bash
#
# CAP-7M0 gate M2: the macOS shared library exposes EXACTLY the 17 pinned
# webview C ABI entry points and nothing else that any caller could invoke.
#
# The Mach-O sibling of test/cap7l/check_webview_exports.sh (`nm -D
# --defined-only`) and test/cap4w/check_webview_exports.ps1. The invariant is
# the ratified one: deps/webview stays pristine on the macOS path (the CAP-4W
# patch is Windows-only and is never applied here), so the public surface may
# never grow an 18th public webview export.
#
# MEASURED, run 31904189177, and the reason this gate is shaped the way it is:
# the export trie is NOT the same on both architectures.
#
#   arm64   17 symbols - the 17 webview entry points, nothing else
#   x86_64  25 symbols - the same 17, plus 8 libc++ typeinfo/typeinfo-name
#                        symbols for the std::function instantiations
#                        upstream creates (bool(), void(),
#                        void(string,string,void*)) and for
#                        std::bad_function_call
#
# Those eight are `_ZTI…` / `_ZTS…` weak/coalesced RTTI records. They are not
# entry points, they carry no code, and no caller can invoke them; the x86_64
# toolchain simply emits them into the image where the arm64 one does not.
# Linux never showed this because ELF resolves the same typeinfos out of
# libstdc++ instead of emitting them into the .so.
#
# So an extra symbol is NOT, by itself, evidence that someone patched
# upstream - the earlier wording here said exactly that and was measurably
# wrong. What the contract actually forbids is an 18th PUBLIC WEBVIEW export,
# and that is what this gate asserts, in three parts:
#
#   (a) the exported symbols named webview_* are EXACTLY the pinned 17, on
#       both architectures. This is the contract.
#   (b) every OTHER exported symbol is C++ typeinfo (`_ZTI`) or a typeinfo
#       name (`_ZTS`). Anything else blocks, and is named. A new export that
#       is neither a webview entry point nor RTTI is a real finding.
#   (c) the COMPLETE list and its count are recorded per architecture as
#       CAP7M_EXPORTS, so the arm64-vs-x64 difference stays visible at
#       Checkpoint 1 instead of being smoothed away by a gate that only ever
#       said "17 OK".
#
# WHY dyld_info AND NOT nm. The Linux gate's `nm -D --defined-only` reads the
# dynamic symbol table - the list the loader actually publishes. Mach-O's
# equivalent is the EXPORT TRIE, and `dyld_info -exports` is what reads it.
# `nm -gU` reads the static symbol table's global defined entries, which is a
# different and larger set. nm is still run, as a RECORDED cross-check.
#
# ONE MACH-O DETAIL that is not tooling trivia: Mach-O prefixes every C symbol
# with an underscore, so the trie holds `_webview_create` and (for C++)
# `__ZTI…`. One leading underscore is stripped before any comparison, which is
# why the RTTI names below read as `_ZTI…`.
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

host_arch="$(uname -m)"

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

# Every exported name must arrive through the Mach-O underscore convention.
no_underscore="$(printf '%s\n' "${raw}" | grep . | grep -v '^_' || true)"
if [ -n "${no_underscore}" ]; then
    printf '[CAP-7M0] exported symbol(s) without the Mach-O underscore:\n' >&2
    printf '  %s\n' ${no_underscore} >&2
    die 'export surface contains a symbol that did not come through the C/C++ convention'
fi

stripped="$(printf '%s\n' "${raw}" | sed 's/^_//' | LC_ALL=C sort -u)"
total="$(printf '%s\n' "${stripped}" | grep -c . || true)"
api="$(printf '%s\n' "${stripped}" | grep '^webview_' || true)"
other="$(printf '%s\n' "${stripped}" | grep -v '^webview_' | grep . || true)"
api_count="$(printf '%s\n' "${api}" | grep -c . || true)"
other_count="$(printf '%s\n' "${other}" | grep -c . || true)"

# --- (c) RECORD FIRST, so a failure below still leaves the evidence ----------
record_measurement "CAP7M_EXPORTS arch=${host_arch} total=${total} webview_api=${api_count} other=${other_count}"
printf '%s\n' "${stripped}" | grep . |
    while IFS= read -r s; do
        record_measurement "CAP7M_EXPORTS_SYMBOL arch=${host_arch} ${s}" > /dev/null
    done

# --- (a) THE CONTRACT: exactly the 17 pinned webview entry points ------------
if [ "${api}" != "${expected}" ]; then
    printf '[CAP-7M0] webview_* export surface differs (< missing / > extra):\n' >&2
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${api}") >&2 || true
    die "public webview export surface mismatch: got ${api_count}, expected 17"
fi

# --- (b) everything else must be C++ RTTI, and nothing else ------------------
if [ "${other_count}" -gt 0 ]; then
    not_rtti="$(printf '%s\n' "${other}" | grep -v '^_ZT[IS]' || true)"
    if [ -n "${not_rtti}" ]; then
        printf '[CAP-7M0] exported symbol(s) that are neither a webview entry point nor C++ RTTI:\n' >&2
        printf '  %s\n' ${not_rtti} >&2
        die 'the export surface grew something invocable -- this IS the "someone patched upstream" case'
    fi
    printf '[CAP-7M0] RECORDED: %s additional export(s), all C++ typeinfo/typeinfo-name:\n' \
        "${other_count}"
    printf '  %s\n' ${other}
fi

printf '[CAP-7M0] C ABI PASS - exactly 17 webview entry points on %s (%s of %s exports; export trie)\n' \
    "${host_arch}" "${api_count}" "${total}"

# --- RECORDED, not gated: what the static symbol table additionally holds ----
if command -v nm >/dev/null 2>&1; then
    nm_syms="$(nm -gU "${lib}" 2>/dev/null | awk 'NF > 1 { print $NF }' |
        LC_ALL=C sort -u || true)"
    nm_count="$(printf '%s\n' "${nm_syms}" | grep -c . || true)"
    extra="$(comm -13 <(printf '%s\n' "${raw}" | grep .) \
                      <(printf '%s\n' "${nm_syms}" | grep .) || true)"
    record_measurement "CAP7M_M2 arch=${host_arch} export_trie=${total} nm_gU=${nm_count}"
    if [ -n "${extra}" ]; then
        printf '[CAP-7M0] RECORDED: nm -gU additionally lists %s non-exported global(s)\n' \
            "$(printf '%s\n' "${extra}" | grep -c . || true)"
        printf '%s\n' "${extra}" | grep . |
            while IFS= read -r s; do
                record_measurement "CAP7M_M2_NM_ONLY arch=${host_arch} ${s}" > /dev/null
            done
    else
        printf '[CAP-7M0] RECORDED: nm -gU and the export trie agree exactly\n'
    fi
fi
