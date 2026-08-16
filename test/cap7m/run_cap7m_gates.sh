#!/usr/bin/env bash
#
# CAP-7M1 HEADLESS gates: everything that needs no window.
#
# Two legs:
#
#   1. THE FULL PWeb TEST SUITE ON DARWIN. Every case the Windows and Linux
#      jobs run, plus the CAP-7M1 macOS adapter cases - and, for the first
#      time, TTestAssetStores, whose Setup constructs a TFolderAssetStore and
#      therefore RAISED on Darwin until this shard gave FinalPathOfFd an
#      fcntl(F_GETPATH) body. Ten existing published tests were unreachable on
#      macOS; they are reachable now, and their being green is a fact about
#      shared production code rather than about this shard's own new code.
#
#   2. A REAL-SYMLINK FOLDER-CONFINEMENT PROBE, mirroring
#      test/cap7l/run_cap7l_gates.sh:65-148 and adding the three cases Linux
#      does not have: a symlinked FINAL COMPONENT that points INSIDE the root
#      (refused because it is a symlink, not because it escapes), a dangling
#      symlink, and the whole matrix re-run from an UNRELATED working
#      directory. The suite's own root-confinement case is a Windows junction
#      and early-exits off Windows, so without this the hardened POSIX branch
#      would be entirely unexercised on macOS.
#
# No display, no NSApplication and no webview_create is required here. The
# suite binary does link the Cocoa bridge (and therefore Cocoa and WebKit)
# because the adapter cases drive the REAL task state machine over a stub
# task - loading a framework is not opening a window.
#
# Prerequisites: tools/build-macos-bridge.sh, test/cap7m/build_cap7m.sh
#
# Usage: test/cap7m/run_cap7m_gates.sh [--clean]
#        --clean is OPT-IN; without it a stale work directory is a refusal.
#
set -euo pipefail

# shellcheck source=test/cap7m/cap7m_common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cap7m_common.sh"

eval "$(cap7m_take_clean_flag "$@")"

cd -- "${repo_root}"

assert_native_arch "${CAP7M_EXPECT_ARCH:-}"
assert_fpc_target
record_environment

bin='build/cap7m/bin'
gates="${repo_root}/build/cap7m/gates"

[ -x "${bin}/pwebtests" ] ||
    die 'pwebtests missing -- run test/cap7m/build_cap7m.sh first'
[ -f "${bin}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
    die "${PWEB_MACOS_DYLIB_VERSIONED} was not staged beside pwebtests"

cap7m_prepare_dir "${gates}"

# --- 0. "no macOS flag is written anywhere but the one helper" ----------------
#
# ACCEPTANCE CRITERION 3, GATED. It was asserted in prose and was already
# false when it was written: the `fpc -va` diagnostic still carried its own
# -Fl, -k-rpath and -k@executable_path. A criterion with no gate is a
# criterion that drifts back, which is the exact reasoning that produced the
# renamed-lock-key rejection gate.
#
# Only NON-COMMENT lines are scanned: these files document the flags at
# length, and rightly so - the prohibition is on WRITING one, not on
# explaining it. A line that MEASURES a flag rather than passing one (the
# `fpc -va` instrument greps the linker log for exactly these tokens) carries
# an explicit `macos-flag-scan-exempt` marker, so an exemption is a visible,
# greppable act rather than a pattern quietly tuned around it.
#
# The pattern is CONCATENATED, like the floating-upstream-ref guards, so this
# file cannot match its own source.
step 'M3: every macOS compile/link flag lives in tools/macos-buildenv.sh'
flag_pattern='(^|[^A-Za-z0-9_-])(-W''M[0-9]|-mmacosx-''version-min|-a''rch[= ]|-frame''work'
flag_pattern="${flag_pattern}"'|-lweb''view|-k-r''path|-k-no_''fixup_chains|-k-''L|-Wl,-r''path|-DCMAKE_''OSX_)'
flag_scan="tools/build-webview-dylib.sh tools/build-macos-bridge.sh"
flag_scan="${flag_scan} test/cap7m/cap7m_common.sh test/cap7m/build_cap7m.sh"
flag_scan="${flag_scan} test/cap7m/check_abi.sh test/cap7m/check_webview_exports.sh"
flag_scan="${flag_scan} test/cap7m/run_cap7m_probes.sh test/cap7m/run_cap7m_gates.sh"
flag_scan="${flag_scan} test/cap7m/run_cap7m_runtime.sh"
flag_scan="${flag_scan} test/cap7m/check_release_layout.sh"
flag_scan="${flag_scan} test/cap7m/check_cap7m_nonetwork.sh"
flag_bad=0
for f in ${flag_scan}; do
    # EXISTENCE FIRST, for the same reason the CI guards now check it: a
    # renamed file must fail this sweep, not silently leave it.
    [ -f "${f}" ] || { printf 'MISSING SCAN TARGET: %s\n' "${f}" >&2; flag_bad=1; continue; }
    hits="$(grep -vE '^[[:space:]]*#' "${f}" |
        grep -v 'macos-flag-scan-exempt' |
        grep -nE "${flag_pattern}" || true)"
    if [ -n "${hits}" ]; then
        printf '[CAP-7M1] INLINE macOS FLAG in %s:\n%s\n' "${f}" "${hits}" >&2
        flag_bad=1
    fi
