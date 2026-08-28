#!/usr/bin/env bash
#
# CAP-10B1 (Linux and macOS): prove the GENERATED project builds and runs.
#
# The POSIX twin of prove_cap10b1.ps1, and it makes the identical claims in
# the identical order. This is a TEST HARNESS and not `pweb build`: CAP-10B1
# exposes no build command and nothing here is a step towards one.
#
# THE RELOCATION IS THE PROOF. The project is copied out of the tree that
# created it and its bytes are digested BEFORE and AFTER everything below.
# THE SDK ROOT IS THE OTHER PROOF: every PWeb unit path names the STAGED
# build/cap10b1/sdk/share/pweb/src, never this repository's src/. CAP-10B2
# corrected the platform unit path here, which had been repo-relative while
# the Windows twin already named the staged tree - the claim was true of the
# other five paths and not of that one.
#
# Two things differ per platform and both are at the seam, not in the claim:
#   - the release layout. Linux ships exe + app.pwb + libwebview.so.0.12 in
#     one directory; macOS ships a .app, because WKWebView keys persistent
#     state by bundle identifier and an unbundled executable has none;
#   - listening-socket sampling uses ss(8) on Linux and lsof(8) on macOS.
#
# Emits build/cap10b1/proof-<target>.json.
#
# Usage: test/cap10b1/prove_cap10b1.sh   (under xvfb-run on a headless Linux)
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

work="${repo_root}/build/cap10b1"
sdk_root="${work}/sdk"
source_project="${work}/project/demo"
bundler="${work}/bin/pwebbundle"
log="${work}/proof.log"

die() { printf '[CAP-10B1] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10B1] === %s\n' "$*"; }

for pre in "${source_project}/pweb.json" "${bundler}" \
           "${sdk_root}/share/pweb/sdk/typescript/package.json" \
           "${sdk_root}/share/pweb/src/webview/pweb.webview.host.pas"; do
    [ -e "${pre}" ] ||
        die "missing precondition: ${pre} -- run build_cap10b1.sh and run_cap10b1_gates.ps1 first"
done
command -v node >/dev/null 2>&1 || die 'required tool not found: node'
command -v npm >/dev/null 2>&1 || die 'required tool not found: npm'
: > "${log}"

failures=0
rows_file="${work}/proof-rows.txt"
: > "${rows_file}"
row() { printf '%s\t%s\n' "$1" "$2" >> "${rows_file}"; }
require() {
    if [ "$1" != '0' ]; then
        printf 'GATE FAILURE: %s\n' "$2"
        failures=$(( failures + 1 ))
    fi
}
bool_row() { if [ "$1" = '0' ]; then printf 'PASS'; else printf 'FAIL'; fi; }

sha_file() { shasum -a 256 "$1" | awk '{ print $1 }'; }
sha_stdin() { shasum -a 256 | awk '{ print $1 }'; }
tree_digest() {
    local root="$1"
    ( cd -- "${root}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort |
      while IFS= read -r rel; do
          printf '%s %s %s\n' "${rel}" \
              "$(wc -c < "${rel}" | tr -d ' ')" "$(sha_file "${rel}")"
      done ) | sha_stdin
}

