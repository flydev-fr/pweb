# CAP-6b1 AUTHORITATIVE clean-machine provisioning gate. This is the
# one proof CI can never give: on a machine WITHOUT a usable WebView2
# runtime and WITH network, the normal setup must verifiably execute
# the embedded lock-verified Evergreen Bootstrapper and end with a
# usable runtime and a working installed app. It runs on a disposable
# instance (Windows Sandbox is the ratified candidate - verify WebView2
# absence at gate time - otherwise a throwaway VM image) and is NEVER
# mocked: this script refuses to run under CI.
#
# Transport to the instance (from a repo where the build gates ran):
#   dist/windows/normal/PWebRelease-Normal-Setup.exe
#   build/cap6b1/bin/pwebwv2prov.exe
#   build/cap6b1/lockfacts.psd1
#   build/cap6b1/payload/        (the staged release triple: the
#                                 BEFORE-phase app-refusal proof runs
#                                 releaseapp.exe from here, pre-setup)
#   this script
# then: pwsh -File run_clean_machine_gate.ps1 -SetupExe <path>
#         -Helper <path> -LockFacts <path> -PayloadDir <dir>
#         [-EvidenceDir <dir>]
#
# Phases (all recorded in the evidence transcript):
#   BEFORE  helper probe with a dummy payload (execution impossible by
#           construction) must report the detector NOT AlreadyUsable -
#           otherwise this is not a clean machine and the gate refuses;
#           then the STAGED releaseapp.exe (payload dir, pre-setup)
#           must refuse with the distinct 'WEBVIEW2 RUNTIME UNUSABLE'
#           stderr marker and a nonzero exit - the CAP-6b1 defensive
#           check observed on a genuinely runtime-less machine
#   SETUP   silent install with /LOG; the ratified flow inside setup
#           verifies sha256 + Authenticode and executes the
#           Bootstrapper; setup exit must be 0 and the log must show
#           WV2PROV_EXEC (it really ran) and outcome=Provisioned
#   AFTER   helper probe again: decision=AlreadyUsable required (the
#           mandatory re-probe invariant, observed independently)
#   APP     the installed releaseapp.exe runs from an unrelated CWD
#           and prints the CAP-6 42 PASS marker
#
# Evidence transcript format (build/cap6b1/clean-machine/evidence.log,
# committed with the artifact by the ratifying human). The transcript
# ALWAYS ends in exactly one verdict line, even when a phase throws:
#   CAP6B1_EVIDENCE_BEGIN <utc timestamp> host=<name>
#   BEFORE <full helper output>
#   BEFORE_APP exit=<code> marker=<found|missing>
#   SETUP exit=<code> log=<setup log copied beside the transcript>
#   AFTER <full helper output>
#   APP exit=<code> marker=<found|missing>
#   CAP6B1_CLEAN_MACHINE_PASS | CAP6B1_CLEAN_MACHINE_FAIL <reason>
#
# Usage: pwsh -File test/cap6b1/run_clean_machine_gate.ps1
#          [-SetupExe <path>] [-Helper <path>] [-LockFacts <path>]
#          [-PayloadDir <dir>] [-EvidenceDir <dir>]

param(
    [string]$SetupExe = '',
    [string]$Helper = '',
    [string]$LockFacts = '',
    [string]$PayloadDir = '',
    [string]$EvidenceDir = ''
)

$ErrorActionPreference = 'Stop'

