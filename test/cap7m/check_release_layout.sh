#!/usr/bin/env bash
#
# CAP-7M0 PROBE K (M18): what a macOS bundle would have to look like, measured
# BEFORE any layout is frozen.
#
# This is NOT release packaging, and nothing here is a proposal for one. It is
# the smallest arrangement that answers the only question CAP-7M actually
# needs answered before it can design a layout:
#
#   does the executable resolve everything it needs from its OWN location,
#   with no working directory, no DYLD_LIBRARY_PATH and no checkout?
#
# So the throwaway bundle is assembled OUTSIDE the repository, the repository
# is never on any search path, the environment is stripped, and the process is
# started from an unrelated working directory. `otool` states why it worked
# rather than leaving "it ran" to stand in for a mechanism.
#
#   <tmp>/CAP7M.app/
#     Contents/Info.plist
#     Contents/MacOS/cap7m_probe            LC_RPATH @executable_path
#     Contents/MacOS/libwebview.0.12.dylib  the LC_LOAD_DYLIB name (MEASURED)
#     Contents/Resources/LICENSE.webview
#
# The bundle also exercises a REAL upstream branch that the bare binary never
# reaches: cocoa_webkit.hh:402-436 asks NSBundle whether the app is bundled
# and skips setActivationPolicy/activateIgnoringOtherApps when it is. The
# non-bundled path is what every other gate here runs; this is the only place
# the bundled one is proven at all.
#
# Then the negative half, mirroring the Linux L23 gate: with the dylib hidden,
# the failure must be deterministic and must NAME the missing library.
#
# Prerequisites: test/cap7m/build_cap7m.sh
#
# Usage: test/cap7m/check_release_layout.sh
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
record_environment

command -v otool >/dev/null 2>&1 || die 'required tool not found: otool'

dylib_versioned="$(lock_get macos-dylib-versioned)"
deployment_target="$(lock_get macos-deployment-target)"
bin='build/cap7m/bin'
logs='build/cap7m/release'

[ -x "${bin}/cap7m_probe" ] || die 'cap7m_probe missing -- run test/cap7m/build_cap7m.sh'
[ -f "${dist}/${dylib_versioned}" ] || die "staged dylib missing: ${dist}/${dylib_versioned}"
[ -f "${dist}/LICENSE.webview" ] || die 'staged upstream licence missing'

mkdir -p -- "${logs}"

# OUTSIDE the checkout on purpose: if anything in the bundle still needed the
# repository, this is where that shows up rather than in a user's crash report.
staging="$(mktemp -d "${TMPDIR:-/tmp}/cap7m-layout.XXXXXX")"
cleanup() { rm -rf -- "${staging}"; }
trap cleanup EXIT

app="${staging}/CAP7M.app"
mkdir -p -- "${app}/Contents/MacOS" "${app}/Contents/Resources"

cp -f -- "${bin}/cap7m_probe" "${app}/Contents/MacOS/"
cp -f -- "${dist}/${dylib_versioned}" "${app}/Contents/MacOS/"
cp -f -- "${dist}/LICENSE.webview" "${app}/Contents/Resources/"

# No DOCTYPE line: a plist does not need one, and the only thing a DTD
# reference would add here is a URL in a tree that is swept for exactly that.
cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>cap7m_probe</string>
	<key>CFBundleIdentifier</key>
	<string>dev.pweb.cap7m0.probe</string>
	<key>CFBundleName</key>
	<string>CAP7M</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0</string>
	<key>CFBundleVersion</key>
	<string>0</string>
	<key>LSMinimumSystemVersion</key>
	<string>${deployment_target}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# --- the layout is exactly what it claims to be -------------------------------
step 'M18: throwaway bundle layout'
listing="$(cd -- "${app}" && find . -type f | LC_ALL=C sort | tr '\n' ' ')"
expected="./Contents/Info.plist ./Contents/MacOS/cap7m_probe ./Contents/MacOS/${dylib_versioned} ./Contents/Resources/LICENSE.webview "
[ "${listing}" = "${expected}" ] ||
    die "bundle is not minimal: got [${listing}] expected [${expected}]"
printf '[CAP-7M0] bundle: 4 files, assembled at %s\n' "${app}"

