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
# CAP-7M1 moved every macOS COMPILE AND LINK DECISION out of here (and out of
# the gates) into tools/macos-buildenv.sh, which this file sources. What is
# left here is gate POLICY - the anti-Rosetta assertions, the pinned-FPC
# assertion, the environment record, the working-directory refusal and the
# deletion guard. The split is deliberate and load-bearing: a BUILD tool must
# be able to reach the flags without depending on the test tree.
#
# It is committed executable like every other *.sh in this repository (the
# Linux job asserts the index mode of all of them), even though it is only
# ever sourced.

# shellcheck shell=bash

cap7m_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${cap7m_script_dir}/../.." && pwd)"

# shellcheck source=tools/macos-buildenv.sh
. "${repo_root}/tools/macos-buildenv.sh"

lock_file="${repo_root}/webview.lock"
fpc_lock_file="${repo_root}/fpc.lock"
work="${repo_root}/build/cap7m"

# Resolved once, at source time, so every gate sees the same values whether or
# not it has reached its own assert_native_arch yet. The staged-artifact path
# is the helper's, never a second spelling of it.
pweb_macos_init
dist="${PWEB_MACOS_DIST}"

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

# Delegates to tools/macos-buildenv.sh so the build tool and the gates append
# to the record exactly one way (the same argument that moved the lock reader
# there). The name is kept because every gate already calls it.
record_measurement() {
    pweb_macos_record "$*"
}

# --- working directories: ASSERT EMPTY, do not wipe --------------------------
#
# THE DEFAULT PATH OF THESE GATES DELETES NOTHING.
#
# The `rm -rf` these scripts used to open with bought nothing on CI, which
# checks out fresh every time; it existed only to make repeated LOCAL runs
# convenient, and it paid for that convenience by putting a recursive delete on
# the default path of a script CI executes as a program. A stale tree is now a
# LOUD REFUSAL instead of a choice between a silently stale measurement and a
# destructive cleanup.
#
#   absent            -> create it, proceed
#   present, empty    -> proceed
#   present, non-empty-> refuse, naming the directory, unless --clean
#
# --clean is opt-in, per invocation, and is the ONLY way anything is removed.
# Even then the removal goes through cap7m_rm_tree below.
cap7m_prepare_dir() {
    local dir="${1:-}"
    [ -n "${dir}" ] || die 'cap7m_prepare_dir: empty directory argument'

    if [ ! -e "${dir}" ]; then
        mkdir -p -- "${dir}"
        return 0
    fi
    [ -d "${dir}" ] || die "expected a directory but found a file: ${dir}"
    if [ -z "$(ls -A -- "${dir}" 2>/dev/null)" ]; then
        return 0
    fi

    if [ "${CAP7M_CLEAN:-0}" = '1' ]; then
        printf '[CAP-7M0] --clean: removing stale %s\n' "${dir}"
        cap7m_rm_tree "${dir}"
        mkdir -p -- "${dir}"
        return 0
    fi

    printf '[CAP-7M0] %s already exists and is not empty.\n' "${dir}" >&2
    printf '[CAP-7M0] Re-using it would let this gate report the PREVIOUS run.\n' >&2
    printf '[CAP-7M0] Re-run with --clean, or remove the directory yourself.\n' >&2
    die "refusing to reuse a non-empty working directory: ${dir}"
}

# Tiny, shared argument convention. Each gate keeps its own positional
# arguments; this only lifts --clean out of them.
#
#   eval "$(cap7m_take_clean_flag "$@")"
#
# sets CAP7M_CLEAN and replaces "$@" with the remaining arguments.
cap7m_take_clean_flag() {
    local arg clean=0
    printf 'set --'
    for arg in "$@"; do
        case "${arg}" in
            --clean) clean=1 ;;
            *) printf ' %q' "${arg}" ;;
        esac
    done
    printf '\nCAP7M_CLEAN=%s\n' "${clean}"
}

