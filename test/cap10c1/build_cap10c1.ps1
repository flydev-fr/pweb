# CAP-10C1 (Windows): complete the SDK root, and build the private pipeline
# driver and its suite.
#
# THE SDK ROOT IS COMPLETED, NOT REPLACED. There is ONE staged SDK in this
# repository - build/cap10b1/sdk, built by test/cap10b1/build_cap10b1.ps1
# where the CLI's trust anchor is generated - and this script ADDS to it the
# three things CAP-10B1 recorded as a known limitation:
#
#   bin/pwebbundle.exe                        the frozen CAP-6 bundler
#   share/pweb/deps/mormot2/src               mORMot, from the INSTALLATION
#   share/pweb/deps/mormot2/static/<target>   its statics
#   share/pweb/lib/<os>-<arch>/webview.dll    the platform artifact
#
# Nothing enumerates that root - every reader in the tree names an exact
# path - so completing it in place leaves CAP-10A, CAP-10B1, CAP-10B2 and
# CAP-10C0 exactly as they were.
#
# WHY THE STAGED mORMot IS CAP-3U-PATCHED. tools/patch-cap3u.ps1 needs MSVC's
# ml64 and a mORMot GIT CHECKOUT and it edits that checkout in place. A
# pipeline that ran it would mutate its own framework's working tree on every
# build. So the patch is applied ONCE here, the patched source is copied into
# the SDK root, and the checkout is restored - which is what a shipped SDK
# has to do anyway, and which leaves the build path with no patch window at
# all. The staged copy is then ASSERTED to differ from the pristine pinned
# source and to carry x64callmethod.obj: a silently unpatched mORMot would
# produce a binary that compiles and misbehaves.
#
# ONLY WHAT A PROJECT COMPILES AGAINST IS STAGED - the eight unit directories
# named by pweb.cli.native's PWEB_MORMOT_UNIT_DIRS plus the include root's own
# files, never the whole checkout. An installation ships what a project
# compiles against, and a staging rule that copies whatever happens to be
# there is a staging rule that will one day ship somebody's test.
#
# Also produces, under build/cap10c1/:
#   iso/   isolation compiles (no binary kept) - the LAYERING proof
#   bin/   pwebpipe.exe   the private lifecycle driver
#          c1tests.exe    the CAP-10C1 suite
#
# Usage: pwsh test/cap10c1/build_cap10c1.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$bundler = Join-Path $repoRoot 'build/cap10b1/bin/pwebbundle.exe'
$webviewDll = Join-Path $repoRoot 'build/webview-dist/webview.dll'
foreach ($pre in (Join-Path $sdk 'bin/pweb.exe'),
                 (Join-Path $sdk 'share/pweb/src/webview/pweb.webview.host.pas'),
                 $bundler, $webviewDll,
                 (Join-Path $repoRoot 'deps/mormot2/src/core/mormot.core.base.pas')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run test/cap10b1/build_cap10b1.ps1 " +
            'and the webview build first')
    }
}

# the SELECTED target, not the default one. A Windows FPC installation
# routinely carries both compilers and the default is whichever the installer
# wrote last; every Windows compile in this repository names -Px86_64 -Twin64
# explicitly, so what has to be true is that the SELECTION resolves.
$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10C1 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
$target = 'windows-x86_64'
$fpcTarget = 'x86_64-win64'
Write-Host "[CAP-10C1] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

# --- 1. the frozen bundler, beside the CLI ---------------------------------
Copy-Item -Force -LiteralPath $bundler -Destination (Join-Path $sdk 'bin')

# --- 2. mORMot, patched, into the SDK root ---------------------------------
$mormotOut = Join-Path $sdk 'share/pweb/deps/mormot2'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $mormotOut
New-Item -ItemType Directory -Force (Join-Path $mormotOut 'src') | Out-Null

$unitDirs = @('core', 'lib', 'crypt', 'net', 'db', 'orm', 'rest', 'soa')
$pristine = Get-FileHash -Algorithm SHA256 `
    -LiteralPath (Join-Path $repoRoot 'deps/mormot2/src/core/mormot.core.interfaces.pas')
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-3U apply FAILED' }
    foreach ($d in $unitDirs) {
        Copy-Item -Recurse -Force `
            -LiteralPath (Join-Path $repoRoot "deps/mormot2/src/$d") `
            -Destination (Join-Path $mormotOut 'src')
    }
    # the include root's OWN files: mormot.defines.inc, mormot.uses.inc, the
    # commit stamps and the Windows manifest resources. -Fi names this
    # directory and a missing .inc is a compile failure three stages later
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deps/mormot2/src') -File |
        Copy-Item -Destination (Join-Path $mormotOut 'src') -Force
    $stagedIntf = Join-Path $mormotOut 'src/core/mormot.core.interfaces.pas'
    $stagedHash = Get-FileHash -Algorithm SHA256 -LiteralPath $stagedIntf
    if ($stagedHash.Hash -eq $pristine.Hash) {
        throw ('the staged mORMot is NOT CAP-3U patched: ' +
            'mormot.core.interfaces.pas is byte-identical to the pristine source')
    }
    if (-not (Test-Path -LiteralPath (Join-Path $mormotOut 'src/core/x64callmethod.obj'))) {
        throw 'the staged mORMot carries no x64callmethod.obj'
    }
    Write-Host '[CAP-10C1] staged mORMot is CAP-3U patched (source differs, obj present)'
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after the restore' }

New-Item -ItemType Directory -Force (Join-Path $mormotOut 'static') | Out-Null
# MEASURED, not guessed: two of the objects a Win64 build links are reached
# from inside mORMot's own sources by a RELATIVE path -
# `{$L ..\..\static\delphi\sha512-x64sse4.obj}` and crc32c64.obj - which
# resolves against the unit's directory and therefore against the STAGED
# tree. Staging only static/<fpc-target> produced
# `Error: Can't open object file: ..\..\static\delphi\sha512-x64sse4.obj`.
# static/delphi holds COFF objects and is staged on Windows ONLY; a POSIX
# installation has no use for it and must not carry it.
foreach ($staticDir in $fpcTarget, 'delphi') {
    Copy-Item -Recurse -Force `
        -LiteralPath (Join-Path $repoRoot "deps/mormot2/static/$staticDir") `
        -Destination (Join-Path $mormotOut 'static')
}

