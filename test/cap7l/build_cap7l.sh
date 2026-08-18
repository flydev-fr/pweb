#!/usr/bin/env bash
#
# CAP-7L: compile everything the Linux gates run.
#
# Layering is proven by the COMPILER here, exactly as the Windows job does
# it: each isolation compile is given only the unit paths its layer is
# allowed to see, so a dependency creeping the wrong way fails this script
# rather than being discovered later by reading code.
#
# Produces, all under build/cap7l/:
#   iso/          isolation compiles (no binaries kept)
#   bin/          pwebtests, signature_pin, cap7l_probe, mkappzip, pwebbundle
#   ex/           assetsapp, releaseapp
#
# Prerequisites: tools/build-webview-so.sh has staged
# build/cap7l/webview-dist, and deps/webview + deps/mormot2 are present.
#
# Usage: test/cap7l/build_cap7l.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7L] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
command -v cc >/dev/null 2>&1 || die 'required tool not found: cc'
command -v pkg-config >/dev/null 2>&1 || die 'required tool not found: pkg-config'

dist='build/cap7l/webview-dist'
[ -f "${dist}/libwebview.so" ] ||
    die "staged webview library missing -- run tools/build-webview-so.sh first"
[ -d 'deps/mormot2/static/x86_64-linux' ] ||
    die 'mORMot Linux statics missing -- fetch deps/mormot2 first'

# FPC target sanity: CAP-7L is ratified for Linux/x86_64 only.
target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[ "${target_os}" = 'linux' ] || die "expected FPC target linux, got ${target_os}"
[ "${target_cpu}" = 'x86_64' ] ||
    die "CAP-7L is ratified for x86_64 only, FPC targets ${target_cpu}"
printf '[CAP-7L] fpc %s targeting %s/%s\n' "$(fpc -iV)" "${target_os}" "${target_cpu}"

rm -rf -- build/cap7l/iso build/cap7l/bin build/cap7l/ex build/cap7l/units
mkdir -p -- build/cap7l/iso build/cap7l/bin build/cap7l/ex build/cap7l/units

mormot_units=(
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
mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
)
link_webview=(
    -Fldeps/mormot2/static/x86_64-linux
    "-Fl${dist}"
    -k'-rpath=$ORIGIN'
)

# --- raw binding layer --------------------------------------------------------
step 'binding units (the regenerated 4-branch platform block)'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso -Fusrc/lib src/lib/pweb.lib.webview.pas ||
    die 'pweb.lib.webview.pas failed to compile for Linux'
fpc -MObjFPC -Sh -FUbuild/cap7l/iso -Fusrc/lib src/lib/pweb.lib.webview.types.pas ||
    die 'pweb.lib.webview.types.pas failed'
fpc -MObjFPC -Sh -FUbuild/cap7l/iso -Fusrc/lib src/lib/pweb.lib.webview.errors.pas ||
    die 'pweb.lib.webview.errors.pas failed'

# --- layering isolation compiles ---------------------------------------------
step 'isolation compiles (each layer sees only what it may)'
# the scheduler must still be source-generic and RTL-only on Linux too
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso -Fusrc/rpc src/rpc/pweb.rpc.support.pas ||
    die 'pweb.rpc.support.pas failed its RTL-only intf-only compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso -Fusrc/rpc src/rpc/pweb.rpc.scheduler.pas ||
    die 'pweb.rpc.scheduler.pas failed its webview-free RTL-only compile'
# CAP-8A: the production capability engine stays RTL-only on Linux too
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso -Fusrc/rpc -Fusrc/security \
    src/security/pweb.capabilities.policy.pas ||
    die 'pweb.capabilities.policy.pas failed its RTL-only isolation compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso src/rpc/pweb.rpc.intf.pas ||
    die 'pweb.rpc.intf.pas is not RTL-only'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso src/webview/pweb.webview.intf.pas ||
    die 'pweb.webview.intf.pas failed RTL-only compile'
