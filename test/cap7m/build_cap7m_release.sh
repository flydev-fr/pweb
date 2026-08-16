#!/usr/bin/env bash
#
# CAP-7M2: compile the release surface for macOS, natively, on THIS
# architecture - the shared release host and the deterministic bundler.
#
# NOT ONE COMPILE OR LINK FLAG IS WRITTEN HERE: every macOS decision comes
# from tools/macos-buildenv.sh, exactly as in test/cap7m/build_cap7m.sh.
# The compile shapes mirror test/cap7l/build_cap7l.sh:132-164 - the same
# two programs the Linux job builds, one more platform:
#
#   pwebbundle   mormot core + the asset units, LINK_MORMOT (it references
#                no webview symbol; it packs an already-built dist into the
#                deterministic app.pwb container)
#   releaseapp   the FULL unit set + the production bridge, LINK_BRIDGE
#                (it hosts a real WKWebView through the CAP-7M1 adapter)
#
# Produces:
#   build/cap7m/bin/pwebbundle
#   build/cap7m/ex/releaseapp
#
# Prerequisites: tools/build-webview-dylib.sh has staged
# build/cap7m/webview-dist, tools/build-macos-bridge.sh has compiled the
# Cocoa bridge object, and deps/mormot2 is present.
#
# Usage: test/cap7m/build_cap7m_release.sh [--clean]
#        --clean is OPT-IN; without it a stale work directory is a refusal.
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

eval "$(cap7m_take_clean_flag "$@")"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
assert_fpc_target
record_environment

[ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB}" ] ||
    die 'staged webview dylib missing -- run tools/build-webview-dylib.sh first'
[ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
    die 'Cocoa bridge object missing -- run tools/build-macos-bridge.sh first'
[ -d "${PWEB_MACOS_STATIC_DIR}" ] ||
    die "mORMot Darwin statics missing: ${PWEB_MACOS_STATIC_DIR} -- fetch deps/mormot2 first"

# ex/ is this script's own output directory and follows the shared policy: a
# stale one is a refusal, --clean is the only deletion. bin/ and units/ are
# SHARED with build_cap7m.sh (this script only adds pwebbundle beside the
# gate binaries), so they are created if absent and never prepared here -
# preparing them would refuse whenever the main build has already run, which
# is the normal CI order.
cap7m_prepare_dir "${repo_root}/build/cap7m/ex"
mkdir -p -- "${repo_root}/build/cap7m/bin" "${repo_root}/build/cap7m/units"

# The same unit-path sets test/cap7m/build_cap7m.sh uses (its arrays are
# script-local, like build_cap7l.sh keeps its own).
mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
)
mormot_all=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
    -Fudeps/mormot2/src/net
    -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm
    -Fudeps/mormot2/src/rest
    -Fudeps/mormot2/src/soa
)
pweb_units=(
    -Fusrc/lib
    -Fusrc/rpc
    -Fusrc/webview
    -Fusrc/assets
    -Fusrc/security
    -Fusrc/platform/macos
)

# --- the deterministic bundler ------------------------------------------------
step 'pwebbundle (the deterministic release bundler, on Darwin)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin \
    -Fusrc/assets -Fusrc/rpc "${mormot_core[@]}" \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
    tools/bundler/pwebbundle.pas ||
    die 'pwebbundle failed to compile'

# --- THE shared release host --------------------------------------------------
step 'releaseapp (THE shared release host, with the CAP-7M2 Darwin seam)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/ex \
    "${pweb_units[@]}" "${mormot_all[@]}" \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
    examples/08-release/releaseapp.pas ||
    die 'releaseapp failed to compile'

# --- MEASURED: what the linker actually recorded ------------------------------
# releaseapp calls into the dylib, so it MUST carry the @rpath load command
# and the @executable_path rpath - the properties the .app layout stands on.
# pwebbundle references no webview symbol; its Mach-O shape (arch, minos) is
# asserted and recorded, load command and rpath are not asked of it.
step 'Mach-O shape of both release binaries (arch, minos, load command, rpath)'
pweb_macos_assert_macho build/cap7m/ex/releaseapp --require-dylib --require-rpath
record_measurement "${PWEB_MACOS_MACHO_FACT}"
pweb_macos_assert_macho build/cap7m/bin/pwebbundle
record_measurement "${PWEB_MACOS_MACHO_FACT}"

printf '\n[CAP-7M2] build_cap7m_release: PASS (%s, deployment target %s)\n' \
    "${PWEB_MACOS_HOST_ARCH}" "${PWEB_MACOS_DEPLOYMENT_TARGET}"
