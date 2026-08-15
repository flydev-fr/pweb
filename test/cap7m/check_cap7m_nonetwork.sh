#!/usr/bin/env bash
#
# CAP-7M0 gate M20: the macOS path opened no transport.
#
# Two halves, because the source half alone has never been enough:
#
#   SOURCE  - no HTTP client/server, loopback address, listening socket or
#             file:// URL appears anywhere in the units, probe or gate
#             scripts CAP-7M0 adds. The same sweep the Windows and Linux jobs
#             run over their own files, over ours.
#
#   RUNTIME - the probe is started for real and its OWN file descriptors are
#             cross-referenced against listening TCP sockets. Not a port scan
#             and not an `lsof | grep`: only sockets THIS process holds count,
#             so a listener belonging to anything else on the machine can
#             neither cause a false failure nor mask a real one.
#
# WebKit's internal XPC/IPC is deliberately NOT a finding, and neither is the
# fact that WKWebView runs in its own process family. Those are Mach ports and
# UNIX-domain channels internal to a browser engine; the ratified claim is
# that PWeb adds no NETWORK transport, not that WebKit has no plumbing. Only
# LISTENING TCP sockets - the thing a "local web server" architecture would
# necessarily create - fail this gate.
#
# test/cap7m/uri_vectors.txt is deliberately NOT swept: its whole job is to
# carry hostile URI literals (wrong schemes and authorities, including
# http:// and file://) that a transport sweep cannot tell apart from real
# usage. The vectors earn their place; sweeping them would only teach us to
# weaken them.
#
# Prerequisites: test/cap7m/build_cap7m.sh
#
# Usage: test/cap7m/check_cap7m_nonetwork.sh
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
record_environment

# --- source sweep -------------------------------------------------------------
step 'zero-transport source sweep over the CAP-7M0 surface'

# tools/get-fpc-macos.ps1 IS swept, deliberately. It carries an https:// URL
# for the pinned toolchain artifact, which the pattern below does not match
# (`http://` is not a substring of `https://`) and which is not a transport in
# the sense this gate means: a build-time fetch of a digest-pinned compiler is
# the same category as tools/get-webview.ps1, and the claim under test is that
# the APPLICATION opens no network transport. It is on the list anyway so it
# cannot later grow a listener, a loopback address or a plain-http fetch
# unnoticed.
cap7m_files=(
    test/cap7m/cap7m_probe.mm
    test/cap7m/uri_oracle.pas
    test/cap7m/abi_probe_fcntl.c
    test/cap7m/abi_probe_fcntl.pas
    test/cap7m/cap7m_common.sh
    test/cap7m/build_cap7m.sh
    test/cap7m/run_cap7m_probes.sh
    test/cap7m/check_abi.sh
    test/cap7m/check_webview_exports.sh
    test/cap7m/check_release_layout.sh
    test/cap7m/summarize_cap7m.sh
    tools/build-webview-dylib.sh
    tools/get-fpc-macos.ps1
)

# The two files deliberately NOT swept, and why. Both reasons are the same
# one: their job is to CONTAIN the hostile shapes the sweep looks for, so
# sweeping them would only teach us to weaken them. The CAP-7L sweep excluded
# test/platform/pweb.test.webkitgtk.pas for exactly this reason.
#
#   uri_vectors.txt          - the canonical hostile URI list: wrong schemes
#                              and authorities, and a transport sweep cannot
#                              tell those apart from real usage.
#   check_cap7m_nonetwork.sh - this file, which carries the forbidden pattern
#                              itself and would match on its own definition.
sweep_exempt=(
    test/cap7m/uri_vectors.txt
    test/cap7m/check_cap7m_nonetwork.sh
)

for f in "${cap7m_files[@]}"; do
    [ -f "${f}" ] || die "sweep target missing: ${f}"
done

# A HAND-MAINTAINED LIST THAT NOBODY CHECKS IS A LIST THAT ROTS. Every file
# under test/cap7m/ must be either swept or explicitly exempt above, so a gate
# added later cannot be silently unswept - which is the failure mode where
# this proof quietly stops proving anything.
unswept=''
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    known=''
    for known_file in "${cap7m_files[@]}" "${sweep_exempt[@]}"; do
        [ "${f}" = "${known_file}" ] && { known=1; break; }
    done
    [ -n "${known}" ] || unswept="${unswept} ${f}"
done < <(find test/cap7m -type f | LC_ALL=C sort)
if [ -n "${unswept}" ]; then
    printf '[CAP-7M0] files under test/cap7m/ that are neither swept nor exempt:\n' >&2
    printf '  %s\n' ${unswept} >&2
    die 'the zero-transport sweep list is out of date'
fi

forbidden='TRestHttpServer|THttpServer|mormot\.rest\.http|mormot\.net\.(server|client|http)|localhost|127\.0\.0\.1|0\.0\.0\.0|http://|file://'
if hits="$(grep -nEi "${forbidden}" "${cap7m_files[@]}")"; then
    printf '%s\n' "${hits}" |
        sed 's/^/FORBIDDEN CAP-7M0 TRANSPORT PATTERN: /' >&2
    die 'CAP-7M0 zero-transport source proof FAILED'
fi
printf '[CAP-7M0] source sweep: %d files clean, %d explicitly exempt, coverage of test/cap7m/ complete\n' \
    "${#cap7m_files[@]}" "${#sweep_exempt[@]}"

# --- runtime proof ------------------------------------------------------------
step 'runtime proof: the probe holds no listening TCP socket'

bin='build/cap7m/bin'
logs='build/cap7m/nonetwork'
[ -x "${bin}/cap7m_probe" ] || die 'cap7m_probe missing -- run test/cap7m/build_cap7m.sh'
command -v lsof >/dev/null 2>&1 || die 'required tool not found: lsof'

mkdir -p -- "${logs}"

"${bin}/cap7m_probe" 1 > "${logs}/nonetwork-run.log" 2>&1 &
app_pid=$!

# Sampled repeatedly through the process's life, so a listener opened only
# briefly - during startup, or only while a page is loading - is still caught.
found=''
samples=0
while kill -0 "${app_pid}" 2>/dev/null; do
    owned="$(lsof -nP -a -p "${app_pid}" -iTCP -sTCP:LISTEN 2>/dev/null |
        awk 'NR > 1 { print $9 }' | LC_ALL=C sort -u || true)"
    [ -n "${owned}" ] && found="${found} ${owned}"
    samples=$((samples + 1))
    sleep 0.5
    [ "${samples}" -gt 120 ] && break
done
wait "${app_pid}" || die 'the probe exited nonzero during the M20 run'

tail -n 3 "${logs}/nonetwork-run.log"
grep -q 'CAP7M_PROBE_PASS cycles=1' "${logs}/nonetwork-run.log" ||
    die 'the M20 run did not reach the probe pass marker'
[ "${samples}" -gt 0 ] ||
    die 'the process was never sampled -- the runtime half proved nothing'

if [ -n "${found}" ]; then
    printf '[CAP-7M0] LISTENING TCP SOCKETS OWNED BY THE PROBE:%s\n' "${found}" >&2
    die 'the probe opened a listening TCP socket'
fi
printf '[CAP-7M0] runtime: %d samples, no listening TCP socket owned by the probe\n' \
    "${samples}"

printf '\n[CAP-7M0] check_cap7m_nonetwork: PASS (%s)\n' "$(uname -m)"
