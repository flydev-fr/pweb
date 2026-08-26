#!/usr/bin/env bash
#
# CAP-9C2: the plugin-enabled release layout and its real-GUI acceptance,
# on the POSIX targets - Linux x64 and macOS (both native architectures),
# dispatched on uname. The bash sibling of test/cap9c2/run_quickjsgui.ps1.
#
# The steps, the row NAMES and the row ORDER are identical to the ps1
# sibling by construction, because the corpus those rows form is hashed
# into ONE digest the aggregator requires to be equal on all four
# targets. Anything genuinely per-platform - how many asset reads an
# engine made, what the layout listing looks like, whether a symlink
# could be created - stays in the log and the JSON, never in the corpus.
#
# Platform differences, and only these:
#   - the release layout: a flat directory on Linux, a .app bundle on
#     macOS (the executable in Contents/MacOS, both archives and both
#     licences in Contents/Resources), which is the CAP-7M2 shape;
#   - the QuickJS static object: pinned in deps on Linux, built from the
#     pinned in-tree sources on macOS (the mORMot release ships no
#     darwin quickjs.o);
#   - no CAP-3U window: the mORMot x64 call-method trampoline is a
#     Win64-only concern;
#   - listening-socket sampling uses ss(8) on Linux and lsof(8) on macOS.
#
# Run Linux under a virtual display:  xvfb-run -a test/cap9c2/run_quickjsgui.sh
#
# Writes: build/cap9c2/quickjsgui-<target>.json (PASS|FAIL),
#         build/cap9c2/quickjs-gui-corpus.txt (the digest source),
#         the platform release layout + logs.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-9C2] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-9C2] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'
command -v unzip >/dev/null 2>&1 || die 'required tool not found: unzip'

work="${repo_root}/build/cap9c2"
mkdir -p -- "${work}"
payload="${repo_root}/build/quickjs-release"
corpus="${work}/quickjs-gui-corpus.txt"
host_rows="${work}/host-rows.txt"
hostile_rows="${work}/hostile-rows.txt"
runner_rows="${work}/runner-rows.txt"
log="${work}/quickjsgui-posix.log"
rm -f -- "${corpus}" "${host_rows}" "${hostile_rows}" "${runner_rows}" \
    "${log}" "${work}"/quickjsgui-*.json

for pre in examples/07-quickjs/quickjsapp.pas \
           examples/07-quickjs/frontend/dist/index.html \
           examples/07-quickjs/frontend/dist/assets/app.js \
           test/cap9c2/quickjsgui.pas \
           test/cap9c2/fixture/index.html \
           test/cap9c2/fixture/assets/driver.js \
           build/quickjs-release/plugins.zip \
           build/quickjs-release/pweb.quickjs.registry.inc \
           build/quickjs-release/LICENSE.quickjs \
           tools/bundler/pwebbundle.pas; do
    [ -f "${pre}" ] || die "missing precondition: ${pre} -- the CAP-9C1 gate and the CAP-9C2 frontend build must have run first"
done

# every row this runner measures, appended in the SAME order as the ps1
rows=''
add_row() {
    local name="$1" ok="$2" detail="${3:-}"
    local value='no'
    [ "${ok}" = '1' ] && value='yes'
    rows="${rows}${name}=${value}"$'\n'
    if [ -n "${detail}" ]; then
        printf '[CAP-9C2] %s=%s | %s\n' "${name}" "${value}" "${detail}"
    else
        printf '[CAP-9C2] %s=%s\n' "${name}" "${value}"
    fi
    if [ "${ok}" != '1' ]; then
        # the failing process's own output goes to the JOB log, not only to
        # a file an upload step may never reach - see the ps1 sibling
        if [ -f "${log}" ]; then
            printf -- '----- CAP-9C2 process output (tail) -----\n'
            tail -n 120 "${log}"
            printf -- '----- end of process output -----\n'
        fi
        die "gate failed: ${name} (${detail})"
    fi
}
add_literal() { rows="${rows}$1"$'\n'; printf '[CAP-9C2] %s\n' "$1"; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# the canonical markers, from the one source each
host_pass="quickjsapp: $(sed -n "s/^    ': \(.*\) PASS';\$/\1/p" \
    examples/07-quickjs/quickjsapp.pas) PASS"
[ "${host_pass}" != 'quickjsapp:  PASS' ] ||
    die 'could not read VERDICT_PASS from quickjsapp.pas'
hostile_pass="$(sed -n "s/^  MARKER_PASS = '\([^']*\)';\$/\1/p" \
    test/cap9c2/quickjsgui.pas)"
