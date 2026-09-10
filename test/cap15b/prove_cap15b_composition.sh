#!/usr/bin/env bash
#
# CAP-15B: THE COMPOSITION, mechanised once.
#
# Everything else this shard gates is a narrower proof: the descriptor
# reader through the production functions, the compiled unit set of two
# witness images, the allowlist digest recomputed from a compiled array, the
# whole request contract through an injected transport. Each is right and
# each runs on all four targets. None of them proves the thing a user does on
# day one:
#
#   pweb create  ->  declare an origin  ->  pweb build  ->  pweb run
#   ->  the page calls that origin through @pweb/runtime
#
# That is the COMPOSITION - that a scaffolded project's `program.lpr` and
# `app.services.pas` compile TOGETHER with the network region on, inside a
# real `pweb build`, and that the door is in the chain of the binary `pweb
# run` supervises. It is mechanised HERE, once, on the Linux leg, because
# breadth is already where it belongs and a fifth copy of it would buy
# nothing (ledger 15B-12).
#
# ---------------------------------------------------------------------------
# WHAT IS GATED, AND WHAT IS RECORDED
# ---------------------------------------------------------------------------
#
# GATED, and hermetic - no public dependency of any kind:
#   the build succeeds and produces a release layout;
#   the running host prints the network digest line, so the region really
#     compiled and the decorator really constructed;
#   the digest the binary recomputes from its compiled array equals the one
#     `pweb.json` declares;
#   the page's `httpFetch` reaches THE DOOR - a typed `service_error`, never
#     `forbidden` (the capability was granted) and never `invalid_request`
#     (the origin matched the compiled allowlist by parsed components);
#   `CalculatorService.Add` still answers 42;
#   the supervised application owns ZERO listening sockets.
#
# RECORDED, never gated: `composition_payload`. Rendering a real payload from
# a RELEASE build needs a reachable `https` origin with a valid chain, which
# means the public internet - and a gate that depended on somebody else's DNS
# is a gate that goes red for their reasons. When the runner has the network,
# the row reads `rendered` and carries the status; when it does not, it reads
# `unreachable` and nothing fails. The door being REACHED is the claim; the
# payload is the corroboration.
#
# Usage: test/cap15b/prove_cap15b_composition.sh   (under xvfb-run -a)
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

work="${repo_root}/build/cap15b/composition"
sdk_root="${repo_root}/build/cap10b1/sdk"
cli="${sdk_root}/bin/pweb"
project="${work}/demo"
rows_file="${work}/rows.tsv"
failures=0

die() { printf '[CAP-15B] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-15B] === %s\n' "$*"; }
row() { printf '%s\t%s\n' "$1" "$2" >> "${rows_file}"; printf '[CAP-15B] %s = %s\n' "$1" "$2"; }
require() {
    if [ "$1" -ne 0 ]; then
        failures=$((failures + 1))
        printf '[CAP-15B] FAIL: %s\n' "$2" >&2
    fi
}

# THE PUBLIC ORIGIN IS ONE PLACE, and it is the only line that would have to
# change if it ever moved. It is declared in the descriptor because a RELEASE
# build accepts `https` and nothing else - the ratified loopback exception
# cannot survive one, which is itself part of what this smoke exercises.
public_origin='https://example.com'
public_host='example.com'
public_path='/'

[ -x "${cli}" ] ||
    die "the CLI is not staged: ${cli} -- test/cap10b1/build_cap10b1.sh runs earlier in this leg"
[ -d "${sdk_root}/share/pweb/src" ] ||
    die "the SDK root is not staged: ${sdk_root}/share/pweb/src"
command -v node >/dev/null 2>&1 || die 'required tool not found: node'
command -v npm >/dev/null 2>&1 || die 'required tool not found: npm'
command -v ss >/dev/null 2>&1 || die 'required tool not found: ss (iproute2)'
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'

# shellcheck source=tools/pwebrmtree.sh
. "${repo_root}/tools/pwebrmtree.sh"
pweb_rm_tree "${work}" "${repo_root}/build"
mkdir -p -- "${work}"
: > "${rows_file}"

# --- 1. create, at schema 2 ------------------------------------------------
step 'pweb create (offline, schema 2)'
# THE DESTINATION IS NAME INSIDE THE WORKING DIRECTORY - there is no
# `--output` in this build and the working directory is read once, at
# startup - so the create runs from `${work}` rather than naming a path
( cd -- "${work}" &&
  "${cli}" create demo --ui react --bundle-id org.pweb.cap15b )     > "${work}/create.log" 2>&1 ||
    { tail -20 "${work}/create.log"; die 'pweb create FAILED'; }
