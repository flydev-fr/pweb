#!/usr/bin/env bash
#
# CAP-7M0: drive the feasibility probe and render the measured verdicts.
#
# There is NO conditional SKIP here, and that is deliberate. The Windows job
# tolerates an absent WebView2 runtime or desktop session because a hosted
# Windows runner may genuinely lack one. A hosted macOS runner always has a
# real WindowServer/Aqua session - there is no Xvfb analogue because none is
# needed - so a real WKWebView opening is a PRECONDITION, and every failure
# gates.
#
# PROBES C, D, E, F, G, H land here, plus the M11/M12 cross-check that is the
# reason the probe carries no URI parser of its own:
#
#   THE LEAK CHECK. Every URL the probe SERVED must be one the shared
#   PWebParseAppUri ACCEPTS. The converse is deliberately NOT asserted: a
#   perfectly canonical pweb://app/missing.txt is accepted by the routine and
#   still refused by the probe, because the probe has no such asset. "Refused
#   for lack of an asset" and "refused because the URI is not ours" are
#   different questions, and only the second one is a security verdict.
#
# Prerequisites: test/cap7m/build_cap7m.sh
#
# Usage: test/cap7m/run_cap7m_probes.sh [cycles] [--clean]
#        --clean is OPT-IN; without it a stale log directory is a refusal.
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

eval "$(cap7m_take_clean_flag "$@")"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
assert_fpc_target
record_environment

# Three by default: one of each shutdown shape, plus a third so the M6 leak
# bound has a baseline cycle that is not the cache-populating first one.
cycles="${1:-3}"
bin='build/cap7m/bin'
logs='build/cap7m/probe'
vectors='test/cap7m/uri_vectors.txt'

[ -x "${bin}/cap7m_probe" ] || die 'cap7m_probe missing -- run test/cap7m/build_cap7m.sh'
[ -x "${bin}/uri_oracle" ] || die 'uri_oracle missing -- run test/cap7m/build_cap7m.sh'
[ -f "${vectors}" ] || die "vector list missing: ${vectors}"

cap7m_prepare_dir "${repo_root}/${logs}"

# --- PROBES C, D, E, G, H -----------------------------------------------------
step "feasibility probe, ${cycles} cycle(s) (M6-M10, M13-M15)"
probe_log="${logs}/probe.log"
if ! "${bin}/cap7m_probe" "${cycles}" > "${probe_log}" 2> "${logs}/probe.err"; then
    cat "${probe_log}"
    cat "${logs}/probe.err" >&2
    die 'cap7m_probe exited nonzero'
fi
cat "${logs}/probe.err" >&2 || true
grep -E 'CAP7M_M[0-9]+|CAP7M_REPORT|CAP7M_CYCLE_PASS|CAP7M_PROBE_PASS' \
    "${probe_log}" || true

grep -q "CAP7M_PROBE_PASS cycles=${cycles}" "${probe_log}" ||
    die 'the probe did not report its all-cycles pass marker'

seen_cycles="$(grep -c '^CAP7M_CYCLE_PASS ' "${probe_log}" || true)"
[ "${seen_cycles}" = "${cycles}" ] ||
    die "expected ${cycles} passing cycles, saw ${seen_cycles}"

# --- M6: BOTH shutdown shapes actually happened -------------------------------
# A probe that only ever terminated programmatically would say nothing about
# a user closing the window, which is the commoner shutdown in a real app.
if [ "${cycles}" -ge 2 ]; then
    grep -q 'CAP7M_M6 cycle=[0-9]* shutdown=terminate' "${probe_log}" ||
        die 'no cycle shut down through webview_terminate'
    grep -q 'CAP7M_M6 cycle=[0-9]* shutdown=window-close' "${probe_log}" ||
        die 'no cycle shut down through an NSWindow close'
    printf '[CAP-7M0] M6: both shutdown shapes exercised and destroyed cleanly\n'
fi

# --- M7/M8: the frozen threading contract, re-proven --------------------------
# COUNT FIRST, COMPARE SECOND. A `while read` over a grep that matches nothing
# executes zero times and every assertion inside it passes vacuously - the
# CAP-7L silent-skip defect, which is why each of these blocks now proves the
# marker was emitted once per cycle BEFORE it looks at what the marker says.
m7_count="$(grep -c '^CAP7M_M7 ' "${probe_log}" || true)"
[ "${m7_count}" = "${cycles}" ] ||
    die "M7: expected ${cycles} CAP7M_M7 marker(s), saw ${m7_count}"
