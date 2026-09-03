#!/usr/bin/env bash
#
# CAP-10C2 (Linux and macOS): build the development suite, the driver, and
# the two host binaries whose difference this shard exists to prove.
#
# The POSIX twin of build_cap10c2.ps1, making the identical claims in the
# identical order. What differs per platform is at the seam rather than in
# the claim: the macOS build environment is initialised the way every macOS
# gate in this repository initialises it, and the target name comes from the
# compiler rather than from a literal.
#
# Produces, all under build/cap10c2/:
#   iso/            isolation compiles (no binary kept) - the LAYERING proof
#   bin/            c2tests, pwebdevdrv
#   release-units/  the RELEASE host's compiled unit set  (T2)
#   dev-units/      the DEVELOPMENT host's compiled unit set (T2)
#   probe/          release-host/ and dev-host/, one binary each (T1, T2)
#
# Usage: test/cap10c2/build_cap10c2.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10C2] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10C2] === %s\n' "$*"; }

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
        x86_64)  target='macos-x86_64'; fpc_target='x86_64-darwin' ;;
        aarch64) target='macos-arm64';  fpc_target='aarch64-darwin' ;;
        *) die "unsupported macOS CPU ${target_cpu}" ;;
    esac
    ;;
linux)
    [ "${target_cpu}" = 'x86_64' ] ||
        die "CAP-10C2 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
    target='linux-x86_64'
    fpc_target='x86_64-linux'
    ;;
*)
    die "unsupported FPC target OS ${target_os}"
    ;;
esac
printf '[CAP-10C2] fpc %s targeting %s/%s (%s)\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}" "${target}"

# --- 0. the SDK root's src/, refreshed --------------------------------------
# CAP-10C2 ADDS src/webview/pweb.webview.devhost.pas and MOVES
# src/webview/pweb.webview.host.pas. An SDK root staged before this shard
# cannot compile a development host, and the failure would look like a
# missing unit rather than a stale installation.
step 'the SDK root src/, refreshed for the development composition'
rm -rf -- "${share}/src"
cp -R -- "${repo_root}/src" "${share}/src"
for u in pweb.webview.host.pas pweb.webview.devhost.pas; do
    [ -f "${share}/src/webview/${u}" ] ||
        die "the staged SDK root does not carry src/webview/${u}"
done

rm -rf -- build/cap10c2/iso build/cap10c2/test-units build/cap10c2/bin \
    build/cap10c2/release-units build/cap10c2/dev-units build/cap10c2/probe
mkdir -p -- build/cap10c2/iso build/cap10c2/test-units build/cap10c2/bin \
    build/cap10c2/release-units build/cap10c2/dev-units \
    build/cap10c2/probe/release-host build/cap10c2/probe/dev-host

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

# --- 1. layering: no dev-loop unit may reach a webview unit -----------------
step 'layering: the dev-loop units are webview-free'
for unit in devlayout dev; do
    fpc -MObjFPC -Sh -B -FUbuild/cap10c2/iso \
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_core[@]}" "tools/pweb/pweb.cli.${unit}.pas" ||
        die "pweb.cli.${unit}.pas failed its isolation compile"
done

# --- 2. the suite and the driver -------------------------------------------
step 'the suite and the real-`pweb dev` driver'
for prog in c2tests pwebdevdrv; do
    fpc -Sh -B -FUbuild/cap10c2/test-units -FEbuild/cap10c2/bin \
        -Futools/pweb -Futest/cap10c2 -Fusrc/rpc -Fusrc/security \
        -Fusrc/assets "${mormot_test[@]}" \
        "-Fldeps/mormot2/static/${fpc_target}" \
        "test/cap10c2/${prog}.pas" || die "${prog}.pas compile FAILED"
    [ -x "build/cap10c2/bin/${prog}" ] ||
        die "expected build/cap10c2/bin/${prog}"
done

