# Builds the CAP-5 Pas2JS frontend into dist/ using ONLY the pinned
# toolchain from deps/pas2js (tools/get-pas2js.ps1). The browser-loaded
# JS originates from Pas2JS compilation of src/p2japp.pas - the one-line
# rtl.run() bootstrap is the only handwritten JavaScript, and CAP-8B
# moved it out of index.html into a bundled assets/boot.js emitted here.
#
# WHY IT MOVED. The ratified native CSP carries script-src 'self' with no
# 'unsafe-inline', and an inline <script> is exactly what that forbids -
# MEASURED blocked on WebView2, WebKitGTK and WKWebView alike. This was
# the only inline script served over pweb://app in the repository. The
# policy was NOT weakened to keep it; the one line became a file.
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

# The bootstrap, as a bundled classic script. app.js is compiled with -Jc,
# which concatenates the RTL and declares a top-level `var rtl` but never
# starts it, so a later classic script in the same global scope is all that
# is needed - no module, no defer, no inline code.
#
# Written byte-exactly rather than with Set-Content: these bytes ship inside
# app.pwb, and the CAP-7F cross-OS inventory gate requires every target to
# package the SAME bytes. WriteAllText with a UTF8Encoding($false) gives no
# BOM, and the LF is written literally instead of inherited from the host's
# newline convention (Windows PowerShell would otherwise emit CRLF here and
# make the Windows bundle diverge - the exact defect .gitattributes pins the
# committed frontend sources against).
$BootJs = Join-Path $Dist 'assets/boot.js'
[System.IO.File]::WriteAllText(
    $BootJs, "rtl.run();`n", (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-Path $BootJs)) {
    throw 'pas2js frontend bootstrap missing (dist/assets/boot.js)'
}
Write-Host 'pas2js frontend built into dist/'
