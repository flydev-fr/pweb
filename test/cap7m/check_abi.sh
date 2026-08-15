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
# Usage: test/cap7m/check_abi.sh [--clean]
#        --clean is OPT-IN; without it a stale work directory is a refusal.
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

eval "$(cap7m_take_clean_flag "$@")"

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

cap7m_prepare_dir "${abi}"
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

# MEASURED, run 31905105454, and RECORDED rather than asserted - because the
# Linux property this used to assert does not exist on Darwin.
#
# CAP-7L could measure DT_NEEDED = libwebview.so.0.12 straight off abi_probe,
# because ELF's ld records DT_NEEDED for any library named on the command
# line whether or not a symbol from it is used. Mach-O's linker does not: it
# records an LC_LOAD_DYLIB only when a symbol from that dylib is actually
# referenced - ELF's --as-needed behaviour, unconditionally and with no
# opt-out by default.
#
# test/core/abi_probe.pas references NOTHING. It declares the externals,
# assigns its OWN cdecl procedures to the typed callback consts, and measures
# sizes, offsets and signedness. So the absence of a load command here is
# correct, expected, and the direct Darwin counterpart of CAP-7L's DT_NEEDED
# finding - not a defect to assert away.
#
# The load command IS asserted, in test/cap7m/build_cap7m.sh, on the binary
# that genuinely calls into the dylib. Neither abi_probe.pas nor abi_probe.c is
# modified to reference a symbol: that pair is the single pinned CAP-1 probe,
# unmodified on every platform, and making it call in to satisfy a gate would
# change what it measures. Nor is the dependency manufactured with
# -needed_library, which would fabricate the measurement instead of taking it.
abi_loaded="$(otool -L "${abi}/bin/abi_probe" |
    awk '/libwebview/ { print $1; exit }')"
if [ -n "${abi_loaded}" ]; then
    record_measurement "CAP7M_M5 binary=abi_probe references_dylib=yes load=${abi_loaded}"
    case "${abi_loaded}" in
        *"${dylib_versioned}") ;;
        *) die "abi_probe loads '${abi_loaded}', expected a path ending ${dylib_versioned}" ;;
    esac
else
    record_measurement "CAP7M_M5 binary=abi_probe references_dylib=no load=<none> note=mach-o-records-LC_LOAD_DYLIB-only-when-a-symbol-is-referenced (ELF records DT_NEEDED unconditionally: CAP-7L measured libwebview.so.0.12 from this same probe)"
fi

# --- 1b. fcntl constants: the folder store's hand-declared Darwin block ------
#
# MEASURED, run 31908958453: FPC 3.2.2's Darwin BaseUnix declares neither
# O_DIRECTORY nor O_NOFOLLOW, although its Linux BaseUnix declares both, so
# the POSIX branch CAP-7L hardened does not compile on Darwin. Both are
# security code (a file passed as the asset root; a symlink swapped in
# between the walk and the open), so the branch was not weakened - the
# constants are declared in the unit's interface and verified HERE.
#
# ZERO permitted delta, unlike the core probe pair above. There is no
# legitimate difference between what <fcntl.h> defines and what the unit
# declares, and the failure mode is asymmetric: a wrong O_DIRECTORY stops the
# store constructing, but a wrong O_NOFOLLOW just silently stops refusing
# symlinks while every other test still passes.
step 'fcntl constant probe (declared block vs the SDK, zero deltas allowed)'
# No -std=…: a strict-ISO mode sets __STRICT_ANSI__, which lowers
# __DARWIN_C_LEVEL and can hide O_NOFOLLOW behind its _DARWIN_C_SOURCE guard.
clang -O1 -Wall -Wextra -Werror \
    -arch "${host_arch}" "-mmacosx-version-min=${deployment_target}" \
    "${repo_root}/test/cap7m/abi_probe_fcntl.c" -o "${abi}/bin/abi_probe_fcntl_c" ||
    die 'fcntl C probe failed to compile'
"${abi}/bin/abi_probe_fcntl_c" > "${abi}/fcntl_c.txt" ||
    die 'fcntl C probe exited nonzero'

# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FU"${abi}/units" -FE"${abi}/bin" \
    -Fu"${repo_root}/src/assets" \
    -Fi"${repo_root}/deps/mormot2/src" \
    -Fu"${repo_root}/deps/mormot2/src/core" \
    -Fu"${repo_root}/deps/mormot2/src/lib" \
    "-WM${deployment_target}" ${CAP7M_FPC_ARCH_LINK_FLAGS} \
    "${repo_root}/test/cap7m/abi_probe_fcntl.pas" > "${abi}/fcntl_pascal.log" 2>&1 ||
    { cat "${abi}/fcntl_pascal.log" >&2; die 'fcntl Pascal probe failed to compile'; }
