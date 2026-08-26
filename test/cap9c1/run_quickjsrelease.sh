#!/usr/bin/env bash
#
# CAP-9C1: the deterministic QuickJS production package and its trusted
# release loader, on the POSIX targets - Linux x64 and macOS (both native
# architectures), dispatched on uname. The bash sibling of
# test/cap9c1/run_quickjsrelease.ps1.
#
# Order matters and is the point:
#
#   1. build the PRIVATE packager (tools/quickjs/pwebqjspack.pas);
#   2. run it TWICE into two staging directories from the trusted
#      build-time plugin list, and require plugins.zip, the generated
#      native registry AND LICENSE.quickjs to be byte-identical - C2/C4
#      and C30's determinism leg on the REAL corpus, not on a fixture;
#   3. compile the C1-C30 harness WITH the generated registry include
#      (-Fibuild/quickjs-release), so "the generated registry compiles on
#      every target" is proven by the gate rather than asserted;
#   4. stage plugins.zip beside the harness executable, so the production
#      executable-relative location rule is exercised for real;
#   5. run the matrix from an unrelated working directory.
#
# HEADLESS by design: no WebView, no DISPLAY, no dylib staging. The only
# platform asymmetry is where the QuickJS static object comes from:
#   Linux : deps/mormot2/static/x86_64-linux/quickjs.o from the
#           sha256-pinned mormot2static release;
#   macOS : the pinned mORMot release carries NO darwin quickjs.o, so this
#           runner first builds it from the PINNED in-tree sources
#           (tools/build_quickjs_darwin.sh, which refuses a non-pinned
#           checkout) and passes -dLIBQUICKJSSTATIC + -Fo itself.
#
# Unlike Windows, POSIX needs NO CAP-3U patch window: the mORMot x64
# call-method trampoline is a Win64-only concern.
#
# NOTE ON ARCHIVE BYTES: plugins.zip is deterministic per TOOLCHAIN, not
# across them - CAP-6/CAP-7L measured that the mORMot static DEFLATE
# object differs between win64 and linux. That is why this runner
# compares the two staging runs on THIS target and why the cross-target
# gate compares the SEMANTIC corpus instead of the archive.
#
# Writes: build/cap9c1/quickjsrelease-<target>.json (PASS|FAIL),
#         build/cap9c1/quickjs-release-corpus.txt (the digest source),
#         build/quickjs-release/ (the reusable release payload), logs.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-9C1] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-9C1] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

work="${repo_root}/build/cap9c1"
mkdir -p -- "${work}"
corpus="${work}/quickjs-release-corpus.txt"
qlog="${work}/quickjsrelease-posix.log"
packlog="${work}/pwebqjspack-posix.log"
rm -f -- "${corpus}" "${qlog}" "${packlog}" "${work}"/quickjsrelease-*.json

for pre in test/cap9c1/quickjsrelease.pas \
           tools/quickjs/pwebqjspack.pas \
           examples/07-quickjs/plugins.trusted \
           src/script/pweb.script.release.pas \
           src/script/pweb.script.startup.pas \
           src/script/pweb.script.plugin.pas \
           src/script/pweb.script.package.pas \
           src/script/pweb.script.quickjs.pas \
           deps/mormot2/res/static/libquickjs/quickjs.h \
           mormot.lock; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

pass_marker="$(sed -n "s/^  MARKER_PASS = '\\([^']*\\)';\$/\\1/p" \
    test/cap9c1/quickjsrelease.pas)"
[ -n "${pass_marker}" ] || die 'could not read MARKER_PASS from quickjsrelease.pas'
# exactly ONE marker line, like the ps1 sibling: a multi-line result would
# quietly turn the grep -qF below into an any-of match
[ "$(printf '%s\n' "${pass_marker}" | wc -l)" -eq 1 ] ||
    die 'expected exactly one MARKER_PASS constant in quickjsrelease.pas'
printf '[CAP-9C1] canonical pass marker: %s\n' "${pass_marker}"

os_name="$(uname -s)"
mormot_units=(
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa
    -Fudeps/mormot2/src/script
)
pweb_units=(-Fusrc/script -Fusrc/rpc -Fusrc/security -Fusrc/assets)

