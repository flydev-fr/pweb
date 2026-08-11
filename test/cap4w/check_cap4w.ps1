param(
    [string]$WebViewBuildDir = 'build/webview-build-cap4w',
    [string]$ProbeBuildDir = 'build/cap4w/probe',
    [ValidateRange(1, 20)]
    [int]$Cycles = 3,
    [switch]$CompileOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WebViewBuild = [IO.Path]::GetFullPath((Join-Path $RepoRoot $WebViewBuildDir))
$ProbeBuild = [IO.Path]::GetFullPath((Join-Path $RepoRoot $ProbeBuildDir))
$ExpectedProbePrefix = [IO.Path]::GetFullPath(
    (Join-Path $RepoRoot 'build\cap4w')) + [IO.Path]::DirectorySeparatorChar
if (-not $ProbeBuild.StartsWith($ExpectedProbePrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "[CAP-4W] probe build path must remain below build/cap4w: $ProbeBuild"
}

$WebViewDll = Join-Path $WebViewBuild 'core\Release\webview.dll'
$WebViewLib = Join-Path $WebViewBuild 'core\Release\webview.lib'
$SdkHeader = Join-Path $WebViewBuild `
    '_deps\microsoft_web_webview2-src\build\native\include\WebView2.h'
foreach ($required in @($WebViewDll, $WebViewLib, $SdkHeader)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "[CAP-4W] required input missing: $required"
    }
}

cmake -B $ProbeBuild -S $PSScriptRoot `
    "-DPWEB_ROOT=$RepoRoot" `
    "-DWEBVIEW_BUILD_DIR=$WebViewBuild"
if ($LASTEXITCODE -ne 0) { throw '[CAP-4W] probe configure failed' }

cmake --build $ProbeBuild --config Release
if ($LASTEXITCODE -ne 0) { throw '[CAP-4W] probe compile failed' }

$ProbeExe = Join-Path $ProbeBuild 'Release\cap4w_probe.exe'
$BoundaryExe = Join-Path $ProbeBuild 'Release\cap4w_loader_boundary.exe'
foreach ($executable in @($ProbeExe, $BoundaryExe)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "[CAP-4W] probe executable missing: $executable"
    }
}
Copy-Item -LiteralPath $WebViewDll -Destination `
    (Join-Path (Split-Path -Parent $ProbeExe) 'webview.dll') -Force

$boundaryOutput = & $BoundaryExe 2>&1 | Out-String
$boundaryCode = $LASTEXITCODE
Write-Host $boundaryOutput.TrimEnd()
if (($boundaryCode -ne 0) -or
    ($boundaryOutput -notmatch 'CAP4W_LOADER_BOUNDARY_PASS')) {
    throw '[CAP-4W] private loader boundary gate failed'
}
Write-Host '[CAP-4W] COMPILE PASS'
if ($CompileOnly) { exit 0 }

$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $ProbeExe
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.CreateNoWindow = $false
[void]$start.ArgumentList.Add($Cycles.ToString(
    [Globalization.CultureInfo]::InvariantCulture))
$process = [Diagnostics.Process]::Start($start)
if ($null -eq $process) { throw '[CAP-4W] failed to start runtime probe' }
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timeoutMs = 10000 + ($Cycles * 25000)
    if (-not $process.WaitForExit($timeoutMs)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "[CAP-4W] runtime probe exceeded ${timeoutMs}ms"
    }
    $outText = $stdout.GetAwaiter().GetResult()
    $errorText = $stderr.GetAwaiter().GetResult()
    if ($outText) { Write-Host $outText.TrimEnd() }
    if ($errorText) { Write-Host $errorText.TrimEnd() }
    if ($process.ExitCode -ne 0) {
        throw "[CAP-4W] runtime probe failed with exit $($process.ExitCode)"
    }
}
finally {
    $process.Dispose()
}
Write-Host '[CAP-4W] RUNTIME PASS'
