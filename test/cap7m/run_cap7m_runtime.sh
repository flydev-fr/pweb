#!/usr/bin/env bash
#
# CAP-7M1 GUI gates: the PRODUCTION path, in a real WKWebView.
#
# There is NO conditional SKIP here, and that is deliberate. The Windows job
# tolerates an absent WebView2 runtime or desktop session because a hosted
# Windows runner may genuinely lack one. A hosted macOS runner always has a
# real WindowServer/Aqua session - there is no Xvfb analogue because none is
# needed - so a real WKWebView opening is a PRECONDITION, and every failure
# gates.
#
# What this drives, per store mode and per cycle:
#
#   pweb://app -> the pre-create seam -> TCocoaAssetHandler -> PWebParseAppUri
#   -> IAssetStore (folder AND zip, over ONE corpus) -> the page -> the
#   production __pweb_invoke binding -> a scheduler worker -> mORMot -> 42
#
# and asserts, from the harness's own markers:
#
#   - the secure-origin object, STATED by the page, in every cycle;
#   - the 42 marker and the 8 + 1 + 1 invocation counts;
#   - the frozen threading facts (GUI-affine callback, distinct worker,
#     direct return);
#   - zero suppressed terminals, zero caught exceptions, zero unresolved
#     handles, an empty live-task set and an empty handler registry;
#   - both shutdown shapes across the run;
#   - THE LEAK CHECK: every URI the PRODUCTION handler observed is fed to the
#     shared PWebParseAppUri through test/cap7m/uri_oracle, and a SERVED URI
#     the routine rejects is a blocker. The converse is deliberately NOT
#     asserted: a perfectly canonical pweb://app/missing.txt is accepted by
#     the routine and still refused by the handler, because there is no such
#     asset - "refused for lack of an asset" and "refused because the URI is
#     not ours" are different questions, and only the second is a security
#     verdict.
#
# Then the whole thing again from `/` with all three DYLD_* hints stripped, so
# "it resolved its dylib from its own location" is a measurement rather than
# an accident of the working directory.
#
# Prerequisites: test/cap7m/build_cap7m.sh
#
# Usage: test/cap7m/run_cap7m_runtime.sh [cycles] [--clean]
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

cycles="${1:-3}"
case "${cycles}" in
    ''|*[!0-9]*) die "cycles must be a number, got '${cycles}'" ;;
esac
[ "${cycles}" -ge 2 ] ||
    die 'at least 2 cycles are required: the two shutdown shapes alternate'

bin='build/cap7m/bin'
logs="${repo_root}/build/cap7m/runtime"
fixture="${repo_root}/test/cap7m/fixture"
vectors='test/cap7m/uri_vectors.txt'

[ -x "${bin}/cap7m_runtime" ] ||
    die 'cap7m_runtime missing -- run test/cap7m/build_cap7m.sh'
[ -x "${bin}/uri_oracle" ] ||
    die 'uri_oracle missing -- run test/cap7m/build_cap7m.sh'
[ -d "${fixture}" ] || die "fixture missing: ${fixture}"
[ -f "${vectors}" ] || die "vector list missing: ${vectors}"

cap7m_prepare_dir "${logs}"