os_name="$(uname -s)"
case "${os_name}" in
Linux)
    target='linux-x86_64'
    dist="${repo_root}/build/cap7l/webview-dist"
    dylib='libwebview.so.0.12'
    [ -f "${dist}/${dylib}" ] ||
        die "staged webview library missing: ${dist}/${dylib}"
    static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
    compile_generated() {
        # -k-lgcc_s: the DSO is findable but was never NAMED, which
        # --as-needed will not do on the caller's behalf (the CAP-9C2
        # measurement, reused verbatim)
        fpc -MObjFPC -Sh -B -FU"${unit_dir}" -FE"${bin_dir}" \
            -Fu"${project}/src" "${sdk_units[@]}" \
            -Fu"${sdk_src}/platform/linux" \
            "${mormot_units[@]}" "-Fl${static_dir}" "-Fl${dist}" \
            -k'-rpath=$ORIGIN' -k-lgcc_s "${project}/src/demo.lpr"
    }
    sample_listeners() {
        local pid="$1" n=0 t=0 u=0
        if command -v ss >/dev/null 2>&1; then
            t=$(ss -ltnp 2>/dev/null | grep -c "pid=${pid}," || true)
            u=$(ss -lunp 2>/dev/null | grep -c "pid=${pid}," || true)
            n=$(( t + u ))
        fi
        printf '%s' "${n}"
    }
    ;;
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    case "$(uname -m)" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: $(uname -m)" ;;
    esac
    dist="${PWEB_MACOS_DIST}"
    dylib="${PWEB_MACOS_DYLIB_VERSIONED}"
    [ -f "${dist}/${dylib}" ] ||
        die "staged dylib missing: ${dist}/${dylib}"
    [ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
        die "production Cocoa bridge object missing: ${PWEB_MACOS_BRIDGE_OBJ} -- run test/cap7m/build_cap7m.sh first"
    static_dir="${PWEB_MACOS_STATIC_DIR}"
    compile_generated() {
        fpc -MObjFPC -Sh -B -FU"${unit_dir}" -FE"${bin_dir}" \
            -Fu"${project}/src" "${sdk_units[@]}" \
            -Fu"${sdk_src}/platform/macos" \
            "${mormot_units[@]}" "${PWEB_MACOS_FPC_FLAGS[@]}" \
            "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" "${project}/src/demo.lpr"
    }
    sample_listeners() {
        local pid="$1" n=0
        if command -v lsof >/dev/null 2>&1; then
            n=$(lsof -nP -p "${pid}" 2>/dev/null |
                grep -c -E 'TCP .*\(LISTEN\)|UDP ' || true)
        fi
        printf '%s' "${n}"
    }
    ;;
*)
    die "unsupported platform: ${os_name}"
    ;;
esac
printf '[CAP-10B1] target: %s\n' "${target}"

mormot_units=(
    -Fideps/mormot2/src
    -Fudeps/mormot2/src/core
    -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt
    -Fudeps/mormot2/src/net
    -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm
    -Fudeps/mormot2/src/rest
    -Fudeps/mormot2/src/soa
)
sdk_src="${sdk_root}/share/pweb/src"
sdk_units=(
    -Fu"${sdk_src}/lib"
    -Fu"${sdk_src}/rpc"
    -Fu"${sdk_src}/security"
    -Fu"${sdk_src}/webview"
    -Fu"${sdk_src}/assets"
)

# --- 1. relocate, and digest what must not change --------------------------
step 'relocate the created project into an unrelated staging path'
stage="${work}/stage"
rm -rf -- "${stage}"
mkdir -p -- "${stage}"
project="${stage}/demo"
cp -R -- "${source_project}" "${project}"
before_digest="$(tree_digest "${source_project}")"
row generated_tree_digest "${before_digest}"

# --- 2. the SDK, materialised into the build stage -------------------------
step 'materialise the pinned TypeScript SDK into the stage'
frontend="${project}/frontend"
node tools/stage-ts-sdk.mjs "${sdk_root}/share/pweb/sdk/typescript" \
    "${frontend}/.pweb/sdk/typescript" >> "${log}" 2>&1
require "$?" 'materialising the TypeScript SDK FAILED'

# --- 3. the frontend -------------------------------------------------------
step 'npm ci, typecheck, production build'
( cd -- "${frontend}" && npm ci --no-audit --no-fund ) >> "${log}" 2>&1
require "$?" 'npm ci FAILED in the generated frontend'
( cd -- "${frontend}" && npm run typecheck ) >> "${log}" 2>&1
typecheck=$?
require "${typecheck}" 'the generated frontend does not typecheck'
row frontend_typecheck "$(bool_row "${typecheck}")"
( cd -- "${frontend}" && npm run build ) >> "${log}" 2>&1
built=$?
require "${built}" 'the generated frontend does not build'
row frontend_build "$(bool_row "${built}")"