# ONE compile entry point, defined per platform rather than assembled from
# shared arrays. bash 3.2 (macOS /bin/bash) errors on expanding an EMPTY
# array under `set -u`, so a "${extra_flags[@]}" that happens to be empty
# on one target only is a latent break - the same bash-3.2 rule
# test/cap7f/emit_evidence.sh states in its header. "$@" with zero
# arguments is safe, so the per-call extras go through it.
#   compile_pas <unitdir> <outdir> <source> [extra fpc flags...]

case "${os_name}" in

# ============================== Linux x64 ====================================
Linux)
    target='linux-x86_64'
    [ -f 'deps/mormot2/static/x86_64-linux/quickjs.o' ] ||
        die 'pinned quickjs.o missing under deps/mormot2/static/x86_64-linux -- fetch the mORMot statics first'
    compile_pas() {
        local unitdir="$1"
        local outdir="$2"
        local src="$3"
        shift 3
        fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
            "${pweb_units[@]}" "$@" "${mormot_units[@]}" \
            -Fldeps/mormot2/static/x86_64-linux \
            "${src}"
    }
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
    compile_pas() {
        local unitdir="$1"
        local outdir="$2"
        local src="$3"
        shift 3
        fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
            "${pweb_units[@]}" "$@" "${mormot_units[@]}" \
            -dLIBQUICKJSSTATIC "-Fo${qjs_obj_dir}" \
            "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
            "${src}"
    }
    ;;

*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

# --- 0. STRUCTURAL browser invisibility -------------------------------------
# The C22 rows prove dynamically that no pweb://app request reaches the
# plugin bytes. This proves it STRUCTURALLY, which is the half a runtime
# probe can never cover: no platform resource handler, no WebView unit and
# no release host may so much as NAME the release package units or the
# archive. If one ever does, a future host could hand the package store to
# a scheme handler and every dynamic probe would still pass.
step 'structural browser invisibility sweep'
surface_files=0
leaks=''
for root in src/platform src/webview examples/08-release; do
    [ -d "${root}" ] || continue
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        surface_files=$((surface_files + 1))
        hit="$(grep -n -E 'pweb\.script\.release|pweb\.script\.startup|plugins\.zip' \
            "${f}" || true)"
        [ -z "${hit}" ] || leaks="${leaks}${f}: ${hit}"$'\n'
    done <<EOF
$(find "${root}" -type f \( -name '*.pas' -o -name '*.pp' -o -name '*.inc' \
    -o -name '*.mm' -o -name '*.h' \))
EOF
done
[ "${surface_files}" -gt 0 ] ||
    die 'the browser-surface sweep matched no files -- it would pass vacuously'
if [ -n "${leaks}" ]; then
    printf '%s' "${leaks}" >&2
    die 'the plugin package is named on the browser-facing surface'
fi
printf '[CAP-9C1] structural browser invisibility: %s platform/webview/release-host files, zero references to the plugin package\n' \
    "${surface_files}"

# --- 0b. zero network, zero CWD, zero ambient input -------------------------
# Three of this shard's Never-list items are source facts, and a source
# sweep is the only place they can be proven for ALL inputs rather than for
# the inputs a test happened to choose: the release path must fetch nothing
# over a network, must resolve nothing against the working directory, and
# must take no descriptor data from argv or the environment. The two
# PRODUCTION units carry the whole ban; the private packager is a build
# tool, so it keeps argv and the CWD (that is how it is invoked) but is
# still banned from every network transport.
step 'zero-network / zero-ambient source proof'
net_rx='TRestHttpServer|THttpServer|mormot\.rest\.http|mormot\.net\.(server|client|http)|localhost|127\.0\.0\.1|socket|https?://|wss?://|file://'
ambient_rx='GetCurrentDir|SetCurrentDir|ParamStr|GetEnvironmentVariable'
bad=0
for f in src/script/pweb.script.release.pas src/script/pweb.script.startup.pas \
         tools/quickjs/pwebqjspack.pas; do
    if grep -niE "${net_rx}" "${f}"; then
        printf 'FORBIDDEN CAP-9C1 TRANSPORT in %s\n' "${f}" >&2
        bad=$((bad + 1))
    fi
