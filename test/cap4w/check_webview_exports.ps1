param(
    [string]$DllPath = 'build/webview-dist/webview.dll'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Dll = [IO.Path]::GetFullPath((Join-Path $RepoRoot $DllPath))
if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) {
    throw "[CAP-4W] webview DLL missing: $Dll"
}

function Resolve-Dumpbin {
    $command = Get-Command dumpbin.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    if ($env:VCToolsInstallDir) {
        $candidate = Join-Path $env:VCToolsInstallDir `
            'bin\Hostx64\x64\dumpbin.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = (& $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath).Trim()
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $tools = Join-Path $installation 'VC\Tools\MSVC'
            $candidate = Get-ChildItem -LiteralPath $tools -Directory |
                Sort-Object Name -Descending |
                ForEach-Object {
                    Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe'
                } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    throw '[CAP-4W] dumpbin.exe not found'
}

$expected = @(
    'webview_bind', 'webview_create', 'webview_destroy', 'webview_dispatch',
    'webview_eval', 'webview_get_native_handle', 'webview_get_window',
    'webview_init', 'webview_navigate', 'webview_return', 'webview_run',
    'webview_set_html', 'webview_set_size', 'webview_set_title',
    'webview_terminate', 'webview_unbind', 'webview_version'
) | Sort-Object

$dumpbin = Resolve-Dumpbin
$output = @(& $dumpbin /nologo /exports $Dll 2>&1)
if ($LASTEXITCODE -ne 0) { throw '[CAP-4W] dumpbin failed' }
$exports = @($output | ForEach-Object {
    # Capture the public name even when dumpbin appends a forwarding target.
    # Ignoring multi-token rows could otherwise hide an extra forwarded export.
    if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)(?:\s+.*)?$') {
        $Matches[1]
    }
} | Where-Object { $_ } | Sort-Object)

$diff = @(Compare-Object -ReferenceObject $expected -DifferenceObject $exports)
if (($exports.Count -ne 17) -or ($diff.Count -ne 0)) {
    $output | ForEach-Object { Write-Host $_ }
    throw "[CAP-4W] DLL export surface mismatch: got $($exports.Count), expected 17"
}

Write-Host '[CAP-4W] C ABI PASS - exactly 17 unchanged webview exports'
