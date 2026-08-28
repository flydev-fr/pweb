#!/usr/bin/env bash
#
# CAP-10B2 (Linux and macOS): prove the GENERATED Pas2JS project builds and
# runs.
#
# The POSIX twin of prove_cap10b2.ps1, and it makes the identical claims in
# the identical order. This is a TEST HARNESS and not `pweb build`: CAP-10B2
# exposes no build command and nothing here is a step towards one.
#
# THE RELOCATION IS THE PROOF, and here it is stronger than the React one:
# there is no package manager, so every artifact of the build lands OUTSIDE
# the project and the relocated copy is untouched too.
#
# THE SDK ROOT IS THE OTHER PROOF. The only -Fu handed to the Pas2JS compiler
# for PWeb code names build/cap10b1/sdk/share/pweb/sdk/pas2js - the STAGED
# SDK - and the native compile names the staged src/.
#
# Two things differ per platform and both are at the seam, not in the claim:
#   - the pinned compiler lives in deps/pas2js-linux or deps/pas2js-darwin,
#     and on macOS arm64 it is the NATIVE build (Rosetta is banned by the
#     ratified no-translation invariant, and `-iSP` is asserted here);
#   - the release layout and the listening-socket sampler, exactly as
#     prove_cap10b1.sh splits them.
#
# Emits build/cap10b2/proof-<target>.json.
#
# Usage: test/cap10b2/prove_cap10b2.sh   (under xvfb-run on a headless Linux)
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

work="${repo_root}/build/cap10b2"
b1="${repo_root}/build/cap10b1"
sdk_root="${b1}/sdk"
sdk_pas2js="${sdk_root}/share/pweb/sdk/pas2js"
source_project="${work}/project/demo"
bundler="${b1}/bin/pwebbundle"
log="${work}/proof.log"

die() { printf '[CAP-10B2] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10B2] === %s\n' "$*"; }

for pre in "${source_project}/pweb.json" "${bundler}" \
           "${sdk_pas2js}/pweb.native.pas" \
           "${sdk_root}/share/pweb/src/webview/pweb.webview.host.pas"; do
    [ -e "${pre}" ] ||
        die "missing precondition: ${pre} -- run build_cap10b1.sh and run_cap10b2_gates.ps1 first"
done
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
    compiler="${repo_root}/deps/pas2js-linux/bin/pas2js"
    dist_lib="${repo_root}/build/cap7l/webview-dist"
    dylib='libwebview.so.0.12'
    [ -f "${dist_lib}/${dylib}" ] ||
        die "staged webview library missing: ${dist_lib}/${dylib}"
    static_dir="${repo_root}/deps/mormot2/static/x86_64-linux"
    expected_compiler_arch='x86_64'
    compile_generated() {
        # -k-lgcc_s: the DSO is findable but was never NAMED, which
        # --as-needed will not do on the caller's behalf (the CAP-9C2
        # measurement, reused verbatim)
        fpc -MObjFPC -Sh -B -FU"${unit_dir}" -FE"${bin_dir}" \
            -Fu"${project}/src" "${sdk_units[@]}" \
            -Fu"${sdk_src}/platform/linux" \
            "${mormot_units[@]}" "-Fl${static_dir}" "-Fl${dist_lib}" \
            -k'-rpath=$ORIGIN' -k-lgcc_s "${project}/src/demo.lpr"
    }
    # A SAMPLER THAT NEVER SAMPLED reports a clean zero for any host, and
    # `pas2js_listener_count = 0` is an ABSOLUTE PIN in the aggregate - so a
    # missing tool would satisfy the pin by proving nothing. Refuse up front.
    command -v ss >/dev/null 2>&1 ||
        die 'ss(8) is required: without it listener_count would be a vacuous 0'
    sample_listeners() {
        local pid="$1" n=0 t=0 u=0
        t=$(ss -ltnp 2>/dev/null | grep -c "pid=${pid}," || true)
        u=$(ss -lunp 2>/dev/null | grep -c "pid=${pid}," || true)
        n=$(( t + u ))
        printf '%s' "${n}"
    }
    ;;
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    compiler="${repo_root}/deps/pas2js-darwin/bin/pas2js"
    case "$(uname -m)" in
        x86_64) target='macos-x86_64'; expected_compiler_arch='x86_64' ;;
        # THE NO-ROSETTA ASSERTION. Upstream publishes no aarch64 Pas2JS, so
        # tools/get-pas2js.ps1 compiles the SAME pinned logical version
        # natively from the pinned FPC revision. `-iSP` is the compiler's own
        # statement of the processor it was built for, so a leftover x86_64
        # binary running under translation is caught here rather than
        # silently accepted.
        arm64) target='macos-arm64'; expected_compiler_arch='aarch64' ;;
        *) die "unsupported macOS architecture: $(uname -m)" ;;
    esac
    dist_lib="${PWEB_MACOS_DIST}"
    dylib="${PWEB_MACOS_DYLIB_VERSIONED}"
    [ -f "${dist_lib}/${dylib}" ] || die "staged dylib missing: ${dist_lib}/${dylib}"
    [ -f "${PWEB_MACOS_BRIDGE_OBJ}" ] ||
        die "production Cocoa bridge object missing: ${PWEB_MACOS_BRIDGE_OBJ}"
    static_dir="${PWEB_MACOS_STATIC_DIR}"
    compile_generated() {
        fpc -MObjFPC -Sh -B -FU"${unit_dir}" -FE"${bin_dir}" \
            -Fu"${project}/src" "${sdk_units[@]}" \
            -Fu"${sdk_src}/platform/macos" \
            "${mormot_units[@]}" "${PWEB_MACOS_FPC_FLAGS[@]}" \
            "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" "${project}/src/demo.lpr"
    }
    # see the Linux branch: a sampler that never sampled satisfies an
    # absolute pin by proving nothing
    command -v lsof >/dev/null 2>&1 ||
        die 'lsof(8) is required: without it listener_count would be a vacuous 0'
    sample_listeners() {
        local pid="$1" n=0
        n=$(lsof -nP -p "${pid}" 2>/dev/null |
            grep -c -E 'TCP .*\(LISTEN\)|UDP ' || true)
        printf '%s' "${n}"
    }
    ;;
