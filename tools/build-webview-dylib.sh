#!/usr/bin/env bash
#
# Builds libwebview.dylib (upstream webview::core_shared, C ABI exports) from
# the PINNED checkout in deps/webview, for ONE native macOS architecture.
#
# The macOS sibling of tools/build-webview-so.sh and
# tools/build-webview-dll.ps1, deliberately the same shape: configure with the
# pinned flags, ASSERT what the configure actually resolved, build only
# webview_core_shared, stage the artifact with its licence. Nothing here is
# autodetected and nothing is decided by the host.
#
# THREE THINGS THIS SCRIPT REFUSES TO LET THE MACHINE DECIDE (CAP-7M0):
#
#   1. The ARCHITECTURE. -DCMAKE_OSX_ARCHITECTURES is passed explicitly and the
#      finished Mach-O is checked with `lipo -archs`: exactly one slice, and
#      exactly the requested one. A universal binary fails here - Universal 2
#      is deliberately NOT a CAP-7 requirement, and a fat artifact would let an
#      arm64 run masquerade as an x86_64 proof.
#
#   2. The DEPLOYMENT TARGET. -DCMAKE_OSX_DEPLOYMENT_TARGET is passed from
#      webview.lock and the resulting LC_BUILD_VERSION minos is read back out
#      of the binary. Left alone, the SDK on the runner silently decides the
#      minimum macOS the product supports, which is exactly the class of fact
#      this shard exists to pin rather than inherit.
#
#   3. WHICH BACKEND WAS COMPILED. Upstream selects the Cocoa/WKWebView
#      backend from platform macros, so nothing in the cache states it
#      directly. The proof is the link: a Cocoa build - and only a Cocoa build
#      - resolves against WebKit.framework, which is asserted below with
#      `otool -L`.
#
# Also RECORDED (not guessed) because the .app layout depends on them (M3):
# the install name (`otool -D`) and every LC_RPATH the artifact carries. Both
# go to build/cap7m/webview-dist/measurements.txt, which is a CI artifact.
#
# Output: build/cap7m/webview-dist/
#           libwebview.0.12.dylib   the compatibility name - what LC_LOAD_DYLIB
#                                   records and therefore what a bundle ships
#           libwebview.dylib        link-time name for FPC's -Fl (the chet
#                                   [Platform.Mac*] LibraryName)
#           LICENSE.webview
#           measurements.txt
#
# Usage:  tools/build-webview-dylib.sh [x86_64|arm64]
#         (default: the native architecture of this host)
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

src="${repo_root}/deps/webview"
build_dir="${repo_root}/build/cap7m/webview-build"
dist_dir="${repo_root}/build/cap7m/webview-dist"
lock_file="${repo_root}/webview.lock"
fpc_lock_file="${repo_root}/fpc.lock"
# the shared, always-uploaded measurement record (see test/cap7m/cap7m_common.sh)
measurements="${repo_root}/build/cap7m/measurements.txt"

die() { printf '[CAP-7M0] %s\n' "$*" >&2; exit 1; }

# --- read a lock (strict: one 'key = value' per non-comment line) ------------
_lock_get() {
    local file="$1" wanted="$2" line key value found='' result=''
    [ -f "${file}" ] || die "lock file missing: ${file}"
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        case "${line}" in '#'*) continue ;; esac
        case "${line}" in *=*) ;; *) die "$(basename "${file}") line is malformed: ${line}" ;; esac
        key="$(printf '%s' "${line%%=*}" | sed -e 's/[[:space:]]*$//')"
        value="$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//')"
        if [ "${key}" = "${wanted}" ]; then
            [ -n "${found}" ] && die "$(basename "${file}") contains duplicate key '${wanted}'"
            found=1
            result="${value}"
        fi
    done < "${file}"
    [ -n "${found}" ] || die "$(basename "${file}") has no '${wanted}' entry"
    printf '%s' "${result}"
}

lock_get() { _lock_get "${lock_file}" "$1"; }
fpc_lock_get() { _lock_get "${fpc_lock_file}" "$1"; }

[ -f "${lock_file}" ] || die "webview.lock missing: ${lock_file}"
[ -f "${src}/CMakeLists.txt" ] || die 'deps/webview missing -- run tools/get-webview.ps1 first'

