# CAP-9C1: the deterministic QuickJS production package and its trusted
# release loader, on Windows x64.
#
# Order matters and is the point:
#
#   1. build the PRIVATE packager (tools/quickjs/pwebqjspack.pas);
#   2. run it TWICE, into two separate staging directories, from the
#      trusted build-time plugin list. Both outputs must be byte-identical
#      - plugins.zip, the generated native registry AND LICENSE.quickjs -
#      which is C2/C4/C30's determinism leg on the REAL corpus rather than
#      on a fixture;
#   3. compile the C1-C30 harness WITH the generated registry include
#      (-Fibuild/quickjs-release), so "the generated registry compiles on
#      every target" is proven by the gate itself rather than asserted;
#   4. stage plugins.zip beside the harness executable, so the production
#      executable-relative location rule is exercised for real;
#   5. run the matrix from an unrelated working directory.
#
# The harness drives the real mORMot SOA bridge, so - exactly like the
# CAP-9A/B1/B2 harnesses - it compiles INSIDE the CAP-3U window
# (patch-cap3u.ps1 apply -> compile -> restore + verify pristine). The
# packager does not: it builds no SOA interface.
#
# QuickJS statics: deps/mormot2/static/x86_64-win64/quickjs.o from the
# sha256-pinned mormot2static release; LIBQUICKJSSTATIC is auto-defined by
# the pinned mormot.defines.inc on FPC win64.
#
# NO fixture files are read from the repository beyond the SHIPPED plugin
# corpus under examples/07-quickjs (pinned to LF in .gitattributes): every
# hostile fixture is generated in process from byte constants.
#
# NO conditional SKIP: the harness is fully headless, so every failure
# gates (exit 1).
#
# Writes: build/cap9c1/quickjsrelease-windows-x86_64.json (PASS|FAIL),
#         build/cap9c1/quickjs-release-corpus.txt (the digest source),
#         build/quickjs-release/ (the reusable release payload) + logs.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap9c1 | Out-Null
$work = (Resolve-Path build/cap9c1).Path
$json = Join-Path $work 'quickjsrelease-windows-x86_64.json'
$corpus = Join-Path $work 'quickjs-release-corpus.txt'
$log = Join-Path $work 'quickjsrelease-win.log'
$packlog = Join-Path $work 'pwebqjspack-win.log'
# every output deleted up front: an aborted run must never leave a
# previous run's evidence where the emitter or an upload could find it
Remove-Item -Force -ErrorAction SilentlyContinue $json, $corpus, $log, $packlog

foreach ($pre in 'test/cap9c1/quickjsrelease.pas',
                 'tools/quickjs/pwebqjspack.pas',
                 'examples/07-quickjs/plugins.trusted',
                 'src/script/pweb.script.release.pas',
                 'src/script/pweb.script.startup.pas',
                 'src/script/pweb.script.plugin.pas',
                 'src/script/pweb.script.package.pas',
                 'src/script/pweb.script.quickjs.pas',
                 'deps/mormot2/res/static/libquickjs/quickjs.h',
                 'deps/mormot2/static/x86_64-win64/quickjs.o',
                 'mormot.lock',
                 'tools/patch-cap3u.ps1') {
    if (-not (Test-Path $pre)) {
        throw "missing precondition: $pre"
    }
}

# the canonical marker, from the one source
$passConst = @(Select-String -Path test/cap9c1/quickjsrelease.pas `
    -Pattern "^  MARKER_PASS = '([^']+)';$" -CaseSensitive)
if ($passConst.Count -ne 1) {
    throw "expected one MARKER_PASS constant in quickjsrelease.pas, found $($passConst.Count)"
}
$passMarker = $passConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-9C1] canonical pass marker: $passMarker"

$mormotUnits = @(
    '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
    '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net', '-Fudeps/mormot2/src/db',
    '-Fudeps/mormot2/src/orm', '-Fudeps/mormot2/src/rest', '-Fudeps/mormot2/src/soa',
    '-Fudeps/mormot2/src/script'
)
$pwebUnits = @('-Fusrc/script', '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/assets')

# --- 0. STRUCTURAL browser invisibility -------------------------------------
# The C22 rows prove dynamically that no pweb://app request reaches the
# plugin bytes. This proves it STRUCTURALLY, which is the half a runtime
# probe can never cover: no platform resource handler, no WebView unit and
# no release host may so much as NAME the release package units or the
# archive. If one ever does, a future host could hand the package store to
# a scheme handler and every dynamic probe would still pass.
$forbidden = @('pweb\.script\.release', 'pweb\.script\.startup', 'plugins\.zip')
$browserSurface = @()
foreach ($root in 'src/platform', 'src/webview', 'examples/08-release') {
    if (Test-Path $root) {
        $browserSurface += Get-ChildItem $root -Recurse -File `
            -Include '*.pas', '*.pp', '*.inc', '*.mm', '*.h'
    }
}
if ($browserSurface.Count -eq 0) {
    throw 'CAP-9C1: the browser-surface sweep matched no files -- it would pass vacuously'
}
$leaks = @()
foreach ($file in $browserSurface) {
    foreach ($rx in $forbidden) {
        $hits = @(Select-String -Path $file.FullName -Pattern $rx)
        foreach ($h in $hits) {
            $leaks += "$($file.FullName):$($h.LineNumber): $($h.Line.Trim())"
        }
    }
}
if ($leaks) {
    $leaks | ForEach-Object { Write-Host $_ }
    throw 'CAP-9C1: the plugin package is named on the browser-facing surface'
}
Write-Host "[CAP-9C1] structural browser invisibility: $($browserSurface.Count) platform/webview/release-host files, zero references to the plugin package"

