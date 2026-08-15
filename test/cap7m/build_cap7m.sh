#!/usr/bin/env bash
#
# CAP-7M0 PROBES I and J: compile everything the macOS gates run, natively,
# on THIS architecture, with the deployment target passed explicitly to every
# compile and every link.
#
# PROBE J is the whole point of this script existing per-architecture rather
# than once: "FPC hosts natively, mORMot core compiles, the binding compiles"
# is a claim about x86_64-darwin AND aarch64-darwin separately, and one arch
# failing is reported, never silently dropped by a matrix leg that quietly
# reused the other's artifacts.
#
# Layering is proven by the COMPILER, exactly as the Windows and Linux jobs do
# it: each isolation compile is given only the unit paths its layer may see,
# so a dependency creeping the wrong way fails here rather than being
# discovered later by reading code.
#
# NOTHING PRODUCTION IS BUILT HERE. There is no macOS adapter, no ported
# example and no packaging in this shard; the artifacts below are the ABI
# gate, the URI oracle and the throwaway feasibility probe.
#
# Produces, all under build/cap7m/:
#   iso/   isolation compiles (no binaries kept)
#   bin/   uri_oracle, cap7m_probe, signature_pin
#
# Prerequisites: tools/build-webview-dylib.sh has staged
# build/cap7m/webview-dist, and deps/webview + deps/mormot2 are present.
#
# Usage: test/cap7m/build_cap7m.sh [--clean]
#        --clean is OPT-IN; without it a stale work directory is a refusal.
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

eval "$(cap7m_take_clean_flag "$@")"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
assert_fpc_target
record_environment
set_fpc_arch_link_flags

command -v clang++ >/dev/null 2>&1 || die 'required tool not found: clang++'
command -v otool >/dev/null 2>&1 || die 'required tool not found: otool'

dylib_link="$(lock_get macos-dylib)"
dylib_versioned="$(lock_get macos-dylib-versioned)"
deployment_target="$(lock_get macos-deployment-target)"
host_arch="$(uname -m)"

[ -f "${dist}/${dylib_link}" ] ||
    die 'staged webview dylib missing -- run tools/build-webview-dylib.sh first'

# FPC and mORMot spell aarch64 the same way; the lock spells it arm64.
case "$(fpc -iTP | tr -d '[:space:]')" in
    x86_64) static_dir='deps/mormot2/static/x86_64-darwin' ;;
    aarch64) static_dir='deps/mormot2/static/aarch64-darwin' ;;
    *) die "unsupported FPC target CPU $(fpc -iTP)" ;;
esac
[ -d "${static_dir}" ] ||
    die "mORMot Darwin statics missing: ${static_dir} -- fetch deps/mormot2 first"

# Absolute, under ${repo_root}, rather than relying on the `cd` above: what a
# gate touches should not depend on the working directory being what an
# earlier line happened to set.
for stale in iso bin units; do
    cap7m_prepare_dir "${repo_root}/build/cap7m/${stale}"
done

mormot_core=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
)
# -WM<version> is FPC's deployment target. Passed on EVERY compile, never
# left to the SDK: an executable whose LC_BUILD_VERSION disagrees with the
# dylib's is a support matrix nobody ratified.
link_webview=(
    "-WM${deployment_target}"
    "-Fl${static_dir}"
    "-Fl${dist}"
    -k-rpath
    -k@executable_path
    # MEASURED, run 31909456486: without these, every FPC binary that actually
    # REFERENCES a webview symbol fails to link with "symbol(s) not found",
    # while abi_probe - which references nothing - links cleanly. `-Fl` is a
    # search PATH only; something has to put the library itself on the line.
    #
    # This mirrors exactly what the clang line below already does for the
    # ObjC++ probe (-L"${dist}" -lwebview), and -lwebview resolves
    # libwebview.dylib, whose install name is @rpath/libwebview.0.12.dylib -
    # so the resulting LC_LOAD_DYLIB is the one M16 already asserts.
    #
    # Supplying it explicitly is correct whether or not FPC would also emit
    # its own -l: a duplicate -l for the same dylib resolves once. What FPC
    # passes unaided is measured separately as CAP7M_LINKLINE below, because
    # the mechanism is NOT yet established - see constraint 11.
    "-k-L${dist}"
    -k-lwebview
)
# Unquoted on purpose: empty on x86_64, and must then add no argument at all.
# On aarch64 this is -k-no_fixup_chains; the measured link failure it works
# around, and the -WM11.0 alternative deliberately not taken, are documented
# at set_fpc_arch_link_flags in cap7m_common.sh.
# shellcheck disable=SC2206
link_webview+=( ${CAP7M_FPC_ARCH_LINK_FLAGS} )

