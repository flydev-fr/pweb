#!/usr/bin/env bash
#
# CAP-10B2: build the ONE artifact this shard needs that CAP-10B1's build
# does not already produce - a `pweb` whose compiled registry describes the
# react template and nothing else. Linux and macOS from ONE script, exactly
# as build_cap10b2.ps1 does it on Windows.
#
# WHY A SECOND CLI EXISTS AT ALL. CAP-10B2 moved `ptcTemplateUnknown` from
# exit 2 to exit 4, because with a two-value compiled allowlist the code can
# no longer be caused by a command line: reaching it means the pack this
# installation carries does not describe a template this build advertises,
# which is the same class of fact as `sdk_share_missing` and `pack_size`.
#
# That reasoning is only worth as much as the measurement behind it. The
# refusal cannot be provoked with the shipped CLI - its registry knows
# pas2js - so this script builds one that does not, and run_cap10b2_gates
# runs `create demo --ui pas2js` against THAT executable and requires exit 4
# with `template_unknown`. A refusal nobody has watched fire is a comment.
#
# NOTHING SHIPPED COMES FROM HERE. This executable exists to be refused by,
# and it lives under its own build directory so no other gate can pick it up.
#
# Usage: test/cap10b2/build_cap10b2.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10B2] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10B2] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
[ -f 'deps/mormot2/src/core/mormot.core.base.pas' ] ||
    die 'deps/mormot2 missing -- fetch it first'
[ -x 'build/cap10b0/bin/pwebtemplates' ] ||
    die 'build/cap10b0/bin/pwebtemplates missing -- run test/cap10b0/build_cap10b0.sh first'

target_os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
target_cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
printf '[CAP-10B2] fpc %s targeting %s/%s\n' "$(fpc -iV)" \
    "${target_os}" "${target_cpu}"

# a space-separated STRING, not an array: macOS still ships bash 3.2, where
# "${arr[@]}" under `set -u` on an empty array is an error
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
            die "CAP-10B2 Linux is ratified for x86_64 only, fpc targets ${target_cpu}"
        static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
        ;;
    *)
        die "unsupported FPC target OS ${target_os}"
        ;;
esac
[ -d "${static_dir}" ] || die "mORMot statics missing: ${static_dir}"

work='build/cap10b2/react-only'
rm -rf -- build/cap10b2
mkdir -p -- "${work}/gen" "${work}/cli-units" "${work}/sdk/bin" \
    "${work}/sdk/share/pweb"

step 'the filtered trusted source'
# BOTH halves, because the builder cross-checks the list against the
# directory in both directions: a declared template whose files are gone is
# an error, and a directory nobody declared is an error too.
cp -R -- tools/templates "${work}/source"
rm -rf -- "${work}/source/pas2js"
# the list, minus the `template = pas2js` block. Its COMMENT banner is left
# in place: comments are ignored by the grammar, and a filter that also
# rewrote prose would be a filter nobody could read the output of.
awk '
    /^template[[:space:]]*=[[:space:]]*pas2js[[:space:]]*$/ { drop = 1; next }
    /^template[[:space:]]*=/ { drop = 0 }
    drop != 1 { print }
' "${work}/source/templates.list" > "${work}/source/templates.list.tmp"
mv -- "${work}/source/templates.list.tmp" "${work}/source/templates.list"
if grep -qE '^template[[:space:]]*=[[:space:]]*pas2js[[:space:]]*$' \
        "${work}/source/templates.list"; then
    die 'the react-only source still declares the pas2js template'
fi

step 'its pack and its generated registry'
./build/cap10b0/bin/pwebtemplates \
    --source "${work}/source" \
    --pack "${work}/sdk/share/pweb/pweb-templates.zip" \
    --registry "${work}/gen/pweb.templates.registry.inc" \
    --include public || die 'the react-only pack build FAILED'

step 'the CLI, compiled against THAT registry'
mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
)
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FU"${work}/cli-units" -FE"${work}/sdk/bin" \
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets \
    -Fi"${work}/gen" "${mormot_core[@]}" "-Fl${static_dir}" \
    ${platform_flags} tools/pweb/pweb.pas ||
    die 'the react-only CLI compile FAILED'

for artifact in "${work}/gen/pweb.templates.registry.inc" \
                "${work}/sdk/bin/pweb" \
                "${work}/sdk/share/pweb/pweb-templates.zip"; do
    [ -e "${artifact}" ] || die "expected ${artifact}"
done
printf '[CAP-10B2] the react-only CLI and its pack are built\n'
