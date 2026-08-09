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

# Exact expected output path for the VS generator, Release config -- never a
# recursive first-match, which could silently pick a stale or debug DLL.
$Dll = Join-Path $BuildDir 'core\Release\webview.dll'
if (-not (Test-Path $Dll)) { throw "expected DLL not found: $Dll" }

New-Item -ItemType Directory -Force $DistDir | Out-Null
Copy-Item $Dll (Join-Path $DistDir 'webview.dll') -Force

# Ship the upstream MIT license next to any distributed binary, and the
# WebView2 SDK license (the DLL embeds upstream's WebView2 loader built
# against the SDK; its license requires the notice with binary distribution).
Copy-Item (Join-Path $Src 'LICENSE') (Join-Path $DistDir 'LICENSE.webview') -Force
$SdkLicense = Join-Path $BuildDir '_deps\microsoft_web_webview2-src\LICENSE.txt'
if (-not (Test-Path $SdkLicense)) { throw "WebView2 SDK license not found: $SdkLicense" }
Copy-Item $SdkLicense (Join-Path $DistDir 'LICENSE.webview2sdk') -Force

Write-Host "webview.dll -> $DistDir\webview.dll"
