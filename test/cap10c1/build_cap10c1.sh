#!/usr/bin/env bash
#
# CAP-10C1 (Linux and macOS): complete the SDK root, and build the private
# pipeline driver and its suite.
#
# The POSIX twin of build_cap10c1.ps1, making the identical claims in the
# identical order. Two things differ per platform and both are at the seam
# rather than in the claim:
#
#   - there is NO CAP-3U window. That patch is Windows-only (it assembles a
#     COFF object with MSVC's ml64), so a POSIX SDK stages the pinned mORMot
#     source as it is, and static/delphi - which holds COFF objects reached
#     from inside mORMot's Win64 sources by a relative path - is NOT staged;
#   - the platform artifact is the webview shared library of this target,
#     plus, on macOS, the compiled production Cocoa bridge object.
#
# Produces, all under build/cap10c1/:
#   iso/   isolation compiles (no binary kept) - the LAYERING proof
#   bin/   pwebpipe   the private lifecycle driver
#          c1tests    the CAP-10C1 suite
#
# and completes build/cap10b1/sdk with:
#   bin/pwebbundle
#   share/pweb/deps/mormot2/{src, static/<fpc-target>}
#   share/pweb/lib/<os>-<arch>/
#
# Usage: test/cap10c1/build_cap10c1.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10C1] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10C1] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
sdk="${repo_root}/build/cap10b1/sdk"
bundler="${repo_root}/build/cap10b1/bin/pwebbundle"
for pre in "${sdk}/bin/pweb" "${sdk}/share/pweb/src/webview/pweb.webview.host.pas" \
           "${bundler}" 'deps/mormot2/src/core/mormot.core.base.pas'; do
    [ -e "${pre}" ] ||
        die "missing precondition: ${pre} -- run test/cap10b1/build_cap10b1.sh first"
done

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
printf '[CAP-10C1] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

case "${target_os}" in
darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    case "${target_cpu}" in
        x86_64)  target='macos-x86_64'; fpc_target='x86_64-darwin' ;;
        aarch64) target='macos-arm64';  fpc_target='aarch64-darwin' ;;
        *) die "unsupported macOS CPU ${target_cpu}" ;;
    esac
    lib_src="${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}"
    lib_name="${PWEB_MACOS_DYLIB_VERSIONED}"
    bridge_src="${PWEB_MACOS_BRIDGE_OBJ}"
    [ -f "${lib_src}" ] || die "staged dylib missing: ${lib_src}"
    [ -f "${bridge_src}" ] ||
        die "production Cocoa bridge object missing: ${bridge_src} -- run test/cap7m/build_cap7m.sh first"
    ;;
linux)
    [ "${target_cpu}" = 'x86_64' ] ||
        die "CAP-10C1 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
    target='linux-x86_64'
    fpc_target='x86_64-linux'
    lib_name='libwebview.so.0.12'
    lib_src="${repo_root}/build/cap7l/webview-dist/${lib_name}"
    bridge_src=''
    [ -f "${lib_src}" ] || die "staged webview library missing: ${lib_src}"
    ;;
*)
    die "unsupported FPC target OS ${target_os}"
    ;;
esac
[ -d "deps/mormot2/static/${fpc_target}" ] ||
    die "mORMot statics missing: deps/mormot2/static/${fpc_target}"

# --- 1. the frozen bundler, beside the CLI ---------------------------------
step 'the frozen CAP-6 bundler, into the SDK root'
cp -f -- "${bundler}" "${sdk}/bin/"

# --- 2. mORMot, into the SDK root ------------------------------------------
# ONLY what a project compiles against: the eight unit directories named by
# pweb.cli.native's PWEB_MORMOT_UNIT_DIRS plus the include root's own files.
# An installation ships what a project compiles against, and a staging rule
# that copies whatever happens to be there is a staging rule that will one
# day ship somebody's test.
step 'mORMot sources and statics, into the SDK root'
mormot_out="${sdk}/share/pweb/deps/mormot2"
rm -rf -- "${mormot_out}"
mkdir -p -- "${mormot_out}/src" "${mormot_out}/static"
for d in core lib crypt net db orm rest soa; do
    cp -R -- "deps/mormot2/src/${d}" "${mormot_out}/src/"
