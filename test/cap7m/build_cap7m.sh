#!/usr/bin/env bash
#
# CAP-7M0 PROBES I and J: compile everything the macOS gates run, natively,
# on THIS architecture, with the deployment target passed explicitly to every
# compile and every link.
#
# PROBE J is the whole point of this script existing per-architecture rather
# than once: "FPC hosts natively, mORMot core compiles, the binding compiles"
# is a claim about x86_64-darwin AND aarch64-darwin separately, and one arch
# failing is reported, never silently dropped by a matrix leg that quietly
# reused the other's artifacts.
#
# Layering is proven by the COMPILER, exactly as the Windows and Linux jobs do
# it: each isolation compile is given only the unit paths its layer may see,
# so a dependency creeping the wrong way fails here rather than being
# discovered later by reading code.
#
# NOTHING PRODUCTION IS BUILT HERE. There is no macOS adapter, no ported
# example and no packaging in this shard; the artifacts below are the ABI
# gate, the URI oracle and the throwaway feasibility probe.
#
# Produces, all under build/cap7m/:
#   iso/   isolation compiles (no binaries kept)
#   bin/   uri_oracle, cap7m_probe, signature_pin
#
# Prerequisites: tools/build-webview-dylib.sh has staged
# build/cap7m/webview-dist, and deps/webview + deps/mormot2 are present.
#
# Usage: test/cap7m/build_cap7m.sh
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
assert_fpc_target
record_environment

command -v clang++ >/dev/null 2>&1 || die 'required tool not found: clang++'
command -v otool >/dev/null 2>&1 || die 'required tool not found: otool'

dylib_link="$(lock_get macos-dylib)"
dylib_versioned="$(lock_get macos-dylib-versioned)"
deployment_target="$(lock_get macos-deployment-target)"
host_arch="$(uname -m)"

[ -f "${dist}/${dylib_link}" ] ||
    die 'staged webview dylib missing -- run tools/build-webview-dylib.sh first'

# FPC and mORMot spell aarch64 the same way; the lock spells it arm64.
case "$(fpc -iTP | tr -d '[:space:]')" in
    x86_64) static_dir='deps/mormot2/static/x86_64-darwin' ;;
    aarch64) static_dir='deps/mormot2/static/aarch64-darwin' ;;
    *) die "unsupported FPC target CPU $(fpc -iTP)" ;;
esac
[ -d "${static_dir}" ] ||
    die "mORMot Darwin statics missing: ${static_dir} -- fetch deps/mormot2 first"

rm -rf -- build/cap7m/iso build/cap7m/bin build/cap7m/units
mkdir -p -- build/cap7m/iso build/cap7m/bin build/cap7m/units

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
)
# -WM<version> is FPC's deployment target. Passed on EVERY compile, never
# left to the SDK: an executable whose LC_BUILD_VERSION disagrees with the
# dylib's is a support matrix nobody ratified.
link_webview=(
    "-WM${deployment_target}"
    "-Fl${static_dir}"
    "-Fl${dist}"
    -k-rpath
    -k@executable_path
)

# --- raw binding layer --------------------------------------------------------
step 'binding units (the regenerated 4-branch platform block, Darwin arm)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/lib "-WM${deployment_target}" \
    src/lib/pweb.lib.webview.pas ||
    die 'pweb.lib.webview.pas failed to compile for Darwin'
fpc -MObjFPC -Sh -FUbuild/cap7m/iso -Fusrc/lib "-WM${deployment_target}" \
    src/lib/pweb.lib.webview.types.pas || die 'pweb.lib.webview.types.pas failed'
fpc -MObjFPC -Sh -FUbuild/cap7m/iso -Fusrc/lib "-WM${deployment_target}" \
    src/lib/pweb.lib.webview.errors.pas || die 'pweb.lib.webview.errors.pas failed'

# --- layering isolation compiles ---------------------------------------------
step 'isolation compiles (each layer sees only what it may)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso "-WM${deployment_target}" \
    src/rpc/pweb.rpc.intf.pas || die 'pweb.rpc.intf.pas is not RTL-only'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso "-WM${deployment_target}" \
    src/webview/pweb.webview.intf.pas ||
    die 'pweb.webview.intf.pas failed RTL-only compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/rpc "-WM${deployment_target}" \
    src/rpc/pweb.rpc.scheduler.pas ||
    die 'pweb.rpc.scheduler.pas failed its webview-free RTL-only compile'
# the stores stay webview-free on Darwin too
for unit in support folder zip; do
    fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/assets "${mormot_core[@]}" \
        "-WM${deployment_target}" "src/assets/pweb.assets.${unit}.pas" ||
        die "pweb.assets.${unit}.pas failed its isolation compile"
done

# --- compile-only ABI gate ----------------------------------------------------
step 'signature pin (all 17 prototypes)'
fpc -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin -Fusrc/lib \
    -Fideps/mormot2/src "${link_webview[@]}" test/core/signature_pin.pas ||
    die 'signature pin failed: binding signatures drifted'