m7_good="$(grep -c 'CAP7M_M7 cycle=[0-9]* gui_affine=1 worker_distinct=1 direct_return=1' \
    "${probe_log}" || true)"
[ "${m7_good}" = "${cycles}" ] ||
    die "M7: the GUI-affine callback / distinct worker / direct return chain held in only ${m7_good}/${cycles} cycles"

m8_count="$(grep -c '^CAP7M_M8 ' "${probe_log}" || true)"
[ "${m8_count}" = "${cycles}" ] ||
    die "M8: expected ${cycles} CAP7M_M8 marker(s), saw ${m8_count}"
while IFS= read -r line; do
    case "${line}" in
        *'echoes=8 errors=1 outstanding=1'*) ;;
        *) die "M8: unexpected completion counts -- ${line}" ;;
    esac
done < <(grep '^CAP7M_M8 ' "${probe_log}")
printf '[CAP-7M0] M7/M8: %s cycle(s), 8 concurrent + 1 forced error + 1 outstanding each, exactly once\n' \
    "${cycles}"

# --- M6: the leak bound -------------------------------------------------------
# "crash/hang/leak blocks" is the matrix row; the crash and the hang are the
# cycle verdict and the two watchdog deadlines, and this is the leak. The
# probe skips it below three cycles, so a skip is only tolerated there.
leak_line="$(grep -m1 '^CAP7M_M6_LEAK ' "${probe_log}" || true)"
[ -n "${leak_line}" ] || die 'M6: the probe emitted no leak measurement at all'
case "${leak_line}" in
    *skipped=1*)
        [ "${cycles}" -lt 3 ] ||
            die "M6: the leak check reported itself skipped at ${cycles} cycles -- ${leak_line}"
        ;;
esac
record_measurement "${leak_line}"

# --- M13: no NSException reached the C++ boundary -----------------------------
m13_count="$(grep -c '^CAP7M_M13 ' "${probe_log}" || true)"
[ "${m13_count}" = "${cycles}" ] ||
    die "M13: expected ${cycles} CAP7M_M13 marker(s), saw ${m13_count}"
if grep -q 'caught_exceptions=[1-9]' "${probe_log}"; then
    grep 'CAP7M_M13' "${probe_log}" >&2
    die 'M13: an NSException reached the C++ boundary'
fi
while IFS= read -r line; do
    record_measurement "${line}"
done < <(grep '^CAP7M_M13 ' "${probe_log}")

# --- M14: the ownership verdict, RECORDED in both directions ------------------
# WebKit keeping the dataWithBytesNoCopy: pointer is the answer that tells
# CAP-7M its adapter must hold the source buffer alive until didFinish. That
# is a finding, not a probe failure, so the gate requires the verdict to
# EXIST and to be determinate - never to be a particular one of the two.
m14_count="$(grep -c '^CAP7M_M14 ' "${probe_log}" || true)"
[ "${m14_count}" = "${cycles}" ] ||
    die "M14: expected ${cycles} CAP7M_M14 marker(s), saw ${m14_count}"
if grep -q '^CAP7M_M14 .*ownership=undetermined' "${probe_log}"; then
    grep '^CAP7M_M14 ' "${probe_log}" >&2
    die 'M14: the response-body ownership rule came back undetermined (matrix: undetermined => incomplete)'
fi
while IFS= read -r line; do
    record_measurement "${line}"
done < <(grep '^CAP7M_M14 ' "${probe_log}")

# --- M9/M10: the seam ---------------------------------------------------------
m10_count="$(grep -c 'CAP7M_M10 cycle=[0-9]* precreate_seam_ran=1' "${probe_log}" || true)"
[ "${m10_count}" = "${cycles}" ] ||
    die "M10: the pre-create seam ran in only ${m10_count}/${cycles} cycles"
# M9 is a MEASUREMENT with two informative answers: seam_a_effective=no
# refuses seam A (the expected result, per Apple's documented copy
# semantics), seam_a_effective=yes would mean the post-create route works
# after all. Recorded, never gated.
m9_count="$(grep -c '^CAP7M_M9 cycle=[0-9]* postcreate_hits=' "${probe_log}" || true)"
[ "${m9_count}" = "${cycles}" ] ||
    die "M9: expected ${cycles} seam-A verdict marker(s), saw ${m9_count}"
