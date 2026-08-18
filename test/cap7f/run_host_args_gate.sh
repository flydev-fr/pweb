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
#              canonical PASS line must land in the verdict file AND the
#              wall clock (< 45 s) must prove argv won over the environment;
#   refusals   unknown argument, malformed --pweb-autoclose-ms=x, duplicated
#              option - nonzero exit, typed message, and a FAIL verdict file
#              still written (parse pass 1 captures the path before pass 2
#              refuses, so even a refused command line leaves evidence).
#
# NO conditional SKIP, unlike the Windows sibling: this gate runs under a
# real virtual display (xvfb-run -a), so a WebView opening is a precondition
# and every failure gates - the same policy as every other Linux GUI gate.
#
# The PASS marker is greped from the VERDICT_PASS constant in
# examples/08-release/releaseapp.pas - single-source, same discipline as
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

for f in releaseapp app.pwb libwebview.so.0.12 LICENSE.webview; do
    [ -e "${release}/${f}" ] ||
        die "release layout incomplete: ${release}/${f} missing -- run test/cap7l/run_release_layout.sh first"
done
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'

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
# app.pwb from Executable.ProgramFilePath, the .so from RUNPATH alone.
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
grep -q '"value":42' "${work}/host-args-pass.log" ||
    die 'PASS leg: the page never reported 42'
[ -f "${pass_verdict}" ] || die 'PASS leg: the run left no verdict file'
verdict_content="$(cat "${pass_verdict}")"
[ "${verdict_content}" = "${pass_line}" ] ||
    die "PASS leg: verdict file holds '${verdict_content}', expected '${pass_line}'"
[ "${elapsed}" -lt 45 ] ||
    die "PASS leg: the run took ${elapsed}s -- the argv autoclose (4000ms) did not win over PWEB_SMOKE_AUTOCLOSE_MS=55000"
printf '[CAP-7F] PASS leg: canonical verdict in the file, argv won by wall clock (%ss < 45s)\n' \
    "${elapsed}"

# --- refusal legs ------------------------------------------------------------
refusal_leg() {
    local name="$1" marker="$2"
    shift 2
    local vf="${work}/verdict-${name}.txt" log="${work}/host-args-${name}.log"
    step "${name}: refused with a typed message AND a FAIL verdict"
    rm -f -- "${vf}"
    run_release "${log}" "--pweb-verdict=${vf}" "$@"
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
refusal_leg refusal_duplicate 'duplicate argument refused' \
    --pweb-autoclose-ms=4000 --pweb-autoclose-ms=4000

# --- the record the emitter and the aggregator read --------------------------
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
  "overall": "PASS",
  "verdict_line": "${pass_line}"
}
EOF

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        printf '### CAP-7F Linux host-argument gate\n'
        printf 'overall: PASS (verdict file, argv-over-env %ss, 3/3 refusals with FAIL verdicts)\n' \
            "${elapsed}"
    } >> "${GITHUB_STEP_SUMMARY}"
fi
printf '\n[CAP-7F] run_host_args_gate: PASS\n'
