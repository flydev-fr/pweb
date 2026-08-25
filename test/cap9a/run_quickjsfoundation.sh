#!/usr/bin/env bash
#
# CAP-9A: the QuickJS invocation-foundation harness on the POSIX targets -
# Linux x64 and macOS (both native architectures), dispatched on uname.
# The bash sibling of test/cap9a/run_quickjsfoundation.ps1.
#
# Builds test/cap9a/quickjsfoundation.pas (the UNCHANGED production
# scheduler + CAP-8A policy + the real mORMot SOA bridge behind a counting
# decorator, with two concurrent QuickJS plugin threads as invocation
# sources) and runs the headless Q1-Q30 matrix, which writes the canonical
# build/cap9a/quickjs-corpus.txt digest source.
#
# HEADLESS by design: no WebView, no DISPLAY, no dylib staging. The only
# platform asymmetry is where the QuickJS static object comes from:
#   Linux : deps/mormot2/static/x86_64-linux/quickjs.o from the
#           sha256-pinned mormot2static release (LIBQUICKJSSTATIC is
#           auto-defined by the pinned mormot.defines.inc there);
#   macOS : the pinned mORMot release carries NO darwin quickjs.o and the
#           pinned defines never set LIBQUICKJSSTATIC on darwin - so this
#           runner first builds the object from the PINNED in-tree sources
#           (tools/build_quickjs_darwin.sh, which refuses a non-pinned
#           checkout) and passes -dLIBQUICKJSSTATIC + -Fo itself.
#
# ABI pairing: the harness writes build/cap9a/abi-pascal.txt; this runner
# compiles test/cap9a/abiprobe.c against the PINNED headers with the exact
# static-build defines and diffs the two line sets byte-for-byte. Both
# POSIX targets always have the toolchain, so the diff always gates here.
#
# Unlike Windows, POSIX needs NO CAP-3U patch window: the mORMot x64
# call-method trampoline is a Win64-only concern (same reasoning and
# wording as test/cap8c/run_multiprincipal.sh) - the ps1 sibling compiles
# inside the window, this runner compiles the SOA path directly.
#
# Writes: build/cap9a/quickjsfoundation-<target>.json (PASS|FAIL),
#         build/cap9a/quickjs-corpus.txt (the digest source),
#         build/cap9a/abi-pascal.txt + abi-c.txt, and the run log.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-9A] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-9A] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

work="${repo_root}/build/cap9a"
mkdir -p -- "${work}"
corpus="${work}/quickjs-corpus.txt"
abipas="${work}/abi-pascal.txt"
abic="${work}/abi-c.txt"
qlog="${work}/quickjsfoundation-posix.log"
rm -f -- "${corpus}" "${abipas}" "${abic}" "${qlog}" "${work}"/quickjsfoundation-*.json

for pre in test/cap9a/quickjsfoundation.pas test/cap9a/abiprobe.c \
           src/script/pweb.script.quickjs.pas \
           deps/mormot2/res/static/libquickjs/quickjs.h; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

pass_marker="$(sed -n "s/^  MARKER_PASS = '\\([^']*\\)';\$/\\1/p" \
    test/cap9a/quickjsfoundation.pas)"
[ -n "${pass_marker}" ] || die 'could not read MARKER_PASS from quickjsfoundation.pas'
# exactly ONE marker line, like the ps1 sibling: a multi-line result would
# quietly turn the grep -qF below into an any-of match
[ "$(printf '%s\n' "${pass_marker}" | wc -l)" -eq 1 ] ||
    die 'expected exactly one MARKER_PASS constant in quickjsfoundation.pas'
printf '[CAP-9A] canonical pass marker: %s\n' "${pass_marker}"

os_name="$(uname -s)"
outdir="${work}/qf-bin"
unitdir="${work}/qf-fpc"
rm -rf -- "${outdir}" "${unitdir}"
mkdir -p -- "${outdir}" "${unitdir}"

