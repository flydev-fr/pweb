#!/usr/bin/env bash
#
# CAP-7M2: the macOS release products, assembled, gated and RUN - the whole
# shard's proof in one script, M18 discipline throughout.
#
# Per architecture this assembles TWO .app products into
# dist/macos-<arch>/release/:
#
#   PWebReleaseReact.app    dev.pweb.release.react
#   PWebReleasePas2js.app   dev.pweb.release.pas2js
#
# differing ONLY in app.pwb and Info.plist identity: releaseapp and the
# dylib are asserted byte-identical across both (R8), which is the
# hash-proven form of "the host has no frontend-kind branch". Two bundle
# identifiers because WebKit keys persistent state by identifier - distinct
# ids make per-frontend state disjoint and LaunchServices instance identity
# unambiguous.
#
# What is asserted, per product:
#
#   R1   the .app is EXACTLY this tree - files, directories AND the absence
#        of anything else, symlinks included (find over files+links+dirs,
#        string compare against the expected set); the release dir holds
#        exactly the two products;
#   R2   direct launch x2 from a relocated copy under a temp path carrying
#        a space AND a non-ASCII character, from CWD=/, with all three
#        DYLD_* hints stripped -> the canonical 42 PASS marker + clean exit
#        (the second run is the R9 warm rerun: a FULL verdict again,
#        including the live RPC 42 - and it also proves the argv autoclose
#        WINS over a deliberately huge PWEB_SMOKE_AUTOCLOSE_MS);
#   R3   LaunchServices launch (open -W -n) with the verdict file named in
#        argv - `open -W` forwards neither stdout nor the exit code and
#        LaunchServices delivers no environment, so a per-run verdict path
#        in argv is the one deterministic evidence channel. The wait is
#        BOUNDED here (autoclose + a wide margin), so a wedged instance
#        fails this gate instead of idling out the CI step budget;
#   R9   per-frontend WebKit state under the product's own bundle id is
#        removed between frontends - ONLY ~/Library/WebKit/<id> and
#        ~/Library/Caches/<id>, through the deletion guard with the allowed
#        root passed explicitly (~/Library/HTTPStorages/<id> is per-id state
#        too: RECORDED, never cleaned - the ratified bounds name two trees);
#   R10  plutil -lint clean, semantic readback of every key, regeneration
#        byte-identical, version pair greped strictly from
#        pweb.rpc.support.pas, LSMinimumSystemVersion == the Mach-O minos;
#   R11  zero listening TCP sockets held by the releaseapp process, sampled
#        for the WHOLE life of EVERY direct run (the M20 mechanism; WebKit
#        child IPC is not a finding);
#   R13  app.pwb rebuilt after touching the dist mtimes is byte-identical;
#   R14  every bundled Mach-O is job-arch only, minos-floored, @rpath-loaded
#        with an @executable_path rpath, and neither the executable nor the
#        bundled dylib references a checkout path.
#
# Then the refusal matrix on the React product: R4 missing (WITH a verdict
# file, proving a refused launch still leaves a FAIL verdict atomically),
# R5 truncated + garbage, R6 hidden dylib, and a bogus-argument refusal -
# typed markers, nonzero exits, no runtime verdict in any refusal log, and
# the layout restored and re-asserted afterwards.
#
# The runtime PASS marker is greped from the VERDICT_PASS constant in
# examples/08-release/releaseapp.pas - the same single-source discipline the
# version pair gets - so this gate can never drift into grepping a line
# nobody emits.
#
# Codesign state is RECORDED (ad-hoc at most, never product signing). If a
# LaunchServices launch leaves no verdict (which a refused launch and a
# crashed instance produce identically - the record says `no-verdict`, not
# more than it knows), a deterministic `codesign -s -` is applied to the
# RELOCATED copy as recorded local prep, the relocated copy's state is
# re-recorded, and the launch retried exactly once. The dist products are
# never signed, which is what keeps the R8 hashes honest.
#
# Emits manifest-<frontend>.txt (the logical app.pwb inventory) and
# inventory-<frontend>.txt (identity + hashes + toolchain facts) into
# build/cap7m/release-apps/ for the cross-architecture compare job (R7).
#
# Prerequisites: test/cap7m/build_cap7m_release.sh, both frontend dists.
#
# Usage: test/cap7m/run_cap7m_release.sh [--clean]
#        --clean is OPT-IN; without it a stale work directory is a refusal.
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

eval "$(cap7m_take_clean_flag "$@")"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
record_environment

for tool in otool plutil shasum zipinfo unzip lsof open; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

bin="${repo_root}/build/cap7m/bin"
ex="${repo_root}/build/cap7m/ex"
logs="${repo_root}/build/cap7m/release-apps"
release_root="${repo_root}/dist/macos-${PWEB_MACOS_HOST_ARCH}/release"
react_dist="${repo_root}/examples/04-react/frontend/dist"
p2j_dist="${repo_root}/examples/05-pas2js/frontend/dist"

