#!/usr/bin/env bash
#
# Builds libwebview.so (upstream webview::core_shared, C ABI exports) from the
# PINNED checkout in deps/webview, using cmake + the distro GCC toolchain.
#
# The Linux sibling of tools/build-webview-dll.ps1, deliberately the same
# shape: configure with the pinned flags, ASSERT what the configure actually
# resolved, build only webview_core_shared, stage the artifact with its
# licence. Nothing here is autodetected.
#
# ONE RATIFIED STACK (webview.lock, CAP-7L):
#   GTK 3 + WebKitGTK API 4.1 (webkit2gtk-4.1, libsoup3), x86_64, glibc.
# Upstream's CMakeLists uses pkg_search_module with a fallback chain
# (webkitgtk-6.0 -> 4.1 -> 4.0). That chain must NEVER pick our engine: we
# pass -DWEBVIEW_WEBKITGTK_API explicitly and then re-read CMakeCache.txt to
# prove which module pkg-config actually resolved. A machine that happens to
# have webkitgtk-6.0 installed must fail this script, not silently build a
# different product.
#
# Output: build/cap7l/webview-dist/
#           libwebview.so.0.12      the SONAME - the file the release ships
#                                   (MEASURED: FPC records the SONAME, not the
#                                   chet LibraryName, as DT_NEEDED)
#           libwebview.so           dev-only link-time name for FPC's -Fl
#           LICENSE.webview
#
# Usage:  tools/build-webview-so.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

src="${repo_root}/deps/webview"
build_dir="${repo_root}/build/cap7l/webview-build"
dist_dir="${repo_root}/build/cap7l/webview-dist"
lock_file="${repo_root}/webview.lock"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }

# --- read the lock (strict: one 'key = value' per non-comment line) ----------
lock_get() {
    local wanted="$1" line key value found='' result=''
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        case "${line}" in '#'*) continue ;; esac
        case "${line}" in *=*) ;; *) die "webview.lock line is malformed: ${line}" ;; esac
        key="$(printf '%s' "${line%%=*}" | sed -e 's/[[:space:]]*$//')"
        value="$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//')"
        if [ "${key}" = "${wanted}" ]; then
            [ -n "${found}" ] && die "webview.lock contains duplicate key '${wanted}'"
            found=1
            result="${value}"
        fi
    done < "${lock_file}"
    [ -n "${found}" ] || die "webview.lock has no '${wanted}' entry"
    printf '%s' "${result}"
}

[ -f "${lock_file}" ] || die "webview.lock missing: ${lock_file}"
[ -f "${src}/CMakeLists.txt" ] || die 'deps/webview missing -- run tools/get-webview.ps1 first'

pinned_commit="$(lock_get commit)"
case "${pinned_commit}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "webview.lock does not pin a full 40-char lowercase SHA: ${pinned_commit}" ;;
esac

webkitgtk_api="$(lock_get linux-webkitgtk-api)"
gtk_api="$(lock_get linux-gtk-api)"
soname="$(lock_get linux-soname)"

# The ratified stack is a FACT of this capability, not a variable: a lock that
# says something else is a deliberate re-ratification and must not be honoured
# by a script that was reviewed against 4.1/3.0.
[ "${webkitgtk_api}" = '4.1' ] || die "unexpected WebKitGTK API pin '${webkitgtk_api}'"
[ "${gtk_api}" = '3.0' ] || die "unexpected GTK API pin '${gtk_api}'"
[ "${soname}" = 'libwebview.so.0.12' ] || die "unexpected soname pin '${soname}'"

expected_webkit_module="webkit2gtk-${webkitgtk_api}"
expected_gtk_module="gtk+-${gtk_api}"

# --- x86_64 only (Never: Linux ARM64 or i386) --------------------------------
host_arch="$(uname -m)"
[ "${host_arch}" = 'x86_64' ] || die "CAP-7L targets x86_64 only, host is ${host_arch}"

for tool in cmake pkg-config readelf nm; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

# --- distro-provided engine: present at BUILD time, never installed by us ----
pkg-config --exists "${expected_webkit_module}" ||
    die "${expected_webkit_module} development files are missing (apt install libwebkit2gtk-4.1-dev)"
pkg-config --exists "${expected_gtk_module}" ||
    die "${expected_gtk_module} development files are missing (apt install libgtk-3-dev)"

printf '[CAP-7L] engine: %s %s, %s %s\n' \
    "${expected_webkit_module}" "$(pkg-config --modversion "${expected_webkit_module}")" \
    "${expected_gtk_module}" "$(pkg-config --modversion "${expected_gtk_module}")"