# --- raw binding layer --------------------------------------------------------
step 'binding units (the regenerated 4-branch platform block, Darwin arm)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/lib "-WM${deployment_target}" \
    src/lib/pweb.lib.webview.pas ||
    die 'pweb.lib.webview.pas failed to compile for Darwin'
fpc -MObjFPC -Sh -FUbuild/cap7m/iso -Fusrc/lib "-WM${deployment_target}" \
    src/lib/pweb.lib.webview.types.pas || die 'pweb.lib.webview.types.pas failed'
fpc -MObjFPC -Sh -FUbuild/cap7m/iso -Fusrc/lib "-WM${deployment_target}" \
    src/lib/pweb.lib.webview.errors.pas || die 'pweb.lib.webview.errors.pas failed'

# --- layering isolation compiles ---------------------------------------------
step 'isolation compiles (each layer sees only what it may)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso "-WM${deployment_target}" \
    src/rpc/pweb.rpc.intf.pas || die 'pweb.rpc.intf.pas is not RTL-only'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso "-WM${deployment_target}" \
    src/webview/pweb.webview.intf.pas ||
    die 'pweb.webview.intf.pas failed RTL-only compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/rpc "-WM${deployment_target}" \
    src/rpc/pweb.rpc.scheduler.pas ||
    die 'pweb.rpc.scheduler.pas failed its webview-free RTL-only compile'
# the stores stay webview-free on Darwin too
for unit in support folder zip; do
    fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/assets "${mormot_core[@]}" \
        "-WM${deployment_target}" "src/assets/pweb.assets.${unit}.pas" ||
        die "pweb.assets.${unit}.pas failed its isolation compile"
done

# --- compile-only ABI gate ----------------------------------------------------
# --- MEASURED: what FPC puts on the link line UNAIDED ------------------------
#
# Run BEFORE the real compile, with the explicit -L/-l deliberately withheld,
# so it records what FPC does on its own rather than what we made it do.
# Entirely non-fatal: this is an instrument, not a gate, and it is expected to
# fail to link on a toolchain where the explicit flags are needed.
#
# It exists because the mechanism is genuinely open. Reading FPC 3.2.2's
# source, compiler/systems/t_bsd.pas:355-369 DOES emit `-l<lib>` from
# SharedLibFiles for Darwin (LdSupportsNoResponseFile is true for
# systems_darwin at :132), and t_linux.pas:565-576 is the SAME code - so
# "FPC emits no -l on Mach-O" is not something the source supports. Yet the
# observed failure was "symbol(s) not found", not "library not found for
# -l…", which is what an emitted-but-unresolvable -l would produce. Something
# else is going on, and this records it instead of guessing.
step 'MEASURED: the link line FPC produces unaided (CAP7M_LINKLINE)'
linkline_dir="${repo_root}/build/cap7m/linkline"
mkdir -p -- "${linkline_dir}/units" "${linkline_dir}/bin"
set +e
# shellcheck disable=SC2086
fpc -va -Sh -B -FU"${linkline_dir}/units" -FE"${linkline_dir}/bin" \
    -Fusrc/lib -Fideps/mormot2/src \
    "-WM${deployment_target}" "-Fl${static_dir}" "-Fl${dist}" \
    -k-rpath -k@executable_path ${CAP7M_FPC_ARCH_LINK_FLAGS} \
    test/core/signature_pin.pas > "${linkline_dir}/fpc-va.log" 2>&1
linkline_rc=$?
set -e
record_measurement "CAP7M_LINKLINE unaided_exit=${linkline_rc}"
# Every distinct way the library could appear on the line, recorded verbatim.
for pattern in '\-lwebview' '\-llibwebview' 'libwebview' '\-L'; do
    hits="$(grep -aoE "[^[:space:]]*${pattern}[^[:space:]]*" \
        "${linkline_dir}/fpc-va.log" 2>/dev/null | LC_ALL=C sort -u | head -n 8 || true)"
    if [ -n "${hits}" ]; then
        printf '%s\n' "${hits}" | while IFS= read -r h; do
            [ -n "${h}" ] && record_measurement "CAP7M_LINKLINE token=${h}" > /dev/null
        done
    fi
