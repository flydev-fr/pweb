#!/usr/bin/env bash
#
# CAP-7L headless gates: everything that needs no display.
#
#   - the PWeb test suite, which on Linux additionally registers the
#     CAP-7L adapter cases (URI gate over the CAP-4 hostile vectors with
#     a counting store, MIME parity, response-lifetime regression) and
#     runs the hardened POSIX folder store against a real filesystem;
#   - a symlink-escape fixture that proves the hardened POSIX branch
#     refuses to follow a link out of its root (the counterpart of the
#     Windows junction case, which cannot be expressed on Linux from
#     inside the suite's Windows-only fixture);
#   - the deterministic packaging inputs the GUI matrix consumes:
#     app.zip from the CAP-4 fixture and app.pwb from the React dist.
#
# Prerequisite: test/cap7l/build_cap7l.sh
#
# Usage: test/cap7l/run_cap7l_gates.sh
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-7L] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-7L] === %s\n' "$*"; }

bin='build/cap7l/bin'
[ -x "${bin}/pwebtests" ] || die 'pwebtests missing -- run test/cap7l/build_cap7l.sh first'

# --- the suite ----------------------------------------------------------------
step 'PWeb test suite (headless, includes the CAP-7L adapter cases)'
# the binding unit statically imports pweb.lib.webview, so the shared
# object must sit beside the executable even though these cases never call
# a native entry point - build_cap7l.sh staged it there
[ -f "${bin}/libwebview.so.0.12" ] || die 'libwebview.so.0.12 was not staged beside pwebtests'
# NO /noenter here, unlike the Windows job: mORMot only registers that
# switch under {$ifndef OSPOSIX}, and there is no ENTER wait to suppress
# on POSIX. Passing it makes TSynTests treat '/noenter' as the output
# REDIRECT FILENAME, print its usage banner and exit 0 without running a
# single case - a silent green. Hence the marker assertions below: an
# exit code alone cannot distinguish "all passed" from "never ran".
suite_log='build/cap7l/pwebtests.log'
# The symbol-coverage case dlopen()s the library and resolves all 17
# pinned entry points. It defaults to the Windows file name, so point it
# at the Linux artifact exactly as the Windows job points it at the DLL.
export PWEB_WEBVIEW_DLL="${repo_root}/build/cap7l/webview-dist/libwebview.so.0.12"
[ -f "${PWEB_WEBVIEW_DLL}" ] || die "staged library missing: ${PWEB_WEBVIEW_DLL}"
# CAP-8A corpus freshness: the CAP-7F emitter hashes this file as THIS
# run's policy-decision evidence, so a stale copy from an earlier run
# must never survive into the suite that is supposed to write it
rm -f -- "${repo_root}/build/cap7f/capability-policy.txt"
set +e
"${bin}/pwebtests" > "${suite_log}" 2>&1
suite_code=$?
set -e
tail -n 40 "${suite_log}"
[ "${suite_code}" -eq 0 ] || die "pwebtests suite FAILED (exit ${suite_code})"
grep -q 'Total assertions failed for all test suits' "${suite_log}" ||
    die 'pwebtests produced no summary -- the suite did not actually run'
grep -q 'Web kit gtk adapter' "${suite_log}" ||
    die 'the CAP-7L Linux adapter cases were not registered in the suite'
# CAP-8A: the capability engine cases and the I1-I10 integration gates
# must both be registered - an exit code alone cannot tell "all passed"
# from "never ran" (see the /noenter note above). Both greps are ANCHORED
# to the case-header colon so neither can be satisfied by the other's
# line ('Capability policy: ' never matches 'Capability policy
# integration: ' and vice versa).
grep -q 'Capability policy: ' "${suite_log}" ||
    die 'the CAP-8A capability policy cases were not registered in the suite'
grep -q 'Capability policy integration: ' "${suite_log}" ||
    die 'the CAP-8A capability integration gates were not registered in the suite'
grep -qE 'Assertion(s)? failed' "${suite_log}" &&
    die 'pwebtests reported failed assertions'
printf '[CAP-7L] suite summary: %s\n' \
    "$(grep 'Total assertions failed' "${suite_log}" | tail -n 1)"

# --- POSIX folder-store confinement ------------------------------------------
# The suite's root-confinement case uses a Windows junction, which has no
# expression inside that fixture on Linux. The hardened POSIX branch refuses
# symlinks per segment (lstat) AND re-proves the opened descriptor's path
# through /proc/self/fd, so prove both here against a real link.
step 'POSIX folder store refuses a symlink escape'
fixture="build/cap7l/folder-fixture"
rm -rf -- "${fixture}"
mkdir -p -- "${fixture}/root/assets" "${fixture}/outside"
printf '<!doctype html>inside' > "${fixture}/root/index.html"
printf 'body{margin:0}' > "${fixture}/root/assets/app.css"
printf 'outside-secret' > "${fixture}/outside/secret.bin"
ln -s "$(cd -- "${fixture}/outside" && pwd)" "${fixture}/root/outlink"
ln -s "$(cd -- "${fixture}/outside" && pwd)/secret.bin" "${fixture}/root/link.bin"