while IFS= read -r line; do
    record_measurement "${line}"
done < <(grep '^CAP7M_M9 ' "${probe_log}")

# --- M15: the secure context is STATED, never inferred ------------------------
report="$(grep -m1 '^CAP7M_REPORT ' "${probe_log}" || true)"
[ -n "${report}" ] || die 'M15: the page never reported'
for fact in '"protocol":"pweb:"' '"host":"app"' '"origin":"pweb://app"' \
            '"secure":true' '"ok":true'; do
    case "${report}" in
        *"${fact}"*) ;;
        *) printf '%s\n' "${report}" >&2
           die "M15: the page did not report ${fact}" ;;
    esac
done
printf '[CAP-7M0] M15: pweb://app is a secure context, stated by the page\n'

# --- M11/M12: the shared routine renders every URI verdict --------------------
step 'PROBE F: observed URIs + canonical vectors -> PWebParseAppUri (M11/M12)'

# awk, not sed: BSD sed - which IS the sed on every macOS runner - does not
# expand \t in a replacement, so the "obvious" one-liner would silently write
# a literal 't' as the separator and every comparison below would miss.
#
# The parse is ANCHORED on the fixed prefix and the URL runs to end of line.
# It has to be: the whole premise of M12 is that these strings are hostile,
# and a page-controlled URL containing " verdict=" would, under a greedy
# `sub(/^.*verdict=/, ...)`, overwrite the verdict column and file a SERVED
# row as something else. A URL is also refused outright if it contains the
# field separator, rather than being allowed to split into a bogus row.
awk '
    /^CAP7M_URI / {
        if (!match($0, /^CAP7M_URI cycle=[0-9]+ verdict=[a-z]+ url=/)) {
            printf "CAP7M_URI_MALFORMED %s\n", $0 > "/dev/stderr"
            bad++
            next
        }
        head = substr($0, 1, RLENGTH)
        u = substr($0, RLENGTH + 1)
        if (index(u, "\t")) {
            printf "CAP7M_URI_HAS_SEPARATOR %s\n", $0 > "/dev/stderr"
            bad++
            next
        }
        v = head
        sub(/^CAP7M_URI cycle=[0-9]+ verdict=/, "", v)
        sub(/ url=$/, "", v)
        printf "%s\t%s\n", v, u
    }
    END { if (bad) exit 3 }
' "${probe_log}" > "${logs}/observed.tsv" ||
    die 'M11: the probe emitted a CAP7M_URI line this gate cannot parse unambiguously'
observed_count="$(grep -c . "${logs}/observed.tsv" || true)"
[ "${observed_count}" -gt 0 ] ||
    die 'M11: not one URL was captured from the scheme handler'

# M11: the main document URL must arrive VERBATIM. A truncated or normalised
# main URL would mean the handler is not seeing what the page asked for, and
# every verdict built on it would be built on a different string.
grep -Fxq "$(printf 'serve\tpweb://app/index.html')" "${logs}/observed.tsv" ||
    { cat "${logs}/observed.tsv" >&2
      die 'M11: pweb://app/index.html was not observed verbatim at the handler'; }

# every distinct observed URL, plus every canonical vector
{
    cut -f2 "${logs}/observed.tsv"
    awk '{ sub(/\r$/, "") } !/^#/ && NF >= 2 { $1 = ""; sub(/^ /, ""); print }' "${vectors}"
} | LC_ALL=C sort -u > "${logs}/oracle-in.txt"

"${bin}/uri_oracle" < "${logs}/oracle-in.txt" > "${logs}/oracle-out.txt" ||
    die 'uri_oracle exited nonzero'
tail -n 1 "${logs}/oracle-out.txt"

# Verdicts are joined to their URIs POSITIONALLY - line N of the oracle's
# output belongs to line N of its input - and the URL is never matched back
# out of the output text. These strings are hostile by construction: one
# containing " url=" would defeat any textual re-parse of the oracle's own
# line, and that is exactly the row an attacker would want misfiled. Only the
# verdict token is read, and it sits immediately after a fixed prefix.
sed -n 's/^CAP7M_ORACLE verdict=\([a-z][a-z]*\) .*$/\1/p' \
    "${logs}/oracle-out.txt" > "${logs}/verdicts.txt"