[ -n "${hostile_pass}" ] || die 'could not read MARKER_PASS from quickjsgui.pas'
[ "$(printf '%s\n' "${hostile_pass}" | wc -l)" -eq 1 ] ||
    die 'expected exactly one MARKER_PASS constant in quickjsgui.pas'
printf '[CAP-9C2] canonical host marker: %s\n' "${host_pass}"
printf '[CAP-9C2] canonical hostile marker: %s\n' "${hostile_pass}"

mormot_units=(
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa
    -Fudeps/mormot2/src/script
)
host_units=(
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview -Fusrc/assets
    -Fusrc/script
)

os_name="$(uname -s)"

# ONE compile entry point per platform rather than shared arrays: bash 3.2
# (macOS /bin/bash) errors on expanding an EMPTY array under `set -u`, so a
# per-target extras array that happens to be empty on one target only is a
# latent break - the CAP-9C1 lesson, applied here from the start.
case "${os_name}" in
Linux)
    target='linux-x86_64'
    [ -f 'deps/mormot2/static/x86_64-linux/quickjs.o' ] ||
        die 'pinned quickjs.o missing under deps/mormot2/static/x86_64-linux'
    [ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export GDK_BACKEND=x11
    dist="${repo_root}/build/cap7l/webview-dist"
    [ -f "${dist}/libwebview.so.0.12" ] ||
        die 'libwebview.so.0.12 missing -- run test/cap7l/build_cap7l.sh first'
    dylib_name='libwebview.so.0.12'
    release="${repo_root}/dist/linux-x64/quickjs-release"
    exe_rel='quickjsapp'
    compile_bundler() {
        fpc -MObjFPC -Sh -B -FU"${work}/bundler-fpc" -FE"${work}/bin" \
            -Fusrc/assets -Fusrc/rpc "${mormot_units[@]}" \
            -Fldeps/mormot2/static/x86_64-linux tools/bundler/pwebbundle.pas
    }
    compile_pas() {
        local unitdir="$1" outdir="$2" src="$3"
        shift 3
        # -k-lgcc_s is REQUIRED here and nowhere before, and the reason is
        # worth stating: CAP-9C2 is the first Linux binary that links the
        # pinned quickjs.o AND libwebview. quickjs.o references __divti3
        # (128-bit division, a libgcc intrinsic). With quickjs.o alone the
        # linker resolved it from the libgcc_s it pulls in implicitly; once
        # libwebview joins the line, ld reports
        #   'libgcc_s.so.1: error adding symbols: DSO missing from command
        #    line'
        # - the symbol is findable but the DSO was never named, which
        # --as-needed will not do on the caller's behalf. Naming it is the
        # documented fix and costs nothing on a target that already links it.
        fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
            "${host_units[@]}" -Fusrc/platform/linux "$@" \
            "${mormot_units[@]}" -Fldeps/mormot2/static/x86_64-linux \
            "-Fl${dist}" -k'-rpath=$ORIGIN' -k-lgcc_s "${src}"
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
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: ${arch}" ;;
    esac
    dist="${PWEB_MACOS_DIST}"
    dylib_name="${PWEB_MACOS_DYLIB_VERSIONED}"
    [ -f "${dist}/${dylib_name}" ] ||
        die "staged dylib missing: ${dist}/${dylib_name}"
    [ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
        die "production Cocoa bridge object missing: ${PWEB_MACOS_BRIDGE_OBJ} -- run test/cap7m/build_cap7m.sh first"
    step 'build the pinned QuickJS static object (the mORMot release ships no darwin quickjs.o)'
    qjs_obj_dir="${work}/qjs-obj"
    tools/build_quickjs_darwin.sh "${qjs_obj_dir}" ||
        die 'tools/build_quickjs_darwin.sh FAILED'
    release="${repo_root}/dist/macos-${arch}/PWebQuickJS.app"
    exe_rel='Contents/MacOS/quickjsapp'
    compile_bundler() {
        fpc -MObjFPC -Sh -B -FU"${work}/bundler-fpc" -FE"${work}/bin" \
            -Fusrc/assets -Fusrc/rpc "${mormot_units[@]}" \
            "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
            tools/bundler/pwebbundle.pas
    }
    compile_pas() {
        local unitdir="$1" outdir="$2" src="$3"
        shift 3
        fpc -MObjFPC -Sh -B -FU"${unitdir}" -FE"${outdir}" \
            "${host_units[@]}" -Fusrc/platform/macos "$@" \
            "${mormot_units[@]}" -dLIBQUICKJSSTATIC -Fo"${qjs_obj_dir}" \
            "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
            "${src}"
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

printf '[CAP-9C2] target: %s\n' "${target}"
json="${work}/quickjsgui-${target}.json"

# --- 0/1. bundler + app.pwb, and the two-domain separation ----------------
mkdir -p -- "${work}/bundler-fpc" "${work}/bin" "${work}/app-fpc" \
    "${work}/app-bin" "${work}/gui-fpc" "${work}/gui-bin"
compile_bundler >> "${log}" 2>&1 ||
    { tail -n 40 "${log}" >&2; die 'bundler compile FAILED'; }

rm -rf -- "${release}"
case "${os_name}" in
Linux)  mkdir -p -- "${release}" ; app_pwb="${release}/app.pwb" ;;
Darwin) mkdir -p -- "${release}/Contents/MacOS" "${release}/Contents/Resources"
        app_pwb="${release}/Contents/Resources/app.pwb" ;;
esac

"${work}/bin/pwebbundle" examples/07-quickjs/frontend/dist "${app_pwb}" \
    >> "${log}" 2>&1 || { tail -n 20 "${log}" >&2; die 'app.pwb build FAILED'; }

app_names="$(unzip -Z1 "${app_pwb}")"
plugin_names="$(unzip -Z1 "${payload}/plugins.zip")"
leak="$(printf '%s\n' "${app_names}" |
    grep -E '^quickjs\.|plugin\.json$|(^|/)main\.js$' || true)"
add_row 'app_pwb_carries_no_plugin_source' \
    "$([ -z "${leak}" ] && echo 1 || echo 0)" "leak=${leak}"
leak="$(printf '%s\n' "${plugin_names}" |
    grep -E 'index\.html$|^assets/|manifest\.json$' || true)"