*)
    die "unsupported platform: ${os_name}"
    ;;
esac
[ -x "${compiler}" ] ||
    die "pinned pas2js missing at ${compiler} -- run: pwsh tools/get-pas2js.ps1"
printf '[CAP-10B2] target: %s\n' "${target}"

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
# THE NATIVE HALF OF THE SDK-ROOT CLAIM, asserted rather than assumed. The
# Pas2JS compile proves its one PWeb unit path names the staged SDK; the same
# has to be true of the ones the FPC compile is handed, and nothing had ever
# measured it - which is exactly how the POSIX CAP-10B1 proof kept a
# repo-relative platform path while its header claimed otherwise.
native_from_sdk=0
for u in "${sdk_units[@]}" "-Fu${sdk_src}/platform/linux" \
         "-Fu${sdk_src}/platform/macos"; do
    case "${u}" in
        "-Fu${sdk_src}/"*) ;;
        *) native_from_sdk=1
           require 1 "the native compile's PWeb unit path is not staged: ${u}" ;;
    esac
    case "${u}" in
        "-Fu${repo_root}/src/"*)
            native_from_sdk=1
            require 1 "the native compile names this repository's src/: ${u}" ;;
    esac
done
row pas2js_native_from_sdk_root "$(bool_row "${native_from_sdk}")"

# --- 1. relocate, and digest what must not change --------------------------
step 'relocate the created project into an unrelated staging path'
stage="${work}/stage"
rm -rf -- "${stage}"
mkdir -p -- "${stage}"
project="${stage}/demo"
cp -R -- "${source_project}" "${project}"
before_digest="$(tree_digest "${source_project}")"
row pas2js_tree_digest "${before_digest}"

# --- 2. the pinned compiler, identified ------------------------------------
step 'identify the pinned Pas2JS compiler'
compiler_version="$("${compiler}" -iV | tr -d '[:space:]')"
compiler_arch="$("${compiler}" -iSP | tr -d '[:space:]')"
compiler_os="$("${compiler}" -iSO | tr -d '[:space:]')"
[ "${compiler_version}" = '3.0.1' ] ||
    require 1 "the pinned Pas2JS reports ${compiler_version}, expected 3.0.1"
[ "${compiler_arch}" = "${expected_compiler_arch}" ] ||
    require 1 "the pinned Pas2JS is built for ${compiler_arch}, expected ${expected_compiler_arch}"
row pas2js_compiler_version "${compiler_version}"
row pas2js_compiler_arch "${compiler_arch}"
row pas2js_compiler_host "${compiler_os}/${compiler_arch}"
row pas2js_compiler_sha256 "$(sha_file "${compiler}")"
printf '[CAP-10B2] pas2js %s (%s/%s)\n' "${compiler_version}" \
    "${compiler_os}" "${compiler_arch}"

