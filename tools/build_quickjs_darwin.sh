#!/bin/sh
# CAP-9A: deterministic macOS build of the PINNED QuickJS static object.
#
# The sha256-pinned mormot2static release carries quickjs.o only for
# x86_64-win64 and x86_64-linux; the pinned mORMot tree itself is the
# source authority for both macOS targets (res/static/libquickjs, the
# quickjspp fork, QUICKJS_VERSION 2021-03-27). This script:
#   1. refuses to run unless deps/mormot2 sits exactly on the commit
#      pinned in mormot.lock (no silent source substitution - STOP);
#   2. rebuilds the same amalgamation the upstream compile-all.sh does
#      (cat cutils.h cutils.c libbf.c libregexp.c libunicode.c quickjs.c;
#      quickjs-libc deliberately excluded);
#   3. records the amalgamation sha256 and the exact clang version;
#   4. compiles with the pinned static-build defines
#      (-DCONFIG_BIGNUM -DJS_STRICT_NAN_BOXING -DCONFIG_JSX
#       -DCONFIG_DEBUGGER) for the HOST architecture;
#   5. verifies the output architecture (lipo -info);
#   6. audits the defined symbols: any js_std_* / js_os_* export means
#      quickjs-libc leaked into the object - refuse.
#
# Usage: tools/build_quickjs_darwin.sh <output-dir>
# Writes <output-dir>/quickjs.o and <output-dir>/quickjs-build-info.txt.

set -eu

out_dir="${1:?usage: build_quickjs_darwin.sh <output-dir>}"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "build_quickjs_darwin: this script only runs on macOS" >&2; exit 1 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${root}/deps/mormot2/res/static/libquickjs"
lock="${root}/mormot.lock"

# 1. the pin gate: repository evidence, not trust
pinned_commit="$(sed -n 's/^commit = //p' "${lock}" | head -n 1)"
actual_commit="$(git -C "${root}/deps/mormot2" rev-parse HEAD)"
if [ -z "${pinned_commit}" ] || [ "${pinned_commit}" != "${actual_commit}" ]; then
  echo "build_quickjs_darwin: deps/mormot2 HEAD ${actual_commit} does not match the mormot.lock pin ${pinned_commit} - STOP" >&2
  exit 1
fi
# HEAD equality is not enough: a locally edited pinned source file would
# still pass it. The QuickJS source subtree must be byte-identical to the
# pin - tracked changes AND untracked additions both refuse.
if ! git -C "${root}/deps/mormot2" diff --exit-code --quiet HEAD -- res/static/libquickjs; then
  echo "build_quickjs_darwin: deps/mormot2 res/static/libquickjs differs from the pinned commit - silent source substitution refused, STOP" >&2
  exit 1
fi
untracked="$(git -C "${root}/deps/mormot2" ls-files --others --exclude-standard -- res/static/libquickjs)"
if [ -n "${untracked}" ]; then
  echo "build_quickjs_darwin: untracked files under res/static/libquickjs - silent source substitution refused, STOP:" >&2
  echo "${untracked}" >&2
  exit 1
fi

arch="$(uname -m)"          # arm64 or x86_64 (native runner per CI job)
mkdir -p "${out_dir}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# 2. the exact upstream amalgamation recipe (compile-all.sh), from the
#    pinned tree only; quickjs-libc is excluded by design
for f in cutils.h cutils.c libbf.c libregexp.c libunicode.c quickjs.c; do
  [ -f "${src}/${f}" ] || { echo "build_quickjs_darwin: pinned source ${f} missing - STOP" >&2; exit 1; }
done
cat "${src}/cutils.h" "${src}/cutils.c" "${src}/libbf.c" \
    "${src}/libregexp.c" "${src}/libunicode.c" "${src}/quickjs.c" \
    > "${work}/quickjs2.c"

# 3. determinism record
src_sha="$(shasum -a 256 "${work}/quickjs2.c" | cut -d ' ' -f 1)"
clang_version="$(clang --version | head -n 1)"

# 4. pinned static-build defines; conservative codegen flags for Darwin
#    (no -fomit-frame-pointer: frame pointers are part of the arm64
#    Darwin ABI; unwind tables stay, Pascal exceptions cross pas_assert)
clang -c -w -O2 -std=c99 -fno-stack-protector \
  -arch "${arch}" \
  -I"${src}" \
  -DCONFIG_BIGNUM -DJS_STRICT_NAN_BOXING -DCONFIG_JSX -DCONFIG_DEBUGGER \
  -o "${out_dir}/quickjs.o" "${work}/quickjs2.c"

# 5. architecture check
lipo_info="$(lipo -info "${out_dir}/quickjs.o")"
case "${lipo_info}" in
  *"${arch}"*) ;;
  *) echo "build_quickjs_darwin: unexpected architecture: ${lipo_info}" >&2; exit 1 ;;
esac

# 6. export audit: the object must not define any quickjs-libc surface.
# nm output is captured with an explicit failure check first - a failed nm
# feeding an empty pipe into grep would otherwise pass the audit silently.
syms="$(nm -gU "${out_dir}/quickjs.o")" || {
  echo "build_quickjs_darwin: nm failed on the produced object - audit impossible, refuse" >&2
  exit 1
}
if [ -z "${syms}" ]; then
  echo "build_quickjs_darwin: nm enumerated no defined symbols - not a credible QuickJS object, refuse" >&2
  exit 1
fi
if printf '%s\n' "${syms}" | grep -E ' _js_(std|os)_' > /dev/null; then
  echo "build_quickjs_darwin: quickjs-libc symbols found in the object - refuse" >&2
  exit 1
fi

{
  echo "schema=1"
  echo "source=deps/mormot2/res/static/libquickjs (pinned quickjspp, QUICKJS_VERSION 2021-03-27)"
  echo "mormot_commit=${actual_commit}"
  echo "amalgamation_sha256=${src_sha}"
  echo "clang=${clang_version}"
  echo "arch=${arch}"
  echo "defines=CONFIG_BIGNUM JS_STRICT_NAN_BOXING CONFIG_JSX CONFIG_DEBUGGER"
  echo "quickjs_libc=excluded"
} > "${out_dir}/quickjs-build-info.txt"

echo "build_quickjs_darwin: OK ${out_dir}/quickjs.o (${arch}, sha256 ${src_sha})"
