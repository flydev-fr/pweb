#!/usr/bin/env bash
#
# CAP-10C0: compile everything the POSIX supervision gates run. Linux and
# macOS from ONE script, exactly as build_cap10c0.ps1 does it on Windows.
#
# Produces, all under build/cap10c0/:
#   iso/    isolation compiles (no binary kept) - the LAYERING proof
#   bin/    c0tests            the CAP-10C0 suite (pure + engine + run)
#           pwebchild          the deliberately badly behaved fixture child
#
# THE CLI ITSELF IS NOT BUILT HERE: there is ONE `pweb`, compiled by
# test/cap10b1/build_cap10b1.sh where its trust anchor is generated.
#
# Usage: test/cap10c0/build_cap10c0.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10C0] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10C0] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
[ -f 'deps/mormot2/src/core/mormot.core.base.pas' ] ||
    die 'deps/mormot2 missing -- fetch it first'
[ -x 'build/cap10b1/sdk/bin/pweb' ] ||
    die 'build/cap10b1/sdk/bin/pweb missing -- run test/cap10b1/build_cap10b1.sh first'

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
printf '[CAP-10C0] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

case "${target_os}" in
    darwin)
        case "${target_cpu}" in
            x86_64)  static_dir="${repo_root}/deps/mormot2/static/x86_64-darwin" ;;
            aarch64) static_dir="${repo_root}/deps/mormot2/static/aarch64-darwin" ;;
            *) die "unsupported macOS CPU ${target_cpu}" ;;
        esac
        ;;
    linux)
        [ "${target_cpu}" = 'x86_64' ] ||
            die "CAP-10C0 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
        static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
        ;;
    *)
        die "unsupported FPC target OS ${target_os}"
        ;;
esac
[ -d "${static_dir}" ] || die "mORMot statics missing: ${static_dir}"

rm -rf -- build/cap10c0/iso build/cap10c0/test-units build/cap10c0/bin
mkdir -p -- build/cap10c0/iso build/cap10c0/test-units build/cap10c0/bin

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

step 'layering: the engine and the run command are webview-free'
for unit in process run; do
    fpc -MObjFPC -Sh -B -FUbuild/cap10c0/iso \
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_core[@]}" "tools/pweb/pweb.cli.${unit}.pas" ||
        die "pweb.cli.${unit}.pas failed its isolation compile"
done

step 'the suite and its fixture'
fpc -Sh -B -FUbuild/cap10c0/test-units -FEbuild/cap10c0/bin \
    -Futools/pweb -Futest/cap10c0 -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    "${mormot_test[@]}" "-Fl${static_dir}" \
    test/cap10c0/c0tests.pas || die 'c0tests.pas compile FAILED'
# RTL-only by design: a fixture that shared code with the thing it tests
# would be measuring the code against itself
fpc -Sh -B -FUbuild/cap10c0/test-units -FEbuild/cap10c0/bin \
    test/cap10c0/pwebchild.pas || die 'pwebchild.pas compile FAILED'

for exe in c0tests pwebchild; do
    [ -x "build/cap10c0/bin/${exe}" ] || die "expected build/cap10c0/bin/${exe}"
done
printf '[CAP-10C0] c0tests + pwebchild built; layering compiles clean\n'