# --- otool STATES the mechanism ----------------------------------------------
step 'M18: otool proves how the dylib is found'
exe="${app}/Contents/MacOS/cap7m_probe"
loaded="$(otool -L "${exe}" | awk '/libwebview/ { print $1; exit }')"
[ -n "${loaded}" ] || die 'the bundled executable records no libwebview load command'
case "${loaded}" in
    @rpath/*"${dylib_versioned}") ;;
    *) die "expected an @rpath-relative load of ${dylib_versioned}, got '${loaded}'" ;;
esac
rpaths="$(otool -l "${exe}" |
    awk '/LC_RPATH/ { r = 1 } r && /^ *path / { print $2; r = 0 }')"
printf '%s\n' "${rpaths}" | grep -qx '@executable_path' ||
    { printf '%s\n' "${rpaths}" >&2
      die 'the bundled executable has no LC_RPATH @executable_path'; }
# Nothing may resolve through an absolute path into the checkout or the
# build tree: that is precisely the dependence this gate exists to exclude.
if otool -L "${exe}" | grep -Fq "${repo_root}"; then
    otool -L "${exe}" >&2
    die 'the bundled executable references an absolute path inside the checkout'
fi
record_measurement "CAP7M_M18 load_command=${loaded} rpath=$(printf '%s' "${rpaths}" | tr '\n' ',')"

# --- RECORDED, never performed: the signing constraints a layout must meet ---
# CAP-7M0 defers signing and notarization outright. It does NOT get to defer
# knowing what the platform already requires - on Apple Silicon every Mach-O
# must carry at least an ad-hoc signature to execute at all, and the linker
# applies one without being asked. Whether that is what let this bundle run,
# and whether a downloaded copy would additionally carry a quarantine
# attribute, are constraints on any future layout. M18 exists to measure
# layout constraints before one is frozen, so they are measured here.
#
# Nothing below signs, re-signs, strips or staples anything.
step 'M18: RECORDED signing and quarantine facts (measured, never performed)'
if command -v codesign >/dev/null 2>&1; then
    sig="$(codesign -dvv "${exe}" 2>&1 | tr '\n' ';' || true)"
    record_measurement "CAP7M_M18_SIGNING codesign_dvv=${sig}"
    if codesign --verify --verbose=2 "${exe}" >/dev/null 2>&1; then
        record_measurement 'CAP7M_M18_SIGNING codesign_verify=pass'
    else
        record_measurement 'CAP7M_M18_SIGNING codesign_verify=fail-or-unsigned'
    fi
    # "adhoc" here means the toolchain signed it for us, which IS the answer
    # to "was signing mechanically required to execute this bundle".
    case "${sig}" in
        *adhoc*) record_measurement 'CAP7M_M18_SIGNING adhoc_required=yes (linker-applied)' ;;
        *'not signed'*) record_measurement 'CAP7M_M18_SIGNING adhoc_required=no (ran unsigned)' ;;
        *) record_measurement 'CAP7M_M18_SIGNING adhoc_required=undetermined' ;;
    esac
else
    record_measurement 'CAP7M_M18_SIGNING codesign=<absent>'
fi
if command -v xattr >/dev/null 2>&1; then
    quarantine="$(xattr -p com.apple.quarantine "${exe}" 2>/dev/null || printf '<none>')"
    record_measurement "CAP7M_M18_SIGNING quarantine=${quarantine}"
    record_measurement "CAP7M_M18_SIGNING xattrs=$(xattr -l "${exe}" 2>/dev/null | tr '\n' ';' || printf '<none>')"
fi

# --- run it: no CWD, no DYLD_*, no checkout -----------------------------------
step 'M18: run from an unrelated CWD with the environment stripped'
# env -u removes the loader hints outright. If any of them were doing the
# work, the run below fails - which is the whole assertion.
( cd / && env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH \
        -u DYLD_FALLBACK_LIBRARY_PATH "${exe}" 1 ) \
    > "${logs}/bundle-run.log" 2>&1 ||
    { cat "${logs}/bundle-run.log" >&2; die 'the bundled probe exited nonzero'; }
grep -E 'CAP7M_REPORT|CAP7M_CYCLE_PASS|CAP7M_PROBE_PASS' "${logs}/bundle-run.log" || true
grep -q 'CAP7M_PROBE_PASS cycles=1' "${logs}/bundle-run.log" ||
    die 'the bundled probe did not reach its pass marker'
grep -q '"secure":true' "${logs}/bundle-run.log" ||
    die 'the bundled probe did not report a secure context'
printf '[CAP-7M0] M18: PASS from CWD=/ with no DYLD_* hint and no checkout on any path\n'

# --- the negative half: a missing dylib fails deterministically, and names it -
step 'M18: dylib absent -> deterministic named loader failure'
mv -f -- "${app}/Contents/MacOS/${dylib_versioned}" "${staging}/hidden.dylib"
set +e
# ALL THREE loader hints, exactly as the positive half strips them. Unsetting
# only DYLD_LIBRARY_PATH would leave DYLD_FRAMEWORK_PATH and
# DYLD_FALLBACK_LIBRARY_PATH able to find the "hidden" dylib somewhere else,
# and the gate would then draw its conclusion - "absent means a named
# failure" - from a run in which the library was never actually absent.
( cd / && env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH \
        -u DYLD_FALLBACK_LIBRARY_PATH "${exe}" 1 ) > "${logs}/missing-dylib.log" 2>&1
missing_code=$?
set -e
mv -f -- "${staging}/hidden.dylib" "${app}/Contents/MacOS/${dylib_versioned}"
cat "${logs}/missing-dylib.log"
[ "${missing_code}" -ne 0 ] ||
    die 'the probe succeeded with its dylib removed -- something else supplied it'
grep -Fq "${dylib_versioned}" "${logs}/missing-dylib.log" ||
    die 'the loader failure did not name the missing dylib'
record_measurement "CAP7M_M18 missing_dylib_exit=${missing_code} names=${dylib_versioned}"

printf '\n[CAP-7M0] check_release_layout: PASS (%s)\n' "$(uname -m)"
