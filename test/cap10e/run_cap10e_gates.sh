#!/usr/bin/env bash
#
# CAP-10E POSIX gates: the kernel-resolved image path, measured on a real
# host at a real non-ASCII location, and the symlink rule this shard
# ratified.
#
#   E1/E9  the image-path probe: what the kernel answers, what the CLI's own
#          seam answers, and whether they are the same bytes. The probe also
#          records the RTL's answer, so the defect stays visible after it is
#          fixed rather than becoming a changelog claim.
#   E2     the release host at a directory carrying a SPACE and a non-ASCII
#          character answers 42, launched from an unrelated working
#          directory. On macOS the layout is the .app shape the host's own
#          DARWIN branch resolves (Contents/MacOS + Contents/Resources), and
#          the directory name is composed NFD on purpose: HFS+ normalised
#          filenames and APFS preserves what it is given, so the only honest
#          way to record what a macOS kernel hands back is the BYTES, which
#          the probe prints as image_dir_hex.
#   E5     THE SYMLINK RULE. A host reached through a symlink resolves
#          app.pwb beside the REAL image, never beside the link. It is
#          measured with a DECOY: the link's own directory holds a corrupt
#          app.pwb, so "the real one was used" and "the decoy was used" have
#          different, unmistakable outcomes - 42 versus a typed refusal -
#          instead of two indistinguishable 42s.
#          This is a BEHAVIOUR CHANGE and the stricter one:
#          ExpandFileName(ParamStr(0)) resolved no links, /proc/self/exe and
#          realpath resolve all of them, so a writable directory can no
#          longer decide which bundle a trusted binary loads.
#   E6/E7  Windows only (junction, long path); recorded not_applicable here.
#
# Prerequisites: test/cap7l/build_cap7l.sh (Linux) or
# test/cap7m/build_cap7m_release.sh (macOS), a frontend dist, and on Linux a
# virtual display:  xvfb-run -a test/cap10e/run_cap10e_gates.sh
#
# Emits build/cap10e/image-path-<target>.json and the row corpus beside it.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-10E] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-10E] === %s\n' "$*"; }

work="${repo_root}/build/cap10e"
mkdir -p -- "${work}"
rows_file="${work}/rows.txt"
: > "${rows_file}"

violations=0
row() { printf '%s=%s\n' "$1" "$2" >> "${rows_file}"; }
require() {
    if [ "$1" != 'true' ]; then
        printf '[CAP-10E] GATE FAILURE: %s\n' "$2" >&2
        violations=$((violations + 1))
    fi
}

uname_s="$(uname -s)"
case "${uname_s}" in
    Linux)  os='linux' ;;
    Darwin) os='macos' ;;
    *)      die "CAP-10E POSIX gates run on Linux and macOS only, not ${uname_s}" ;;
esac
arch="$(uname -m)"
target="${os}-${arch}"
row 'schema' '1'
row 'target' "${target}"

# ---------------------------------------------------------------------------
# the artifacts each platform's own build produced - never rebuilt here
# ---------------------------------------------------------------------------
if [ "${os}" = 'linux' ]; then
    host_bin="${repo_root}/build/cap7l/ex/releaseapp"
    bundler="${repo_root}/build/cap7l/bin/pwebbundle"
    dist_dir="${repo_root}/build/cap7l/webview-dist"
    lib_name='libwebview.so.0.12'
    platform_units='-Fusrc/platform/linux'
    static_dir='deps/mormot2/static/x86_64-linux'
else
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init
    host_bin="${repo_root}/build/cap7m/ex/releaseapp"
    bundler="${repo_root}/build/cap7m/bin/pwebbundle"
    dist_dir="${PWEB_MACOS_DIST}"
    lib_name="${PWEB_MACOS_DYLIB_VERSIONED}"
    platform_units='-Fusrc/platform/macos'
    if [ "${arch}" = 'arm64' ]; then
        static_dir='deps/mormot2/static/aarch64-darwin'
    else
        static_dir='deps/mormot2/static/x86_64-darwin'
    fi
fi

[ -x "${host_bin}" ] || die "release host missing: ${host_bin}"
[ -x "${bundler}" ] || die "pwebbundle missing: ${bundler}"
[ -f "${dist_dir}/${lib_name}" ] || die "staged webview library missing: ${dist_dir}/${lib_name}"

frontend=''
for candidate in \
    "${repo_root}/examples/04-react/frontend/dist" \
    "${repo_root}/examples/05-pas2js/frontend/dist" \
    "${repo_root}/examples/07-quickjs/frontend/dist"; do
    if [ -f "${candidate}/index.html" ]; then frontend="${candidate}"; break; fi