[ -f "${project}/pweb.json" ] || die 'pweb create produced no descriptor'
grep -q '"schema": 2' "${project}/pweb.json" ||
    die 'pweb create did not emit schema 2'
grep -q '"origins": \[\]' "${project}/pweb.json" ||
    die 'pweb create did not emit an EMPTY origin set'
row create_schema '2'
row create_origins_empty 'true'

# --- 2. declare the origin -------------------------------------------------
# ONE line of the descriptor, edited the way a developer edits it. Nothing
# else in the generated project is touched by this step, which is the point:
# opening the door is one visible act in one file.
step 'declare the outbound origin'
tmp="${work}/pweb.json.new"
sed "s|\"origins\": \[\]|\"origins\": [\"${public_origin}\"]|" \
    "${project}/pweb.json" > "${tmp}"
mv -f -- "${tmp}" "${project}/pweb.json"
grep -q "${public_origin}" "${project}/pweb.json" ||
    die 'the origin was not declared'
row declared_origin "${public_origin}"

# --- 3. the page calls it, through @pweb/runtime ---------------------------
# The SHIPPED template does not call the door - a scaffold that fetched a
# remote server on first run would be a scaffold making a decision for its
# author - so this smoke adds the call to ITS OWN copy, exactly as a
# developer would: one import, one await, two fields in the report the page
# already sends home.
step 'teach the generated page to call the door'
app="${project}/frontend/src/App.tsx"
[ -f "${app}" ] || die "the generated project has no App.tsx at ${app}"
tmp="${work}/App.tsx.new"
awk -v origin="${public_origin}${public_path}" '
/^import \{ handshake, invoke, PWebError \} from "@pweb\/runtime";$/ {
    print "import { handshake, httpFetch, invoke, PWebError } from \"@pweb/runtime\";"
    next
}
/^  value: number;$/ {
    print
    print "  net: string;"
    print "  netStatus: number;"
    next
}
/^        value: 0,$/ {
    print
    print "        net: \"unset\","
    print "        netStatus: 0,"
    next
}
/^        const shell = readShell\(\);$/ {
    print "        /* CAP-15B: the native outbound door, through the SDK. */"
    print "        try {"
    print "          const res = await httpFetch({ url: \"" origin "\" });"
    print "          report.net = \"rendered\";"
    print "          report.netStatus = res.status;"
    print "        } catch (netErr) {"
    print "          report.net = netErr instanceof PWebError"
    print "            ? netErr.code"
    print "            : \"unknown\";"
    print "        }"
    print
    next
}
{ print }
' "${app}" > "${tmp}"
mv -f -- "${tmp}" "${app}"
grep -q 'httpFetch' "${app}" || die 'the page was not taught to call the door'
row page_calls_door 'true'

# --- 4. pweb build ---------------------------------------------------------
step 'pweb build'
( cd -- "${project}" && "${cli}" build ) > "${work}/build.log" 2>&1 ||
    { tail -40 "${work}/build.log"; die 'pweb build FAILED'; }
release="${project}/dist/linux-x86_64/release"
[ -x "${release}/demo" ] || die "no release executable at ${release}/demo"
[ -f "${release}/app.pwb" ] || die 'the release layout carries no app.pwb'
row build 'PASS'

# THE DECLARED DIGEST, from the descriptor the build read
declared_digest="$(grep -o '"[0-9a-f]\{64\}"' \
    "${project}/dist/linux-x86_64/gen/app.network.inc" | tr -d '"' | head -n 1)"
[ -n "${declared_digest}" ] ||
    die 'the build generated no allowlist digest'
row generated_include 'present'

# --- 5. pweb run -----------------------------------------------------------
# `pweb run` supervises the release layout, which is the path a user takes.
# The auto-close bound reaches the host through the ENVIRONMENT rather than
# through an argument, because the production template consumes no argument
# of its own and the host refuses every one it does not own.
step 'pweb run'
export PWEB_SMOKE_AUTOCLOSE_MS=25000
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
out_file="${work}/run.log"
( cd -- "${project}" && "${cli}" run ) > "${out_file}" 2>&1 &
run_pid=$!

# the listening-socket sampler watches the APPLICATION, not this script and
# not the CLI supervising it: only sockets that process holds count
listener_max=0
samples=0
app_pid=''
for _ in $(seq 1 60); do
    if [ -z "${app_pid}" ]; then
        app_pid="$(pgrep -f "${release}/demo" | head -n 1 || true)"
    fi
    if [ -n "${app_pid}" ] && [ -d "/proc/${app_pid}" ]; then
        t=$(ss -ltnp 2>/dev/null | grep -c "pid=${app_pid}," || true)
        u=$(ss -lunp 2>/dev/null | grep -c "pid=${app_pid}," || true)
        n=$((t + u))
        samples=$((samples + 1))
        [ "${n}" -gt "${listener_max}" ] && listener_max="${n}"
    fi
    kill -0 "${run_pid}" 2>/dev/null || break
    sleep 0.5
