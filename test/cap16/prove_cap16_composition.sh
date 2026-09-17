#!/usr/bin/env bash
#
# CAP-16: THE SIGNAL COMPOSITION, mechanised once.
#
# Every other CAP-16 proof is narrower and runs on four targets: the channel
# through a fake view, the engine facts through the production encoder, the
# production host with the real SDK. None of them proves the thing a user does
# on day one:
#
#   pweb create  ->  declare a topic and a native worker that signals it
#   ->  pweb build  ->  pweb run
#   ->  the page hears the topic through @pweb/runtime and re-reads, never polls
#
# It is mechanised HERE, once, on the Linux leg, for the CAP-15B reason
# (ledger 15B-12): breadth is already where it belongs.
#
# ---------------------------------------------------------------------------
# WHAT IS GATED
# ---------------------------------------------------------------------------
#
#   the build succeeds and the application runs and exits 0;
#   the page subscribed to `demo.tick` and was told of at least three ticks
#     by a native worker thread, reading the count ONLY from the signal
#     callback - the page has no timer that reads;
#   `CalculatorService.Add` still answers 42;
#   the supervised application owns ZERO listening sockets;
#   the RELEASE image carries the template of the one injected script exactly
#     once and no development console channel;
#   the page uses @pweb/runtime and never the raw primitive.
#
# Usage: test/cap16/prove_cap16_composition.sh   (under xvfb-run -a)
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

work="${repo_root}/build/cap16/composition"
sdk_root="${repo_root}/build/cap10b1/sdk"
cli="${sdk_root}/bin/pweb"
project="${work}/demo"
rows_file="${work}/rows.tsv"
failures=0

die() { printf '[CAP-16] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-16] === %s\n' "$*"; }
row() { printf '%s\t%s\n' "$1" "$2" >> "${rows_file}"; printf '[CAP-16] %s = %s\n' "$1" "$2"; }
require() {
    if [ "$1" -ne 0 ]; then
        failures=$((failures + 1))
        printf '[CAP-16] FAIL: %s\n' "$2" >&2
    fi
}

[ -x "${cli}" ] ||
    die "the CLI is not staged: ${cli} -- test/cap10b1/build_cap10b1.sh runs earlier in this leg"
[ -d "${sdk_root}/share/pweb/src" ] ||
    die "the SDK root is not staged: ${sdk_root}/share/pweb/src"
[ -f "${sdk_root}/share/pweb/src/rpc/pweb.rpc.signal.pas" ] ||
    die 'the staged SDK root carries no pweb.rpc.signal.pas -- it predates CAP-16'
[ -f "${sdk_root}/share/pweb/sdk/typescript/dist/src/signal.js" ] ||
    die 'the staged @pweb/runtime carries no dist/src/signal.js -- the SDK root predates CAP-16'
