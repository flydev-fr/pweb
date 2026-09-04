# CAP-10D2: the SDK distribution gates - PK1..PK4, IN1..IN4, CM1..CM6 and the
# closure checks CL1..CL4.
#
# THE REAL PACKAGER over the REAL staged SDK root, the REAL archive extracted
# to a path with a space and a non-ASCII character, and the REAL `pweb` out of
# that extraction driving `doctor`, `create`, `build` and `run` to 42 with the
# checkout's framework trees renamed aside. Nothing here reimplements a rule:
# every refusal it exercises is the CLI's own and every digest it compares is
# one the tool that owns it printed.
#
# THE UNREACHABILITY MECHANISM IS RATIFIED HERE, and it is narrower than
# "rename the whole checkout" on purpose. Renaming a hosted runner's own
# workspace out from under the shell that is running this script is a
# destructive act with no safe recovery if a single handle is open; what this
# gate does instead is rename aside, under a finally that restores
# unconditionally, EVERY directory of the checkout an SDK-driven build could
# resolve a framework input from:
#
#     build/cap10b1/sdk   the staged SDK root this distribution replaces
#     src                 the PWeb Pascal sources
#     sdk                 the two frontend SDKs
#     deps/mormot2        the framework a generated project compiles against
#     tools               the templates, the bundler sources, every script
#     examples            the only other tree carrying PWeb sources
#
# Every one of them is what a silently-checkout-resolving SDK would have
# reached, and each rename is one filesystem operation this script can undo.
# The rename is SUFFICIENT rather than necessary, and the claim that it is
# necessary is measured separately: CM4 requires that no stage command line
# names the repository root at all and that every unit and library path lies
# under the extracted root, which is the property the rename only
# demonstrates.
#
# Emits build/cap10d2/cli-<target>.json for the CAP-7F aggregation, plus
# build/cap10d2/sdk-corpus.txt (from the suite) and the packager's own
# summaries.
#
# Usage: pwsh test/cap10d2/run_cap10d2_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10d2'
New-Item -ItemType Directory -Force $work | Out-Null

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Key, [string]$Value) { $rows[$Key] = $Value }
function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        $failures.Add($Message)
        Write-Host "GATE FAILURE: $Message"
    }
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }
function Sha256File([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return (-join ($sha.ComputeHash($bytes) |
            ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
}
function TargetName {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'arm64' }
        default { 'other' }
    }
    return "$os-$arch"
}
$target = TargetName
Row 'target' $target
# EVERY per-target row is seeded, so a target that does not measure one emits
# `not_applicable` rather than nothing: the CAP-7F aggregator requires each of
# them PRESENT on all four, and an absent field and a measured absence are
# different facts. (The CAP-10D1 lesson, applied at the point a field is
# introduced rather than after a green run produced 124 disagreements.)
foreach ($seed in 'clean_machine_bin_mode', 'clean_machine_profile_result',
                  'clean_machine_react_build_exit',
                  'clean_machine_pas2js_build_exit', 'clean_machine_react_rpc',
                  'clean_machine_pas2js_rpc', 'clean_machine_doctor',
                  'sdk_tool_rule_decoy_build_exit') {
    Row $seed 'not_applicable'
}

# the pinned Pas2JS on PATH, deliberately and visibly, exactly as the
# CAP-10B2, C1, C3, D0 and D1 gates do it: the pipeline resolves tools on
# PATH by ratified design, and every CI job fetches the pinned compiler into
# deps/ without putting it there. THE SDK SHIPS NO COMPILER, so this is what
# a user of the distribution does too.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
}
Require ($null -ne (Get-Command pas2js -ErrorAction SilentlyContinue)) `
    'pas2js is not on PATH and no pinned copy exists under deps/'

$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$packager = Join-Path $work "bin/pwebsdk$exeSuffix"
$suite = Join-Path $work "bin/d2tests$exeSuffix"
$outDir = Join-Path $work 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
foreach ($pre in $packager, $suite, (Join-Path $sdk "bin/pweb$exeSuffix")) {
    Require (Test-Path -LiteralPath $pre) `
        "precondition absent: $pre -- run test/cap10d2/build_cap10d2 first"
}
if ($failures.Count -gt 0) {
    throw "CAP-10D2 preconditions FAILED: $($failures.Count)"
}

