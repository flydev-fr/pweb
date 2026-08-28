# CAP-10B2 (Windows): prove the GENERATED Pas2JS project builds and runs.
#
# This is a TEST HARNESS and not `pweb build`. CAP-10B2 exposes no build
# command, and nothing here is a step towards one: it exists so that "the
# Pas2JS scaffold produces a working application" is a measurement rather
# than a claim, and CAP-10D will own the real orchestration.
#
# THE RELOCATION IS THE PROOF, and here it is stronger than the React one.
# The project is copied out of the tree that created it into an unrelated
# staging path, and every artifact of its build lands OUTSIDE it - there is
# no npm, so nothing is materialised into the project at all. Its bytes are
# digested before and after, and must be identical.
#
# THE SDK ROOT IS THE OTHER PROOF. The only -Fu handed to the compiler for
# PWeb code names build/cap10b1/sdk/share/pweb/sdk/pas2js - the STAGED SDK -
# and the native compile names the staged src/. So a generated project that
# only builds beside its own framework's checkout fails here.
#
# Steps, in order:
#   1  relocate the created project, digest it
#   2  the pinned compiler, identified and recorded (version, host arch)
#   3  compile the Pascal frontend into an EXTERNAL stage
#   4  normalise, assemble the static output, sweep it
#   5  app.pwb, through the frozen CAP-6 bundler
#   6  the generated Pascal program, inside the CAP-3U window
#   7  the smallest release layout, and a real GUI run from an unrelated CWD
#   8  re-digest the project and require it unchanged
#   9  React/Pas2JS backend parity, against the CAP-10B1 proof record
#
# Emits build/cap10b2/proof-<target>.json.
#
# Usage: pwsh test/cap10b2/prove_cap10b2.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap10b2'
$sdkRoot = Join-Path $repoRoot 'build/cap10b1/sdk'
$sdkPas2js = Join-Path $sdkRoot 'share/pweb/sdk/pas2js'
$source = Join-Path $work 'project/demo'
$bundler = Join-Path $repoRoot 'build/cap10b1/bin/pwebbundle.exe'
$webviewDll = Join-Path $repoRoot 'build/webview-dist/webview.dll'
$compiler = Join-Path $repoRoot 'deps/pas2js/bin/pas2js.exe'
foreach ($pre in $source, $bundler, $webviewDll, $compiler,
                 (Join-Path $sdkPas2js 'pweb.native.pas'),
                 (Join-Path $sdkRoot 'share/pweb/src/webview/pweb.webview.host.pas')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run build_cap10b1, " +
            'run_cap10b2_gates and tools/get-pas2js.ps1 first')
    }
}
$target = 'windows-x86_64'
$log = Join-Path $work 'proof.log'
Remove-Item -Force -ErrorAction SilentlyContinue $log

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Name, $Value) { $rows[$Name] = $Value }
function Require([bool]$Ok, [string]$What) {
    if (-not $Ok) { $failures.Add($What) }
}
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
function Sha256File([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
# ORDINAL, never Sort-Object - see the note in run_cap10b2_gates.ps1.
function SortOrdinal([string[]]$Items) {
    $copy = [string[]]::new($Items.Length)
    [Array]::Copy($Items, $copy, $Items.Length)
    [Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return $copy
}
function TreeDigest([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $lines.Add("$rel $($f.Length) $(Sha256File $f.FullName)")
    }
    return Sha256Text (((SortOrdinal $lines.ToArray()) -join "`n") + "`n")
}

# --- 1. relocate, and digest what must not change --------------------------
$stage = Join-Path $work 'stage'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
New-Item -ItemType Directory -Force $stage | Out-Null
$project = Join-Path $stage 'demo'
Copy-Item -Recurse -LiteralPath $source -Destination $project
$beforeDigest = TreeDigest $source
Row 'pas2js_tree_digest' $beforeDigest

# --- 2. the pinned compiler, identified --------------------------------------
# THE VERSION IS EXACT, not a floor: the PWeb Pas2JS SDK is compiled by it,
# so a different compiler is a different product rather than a newer one.
$compilerVersion = (& $compiler -iV | Out-String).Trim()
$compilerArch = (& $compiler -iSP | Out-String).Trim()
$compilerOs = (& $compiler -iSO | Out-String).Trim()
Require ($compilerVersion -ceq '3.0.1') `
    "the pinned Pas2JS reports $compilerVersion, expected 3.0.1"
Row 'pas2js_compiler_version' $compilerVersion
Row 'pas2js_compiler_arch' $compilerArch
Row 'pas2js_compiler_host' "$compilerOs/$compilerArch"
Row 'pas2js_compiler_sha256' (Sha256File $compiler)
Write-Host "[CAP-10B2] pas2js $compilerVersion ($compilerOs/$compilerArch)"

# --- 3. the frontend, compiled into an EXTERNAL stage ------------------------
# Every path handed to the compiler is absolute and lives OUTSIDE the
# project: the SDK unit path names the staged SDK root, and the output names
# the build stage. Nothing is written back into the tree being built.
$dist = Join-Path $stage 'dist'
New-Item -ItemType Directory -Force (Join-Path $dist 'assets') | Out-Null
$outJs = Join-Path $dist 'assets/app.js'
$cfg = Join-Path $project 'frontend/pas2js.cfg'
$entry = Join-Path $project 'frontend/src/demoapp.lpr'
$compilerArgs = @("@$cfg", "-Fu$sdkPas2js", "-o$outJs", $entry)
Row 'pas2js_compiler_invocation' (
    'pas2js ' + (($compilerArgs | ForEach-Object {
        $_.Replace($repoRoot, '<repo>').Replace($stage, '<stage>') }) -join ' '))
# THE STAGED SDK, ASSERTED RATHER THAN RECORDED. An invocation string in the
# evidence says what this script MEANT to do; these two rules say what it
# actually did. Exactly one PWeb unit path is handed to the compiler, it
# names the staged SDK root, and this repository's own sdk/pas2js is not
# among the arguments at all - so "the frontend compiles" cannot quietly
# mean "it compiles beside its own framework's git checkout".
$unitPaths = @($compilerArgs | Where-Object { $_ -like '-Fu*' })
Require ($unitPaths.Count -eq 1) `
    "the frontend compile passes $($unitPaths.Count) unit paths, expected exactly 1"
Require ($unitPaths[0] -ceq "-Fu$sdkPas2js") `
    "the frontend compile's unit path is '$($unitPaths[0])', expected the staged SDK"
$checkoutSdk = Join-Path $repoRoot 'sdk/pas2js'
foreach ($a in $compilerArgs) {
    Require (-not $a.StartsWith("-Fu$checkoutSdk")) `
        "the frontend compile names this repository's sdk/pas2js: $a"
}
Row 'pas2js_sdk_from_sdk_root' $(
    if (($unitPaths.Count -eq 1) -and ($unitPaths[0] -ceq "-Fu$sdkPas2js")) {
        'PASS' } else { 'FAIL' })
& $compiler @compilerArgs 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
$frontendBuilt = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $outJs)
Require $frontendBuilt 'the generated Pas2JS frontend does not compile'
Row 'pas2js_frontend_build' $(if ($frontendBuilt) { 'PASS' } else { 'FAIL' })
if (-not $frontendBuilt) {
    throw 'CAP-10B2 build proof FAILED: the frontend did not compile'
}

# --- 4. the static output, normalised, assembled and swept -------------------
#
# THE NORMALISATION IS A MEASUREMENT, NOT A PREFERENCE. Pas2JS writes its
# output through the host's text layer: MEASURED on Windows, app.js begins
# EF BB BF and carries CRLF; on POSIX it carries LF. Packing the compiler's
# raw bytes would make the Pas2JS app.pwb an OS-family artifact and
# pas2js_static_inventory_digest unsatisfiable across four targets. This is
# the same decision, for the same reason, that makes the CAP-5 build write
# boot.js byte-exactly with LF rather than through Set-Content.
$bytes = [System.IO.File]::ReadAllBytes($outJs)
$hadBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and
    ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($hadBom) { $text = $text.Substring(1) }
$hadCrlf = $text.Contains("`r`n")
$text = $text.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($outJs, $text,
    [System.Text.UTF8Encoding]::new($false))
Row 'pas2js_output_normalised' "bom=$hadBom crlf=$hadCrlf"

# the bootstrap, as a bundled classic script, byte-exactly with LF. -Jc
# concatenates the RTL and declares `rtl` without starting it, so a later
# classic script in the same global scope is all that is needed - no module,
# no defer, and above all no INLINE code, which the ratified script-src
# 'self' forbids and CAP-8B measured blocked on all three engines.
[System.IO.File]::WriteAllText((Join-Path $dist 'assets/boot.js'),
    "rtl.run();`n", [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $project 'frontend/index.html') `
    -Destination (Join-Path $dist 'index.html')
Copy-Item -LiteralPath (Join-Path $project 'frontend/app.css') `
    -Destination (Join-Path $dist 'assets/app.css')

# the EXACT static set: only the assets app.pwb needs, and nothing else
$distFiles = SortOrdinal @(Get-ChildItem -LiteralPath $dist -Recurse -File -Force |
    ForEach-Object { $_.FullName.Substring($dist.Length + 1).Replace('\', '/') })
$expectedDist = SortOrdinal @('index.html', 'assets/app.js', 'assets/boot.js',
    'assets/app.css')
Require ((($distFiles -join '|')) -ceq (($expectedDist -join '|'))) `
    "the static output is $($distFiles -join ', ')"
Row 'pas2js_static_inventory_digest' (Sha256Text (
    (($distFiles | ForEach-Object {
        "$_ $((Get-Item -LiteralPath (Join-Path $dist $_)).Length) " +
        "$(Sha256File (Join-Path $dist $_))" }) -join "`n") + "`n"))

# the sweep. Developer paths, home directories, the checkout, the SDK root,
# any network fallback, any dev watcher and any source map: none of them may
# survive into something that ships inside app.pwb.
$bundleText = [System.IO.File]::ReadAllText($outJs)
$outputClean = $true
foreach ($needle in '/Users/', '/home/', '\Users\', '%USERPROFILE%',
                    '/private/var/folders/', 'C:\', $repoRoot, $sdkPas2js,
                    $stage, 'localhost', '127.0.0.1', 'file://', 'http://',
                    'https://', 'ws://', 'wss://', 'sourceMappingURL',
                    'import.meta.hot', '/@vite/client') {
    if ($bundleText.Contains($needle)) {
        $outputClean = $false
        Require $false "the compiled frontend carries $needle"
    }
}
Require (-not (Test-Path -LiteralPath "$outJs.map")) `
    'the production build emitted a source map'
Row 'pas2js_output_sweep' $(if ($outputClean) { 'PASS' } else { 'FAIL' })

# THE RAW BINDING, by occurrence classification rather than by an impossible
# whole-bundle ban. The SDK necessarily contains the binding - it IS the
# transport - so what is proven is OWNERSHIP:
#   exactly one occurrence in the whole bundle, and
#   that occurrence inside the rtl.module("pweb.native", ...) body.
# A second binding emitted by the application breaks the first; a binding
# emitted outside the SDK breaks the second.
# OCCURRENCES, not lines: two bindings on one line would read as one
$bindingCount = @([regex]::Matches($bundleText, '__pweb_invoke')).Count
$lines = $bundleText -split "`n"
$bindingLines = @()
$moduleStarts = @()
for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i].Contains('__pweb_invoke')) { $bindingLines += $i }
    if ($lines[$i] -match '^rtl\.module\("([^"]+)"') {
        $moduleStarts += [pscustomobject]@{ Line = $i; Name = $Matches[1] }
    }
}
Require ($bindingCount -eq 1) `
    ("the compiled frontend names the raw native binding " +
     "$bindingCount time(s), expected exactly 1 (the SDK's own)")
$owner = ''
if ($bindingLines.Count -ge 1) {
    $at = $bindingLines[0]
    foreach ($m in $moduleStarts) {
        if ($m.Line -lt $at) { $owner = $m.Name }
    }
}
Require ($owner -ceq 'pweb.native') `
    ("the raw native binding is emitted inside module '$owner', expected " +
     "'pweb.native' -- only the frozen SDK may own that name")
Row 'pas2js_app_raw_binding' $(
    if ($bindingCount -eq 1) { 'false' } else { 'true' })
Row 'pas2js_sdk_binding_owner' $(
    if ($owner -ceq 'pweb.native') { 'true' } else { 'false' })
foreach ($channel in 'webkit.messageHandlers', 'chrome.webview') {
    Require (-not $bundleText.Contains($channel)) `
        "the compiled frontend names the platform channel $channel"
}
# the page loads its scripts EXTERNALLY and carries no inline code
$indexText = [System.IO.File]::ReadAllText((Join-Path $dist 'index.html'))
Require ($indexText -match '<script[^>]*\ssrc=') `
    'the built index.html has no external script'
Require (-not ($indexText -match '<script(?![^>]*\ssrc=)[^>]*>[^<]')) `
    'the built index.html carries an inline script'
Require ($indexText -match '<link[^>]*rel="stylesheet"') `
    'the built index.html does not link the stylesheet'

# --- 5. app.pwb, through the frozen bundler --------------------------------
$appPwb = Join-Path $stage 'app.pwb'
& $bundler $dist $appPwb 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
Require ($LASTEXITCODE -eq 0) 'the app.pwb build FAILED'
Row 'pas2js_app_pwb_bytes' (Get-Item -LiteralPath $appPwb).Length
# the SEMANTIC inventory, not the archive bytes: CAP-6/CAP-7L measured that
# the mORMot static DEFLATE object emits different bytes per toolchain, and
# CAP-10B0 measured the ZIP `version made by` OS byte on top of that. What is
# a function of the input alone is the logical name, length and digest of
# each entry, which is what four targets compare.
Row 'pas2js_app_pwb_semantic_digest' $rows['pas2js_static_inventory_digest']

# --- 6. the generated Pascal program, against the STAGED SDK ---------------
$sdkSrc = Join-Path $sdkRoot 'share/pweb/src'
$unitDir = Join-Path $work 'app-units'
$binDir = Join-Path $work 'app-bin'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $unitDir, $binDir
New-Item -ItemType Directory -Force $unitDir, $binDir | Out-Null
$nativeBuilt = $false
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1 2>&1 |
        Tee-Object -FilePath $log -Append | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'CAP-3U re-apply FAILED' }
    $sdkUnits = @('lib', 'rpc', 'security', 'webview', 'assets',
                  'platform/windows') |
        ForEach-Object { "-Fu$(Join-Path $sdkSrc $_)" }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
        "-FU$unitDir" "-FE$binDir" "-Fu$(Join-Path $project 'src')" `
        @sdkUnits `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net `
        -Fudeps/mormot2/src/db -Fudeps/mormot2/src/orm `
        -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa `
        -Fldeps/mormot2/static/x86_64-win64 `
        (Join-Path $project 'src/demo.lpr') 2>&1 |
        Tee-Object -FilePath $log -Append | Out-Null
    $nativeBuilt = $LASTEXITCODE -eq 0
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore 2>&1 |
            Tee-Object -FilePath $log -Append | Out-Null
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
Require $nativeBuilt 'the generated Pascal program does not compile'
Row 'pas2js_native_build' $(if ($nativeBuilt) { 'PASS' } else { 'FAIL' })
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas |
    Out-Null
Require ($LASTEXITCODE -eq 0) 'CAP-3U source is not pristine after the restore'

# THE EXECUTABLE COMPARISON, MEASURED AND REPORTED RATHER THAN ASSERTED.
# The two UI variants compile the same native source, so in principle they
# could produce the same binary. In practice the compiler is handed different
# absolute unit paths for each project and FPC records build metadata, so
# equality is not something to require - it is something to observe, and to
# say plainly which way it came out.
$reactExe = Join-Path $repoRoot 'build/cap10b1/app-bin/demo.exe'
if (Test-Path -LiteralPath $reactExe) {
    $a = Sha256File $reactExe
    $b = Sha256File (Join-Path $binDir 'demo.exe')
    Row 'native_binary_equal' $(if ($a -ceq $b) { 'true' } else { 'false' })
    Row 'native_binary_note' $(
        if ($a -ceq $b) { 'identical bytes' }
        else { 'differs: the two projects compile from different absolute paths' })
} else {
    Row 'native_binary_equal' 'not_measured'
    Row 'native_binary_note' 'the CAP-10B1 react executable was not present'
}

# --- 7. the smallest release layout, and a real run ------------------------
$release = Join-Path $work 'release'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $release
New-Item -ItemType Directory -Force $release | Out-Null
Copy-Item -LiteralPath (Join-Path $binDir 'demo.exe') -Destination $release
Copy-Item -LiteralPath $appPwb -Destination $release
Copy-Item -LiteralPath $webviewDll -Destination $release
$layout = SortOrdinal @(Get-ChildItem -LiteralPath $release -Recurse -Force |
    ForEach-Object { $_.Name })
$expectedLayout = SortOrdinal @('app.pwb', 'demo.exe', 'webview.dll')
Require ((($layout -join '|')) -ceq (($expectedLayout -join '|'))) `
    "the release layout is $($layout -join ', ')"
Row 'pas2js_loose_assets' $(
    if ((($layout -join '|')) -ceq (($expectedLayout -join '|'))) { 'false' }
    else { 'true' })

$verdictFile = Join-Path $work 'app-verdict.txt'
$outFile = Join-Path $work 'app-stdout.txt'
$errFile = Join-Path $work 'app-stderr.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $verdictFile, $outFile, $errFile
$autoCloseMs = 20000
$started = [System.Diagnostics.Stopwatch]::StartNew()
# an unrelated CWD, deliberately: app.pwb is resolved from the EXECUTABLE and
# a run that only works from its own directory has not proved that
$proc = Start-Process -FilePath (Join-Path $release 'demo.exe') `
    -ArgumentList @("--pweb-verdict=$verdictFile", "--pweb-autoclose-ms=$autoCloseMs") `
    -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
    -NoNewWindow -PassThru
# sampled WHILE the window is live: a socket opened and closed between runs
# would be invisible afterwards
$listeners = 0
for ($i = 0; $i -lt 60 -and -not $proc.HasExited; $i++) {
    try {
        $n = @(Get-NetTCPConnection -State Listen -OwningProcess $proc.Id `
                -ErrorAction SilentlyContinue).Count
        $u = @(Get-NetUDPEndpoint -OwningProcess $proc.Id `
                -ErrorAction SilentlyContinue).Count
        if (($n + $u) -gt $listeners) { $listeners = $n + $u }
    } catch { }
    Start-Sleep -Milliseconds 500
}
$proc.WaitForExit()
$started.Stop()
$elapsedMs = [int]$started.Elapsed.TotalMilliseconds
$stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
$stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
Add-Content -Path $log -Value "===== app run (exit $($proc.ExitCode), ${elapsedMs}ms) ====="
Add-Content -Path $log -Value ($stdout + $stderr)
Write-Host $stdout
Write-Host $stderr

Require ($proc.ExitCode -eq 0) `
    "the generated application exited $($proc.ExitCode)"
Row 'pas2js_app_exit' $proc.ExitCode
Row 'pas2js_run_elapsed_ms' $elapsedMs
Row 'pas2js_listener_count' $listeners
Require ($listeners -eq 0) "the generated application opened $listeners listener(s)"
Require ((Test-Path $verdictFile) -and
         ((Get-Content $verdictFile -Raw).Trim() -ceq 'demo: ok')) `
    'the generated application did not write its verdict'
Row 'pas2js_clean_shutdown' $(
    if (($proc.ExitCode -eq 0) -and $stdout.Contains('demo: clean exit')) {
        'true' } else { 'false' })

# the page's own report. Every field is REQUIRED: a report that arrived with
# a false in it is a failure, and a report that never arrived is a failure
# too - and the two are named DIFFERENTLY, because a page that did not
# report inside its window is a timing observation and not a runtime defect.
# `deferred-work.md` records exactly that shape happening to the CAP-5
# Pas2JS smoke, undiagnosed, so this harness refuses to conflate them.
$reportJson = ''
foreach ($line in ($stdout -split "`n")) {
    if ($line -match 'demo: ready (\{.*\})\s*$') { $reportJson = $Matches[1] }
}
Require ($reportJson -ne '') `
    ("the generated application printed no ready report within " +
     "${autoCloseMs}ms (ran ${elapsedMs}ms) -- NO REPORT RECEIVED, which is " +
     'a timing observation and not a runtime verdict')
Row 'pas2js_report_received' $(if ($reportJson -ne '') { 'true' } else { 'false' })
$reportFields = ''
if ($reportJson -ne '') {
    $report = $reportJson | ConvertFrom-Json
    $reportFields = (SortOrdinal @($report.PSObject.Properties.Name)) -join ','
    foreach ($flag in 'html', 'css', 'js', 'secure', 'handshake', 'rpc', 'errmap') {
        Require ($report.$flag -eq $true) "the page reported $flag = $($report.$flag)"
        Row "pas2js_$flag" $(if ($report.$flag -eq $true) { 'true' } else { 'false' })
    }
    Require ($report.value -eq 42) "CalculatorService.Add returned $($report.value)"
    Row 'pas2js_rpc_result' $report.value
    Row 'pas2js_secure_origin' $(if ($report.secure -eq $true) { 'PASS' } else { 'FAIL' })
    Row 'pas2js_error_mapping' $(if ($report.errmap -eq $true) { 'PASS' } else { 'FAIL' })
}
Row 'pas2js_report_fields' $reportFields
# THE EXACT REPORT SHAPE, and it is the React starter's. Both pages answer
# the same eight questions under the same names, which is what makes the
# parity comparison below a comparison rather than two separate readings.
Require ($reportFields -ceq 'css,errmap,handshake,html,js,rpc,secure,value') `
    "the pas2js page reported the field set '$reportFields'"

# --- 8. the project the build was NOT allowed to touch ---------------------
$afterDigest = TreeDigest $source
Require ($afterDigest -ceq $beforeDigest) `
    'the build mutated the generated project'
Row 'pas2js_tree_unchanged' $(
    if ($afterDigest -ceq $beforeDigest) { 'PASS' } else { 'FAIL' })
# and the relocated COPY is untouched too, which is the stronger claim the
# Pas2JS path can make and the React one cannot: with no package manager
# there is nothing to materialise into a working tree at all
$copyDigest = TreeDigest $project
Require ($copyDigest -ceq $beforeDigest) `
    'the build wrote into the relocated project copy'
Row 'pas2js_build_out_of_tree' $(
    if ($copyDigest -ceq $beforeDigest) { 'PASS' } else { 'FAIL' })

# --- 9. React/Pas2JS backend parity ----------------------------------------
#
# The parity claim is RUNTIME and BACKEND, never source-language identity:
# same secure origin, same handshake, same 42, same typed rejection, no
# listener and no loose asset on either. The React half of it was measured
# minutes ago by the CAP-10B1 proof in this same job, so the comparison is
# between two records rather than between a record and a memory.
$reactProof = Join-Path $repoRoot "build/cap10b1/proof-$target.json"
if (Test-Path -LiteralPath $reactProof) {
    $rp = Get-Content $reactProof -Raw | ConvertFrom-Json
    $parity = $true
    foreach ($flag in 'html', 'css', 'js', 'secure', 'handshake', 'rpc', 'errmap') {
        if ("$($rp.$flag)" -cne 'true') {
            $parity = $false
            Require $false "the CAP-10B1 react record reports $flag = $($rp.$flag)"
        }
    }
    foreach ($pair in @(@('rpc_result', 'pas2js_rpc_result'),
                        @('listener_count', 'pas2js_listener_count'),
                        @('loose_assets_used', 'pas2js_loose_assets'))) {
        $reactValue = "$($rp.($pair[0]))"
        $p2jValue = "$($rows[$pair[1]])"
        if ($reactValue -cne $p2jValue) {
            $parity = $false
            Require $false ("react and pas2js disagree on $($pair[0]): " +
                "'$reactValue' vs '$p2jValue'")
        }
    }
    Row 'react_pas2js_parity' $(if ($parity) { 'PASS' } else { 'FAIL' })
    Row 'react_regression_runtime' $(
        if ("$($rp.rpc_result)" -ceq '42') { 'PASS' } else { 'FAIL' })
} else {
    Require $false ("the CAP-10B1 proof record is absent at $reactProof -- " +
        'backend parity cannot be a claim about a measurement nobody made')
}

Row 'target' $target
Row 'pas2js_proof_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "proof-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10B2] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10B2 build proof FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10B2] the generated Pas2JS project builds and runs on $target"