[ -x "${ex}/releaseapp" ] ||
    die 'releaseapp missing -- run test/cap7m/build_cap7m_release.sh first'
[ -x "${bin}/pwebbundle" ] ||
    die 'pwebbundle missing -- run test/cap7m/build_cap7m_release.sh first'
[ -f "${dist}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
    die "staged dylib missing: ${dist}/${PWEB_MACOS_DYLIB_VERSIONED}"
[ -f "${dist}/LICENSE.webview" ] || die 'staged upstream licence missing'
[ -f "${react_dist}/index.html" ] ||
    die "react frontend dist missing: ${react_dist}"
[ -f "${p2j_dist}/index.html" ] ||
    die "pas2js frontend dist missing: ${p2j_dist}"

cap7m_prepare_dir "${logs}"

# The release directory lives under dist/, OUTSIDE the guard's default
# build/ root, so the allowed root is passed explicitly - same policy as
# everywhere else: absent is created, empty is used, non-empty refuses
# unless --clean.
if [ -e "${release_root}" ] &&
   [ -n "$(ls -A -- "${release_root}" 2>/dev/null)" ]; then
    if [ "${CAP7M_CLEAN:-0}" = '1' ]; then
        printf '[CAP-7M2] --clean: removing stale %s\n' "${release_root}"
        cap7m_rm_tree "${release_root}" "${repo_root}/dist"
    else
        die "refusing to reuse a non-empty release directory: ${release_root} (re-run with --clean)"
    fi
fi
mkdir -p -- "${release_root}"

# --- the ratified facts every product carries ---------------------------------
# The version pair is greped STRICTLY from the one native source of truth: a
# reworded constant fails here rather than silently stamping a wrong version.
version_lines="$(grep -cE "^  PWEB_RUNTIME_VERSION = '[0-9]+\.[0-9]+\.[0-9]+';\$" \
    src/rpc/pweb.rpc.support.pas || true)"
[ "${version_lines}" = '1' ] ||
    die "expected exactly one PWEB_RUNTIME_VERSION constant, found ${version_lines}"
runtime_version="$(sed -n \
    "s/^  PWEB_RUNTIME_VERSION = '\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)';\$/\1/p" \
    src/rpc/pweb.rpc.support.pas)"
[ -n "${runtime_version}" ] || die 'could not extract PWEB_RUNTIME_VERSION'

# The runtime PASS marker, greped from the host's own VERDICT_PASS constant
# with the same strictness: the host just centralized the spelling, and a
# second hand-typed copy here would be exactly the two-spellings drift the
# constant exists to end.
marker_lines="$(grep -cE "^  VERDICT_PASS = '[^']+';\$" \
    examples/08-release/releaseapp.pas || true)"
[ "${marker_lines}" = '1' ] ||
    die "expected exactly one VERDICT_PASS constant in releaseapp.pas, found ${marker_lines}"
pass_marker="$(sed -n "s/^  VERDICT_PASS = '\([^']*\)';\$/\1/p" \
    examples/08-release/releaseapp.pas)"
[ -n "${pass_marker}" ] || die 'could not extract the VERDICT_PASS marker'
printf '[CAP-7M2] runtime verdict marker: %s\n' "${pass_marker}"

deployment_target="${PWEB_MACOS_DEPLOYMENT_TARGET}"
frontend_rev="$(git rev-parse HEAD)"
fpc_version="$(fpc -iV 2>/dev/null | tr -d '[:space:]' || printf '<absent>')"
pas2js_version="$(pweb_macos_lock_read "${repo_root}/pas2js.lock" version)"
node_version="$(node --version 2>/dev/null || printf '<absent>')"
pas2js_bin="${repo_root}/deps/pas2js-darwin/bin/pas2js"
if [ -f "${pas2js_bin}" ]; then
    # RECORDED, not gated: the staged compiler is a host build tool, not a
    # shipped product, so its minos is a fact worth keeping (the source-built
    # arm64 binary links at FPC's own default deployment target, which no
    # ledger entry should have to guess at) rather than a floor to enforce.
    pas2js_minos="$(otool -l "${pas2js_bin}" 2>/dev/null |
        awk '/LC_BUILD_VERSION/ { b = 1 } b && /^ *minos / { print $2; exit }')"
    if [ -z "${pas2js_minos}" ]; then
        pas2js_minos="$(otool -l "${pas2js_bin}" 2>/dev/null |
            awk '/LC_VERSION_MIN_MACOSX/ { b = 1 } b && /^ *version / { print $2; exit }')"
    fi
    record_measurement "CAP7M2_PAS2JS staged_arch=$(lipo -archs "${pas2js_bin}" 2>/dev/null || printf '<unreadable>') minos=${pas2js_minos:-<none>} lock_version=${pas2js_version}"
fi