function RunTool([string]$Exe, [string[]]$ToolArgs, [string]$WorkDir,
                 [int]$TimeoutMs = 900000, [hashtable]$Extra = $null) {
    $so = Join-Path $work 'tool-stdout.txt'
    $se = Join-Path $work 'tool-stderr.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $p = Start-PWebProcess -FilePath $Exe -ArgumentList $ToolArgs -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        $p.WaitForExit(10000) | Out-Null
        Require $false "$Exe $($ToolArgs -join ' ') did not exit inside $TimeoutMs ms"
    }
    $p.WaitForExit()
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
        Err = if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    }
}
# the packager prints `key value` lines; this is the only reader of them
function KV([string]$Text) {
    $map = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^([a-z0-9_]+) (.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

# --- 1. the headless suite and its corpus ------------------------------------
# /noenter is the WINDOWS switch; the POSIX runner reads it as a FILENAME,
# prints its usage and exits 0 - a green verdict over nothing. So the option
# is passed on Windows only, and the corpus is REQUIRED to carry decisions.
$suiteLog = Join-Path $work 'd2tests.log'
$suiteArgs = if ($IsWindows) { @('/noenter') } else { @() }
$sp = Start-PWebProcess -FilePath $suite -ArgumentList $suiteArgs -Wait -PassThru `
    -NoNewWindow -WorkingDirectory $repoRoot -RedirectStandardOutput $suiteLog `
    -RedirectStandardError (Join-Path $work 'd2tests-stderr.log')
Write-Host ([System.IO.File]::ReadAllText($suiteLog))
Row 'sdk_suite' $(if ($sp.ExitCode -eq 0) { 'PASS' } else { 'FAIL' })
Require ($sp.ExitCode -eq 0) "the CAP-10D2 suite exited $($sp.ExitCode)"
$corpusPath = Join-Path $work 'sdk-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite wrote no corpus'
$corpusText = if (Test-Path $corpusPath) {
    [System.IO.File]::ReadAllText($corpusPath) } else { '' }
$corpusLines = @($corpusText -split "`n" |
    Where-Object { $_ -and (-not $_.StartsWith('#')) })
Row 'sdk_corpus_lines' "$($corpusLines.Count)"
Require ($corpusLines.Count -ge 60) `
    "the CAP-10D2 corpus carries $($corpusLines.Count) decisions; a corpus that thin measured nothing"
Row 'sdk_digest' (Sha256Text (($corpusLines -join "`n") + "`n"))

# --- 2. PK1: the packager, twice --------------------------------------------
$manifestPath = Join-Path $sdk 'share/pweb/sdk-manifest.json'
function Package([string]$SdkRoot, [string]$RepoRootArg, [string]$Out) {
    return RunTool $packager @('--sdk', $SdkRoot, '--repo', $RepoRootArg,
        '--out', $Out) $repoRoot 900000
}
$p1 = Package $sdk $repoRoot $outDir
Require ($p1.Code -eq 0) "PK1: the packager exited $($p1.Code): $($p1.Err)"
Write-Host $p1.Out
$k1 = KV $p1.Out
Row 'sdk_package_built' (Bool ($p1.Code -eq 0))
$archiveName = $k1['sdk_archive']
$archivePath = Join-Path $outDir $archiveName
Require (Test-Path -LiteralPath $archivePath) "PK1: no archive at $archivePath"
$m1 = Sha256File $manifestPath
$a1 = Sha256File $archivePath
$keep1 = Join-Path $work 'run1-manifest.json'
Copy-Item -Force -LiteralPath $manifestPath -Destination $keep1

$p2 = Package $sdk $repoRoot $outDir
Require ($p2.Code -eq 0) "PK1: the second packaging run exited $($p2.Code)"
$k2 = KV $p2.Out
$m2 = Sha256File $manifestPath
$a2 = Sha256File $archivePath
Row 'sdk_inventory_digest' $k1['sdk_inventory_digest']
Row 'sdk_manifest_deterministic' (Bool ($m1 -ceq $m2))
Row 'sdk_archive_deterministic' (Bool ($a1 -ceq $a2))
Row 'sdk_inventory_deterministic' (Bool (
    $k1['sdk_inventory_digest'] -ceq $k2['sdk_inventory_digest']))
Require ($m1 -ceq $m2) 'PK1: two packaging runs produced different manifests'
Require ($a1 -ceq $a2) 'PK1: two packaging runs produced different archives'
Require ($k1['sdk_inventory_digest'] -ceq $k2['sdk_inventory_digest']) `
    'PK1: two packaging runs produced different inventories'
Row 'sdk_ship_table_digest' $k1['sdk_ship_table_digest']
Row 'sdk_files' $k1['sdk_files']
Row 'sdk_licenses_count' $k1['sdk_licenses']
Row 'sdk_locks_count' $k1['sdk_locks']
Row 'sdk_archive_sha256' $a1
Row 'sdk_archive_bytes' $k1['sdk_archive_bytes']
Row 'sdk_manifest_sha256' $m1
Row 'sdk_manifest_schema' $k1['sdk_schema']
Row 'sdk_protocol' $k1['sdk_protocol']
Row 'sdk_version' $k1['sdk_version']
$integritySeconds = [math]::Round(
    ([double]$k1['sdk_integrity_ms']) / 1000.0, 3)
Row 'sdk_integrity_seconds' ($integritySeconds.ToString(
    [System.Globalization.CultureInfo]::InvariantCulture))
Require ($k1['sdk_target'] -ceq $target) `
    "PK1: the packager recorded target $($k1['sdk_target']) on $target"
Require ([int]$k1['sdk_locks'] -eq 6) `
    "PK1: $($k1['sdk_locks']) lock digests recorded; six locks are ratified"

# THE LOCKS THEMSELVES NEVER SHIP - docs/distribution-contract.md section 3.
# Measured on the manifest's own inventory rather than promised.
$manifestObj = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$shippedLocks = @($manifestObj.files | Where-Object { $_.path -like '*.lock' })
Row 'sdk_lock_files_shipped' "$($shippedLocks.Count)"
Require ($shippedLocks.Count -eq 0) `
    "PK1: $($shippedLocks.Count) lock FILE(s) reached the distribution"
$shippedPins = @($manifestObj.files |
    Where-Object { $_.path -like 'share/pweb/deps/innosetup/*' -or
                   $_.path -like 'share/pweb/deps/webview2-runtime/*' })
Row 'sdk_pinned_only_components_shipped' "$($shippedPins.Count)"
Require ($shippedPins.Count -eq 0) `
    'PK1: a pin-only component reached the distribution'
$shippedDrivers = @($manifestObj.files |
    Where-Object { $_.path -like 'bin/pwebpipe*' -or $_.path -like '*drv*' })
Row 'sdk_test_drivers_shipped' "$($shippedDrivers.Count)"
Require ($shippedDrivers.Count -eq 0) `
    'PK1: a private test driver reached the distribution'

# --- 3. PK4: no network during packaging ------------------------------------
# The same membership-scoped sampler the C0/C1/C2/C3/D0 gates use, never a
# lookup by process name. A sampler that never ran would report a vacuous 0,
# so its own liveness is a requirement.
$netSo = Join-Path $work 'net-pack-stdout.txt'
$netSe = Join-Path $work 'net-pack-stderr.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $netSo, $netSe
$np = Start-PWebProcess -FilePath $packager -PassThru -NoNewWindow `
    -ArgumentList @('--sdk', $sdk, '--repo', $repoRoot, '--out', $outDir) `
    -WorkingDirectory $repoRoot -RedirectStandardOutput $netSo `
    -RedirectStandardError $netSe
$netMax = 0
$netSamples = 0
$netMembers = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ((-not $np.HasExited) -and ($sw.ElapsedMilliseconds -lt 900000)) {
    Start-Sleep -Milliseconds 50
    $members = @(Get-PWebTreeMembers -RootPid $np.Id)
    if ($members.Count -gt $netMembers) { $netMembers = $members.Count }
    $netSamples++
    foreach ($m in $members) {
        $c = Get-PWebConnectionCount -OwnerPid $m
        if ($c -gt $netMax) { $netMax = $c }
    }
}
$np.WaitForExit()
Row 'packaging_network_calls' "$netMax"
Row 'packaging_sampler_samples' "$netSamples"
Row 'packaging_sampler_members' "$netMembers"
Require ($np.ExitCode -eq 0) "PK4: the sampled packaging run exited $($np.ExitCode)"
Require ($netSamples -ge 2) `
    "PK4: the network sampler took $netSamples samples -- a vacuous zero"
Require ($netMembers -ge 1) 'PK4: the sampler saw no process at all'
Require ($netMax -eq 0) `
    "PK4: packaging held $netMax network connection(s); it names no URL and must reach none"
# and the packager spawns NOTHING: one member, itself
Row 'packaging_children_spawned' (Bool ($netMembers -gt 1))
Require ($netMembers -eq 1) `
    "PK4: the packager's process tree grew to $netMembers members; a trusted build tool spawns nothing"

# --- 4. PK2: every refusal, on a fixture root -------------------------------
# A FIXTURE root rather than a copy of the real one: the real SDK root
# carries 500 MB of pinned Microsoft artifacts this shard deliberately does
# not ship, and copying them nine times to poison one file each would be
# nine minutes of a runner's life for no extra claim. The fixture is the same
# SHAPE - every component the ship table names, resolved - and its template
# pack is the real one, so the baseline packages successfully and each
# negative leg differs from it by exactly one poison.
$fixRoot = Join-Path $work 'fixroot'
$fixRepo = Join-Path $work 'fixrepo'
$fpcTarget = switch ($target) {
    'windows-x86_64' { 'x86_64-win64' }
    'linux-x86_64'   { 'x86_64-linux' }
    'macos-x86_64'   { 'x86_64-darwin' }
    default          { 'aarch64-darwin' }
}
function BuildFixtureRoot {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $fixRoot, $fixRepo
    $dirs = @('bin', 'share/pweb/src/lib', 'share/pweb/sdk/typescript',
        'share/pweb/sdk/pas2js', 'share/pweb/deps/mormot2/src/core',
        "share/pweb/deps/mormot2/static/$fpcTarget",
        "share/pweb/lib/$target", 'share/pweb/licenses')
    if ($IsWindows) {
        $dirs += @('share/pweb/deps/mormot2/static/delphi',
            'share/pweb/pack/setup', 'share/pweb/pack/bin',
            'share/pweb/pack/lib')
    }
    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Force (Join-Path $fixRoot $d) | Out-Null
    }
    $files = @("bin/pweb$exeSuffix", "bin/pwebbundle$exeSuffix",
        'share/pweb/src/lib/a.pas', 'share/pweb/sdk/typescript/package.json',
        'share/pweb/sdk/pas2js/pweb.native.pas',
        'share/pweb/deps/mormot2/src/core/mormot.core.base.pas',
        "share/pweb/deps/mormot2/static/$fpcTarget/x.a",
        "share/pweb/lib/$target/libx")
    if ($IsWindows) {
        $files += @('share/pweb/deps/mormot2/static/delphi/y.obj',
            'share/pweb/pack/setup/app-normal.iss',
            'share/pweb/pack/bin/pwebwv2prov.exe',
            'share/pweb/pack/lib/WebView2Loader.dll')
    }
    foreach ($f in $files) {
        [System.IO.File]::WriteAllText((Join-Path $fixRoot $f), 'x')
    }
    # the REAL pack, so the compiled registry's digest matches and the
    # baseline reaches the end of the tool rather than its template check
    Copy-Item -Force -LiteralPath (Join-Path $sdk 'share/pweb/pweb-templates.zip') `
        -Destination (Join-Path $fixRoot 'share/pweb/pweb-templates.zip')
    foreach ($lf in (Get-ChildItem -LiteralPath (Join-Path $sdk 'share/pweb/licenses') -File)) {
        Copy-Item -Force -LiteralPath $lf.FullName `
            -Destination (Join-Path $fixRoot "share/pweb/licenses/$($lf.Name)")
    }
    New-Item -ItemType Directory -Force $fixRepo | Out-Null
    foreach ($lock in 'fpc.lock', 'innosetup.lock', 'mormot.lock',
                      'pas2js.lock', 'webview.lock', 'webview2-runtime.lock') {
        Copy-Item -Force -LiteralPath (Join-Path $repoRoot $lock) `
            -Destination (Join-Path $fixRepo $lock)
    }
}
$fixOut = Join-Path $work 'fixout'
New-Item -ItemType Directory -Force $fixOut | Out-Null
BuildFixtureRoot
$base = Package $fixRoot $fixRepo $fixOut
Row 'pack_fixture_baseline' (Bool ($base.Code -eq 0))
Require ($base.Code -eq 0) `
    "PK2: the fixture baseline did not package: $($base.Err)"

$refusals = [ordered]@{}
function Refuses([string]$Name, [scriptblock]$Poison, [string]$WantCause) {
    BuildFixtureRoot
    & $Poison
    $r = Package $fixRoot $fixRepo $fixOut
    $cause = ''
    if ($r.Err -match 'pwebsdk: ([a-z0-9_]+):') { $cause = $Matches[1] }
    $refusals[$Name] = $cause
    Require ($r.Code -ne 0) "PK2: $Name was NOT refused (exit $($r.Code))"
    Require ($cause -ceq $WantCause) `
        "PK2: $Name refused with '$cause', expected '$WantCause'"
}
Refuses 'dotenv' {
    [System.IO.File]::WriteAllText(
        (Join-Path $fixRoot 'share/pweb/src/lib/.env'), 'TOKEN=1')
} 'sdk_secret_path'
Refuses 'credential_name' {
    [System.IO.File]::WriteAllText(
        (Join-Path $fixRoot 'share/pweb/src/lib/server.pem'), 'k')
} 'sdk_secret_path'
Refuses 'node_modules' {
    New-Item -ItemType Directory -Force `
        (Join-Path $fixRoot 'share/pweb/sdk/typescript/node_modules') | Out-Null
} 'sdk_secret_path'
Refuses 'build_output_in_source_tree' {
    [System.IO.File]::WriteAllText(
        (Join-Path $fixRoot 'share/pweb/src/lib/a.ppu'), 'o')
} 'sdk_build_output'
Refuses 'missing_component' {
    Remove-Item -Recurse -Force (Join-Path $fixRoot 'share/pweb/sdk/pas2js')
} 'sdk_component_missing'
Refuses 'missing_lock' {
    Remove-Item -Force (Join-Path $fixRepo 'mormot.lock')
} 'sdk_lock_missing'
Refuses 'missing_licence' {
    Remove-Item -Force (Join-Path $fixRoot 'share/pweb/licenses/LICENSE.mormot2.md')
} 'sdk_license_missing'
Refuses 'unratified_licence' {
    [System.IO.File]::WriteAllText(
        (Join-Path $fixRoot 'share/pweb/licenses/LICENSE.invented.txt'), 'x')
} 'sdk_license_unratified'
Refuses 'template_pack_mismatch' {
    [System.IO.File]::WriteAllText(
        (Join-Path $fixRoot 'share/pweb/pweb-templates.zip'), 'not the pack')
} 'sdk_template_pack_mismatch'
# a reparse point: a JUNCTION on Windows (which needs no privilege, unlike a
# symbolic link) and a symlink on POSIX. Both are pcnLink, and both are
# refused rather than followed - trusted build input is read, never resolved.
# A leg that could not arm itself is a FAILURE, never a silent pass.
BuildFixtureRoot
$linkMade = $false
$link = Join-Path $fixRoot 'share/pweb/src/linked'
try {
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $link `
        -Target (Join-Path $fixRoot 'share/pweb/sdk') -ErrorAction Stop | Out-Null
    $linkMade = Test-Path -LiteralPath $link
} catch {
    Write-Host "PK2: could not create a reparse point: $_"
}
Row 'pack_link_leg_armed' (Bool $linkMade)
Require $linkMade 'PK2: no reparse point could be created; the leg proved nothing'
if ($linkMade) {
    $r = Package $fixRoot $fixRepo $fixOut
    $cause = ''
    if ($r.Err -match 'pwebsdk: ([a-z0-9_]+):') { $cause = $Matches[1] }
    $refusals['reparse_point'] = $cause
    Require ($r.Code -ne 0) 'PK2: a reparse point was NOT refused'
    Require ($cause -ceq 'sdk_reparse_point') `
        "PK2: a reparse point refused with '$cause'"
}
Row 'pack_refusals' (($refusals.Keys | ForEach-Object {
    "$_=$($refusals[$_])" }) -join ',')
Row 'pack_refusal_count' "$($refusals.Count)"
BuildFixtureRoot

# --- 5. PK3: the licence set equals the documented shipped subset ------------
# docs/third-party-licenses.md carries a machine-readable shipped table; this
# reads it rather than restating it, so a component that gains or loses a
# notice fails here instead of shipping unremarked.
$licDoc = [System.IO.File]::ReadAllText(
    (Join-Path $repoRoot 'docs/third-party-licenses.md'))
$docRows = @()
foreach ($line in ($licDoc -split "`r?`n")) {
    if ($line -match '^\|\s*`([A-Za-z0-9._-]+)`\s*\|\s*([a-z0-9_, -]+?)\s*\|') {
        $docRows += [pscustomobject]@{ Name = $Matches[1]; Targets = $Matches[2].Trim() }
    }
}
# the document's three condition spellings, read rather than re-derived:
# `all`, `not <os>`, and an exact target name
$wantLicences = @($docRows | Where-Object {
        if ($_.Targets -ceq 'all') { return $true }
        if ($_.Targets -clike 'not *') {
            return -not $target.StartsWith($_.Targets.Substring(4))
        }
        return $_.Targets -ceq $target
    } | ForEach-Object { $_.Name } | Sort-Object)
$gotLicences = @($manifestObj.licenses | Sort-Object)
Row 'sdk_licenses_documented' ($wantLicences -join ',')
Row 'sdk_licenses_shipped' ($gotLicences -join ',')
Row 'sdk_licenses_complete' (Bool (
    ($wantLicences.Count -gt 0) -and
    (($wantLicences -join ',') -ceq ($gotLicences -join ','))))
Require ($wantLicences.Count -gt 0) `
    'PK3: docs/third-party-licenses.md carries no machine-readable shipped table'
Require (($wantLicences -join ',') -ceq ($gotLicences -join ',')) `
    "PK3: shipped licences [$($gotLicences -join ',')] != documented [$($wantLicences -join ',')]"
foreach ($l in $gotLicences) {
    $lp = Join-Path $sdk "share/pweb/licenses/$l"
    Require ((Test-Path -LiteralPath $lp) -and
        ((Get-Item -LiteralPath $lp).Length -gt 200)) `
        "PK3: $l is absent or implausibly short"
}