# --- 1. build the private packager (no CAP-3U window needed) ----------------
New-Item -ItemType Directory -Force build/cap9c1/pack-fpc, build/cap9c1/pack-bin | Out-Null
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
    -FUbuild/cap9c1/pack-fpc -FEbuild/cap9c1/pack-bin `
    @pwebUnits @mormotUnits `
    -Fldeps/mormot2/static/x86_64-win64 `
    tools/quickjs/pwebqjspack.pas
if ($LASTEXITCODE -ne 0) { throw 'pwebqjspack.pas compile FAILED' }
$packer = (Resolve-Path build/cap9c1/pack-bin/pwebqjspack.exe).Path

# --- 2. stage the release payload TWICE and require byte equality ----------
$stage1 = Join-Path $repoRoot 'build\quickjs-release'
$stage2 = Join-Path $repoRoot 'build\quickjs-release-verify'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage1, $stage2
foreach ($stage in @($stage1, $stage2)) {
    & $packer examples/07-quickjs/plugins.trusted $stage 2>&1 |
        Tee-Object -FilePath $packlog -Append
    if ($LASTEXITCODE -ne 0) { throw "pwebqjspack FAILED for $stage" }
}
foreach ($artifact in 'plugins.zip', 'pweb.quickjs.registry.inc', 'LICENSE.quickjs') {
    $a = Get-FileHash -Algorithm SHA256 (Join-Path $stage1 $artifact)
    $b = Get-FileHash -Algorithm SHA256 (Join-Path $stage2 $artifact)
    if ($a.Hash -ne $b.Hash) {
        throw "CAP-9C1: $artifact is NOT deterministic ($($a.Hash) vs $($b.Hash))"
    }
    Write-Host "[CAP-9C1] deterministic $artifact sha256=$($a.Hash.ToLower())"
}
# the second staging directory has done its job; the first IS the payload
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage2
foreach ($required in 'plugins.zip', 'pweb.quickjs.registry.inc',
                      'LICENSE.quickjs', 'package-inventory.txt',
                      'package-build-info.txt') {
    if (-not (Test-Path (Join-Path $stage1 $required))) {
        throw "CAP-9C1: the release staging is missing $required"
    }
}

# --- 3. compile the harness INSIDE the CAP-3U window ------------------------
# -Fibuild/quickjs-release is how the GENERATED registry gets compiled into
# the executable: that compile is itself an acceptance criterion.
New-Item -ItemType Directory -Force build/cap9c1/rel-fpc, build/cap9c1/rel-bin | Out-Null
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-9C1 CAP-3U re-apply failed' }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
        -FUbuild/cap9c1/rel-fpc -FEbuild/cap9c1/rel-bin `
        @pwebUnits -Fibuild/quickjs-release @mormotUnits `
        -Fldeps/mormot2/static/x86_64-win64 `
        test/cap9c1/quickjsrelease.pas
    if ($LASTEXITCODE -ne 0) { throw 'quickjsrelease.pas compile FAILED' }
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-9C1 CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-9C1 restore' }

$exe = (Resolve-Path build/cap9c1/rel-bin/quickjsrelease.exe).Path

# --- 4. the production location rule: the archive sits beside the exe ------
Copy-Item -Force (Join-Path $stage1 'plugins.zip') `
    (Join-Path (Split-Path -Parent $exe) 'plugins.zip')

# --- 5. run it, from an unrelated CWD (nothing may resolve relative to it) --
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $out = & $exe 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
Set-Content -Path $log -Value $out
Write-Host $out

if (-not (Test-Path $corpus)) {
    throw "CAP-9C1: the quickjs-release-corpus digest source was not written -- see $log"
}
# -cmatch, not -match: the marker was extracted -CaseSensitive, so it must
# be tested case-sensitively too - otherwise a marker differing only in
# case would satisfy the Windows gate while the bash sibling's grep -qF
# refused it
if (-not ($out -cmatch [regex]::Escape($passMarker))) {
    throw "CAP-9C1 quickjsrelease FAILED (exit $code) -- see $log"
}
if ($code -ne 0) {
    throw "the PASS marker was printed but the harness exited $code"
}
if (-not (Test-Path $json)) {
    throw 'PASS marker printed but no quickjsrelease JSON was written'
}

Write-Host '[CAP-9C1] quickjsrelease verdict: PASS'
