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

# THE DARWIN TRANSPORT IS A SEAM OVER AN OBJECT, and every artifact that
# compiles `pweb.platform.cocoa.fetch` has to link that object and the two
# frameworks behind it. MEASURED, on hosted run 34457918457: `fetchlive` and
# the two `nethost` witnesses were built WITHOUT them, so both macOS legs
# died at the linker with
#
#   Undefined symbols for architecture x86_64:
#     "_pweb_cocoa_fetch", referenced from:
#        _PWEB.PLATFORM.COCOA.FETCH_$$_PWEBFETCHNATIVETRANSPORT ...
#
# The production path never had this problem - `pweb.cli.native.pas` already
# pushes the bridge object and `-framework Cocoa -framework WebKit` for a
# generated project - so it is the TEST HARNESS that was linking half a
# transport. The flags live in ONE variable here and are handed to every
# artifact that needs them, so a third artifact cannot be added with only
# the compile half.
$macLink = @()
if ($IsMacOS) {
    # the bridge object carries the NSURLSession seam, and it is rebuilt
    # here rather than assumed: CAP-7M1 builds it earlier on the leg, but a
    # developer running only this script has no such step
    & bash tools/build-macos-bridge.sh
    if ($LASTEXITCODE -ne 0) { throw 'the Cocoa bridge did not build' }
    $bridge = 'build/cap7m/bridge/pweb_cocoa_bridge.o'
    if (-not (Test-Path $bridge)) { throw "bridge object missing: $bridge" }
    $macLink = @("-k$bridge", '-k-framework', '-kCocoa', '-k-framework',
        '-kWebKit', '-k-lc++', '-k-lobjc')
}

# cap15btests drives the INJECTED transport only and names no platform unit,
# so it deliberately gets no link flags: if it ever needs them, it has
# stopped being the headless suite.
Build 'test/cap15b/cap15btests.pas' @()
Build 'test/cap15b/fetchlive.pas' $macLink
if ($IsMacOS) { Build 'test/cap15b/darwinprobe.pas' $macLink }
Build 'tools/bundler/pwebbundle.pas' @()

# --- the Darwin path, TYPE-CHECKED where no Darwin exists -------------------
#
# `src/platform/macos/pweb.platform.cocoa.fetch.pas` is compiled by exactly
# one target, and this development host is not it. Three hosted runs in a row
# were spent on defects in the macOS path that no reachable leg could see, so
# the Pascal half is checked HERE, on every non-Darwin target, by compiling it
# with `-dDARWIN -Cn`: `-dDARWIN` takes the unit past its own
# `{$MESSAGE Error}` guard and selects the Darwin branch of everything that
# has one, and `-Cn` omits the link - which is the only part that genuinely
# needs a Mac, and which C15 covers separately by pairing every program that
# names the unit against the bridge object.
#
# It is a TYPE CHECK and says so: it proves the unit and its callers are
# well-formed Pascal against the real interfaces, and proves nothing about
# NSURLSession's behaviour. That is what `darwinprobe` measures on the leg.
if (-not $IsMacOS) {
    $tcUnits = Join-Path $work 'typecheck'
    Remove-Item -Recurse -Force $tcUnits -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tcUnits | Out-Null
    foreach ($src in 'src/platform/macos/pweb.platform.cocoa.fetch.pas',
                     'test/cap15b/fetchlive.pas',
                     'test/cap15b/darwinprobe.pas') {
        Write-Host "[CAP-15B] type-checking $src as Darwin (-dDARWIN -Cn)"
        $tcArgs = @('-MObjFPC', '-Sh', '-B', '-Cn', '-dDARWIN',
            "-FU$tcUnits", "-FE$tcUnits",
            '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib',
            '-Fusrc/assets', '-Fusrc/platform/macos', '-Futest/cap15b',
            '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
            '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
            '-Fudeps/mormot2/src/net', "-Fl$static")
        if ($IsWindows) { $tcArgs = @('-Px86_64', '-Twin64') + $tcArgs }
        & fpc @tcArgs $src | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { throw "$src does not type-check as Darwin" }
    }
    Write-Host '[CAP-15B] the Darwin path type-checks off a Mac (3 sources)'
}

$exe = if ($IsWindows) { '.exe' } else { '' }
$wanted = @("cap15btests$exe", "fetchlive$exe", "pwebbundle$exe")
if ($IsMacOS) { $wanted += "darwinprobe$exe" }
foreach ($w in $wanted) {
    if (-not (Test-Path (Join-Path $work "bin/$w"))) {
        throw "expected artifact missing: $w"
    }
}
Write-Host "[CAP-15B] built: $($wanted -join ', ')"
