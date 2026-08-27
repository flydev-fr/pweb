# CAP-10B1 (Windows): prove the GENERATED project builds and runs.
#
# This is a TEST HARNESS and not `pweb build`. CAP-10B1 exposes no build
# command, and nothing here is a step towards one: it exists so that "the
# scaffold produces a working application" is a measurement rather than a
# claim, and CAP-10D will own the real orchestration.
#
# THE RELOCATION IS THE PROOF. The project is copied out of the tree that
# created it into an unrelated staging path, and its bytes are digested
# BEFORE and AFTER everything below. A build that mutates the project it
# builds is a build whose output is not a function of its input, and the
# SDK-root dependency model exists precisely so that it does not have to.
#
# THE SDK ROOT IS THE OTHER PROOF. Every PWeb unit path handed to the
# compiler names build/cap10b1/sdk/share/pweb/src - the STAGED SDK - and not
# this repository's src/. So a generated project that only compiles beside
# its own framework's checkout fails here.
#
# Steps, in order:
#   1  relocate the created project, digest it
#   2  materialise the pinned TypeScript SDK into the build stage
#   3  npm ci, typecheck, production build
#   4  the frontend security sweeps, over SOURCE and over OUTPUT
#   5  app.pwb, through the frozen CAP-6 bundler
#   6  the generated Pascal program, inside the CAP-3U window
#   7  the smallest release layout, and a real GUI run from an unrelated CWD
#   8  re-digest the project and require it unchanged
#
# Emits build/cap10b1/proof-<target>.json.
#
# Usage: pwsh test/cap10b1/prove_cap10b1.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$work = Join-Path $repoRoot 'build/cap10b1'
$sdkRoot = Join-Path $work 'sdk'
$source = Join-Path $work 'project/demo'
$bundler = Join-Path $work 'bin/pwebbundle.exe'
$webviewDll = Join-Path $repoRoot 'build/webview-dist/webview.dll'
foreach ($pre in $source, $bundler, $webviewDll,
                 (Join-Path $sdkRoot 'share/pweb/sdk/typescript/package.json'),
                 (Join-Path $sdkRoot 'share/pweb/src/webview/pweb.webview.host.pas')) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run build_cap10b1.ps1 and " +
            'run_cap10b1_gates.ps1 first')
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
function TreeDigest([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$rel $($f.Length) $h")
    }
    return Sha256Text ((@($lines | Sort-Object) -join "`n") + "`n")
}

# --- 1. relocate, and digest what must not change --------------------------
$stage = Join-Path $work 'stage'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
New-Item -ItemType Directory -Force $stage | Out-Null
$project = Join-Path $stage 'demo'
Copy-Item -Recurse -LiteralPath $source -Destination $project
$beforeDigest = TreeDigest $source
Row 'generated_tree_digest' $beforeDigest

# --- 2. the SDK, materialised into the build stage -------------------------
# the generated package.json points at .pweb/sdk/typescript RELATIVE to the
# frontend, and this is the step that puts a package there. Note where it
# lands: inside the STAGE, never inside $source
$frontend = Join-Path $project 'frontend'
node tools/stage-ts-sdk.mjs (Join-Path $sdkRoot 'share/pweb/sdk/typescript') `
    (Join-Path $frontend '.pweb/sdk/typescript') 2>&1 |
    Tee-Object -FilePath $log -Append | Out-Null
Require ($LASTEXITCODE -eq 0) 'materialising the TypeScript SDK FAILED'

# --- 3. the frontend ------------------------------------------------------
Push-Location $frontend
try {
    npm ci --no-audit --no-fund 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
    Require ($LASTEXITCODE -eq 0) 'npm ci FAILED in the generated frontend'
    npm run typecheck 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
    $typecheck = $LASTEXITCODE -eq 0
    Require $typecheck 'the generated frontend does not typecheck'
    npm run build 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
    $built = $LASTEXITCODE -eq 0
    Require $built 'the generated frontend does not build'
}
finally { Pop-Location }
Row 'frontend_typecheck' $(if ($typecheck) { 'PASS' } else { 'FAIL' })
Row 'frontend_build' $(if ($built) { 'PASS' } else { 'FAIL' })

$dist = Join-Path $frontend 'dist'
foreach ($f in 'index.html', 'assets/app.js', 'assets/index.css') {
    Require (Test-Path -LiteralPath (Join-Path $dist $f)) `
        "the production build did not emit $f"
}

