#!/usr/bin/env bash
#
# CAP-10D0 (Linux and macOS): build the public-build suite and its driver.
#
# The POSIX twin of build_cap10d0.ps1, making the identical claims in the
# identical order. What differs per platform is at the seam rather than in
# the claim: the macOS build environment is initialised the way every macOS
# gate in this repository initialises it, and the target name comes from the
# compiler rather than from a literal.
#
# Produces, all under build/cap10d0/:
#   iso/            the isolation compile of pweb.cli.build - the LAYERING
#                   proof that the public build driver stands on the
#                   pipeline and on file operations, and on nothing else
#   bin/            d0tests, pwebbuilddrv
#
# Usage: test/cap10d0/build_cap10d0.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10D0] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10D0] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
sdk="${repo_root}/build/cap10b1/sdk"
share="${sdk}/share/pweb"
for pre in "${sdk}/bin/pweb" "${sdk}/bin/pwebbundle" \
           "${share}/deps/mormot2/src/core/mormot.core.base.pas"; do
    [ -e "${pre}" ] ||
        die "missing precondition: ${pre} -- run test/cap10b1/build_cap10b1.sh and test/cap10c1/build_cap10c1.sh first"
done

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "${target_os}" in
darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    case "${target_cpu}" in
        x86_64)  fpc_target='x86_64-darwin' ;;
        aarch64) fpc_target='aarch64-darwin' ;;
        *) die "unsupported macOS CPU ${target_cpu}" ;;
    esac
    ;;
linux)
    [ "${target_cpu}" = 'x86_64' ] ||
        die "CAP-10D0 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
    fpc_target='x86_64-linux'
    ;;
*)
    die "unsupported FPC target OS ${target_os}"
    ;;
esac
printf '[CAP-10D0] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

# the whole tree, including the fixture directories the suite plants beside
# its own binary (mormot.core.test runs a suite from the executable's
# directory, so `build/cap10d0/fixture` resolves under bin/ while a case is
# running and beside it once the runner has restored the working directory)
rm -rf -- build/cap10d0/iso build/cap10d0/test-units build/cap10d0/bin \
    build/cap10d0/fixture
mkdir -p -- build/cap10d0/iso build/cap10d0/test-units build/cap10d0/bin

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

# --- 1. layering: the build driver compiles on its own ----------------------
# It calls PWebCliRunPipeline and reads a disk. If it ever grew a second way
# to run a child, this compile would drag in the units that do - and
# check_cap10d0_contracts.ps1 makes the same claim over the SOURCE, so the
# two together catch both a new dependency and a new spelling of an old one.
step 'layering: pweb.cli.build stands on the pipeline and on file operations'
fpc -MObjFPC -Sh -B -FUbuild/cap10d0/iso \
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    "${mormot_core[@]}" tools/pweb/pweb.cli.build.pas ||
    die 'pweb.cli.build.pas failed its isolation compile'

# --- 2. the suite and the real-`pweb build` driver --------------------------
step 'the suite and the real-`pweb build` driver'
for prog in d0tests pwebbuilddrv; do
    fpc -Sh -B -FUbuild/cap10d0/test-units -FEbuild/cap10d0/bin \
        -Futools/pweb -Futest/cap10d0 -Fusrc/rpc -Fusrc/security \
        -Fusrc/assets "${mormot_test[@]}" \
        "-Fldeps/mormot2/static/${fpc_target}" \
        "test/cap10d0/${prog}.pas" || die "${prog}.pas compile FAILED"
    [ -x "build/cap10d0/bin/${prog}" ] ||
        die "expected build/cap10d0/bin/${prog}"
done

printf '[CAP-10D0] suite + driver built; the build driver compiles in isolation\n'