done
[ "${flag_bad}" -eq 0 ] ||
    die 'a macOS compile or link flag is written outside tools/macos-buildenv.sh'
printf '[CAP-7M1] M3: %s scripts carry no inline macOS flag\n' \
    "$(echo ${flag_scan} | wc -w | tr -d ' ')"

# --- 1. the suite -------------------------------------------------------------
step 'PWeb test suite (headless, includes the CAP-7M1 macOS adapter cases)'
# NO /noenter, exactly as on Linux: mORMot only registers that switch under
# {$ifndef OSPOSIX}, and passing it makes TSynTests treat '/noenter' as the
# output REDIRECT FILENAME, print its usage banner and exit 0 without running
# a single case - a silent green. Hence the marker assertions below: an exit
# code alone cannot distinguish "all passed" from "never ran".
suite_log="${gates}/pwebtests.log"
# The symbol-coverage case dlopen()s the library and resolves all 17 pinned
# entry points. It defaults to the Windows file name, so point it at the macOS
# artifact exactly as the Linux job points it at the .so.
PWEB_WEBVIEW_DLL="${repo_root}/${bin}/${PWEB_MACOS_DYLIB_VERSIONED}"
export PWEB_WEBVIEW_DLL
[ -f "${PWEB_WEBVIEW_DLL}" ] || die "staged library missing: ${PWEB_WEBVIEW_DLL}"

set +e
"${bin}/pwebtests" > "${suite_log}" 2>&1
suite_code=$?
set -e
tail -n 40 "${suite_log}"
[ "${suite_code}" -eq 0 ] || die "pwebtests suite FAILED (exit ${suite_code})"
grep -q 'Total assertions failed for all test suits' "${suite_log}" ||
    die 'pwebtests produced no summary -- the suite did not actually run'
# The humanised published-method name of TPWebTests.CocoaAdapter. A suite that
# silently stopped registering the Darwin case would otherwise pass.
grep -q 'Cocoa adapter' "${suite_log}" ||
    die 'the CAP-7M1 macOS adapter cases were not registered in the suite'
# TTestAssetStores could not even construct on Darwin before this shard; its
# presence here is the visible half of the FinalPathOfFd fix.
grep -qi 'Asset system' "${suite_log}" ||
    die 'the CAP-4 asset-store cases were not registered in the suite'
if grep -qE 'Assertion(s)? failed' "${suite_log}"; then
    die 'pwebtests reported failed assertions'
fi
record_measurement "CAP7M1_SUITE $(grep 'Total assertions failed' "${suite_log}" | tail -n 1)"

# --- 2. POSIX folder-store confinement, against real symlinks -----------------
step 'POSIX folder store refuses every symlink, case variant and glob vector'
fixture="${gates}/folder-fixture"
mkdir -p -- "${fixture}/root/assets" "${fixture}/outside"
printf '<!doctype html>inside' > "${fixture}/root/index.html"
printf 'body{margin:0}' > "${fixture}/root/assets/app.css"
printf 'outside-secret' > "${fixture}/outside/secret.bin"

# `pwd -P` on BOTH sides: the runner's /tmp is a symlink to /private/tmp and
# macOS resolves firmlinks, so an unresolved path here would build a fixture
# whose own link targets do not compare equal to what the kernel reports.
outside_real="$(cd -- "${fixture}/outside" && pwd -P)"
root_real="$(cd -- "${fixture}/root" && pwd -P)"