# --- 3. the frontend, compiled into an EXTERNAL stage ----------------------
step 'compile the generated Pascal frontend against the staged SDK'
dist_dir="${stage}/dist"
mkdir -p -- "${dist_dir}/assets"
out_js="${dist_dir}/assets/app.js"
row pas2js_compiler_invocation "pas2js @<project>/frontend/pas2js.cfg -Fu<sdk-root>/share/pweb/sdk/pas2js -o<stage>/dist/assets/app.js <project>/frontend/src/demoapp.lpr"
# THE STAGED SDK, ASSERTED RATHER THAN RECORDED. An invocation string in the
# evidence says what this script MEANT to do; these rules say what it
# actually did. Exactly one PWeb unit path reaches the compiler, it names the
# staged SDK root, and this repository's own sdk/pas2js is not among the
# arguments at all - so "the frontend compiles" cannot quietly mean "it
# compiles beside its own framework's git checkout".
compiler_args=( "@${project}/frontend/pas2js.cfg" "-Fu${sdk_pas2js}"
                "-o${out_js}" "${project}/frontend/src/demoapp.lpr" )
unit_paths=0
staged_paths=0
for a in "${compiler_args[@]}"; do
    case "${a}" in
        "-Fu${repo_root}/sdk/pas2js"*)
            require 1 "the frontend compile names this repository's sdk/pas2js: ${a}"
            unit_paths=$(( unit_paths + 1 ))
            ;;
        "-Fu${sdk_pas2js}")
            unit_paths=$(( unit_paths + 1 ))
            staged_paths=$(( staged_paths + 1 ))
            ;;
        -Fu*)
            require 1 "the frontend compile passes an unratified unit path: ${a}"
            unit_paths=$(( unit_paths + 1 ))
            ;;
    esac
done
[ "${unit_paths}" = '1' ] ||
    require 1 "the frontend compile passes ${unit_paths} unit paths, expected exactly 1"
if [ "${unit_paths}" = '1' ] && [ "${staged_paths}" = '1' ]; then
    row pas2js_sdk_from_sdk_root 'PASS'
else
    row pas2js_sdk_from_sdk_root 'FAIL'
    require 1 "the frontend compile's unit path is not the staged SDK"
fi
# `if cmd`, never `cmd` then `$?`. Under `set -euo pipefail` a bare failing
# command TERMINATES the script, so the row this harness would have written
# to explain the failure is never written at all - and the reader sees a raw
# compiler exit status where a diagnosed FAIL belongs. Every step below that
# is allowed to fail is written in a condition context for that reason.
if "${compiler}" "${compiler_args[@]}" >> "${log}" 2>&1; then
    frontend_built=0
else
    frontend_built=$?
fi
[ -f "${out_js}" ] || frontend_built=1
require "${frontend_built}" 'the generated Pas2JS frontend does not compile'
row pas2js_frontend_build "$(bool_row "${frontend_built}")"
[ "${frontend_built}" = '0' ] ||
    die 'CAP-10B2 build proof FAILED: the frontend did not compile'

# --- 4. the static output, normalised, assembled and swept -----------------
#
# THE NORMALISATION IS A MEASUREMENT, NOT A PREFERENCE. Pas2JS writes its
# output through the host's text layer: MEASURED on Windows, app.js begins
# EF BB BF and carries CRLF; on POSIX it carries LF. Packing the compiler's
# raw bytes would make the Pas2JS app.pwb an OS-family artifact and
# pas2js_static_inventory_digest unsatisfiable across four targets. Doing it
# on BOTH families - rather than only where the divergence was measured - is
# what makes the four-target field a property of the pipeline instead of a
# property of the host that happened to run it.
had_bom=0
had_cr=0
if head -c 3 -- "${out_js}" | od -An -tx1 | tr -d ' \n' | grep -q '^efbbbf$'; then
    had_bom=1
fi
if LC_ALL=C grep -q -- "$(printf '\r')" "${out_js}"; then had_cr=1; fi
# tail -c and tr, not sed or perl: GNU sed understands \xEF and BSD sed does
# not, and this script runs on both families
if [ "${had_bom}" = '1' ]; then
    tail -c +4 -- "${out_js}" > "${out_js}.norm"
    mv -f -- "${out_js}.norm" "${out_js}"
