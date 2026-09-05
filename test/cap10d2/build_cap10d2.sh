#!/usr/bin/env bash
# CAP-10D2 (POSIX): stage the licence set into the ONE SDK root and build the
# private SDK packager, the suite and the isolation compiles.
#
# The POSIX twin of build_cap10d2.ps1, making the identical claims in the
# identical order minus the half only Windows has: the Microsoft WebView2 SDK
# notice belongs to `webview.dll`, which embeds upstream's built-in loader,
# and neither the .so nor the .dylib does.
#
# The QuickJS notice ships on Linux and NOT on macOS, and that is a
# MEASUREMENT rather than a preference: mORMot's static tree carries
# quickjs.o for x86_64-linux and not for either Darwin architecture, so the
# macOS package redistributes no QuickJS object at all.
#
# NOTHING HERE DOWNLOADS ANYTHING. Every licence text is COPIED from the
# place its own material came from, and the one with a ratified digest is
# verified against it.
#
# Produces, under build/cap10d2/:
#   iso/    the isolation compile of pweb.cli.sdkmanifest
#   bin/    pwebsdk      the private SDK packager
#           d2tests      the CAP-10D2 suite
#
# Usage: test/cap10d2/build_cap10d2.sh
set -euo pipefail

die() { printf '[CAP-10D2] FATAL: %s\n' "$*" >&2; exit 1; }
step() { printf '[CAP-10D2] %s\n' "$*"; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

sdk="${repo_root}/build/cap10b1/sdk"
share="${sdk}/share/pweb"

target_os="$(fpc -iTO | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')"
case "${target_os}" in
darwin)
    # shellcheck source=/dev/null
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    case "${target_cpu}" in
        x86_64)  target='macos-x86_64'; fpc_target='x86_64-darwin' ;;
        aarch64) target='macos-arm64';  fpc_target='aarch64-darwin' ;;
        *) die "unsupported macOS CPU ${target_cpu}" ;;
    esac
    webview_dist="${PWEB_MACOS_DIST}"
    ships_quickjs=0
    ;;
linux)
    [ "${target_cpu}" = 'x86_64' ] ||
        die "CAP-10D2 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
    target='linux-x86_64'
    fpc_target='x86_64-linux'
    webview_dist="${repo_root}/build/cap7l/webview-dist"
    ships_quickjs=1
    ;;
*)
    die "unsupported FPC target OS ${target_os}"
    ;;
esac
step "fpc $(fpc -iV | tr -d '\r\n') targeting ${target_os}/${target_cpu} (${target})"

for pre in "${sdk}/bin/pweb" "${sdk}/bin/pwebbundle" \
           "${share}/pweb-templates.zip" \
           "${share}/deps/mormot2/src/core/mormot.core.base.pas" \
           "${repo_root}/build/cap10b1/gen/pweb.templates.registry.inc"; do
    [ -e "${pre}" ] ||
        die "missing precondition: ${pre} -- run test/cap10b1/build_cap10b1.sh and test/cap10c1/build_cap10c1.sh first"
done
[ -d "${share}/lib/${target}" ] || die "missing precondition: ${share}/lib/${target}"

# --- 1. the licence set, from the material's OWN provenance ------------------
step 'stage the ratified licence set into the one SDK root'
lic_dir="${share}/licenses"
rm -rf -- "${lic_dir}"
mkdir -p -- "${lic_dir}"

QUICKJS_NOTICE_SHA='8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc'

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d' ' -f1
    else
        shasum -a 256 -- "$1" | cut -d' ' -f1
    fi
}

stage_licence() {
    local source="$1" name="$2" want="${3:-}" got
    [ -f "${source}" ] ||
        die "missing licence source: ${source} -- CAP-10D2 ships no licence text of its own, and a component whose notice cannot be produced from its own provenance is a component that cannot ship"
    if [ -n "${want}" ]; then
        got="$(sha256_of "${source}")"
        [ "${got}" = "${want}" ] ||
            die "licence digest drift for ${name}: expected ${want}, got ${got}"
    fi
    cp -f -- "${source}" "${lic_dir}/${name}"
    printf '  %s <- %s\n' "${name}" "${source}"
}