# a symlinked DIRECTORY segment pointing out of the root
ln -s "${outside_real}" "${fixture}/root/outlink"
# a symlinked FINAL COMPONENT pointing out of the root
ln -s "${outside_real}/secret.bin" "${fixture}/root/link.bin"
# CAP-7M1 additions the Linux gate does not have:
#   a symlinked final component pointing INSIDE the root - refused because it
#   is a symlink, NOT because it escapes, which is the stronger claim
ln -s "${root_real}/index.html" "${fixture}/root/inside-link.html"
#   a dangling symlink - must be a miss, never an error that leaks a path
ln -s "${root_real}/nothing-here.html" "${fixture}/root/dangling.html"

cat > "${gates}/folderprobe.pas" <<'PASCAL'
program folderprobe;
{ CAP-7M1: drives the hardened POSIX TFolderAssetStore against a fixture the
  in-suite Windows junction case cannot express, on the platform where the
  branch could not even CONSTRUCT until FinalPathOfFd grew an
  fcntl(F_GETPATH) body. Every line printed is a verdict; the exit code is
  the gate. }
{$mode ObjFPC}{$H+}
uses
  sysutils, mormot.core.base, pweb.assets.intf, pweb.assets.folder;
var
  store: IAssetStore;
  asset: TAssetResponse;
  failures: Integer = 0;
  checks: Integer = 0;

  { EVERY LABEL STATES WHAT PASSING MEANS. This stdout IS the confinement
    evidence a reader is expected to believe, and a passing line reading "ok
    glob pattern resolved" says the opposite of what happened. }
  procedure Expect(Condition: Boolean; const What: string);
  begin
    Inc(checks);
    if Condition then
      WriteLn('  ok   ', What)
    else
    begin
      WriteLn('  FAIL ', What);
      Inc(failures);
    end;
  end;

begin
  if ParamCount <> 1 then
  begin
    WriteLn(StdErr, 'usage: folderprobe <root>');
    Halt(2);
  end;
  WriteLn('folderprobe cwd=', GetCurrentDir);
  store := TFolderAssetStore.Create(ParamStr(1));
  // control: confined reads work. If FinalPathOfFd were broken, the
  // constructor above would already have raised - and if it merely returned
  // a WRONG path, these two would fail while everything else still passed.
  Expect(store.TryRead('index.html', asset) and
    (asset.Content = '<!doctype html>inside'), 'confined read');
  Expect(store.TryRead('assets/app.css', asset), 'nested confined read');
  // a symlinked DIRECTORY segment must not be traversed
  Expect(not store.TryRead('outlink/secret.bin', asset),
    'symlinked directory segment refused');
  Expect(not store.TryRead('outlink', asset),
    'symlinked directory refused as an asset');
  // a symlinked FILE must not be served either (lstat + O_NOFOLLOW)
  Expect(not store.TryRead('link.bin', asset), 'symlinked file refused');
  // CAP-7M1: a symlink pointing INSIDE the root is still refused. The rule is
  // "no symlink on the resolved chain", not "no escape" - a target inside the
  // root today can be repointed outside it tomorrow.
  Expect(not store.TryRead('inside-link.html', asset),
    'symlinked final component pointing inside the root refused');
  // CAP-7M1: a dangling symlink is a miss, never an error carrying a path
  Expect(not store.TryRead('dangling.html', asset), 'dangling symlink refused');
  // exact case on every platform, even where the mount folds it - and macOS
  // APFS folds case by default, so this is not theoretical here
  Expect(not store.TryRead('Index.html', asset),
    'case-folded file name refused');
  Expect(not store.TryRead('ASSETS/app.css', asset),
    'case-folded directory refused');
  // a directory is not an asset; a file is not a directory
  Expect(not store.TryRead('assets', asset), 'directory refused as an asset');
  Expect(not store.TryRead('index.html/x', asset),
    'file refused as a directory');
  // fnmatch metacharacters are LITERAL, never a glob: this is the reason the
  // POSIX branch reads the directory instead of calling FindFirst
  Expect(not store.TryRead('[i]ndex.html', asset),
    'bracket glob treated literally');
  Expect(not store.TryRead('index.htm?', asset),
    'single-char wildcard treated literally');
  Expect(not store.TryRead('*.html', asset),
    'star wildcard treated literally');
  store := nil;
  // COUNTED, and compared by the caller against a ratified number. Without
  // this the probe halts 0 for zero Expect calls just as happily as for
  // fourteen passing ones, and deleting the four symlink vectors would still
  // report PASS.
  WriteLn('FOLDERPROBE VECTORS=', checks);
  if failures = 0 then
  begin
    WriteLn('FOLDERPROBE PASS');
    Halt(0);
  end;
  WriteLn(StdErr, 'FOLDERPROBE FAIL: ', failures, ' finding(s)');
  Halt(1);
end.
PASCAL

fpc -MObjFPC -Sh -B -FU"${gates}/units" -FE"${gates}/bin" \
    -Fusrc/assets -Fideps/mormot2/src -Fudeps/mormot2/src/core \
    -Fudeps/mormot2/src/lib \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
    "${gates}/folderprobe.pas" > "${gates}/folderprobe.log" 2>&1 ||
    { cat "${gates}/folderprobe.log" >&2; die 'folder probe failed to compile'; }

pweb_macos_assert_macho "${gates}/bin/folderprobe"
record_measurement "${PWEB_MACOS_MACHO_FACT}"

# From the repository, then from an UNRELATED working directory. The store is
# rooted at an absolute path in both, so the verdicts must be identical: any
# difference would mean a relative path was being built somewhere, which is
# precisely the class of defect confinement code cannot afford.
"${gates}/bin/folderprobe" "${root_real}" > "${gates}/folderprobe-repo.out" ||
    { cat "${gates}/folderprobe-repo.out" >&2
      die 'POSIX folder store confinement FAILED (from the repository)'; }
( cd / && "${gates}/bin/folderprobe" "${root_real}" ) \
    > "${gates}/folderprobe-root.out" ||
    { cat "${gates}/folderprobe-root.out" >&2
      die 'POSIX folder store confinement FAILED (from CWD=/)'; }
cat "${gates}/folderprobe-repo.out"

# COUNT FIRST, AND AGAINST A RATIFIED NUMBER - the same discipline
# run_cap7m_probes.sh applies to uri_vectors.txt, and for the same reason. The
# probe exits 0 whenever it found no FAILURE, which includes finding nothing
# to check at all: deleting the four symlink vectors would leave this gate
# printing "confinement: identical verdicts" and passing. Changing the vector
# set is a deliberate act that updates this number in the same commit.
CAP7M1_RATIFIED_CONFINEMENT_VECTORS=14
for out in folderprobe-repo folderprobe-root; do
    reported="$(sed -n 's/^FOLDERPROBE VECTORS=\([0-9][0-9]*\)$/\1/p' \
        "${gates}/${out}.out" | tail -n 1)"
    [ -n "${reported}" ] ||
        die "${out}: the folder probe reported no vector count at all"
    [ "${reported}" = "${CAP7M1_RATIFIED_CONFINEMENT_VECTORS}" ] ||
        die "${out}: the folder probe ran ${reported} vectors, the ratified count is ${CAP7M1_RATIFIED_CONFINEMENT_VECTORS}"
    counted="$(grep -c '^  ok   ' "${gates}/${out}.out" || true)"
    [ "${counted}" = "${CAP7M1_RATIFIED_CONFINEMENT_VECTORS}" ] ||
        die "${out}: ${counted} vectors passed, expected ${CAP7M1_RATIFIED_CONFINEMENT_VECTORS}"
done

# Only THEN compare the two runs. The first line records the working
# directory, which is the one thing that is meant to differ.
if ! diff -u <(grep -E '^  (ok|FAIL) ' "${gates}/folderprobe-repo.out") \
             <(grep -E '^  (ok|FAIL) ' "${gates}/folderprobe-root.out") \
        > "${gates}/folderprobe.diff"; then
    cat "${gates}/folderprobe.diff" >&2
    die 'the folder store reached different verdicts from a different CWD'
fi
record_measurement "CAP7M1_CONFINEMENT vectors=${CAP7M1_RATIFIED_CONFINEMENT_VECTORS} cwd_independent=yes"
printf '[CAP-7M1] confinement: %s ratified vectors, identical verdicts from / and from the repository\n' \
    "${CAP7M1_RATIFIED_CONFINEMENT_VECTORS}"

printf '\n[CAP-7M1] run_cap7m_gates: PASS (%s)\n' "${PWEB_MACOS_HOST_ARCH}"
