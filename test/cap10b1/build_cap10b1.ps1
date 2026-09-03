# CAP-10B1: build the PUBLIC template pack, the CLI that carries it, and the
# SDK root the generated project will be built against.
#
# Produces, all under build/cap10b1/:
#   gen/pweb.templates.registry.inc  the PUBLIC trust anchor
#   cli-units/                       the CLI's compiled unit set - the
#                                    LINKAGE evidence the contract check
#                                    reads, now inverted from CAP-10B0's
#   bin/pwebbundle.exe               the frozen CAP-6 bundler
#   sdk/bin/pweb.exe                 the public CLI
#   sdk/share/pweb/pweb-templates.zip     the public pack
#   sdk/share/pweb/sdk/typescript/        the pinned TypeScript SDK
#   sdk/share/pweb/sdk/pas2js/            the PWeb Pas2JS SDK
#   sdk/share/pweb/src/                   the PWeb Pascal source root
#
# TWO PACKS, FROM ONE TRUSTED SOURCE, AND THE DIFFERENCE IS THE POINT.
# test/cap10b0 builds `--include all`, which carries the private neutral
# fixture the engine suite needs. This script builds `--include public`,
# which carries the two PUBLIC templates - react and, since CAP-10B2,
# pas2js - and nothing else, so the registry compiled into the SHIPPED
# executable does not describe the fixture at all and no public command can
# reach it even by exact name. The RequirePublic refusal is the second lock;
# this is the first.
#
# WHY THE SDK ROOT IS STAGED RATHER THAN POINTED AT THE CHECKOUT. The
# generated project must be provably buildable from an INSTALLATION, not
# from this repository. Staging bin/, share/pweb/ and the Pascal source root
# into one tree is what lets prove_cap10b1 compile the generated program
# with unit paths that name only the staged SDK - so "it compiles" cannot
# quietly mean "it compiles next to its own framework's git checkout".
#
# mORMot and the webview library are still resolved from deps/. Schema 1
# carries no dependency model and CAP-10D owns packaging them; recorded as a
# known limitation rather than papered over with a second staging rule.
#
# Usage: pwsh test/cap10b1/build_cap10b1.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

if (-not (Test-Path 'deps/mormot2/src/core/mormot.core.base.pas')) {
    throw 'deps/mormot2 missing -- run tools/get-mormot.ps1 first'
}
$builder = 'build/cap10b0/bin/pwebtemplates.exe'
if (-not (Test-Path $builder)) {
    throw ("$builder missing -- run test/cap10b0/build_cap10b0.ps1 first " +
        '(CAP-10B1 reuses the CAP-10B0 pack builder rather than shipping a second one)')
}
foreach ($f in 'sdk/typescript/dist/src/index.js',
                'sdk/typescript/dist/src/index.d.ts') {
    if (-not (Test-Path $f)) {
        throw ("$f missing -- build the TypeScript SDK first " +
            '(npm ci && npm run build in sdk/typescript)')
    }
}

# CAP-10C2: the SELECTED target, not the compiler's default. One Windows FPC
# installation routinely carries both the i386 and the x86_64 compiler and the
# default is whichever the installer wrote last, which on a dev host is
# regularly win32/i386 - so this script refused to run there while every
# compile it performs names its target explicitly. That is the rule CAP-10C1
# ratified (`build_cap10c1.ps1` checks the selected target for the same
# reason); the bundler compile below was the one that did not name it, and
# now does. On the CI runner the default IS win64, so nothing this script
# produces there changes.
$targetOs = (fpc -Px86_64 -Twin64 -iTO).Trim().ToLowerInvariant()
$targetCpu = (fpc -Px86_64 -Twin64 -iTP).Trim().ToLowerInvariant()
if (($targetOs -cne 'win64') -or ($targetCpu -cne 'x86_64')) {
    throw "CAP-10B1 expects FPC target Win64/x86_64, got $targetOs/$targetCpu"
}
Write-Host "[CAP-10B1] fpc $((fpc -iV).Trim()) targeting $targetOs/$targetCpu"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    build/cap10b1/gen, build/cap10b1/cli-units, build/cap10b1/bundler-units, `
    build/cap10b1/bin, build/cap10b1/sdk
New-Item -ItemType Directory -Force build/cap10b1/gen,
    build/cap10b1/cli-units, build/cap10b1/bundler-units, build/cap10b1/bin,
    build/cap10b1/sdk/bin, build/cap10b1/sdk/share/pweb | Out-Null

$mormotCore = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt')
$statics = '-Fldeps/mormot2/static/x86_64-win64'

# --- 1. the PUBLIC pack and its generated registry -------------------------
& $builder --source tools/templates `
    --pack build/cap10b1/sdk/share/pweb/pweb-templates.zip `
    --registry build/cap10b1/gen/pweb.templates.registry.inc `
    --include public
