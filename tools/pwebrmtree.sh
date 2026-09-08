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
# `/`; a `..` PATH COMPONENT; an unusable basename; an allowed root that does
# not resolve; a target outside the allowed root; and the allowed root itself.
# An ABSENT target is not among them - it is a no-op, because every caller
# deletes and immediately recreates, and on a fresh checkout there is nothing
# there yet. See the comment at that early return; it cost a hosted Linux leg.
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

    base="$(basename -- "${target}")"
    case "${base}" in
        ''|'.'|'..'|'/')
            pweb_rmtree_die "refusing to delete: unusable basename in '${target}'" ;;
    esac

    # THERE IS NOTHING TO DELETE, AND THAT IS NOT A REFUSAL. Every caller here
    # deletes a tree and immediately recreates it, so on a fresh checkout the
    # target is routinely absent - and so is its PARENT, because `build/cap7l`
    # is itself made by the step that is about to run. Resolving the parent
    # before establishing that there is any work to do turned the first hosted
    # Linux leg red with `refusing to delete
    # '.../build/cap7l/webview-build': its parent does not resolve`, on a
    # target that did not exist.
    #
    # It went unseen locally for the reason this repository already has a name
    # for: the dev host had `build/cap7l` from earlier runs, so the harness was
    # more generous than the one under test. The shape refusals above are all
    # string-level and still apply; returning here cannot delete the wrong
    # thing, because it deletes nothing.
    if [ ! -e "${target}" ] && [ ! -L "${target}" ]; then
        return 0
    fi

    # The target exists, so its parent must resolve. This branch is therefore
    # unreachable except by a race - the parent removed between the test above
    # and the `cd` - and it is kept for that race rather than removed as dead.
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