if ($env:CI -or $env:GITHUB_ACTIONS) {
    throw ('the clean-machine gate is the authoritative HUMAN/VM proof: ' +
        'it never runs in CI and its evidence is never mocked')
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if ($SetupExe -eq '') {
    $SetupExe = Join-Path $RepoRoot 'dist/windows/normal/PWebRelease-Normal-Setup.exe'
}
if ($Helper -eq '') { $Helper = Join-Path $RepoRoot 'build/cap6b1/bin/pwebwv2prov.exe' }
if ($LockFacts -eq '') { $LockFacts = Join-Path $RepoRoot 'build/cap6b1/lockfacts.psd1' }
if ($PayloadDir -eq '') { $PayloadDir = Join-Path $RepoRoot 'build/cap6b1/payload' }
if ($EvidenceDir -eq '') { $EvidenceDir = Join-Path $RepoRoot 'build/cap6b1/clean-machine' }

New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
$Evidence = Join-Path $EvidenceDir 'evidence.log'
$script:Lines = @()

function Add-Evidence([string]$Line) {
    $script:Lines += $Line
    Write-Host $Line
}

function Save-Evidence {
    $script:Lines | Out-File -Encoding utf8 $Evidence
    Write-Host "evidence transcript: $Evidence"
}

function Invoke-Captured {
    param([string]$Exe, [string[]]$Args2, [int]$TimeoutMs, [string]$What,
        [string]$WorkDir = '')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($WorkDir -ne '') { $start.WorkingDirectory = $WorkDir }
    foreach ($a in $Args2) { [void]$start.ArgumentList.Add($a) }
    $proc = [Diagnostics.Process]::Start($start)
    if ($null -eq $proc) { throw "failed to start $What" }
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $proc.Kill($true)
            $proc.WaitForExit()
            throw "$What exceeded ${TimeoutMs}ms and was killed"
        }
        [pscustomobject]@{
            Code = $proc.ExitCode
            Out = ($stdout.GetAwaiter().GetResult() +
                   $stderr.GetAwaiter().GetResult())
        }
    }
    finally { $proc.Dispose() }
}

