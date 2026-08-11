# Builds webview.dll (upstream webview::core_shared, C ABI exports) from the
# PINNED checkout in deps/webview, using cmake + MSVC.
#
# This is the linkage chosen for CAP-1: FPC binds the C ABI of the shared
# library; no Pascal <-> C++ ABI contact, no static C++ runtime entanglement.
#
# CAP-4W keeps the upstream commit fixed but overrides its old WebView2 SDK
# default with the exact PWeb Windows dependency pin in webview.lock. The
# package and dependency patch hashes are checked before compilation.
#
# Output: build/webview-dist/webview.dll
# Usage:  pwsh tools/build-webview-dll.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src      = Join-Path $RepoRoot 'deps\webview'
$BuildDir = Join-Path $RepoRoot 'build\webview-build-cap4w'
$DistDir  = Join-Path $RepoRoot 'build\webview-dist'
$LockFile = Join-Path $RepoRoot 'webview.lock'
$PatchScript = Join-Path $PSScriptRoot 'patch-cap4w-webview.ps1'

function Read-LockFile {
    $result = @{}
    $lineNumber = 0
    foreach ($lineValue in Get-Content -LiteralPath $LockFile) {
        $lineNumber++
        $line = $lineValue.Trim()
        if (($line -eq '') -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') {
            throw "webview.lock line ${lineNumber} is malformed"
        }
        $key, $value = $line -split '=', 2
        $key = $key.Trim()
        if ($result.ContainsKey($key)) {
            throw "webview.lock contains duplicate key '$key'"
        }
        $result[$key] = $value.Trim()
    }
    return $result
}

function Get-DirectoryTreeHash([string]$Root) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
    [string[]]$relativePaths = @(Get-ChildItem -LiteralPath $rootPath `
        -Recurse -File | ForEach-Object {
            $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        })
    if ($relativePaths.Count -eq 0) {
        throw "WebView2 SDK extraction is empty: $rootPath"
    }
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $manifest = foreach ($relative in $relativePaths) {
        $nativeRelative = $relative.Replace('/',
            [IO.Path]::DirectorySeparatorChar)
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath `
            (Join-Path $rootPath $nativeRelative)).Hash.ToLowerInvariant()
        "$hash  $relative"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (($manifest -join "`n") + "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).
            Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

if (-not (Test-Path (Join-Path $Src 'CMakeLists.txt'))) {
    throw 'deps/webview missing -- run tools/get-webview.ps1 first'
}
if (-not (Test-Path -LiteralPath $PatchScript -PathType Leaf)) {
    throw "CAP-4W patch script missing: $PatchScript"
}

$lock = Read-LockFile
$SdkVersion = $lock['webview2-sdk']
$SdkSha256 = $lock['webview2-sdk-sha256']
$SdkTreeSha256 = $lock['webview2-sdk-tree-sha256']
if ($SdkVersion -cne '1.0.1587.40') {
    throw "unexpected WebView2 SDK pin '$SdkVersion'"
}
if (-not $SdkSha256 -or ($SdkSha256 -cnotmatch '^[0-9a-f]{64}$')) {
    throw 'webview.lock has no full lowercase WebView2 SDK package hash'
}
if (-not $SdkTreeSha256 -or
    ($SdkTreeSha256 -cnotmatch '^[0-9a-f]{64}$')) {
    throw 'webview.lock has no full lowercase WebView2 SDK tree hash'
}

& pwsh -NoProfile -File $PatchScript
if ($LASTEXITCODE -ne 0) {
    throw 'CAP-4W dependency patch preparation failed'
}

cmake -B $BuildDir -S $Src `
    "-DWEBVIEW_MSWEBVIEW2_VERSION=$SdkVersion" `
    -DWEBVIEW_BUILD_TESTS=OFF `
    -DWEBVIEW_BUILD_EXAMPLES=OFF `
    -DWEBVIEW_BUILD_DOCS=OFF `
    -DWEBVIEW_BUILD_STATIC_LIBRARY=OFF `
    -DWEBVIEW_BUILD_AMALGAMATION=OFF
if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }

$CacheFile = Join-Path $BuildDir 'CMakeCache.txt'
if (-not (Test-Path -LiteralPath $CacheFile -PathType Leaf)) {
    throw "CMake cache missing: $CacheFile"
}
$cache = Get-Content -Raw -LiteralPath $CacheFile
if ($cache -notmatch "(?m)^WEBVIEW_MSWEBVIEW2_VERSION:STRING=$([regex]::Escape($SdkVersion))`r?$") {
    throw 'CMake cache does not contain the exact WebView2 SDK pin'
}
$includeMatch = [regex]::Match($cache,
    '(?m)^MSWebView2_INCLUDE_DIR:PATH=(.+?)\r?$')
if (-not $includeMatch.Success) {
    throw 'CMake cache has no MSWebView2 include directory'
}
$sdkInclude = [IO.Path]::GetFullPath($includeMatch.Groups[1].Value.Trim())
$expectedSdkPrefix = [IO.Path]::GetFullPath(
    (Join-Path $BuildDir '_deps\microsoft_web_webview2-src')) +
    [IO.Path]::DirectorySeparatorChar
if (-not $sdkInclude.StartsWith($expectedSdkPrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "CMake selected an unpinned external WebView2 SDK: $sdkInclude"
}
$sdkOptions = Join-Path $sdkInclude 'WebView2EnvironmentOptions.h'
if (-not (Test-Path -LiteralPath $sdkOptions -PathType Leaf)) {
    throw "custom-scheme SDK header missing: $sdkOptions"
}
if ((Get-Content -Raw -LiteralPath $sdkOptions) -notmatch
    'CORE_WEBVIEW_TARGET_PRODUCT_VERSION L"110\.0\.1587\.40"') {
    throw 'WebView2 environment-options header is not SDK 1.0.1587.40'
}

$archives = @(Get-ChildItem -LiteralPath (Join-Path $BuildDir '_deps') `
    -Filter archive.tar -File -Recurse -ErrorAction SilentlyContinue)
if ($archives.Count -ne 1) {
    throw "expected one fetched WebView2 package archive, found $($archives.Count)"
}
$gotSdkSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archives[0].FullName).
    Hash.ToLowerInvariant()
if ($gotSdkSha -cne $SdkSha256) {
    throw "WebView2 SDK package hash mismatch: got $gotSdkSha expected $SdkSha256"
}
$sdkRoot = [IO.Path]::GetFullPath(
    (Join-Path $BuildDir '_deps\microsoft_web_webview2-src'))
$gotSdkTreeSha = Get-DirectoryTreeHash $sdkRoot
if ($gotSdkTreeSha -cne $SdkTreeSha256) {
    throw "WebView2 SDK extracted-tree hash mismatch: got $gotSdkTreeSha expected $SdkTreeSha256"
}

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
Write-Host "WebView2 SDK -> $SdkVersion (package=$gotSdkSha tree=$gotSdkTreeSha)"