# --- 4. the frontend security sweeps ---------------------------------------
# over the generated SOURCE, which is what a developer reads and edits. The
# BUNDLE necessarily contains the SDK's own use of the native primitive -
# that is the SDK doing its job - so sweeping the bundle for that string
# would be sweeping for the runtime rather than for the application.
#
# ONLY A STRING LITERAL COUNTS, which is the discipline CAP-10A's dev-trust
# gate already established: a comment that names a transport is how this
# repository EXPLAINS what it refuses - the generated App.tsx opens by saying
# it uses no fetch, no WebSocket and no localhost - and a gate that could not
# tell a literal from its explanation would forbid the explanation. What must
# not exist is the transport as DATA.
$srcFiles = @(Get-ChildItem -LiteralPath (Join-Path $frontend 'src') -Recurse -File) +
    @(Get-Item -LiteralPath (Join-Path $frontend 'index.html'))
$literalForms = @('"([^"]*)"', "'((?:[^']|'')*)'", '`([^`]*)`')
$primitiveRx = '__pweb_invoke|webkit\.messageHandlers|chrome\.webview'
$transportRx = 'localhost|127\.0\.0\.1|file://|http://|https://|ws://|wss://'
$rawPrimitive = $false
$transportLeak = $false
foreach ($f in $srcFiles) {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
        $lineNo++
        foreach ($form in $literalForms) {
            foreach ($m in [regex]::Matches($line, $form)) {
                $v = $m.Groups[1].Value
                if ($v -match $primitiveRx) {
                    $rawPrimitive = $true
                    Require $false ("$($f.Name):${lineNo} uses a raw native " +
                        "primitive as DATA: $v")
                }
                if ($v -match $transportRx) {
                    $transportLeak = $true
                    Require $false ("$($f.Name):${lineNo} names a transport " +
                        "as DATA: $v")
                }
            }
        }
    }
}
# and exactly ONE import provides the native calls
$appText = [System.IO.File]::ReadAllText((Join-Path $frontend 'src/App.tsx'))
Require ($appText.Contains('from "@pweb/runtime"')) `
    'App.tsx does not import @pweb/runtime'
# the EXACT module set the frontend pulls in, side-effect imports included.
# An exact set rather than a deny-list: the interesting mistake in this class
# is the import nobody thought to forbid
$imports = New-Object System.Collections.Generic.List[string]
foreach ($f in 'src/App.tsx', 'src/main.tsx') {
    foreach ($line in [System.IO.File]::ReadLines((Join-Path $frontend $f))) {
        if ($line.TrimStart().StartsWith('import ')) {
            foreach ($m in [regex]::Matches($line, '"([^"]+)"')) {
                $imports.Add($m.Groups[1].Value)
            }
        }
    }
}
$observedImports = @($imports | Sort-Object -Unique)
$expectedImports = @('./App', './app.css', '@pweb/runtime', 'react',
    'react-dom/client') | Sort-Object
Require ((($observedImports -join '|')) -ceq (($expectedImports -join '|'))) `
    "the generated frontend imports $($observedImports -join ', ')"
Row 'raw_primitive_used' $(if ($rawPrimitive) { 'true' } else { 'false' })
Row 'frontend_transport_clean' $(if ($transportLeak) { 'FAIL' } else { 'PASS' })

# over the OUTPUT: no development transport may survive a production build
$bundleText = [System.IO.File]::ReadAllText((Join-Path $dist 'assets/app.js'))
$devLeak = $false
foreach ($needle in 'import.meta.hot', '/@vite/client', 'localhost',
                    '127.0.0.1', 'ws://', 'eval(') {
    if ($bundleText.Contains($needle)) {
        $devLeak = $true
        Require $false "the production bundle carries $needle"
    }
}
Row 'frontend_no_dev_code' $(if ($devLeak) { 'FAIL' } else { 'PASS' })
# the script is EXTERNAL and the document carries no inline script, which is
# what makes script-src 'self' with no 'unsafe-inline' a policy the page can
# actually live under
$indexText = [System.IO.File]::ReadAllText((Join-Path $dist 'index.html'))
Require ($indexText -match '<script[^>]*\ssrc=') `
    'the built index.html has no external script'
Require (-not ($indexText -match '<script(?![^>]*\ssrc=)[^>]*>[^<]')) `
    'the built index.html carries an inline script'

