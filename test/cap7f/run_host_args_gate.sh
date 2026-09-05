#!/usr/bin/env bash
#
# CAP-7F: the CAP-7M2 host arguments EXECUTED on Linux (closes deferred-work
# D1 on this platform). The bash sibling of test/cap7f/run_host_args_gate.ps1,
# run on the REAL CAP-7L release layout (dist/linux-x64/release, the four
# files assembled by test/cap7l/run_release_layout.sh), from CWD=/ with
# LD_LIBRARY_PATH stripped - the same launch discipline as every CAP-7L gate:
#
#   PASS leg   --pweb-verdict=<file> --pweb-autoclose-ms=4000 with
#              PWEB_SMOKE_AUTOCLOSE_MS=55000 in the environment: the
#              canonical PASS line must land in the verdict file, the page
#              report must carry secure + the anchored 42 + the pweb://app
#              origin, and the wall clock must prove argv won - TWO-SIDED:
#              < 45 s (obeying the env would take >= 55 s) AND >= 3 s (a run
#              that exited before its own 4 s autoclose proves nothing);
#   refusals   unknown argument, malformed --pweb-autoclose-ms=x, duplicated
#              --pweb-autoclose-ms (two DIFFERENT values, so last-one-wins
#              could never masquerade as a refusal), duplicated
#              --pweb-verdict= (the FAIL verdict must land in the LAST path,
#              per the host's pass-1 capture semantics, and never the first)
#              - nonzero exit, typed message, FAIL verdict file still
#              written. Refusal launches are BOUNDED (timeout 30 s + kill)
#              with a small env autoclose exported, so a regressed parser
#              that silently ACCEPTED the argument fails fast instead of
#              idling out the step budget.
#
# NO conditional SKIP, unlike the Windows sibling: this gate runs under a
# real virtual display (xvfb-run -a), so a WebView opening is a precondition
# and every failure gates - the same policy as every other Linux GUI gate.
#
# The PASS marker is greped from the VERDICT_PASS constant in
# examples/08-release/releaseapp.pas, and the shared-object name from
# webview.lock's linux-soname - single-source both, same discipline as
# test/cap7m/run_cap7m_release.sh.
#
# Writes: build/cap7f/host-args.json (+ per-leg logs under build/cap7f/).
#
# Usage: xvfb-run -a test/cap7f/run_host_args_gate.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7F] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7F] === %s\n' "$*"; }

release="${repo_root}/dist/linux-x64/release"
work="${repo_root}/build/cap7f"

# strict 'key = value' reader, the one grammar every lock in this repo uses
lock_read() {
    local file="$1" key="$2" hits value
    hits="$(grep -cE "^${key}[[:space:]]*=" "${file}" || true)"
    [ "${hits}" = '1' ] || die "lock key '${key}' not found exactly once in ${file}"
    value="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "${file}" |
        sed 's/[[:space:]]*$//')"
    [ -n "${value}" ] || die "lock key '${key}' is empty in ${file}"
    printf '%s' "${value}"
}

# minimal JSON string escaper for interpolated free text (backslash, quote)
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

linux_soname="$(lock_read "${repo_root}/webview.lock" linux-soname)"

for f in releaseapp app.pwb "${linux_soname}" LICENSE.webview; do
    [ -e "${release}/${f}" ] ||
        die "release layout incomplete: ${release}/${f} missing -- run test/cap7l/run_release_layout.sh first"
done
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'
command -v timeout >/dev/null 2>&1 || die 'required tool not found: timeout'

mkdir -p -- "${work}"

export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11

# --- the canonical verdict line, greped strictly from the one source ---------
marker_lines="$(grep -cE "^  VERDICT_PASS = '[^']+';\$" \
    examples/08-release/releaseapp.pas || true)"
[ "${marker_lines}" = '1' ] ||
    die "expected exactly one VERDICT_PASS constant in releaseapp.pas, found ${marker_lines}"
pass_line="releaseapp$(sed -n "s/^  VERDICT_PASS = '\([^']*\)';\$/\1/p" \
    examples/08-release/releaseapp.pas)"
[ "${pass_line}" != 'releaseapp' ] || die 'could not extract the VERDICT_PASS marker'
printf '[CAP-7F] canonical verdict line: %s\n' "${pass_line}"