qjs_src='deps/mormot2/res/static/libquickjs'
qjs_defines=( -DCONFIG_BIGNUM -DJS_STRICT_NAN_BOXING -DCONFIG_JSX -DCONFIG_DEBUGGER )

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
    cprobe_cc='gcc'

    # mechanical quickjs-libc audit of the RELEASE-SHIPPED object (its
    # bytes are already sha256-pinned via mormot.lock, this asserts the
    # pinned bytes themselves carry no std/os MODULE REGISTRATION
    # surface: js_init_module_std/os, js_std_add_helpers, js_std_loop).
    # A bare js_std_/js_os_ prefix match false-positives on the harmless
    # js_std_eval_binary helper the pinned patch moved into quickjs.c
    # (measured, hosted run 32857758203). Explicit nm failure check: an
    # empty pipe must never pass the audit. On Windows the sha256 pin
    # alone stands (no guaranteed nm); Darwin audits its own freshly
    # built object inside tools/build_quickjs_darwin.sh.
    step 'quickjs-libc symbol audit of the pinned static object'
    qsyms="$(nm 'deps/mormot2/static/x86_64-linux/quickjs.o')" ||
        die 'nm failed on the pinned quickjs.o -- audit impossible'
    [ -n "${qsyms}" ] || die 'nm enumerated no symbols from the pinned quickjs.o'
    if printf '%s\n' "${qsyms}" | grep -E ' T (js_init_module_(std|os)|js_std_add_helpers|js_std_loop)$' > /dev/null; then
        die 'quickjs-libc module-registration symbols found in the pinned quickjs.o -- refuse'
    fi
    printf '[CAP-9A] pinned quickjs.o defines no quickjs-libc module-registration surface\n'

    step 'compile quickjsfoundation (production runtime + pinned QuickJS statics)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Fusrc/script -Fusrc/rpc -Fusrc/security \
        "${mormot_units[@]}" \
        -Fldeps/mormot2/static/x86_64-linux \
        test/cap9a/quickjsfoundation.pas ||
        die 'quickjsfoundation.pas compile FAILED'
    exe="${outdir}/quickjsfoundation"
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
    cprobe_cc='clang'

    step 'build the pinned QuickJS static object (no darwin artifact in the release)'
    qjs_obj_dir="${work}/qjs-obj"
    tools/build_quickjs_darwin.sh "${qjs_obj_dir}" ||
        die 'tools/build_quickjs_darwin.sh FAILED'

    step 'compile quickjsfoundation (production runtime + CI-built QuickJS object)'
    fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -dLIBQUICKJSSTATIC \
        -Fusrc/script -Fusrc/rpc -Fusrc/security \
        "${mormot_units[@]}" \
        -Fo"${qjs_obj_dir}" \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
        test/cap9a/quickjsfoundation.pas ||
        die 'quickjsfoundation.pas compile FAILED'
    exe="${outdir}/quickjsfoundation"
    ;;

*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

json="${work}/quickjsfoundation-${target}.json"
rm -f -- "${json}"

step "run the headless Q1-Q30 matrix (${target})"
set +e
( cd -- "$(mktemp -d)" && "${exe}" ) > "${qlog}" 2>&1
code=$?
set -e
cat "${qlog}"

[ -f "${corpus}" ] ||
    die "the quickjs-corpus digest source was not written -- see ${qlog}"
[ -f "${abipas}" ] ||
    die "the Pascal ABI line set was not written -- see ${qlog}"

if grep -qF "${pass_marker}" "${qlog}"; then
    [ "${code}" -eq 0 ] ||
        die "the PASS marker was printed but the harness exited ${code}"
    [ -f "${json}" ] || die 'PASS marker printed but no quickjsfoundation JSON was written'
else
    die "CAP-9A quickjsfoundation FAILED (exit ${code}) -- see ${qlog}"
fi

step 'paired C/Pascal ABI diff against the pinned headers'
command -v "${cprobe_cc}" >/dev/null 2>&1 ||
    die "required C toolchain not found: ${cprobe_cc}"
"${cprobe_cc}" -o "${outdir}/abiprobe" -I"${qjs_src}" "${qjs_defines[@]}" \
    test/cap9a/abiprobe.c ||
    die 'abiprobe.c compile FAILED against the pinned headers'
"${outdir}/abiprobe" > "${abic}" || die 'abiprobe execution FAILED'
diff -u "${abipas}" "${abic}" ||
    die 'JSValue ABI mismatch between the Pascal binding and the pinned C headers -- STOP'
printf '[CAP-9A] ABI line sets identical (C vs Pascal)\n'

printf '[CAP-9A] quickjsfoundation verdict: PASS (%s)\n' "${target}"