# ---------------------------------------------------------------------------
# assert_run <store-label> <logfile> [record-label]
#
# Every per-cycle and per-run marker. The STORE label is what the harness
# wrote into the log; the RECORD label is what this gate keys its measurements
# on, and they differ for the stripped-environment run - which uses the folder
# store but must not file its numbers under the same key as the earlier folder
# run, or the record cannot be read afterwards.
# ---------------------------------------------------------------------------
assert_run() {
    local label="$1" log="$2" rec="${3:-$1}" n readback

    grep -q "CAP7M1_PASS store=${label} cycles=${cycles}" "${log}" ||
        die "${label}: the harness did not report its all-cycles pass marker"

    # COUNT FIRST, COMPARE SECOND. A `while read` over a grep that matches
    # nothing executes zero times and every assertion inside it passes
    # vacuously - the CAP-7L silent-skip defect, which is why each block below
    # proves the marker was emitted once per cycle BEFORE reading what it says.
    n="$(grep -c "^CAP7M1_CYCLE_PASS cycle=[0-9]* store=${label}$" "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: expected ${cycles} passing cycles, saw ${n}"

    # MEASURED, run 31951505821: with FPC's default FPU state every cycle died
    # with EInvalidOp before serving one asset, because WebKit computes on
    # NaNs. Asserted rather than assumed - a process that merely SURVIVED
    # proves nothing about why.
    grep -q "^CAP7M1_FPU store=${label} traps_masked=1$" "${log}" ||
        die "${label}: the FPU was not put in its non-trapping default state"
    record_measurement "CAP7M1_FPU store=${rec} traps_masked=1"

    n="$(grep -c '^CAP7M1_SEAM cycle=[0-9]* seam_ran=1 ' "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: the pre-create seam ran in only ${n}/${cycles} cycles"

    # RECORDED, NOT GATED, and deliberately so. Attach already REFUSED
    # 'foreign' (another handler owning pweb:// on this view), which is the
    # only unambiguous answer. 'absent' cannot distinguish a configuration
    # copy that drops the scheme-handler map from a view that genuinely has no
    # handler, and Cocoa's behaviour there has never been measured by this
    # project - gating it would fail a correct adapter on an assumption.
    #
    # PROMOTE THIS TO A GATE once a hosted run has reported readback=ours on
    # BOTH architectures; until then the per-view claim rests on the served
    # main document and the page's own verdict, which ARE asserted above and
    # below. Ledgered in deferred-work.md.
    readback="$(sed -n 's/^CAP7M1_SEAM .*readback=\([a-z][a-z]*\).*$/\1/p' \
        "${log}" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//')"
    record_measurement "CAP7M1_READBACK store=${rec} observed=${readback:-<none>}"
    # PROMOTED from recorded to gated. Run 31952514083 reported readback=ours
    # on every cycle on BOTH architectures, which was the ledgered condition:
    # the configuration a WKWebView hands back DOES carry the scheme-handler
    # registration, so 'absent' is no longer an ambiguous platform answer -
    # it is drift, and so is 'foreign'. Anything but 'ours' fails here, and
    # Attach itself refuses first.
    [ "${readback}" = 'ours' ] ||
        die "${label}: per-view seam read-back is '${readback:-<none>}', expected 'ours' on every cycle"

    # P17: the secure origin, STATED by the page, in EVERY cycle - never once
    # and never inferred from "it rendered".
    n="$(grep -c '^CAP7M1_REPORT ' "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: the page reported in only ${n}/${cycles} cycles"
    # ANCHORED to the report line, and matched as a FIXED string. This log
    # also carries every URL the handler observed, verbatim and
    # page-controlled: an unanchored count of '"secure":true' could be
    # satisfied by a page fetching pweb://app/%22secure%22:true. The
    # CAP7M1_URI parser anchors for exactly this reason and so must this.
    local fact
    for fact in '"protocol":"pweb:"' '"host":"app"' '"origin":"pweb://app"' \
                '"secure":true' '"ok":true'; do
        n="$(awk -v f="${fact}" '
            index($0, "CAP7M1_REPORT ") == 1 && index($0, f) > 0 { c++ }
            END { print c + 0 }' "${log}")"
        [ "${n}" = "${cycles}" ] ||
            die "${label}: ${fact} was reported in only ${n}/${cycles} cycles"
    done

    # P18: the frozen threading contract, re-proven against production
    n="$(grep -c '^CAP7M1_THREADS cycle=[0-9]* gui_affine=1 worker_distinct=1 direct_return=1$' \
        "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: the GUI-affine callback / distinct worker / direct return chain held in only ${n}/${cycles} cycles"

    # P19/P20: 8 concurrent + 1 explicit RPC = 9 Add calls, 1 forced error,
    # 1 invocation still outstanding when the shutdown began
    n="$(grep -c '^CAP7M1_INVOKE cycle=[0-9]* adds=9 errors=1 outstanding=1$' \
        "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: the 8+1+1 invocation counts held in only ${n}/${cycles} cycles"

    # P12/P15/P16: zero anomalies, an empty task set and an empty registry
    n="$(grep -c 'suppressed=0 caught=0 unresolved=0 live=0$' "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: only ${n}/${cycles} cycles ended with zero anomalies and an empty task set"
    n="$(grep -c '^CAP7M1_REGISTRY cycle=[0-9]* handlers=0 handle_resolves=0$' \
        "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: only ${n}/${cycles} cycles ended with an empty registry and an unresolvable handle"

    # P23: BOTH shutdown shapes actually happened. A run that only ever
    # terminated programmatically would say nothing about a user closing the
    # window, which is the commoner shutdown in a real application.
    grep -q '^CAP7M1_SHUTDOWN cycle=[0-9]* shape=terminate clean=1$' "${log}" ||
        die "${label}: no cycle shut down through webview_terminate"
    grep -q '^CAP7M1_SHUTDOWN cycle=[0-9]* shape=window-close clean=1$' "${log}" ||
        die "${label}: no cycle shut down through an NSWindow close"

    # G3: the URI ring's own integrity, per cycle. A ring that overwrote its
    # oldest entries would make the leak check below cover an unknown subset
    # of the requests while still reporting "0 leaks", and a request whose URL
    # could not be read at all would never reach the oracle. Both are required
    # to be zero, and the ring must account for EVERY task the bridge started.
    n="$(grep -c '^CAP7M1_URI_RING cycle=[0-9]* observed=[0-9]* dropped=0 nonconforming=0 started=[0-9]*$' \
        "${log}" || true)"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: only ${n}/${cycles} cycles kept a complete URI ring (dropped or nonconforming observations)"
    n="$(awk '
        index($0, "CAP7M1_URI_RING ") == 1 {
            obs = ""; started = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^observed=/) { obs = substr($i, 10) }
                if ($i ~ /^started=/)  { started = substr($i, 9) }
            }
            if (obs != "" && obs == started) { c++ }
        }
        END { print c + 0 }' "${log}")"
    [ "${n}" = "${cycles}" ] ||
        die "${label}: the URI ring observed every started task in only ${n}/${cycles} cycles"

    # P23: the leak half.
    local leak
    leak="$(grep -m1 '^CAP7M1_LEAK ' "${log}" || true)"
    [ -n "${leak}" ] || die "${label}: the harness emitted no leak measurement"
    # A SKIP is only tolerable below the harness's own three-cycle floor, and
    # a zero baseline is not a measurement: pweb_cocoa_rss_kb returns 0 when
    # task_info fails, and base=last=0 yields growth=0 inside any budget - a
    # detector reporting a pass while measuring nothing at all.
    case "${leak}" in
        *skipped=1*)
            [ "${cycles}" -lt 3 ] ||
                die "${label}: the leak check reported itself skipped at ${cycles} cycles -- ${leak}"
            ;;
        *)
            local base last
            base="$(printf '%s' "${leak}" | sed -n 's/.*[[:space:]]base_kb=\([0-9]*\).*/\1/p')"
            last="$(printf '%s' "${leak}" | sed -n 's/.*[[:space:]]last_kb=\([0-9]*\).*/\1/p')"
            { [ -n "${base}" ] && [ "${base}" -gt 0 ]; } ||
                die "${label}: the leak baseline is 0 KiB -- task_info gave no reading, so nothing was measured (${leak})"
            { [ -n "${last}" ] && [ "${last}" -gt 0 ]; } ||
                die "${label}: the final leak reading is 0 KiB -- nothing was measured (${leak})"
            ;;
    esac
    record_measurement "CAP7M1 store=${rec} ${leak}"

    # RECORDED, never dressed up: whether stopURLSchemeTask: arrived at all.
    # A synchronous main-thread handler makes the cancellation race
    # STRUCTURALLY absent rather than merely untested, so zero arrivals here
    # is expected - and it is a LIMITATION of what this leg proves, not a
    # passing race test. The deterministic proof lives in the headless suite.
    #
    # The per-cycle values are DELTAS (the bridge's counters are process
    # cumulative and the harness subtracts), so summing them is meaningful.
    local stops serving
    stops="$(awk '/^CAP7M1_STATS /{ for (i=1;i<=NF;i++) if ($i ~ /^stopped=/) { sub(/^stopped=/,"",$i); s+=$i } } END { print s+0 }' \
        "${log}")"
    serving="$(awk '/^CAP7M1_STATS /{ for (i=1;i<=NF;i++) if ($i ~ /^stops_serving=/) { sub(/^stops_serving=/,"",$i); s+=$i } } END { print s+0 }' \
        "${log}")"
    record_measurement "CAP7M1 store=${rec} stop_arrivals=${stops} stops_while_serving=${serving}"
    if [ "${stops}" = '0' ]; then
        printf '[CAP-7M1] LIMITATION: stopURLSchemeTask: never arrived in the %s leg.\n' "${label}"
        printf '[CAP-7M1] The handler serves entirely inside startURLSchemeTask: on the main\n'
        printf '[CAP-7M1] thread, so a cancellation cannot interleave with serving. That race is\n'
        printf '[CAP-7M1] structurally absent here and is proven deterministically by the stub-task\n'
        printf '[CAP-7M1] cases in the headless suite - it is NOT proven by this run.\n'
    fi
}

