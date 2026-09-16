<#
CAP-12A: the blob data-plane measurement on Windows x64 (WebView2). The
PowerShell sibling of test/cap12a/run_cap12a.sh, and it MUST stay a sibling:
the two scripts differ in how they build and run, never in what a row means -
that lives once, in test/cap12a/summarize.js.

NOTHING HERE MAY BECOME A CI STEP. The run puts a throwaway store behind the
production pweb://app seam, and a gate that does that is a gate that can
normalise it. It is a measurement instrument, run by hand.

Prerequisites: fpc and node on PATH; a webview.dll staged at
build/webview-dist/webview.dll (tools/build-webview-dll.ps1), and an
installed WebView2 runtime.

Usage: pwsh test/cap12a/run_cap12a.ps1 [-TimeoutMs 600000] [-Debug]
#>
[CmdletBinding()]
param(
    [ValidateRange(10000, 1200000)][int]$TimeoutMs = 600000,
    [switch]$DebugWindow
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

function Step([string]$m) { Write-Host "`n[CAP-12A] === $m" }

# The delete is validated against build/ before it happens, exactly as the
# POSIX sibling does and for the same reason (deferred-work 7M0-6).
function Remove-BuildTree([string]$p) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $p))
    $root = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'build'))
    if (-not $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar)) {
        throw "refusing to delete outside build/: $full"
    }
    if (Test-Path $full) { Remove-Item -Recurse -Force $full }
}

foreach ($tool in 'fpc', 'node') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "required tool not found: $tool"
    }
}
foreach ($pre in 'test/cap12a/blobprobe.pas', 'test/cap12a/blobsource.pas',
                 'test/cap12a/spikewv2.pas', 'test/cap12a/summarize.js',
                 'test/cap12a/fixture/index.html',
                 'test/cap12a/fixture/assets/probe.js',
                 'src/assets/pweb.assets.support.pas',
                 'src/security/pweb.navigation.policy.pas') {
    if (-not (Test-Path $pre)) { throw "missing precondition: $pre" }
}
if (-not (Test-Path 'build/webview-dist/webview.dll')) {
    throw 'build/webview-dist/webview.dll is missing -- run tools/build-webview-dll.ps1'
}

$target = 'windows-x86_64'
$work = Join-Path $repoRoot 'build/cap12a'
New-Item -ItemType Directory -Force $work | Out-Null
$unitDir = "build/cap12a/fpc-$target"
$outDir = "build/cap12a/bin-$target"
Remove-BuildTree $unitDir
Remove-BuildTree $outDir
New-Item -ItemType Directory -Force $unitDir, $outDir | Out-Null

Step "compile blobprobe ($target)"
$fpcArgs = @(
    '-Px86_64', '-Twin64', '-MObjFPC', '-Sh', '-B',
    "-FU$unitDir", "-FE$outDir",
    '-Futest/cap12a', '-Fusrc/lib', '-Fusrc/assets', '-Fusrc/security',
    '-Fusrc/webview', '-Fusrc/rpc', '-Futest/security',
    '-Fusrc/platform/windows',
    '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
    '-Fudeps/mormot2/src/net',
    '-Fldeps/mormot2/static/x86_64-win64',
    'test/cap12a/blobprobe.pas'
)
$buildOut = (& fpc @fpcArgs 2>&1 | Out-String)
Set-Content -Path (Join-Path $work "build-$target.log") -Value $buildOut
if ($LASTEXITCODE -ne 0) {
    Write-Host $buildOut
    throw 'blobprobe.pas compile FAILED'
}
Copy-Item build/webview-dist/webview.dll $outDir -Force

Step "run blobprobe in a real window ($target)"
$env:PWEB_CAP12A_TIMEOUT_MS = "$TimeoutMs"
if ($DebugWindow) { $env:PWEB_CAP12A_DEBUG = '1' } else { $env:PWEB_CAP12A_DEBUG = '' }
$runLog = Join-Path $work "run-$target.log"
$errLog = Join-Path $work "run-$target.err.log"
$proc = Start-Process -FilePath (Resolve-Path "$outDir/blobprobe.exe") `
    -WorkingDirectory (Resolve-Path $outDir) -PassThru -NoNewWindow `
    -RedirectStandardOutput $runLog -RedirectStandardError $errLog
# the host carries its own watchdog; this bound only stops the SCRIPT from
# waiting for ever if the process itself wedges
if (-not $proc.WaitForExit($TimeoutMs + 120000)) {
    try { $proc.Kill() } catch { }
    throw 'blobprobe did not exit within its watchdog plus margin'
}
Get-Content $runLog | Select-Object -Last 20
if (Test-Path $errLog) { Get-Content $errLog | Select-Object -Last 20 }
if ($proc.ExitCode -ne 0) { throw "blobprobe exited $($proc.ExitCode)" }

Step 'summarize'
& node test/cap12a/summarize.js --work $work
& node test/cap12a/summarize.js --work $work --json |
    Set-Content -Path (Join-Path $work 'summary.json')
Write-Host "[CAP-12A] summary: $(Join-Path $work 'summary.json')"