stage_licence "${repo_root}/deps/mormot2/LICENCE.md" 'LICENSE.mormot2.md'
stage_licence "${webview_dist}/LICENSE.webview" 'LICENSE.webview.txt'
if [ "${ships_quickjs}" -eq 1 ]; then
    stage_licence "${repo_root}/build/quickjs-release/LICENSE.quickjs" \
        'LICENSE.quickjs.txt' "${QUICKJS_NOTICE_SHA}"
fi

# --- 2. the isolation compile ------------------------------------------------
# pweb.cli.sdkmanifest stands on mORMot and on the two lowest CLI units and on
# nothing else: it is read by the DOCTOR, so a dependency that dragged the
# pipeline or the process engine into it would put the whole build layer under
# a diagnostic.
rm -rf -- build/cap10d2/iso build/cap10d2/pkg-units build/cap10d2/test-units \
    build/cap10d2/bin build/cap10d2/fixture build/cap10d2/out
mkdir -p -- build/cap10d2/iso build/cap10d2/pkg-units build/cap10d2/test-units \
    build/cap10d2/bin build/cap10d2/out

mormot_core=( -Fideps/mormot2/src -Fudeps/mormot2/src/core
              -Fudeps/mormot2/src/lib -Fudeps/mormot2/src/crypt )
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )
statics="-Fldeps/mormot2/static/${fpc_target}"
platform_units="-Fusrc/platform/${target_os/darwin/macos}"

# the platform unit path is the ONE extra, and it is not a weakening:
# pweb.cli.platform itself reaches a platform unit on some targets, so the
# unit under test would be refused for a dependency of its dependency. What
# the isolation proves is what pweb.cli.sdkmanifest does NOT reach - the
# pipeline, the process engine, the toolset and the doctor - and
# check_cap10d2_contracts.ps1 measures that at the source as well.
#
# CAP-10E added -Fusrc/security for the SAME reason and with the same
# reservation: pweb.cli.platform now stands on src/security/pweb.imagepath,
# the ONE kernel-resolved image path the shipped hosts and the CLI share, so
# without it this compile is refused for a dependency of its dependency. It
# is a LEAF - the RTL and mormot.core.base/.unicode and no PWeb unit at all -
# so nothing about what sdkmanifest may reach has been widened. Every other
# CLI isolation compile in this repository already carried the path.
step 'layering: pweb.cli.sdkmanifest stands on mORMot and the anchor'
fpc -MObjFPC -Sh -B -FUbuild/cap10d2/iso -Futools/pweb "${platform_units}" \
    -Fusrc/security "${mormot_core[@]}" tools/pweb/pweb.cli.sdkmanifest.pas ||
    die 'pweb.cli.sdkmanifest.pas failed its isolation compile'

# --- 3. the private packager -------------------------------------------------
step 'the private SDK packager'
fpc -MObjFPC -Sh -B -FUbuild/cap10d2/pkg-units -FEbuild/cap10d2/bin \
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets "${platform_units}" \
    -Fibuild/cap10b1/gen "${mormot_test[@]}" "${statics}" \
    tools/pweb/pwebsdk.pas || die 'pwebsdk.pas compile FAILED'
[ -x build/cap10d2/bin/pwebsdk ] || die 'expected build/cap10d2/bin/pwebsdk'

# --- 4. the suite ------------------------------------------------------------
step 'the suite'
fpc -Sh -B -FUbuild/cap10d2/test-units -FEbuild/cap10d2/bin -Futools/pweb \
    -Futest/cap10d2 -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    "${platform_units}" "${mormot_test[@]}" "${statics}" \
    test/cap10d2/d2tests.pas || die 'd2tests.pas compile FAILED'
[ -x build/cap10d2/bin/d2tests ] || die 'expected build/cap10d2/bin/d2tests'

step 'licence set staged; packager + suite built; the manifest unit compiles in isolation'