# --- staging OUTSIDE the checkout (relocated copies, hidden files, verdicts) --
tmp_root="${TMPDIR:-/tmp}"
staging=''
cleanup() {
    [ -n "${staging}" ] || return 0
    # In a SUBSHELL: cap7m_rm_tree dies on refusal, and an `exit` inside an
    # EXIT trap would replace the script's real exit status with the guard's.
    ( cap7m_rm_tree "${staging}" "${tmp_root}" ) ||
        printf '[CAP-7M2] warning: refused to remove staging directory %s\n' \
            "${staging}" >&2
}
trap cleanup EXIT
staging="$(mktemp -d "${tmp_root}/cap7m2-release.XXXXXX")"
# R2 demands a path with a space AND a non-ASCII character; mktemp templates
# cannot carry either, so the hostile component is a child of the unique one.
reloc_base="${staging}/re loc é"
mkdir -p -- "${reloc_base}"

# --- helpers ------------------------------------------------------------------

file_sha() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

# One writer, used for the product AND the regeneration byte-check: two
# writers is how "regenerated byte-identical" stops being a determinism
# proof. No DOCTYPE line, deliberately - a plist does not need one, and the
# only thing a DTD reference would add here is a URL in a swept tree.
write_plist() {
    local out="$1" bundle_id="$2" app_name="$3"
    cat > "${out}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>releaseapp</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleName</key>
	<string>${app_name}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${runtime_version}</string>
	<key>CFBundleVersion</key>
	<string>${runtime_version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${deployment_target}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
}

# Canonical semantic view of a plist: the eight keys, read back through
# plutil, one key=value per line. Its sha256 is what the cross-arch compare
# job matches - semantics, not bytes, though the bytes are identical too.
plist_semantics() {
    local plist="$1" key v
    for key in CFBundleExecutable CFBundleIdentifier CFBundleName \
               CFBundlePackageType CFBundleShortVersionString CFBundleVersion \
               LSMinimumSystemVersion NSHighResolutionCapable; do
        v="$(plutil -extract "${key}" raw -o - "${plist}")" ||
            die "plist key unreadable: ${key} in ${plist}"
        printf '%s=%s\n' "${key}" "${v}"
    done
}

# R1: the .app is EXACTLY this tree. Files, symlinks AND directories are
# enumerated: a find over `-type f` alone is blind to a smuggled empty
# directory, and a symlinked app.pwb would read as a file living elsewhere.
# Nothing in the expected set is a symlink, so any symlink anywhere in the
# bundle fails the compare by not being in the set.
assert_app_layout() {
    local app="$1" listing expected
    listing="$(cd -- "${app}" &&
        find . -mindepth 1 \( -type f -o -type l -o -type d \) |
        LC_ALL=C sort | tr '\n' ' ')"
    expected="./Contents ./Contents/Info.plist ./Contents/MacOS ./Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED} ./Contents/MacOS/releaseapp ./Contents/Resources ./Contents/Resources/LICENSE.webview ./Contents/Resources/app.pwb "
    [ "${listing}" = "${expected}" ] ||
        die "bundle is not minimal: got [${listing}] expected [${expected}]"
}

# The LOGICAL inventory of an app.pwb: entry name, uncompressed size,
# uncompressed sha256, in bytewise name order. This is what R7 compares
# across architectures - compressed container bytes may legitimately differ
# per toolchain, the logical corpus may not.
#
# unzip treats the member NAME as a PATTERN: an entry carrying [, * or ?
# would silently extract some other member. Each metacharacter is wrapped in
# a bracket class so the name is matched literally, and each entry is
# extracted exactly ONCE - size and digest both come from that one pass.
emit_manifest() {
    local pwb="$1" out="$2" entry pattern size sha
    local extracted="${staging}/manifest-entry.bin"
    : > "${out}"
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        case "${entry}" in
            */) continue ;;
        esac
        pattern="$(printf '%s' "${entry}" | sed -e 's/[[*?]/[&]/g')"
        unzip -p "${pwb}" "${pattern}" > "${extracted}"
        size="$(wc -c < "${extracted}" | tr -d ' ')"
        sha="$(file_sha "${extracted}")"
        printf 'entry=%s size=%s sha256=%s\n' "${entry}" "${size}" "${sha}" >> "${out}"
    done < <(zipinfo -1 "${pwb}" | LC_ALL=C sort)
    rm -f -- "${extracted}"
    [ -s "${out}" ] || die "logical inventory of ${pwb} came out empty"
}

# Codesign state is RECORDED, never performed here (ad-hoc at most, and only
# the LaunchServices fallback below ever signs anything - and then only the
# relocated copy). Every emitted key=value is TOKEN-CLEAN: the measurement
# record is whitespace-tokenized, and a value with a space in it truncates
# in the summary's field reader. Sets CAP7M2_CODESIGN_LAST for the
# inventory row.
CAP7M2_CODESIGN_LAST='<not-recorded>'
record_codesign() {
    local product="$1" file="$2" role="$3" sig verify state
    if ! command -v codesign >/dev/null 2>&1; then
        CAP7M2_CODESIGN_LAST='codesign-absent'
        record_measurement "CAP7M2_CODESIGN product=${product} role=${role} codesign_state=absent codesign_verify=untested"
        return 0
    fi
    sig="$(codesign -dvv "${file}" 2>&1 | tr '\n' ';' || true)"
    if codesign --verify --verbose=2 "${file}" >/dev/null 2>&1; then
        verify='pass'
    else
        verify='fail-or-unsigned'
    fi
    case "${sig}" in
        *adhoc*) state='adhoc' ;;
        *'not signed'*) state='unsigned' ;;
        *) state='other' ;;
    esac
    CAP7M2_CODESIGN_LAST="${state}(verify=${verify})"
    record_measurement "CAP7M2_CODESIGN product=${product} role=${role} codesign_state=${state} codesign_verify=${verify} dvv=$(printf '%s' "${sig}" | cut -c1-300)"
}

