#!/usr/bin/env bash
#
# CAP-7M: compile everything the macOS gates run, natively, on THIS
# architecture, with every flag taken from tools/macos-buildenv.sh.
#
# NOT ONE COMPILE OR LINK FLAG IS WRITTEN HERE. Before CAP-7M1 this script
# carried `-WM` ten times, an `-arch`, a `-mmacosx-version-min`, four `-Fl`s,
# the only `-framework`/`-Wl,-rpath`/`-L`/`-lwebview` in the tree, and its own
# copy of the arch -> mORMot-static-dir map. Every one of them now comes from
# the helper, so the deployment target has exactly one place to drift from.
#
# PER-ARCHITECTURE BY DESIGN: "FPC hosts natively, mORMot core compiles, the
# binding compiles, the production adapter compiles and links" is a claim
# about x86_64-darwin AND aarch64-darwin separately, and one arch failing is
# reported, never silently dropped by a matrix leg that quietly reused the
# other's artifacts.
#
# Layering is proven by the COMPILER, exactly as the Windows and Linux jobs do
# it: each isolation compile is given only the unit paths its layer may see,
# so a dependency creeping the wrong way fails here rather than being
# discovered later by reading code.
#
# Produces, all under build/cap7m/:
#   iso/   isolation compiles (no binaries kept)
#   bin/   uri_oracle, cap7m_probe, signature_pin, pwebtests, cap7m_runtime
#
# Prerequisites: tools/build-webview-dylib.sh has staged
# build/cap7m/webview-dist, tools/build-macos-bridge.sh has compiled the
# Cocoa bridge object, and deps/webview + deps/mormot2 are present.
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

command -v clang++ >/dev/null 2>&1 || die 'required tool not found: clang++'
command -v otool >/dev/null 2>&1 || die 'required tool not found: otool'

[ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB}" ] ||
    die 'staged webview dylib missing -- run tools/build-webview-dylib.sh first'
[ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
    die 'Cocoa bridge object missing -- run tools/build-macos-bridge.sh first'
[ -d "${PWEB_MACOS_STATIC_DIR}" ] ||
    die "mORMot Darwin statics missing: ${PWEB_MACOS_STATIC_DIR} -- fetch deps/mormot2 first"

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
# Every unit path the full test suite and the runtime harness need. Exactly
# the set test/cap7l/build_cap7l.sh:50-60 proves sufficient for pwebtests -
# same suite, same units, one more platform.
mormot_all=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
    -Fudeps/mormot2/src/net
    -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm
    -Fudeps/mormot2/src/rest
    -Fudeps/mormot2/src/soa
)
pweb_units=(
    -Fusrc/lib
    -Fusrc/rpc
    -Fusrc/webview
    -Fusrc/assets
    -Fusrc/security
    -Fusrc/platform/macos
    -Futest/core
    -Futest/rpc
    -Futest/security
    -Futest/assets
    -Futest/platform
)

# --- raw binding layer --------------------------------------------------------
step 'binding units (the regenerated 4-branch platform block, Darwin arm)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/lib \
    "${PWEB_MACOS_FPC_FLAGS[@]}" src/lib/pweb.lib.webview.pas ||
    die 'pweb.lib.webview.pas failed to compile for Darwin'
fpc -MObjFPC -Sh -FUbuild/cap7m/iso -Fusrc/lib \
    "${PWEB_MACOS_FPC_FLAGS[@]}" src/lib/pweb.lib.webview.types.pas ||
    die 'pweb.lib.webview.types.pas failed'
fpc -MObjFPC -Sh -FUbuild/cap7m/iso -Fusrc/lib \
    "${PWEB_MACOS_FPC_FLAGS[@]}" src/lib/pweb.lib.webview.errors.pas ||
    die 'pweb.lib.webview.errors.pas failed'

# --- layering isolation compiles ---------------------------------------------
step 'isolation compiles (each layer sees only what it may)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso "${PWEB_MACOS_FPC_FLAGS[@]}" \
    src/rpc/pweb.rpc.intf.pas || die 'pweb.rpc.intf.pas is not RTL-only'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso "${PWEB_MACOS_FPC_FLAGS[@]}" \
    src/webview/pweb.webview.intf.pas ||
    die 'pweb.webview.intf.pas failed RTL-only compile'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/rpc "${PWEB_MACOS_FPC_FLAGS[@]}" \
    src/rpc/pweb.rpc.scheduler.pas ||
    die 'pweb.rpc.scheduler.pas failed its webview-free RTL-only compile'