# --- 6. the extraction, to a path with a space and a non-ASCII character ----
$cleanBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else {
    [System.IO.Path]::GetTempPath() }
$cleanHome = Join-Path $cleanBase ([char]0x00E9 + 'tude sdk')
$cleanCwd = Join-Path $cleanBase ([char]0x00E9 + 'tude cwd')
# `tar` is the extractor on every target: it is in Windows' System32 since
# 10 1803, and one extraction rule beats three. On Windows it is resolved
# from the SYSTEM DIRECTORY by exact name and never through PATH - the same
# rule CAP-10D1 ratified for `expand.exe`, and for the same reason a
# developer machine makes visible: a Git or MSYS `tar` earlier on PATH is a
# different program that does not understand a Windows drive letter, and
# picking it up would make this leg fail for a reason that has nothing to do
# with the archive.
$tarExe = if ($IsWindows) {
    Join-Path $env:SystemRoot 'System32/tar.exe'
} else { 'tar' }
if ($IsWindows) {
    Require (Test-Path -LiteralPath $tarExe) `
        "the system tar is absent at $tarExe (Windows 10 1803 or later ships it)"
}
Row 'clean_machine_extractor' $(if ($IsWindows) { 'System32/tar.exe' } else { 'tar' })
function ResetExtraction {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $cleanHome
    New-Item -ItemType Directory -Force $cleanHome | Out-Null
    $t = RunTool $tarExe @('-xzf', $archivePath, '-C', $cleanHome) $repoRoot 600000
    Require ($t.Code -eq 0) "extraction failed: $($t.Err)"
}
ResetExtraction
$stem = [System.IO.Path]::GetFileName($archiveName) -replace '\.tar\.gz$', ''
$cleanSdk = Join-Path $cleanHome $stem
$cleanPweb = Join-Path $cleanSdk "bin/pweb$exeSuffix"
Row 'clean_machine_path' (Split-Path -Leaf $cleanHome)
Row 'clean_machine_path_has_space' (Bool ((Split-Path -Leaf $cleanHome) -like '* *'))
Row 'clean_machine_path_non_ascii' (Bool (
    ((Split-Path -Leaf $cleanHome).ToCharArray() |
        Where-Object { [int]$_ -gt 127 }).Count -gt 0))
Require (Test-Path -LiteralPath $cleanPweb) `
    "the extracted SDK has no bin/pweb at $cleanPweb"
if ($IsWindows) {
    # the extracted tree must be COMPLETE: the manifest is the inventory, and
    # the doctor below verifies it, but a missing executable would have made
    # every later leg a different failure
    Require (Test-Path -LiteralPath (Join-Path $cleanSdk 'share/pweb/pack/setup/app-normal.iss')) `
        'the extracted SDK carries no packaging kit'
} else {
    # POSIX: the archive's mode plane is the whole reason this writer exists.
    # Windows has none to read, so the row stays `not_applicable` there - a
    # measured absence rather than a missing field.
    $mode = (Get-Item -LiteralPath $cleanPweb).UnixMode
    Row 'clean_machine_bin_mode' "$mode"
    Require ("$mode" -match '^-rwxr-xr-x') `
        "the extracted bin/pweb arrived at mode '$mode', not 0755"
}
New-Item -ItemType Directory -Force $cleanCwd | Out-Null

function CleanCli([string[]]$CliArgs, [int]$TimeoutMs = 2400000,
                  [string]$Cwd = $cleanCwd) {
    return RunTool $cleanPweb $CliArgs $Cwd $TimeoutMs
}

# --- 7. IN1: the doctor on a pristine extracted SDK --------------------------
$doc = CleanCli @('doctor', '--json') 300000
$docObj = $null
try { $docObj = $doc.Out | ConvertFrom-Json } catch { }
Require ($null -ne $docObj) "IN1: the extracted doctor emitted no JSON: $($doc.Err)"
$sdkRows = @{}
if ($null -ne $docObj) {
    foreach ($c in $docObj.checks) {
        if ($c.id -like 'sdk.*') { $sdkRows[$c.id] = "$($c.status)/$($c.cause)" }
    }
    Row 'clean_machine_doctor_rows' (($docObj.checks |
        ForEach-Object { "$($_.id)=$($_.status)" }) -join ',')
}
Row 'sdk_doctor_manifest' "$($sdkRows['sdk.manifest'])"
Row 'sdk_doctor_integrity' "$($sdkRows['sdk.integrity'])"
Row 'sdk_doctor_version' "$($sdkRows['sdk.version'])"
Row 'sdk_integrity_pass_pristine' (Bool ("$($sdkRows['sdk.integrity'])" -ceq 'pass/ok'))
Require ("$($sdkRows['sdk.manifest'])" -ceq 'pass/ok') 'IN1: sdk.manifest did not pass'
Require ("$($sdkRows['sdk.integrity'])" -ceq 'pass/ok') 'IN1: sdk.integrity did not pass'
Require ("$($sdkRows['sdk.version'])" -ceq 'pass/ok') 'IN1: sdk.version did not pass'

# --- 8. IN2/IN3: tamper, and every wrong manifest ---------------------------
$probeRoot = Join-Path $cleanBase 'cap10d2 probe'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $probeRoot
New-Item -ItemType Directory -Force $probeRoot | Out-Null
$cr = CleanCli @('create', 'probe', '--ui', 'pas2js', '--bundle-id',
    'com.example.probe') 300000 $probeRoot
Require ($cr.Code -eq 0) "IN2: create in the probe root exited $($cr.Code): $($cr.Err)"
$probe = Join-Path $probeRoot 'probe'

function IntegrityLeg([string]$Name, [scriptblock]$Poison, [string]$WantCause) {
    ResetExtraction
    & $Poison
    $d = CleanCli @('doctor', '--json') 300000
    $o = $null
    try { $o = $d.Out | ConvertFrom-Json } catch { }
    $seen = ''
    if ($null -ne $o) {
        foreach ($c in $o.checks) {
            if (($c.id -like 'sdk.*') -and ($c.status -eq 'fail') -and ($seen -eq '')) {
                $seen = $c.cause
            }
        }
    }
    $b = CleanCli @('build', '--project', $probe) 600000
    $staged = Test-Path -LiteralPath (Join-Path $probe 'dist')
    $spawned = $b.Err -match '(?m)^pweb: toolchain: start'
    Write-Host "IN: $Name -> doctor '$seen', build exit $($b.Code)"
    Require ($seen -ceq $WantCause) `
        "IN: $Name doctor reported '$seen', expected '$WantCause'"
    Require ($b.Code -eq 4) "IN: $Name build exited $($b.Code), expected 4"
    Require (-not $staged) "IN: $Name staged output despite refusing"
    Require (-not $spawned) "IN: $Name entered the toolchain stage"
    return $seen
}
$manifestClean = Join-Path $cleanSdk 'share/pweb/sdk-manifest.json'
$tamperTarget = Join-Path $cleanSdk 'share/pweb/src/lib/pweb.lib.webview.pas'
Row 'in2_tampered_cause' (IntegrityLeg 'tampered_file' {
    $bytes = [System.IO.File]::ReadAllBytes($tamperTarget)
    # SAME LENGTH: only the digest can tell, which is the case a
    # length-only inventory would miss
    $bytes[10] = [byte](($bytes[10] + 1) % 256)
    [System.IO.File]::WriteAllBytes($tamperTarget, $bytes)
} 'sdk_integrity_mismatch')
Row 'in2_removed_cause' (IntegrityLeg 'removed_file' {
    Remove-Item -Force -LiteralPath $tamperTarget
} 'sdk_integrity_missing')
Row 'in3_malformed_cause' (IntegrityLeg 'malformed_manifest' {
    [System.IO.File]::WriteAllText($manifestClean, '{ this is not a manifest')
} 'sdk_manifest_malformed')
Row 'in3_schema_cause' (IntegrityLeg 'wrong_schema' {
    $t = [System.IO.File]::ReadAllText($manifestClean)
    [System.IO.File]::WriteAllText($manifestClean,
        ($t -replace '"schema": 1,', '"schema": 2,'))
} 'sdk_manifest_schema')
Row 'in3_version_cause' (IntegrityLeg 'wrong_version' {
    $t = [System.IO.File]::ReadAllText($manifestClean)
    [System.IO.File]::WriteAllText($manifestClean,
        ($t -replace '"pweb": "[0-9.]+",', '"pweb": "9.9.9",'))
} 'sdk_version_mismatch')
Row 'in3_noncanonical_cause' (IntegrityLeg 'noncanonical_manifest' {
    $t = [System.IO.File]::ReadAllText($manifestClean)
    [System.IO.File]::WriteAllText($manifestClean, ' ' + $t)
} 'sdk_manifest_noncanonical')
Row 'sdk_integrity_fail_tampered' (Bool (
    "$($rows['in2_tampered_cause'])" -ceq 'sdk_integrity_mismatch'))
# and an SDK with NO manifest is an unpackaged root, not a refusal
ResetExtraction
Remove-Item -Force -LiteralPath $manifestClean
$d = CleanCli @('doctor', '--json') 300000
$o = $null
try { $o = $d.Out | ConvertFrom-Json } catch { }
$unp = ''
if ($null -ne $o) {
    foreach ($c in $o.checks) { if ($c.id -eq 'sdk.integrity') { $unp = "$($c.status)/$($c.cause)" } }
}
Row 'sdk_absent_manifest_row' $unp
Require ($unp -ceq 'not_applicable/sdk_unpackaged') `
    "IN3: an SDK with no manifest reported '$unp'"
ResetExtraction

# --- 9. CM: the clean machine -----------------------------------------------
# the pinned packaging inputs, placed under the extracted root exactly as a
# developer places them after running the provisioning scripts. THE SDK DOES
# NOT SHIP THEM: 523 MB of Microsoft and jrsoftware material under their own
# terms, and `pweb build --profile` refuses by name when they are absent.
$profilesForTarget = if ($IsWindows) { 'normal,offline,fixed-runtime' } else { 'archive' }
Row 'profiles_for_target' $profilesForTarget
if ($IsWindows) {
    foreach ($pin in 'innosetup', 'webview2-runtime') {
        $src = Join-Path $sdk "share/pweb/deps/$pin"
        if (Test-Path -LiteralPath $src) {
            Copy-Item -Recurse -Force -LiteralPath $src `
                -Destination (Join-Path $cleanSdk 'share/pweb/deps')
        }
    }
}

$asideNames = @('build/cap10b1/sdk', 'src', 'sdk', 'deps/mormot2', 'tools',
    'examples')
$aside = @()
$cmDone = $false
try {
    foreach ($rel in $asideNames) {
        $from = Join-Path $repoRoot $rel
        if (Test-Path -LiteralPath $from) {
            $to = "$from.d2aside"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $to
            Rename-Item -LiteralPath $from -NewName (Split-Path -Leaf $to)
            $aside += [pscustomobject]@{ From = $from; To = $to; Rel = $rel }
        }
    }
    # the RELATIVE names, because `build/cap10b1/sdk` and `sdk` have the same
    # leaf and a reader of the evidence has to be able to tell them apart
    Row 'checkout_renamed_aside' (($aside | ForEach-Object { $_.Rel }) -join ',')
    Require ($aside.Count -eq $asideNames.Count) `
        "CM: only $($aside.Count) of $($asideNames.Count) checkout trees were renamed aside"

    # CM6 (runtime): an exported root variable changes NOTHING
    $env:PWEB_SDK = Join-Path $cleanBase 'not-an-sdk'
    $env:PWEB_HOME = $env:PWEB_SDK
    $env:PWEB_MORMOT = $env:PWEB_SDK
    $env:PWEB_TEMPLATES = $env:PWEB_SDK

    # THE PROJECTS LIVE AT A SPACED path, not a non-ASCII one, and the split
    # is a MEASUREMENT rather than a preference. The brief asks for the SDK to
    # be extracted to a path with a space and a non-ASCII character, and it
    # is - `<temp>/<e-acute>tude sdk/`, above. The PROJECT path is the one
    # CAP-10D0 and CAP-10D1 ratified as spaced, and it stays spaced here for
    # a reason this leg found: `pwebbundle`, the FROZEN CAP-6 bundler, reads
    # its argv through the RTL's ANSI conversion on Windows, so a project
    # root carrying a non-ASCII character reaches it as `?tude apps` and the
    # `pack` stage fails with `dist directory not found`. That is a real
    # limitation of a frozen program, it is ledgered with its owner, and it
    # is not this shard's to fix - but a gate that quietly demanded it would
    # be measuring CAP-6 rather than the SDK distribution.
    $projRoot = Join-Path $cleanBase 'cap10d2 apps'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $projRoot
    New-Item -ItemType Directory -Force $projRoot | Out-Null
    $cmdLines = New-Object System.Collections.Generic.List[string]
    $cmDoctorStatus = @{}
    foreach ($ui in 'react', 'pas2js') {
        $name = "demo$ui"
        $c = CleanCli @('create', $name, '--ui', $ui, '--bundle-id',
            "com.example.$name") 600000 $projRoot
        Require ($c.Code -eq 0) "CM: create --ui $ui exited $($c.Code): $($c.Err)"
        $proj = Join-Path $projRoot $name
        # THE DOCTOR, on a REAL project, from the extracted SDK, with the
        # checkout aside. Without a project the graph reports
        # project.descriptor absent and nothing below it, which is a
        # diagnosis of the working directory rather than of the SDK.
        $d = CleanCli @('doctor', '--json', '--project', $proj) 300000
        $o = $null
        try { $o = $d.Out | ConvertFrom-Json } catch { }
        $cmDoctor = 'unparsed'
        if ($null -ne $o) {
            $cmDoctor = $o.status
            Row "clean_machine_doctor_${ui}_rows" (($o.checks |
                ForEach-Object { "$($_.id)=$($_.status)/$($_.cause)" }) -join ',')
        }
        $cmDoctorStatus[$ui] = $cmDoctor
        # THE ASSERTION IS THE PIPELINE'S RULE, NOT THE DOCTOR'S OVERALL
        # STATUS, and the difference is a ratified one. `platform.webview`
        # asks whether this machine can DISPLAY a WebView, and CAP-10C1
        # (ledger C1-15) measured hosted macOS runners answering
        # `framework_absent` on machines where the same projects build and
        # run - so `FirstRequiredFailure` excludes that row from the BUILD
        # verdict by name. A gate that required the doctor's overall status
        # to be pass would be re-imposing exactly the requirement CAP-10C1
        # removed. The row is still RECORDED, per target, in the rows field
        # above; what is REQUIRED here is that no OTHER required row failed.
        $blocking = @()
        if ($null -ne $o) {
            foreach ($c in $o.checks) {
                if (($c.severity -eq 'required') -and ($c.status -eq 'fail') -and
                    ($c.id -ne 'platform.webview')) {
                    $blocking += "$($c.id)=$($c.cause)"
                }
            }
        }
        Require (($null -ne $o) -and ($blocking.Count -eq 0)) `
            ("CM1: the doctor on the extracted SDK failed a build-blocking row " +
             "for the $ui project with the checkout aside: [$($blocking -join ',')]")
        $b = CleanCli @('build', '--project', $proj) 2400000
        Row "clean_machine_${ui}_build_exit" "$($b.Code)"
        # BOTH STREAMS on a failure. The pipeline's own lines go to stderr
        # and every FORWARDED child line - the compiler's, the bundler's -
        # goes to stdout, so a gate that printed only stderr reports
        # `stage_exited 1` and throws away the sentence that says why. It
        # cost a hosted macOS run to learn that once.
        if ($b.Code -ne 0) {
            Write-Host "----- CM $ui build (stdout, the children's own lines) -----"
            Write-Host $b.Out
        }
        Require ($b.Code -eq 0) "CM: the $ui build exited $($b.Code): $($b.Err)"
        foreach ($line in ($b.Err -split "`r?`n")) {
            if ($line -match '^pweb: (open|toolchain|stage_sdk|install|typecheck|build|pack|compile|layout|verify): (.+)$') {
                $cmdLines.Add($line)
            }
        }
        # run it, from an unrelated working directory, with the extracted
        # bin/ NOT on PATH
        $so = Join-Path $work "cm-run-$ui-stdout.txt"
        $se = Join-Path $work "cm-run-$ui-stderr.txt"
        Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
        $env:PWEB_SMOKE_AUTOCLOSE_MS = '20000'
        $rp = Start-PWebProcess -FilePath $cleanPweb -PassThru -NoNewWindow `
            -ArgumentList @('run', '--project', $proj) `
            -WorkingDirectory $cleanCwd -RedirectStandardOutput $so `
            -RedirectStandardError $se
        if (-not $rp.WaitForExit(180000)) {
            try { $rp.Kill() } catch { }
            $rp.WaitForExit(10000) | Out-Null
            Require $false "CM: the $ui run did not exit inside 180 s"
        }
        $rp.WaitForExit()
        Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
        $rout = if (Test-Path $so) { [System.IO.File]::ReadAllText($so) } else { '' }
        $rerr = if (Test-Path $se) { [System.IO.File]::ReadAllText($se) } else { '' }
        Write-Host "----- CM $ui run (stdout) -----"; Write-Host $rout
        Write-Host "----- CM $ui run (stderr) -----"; Write-Host $rerr
        $value = -1
        foreach ($line in ($rout -split "`n")) {
            if ($line -match '^\w+: ready (\{.*\})\s*$') {
                $value = ($Matches[1] | ConvertFrom-Json).value
            }
        }
        Row "clean_machine_${ui}_rpc" "$value"
        Require ($value -eq 42) "CM: the $ui application answered $value, not 42"

        # CM3: the target's profiles, from the extracted SDK
        if ($ui -eq 'pas2js') {
            $profileResults = @()
            foreach ($profile in ($profilesForTarget -split ',')) {
                $pr = CleanCli @('build', '--project', $proj, '--profile',
                    $profile) 3000000
                $profileResults += "$profile=$($pr.Code)"
                if ($pr.Code -ne 0) {
                    Write-Host "----- CM3 $profile (stdout, the children's own lines) -----"
                    Write-Host $pr.Out
                }
                Require ($pr.Code -eq 0) `
                    "CM3: --profile $profile from the extracted SDK exited $($pr.Code): $($pr.Err)"
                foreach ($line in ($pr.Err -split "`r?`n")) {
                    if ($line -match '^pweb: (open|toolchain|stage_sdk|install|typecheck|build|pack|compile|layout|verify): (.+)$') {
                        $cmdLines.Add($line)
                    }
                }
            }
            Row 'clean_machine_profile_result' ($profileResults -join ',')
        }
    }

    # CM4: no spawned command line names the checkout, and every unit and
    # library path lies under the extracted root. The pipeline redacts its
    # OWN roots to <project> and <sdk>; anything else would appear raw, which
    # is exactly what makes this measurable.
    $cmdText = ($cmdLines -join "`n")
    [System.IO.File]::WriteAllText((Join-Path $work 'cm-commands.txt'),
        $cmdText + "`n")
    $repoLeaf = Split-Path -Leaf $repoRoot
    $checkoutHits = 0
    foreach ($line in $cmdLines) {
        if (($line -match [regex]::Escape($repoRoot)) -or
            ($line -match [regex]::Escape($repoRoot.Replace('\', '/')))) {
            $checkoutHits++
            Write-Host "CM4 CHECKOUT PATH: $line"
        }
    }
    Row 'checkout_path_in_argv' "$checkoutHits"
    Require ($checkoutHits -eq 0) `
        "CM4: $checkoutHits spawned command line(s) named the checkout"
    $badUnit = 0
    $unitPaths = 0
    foreach ($line in $cmdLines) {
        foreach ($m in [regex]::Matches($line, '-F[uliE]([^\s]+)')) {
            $p = $m.Groups[1].Value
            $unitPaths++
            if (-not (($p -like '<sdk>*') -or ($p -like '<project>*') -or
                      ($p -like '<*>*'))) {
                $badUnit++
                Write-Host "CM4 UNIT PATH OUTSIDE THE SDK: $p"
            }
        }
    }
    Row 'unit_paths_seen' "$unitPaths"
    Row 'unit_paths_under_sdk' (Bool ($badUnit -eq 0))
    Require ($unitPaths -ge 8) `
        "CM4: only $unitPaths unit/library paths were observed; the capture measured nothing"
    Require ($badUnit -eq 0) `
        "CM4: $badUnit unit/library path(s) resolved outside the extracted SDK"

    # CM5: the SDK-shipped tool rule. `pwebbundle` is resolved from the SDK
    # root and PATH is never consulted for it; a decoy of the same name
    # earlier on PATH changes nothing.
    $decoy = Join-Path $cleanBase 'cap10d2 decoy'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $decoy
    New-Item -ItemType Directory -Force $decoy | Out-Null
    $decoyBundler = Join-Path $decoy "pwebbundle$exeSuffix"
    if ($IsWindows) {
        [System.IO.File]::WriteAllText($decoyBundler, 'not an executable')
    } else {
        [System.IO.File]::WriteAllText($decoyBundler, "#!/bin/sh`nexit 7`n")
        chmod +x $decoyBundler
    }
    $savedPath = $env:PATH
    $env:PATH = $decoy + [System.IO.Path]::PathSeparator + $env:PATH
    $proj = Join-Path $projRoot 'demopas2js'
    $bd = CleanCli @('build', '--project', $proj) 1800000
    $env:PATH = $savedPath
    Row 'sdk_tool_rule_decoy_build_exit' "$($bd.Code)"
    Require ($bd.Code -eq 0) `
        "CM5: a decoy pwebbundle on PATH changed the build (exit $($bd.Code))"
    Row 'sdk_shipped_tool_rule' 'sdk_root_only:pwebbundle,iscc|path_only:fpc,node,pas2js'
    Row 'clean_machine_doctor' (($cmDoctorStatus.Keys | Sort-Object |
        ForEach-Object { "$_=$($cmDoctorStatus[$_])" }) -join ',')
    $cmDone = $true
}
finally {
    foreach ($a in $aside) {
        if (Test-Path -LiteralPath $a.To) {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $a.From
            Rename-Item -LiteralPath $a.To -NewName (Split-Path -Leaf $a.From)
        }
    }
    Remove-Item Env:PWEB_SDK, Env:PWEB_HOME, Env:PWEB_MORMOT, Env:PWEB_TEMPLATES `
        -ErrorAction SilentlyContinue
}
Row 'clean_machine_completed' (Bool $cmDone)
Require $cmDone 'CM: the clean-machine legs did not complete'
foreach ($rel in $asideNames) {
    Require (Test-Path -LiteralPath (Join-Path $repoRoot $rel)) `
        "CM: the checkout tree '$rel' was not restored"
}
Row 'checkout_restored' 'true'
Row 'env_root_variables_read' '0'

# --- 10. CL: the closure ------------------------------------------------------
$ledger = RunTool 'pwsh' @('-NoProfile', '-File',
    (Join-Path $repoRoot 'test/cap10d2/check_cap10_ledger.ps1')) $repoRoot 600000
Write-Host $ledger.Out
Write-Host $ledger.Err
Row 'cap10_ledger_gate' $(if ($ledger.Code -eq 0) { 'PASS' } else { 'FAIL' })
Require ($ledger.Code -eq 0) 'CL3: the phase-wide ledger gate failed'
$ledgerJson = Join-Path $work 'ledger.json'
if (Test-Path -LiteralPath $ledgerJson) {
    $lj = Get-Content -LiteralPath $ledgerJson -Raw | ConvertFrom-Json
    Row 'cap10_ledger_orphans' "$($lj.ledger_orphans)"
    Row 'cap10_ledger_entries' "$($lj.ledger_entries)"
    Row 'cap10_spec_acceptance_lines_met' "$($lj.spec_lines_met)"
    Row 'cap10_spec_acceptance_lines_deviated' "$($lj.spec_lines_deviated)"
    Row 'cap10_runs_cited' "$($lj.hosted_runs_cited)"
} else {
    Row 'cap10_ledger_orphans' 'unmeasured'
}
Row 'c1_11_c_closed' (Bool ($corpusText -match 'c1_11_c_reemitter_canonical\|true'))
Require ($corpusText -match 'c1_11_c_reemitter_canonical\|true') `
    'C1-11 (c): the suite recorded no closure decision'

# --- 11. the verdict and the evidence ----------------------------------------
Row 'sdk_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
Row 'github_sha' "$env:GITHUB_SHA"
Row 'github_run_id' "$env:GITHUB_RUN_ID"
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($rows | ConvertTo-Json -Depth 6)
Write-Host "[CAP-10D2] evidence written to $evidence"
if ($failures.Count -gt 0) {
    Write-Host "[CAP-10D2] $($failures.Count) FAILURE(S):"
    foreach ($f in $failures) { Write-Host "  - $f" }
    throw "CAP-10D2 gates FAILED: $($failures.Count)"
}
Write-Host '[CAP-10D2] all gates PASS'
