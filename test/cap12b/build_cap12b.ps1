# CAP-12B: build everything the gates drive.
#
#   cap12btests   the headless suite - the store, the ceilings, the token and
#                 Range grammars, the exchange a handler gets back, the fetch
#                 door's envelope and the three lifecycle releases, all with
#                 no window and no engine
#   bloblive      the SHIPPED store behind the SHIPPED handler in a real
#                 window, which is the only place the engine facts live
#
# The live binary needs a display; the suite does not. Both are built here
# so that a leg which cannot open a window still proves it COMPILES - a
# harness that only ever builds where it can run is a harness that breaks
# quietly on the target it cannot.
#
# Usage: pwsh test/cap12b/build_cap12b.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap12b'
New-Item -ItemType Directory -Force $work, (Join-Path $work 'units'),
    (Join-Path $work 'bin') | Out-Null

$static = if ($IsWindows) { 'deps/mormot2/static/x86_64-win64' }
    elseif ($IsMacOS) {
        if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
            'deps/mormot2/static/aarch64-darwin'
        } else { 'deps/mormot2/static/x86_64-darwin' }
    }
    else { 'deps/mormot2/static/x86_64-linux' }

$platformUnits = if ($IsWindows) { 'src/platform/windows' }
    elseif ($IsMacOS) { 'src/platform/macos' } else { 'src/platform/linux' }

$common = @(
    '-MObjFPC', '-Sh', '-B',
    "-FU$work/units", "-FE$work/bin",
    '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
    '-Fusrc/webview',
    "-Fu$platformUnits",
    '-Futest/cap12b', '-Futest/security',
    '-Fideps/mormot2/src',
    '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
    '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net',
    "-Fl$static"
)
if ($IsWindows) { $common = @('-Px86_64', '-Twin64') + $common }

$failed = New-Object System.Collections.Generic.List[string]
function Build([string]$Source, [string[]]$Extra) {
    Write-Host "[CAP-12B] compiling $Source"
    $fpcArgs = $common + $Extra + @($Source)
    & fpc @fpcArgs | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { $failed.Add($Source); Write-Host "[CAP-12B] $Source compile FAILED" }
}

# EVERY ARTIFACT IS ATTEMPTED and the script fails at the end. The first
# hosted macOS run of this script threw at the live harness and therefore
# never built the bundler, so the pack gate reported "no pwebbundle binary"
# for a leg whose only real defect was one link line - two findings where
# there was one.
Build 'test/cap12b/cap12btests.pas' @()
# THE BUNDLER IS BUILT HERE TOO, because the pack-time half of the reserved
# prefix is a CAP-12B claim and a gate that borrowed another shard's binary
# would be a gate that passes when that shard is not built.
Build 'tools/bundler/pwebbundle.pas' @('-Fudeps/mormot2/src/rest',
    '-Fudeps/mormot2/src/db', '-Fudeps/mormot2/src/orm',
    '-Fudeps/mormot2/src/soa', '-Fudeps/mormot2/src/app')

