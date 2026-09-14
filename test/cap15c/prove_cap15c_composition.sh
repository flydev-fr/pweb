#!/usr/bin/env bash
#
# CAP-15C: THE SOCKET COMPOSITION, mechanised once.
#
# Every other CAP-15C proof is narrower and runs on four targets: the whole
# contract through an injected transport, the shipped transport against a
# standard RFC 6455 server, the image proofs over a console witness. None of
# them proves the thing a user does on day one:
#
#   pweb create  ->  declare an origin  ->  pweb build  ->  pweb run
#   ->  the page opens a socket through @pweb/runtime and echoes
#
# It is mechanised HERE, once, on the Linux leg, for the CAP-15B reason
# (ledger 15B-12): breadth is already where it belongs.
#
# ---------------------------------------------------------------------------
# HERMETIC, AND STILL A RELEASE BUILD
# ---------------------------------------------------------------------------
#
# A release build refuses a loopback `http` origin, so a plaintext local
# witness is out of reach by design. The witness is therefore a TLS RFC 6455
# server on 127.0.0.1 with a certificate made for THIS run, and the declared
# origin is `https://127.0.0.1:<port>` - an ordinary https origin, which the
# grammar accepts and a release build keeps. The certificate is trusted by
# the supervised application ONLY, through OpenSSL's own `SSL_CERT_FILE`:
# mORMot's client loads OpenSSL's default verify paths when no CA file is
# configured, and nothing in the product relaxes validation. No system trust
# store is touched and no public endpoint is involved.
#
# ---------------------------------------------------------------------------
# WHAT IS GATED
# ---------------------------------------------------------------------------
#
#   the build succeeds, and the running host prints its network digest line;
#   the page's socket OPENS and ECHOES through PWebSocket;
#   a REAL reload of the page closes the previous document's socket - 1001
#     close on the witness's wire. A development generation switch is
#     the same trusted re-navigation (test/cap15c K8), so this is its
#     real-window witness (a native close carries its code and no reason);
#   a socket left open when the host auto-closes is released BEFORE the
#     drain - a 1001 close on the wire - and the host still exits 0;
#   `CalculatorService.Add` still answers 42;
#   the supervised application owns ZERO listening sockets, and the sampler
#     TYPES the client connection it does hold instead of counting it.
#
# Usage: test/cap15c/prove_cap15c_composition.sh   (under xvfb-run -a)
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

work="${repo_root}/build/cap15c/composition"
sdk_root="${repo_root}/build/cap10b1/sdk"
cli="${sdk_root}/bin/pweb"
project="${work}/demo"
rows_file="${work}/rows.tsv"
failures=0

die() { printf '[CAP-15C] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-15C] === %s\n' "$*"; }
row() { printf '%s\t%s\n' "$1" "$2" >> "${rows_file}"; printf '[CAP-15C] %s = %s\n' "$1" "$2"; }
require() {
    if [ "$1" -ne 0 ]; then
        failures=$((failures + 1))
        printf '[CAP-15C] FAIL: %s\n' "$2" >&2
    fi
}

# THE WITNESS PORT IS ONE PLACE. 18791 is outside every other CAP-15C port
# (Windows 18761/2, Linux 18771/2, macOS 18781/2)
port=18791
origin="https://127.0.0.1:${port}"

[ -x "${cli}" ] ||
    die "the CLI is not staged: ${cli} -- test/cap10b1/build_cap10b1.sh runs earlier in this leg"
[ -d "${sdk_root}/share/pweb/src" ] ||
    die "the SDK root is not staged: ${sdk_root}/share/pweb/src"
[ -f "${sdk_root}/share/pweb/deps/mormot2/src/core/mormot.core.base.pas" ] ||
    die "the SDK root carries no mORMot -- test/cap10c1/build_cap10c1.sh completes it and runs earlier in this leg"
[ -f "${sdk_root}/share/pweb/sdk/typescript/dist/src/socket.js" ] ||
    die 'the staged @pweb/runtime carries no dist/src/socket.js -- the SDK root predates CAP-15C'