add_row 'plugins_zip_carries_no_frontend' \
    "$([ -z "${leak}" ] && echo 1 || echo 0)" "leak=${leak}"

# --- 0b. no CWD dependence, no discovery: source facts --------------------
# See the ps1 sibling: two Never-list items that are properties of ALL
# inputs rather than of the inputs a test happened to choose.
cwd_rx='GetCurrentDir|SetCurrentDir|ChDir'
discovery_rx='FindFirst|FindNext|FileAge|ReadDirectory|FindFirstChangeNotification|inotify|FSEvent|kqueue'
hits="$(grep -c -E "${cwd_rx}" examples/07-quickjs/quickjsapp.pas || true)"
add_row 'host_no_cwd_resolution' \
    "$([ "${hits}" = '0' ] && echo 1 || echo 0)" "hits=${hits}"
anchor="$(grep -c -E 'Executable\.ProgramFilePath' examples/07-quickjs/quickjsapp.pas || true)"
add_row 'host_resolves_from_executable' \
    "$([ "${anchor}" -ge 2 ] && echo 1 || echo 0)" "sites=${anchor}"
hits="$(cat examples/07-quickjs/quickjsapp.pas test/cap9c2/quickjsgui.pas |
    grep -c -E "${discovery_rx}" || true)"
add_row 'no_plugin_discovery_or_watching' \
    "$([ "${hits}" = '0' ] && echo 1 || echo 0)" "hits=${hits}"