done
[ -n "${frontend}" ] || die 'no built frontend dist found -- build one first'

# IS THE INSTRUMENT IN THE THING UNDER TEST? This gate relocates a binary
# ANOTHER gate built, so it can be handed a pre-CAP-10E host and would then
# measure the defect and call it a failure of the fix. The Windows twin's
# first local run did exactly that, and the ledger already carries the
# general form ("a reproduction must name the artifact the build just
# produced"), so the binary is asked whether it carries the refusal string
# CAP-10E introduced before anything else happens.
if ! LC_ALL=C grep -qa 'image path unavailable' "${host_bin}"; then
    die "${host_bin} predates CAP-10E (it does not carry \"image path unavailable\") -- rebuild it before running this gate; measuring a stale binary here would report the defect as a failure of its own fix"
fi
row 'host_binary_carries_cap10e' 'true'

# The PASS marker from the host's OWN constant, never a literal repeated
# here: the same single-source discipline test/cap7m/run_cap7m_release.sh
# applies, and for the same reason - a gate that carries its own copy of a
# marker stops testing the host the day somebody edits one of the two.
marker_lines="$(grep -cE "^  VERDICT_PASS = '[^']+';\$" \
    examples/08-release/releaseapp.pas || true)"
[ "${marker_lines}" = '1' ] ||
    die "expected exactly one VERDICT_PASS constant in releaseapp.pas, found ${marker_lines}"
pass_marker="$(sed -n "s/^  VERDICT_PASS = '\([^']*\)';\$/\1/p" \
    examples/08-release/releaseapp.pas)"
[ -n "${pass_marker}" ] || die 'could not extract the VERDICT_PASS marker'
printf '[CAP-10E] canonical release marker: %s\n' "${pass_marker}"

# ---------------------------------------------------------------------------
# THE non-ASCII directory name.
#
# Linux gets an NFC-composed U+00E9; macOS gets the DECOMPOSED pair
# (e + U+0301), which is the harder case and the one the brief asks to be
# measured rather than assumed. Both carry a space as well, because the two
# defects a path can have - a separator-adjacent space and a byte outside the
# active code page - have historically arrived together.
# ---------------------------------------------------------------------------
if [ "${os}" = 'macos' ]; then
    accent_dir="$(printf 'e\xcc\x81tude cap10e')"   # NFD: e + COMBINING ACUTE
    accent_form='nfd'
else
    accent_dir="$(printf '\xc3\xa9tude cap10e')"    # NFC: U+00E9
    accent_form='nfc'
