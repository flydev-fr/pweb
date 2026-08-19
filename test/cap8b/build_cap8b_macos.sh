#!/usr/bin/env bash
#
# CAP-8B: compile the macOS/WKWebView measurement probe, natively, on THIS
# architecture.
#
# One translation unit, one binary, no Pascal. The probe is an AUDIT
# INSTRUMENT: it links the pinned libwebview.dylib and the Cocoa/WebKit
# frameworks, and nothing at all from src/. That is enforced here by giving the
# compile exactly one project include path - deps/webview/core/include - and by
# asserting that the source pulls in exactly one project header, so a probe that
# reached into the product would fail this script rather than be discovered
# later by reading code.
#
# NOT ONE COMPILE OR LINK FLAG IS WRITTEN HERE, and that is the ONE way this
# script differs from its Linux sibling. On Linux the flags come from
# pkg-config; on macOS the -arch, the -mmacosx-version-min, the frameworks and
# the -L/-lwebview/-rpath set are RATIFIED DECISIONS that live in exactly one
# place, tools/macos-buildenv.sh, because before CAP-7M1 they were written
# inline at twenty call sites and the support floor drifted between them. This
# script sources test/cap7m/cap7m_common.sh, which is the shared macOS gate
# preamble (the anti-Rosetta assertion, the environment record and the ONE
# deletion guard) and which sources that flag file in turn. The dependency is
# not new: this probe links the pinned dylib the CAP-7M flow stages under
# build/cap7m/webview-dist.
#
# PER-ARCHITECTURE BY DESIGN, exactly as CAP-7M states it: "the engine behaves
# like this" is a claim about x86_64-darwin AND aarch64-darwin separately, and
# CAP-8B must answer its three questions on both. Nothing here cross-builds; a
# fat artifact would let one architecture masquerade as proof of the other.
#
# NO FPC IS REQUIRED and none is asserted. The probe is pure Objective-C++ with
# no Pascal runtime in the process - which is also why it needs no
# fesetenv(FE_DFL_ENV) remedy; see the probe's own header.
#
# Produces, under build/cap8b/:
#   bin/cap8b_audit_macos       the probe
#   bin/libwebview.0.12.dylib   the pinned library it records as LC_LOAD_DYLIB
#
# Prerequisites: tools/build-webview-dylib.sh has staged
# build/cap7m/webview-dist, and deps/webview is present at the pinned commit.
#
# RE-RUNNABLE. build/cap8b/bin is removed and recreated on every invocation
# through the repository's ONE deletion guard (cap7m_rm_tree, which refuses any
# target outside build/), because test/cap8b/run_audit_macos.sh invokes this
# builder on every run and a gate that refused its own second invocation would
# be usable exactly once.
#
# Usage: test/cap8b/build_cap8b_macos.sh
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../cap7m/cap7m_common.sh"

# The shared preamble tags its own messages CAP-7M0. Re-tagging is not cosmetic:
# a reader of a failing log has to be able to tell which gate spoke, and bash
# resolves these dynamically, so the preamble's own refusals come out under this
# gate's name too.
die() { printf '[CAP-8B] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8B] === %s\n' "$*"; }

cd -- "${repo_root}"

assert_native_arch "${CAP8B_EXPECT_ARCH:-}"
record_environment

command -v clang++ >/dev/null 2>&1 || die 'required tool not found: clang++'
command -v otool >/dev/null 2>&1 || die 'required tool not found: otool'
command -v lipo >/dev/null 2>&1 || die 'required tool not found: lipo'

[ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB}" ] ||
    die 'staged webview dylib missing -- run tools/build-webview-dylib.sh first'
[ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
    die 'staged webview soname missing -- run tools/build-webview-dylib.sh first'
[ -d deps/webview/core/include ] ||
    die 'deps/webview is missing -- fetch the pinned upstream first'

# THE ONLY DELETION, and it goes through the repository's single guard: it
# refuses an empty target, `/`, a `..` component, and anything resolving
# outside ${repo_root}/build. An unguarded rm -rf on the default path of a
# script CI executes as a program is exactly what that guard exists to prevent.
#
# The parent is created FIRST and deliberately: the guard resolves the target's
# PARENT with `cd`, so on a fresh checkout - where build/cap8b does not exist
# yet - it would otherwise refuse a perfectly correct path.
mkdir -p -- "${repo_root}/build/cap8b"
cap7m_rm_tree "${repo_root}/build/cap8b/bin"
mkdir -p -- "${repo_root}/build/cap8b/bin"

# --- the probe ----------------------------------------------------------------
step 'CAP-8B Objective-C++ audit probe (WKWebView)'
clang++ "${PWEB_MACOS_CLANGXX_OBJCXX_FLAGS[@]}" \
    "${PWEB_MACOS_CLANG_WARNINGS[@]}" "${PWEB_MACOS_CLANG_FLAGS[@]}" \
    -Ideps/webview/core/include \
    "${PWEB_MACOS_FRAMEWORKS[@]}" \
    test/cap8b/cap8b_audit_macos.mm -o build/cap8b/bin/cap8b_audit_macos \
    "${PWEB_MACOS_CLANG_LINK_WEBVIEW[@]}" ||
    die 'cap8b_audit_macos failed to compile'

cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" \
    build/cap8b/bin/

# --- MEASURED: what the linker actually recorded ------------------------------
# The Mach-O statement of "this binary resolves the pinned dylib from its own
# location" is LC_LOAD_DYLIB == the install name plus LC_RPATH
# @executable_path, which is why the VERSIONED file is what is copied beside it
# and the bare .dylib is a link-time convenience. The probe calls into the
# dylib on every line it runs, so the load command is REQUIRED here rather than
# merely recorded - and the same helper asserts the single native slice and the
# ratified minos, so a fat or floor-drifting artifact fails here.
step 'Mach-O shape of the produced probe (arch, minos, load command, rpath)'
pweb_macos_assert_macho 'build/cap8b/bin/cap8b_audit_macos' \
    --require-dylib --require-rpath
record_measurement "CAP8B_MACHO ${PWEB_MACOS_MACHO_FACT}"

# The probe is an instrument, not a product component. The compile above gives
# it exactly one project include path; this asserts the other half of the same
# claim, that it pulls in exactly one project header and nothing else - no src/
# unit, no shared fixture, no second copy of the corpus. In particular it must
# NOT reach for src/platform/macos/pweb_cocoa_bridge.h: the probe REPRODUCES
# that seam so the thing it measures is the engine and not our own plumbing.
bad_includes="$(grep -nE '^[[:space:]]*#[[:space:]]*(include|import)[[:space:]]*"' \
    test/cap8b/cap8b_audit_macos.mm | grep -v 'webview/api\.h' || true)"
[ -z "${bad_includes}" ] || {
    printf '%s\n' "${bad_includes}" >&2
    die 'the probe includes a project header other than webview/api.h'
}

printf '\n[CAP-8B] build_cap8b_macos: PASS (%s, deployment target %s, load %s)\n' \
    "${PWEB_MACOS_HOST_ARCH}" "${PWEB_MACOS_DEPLOYMENT_TARGET}" \
    "${PWEB_MACOS_MACHO_LOAD:-<none>}"
printf '[CAP-8B] run it on a real Aqua session:\n'
printf '[CAP-8B]   build/cap8b/bin/cap8b_audit_macos build/cap8b/audit-macos-%s.json\n' \
    "${PWEB_MACOS_HOST_ARCH}"