# the stores stay webview-free
for unit in support folder zip; do
    fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso -Fusrc/assets "${mormot_core[@]}" \
        "src/assets/pweb.assets.${unit}.pas" ||
        die "pweb.assets.${unit}.pas failed its isolation compile"
done
# the Linux handler adds only src/lib on top of the stores: it must never
# pull the rpc scheduler or the CAP-2 binding into the resource path
fpc -MObjFPC -Sh -B -FUbuild/cap7l/iso -Fusrc/assets -Fusrc/lib \
    -Fusrc/platform/linux "${mormot_core[@]}" \
    src/platform/linux/pweb.platform.webkitgtk.pas ||
    die 'pweb.platform.webkitgtk.pas failed its isolation compile'

# --- compile-only ABI gate ----------------------------------------------------
step 'signature pin (all 17 prototypes)'
fpc -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/bin -Fusrc/lib \
    -Fideps/mormot2/src "${link_webview[@]}" test/core/signature_pin.pas ||
    die 'signature pin failed: binding signatures drifted'

# --- test suite ---------------------------------------------------------------
step 'PWeb test suite (adds the CAP-7L Linux adapter cases)'
fpc -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/bin \
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
    -Fusrc/platform/linux \
    -Futest/core -Futest/rpc -Futest/security -Futest/assets \
    -Futest/platform \
    "${mormot_units[@]}" "${link_webview[@]}" test/core/pwebtests.pas ||
    die 'pwebtests failed to compile'

# --- reference C probe --------------------------------------------------------
step 'CAP-7L reference C probe'
# shellcheck disable=SC2046
cc -O1 -Wall -Wextra -Werror -pthread \
    -Ideps/webview/core/include \
    $(pkg-config --cflags webkit2gtk-4.1) \
    test/cap7l/cap7l_probe.c -o build/cap7l/bin/cap7l_probe \
    -Wl,-rpath,'$ORIGIN' -L"${dist}" -lwebview \
    $(pkg-config --libs webkit2gtk-4.1) ||
    die 'cap7l_probe failed to compile'
cp -f -- "${dist}/libwebview.so.0.12" build/cap7l/bin/

# --- tools and examples -------------------------------------------------------
step 'bundler and packaging tools'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/bin \
    "${mormot_core[@]}" -Fldeps/mormot2/static/x86_64-linux \
    examples/06-assets/mkappzip.pas ||
    die 'mkappzip failed to compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/bin \
    -Fusrc/assets "${mormot_core[@]}" -Fldeps/mormot2/static/x86_64-linux \
    tools/bundler/pwebbundle.pas ||
    die 'pwebbundle failed to compile'

step 'runtime examples (the real apps, not Linux demos)'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/ex \
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
    -Fusrc/platform/linux "${mormot_units[@]}" "${link_webview[@]}" \
    examples/06-assets/assetsapp.pas ||
    die 'assetsapp failed to compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/ex \
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets \
    -Fusrc/platform/linux "${mormot_units[@]}" "${link_webview[@]}" \
    examples/08-release/releaseapp.pas ||
    die 'releaseapp failed to compile'
cp -f -- "${dist}/libwebview.so.0.12" build/cap7l/ex/

# --- MEASURED: FPC records the SONAME, not the chet LibraryName --------------
needed="$(readelf -d build/cap7l/ex/releaseapp |
    sed -n 's/.*NEEDED.*\[\(libwebview[^]]*\)\].*/\1/p' | head -n 1)"
[ "${needed}" = 'libwebview.so.0.12' ] ||
    die "releaseapp records DT_NEEDED '${needed}', expected libwebview.so.0.12"
runpath="$(readelf -d build/cap7l/ex/releaseapp |
    sed -n 's/.*RUNPATH.*\[\(.*\)\].*/\1/p' | head -n 1)"
[ "${runpath}" = '$ORIGIN' ] ||
    die "releaseapp RUNPATH is '${runpath}', expected \$ORIGIN (no CWD dependence)"

printf '\n[CAP-7L] build_cap7l: PASS (DT_NEEDED=%s RUNPATH=%s)\n' \
    "${needed}" "${runpath}"