# --- configure ---------------------------------------------------------------
# The same WEBVIEW_BUILD_* set tools/build-webview-dll.ps1 passes: only the
# shared core is ever built, so no test, example, doc, static-library or
# amalgamation target can pull an unreviewed dependency into this build.
rm -rf -- "${build_dir}"
cmake -B "${build_dir}" -S "${src}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "-DWEBVIEW_WEBKITGTK_API=${webkitgtk_api}" \
    -DWEBVIEW_BUILD_TESTS=OFF \
    -DWEBVIEW_BUILD_EXAMPLES=OFF \
    -DWEBVIEW_BUILD_DOCS=OFF \
    -DWEBVIEW_BUILD_STATIC_LIBRARY=OFF \
    -DWEBVIEW_BUILD_AMALGAMATION=OFF ||
    die 'cmake configure failed'

cache="${build_dir}/CMakeCache.txt"
[ -f "${cache}" ] || die "CMake cache missing: ${cache}"

# --- assert what the configure actually RESOLVED -----------------------------
# These are the load-bearing lines: WEBVIEW_WEBKITGTK_MODULE_NAME is written by
# pkg_search_module with the module it settled on, so it - not our -D flag -
# is the proof that the fallback chain did not decide.
cache_value() {
    sed -n "s/^$1:[^=]*=\\(.*\\)$/\\1/p" "${cache}" | head -n 1
}

got_api="$(cache_value WEBVIEW_WEBKITGTK_API)"
[ "${got_api}" = "${webkitgtk_api}" ] ||
    die "CMake cache WEBVIEW_WEBKITGTK_API is '${got_api}', expected '${webkitgtk_api}'"

[ "$(cache_value WEBVIEW_WEBKITGTK_FOUND)" = '1' ] ||
    die 'CMake did not find a WebKitGTK module at all'
[ "$(cache_value WEBVIEW_GTK_FOUND)" = '1' ] ||
    die 'CMake did not find a GTK module at all'

got_webkit_module="$(cache_value WEBVIEW_WEBKITGTK_MODULE_NAME)"
[ "${got_webkit_module}" = "${expected_webkit_module}" ] ||
    die "CMake resolved '${got_webkit_module}', not the ratified '${expected_webkit_module}' -- the pkg_search_module fallback decided"

got_gtk_module="$(cache_value WEBVIEW_GTK_MODULE_NAME)"
[ "${got_gtk_module}" = "${expected_gtk_module}" ] ||
    die "CMake resolved '${got_gtk_module}', not the ratified '${expected_gtk_module}'"

got_webkit_version="$(cache_value WEBVIEW_WEBKITGTK_VERSION)"
got_gtk_version="$(cache_value WEBVIEW_GTK_VERSION)"

# --- build only the shared core ----------------------------------------------
cmake --build "${build_dir}" --target webview_core_shared ||
    die 'cmake build failed'

# Exact expected output path -- never a recursive first-match, which could
# silently pick a stale artifact from an earlier configuration.
real_lib="${build_dir}/core/${soname}.0"
[ -f "${real_lib}" ] || die "expected shared library not found: ${real_lib}"

got_soname="$(readelf -d "${real_lib}" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -n 1)"
[ "${got_soname}" = "${soname}" ] ||
    die "built SONAME is '${got_soname}', expected the pinned '${soname}'"

# --- stage --------------------------------------------------------------------
rm -rf -- "${dist_dir}"
mkdir -p -- "${dist_dir}"

# The SONAME name is what DT_NEEDED records and therefore what the release
# layout ships; stage it as a REGULAR FILE so a copy of this directory is
# self-contained even on a filesystem without symlink support (the repository
# build tree lives on DrvFs under WSL on the dev host).
cp -f -- "${real_lib}" "${dist_dir}/${soname}"

# Dev-only link-time name. FPC's `external 'libwebview.so'` makes the linker
# look for exactly this file; it then records the SONAME it reads out of it,
# which is why the runtime only ever needs the versioned name beside the
# executable. A copy rather than a symlink for the same DrvFs reason - the
# linker reads the SONAME either way.
cp -f -- "${real_lib}" "${dist_dir}/libwebview.so"

[ -f "${src}/LICENSE" ] || die "upstream licence not found: ${src}/LICENSE"
cp -f -- "${src}/LICENSE" "${dist_dir}/LICENSE.webview"

printf '[CAP-7L] %s -> %s/%s\n' "$(basename -- "${real_lib}")" "${dist_dir}" "${soname}"
printf '[CAP-7L] engine resolved: %s %s + %s %s (pin %s)\n' \
    "${got_webkit_module}" "${got_webkit_version}" \
    "${got_gtk_module}" "${got_gtk_version}" "${pinned_commit}"
