#!/usr/bin/env bash
#
# CAP-9B2: the QuickJS plugin lifecycle + transactional reload harness on
# the POSIX targets - Linux x64 and macOS (both native architectures),
# dispatched on uname. The bash sibling of
# test/cap9b2/run_quickjslifecycle.ps1.
#
# Builds test/cap9b2/quickjslifecycle.pas (the UNCHANGED production
# scheduler + CAP-8A policy + the real mORMot SOA bridge behind a
# counting/rendezvous decorator, driving CAP-9B2 plugin HOSTS over CAP-9B1
# package generations) and runs the headless L1-L40 matrix, which writes
# the canonical build/cap9b2/quickjs-lifecycle-corpus.txt digest source.
#
# HEADLESS by design: no WebView, no DISPLAY, no dylib staging, and NO
# fixture files read from the repository - every package is generated in
# process from in-source byte constants. The only platform asymmetry is
# where the QuickJS static object comes from:
#   Linux : deps/mormot2/static/x86_64-linux/quickjs.o from the
#           sha256-pinned mormot2static release;
#   macOS : the pinned mORMot release carries NO darwin quickjs.o, so this
#           runner first builds it from the PINNED in-tree sources
#           (tools/build_quickjs_darwin.sh, which refuses a non-pinned
#           checkout) and passes -dLIBQUICKJSSTATIC + -Fo itself.
#
# RUNTIME NOTE: several rows are bounded by real resource limits (a 1-2s
# CPU bound fired three times, plus a quarantine row that waits for a
# leaked thread to end on its own bound), so this gate is slower than the
# CAP-9B1 one by design.
#
# Unlike Windows, POSIX needs NO CAP-3U patch window: the mORMot x64
# call-method trampoline is a Win64-only concern.
#
# Writes: build/cap9b2/quickjslifecycle-<target>.json (PASS|FAIL),
#         build/cap9b2/quickjs-lifecycle-corpus.txt (the digest source), log.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-9B2] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-9B2] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

work="${repo_root}/build/cap9b2"
mkdir -p -- "${work}"
corpus="${work}/quickjs-lifecycle-corpus.txt"
qlog="${work}/quickjslifecycle-posix.log"
rm -f -- "${corpus}" "${qlog}" "${work}"/quickjslifecycle-*.json

for pre in test/cap9b2/quickjslifecycle.pas \
           src/script/pweb.script.plugin.pas \
           src/script/pweb.script.package.pas \
           src/script/pweb.script.quickjs.pas \
           src/assets/pweb.assets.folder.pas; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

pass_marker="$(sed -n "s/^  MARKER_PASS = '\\([^']*\\)';\$/\\1/p" \
    test/cap9b2/quickjslifecycle.pas)"
[ -n "${pass_marker}" ] || die 'could not read MARKER_PASS from quickjslifecycle.pas'
# exactly ONE marker line, like the ps1 sibling: a multi-line result would
# quietly turn the grep -qF below into an any-of match
[ "$(printf '%s\n' "${pass_marker}" | wc -l)" -eq 1 ] ||
    die 'expected exactly one MARKER_PASS constant in quickjslifecycle.pas'
printf '[CAP-9B2] canonical pass marker: %s\n' "${pass_marker}"

os_name="$(uname -s)"
outdir="${work}/lc-bin"
unitdir="${work}/lc-fpc"
rm -rf -- "${outdir}" "${unitdir}"
mkdir -p -- "${outdir}" "${unitdir}"

mormot_units=(
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa
    -Fudeps/mormot2/src/script
)

case "${os_name}" in

# ============================== Linux x64 ====================================
Linux)
    target='linux-x86_64'
    [ -f 'deps/mormot2/static/x86_64-linux/quickjs.o' ] ||
        die 'pinned quickjs.o missing under deps/mormot2/static/x86_64-linux -- fetch the mORMot statics first'

    step 'compile quickjslifecycle (production runtime + pinned QuickJS statics)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/script -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_units[@]}" \
        -Fldeps/mormot2/static/x86_64-linux \
        test/cap9b2/quickjslifecycle.pas ||
        die 'quickjslifecycle.pas compile FAILED'
    exe="${outdir}/quickjslifecycle"
    ;;

# ============================ macOS (both arches) ============================
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: ${arch}" ;;
    esac

    step 'build the pinned QuickJS static object (no darwin artifact in the release)'
    qjs_obj_dir="${work}/qjs-obj"
    tools/build_quickjs_darwin.sh "${qjs_obj_dir}" ||
        die 'tools/build_quickjs_darwin.sh FAILED'

    step 'compile quickjslifecycle (production runtime + CI-built QuickJS object)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -dLIBQUICKJSSTATIC \
        -Fusrc/script -Fusrc/rpc -Fusrc/security -Fusrc/assets \
        "${mormot_units[@]}" \
        -Fo"${qjs_obj_dir}" \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
        test/cap9b2/quickjslifecycle.pas ||
        die 'quickjslifecycle.pas compile FAILED'
    exe="${outdir}/quickjslifecycle"
    ;;

*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

json="${work}/quickjslifecycle-${target}.json"
rm -f -- "${json}"

step "run the headless L1-L40 matrix (${target})"
# run from a throwaway CWD (nothing may resolve relative to it) and clean
# it up: a per-run temp directory that is never removed is a leak on any
# machine that runs this gate more than once
runcwd="$(mktemp -d)"
trap 'rm -rf -- "${runcwd}"' EXIT
set +e
( cd -- "${runcwd}" && "${exe}" ) > "${qlog}" 2>&1
code=$?
set -e
cat "${qlog}"

[ -f "${corpus}" ] ||
    die "the quickjs-lifecycle-corpus digest source was not written -- see ${qlog}"

if grep -qF "${pass_marker}" "${qlog}"; then
    [ "${code}" -eq 0 ] ||
        die "the PASS marker was printed but the harness exited ${code}"
    [ -f "${json}" ] || die 'PASS marker printed but no quickjslifecycle JSON was written'
else
    die "CAP-9B2 quickjslifecycle FAILED (exit ${code}) -- see ${qlog}"
fi

printf '[CAP-9B2] quickjslifecycle verdict: PASS (%s)\n' "${target}"