# CAP-8A: the production capability engine stays RTL-only on Darwin too
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/rpc -Fusrc/security \
    "${PWEB_MACOS_FPC_FLAGS[@]}" src/security/pweb.capabilities.policy.pas ||
    die 'pweb.capabilities.policy.pas failed its RTL-only isolation compile'
# the stores stay webview-free on Darwin too
for unit in support folder zip; do
    fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso -Fusrc/assets "${mormot_core[@]}" \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "src/assets/pweb.assets.${unit}.pas" ||
        die "pweb.assets.${unit}.pas failed its isolation compile"
done
# CAP-7M1: the production adapter sees the binding, the asset contracts, the
# shared URI routine and - since CAP-8B - the shared navigation classifier, and
# NOTHING of the scheduler, the bridge or the wire. A dependency creeping the
# wrong way fails right here.
#
# -Fusrc/security is the CAP-8B addition and it buys exactly one unit:
# pweb.navigation.policy, which is RTL + mormot.core.base + pweb.assets.support
# and carries no webview, no engine type and no platform conditional. The
# adapter must reach it, because the alternative is a second copy of the
# classification table and of PWEB_NATIVE_CSP living in each engine.
step 'isolation compile: the production macOS adapter'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/iso \
    -Fusrc/lib -Fusrc/assets -Fusrc/security -Fusrc/platform/macos \
    "${mormot_core[@]}" \
    "${PWEB_MACOS_FPC_FLAGS[@]}" src/platform/macos/pweb.platform.cocoa.pas ||
    die 'pweb.platform.cocoa.pas failed its isolation compile'

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
# The UNAIDED set differs from the real one by exactly the two elements under
# measurement (-k-L/-k-lwebview) and by nothing else - including the aarch64
# link flag, which it keeps, so a failure here means what it says rather than
# meaning "we forgot -no_fixup_chains". It is defined in the helper for the
# same reason every other flag is: nothing outside that file writes one.
fpc -va -Sh -B -FU"${linkline_dir}/units" -FE"${linkline_dir}/bin" \
    -Fusrc/lib -Fideps/mormot2/src \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_WEBVIEW_UNAIDED[@]}" \
    test/core/signature_pin.pas > "${linkline_dir}/fpc-va.log" 2>&1
linkline_rc=$?
set -e
record_measurement "CAP7M_LINKLINE unaided_exit=${linkline_rc}"
# Every distinct way the library could appear on the line, recorded verbatim.
# The two lines below are SEARCH patterns over the linker log, not flags being
# passed: the whole point of this block is to measure whether FPC emitted them
# for us. The marker is per-LINE, so an exemption is visible on the line it
# applies to rather than inferred from a nearby comment.
for pattern in '\-lwebview' '\-llibwebview' 'libwebview' '\-L'; do # macos-flag-scan-exempt
    hits="$(grep -aoE "[^[:space:]]*${pattern}[^[:space:]]*" \
        "${linkline_dir}/fpc-va.log" 2>/dev/null | LC_ALL=C sort -u | head -n 8 || true)"
    if [ -n "${hits}" ]; then
        printf '%s\n' "${hits}" | while IFS= read -r h; do
            [ -n "${h}" ] && record_measurement "CAP7M_LINKLINE token=${h}" > /dev/null
        done
    fi
done
if grep -aqE '(^|[[:space:]])-lwebview([[:space:]]|$)' "${linkline_dir}/fpc-va.log"; then # macos-flag-scan-exempt
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
        -Fideps/mormot2/src "${PWEB_MACOS_FPC_FLAGS[@]}" \
        "${PWEB_MACOS_FPC_LINK_WEBVIEW[@]}" test/core/signature_pin.pas \
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
# Also the "mORMot core compiles" leg: this pulls mormot.core.base and links
# the Darwin statics for this architecture. It references no webview symbol,
# so it needs the mORMot link set only.
step 'URI oracle (the shared PWebParseAppUri, on Darwin)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin \
    -Fusrc/assets "${mormot_core[@]}" \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
    test/cap7m/uri_oracle.pas ||
    die 'uri_oracle failed to compile'