for tool in node npm ss; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
[ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'

# shellcheck source=tools/pwebrmtree.sh
. "${repo_root}/tools/pwebrmtree.sh"
pweb_rm_tree "${work}" "${repo_root}/build"
mkdir -p -- "${work}"
: > "${rows_file}"

# --- 1. create ---------------------------------------------------------------
step 'pweb create (offline)'
( cd -- "${work}" &&
  "${cli}" create demo --ui react --bundle-id org.pweb.cap16 ) > "${work}/create.log" 2>&1 ||
    { tail -20 "${work}/create.log"; die 'pweb create FAILED'; }

# --- 2. the native half: a topic, its grant, a worker that signals it ---------
# The SHIPPED template declares no topic and starts no thread - what moves on
# its own schedule belongs to the author - so this smoke teaches ITS OWN
# copy, exactly as a developer would. The apostrophe reaches awk as `q`, and
# lines are matched whole, so no quote is ever escaped inside a pattern.
step 'teach the native side a topic and a worker'
services="${project}/src/app.services.pas"
[ -f "${services}" ] || die "the generated project has no ${services}"
tmp="${work}/app.services.pas.new"
awk -v q="'" '
function grant(prefix, rest) {
    return prefix "[APP_CAP_CALCULATOR_ADD, " q "signal.demo.tick" q "]);" rest
}
$0 == "  sysutils," && !done_uses { print; print "  classes,"; done_uses = 1; next }
$0 == "function AppSignalTopics: TRawUtf8DynArray;" { in_topics = 1 }
$0 == "  Result := nil;" && in_topics {
    print "  // CAP-16 smoke: one topic, signalled by a native worker"
    print "  SetLength(Result, 1);"
    print "  Result[0] := " q "demo.tick" q ";"
    in_topics = 0
    next
}
$0 == "    b.SetAppMaximum([APP_CAP_CALCULATOR_ADD]);" {
    print grant("    b.SetAppMaximum(", ""); next }
$0 == "    b.SetWindowCapabilities(" q "main" q ", [APP_CAP_CALCULATOR_ADD]);" {
    print grant("    b.SetWindowCapabilities(" q "main" q ", ", ""); next }
$0 == "    b.SetPrincipalCapabilities(" q "window:main" q ", [APP_CAP_CALCULATOR_ADD]);" {
    print grant("    b.SetPrincipalCapabilities(" q "window:main" q ", ", ""); next }
$0 == "    b.RegisterZeroCapMethod(APP_METHOD_READY);" {
    print
    print "    b.RegisterZeroCapMethod(" q "Ticker.Start" q ");"
    print "    b.RegisterZeroCapMethod(" q "Ticker.Count" q ");"
    next
}
$0 == "function TAppBridge.Invoke(const Context: TInvocationContext;" {
    print "type"
    print "  // CAP-16 smoke: a native job that moves on its own schedule"
    print "  TTicker = class(TThread)"
    print "  protected"
    print "    procedure Execute; override;"
    print "  end;"
    print ""
    print "var"
    print "  TickCount: LongInt = 0;"
    print "  TickerStarted: LongInt = 0;"
    print ""
    print "procedure TTicker.Execute;"
    print "var"
    print "  i: Integer;"
    print "begin"
    print "  for i := 1 to 40 do"
    print "  begin"
    print "    Sleep(150);"
    print "    InterlockedIncrement(TickCount);"
    print "    PWebSignal(" q "demo.tick" q ");"
    print "  end;"
    print "end;"
    print ""
    print
    next
}
$0 == "  if Method = APP_METHOD_READY then" {
    print "  if Method = " q "Ticker.Start" q " then"
    print "  begin"
    print "    if InterlockedIncrement(TickerStarted) = 1 then"
    print "      with TTicker.Create(True) do"
    print "      begin"
    print "        FreeOnTerminate := True;"
    print "        Start;"
    print "      end;"
    print "    Result := PWebSuccessResult(" q "{}" q ");"
    print "  end"
    print "  else if Method = " q "Ticker.Count" q " then"
    print "    Result := PWebSuccessResult(TPWebJson(IntToStr(TickCount)))"
    print "  else"
    print
    next
}
{ print }
' "${services}" > "${tmp}"
mv -f -- "${tmp}" "${services}"
[ "$(grep -c 'signal.demo.tick' "${services}")" -eq 3 ] || die 'the grant was not taught at every anchor'
grep -q 'TTicker.Create' "${services}" || die 'the worker was not taught'
grep -q "Result\\[0\\] := 'demo.tick'" "${services}" || die 'the topic was not declared'
grep -q '^  classes,$' "${services}" || die 'the thread unit was not added'

# --- 3. the page half: subscribe, and read ONLY when told --------------------
step 'teach the page to hear the topic'
app="${project}/frontend/src/App.tsx"
[ -f "${app}" ] || die "the generated project has no App.tsx at ${app}"
tmp="${work}/App.tsx.new"
awk '
$0 == "import { handshake, invoke, PWebError } from \"@pweb/runtime\";" {
    print "import { handshake, invoke, onSignal, PWebError } from \"@pweb/runtime\";"
    next
}
$0 == "  errmap: boolean;" {
    print
    print "  signalSubscribed: boolean;"
    print "  signalUpdates: number;"
    print "  signalLastCount: number;"
    next
}
$0 == "        errmap: false," {
    print
    print "        signalSubscribed: false,"
    print "        signalUpdates: 0,"
    print "        signalLastCount: -1,"
    next
}
$0 == "        const shell = readShell();" {
    print "        /* CAP-16: the native worker signals demo.tick; the page reads the"
    print "         * count ONLY from the signal callback - it has no reading timer. */"
    print "        const ticks = onSignal(\"demo.tick\", () => {"
    print "          void invoke<number>(\"Ticker.Count\", null).then((n) => {"
    print "            report.signalUpdates++;"
    print "            report.signalLastCount = n;"
    print "          });"
    print "        });"
    print "        await ticks.ready;"
    print "        report.signalSubscribed = true;"
    print "        await invoke(\"Ticker.Start\", null);"
    print "        await new Promise<void>((resolve) => setTimeout(resolve, 4000));"
    print "        ticks.off();"
    print
    next
}
{ print }
' "${app}" > "${tmp}"
mv -f -- "${tmp}" "${app}"
[ "$(grep -c 'signalUpdates' "${app}")" -eq 4 ] || die 'the page teaching did not apply at every anchor'
grep -q 'onSignal("demo.tick"' "${app}" || die 'the page does not subscribe'

# --- 4. pweb build -----------------------------------------------------------
step 'pweb build'
( cd -- "${project}" && "${cli}" build ) > "${work}/build.log" 2>&1 ||
    { tail -40 "${work}/build.log"; die 'pweb build FAILED'; }
release="${project}/dist/linux-x86_64/release"
[ -x "${release}/demo" ] || die "no release executable at ${release}/demo"
row signal_composition_build 'PASS'

# THE RELEASE IMAGE: the template of the one script once, no development
# console channel, and a page that never names the raw primitive
template='window.dispatchEvent(new CustomEvent("pweb:signal",{detail:'
tcount="$(grep -aoF "${template}" "${release}/demo" | wc -l | tr -d ' ')"
row signal_composition_image_template "${tcount}"
[ "${tcount}" = '1' ] || require 1 "the release image carries the template ${tcount} time(s), not once"
if grep -aqF '__pweb_dev_console' "${release}/demo"; then
    row signal_composition_image_dev_console 'present'
    require 1 'the release image carries the development console channel'
else
    row signal_composition_image_dev_console 'absent'
fi
if grep -q '__pweb_invoke' "${app}"; then
    row signal_composition_raw_primitive 'true'
    require 1 'the page calls the raw primitive'
else
    row signal_composition_raw_primitive 'false'
fi

# --- 5. pweb run -------------------------------------------------------------
step 'pweb run'
export PWEB_SMOKE_AUTOCLOSE_MS=20000
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
out_file="${work}/run.log"
( cd -- "${project}" && "${cli}" run ) > "${out_file}" 2>&1 &
run_pid=$!

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
row signal_composition_run_exit "${run_exit}"
require "${run_exit}" 'pweb run did not exit cleanly'
row signal_composition_listener_samples "${samples}"
row signal_composition_listener_members "${listener_max}"
[ "${samples}" -gt 0 ] || require 1 'the application was never sampled'
[ "${listener_max}" = '0' ] ||
    require 1 "the supervised application opened ${listener_max} listener(s)"

# --- 6. what the page said -----------------------------------------------------
step 'read the composition back'
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
subscribed="$(field signalSubscribed)"
updates="$(field signalUpdates)"
last_count="$(field signalLastCount)"
row signal_composition_rpc_ok "${rpc}"
row signal_composition_rpc_result "${value:-0}"
[ "${rpc}" = 'true' ] || require 1 'CalculatorService.Add did not answer'
[ "${value}" = '42' ] || require 1 "Add answered ${value}, not 42"
row signal_composition_subscribed "${subscribed:-false}"
row signal_composition_updates "${updates:-0}"
row signal_composition_last_count "${last_count:--1}"
[ "${subscribed}" = 'true' ] || require 1 'the page never subscribed to demo.tick'
[ "${updates:-0}" -ge 3 ] 2>/dev/null ||
    require 1 "the page was told of ${updates:-0} tick(s) - a native worker signalled 40 over 6 s"
[ "${last_count:--1}" -ge 3 ] 2>/dev/null ||
    require 1 "the page read a count of ${last_count:--1} - it did not re-read on the signal"

# --- verdict -----------------------------------------------------------------
row signal_composition_target 'linux-x86_64'
if [ "${failures}" -eq 0 ]; then row signal_composition 'PASS'; else row signal_composition 'FAIL'; fi

numeric_keys='|signal_composition_run_exit|signal_composition_listener_members|signal_composition_listener_samples|signal_composition_rpc_result|signal_composition_updates|signal_composition_last_count|signal_composition_image_template|'
evidence="${repo_root}/build/cap16/composition-linux-x86_64.json"
mkdir -p -- "$(dirname -- "${evidence}")"
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
printf '[CAP-16] evidence: %s\n' "${evidence}"
cat -- "${evidence}"

[ "${failures}" -eq 0 ] ||
    die "CAP-16 signal composition smoke FAILED: ${failures} failure(s)"
printf '[CAP-16] composition PASS - create, build, run; a native worker signalled, the page re-read, 42 answered, nothing listened\n'
