#!/usr/bin/env bash
#
# CAP-8B Linux/WebKitGTK 4.1 AUDIT harness. MEASUREMENT ONLY, NOT A GATE.
#
# WHAT THIS DOES. It builds the Linux measurement probe through
# test/cap8b/build_cap8b_linux.sh, runs it on a REAL GTK/WebKitGTK WebView
# under a virtual display, and then requires the document it produced to be a
# structurally valid schema-1 audit before rendering it.
#
# WHAT IT DELIBERATELY IS NOT. It is not a gate on CAP-8B's policy, and no
# line it prints is a pass/fail judgement about the engine. The MEASURED fact
# this whole shard exists to pin down - that upstream injects its user script
# TOP-FRAME-ONLY on WebKit (WEBKIT_USER_CONTENT_INJECT_TOP_FRAME) while
# registering the "__webview__" script message handler on the user-content
# controller, which WebKit exposes in EVERY frame - means the interesting
# answer is very likely "the raw channel is reachable where the shim is not".
# That is a RESULT. The only failures this script recognizes are failures of
# the INSTRUMENT: it did not build, it did not run, it crashed, it exceeded
# its deadline, or it wrote a document that is not a measurement.
#
# THERE IS NO SKIP PATH, and that is deliberate. The Windows harness tolerates
# an absent WebView2 runtime or desktop session because a hosted Windows
# runner may genuinely lack one; this script supplies its own display through
# xvfb-run, so a real WebKitGTK WebView opening is a PRECONDITION rather than
# a possibility - the same policy test/cap7l/run_gui_matrix.sh states.
#
# ZERO NETWORK. Every "external" URI in the corpus targets the reserved TLD
# example.invalid and every case is decided by a native hook before a request
# could leave the machine; both redirect cases are the probe's own 302s. This
# harness adds no network of its own and needs none.
#
# Prerequisites: test/cap8b/build_cap8b_linux.sh and whatever IT requires
# (the staged libwebview.so under build/cap7l/webview-dist).
#
# Usage: test/cap8b/run_audit_linux.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-8B] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-8B] === %s\n' "$*"; }

builder='test/cap8b/build_cap8b_linux.sh'
probe='build/cap8b/bin/cap8b_audit_linux'
out='build/cap8b/audit-linux-x86_64.json'
log='build/cap8b/audit-linux.log'
summarizer='test/cap8b/summarize_audit.ps1'

# The completion marker the probe prints on its last line, mirroring the
# Windows probe's CAP8B_AUDIT_WIN_DONE. It is a CONTRACT between this harness
# and test/cap8b/cap8b_audit_linux.c; the override exists so a marker rename
# is a one-line invocation change rather than a red CI run.
marker="${CAP8B_LINUX_MARKER:-CAP8B_AUDIT_LINUX_DONE}"

# The probe watchdogs each of its phases itself: 30 + 90 + 30 + 30 s for the
# exposure, coverage and two CSP phases, then 15 + 15 + 17 + 22 s for the four
# user-activation controls (the eval and click controls arm their gesture after
# a 2 s settle, which sits on top of their own deadline) and 15 + 15 s for the
# two redirect controls - 279 s if every one of the ten phases burns its whole
# budget, which only happens when nothing reports. This is the OUTER bound: it
# catches what an
# in-process watchdog cannot - a hang before the watchdog is armed, a wedged
# main loop that ignores webview_terminate, a WebKit web process that dies and
# takes the UI process's event loop with it. It is a hang ceiling, not a
# prediction, and it must stay comfortably above that sum or it would fire on
# a run that was working exactly as designed.
deadline="${CAP8B_TIMEOUT_SEC:-600}"

command -v xvfb-run >/dev/null 2>&1 || die 'required tool not found: xvfb-run'
command -v timeout >/dev/null 2>&1 || die 'required tool not found: timeout'
# The schema check and the human summary are ONE reader shared by all four
# targets (pwsh is preinstalled on the ubuntu-24.04 runner, and this
# repository already runs its pinned-fetch verifiers through it on Linux). A
# bash twin of a schema validator is precisely what that avoids.
command -v pwsh >/dev/null 2>&1 || die 'required tool not found: pwsh'
[ -x "${builder}" ] || die "audit builder missing or not executable: ${builder}"
[ -f "${summarizer}" ] || die "audit summarizer missing: ${summarizer}"

# EVERYTHING FROM HERE IS TEE'D INTO THE LOG, INCLUDING THE BUILD.
# MEASURED the hard way on hosted run 32256330091: the macOS probe failed
# to COMPILE, so its runner never reached the point where it started
# writing a log, the upload therefore had nothing to collect, and the step
# - which is deliberately continue-on-error - reported success with no
# artifact at all. A build failure has to be as recoverable as a
# measurement failure, or diagnosing it costs another hosted run.
mkdir -p -- build/cap8b
exec > >(tee -a -- "${log}") 2>&1
printf '[CAP-8B] log opened before the build: %s
' "${log}"

step 'build the Linux audit probe'
"${builder}" || die 'build_cap8b_linux.sh failed'
[ -x "${probe}" ] ||
    die "the builder produced no probe at ${probe} (contract: build_cap8b_linux.sh -> ${probe})"

mkdir -p -- build/cap8b
# Two named files below build/cap8b, no recursion and no wildcard: a stale
# document from a previous run must never be read as this run's result.
rm -f -- "${out}" "${log}"

# The hosted-runner condition, matched deliberately: no GPU, no compositor.
# WebKitGTK otherwise tries a DMA-BUF/accelerated path that has no backing on
# Xvfb and dies in the web process, which would look like a probe defect
# rather than an environment one. Identical to test/cap7l/run_gui_matrix.sh.
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1

step "run the audit probe under Xvfb (outer bound ${deadline}s)"
set +e
xvfb-run -a timeout --signal=TERM --kill-after=10 "${deadline}" \
    "${probe}" "${out}" > "${log}" 2>&1
rc=$?
set -e
cat "${log}"

# 124: timeout sent TERM. 137: it had to follow with KILL. Either way the
# probe did not finish, and an unfinished probe is never a measurement.
case "${rc}" in
    124|137) die "the audit probe exceeded its ${deadline}s bound (exit ${rc})" ;;
    0) ;;
    *) die "the audit probe exited ${rc} (see ${log})" ;;
esac
grep -q "${marker}" "${log}" ||
    die "the probe exited 0 without its completion marker ${marker} (see ${log})"
[ -f "${out}" ] || die "the probe wrote no document: ${out}"

step 'validate the document and render the measurement'
pwsh -NoProfile -File "${summarizer}" -Path build/cap8b \
    -RequireTarget linux-x86_64 -Detail ||
    die 'the audit document failed its schema validation'

printf '\n[CAP-8B] run_audit_linux: AUDIT COMPLETE (measurement only, never a gate)\n'
printf '[CAP-8B] document: %s\n' "${out}"
