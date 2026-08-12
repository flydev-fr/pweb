# CAP-6 headless gates - all deterministic, no WebView2/desktop session
# required (the refusal paths run and exit BEFORE webview creation):
#   1. real app.pwb built from the CAP-5 React dist
#   2. byte-identical rebuild from a SCRATCH COPY of the dist with
#      touched mtimes, >= 3 s of wall clock apart (SHA256 equality) +
#      stable atomic in-place rebuild (the shared dist is never mutated)
#   3. D3 exclusion policy over a real walk: secret refusal, sourcemap
#      skip-by-default and --include-sourcemaps opt-in PROVEN BY ENTRY
#      LIST (System.IO.Compression), not by size
#   4. CLI flags: --min-runtime stamps the served manifest bytes;
#      --max-asset-bytes refuses at a small ceiling, accepts at a larger
#   5. isolated release/ assembly: exe + app.pwb + dll ONLY
#   6. missing-bundle refusal, run from an unrelated CWD
#   7. tampered-bundle refusals (garbage bytes, truncated archive)
#   8. native compat refusals end-to-end: a crafted protocol-2 bundle
#      and a minRuntime-above-runtime bundle both refuse with their
#      typed markers before any WebView exists
#   9. observational ZIP load benchmark recorded to the step summary
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($pre in 'build/cap6/bin/pwebbundle.exe',
                 'build/cap6/bin/releaseapp.exe',
                 'build/webview-dist/webview.dll',
                 'examples/04-react/frontend/dist/index.html',
                 'examples/04-react/frontend/dist/assets/app.js') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- build the React frontend " +
            '(npm run build), webview.dll, and run test/cap6/build_cap6.ps1 first')
    }
}

function Get-ZipEntryNames([string]$Path) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path).Path)
    try { return @($zip.Entries | ForEach-Object FullName) }
    finally { $zip.Dispose() }
}

function Get-ZipEntryText([string]$Path, [string]$Entry) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path).Path)
    try {
        $e = $zip.GetEntry($Entry)
        if ($null -eq $e) { throw "entry $Entry missing in $Path" }
        $r = [System.IO.StreamReader]::new($e.Open())
        try { return $r.ReadToEnd() } finally { $r.Dispose() }
    }
    finally { $zip.Dispose() }
}

function Invoke-ReleaseApp([string]$Dir) {
    $exe = (Resolve-Path "$Dir/releaseapp.exe").Path
    Push-Location ([System.IO.Path]::GetTempPath())  # unrelated CWD
    try {
        $out = & $exe 2>&1 | Out-String
        return @{ Out = $out; Code = $LASTEXITCODE }
    } finally { Pop-Location }
}

function New-ReleaseDir([string]$Dir) {
    if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
    New-Item -ItemType Directory -Force $Dir | Out-Null
    Copy-Item build/cap6/bin/releaseapp.exe $Dir/
    Copy-Item build/webview-dist/webview.dll $Dir/
}

# --- 1) real bundle from the React CAP-5 dist ---
& build/cap6/bin/pwebbundle.exe examples/04-react/frontend/dist build/cap6/app.pwb
if ($LASTEXITCODE -ne 0) { throw 'CAP-6 bundle build failed' }
if (-not (Test-Path build/cap6/app.pwb)) { throw 'app.pwb missing after build' }

# --- 2) deterministic rebuild across time and mtime variance, from a
#        scratch copy so the shared dist is never mutated ---
$h1 = (Get-FileHash build/cap6/app.pwb -Algorithm SHA256).Hash
$mdir = 'build/cap6/dist-mtime'
if (Test-Path $mdir) { Remove-Item -Recurse -Force $mdir }
Copy-Item examples/04-react/frontend/dist $mdir -Recurse
Get-ChildItem $mdir -Recurse -File |
    ForEach-Object { $_.LastWriteTime = (Get-Date) }
Start-Sleep -Seconds 3
& build/cap6/bin/pwebbundle.exe $mdir build/cap6/app-rebuild.pwb
if ($LASTEXITCODE -ne 0) { throw 'CAP-6 rebuild failed' }
$h2 = (Get-FileHash build/cap6/app-rebuild.pwb -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw "CAP-6 determinism gate FAILED: $h1 vs $h2" }
Write-Host "CAP-6 deterministic rebuild PASS (SHA256 $h1)"
# the atomic in-place replace path must land on the same bytes
& build/cap6/bin/pwebbundle.exe examples/04-react/frontend/dist build/cap6/app.pwb
if ($LASTEXITCODE -ne 0) { throw 'CAP-6 in-place rebuild failed' }
if ((Get-FileHash build/cap6/app.pwb -Algorithm SHA256).Hash -ne $h1) {
    throw 'CAP-6 in-place atomic rebuild drifted'
}