# --- 2. compile the host WITH the generated registry ----------------------
compile_pas "${work}/app-fpc" "${work}/app-bin" \
    examples/07-quickjs/quickjsapp.pas -Fibuild/quickjs-release \
    >> "${log}" 2>&1 || { tail -n 40 "${log}" >&2; die 'quickjsapp.pas compile FAILED'; }
compile_pas "${work}/gui-fpc" "${work}/gui-bin" \
    test/cap9c2/quickjsgui.pas \
    >> "${log}" 2>&1 || { tail -n 40 "${log}" >&2; die 'quickjsgui.pas compile FAILED'; }
add_row 'registry_compiled_into_host' \
    "$([ -x "${work}/app-bin/quickjsapp" ] && echo 1 || echo 0)" ''

# --- 3. assemble the EXACT release layout --------------------------------
case "${os_name}" in
Linux)
    cp -f -- "${work}/app-bin/quickjsapp" "${release}/"
    cp -f -- "${payload}/plugins.zip" "${release}/"
    cp -f -- "${payload}/LICENSE.quickjs" "${release}/"
    cp -f -- "${dist}/${dylib_name}" "${release}/"
    cp -f -- "${dist}/LICENSE.webview" "${release}/"
    expected_layout='file:LICENSE.quickjs
file:LICENSE.webview
file:app.pwb
file:libwebview.so.0.12
file:plugins.zip
file:quickjsapp'
    archive="${release}/plugins.zip"
    ;;
Darwin)
    cp -f -- "${work}/app-bin/quickjsapp" "${release}/Contents/MacOS/"
    cp -f -- "${dist}/${dylib_name}" "${release}/Contents/MacOS/"
    cp -f -- "${payload}/plugins.zip" "${release}/Contents/Resources/"
    cp -f -- "${payload}/LICENSE.quickjs" "${release}/Contents/Resources/"
    cp -f -- "${dist}/LICENSE.webview" "${release}/Contents/Resources/"
    cat > "${release}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>quickjsapp</string>
	<key>CFBundleIdentifier</key>
	<string>dev.pweb.cap9c2.quickjs</string>
	<key>CFBundleName</key>
	<string>PWebQuickJS</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>${PWEB_MACOS_DEPLOYMENT_TARGET}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
    expected_layout="dir:Contents
dir:Contents/MacOS
dir:Contents/Resources
file:Contents/Info.plist
file:Contents/MacOS/${dylib_name}
file:Contents/MacOS/quickjsapp
file:Contents/Resources/LICENSE.quickjs
file:Contents/Resources/LICENSE.webview
file:Contents/Resources/app.pwb
file:Contents/Resources/plugins.zip"
    archive="${release}/Contents/Resources/plugins.zip"
    ;;
esac

# files, directories AND symlinks - "smallest possible" is a claim that
# rots silently unless the whole set is asserted
layout_listing() {
    ( cd -- "${release}" && find . -mindepth 1 | while IFS= read -r p; do
        if [ -L "${p}" ]; then k='link'
        elif [ -d "${p}" ]; then k='dir'
        else k='file'; fi
        printf '%s:%s\n' "${k}" "${p#./}"
      done | LC_ALL=C sort )
}
actual_layout="$(layout_listing)"
expected_sorted="$(printf '%s\n' "${expected_layout}" | LC_ALL=C sort)"
add_row 'release_layout_exact' \
    "$([ "${actual_layout}" = "${expected_sorted}" ] && echo 1 || echo 0)" \
    "got=[$(printf '%s' "${actual_layout}" | tr '\n' ' ')]"