try {
    Add-Evidence ("CAP6B1_EVIDENCE_BEGIN $((Get-Date).ToUniversalTime().ToString('u'))" +
        " host=$env:COMPUTERNAME")

    # inputs are checked INSIDE the evidence scope: even a missing file
    # ends the transcript with a documented FAIL verdict (via catch)
    foreach ($pre in $SetupExe, $Helper, $LockFacts,
        (Join-Path $PayloadDir 'releaseapp.exe'),
        (Join-Path $PayloadDir 'app.pwb'),
        (Join-Path $PayloadDir 'webview.dll')) {
        if (-not (Test-Path $pre)) { throw "missing input: $pre" }
    }
    $facts = Import-PowerShellDataFile (Resolve-Path $LockFacts).Path

    # --- BEFORE: must NOT be AlreadyUsable (clean-machine precondition) ------
    $dummy = Join-Path $EvidenceDir 'dummy-payload.bin'
    Set-Content -LiteralPath $dummy -Value 'not the ratified bootstrapper' -NoNewline
    $before = Invoke-Captured $Helper @($dummy, $facts.BootSha,
        $facts.BootSubject) 60000 'BEFORE probe'
    Add-Evidence "BEFORE $($before.Out.Trim())"
    if ($before.Out -match 'WV2PROV_RESULT outcome=AlreadyUsable') {
        Add-Evidence ('CAP6B1_CLEAN_MACHINE_FAIL this machine already has a ' +
            'usable WebView2 runtime - not a clean machine; use a disposable ' +
            'instance (verify WebView2 absence at gate time)')
        exit 1
    }
    if ($before.Out -notmatch 'WV2PROV_DETECT status=(unavailable|available)') {
        Add-Evidence ('CAP6B1_CLEAN_MACHINE_FAIL BEFORE probe did not produce ' +
            'a structured detector verdict (detection_error is not a clean state)')
        exit 1
    }

    # --- BEFORE_APP: the staged (pre-setup) app must refuse with the
    # --- CAP-6b1 defensive marker and a nonzero exit -------------------------
    $unusableMarker = 'WEBVIEW2 RUNTIME UNUSABLE'
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    $beforeApp = Invoke-Captured (Join-Path $PayloadDir 'releaseapp.exe') @() `
        120000 'BEFORE_APP staged app' ([System.IO.Path]::GetTempPath())
    $beforeFound = 'missing'
    if ($beforeApp.Out -match [regex]::Escape($unusableMarker)) {
        $beforeFound = 'found'
    }
    Add-Evidence "BEFORE_APP exit=$($beforeApp.Code) marker=$beforeFound"
    Add-Evidence $beforeApp.Out.Trim()
    if (($beforeApp.Code -eq 0) -or ($beforeFound -ne 'found')) {
        Add-Evidence ('CAP6B1_CLEAN_MACHINE_FAIL the staged app did not refuse ' +
            'with the defensive UNUSABLE marker and a nonzero exit pre-setup')
        exit 1
    }

    # --- SETUP: the ratified provisioning flow, for real ---------------------
    $setupLog = Join-Path $EvidenceDir 'setup-install.log'
    if (Test-Path $setupLog) { Remove-Item -Force $setupLog }
    # 900 s bounded bootstrapper + margin for the download-heavy path
    $r = Invoke-Captured $SetupExe @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART', '/SP-', "/LOG=$setupLog") 1200000 'silent setup'
    Add-Evidence "SETUP exit=$($r.Code) log=$setupLog"
    if (-not (Test-Path $setupLog)) {
        Add-Evidence 'CAP6B1_CLEAN_MACHINE_FAIL setup produced no log'
        exit 1
    }
    $logText = Get-Content $setupLog -Raw
    if ($r.Code -ne 0) {
        Add-Evidence 'CAP6B1_CLEAN_MACHINE_FAIL setup exited nonzero (fail closed proven if provisioning failed; see log)'
        exit 1
    }
    if ($logText -notmatch 'WV2PROV_EXEC exit=') {
        Add-Evidence ('CAP6B1_CLEAN_MACHINE_FAIL the Bootstrapper was never ' +
            'executed - this run proved nothing about provisioning')
        exit 1
    }
    if ($logText -notmatch 'WV2PROV_RESULT outcome=Provisioned step=none') {
        Add-Evidence 'CAP6B1_CLEAN_MACHINE_FAIL helper did not report Provisioned'
        exit 1
    }

    # --- AFTER: independent re-observation of the re-probe verdict -----------
    $after = Invoke-Captured $Helper @($dummy, $facts.BootSha,
        $facts.BootSubject) 60000 'AFTER probe'
    Add-Evidence "AFTER $($after.Out.Trim())"
    if (($after.Code -ne 0) -or
        ($after.Out -notmatch 'WV2PROV_RESULT outcome=AlreadyUsable')) {
        Add-Evidence ('CAP6B1_CLEAN_MACHINE_FAIL post-setup detector is not ' +
            'AlreadyUsable - installer success is never runtime success')
        exit 1
    }

    # --- APP: the installed app proves the whole chain -----------------------
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\PWebRelease\releaseapp.exe'
    if (-not (Test-Path $installed)) {
        Add-Evidence "CAP6B1_CLEAN_MACHINE_FAIL installed app missing: $installed"
        exit 1
    }
    $marker = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    $app = Invoke-Captured $installed @() 120000 'installed app' `
        ([System.IO.Path]::GetTempPath())
    $found = 'missing'
    if ($app.Out -match [regex]::Escape($marker)) { $found = 'found' }
    Add-Evidence "APP exit=$($app.Code) marker=$found"
    Add-Evidence $app.Out.Trim()
    if (($app.Code -ne 0) -or ($found -ne 'found')) {
        Add-Evidence 'CAP6B1_CLEAN_MACHINE_FAIL installed app did not print the 42 PASS marker'
        exit 1
    }

    Add-Evidence 'CAP6B1_CLEAN_MACHINE_PASS'
    exit 0
}
catch {
    # the transcript NEVER ends without a verdict: any thrown error
    # (missing input, timeout kill, IO failure...) is recorded as the
    # documented FAIL line before the nonzero exit
    Add-Evidence "CAP6B1_CLEAN_MACHINE_FAIL unexpected error: $($_.Exception.Message)"
    exit 1
}
finally {
    Save-Evidence
}
