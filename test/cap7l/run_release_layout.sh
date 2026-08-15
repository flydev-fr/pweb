#!/usr/bin/env bash
#
# CAP-7L L16-L19 and L23: the Linux release layout, proven from an
# isolated directory with the CWD somewhere else entirely.
#
#   dist/linux-x64/release/
#     releaseapp            -rpath=$ORIGIN, no CWD dependence
#     app.pwb               resolved from Executable.ProgramFilePath
#     libwebview.so.0.12    the DT_NEEDED name (MEASURED)
#     LICENSE.webview
#
# Nothing else: no frontend/dist, no node_modules, no compiler artifacts,
# no WebKit files. The layout is asserted to contain EXACTLY those four
# entries, because "smallest possible" is a claim that rots silently.
#
# L16/L17 run the SAME executable twice, over an app.pwb built from the
# React dist and then from the Pas2JS dist. One backend binary, two real
# frontends, both reaching CalculatorService.Add(20,42) -> 42: that is
# what "no per-frontend workaround" means.
#
# L23 then hides the shared object and requires a deterministic, NAMED
# loader failure - the Linux equivalent of a missing webview.dll.
#
# Run it under a virtual display:
#   xvfb-run -a test/cap7l/run_release_layout.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7L] === %s\n' "$*"; }

release="${repo_root}/dist/linux-x64/release"
dist="${repo_root}/build/cap7l/webview-dist"
bin="${repo_root}/build/cap7l/bin"
logs="${repo_root}/build/cap7l/release"

[ -x "${repo_root}/build/cap7l/ex/releaseapp" ] ||
    die 'releaseapp missing -- run test/cap7l/build_cap7l.sh'
[ -x "${bin}/pwebbundle" ] || die 'pwebbundle missing -- run test/cap7l/build_cap7l.sh'
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'

export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export PWEB_SMOKE_AUTOCLOSE_MS=8000

mkdir -p -- "${logs}"
rm -rf -- "${release}"
mkdir -p -- "${release}"

cp -f -- "${repo_root}/build/cap7l/ex/releaseapp" "${release}/"
cp -f -- "${dist}/libwebview.so.0.12" "${release}/"
cp -f -- "${dist}/LICENSE.webview" "${release}/"

# --- the layout is exactly four files -----------------------------------------
assert_layout() {
    local listing
    listing="$(cd -- "${release}" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
    local expected='LICENSE.webview app.pwb libwebview.so.0.12 releaseapp '
    [ "${listing}" = "${expected}" ] ||
        die "release layout is not minimal: got [${listing}] expected [${expected}]"
}

# --- L18/L19 + L16/L17 --------------------------------------------------------
# CWD deliberately somewhere with no relationship to the layout: app.pwb
# must be found from Executable.ProgramFilePath and the shared object from
# RUNPATH=$ORIGIN, never from the working directory.
run_release_case() {
    local name="$1" frontend="$2" log="${logs}/release-${1}.log"

    step "release layout, ${name} frontend (L16-L19)"
    [ -f "${frontend}/index.html" ] ||
        die "${name} frontend dist missing: ${frontend}"
    "${bin}/pwebbundle" "${frontend}" "${release}/app.pwb" > "${log}" 2>&1 ||
        { cat "${log}" >&2; die "${name}: app.pwb build failed"; }
    assert_layout

    local cwd='/'
    # env -u strips LD_LIBRARY_PATH outright: the layout must resolve its
    # own library through RUNPATH alone, never through an inherited hint
    ( cd "${cwd}" && env -u LD_LIBRARY_PATH "${release}/releaseapp" ) \
        >> "${log}" 2>&1 ||
        { cat "${log}" >&2; die "${name}: releaseapp exited nonzero"; }
    tail -n 4 "${log}"
    grep -q 'app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS' "${log}" ||
        die "${name}: missing the release PASS marker"
    grep -q '"value":42' "${log}" ||
        die "${name}: the page never reported 42"
    printf '[CAP-7L] %s: 42 from CWD=%s with no LD_LIBRARY_PATH\n' "${name}" "${cwd}"
}

run_release_case react "${repo_root}/examples/04-react/frontend/dist"
run_release_case pas2js "${repo_root}/examples/05-pas2js/frontend/dist"

# --- L23: the missing shared object is a NAMED loader failure ----------------
step 'L23: libwebview.so.0.12 absent -> deterministic named failure'
mv -f -- "${release}/libwebview.so.0.12" "${logs}/libwebview.hidden"
set +e
( cd / && env -u LD_LIBRARY_PATH "${release}/releaseapp" ) \
    > "${logs}/missing-so.log" 2>&1
missing_code=$?
set -e
mv -f -- "${logs}/libwebview.hidden" "${release}/libwebview.so.0.12"
cat "${logs}/missing-so.log"
[ "${missing_code}" -eq 127 ] ||
    die "expected loader exit 127 for the missing library, got ${missing_code}"
grep -q 'libwebview.so.0.12' "${logs}/missing-so.log" ||
    die 'the loader failure did not name the missing soname'
printf '[CAP-7L] missing library: exit 127 naming libwebview.so.0.12\n'

# restore a valid layout so the directory is left in the shipping shape
assert_layout
printf '\n[CAP-7L] run_release_layout: PASS\n'
