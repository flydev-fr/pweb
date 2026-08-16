#!/usr/bin/env bash
#
# CAP-7M0: the per-architecture headline facts, written to the run summary.
#
# Checkpoint 1 needs exactly a dozen numbers from each of two jobs. Without
# this they are only in an artifact, so rendering the verdict means
# downloading two zips and diffing them by hand - at which point the
# measurement that the shard exists to produce is harder to read than it is
# to take. Everything here is extracted from build/cap7m/measurements.txt and
# the probe log; nothing is recomputed, and nothing is inferred.
#
# Runs with `if: always()`, so it must be robust to a job that failed early
# and produced only some of these. A missing fact is reported as missing.
#
# Usage: test/cap7m/summarize_cap7m.sh
#
set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

measurements='build/cap7m/measurements.txt'
probe_log='build/cap7m/probe/probe.log'
out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# last value of a key=... field across the record, or a placeholder
field() {
    local file="$1" pattern="$2" key="$3" v=''
    [ -f "${file}" ] || { printf '_not recorded_'; return; }
    v="$(grep -h "${pattern}" "${file}" 2>/dev/null |
        sed -n "s/.*[[:space:]]${key}=\\([^[:space:]]*\\).*/\\1/p" |
        tail -n 1)"
    [ -n "${v}" ] && printf '%s' "${v}" || printf '_not recorded_'
}

arch="$(uname -m 2>/dev/null || printf 'unknown')"

