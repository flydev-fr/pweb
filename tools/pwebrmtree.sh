#!/usr/bin/env bash
#
# THE ONE GUARDED RECURSIVE DELETE for the Linux and shared POSIX scripts.
# SOURCED, never executed:
#
#     . "$(dirname -- "${BASH_SOURCE[0]}")/pwebrmtree.sh"
#     pweb_rm_tree "${work}" "${repo_root}/build"
#
# WHAT IT REPLACES, and why the ledger asked for it (deferred-work 7M0-6).
# Seven sites across `test/cap7l/*.sh` and `tools/build-webview-so.sh` opened
# by deleting a directory tree with a bare `rm -rf -- "${var}"`. Nothing
# validated the target first, so an empty variable turned
# `rm -rf -- "${work}/abi"` into `rm -rf -- /abi`. They were not wired to
# misfire - `set -euo pipefail` plus a `repo_root="$(cd -- … && pwd)"` aborts
# the assignment if the cd fails - but that is an argument that an accident is
# unlikely rather than impossible, in scripts CI executes as programs.
#
# THE RULE IS LIFTED, NOT INVENTED. `cap7m_rm_tree` in
# `test/cap7m/cap7m_common.sh` is the shape CAP-7M0 measured and ratified, and
# every refusal below is that function's, in its order. Two changes, both
# narrowing:
#
#   - THE ALLOWED ROOT IS REQUIRED. `cap7m_rm_tree` defaults it to
#     `${repo_root}/build` via `${2-…}`, which is correct and subtle: `:-`
#     would treat an explicitly empty root as unset and silently substitute
#     the default. With six call sites rather than one, a root that every
#     caller must NAME is simpler than a default every reader has to know, and
#     it removes the subtlety instead of documenting it.
#   - IT DOES NOT REQUIRE THE CALLER'S `die`. It uses one if the caller
#     defined it and otherwise prints and exits, so a script can source this
#     before its own preamble without the failure mode being a missing
#     function at the moment something is about to be deleted.
#
# WHERE THE macOS FAMILY STANDS. `test/cap7m/cap7m_common.sh` and
# `tools/build-webview-dylib.sh` carry the same rule twice, deliberately -
# CAP-7M0 duplicated it self-contained so that a build tool does not depend on
# the test tree, which is the very gap this file closes on the `tools/` side.
# Retiring those two into this one is the obvious next move and is NOT taken
# here: both are macOS-only, this development host cannot run either, and a
# consolidation nobody can execute before pushing is how a green tree becomes
# four red legs. It wants a macOS run of its own.
#
# THE REFUSALS, in order: an empty target; an empty or missing allowed root;
# `/`; a `..` PATH COMPONENT; an unusable basename; a target whose parent does
# not resolve; an allowed root that does not resolve; a target outside the
# allowed root; and the allowed root itself.
#
# Two details that are easy to get wrong, and the reason this is one function
# rather than an inline test at each site:
#
#   - the `..` test matches `*/../*` against a SLASH-PADDED copy, not `*..*`
#     against the bare string, so `report..old` is a legitimate filename while
#     `build/../etc` is refused;
#   - every comparison is on `pwd -P` output, and the prefix strip is LITERAL
#     and trailing-slashed on both sides, so `/x/buildkit` can never pass as
#     inside `/x/build`.

pweb_rmtree_die() {
    if command -v die >/dev/null 2>&1; then
        die "$*"
    else
        printf '[pweb_rm_tree] %s\n' "$*" >&2
        exit 1
    fi
}

pweb_rm_tree() {
    local target="${1:-}"
    # `${2-}` and NOT `${2:-}`: an explicitly passed empty root must die rather
    # than fall through to anything, and a missing one must die too. There is
    # no default to fall back to, which is the whole point.
    local allowed_root="${2-}"
    local padded parent base resolved resolved_root root_slash target_slash

    [ -n "${target}" ] ||
        pweb_rmtree_die 'refusing to delete: empty target path'
    [ -n "${allowed_root}" ] ||
        pweb_rmtree_die "refusing to delete '${target}': no allowed root was named"
    [ "${target}" != '/' ] || pweb_rmtree_die 'refusing to delete: /'

    padded="/${target}/"
    case "${padded}" in
        */../*) pweb_rmtree_die "refusing to delete: '..' path component in '${target}'" ;;
    esac

    # The target may legitimately not exist yet, so resolve its PARENT and
    # re-append the basename rather than requiring the target itself.
    base="$(basename -- "${target}")"
    case "${base}" in
        ''|'.'|'..'|'/')
            pweb_rmtree_die "refusing to delete: unusable basename in '${target}'" ;;
    esac
    parent="$(cd -- "$(dirname -- "${target}")" 2>/dev/null && pwd -P)" ||
        pweb_rmtree_die "refusing to delete '${target}': its parent does not resolve"
    [ -n "${parent}" ] ||
        pweb_rmtree_die "refusing to delete '${target}': its parent does not resolve"
    resolved="${parent%/}/${base}"

    resolved_root="$(cd -- "${allowed_root}" 2>/dev/null && pwd -P)" ||
        pweb_rmtree_die "refusing to delete '${target}': allowed root '${allowed_root}' does not resolve"
    [ -n "${resolved_root}" ] ||
        pweb_rmtree_die "refusing to delete '${target}': allowed root '${allowed_root}' does not resolve"

    root_slash="${resolved_root%/}/"
    target_slash="${resolved}/"
    [ "${target_slash#"${root_slash}"}" != "${target_slash}" ] ||
        pweb_rmtree_die "refusing to delete '${resolved}': outside '${resolved_root}'"
    [ "${resolved}" != "${resolved_root%/}" ] ||
        pweb_rmtree_die "refusing to delete the allowed root itself: '${resolved}'"

    rm -rf -- "${resolved}"
}