# --- 3) D3 exclusion policy over a real walk ---
$xdir = 'build/cap6/dist-hostile'
if (Test-Path $xdir) { Remove-Item -Recurse -Force $xdir }
Copy-Item examples/04-react/frontend/dist $xdir -Recurse
Set-Content "$xdir/.env" 'SECRET=1'
& build/cap6/bin/pwebbundle.exe $xdir build/cap6/hostile.pwb 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'secret artifact (.env) was packaged' }
if (Test-Path build/cap6/hostile.pwb) {
    throw 'output produced despite a refused input'
}
Remove-Item "$xdir/.env"
Set-Content "$xdir/assets/app.js.map" '{"version":3,"mappings":""}'
$out = & build/cap6/bin/pwebbundle.exe $xdir build/cap6/maps.pwb 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "sourcemap-exclusion build failed: $out" }
if ($out -notmatch 'excluded sourcemap') {
    throw 'sourcemap exclusion was not logged'
}
& build/cap6/bin/pwebbundle.exe $xdir build/cap6/maps-optin.pwb --include-sourcemaps
if ($LASTEXITCODE -ne 0) { throw '--include-sourcemaps build failed' }
# proof by ENTRY LIST, not by size
$defaultNames = Get-ZipEntryNames build/cap6/maps.pwb
$optinNames = Get-ZipEntryNames build/cap6/maps-optin.pwb
if ($defaultNames -contains 'assets/app.js.map') {
    throw 'sourcemap present in the default bundle'
}
if ($optinNames -notcontains 'assets/app.js.map') {
    throw 'sourcemap absent from the --include-sourcemaps bundle'
}
Write-Host 'CAP-6 exclusion policy PASS (secret refused; sourcemap absent by default, present on opt-in - by entry list)'

# --- 4) CLI flags: --min-runtime and --max-asset-bytes ---
& build/cap6/bin/pwebbundle.exe examples/04-react/frontend/dist `
    build/cap6/minrt.pwb --min-runtime=0.2.0
if ($LASTEXITCODE -ne 0) { throw '--min-runtime build failed' }
$manifest = Get-ZipEntryText build/cap6/minrt.pwb 'manifest.json'
if ($manifest -cne '{"pweb":{"protocol":1,"minRuntime":"0.2.0"}}') {
    throw "stamped manifest bytes wrong: $manifest"
}
# a prior run's acceptance leg may have left limited.pwb (and a refused
# build rightly preserves pre-existing output) - clear it so this leg
# asserts exactly "a refusal creates nothing"
Remove-Item -Force -ErrorAction SilentlyContinue build/cap6/limited.pwb
& build/cap6/bin/pwebbundle.exe examples/04-react/frontend/dist `
    build/cap6/limited.pwb --max-asset-bytes=100 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'undersized --max-asset-bytes did not refuse' }
