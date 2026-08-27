#!/usr/bin/env bash
#
# CAP-10B1: build the PUBLIC template pack, the CLI that carries it, and the
# SDK root the generated project will be built against - Linux and macOS
# from ONE script, exactly as build_cap10b1.ps1 does it on Windows. The only
# divergence is where the mORMot statics live and, on Darwin, the ratified
# deployment-target and link flags, both of which come from
# tools/macos-buildenv.sh rather than from anything written here.
#
# Produces, all under build/cap10b1/:
#   gen/pweb.templates.registry.inc  the PUBLIC trust anchor
#   cli-units/                       the CLI's compiled unit set - the
#                                    LINKAGE evidence, now inverted from
#                                    CAP-10B0's
#   bin/pwebbundle                   the frozen CAP-6 bundler
#   sdk/bin/pweb                     the public CLI
#   sdk/share/pweb/pweb-templates.zip     the public pack
#   sdk/share/pweb/sdk/typescript/        the pinned TypeScript SDK
#   sdk/share/pweb/src/                   the PWeb Pascal source root
#
# TWO PACKS, FROM ONE TRUSTED SOURCE. test/cap10b0 builds `--include all`,
# which carries the private neutral fixture its engine suite needs. This
# builds `--include public`, so the registry compiled into the SHIPPED
# executable does not describe the fixture at all.
#
# WHY THE SDK ROOT IS STAGED. The generated project must be provably
# buildable from an INSTALLATION rather than from this repository, so
# prove_cap10b1.sh names only the staged tree when it compiles the generated
# program. mORMot and the webview library still come from deps/: schema 1
# carries no dependency model and CAP-10D owns packaging them.
#
# Usage: test/cap10b1/build_cap10b1.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10B1] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10B1] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
command -v node >/dev/null 2>&1 || die 'required tool not found: node'
[ -f 'deps/mormot2/src/core/mormot.core.base.pas' ] ||
    die 'deps/mormot2 missing -- fetch it first'
[ -x 'build/cap10b0/bin/pwebtemplates' ] ||
    die 'build/cap10b0/bin/pwebtemplates missing -- run test/cap10b0/build_cap10b0.sh first'
for f in sdk/typescript/dist/src/index.js sdk/typescript/dist/src/index.d.ts; do
    [ -f "${f}" ] ||
        die "${f} missing -- build the TypeScript SDK first (npm ci && npm run build)"
done

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
printf '[CAP-10B1] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

# a space-separated STRING, not an array: macOS still ships bash 3.2, where
# "${arr[@]}" under `set -u` on an empty array is an error
platform_flags=''
platform_units=''
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
            die "CAP-10B1 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
        static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
        ;;
    *)
        die "unsupported FPC target OS ${target_os}"
        ;;
esac
[ -d "${static_dir}" ] || die "mORMot statics missing: ${static_dir}"

rm -rf -- build/cap10b1/gen build/cap10b1/cli-units \
    build/cap10b1/bundler-units build/cap10b1/bin build/cap10b1/sdk
mkdir -p -- build/cap10b1/gen build/cap10b1/cli-units \
    build/cap10b1/bundler-units build/cap10b1/bin build/cap10b1/sdk/bin \
    build/cap10b1/sdk/share/pweb

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)

step 'the PUBLIC pack and its generated registry'
./build/cap10b0/bin/pwebtemplates \
    --source tools/templates \
    --pack build/cap10b1/sdk/share/pweb/pweb-templates.zip \
    --registry build/cap10b1/gen/pweb.templates.registry.inc \
    --include public || die 'the public template pack build FAILED'

step 'the public CLI, compiled WITH that registry'
# NOTE the deliberate asymmetry with Windows: there is no src/platform/<os>
# path here, the same asymmetry build_cap10a.sh and build_cap10b0.sh
# document. The Windows CLI uses the ratified CAP-6b0 WebView2 detector;
# Linux and macOS answer the same question from inside pweb.cli.platform.
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FUbuild/cap10b1/cli-units -FEbuild/cap10b1/sdk/bin \
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    -Fibuild/cap10b1/gen "${mormot_core[@]}" "-Fl${static_dir}" \
    ${platform_flags} tools/pweb/pweb.pas ||
    die 'the CAP-10B1 CLI compile FAILED'

step 'the frozen CAP-6 bundler'
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FUbuild/cap10b1/bundler-units -FEbuild/cap10b1/bin \
    -Fusrc/assets -Fusrc/rpc "${mormot_core[@]}" "-Fl${static_dir}" \
    ${platform_flags} tools/bundler/pwebbundle.pas ||
    die 'the CAP-6 bundler compile FAILED'

step 'the SDK root data: the TypeScript SDK and the Pascal source root'
node tools/stage-ts-sdk.mjs sdk/typescript \
    build/cap10b1/sdk/share/pweb/sdk/typescript ||
    die 'staging the TypeScript SDK FAILED'
cp -R -- src build/cap10b1/sdk/share/pweb/src

for artifact in build/cap10b1/gen/pweb.templates.registry.inc \
                build/cap10b1/sdk/bin/pweb \
                build/cap10b1/bin/pwebbundle \
                build/cap10b1/sdk/share/pweb/pweb-templates.zip \
                build/cap10b1/sdk/share/pweb/sdk/typescript/package.json \
                build/cap10b1/sdk/share/pweb/sdk/typescript/dist/src/index.js \
                build/cap10b1/sdk/share/pweb/src/webview/pweb.webview.host.pas; do
    [ -e "${artifact}" ] || die "expected ${artifact}"
done
printf '[CAP-10B1] public pack + CLI + bundler + staged SDK root built\n'