pinned_commit="$(lock_get commit)"
case "${pinned_commit}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "webview.lock does not pin a full 40-char lowercase SHA: ${pinned_commit}" ;;
esac

# The checkout must BE the pin, not merely be clean at some commit. CI's
# `git status --porcelain` check passes perfectly on a tree parked at the
# wrong revision, and every measurement below would then describe a different
# library than the one this project ratified. One command turns a lock value
# into a measurement, which is this whole shard's thesis.
checkout_commit="$(git -C "${src}" rev-parse HEAD 2>/dev/null || printf '')"
[ -n "${checkout_commit}" ] ||
    die "deps/webview is not a git checkout -- cannot verify it is at ${pinned_commit}"
[ "${checkout_commit}" = "${pinned_commit}" ] ||
    die "deps/webview is at ${checkout_commit}, webview.lock pins ${pinned_commit}"

dylib_link="$(lock_get macos-dylib)"
dylib_versioned="$(lock_get macos-dylib-versioned)"
dylib_real="$(lock_get macos-dylib-real)"
install_name_prefix="$(lock_get macos-install-name-prefix)"
deployment_target="$(lock_get macos-deployment-target)"
arch_x64="$(lock_get macos-arch-x64)"
arch_arm64="$(lock_get macos-arch-arm64)"

# The ratified names are FACTS of this capability, not variables: a lock that
# says something else is a deliberate re-ratification and must not be honoured
# by a script that was reviewed against these values.
[ "${dylib_link}" = 'libwebview.dylib' ] || die "unexpected macos-dylib pin '${dylib_link}'"
[ "${dylib_versioned}" = 'libwebview.0.12.dylib' ] ||
    die "unexpected macos-dylib-versioned pin '${dylib_versioned}'"
[ "${dylib_real}" = 'libwebview.0.12.0.dylib' ] ||
    die "unexpected macos-dylib-real pin '${dylib_real}'"
[ "${install_name_prefix}" = '@rpath/' ] ||
    die "unexpected macos-install-name-prefix pin '${install_name_prefix}'"

# --- native architecture, never Rosetta, never a cross build -----------------
host_arch="$(uname -m)"
want_arch="${1:-${host_arch}}"
case "${want_arch}" in
    "${arch_x64}"|"${arch_arm64}") ;;
    *) die "unsupported architecture '${want_arch}' (expected ${arch_x64} or ${arch_arm64})" ;;
esac
[ "${want_arch}" = "${host_arch}" ] ||
    die "refusing to cross-build: asked for ${want_arch} on a ${host_arch} host"

# `uname -m` alone is NOT an anti-Rosetta gate: a translated process on Apple
# Silicon reports x86_64 quite honestly. These two do settle it.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0')" = '1' ]; then
    die 'this process is running under Rosetta -- a translated run is never authoritative'
fi
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = '1' ] &&
   [ "${host_arch}" != "${arch_arm64}" ]; then
    die "host is Apple Silicon but uname -m says ${host_arch} -- translated shell"
fi

[ "$(uname -s)" = 'Darwin' ] || die "this script is macOS only, host is $(uname -s)"

for tool in cmake otool lipo nm xcrun; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

# --- the Xcode selection is a PIN, so prove it was applied -------------------
# fpc.lock records known-bad Xcode versions because FPC 3.2.2 has open linker
# failures on them. That pin is worth nothing if this script cheerfully builds
# under whatever the image defaults to when the selection step was skipped,
# reordered or silently failed - and the record would say
# "<unset, runner default>" while the artifact looked perfectly normal.
[ -n "${DEVELOPER_DIR:-}" ] ||
    die 'DEVELOPER_DIR is unset -- run tools/get-fpc-macos.ps1 first; the pinned Xcode selection is not optional'

xcode_candidates="$(fpc_lock_get macos-xcode-candidates)"
xcode_known_bad="$(fpc_lock_get macos-xcode-known-bad)"
selected_xcode=''
for c in ${xcode_candidates}; do
    if [ "${DEVELOPER_DIR}" = "/Applications/Xcode_${c}.app/Contents/Developer" ]; then
        selected_xcode="${c}"
        break
    fi
done
if [ -z "${selected_xcode}" ]; then
    for c in ${xcode_known_bad}; do
        if [ "${DEVELOPER_DIR}" = "/Applications/Xcode_${c}.app/Contents/Developer" ]; then
            die "DEVELOPER_DIR selects Xcode ${c}, which fpc.lock records as KNOWN BAD for FPC 3.2.2"
        fi
    done
    die "DEVELOPER_DIR is '${DEVELOPER_DIR}', which is not one of the pinned macos-xcode-candidates (${xcode_candidates})"