# --- the CAP-7M0 feasibility probe, KEPT ---------------------------------------
# It is no longer the shard's deliverable, and production depends on none of
# its answers - but poststop_throws, abort_delivered, handoff and
# seam_a_effective are PLATFORM FACTS, and a silent change to any of them is
# exactly the class of drift that would otherwise surface as corrupted assets
# in someone's application. So it keeps running as the platform regression.
step 'CAP-7M0 Objective-C++ feasibility probe (kept as the platform regression)'
clang++ "${PWEB_MACOS_CLANGXX_OBJCXX_FLAGS[@]}" \
    "${PWEB_MACOS_CLANG_WARNINGS[@]}" "${PWEB_MACOS_CLANG_FLAGS[@]}" \
    -Ideps/webview/core/include \
    "${PWEB_MACOS_FRAMEWORKS[@]}" \
    test/cap7m/cap7m_probe.mm -o build/cap7m/bin/cap7m_probe \
    "${PWEB_MACOS_CLANG_LINK_WEBVIEW[@]}" ||
    die 'cap7m_probe failed to compile'

# --- the full PWeb test suite, including the Darwin adapter cases -------------
# The suite links the production bridge object and therefore Cocoa and WebKit:
# test/platform/pweb.test.cocoa.pas drives the REAL task state machine over a
# stub task, which needs the real Objective-C classes and nothing else.
step 'pwebtests (the full suite, with the CAP-7M1 Darwin adapter cases)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin \
    "${pweb_units[@]}" "${mormot_all[@]}" \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
    test/core/pwebtests.pas ||
    die 'pwebtests failed to compile'

# --- the production runtime harness -------------------------------------------
step 'cap7m_runtime (the production runtime harness)'
fpc -MObjFPC -Sh -B -FUbuild/cap7m/units -FEbuild/cap7m/bin \
    "${pweb_units[@]}" "${mormot_all[@]}" \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
    test/cap7m/cap7m_runtime.pas ||
    die 'cap7m_runtime failed to compile'

cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" build/cap7m/bin/

# --- MEASURED: what the linker actually recorded ------------------------------
# The Linux sibling asserts DT_NEEDED == the SONAME here. The Mach-O statement
# of the same fact is LC_LOAD_DYLIB == the install name, which is why the
# VERSIONED file is what ships and the bare .dylib is a link-time convenience.
#
# THE LOAD COMMAND IS ASSERTED WHERE THE REFERENCE EXISTS, and only there.
# MEASURED (run 31905105454): Mach-O records an LC_LOAD_DYLIB only when a
# symbol from that dylib is actually referenced - ELF's --as-needed behaviour,
# unconditionally. So "carries a load command" is a property of what a binary
# USES, not of what it was linked against.
#
#   cap7m_probe, pwebtests and cap7m_runtime MUST carry one and MUST have an
#   @executable_path rpath: all three call into the dylib, and all three are
#   binaries a bundle layout would have to place.
#   signature_pin only takes the addresses of the 17 externals and uri_oracle
#   references none of them, so both are recorded rather than required.
step 'Mach-O shape of every produced binary (arch, minos, load command, rpath)'
for binary in cap7m_probe pwebtests cap7m_runtime; do
    pweb_macos_assert_macho "build/cap7m/bin/${binary}" \
        --require-dylib --require-rpath
    record_measurement "${PWEB_MACOS_MACHO_FACT}"
done
# signature_pin is linked with the full webview set, so it MUST carry the
# rpath even though it only takes the 17 addresses and therefore records no
# load command. uri_oracle is linked with the mORMot set alone and needs
# neither - it is recorded, not required.
pweb_macos_assert_macho "build/cap7m/bin/signature_pin" --require-rpath
record_measurement "${PWEB_MACOS_MACHO_FACT}"
pweb_macos_assert_macho "build/cap7m/bin/uri_oracle"
record_measurement "${PWEB_MACOS_MACHO_FACT}"
# the bridge object too: it is a produced Mach-O like any other
pweb_macos_assert_macho "${PWEB_MACOS_BRIDGE_OBJ}" --object
record_measurement "${PWEB_MACOS_MACHO_FACT}"

printf '\n[CAP-7M] build_cap7m: PASS (%s, deployment target %s)\n' \
    "${PWEB_MACOS_HOST_ARCH}" "${PWEB_MACOS_DEPLOYMENT_TARGET}"