for tool in node npm ss openssl; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'

# shellcheck source=tools/pwebrmtree.sh
. "${repo_root}/tools/pwebrmtree.sh"
pweb_rm_tree "${work}" "${repo_root}/build"
mkdir -p -- "${work}/tls"
: > "${rows_file}"

# --- 0. the witness ----------------------------------------------------------
step 'the TLS RFC 6455 witness, trusted by this run only'
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${work}/tls/key.pem" -out "${work}/tls/cert.pem" -days 2 \
    -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1,DNS:127.0.0.1' \
    > "${work}/tls/openssl.log" 2>&1 ||
    { cat "${work}/tls/openssl.log"; die 'openssl could not make the witness certificate'; }
wire="${work}/wire.jsonl"
node test/cap15c/ws_server.js "--port=${port}" \
    "--tls-cert=${work}/tls/cert.pem" "--tls-key=${work}/tls/key.pem" \
    "--log=${wire}" --ttl=900 > "${work}/witness.out" 2>&1 &
witness_pid=$!
trap 'kill "${witness_pid}" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
    grep -q 'listening' "${work}/witness.out" 2>/dev/null && break
    kill -0 "${witness_pid}" 2>/dev/null || { cat "${work}/witness.out"; die 'the witness exited'; }
    sleep 0.1
done
grep -q 'listening' "${work}/witness.out" || die 'the witness never listened'

# --- 1. create, at schema 2 --------------------------------------------------
step 'pweb create (offline, schema 2)'
( cd -- "${work}" &&
  "${cli}" create demo --ui react --bundle-id org.pweb.cap15c ) > "${work}/create.log" 2>&1 ||
    { tail -20 "${work}/create.log"; die 'pweb create FAILED'; }
grep -q '"schema": 2' "${project}/pweb.json" || die 'pweb create did not emit schema 2'
grep -q '"origins": \[\]' "${project}/pweb.json" || die 'pweb create did not emit an EMPTY origin set'

# --- 2. declare the origin ---------------------------------------------------
step 'declare the origin'
tmp="${work}/pweb.json.new"
sed "s|\"origins\": \[\]|\"origins\": [\"${origin}\"]|" "${project}/pweb.json" > "${tmp}"
mv -f -- "${tmp}" "${project}/pweb.json"
grep -q "${origin}" "${project}/pweb.json" || die 'the origin was not declared'
row socket_composition_declared_origin "${origin}"