done
for f in src/script/pweb.script.release.pas src/script/pweb.script.startup.pas; do
    if grep -niE "${ambient_rx}" "${f}"; then
        printf 'FORBIDDEN CAP-9C1 AMBIENT INPUT in %s\n' "${f}" >&2
        bad=$((bad + 1))
    fi
done
[ "${bad}" -eq 0 ] || die 'zero-network / zero-ambient source proof failed'
printf '[CAP-9C1] source proof: no network transport, no CWD lookup, no argv or environment input\n'

# --- 1. build the private packager ------------------------------------------
step 'compile pwebqjspack (the private deterministic packager)'
packfpc="${work}/pack-fpc"
packbin="${work}/pack-bin"
rm -rf -- "${packfpc}" "${packbin}"
mkdir -p -- "${packfpc}" "${packbin}"
compile_pas "${packfpc}" "${packbin}" tools/quickjs/pwebqjspack.pas ||
    die 'pwebqjspack.pas compile FAILED'
packer="${packbin}/pwebqjspack"

# --- 2. stage the release payload TWICE and require byte equality ----------
step 'stage the release payload twice and require byte-identical output'
stage1="${repo_root}/build/quickjs-release"
stage2="${repo_root}/build/quickjs-release-verify"
rm -rf -- "${stage1}" "${stage2}"
for stage in "${stage1}" "${stage2}"; do
    "${packer}" examples/07-quickjs/plugins.trusted "${stage}" \
        >> "${packlog}" 2>&1 || { cat "${packlog}"; die "pwebqjspack FAILED for ${stage}"; }
done
cat "${packlog}"
if command -v shasum >/dev/null 2>&1; then
    sha_cmd() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    sha_cmd() { sha256sum "$1" | cut -d ' ' -f 1; }
fi
for artifact in plugins.zip pweb.quickjs.registry.inc LICENSE.quickjs; do
    a="$(sha_cmd "${stage1}/${artifact}")"
    b="$(sha_cmd "${stage2}/${artifact}")"
    [ "${a}" = "${b}" ] ||
        die "${artifact} is NOT deterministic (${a} vs ${b})"
    printf '[CAP-9C1] deterministic %s sha256=%s\n' "${artifact}" "${a}"
done
rm -rf -- "${stage2}"
for required in plugins.zip pweb.quickjs.registry.inc LICENSE.quickjs \
                package-inventory.txt package-build-info.txt; do
    [ -f "${stage1}/${required}" ] ||
        die "the release staging is missing ${required}"
done

# --- 3. compile the harness WITH the generated registry --------------------
step "compile quickjsrelease with the generated registry (${target})"
relfpc="${work}/rel-fpc"
relbin="${work}/rel-bin"
rm -rf -- "${relfpc}" "${relbin}"
mkdir -p -- "${relfpc}" "${relbin}"
compile_pas "${relfpc}" "${relbin}" test/cap9c1/quickjsrelease.pas \
    -Fibuild/quickjs-release ||
    die 'quickjsrelease.pas compile FAILED'
exe="${relbin}/quickjsrelease"

# --- 4. the production location rule: the archive sits beside the exe ------
cp -f -- "${stage1}/plugins.zip" "${relbin}/plugins.zip"

# --- 5. run the matrix from a throwaway CWD --------------------------------
json="${work}/quickjsrelease-${target}.json"
rm -f -- "${json}"
step "run the headless C1-C30 matrix (${target})"
runcwd="$(mktemp -d)"
trap 'rm -rf -- "${runcwd}"' EXIT
set +e
( cd -- "${runcwd}" && "${exe}" ) > "${qlog}" 2>&1
code=$?
set -e
cat "${qlog}"

[ -f "${corpus}" ] ||
    die "the quickjs-release-corpus digest source was not written -- see ${qlog}"

if grep -qF "${pass_marker}" "${qlog}"; then
    [ "${code}" -eq 0 ] ||
        die "the PASS marker was printed but the harness exited ${code}"
    [ -f "${json}" ] || die 'PASS marker printed but no quickjsrelease JSON was written'
else
    die "CAP-9C1 quickjsrelease FAILED (exit ${code}) -- see ${qlog}"
fi

printf '[CAP-9C1] quickjsrelease verdict: PASS (%s)\n' "${target}"
