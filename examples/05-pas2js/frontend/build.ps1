# Builds the CAP-5 Pas2JS frontend into dist/ using ONLY the pinned
# toolchain from deps/pas2js (tools/get-pas2js.ps1). The browser-loaded
# JS originates from Pas2JS compilation of src/p2japp.pas - there is no
# handwritten JavaScript in this frontend beyond the one-line rtl.run()
# bootstrap in index.html.
$ErrorActionPreference = 'Stop'

$FrontendDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $FrontendDir '../../..')).Path
# CAP-7L/CAP-7M2: same pinned compiler, host-specific checkout (see
# pas2js.lock). Not $IsWindows - that variable does not exist in Windows
# PowerShell 5.1; off Windows the split is on `uname -s` for the same reason.
if ($env:OS -eq 'Windows_NT') {
    $Compiler = Join-Path $RepoRoot 'deps/pas2js/bin/pas2js.exe'
}
elseif ((& uname -s | Out-String).Trim() -eq 'Darwin') {
    $Compiler = Join-Path $RepoRoot 'deps/pas2js-darwin/bin/pas2js'
}
else {
    $Compiler = Join-Path $RepoRoot 'deps/pas2js-linux/bin/pas2js'
}
if (-not (Test-Path $Compiler)) {
    throw "pinned pas2js missing at $Compiler -- run: pwsh tools/get-pas2js.ps1"
}

$Dist = Join-Path $FrontendDir 'dist'
if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force (Join-Path $Dist 'assets') | Out-Null

$OutJs = Join-Path $Dist 'assets/app.js'
$CompilerArgs = @(
    '-Tbrowser', '-Jc', '-Jirtl.js', '-O1',
    ('-Fu' + (Join-Path $RepoRoot 'sdk/pas2js')),
    ('-o' + $OutJs),
    (Join-Path $FrontendDir 'src/p2japp.pas')
)
& $Compiler @CompilerArgs
if ($LASTEXITCODE -ne 0) { throw 'pas2js frontend compile failed' }
if (-not (Test-Path $OutJs)) {
    throw 'pas2js frontend output missing (dist/assets/app.js)'
}
Copy-Item (Join-Path $FrontendDir 'src/index.html') (Join-Path $Dist 'index.html')
Write-Host 'pas2js frontend built into dist/'