add_row 'registry_not_shipped' \
    "$([ -z "$(printf '%s\n' "${actual_layout}" | grep 'registry\.inc' || true)" ] && echo 1 || echo 0)" ''

license_path="${release}/LICENSE.quickjs"
if [ "${os_name}" = 'Darwin' ]; then
    license_path="${release}/Contents/Resources/LICENSE.quickjs"
fi
license_sha="$(sha256_of "${license_path}")"
add_row 'license_quickjs_sha256' \
    "$([ "${license_sha}" = '8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc' ] && echo 1 || echo 0)" \
    "sha256=${license_sha}"
license_count="$(printf '%s\n' "${actual_layout}" | grep -c 'LICENSE\.quickjs$' || true)"
add_row 'license_quickjs_once' \
    "$([ "${license_count}" = '1' ] && echo 1 || echo 0)" "count=${license_count}"
embedded="$( { printf '%s\n' "${app_names}"; printf '%s\n' "${plugin_names}"; } |
    grep -c 'LICENSE' || true)"
add_row 'license_not_embedded' \
    "$([ "${embedded}" = '0' ] && echo 1 || echo 0)" ''

exe="${release}/${exe_rel}"
golden="${work}/plugins.zip.golden"
cp -f -- "${archive}" "${golden}"

# --- 4. run the host from an unrelated CWD, sampling listeners ------------
run_host() {
    local tag="$1"
    shift
    local out="${work}/run-${tag}.out"
    local sample="${1:-}"
    if [ "${sample}" = 'sample' ]; then shift; fi
    rm -f -- "${out}"
    # `exec` so the backgrounded subshell BECOMES the host: without it $!
    # is the subshell and the listener sampling below would be watching a
    # process that never opens a socket either way - a zero that proves
    # nothing, which is the exact shape of evidence this shard refuses
    ( cd / && exec "${exe}" "$@" ) > "${out}" 2>&1 &
    local pid=$!
    listener_max=0
    if [ "${sample}" = 'sample' ]; then
        local i n
        for i in $(seq 1 60); do
            kill -0 "${pid}" 2>/dev/null || break
            n="$(sample_listeners "${pid}")"
            # an if, never `[ ... ] && x=y`: under `set -e` a false test as
            # the last command of a list aborts the script
            if [ "${n}" -gt "${listener_max}" ]; then listener_max="${n}"; fi
            sleep 0.5
        done
    fi
    set +e
    wait "${pid}"
    host_exit=$?
    set -e
    host_text="$(cat "${out}")"
    {
        printf '===== %s (exit %s) =====\n' "${tag}" "${host_exit}"
        printf '%s\n' "${host_text}"
    } >> "${log}"
}

run_host green sample "--pweb-verdict=${work}/host-verdict.txt" \
    "--pweb-corpus=${host_rows}" '--pweb-autoclose-ms=240000'
add_row 'host_exit_zero' "$([ "${host_exit}" -eq 0 ] && echo 1 || echo 0)" \
    "exit=${host_exit}"
add_row 'host_pass_marker' \
    "$(printf '%s' "${host_text}" | grep -qF "${host_pass}" && echo 1 || echo 0)" ''
add_row 'host_corpus_written' "$([ -s "${host_rows}" ] && echo 1 || echo 0)" ''
listeners_seen="${listener_max}"
add_row 'listeners' "$([ "${listeners_seen}" -eq 0 ] && echo 1 || echo 0)" \
    "max_sampled=${listeners_seen}"
add_literal "listeners_count=${listeners_seen}"