fi
if [ "${had_cr}" = '1' ]; then
    tr -d '\r' < "${out_js}" > "${out_js}.norm"
    mv -f -- "${out_js}.norm" "${out_js}"
fi
row pas2js_output_normalised "bom=${had_bom} cr=${had_cr}"

# the bootstrap, as a bundled classic script, byte-exactly with LF. -Jc
# concatenates the RTL and declares `rtl` without starting it, so a later
# classic script in the same global scope is all that is needed - no module,
# no defer, and above all no INLINE code, which the ratified script-src
# 'self' forbids and CAP-8B measured blocked on all three engines.
printf 'rtl.run();\n' > "${dist_dir}/assets/boot.js"
cp -f -- "${project}/frontend/index.html" "${dist_dir}/index.html"
cp -f -- "${project}/frontend/app.css" "${dist_dir}/assets/app.css"

observed_dist="$( ( cd -- "${dist_dir}" && find . -type f | sed 's|^\./||' |
    LC_ALL=C sort ) | tr '\n' '|')"
expected_dist="$(printf '%s\n' 'assets/app.css' 'assets/app.js' \
    'assets/boot.js' 'index.html' | LC_ALL=C sort | tr '\n' '|')"
[ "${observed_dist}" = "${expected_dist}" ] ||
    require 1 "the static output is ${observed_dist}"
row pas2js_static_inventory_digest "$( ( cd -- "${dist_dir}" &&
    find . -type f | sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r rel; do
        printf '%s %s %s\n' "${rel}" "$(wc -c < "${rel}" | tr -d ' ')" \
            "$(sha_file "${rel}")"
    done ) | sha_stdin)"

# the sweep. Developer paths, home directories, the checkout, the SDK root,
# any network fallback, any dev watcher and any source map: none of them may
# survive into something that ships inside app.pwb.
output_clean=0
for needle in '/Users/' '/home/' '\Users\' 'C:\' '%USERPROFILE%' \
              '/private/var/folders/' \
              "${repo_root}" "${sdk_pas2js}" "${stage}" 'localhost' \
              '127.0.0.1' 'file://' 'http://' 'https://' 'ws://' 'wss://' \
              'sourceMappingURL' 'import.meta.hot' '/@vite/client'; do
    if grep -qF -- "${needle}" "${out_js}"; then
        output_clean=1
        require 1 "the compiled frontend carries ${needle}"
    fi
done
[ ! -f "${out_js}.map" ] || require 1 'the production build emitted a source map'
row pas2js_output_sweep "$(bool_row "${output_clean}")"

# THE RAW BINDING, by occurrence classification rather than by an impossible
# whole-bundle ban. The SDK necessarily contains the binding - it IS the
# transport - so what is proven is OWNERSHIP: exactly one occurrence in the
# whole bundle, and that occurrence inside the rtl.module("pweb.native", ...)
# body. A second binding emitted by the application breaks the first; a
# binding emitted outside the SDK breaks the second.
# OCCURRENCES, not lines: `grep -c` counts matching lines, so two bindings on
# one line would read as one.
#
# `|| true` is load-bearing under `set -euo pipefail`: ZERO occurrences makes
# grep exit 1, pipefail propagates it, and the script would die instead of
# reporting "expected exactly 1" - turning the most interesting outcome this
# check has into a silent abort.
binding_count="$( { grep -o '__pweb_invoke' "${out_js}" || true; } | wc -l | tr -d ' ')"
[ "${binding_count}" = '1' ] ||
    require 1 "the compiled frontend names the raw native binding ${binding_count} time(s), expected exactly 1"
binding_line="$( { grep -n '__pweb_invoke' "${out_js}" || true; } |
    head -n 1 | cut -d: -f1)"
binding_owner=''
binding_next_module=''
if [ -n "${binding_line}" ]; then
    binding_owner="$( { head -n "${binding_line}" "${out_js}" |
        grep -oE '^rtl\.module\("[^"]+"' || true; } | tail -n 1 |
        sed 's/^rtl\.module("//; s/"$//')"
    # and the binding must lie INSIDE that module's body, not merely after
    # its opening line: a binding emitted at top level after the last module
    # would otherwise inherit the last module's name
    binding_next_module="$( { tail -n "+$(( binding_line + 1 ))" "${out_js}" |
        grep -n -m1 -E '^rtl\.module\("' || true; } | cut -d: -f1)"
    [ -n "${binding_next_module}" ] ||
        require 1 'the raw native binding is emitted after the last module body'