"${abi}/bin/abi_probe_fcntl" > "${abi}/fcntl_pas.txt" ||
    die 'fcntl Pascal probe exited nonzero'

fcntl_facts="$(grep -c . "${abi}/fcntl_c.txt" || true)"
[ "${fcntl_facts}" -eq 3 ] ||
    die "fcntl C probe emitted ${fcntl_facts} facts, expected 3"
if ! diff -u "${abi}/fcntl_c.txt" "${abi}/fcntl_pas.txt" > "${abi}/fcntl.diff"; then
    cat "${abi}/fcntl.diff" >&2
    die 'the folder store declares an fcntl value the SDK does not -- O_NOFOLLOW drift silently disables the symlink refusal'
fi
while IFS= read -r line; do
    [ -n "${line}" ] && record_measurement "CAP7M_FCNTL ${line}"
done < "${abi}/fcntl_c.txt"
printf '[CAP-7M0] fcntl constants: %s facts identical, 0 deltas\n' "${fcntl_facts}"

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

# --- 3. dlopen/dlsym gate: THIS is what satisfies M5 --------------------------
#
# M5 asks that "all 17 externals resolve through the Mach-O underscore
# convention". A load command cannot show that and never could: it says a
# library is needed, not that a name resolves. dlopen + dlsym does show it,
# and shows it at RUN time through the exact mangling FPC's `external` uses.
#
# The convention is asserted from BOTH sides, because asserting it from one
# is how it ends up proven incidentally:
#   - the bare C name MUST resolve       ("webview_create")
#   - the trie's own spelling MUST NOT   ("_webview_create" -> dlsym looks up
#     __webview_create, which does not exist)
# The second is recorded rather than gated, so a future dyld that added a
# fallback would be reported as the finding it is instead of blocking a shard
# on a triviality.
step 'M5: dynamic resolution gate (dlopen + dlsym, the loader itself)'
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
    printf '  void *h;\n  unsigned i, bad = 0, underscored = 0;\n'
    printf '  char prefixed[256];\n'
    printf '  if (argc != 2) { fprintf(stderr, "usage: dlprobe <dylib>\\n"); return 2; }\n'
    printf '  h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);\n'
    printf '  if (!h) { fprintf(stderr, "dlopen failed: %%s\\n", dlerror()); return 1; }\n'
    printf '  for (i = 0; i < sizeof(kNames) / sizeof(kNames[0]); ++i) {\n'
    printf '    /* THE CONVENTION, asserted: dlsym takes the C name WITHOUT the\n'
    printf '       leading underscore even though the export trie stores\n'
    printf '       _webview_create. The loader applies the Mach-O prefix\n'
    printf '       itself - which is exactly what FPC does for `external name`,\n'
    printf '       and why the generated binding keeps _PU empty. */\n'
    printf '    if (!dlsym(h, kNames[i])) {\n'
    printf '      fprintf(stderr, "dlsym failed for the bare name: %%s\\n", kNames[i]);\n'
    printf '      ++bad;\n    }\n'
    printf '    /* the contrast, recorded: the trie spelling must NOT resolve */\n'
    printf '    snprintf(prefixed, sizeof(prefixed), "_%%s", kNames[i]);\n'
    printf '    if (dlsym(h, prefixed)) { ++underscored; }\n'
    printf '  }\n'
    printf '  dlclose(h);\n'
    printf '  printf("CAP7M_M5 dlsym_bare_resolved=%%u dlsym_bare_failed=%%u "\n'
    printf '         "dlsym_underscored_resolved=%%u convention=%%s\\n",\n'
    printf '         (unsigned)(sizeof(kNames) / sizeof(kNames[0])) - bad, bad,\n'
    printf '         underscored,\n'
    printf '         (bad == 0 && underscored == 0) ? "bare-name-only-as-expected"\n'
    printf '                                        : "UNEXPECTED");\n'
    printf '  return bad ? 1 : 0;\n}\n'
} > "${abi}/dlprobe.c"

clang -O1 -Wall -Wextra -Werror \
    -arch "${host_arch}" "-mmacosx-version-min=${deployment_target}" \
    "${abi}/dlprobe.c" -o "${abi}/bin/dlprobe" ||
    die 'dlopen probe failed to compile'
dlresult="$("${abi}/bin/dlprobe" "${dist}/${dylib_versioned}")" ||
    { printf '%s\n' "${dlresult}" >&2
      die 'the dynamic loader could not resolve every declared symbol by its bare C name'; }
record_measurement "${dlresult}"
case "${dlresult}" in
    *dlsym_underscored_resolved=0*) ;;
    *) printf '[CAP-7M0] RECORDED SURPRISE: the trie spelling also resolved through dlsym\n' ;;
esac

printf '\n[CAP-7M0] check_abi: PASS (%s)\n' "${host_arch}"
