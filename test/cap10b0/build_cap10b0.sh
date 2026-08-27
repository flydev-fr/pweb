#!/usr/bin/env bash
#
# CAP-10B0: compile the scaffold engine, build the template pack, and stage
# the SDK layout the suite resolves against - Linux and macOS from ONE
# script, because the engine has no platform-specific build step of its own.
# The only divergence is where the mORMot statics live and, on Darwin, the
# ratified deployment-target and link flags, both of which come from
# tools/macos-buildenv.sh rather than from anything written here.
#
# Produces, all under build/cap10b0/:
#   iso/         isolation compiles (no binary kept) - the LAYERING proof
#   bin/         pwebtemplates   the trusted pack builder
#   gen/         pweb.templates.registry.inc  the GENERATED trust anchor
#   sdk/bin/     tpltests        the suite, staged where an SDK puts a
#                                binary, so PWebCliSdkRoot resolves the same
#                                way it will in an installation
#   sdk/share/pweb/pweb-templates.zip  the pack, where an SDK puts its data
#
# THE STAGED LAYOUT IS THE POINT. The suite's own executable sits in
# <root>/bin, so the resolver under test is the production resolver walking
# the production shape rather than a second code path that exists only for
# tests.
#
# LAYERING IS PROVEN BY THE COMPILER, exactly as build_cap10b0.ps1 does it
# on Windows: each isolation compile is given only the unit paths its layer
# may see, and the ORDER - sdk, template, scaffold, write - is itself a
# claim, because each compiles alone against what precedes it.
#
# NOTE the deliberate asymmetry with Windows: there is no src/platform/<os>
# path here, the same asymmetry build_cap10a.sh documents. The Windows CLI
# uses the ratified CAP-6b0 WebView2 detector; Linux and macOS answer the
# same question from inside pweb.cli.platform with no platform unit at all.
#
# Usage: test/cap10b0/build_cap10b0.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10B0] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10B0] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
[ -f 'deps/mormot2/src/core/mormot.core.base.pas' ] ||
    die 'deps/mormot2 missing -- fetch it first'

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
printf '[CAP-10B0] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
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
            die "CAP-10B0 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
        static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
        ;;
    *)
        die "unsupported FPC target OS ${target_os}"
        ;;
esac
[ -d "${static_dir}" ] || die "mORMot statics missing: ${static_dir}"

rm -rf -- build/cap10b0/iso build/cap10b0/tool-units \
    build/cap10b0/test-units build/cap10b0/bin build/cap10b0/gen \
    build/cap10b0/sdk
mkdir -p -- build/cap10b0/iso build/cap10b0/tool-units \
    build/cap10b0/test-units build/cap10b0/bin build/cap10b0/gen \
    build/cap10b0/sdk/bin build/cap10b0/sdk/share/pweb

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
mormot_test=( "${mormot_core[@]}" -Fudeps/mormot2/src/net )

step 'layering: the engine units, each with only what it may see'
for unit in sdk template scaffold write; do
    # shellcheck disable=SC2086
    fpc -MObjFPC -Sh -B -FUbuild/cap10b0/iso \
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_core[@]}" ${platform_flags} \
        "tools/pweb/pweb.cli.${unit}.pas" ||
        die "pweb.cli.${unit}.pas failed its isolation compile"
done

step 'the trusted template-pack builder'
# its OWN unit directory: build/cap10b0/tool-units then contains EXACTLY the
# units the builder links, which is what makes the offline proof mechanical
# instead of a claim (check_cap10b0_contracts.ps1 requires none of them to
# be a networking unit). Sharing a unit directory with the suite - which
# does pull mormot.net through mormot.core.test - would destroy it.
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FUbuild/cap10b0/tool-units -FEbuild/cap10b0/bin \
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    "${mormot_core[@]}" "-Fl${static_dir}" ${platform_flags} \
    tools/pweb/pwebtemplates.pas || die 'pwebtemplates.pas compile FAILED'

step 'the template pack and the generated registry'
# --include all: CAP-10B0 ships one PRIVATE fixture and the suite has to be
# able to reach it. CAP-10B1 builds the public release pack from the same
# list with --include public.
./build/cap10b0/bin/pwebtemplates \
    --source tools/templates \
    --pack build/cap10b0/sdk/share/pweb/pweb-templates.zip \
    --registry build/cap10b0/gen/pweb.templates.registry.inc \
    --include all || die 'the template pack build FAILED'

step 'the CAP-10B0 suite, compiled WITH the generated registry'
# -Fibuild/cap10b0/gen is how the generated trust anchor gets compiled in:
# "the registry the build produced compiles" is a claim this line makes and
# the compiler either honours or refuses.
# shellcheck disable=SC2086
fpc -Sh -B -FUbuild/cap10b0/test-units -FEbuild/cap10b0/sdk/bin \
    -Futools/pweb -Futest/cap10b0 -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    -Fibuild/cap10b0/gen "${mormot_test[@]}" "-Fl${static_dir}" \
    ${platform_flags} test/cap10b0/tpltests.pas ||
    die 'tpltests.pas compile FAILED'

[ -x 'build/cap10b0/bin/pwebtemplates' ] ||
    die 'expected build/cap10b0/bin/pwebtemplates'
[ -x 'build/cap10b0/sdk/bin/tpltests' ] ||
    die 'expected build/cap10b0/sdk/bin/tpltests'
[ -f 'build/cap10b0/gen/pweb.templates.registry.inc' ] ||
    die 'expected build/cap10b0/gen/pweb.templates.registry.inc'
[ -f 'build/cap10b0/sdk/share/pweb/pweb-templates.zip' ] ||
    die 'expected build/cap10b0/sdk/share/pweb/pweb-templates.zip'
printf '[CAP-10B0] engine + builder + pack + registry + suite built; layering compiles clean\n'