# --- the ONE deletion guard --------------------------------------------------
#
# Reached only by `--clean` and by the mktemp staging trap in
# check_release_layout.sh. It is the last line of defence, not the first: the
# first is that nothing above deletes at all.
#
#   cap7m_rm_tree <target> [allowed_root]   allowed_root: ${repo_root}/build
#
# Refuses, in this order: an empty target or allowed root; `/`; a `..` PATH
# COMPONENT; a target whose parent does not resolve; an unusable basename; a
# target outside the allowed root; and the allowed root itself.
#
# Two details that are easy to get wrong, and the reason this is one function
# rather than an inline test at each site:
#
#   - the `..` test matches `*/../*` against a SLASH-PADDED copy, not `*..*`
#     against the bare string, so `report..old` is a legitimate filename while
#     `build/../etc` is refused;
#   - every comparison is on `pwd -P` output. The runner's /tmp is a symlink
#     to /private/tmp, so an unresolved comparison would reject a staging
#     directory that really is inside its allowed root.
cap7m_rm_tree() {
    local target="${1:-}"
    # `${2-…}` and NOT `${2:-…}`, deliberately: `:-` treats an explicitly
    # passed EMPTY string as "unset" and silently substitutes the default, so
    # `cap7m_rm_tree "$x" "$root"` with an empty $root would quietly fall back
    # to ${repo_root}/build instead of failing. Omitted means default;
    # explicitly empty means die, which is what the caller meant to be told.
    local allowed_root="${2-${repo_root}/build}"
    local padded parent base resolved resolved_root root_slash target_slash

    [ -n "${target}" ] || die 'refusing to delete: empty target path'
    [ -n "${allowed_root}" ] || die 'refusing to delete: empty allowed root'
    [ "${target}" != '/' ] || die 'refusing to delete: /'

    padded="/${target}/"
    case "${padded}" in
        */../*) die "refusing to delete: '..' path component in '${target}'" ;;
    esac

    # The target may legitimately not exist yet, so resolve its PARENT and
    # re-append the basename rather than requiring the target itself.
    base="$(basename -- "${target}")"
    case "${base}" in
        ''|'.'|'..'|'/')
            die "refusing to delete: unusable basename in '${target}'" ;;
    esac
    parent="$(cd -- "$(dirname -- "${target}")" 2>/dev/null && pwd -P)" ||
        die "refusing to delete '${target}': its parent does not resolve"
    [ -n "${parent}" ] ||
        die "refusing to delete '${target}': its parent does not resolve"
    resolved="${parent%/}/${base}"

    resolved_root="$(cd -- "${allowed_root}" 2>/dev/null && pwd -P)" ||
        die "refusing to delete '${target}': allowed root '${allowed_root}' does not resolve"
    [ -n "${resolved_root}" ] ||
        die "refusing to delete '${target}': allowed root '${allowed_root}' does not resolve"

    # Trailing slash on BOTH sides, and a LITERAL (unglobbed) prefix strip, so
    # /x/buildkit can never pass as inside /x/build.
    root_slash="${resolved_root%/}/"
    target_slash="${resolved}/"
    [ "${target_slash#"${root_slash}"}" != "${target_slash}" ] ||
        die "refusing to delete '${resolved}': outside '${resolved_root}'"
    [ "${resolved}" != "${resolved_root%/}" ] ||
        die "refusing to delete the allowed root itself: '${resolved}'"

    rm -rf -- "${resolved}"
}

# The strict 'key = value' reader now lives in tools/macos-buildenv.sh, so the
# build tool and the gates read a lock exactly one way. These two names are
# kept because every gate already uses them.
lock_get() { pweb_macos_lock_read "${lock_file}" "$1"; }
fpc_lock_get() { pweb_macos_lock_read "${fpc_lock_file}" "$1"; }

# --- the anti-Rosetta gate (M19) ---------------------------------------------
# A Rosetta-hosted execution is never authoritative x64 proof: it reports
# x86_64 from `uname -m` quite honestly while running on Apple Silicon. Three
# facts settle it, and every gate asserts them before it accepts a result.
#
# The Darwin check, the supported-architecture set and the caller's expected
# architecture are pweb_macos_init's job (one place for every architecture
# decision); the two sysctl assertions are gate POLICY and stay here.
assert_native_arch() {
    pweb_macos_init "${1:-}"
    host_arch="${PWEB_MACOS_HOST_ARCH}"
    arch_x64="${PWEB_MACOS_ARCH_X64}"
    arch_arm64="${PWEB_MACOS_ARCH_ARM64}"

    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0')" = '1' ]; then
        die 'running under Rosetta -- a translated run is never authoritative'
    fi
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = '1' ] &&
       [ "${host_arch}" != "${arch_arm64}" ]; then
        die "host is Apple Silicon but uname -m says ${host_arch} -- translated shell"
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
    local v want os arch
    want="$(fpc_lock_get version)"
    v="$(fpc -iV | tr -d '[:space:]')"
    [ "${v}" = "${want}" ] ||
        die "fpc reports ${v}, fpc.lock pins ${want}"
    os="$(fpc -iTO | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ "${os}" = 'darwin' ] || die "expected FPC target darwin, got ${os}"
    # The FPC-CPU -> lock-architecture map and the mORMot static directory it
    # implies existed TWICE before CAP-7M1. Both now come from one place, and
    # this is also where every FPC compile/link flag array is resolved.
    pweb_macos_init_fpc
    case "${PWEB_MACOS_FPC_CPU}" in
        x86_64) arch="${PWEB_MACOS_ARCH_X64}" ;;
        aarch64) arch="${PWEB_MACOS_ARCH_ARM64}" ;;
        *) die "unsupported FPC target CPU ${PWEB_MACOS_FPC_CPU}" ;;
    esac
    [ "${arch}" = "${PWEB_MACOS_HOST_ARCH}" ] ||
        die "fpc targets ${PWEB_MACOS_FPC_CPU} (${arch}) but the host is ${PWEB_MACOS_HOST_ARCH}"
    printf '[CAP-7M0] fpc %s targeting %s/%s\n' "${v}" "${os}" \
        "${PWEB_MACOS_FPC_CPU}"
}

# --- the aarch64-only Pascal link flag ---------------------------------------
#
# DELETED here, not renamed. It MOVED to tools/macos-buildenv.sh, which now
# folds -k-no_fixup_chains into every FPC link array it exports and ASSERTS
# on aarch64 that all four carry it.
#
# The forwarding shim this file briefly carried (CAP7M_FPC_ARCH_LINK_FLAGS +
# set_fpc_arch_link_flags) is exactly why its absence from those arrays looked
# wired: every gate still called the setter, so the variable was populated and
# reached nothing but a non-fatal `fpc -va` diagnostic. A name that is still
# there is indistinguishable from a name that still works. There is no
# replacement to call - the flag arrives with the link set.
#
# The MEASURED rationale (run 31904189177: FPC 3.2.2 emits
# FPC_THREADVARTABLES 4-byte aligned, ld_prime's chained fixups need 8 on
# arm64, -WM11.0 the remedy deliberately NOT taken) lives with the flag.

# --- the ratified canonical URI vector count ---------------------------------
# ONE source for both gates that compare against test/cap7m/uri_vectors.txt
# (run_cap7m_probes.sh and run_cap7m_runtime.sh). Changing the vector list is
# a deliberate act that updates this number in the same commit; two copies of
# a ratified count is a second place for one of them to be forgotten.
CAP7M_RATIFIED_VECTORS=44

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
