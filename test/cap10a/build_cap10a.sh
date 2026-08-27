#!/usr/bin/env bash
#
# CAP-10A: compile everything the POSIX CLI gates run - Linux and macOS from
# ONE script, because the CLI has no platform-specific build step of its own.
# The only divergence is where the mORMot statics live and, on Darwin, the
# ratified deployment-target and link flags, both of which come from
# tools/macos-buildenv.sh rather than from anything written here.
#
# Produces, all under build/cap10a/:
#   iso/   isolation compiles (no binary kept) - the LAYERING proof
#   bin/   pweb           the public CLI
#          clitests       the CAP-10A suite (C/P/D matrices)
#          probechild     the deliberately badly behaved probe fixture
#
# LAYERING IS PROVEN BY THE COMPILER, exactly as build_cap10a.ps1 does it on
# Windows: each isolation compile is given only the unit paths its layer may
# see. Two claims are worth naming: pweb.rpc.command compiles with the rpc +
# security + assets layers and no webview, platform, REST or SOA unit at all;
# and the CLI compiles with NO webview unit path, so `pweb doctor` cannot
# open a window because the units that could are not on its path.
#
# NOTE the deliberate asymmetry with Windows: there is no src/platform/<os>
# path here. The Windows CLI uses the ratified CAP-6b0 WebView2 DETECTOR
# (registry reads only); Linux and macOS answer the same question from the
# dynamic linker and from sysctl, inside pweb.cli.platform, with no platform
# unit involved.
#
# Usage: test/cap10a/build_cap10a.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10A] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10A] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
[ -f 'deps/mormot2/src/core/mormot.core.base.pas' ] ||
    die 'deps/mormot2 missing -- fetch it first'

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
printf '[CAP-10A] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

# Darwin decisions come from the ONE place they are allowed to come from.
# A space-separated STRING, not an array: macOS still ships bash 3.2, where
# "${arr[@]}" under `set -u` on an empty array is an error.
platform_flags=''
case "${target_os}" in
    darwin)
        # shellcheck source=tools/macos-buildenv.sh
        . "${repo_root}/tools/macos-buildenv.sh"
        pweb_macos_init_fpc
        static_dir="${PWEB_MACOS_STATIC_DIR}"
        platform_flags="${PWEB_MACOS_FPC_FLAGS[*]} ${PWEB_MACOS_FPC_ARCH_LINK_FLAGS}"
        ;;
    linux)
        [ "${target_cpu}" = 'x86_64' ] ||
            die "CAP-10A Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
        static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
        ;;
    *)
        die "unsupported FPC target OS ${target_os}"
        ;;
esac
[ -d "${static_dir}" ] || die "mORMot statics missing: ${static_dir}"

rm -rf -- build/cap10a/iso build/cap10a/cli-units build/cap10a/test-units build/cap10a/bin
mkdir -p -- build/cap10a/iso build/cap10a/cli-units build/cap10a/test-units build/cap10a/bin

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

step 'layering: the reusable runtime-command layer is webview-free'
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FUbuild/cap10a/iso \
    -Fusrc/rpc -Fusrc/security -Fusrc/assets "${mormot_core[@]}" \
    ${platform_flags} src/rpc/pweb.rpc.command.pas ||
    die 'pweb.rpc.command.pas failed its webview-free isolation compile'

step 'layering: the CLI units, each with only what it may see'
for unit in args toolchain platform paths project probe doctor report; do
    # shellcheck disable=SC2086
    fpc -MObjFPC -Sh -B -FUbuild/cap10a/iso \
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_core[@]}" ${platform_flags} \
        "tools/pweb/pweb.cli.${unit}.pas" ||
        die "pweb.cli.${unit}.pas failed its isolation compile"
done

step 'the pweb CLI, taken from where its TRUST ANCHOR is generated'
# CAP-10B1 CHANGED WHERE THIS EXECUTABLE IS BUILT, and the reason is not
# organisational. `pweb` now compiles the generated template registry in
# with -Fi, so it cannot be built before the pack that registry describes
# exists - and the pack is built by test/cap10b1/build_cap10b1.sh. Building
# a second `pweb` here to keep the old path would give this repository two
# executables that could disagree.
#
# So there is ONE CLI, built once, and every shard's gates measure it. The
# compiled unit set check_cap10a_contracts.ps1 reads moved with it, to
# build/cap10b1/cli-units.
[ -x 'build/cap10b1/sdk/bin/pweb' ] ||
    die 'build/cap10b1/sdk/bin/pweb missing -- run test/cap10b1/build_cap10b1.sh first; the CLI carries a generated template registry and is built where that registry is produced'
cp -f -- build/cap10b1/sdk/bin/pweb build/cap10a/bin/pweb

step 'the CAP-10A suite and its probe fixture'
# shellcheck disable=SC2086
fpc -Sh -B -FUbuild/cap10a/test-units -FEbuild/cap10a/bin \
    -Futools/pweb -Futest/cap10a -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    "${mormot_test[@]}" "-Fl${static_dir}" ${platform_flags} \
    test/cap10a/clitests.pas || die 'clitests.pas compile FAILED'

# RTL-only by design: a fixture that shared code with the thing it tests
# would be measuring the code against itself
# shellcheck disable=SC2086
fpc -Sh -B -FUbuild/cap10a/test-units -FEbuild/cap10a/bin \
    ${platform_flags} test/cap10a/probechild.pas ||
    die 'probechild.pas compile FAILED'

for exe in pweb clitests probechild; do
    [ -x "build/cap10a/bin/${exe}" ] ||
        die "expected build/cap10a/bin/${exe}"
done
printf '[CAP-10A] pweb + clitests + probechild built; layering compiles clean\n'
