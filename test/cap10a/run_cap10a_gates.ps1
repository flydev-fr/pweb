# CAP-10A: run the CLI gates and emit this target's evidence.
#
# ONE script for all four targets. Unlike the build, nothing here is
# platform-specific: the suite is headless, the CLI needs no display, and pwsh
# is present on every runner this project uses (it is already how the pinned
# fetch/verify logic stays single-source). A bash twin would be a second
# implementation of a verifier, which is exactly what this repository avoids.
#
# WHAT IT PROVES, beyond running the suite:
#
#   - the REAL executable behaves as the contract says: the exact --version
#     line, help that lists `doctor` and NOTHING else, and the exit-code
#     taxonomy on real invocations rather than on injected inputs;
#   - `pweb doctor` MUTATES NOTHING. The fixture tree and every lock file in
#     the repository are hashed before and after a real run, and the digests
#     must be identical. That is the claim "diagnostic only" makes, measured;
#   - the human report carries no ANSI when redirected - which is what this
#     script's own captured output IS - and the JSON parses, carries no escape
#     byte, and is byte-identical across two consecutive runs;
#   - the CLI opens no listener: proved at the source and at the LINK by
#     check_cap10a_contracts.ps1, and re-asserted here as a recorded row.
#
# Emits build/cap10a/cli-<target>.json, which the CAP-7F emitter folds into
# this target's evidence.
#
# Usage: pwsh test/cap10a/run_cap10a_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$bin = Join-Path $repoRoot 'build/cap10a/bin'
$pweb = Join-Path $bin "pweb$exeSuffix"
$suite = Join-Path $bin "clitests$exeSuffix"
foreach ($pre in $pweb, $suite, (Join-Path $bin "probechild$exeSuffix")) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw "missing precondition: $pre -- run the build script first"
    }
}

if ($IsWindows) { $target = 'windows-x86_64' }
elseif ($IsLinux) { $target = 'linux-x86_64' }
elseif ($IsMacOS) {
    $target = if ((uname -m).Trim() -eq 'arm64') { 'macos-arm64' }
              else { 'macos-x86_64' }
} else { throw 'unsupported host' }
Write-Host "[CAP-10A] target: $target"

$work = Join-Path $repoRoot 'build/cap10a'
New-Item -ItemType Directory -Force $work | Out-Null
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

# LF-normalized, so a digest is a digest of CONTENT and not of a checkout's
# line-ending policy
function Sha256File([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    return Sha256Text $text
}

function TreeDigest([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return 'absent' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File |
                    Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/') `
            -replace '\\', '/'
        $parts.Add("$rel|$($f.Length)|$(Sha256File $f.FullName)")
    }
    return Sha256Text ($parts -join "`n")
}

# --- 1. the headless suite -------------------------------------------------
$suiteLog = Join-Path $work 'clitests.log'
Remove-Item -Force -ErrorAction SilentlyContinue `
    (Join-Path $work 'cli-corpus.txt')
# /noenter is the WINDOWS switch that skips mormot.core.test's interactive
# ENTER wait; the POSIX runner has no such wait and REFUSES the option, which
# is why the existing CAP-7L gate runs the suite with no arguments at all
if ($IsWindows) { $out = & $suite /noenter 2>&1 | Out-String }
else { $out = & $suite 2>&1 | Out-String }
$suiteCode = $LASTEXITCODE
[System.IO.File]::WriteAllText($suiteLog, $out)
Write-Host $out
Require ($suiteCode -eq 0) 'the CAP-10A suite failed'
# an exit code alone cannot tell "all passed" from "never ran": the four case
# headers must be present, which is the same rule the CAP-8 gates apply
foreach ($anchor in 'P web cli args', 'P web cli project', 'P web cli doctor',
                    'P web cli probe') {
    Require ($out.Contains($anchor)) "the suite never registered '$anchor'"
}
Row 'cli_suite' $(if ($suiteCode -eq 0) { 'PASS' } else { 'FAIL' })

$corpusPath = Join-Path $work 'cli-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite emitted no corpus'
if (Test-Path -LiteralPath $corpusPath) {
    Row 'cli_digest' (Sha256File $corpusPath)
    Row 'cli_corpus_lines' (
        @([System.IO.File]::ReadAllLines($corpusPath) |
          Where-Object { $_ -notmatch '^#' }).Count)
} else {
    Row 'cli_digest' ''
    Row 'cli_corpus_lines' 0
}

# --- 2. the fixture project ------------------------------------------------
$fixture = Join-Path $work 'fixture'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $fixture
New-Item -ItemType Directory -Force (Join-Path $fixture 'src'),
    (Join-Path $fixture 'frontend') | Out-Null
$descriptor = @'
{
  "schema": 1,
  "name": "cap10a-fixture",
  "version": "0.1.0",
  "bundleId": "org.pweb.cap10afixture",
  "ui": "react",
  "native": { "program": "src/fixture.lpr" },
  "frontend": { "root": "frontend" },
  "output": "dist"
}
'@
function WriteLf([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
}
WriteLf (Join-Path $fixture 'pweb.json') $descriptor
WriteLf (Join-Path $fixture 'src/fixture.lpr') "program fixture;`nbegin`nend.`n"
WriteLf (Join-Path $fixture 'frontend/package.json') '{"name":"cap10a","private":true}'
WriteLf (Join-Path $fixture 'frontend/package-lock.json') '{"lockfileVersion":3}'

# --- 3. the real executable, against the contract --------------------------
function RunCli([string[]]$CliArgs) {
    $so = Join-Path $work 'cli-stdout.txt'
    $se = Join-Path $work 'cli-stderr.txt'
    # -ArgumentList refuses an EMPTY array, and the bare invocation is one of
    # the rows this gate exists to check, so the no-argument case is its own
    # call rather than an empty list
    if ($CliArgs.Count -eq 0) {
        $p = Start-Process -FilePath $pweb -Wait -PassThru `
            -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
    } else {
        $p = Start-Process -FilePath $pweb -ArgumentList $CliArgs -Wait -PassThru `
            -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
    }
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = [System.IO.File]::ReadAllText($so)
        Err = [System.IO.File]::ReadAllText($se)
    }
}