cat > "build/cap7l/folderprobe.pas" <<'PASCAL'
program folderprobe;
{ CAP-7L: drives the hardened POSIX TFolderAssetStore against a fixture
  the in-suite Windows junction case cannot express. Every line printed is
  a verdict; the exit code is the gate. }
{$mode ObjFPC}{$H+}
uses
  sysutils, mormot.core.base, pweb.assets.intf, pweb.assets.folder;
var
  store: IAssetStore;
  asset: TAssetResponse;
  failures: Integer = 0;

  procedure Expect(Condition: Boolean; const What: string);
  begin
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
  store := TFolderAssetStore.Create(ParamStr(1));
  // control: confined reads work
  Expect(store.TryRead('index.html', asset) and
    (asset.Content = '<!doctype html>inside'), 'confined read');
  Expect(store.TryRead('assets/app.css', asset), 'nested confined read');
  // a symlinked DIRECTORY segment must not be traversed
  Expect(not store.TryRead('outlink/secret.bin', asset),
    'symlinked directory segment refused');
  Expect(not store.TryRead('outlink', asset), 'symlink served as asset');
  // a symlinked FILE must not be served either (lstat + O_NOFOLLOW)
  Expect(not store.TryRead('link.bin', asset), 'symlinked file refused');
  // exact case on every platform, even where the mount folds it
  Expect(not store.TryRead('Index.html', asset), 'case-folded file name');
  Expect(not store.TryRead('ASSETS/app.css', asset), 'case-folded directory');
  // a directory is not an asset; a file is not a directory
  Expect(not store.TryRead('assets', asset), 'directory served as asset');
  Expect(not store.TryRead('index.html/x', asset), 'file used as directory');
  // fnmatch metacharacters are LITERAL, never a glob: this is the reason
  // the POSIX branch reads the directory instead of calling FindFirst
  Expect(not store.TryRead('[i]ndex.html', asset), 'glob pattern resolved');
  Expect(not store.TryRead('index.htm?', asset), 'single-char wildcard resolved');
  Expect(not store.TryRead('*.html', asset), 'star wildcard resolved');
  store := nil;
  if failures = 0 then
  begin
    WriteLn('FOLDERPROBE PASS');
    Halt(0);
  end;
  WriteLn(StdErr, 'FOLDERPROBE FAIL: ', failures, ' finding(s)');
  Halt(1);
end.
PASCAL

fpc -MObjFPC -Sh -B -FUbuild/cap7l/units -FEbuild/cap7l/bin \
    -Fusrc/assets -Fideps/mormot2/src -Fudeps/mormot2/src/core \
    -Fudeps/mormot2/src/lib -Fldeps/mormot2/static/x86_64-linux \
    build/cap7l/folderprobe.pas > build/cap7l/folderprobe.log 2>&1 ||
    { cat build/cap7l/folderprobe.log >&2; die 'folder probe failed to compile'; }
"${bin}/folderprobe" "${fixture}/root" || die 'POSIX folder store confinement FAILED'

# --- deterministic packaging inputs ------------------------------------------
step 'app.zip from the CAP-4 frontend fixture'
[ -d 'examples/06-assets/frontend/dist' ] ||
    die 'CAP-4 frontend fixture missing: examples/06-assets/frontend/dist'
"${bin}/mkappzip" examples/06-assets/frontend/dist build/cap7l/app.zip ||
    die 'app.zip build FAILED'
[ -f 'build/cap7l/app.zip' ] || die 'app.zip missing after build'

step 'app.pwb from the React dist'
[ -f 'examples/04-react/frontend/dist/index.html' ] ||
    die 'React dist missing -- build examples/04-react/frontend first'
"${bin}/pwebbundle" examples/04-react/frontend/dist build/cap7l/app.pwb ||
    die 'app.pwb build FAILED'
[ -f 'build/cap7l/app.pwb' ] || die 'app.pwb missing after build'

# determinism: the same inputs must produce the same bytes
"${bin}/pwebbundle" examples/04-react/frontend/dist build/cap7l/app-rebuild.pwb ||
    die 'app.pwb rebuild FAILED'
a="$(sha256sum build/cap7l/app.pwb | cut -d' ' -f1)"
b="$(sha256sum build/cap7l/app-rebuild.pwb | cut -d' ' -f1)"
[ "${a}" = "${b}" ] || die "app.pwb is not deterministic on Linux: ${a} != ${b}"
printf '[CAP-7L] app.pwb deterministic: %s\n' "${a}"

printf '\n[CAP-7L] run_cap7l_gates: PASS\n'