dist_dir="${frontend}/dist"
for f in index.html assets/app.js assets/index.css; do
    [ -f "${dist_dir}/${f}" ] || require 1 "the production build did not emit ${f}"
done

# WHERE @pweb/runtime ACTUALLY CAME FROM, resolved through the link npm
# created rather than read out of the manifest that asked for it.
#
# MEASURED, and worth stating because it is the security property: the
# lockfile marks this dependency `link: true` with a project-relative
# target, so npm LINKS it and never fetches it. Point the target at nothing
# and `npm ci` still succeeds - it makes a dangling link - and the failure
# arrives at the first typecheck. No package registry ever answers for this
# name.
expected_target="$(cd -- "${frontend}/.pweb/sdk/typescript" && pwd -P)"
if [ -e "${frontend}/node_modules/@pweb/runtime" ]; then
    actual_target="$(cd -- "${frontend}/node_modules/@pweb/runtime" && pwd -P)"
else
    actual_target=''
    require 1 'npm did not provide @pweb/runtime'
fi
if [ "${actual_target}" = "${expected_target}" ]; then
    row runtime_from_sdk_root 'PASS'
else
    row runtime_from_sdk_root 'FAIL'
    require 1 "@pweb/runtime resolved to '${actual_target}', expected the staged SDK at '${expected_target}'"
fi