# --- 5. the whole-archive NEGATIVE matrix, on the REAL layout -------------
test_refusal() {
    local tag="$1" expect="$2"
    run_host "${tag}" '--pweb-autoclose-ms=60000'
    local ok=1
    # every branch an `if`, never a `&&` chain: under `set -e` a false test
    # at the end of a list aborts the script, which would turn a REFUSAL
    # that behaved correctly into a runner crash
    if [ "${host_exit}" -eq 0 ]; then ok=0; fi
    if ! printf '%s' "${host_text}" | grep -q "plugins.zip REFUSED (${expect})"; then ok=0; fi
    if ! printf '%s' "${host_text}" | grep -q 'webviews_created=0'; then ok=0; fi
    if ! printf '%s' "${host_text}" | grep -q 'soa_calls=0'; then ok=0; fi
    if printf '%s' "${host_text}" | grep -qF "${host_pass}"; then ok=0; fi
    add_row "negative_${tag}" "${ok}" "exit=${host_exit} expect=${expect}"
}

golden_bytes="$(wc -c < "${golden}" | tr -d ' ')"

rm -f -- "${archive}"
test_refusal 'missing' 'package_missing'

head -c $(( golden_bytes / 2 )) "${golden}" > "${archive}"
test_refusal 'truncated' 'package_size'

cat "${golden}" > "${archive}"
head -c 64 /dev/zero >> "${archive}"
test_refusal 'overlong' 'package_size'

# same LENGTH, different bytes: only the digest can refuse this one
cp -f -- "${golden}" "${archive}"
printf '\xff' | dd of="${archive}" bs=1 seek=$(( golden_bytes / 2 )) \
    count=1 conv=notrunc status=none
test_refusal 'digest' 'package_digest'

# see the ps1 sibling: the two rows this matrix cannot reach from outside
# a compiled host are proven by CAP-9C1 on a mutated registry copy, in
# the same job
add_literal 'negative_inventory_and_registry=cap9c1'

cp -f -- "${golden}" "${archive}"
run_host restored "--pweb-corpus=${host_rows}" '--pweb-autoclose-ms=240000'
ok=1
if [ "${host_exit}" -ne 0 ]; then ok=0; fi
if ! printf '%s' "${host_text}" | grep -qF "${host_pass}"; then ok=0; fi
add_row 'layout_recovers_after_negatives' "${ok}" "exit=${host_exit}"

# --- 6. the hostile-package real-GUI harness -----------------------------
cp -f -- "${dist}/${dylib_name}" "${work}/gui-bin/"
gui_out="${work}/run-hostile.out"
rm -f -- "${gui_out}"
set +e
( cd / && "${work}/gui-bin/quickjsgui" "--pweb-corpus=${hostile_rows}" \
    '--pweb-autoclose-ms=240000' ) > "${gui_out}" 2>&1
gui_exit=$?
set -e
gui_text="$(cat "${gui_out}")"
{ printf '===== hostile (exit %s) =====\n' "${gui_exit}"
  printf '%s\n' "${gui_text}"; } >> "${log}"
add_row 'hostile_exit_zero' "$([ "${gui_exit}" -eq 0 ] && echo 1 || echo 0)" \
    "exit=${gui_exit}"
add_row 'hostile_pass_marker' \
    "$(printf '%s' "${gui_text}" | grep -qF "${hostile_pass}" && echo 1 || echo 0)" ''
add_row 'hostile_corpus_written' "$([ -s "${hostile_rows}" ] && echo 1 || echo 0)" ''

# --- the reparse leg: json only, never in the digest ----------------------
# On POSIX a symlink always creates, so unlike the ps1 sibling this leg is
# never waived here. It still stays out of the corpus, so the two runners
# produce the same rows.
cp -f -- "${golden}" "${archive}"
rm -f -- "${archive}"
ln -s "${golden}" "${archive}"
run_host reparse '--pweb-autoclose-ms=60000'
reparse_result='waived'
if [ "${host_exit}" -ne 0 ] &&
   printf '%s' "${host_text}" | grep -q 'plugins.zip REFUSED (package_unreadable)' &&
   printf '%s' "${host_text}" | grep -q 'webviews_created=0'; then
    reparse_result='yes'
