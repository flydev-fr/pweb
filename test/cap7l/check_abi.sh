#!/usr/bin/env bash
#
# CAP-7L gate L3: the Pascal side and the C side agree, on both binding
# surfaces, and every hand-declared symbol really exists.
#
# Three parts, all blocking:
#
#   1. The CORE paired probe (test/core/abi_probe.c / abi_probe.pas), the
#      same 36 facts CI compares on Windows - except that exactly TWO lines
#      are permitted to differ here, with exactly the documented values:
#
#         signed.webview_hint_t                 C=0  Pascal=1
#         signed.webview_native_handle_kind_t   C=0  Pascal=1
#
#      MSVC types every C enum as signed int; gcc picks unsigned when no
#      enumerator is negative, and both of these enums are 0..3. Width is
#      4 bytes on both sides and every transported value is non-negative,
#      so the calling convention is untouched. webview_error_t has a
#      negative enumerator and is therefore signed on both. Any OTHER
#      difference, and any difference in the VALUES of these two lines,
#      blocks.
#
#   2. The GTK/GLib paired probe (test/cap7l/abi_probe_gtk.c / .pas) over
#      the hand-declared WebKitGTK/GLib externals. NO delta is permitted
#      there: those declarations are ours, not an upstream's.
#
#   3. The presence gate: every symbol the Linux platform unit declares
#      must be exported by the exact distro .so it is declared against,
#      proven with nm -D. A typo would otherwise only surface as a loader
#      failure on a user's machine.
#
# Parts 2 and 3 are the two conditions attached to the CAP-7L checkpoint-1
# ratification of hand-written private externals.
#
# Usage: test/cap7l/check_abi.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
work="${repo_root}/build/cap7l/abi"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }

for tool in cc fpc nm pkg-config; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
[ -f "${repo_root}/deps/webview/core/include/webview/api.h" ] ||
    die 'pinned headers missing -- fetch deps/webview first'

# The Pascal probe calls no external function, but FPC still records the
# library dependency from the `external` declarations, so the shared object
# is needed to LINK (-Fl) and to LOAD (DT_NEEDED = the SONAME). This is the
# same fact the release layout is built on, so prove it the same way: link
# against the staged dev name and run with the SONAME beside the binary.
dist="${repo_root}/build/cap7l/webview-dist"
[ -f "${dist}/libwebview.so" ] ||
    die "staged webview library missing -- run tools/build-webview-so.sh first (${dist})"

rm -rf -- "${work}"
mkdir -p -- "${work}/units" "${work}/bin"
cp -f -- "${dist}/libwebview.so.0.12" "${work}/bin/"

# --- 1. core paired probe -----------------------------------------------------

# -Wno-type-limits, and ONLY here: test/core/abi_probe.c measures signedness
# with ((type)-1 < 0), and for an enum gcc makes unsigned that comparison is
# provably false - which is the FACT being measured, not a defect. MSVC's
# /W4 has no equivalent diagnostic, so the file is unchanged and stays the
# single pinned CAP-1 probe on both platforms. Every other warning still
# blocks.
cc -O1 -Wall -Wextra -Werror -Wno-type-limits \
    -I"${repo_root}/deps/webview/core/include" \
    "${repo_root}/test/core/abi_probe.c" -o "${work}/bin/abi_probe_c" ||
    die 'core C ABI probe failed to compile'
"${work}/bin/abi_probe_c" > "${work}/abi_c.txt" ||
    die 'core C ABI probe exited nonzero'

fpc -Sh -B -FU"${work}/units" -FE"${work}/bin" \
    -Fu"${repo_root}/src/lib" \
    -Fi"${repo_root}/deps/mormot2/src" \
    -Fl"${dist}" -k'-rpath=$ORIGIN' \
    "${repo_root}/test/core/abi_probe.pas" > "${work}/abi_pascal.log" 2>&1 ||
    { cat "${work}/abi_pascal.log" >&2; die 'core Pascal ABI probe failed to compile'; }
"${work}/bin/abi_probe" > "${work}/abi_pascal.txt" ||
    die 'core Pascal ABI probe exited nonzero'

c_facts="$(grep -c . "${work}/abi_c.txt" || true)"
p_facts="$(grep -c . "${work}/abi_pascal.txt" || true)"
[ "${c_facts}" -ge 30 ] ||
    die "core C probe emitted only ${c_facts} facts -- expected >= 30"
[ "${c_facts}" = "${p_facts}" ] ||
    die "core ABI probe mismatch: ${c_facts} vs ${p_facts} lines"

# Order-sensitive, line by line. Only the two documented signedness lines
# may differ, and only with exactly the documented values.
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
        printf '[CAP-7L] documented signedness delta line %d: C=%s Pascal=%s\n' \
            "${line_no}" "${c_line}" "${p_line}"
        continue
    fi
    printf '[CAP-7L] MISMATCH line %d: C=%s Pascal=%s\n' \
        "${line_no}" "${c_line}" "${p_line}" >&2
    blocking=$((blocking + 1))
done < "${work}/abi_c.txt" 3< "${work}/abi_pascal.txt"

[ "${blocking}" -eq 0 ] || die "core ABI probe mismatch: ${blocking} undocumented line(s)"
[ "${allowed}" -eq 2 ] ||
    die "expected exactly 2 documented signedness deltas, saw ${allowed} (an enum changed shape)"
printf '[CAP-7L] core ABI: %s facts, 2 documented deltas, 0 blocking\n' "${c_facts}"

# --- 2. WebKitGTK/GLib paired probe ------------------------------------------