# --- 4. the frontend security sweeps ---------------------------------------
# ONLY A STRING LITERAL COUNTS, the discipline CAP-10A's dev-trust gate
# established: the generated App.tsx opens by SAYING it uses no fetch, no
# WebSocket and no localhost, and a gate that could not tell a literal from
# its explanation would forbid the explanation.
step 'the frontend security sweeps'
literals() {
    # every double-quoted, single-quoted and backticked run, one per line
    grep -oE '"[^"]*"|'"'"'[^'"'"']*'"'"'|`[^`]*`' "$1" 2>/dev/null || true
}
raw_primitive='false'
transport_leak=0
for f in "${frontend}/src"/*.tsx "${frontend}/src"/*.ts \
         "${frontend}/src"/*.css "${frontend}/index.html"; do
    [ -f "${f}" ] || continue
    if literals "${f}" | grep -qE '__pweb_invoke|webkit\.messageHandlers|chrome\.webview'; then
        raw_primitive='true'
        require 1 "$(basename "${f}") uses a raw native primitive as DATA"
    fi
    if literals "${f}" | grep -qE 'localhost|127\.0\.0\.1|file://|https?://|wss?://'; then
        transport_leak=1
        require 1 "$(basename "${f}") names a transport as DATA"
    fi
done
row raw_primitive_used "${raw_primitive}"
row frontend_transport_clean "$(bool_row "${transport_leak}")"
grep -q 'from "@pweb/runtime"' "${frontend}/src/App.tsx" ||
    require 1 'App.tsx does not import @pweb/runtime'
# the EXACT module set, side-effect imports included
observed_imports="$(grep -h '^import ' "${frontend}/src/App.tsx" \
    "${frontend}/src/main.tsx" | grep -oE '"[^"]+"' | tr -d '"' |
    LC_ALL=C sort -u | tr '\n' '|')"
expected_imports="$(printf '%s\n' './App' './app.css' '@pweb/runtime' \
    'react' 'react-dom/client' | LC_ALL=C sort -u | tr '\n' '|')"
[ "${observed_imports}" = "${expected_imports}" ] ||
    require 1 "the generated frontend imports ${observed_imports}"

dev_leak=0
if grep -qE 'import\.meta\.hot|/@vite/client|localhost|127\.0\.0\.1|ws://|eval\(' \
        "${dist_dir}/assets/app.js"; then
    dev_leak=1
    require 1 'the production bundle carries a development transport'
fi
row frontend_no_dev_code "$(bool_row "${dev_leak}")"
grep -qE '<script[^>]*[[:space:]]src=' "${dist_dir}/index.html" ||
    require 1 'the built index.html has no external script'

# --- 5. app.pwb, through the frozen bundler --------------------------------
step 'app.pwb, through the frozen CAP-6 bundler'
app_pwb="${stage}/app.pwb"
"${bundler}" "${dist_dir}" "${app_pwb}" >> "${log}" 2>&1
require "$?" 'the app.pwb build FAILED'

# --- 6. the generated Pascal program, against the STAGED SDK ---------------
step 'compile the generated Pascal program against the staged SDK root'
unit_dir="${work}/app-units"
bin_dir="${work}/app-bin"
rm -rf -- "${unit_dir}" "${bin_dir}"
mkdir -p -- "${unit_dir}" "${bin_dir}"
compile_generated >> "${log}" 2>&1
native_built=$?
require "${native_built}" 'the generated Pascal program does not compile'
row native_build "$(bool_row "${native_built}")"
[ -x "${bin_dir}/demo" ] || die 'the generated program produced no executable'

# --- 7. the smallest release layout, and a real run ------------------------
step 'assemble the smallest release layout and run it from an unrelated CWD'
release="${work}/release"
rm -rf -- "${release}"
verdict_file="${work}/app-verdict.txt"
out_file="${work}/app-stdout.txt"
rm -f -- "${verdict_file}" "${out_file}"
case "${os_name}" in
Linux)
    mkdir -p -- "${release}"
    cp -f -- "${bin_dir}/demo" "${release}/"
    cp -f -- "${app_pwb}" "${release}/"
    cp -f -- "${dist}/${dylib}" "${release}/"
    exe="${release}/demo"
    expected_layout="app.pwb|demo|${dylib}"
    ;;
Darwin)
    # a .app, because WKWebView keys persistent state by bundle identifier
    # and an unbundled executable has none. The identity comes from the
    # GENERATED descriptor, which is the point: bundleId was stated by the
    # developer at create time and travels to the platform unchanged.
    bundle_id="$(grep -o '"bundleId"[^,]*' "${project}/pweb.json" |
        sed 's/.*"bundleId"[^"]*"\([^"]*\)".*/\1/')"
    app_version="$(grep -o '"version"[^,]*' "${project}/pweb.json" |
        head -n 1 | sed 's/.*"version"[^"]*"\([^"]*\)".*/\1/')"
    [ -n "${bundle_id}" ] || die 'could not read bundleId from the generated pweb.json'
    app="${release}/Demo.app"
    mkdir -p -- "${app}/Contents/MacOS" "${app}/Contents/Resources"
    cp -f -- "${bin_dir}/demo" "${app}/Contents/MacOS/"
    cp -f -- "${dist}/${dylib}" "${app}/Contents/MacOS/"
    cp -f -- "${app_pwb}" "${app}/Contents/Resources/"
    cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>demo</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleName</key>
	<string>demo</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${app_version}</string>
	<key>CFBundleVersion</key>
	<string>${app_version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${PWEB_MACOS_DEPLOYMENT_TARGET}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
    plutil -lint "${app}/Contents/Info.plist" >> "${log}" 2>&1 ||
        die 'the generated Info.plist does not lint'
    # DELIBERATELY NOT codesigned. `codesign -s - -f` on a BUNDLE writes
    # Contents/_CodeSignature/CodeResources, which would add a file to the
    # layout this step then asserts is minimal - and nothing here needs it:
    # the executable is launched DIRECTLY, not through LaunchServices, and
    # the linker already ad-hoc signs a Mach-O on Apple Silicon. CAP-7M2
    # signs only as a RETRY when LaunchServices leaves no verdict, after its
    # own layout check has run.
    exe="${app}/Contents/MacOS/demo"
    expected_layout="Info.plist|demo|${dylib}|app.pwb"
    ;;
esac

observed_layout="$( ( cd -- "${release}" && find . -type f |
    sed 's|.*/||' | LC_ALL=C sort ) | tr '\n' '|')"
expected_sorted="$(printf '%s\n' ${expected_layout//|/ } | LC_ALL=C sort |
    tr '\n' '|')"
if [ "${observed_layout}" = "${expected_sorted}" ]; then
    row loose_assets_used 'false'
else
    row loose_assets_used 'true'
    require 1 "the release layout is ${observed_layout}, expected ${expected_sorted}"