# --- the URI oracle -----------------------------------------------------------
# Also PROBE J's "mORMot core compiles" leg: this pulls mormot.core.base and
# links the Darwin statics for this architecture.
step 'URI oracle (the shared PWebParseAppUri, on Darwin)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin \
    -Fusrc/assets "${mormot_core[@]}" "-WM${deployment_target}" \
    "-Fl${static_dir}" test/cap7m/uri_oracle.pas ||
    die 'uri_oracle failed to compile'

# --- the feasibility probe ----------------------------------------------------
step 'CAP-7M0 Objective-C++ feasibility probe'
# -DWEBVIEW_SHARED is MANDATORY and easy to miss: macros.h defines
# WEBVIEW_API as `inline` for a C++ translation unit that declares neither
# WEBVIEW_SHARED nor WEBVIEW_STATIC (core/include/webview/macros.h:45-60), so
# without it every one of the 17 prototypes becomes an inline function with
# no definition. test/cap4w/CMakeLists.txt:33 passes it for the same reason.
#
# -fno-objc-arc on purpose: the probe measures ownership (the +new return
# value, the retained tasks, the response buffer handoff), and ARC would hide
# exactly what is under measurement.
#
# -std=c++17 matches the Windows probe (test/cap4w/CMakeLists.txt:31); -arch
# and -mmacosx-version-min are explicit for the same reason every other
# compile here is.
clang++ -std=c++17 -fno-objc-arc -O1 -Wall -Wextra -Werror \
    -DWEBVIEW_SHARED \
    -arch "${host_arch}" "-mmacosx-version-min=${deployment_target}" \
    -Ideps/webview/core/include \
    -framework Cocoa -framework WebKit \
    test/cap7m/cap7m_probe.mm -o build/cap7m/bin/cap7m_probe \
    -Wl,-rpath,@executable_path -L"${dist}" -lwebview ||
    die 'cap7m_probe failed to compile'

cp -f -- "${dist}/${dylib_versioned}" build/cap7m/bin/

# --- MEASURED: what the linker actually recorded ------------------------------
# The Linux sibling asserts DT_NEEDED == the SONAME here. The Mach-O statement
# of the same fact is LC_LOAD_DYLIB == the install name, which is why the
# VERSIONED file is what ships and the bare .dylib is a link-time convenience.
# LC_BUILD_VERSION on anything modern, LC_VERSION_MIN_MACOSX on older
# toolchains. The fallback matters MORE here than in the dylib build that
# already has it: these binaries are linked by FPC 3.2.2, the oldest
# toolchain in this shard and therefore the likeliest to emit the old load
# command. Without it the read-back returns the empty string and the gate
# dies with "minos is ''", which reads as a deployment-target violation when
# the target is in fact correct.
read_minos() {
    local out
    out="$(otool -l "$1" |
        awk '/LC_BUILD_VERSION/ { b = 1 } b && /^ *minos / { print $2; exit }')"
    if [ -z "${out}" ]; then
        out="$(otool -l "$1" |
            awk '/LC_VERSION_MIN_MACOSX/ { b = 1 } b && /^ *version / { print $2; exit }')"
    fi
    printf '%s' "${out}"
}

# EVERY binary this script produced, not just the two that link the dylib:
# uri_oracle and the probe are compiled with an explicit floor too, and an
# unverified -WM is exactly the "the SDK decided it" failure M16 exists to
# exclude.
for binary in build/cap7m/bin/cap7m_probe build/cap7m/bin/signature_pin \
              build/cap7m/bin/uri_oracle; do
    [ -x "${binary}" ] || die "expected binary missing: ${binary}"
    name="$(basename -- "${binary}")"

    minos="$(read_minos "${binary}")"
    [ -n "${minos}" ] ||
        die "${binary} carries neither LC_BUILD_VERSION nor LC_VERSION_MIN_MACOSX"
    case "${minos}" in
        "${deployment_target}"|"${deployment_target}".0) ;;
        *) die "${binary} minos is '${minos}', expected '${deployment_target}'" ;;
    esac

    # uri_oracle links no dylib and needs no rpath; the other two do both.
    case "${name}" in
        uri_oracle)
            record_measurement "CAP7M_M16 binary=${name} minos=${minos}"
            continue
            ;;
    esac

    loaded="$(otool -L "${binary}" | awk '/libwebview/ { print $1; exit }')"
    [ -n "${loaded}" ] || die "${binary} records no libwebview load command"
    case "${loaded}" in
        *"${dylib_versioned}") ;;
        *) die "${binary} loads '${loaded}', expected a path ending ${dylib_versioned}" ;;
    esac
    rpath="$(otool -l "${binary}" |
        awk '/LC_RPATH/ { r = 1 } r && /^ *path / { print $2; r = 0 }' |
        grep -x '@executable_path' || true)"
    [ "${rpath}" = '@executable_path' ] ||
        die "${binary} has no LC_RPATH @executable_path (CWD dependence)"
    record_measurement "CAP7M_M16 binary=${name} minos=${minos} load=${loaded} rpath=${rpath}"
done

printf '\n[CAP-7M0] build_cap7m: PASS (%s, deployment target %s)\n' \
    "${host_arch}" "${deployment_target}"