if ($LASTEXITCODE -ne 0) { throw 'the public template pack build FAILED' }

# --- 2. the CLI, compiled WITH that registry -------------------------------
# -Fibuild/cap10b1/gen is how the trust anchor gets compiled in, and
# -FUbuild/cap10b1/cli-units is what makes the LINKAGE measurable: the
# contract check reads that directory and now REQUIRES the scaffold engine
# to be there, which is the exact inversion of the CAP-10B0 rule.
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FUbuild/cap10b1/cli-units -FEbuild/cap10b1/sdk/bin `
    -Futools/pweb -Fusrc/rpc -Fusrc/security -Fusrc/assets `
    -Fusrc/platform/windows -Fibuild/cap10b1/gen @mormotCore $statics `
    tools/pweb/pweb.pas
if ($LASTEXITCODE -ne 0) { throw 'the CAP-10B1 CLI compile FAILED' }

# --- 3. the frozen bundler, unchanged ---------------------------------------
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B `
    -FUbuild/cap10b1/bundler-units -FEbuild/cap10b1/bin `
    -Fusrc/assets -Fusrc/rpc @mormotCore $statics `
    tools/bundler/pwebbundle.pas
if ($LASTEXITCODE -ne 0) { throw 'the CAP-6 bundler compile FAILED' }

# --- 4. the SDK root's data ------------------------------------------------
node tools/stage-ts-sdk.mjs sdk/typescript `
    build/cap10b1/sdk/share/pweb/sdk/typescript
if ($LASTEXITCODE -ne 0) { throw 'staging the TypeScript SDK FAILED' }

# the Pascal source root. A COPY, deliberately: prove_cap10b1 names only
# these paths when it compiles the generated program, so a unit that is
# missing from an installation fails here rather than in somebody's
# first project.
Copy-Item -Recurse -Force src `
    (Join-Path $repoRoot 'build/cap10b1/sdk/share/pweb/src')

# the PWeb Pas2JS SDK, staged for the same reason the TypeScript one is
# (CAP-10B2). A generated Pas2JS project names NO unit path for it: the
# -Fu that finds pweb.native is supplied at build time and points HERE, so
# "the frontend compiles" cannot quietly mean "it compiles beside its own
# framework's git checkout".
# The unit and its README, NAMED - not the directory, which also carries the
# SDK's own test program. An installation ships what a project compiles
# against, and a staging rule that copies whatever happens to be there is a
# staging rule that will one day ship a test.
New-Item -ItemType Directory -Force `
    build/cap10b1/sdk/share/pweb/sdk/pas2js | Out-Null
foreach ($f in 'pweb.native.pas', 'README.md') {
    Copy-Item -Force (Join-Path $repoRoot "sdk/pas2js/$f") `
        (Join-Path $repoRoot "build/cap10b1/sdk/share/pweb/sdk/pas2js/$f")
}

foreach ($artifact in 'build/cap10b1/gen/pweb.templates.registry.inc',
                      'build/cap10b1/sdk/bin/pweb.exe',
                      'build/cap10b1/bin/pwebbundle.exe',
                      'build/cap10b1/sdk/share/pweb/pweb-templates.zip',
                      'build/cap10b1/sdk/share/pweb/sdk/typescript/package.json',
                      'build/cap10b1/sdk/share/pweb/sdk/typescript/dist/src/index.js',
                      'build/cap10b1/sdk/share/pweb/sdk/pas2js/pweb.native.pas',
                      'build/cap10b1/sdk/share/pweb/src/webview/pweb.webview.host.pas') {
    if (-not (Test-Path $artifact)) { throw "expected $artifact" }
}
Write-Host '[CAP-10B1] public pack + CLI + bundler + staged SDK root built'