in_count="$(grep -c . "${logs}/oracle-in.txt" || true)"
out_count="$(grep -c . "${logs}/verdicts.txt" || true)"
[ "${in_count}" = "${out_count}" ] ||
    die "the oracle answered ${out_count} of ${in_count} URIs -- refusing to join them"
paste "${logs}/verdicts.txt" "${logs}/oracle-in.txt" > "${logs}/oracle.tsv"

# 1. the canonical vector expectations
#
# COUNT FIRST, AND AGAINST A RATIFIED NUMBER. A truncated, mis-globbed or
# header-only vectors file would otherwise make the comparison body never
# execute, and this gate would print "0 canonical vectors, every verdict as
# ratified" and exit 0 - the CAP-7L silent-skip defect in a new place.
# Changing uri_vectors.txt is a deliberate act that updates this number in
# the same commit.
CAP7M_RATIFIED_VECTORS=44
vector_count="$(awk '{ sub(/\r$/, "") } !/^#/ && NF >= 2' "${vectors}" | grep -c . || true)"
[ "${vector_count}" = "${CAP7M_RATIFIED_VECTORS}" ] ||
    die "uri_vectors.txt carries ${vector_count} vectors, the ratified count is ${CAP7M_RATIFIED_VECTORS}"

awk -v want="${CAP7M_RATIFIED_VECTORS}" '
    FNR == NR { verdict[$2] = $1; next }
    { sub(/\r$/, "") }
    /^#/ || NF < 2 { next }
    {
        uri = $0
        sub(/^[^ ]+ /, "", uri)
        got = (uri in verdict) ? verdict[uri] : "<absent>"
        checked++
        if (got != $1) {
            printf "[CAP-7M0] VECTOR MISMATCH expect=%s got=%s url=%s\n",
                $1, got, uri > "/dev/stderr"
            bad++
        }
    }
    END {
        if (checked != want) {
            printf "[CAP-7M0] compared %d vectors, expected %d\n",
                checked, want > "/dev/stderr"
            exit 1
        }
        if (bad) {
            printf "[CAP-7M0] %d vector(s) disagree with PWebParseAppUri\n",
                bad > "/dev/stderr"
            exit 1
        }
    }
' FS='\t' "${logs}/oracle.tsv" FS=' ' "${vectors}" ||
    die 'the canonical URI vectors disagree with PWebParseAppUri'
printf '[CAP-7M0] M12: %s canonical vectors, every verdict as ratified\n' "${vector_count}"

# 2. THE LEAK CHECK: nothing served was rejected by the shared routine
awk '
    FNR == NR { verdict[$2] = $1; next }
    $1 != "serve" { next }
    {
        got = ($2 in verdict) ? verdict[$2] : "<absent>"
        if (got != "accept") {
            printf "[CAP-7M0] LEAK: served a URI PWebParseAppUri rejects (%s): %s\n",
                got, $2 > "/dev/stderr"
            bad++
        }
    }
    END { if (bad) exit 1 }
' FS='\t' "${logs}/oracle.tsv" "${logs}/observed.tsv" ||
    die 'a wrong-authority or non-canonical URI was served'

served="$(awk -F'\t' '$1 == "serve"' "${logs}/observed.tsv" | grep -c . || true)"
refused="$(awk -F'\t' '$1 == "refuse"' "${logs}/observed.tsv" | grep -c . || true)"
printf '[CAP-7M0] M11/M12: %s URLs observed (%s served, %s refused), 0 leaks\n' \
    "${observed_count}" "${served}" "${refused}"

# 3. RECORDED, not asserted: which hostile vectors WebKit let through to the
# handler at all. A vector the engine normalised away is defence in depth and
# is worth knowing about; it is never why a vector is considered handled.
# Exact whole-string equality, never a substring test - `pweb://` is a prefix
# of `pweb://evil/x`, and quiet over-reporting makes a record worthless.
step 'RECORDED: hostile vectors that actually reached the handler'
awk '
    FNR == NR { observed[$2] = 1; next }
    { sub(/\r$/, "") }
    /^#/ || NF < 2 || $1 != "reject" { next }
    {
        uri = $0
        sub(/^[^ ]+ /, "", uri)
        if (uri in observed) {
            printf "CAP7M_VECTOR_REACHED_HANDLER %s\n", uri
        }
    }
' FS='\t' "${logs}/observed.tsv" FS=' ' "${vectors}"

printf '\n[CAP-7M0] run_cap7m_probes: PASS (%s)\n' "$(uname -m)"
