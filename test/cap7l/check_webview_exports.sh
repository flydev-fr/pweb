#!/usr/bin/env bash
#
# CAP-7L gate L1/L2: the Linux shared library exports EXACTLY the 17 pinned
# C ABI entry points and nothing else.
#
# The nm -D sibling of test/cap4w/check_webview_exports.ps1, and it asserts
# the same invariant for the same reason: the Linux port reaches pweb://app
# through the seam upstream already exposes, so deps/webview carries no Linux
# patch and the public surface may not grow an 18th export. An extra symbol
# here means someone patched upstream.
#
# Usage: test/cap7l/check_webview_exports.sh [path-to-libwebview.so.0.12]
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }

lib="${1:-${repo_root}/build/cap7l/webview-dist/libwebview.so.0.12}"
[ -f "${lib}" ] || die "webview shared library missing: ${lib}"
command -v nm >/dev/null 2>&1 || die 'required tool not found: nm'

expected="$(printf '%s\n' \
    webview_bind webview_create webview_destroy webview_dispatch \
    webview_eval webview_get_native_handle webview_get_window \
    webview_init webview_navigate webview_return webview_run \
    webview_set_html webview_set_size webview_set_title \
    webview_terminate webview_unbind webview_version | LC_ALL=C sort)"

# --format=posix keeps the name in field 1 whatever the symbol type, so a
# forwarded or oddly-typed extra export cannot slip past the parse.
actual="$(nm -D --defined-only --format=posix "${lib}" |
    awk 'NF > 0 { print $1 }' | LC_ALL=C sort)"

count="$(printf '%s\n' "${actual}" | grep -c . || true)"

if [ "${actual}" != "${expected}" ]; then
    printf '[CAP-7L] unexpected exports (+ extra / - missing):\n' >&2
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") |
        sed -n 's/^[<>]/&/p' >&2 || true
    die "export surface mismatch: got ${count}, expected 17"
fi

printf '[CAP-7L] C ABI PASS - exactly 17 unchanged webview exports (%s)\n' \
    "$(basename -- "${lib}")"