done
if grep -aqE '(^|[[:space:]])-lwebview([[:space:]]|$)' "${linkline_dir}/fpc-va.log"; then
    record_measurement 'CAP7M_LINKLINE fpc_emits_l_webview=yes'
else
    record_measurement 'CAP7M_LINKLINE fpc_emits_l_webview=no'
fi
# the linker invocation itself, if -va printed one
ld_line="$(grep -aE 'ld|clang' "${linkline_dir}/fpc-va.log" |
    grep -aE '\-o[[:space:]]|\-arch|\-L' | tail -n 1 || true)"
if [ -n "${ld_line}" ]; then
    record_measurement "CAP7M_LINKLINE ld_invocation=$(printf '%s' "${ld_line}" | cut -c1-600)"
else
    record_measurement 'CAP7M_LINKLINE ld_invocation=<not printed by -va>'
fi

step 'signature pin (all 17 prototypes)'
# COMPILE failure and LINK failure mean opposite things here, and conflating
# them sends the next reader to the wrong place: "binding signatures drifted"
# was the message for a link error that had nothing to do with signatures.
sigpin_log="${repo_root}/build/cap7m/signature_pin.log"
if ! fpc -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin -Fusrc/lib \
        -Fideps/mormot2/src "${link_webview[@]}" test/core/signature_pin.pas \
        > "${sigpin_log}" 2>&1; then
    cat "${sigpin_log}" >&2
    if grep -qaE 'Error while linking|^ld: |symbol\(s\) not found|library not found' \
            "${sigpin_log}"; then
        die 'signature_pin failed to LINK: the webview library did not reach the linker. This is NOT a signature drift -- see CAP7M_LINKLINE and constraint 11 in docs/wkwebview-macos-semantics.md'
    fi
    die 'signature_pin failed to COMPILE: the binding signatures drifted'
fi
cat "${sigpin_log}"

# --- the URI oracle -----------------------------------------------------------
# Also PROBE J's "mORMot core compiles" leg: this pulls mormot.core.base and
# links the Darwin statics for this architecture.
step 'URI oracle (the shared PWebParseAppUri, on Darwin)'
# links a Pascal program, so it needs the same arch-conditional link flag
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin \
    -Fusrc/assets "${mormot_core[@]}" "-WM${deployment_target}" \
    "-Fl${static_dir}" ${CAP7M_FPC_ARCH_LINK_FLAGS} \
    test/cap7m/uri_oracle.pas ||
    die 'uri_oracle failed to compile'

# --- the feasibility probe ----------------------------------------------------
step 'CAP-7M0 Objective-C++ feasibility probe'
# -DWEBVIEW_SHARED is MANDATORY and easy to miss: macros.h defines
# WEBVIEW_API as `inline` for a C++ translation unit that declares neither
# WEBVIEW_SHARED nor WEBVIEW_STATIC (core/include/webview/macros.h:45-60), so
# without it every one of the 17 prototypes becomes an inline function with
# no definition. test/cap4w/CMakeLists.txt:33 passes it for the same reason.
#
# -fno-objc-arc on purpose: the probe measures ownership (the +new return
# value, the retained tasks, the response buffer handoff), and ARC would hide
# exactly what is under measurement.
#
# -std=c++17 matches the Windows probe (test/cap4w/CMakeLists.txt:31); -arch
# and -mmacosx-version-min are explicit for the same reason every other
# compile here is.
clang++ -std=c++17 -fno-objc-arc -O1 -Wall -Wextra -Werror \
    -DWEBVIEW_SHARED \
    -arch "${host_arch}" "-mmacosx-version-min=${deployment_target}" \
    -Ideps/webview/core/include \
    -framework Cocoa -framework WebKit \
    test/cap7m/cap7m_probe.mm -o build/cap7m/bin/cap7m_probe \
    -Wl,-rpath,@executable_path -L"${dist}" -lwebview ||
    die 'cap7m_probe failed to compile'

cp -f -- "${dist}/${dylib_versioned}" build/cap7m/bin/