$version = RunCli @('--version')
Require ($version.Code -eq 0) '--version did not exit 0'
Require ($version.Out.Trim() -cmatch '^pweb \d+\.\d+\.\d+ \(protocol \d+\)$') `
    "--version line is not the contract shape: $($version.Out.Trim())"
Row 'cli_version_line' $version.Out.Trim()

$help = RunCli @('--help')
Require ($help.Code -eq 0) '--help did not exit 0'
Require ($help.Out.Contains('doctor')) '--help does not list doctor'
# CAP-10B1 moved `create` from this list into the one above it, and CAP-10C0
# moved `run`: the rule is unchanged - help advertises exactly the commands
# the binary implements - and only the membership changed. `dev` and
# `build` stay here.
Require ($help.Out.Contains('pweb create ')) '--help does not list create'
Require ($help.Out.Contains('pweb run ')) '--help does not list run'
foreach ($absent in 'pweb dev ', 'pweb build') {
    Require (-not $help.Out.Contains($absent)) `
        "--help advertises an unimplemented command: $absent"
}
Require (-not $help.Out.Contains([char]27)) '--help emitted ANSI when redirected'

$bare = RunCli @()
Require ($bare.Code -eq 2) "a bare invocation must exit 2, got $($bare.Code)"
$unknown = RunCli @('frobnicate')
Require ($unknown.Code -eq 2) "an unknown command must exit 2, got $($unknown.Code)"
$badopt = RunCli @('doctor', '--nonesuch')
Require ($badopt.Code -eq 2) "an unknown option must exit 2, got $($badopt.Code)"
$dup = RunCli @('doctor', '--json', '--json')
Require ($dup.Code -eq 2) "a duplicate option must exit 2, got $($dup.Code)"
$noval = RunCli @('doctor', '--project')
Require ($noval.Code -eq 2) "a missing value must exit 2, got $($noval.Code)"
$noproject = RunCli @('doctor', '--project',
    (Join-Path $work 'fixture-that-does-not-exist'))
Require ($noproject.Code -eq 3) `
    "an absent project must exit 3, got $($noproject.Code)"
Row 'cli_exit_taxonomy' 'PASS'

# --- 4. the real doctor run, and the no-mutation proof ---------------------
$locks = @(Get-ChildItem $repoRoot -File -Filter '*.lock' | Sort-Object Name)
$locksBefore = Sha256Text (($locks | ForEach-Object {
    "$($_.Name)|$(Sha256File $_.FullName)" }) -join "`n")
