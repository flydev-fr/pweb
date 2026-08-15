#!/usr/bin/env bash
#
# CAP-7L GUI matrix (L4-L22): a real GTK/WebKitGTK WebView, on a real
# display, serving real assets over pweb://app.
#
# There is NO conditional SKIP here, and that is deliberate. The Windows
# job tolerates an absent WebView2/desktop session because a hosted
# runner may genuinely lack one; the Linux job always runs under
# xvfb-run, so a display is a PRECONDITION rather than a possibility.
# Every failure gates. Nothing below is mocked, and no verdict is ever
# inferred from "it rendered" - each page STATES its facts through the
# same SDK the product uses.
#
# Run it under a virtual display:
#   xvfb-run -a test/cap7l/run_gui_matrix.sh
#
# Prerequisites: test/cap7l/build_cap7l.sh and test/cap7l/run_cap7l_gates.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7L] === %s\n' "$*"; }

bin='build/cap7l/bin'
ex='build/cap7l/ex'
logs='build/cap7l/gui'
mkdir -p -- "${logs}"

[ -x "${bin}/cap7l_probe" ] || die 'cap7l_probe missing -- run test/cap7l/build_cap7l.sh'
[ -x "${ex}/assetsapp" ] || die 'assetsapp missing -- run test/cap7l/build_cap7l.sh'
[ -f 'build/cap7l/app.zip' ] || die 'app.zip missing -- run test/cap7l/run_cap7l_gates.sh'
[ -x "${ex}/releaseapp" ] || die 'releaseapp missing -- run test/cap7l/build_cap7l.sh'
[ -f 'build/cap7l/app.pwb' ] || die 'app.pwb missing -- run test/cap7l/run_cap7l_gates.sh'

# A display is required, not optional. Without this check a headless
# invocation would collapse every case into "webview_create returned nil"
# and look like an environment problem rather than a gate that never ran.
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'
printf '[CAP-7L] display: DISPLAY=%s WAYLAND_DISPLAY=%s\n' \
    "${DISPLAY}" "${WAYLAND_DISPLAY:-<unset>}"

# The hosted-runner condition, matched deliberately: no GPU, no compositor.
# WebKitGTK otherwise tries a DMA-BUF/accelerated path that has no backing
# on Xvfb and dies in the web process, which would look like a PWeb defect.
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1

failures=0
note_failure() {
    printf '[CAP-7L] FAIL %s\n' "$*" >&2
    failures=$((failures + 1))
}

# --- L4-L8, L11, L13, L21, L22: the reference C probe -------------------------
step 'reference C seam probe, 3 cycles (L4-L8, L11, L13, L21, L22)'
if "${bin}/cap7l_probe" 3 > "${logs}/probe.log" 2>&1; then
    grep -E 'CAP7L_REPORT|CAP7L_CYCLE_PASS|CAP7L_RENDERED_PASS' "${logs}/probe.log" || true
    grep -q 'CAP7L_RENDERED_PASS cycles=3' "${logs}/probe.log" ||
        note_failure 'C probe did not report the three-cycle pass marker'
else
    cat "${logs}/probe.log" >&2
    note_failure 'C seam probe exited nonzero'
fi

# --- L9, L10, L12, L14, L15: the dual-mode asset example ----------------------
# The SAME real frontend over BOTH stores; identical bytes and content
# types from a folder tree and from a ZIP archive is the parity claim.
export PWEB_SMOKE_AUTOCLOSE_MS=8000
run_assetsapp() {
    local mode="$1" target="$2" log="${logs}/assetsapp-${1}.log"
    step "assetsapp ${mode} mode over pweb://app (L9/L10/L12/L14/L15)"
    if "${ex}/assetsapp" "${mode}" "${target}" > "${log}" 2>&1; then
        tail -n 5 "${log}"
        grep -q 'via IAssetStore PASS' "${log}" ||
            note_failure "assetsapp ${mode}: missing the CAP-4 PASS marker"
    else
        cat "${log}" >&2
        note_failure "assetsapp ${mode} exited nonzero"
    fi
}
run_assetsapp folder examples/06-assets/frontend/dist
run_assetsapp zip build/cap7l/app.zip

# --- the release host over app.pwb -------------------------------------------
# L16-L19 are proven from an ISOLATED directory with the CWD elsewhere by
# test/cap7l/run_release_layout.sh; this is the in-tree sanity run.
step 'releaseapp over app.pwb, in-tree'
rm -rf -- build/cap7l/gui-release
mkdir -p -- build/cap7l/gui-release
cp -f -- "${ex}/releaseapp" build/cap7l/gui-release/
cp -f -- build/cap7l/app.pwb build/cap7l/gui-release/
cp -f -- build/cap7l/webview-dist/libwebview.so.0.12 build/cap7l/gui-release/
if build/cap7l/gui-release/releaseapp > "${logs}/releaseapp.log" 2>&1; then
    tail -n 5 "${logs}/releaseapp.log"
    grep -q 'app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS' \
        "${logs}/releaseapp.log" ||
        note_failure 'releaseapp: missing the CAP-6 PASS marker'
else
    cat "${logs}/releaseapp.log" >&2
    note_failure 'releaseapp exited nonzero'
fi

if [ "${failures}" -ne 0 ]; then
    die "GUI matrix FAILED (${failures} case(s))"
fi
printf '\n[CAP-7L] run_gui_matrix: PASS\n'
