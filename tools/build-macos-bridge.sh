#!/usr/bin/env bash
#
# Compiles src/platform/macos/pweb_cocoa_bridge.mm to ONE object file, for the
# native architecture of this host, with every flag taken from
# tools/macos-buildenv.sh.
#
# ONE SHIPPED DYLIB, ONE LINKED OBJECT, NOTHING ELSE. The bridge is not a
# second library: it is an object linked into each PWeb binary that hosts a
# macOS WebView, so the pinned upstream stays unpatched, the public webview
# export surface stays at exactly 17, and there is no second artifact for a
# release layout to lose track of.
#
# The object's ARCHITECTURE is asserted here rather than assumed: a bridge
# built for the other architecture would fail at link time with a message
# about the binary, not about this file, and the next reader would go looking
# in the wrong place.
#
# Output: build/cap7m/bridge/pweb_cocoa_bridge.o
#
# Prerequisite: tools/get-webview.ps1 has staged deps/webview (the bridge
# includes nothing from it today, but the deployment target, the SDK selection
# and the Cocoa/WebKit frameworks are the same decisions the dylib build
# makes, and they are all read from one place).
#
# Usage: tools/build-macos-bridge.sh
#
set -euo pipefail

pweb_bridge_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tools/macos-buildenv.sh
. "${pweb_bridge_script_dir}/macos-buildenv.sh"

die() { printf '[CAP-7M1] %s\n' "$*" >&2; exit 1; }

pweb_macos_init "${CAP7M_EXPECT_ARCH:-}"

# THE ANTI-ROSETTA GATE. This script produces an ARCH-LABELLED artifact, and
# `uname -m` alone cannot label it honestly: a translated process on Apple
# Silicon reports x86_64 quite truthfully. Without these two, an arm64 runner
# under Rosetta would emit an object stamped x86_64 that every later gate then
# treats as x86_64 evidence.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0')" = '1' ]; then
    die 'this process is running under Rosetta -- a translated build is never authoritative'
fi
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = '1' ] &&
   [ "${PWEB_MACOS_HOST_ARCH}" != "${PWEB_MACOS_ARCH_ARM64}" ]; then
    die "host is Apple Silicon but uname -m says ${PWEB_MACOS_HOST_ARCH} -- translated shell"
fi

command -v clang++ >/dev/null 2>&1 || die 'required tool not found: clang++'
command -v lipo >/dev/null 2>&1 || die 'required tool not found: lipo'
command -v otool >/dev/null 2>&1 || die 'required tool not found: otool'

[ -f "${PWEB_MACOS_BRIDGE_SRC}" ] ||
    die "bridge source missing: ${PWEB_MACOS_BRIDGE_SRC}"

mkdir -p -- "${PWEB_MACOS_BRIDGE_DIR}"

printf '[CAP-7M1] compiling the Cocoa bridge (%s, deployment target %s)\n' \
    "${PWEB_MACOS_HOST_ARCH}" "${PWEB_MACOS_DEPLOYMENT_TARGET}"

# -c: an OBJECT, never a library. The frameworks are not needed to compile a
# translation unit, but they ARE the link-time decision this file's consumers
# inherit, so they live beside it in the helper rather than in each consumer.
clang++ -c \
    "${PWEB_MACOS_CLANGXX_OBJCXX_FLAGS[@]}" \
    "${PWEB_MACOS_CLANG_WARNINGS[@]}" \
    "${PWEB_MACOS_CLANG_FLAGS[@]}" \
    -I"${PWEB_MACOS_REPO_ROOT}/src/platform/macos" \
    "${PWEB_MACOS_BRIDGE_SRC}" \
    -o "${PWEB_MACOS_BRIDGE_OBJ}" ||
    die 'pweb_cocoa_bridge.mm failed to compile'

pweb_macos_assert_macho "${PWEB_MACOS_BRIDGE_OBJ}" --object
pweb_macos_record "${PWEB_MACOS_MACHO_FACT}" > /dev/null

# THE PRIVATE-SEAM GATE, and the record-vs-assert split matters here exactly
# as it does in check_webview_exports.sh.
#
# ASSERTED, over TEXT symbols only: every callable entry point this object
# publishes must be one of the seam functions declared in
# pweb_cocoa_bridge.h. An object that started exporting a callable symbol
# nobody reviewed IS the "the seam grew a surface" case.
#
# RECORDED, never asserted, over DATA symbols: this translation unit has eight
# `@catch (NSException *e)` clauses, and on the 64-bit runtime clang lowers
# those to Itanium C++ catch clauses whose typeinfo records (__ZTI11NSException,
# __ZTS11NSException and their pointer forms) are emitted as weak_odr DATA -
# nm type S. They carry no code and cannot be invoked. Gating on them would
# fail this object for having exception handling at all, which is the one
# thing it exists to provide.
step_bad="$(nm -g -U "${PWEB_MACOS_BRIDGE_OBJ}" |
    awk '$2 == "T" { print $3 }' |
    grep -Ev '^_pweb_cocoa_' || true)"
if [ -n "${step_bad}" ]; then
    printf '%s\n' "${step_bad}" >&2
    die 'the bridge object exports a CALLABLE symbol that is not part of the private seam'
fi

seam_count="$(nm -g -U "${PWEB_MACOS_BRIDGE_OBJ}" |
    awk '$2 == "T" { print $3 }' | grep -c '^_pweb_cocoa_' || true)"
data_syms="$(nm -g -U "${PWEB_MACOS_BRIDGE_OBJ}" |
    awk '$2 == "S" || $2 == "D" { print $3 }' | LC_ALL=C sort -u |
    tr '\n' ' ' || true)"
pweb_macos_record "CAP7M1_BRIDGE arch=${PWEB_MACOS_MACHO_ARCH} minos=${PWEB_MACOS_MACHO_MINOS} seam_text_exports=${seam_count}" > /dev/null
pweb_macos_record "CAP7M1_BRIDGE_DATA ${data_syms:-<none>}" > /dev/null
printf '[CAP-7M1] bridge object: %s callable seam entry points (data symbols recorded, not gated)\n' \
    "${seam_count}"
printf '[CAP-7M1] build-macos-bridge: PASS (%s)\n' "${PWEB_MACOS_HOST_ARCH}"