fi

sdk_path="$(xcrun --show-sdk-path)"
sdk_version="$(xcrun --show-sdk-version)"
printf '[CAP-7M0] arch %s, deployment target %s, SDK %s (%s)\n' \
    "${want_arch}" "${deployment_target}" "${sdk_version}" "${sdk_path}"
printf '[CAP-7M0] DEVELOPER_DIR=%s (pinned Xcode %s)\n' \
    "${DEVELOPER_DIR}" "${selected_xcode}"

# --- configure ---------------------------------------------------------------
# The same WEBVIEW_BUILD_* set the Windows and Linux scripts pass: only the
# shared core is ever built, so no test, example, doc, static-library or
# amalgamation target can pull an unreviewed dependency into this build.
#
# WEBVIEW_ENABLE_CHECKS=OFF is the one flag the siblings do not need. MEASURED
# (hosted run 31903389675): configuring deps/webview directly makes it a
# TOP-LEVEL build, so WEBVIEW_ENABLE_CHECKS defaults ON, and webview_init ->
# webview_find_clang_format then hard-fails with
#   Could not find WEBVIEW_CLANG_FORMAT_EXE using the following names:
#   clang-format
# because the Xcode toolchain does not ship clang-format. ubuntu-24.04 and the
# Windows image happen to carry one, which is the only reason the two sibling
# scripts never had to say this out loud. These are upstream's own LINT
# targets, not part of the library: turning them off changes nothing about the
# artifact, and the alternative -- brew-installing clang-format -- would add an
# unpinned build dependency to satisfy a check PWeb never runs.
rm -rf -- "${build_dir}"
cmake -B "${build_dir}" -S "${src}" \
    -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_OSX_ARCHITECTURES=${want_arch}" \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${deployment_target}" \
    -DWEBVIEW_ENABLE_CHECKS=OFF \
    -DWEBVIEW_BUILD_TESTS=OFF \
    -DWEBVIEW_BUILD_EXAMPLES=OFF \
    -DWEBVIEW_BUILD_DOCS=OFF \
    -DWEBVIEW_BUILD_STATIC_LIBRARY=OFF \
    -DWEBVIEW_BUILD_AMALGAMATION=OFF ||
    die 'cmake configure failed'

cache="${build_dir}/CMakeCache.txt"
[ -f "${cache}" ] || die "CMake cache missing: ${cache}"

cache_value() {
    sed -n "s/^$1:[^=]*=\\(.*\\)$/\\1/p" "${cache}" | head -n 1
}

# --- assert what the configure actually RESOLVED -----------------------------
got_system="$(cache_value CMAKE_SYSTEM_NAME)"
[ "${got_system}" = 'Darwin' ] ||
    die "CMake cache CMAKE_SYSTEM_NAME is '${got_system}', expected Darwin"

got_archs="$(cache_value CMAKE_OSX_ARCHITECTURES)"
[ "${got_archs}" = "${want_arch}" ] ||
    die "CMake cache CMAKE_OSX_ARCHITECTURES is '${got_archs}', expected '${want_arch}'"

got_target="$(cache_value CMAKE_OSX_DEPLOYMENT_TARGET)"
[ "${got_target}" = "${deployment_target}" ] ||
    die "CMake cache CMAKE_OSX_DEPLOYMENT_TARGET is '${got_target}', expected '${deployment_target}' -- the SDK decided the minimum"

got_sysroot="$(cache_value CMAKE_OSX_SYSROOT)"

# --- build only the shared core ----------------------------------------------
cmake --build "${build_dir}" --target webview_core_shared ||
    die 'cmake build failed'

# Exact expected output path -- never a recursive first-match, which could
# silently pick a stale artifact from an earlier configuration.
real_lib="${build_dir}/core/${dylib_real}"
[ -f "${real_lib}" ] || die "expected shared library not found: ${real_lib}"

# --- assert the Mach-O, then RECORD what cannot be assumed -------------------
got_slices="$(lipo -archs "${real_lib}")"
[ "${got_slices}" = "${want_arch}" ] ||
    die "built Mach-O carries slices '${got_slices}', expected exactly '${want_arch}'"

