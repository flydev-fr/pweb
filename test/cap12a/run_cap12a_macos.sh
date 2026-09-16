#!/usr/bin/env bash
#
# CAP-12A: build and run the macOS / WKWebView blob data-plane probe.
#
# ####################################################################
# ##  NEITHER THIS SCRIPT NOR test/cap12a/cap12a_probe.mm HAS EVER  ##
# ##  BEEN RUN. The CAP-12A shard ran on a Windows host with WSL.   ##
# ####################################################################
#
# Every macOS row in cap12a-decision-artifact.md is DERIVED and says so.
# This is the instrument that would turn those rows into measurements; treat
# its first run as a debugging session, not as a measurement, and re-read
# test/cap12a/README.md before believing anything it prints.
#
# NOT A CI STEP, for the same reason the other two runners are not: the run
# puts a throwaway store behind the production pweb://app seam.
#
# Usage: test/cap12a/run_cap12a_macos.sh [--timeout-ms N]
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-12A] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-12A] === %s\n' "$*"; }

. "${repo_root}/tools/pwebrmtree.sh"

timeout_ms=600000
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout-ms)
            [ $# -ge 2 ] || die '--timeout-ms needs a value'
            case "$2" in
                ''|*[!0-9]*) die "--timeout-ms: not a number: '$2'" ;;
            esac
            [ "$2" -ge 10000 ] && [ "$2" -le 1200000 ] ||
                die "--timeout-ms out of range: $2"
            timeout_ms="$2"; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$(uname -s)" = 'Darwin' ] || die 'this runner is macOS only'
command -v clang++ >/dev/null 2>&1 || die 'required tool not found: clang++'
command -v node >/dev/null 2>&1 || die 'required tool not found: node'
for pre in test/cap12a/cap12a_probe.mm test/cap12a/summarize.js \
           test/cap12a/fixture/index.html \
           test/cap12a/fixture/assets/probe.js \
           src/security/pweb.navigation.policy.pas; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

work="${repo_root}/build/cap12a"
mkdir -p -- "${work}"

# --- the CSP, extracted rather than retyped --------------------------------
#
# The probe must carry the SHIPPED policy, byte for byte, or its rows measure
# a different product from the Windows and Linux legs. The constant is a
# multi-line Pascal string concatenation, so it is reassembled here from the
# quoted fragments of that one declaration and the doubled quotes are undone.
policy='src/security/pweb.navigation.policy.pas'
csp_file="${work}/csp.txt"
# FIRST QUOTE TO LAST QUOTE ON EACH LINE, and not a scan for quoted runs: a
# Pascal literal spells an embedded apostrophe by DOUBLING it, so the CSP's
# own ''self'' reads as two adjacent one-character literals to any scanner
# that pairs quotes left to right. The first version of this extraction did
# exactly that and produced `connect-src self`, which the guard below caught.
awk '
  /PWEB_NATIVE_CSP: RawUtf8 =/ { collecting = 1 }
  collecting {
    f = index($0, "\047")
    if (f > 0) {
      l = 0
      for (i = length($0); i > f; i--) {
        if (substr($0, i, 1) == "\047") { l = i; break }
      }
      if (l > f) { printf "%s", substr($0, f + 1, l - f - 1) }
    }
    if ($0 ~ /;[[:space:]]*$/) { exit }
  }
' "${policy}" | sed "s/''/'/g" > "${csp_file}"

[ -s "${csp_file}" ] || die "could not extract PWEB_NATIVE_CSP from ${policy}"
grep -q "connect-src 'self'" "${csp_file}" ||
    die "the extracted CSP does not carry connect-src 'self' -- the shipped
constant moved, or the extraction in this script no longer matches it"
printf '[CAP-12A] CSP extracted: %s\n' "$(cat "${csp_file}")"

# --- build ----------------------------------------------------------------
arch="$(uname -m)"
case "${arch}" in
    x86_64) target='macos-x86_64' ;;
    arm64) target='macos-arm64' ;;
    *) die "unsupported macOS architecture: ${arch}" ;;
esac

outdir="${work}/bin-${target}"
pweb_rm_tree "${outdir}" "${repo_root}/build"
mkdir -p -- "${outdir}"

step "compile cap12a_probe.mm (${target})"
clang++ -std=c++17 -fobjc-arc -O1 -Wall \
    -framework Cocoa -framework WebKit \
    -o "${outdir}/cap12a_probe" test/cap12a/cap12a_probe.mm \
    > "${work}/build-${target}.log" 2>&1 ||
    { tail -40 "${work}/build-${target}.log"
      die 'cap12a_probe.mm compile FAILED -- expected on its first run; see README.md'; }

# --- run ------------------------------------------------------------------
step "run cap12a_probe in a real window (${target})"
export PWEB_CAP12A_REPO="${repo_root}"
export PWEB_CAP12A_OUT="${work}/${target}.json"
export PWEB_CAP12A_CSP_FILE="${csp_file}"
export PWEB_CAP12A_TIMEOUT_MS="${timeout_ms}"
set +e
"${outdir}/cap12a_probe" > "${work}/run-${target}.log" 2>&1
code=$?
set -e
tail -20 "${work}/run-${target}.log"
[ "${code}" -eq 0 ] || die "cap12a_probe exited ${code}"

step 'summarize'
node test/cap12a/summarize.js --work "${work}"
node test/cap12a/summarize.js --work "${work}" --json > "${work}/summary.json"
printf '[CAP-12A] summary: %s\n' "${work}/summary.json"
