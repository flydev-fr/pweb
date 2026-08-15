#!/usr/bin/env bash
#
# CAP-7M0 PROBE B (M4/M5): the Pascal side and the C side agree on Darwin, and
# every one of the 17 hand-free externals really resolves.
#
# Three parts, all blocking:
#
#   1. The CORE paired probe (test/core/abi_probe.c / abi_probe.pas), the same
#      36 facts CI compares on Windows and Linux. Both files are the single
#      pinned CAP-1 pair and are used UNMODIFIED - the Darwin work is a new
#      harness around them, never a third copy. Exactly TWO lines may differ,
#      with exactly the documented values:
#
#         signed.webview_hint_t                 C=0  Pascal=1
#         signed.webview_native_handle_kind_t   C=0  Pascal=1
#
#      MSVC types every C enum as signed int; clang and gcc both pick unsigned
#      when no enumerator is negative, and both of these enums are 0..3. Width
#      is 4 bytes on every side and every transported value is non-negative,
#      so the calling convention is untouched. webview_error_t has a negative
#      enumerator and is therefore signed everywhere. Any OTHER difference,
#      and any difference in the VALUES of these two lines, blocks.
#
#      clang needs the same -Wno-type-limits gcc needed: abi_probe.c measures
#      signedness with ((type)-1 < 0), and for an enum the compiler made
#      unsigned that comparison is provably false - which IS the fact being
#      measured, not a defect. Every other warning still blocks.
#
#   2. The Mach-O presence gate. Every symbol the generated binding declares
#      must be exported by the dylib it is declared against, under the
#      underscore convention Mach-O uses. Read out of the binding rather than
#      typed here, so a regeneration that dropped a declaration cannot pass by
#      matching a list that was never updated.
#
#   3. The dlopen/dlsym gate. Part 2 proves the name is in the table; this
#      proves the DYNAMIC LOADER resolves it from the staged artifact, which
#      is the thing FPC's `external` actually depends on at run time. A typo
#      or a stripped export would otherwise only surface on a user's machine.
#
# Prerequisite: tools/build-webview-dylib.sh has staged build/cap7m/webview-dist.
#
# Usage: test/cap7m/check_abi.sh
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
assert_fpc_target
record_environment
set_fpc_arch_link_flags

abi="${work}/abi"

for tool in clang nm otool; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
[ -f "${repo_root}/deps/webview/core/include/webview/api.h" ] ||
    die 'pinned headers missing -- fetch deps/webview first'

dylib_link="$(lock_get macos-dylib)"
dylib_versioned="$(lock_get macos-dylib-versioned)"
deployment_target="$(lock_get macos-deployment-target)"
host_arch="$(uname -m)"

[ -f "${dist}/${dylib_link}" ] ||
    die "staged webview dylib missing -- run tools/build-webview-dylib.sh first (${dist})"

rm -rf -- "${abi}"
mkdir -p -- "${abi}/units" "${abi}/bin"
# The Pascal probe links against the dev name and LOADS the versioned one
# (ld records the install name, exactly as it records the SONAME on Linux), so
# the versioned file has to sit beside the binary for @executable_path to find.
cp -f -- "${dist}/${dylib_versioned}" "${abi}/bin/"

# --- 1. core paired probe -----------------------------------------------------

step 'core paired ABI probe (the unmodified CAP-1 pair, on Darwin)'
clang -O1 -Wall -Wextra -Werror -Wno-type-limits \
    -arch "${host_arch}" "-mmacosx-version-min=${deployment_target}" \
    -I"${repo_root}/deps/webview/core/include" \
    "${repo_root}/test/core/abi_probe.c" -o "${abi}/bin/abi_probe_c" ||
    die 'core C ABI probe failed to compile'
"${abi}/bin/abi_probe_c" > "${abi}/abi_c.txt" ||
    die 'core C ABI probe exited nonzero'

# CAP7M_FPC_ARCH_LINK_FLAGS is UNQUOTED on purpose: it is empty on x86_64 and
# must then contribute no argument at all. See set_fpc_arch_link_flags in
# cap7m_common.sh for the measured aarch64 link failure it works around.
# shellcheck disable=SC2086
fpc -Sh -B -FU"${abi}/units" -FE"${abi}/bin" \
    -Fu"${repo_root}/src/lib" \
    -Fi"${repo_root}/deps/mormot2/src" \
    "-WM${deployment_target}" \
    -Fl"${dist}" -k-rpath -k@executable_path \
    ${CAP7M_FPC_ARCH_LINK_FLAGS} \
    "${repo_root}/test/core/abi_probe.pas" > "${abi}/abi_pascal.log" 2>&1 ||
    { cat "${abi}/abi_pascal.log" >&2; die 'core Pascal ABI probe failed to compile'; }