# CWD=/ and LD_LIBRARY_PATH stripped, exactly like run_release_layout.sh:
# app.pwb from the kernel-resolved image path (CAP-10E), the .so from RUNPATH alone.
run_code=0
run_release() {
    local log="$1"
    shift
    set +e
    ( cd / && env -u LD_LIBRARY_PATH "${release}/releaseapp" "$@" ) \
        > "${log}" 2>&1
    run_code=$?
    set -e
}

# Bounded sibling for the refusal legs: a refusal is expected in
# milliseconds, so anything alive after the bound ACCEPTED an argument it
# must refuse - timeout kills it and this gate fails loudly on exit 124.
run_release_bounded() {
    local log="$1"
    shift
    set +e
    ( cd / && env -u LD_LIBRARY_PATH \
        timeout -k 5 30 "${release}/releaseapp" "$@" ) > "${log}" 2>&1
    run_code=$?
    set -e
    if [ "${run_code}" -eq 124 ] || [ "${run_code}" -eq 137 ]; then
        cat "${log}" >&2
        die 'bounded refusal launch exceeded 30s -- the host accepted (or hung on) an argument it must refuse'
    fi
}

assert_fail_verdict() {
    local leg="$1" file="$2"
    [ -f "${file}" ] || die "${leg}: the refused launch left no FAIL verdict file"
    grep -Fq 'releaseapp: FAIL' "${file}" ||
        { cat "${file}" >&2
          die "${leg}: the refusal verdict does not carry the FAIL line"; }
}

# --- PASS leg: verdict file + argv beats the 55 s environment ----------------
step 'PASS leg: --pweb-verdict + --pweb-autoclose-ms=4000 vs env 55000'
pass_verdict="${work}/verdict-pass.txt"
rm -f -- "${pass_verdict}"
started="$(date +%s)"
export PWEB_SMOKE_AUTOCLOSE_MS=55000
run_release "${work}/host-args-pass.log" \
    "--pweb-verdict=${pass_verdict}" --pweb-autoclose-ms=4000
unset PWEB_SMOKE_AUTOCLOSE_MS
elapsed=$(( $(date +%s) - started ))
tail -n 4 "${work}/host-args-pass.log"
[ "${run_code}" -eq 0 ] ||
    { cat "${work}/host-args-pass.log" >&2
      die "PASS leg: releaseapp exited ${run_code}"; }
grep -Fq "${pass_line}" "${work}/host-args-pass.log" ||
    die 'PASS leg: missing the release PASS marker in the log'
# the same three page-report facts the Windows gate asserts, and the 42 is
# ANCHORED so "value":420 can never satisfy it
grep -q '"secure":true' "${work}/host-args-pass.log" ||
    die 'PASS leg: the page never reported "secure":true'
grep -Eq '"value":42([^0-9]|$)' "${work}/host-args-pass.log" ||
    die 'PASS leg: the page never reported the anchored "value":42'
grep -Fq 'pweb://app' "${work}/host-args-pass.log" ||
    die 'PASS leg: the run never named the pweb://app origin'
# CAP-8A runtime deny enforcement: the page probes an UNMAPPED method
# (Denied.Probe) and reports whether the production policy answered typed
# forbidden/403; an allow-all regression 404s instead ("denied":false)
grep -q '"denied":true' "${work}/host-args-pass.log" ||
    die 'PASS leg: the page never reported "denied":true -- the production policy did not forbid the unmapped probe'
[ -f "${pass_verdict}" ] || die 'PASS leg: the run left no verdict file'
verdict_content="$(cat "${pass_verdict}")"
[ "${verdict_content}" = "${pass_line}" ] ||
    die "PASS leg: verdict file holds '${verdict_content}', expected '${pass_line}'"
[ "${elapsed}" -lt 45 ] ||
    die "PASS leg: the run took ${elapsed}s -- the argv autoclose (4000ms) did not win over PWEB_SMOKE_AUTOCLOSE_MS=55000"
[ "${elapsed}" -ge 3 ] ||
    die "PASS leg: the run took only ${elapsed}s -- it exited before its own 4000ms autoclose, so this run proves nothing about argv precedence"
printf '[CAP-7F] PASS leg: canonical verdict in the file, argv won by wall clock (3s <= %ss < 45s)\n' \
    "${elapsed}"

# --- refusal legs ------------------------------------------------------------
# A small env autoclose for the whole block: if a regressed parser ACCEPTED
# one of these command lines, the run auto-closes in 8 s and fails on its
# exit code instead of hanging into the 30 s bound.
export PWEB_SMOKE_AUTOCLOSE_MS=8000

