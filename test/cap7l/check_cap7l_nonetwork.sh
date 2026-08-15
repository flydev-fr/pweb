#!/usr/bin/env bash
#
# CAP-7L gate L20: the Linux port opened no transport.
#
# Two halves, because the source half alone has never been enough:
#
#   SOURCE - no HTTP client/server, loopback address, listening socket or
#            file:// URL appears anywhere in the units, probe, gate
#            scripts or ported examples CAP-7L touches. The same sweep
#            the Windows job runs over its own files, over ours.
#
#   RUNTIME - the release application is started for real and its OWN
#            file descriptors are cross-referenced against the kernel's
#            table of listening TCP sockets. Not a port scan and not a
#            netstat grep: only sockets this process holds count, so a
#            listener belonging to anything else on the machine can
#            neither cause a false failure nor mask a real one.
#
# WebKit's internal IPC is deliberately NOT a finding. It is UNIX-domain
# and process-local; the ratified claim is that PWeb adds no network
# transport, not that a browser engine has no internal plumbing. Only
# LISTENING TCP sockets - the thing a "local web server" architecture
# would necessarily create - fail this gate.
#
# Run it under a virtual display:
#   xvfb-run -a test/cap7l/check_cap7l_nonetwork.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7L] === %s\n' "$*"; }

# --- source sweep -------------------------------------------------------------
step 'zero-transport source sweep over the CAP-7L surface'

# test/platform/pweb.test.webkitgtk.pas is deliberately absent: its whole
# job is to carry hostile URI literals (wrong schemes and authorities)
# that a transport sweep cannot tell apart from real usage. The vectors
# earn their place; the sweep would only teach us to weaken them.
cap7l_files=(
    src/platform/linux/pweb.platform.webkitgtk.pas
    src/assets/pweb.assets.folder.pas
    examples/08-release/releaseapp.pas
    examples/06-assets/assetsapp.pas
    test/cap7l/cap7l_probe.c
    test/cap7l/abi_probe_gtk.c
    test/cap7l/abi_probe_gtk.pas
    tools/build-webview-so.sh
    test/cap7l/build_cap7l.sh
    test/cap7l/run_cap7l_gates.sh
    test/cap7l/run_gui_matrix.sh
    test/cap7l/run_release_layout.sh
)
for f in "${cap7l_files[@]}"; do
    [ -f "${f}" ] || die "sweep target missing: ${f}"
done

forbidden='TRestHttpServer|THttpServer|mormot\.rest\.http|mormot\.net\.(server|client|http)|localhost|127\.0\.0\.1|0\.0\.0\.0|http://|file://'
if hits="$(grep -nEi "${forbidden}" "${cap7l_files[@]}")"; then
    printf '%s\n' "${hits}" |
        sed 's/^/FORBIDDEN CAP-7L TRANSPORT PATTERN: /' >&2
    die 'CAP-7L zero-transport source proof FAILED'
fi
printf '[CAP-7L] source sweep: %d files clean\n' "${#cap7l_files[@]}"

# --- runtime proof ------------------------------------------------------------
step 'runtime proof: the release app holds no listening TCP socket'

release="${repo_root}/dist/linux-x64/release"
[ -x "${release}/releaseapp" ] ||
    die 'release layout missing -- run test/cap7l/run_release_layout.sh first'
[ -f "${release}/app.pwb" ] || die 'release layout has no app.pwb'
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'

export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
# long enough that the window is fully up while we look at it
export PWEB_SMOKE_AUTOCLOSE_MS=12000

logs="${repo_root}/build/cap7l/release"
mkdir -p -- "${logs}"

( cd / && env -u LD_LIBRARY_PATH "${release}/releaseapp" ) \
    > "${logs}/nonetwork-run.log" 2>&1 &
app_pid=$!

# the inodes of every socket this process holds, at several points during
# its life - a listener opened only briefly would still be caught
collect_listeners() {
    local pid="$1" inode listening owned=''
    [ -d "/proc/${pid}" ] || return 0
    # LISTEN is state 0A; field 10 is the socket inode
    listening="$(awk 'NR > 1 && $4 == "0A" { print $10 }' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null | LC_ALL=C sort -u)"
    [ -n "${listening}" ] || return 0
    for fd in /proc/"${pid}"/fd/*; do
        inode="$(readlink "${fd}" 2>/dev/null | sed -n 's/^socket:\[\([0-9]*\)\]$/\1/p')"
        [ -n "${inode}" ] || continue
        if printf '%s\n' "${listening}" | grep -Fxq "${inode}"; then
            owned="${owned} ${inode}"
        fi
    done
    printf '%s' "${owned}"
}

found=''
samples=0
while kill -0 "${app_pid}" 2>/dev/null; do
    owned="$(collect_listeners "${app_pid}")"
    [ -n "${owned}" ] && found="${found}${owned}"
    samples=$((samples + 1))
    sleep 0.5
    [ "${samples}" -gt 40 ] && break
done
wait "${app_pid}" || die 'release app exited nonzero during the L20 run'

tail -n 3 "${logs}/nonetwork-run.log"
grep -q 'app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS' \
    "${logs}/nonetwork-run.log" ||
    die 'the L20 run did not reach the release PASS marker'
[ "${samples}" -gt 0 ] ||
    die 'the process was never sampled -- the runtime half proved nothing'

if [ -n "${found}" ]; then
    printf '[CAP-7L] LISTENING SOCKET INODES OWNED BY THE APP:%s\n' "${found}" >&2
    die 'the release application opened a listening TCP socket'
fi
printf '[CAP-7L] runtime: %d samples, no listening TCP socket owned by the app\n' \
    "${samples}"

printf '\n[CAP-7L] check_cap7l_nonetwork: PASS\n'