fi
rm -f -- "${archive}"
cp -f -- "${golden}" "${archive}"
[ "${reparse_result}" = 'yes' ] || die 'negative_reparse did not refuse a symlinked archive'
printf '[CAP-9C2] negative_reparse=%s (json only, never in the digest)\n' "${reparse_result}"

# --- 7. assemble ONE corpus and hash it ----------------------------------
printf '%s' "${rows}" > "${runner_rows}"
{
    printf 'schema=1\n'
    cat "${host_rows}" "${hostile_rows}" "${runner_rows}" |
        sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]*$//'
    printf 'verdict=PASS\n'
} > "${corpus}"
digest="$(sha256_of "${corpus}")"
printf '[CAP-9C2] quickjs_gui_digest: %s\n' "${digest}"

row_value() {
    local name="$1"
    sed -n "s/^${name}=\(.*\)\$/\1/p" "${corpus}" | head -n 1
}
cat > "${json}" <<JSON
{
  "schema": 1,
  "target": "${target}",
  "overall": "PASS",
  "gui_digest": "${digest}",
  "listeners": ${listeners_seen},
  "negative_reparse": "${reparse_result}",
  "ui_add": "$(row_value ui_add)",
  "quickjs_add": "$(row_value quickjs_add)",
  "reporting_code": "$(row_value reporting_code)",
  "reporting_soa_count": "$(row_value reporting_soa_count)",
  "reporting_denied_bridge": "$(row_value reporting_denied_bridge_delta)",
  "opener_reached": "$(row_value opener_reached)",
  "ui_rendered": "$(row_value ui_rendered)",
  "concurrent_overlap": "$(row_value concurrent_overlap)",
  "no_cross_delivery": "$(row_value no_cross_delivery)",
  "plugin_archive_verified": "$(row_value plugin_archive_verified)",
  "plugin_inventory_verified": "$(row_value plugin_inventory_verified)",
  "quickjs_window_absent": "$(row_value quickjs_window_absent)",
  "quickjs_document_absent": "$(row_value quickjs_document_absent)",
  "quickjs_webkit_channel_absent": "$(row_value quickjs_webkit_channel_absent)",
  "quickjs_webview2_channel_absent": "$(row_value quickjs_webview2_channel_absent)",
  "quickjs_raw_webview_invoke_absent": "$(row_value quickjs_raw_webview_invoke_absent)",
  "same_scheduler": "$(row_value same_scheduler)",
  "same_policy": "$(row_value same_policy)",
  "same_bridge": "$(row_value same_bridge)",
  "same_server": "$(row_value same_server)",
  "browser_plugin_store_arrivals": "$(row_value browser_plugin_store_arrivals)",
  "quickjs_app_store_arrivals": "$(row_value quickjs_app_store_arrivals)",
  "browser_plugin_script_marker": "$(row_value browser_plugin_script_marker)",
  "raw_channel_source_bytes": "$(row_value raw_channel_source_bytes)",
  "neighbour_survived_timeout": "$(row_value neighbour_survived_timeout)",
  "ui_survived_timeout": "$(row_value ui_survived_timeout)",
  "reload_generation_changed": "$(row_value reload_generation_changed)",
  "clean_shutdown": "$(row_value clean_shutdown)",
  "hostile_running": "$(row_value h1_running_plugins)",
  "hostile_failed": "$(row_value h1_failed_plugins)",
  "license_quickjs_sha256": "${license_sha}",
  "release_layout": "$(row_value release_layout_exact)"
}
JSON

printf '\n[CAP-9C2] quickjsgui verdict: PASS\n'
