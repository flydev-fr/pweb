#!/usr/bin/env bash
#
# CAP-10D1 (Linux and macOS): stage the packaging kit into the ONE SDK root
# and build the packaging suite and its interrupt driver.
#
# IT ADDS TO build/cap10b1/sdk rather than building a second one, exactly as
# test/cap10c1 and test/cap10d0 do. What it adds is the packaging kit:
#
#   share/pweb/pack/setup/     the generic .iss / .issi manifests
#   share/pweb/pack/bin/       (Windows only) the compiled CAP-13 helpers
#   share/pweb/pack/lib/       (Windows only) the pinned WebView2 loader
#   share/pweb/deps/innosetup/ (Windows only) the pinned compiler
#   share/pweb/deps/webview2-runtime/  (Windows only) the pinned artifacts
#
# On POSIX the archive profile needs NONE of the Windows halves: its writer
# is pweb.cli.tar and its compressor is mORMot, so the kit here is the
# manifests alone - staged anyway, because `pweb.cli.package` resolves the
# pack directory on every target and a kit that only existed on Windows
# would make the POSIX resolution untested.
#
# Produces, under build/cap10d1/:
#   iso/    the isolation compiles of pweb.cli.tar and pweb.cli.package
#   bin/    d1tests        the CAP-10D1 suite
#           pwebpackdrv    the real-`pweb build --profile` interrupt driver
#
# THE SUITE IS COMPILED WITH -dPWEB_LAYOUT_FAULTS, and it is the ONLY
# compile in this repository that is. That define arms the CAP-10D1 rollback
# fault seam in pweb.cli.layout (ledger item C1-11 (b)); every other build
# command and every CI step is swept for the spelling by
# check_cap10d1_contracts.ps1, so the seam can never reach a shipped binary.
#
# Usage: test/cap10d1/build_cap10d1.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10D1] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10D1] === %s\n' "$*"; }

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
        die "CAP-10D1 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
    fpc_target='x86_64-linux'
    ;;
*)
    die "unsupported FPC target OS ${target_os}"
    ;;
esac
printf '[CAP-10D1] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

# --- 1. the packaging kit ---------------------------------------------------
# The manifests are COPIED rather than linked, and the copy is what a real
# installation would ship: `pweb.cli.package` hands ISCC a path inside the
# SDK, so a kit that resolved back into the checkout would be testing a
# layout no user will ever have.
step 'stage the packaging kit into the one SDK root'
rm -rf -- "${share}/pack"
mkdir -p -- "${share}/pack/setup"
cp -- tools/setup/app/*.iss tools/setup/app/*.issi "${share}/pack/setup/"
for f in app-normal.iss app-offline.iss app-fixed.iss pwebappid.issi \
         pwebapptriple.issi pwebappprov.issi; do
    [ -f "${share}/pack/setup/${f}" ] || die "kit is missing ${f}"
done

# --- 2. the isolation compiles ----------------------------------------------
# pweb.cli.tar stands on mORMot alone: it is a pure function from entries to
# bytes and reads no disk, which is what lets the whole archive rule be
# tested without a filesystem on four targets.
step 'layering: pweb.cli.tar stands on mORMot alone'
rm -rf -- build/cap10d1/iso build/cap10d1/test-units build/cap10d1/bin \
    build/cap10d1/fixture
mkdir -p -- build/cap10d1/iso build/cap10d1/test-units build/cap10d1/bin

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

fpc -MObjFPC -Sh -B -FUbuild/cap10d1/iso -Futools/pweb \
    "${mormot_core[@]}" tools/pweb/pweb.cli.tar.pas ||
    die 'pweb.cli.tar.pas failed its isolation compile'

step 'layering: pweb.cli.package stands on the engine and the pipeline'
fpc -MObjFPC -Sh -B -FUbuild/cap10d1/iso -Futools/pweb -Fusrc/rpc \
    -Fusrc/security -Fusrc/assets "${mormot_core[@]}" \
    tools/pweb/pweb.cli.package.pas ||
    die 'pweb.cli.package.pas failed its isolation compile'

# --- 3. the suite and the interrupt driver ----------------------------------
# -dPWEB_LAYOUT_FAULTS: the ONE compile in this repository that arms the
# rollback seam. See the header.
step 'the suite (with the rollback fault seam) and the interrupt driver'
for prog in d1tests pwebpackdrv; do
    fpc -Sh -B -dPWEB_LAYOUT_FAULTS -FUbuild/cap10d1/test-units \
        -FEbuild/cap10d1/bin -Futools/pweb -Futest/cap10d1 -Fusrc/rpc \
        -Fusrc/security -Fusrc/assets "${mormot_test[@]}" \
        "-Fldeps/mormot2/static/${fpc_target}" \
        "test/cap10d1/${prog}.pas" || die "${prog}.pas compile FAILED"
    [ -x "build/cap10d1/bin/${prog}" ] ||
        die "expected build/cap10d1/bin/${prog}"
done

printf '[CAP-10D1] kit staged; suite + driver built; both units compile in isolation\n'