# --- MEASURED: what the linker actually recorded ------------------------------
# The Linux sibling asserts DT_NEEDED == the SONAME here. The Mach-O statement
# of the same fact is LC_LOAD_DYLIB == the install name, which is why the
# VERSIONED file is what ships and the bare .dylib is a link-time convenience.
# LC_BUILD_VERSION on anything modern, LC_VERSION_MIN_MACOSX on older
# toolchains. The fallback matters MORE here than in the dylib build that
# already has it: these binaries are linked by FPC 3.2.2, the oldest
# toolchain in this shard and therefore the likeliest to emit the old load
# command. Without it the read-back returns the empty string and the gate
# dies with "minos is ''", which reads as a deployment-target violation when
# the target is in fact correct.
read_minos() {
    local out
    out="$(otool -l "$1" |
        awk '/LC_BUILD_VERSION/ { b = 1 } b && /^ *minos / { print $2; exit }')"
    if [ -z "${out}" ]; then
        out="$(otool -l "$1" |
            awk '/LC_VERSION_MIN_MACOSX/ { b = 1 } b && /^ *version / { print $2; exit }')"
    fi
    printf '%s' "${out}"
}

# EVERY binary this script produced, not just the ones that link the dylib:
# uri_oracle is compiled with an explicit floor too, and an unverified -WM is
# exactly the "the SDK decided it" failure M16 exists to exclude.
#
# THE LOAD COMMAND IS ASSERTED WHERE THE REFERENCE EXISTS, and only there.
# MEASURED (run 31905105454): Mach-O records an LC_LOAD_DYLIB only when a
# symbol from that dylib is actually referenced - ELF's --as-needed behaviour,
# unconditionally. So "carries a load command" is a property of what a binary
# USES, not of what it was linked against, and demanding it everywhere would
# assert a Linux property that does not exist here. Two rules instead:
#
#   - cap7m_probe MUST carry one. It calls webview_create and fifteen others,
#     so an absence there would mean the reference vanished - and it is also
#     the binary whose load command the PROBE K bundle layout depends on.
#   - any binary that DOES carry one must name @rpath/<versioned dylib>.
#     Recorded for the rest, since signature_pin only takes the addresses of
#     the 17 externals and uri_oracle references none of them.
for binary in build/cap7m/bin/cap7m_probe build/cap7m/bin/signature_pin \
              build/cap7m/bin/uri_oracle; do
    [ -x "${binary}" ] || die "expected binary missing: ${binary}"
    name="$(basename -- "${binary}")"

    minos="$(read_minos "${binary}")"
    [ -n "${minos}" ] ||
        die "${binary} carries neither LC_BUILD_VERSION nor LC_VERSION_MIN_MACOSX"
    case "${minos}" in
        "${deployment_target}"|"${deployment_target}".0) ;;
        *) die "${binary} minos is '${minos}', expected '${deployment_target}'" ;;
    esac

    loaded="$(otool -L "${binary}" | awk '/libwebview/ { print $1; exit }')"
    if [ -n "${loaded}" ]; then
        # wherever it exists, it must be @rpath-relative and versioned - that
        # is the fact a bundle layout is built on
        case "${loaded}" in
            @rpath/*"${dylib_versioned}") ;;
            *) die "${binary} loads '${loaded}', expected @rpath/${dylib_versioned}" ;;
        esac
    elif [ "${name}" = 'cap7m_probe' ]; then
        die 'cap7m_probe records no libwebview load command -- it calls into the dylib, so the reference has gone missing'
    fi

    # uri_oracle is not linked with -rpath and needs none; the other two are.
    rpath=''
    if [ "${name}" != 'uri_oracle' ]; then
        rpath="$(otool -l "${binary}" |
            awk '/LC_RPATH/ { r = 1 } r && /^ *path / { print $2; r = 0 }' |
            grep -x '@executable_path' || true)"
        [ "${rpath}" = '@executable_path' ] ||
            die "${binary} has no LC_RPATH @executable_path (CWD dependence)"
    fi

    record_measurement "CAP7M_M16 binary=${name} minos=${minos} references_dylib=$([ -n "${loaded}" ] && printf 'yes' || printf 'no') load=${loaded:-<none>} rpath=${rpath:-<none>}"
done

printf '\n[CAP-7M0] build_cap7m: PASS (%s, deployment target %s)\n' \
    "${host_arch}" "${deployment_target}"