fi
[ "${binding_owner}" = 'pweb.native' ] ||
    require 1 "the raw native binding is emitted inside module '${binding_owner}', expected 'pweb.native'"
if [ "${binding_count}" = '1' ]; then
    row pas2js_app_raw_binding 'false'
else
    row pas2js_app_raw_binding 'true'
fi
if [ "${binding_owner}" = 'pweb.native' ]; then
    row pas2js_sdk_binding_owner 'true'
else
    row pas2js_sdk_binding_owner 'false'
fi
for channel in 'webkit.messageHandlers' 'chrome.webview'; do
    grep -qF -- "${channel}" "${out_js}" &&
        require 1 "the compiled frontend names the platform channel ${channel}" || true
done
grep -qE '<script[^>]*[[:space:]]src=' "${dist_dir}/index.html" ||
    require 1 'the built index.html has no external script'
grep -qE '<link[^>]*rel="stylesheet"' "${dist_dir}/index.html" ||
    require 1 'the built index.html does not link the stylesheet'
# no INLINE script: the ratified script-src 'self' carries no 'unsafe-inline'
# and CAP-8B measured an inline <script> blocked on all three engines
if grep -qE '<script(?![^>]*[[:space:]]src=)' "${dist_dir}/index.html" 2>/dev/null ||
   grep -E '<script[^>]*>' "${dist_dir}/index.html" |
       grep -qvE '[[:space:]]src='; then
    require 1 'the built index.html carries an inline script'
fi
# and the two scripts load IN ORDER: -Jc declares `rtl` without starting it,
# so boot.js must come after app.js or nothing runs
app_js_line="$(grep -n 'assets/app\.js' "${dist_dir}/index.html" | head -n 1 | cut -d: -f1)"
boot_js_line="$(grep -n 'assets/boot\.js' "${dist_dir}/index.html" | head -n 1 | cut -d: -f1)"
if [ -n "${app_js_line}" ] && [ -n "${boot_js_line}" ]; then
    [ "${app_js_line}" -lt "${boot_js_line}" ] ||
        require 1 'the built index.html loads boot.js before app.js'
else
    require 1 'the built index.html does not load both app.js and boot.js'
fi

# --- 5. app.pwb, through the frozen bundler --------------------------------
step 'app.pwb, through the frozen CAP-6 bundler'
app_pwb="${stage}/app.pwb"
if "${bundler}" "${dist_dir}" "${app_pwb}" >> "${log}" 2>&1; then
    pwb_built=0
else
    pwb_built=$?
fi
require "${pwb_built}" 'the app.pwb build FAILED'
row pas2js_app_pwb_bytes "$(wc -c < "${app_pwb}" | tr -d ' ')"
# the SEMANTIC inventory OF THE ARCHIVE - opened and projected, not inferred
# from the directory that went into it. The CAP-6/CAP-7L and CAP-10B0
# measurements say the container's BYTES are a toolchain and an OS-family
# property; its meaning is a function of the input, and the meaning is what
# four targets compare.
#
# The projection is CAP-7F's `emit_manifest`, reused verbatim in shape:
# `entry=<name> size=<n> sha256=<hex>` per entry, bytewise-sorted, one final
# newline. That also brings manifest.json - which the bundler owns and the
# dist never contained - inside the measurement, so a bundler that stopped
# stamping the protocol would be visible here.
zip_manifest="${stage}/app-pwb-manifest.txt"
: > "${zip_manifest}"
zip_entry_bin="${stage}/app-pwb-entry.bin"
while IFS= read -r zentry; do
    [ -n "${zentry}" ] || continue
    case "${zentry}" in */) continue ;; esac
    zpattern="$(printf '%s' "${zentry}" | sed -e 's/[[*?]/[&]/g')"
    unzip -p "${app_pwb}" "${zpattern}" > "${zip_entry_bin}"
    printf 'entry=%s size=%s sha256=%s\n' "${zentry}" \
        "$(wc -c < "${zip_entry_bin}" | tr -d ' ')" \
        "$(sha_file "${zip_entry_bin}")" >> "${zip_manifest}"
done < <(zipinfo -1 "${app_pwb}" | LC_ALL=C sort)
rm -f -- "${zip_entry_bin}"
[ -s "${zip_manifest}" ] || die "the app.pwb logical inventory came out empty"
row pas2js_app_pwb_entries "$(wc -l < "${zip_manifest}" | tr -d ' ')"
row pas2js_app_pwb_semantic_digest "$(sha_file "${zip_manifest}")"