fi
row 'nonascii_dir_form_requested' "${accent_form}"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/cap10e.XXXXXX")"
cleanup() { rm -rf -- "${sandbox}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# E1/E9: the probe, compiled here and RUN from the accented directory
# ---------------------------------------------------------------------------
step 'E1/E9 the image-path probe at a non-ASCII directory'
mkdir -p -- "${work}/probe-units" "${work}/probe-bin"
# shellcheck disable=SC2086
fpc -MObjFPC -Sh -B -FU"${work}/probe-units" -FE"${work}/probe-bin" \
    -Fusrc/security -Futools/pweb -Fusrc/rpc -Fusrc/assets ${platform_units} \
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db \
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa \
    "-Fl${static_dir}" test/cap10e/imageprobe.pas > "${work}/probe-build.log" 2>&1 ||
    { tail -30 "${work}/probe-build.log" >&2; die 'the CAP-10E probe compile FAILED'; }

probe_dir="${sandbox}/${accent_dir}"
mkdir -p -- "${probe_dir}"
cp -f -- "${work}/probe-bin/imageprobe" "${probe_dir}/imageprobe"
probe_out="${work}/probe-${target}.txt"
( cd / && "${probe_dir}/imageprobe" ) > "${probe_out}" 2>&1 ||
    { cat "${probe_out}" >&2; die 'the image-path probe refused'; }
cat "${probe_out}"

probe_get() { sed -n "s/^$1=//p" "${probe_out}" | head -n 1; }
row 'image_path_source' "$(probe_get image_path_source)"
row 'image_dir_non_ascii' "$(probe_get image_dir_non_ascii)"
row 'image_dir_hex' "$(probe_get image_dir_hex)"
row 'cli_equals_helper' "$(probe_get cli_equals_helper)"
row 'rtl_equals_kernel' "$(probe_get rtl_equals_kernel)"
row 'probe_verdict' "$(probe_get verdict)"
require "$([ "$(probe_get verdict)" = 'PASS' ] && echo true || echo false)" \
    'E9: the probe did not answer PASS'
require "$([ "$(probe_get image_dir_non_ascii)" = 'true' ] && echo true || echo false)" \
    'E1: the probe directory carries no non-ASCII character - an ASCII path measures the shape that never failed'
require "$([ "$(probe_get cli_equals_helper)" = 'true' ] && echo true || echo false)" \
    'E9: the CLI seam and the shipped helper disagreed on the image directory'

# WHAT THE FILESYSTEM GAVE BACK, rather than what was asked for. On macOS an
# NFD request may come back NFD (APFS preserves) or NFC (a normalising
# layer); the hex says which, and this row records it as an observation.
probe_hex="$(probe_get image_dir_hex)"
if printf '%s' "${probe_hex}" | grep -q '65cc81'; then
    row 'nonascii_dir_form_observed' 'nfd'
elif printf '%s' "${probe_hex}" | grep -q 'c3a9'; then
    row 'nonascii_dir_form_observed' 'nfc'
else
    row 'nonascii_dir_form_observed' 'unknown'
fi

# ---------------------------------------------------------------------------
# E2: the release host at the accented directory answers 42
# ---------------------------------------------------------------------------
step 'E2 the release host at a non-ASCII directory'
export PWEB_SMOKE_AUTOCLOSE_MS="${PWEB_SMOKE_AUTOCLOSE_MS:-8000}"
if [ "${os}" = 'linux' ]; then
    [ -n "${DISPLAY:-}" ] || die 'no DISPLAY -- run this under xvfb-run -a'
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export GDK_BACKEND=x11
fi

# the layout each platform's host actually resolves: beside the executable on
# Linux, Contents/Resources beside Contents/MacOS on macOS
# the .app suffix on macOS is not decoration: the host's DARWIN branch
# resolves Contents/Resources, and the upstream Cocoa code asks NSBundle
# whether it is bundled - so a relocated tree without the suffix and the
# plist would be a DIFFERENT launch shape rather than the same layout at a
# different path, and this leg is about the path alone.
if [ "${os}" = 'macos' ]; then bundle_suffix='.app'; else bundle_suffix=''; fi

assemble_release() {
    local root="$1" pwb_src="$2"
    if [ "${os}" = 'macos' ]; then
        mkdir -p -- "${root}/Contents/MacOS" "${root}/Contents/Resources"
        cp -f -- "${host_bin}" "${root}/Contents/MacOS/releaseapp"
        cp -f -- "${dist_dir}/${lib_name}" "${root}/Contents/MacOS/${lib_name}"
        cp -f -- "${pwb_src}" "${root}/Contents/Resources/app.pwb"
        # the smallest plist NSBundle accepts as an identity; the full
        # product plist is CAP-7M2's and is not what this leg measures
        cat > "${root}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>releaseapp</string>
	<key>CFBundleIdentifier</key>
	<string>dev.pweb.cap10e.imagepath</string>
	<key>CFBundleName</key>
	<string>PWebCap10E</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST
        printf '%s\n' "${root}/Contents/MacOS/releaseapp"
    else
        mkdir -p -- "${root}"
        cp -f -- "${host_bin}" "${root}/releaseapp"
        cp -f -- "${dist_dir}/${lib_name}" "${root}/${lib_name}"
        cp -f -- "${pwb_src}" "${root}/app.pwb"
        printf '%s\n' "${root}/releaseapp"
    fi
}

good_pwb="${work}/app.pwb"
"${bundler}" "${frontend}" "${good_pwb}" > "${work}/bundle.log" 2>&1 ||
    { cat "${work}/bundle.log" >&2; die 'app.pwb build FAILED'; }

accent_root="${sandbox}/${accent_dir}/release${bundle_suffix}"
accent_exe="$(assemble_release "${accent_root}" "${good_pwb}")"
accent_log="${work}/release-nonascii.log"
set +e
( cd / && env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH "${accent_exe}" ) \
    > "${accent_log}" 2>&1
accent_code=$?
set -e
tail -n 6 "${accent_log}" || true
row 'nonascii_release_exit' "${accent_code}"
if grep -Fq "${pass_marker}" "${accent_log}"; then
    row 'nonascii_release_host' '42'
else
    row 'nonascii_release_host' '-1'
fi
require "$([ "${accent_code}" = '0' ] && echo true || echo false)" \
    "E2: the release host at a non-ASCII directory exited ${accent_code}"
require "$(grep -Fq "${pass_marker}" "${accent_log}" && echo true || echo false)" \
    'E2: the release host at a non-ASCII directory did not print the 42 PASS marker'

# ---------------------------------------------------------------------------
# E5: the symlink rule, with a decoy
# ---------------------------------------------------------------------------
step 'E5 a symlinked launch resolves the REAL image, not the link'
real_root="${sandbox}/real${bundle_suffix}"
link_root="${sandbox}/link${bundle_suffix}"
real_exe="$(assemble_release "${real_root}" "${good_pwb}")"
mkdir -p -- "${link_root}"

# THE DECOY: a corrupt app.pwb beside the LINK. If the old rule were still in
# force the host would find this one and refuse; finding the real one is the
# only way it can answer 42, so the two outcomes cannot be confused.
if [ "${os}" = 'macos' ]; then
    mkdir -p -- "${link_root}/Contents/MacOS" "${link_root}/Contents/Resources"
    printf 'this is not a zip archive - CAP-10E decoy' \
        > "${link_root}/Contents/Resources/app.pwb"
    ln -s -- "${real_exe}" "${link_root}/Contents/MacOS/releaseapp"
    link_exe="${link_root}/Contents/MacOS/releaseapp"
else
    printf 'this is not a zip archive - CAP-10E decoy' > "${link_root}/app.pwb"
    ln -s -- "${real_exe}" "${link_root}/releaseapp"
    link_exe="${link_root}/releaseapp"
fi
row 'symlink_decoy_bytes' "$(wc -c < "${link_root}$( [ "${os}" = 'macos' ] && printf '/Contents/Resources' )/app.pwb" | tr -d ' ')"

link_log="${work}/release-symlink.log"
set +e
( cd / && env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH "${link_exe}" ) \
    > "${link_log}" 2>&1
link_code=$?
set -e
tail -n 6 "${link_log}" || true
row 'symlink_launch_exit' "${link_code}"
if grep -Fq "${pass_marker}" "${link_log}"; then
    row 'symlink_rule' 'real_image'
    row 'symlink_decoy_ignored' 'true'
elif grep -Fq 'app.pwb REFUSED' "${link_log}"; then
    row 'symlink_rule' 'link_dir'
    row 'symlink_decoy_ignored' 'false'
else
    row 'symlink_rule' 'unmeasured'
    row 'symlink_decoy_ignored' 'unmeasured'
fi
require "$(grep -Fq "${pass_marker}" "${link_log}" && echo true || echo false)" \
    'E5: a symlinked launch did not resolve app.pwb beside the REAL image'

# ---------------------------------------------------------------------------
# the Windows-only legs, recorded rather than silently absent
# ---------------------------------------------------------------------------
# the NAMES matter as much as the values: these rows are read straight out
# of this JSON by test/cap7f/emit_evidence.sh and required by name in
# check_cap7f_aggregate.ps1, so a row spelled differently here is a
# REQUIRED FIELD MISSING on three targets - the failure mode ledger entry
# D2-10's neighbour records as having cost a hosted run once already
row 'junction_on_chain' 'not_applicable'
row 'long_path_outcome' 'not_applicable'
row 'fixed_profile_nonascii_dir' 'not_applicable'

# ---------------------------------------------------------------------------
# the record
# ---------------------------------------------------------------------------
if [ "${violations}" -eq 0 ]; then
    row 'verdict' 'PASS'
else
    row 'verdict' 'FAIL'
fi
digest="$( (sha256sum "${rows_file}" 2>/dev/null || shasum -a 256 "${rows_file}") \
    | cut -d' ' -f1 )"
row_json="${work}/image-path-${target}.json"
{
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "target": "%s",\n' "${target}"
    printf '  "image_path_digest": "%s",\n' "${digest}"
    first=1
    while IFS='=' read -r k v; do
        [ -n "${k}" ] || continue
        [ "${k}" = 'schema' ] && continue
        [ "${k}" = 'target' ] && continue
        if [ "${first}" -eq 0 ]; then printf ',\n'; fi
        first=0
        printf '  "%s": "%s"' "${k}" "${v}"
    done < "${rows_file}"
    printf '\n}\n'
} > "${row_json}"
cat "${row_json}"

[ "${violations}" -eq 0 ] ||
    die "CAP-10E POSIX gates FAILED (${violations} violation(s))"
printf '[CAP-10E] POSIX gates PASS on %s (digest %s)\n' "${target}" "${digest}"