"${abi}/bin/abi_probe" > "${abi}/abi_pascal.txt" ||
    die 'core Pascal ABI probe exited nonzero'

# PHYSICAL lines, with wc -l, for the EQUALITY test. `grep -c .` counts
# non-blank lines, so a Pascal probe that emitted a blank line and one extra
# fact would tie with the C probe on that count while the two files are
# different lengths - and the walk below, which reads one line from each in
# lockstep, would then stop early and never compare the trailing facts.
# grep -c . is still the right tool for the >= 30 sanity floor, which is a
# statement about how many FACTS were emitted.
c_lines="$(wc -l < "${abi}/abi_c.txt" | tr -d '[:space:]')"
p_lines="$(wc -l < "${abi}/abi_pascal.txt" | tr -d '[:space:]')"
c_facts="$(grep -c . "${abi}/abi_c.txt" || true)"
p_facts="$(grep -c . "${abi}/abi_pascal.txt" || true)"
[ "${c_facts}" -ge 30 ] ||
    die "core C probe emitted only ${c_facts} facts -- expected >= 30"
[ "${c_lines}" = "${p_lines}" ] ||
    die "core ABI probe mismatch: ${c_lines} vs ${p_lines} lines (${c_facts} vs ${p_facts} facts)"
[ "${c_facts}" = "${p_facts}" ] ||
    die "core ABI probe mismatch: ${c_facts} vs ${p_facts} facts"

# Order-sensitive, line by line. Only the two documented signedness lines may
# differ, and only with exactly the documented values. `allowed -eq 2` and not
# `<= 2`, so a VANISHED delta blocks too: that would mean an enum changed
# shape, which is exactly as interesting as a new delta.
allowed=0
blocking=0
line_no=0
while IFS= read -r c_line && IFS= read -r p_line <&3; do
    line_no=$((line_no + 1))
    [ "${c_line}" = "${p_line}" ] && continue
    if { [ "${c_line}" = 'signed.webview_hint_t=0' ] &&
         [ "${p_line}" = 'signed.webview_hint_t=1' ]; } ||
       { [ "${c_line}" = 'signed.webview_native_handle_kind_t=0' ] &&
         [ "${p_line}" = 'signed.webview_native_handle_kind_t=1' ]; }; then
        allowed=$((allowed + 1))
        printf '[CAP-7M0] documented signedness delta line %d: C=%s Pascal=%s\n' \
            "${line_no}" "${c_line}" "${p_line}"
        continue
    fi
    printf '[CAP-7M0] MISMATCH line %d: C=%s Pascal=%s\n' \
        "${line_no}" "${c_line}" "${p_line}" >&2
    blocking=$((blocking + 1))
done < "${abi}/abi_c.txt" 3< "${abi}/abi_pascal.txt"

[ "${blocking}" -eq 0 ] || die "core ABI probe mismatch: ${blocking} undocumented line(s)"
[ "${allowed}" -eq 2 ] ||
    die "expected exactly 2 documented signedness deltas, saw ${allowed} (an enum changed shape)"
printf '[CAP-7M0] core ABI: %s facts, 2 documented deltas, 0 blocking (%s)\n' \
    "${c_facts}" "${host_arch}"

# MEASURED, and recorded rather than assumed: what the Pascal probe actually
# asked the loader for. On Linux this is DT_NEEDED = the SONAME; here it is
# LC_LOAD_DYLIB = the install name, which is why the versioned file - not the
# bare one the compiler was pointed at - is what a bundle ships.
loaded="$(otool -L "${abi}/bin/abi_probe" |
    awk '/libwebview/ { print $1; exit }')"
[ -n "${loaded}" ] ||
    die 'the Pascal probe records no libwebview load command at all'
printf '[CAP-7M0] MEASURED LC_LOAD_DYLIB: %s\n' "${loaded}"
case "${loaded}" in
    *"${dylib_versioned}") ;;
    *) die "expected the load command to name ${dylib_versioned}, got ${loaded}" ;;
