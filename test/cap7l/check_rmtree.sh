#!/usr/bin/env bash
#
# THE DELETION GUARD'S NEGATIVE SELF-TEST (deferred-work 7M0-6).
#
# `tools/pwebrmtree.sh` exists because seven sites opened by deleting a tree
# with a bare `rm -rf -- "${var}"` and nothing checked the variable first. A
# guard whose refusals nobody has watched fire is the same class of assurance
# as the argument those sites rested on - that an accident is unlikely - so
# each refusal is driven here, against a real filesystem, and the two ACCEPT
# cases are driven too: a guard that refused everything would pass a test that
# only ever asked it to refuse.
#
# It also sweeps the six scripts it protects and requires that none of them has
# grown a bare `rm -rf` back, because the fix and the rule that keeps it are
# two different things.
#
# Checkout-only: no toolchain, no network, no display.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

pass=0
fail=0
ok()   { printf '  refused  %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  ACCEPTED %s\n' "$*"; fail=$((fail + 1)); }
okd()  { printf '  deleted  %s\n' "$*"; pass=$((pass + 1)); }
badd() { printf '  KEPT     %s\n' "$*"; fail=$((fail + 1)); }

# The guard calls `exit 1` on a refusal (or the caller's `die`), so every
# refusal leg runs it in a SUBSHELL and reads the status. A leg that ran it in
# this shell would end the self-test at its first success.
guard() (
    # shellcheck source=tools/pwebrmtree.sh
    . "${repo_root}/tools/pwebrmtree.sh"
    pweb_rm_tree "$@" >/dev/null 2>&1
)

sandbox="${repo_root}/build/cap7l/rmtree-selftest"
rm -rf -- "${sandbox}" 2>/dev/null || true
mkdir -p -- "${sandbox}/allowed/tree" "${sandbox}/outside/tree" "${sandbox}/buildkit"
: > "${sandbox}/allowed/tree/marker"
: > "${sandbox}/outside/tree/marker"
: > "${sandbox}/buildkit/marker"
trap 'rm -rf -- "${sandbox}" 2>/dev/null || true' EXIT

root="${sandbox}/allowed"

printf '[CAP-7L] the deletion guard: refusals\n'

guard '' "${root}"                        && bad 'an empty target'            || ok 'an empty target'
guard "${root}/tree"                      && bad 'a missing allowed root'     || ok 'a missing allowed root'
guard "${root}/tree" ''                   && bad 'an explicitly empty root'   || ok 'an explicitly empty root'
guard '/' "${root}"                       && bad 'the filesystem root'        || ok 'the filesystem root'
guard "${root}/../outside/tree" "${root}" && bad "a '..' path component"      || ok "a '..' path component"
guard "${sandbox}/outside/tree" "${root}" && bad 'a target outside the root'  || ok 'a target outside the root'
guard "${root}" "${root}"                 && bad 'the allowed root itself'    || ok 'the allowed root itself'
guard "${root}/." "${root}"               && bad 'an unusable basename'       || ok 'an unusable basename'
guard "${root}/nope/deeper" "${root}"     && bad 'an unresolvable parent'     || ok 'an unresolvable parent'
# A LITERAL prefix strip, not a string prefix: /x/buildkit is not inside /x/build.
guard "${sandbox}/buildkit" "${sandbox}/build" \
                                          && bad 'a sibling sharing a prefix' || ok 'a sibling sharing a prefix'

printf '[CAP-7L] the deletion guard: the deletes it must still perform\n'

guard "${root}/tree" "${root}"
if [ -e "${root}/tree" ]; then badd 'a real target inside the root'; else okd 'a real target inside the root'; fi
# a target that does not exist yet is not an error - every caller deletes then
# recreates, and the first run of a clean checkout has nothing to remove
mkdir -p -- "${root}/tree"
guard "${root}/absent" "${root}"
if [ -e "${root}/absent" ]; then badd 'an absent target is a no-op'; else okd 'an absent target is a no-op'; fi

printf '[CAP-7L] the six protected scripts carry no bare rm -rf\n'
bare=0
for f in test/cap7l/build_cap7l.sh test/cap7l/check_abi.sh \
         test/cap7l/run_cap7l_gates.sh test/cap7l/run_gui_matrix.sh \
         test/cap7l/run_release_layout.sh tools/build-webview-so.sh; do
    [ -f "${f}" ] || { printf '  MISSING  %s\n' "${f}"; fail=$((fail + 1)); continue; }
    # the needle is built by concatenation so this sweep cannot match itself
    hits="$(grep -nE "(^|[^[:alnum:]_])rm[[:space:]]+-""rf" "${f}" || true)"
    if [ -n "${hits}" ]; then
        printf '  BARE     %s: %s\n' "${f}" "${hits}"
        bare=$((bare + 1))
    fi
done
if [ "${bare}" -eq 0 ]; then
    printf '  clean    six scripts, zero bare recursive deletes\n'
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

printf '\n[CAP-7L] deletion guard self-test: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
printf 'CAP7L_RMTREE_PASS legs=%d\n' "${pass}"