# R9 bounds: EXACTLY these two per-identifier trees, through the guard, with
# the allowed root passed explicitly. Nothing else under ~/Library is ever
# touched - ~/Library/HTTPStorages/<id> is per-identifier state too, and it
# is deliberately RECORDED rather than cleaned: the ratified matrix names
# two trees, and a cleanup that quietly grew a third would be a bound that
# stopped bounding.
clean_webkit_state() {
    local id="$1" d
    for d in "${HOME}/Library/WebKit/${id}" "${HOME}/Library/Caches/${id}"; do
        if [ -e "${d}" ]; then
            ( cap7m_rm_tree "${d}" "${HOME}/Library" ) ||
                die "refused to remove per-identifier WebKit state: ${d}"
            printf '[CAP-7M2] removed per-identifier WebKit state %s\n' "${d}"
        fi
    done
    if [ -e "${HOME}/Library/HTTPStorages/${id}" ]; then
        record_measurement "CAP7M2_WEBKIT_STATE bundle_id=${id} httpstorages=present action=recorded-not-cleaned"
    fi
}

# R2 + R11: direct launch from CWD=/ with all three loader hints stripped,
# listener-sampled for the process's WHOLE life. `exec` collapses the
# subshell into env into the app, so $! IS the releaseapp pid and the
# sampling watches the right process. There is deliberately NO sample cap:
# the run is already bounded by the argv autoclose plus the host's own
# closer-wait margin, and a cap that broke the loop early would let the
# record claim lifetime sampling it did not do.
RUN_DIRECT_SAMPLES=0
run_direct() {
    local label="$1" app="$2" log="$3"
    local exe="${app}/Contents/MacOS/releaseapp"
    local app_pid found samples owned

    ( cd / && exec env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH \
            -u DYLD_FALLBACK_LIBRARY_PATH \
            "${exe}" --pweb-autoclose-ms=8000 ) > "${log}" 2>&1 &
    app_pid=$!

    found=''
    samples=0
    while kill -0 "${app_pid}" 2>/dev/null; do
        owned="$(lsof -nP -a -p "${app_pid}" -iTCP -sTCP:LISTEN 2>/dev/null |
            awk 'NR > 1 { print $9 }' | LC_ALL=C sort -u || true)"
        [ -n "${owned}" ] && found="${found} ${owned}"
        samples=$((samples + 1))
        sleep 0.5
    done
    if ! wait "${app_pid}"; then
        cat "${log}" >&2
        die "${label}: releaseapp exited nonzero"
    fi
    grep -Fq "${pass_marker}" "${log}" ||
        { cat "${log}" >&2; die "${label}: missing the release PASS marker"; }
    grep -q '"value":42' "${log}" ||
        die "${label}: the page never reported 42"
    grep -Fq 'releaseapp: clean exit' "${log}" ||
        die "${label}: no clean exit"
    [ "${samples}" -gt 0 ] ||
        die "${label}: the process was never sampled -- the listener half proved nothing"
    if [ -n "${found}" ]; then
        printf '[CAP-7M2] LISTENING TCP SOCKETS OWNED BY releaseapp:%s\n' "${found}" >&2
        die "${label}: the release app owned a listening TCP socket"
    fi
    RUN_DIRECT_SAMPLES="${samples}"
    printf '[CAP-7M2] %s: 42 PASS from CWD=/ with no DYLD_* hint (%s listener samples, 0 owned)\n' \
        "${label}" "${samples}"
}

# BOUNDED `open -W`: open itself has no timeout, and without this the only
# ceiling above a wedged instance is the 30-minute CI step budget. The
# instance auto-closes after 8s, so a 120s bound (8s autoclose + a wide
# launch/teardown margin) is reached only by something genuinely stuck -
# which is then killed and FAILED here, with the diagnosis, instead of
# idling the step out.
LS_OPEN_RC=0
ls_open_bounded() {
    local app="$1" verdict="$2" log="$3" open_pid waited
    open -W -n "${app}" --args "--pweb-verdict=${verdict}" \
        --pweb-autoclose-ms=8000 > "${log}" 2>&1 &
    open_pid=$!
    waited=0
    while kill -0 "${open_pid}" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "${waited}" -gt 120 ]; then
            kill "${open_pid}" 2>/dev/null || true
            die "LaunchServices wait exceeded its 120s bound for ${app}"
        fi
    done
    if wait "${open_pid}"; then
        LS_OPEN_RC=0
    else
        LS_OPEN_RC=$?
    fi
}