# --- 5. app.pwb, through the frozen bundler --------------------------------
$appPwb = Join-Path $stage 'app.pwb'
& $bundler $dist $appPwb 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
Require ($LASTEXITCODE -eq 0) 'the app.pwb build FAILED'

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
    # every PWeb unit path names the STAGED SDK. If one of them silently
    # resolved to this repository's src/ instead, the claim this step makes
    # would be about the checkout rather than about an installation.
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
Row 'native_build' $(if ($nativeBuilt) { 'PASS' } else { 'FAIL' })
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas |
    Out-Null
Require ($LASTEXITCODE -eq 0) 'CAP-3U source is not pristine after the restore'

# --- 7. the smallest release layout, and a real run ------------------------
$release = Join-Path $work 'release'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $release
New-Item -ItemType Directory -Force $release | Out-Null
Copy-Item -LiteralPath (Join-Path $binDir 'demo.exe') -Destination $release
Copy-Item -LiteralPath $appPwb -Destination $release
Copy-Item -LiteralPath $webviewDll -Destination $release
# exactly three files: an executable, its bundle and the engine library. A
# loose frontend file here would mean the release could serve something the
# bundle does not contain
$layout = @(Get-ChildItem -LiteralPath $release -Recurse -Force |
    ForEach-Object { $_.Name }) | Sort-Object
$expectedLayout = @('app.pwb', 'demo.exe', 'webview.dll')
Require ((($layout -join '|')) -ceq (($expectedLayout -join '|'))) `
    "the release layout is $($layout -join ', ')"
Row 'loose_assets_used' $(
    if ((($layout -join '|')) -ceq (($expectedLayout -join '|'))) { 'false' }
    else { 'true' })

$verdictFile = Join-Path $work 'app-verdict.txt'
$outFile = Join-Path $work 'app-stdout.txt'
$errFile = Join-Path $work 'app-stderr.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $verdictFile, $outFile, $errFile
# an unrelated CWD, deliberately: app.pwb is resolved from the EXECUTABLE
# and a run that only works from its own directory has not proved that
$proc = Start-Process -FilePath (Join-Path $release 'demo.exe') `
    -ArgumentList @("--pweb-verdict=$verdictFile", '--pweb-autoclose-ms=20000') `
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
$stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
$stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
Add-Content -Path $log -Value "===== app run (exit $($proc.ExitCode)) ====="
Add-Content -Path $log -Value ($stdout + $stderr)
Write-Host $stdout
Write-Host $stderr

Require ($proc.ExitCode -eq 0) `
    "the generated application exited $($proc.ExitCode)"
Row 'app_exit' $proc.ExitCode
Row 'listener_count' $listeners
Require ($listeners -eq 0) "the generated application opened $listeners listener(s)"
Require ((Test-Path $verdictFile) -and
         ((Get-Content $verdictFile -Raw).Trim() -ceq 'demo: ok')) `
    'the generated application did not write its verdict'

# the page's own report, parsed out of the ONE marker line the generated
# host prints. Every field is REQUIRED: a report that arrived with a false
# in it is a failure, and a report that never arrived is a failure too
$reportJson = ''
foreach ($line in ($stdout -split "`n")) {
    if ($line -match 'demo: ready (\{.*\})\s*$') { $reportJson = $Matches[1] }
}
Require ($reportJson -ne '') 'the generated application printed no ready report'
if ($reportJson -ne '') {
    $report = $reportJson | ConvertFrom-Json
    foreach ($flag in 'html', 'css', 'js', 'secure', 'handshake', 'rpc', 'errmap') {
        Require ($report.$flag -eq $true) "the page reported $flag = $($report.$flag)"
        Row $flag $(if ($report.$flag -eq $true) { 'true' } else { 'false' })
    }
    Require ($report.value -eq 42) "CalculatorService.Add returned $($report.value)"
    Row 'rpc_result' $report.value
    Row 'secure_origin' $(if ($report.secure -eq $true) { 'PASS' } else { 'FAIL' })
    Row 'error_mapping' $(if ($report.errmap -eq $true) { 'PASS' } else { 'FAIL' })
}

# --- 8. the project the build was NOT allowed to touch ---------------------
$afterDigest = TreeDigest $source
Require ($afterDigest -ceq $beforeDigest) `
    'the build mutated the generated project'
Row 'generated_tree_unchanged' $(
    if ($afterDigest -ceq $beforeDigest) { 'PASS' } else { 'FAIL' })

Row 'target' $target
Row 'proof_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "proof-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10B1] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10B1 build proof FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10B1] the generated project builds and runs on $target"