# --- 3. the page opens sockets, through @pweb/runtime ------------------------
# The SHIPPED template opens no socket - a scaffold that connected somewhere
# on first run would be deciding for its author - so this smoke teaches ITS
# OWN copy, exactly as a developer would.
step 'teach the generated page to use the socket door'
app="${project}/frontend/src/App.tsx"
[ -f "${app}" ] || die "the generated project has no App.tsx at ${app}"
tmp="${work}/App.tsx.new"
awk -v base="wss://127.0.0.1:${port}" '
/^import \{ handshake, invoke, PWebError \} from "@pweb\/runtime";$/ {
    print "import { handshake, invoke, PWebError, PWebSocket } from \"@pweb/runtime\";"
    print "const CAP15C_SOCKET_BASE = \"" base "\";"
    next
}
/^  value: number;$/ {
    print
    print "  sockOpen: boolean;"
    print "  sockEcho: string;"
    next
}
/^        value: 0,$/ {
    print
    print "        sockOpen: false,"
    print "        sockEcho: \"unset\","
    next
}
/^        const shell = readShell\(\);$/ {
    print "        /* CAP-15C: the native socket door, through the SDK. The FIRST"
    print "         * document parks a socket and reloads; the reload replaces the"
    print "         * document, and the host must close what the old one held. */"
    print "        if (window.name !== \"cap15c-reloaded\") {"
    print "          await new Promise<void>((resolve) => {"
    print "            const parked = new PWebSocket(CAP15C_SOCKET_BASE + \"/idle?row=c_navigation\");"
    print "            const timer = setTimeout(resolve, 10000);"
    print "            parked.onopen = () => { clearTimeout(timer); resolve(); };"
    print "            parked.onclose = () => { clearTimeout(timer); resolve(); };"
    print "          });"
    print "          window.name = \"cap15c-reloaded\";"
    print "          window.location.reload();"
    print "          return;"
    print "        }"
    print "        report.sockEcho = await new Promise<string>((resolve) => {"
    print "          const s = new PWebSocket(CAP15C_SOCKET_BASE + \"/echo?row=c_echo\");"
    print "          const timer = setTimeout(() => resolve(\"timeout\"), 15000);"
    print "          s.onopen = () => { report.sockOpen = true; s.send(\"cap15c-echo\"); };"
    print "          s.onmessage = (e) => {"
    print "            clearTimeout(timer);"
    print "            resolve(typeof e.data === \"string\" ? e.data : \"binary\");"
    print "            s.close(4000, \"done\");"
    print "          };"
    print "          s.onerror = (e) => { clearTimeout(timer); resolve(\"error-\" + (e.category ?? e.code)); };"
    print "          s.onclose = (e) => { clearTimeout(timer); resolve(\"closed-\" + e.category); };"
    print "        });"
    print "        /* left open ON PURPOSE: the host must release it before it drains */"
    print "        const parkedForShutdown = new PWebSocket(CAP15C_SOCKET_BASE + \"/idle?row=c_shutdown\");"
    print "        parkedForShutdown.onclose = () => undefined;"
    print
    next
}
{ print }
' "${app}" > "${tmp}"
mv -f -- "${tmp}" "${app}"
grep -q 'PWebSocket' "${app}" || die 'the page was not taught to use the socket door'
[ "$(grep -c 'CAP15C_SOCKET_BASE' "${app}")" -eq 4 ] || die 'the page teaching did not apply at every anchor'

# --- 4. pweb build -----------------------------------------------------------
step 'pweb build'
( cd -- "${project}" && "${cli}" build ) > "${work}/build.log" 2>&1 ||
    { tail -40 "${work}/build.log"; die 'pweb build FAILED'; }
release="${project}/dist/linux-x86_64/release"
[ -x "${release}/demo" ] || die "no release executable at ${release}/demo"
row socket_composition_build 'PASS'

# --- 5. pweb run -------------------------------------------------------------
step 'pweb run'
export PWEB_SMOKE_AUTOCLOSE_MS=25000
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
# the ONE trust relaxation of this run, and it is OpenSSL's, not the product's
export SSL_CERT_FILE="${work}/tls/cert.pem"
out_file="${work}/run.log"
( cd -- "${project}" && "${cli}" run ) > "${out_file}" 2>&1 &
run_pid=$!

listener_max=0
client_max=0
samples=0
app_pid=''
for _ in $(seq 1 70); do
    if [ -z "${app_pid}" ]; then
        app_pid="$(pgrep -f "${release}/demo" | head -n 1 || true)"
    fi
    if [ -n "${app_pid}" ] && [ -d "/proc/${app_pid}" ]; then
        t=$(ss -ltnp 2>/dev/null | grep -c "pid=${app_pid}," || true)
        u=$(ss -lunp 2>/dev/null | grep -c "pid=${app_pid}," || true)
        n=$((t + u))
        # THE CLIENT CONNECTION IS TYPED, NOT COUNTED: an established TCP
        # socket to the witness port is what the door is for, and it is
        # reported beside the listener count rather than folded into it
        c=$(ss -Htnp state established "( dport = :${port} )" 2>/dev/null |
            grep -c "pid=${app_pid}," || true)
        samples=$((samples + 1))
        [ "${n}" -gt "${listener_max}" ] && listener_max="${n}"
        [ "${c}" -gt "${client_max}" ] && client_max="${c}"
    fi
    kill -0 "${run_pid}" 2>/dev/null || break
    sleep 0.5
