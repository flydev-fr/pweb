# CAP-16: build everything the gates drive.
#
#   cap16tests   the headless suite - the one script and its encoder, the
#                channel over a fake view, the socket door on the channel,
#                and the caller principal through a real mORMot service
#   evalprobe    the ENGINE facts behind the one injected script: it runs
#                under PWEB_NATIVE_CSP, in what order successive scripts
#                arrive, and what hostile topics become
#   signallive   the channel in the PRODUCTION host (PWebHostRun), the real
#                @pweb/runtime in the page, a flood, a revocation, a reload,
#                a socket echo through the migrated loop and a service blob
#
# The live binaries link the webview library and need a display; the suite
# does not. All three are built on every target, so a leg that cannot open a
# window still proves they COMPILE, and every artifact is attempted before
# the script fails (the CAP-12B rule).
#
# THE PAGE IMPORTS THE REAL SDK: sdk/typescript/dist/src is staged beside the
# fixture as build/cap16/fixture-live/sdk. The SDK is built earlier in every
# platform leg; a missing or stale build is a failure here, by name.
#
# Usage: pwsh test/cap16/build_cap16.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap16'
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

$mormotPaths = @('-Fideps/mormot2/src',
    '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
    '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net',
    '-Fudeps/mormot2/src/db', '-Fudeps/mormot2/src/orm',
    '-Fudeps/mormot2/src/rest', '-Fudeps/mormot2/src/soa')
$common = @(
    '-MObjFPC', '-Sh', '-B',
    "-FU$work/units", "-FE$work/bin",
    '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
    '-Fusrc/webview', "-Fu$platformUnits",
    '-Futest/cap16', '-Futest/security') + $mormotPaths + @("-Fl$static")
if ($IsWindows) { $common = @('-Px86_64', '-Twin64') + $common }

$failed = New-Object System.Collections.Generic.List[string]
function Build([string]$Source, [string[]]$Extra) {
    Write-Host "[CAP-16] compiling $Source"
    $fpcArgs = $common + $Extra + @($Source)
    & fpc @fpcArgs | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { $failed.Add($Source); Write-Host "[CAP-16] $Source compile FAILED" }
}

# --- the page's SDK --------------------------------------------------------
$sdkDist = 'sdk/typescript/dist/src'
$fixture = Join-Path $work 'fixture-live'
Remove-Item -Recurse -Force $fixture -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $fixture 'sdk') | Out-Null
if (-not (Test-Path (Join-Path $sdkDist 'signal.js'))) {
    $failed.Add("$sdkDist/signal.js (the @pweb/runtime build is missing or predates CAP-16)")
} else {
    Copy-Item -Force (Join-Path $sdkDist '*.js') (Join-Path $fixture 'sdk')
}
Copy-Item -Force 'test/cap16/fixture/live/*' $fixture
Write-Host "[CAP-16] staged the live fixture with @pweb/runtime at $fixture"

# --- the headless suite ----------------------------------------------------
Build 'test/cap16/cap16tests.pas' @()

# --- the two live programs -------------------------------------------------
if ($IsWindows) {
    Build 'test/cap16/evalprobe.pas' @('-Flbuild/webview-dist')
    Build 'test/cap16/signallive.pas' @('-Flbuild/webview-dist')
    $dist = 'build/webview-dist/webview.dll'
    if (Test-Path -LiteralPath $dist) {
        Copy-Item -Force $dist (Join-Path $work 'bin')
        Write-Host "[CAP-16] staged $(Split-Path -Leaf $dist)"
    } else {
        Write-Host "[CAP-16] NOTE: $dist is not staged; the live programs will not run here"
    }
} elseif ($IsMacOS) {
    # the link set is tools/macos-buildenv.sh's, never retyped (CAP-12B)
    & bash tools/build-macos-bridge.sh
    if ($LASTEXITCODE -ne 0) { $failed.Add('the Cocoa bridge object') }
    $macScript = @'
set -euo pipefail
. tools/macos-buildenv.sh
pweb_macos_init_fpc
[ -f "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" ] ||
    { echo "staged webview dylib missing: ${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" >&2; exit 1; }
for src in test/cap16/evalprobe.pas test/cap16/signallive.pas; do
    echo "[CAP-16] compiling $src (macos-buildenv link set)"
    fpc -MObjFPC -Sh -B -FU"$1" -FE"$2" \
        -Fusrc/rpc -Fusrc/security -Fusrc/lib -Fusrc/assets -Fusrc/webview \
        -Fusrc/platform/macos -Futest/cap16 -Futest/security \
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib \
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net \
        -Fudeps/mormot2/src/db -Fudeps/mormot2/src/orm \
        -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_BRIDGE[@]}" \
        "$src" | tail -n 3
done
cp -f -- "${PWEB_MACOS_DIST}/${PWEB_MACOS_DYLIB_VERSIONED}" "$2/"
echo "[CAP-16] staged ${PWEB_MACOS_DYLIB_VERSIONED}"
'@
    & bash -c $macScript bash "$work/units" "$work/bin"
    if ($LASTEXITCODE -ne 0) { $failed.Add('test/cap16/evalprobe.pas + signallive.pas (macOS)') }
} else {
    Build 'test/cap16/evalprobe.pas' @('-Flbuild/cap7l/webview-dist', '-k-rpath=$ORIGIN')
    Build 'test/cap16/signallive.pas' @('-Flbuild/cap7l/webview-dist', '-k-rpath=$ORIGIN')
    $dist = 'build/cap7l/webview-dist/libwebview.so.0.12'
    if (Test-Path -LiteralPath $dist) {
        Copy-Item -Force $dist (Join-Path $work 'bin')
        Write-Host "[CAP-16] staged $(Split-Path -Leaf $dist)"
    } else {
        Write-Host "[CAP-16] NOTE: $dist is not staged; the live programs will not run here"
    }
}

# --- the Darwin path, TYPE-CHECKED where no Darwin exists -------------------
# The CAP-12B shape and reason: the live programs name the folder store,
# whose Darwin half only a POSIX host can check, so Linux type-checks them
if ($IsLinux) {
    $tcUnits = Join-Path $work 'typecheck'
    Remove-Item -Recurse -Force $tcUnits -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tcUnits | Out-Null
    foreach ($src in 'test/cap16/evalprobe.pas', 'test/cap16/signallive.pas') {
        Write-Host "[CAP-16] type-checking $src as Darwin (-dDARWIN -Cn)"
        $tcArgs = @('-MObjFPC', '-Sh', '-B', '-Cn', '-dDARWIN',
            "-FU$tcUnits", "-FE$tcUnits",
            '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
            '-Fusrc/webview', '-Fusrc/platform/macos',
            '-Futest/cap16', '-Futest/security') + $mormotPaths + @("-Fl$static")
        & fpc @tcArgs $src | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { $failed.Add("$src (Darwin type check)") }
    }
}

if ($failed.Count -gt 0) {
    throw "[CAP-16] build FAILED: $($failed -join ', ')"
}
$exe = if ($IsWindows) { '.exe' } else { '' }
foreach ($w in "cap16tests$exe", "evalprobe$exe", "signallive$exe") {
    if (-not (Test-Path (Join-Path $work "bin/$w"))) { throw "expected artifact missing: $w" }
}
Write-Host '[CAP-16] build OK'