# --- 6. the generated Pascal program, against the STAGED SDK ---------------
step 'compile the generated Pascal program against the staged SDK root'
unit_dir="${work}/app-units"
bin_dir="${work}/app-bin"
rm -rf -- "${unit_dir}" "${bin_dir}"
mkdir -p -- "${unit_dir}" "${bin_dir}"
if compile_generated >> "${log}" 2>&1; then
    native_built=0
else
    native_built=$?
fi
require "${native_built}" 'the generated Pascal program does not compile'
row pas2js_native_build "$(bool_row "${native_built}")"
[ -x "${bin_dir}/demo" ] || die 'the generated program produced no executable'

# THE EXECUTABLE COMPARISON, MEASURED AND REPORTED RATHER THAN ASSERTED. The
# two UI variants compile the same native source, so in principle they could
# produce the same binary; in practice the compiler is handed different
# absolute unit paths and records build metadata. Equality is observed, not
# required, and the row says which way it came out.
if [ -f "${b1}/app-bin/demo" ]; then
    if [ "$(sha_file "${b1}/app-bin/demo")" = "$(sha_file "${bin_dir}/demo")" ]; then
        row native_binary_equal 'true'
        row native_binary_note 'identical bytes'
    else
        row native_binary_equal 'false'
        row native_binary_note 'differs: the two projects compile from different absolute paths'
    fi
else
    row native_binary_equal 'not_measured'
    row native_binary_note 'the CAP-10B1 react executable was not present'
fi

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
    cp -f -- "${dist_lib}/${dylib}" "${release}/"
    exe="${release}/demo"
    expected_layout="app.pwb|demo|${dylib}"
    ;;
Darwin)
    # a .app, because WKWebView keys persistent state by bundle identifier
    # and an unbundled executable has none. The identity comes from the
    # GENERATED descriptor, unchanged since the developer stated it.
    bundle_id="$( { grep -o '"bundleId"[^,]*' "${project}/pweb.json" || true; } |
        sed 's/.*"bundleId"[^"]*"\([^"]*\)".*/\1/')"
    app_version="$( { grep -o '"version"[^,]*' "${project}/pweb.json" || true; } |
        head -n 1 | sed 's/.*"version"[^"]*"\([^"]*\)".*/\1/')"
    [ -n "${bundle_id}" ] || die 'could not read bundleId from the generated pweb.json'
    [ -n "${app_version}" ] || die 'could not read version from the generated pweb.json'
    app="${release}/Demo.app"
    mkdir -p -- "${app}/Contents/MacOS" "${app}/Contents/Resources"
    cp -f -- "${bin_dir}/demo" "${app}/Contents/MacOS/"
    cp -f -- "${dist_lib}/${dylib}" "${app}/Contents/MacOS/"
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
    exe="${app}/Contents/MacOS/demo"
    expected_layout="Info.plist|demo|${dylib}|app.pwb"
    ;;
esac

observed_layout="$( ( cd -- "${release}" && find . -type f |
    sed 's|.*/||' | LC_ALL=C sort ) | tr '\n' '|')"
expected_sorted="$(printf '%s\n' ${expected_layout//|/ } | LC_ALL=C sort |
    tr '\n' '|')"
if [ "${observed_layout}" = "${expected_sorted}" ]; then
    row pas2js_loose_assets 'false'
else
    row pas2js_loose_assets 'true'
    require 1 "the release layout is ${observed_layout}, expected ${expected_sorted}"
fi

# an unrelated CWD, deliberately: app.pwb is resolved from the EXECUTABLE and
# a run that only works from its own directory has not proved that.
#
# `exec` matters: it REPLACES the subshell with the application, so $! is the
# application's own pid. Without it the listener sampler would be watching a
# shell that owns no sockets and would report a clean zero for any host.
autoclose_ms=20000
run_cwd="$(mktemp -d)"
started="$(date +%s)"
( cd -- "${run_cwd}" &&
  exec "${exe}" "--pweb-verdict=${verdict_file}" "--pweb-autoclose-ms=${autoclose_ms}" \
      > "${out_file}" 2>&1 ) &
app_pid=$!
listener_max=0
for _ in $(seq 1 60); do
    kill -0 "${app_pid}" 2>/dev/null || break
    n="$(sample_listeners "${app_pid}")"
    [ -n "${n}" ] || n=0
    if [ "${n}" -gt "${listener_max}" ]; then listener_max="${n}"; fi
    sleep 0.5