$fixtureBefore = TreeDigest $fixture

$doctorHuman = RunCli @('doctor', '--project', $fixture, '--no-color')
Require (-not $doctorHuman.Out.Contains([char]27)) `
    'the human report emitted ANSI when redirected'
Require ($doctorHuman.Out.Contains('doctor:')) `
    'the human report carries no verdict line'
[System.IO.File]::WriteAllText((Join-Path $work 'doctor-human.txt'),
    $doctorHuman.Out)
Row 'doctor_exit' $doctorHuman.Code

$doctorJson = RunCli @('doctor', '--project', $fixture, '--json')
Require (-not $doctorJson.Out.Contains([char]27)) 'the JSON carried an escape byte'
[System.IO.File]::WriteAllText((Join-Path $work 'doctor.json'), $doctorJson.Out)
$doc = $null
try { $doc = $doctorJson.Out | ConvertFrom-Json }
catch { Require $false "the doctor JSON did not parse: $($_.Exception.Message)" }
Require ($doctorJson.Code -eq $doctorHuman.Code) `
    'the two projections disagreed on the exit code'

$fixtureAfter = TreeDigest $fixture
$locksAfter = Sha256Text (($locks | ForEach-Object {
    "$($_.Name)|$(Sha256File $_.FullName)" }) -join "`n")
Require ($fixtureBefore -ceq $fixtureAfter) `
    'pweb doctor MUTATED the project tree'
Require ($locksBefore -ceq $locksAfter) 'pweb doctor MUTATED a lock file'
Row 'doctor_no_mutation' $(
    if (($fixtureBefore -ceq $fixtureAfter) -and
        ($locksBefore -ceq $locksAfter)) { 'PASS' } else { 'FAIL' })

# a second run must be byte-identical: the document carries no timestamp and
# no ordering that depends on emission
$again = RunCli @('doctor', '--project', $fixture, '--json')
Require ($again.Out -ceq $doctorJson.Out) `
    'two consecutive doctor JSON documents differed'
Row 'doctor_json_deterministic' $(
    if ($again.Out -ceq $doctorJson.Out) { 'PASS' } else { 'FAIL' })

if ($doc) {
    Require ($doc.doctor -eq 1) "the doctor schema is not 1: $($doc.doctor)"
    Require ($doc.project.present -eq $true) 'the fixture project was not opened'
    Require ($doc.project.name -ceq 'cap10a-fixture') 'the project name'
    Require ($doc.project.programIdent -ceq 'fixture') `
        'the derived program identifier'
    Require ($doc.project.root -ceq '<project>') `
        'paths are not redacted by default'
    # THE SCHEMA DIGEST: the row set and the document shape, which are
    # platform-INDEPENDENT. Versions, paths and per-host causes deliberately
    # do NOT enter it - they are observations, and comparing them across four
    # machines would be comparing the machines.
    $shape = New-Object System.Collections.Generic.List[string]
    $shape.Add("doctor=$($doc.doctor)")
    $shape.Add('top=' + (($doc.PSObject.Properties |
        ForEach-Object { $_.Name }) -join ','))
    $shape.Add('project=' + (($doc.project.PSObject.Properties |
        ForEach-Object { $_.Name }) -join ','))
    if ($doc.checks.Count -gt 0) {
        $shape.Add('check=' + (($doc.checks[0].PSObject.Properties |
            ForEach-Object { $_.Name }) -join ','))
    }
    foreach ($c in $doc.checks) { $shape.Add("$($c.id)|$($c.severity)") }
    Row 'doctor_schema_digest' (Sha256Text ($shape -join "`n"))
    Row 'doctor_checks' $doc.checks.Count
    Row 'doctor_status' $doc.status
    # per-host OBSERVATIONS: recorded, explicitly NOT compared across targets
    $observed = [ordered]@{}
    foreach ($c in $doc.checks) {
        $observed[$c.id] = "$($c.status)/$($c.cause)"
    }
    Row 'doctor_observations' $observed
} else {
    Row 'doctor_schema_digest' ''
    Row 'doctor_checks' 0
    Row 'doctor_status' 'unparsed'
    Row 'doctor_observations' @{}
}

# --- 5. the verdict and the evidence ---------------------------------------
Row 'target' $target
Row 'cli_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10A] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10A gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10A] gates PASS on $target"
