# Builds webview.dll (upstream webview::core_shared, C ABI exports) from the
# PINNED checkout in deps/webview, using cmake + MSVC.
#
# This is the linkage chosen for CAP-1: FPC binds the C ABI of the shared
# library; no Pascal <-> C++ ABI contact, no static C++ runtime entanglement.
#
# The WebView2 SDK nuget package version used by the build is pinned INSIDE
# the pinned upstream commit (cmake/webview.cmake, WEBVIEW_MSWEBVIEW2_VERSION)
# -- no floating ref is introduced here.
#
# Output: build/webview-dist/webview.dll
# Usage:  pwsh tools/build-webview-dll.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src      = Join-Path $RepoRoot 'deps\webview'
$BuildDir = Join-Path $RepoRoot 'build\webview-build'
$DistDir  = Join-Path $RepoRoot 'build\webview-dist'

if (-not (Test-Path (Join-Path $Src 'CMakeLists.txt'))) {
    throw 'deps/webview missing -- run tools/get-webview.ps1 first'
}

cmake -B $BuildDir -S $Src `
    -DWEBVIEW_BUILD_TESTS=OFF `
    -DWEBVIEW_BUILD_EXAMPLES=OFF `
    -DWEBVIEW_BUILD_DOCS=OFF `
    -DWEBVIEW_BUILD_STATIC_LIBRARY=OFF `
    -DWEBVIEW_BUILD_AMALGAMATION=OFF
if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }

cmake --build $BuildDir --target webview_core_shared --config Release
if ($LASTEXITCODE -ne 0) { throw 'cmake build failed' }

$Dll = Get-ChildItem -Recurse $BuildDir -Filter 'webview.dll' | Select-Object -First 1
if (-not $Dll) { throw 'webview.dll not found in build output' }

New-Item -ItemType Directory -Force $DistDir | Out-Null
Copy-Item $Dll.FullName (Join-Path $DistDir 'webview.dll') -Force

# Ship the upstream MIT license next to any distributed binary.
Copy-Item (Join-Path $Src 'LICENSE') (Join-Path $DistDir 'LICENSE.webview') -Force

Write-Host "webview.dll -> $DistDir\webview.dll"