done
# BOUNDED, and killed rather than waited on forever. A process that outlives
# its auto-close window plus a generous margin has hung, and hanging until
# the 30-minute CI step timeout would produce no evidence at all - which is
# precisely the "no report received" conflation this harness exists to avoid.
hung=0
for _ in $(seq 1 120); do
    kill -0 "${app_pid}" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "${app_pid}" 2>/dev/null; then
    hung=1
    kill -9 "${app_pid}" 2>/dev/null || true
fi
wait "${app_pid}" && app_exit=0 || app_exit=$?
[ "${hung}" = '0' ] ||
    require 1 "the generated application did not exit within its window and was killed -- a HUNG RUN, which is a timing observation and not a runtime verdict"
elapsed_ms=$(( ( $(date +%s) - started ) * 1000 ))
cat -- "${out_file}" || true
{ printf '===== app run (exit %s, %sms) =====\n' "${app_exit}" "${elapsed_ms}"
  cat -- "${out_file}"; } >> "${log}"

row pas2js_app_exit "${app_exit}"
row pas2js_run_elapsed_ms "${elapsed_ms}"
row pas2js_listener_count "${listener_max}"
[ "${app_exit}" = '0' ] || require 1 "the generated application exited ${app_exit}"
[ "${listener_max}" = '0' ] ||
    require 1 "the generated application opened ${listener_max} listener(s)"
[ -f "${verdict_file}" ] && [ "$(tr -d '\r\n' < "${verdict_file}")" = 'demo: ok' ] ||
    require 1 'the generated application did not write its verdict'
if [ "${app_exit}" = '0' ] && grep -q 'demo: clean exit' "${out_file}"; then
    row pas2js_clean_shutdown 'true'
else
    row pas2js_clean_shutdown 'false'
fi

# the page's own report. Every field is REQUIRED: a report that arrived with
# a false in it is a failure, and a report that never arrived is a failure
# too - and the two are named DIFFERENTLY, because a page that did not report
# inside its window is a timing observation and not a runtime defect.
# deferred-work.md records exactly that shape happening to the CAP-5 Pas2JS
# smoke, undiagnosed, so this harness refuses to conflate them.
# `|| true` is the whole point of this line. Without it, `set -euo pipefail`
# turns "the page never reported" into a silent abort - and the branch below,
# which exists specifically so an intermittent timing failure is NOT reported
# as a runtime defect, would be unreachable on exactly the run it was written
# for.
report_fields=''
report="$( { grep -o 'demo: ready {.*}' "${out_file}" || true; } | tail -n 1 |
    sed 's/^demo: ready //')"
if [ -n "${report}" ]; then
    row pas2js_report_received 'true'
else
    row pas2js_report_received 'false'
    require 1 "the generated application printed no ready report within ${autoclose_ms}ms (ran ${elapsed_ms}ms) -- NO REPORT RECEIVED, which is a timing observation and not a runtime verdict"
fi
if [ -n "${report}" ]; then
    for flag in html css js secure handshake rpc errmap; do
        if printf '%s' "${report}" | grep -q "\"${flag}\":true"; then
            row "pas2js_${flag}" 'true'
        else
            row "pas2js_${flag}" 'false'
            require 1 "the page reported ${flag} = false"
        fi
    done
    if printf '%s' "${report}" | grep -q '"value":42'; then
        row pas2js_rpc_result '42'
    else
        row pas2js_rpc_result '0'
        require 1 "CalculatorService.Add did not return 42: ${report}"
    fi
    row pas2js_secure_origin "$(if printf '%s' "${report}" | grep -q '"secure":true'; \
        then printf 'PASS'; else printf 'FAIL'; fi)"
    row pas2js_error_mapping "$(if printf '%s' "${report}" | grep -q '"errmap":true'; \
        then printf 'PASS'; else printf 'FAIL'; fi)"
    # THE EXACT REPORT SHAPE, and it is the React starter's: both pages answer
    # the same eight questions under the same names, which is what makes the
    # parity comparison below a comparison rather than two separate readings
    report_fields="$(printf '%s' "${report}" | tr ',' '\n' |
        sed 's/^[{ ]*"//; s/".*$//' | LC_ALL=C sort | tr '\n' ',' |
        sed 's/,$//')"
    row pas2js_report_fields "${report_fields}"
    [ "${report_fields}" = 'css,errmap,handshake,html,js,rpc,secure,value' ] ||
        require 1 "the pas2js page reported the field set '${report_fields}'"
fi

