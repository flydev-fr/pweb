# CAP-15B: build everything the gates drive.
#
#   cap15btests   the headless suite - the whole §4/§5 decision through the
#                 INJECTED transport, no socket anywhere
#   fetchlive     the SHIPPED transport against a real local server, which is
#                 the one half a fake transport cannot stand in for
#   darwinprobe   macOS only: the §10 NSURLSession measurement CAP-15A
#                 deferred to this shard's Checkpoint 1
#   pwebbundle    the CAP-6 bundler, for §7.4's manifest refusal
#
# It does NOT build a GUI host: every claim these gates make about a built
# image - the CSP, the compiled allowlist digest, the relaxation sweep and
# the compiled unit set - is a property of the BINARY, and a window would
# add a display dependency to a proof that does not need one.
#
# Usage: pwsh test/cap15b/build_cap15b.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap15b'
New-Item -ItemType Directory -Force $work | Out-Null
New-Item -ItemType Directory -Force (Join-Path $work 'units') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $work 'bin') | Out-Null

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
    "-Fu$platformUnits",
    '-Futest/cap15b',
    '-Fideps/mormot2/src',
    '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
    '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net',
    "-Fl$static"
)
if ($IsWindows) { $common = @('-Px86_64', '-Twin64') + $common }

function Build([string]$Source, [string[]]$Extra) {
    Write-Host "[CAP-15B] compiling $Source"
    $args = $common + $Extra + @($Source)
    & fpc @args | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw "$Source compile FAILED" }
}

Build 'test/cap15b/cap15btests.pas' @()
Build 'test/cap15b/fetchlive.pas' @()
if ($IsMacOS) {
    # the bridge object carries the NSURLSession seam; the probe links it
    & bash tools/build-macos-bridge.sh
    if ($LASTEXITCODE -ne 0) { throw 'the Cocoa bridge did not build' }
    $bridge = 'build/cap7m/bridge/pweb_cocoa_bridge.o'
    if (-not (Test-Path $bridge)) { throw "bridge object missing: $bridge" }
    Build 'test/cap15b/darwinprobe.pas' @(
        "-k$bridge", '-k-framework', '-kCocoa', '-k-framework', '-kWebKit',
        '-k-lc++', '-k-lobjc')
}
Build 'tools/bundler/pwebbundle.pas' @()

$exe = if ($IsWindows) { '.exe' } else { '' }
$wanted = @("cap15btests$exe", "fetchlive$exe", "pwebbundle$exe")
if ($IsMacOS) { $wanted += "darwinprobe$exe" }
foreach ($w in $wanted) {
    if (-not (Test-Path (Join-Path $work "bin/$w"))) {
        throw "expected artifact missing: $w"
    }
}
Write-Host "[CAP-15B] built: $($wanted -join ', ')"
