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

# THE LIVE BINARY LINKS THE WEBVIEW LIBRARY AND, ON DARWIN, THE BRIDGE
# OBJECT - one variable, exactly as CAP-15B and CAP-15C do it, so that the
# three targets differ in link flags and in nothing else.
$liveLink = @()
if ($IsWindows) {
    $liveLink += '-Flbuild/webview-dist'
} elseif ($IsMacOS) {
    $liveLink += @('-Flbuild/cap7m/webview-dist',
        '-k' + (Join-Path $repoRoot 'build/cap7m/bridge/pweb_cocoa_bridge.o'),
        '-kframework', '-kCocoa', '-kframework', '-kWebKit')
} else {
    $liveLink += @('-Flbuild/cap7l/webview-dist', '-k-rpath=$ORIGIN')
}

function Build([string]$Source, [string[]]$Extra) {
    Write-Host "[CAP-12B] compiling $Source"
    $fpcArgs = $common + $Extra + @($Source)
    & fpc @fpcArgs | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw "$Source compile FAILED" }
}

Build 'test/cap12b/cap12btests.pas' @()
Build 'test/cap12b/bloblive.pas' $liveLink

# the engine library must sit beside the live binary, exactly as every other
# live harness in this repository stages it
$dist = if ($IsWindows) { 'build/webview-dist/webview.dll' }
    elseif ($IsMacOS) { 'build/cap7m/webview-dist/libwebview.0.12.dylib' }
    else { 'build/cap7l/webview-dist/libwebview.so.0.12' }
if (Test-Path -LiteralPath $dist) {
    Copy-Item -Force $dist (Join-Path $work 'bin')
    Write-Host "[CAP-12B] staged $(Split-Path -Leaf $dist)"
} else {
    Write-Host "[CAP-12B] NOTE: $dist is not staged; bloblive will not run here"
}

Write-Host '[CAP-12B] build OK'