# R3: LaunchServices. Fresh instance (-n), fresh per-run verdict path, the
# verdict named in argv because argv is ALL LaunchServices delivers.
run_launchservices() {
    local product="$1" app="$2" verdict ls_ok
    verdict="$(mktemp "${staging}/verdict-${product}.XXXXXX")"
    rm -f -- "${verdict}"

    ls_ok=0
    ls_open_bounded "${app}" "${verdict}" "${logs}/ls-${product}-open.log"
    if [ "${LS_OPEN_RC}" -eq 0 ] && [ -f "${verdict}" ]; then
        ls_ok=1
    fi

    if [ "${ls_ok}" != '1' ]; then
        # NO VERDICT is all this branch actually knows: a launch
        # LaunchServices refused and an instance that launched and then
        # crashed before its first write produce the IDENTICAL observation
        # from out here, so the record says `no-verdict` and no more. The
        # one permitted local prep is a deterministic ad-hoc signature on
        # the RELOCATED copy - recorded, re-measured, retried exactly once,
        # and never represented as product signing. The dist products stay
        # untouched, which is what keeps the R8 hashes and the emitted
        # manifest/inventory rows (taken from the dist tree) honest.
        cat "${logs}/ls-${product}-open.log" >&2 || true
        command -v codesign >/dev/null 2>&1 ||
            die "${product}: LaunchServices left no verdict and codesign is unavailable"
        printf '[CAP-7M2] %s: LaunchServices left no verdict; applying recorded ad-hoc local prep and retrying once\n' \
            "${product}"
        codesign -s - -f "${app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}" ||
            die "${product}: ad-hoc local prep failed on the dylib"
        codesign -s - -f "${app}" ||
            die "${product}: ad-hoc local prep failed on the app"
        record_measurement "CAP7M2_CODESIGN product=${product} role=local-prep applied=adhoc reason=no-verdict"
        # the relocated copy just changed: what runs from here on is the
        # re-signed binary, so its state is re-recorded under distinct roles
        record_codesign "${product}" "${app}/Contents/MacOS/releaseapp" \
            relocated-exe-post-prep
        record_codesign "${product}" \
            "${app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}" \
            relocated-dylib-post-prep
        verdict="$(mktemp "${staging}/verdict-${product}-retry.XXXXXX")"
        rm -f -- "${verdict}"
        ls_open_bounded "${app}" "${verdict}" "${logs}/ls-${product}-open-retry.log"
        [ "${LS_OPEN_RC}" -eq 0 ] ||
            { cat "${logs}/ls-${product}-open-retry.log" >&2
              die "${product}: LaunchServices launch failed after the ad-hoc local prep"; }
    fi

    [ -f "${verdict}" ] ||
        die "${product}: the LaunchServices run left no verdict file"
    cp -f -- "${verdict}" "${logs}/ls-verdict-${product}.txt"
    grep -Fq "${pass_marker}" "${verdict}" ||
        { cat "${verdict}" >&2
          die "${product}: the LaunchServices verdict does not carry the PASS marker"; }
    printf '[CAP-7M2] %s: LaunchServices verdict PASS\n' "${product}"
}