refusal_leg() {
    local name="$1" marker="$2"
    shift 2
    local vf="${work}/verdict-${name}.txt" log="${work}/host-args-${name}.log"
    step "${name}: refused with a typed message AND a FAIL verdict"
    rm -f -- "${vf}"
    run_release_bounded "${log}" "--pweb-verdict=${vf}" "$@"
    [ "${run_code}" -ne 0 ] ||
        die "${name}: releaseapp exited zero where a refusal was required"
    grep -Fq "${marker}" "${log}" ||
        { cat "${log}" >&2; die "${name}: missing the typed marker [${marker}]"; }
    # fail-closed means BEFORE any WebView: a refusal log carrying the
    # runtime verdict would mean content executed after the parse said no
    if grep -Fq "${pass_line}" "${log}"; then
        die "${name}: the refusal log carries a runtime verdict"
    fi
    assert_fail_verdict "${name}" "${vf}"
    printf '[CAP-7F] %s: refused with exit %s, marker + FAIL verdict present\n' \
        "${name}" "${run_code}"
}

refusal_leg refusal_unknown 'usage:' --pweb-bogus-argument
refusal_leg refusal_malformed 'requires a non-negative integer' \
    --pweb-autoclose-ms=x
# two DIFFERENT values: a last-one-wins parser would accept this command
# line and run 55 s, which the bound + exit code turn into a loud failure
refusal_leg refusal_duplicate 'duplicate argument refused' \
    --pweb-autoclose-ms=4000 --pweb-autoclose-ms=55000

# duplicated --pweb-verdict=: pass-1 captures the LAST path, pass-2 refuses
# the duplication - so the FAIL verdict must land in the LAST path and
# never in the first
step 'refusal_duplicate_verdict: FAIL verdict lands in the LAST duplicated path'
dupv_first="${work}/verdict-refusal_dup_verdict_first.txt"
dupv_last="${work}/verdict-refusal_dup_verdict_last.txt"
rm -f -- "${dupv_first}" "${dupv_last}"
run_release_bounded "${work}/host-args-refusal_duplicate_verdict.log" \
    "--pweb-verdict=${dupv_first}" "--pweb-verdict=${dupv_last}"
[ "${run_code}" -ne 0 ] ||
    die 'refusal_duplicate_verdict: releaseapp exited zero where a refusal was required'
grep -Fq 'duplicate argument refused' \
    "${work}/host-args-refusal_duplicate_verdict.log" ||
    { cat "${work}/host-args-refusal_duplicate_verdict.log" >&2
      die 'refusal_duplicate_verdict: missing the typed marker'; }
if grep -Fq "${pass_line}" "${work}/host-args-refusal_duplicate_verdict.log"; then
    die 'refusal_duplicate_verdict: the refusal log carries a runtime verdict'
fi
assert_fail_verdict refusal_duplicate_verdict "${dupv_last}"
[ ! -e "${dupv_first}" ] ||
    die 'refusal_duplicate_verdict: a verdict landed in the FIRST duplicated path -- pass-1 last-capture semantics were not honoured'
printf '[CAP-7F] refusal_duplicate_verdict: refused with exit %s, FAIL verdict in the last path only\n' \
    "${run_code}"

unset PWEB_SMOKE_AUTOCLOSE_MS

# --- the record the emitter and the aggregator read --------------------------
pass_line_json="$(json_escape "${pass_line}")"
cat > "${work}/host-args.json" <<EOF
{
  "schema": 1,
  "os": "linux",
  "pass_leg": "PASS",
  "argv_beats_env": "PASS",
  "elapsed_s": ${elapsed},
  "refusal_unknown": "PASS",
  "refusal_malformed": "PASS",
  "refusal_duplicate": "PASS",
  "refusal_duplicate_verdict": "PASS",
  "overall": "PASS",
  "verdict_line": "${pass_line_json}"
}
EOF

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        printf '### CAP-7F Linux host-argument gate\n'
        printf 'overall: PASS (verdict file, argv-over-env %ss, 4/4 refusals with FAIL verdicts)\n' \
            "${elapsed}"
    } >> "${GITHUB_STEP_SUMMARY}"
fi
printf '\n[CAP-7F] run_host_args_gate: PASS\n'