# --- 3. the TWO host binaries ----------------------------------------------
# A generated project is scaffolded here by the REAL CLI, so what is compiled
# is what a developer's project would be - not a fixture that resembles one.
step 'the release host and the development host, from one generated project'
probe_gen="${repo_root}/build/cap10c2/probe/gen"
rm -rf -- "${probe_gen}"
mkdir -p -- "${probe_gen}"
( cd -- "${probe_gen}" &&
  "${sdk}/bin/pweb" create demo --ui react --bundle-id com.example.demo ) ||
    die 'scaffolding the probe project FAILED'
proj="${probe_gen}/demo"

sdk_args=(
    "-Fu${proj}/src"
    "-Fu${share}/src/lib" "-Fu${share}/src/rpc" "-Fu${share}/src/security"
    "-Fu${share}/src/webview" "-Fu${share}/src/assets"
    "-Fi${share}/deps/mormot2/src"
    "-Fu${share}/deps/mormot2/src/core" "-Fu${share}/deps/mormot2/src/lib"
    "-Fu${share}/deps/mormot2/src/crypt" "-Fu${share}/deps/mormot2/src/net"
    "-Fu${share}/deps/mormot2/src/db" "-Fu${share}/deps/mormot2/src/orm"
    "-Fu${share}/deps/mormot2/src/rest" "-Fu${share}/deps/mormot2/src/soa"
    "-Fl${share}/deps/mormot2/static/${fpc_target}"
)
case "${target_os}" in
darwin)
    sdk_args+=( "-Fu${share}/src/platform/macos"
                "-WM12.0"
                "-Fl${share}/lib/${target}"
                -k-rpath -k@executable_path
                "-k-L${share}/lib/${target}" -k-lwebview
                "-k${share}/lib/${target}/pweb_cocoa_bridge.o"
                -k-framework -kCocoa -k-framework -kWebKit
                -k-lc++ -k-lobjc )
    if [ "${target_cpu}" = 'aarch64' ]; then
        sdk_args+=( -k-no_fixup_chains )
    fi
    ;;
linux)
    sdk_args+=( "-Fu${share}/src/platform/linux"
                "-Fl${share}/lib/${target}"
                '-k-rpath=$ORIGIN' -k-lgcc_s )
    ;;
esac

fpc -MObjFPC -Sh -B \
    -FUbuild/cap10c2/release-units -FEbuild/cap10c2/probe/release-host \
    "${sdk_args[@]}" "${proj}/src/demo.lpr" ||
    die 'the RELEASE host compile FAILED'

fpc -MObjFPC -Sh -B -dPWEB_DEV \
    -FUbuild/cap10c2/dev-units -FEbuild/cap10c2/probe/dev-host \
    "${sdk_args[@]}" "${proj}/src/demo.lpr" ||
    die 'the DEVELOPMENT host compile FAILED'

# the webview library, beside BOTH probe binaries. It is a load-time import,
# so a host that cannot find it dies before main() and DEV9's refusal - which
# happens before anything webview-related exists - would never be reached.
for probe in release-host dev-host; do
    for f in "${share}/lib/${target}"/*; do
        [ -f "${f}" ] || continue
        case "${f}" in
            *.o) continue ;;
        esac
        cp -f -- "${f}" "build/cap10c2/probe/${probe}/"
    done
done

for artifact in build/cap10c2/bin/c2tests build/cap10c2/bin/pwebdevdrv \
                build/cap10c2/probe/release-host/demo \
                build/cap10c2/probe/dev-host/demo \
                build/cap10c2/dev-units/pweb.webview.devhost.ppu; do
    [ -e "${artifact}" ] || die "expected ${artifact}"
done
if [ -e 'build/cap10c2/release-units/pweb.webview.devhost.ppu' ]; then
    die 'the RELEASE unit set carries pweb.webview.devhost -- the development composition must be unreachable from a release build'
fi
printf '[CAP-10C2] suite + driver + both host binaries built; layering compiles clean\n'
