# CAP-3U Currency return matrix on Windows x64.
#
# Builds test/cap3u/cap3u_currency.pas against the PRISTINE pinned mORMot and
# runs it. The program itself decides what gates: it reads
# test/cap3u/currency-expectations.tsv and fails only on a case the table
# declares `must_pass` for THIS target - which on windows-x86_64 is all five,
# because all five were measured passing on FPC 3.2.2 x86_64-win64, the exact
# toolchain fpc.lock pins for this leg.
#
# WHY IT RUNS AT ALL. The 2026-09-08 pin move took upstream 790154af, which
# changed how mORMot's SHARED x64 CallMethod reads a Currency result. Win64
# went from 0/5 unpatched at the previous pin to 5/5 at this one, and that is
# half of why the CAP-3U patch could be removed; this gate is what keeps it
# true.
#
# Writes: build/cap3u/currency-corpus.txt (written by the program) and a log.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

foreach ($pre in 'test/cap3u/cap3u_currency.pas',
                 'test/cap3u/currency-expectations.tsv',
                 'test/security/pweb.test.reporoot.pas',
                 'deps/mormot2/src/core/mormot.core.interfaces.pas') {
    if (-not (Test-Path $pre)) { throw "missing precondition: $pre" }
}

$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-3U expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}

New-Item -ItemType Directory -Force build/cap3u | Out-Null
$work = (Resolve-Path build/cap3u).Path
$corpus = Join-Path $work 'currency-corpus.txt'
$log = Join-Path $work 'currency-win.log'
Remove-Item -Force -ErrorAction SilentlyContinue $corpus, $log
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    (Join-Path $work 'cur-fpc'), (Join-Path $work 'cur-bin')
New-Item -ItemType Directory -Force build/cap3u/cur-fpc, build/cap3u/cur-bin |
    Out-Null

fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap3u/cur-fpc -FEbuild/cap3u/cur-bin `
    -Futest/security `
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa `
    -Fldeps/mormot2/static/x86_64-win64 `
    test/cap3u/cap3u_currency.pas
if ($LASTEXITCODE -ne 0) { throw 'cap3u_currency.pas compile FAILED' }

$exe = (Resolve-Path build/cap3u/cur-bin/cap3u_currency.exe).Path

# run from an unrelated working directory: the program resolves the
# expectation table and the corpus from its own image, never from the CWD
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}
[System.IO.File]::WriteAllText($log, $out)
Write-Host $out

if (-not (Test-Path -LiteralPath $corpus)) {
    throw "the currency corpus was not written -- see $log"
}
if ((Get-Content -LiteralPath $corpus) -notcontains 'target=windows-x86_64') {
    throw "the corpus does not name windows-x86_64 -- see $corpus"
}
if ($code -ne 0) {
    throw "CAP-3U Currency matrix FAILED on windows-x86_64 (exit $code) -- see $log"
}
Write-Host '[CAP-3U] Currency matrix verdict on windows-x86_64: PASS'