# --- assemble one product -----------------------------------------------------
assemble_product() {
    local frontend="$1" bundle_id="$2" app_name="$3" dist_dir="$4"
    local app="${release_root}/${app_name}.app"
    local plist="${app}/Contents/Info.plist"
    local exe="${app}/Contents/MacOS/releaseapp"
    local pwb="${app}/Contents/Resources/app.pwb"

    step "assemble ${app_name}.app (${bundle_id})"
    mkdir -p -- "${app}/Contents/MacOS" "${app}/Contents/Resources"
    cp -f -- "${ex}/releaseapp" "${app}/Contents/MacOS/"
    cp -f -- "${dist}/${PWEB_MACOS_DYLIB_VERSIONED}" "${app}/Contents/MacOS/"
    cp -f -- "${dist}/LICENSE.webview" "${app}/Contents/Resources/"

    # R10: lint, semantic readback of every key, regeneration byte-check
    write_plist "${plist}" "${bundle_id}" "${app_name}"
    plutil -lint "${plist}" > /dev/null ||
        die "${app_name}: Info.plist does not lint"
    local pair want got
    for pair in "CFBundleExecutable=releaseapp" \
                "CFBundleIdentifier=${bundle_id}" \
                "CFBundleName=${app_name}" \
                "CFBundlePackageType=APPL" \
                "CFBundleShortVersionString=${runtime_version}" \
                "CFBundleVersion=${runtime_version}" \
                "LSMinimumSystemVersion=${deployment_target}" \
                "NSHighResolutionCapable=true"; do
        want="${pair#*=}"
        got="$(plutil -extract "${pair%%=*}" raw -o - "${plist}")" ||
            die "${app_name}: plist key unreadable: ${pair%%=*}"
        [ "${got}" = "${want}" ] ||
            die "${app_name}: plist ${pair%%=*} is '${got}', expected '${want}'"
    done
    write_plist "${logs}/plist-regen-${frontend}.plist" "${bundle_id}" "${app_name}"
    cmp -s "${plist}" "${logs}/plist-regen-${frontend}.plist" ||
        die "${app_name}: regenerating Info.plist changed its bytes"

    # app.pwb + R13: byte-identical after touching every dist mtime
    "${bin}/pwebbundle" "${dist_dir}" "${pwb}" \
        > "${logs}/pwebbundle-${frontend}.log" 2>&1 ||
        { cat "${logs}/pwebbundle-${frontend}.log" >&2
          die "${frontend}: app.pwb build failed"; }
    find "${dist_dir}" -type f -exec touch {} +
    "${bin}/pwebbundle" "${dist_dir}" "${logs}/rebuild-${frontend}.pwb" \
        >> "${logs}/pwebbundle-${frontend}.log" 2>&1 ||
        { cat "${logs}/pwebbundle-${frontend}.log" >&2
          die "${frontend}: app.pwb rebuild failed"; }
    local sha_a sha_b
    sha_a="$(file_sha "${pwb}")"
    sha_b="$(file_sha "${logs}/rebuild-${frontend}.pwb")"
    [ "${sha_a}" = "${sha_b}" ] ||
        die "${frontend}: app.pwb is not deterministic after touching dist mtimes (${sha_a} vs ${sha_b})"
    rm -f -- "${logs}/rebuild-${frontend}.pwb"
    record_measurement "CAP7M2_DETERMINISM product=${frontend} rebuild_identical=yes sha256=${sha_a}"

    # R1 for this product
    assert_app_layout "${app}"

    # R14: Mach-O shape of everything bundled, and no checkout path in
    # EITHER bundled Mach-O - the dylib links against system frameworks and
    # could carry a stray absolute path exactly as the executable could.
    pweb_macos_assert_macho "${exe}" --require-dylib --require-rpath
    record_measurement "${PWEB_MACOS_MACHO_FACT}"
    local exe_minos="${PWEB_MACOS_MACHO_MINOS}"
    pweb_macos_assert_macho "${app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}"
    record_measurement "${PWEB_MACOS_MACHO_FACT}"
    local scanned
    for scanned in "${exe}" "${app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}"; do
        if otool -L "${scanned}" | grep -Fq "${repo_root}"; then
            otool -L "${scanned}" >&2
            die "${app_name}: a bundled Mach-O references a path inside the checkout"
        fi
    done
    # R10: the plist floor and the Mach-O floor are the SAME decision
    case "${exe_minos}" in
        "${deployment_target}"|"${deployment_target}".0) ;;
        *) die "${app_name}: LSMinimumSystemVersion=${deployment_target} but the executable minos is ${exe_minos}" ;;
    esac

    # codesign state: recorded per binary, never performed here
    record_codesign "${frontend}" "${exe}" exe
    local codesign_exe_state="${CAP7M2_CODESIGN_LAST}"
    record_codesign "${frontend}" "${app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}" dylib

    # the R7 artifacts: logical inventory + identity/hashes/toolchain rows
    emit_manifest "${pwb}" "${logs}/manifest-${frontend}.txt"
    local exe_sha dylib_sha man_sha plist_sha
    exe_sha="$(file_sha "${exe}")"
    dylib_sha="$(file_sha "${app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}")"
    man_sha="$(file_sha "${logs}/manifest-${frontend}.txt")"
    plist_sha="$(plist_semantics "${plist}" | shasum -a 256 | awk '{ print $1 }')"
    {
        printf 'product=%s\n' "${frontend}"
        printf 'bundle_id=%s\n' "${bundle_id}"
        printf 'app_name=%s\n' "${app_name}"
        printf 'version_pair=%s\n' "${runtime_version}"
        printf 'frontend_rev=%s\n' "${frontend_rev}"
        printf 'plist_semantic_sha256=%s\n' "${plist_sha}"
        printf 'logical_inventory_sha256=%s\n' "${man_sha}"
        printf 'minos=%s\n' "${exe_minos}"
        printf 'arch=%s\n' "${PWEB_MACOS_HOST_ARCH}"
        printf 'bundle_path=dist/macos-%s/release/%s.app\n' \
            "${PWEB_MACOS_HOST_ARCH}" "${app_name}"
        printf 'exe_sha256=%s\n' "${exe_sha}"
        printf 'dylib_sha256=%s\n' "${dylib_sha}"
        printf 'app_pwb_sha256=%s\n' "${sha_a}"
        printf 'toolchain_fpc=%s\n' "${fpc_version}"
        printf 'toolchain_pas2js=%s\n' "${pas2js_version}"
        printf 'toolchain_node=%s\n' "${node_version}"
        printf 'codesign_exe=%s\n' "${codesign_exe_state}"
    } > "${logs}/inventory-${frontend}.txt"
    record_measurement "CAP7M2_HASHES product=${frontend} exe=${exe_sha} dylib=${dylib_sha} app_pwb=${sha_a} inventory=${man_sha} plist_semantic=${plist_sha}"
}

