# CAP-9A: the QuickJS invocation-foundation harness on Windows x64.
#
# Builds test/cap9a/quickjsfoundation.pas (the UNCHANGED production
# scheduler + CAP-8A policy + the real mORMot SOA bridge behind a counting
# decorator, with two concurrent QuickJS plugin threads as invocation
# sources) and runs the headless Q1-Q30 matrix, which writes the canonical
# build/cap9a/quickjs-corpus.txt digest source.
#
# The real mORMot SOA bridge means this host, exactly like the CAP-6
# release host and the CAP-8C harness, compiles INSIDE the CAP-3U window
# (patch-cap3u.ps1 apply -> compile -> restore + verify pristine).
#
# QuickJS statics: deps/mormot2/static/x86_64-win64/quickjs.o from the
# sha256-pinned mormot2static release; LIBQUICKJSSTATIC is auto-defined by
# the pinned mormot.defines.inc on FPC win64.
#
# ABI pairing: the harness writes build/cap9a/abi-pascal.txt; where a gcc
# is on PATH (the hosted windows runner ships mingw gcc) this runner also
# compiles test/cap9a/abiprobe.c against the PINNED headers with the exact
# static-build defines and compares the two line sets exactly. Without a C
# toolchain the comparison is recorded as skipped on stdout - the POSIX
# targets always run it, and the Pascal line set still feeds the corpus.
#
# NO conditional SKIP for the harness itself: it is fully headless, so
# every failure gates (exit 1).
#
# Writes: build/cap9a/quickjsfoundation-windows-x86_64.json (PASS|FAIL),
#         build/cap9a/quickjs-corpus.txt (the digest source),
#         build/cap9a/abi-pascal.txt (+ abi-c.txt when gcc exists) + log.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap9a | Out-Null
$work = (Resolve-Path build/cap9a).Path
$json = Join-Path $work 'quickjsfoundation-windows-x86_64.json'
$corpus = Join-Path $work 'quickjs-corpus.txt'
$abiPas = Join-Path $work 'abi-pascal.txt'
$abiC = Join-Path $work 'abi-c.txt'
$log = Join-Path $work 'quickjsfoundation-win.log'
# every output deleted up front: an aborted run must never leave a previous
# run's evidence lying where the emitter or an upload could mistake it
Remove-Item -Force -ErrorAction SilentlyContinue $json, $corpus, $abiPas, $abiC, $log

foreach ($pre in 'test/cap9a/quickjsfoundation.pas',
                 'test/cap9a/abiprobe.c',
                 'src/script/pweb.script.quickjs.pas',
                 'deps/mormot2/static/x86_64-win64/quickjs.o',
                 'deps/mormot2/res/static/libquickjs/quickjs.h',
                 'tools/patch-cap3u.ps1') {
    if (-not (Test-Path $pre)) {
        throw "missing precondition: $pre"
    }
}

# the canonical marker, from the one source
$passConst = @(Select-String -Path test/cap9a/quickjsfoundation.pas `
    -Pattern "^  MARKER_PASS = '([^']+)';$" -CaseSensitive)
if ($passConst.Count -ne 1) {
    throw "expected one MARKER_PASS constant in quickjsfoundation.pas, found $($passConst.Count)"
}
$passMarker = $passConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-9A] canonical pass marker: $passMarker"

# --- build quickjsfoundation.exe INSIDE the CAP-3U window (this harness
# drives the real mORMot SOA bridge) -----------------------------------------
New-Item -ItemType Directory -Force build/cap9a/qf-fpc, build/cap9a/qf-bin | Out-Null
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-9A CAP-3U re-apply failed' }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
        -FUbuild/cap9a/qf-fpc -FEbuild/cap9a/qf-bin `
        -Fusrc/script -Fusrc/rpc -Fusrc/security `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
        -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa `
        -Fudeps/mormot2/src/script `
        -Fldeps/mormot2/static/x86_64-win64 `
        test/cap9a/quickjsfoundation.pas
    if ($LASTEXITCODE -ne 0) { throw 'quickjsfoundation.pas compile FAILED' }
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-9A CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-9A restore' }

$exe = (Resolve-Path build/cap9a/qf-bin/quickjsfoundation.exe).Path

# --- run it, from an unrelated CWD (output resolves from the exe) ------------
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Set-Content -Path $log -Value $out
Write-Host $out

if (-not (Test-Path $corpus)) {
    throw "CAP-9A: the quickjs-corpus digest source was not written -- see $log"
}
if (-not (Test-Path $abiPas)) {
    throw "CAP-9A: the Pascal ABI line set was not written -- see $log"
}
if (-not ($out -match [regex]::Escape($passMarker))) {
    throw "CAP-9A quickjsfoundation FAILED (exit $code) -- see $log"
}
if ($code -ne 0) {
    throw "the PASS marker was printed but the harness exited $code"
}
if (-not (Test-Path $json)) {
    throw 'PASS marker printed but no quickjsfoundation JSON was written'
}

# --- paired C/Pascal ABI diff where a C toolchain exists ---------------------
$abiSkipNoted = $false
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if ($gcc) {
    # sanity-probe the toolchain first: a gcc without its own libc headers
    # (some FPC-adjacent installs) must record an honest skip, not
    # masquerade as an ABI failure
    $sanitySrc = Join-Path $work 'abisanity.c'
    Set-Content -Path $sanitySrc -Value "#include <stdio.h>`nint main(void){return 0;}"
    & $gcc.Source -o (Join-Path $work 'abisanity.exe') $sanitySrc 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[CAP-9A] gcc on PATH cannot compile against its own libc headers - paired C ABI diff skipped on this host (POSIX targets always run it)'
        $gcc = $null
        $abiSkipNoted = $true
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $sanitySrc, (Join-Path $work 'abisanity.exe')
}
if ($gcc) {
    $qjsSrc = (Resolve-Path deps/mormot2/res/static/libquickjs).Path
    & $gcc.Source -o build/cap9a/qf-bin/abiprobe.exe "-I$qjsSrc" `
        -DCONFIG_BIGNUM -DJS_STRICT_NAN_BOXING -DCONFIG_JSX -DCONFIG_DEBUGGER `
        test/cap9a/abiprobe.c
    if ($LASTEXITCODE -ne 0) {
        throw 'abiprobe.c compile FAILED against the pinned headers'
    }
    # line-based capture sidesteps CRLF-vs-LF differences between the C
    # runtime's text mode and the Pascal writer
    $cLines = @(& build/cap9a/qf-bin/abiprobe.exe) | ForEach-Object { $_.TrimEnd() }
    if ($LASTEXITCODE -ne 0) { throw 'abiprobe execution FAILED' }
    [System.IO.File]::WriteAllText($abiC,
        (($cLines -join "`n") + "`n"),
        [System.Text.UTF8Encoding]::new($false))
    $pasLines = @(Get-Content $abiPas) | ForEach-Object { $_.TrimEnd() }
    $diff = Compare-Object -ReferenceObject $pasLines -DifferenceObject $cLines -SyncWindow 0
    if ($diff) {
        $diff | Format-Table | Out-String | Write-Host
        throw 'JSValue ABI mismatch between the Pascal binding and the pinned C headers -- STOP'
    }
    Write-Host '[CAP-9A] ABI line sets identical (C vs Pascal)'
} elseif (-not $abiSkipNoted) {
    Write-Host '[CAP-9A] no gcc on PATH - paired C ABI diff skipped on this host (POSIX targets always run it)'
}

Write-Host '[CAP-9A] quickjsfoundation verdict: PASS'
