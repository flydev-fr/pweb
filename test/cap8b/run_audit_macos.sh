#!/usr/bin/env bash
#
# CAP-8B macOS/WKWebView AUDIT harness. MEASUREMENT ONLY, NOT A GATE.
#
# WHAT THIS DOES. It builds the macOS measurement probe through
# test/cap8b/build_cap8b_macos.sh, runs it on a REAL WKWebView on this
# machine's Aqua session, and then requires the document it produced to be a
# structurally valid schema-1 audit before rendering it.
#
# PER-ARCHITECTURE BY DESIGN, exactly as CAP-7M states it: "the engine behaves
# like this" is a claim about x86_64-darwin AND aarch64-darwin separately. The
# architecture comes from `uname -m` and names the document
# (audit-macos-x86_64.json / audit-macos-arm64.json), so one arch's result can
# never be quietly presented as the other's.
#
# WHAT IT DELIBERATELY IS NOT. It is not a gate on CAP-8B's policy, and no
# line it prints is a pass/fail judgement about the engine. The MEASURED fact
# this shard exists to pin down - that upstream passes forMainFrameOnly=true
# for its user script in cocoa_webkit.hh while registering the "__webview__"
# script message handler on the user-content controller, which WebKit exposes
# in EVERY frame - means the interesting answer is very likely "the raw
# channel is reachable where the shim is not". That is a RESULT. The only
# failures this script recognizes are failures of the INSTRUMENT: it did not
# build, it did not run, it crashed, it exceeded its deadline, or it wrote a
# document that is not a measurement.
#
# THERE IS NO SKIP PATH, and that is deliberate. The Windows harness tolerates
# an absent runtime or desktop session because a hosted Windows runner may
# genuinely lack one; a hosted macOS runner always has a real WindowServer/Aqua
# session - there is no Xvfb analogue because none is needed - so a real
# WKWebView opening is a PRECONDITION, the same policy
# test/cap7m/run_cap7m_probes.sh states.
#
# ZERO NETWORK. Every "external" URI in the corpus targets the reserved TLD
# example.invalid and every case is decided by a native hook before a request
# could leave the machine; the one redirect case is the probe's own 302. This
# harness adds no network of its own and needs none.
#
# Prerequisites: test/cap8b/build_cap8b_macos.sh and whatever IT requires
# (the staged libwebview dylib under build/cap7m/webview-dist).
#
# Usage: test/cap8b/run_audit_macos.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-8B] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8B] === %s\n' "$*"; }

[ "$(uname -s)" = 'Darwin' ] || die "this harness is macOS only (uname -s: $(uname -s))"

# uname -m -> the architecture id the audit schema uses. An unrecognized
# machine name is a refusal, never a default: a document filed under the wrong
# architecture is worse than no document.
host_arch="$(uname -m)"
case "${host_arch}" in
    x86_64) arch='x86_64' ;;
    arm64|aarch64) arch='arm64' ;;
    *) die "unsupported macOS architecture: ${host_arch}" ;;
esac

builder='test/cap8b/build_cap8b_macos.sh'
probe='build/cap8b/bin/cap8b_audit_macos'
out="build/cap8b/audit-macos-${arch}.json"
log="build/cap8b/audit-macos-${arch}.log"
summarizer='test/cap8b/summarize_audit.ps1'

# The completion marker the probe prints on its last line, mirroring the
# Windows probe's CAP8B_AUDIT_WIN_DONE. It is a CONTRACT between this harness
# and test/cap8b/cap8b_audit_macos.mm; the override exists so a marker rename
# is a one-line invocation change rather than a red CI run.
marker="${CAP8B_MACOS_MARKER:-CAP8B_AUDIT_MACOS_DONE}"

# The probe watchdogs each of its phases itself. This is the OUTER bound: it
# catches what an in-process watchdog cannot - a hang before the watchdog is
# armed, a wedged NSRunLoop that ignores webview_terminate, a modal panel
# nobody will ever dismiss. It is a hang ceiling, not a prediction: it must
# stay comfortably above the sum of the probe's own per-phase watchdogs, or it
# would fire on a run that was working exactly as designed.
deadline="${CAP8B_TIMEOUT_SEC:-600}"