# --- 8. the project the build was NOT allowed to touch ---------------------
after_digest="$(tree_digest "${source_project}")"
if [ "${after_digest}" = "${before_digest}" ]; then
    row pas2js_tree_unchanged 'PASS'
else
    row pas2js_tree_unchanged 'FAIL'
    require 1 'the build mutated the generated project'
fi
# and the relocated COPY is untouched too, which is the stronger claim the
# Pas2JS path can make and the React one cannot: with no package manager
# there is nothing to materialise into a working tree at all
if [ "$(tree_digest "${project}")" = "${before_digest}" ]; then
    row pas2js_build_out_of_tree 'PASS'
else
    row pas2js_build_out_of_tree 'FAIL'
    require 1 'the build wrote into the relocated project copy'
fi

# --- 9. React/Pas2JS backend parity ----------------------------------------
#
# The parity claim is RUNTIME and BACKEND, never source-language identity:
# same secure origin, same handshake, same 42, same typed rejection, no
# listener and no loose asset on either. The React half was measured minutes
# ago by the CAP-10B1 proof in this same job, so the comparison is between
# two records rather than between a record and a memory.
react_proof="${b1}/proof-${target}.json"
if [ -f "${react_proof}" ]; then
    parity=0
    for flag in html css js secure handshake rpc errmap; do
        grep -q "\"${flag}\": \"true\"" "${react_proof}" || {
            parity=1
            require 1 "the CAP-10B1 react record does not report ${flag} = true"
        }
    done
    grep -q '"rpc_result": 42' "${react_proof}" || {
        parity=1
        require 1 'the CAP-10B1 react record does not report rpc_result 42'
    }
    grep -q '"listener_count": 0' "${react_proof}" || {
        parity=1
        require 1 'the CAP-10B1 react record reports a listening socket'
    }
    grep -q '"loose_assets_used": "false"' "${react_proof}" || {
        parity=1
        require 1 'the CAP-10B1 react record reports a loose asset'
    }
    # THE REPORT SHAPE, compared PAGE TO PAGE rather than each against a
    # literal. Both starters answer the same eight questions under the same
    # names; asserting only the Pas2JS set against a constant would have let
    # the React page grow or lose a field with the parity claim still green.
    react_fields="$( { grep -o '"report_fields": "[^"]*"' "${react_proof}" || true; } |
        head -n 1 | sed 's/.*: "//; s/"$//')"
    if [ -z "${react_fields}" ]; then
        parity=1
        require 1 'the CAP-10B1 react record carries no report_fields'
    elif [ "${react_fields}" != "${report_fields}" ]; then
        parity=1
        require 1 "the two pages report different shapes: react '${react_fields}' vs pas2js '${report_fields}'"
    fi
    row react_pas2js_parity "$(bool_row "${parity}")"
    if grep -q '"rpc_result": 42' "${react_proof}"; then
        row react_regression_runtime 'PASS'
    else
        row react_regression_runtime 'FAIL'
    fi
else
    require 1 "the CAP-10B1 proof record is absent at ${react_proof} -- backend parity cannot be a claim about a measurement nobody made"
fi

row target "${target}"
if [ "${failures}" -eq 0 ]; then
    row pas2js_proof_corpus 'PASS'
else
    row pas2js_proof_corpus 'FAIL'
fi

# ONE writer for the JSON, from the tab-separated rows: two writers is how a
# corpus ends up with two shapes. The numeric keys are NAMED rather than
# sniffed - a sha256 that happened to be sixty-four decimal digits would
# otherwise be emitted as a number.
# EVERY key the PowerShell twin emits as a JSON number must be here, or the
# two records carry the same fact in two shapes and the emitter's numeric
# reader silently substitutes 0 for the quoted one. MEASURED on hosted run
# 33158296971: `pas2js_app_pwb_entries` was missing from this list, the three
# POSIX targets published 0 where Windows published 5, and the aggregator's
# BAD-BUNDLE-INVENTORY branch refused all three - which is the layered
# defence working, and is why the count is a compared field at all.
numeric_keys='|pas2js_app_exit|pas2js_listener_count|pas2js_rpc_result|pas2js_app_pwb_bytes|pas2js_app_pwb_entries|pas2js_run_elapsed_ms|'
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
printf '[CAP-10B2] evidence: %s\n' "${evidence}"
cat -- "${evidence}"

[ "${failures}" -eq 0 ] ||
    die "CAP-10B2 build proof FAILED: ${failures} failure(s)"
printf '[CAP-10B2] the generated Pas2JS project builds and runs on %s\n' "${target}"