{
    printf '## CAP-7M0 macOS feasibility - %s\n\n' "${arch}"
    printf '| Fact | Value |\n|---|---|\n'
    printf '| runner label | `%s` |\n' "${CAP7M_RUNNER_LABEL:-<unset>}"
    printf '| uname -m | `%s` (expected `%s`) |\n' \
        "${arch}" "${CAP7M_EXPECT_ARCH:-<unset>}"
    printf '| macOS | %s (%s) |\n' \
        "$(field "${measurements}" 'CAP7M_ENV' sw_vers)" \
        "$(field "${measurements}" 'CAP7M_ENV' build)"
    printf '| Xcode (pinned selection) | %s |\n' \
        "$(field "${measurements}" 'CAP7M_XCODE' pinned_candidate)"
    printf '| DEVELOPER_DIR | `%s` |\n' \
        "$(field "${measurements}" 'CAP7M_ENV' developer_dir)"
    printf '| SDK | %s |\n' "$(field "${measurements}" 'CAP7M_SDK' version)"
    printf '| FPC | %s |\n' "$(field "${measurements}" 'CAP7M_ENV' fpc)"
    printf '| deployment target / minos | %s / %s |\n' \
        "$(field "${measurements}" 'CAP7M_DEPLOYMENT_TARGET' pinned)" \
        "$(field "${measurements}" 'CAP7M_DEPLOYMENT_TARGET' minos)"
    printf '| webview pin (lock = checkout) | `%s` |\n' \
        "$(field "${measurements}" 'CAP7M_PIN' lock)"
    printf '| exports (trie) | %s |\n' \
        "$(field "${measurements}" 'CAP7M_M2 ' export_trie)"
    printf '| install name | `%s` |\n' \
        "$(grep -h '^CAP7M_INSTALL_NAME' "${measurements}" 2>/dev/null |
            tail -n 1 | sed 's/^CAP7M_INSTALL_NAME //' || printf '_not recorded_')"
    printf '\n### Seam and origin\n\n'
    printf '| Measurement | Value |\n|---|---|\n'
    printf '| M10 pre-create seam ran | %s |\n' \
        "$(field "${probe_log}" 'CAP7M_M10' precreate_seam_ran)"
    printf '| M9 seam A effective | %s (postcreate_hits=%s) |\n' \
        "$(field "${probe_log}" 'CAP7M_M9 cycle=[0-9]* postcreate_hits' seam_a_effective)" \
        "$(field "${probe_log}" 'CAP7M_M9 cycle=[0-9]* postcreate_hits' postcreate_hits)"
    printf '| M14 body ownership | %s |\n' \
        "$(field "${probe_log}" 'CAP7M_M14' ownership)"
    printf '| M13 post-stop callback throws | %s |\n' \
        "$(field "${probe_log}" 'CAP7M_M13' poststop_throws)"
    printf '| M13 abort delivered | %s |\n' \
        "$(field "${probe_log}" 'CAP7M_M13' abort_delivered)"
    printf '| M6 leak growth / budget (KiB) | %s / %s |\n' \
        "$(field "${probe_log}" 'CAP7M_M6_LEAK' growth_kb)" \
        "$(field "${probe_log}" 'CAP7M_M6_LEAK' budget_kb)"

    printf '\n### M15 secure origin, as stated by the page\n\n'
    if [ -f "${probe_log}" ] && grep -q '^CAP7M_REPORT ' "${probe_log}"; then
        printf '| Field | Value |\n|---|---|\n'
        report="$(grep -m1 '^CAP7M_REPORT ' "${probe_log}")"
        for key in protocol host origin secure; do
            v="$(printf '%s' "${report}" |
                sed -n "s/.*\"${key}\":\\(\"[^\"]*\"\\|true\\|false\\).*/\\1/p")"
            printf '| `%s` | `%s` |\n' "${key}" "${v:-_not reported_}"
        done
    else
        printf '_the page never reported_\n'
    fi

    # CAP-7M2: the release facts must reach the step summary, not only the
    # artifact - Checkpoint reads the verdicts here, per frontend.
    printf '\n### CAP-7M2 release .app products\n\n'
    if [ -f "${measurements}" ] && grep -q '^CAP7M2' "${measurements}"; then
        printf '| Product | direct / warm / LS | listeners (cold+warm samples) | inventory sha256 | plist sha256 | codesign (exe) |\n'
        printf '|---|---|---|---|---|---|\n'
        for fe in react pas2js; do
            printf '| %s | %s / %s / %s | %s (%s+%s) | `%s` | `%s` | %s (verify=%s) |\n' \
                "${fe}" \
                "$(field "${measurements}" "^CAP7M2 product=${fe} " direct)" \
                "$(field "${measurements}" "^CAP7M2 product=${fe} " warm)" \
                "$(field "${measurements}" "^CAP7M2 product=${fe} " ls)" \
                "$(field "${measurements}" "^CAP7M2 product=${fe} " listeners)" \
                "$(field "${measurements}" "^CAP7M2 product=${fe} " samples_cold)" \
                "$(field "${measurements}" "^CAP7M2 product=${fe} " samples_warm)" \
                "$(field "${measurements}" "^CAP7M2_HASHES product=${fe} " inventory)" \
                "$(field "${measurements}" "^CAP7M2_HASHES product=${fe} " plist_semantic)" \
                "$(field "${measurements}" "^CAP7M2_CODESIGN product=${fe} role=exe " codesign_state)" \
                "$(field "${measurements}" "^CAP7M2_CODESIGN product=${fe} role=exe " codesign_verify)"
        done
        printf '\n| Fact | Value |\n|---|---|\n'
        printf '| host parity (exe / dylib identical) | %s / %s |\n' \
            "$(field "${measurements}" '^CAP7M2_PARITY ' exe_identical)" \
            "$(field "${measurements}" '^CAP7M2_PARITY ' dylib_identical)"
        printf '| refusal matrix (missing/truncated/garbage/hidden dylib/bad arg) | %s/%s/%s/%s/%s |\n' \
            "$(field "${measurements}" '^CAP7M2_REFUSALS ' missing)" \
            "$(field "${measurements}" '^CAP7M2_REFUSALS ' truncated)" \
            "$(field "${measurements}" '^CAP7M2_REFUSALS ' garbage)" \
            "$(field "${measurements}" '^CAP7M2_REFUSALS ' hidden_dylib)" \
            "$(field "${measurements}" '^CAP7M2_REFUSALS ' bad_arg)"
        printf '| argv autoclose beats env (react / pas2js, elapsed s) | %s (%ss) / %s (%ss) |\n' \
            "$(field "${measurements}" '^CAP7M2_AUTOCLOSE product=react ' argv_wins)" \
            "$(field "${measurements}" '^CAP7M2_AUTOCLOSE product=react ' elapsed_s)" \
            "$(field "${measurements}" '^CAP7M2_AUTOCLOSE product=pas2js ' argv_wins)" \
            "$(field "${measurements}" '^CAP7M2_AUTOCLOSE product=pas2js ' elapsed_s)"
        printf '| app.pwb determinism (react / pas2js) | %s / %s |\n' \
            "$(field "${measurements}" '^CAP7M2_DETERMINISM product=react ' rebuild_identical)" \
            "$(field "${measurements}" '^CAP7M2_DETERMINISM product=pas2js ' rebuild_identical)"
    else
        printf '_no CAP-7M2 release measurements recorded_\n'
    fi
} >> "${out}"

printf '[CAP-7M0] headline facts written to %s\n' "${out}"