if (Test-Path build/cap6/limited.pwb) { throw 'refused build left an output' }
& build/cap6/bin/pwebbundle.exe examples/04-react/frontend/dist `
    build/cap6/limited.pwb --max-asset-bytes=10000000
if ($LASTEXITCODE -ne 0) { throw 'generous --max-asset-bytes build failed' }
Write-Host 'CAP-6 CLI flags PASS (--min-runtime stamped; --max-asset-bytes refuse/accept)'

# --- 5) isolated release/ assembly, zero loose frontend files ---
$rel = 'build/cap6/release'
New-ReleaseDir $rel
Copy-Item build/cap6/app.pwb $rel/
$files = @(Get-ChildItem $rel -Recurse -File | ForEach-Object Name | Sort-Object)
$expected = @('app.pwb', 'releaseapp.exe', 'webview.dll')
if (($files -join ',') -ne ($expected -join ',')) {
    throw "release dir is not clean: $($files -join ', ')"
}
$loose = @(Get-ChildItem $rel -Recurse -File |
    Where-Object { $_.Name -match '\.(html|css|js|map|json)$' })
if ($loose) { throw "loose frontend file(s) in release dir: $($loose.Name -join ', ')" }
Write-Host 'CAP-6 release layout PASS (exe + app.pwb + dll only)'

# --- 6) missing-bundle refusal from an unrelated CWD (headless) ---
$missDir = 'build/cap6/release-missing'
New-ReleaseDir $missDir
$r = Invoke-ReleaseApp $missDir
if ($r.Code -eq 0) { throw 'missing bundle did not exit nonzero' }
if ($r.Out -notmatch 'app\.pwb REFUSED \(bundle file missing\)') {
    throw "missing-bundle refusal marker absent (exit $($r.Code)): $($r.Out)"
}
Write-Host "CAP-6 missing-bundle refusal PASS (exit $($r.Code), marker present, no WebView)"

# --- 7) tampered-bundle refusals (headless) ---
$tampDir = 'build/cap6/release-tampered'
New-ReleaseDir $tampDir
# 7a: non-ZIP bytes
Set-Content -Path "$tampDir/app.pwb" -Value 'this is not a zip archive at all' -NoNewline
if (-not (Test-Path "$tampDir/app.pwb")) { throw 'tamper fixture not written' }
$r = Invoke-ReleaseApp $tampDir
if ($r.Code -eq 0) { throw 'garbage bundle did not exit nonzero' }
if ($r.Out -notmatch 'app\.pwb REFUSED \(bundle archive invalid\)') {
    throw "garbage-bundle refusal marker absent (exit $($r.Code)): $($r.Out)"
}
# 7b: truncated real bundle
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path build/cap6/app.pwb).Path)
[System.IO.File]::WriteAllBytes(
    (Join-Path (Resolve-Path $tampDir).Path 'app.pwb'),
    $bytes[0..([int]($bytes.Length / 2))])
$r = Invoke-ReleaseApp $tampDir
if ($r.Code -eq 0) { throw 'truncated bundle did not exit nonzero' }
if ($r.Out -notmatch 'app\.pwb REFUSED \(bundle archive invalid\)') {
    throw "truncated-bundle refusal marker absent (exit $($r.Code)): $($r.Out)"
}
Write-Host 'CAP-6 tampered-bundle refusals PASS (garbage + truncated, typed markers)'

# --- 8) native compat refusals end-to-end (typed categories) ---
# 8a: a structurally valid bundle whose manifest declares protocol 2 -
# crafted here, outside the bundler, exactly like a foreign tool would
$protoDir = 'build/cap6/release-proto2'
New-ReleaseDir $protoDir
$pwbPath = Join-Path (Resolve-Path $protoDir).Path 'app.pwb'
$fs = [System.IO.File]::Create($pwbPath)
try {
    $zip = [System.IO.Compression.ZipArchive]::new($fs,
        [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($pair in @(
            @{ n = 'manifest.json'
               v = '{"pweb":{"protocol":2,"minRuntime":"0.1.0"}}' },
            @{ n = 'index.html'
               v = '<!doctype html><html><body>proto2</body></html>' })) {
            $entry = $zip.CreateEntry($pair.n)
            $w = [System.IO.StreamWriter]::new($entry.Open())  # UTF-8, no BOM
            try { $w.Write($pair.v) } finally { $w.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
$r = Invoke-ReleaseApp $protoDir
if ($r.Code -eq 0) { throw 'protocol-2 bundle did not exit nonzero' }
if ($r.Out -notmatch 'app\.pwb REFUSED \(bundle protocol unsupported\)') {
    throw "protocol refusal marker absent (exit $($r.Code)): $($r.Out)"
}
# 8b: minRuntime above this runtime refuses with its own category
$minrtDir = 'build/cap6/release-minrt'
New-ReleaseDir $minrtDir
Copy-Item build/cap6/minrt.pwb "$minrtDir/app.pwb"
$r = Invoke-ReleaseApp $minrtDir
if ($r.Code -eq 0) { throw 'minRuntime-above bundle did not exit nonzero' }
if ($r.Out -notmatch 'app\.pwb REFUSED \(runtime below bundle minimum\)') {
    throw "minRuntime refusal marker absent (exit $($r.Code)): $($r.Out)"
}
Write-Host 'CAP-6 native compat refusals PASS (protocol 2 + minRuntime 0.2.0, typed markers, no WebView)'

# --- 9) observational ZIP benchmark (no gate) ---
$iters = 50
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = & build/cap6/bin/pwebbundle.exe --verify build/cap6/app.pwb $iters 2>&1 | Out-String
$sw.Stop()
if ($LASTEXITCODE -ne 0) { throw "verify benchmark run failed: $out" }
$size = (Get-Item build/cap6/app.pwb).Length
$perCycle = [math]::Round($sw.Elapsed.TotalMilliseconds / $iters, 3)
$bench = "app.pwb $size bytes; $iters full load+read cycles in " +
    "$([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms " +
    "($perCycle ms/cycle, process-timed); in-process: $($out.Trim())"
Write-Host "CAP-6 ZIP benchmark (observational): $bench"
if ($env:GITHUB_STEP_SUMMARY) {
    "### CAP-6 ZIP bundle benchmark (observational)`n$bench" |
        Out-File -Append $env:GITHUB_STEP_SUMMARY
}

Write-Host 'CAP-6 headless gates: ALL PASS'