# LC_BUILD_VERSION on anything modern; LC_VERSION_MIN_MACOSX only on very old
# toolchains. Accept either shape and read the minimum out of it.
minos="$(otool -l "${real_lib}" |
    awk '/LC_BUILD_VERSION/ { b = 1 } b && /^ *minos / { print $2; exit }')"
if [ -z "${minos}" ]; then
    minos="$(otool -l "${real_lib}" |
        awk '/LC_VERSION_MIN_MACOSX/ { b = 1 } b && /^ *version / { print $2; exit }')"
fi
[ -n "${minos}" ] ||
    die 'the built dylib carries no LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX at all'
# "12.0" and "12.0.0" are the same floor written two ways
case "${minos}" in
    "${deployment_target}"|"${deployment_target}".0) ;;
    *) die "built dylib minos is '${minos}', expected '${deployment_target}'" ;;
esac

# A Cocoa/WKWebView build - and only a Cocoa build - links WebKit.framework.
deps="$(otool -L "${real_lib}")"
printf '%s\n' "${deps}" | grep -q 'WebKit.framework' ||
    die 'the built dylib does not link WebKit.framework -- this is not the Cocoa backend'

install_name="$(otool -D "${real_lib}" | sed -n '2p')"
case "${install_name}" in
    "${install_name_prefix}"*) ;;
    *) die "install name '${install_name}' is not ${install_name_prefix}-relative -- a bundle could not resolve it" ;;
esac

rpaths="$(otool -l "${real_lib}" |
    awk '/LC_RPATH/ { r = 1 } r && /^ *path / { print $2; r = 0 }')"

# --- stage --------------------------------------------------------------------
rm -rf -- "${dist_dir}"
mkdir -p -- "${dist_dir}"

# Regular files, not the symlinks CMake leaves in the build tree: a copy of
# this directory has to be self-contained, and a bundle must never ship a
# dangling link. The versioned name is what LC_LOAD_DYLIB records and
# therefore what the .app carries; the bare name exists so FPC's
# `external 'libwebview.dylib'` resolves at LINK time.
cp -f -- "${real_lib}" "${dist_dir}/${dylib_versioned}"
cp -f -- "${real_lib}" "${dist_dir}/${dylib_link}"

[ -f "${src}/LICENSE" ] || die "upstream licence not found: ${src}/LICENSE"
cp -f -- "${src}/LICENSE" "${dist_dir}/LICENSE.webview"

# --- the measurement record (M3, M16) ----------------------------------------
{
    printf 'CAP7M_PIN lock=%s checkout=%s (verified equal)\n' \
        "${pinned_commit}" "${checkout_commit}"
    printf 'CAP7M_ARCH requested=%s host=%s slices=%s\n' \
        "${want_arch}" "${host_arch}" "${got_slices}"
    printf 'CAP7M_DEPLOYMENT_TARGET pinned=%s minos=%s\n' "${deployment_target}" "${minos}"
    printf 'CAP7M_SDK version=%s path=%s sysroot=%s\n' \
        "${sdk_version}" "${sdk_path}" "${got_sysroot}"
    printf 'CAP7M_XCODE developer_dir=%s pinned_candidate=%s\n' \
        "${DEVELOPER_DIR}" "${selected_xcode}"
    printf 'CAP7M_INSTALL_NAME %s\n' "${install_name}"
    if [ -n "${rpaths}" ]; then
        printf '%s\n' "${rpaths}" | while IFS= read -r p; do
            [ -n "${p}" ] && printf 'CAP7M_LC_RPATH %s\n' "${p}"
        done
    else
        printf 'CAP7M_LC_RPATH <none>\n'
    fi
    printf '%s\n' "${deps}" | sed 's/^/CAP7M_OTOOL_L /'
} > "${dist_dir}/measurements.txt"

# Also append to the SHARED record, which survives this script's own
# `rm -rf "${dist_dir}"` on the next run and is uploaded whatever happens.
mkdir -p -- "$(dirname -- "${measurements}")"
cat "${dist_dir}/measurements.txt" >> "${measurements}"

cat "${dist_dir}/measurements.txt"
printf '[CAP-7M0] %s -> %s/%s (pin %s)\n' \
    "$(basename -- "${real_lib}")" "${dist_dir}" "${dylib_versioned}" "${pinned_commit}"