# --- assemble both products ---------------------------------------------------
assemble_product react  dev.pweb.release.react  PWebReleaseReact  "${react_dist}"
assemble_product pas2js dev.pweb.release.pas2js PWebReleasePas2js "${p2j_dist}"

# --- R1: the release dir is exactly the two products --------------------------
step 'R1: dist release dir holds exactly the two products'
top_listing="$(cd -- "${release_root}" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
[ "${top_listing}" = 'PWebReleasePas2js.app PWebReleaseReact.app ' ] ||
    die "release dir is not exactly the two products: [${top_listing}]"

# --- R8: one host, hash-proven ------------------------------------------------
step 'R8: releaseapp and dylib byte-identical across both products'
exe_react="$(file_sha "${release_root}/PWebReleaseReact.app/Contents/MacOS/releaseapp")"
exe_p2j="$(file_sha "${release_root}/PWebReleasePas2js.app/Contents/MacOS/releaseapp")"
[ "${exe_react}" = "${exe_p2j}" ] ||
    die "releaseapp differs between the two products -- a frontend-kind branch (${exe_react} vs ${exe_p2j})"
dylib_react="$(file_sha "${release_root}/PWebReleaseReact.app/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}")"
dylib_p2j="$(file_sha "${release_root}/PWebReleasePas2js.app/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}")"
[ "${dylib_react}" = "${dylib_p2j}" ] ||
    die "the dylib differs between the two products (${dylib_react} vs ${dylib_p2j})"
record_measurement "CAP7M2_PARITY exe_identical=yes dylib_identical=yes exe_sha256=${exe_react}"

# --- R2/R3/R9/R11: relocate and RUN, per frontend -----------------------------
for frontend in react pas2js; do
    if [ "${frontend}" = 'react' ]; then
        app_name='PWebReleaseReact'
        bundle_id='dev.pweb.release.react'
    else
        app_name='PWebReleasePas2js'
        bundle_id='dev.pweb.release.pas2js'
    fi
    reloc_dir="${reloc_base}/${frontend}"
    mkdir -p -- "${reloc_dir}"
    cp -R "${release_root}/${app_name}.app" "${reloc_dir}/"
    app="${reloc_dir}/${app_name}.app"
    assert_app_layout "${app}"

    # cold start: the product's own persistent WebKit state is removed
    # BEFORE its first run and again after its last, so nothing a previous
    # frontend (or a previous run) cached can stand in for a live verdict
    clean_webkit_state "${bundle_id}"

    step "${frontend}: direct launch 1 (cold, relocated under space + non-ASCII, listener-sampled)"
    RUN_DIRECT_SAMPLES=0
    run_direct "${frontend}-direct-cold" "${app}" "${logs}/direct-${frontend}-1.log"
    samples_cold="${RUN_DIRECT_SAMPLES}"

    # R9 warm rerun, and the argv-beats-env proof in the same run: the
    # environment carries a deliberately HUGE autoclose while argv carries
    # 8000ms, so a run that completes well under the env value has proven by
    # wall clock which channel the host obeyed. The bound is generous (the
    # run itself takes ~10-15s) but far below the 55s the env would impose.
    step "${frontend}: direct launch 2 (R9 warm rerun + argv autoclose beats the environment)"
    RUN_DIRECT_SAMPLES=0
    warm_started="$(date +%s)"
    export PWEB_SMOKE_AUTOCLOSE_MS=55000
    run_direct "${frontend}-direct-warm" "${app}" "${logs}/direct-${frontend}-2.log"
    unset PWEB_SMOKE_AUTOCLOSE_MS
    samples_warm="${RUN_DIRECT_SAMPLES}"
    warm_elapsed=$(( $(date +%s) - warm_started ))
    [ "${warm_elapsed}" -lt 45 ] ||
        die "${frontend}: the warm run took ${warm_elapsed}s -- the argv autoclose (8000ms) did not win over PWEB_SMOKE_AUTOCLOSE_MS=55000"
    record_measurement "CAP7M2_AUTOCLOSE product=${frontend} argv_ms=8000 env_ms=55000 elapsed_s=${warm_elapsed} argv_wins=yes"

    step "${frontend}: LaunchServices launch (R3, bounded wait)"
    run_launchservices "${frontend}" "${app}"

    clean_webkit_state "${bundle_id}"
    record_measurement "CAP7M2 product=${frontend} arch=${PWEB_MACOS_HOST_ARCH} direct=pass warm=pass ls=pass listeners=0 samples_cold=${samples_cold} samples_warm=${samples_warm}"
done

# --- R4/R5/R6 + argument refusal: the matrix, on the real React product -------
react_app="${release_root}/PWebReleaseReact.app"
react_exe="${react_app}/Contents/MacOS/releaseapp"
react_pwb="${react_app}/Contents/Resources/app.pwb"