# ---------------------------------------------------------------------------
# assert_uri_leak <label> <logfile> - every SERVED URI must be one the shared
# PWebParseAppUri ACCEPTS, plus the canonical vector list
# ---------------------------------------------------------------------------
assert_uri_leak() {
    # TWO statements, deliberately. `local a="$1" b="${a}x"` does NOT work on
    # macOS: bash 3.2 - which IS /bin/bash on every runner - expands every word
    # of the command BEFORE performing any of the assignments, so ${label} is
    # still unset when ${observed} is built, and `set -u` turns that into
    # `label: unbound variable`. Newer bash assigns left to right and hides it,
    # which is why this survived review on a Linux/Windows dev host.
    local label="$1" log="$2"
    local observed="${logs}/${label}-observed.tsv"
    local oracle_in="${logs}/${label}-oracle-in.txt"
    local oracle_out="${logs}/${label}-oracle-out.txt"
    local verdicts="${logs}/${label}-verdicts.txt"
    local joined="${logs}/${label}-oracle.tsv"
    local observed_count in_count out_count served refused

    # awk, not sed: BSD sed - which IS the sed on every macOS runner - does not
    # expand \t in a replacement, so the "obvious" one-liner would silently
    # write a literal 't' as the separator and every comparison below would
    # miss.
    #
    # The parse is ANCHORED on the fixed prefix and the URL runs to end of
    # line. It has to be: these strings are hostile by construction, and a
    # page-controlled URL containing " verdict=" would, under a greedy
    # sub(/^.*verdict=/, ...), overwrite the verdict column and file a SERVED
    # row as something else.
    awk '
        /^CAP7M1_URI / {
            if (!match($0, /^CAP7M1_URI cycle=[0-9]+ verdict=[a-z]+ url=/)) {
                printf "CAP7M1_URI_MALFORMED %s\n", $0 > "/dev/stderr"
                bad++
                next
            }
            head = substr($0, 1, RLENGTH)
            u = substr($0, RLENGTH + 1)
            if (index(u, "\t")) {
                printf "CAP7M1_URI_HAS_SEPARATOR %s\n", $0 > "/dev/stderr"
                bad++
                next
            }
            v = head
            sub(/^CAP7M1_URI cycle=[0-9]+ verdict=/, "", v)
            sub(/ url=$/, "", v)
            printf "%s\t%s\n", v, u
        }
        END { if (bad) exit 3 }
    ' "${log}" > "${observed}" ||
        die "${label}: the harness emitted a CAP7M1_URI line this gate cannot parse unambiguously"

    observed_count="$(grep -c . "${observed}" || true)"
    [ "${observed_count}" -gt 0 ] ||
        die "${label}: not one URL was captured from the production handler"

    # The main document URL must arrive VERBATIM. A truncated or normalised
    # main URL would mean the handler is not seeing what the page asked for,
    # and every verdict built on it would rest on a different string.
    grep -Fxq "$(printf 'serve\tpweb://app/')" "${observed}" ||
        { cat "${observed}" >&2
          die "${label}: pweb://app/ was not observed verbatim at the handler"; }

    { cut -f2 "${observed}"
      awk '{ sub(/\r$/, "") } !/^#/ && NF >= 2 { $1 = ""; sub(/^ /, ""); print }' \
        "${vectors}"
    } | LC_ALL=C sort -u > "${oracle_in}"

    "${bin}/uri_oracle" < "${oracle_in}" > "${oracle_out}" ||
        die "${label}: uri_oracle exited nonzero"
    tail -n 1 "${oracle_out}"

    # Verdicts are joined to their URIs POSITIONALLY - line N of the oracle's
    # output belongs to line N of its input - and the URL is never matched
    # back out of the output text. One containing " url=" would defeat any
    # textual re-parse, and that is exactly the row an attacker would want
    # misfiled.
    sed -n 's/^CAP7M_ORACLE verdict=\([a-z][a-z]*\) .*$/\1/p' \
        "${oracle_out}" > "${verdicts}"
    in_count="$(grep -c . "${oracle_in}" || true)"
    out_count="$(grep -c . "${verdicts}" || true)"
    [ "${in_count}" = "${out_count}" ] ||
        die "${label}: the oracle answered ${out_count} of ${in_count} URIs -- refusing to join them"
    paste "${verdicts}" "${oracle_in}" > "${joined}"

    # 1. the canonical vector expectations, against a RATIFIED count. A
    # truncated or header-only vectors file would otherwise make the
    # comparison body never execute and this gate would print "0 vectors, every
    # verdict as ratified" and exit 0.
    #
    # The number itself comes from test/cap7m/cap7m_common.sh, so this gate
    # and run_cap7m_probes.sh cannot disagree about what "ratified" means.
    local vector_count
    vector_count="$(awk '{ sub(/\r$/, "") } !/^#/ && NF >= 2' "${vectors}" |
        grep -c . || true)"
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
                printf "[CAP-7M1] VECTOR MISMATCH expect=%s got=%s url=%s\n",
                    $1, got, uri > "/dev/stderr"
                bad++
            }
        }
        END {
            if (checked != want) {
                printf "[CAP-7M1] compared %d vectors, expected %d\n",
                    checked, want > "/dev/stderr"
                exit 1
            }
            if (bad) { exit 1 }
        }
    ' FS='\t' "${joined}" FS=' ' "${vectors}" ||
        die "${label}: the canonical URI vectors disagree with PWebParseAppUri"

    # 2. THE LEAK CHECK: nothing the PRODUCTION handler served was rejected by
    # the shared routine.
    awk '
        FNR == NR { verdict[$2] = $1; next }
        $1 != "serve" { next }
        {
            got = ($2 in verdict) ? verdict[$2] : "<absent>"
            if (got != "accept") {
                printf "[CAP-7M1] LEAK: served a URI PWebParseAppUri rejects (%s): %s\n",
                    got, $2 > "/dev/stderr"
                bad++
            }
        }
        END { if (bad) exit 1 }
    ' FS='\t' "${joined}" "${observed}" ||
        die "${label}: a wrong-authority or non-canonical URI was SERVED by the production handler"

    served="$(awk -F'\t' '$1 == "serve"' "${observed}" | grep -c . || true)"
    refused="$(awk -F'\t' '$1 == "refuse"' "${observed}" | grep -c . || true)"
    record_measurement "CAP7M1_URI store=${label} observed=${observed_count} served=${served} refused=${refused} leaks=0"
    printf '[CAP-7M1] %s: %s URLs observed (%s served, %s refused), 0 leaks\n' \
        "${label}" "${observed_count}" "${served}" "${refused}"
}