done
find deps/mormot2/src -maxdepth 1 -type f -exec cp -f -- {} "${mormot_out}/src/" \;
cp -R -- "deps/mormot2/static/${fpc_target}" "${mormot_out}/static/"

# --- 3. the platform artifacts ---------------------------------------------
step "the ${target} platform artifacts, into the SDK root"
lib_dir="${sdk}/share/pweb/lib/${target}"
rm -rf -- "${lib_dir}"
mkdir -p -- "${lib_dir}"
cp -f -- "${lib_src}" "${lib_dir}/${lib_name}"
if [ -n "${bridge_src}" ]; then
    cp -f -- "${bridge_src}" "${lib_dir}/pweb_cocoa_bridge.o"
fi

for artifact in "${sdk}/bin/pwebbundle" \
                "${mormot_out}/src/core/mormot.core.base.pas" \
                "${mormot_out}/src/mormot.defines.inc" \
                "${mormot_out}/static/${fpc_target}" \
                "${lib_dir}/${lib_name}"; do
    [ -e "${artifact}" ] || die "expected ${artifact}"
done
printf '[CAP-10C1] SDK root completed at build/cap10b1/sdk for %s\n' "${target}"

# --- 4. layering: no pipeline unit may reach a webview unit ----------------
step 'layering: the pipeline units are webview-free'
rm -rf -- build/cap10c1/iso build/cap10c1/test-units build/cap10c1/bin
mkdir -p -- build/cap10c1/iso build/cap10c1/test-units build/cap10c1/bin

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

for unit in sdkroot stage toolset frontend pack native layout pipeline; do
    fpc -MObjFPC -Sh -B -FUbuild/cap10c1/iso \
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_core[@]}" "tools/pweb/pweb.cli.${unit}.pas" ||
        die "pweb.cli.${unit}.pas failed its isolation compile"
done

# --- 5. the driver and the suite -------------------------------------------
step 'the private driver and the suite'
for prog in pwebpipe c1tests; do
    fpc -Sh -B -FUbuild/cap10c1/test-units -FEbuild/cap10c1/bin \
        -Futools/pweb -Futest/cap10c1 -Fusrc/rpc -Fusrc/security \
        -Fusrc/assets "${mormot_test[@]}" \
        "-Fldeps/mormot2/static/${fpc_target}" \
        "test/cap10c1/${prog}.pas" || die "${prog}.pas compile FAILED"
    [ -x "build/cap10c1/bin/${prog}" ] ||
        die "expected build/cap10c1/bin/${prog}"
done
# the deliberately wrong compiler the TC2/TC3 refusals are measured with,
# named `fpc` because that is what PATH resolution has to find. RTL-only.
fpc -Sh -B -FUbuild/cap10c1/test-units -FEbuild/cap10c1/bin \
    test/cap10c1/fakefpc.pas || die 'fakefpc.pas compile FAILED'
mkdir -p -- build/cap10c1/fake
cp -f -- build/cap10c1/bin/fakefpc build/cap10c1/fake/fpc
chmod +x build/cap10c1/fake/fpc

# THE DRIVER LIVES IN THE SDK's OWN bin/, and that is the point: it resolves
# the SDK root from the RUNNING IMAGE by the CAP-10B0 anchor rule, with no
# parameter and no environment variable, exactly as the shipped `pweb` does.
# A driver that took the root as a flag would be proving a different claim.
cp -f -- build/cap10c1/bin/pwebpipe "${sdk}/bin/"

printf '[CAP-10C1] pwebpipe + c1tests built; layering compiles clean\n'