# --- 3. the platform artifacts ---------------------------------------------
$libDir = Join-Path $sdk "share/pweb/lib/$target"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $libDir
New-Item -ItemType Directory -Force $libDir | Out-Null
Copy-Item -Force -LiteralPath $webviewDll -Destination $libDir

foreach ($artifact in (Join-Path $sdk 'bin/pwebbundle.exe'),
                      (Join-Path $mormotOut 'src/core/mormot.core.base.pas'),
                      (Join-Path $mormotOut 'src/mormot.defines.inc'),
                      (Join-Path $mormotOut "static/$fpcTarget"),
                      (Join-Path $libDir 'webview.dll')) {
    if (-not (Test-Path -LiteralPath $artifact)) { throw "expected $artifact" }
}
Write-Host "[CAP-10C1] SDK root completed at build/cap10b1/sdk for $target"

# --- 4. layering: no pipeline unit may reach a webview unit ----------------
# The pipeline BUILDS a window-owning application; it can never BE one,
# because the units that could are not on its path. Proven by the compiler,
# exactly as CAP-10C0 proves it for the engine and the run command.
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10c1/iso, build/cap10c1/test-units, build/cap10c1/bin
New-Item -ItemType Directory -Force build/cap10c1/iso,
    build/cap10c1/test-units, build/cap10c1/bin | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$mormotTest = $mormotCore + @('-Fudeps/mormot2/src/net')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

foreach ($unit in 'sdkroot', 'stage', 'toolset', 'frontend', 'pack',
                  'native', 'layout', 'pipeline') {
    fpc -MObjFPC -Sh -B -FUbuild/cap10c1/iso `
        -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
        -Fusrc/platform/windows @mormotCore `
        "tools/pweb/pweb.cli.$unit.pas"
    if ($LASTEXITCODE -ne 0) {
        throw "pweb.cli.$unit.pas failed its isolation compile"
    }
}

# --- 5. the driver and the suite -------------------------------------------
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10c1/test-units -FEbuild/cap10c1/bin `
    -Futools/pweb -Futest/cap10c1 -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotTest $statics `
    test/cap10c1/pwebpipe.pas
if ($LASTEXITCODE -ne 0) { throw 'pwebpipe.pas compile FAILED' }

fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10c1/test-units -FEbuild/cap10c1/bin `
    -Futools/pweb -Futest/cap10c1 -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows @mormotTest $statics `
    test/cap10c1/c1tests.pas
if ($LASTEXITCODE -ne 0) { throw 'c1tests.pas compile FAILED' }

# the deliberately wrong compiler the TC2/TC3 refusals are measured with,
# named `fpc` because that is what PATH resolution has to find
fpc -Px86_64 -Twin64 -Sh -B `
    -FUbuild/cap10c1/test-units -FEbuild/cap10c1/bin `
    test/cap10c1/fakefpc.pas
if ($LASTEXITCODE -ne 0) { throw 'fakefpc.pas compile FAILED' }
New-Item -ItemType Directory -Force build/cap10c1/fake | Out-Null
Copy-Item -Force -LiteralPath 'build/cap10c1/bin/fakefpc.exe' `
    -Destination 'build/cap10c1/fake/fpc.exe'

foreach ($exe in 'pwebpipe.exe', 'c1tests.exe', 'fakefpc.exe') {
    if (-not (Test-Path "build/cap10c1/bin/$exe")) {
        throw "expected build/cap10c1/bin/$exe"
    }
}

# THE DRIVER LIVES IN THE SDK's OWN bin/, and that is the point: it resolves
# the SDK root from the RUNNING IMAGE by the CAP-10B0 anchor rule, with no
# parameter and no environment variable, exactly as the shipped `pweb` does.
# A driver that took the root as a flag would be proving a different claim.
Copy-Item -Force -LiteralPath 'build/cap10c1/bin/pwebpipe.exe' `
    -Destination (Join-Path $sdk 'bin')
Write-Host '[CAP-10C1] pwebpipe + c1tests built; layering compiles clean'