# THE LIVE BINARY LINKS THE WEBVIEW LIBRARY, and the engine library is
# staged beside it exactly as every other live harness here stages it.
if ($IsWindows) {
    Build 'test/cap12b/bloblive.pas' @('-Flbuild/webview-dist')
    $dist = 'build/webview-dist/webview.dll'
    if (Test-Path -LiteralPath $dist) {
        Copy-Item -Force $dist (Join-Path $work 'bin')
        Write-Host "[CAP-12B] staged $(Split-Path -Leaf $dist)"
    } else {
        Write-Host "[CAP-12B] NOTE: $dist is not staged; bloblive will not run here"
    }
} elseif ($IsMacOS) {
    # ON DARWIN THE LINK SET IS NOT RETYPED. The first hosted macOS run of
    # this script (35102099474) hand-wrote the bridge flags and both legs
    # died at `Error: Illegal parameter: -k` - and even correctly spelled, a
    # hand-written list would have missed `-k-no_fixup_chains`, without which
    # every aarch64 link that reaches the dylib fails. tools/macos-buildenv.sh
    # owns that set (PWEB_MACOS_FPC_LINK_BRIDGE: the dylib, @executable_path,
    # the bridge object, both frameworks, the C++ and ObjC runtimes and the
    # arch flag), so the live harness is compiled through it, exactly as
    # test/cap8b/run_nav_matrix.sh compiles navmatrix.
    & bash tools/build-macos-bridge.sh
    if ($LASTEXITCODE -ne 0) { $failed.Add('the Cocoa bridge object') }
    Write-Host '[CAP-12B] compiling test/cap12b/bloblive.pas (macos-buildenv link set)'
    $macScript = @'
set -euo pipefail
. tools/macos-buildenv.sh
pweb_macos_init_fpc
[ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
    { echo "staged webview dylib missing: ${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" >&2; exit 1; }
fpc -MObjFPC -Sh -B -FU"$1" -FE"$2" \
    -Fusrc/rpc -Fusrc/security -Fusrc/lib -Fusrc/assets -Fusrc/webview \
    -Fusrc/platform/macos -Futest/cap12b -Futest/security \
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
    "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
    test/cap12b/bloblive.pas | tail -n 3
# @rpath is @executable_path, so the dylib sits beside the binary
cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" "$2/"
echo "[CAP-12B] staged ${PWEB_MACOS_DYLIB_VERSIONED}"
'@
    & bash -c $macScript bash "$work/units" "$work/bin"
    if ($LASTEXITCODE -ne 0) { $failed.Add('test/cap12b/bloblive.pas') }
} else {
    Build 'test/cap12b/bloblive.pas' @('-Flbuild/cap7l/webview-dist', '-k-rpath=$ORIGIN')
    $dist = 'build/cap7l/webview-dist/libwebview.so.0.12'
    if (Test-Path -LiteralPath $dist) {
        Copy-Item -Force $dist (Join-Path $work 'bin')
        Write-Host "[CAP-12B] staged $(Split-Path -Leaf $dist)"
    } else {
        Write-Host "[CAP-12B] NOTE: $dist is not staged; bloblive will not run here"
    }
}

# --- the Darwin path, TYPE-CHECKED where no Darwin exists -------------------
#
# CAP-15B's shape: the Cocoa blob branch and the live harness's DARWIN
# regions are compiled with `-dDARWIN -Cn` on every non-Darwin target, so a
# Pascal defect there is found on the development host instead of on a
# hosted macOS leg. It is a TYPE CHECK and proves nothing about the link,
# which only a Mac performs, nor about WKWebView's behaviour.
#
# The live harness is checked on LINUX ONLY: it names the folder asset
# store, whose Darwin half sits inside its POSIX branch, so `-dDARWIN` on a
# Windows host leaves that half's forward declaration unresolved - a
# property of the host doing the checking, not of the Darwin build.
if (-not $IsMacOS) {
    $tcUnits = Join-Path $work 'typecheck'
    Remove-Item -Recurse -Force $tcUnits -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tcUnits | Out-Null
    $tcSources = @('src/platform/macos/pweb.platform.cocoa.pas')
    if (-not $IsWindows) { $tcSources += 'test/cap12b/bloblive.pas' }
    foreach ($src in $tcSources) {
        Write-Host "[CAP-12B] type-checking $src as Darwin (-dDARWIN -Cn)"
        $tcArgs = @('-MObjFPC', '-Sh', '-B', '-Cn', '-dDARWIN',
            "-FU$tcUnits", "-FE$tcUnits",
            '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib',
            '-Fusrc/assets', '-Fusrc/webview', '-Fusrc/platform/macos',
            '-Futest/cap12b', '-Futest/security',
            '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
            '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
            '-Fudeps/mormot2/src/net', "-Fl$static")
        if ($IsWindows) { $tcArgs = @('-Px86_64', '-Twin64') + $tcArgs }
        & fpc @tcArgs $src | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { $failed.Add("$src (Darwin type check)") }
    }
}

if ($failed.Count -gt 0) {
    throw "[CAP-12B] build FAILED: $($failed -join ', ')"
}
Write-Host '[CAP-12B] build OK'