refusal_code=0
refusal_run() {
    local log="$1"
    shift
    set +e
    ( cd / && env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH \
            -u DYLD_FALLBACK_LIBRARY_PATH \
            "${react_exe}" "$@" ) > "${log}" 2>&1
    refusal_code=$?
    set -e
}

assert_refused() {
    local label="$1" log="$2" marker="$3"
    [ "${refusal_code}" -ne 0 ] ||
        die "${label}: releaseapp exited zero where a refusal was required"
    grep -Fq "${marker}" "${log}" ||
        { cat "${log}" >&2; die "${label}: missing the typed marker [${marker}]"; }
    # fail-closed means BEFORE any WebView: a refusal log carrying a runtime
    # verdict would mean content executed after the gate said no
    if grep -Fq "${pass_marker}" "${log}"; then
        die "${label}: the refusal log carries a runtime verdict"
    fi
    printf '[CAP-7M2] %s: refused with exit %s, marker present\n' \
        "${label}" "${refusal_code}"
}

step 'R4: app.pwb removed -> typed refusal before any WebView, WITH a FAIL verdict file'
mv -f -- "${react_pwb}" "${staging}/app.pwb.hidden"
# The refusal path must still honour --pweb-verdict=: a refused
# LaunchServices launch with no FAIL verdict would be indistinguishable from
# a crash out there, and this is where that promise is proven.
refusal_verdict="$(mktemp "${staging}/verdict-refusal.XXXXXX")"
rm -f -- "${refusal_verdict}"
refusal_run "${logs}/refusal-missing.log" \
    "--pweb-verdict=${refusal_verdict}" --pweb-autoclose-ms=8000
assert_refused R4-missing "${logs}/refusal-missing.log" \
    'app.pwb REFUSED (bundle file missing)'
[ -f "${refusal_verdict}" ] ||
    die 'R4: the refused launch left no FAIL verdict file'
grep -Fq 'releaseapp: FAIL' "${refusal_verdict}" ||
    { cat "${refusal_verdict}" >&2
      die 'R4: the refusal verdict does not carry the FAIL line'; }
stray_tmp="$(find "${staging}" -maxdepth 1 -name "$(basename -- "${refusal_verdict}").*.tmp" 2>/dev/null || true)"
[ -z "${stray_tmp}" ] ||
    die "R4: the verdict write left a stray temp sibling: ${stray_tmp}"
cp -f -- "${refusal_verdict}" "${logs}/refusal-verdict.txt"
printf '[CAP-7M2] R4: FAIL verdict written atomically: %s\n' \
    "$(cat "${refusal_verdict}")"

step 'R5: truncated app.pwb -> archive-invalid refusal'
orig_bytes="$(wc -c < "${staging}/app.pwb.hidden" | tr -d ' ')"
head -c $(( orig_bytes / 2 )) "${staging}/app.pwb.hidden" > "${react_pwb}"
refusal_run "${logs}/refusal-truncated.log" --pweb-autoclose-ms=8000
assert_refused R5-truncated "${logs}/refusal-truncated.log" \
    'app.pwb REFUSED (bundle archive invalid)'

step 'R5: garbage app.pwb -> archive-invalid refusal'
printf 'deterministic garbage: this is not a release bundle\n' > "${react_pwb}"
refusal_run "${logs}/refusal-garbage.log" --pweb-autoclose-ms=8000
assert_refused R5-garbage "${logs}/refusal-garbage.log" \
    'app.pwb REFUSED (bundle archive invalid)'
mv -f -- "${staging}/app.pwb.hidden" "${react_pwb}"

step 'R6: dylib hidden -> deterministic nonzero abort naming the dylib'
mv -f -- "${react_app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}" \
    "${staging}/hidden.dylib"
refusal_run "${logs}/refusal-dylib.log" --pweb-autoclose-ms=8000
mv -f -- "${staging}/hidden.dylib" \
    "${react_app}/Contents/MacOS/${PWEB_MACOS_DYLIB_VERSIONED}"
# through the SAME assertion as R4/R5: nonzero, the dylib NAMED, and no
# runtime verdict anywhere in the log
assert_refused R6-dylib "${logs}/refusal-dylib.log" \
    "${PWEB_MACOS_DYLIB_VERSIONED}"

step 'argument refusal: an unknown argument is refused, never half-ignored'
refusal_run "${logs}/refusal-badarg.log" --pweb-bogus-argument
assert_refused R-badarg "${logs}/refusal-badarg.log" 'usage:'

# restored to the shipping shape, and proven so
assert_app_layout "${react_app}"
record_measurement 'CAP7M2_REFUSALS product=react missing=pass truncated=pass garbage=pass hidden_dylib=pass bad_arg=pass refusal_verdict=pass'

printf '\n[CAP-7M2] run_cap7m_release: PASS (%s, 2 products x {direct cold, direct warm, LaunchServices} + refusal matrix)\n' \
    "${PWEB_MACOS_HOST_ARCH}"