# The schema check and the human summary are ONE reader shared by all four
# targets, and pwsh is already how both macOS jobs run their pinned-fetch
# verifiers. A per-platform twin of a schema validator is what that avoids.
command -v pwsh >/dev/null 2>&1 || die 'required tool not found: pwsh'
[ -x "${builder}" ] || die "audit builder missing or not executable: ${builder}"
[ -f "${summarizer}" ] || die "audit summarizer missing: ${summarizer}"

# EVERYTHING FROM HERE IS TEE'D INTO THE LOG, INCLUDING THE BUILD.
# MEASURED the hard way on hosted run 32256330091: the probe failed to
# COMPILE, so the runner never reached the point where it started
# writing its log, the upload therefore had nothing to collect, and the
# step - which is deliberately continue-on-error - reported success with
# no artifact at all. A build failure has to be as recoverable as a
# measurement failure, or diagnosing it costs another hosted run.
mkdir -p -- build/cap8b
exec > >(tee -a -- "${log}") 2>&1
printf '[CAP-8B] log opened before the build: %s
' "${log}"

step "build the macOS audit probe (${arch})"
"${builder}" || die 'build_cap8b_macos.sh failed'
[ -x "${probe}" ] ||
    die "the builder produced no probe at ${probe} (contract: build_cap8b_macos.sh -> ${probe})"

mkdir -p -- build/cap8b
# Two named files below build/cap8b, no recursion and no wildcard: a stale
# document from a previous run must never be read as this run's result.
rm -f -- "${out}" "${log}"

# THE OUTER BOUND, WRITTEN OUT RATHER THAN DELEGATED. macOS ships no
# coreutils `timeout` (only Homebrew's gtimeout, which is not a dependency
# this repository takes), so the watchdog is a subshell that escalates
# TERM -> KILL and leaves a sentinel behind. The sentinel is what makes the
# verdict unambiguous: a probe killed at the deadline and a probe that chose
# to die of SIGTERM are indistinguishable from an exit status alone.
fired="build/cap8b/audit-macos-${arch}.timedout"
rm -f -- "${fired}"

step "run the audit probe on a real WKWebView (outer bound ${deadline}s)"
"${probe}" "${out}" > "${log}" 2>&1 &
probe_pid=$!
(
    sleep "${deadline}"
    if kill -0 "${probe_pid}" 2>/dev/null; then
        : > "${fired}"
        kill -TERM "${probe_pid}" 2>/dev/null || true
        sleep 10
        kill -KILL "${probe_pid}" 2>/dev/null || true
    fi
) >/dev/null 2>&1 &
watchdog_pid=$!

set +e
wait "${probe_pid}"
rc=$?
set -e
kill -TERM "${watchdog_pid}" 2>/dev/null || true
wait "${watchdog_pid}" 2>/dev/null || true
cat "${log}"

if [ -f "${fired}" ]; then
    rm -f -- "${fired}"
    die "the audit probe exceeded its ${deadline}s bound (exit ${rc})"
fi
[ "${rc}" -eq 0 ] || die "the audit probe exited ${rc} (see ${log})"
grep -q "${marker}" "${log}" ||
    die "the probe exited 0 without its completion marker ${marker} (see ${log})"
[ -f "${out}" ] || die "the probe wrote no document: ${out}"

step 'validate the document and render the measurement'
pwsh -NoProfile -File "${summarizer}" -Path build/cap8b \
    -RequireTarget "macos-${arch}" -Detail ||
    die 'the audit document failed its schema validation'

printf '\n[CAP-8B] run_audit_macos: AUDIT COMPLETE (measurement only, never a gate)\n'
printf '[CAP-8B] document: %s (%s)\n' "${out}" "${arch}"