fi

# an unrelated CWD, deliberately: app.pwb is resolved from the EXECUTABLE and
# a run that only works from its own directory has not proved that.
#
# `exec` matters: it REPLACES the subshell with the application, so $! is the
# application's own pid. Without it the listener sampler would be watching a
# shell that owns no sockets and would report a clean zero for any host.
run_cwd="$(mktemp -d)"
( cd -- "${run_cwd}" &&
  exec "${exe}" "--pweb-verdict=${verdict_file}" --pweb-autoclose-ms=20000 \
      > "${out_file}" 2>&1 ) &
app_pid=$!
# sampled WHILE the window is live: a socket opened and closed between runs
# would be invisible afterwards
listener_max=0
for _ in $(seq 1 60); do
    kill -0 "${app_pid}" 2>/dev/null || break
    n="$(sample_listeners "${app_pid}")"
    [ -n "${n}" ] || n=0
    if [ "${n}" -gt "${listener_max}" ]; then listener_max="${n}"; fi
    sleep 0.5
done
wait "${app_pid}" && app_exit=0 || app_exit=$?
cat -- "${out_file}" || true
{ printf '===== app run (exit %s) =====\n' "${app_exit}"; cat -- "${out_file}"; } \
    >> "${log}"

row app_exit "${app_exit}"
row listener_count "${listener_max}"
[ "${app_exit}" = '0' ] || require 1 "the generated application exited ${app_exit}"
[ "${listener_max}" = '0' ] ||
    require 1 "the generated application opened ${listener_max} listener(s)"
[ -f "${verdict_file}" ] && [ "$(tr -d '\r\n' < "${verdict_file}")" = 'demo: ok' ] ||
    require 1 'the generated application did not write its verdict'

report="$(grep -o 'demo: ready {.*}' "${out_file}" | tail -n 1 |
    sed 's/^demo: ready //')"
[ -n "${report}" ] || require 1 'the generated application printed no ready report'
if [ -n "${report}" ]; then
    for flag in html css js secure handshake rpc errmap; do
        if printf '%s' "${report}" | grep -q "\"${flag}\":true"; then
            row "${flag}" 'true'
        else
            row "${flag}" 'false'
            require 1 "the page reported ${flag} = false"
        fi
    done
    if printf '%s' "${report}" | grep -q '"value":42'; then
        row rpc_result '42'
    else
        row rpc_result '0'
        require 1 "CalculatorService.Add did not return 42: ${report}"
    fi
    row secure_origin "$(if printf '%s' "${report}" | grep -q '"secure":true'; \
        then printf 'PASS'; else printf 'FAIL'; fi)"
    row error_mapping "$(if printf '%s' "${report}" | grep -q '"errmap":true'; \
        then printf 'PASS'; else printf 'FAIL'; fi)"
fi

# --- 8. the project the build was NOT allowed to touch ---------------------
after_digest="$(tree_digest "${source_project}")"
if [ "${after_digest}" = "${before_digest}" ]; then
    row generated_tree_unchanged 'PASS'
else
    row generated_tree_unchanged 'FAIL'
    require 1 'the build mutated the generated project'
fi

row target "${target}"
if [ "${failures}" -eq 0 ]; then row proof_corpus 'PASS'; else row proof_corpus 'FAIL'; fi

# ONE writer for the JSON, from the tab-separated rows: two writers is how a
# corpus ends up with two shapes.
#
# The numeric keys are NAMED rather than sniffed. A sha256 that happened to
# be sixty-four decimal digits would otherwise be emitted as a number, which
# is both invalid JSON for that magnitude and a bug nobody would ever
# reproduce on purpose.
numeric_keys='|app_exit|listener_count|rpc_result|'
evidence="${work}/proof-${target}.json"
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
printf '[CAP-10B1] evidence: %s\n' "${evidence}"
cat -- "${evidence}"

[ "${failures}" -eq 0 ] ||
    die "CAP-10B1 build proof FAILED: ${failures} failure(s)"
printf '[CAP-10B1] the generated project builds and runs on %s\n' "${target}"