done
wait "${run_pid}" && run_exit=0 || run_exit=$?
unset SSL_CERT_FILE
sleep 1
row socket_composition_run_exit "${run_exit}"
require "${run_exit}" 'pweb run did not exit cleanly'
row socket_composition_listener_samples "${samples}"
row socket_composition_listener_members "${listener_max}"
row socket_composition_client_sockets "${client_max}"
[ "${samples}" -gt 0 ] || require 1 'the application was never sampled'
[ "${listener_max}" = '0' ] ||
    require 1 "the supervised application opened ${listener_max} listener(s)"
[ "${client_max}" -ge 1 ] ||
    require 1 'no client connection to the witness was ever observed on the application'

# --- 6. what the run and the wire said ---------------------------------------
step 'read the composition back'
if grep -q 'demo: network [0-9a-f]* [0-9a-f]*' "${out_file}"; then
    row socket_composition_region 'compiled'
else
    row socket_composition_region 'absent'
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
sock_open="$(field sockOpen)"
sock_echo="$(field sockEcho)"
row socket_composition_rpc_ok "${rpc}"
row socket_composition_rpc_result "${value:-0}"
[ "${rpc}" = 'true' ] || require 1 'CalculatorService.Add did not answer'
[ "${value}" = '42' ] || require 1 "Add answered ${value}, not 42"
row socket_composition_open "${sock_open:-false}"
[ "${sock_open}" = 'true' ] || require 1 'the page socket never opened'
if [ "${sock_echo}" = 'cap15c-echo' ]; then
    row socket_composition_echo 'echoed'
else
    row socket_composition_echo "${sock_echo:-none}"
    require 1 "the page socket did not echo: ${sock_echo}"
fi

# THE WIRE, read by row: which client closes reached the witness, with what
node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n")
  .filter(Boolean).map((l) => JSON.parse(l));
const rowOf = {};
for (const w of lines) {
  if (w.kind === "upgrade") {
    const m = /row=([a-z0-9_]+)/.exec(w.url || "");
    rowOf[w.id] = m ? m[1] : "";
  }
}
const close = (r) => {
  const c = lines.find((w) => w.event === "client_close" && rowOf[w.id] === r);
  return c ? `${c.code}/${c.reason}` : "none";
};
console.log(`navigation\t${close("c_navigation")}`);
console.log(`shutdown\t${close("c_shutdown")}`);
console.log(`echo\t${close("c_echo")}`);
' "${wire}" > "${work}/wire-rows.tsv" || die 'the wire log could not be read'
nav_close="$(awk -F '\t' '$1 == "navigation" { print $2 }' "${work}/wire-rows.tsv")"
shut_close="$(awk -F '\t' '$1 == "shutdown" { print $2 }' "${work}/wire-rows.tsv")"
echo_close="$(awk -F '\t' '$1 == "echo" { print $2 }' "${work}/wire-rows.tsv")"
row socket_composition_navigation_close "${nav_close}"
row socket_composition_shutdown_close "${shut_close}"
row socket_composition_page_close "${echo_close}"
[ "${nav_close}" = '1001/' ] ||
    require 1 "the reloaded document's socket closed as ${nav_close}, not a 1001 close with no reason"
[ "${shut_close}" = '1001/' ] ||
    require 1 "the socket open at shutdown closed as ${shut_close}, not a 1001 close with no reason"
[ "${echo_close}" = '4000/done' ] ||
    require 1 "the page close reached the wire as ${echo_close}, not 4000/done"

# --- verdict -----------------------------------------------------------------
row socket_composition_target 'linux-x86_64'
if [ "${failures}" -eq 0 ]; then row socket_composition 'PASS'; else row socket_composition 'FAIL'; fi

numeric_keys='|socket_composition_run_exit|socket_composition_listener_members|socket_composition_listener_samples|socket_composition_client_sockets|socket_composition_rpc_result|'
evidence="${repo_root}/build/cap15c/composition-linux-x86_64.json"
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
printf '[CAP-15C] evidence: %s\n' "${evidence}"
cat -- "${evidence}"

[ "${failures}" -eq 0 ] ||
    die "CAP-15C socket composition smoke FAILED: ${failures} failure(s)"
printf '[CAP-15C] composition PASS - create, build, run; the page opened, echoed, reloaded and was shut down with a socket open\n'
