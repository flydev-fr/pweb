# CAP-15C: build everything the gates drive.
#
#   cap15ctests   the headless suite - the wss authorisation rule, the
#                 handshake allowlists, the traffic contract, the bounded
#                 queue, ownership, the lifecycle and the capability wiring,
#                 all through the INJECTED transport, no socket anywhere
#   socketlive    the SHIPPED transport through the REAL decorator, against
#                 test/cap15c/ws_server.js
#   socketstarve  the starvation measurement: the real scheduler at the host
#                 defaults, the real policy, the decorator and the mORMot
#                 SOA bridge, against the same witness (Windows and Linux)
#
# Like build_cap15b.ps1 it builds no GUI host: every claim these gates make
# about a built image is a property of the binary, and a window would add a
# display dependency to a proof that does not need one.
#
# Usage: pwsh test/cap15c/build_cap15c.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap15c'
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
    "-Fu$platformUnits",
    '-Futest/cap15c',
    '-Fideps/mormot2/src',
    '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
    '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net',
    "-Fl$static"
)
if ($IsWindows) { $common = @('-Px86_64', '-Twin64') + $common }

function Build([string]$Source, [string[]]$Extra) {
    Write-Host "[CAP-15C] compiling $Source"
    $fpcArgs = $common + $Extra + @($Source)
    & fpc @fpcArgs | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw "$Source compile FAILED" }
}

# THE DARWIN TRANSPORT IS A SEAM OVER AN OBJECT, exactly as 15B's fetch is:
# every program that compiles `pweb.platform.cocoa.socket` links the bridge
# object and the frameworks behind it, from this ONE variable
$macLink = @()
if ($IsMacOS) {
    & bash tools/build-macos-bridge.sh
    if ($LASTEXITCODE -ne 0) { throw 'the Cocoa bridge did not build' }
    $bridge = 'build/cap7m/bridge/pweb_cocoa_bridge.o'
    if (-not (Test-Path $bridge)) { throw "bridge object missing: $bridge" }
    $macLink = @("-k$bridge", '-k-framework', '-kCocoa', '-k-framework',
        '-kWebKit', '-k-lc++', '-k-lobjc')
}

# the headless suite names no platform unit and gets no link flags: if it
# ever needs them, it has stopped being the headless suite
Build 'test/cap15c/cap15ctests.pas' @()
Build 'test/cap15c/socketlive.pas' $macLink
# the CAP-6 bundler, for the app.pwb refusal of a socket field (B5)
Build 'tools/bundler/pwebbundle.pas' @()
# THE STARVATION MEASUREMENT, Windows and Linux only - the two targets whose
# transport is the mORMot one it composes. It is a measurement of the
# scheduler under the host defaults, not of a transport, so the macOS legs
# carry `not_applicable` rows rather than a second transport's copy of it.
if (-not $IsMacOS) {
    Build 'test/cap15c/socketstarve.pas' @('-Fudeps/mormot2/src/db',
        '-Fudeps/mormot2/src/orm', '-Fudeps/mormot2/src/rest',
        '-Fudeps/mormot2/src/soa')
}

# --- the Darwin path, TYPE-CHECKED where no Darwin exists -------------------
#
# 15B's lesson, applied from the first commit: `pweb.platform.cocoa.socket`
# is compiled by exactly one target, so its Pascal half and the live program
# that names it are type-checked here with `-dDARWIN -Cn` on every other
# target. It proves well-formed Pascal against the real interfaces and
# nothing about NSURLSessionWebSocketTask's behaviour, which the Darwin leg
# measures.
if (-not $IsMacOS) {
    $tcUnits = Join-Path $work 'typecheck'
    Remove-Item -Recurse -Force $tcUnits -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tcUnits | Out-Null
    foreach ($src in 'src/platform/macos/pweb.platform.cocoa.socket.pas',
                     'test/cap15c/socketlive.pas') {
        Write-Host "[CAP-15C] type-checking $src as Darwin (-dDARWIN -Cn)"
        $tcArgs = @('-MObjFPC', '-Sh', '-B', '-Cn', '-dDARWIN',
            "-FU$tcUnits", "-FE$tcUnits",
            '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib',
            '-Fusrc/assets', '-Fusrc/platform/macos', '-Futest/cap15c',
            '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
            '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
            '-Fudeps/mormot2/src/net', "-Fl$static")
        if ($IsWindows) { $tcArgs = @('-Px86_64', '-Twin64') + $tcArgs }
        & fpc @tcArgs $src | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { throw "$src does not type-check as Darwin" }
    }
    Write-Host '[CAP-15C] the Darwin socket path type-checks off a Mac (2 sources)'
}

$exe = if ($IsWindows) { '.exe' } else { '' }
$wanted = @("cap15ctests$exe", "socketlive$exe", "pwebbundle$exe")
if (-not $IsMacOS) { $wanted += "socketstarve$exe" }
foreach ($w in $wanted) {
    if (-not (Test-Path (Join-Path $work "bin/$w"))) {
        throw "expected artifact missing: $w"
    }
}
Write-Host "[CAP-15C] built: $($wanted -join ', ')"
