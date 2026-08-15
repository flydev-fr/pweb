#!/usr/bin/env bash
#
# CAP-7M0 shared gate preamble. SOURCED, never executed:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/cap7m_common.sh"
#
# CAP-7L kept every gate self-contained, and on Linux that cost nothing. Here
# it would: the spec requires EVERY macOS gate to assert `uname -m` and
# `fpc -iTP` and to record its environment before it accepts a result, and an
# assertion copied into seven scripts is an assertion that will eventually
# differ in one of them.
#
# Provides: die, step, lock_get, fpc_lock_get, assert_native_arch,
#           assert_fpc_target, record_environment, record_measurement,
#           and the standard paths.
#
# It is committed executable like every other *.sh in this repository (the
# Linux job asserts the index mode of all of them), even though it is only
# ever sourced.

# shellcheck shell=bash

cap7m_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${cap7m_script_dir}/../.." && pwd)"

lock_file="${repo_root}/webview.lock"
fpc_lock_file="${repo_root}/fpc.lock"
dist="${repo_root}/build/cap7m/webview-dist"
work="${repo_root}/build/cap7m"

# THE measurement record. This shard's deliverable is a set of measurements,
# so they go to a file that is uploaded whether the job passes or fails -
# stdout alone is lost the moment the log rotates. It deliberately lives at
# the root of build/cap7m/: every gate wipes its own subdirectory, and a
# record that gets deleted by the next gate is not a record.
measurements="${work}/measurements.txt"

die() { printf '[CAP-7M0] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7M0] === %s\n' "$*"; }

# The gate currently running, used to tag its block in the record.
cap7m_gate="$(basename -- "${0:-cap7m}")"

record_measurement() {
    mkdir -p -- "${work}"
    printf '%s\n' "$*" >> "${measurements}"
    printf '%s\n' "$*"
}

# strict 'key = value' reader, identical in behaviour to the one in
# tools/build-webview-dylib.sh and tools/build-webview-so.sh
_lock_get() {
    local file="$1" wanted="$2" line key value found='' result=''
    [ -f "${file}" ] || die "lock file missing: ${file}"
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        case "${line}" in '#'*) continue ;; esac
        case "${line}" in *=*) ;; *) die "$(basename "${file}") line is malformed: ${line}" ;; esac
        key="$(printf '%s' "${line%%=*}" | sed -e 's/[[:space:]]*$//')"
        value="$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//')"
        if [ "${key}" = "${wanted}" ]; then
            [ -n "${found}" ] && die "$(basename "${file}") contains duplicate key '${wanted}'"
            found=1
            result="${value}"
        fi
    done < "${file}"
    [ -n "${found}" ] || die "$(basename "${file}") has no '${wanted}' entry"
    printf '%s' "${result}"
}

lock_get() { _lock_get "${lock_file}" "$1"; }
fpc_lock_get() { _lock_get "${fpc_lock_file}" "$1"; }

# --- the anti-Rosetta gate (M19) ---------------------------------------------
# A Rosetta-hosted execution is never authoritative x64 proof: it reports
# x86_64 from `uname -m` quite honestly while running on Apple Silicon. Three
# facts settle it, and every gate asserts them before it accepts a result.
assert_native_arch() {
    [ "$(uname -s)" = 'Darwin' ] || die "macOS only, host is $(uname -s)"

    host_arch="$(uname -m)"
    arch_x64="$(lock_get macos-arch-x64)"
    arch_arm64="$(lock_get macos-arch-arm64)"
    case "${host_arch}" in
        "${arch_x64}"|"${arch_arm64}") ;;
        *) die "unsupported host architecture '${host_arch}'" ;;
    esac

    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0')" = '1' ]; then
        die 'running under Rosetta -- a translated run is never authoritative'
    fi
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = '1' ] &&
       [ "${host_arch}" != "${arch_arm64}" ]; then
        die "host is Apple Silicon but uname -m says ${host_arch} -- translated shell"
    fi

    # If the caller named an expected architecture, it must be THIS one. A job
    # that thinks it is the x64 leg while running somewhere else is precisely
    # the failure that would otherwise be reported as parity.
    if [ -n "${1:-}" ] && [ "$1" != "${host_arch}" ]; then
        die "job expects ${1} but this host is ${host_arch}"
    fi
    printf '[CAP-7M0] native arch: %s (not translated)\n' "${host_arch}"
}

# --- FPC must be the PINNED version and target the SAME architecture ---------
# The version comes from fpc.lock, never from a list written here:
# tools/get-fpc-macos.ps1 demands exact equality with that key, so a hardcoded
# `3.2.2|3.2.3` here could accept a compiler the installer refuses to produce
# and the two halves of the pin would disagree in silence.
assert_fpc_target() {
    command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
    local v want os cpu arch
    want="$(fpc_lock_get version)"
    v="$(fpc -iV | tr -d '[:space:]')"
    [ "${v}" = "${want}" ] ||
        die "fpc reports ${v}, fpc.lock pins ${want}"
    os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    cpu="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ "${os}" = 'darwin' ] || die "expected FPC target darwin, got ${os}"
    # FPC spells the architectures its own way; map to the lock's names
    case "${cpu}" in
        x86_64) arch="$(lock_get macos-arch-x64)" ;;
        aarch64) arch="$(lock_get macos-arch-arm64)" ;;
        *) die "unsupported FPC target CPU ${cpu}" ;;
    esac
    [ "${arch}" = "$(uname -m)" ] ||
        die "fpc targets ${cpu} (${arch}) but the host is $(uname -m)"
    printf '[CAP-7M0] fpc %s targeting %s/%s\n' "${v}" "${os}" "${cpu}"
}

# --- M19: record the environment BEFORE any gate is accepted -----------------
# Called by EVERY gate, not just the probe driver: "recorded before any gate
# is accepted" is not satisfied by recording it after the dylib build, the
# export gate and the ABI gate have already been believed. Idempotent within
# a process; each gate contributes its own tagged block, which is what makes
# it possible to tell afterwards which toolchain a given result came from.
record_environment() {
    if [ -n "${CAP7M_ENV_RECORDED:-}" ]; then
        return 0
    fi
    CAP7M_ENV_RECORDED=1

    step "runner environment for ${cap7m_gate} (recorded before any gate is accepted)"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} uname_m=$(uname -m) uname_r=$(uname -r)"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} sw_vers=$(sw_vers -productVersion) build=$(sw_vers -buildVersion)"
    # The SELECTED toolchain, not the image default. tools/get-fpc-macos.ps1
    # exports DEVELOPER_DIR from the pinned candidate list, and the whole
    # point of that pin is lost if the record shows what the image shipped
    # with instead of what the compiler actually ran under.
    record_measurement "CAP7M_ENV gate=${cap7m_gate} developer_dir=${DEVELOPER_DIR:-<unset>}"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} sdk_version=$(xcrun --show-sdk-version 2>/dev/null)"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} sdk_path=$(xcrun --show-sdk-path 2>/dev/null)"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} clang=$(clang --version 2>/dev/null | head -n 1)"
    if command -v fpc >/dev/null 2>&1; then
        record_measurement "CAP7M_ENV gate=${cap7m_gate} fpc=$(fpc -iV) target=$(fpc -iTO)/$(fpc -iTP)"
    else
        record_measurement "CAP7M_ENV gate=${cap7m_gate} fpc=<absent>"
    fi
    record_measurement "CAP7M_ENV gate=${cap7m_gate} deployment_target=$(lock_get macos-deployment-target)"
    record_measurement "CAP7M_ENV gate=${cap7m_gate} webview_pin=$(lock_get commit)"
}