# -Wno-type-limits for the same reason as the core probe above: the
# "always false" comparison on gsize/GQuark IS the unsignedness being
# measured.
# shellcheck disable=SC2046
cc -O1 -Wall -Wextra -Werror -Wno-type-limits $(pkg-config --cflags webkit2gtk-4.1) \
    "${repo_root}/test/cap7l/abi_probe_gtk.c" \
    -o "${work}/bin/abi_probe_gtk_c" $(pkg-config --libs webkit2gtk-4.1) ||
    die 'GTK C ABI probe failed to compile'
"${work}/bin/abi_probe_gtk_c" > "${work}/gtk_c.txt" ||
    die 'GTK C ABI probe exited nonzero'

fpc -MObjFPC -Sh -B -FU"${work}/units" -FE"${work}/bin" \
    -Fu"${repo_root}/src/lib" -Fu"${repo_root}/src/assets" \
    -Fu"${repo_root}/src/platform/linux" \
    -Fi"${repo_root}/deps/mormot2/src" \
    -Fu"${repo_root}/deps/mormot2/src/core" \
    -Fu"${repo_root}/deps/mormot2/src/lib" \
    -Fl"${dist}" -k'-rpath=$ORIGIN' \
    "${repo_root}/test/cap7l/abi_probe_gtk.pas" > "${work}/gtk_pascal.log" 2>&1 ||
    { cat "${work}/gtk_pascal.log" >&2; die 'GTK Pascal ABI probe failed to compile'; }
"${work}/bin/abi_probe_gtk" > "${work}/gtk_pas.txt" ||
    die 'GTK Pascal ABI probe exited nonzero'

gtk_facts="$(grep -c . "${work}/gtk_c.txt" || true)"
[ "${gtk_facts}" -ge 12 ] ||
    die "GTK C probe emitted only ${gtk_facts} facts -- expected >= 12"
if ! diff -u "${work}/gtk_c.txt" "${work}/gtk_pas.txt" > "${work}/gtk.diff"; then
    cat "${work}/gtk.diff" >&2
    die 'GTK/GLib ABI probe mismatch -- no delta is permitted on this pair'
fi
printf '[CAP-7L] GTK/GLib ABI: %s facts identical, 0 deltas\n' "${gtk_facts}"

# --- 3. nm -D presence gate ---------------------------------------------------

unit="${repo_root}/src/platform/linux/pweb.platform.webkitgtk.pas"
[ -f "${unit}" ] || die "Linux platform unit missing: ${unit}"

resolve_so() {
    local soname="$1" found=''
    for ldc in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
        command -v "${ldc}" >/dev/null 2>&1 || [ -x "${ldc}" ] || continue
        found="$("${ldc}" -p 2>/dev/null |
            awk -v s="${soname}" '$1 == s { print $NF; exit }')"
        [ -n "${found}" ] && break
    done
    if [ -z "${found}" ]; then
        for dir in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib /lib; do
            if [ -e "${dir}/${soname}" ]; then
                found="${dir}/${soname}"
                break
            fi
        done
    fi
    printf '%s' "${found}"
}

# The library-name constants, e.g.  WEBKITGTK_LIB = 'libwebkit2gtk-4.1.so.0';
lib_names="$(sed -nE \
    "s/^[[:space:]]*([A-Z0-9_]+_LIB)[[:space:]]*=[[:space:]]*'([^']+)'[[:space:]]*;.*$/\1 \2/p" \
    "${unit}")"
[ -n "${lib_names}" ] || die 'no *_LIB soname constants found in the platform unit'

# The externals themselves. Declarations wrap across lines, so flatten first.
decls="$(tr '\n' ' ' < "${unit}" |
    grep -oE "external[[:space:]]+[A-Z0-9_]+_LIB[[:space:]]+name[[:space:]]+'[A-Za-z0-9_]+'" |
    sed -E "s/external[[:space:]]+([A-Z0-9_]+_LIB)[[:space:]]+name[[:space:]]+'([A-Za-z0-9_]+)'/\1 \2/" |
    LC_ALL=C sort -u)"
[ -n "${decls}" ] || die 'no hand-declared externals found in the platform unit'

declared_count="$(printf '%s\n' "${decls}" | grep -c . || true)"
missing=0
while read -r lib_const symbol; do
    [ -n "${lib_const}" ] || continue
    soname="$(printf '%s\n' "${lib_names}" |
        awk -v k="${lib_const}" '$1 == k { print $2; exit }')"
    [ -n "${soname}" ] || die "no soname constant named ${lib_const}"
    so_path="$(resolve_so "${soname}")"
    [ -n "${so_path}" ] || die "declared library not installed: ${soname}"
    cache="${work}/syms.$(printf '%s' "${soname}" | tr -c 'A-Za-z0-9._-' '_')"
    if [ ! -f "${cache}" ]; then
        nm -D --defined-only --format=posix "${so_path}" |
            awk 'NF > 0 { print $1 }' | LC_ALL=C sort -u > "${cache}"
    fi
    if grep -Fxq "${symbol}" "${cache}"; then
        printf '[CAP-7L] symbol OK %-52s %s\n' "${symbol}" "${soname}"
    else
        printf '[CAP-7L] MISSING SYMBOL %s in %s (%s)\n' \
            "${symbol}" "${soname}" "${so_path}" >&2
        missing=$((missing + 1))
    fi
done <<< "${decls}"

[ "${missing}" -eq 0 ] ||
    die "${missing} hand-declared symbol(s) are absent from their library"

printf '[CAP-7L] presence gate PASS - %s declared symbols exist in their distro .so\n' \
    "${declared_count}"
printf '[CAP-7L] check_abi: PASS\n'
