# CAP-9B1: the QuickJS plugin-package + module-loader harness on Windows x64.
#
# Builds test/cap9b1/quickjspackage.pas (the UNCHANGED production scheduler +
# CAP-8A policy + the real mORMot SOA bridge behind a counting decorator,
# driving CAP-9B1 package plugins as invocation sources) and runs the
# headless P1-P40 matrix, which writes the canonical
# build/cap9b1/quickjs-package-corpus.txt digest source.
#
# The real mORMot SOA bridge means this host, exactly like the CAP-9A
# harness, compiles INSIDE the CAP-3U window (patch-cap3u.ps1 apply ->
# compile -> restore + verify pristine).
#
# QuickJS statics: deps/mormot2/static/x86_64-win64/quickjs.o from the
# sha256-pinned mormot2static release; LIBQUICKJSSTATIC is auto-defined by
# the pinned mormot.defines.inc on FPC win64.
#
# NO fixture files are read from the repository: the harness GENERATES the
# reference package and every hostile fixture from in-source byte constants
# into a temp folder AND an in-memory ZIP, so a CRLF checkout can never
# change the module bytes it hashes.
#
# NO conditional SKIP: the harness is fully headless, so every failure
# gates (exit 1).
#
# Writes: build/cap9b1/quickjspackage-windows-x86_64.json (PASS|FAIL),
#         build/cap9b1/quickjs-package-corpus.txt (the digest source) + log.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap9b1 | Out-Null
$work = (Resolve-Path build/cap9b1).Path
$json = Join-Path $work 'quickjspackage-windows-x86_64.json'
$corpus = Join-Path $work 'quickjs-package-corpus.txt'
$log = Join-Path $work 'quickjspackage-win.log'
# every output deleted up front: an aborted run must never leave a previous
# run's evidence lying where the emitter or an upload could mistake it
Remove-Item -Force -ErrorAction SilentlyContinue $json, $corpus, $log

foreach ($pre in 'test/cap9b1/quickjspackage.pas',
                 'src/script/pweb.script.package.pas',
                 'src/script/pweb.script.quickjs.pas',
                 'src/assets/pweb.assets.folder.pas',
                 'src/assets/pweb.assets.zip.pas',
                 'deps/mormot2/static/x86_64-win64/quickjs.o',
                 'tools/patch-cap3u.ps1') {
    if (-not (Test-Path $pre)) {
        throw "missing precondition: $pre"
    }
}

# the canonical marker, from the one source
$passConst = @(Select-String -Path test/cap9b1/quickjspackage.pas `
    -Pattern "^  MARKER_PASS = '([^']+)';$" -CaseSensitive)
if ($passConst.Count -ne 1) {
    throw "expected one MARKER_PASS constant in quickjspackage.pas, found $($passConst.Count)"
}
$passMarker = $passConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-9B1] canonical pass marker: $passMarker"

# --- build quickjspackage.exe INSIDE the CAP-3U window ----------------------
New-Item -ItemType Directory -Force build/cap9b1/qp-fpc, build/cap9b1/qp-bin | Out-Null
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-9B1 CAP-3U re-apply failed' }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
        -FUbuild/cap9b1/qp-fpc -FEbuild/cap9b1/qp-bin `
        -Fusrc/script -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
        -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa `
        -Fudeps/mormot2/src/script `
        -Fldeps/mormot2/static/x86_64-win64 `
        test/cap9b1/quickjspackage.pas
    if ($LASTEXITCODE -ne 0) { throw 'quickjspackage.pas compile FAILED' }
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-9B1 CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-9B1 restore' }

$exe = (Resolve-Path build/cap9b1/qp-bin/quickjspackage.exe).Path

# --- run it, from an unrelated CWD (output resolves from the exe) ------------
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Set-Content -Path $log -Value $out
Write-Host $out

if (-not (Test-Path $corpus)) {
    throw "CAP-9B1: the quickjs-package-corpus digest source was not written -- see $log"
}
# -cmatch, not -match: the marker was extracted -CaseSensitive, so it must
# be tested case-sensitively too - otherwise a marker differing only in case
# would satisfy the Windows gate while the bash sibling's grep -qF refused it
if (-not ($out -cmatch [regex]::Escape($passMarker))) {
    throw "CAP-9B1 quickjspackage FAILED (exit $code) -- see $log"
}
if ($code -ne 0) {
    throw "the PASS marker was printed but the harness exited $code"
}
if (-not (Test-Path $json)) {
    throw 'PASS marker printed but no quickjspackage JSON was written'
}

Write-Host '[CAP-9B1] quickjspackage verdict: PASS'