done
wait "${run_pid}" && run_exit=0 || run_exit=$?
row run_exit "${run_exit}"
require "${run_exit}" 'pweb run did not exit cleanly'
row listener_samples "${samples}"
row listener_members "${listener_max}"
[ "${samples}" -gt 0 ] || require 1 'the application was never sampled'
[ "${listener_max}" = '0' ] ||
    require 1 "the supervised application opened ${listener_max} listener(s)"

# --- 6. what the run said --------------------------------------------------
step 'read the composition back'

# THE DIGEST LINE, printed by the generated program from INSIDE its network
# region: it exists only if the region compiled and the decorator really
# constructed, and it carries the digest recomputed from the compiled array
# beside the one the build declared
net_line="$(grep -o 'demo: network [0-9a-f]* [0-9a-f]*' "${out_file}" | tail -n 1 || true)"
if [ -n "${net_line}" ]; then
    recomputed="$(printf '%s' "${net_line}" | awk '{print $3}')"
    compiled="$(printf '%s' "${net_line}" | awk '{print $4}')"
    row composition_region 'compiled'
    row composition_digest_recomputed "${recomputed}"
    row composition_digest_compiled "${compiled}"
    row composition_digest_declared "${declared_digest}"
    [ "${recomputed}" = "${compiled}" ] ||
        require 1 'the recomputed and compiled digests differ'
    [ "${compiled}" = "${declared_digest}" ] ||
        require 1 'the compiled digest differs from the declared one'
else
    row composition_region 'absent'
    require 1 'the running host printed no network digest line -- the region did not compile'
fi

report="$(grep -o 'demo: ready {.*}' "${out_file}" | tail -n 1 |
    sed 's/^demo: ready //' || true)"
[ -n "${report}" ] || { tail -30 "${out_file}"; die 'the application printed no ready report'; }

field() {
    printf '%s' "${report}" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p" |
        tr -d '" ' | head -n 1
}
rpc="$(field rpc)"
value="$(field value)"
net="$(field net)"
net_status="$(field netStatus)"
row rpc_ok "${rpc}"
row rpc_result "${value:-0}"
[ "${rpc}" = 'true' ] || require 1 'CalculatorService.Add did not answer'
[ "${value}" = '42' ] || require 1 "Add answered ${value}, not 42"

# THE DOOR WAS REACHED. `forbidden` would mean the capability was not
# granted; `invalid_request` would mean the origin did not match the compiled
# allowlist. Either is a composition failure. `rendered` or `service_error`
# both mean the request left the decorator and entered the transport.
row composition_fetch "${net}"
row composition_fetch_status "${net_status:-0}"
case "${net}" in
    rendered)
        row composition_payload 'rendered'
        [ "${net_status}" = '200' ] ||
            printf '[CAP-15B] NOTE: the public origin answered %s\n' "${net_status}"
        ;;
    service_error)
        # the door ran and the exchange did not complete: hermetic, expected
        # on a runner with no outbound network, and NOT a failure
        row composition_payload 'unreachable'
        printf '[CAP-15B] NOTE: the public origin was unreachable; the door was reached and the row is recorded, never gated\n'
        ;;
    *)
        row composition_payload 'refused'
        require 1 "the page's fetch was answered ${net} -- the door was not reached"
        ;;
esac

# --- verdict ---------------------------------------------------------------
row composition_target 'linux-x86_64'
if [ "${failures}" -eq 0 ]; then row composition 'PASS'; else row composition 'FAIL'; fi

numeric_keys='|run_exit|listener_members|listener_samples|rpc_result|composition_fetch_status|'
evidence="${repo_root}/build/cap15b/composition-linux-x86_64.json"
{
    printf '{\n'
    first=1
    while IFS="$(printf '\t')" read -r key value; do
        [ -n "${key}" ] || continue
        [ "${first}" -eq 1 ] || printf ',\n'
        first=0
        case "${numeric_keys}" in
            *"|${key}|"*) printf '  "%s": %s' "${key}" "${value}" ;;
            *) printf '  "%s": "%s"' "${key}" "${value}" ;;
        esac
    done < "${rows_file}"
    printf '\n}\n'
} > "${evidence}"
printf '[CAP-15B] evidence: %s\n' "${evidence}"
cat -- "${evidence}"

[ "${failures}" -eq 0 ] ||
    die "CAP-15B composition smoke FAILED: ${failures} failure(s)"
printf '[CAP-15B] composition PASS - create, build, run, and the page reached the door\n'