# --- both store modes, from the repository -----------------------------------
for mode in folder zip; do
    step "production runtime, ${cycles} cycle(s), ${mode} store"
    log="${logs}/${mode}.log"
    if ! "${bin}/cap7m_runtime" "${mode}" "${fixture}" "${logs}/${mode}-work" \
            "${cycles}" > "${log}" 2> "${logs}/${mode}.err"; then
        cat "${log}"
        cat "${logs}/${mode}.err" >&2
        die "cap7m_runtime (${mode}) exited nonzero"
    fi
    cat "${logs}/${mode}.err" >&2 || true
    grep -E '^CAP7M1_(SEAM|THREADS|INVOKE|STATS|REGISTRY|SHUTDOWN|RSS|LEAK|CYCLE_PASS|PASS) ' \
        "${log}" || true
    assert_run "${mode}" "${log}"
    assert_uri_leak "${mode}" "${log}"
done

# --- P22/P24: from `/`, with every loader hint stripped -----------------------
# env -u removes the loader hints outright. If any of them were doing the work,
# the run below fails - which is the whole assertion. All THREE are stripped:
# unsetting only DYLD_LIBRARY_PATH would leave DYLD_FRAMEWORK_PATH and
# DYLD_FALLBACK_LIBRARY_PATH able to find the dylib somewhere else, and the
# conclusion would be drawn from a run in which nothing was actually absent.
#
# The store is rooted at an ABSOLUTE path and the harness is given absolute
# paths, so a different working directory must change nothing at all. Any CWD
# dependence surfaces here rather than in a user's application.
step "production runtime from CWD=/ with every DYLD_* hint stripped (folder store)"
strip_log="${logs}/stripped.log"
( cd / && env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH \
        -u DYLD_FALLBACK_LIBRARY_PATH \
        "${repo_root}/${bin}/cap7m_runtime" folder "${fixture}" \
        "${logs}/stripped-work" "${cycles}" ) \
    > "${strip_log}" 2> "${logs}/stripped.err" ||
    { cat "${strip_log}"; cat "${logs}/stripped.err" >&2
      die 'the production harness failed from an unrelated CWD with DYLD_* stripped'; }
cat "${logs}/stripped.err" >&2 || true
assert_run folder "${strip_log}" stripped-folder
assert_uri_leak stripped-folder "${strip_log}"
# stripped-folder, NOT folder: this run and the earlier folder run both append
# to the same measurements.txt, and two rows keyed `store=folder` describing
# different runs is a record that cannot be read afterwards.
record_measurement "CAP7M1_CWD store=stripped-folder cwd=/ dyld_hints=stripped result=pass"

printf '\n[CAP-7M1] run_cap7m_runtime: PASS (%s, %s cycles x {folder, zip} + a stripped-environment run)\n' \
    "${PWEB_MACOS_HOST_ARCH}" "${cycles}"