esac

# --- 2. Mach-O presence gate --------------------------------------------------

step 'Mach-O presence gate over the generated binding'
unit="${repo_root}/src/lib/pweb.lib.webview.pas"
[ -f "${unit}" ] || die "binding unit missing: ${unit}"

# `external LIB_WEBVIEW name _PU + 'webview_create';` - flatten first, the
# declarations wrap across lines.
decls="$(tr '\n' ' ' < "${unit}" |
    grep -oE "external[[:space:]]+LIB_WEBVIEW[[:space:]]+name[[:space:]]+_PU[[:space:]]*\+[[:space:]]*'[A-Za-z0-9_]+'" |
    sed -E "s/.*'([A-Za-z0-9_]+)'/\1/" |
    LC_ALL=C sort -u)"
declared_count="$(printf '%s\n' "${decls}" | grep -c . || true)"
[ "${declared_count}" -eq 17 ] ||
    die "expected 17 externals in the binding, parsed ${declared_count}"

nm -gU "${dist}/${dylib_versioned}" | awk 'NF > 1 { print $NF }' |
    LC_ALL=C sort -u > "${abi}/exports.txt"

missing=0
while IFS= read -r symbol; do
    [ -n "${symbol}" ] || continue
    if grep -Fxq "_${symbol}" "${abi}/exports.txt"; then
        printf '[CAP-7M0] symbol OK %-32s -> _%s\n' "${symbol}" "${symbol}"
    else
        printf '[CAP-7M0] MISSING SYMBOL _%s in %s\n' "${symbol}" "${dylib_versioned}" >&2
        missing=$((missing + 1))
    fi
done <<< "${decls}"
[ "${missing}" -eq 0 ] ||
    die "${missing} declared symbol(s) are absent from the dylib"
printf '[CAP-7M0] presence gate PASS - %s declared symbols exist under the underscore convention\n' \
    "${declared_count}"

# --- 3. dlopen/dlsym gate -----------------------------------------------------

step 'dynamic resolution gate (dlopen + dlsym, the loader itself)'
# Generated from the SAME parsed list, so it can never drift from the binding.
{
    printf '/* generated by test/cap7m/check_abi.sh -- do not commit */\n'
    printf '#include <dlfcn.h>\n#include <stdio.h>\n\n'
    printf 'static const char *const kNames[] = {\n'
    while IFS= read -r symbol; do
        [ -n "${symbol}" ] || continue
        printf '    "%s",\n' "${symbol}"
    done <<< "${decls}"
    printf '};\n\n'
    printf 'int main(int argc, char **argv) {\n'
    printf '  void *h;\n  unsigned i, bad = 0;\n'
    printf '  if (argc != 2) { fprintf(stderr, "usage: dlprobe <dylib>\\n"); return 2; }\n'
    printf '  h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);\n'
    printf '  if (!h) { fprintf(stderr, "dlopen failed: %%s\\n", dlerror()); return 1; }\n'
    printf '  for (i = 0; i < sizeof(kNames) / sizeof(kNames[0]); ++i) {\n'
    printf '    /* dlsym takes the C name WITHOUT the underscore: the loader\n'
    printf '       applies the Mach-O convention itself, exactly as FPC does */\n'
    printf '    if (!dlsym(h, kNames[i])) {\n'
    printf '      fprintf(stderr, "dlsym failed: %%s\\n", kNames[i]);\n'
    printf '      ++bad;\n    }\n  }\n'
    printf '  dlclose(h);\n'
    printf '  printf("CAP7M_DLSYM resolved=%%u failed=%%u\\n",\n'
    printf '         (unsigned)(sizeof(kNames) / sizeof(kNames[0])) - bad, bad);\n'
    printf '  return bad ? 1 : 0;\n}\n'
} > "${abi}/dlprobe.c"

clang -O1 -Wall -Wextra -Werror \
    -arch "${host_arch}" "-mmacosx-version-min=${deployment_target}" \
    "${abi}/dlprobe.c" -o "${abi}/bin/dlprobe" ||
    die 'dlopen probe failed to compile'
"${abi}/bin/dlprobe" "${dist}/${dylib_versioned}" ||
    die 'the dynamic loader could not resolve every declared symbol'

printf '\n[CAP-7M0] check_abi: PASS (%s)\n' "${host_arch}"
