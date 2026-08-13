# CAP-6b3 AUTHORITATIVE clean-machine gate for the fixed-runtime
# profile. This is the one proof CI can never give: on a machine
# WITHOUT any usable WebView2 Evergreen runtime, the fixed setup must
# install and the app must run to the CAP-6 42 marker on the BUNDLED
# runtime alone - having provisioned nothing, downloaded nothing and
# left the machine's (absent) Evergreen state exactly as it found it.
# It runs on a disposable instance (Windows Sandbox is the ratified
# candidate - verify WebView2 absence at gate time - otherwise a
# throwaway VM image) and is NEVER mocked: this script refuses to run
# under CI.
#
# Transport to the instance (from a repo where the build gates ran):
#   dist/windows/fixed-runtime/setup.exe
#   build/cap6b3/bin/pwebwv2fixed.exe
#   build/cap6b3/lockfacts.psd1
#   build/cap6b3/tree.manifest
#   this script
# then: pwsh -File run_fixed_clean_machine_gate.ps1 -SetupExe <path>
#         -Helper <path> -LockFacts <path> -Manifest <path>
#         [-EvidenceDir <dir>]
#
# Phases (all recorded in the evidence transcript):
#   BEFORE  the compiled helper's --detect must report the Evergreen
#           detector NOT usable - otherwise this is not a clean machine
#           and the gate refuses (a fixed-runtime PASS observed next to
#           a usable Evergreen would prove nothing about the bundle)
#   SETUP   silent install with /LOG; setup exit must be 0, the log
#           must show the ACL helper's exit 0 and its verify-by-SID
#           verdict, and it must contain NO provisioning marker
#   AFTER   --detect again: the Evergreen state must be UNCHANGED and
#           still not usable - installing this profile must never give
#           the machine a runtime it did not have
#   APP     the installed releaseapp.exe runs from an unrelated CWD,
#           SELECTS the bundled runtime, OBSERVES the pinned version
#           and prints the CAP-6 42 PASS marker
#   BROKEN  the bundled browser image is removed and the app must FAIL
#           closed with the typed refusal - on a machine with no
#           Evergreen at all, this pins that the bundle really is the
#           runtime; the file is restored afterwards
#
# Evidence transcript format (build/cap6b3/clean-machine/evidence.log,
# committed with the artifact by the ratifying human). The transcript
# ALWAYS ends in exactly one verdict line, even when a phase throws:
#   CAP6B3_EVIDENCE_BEGIN <utc timestamp> host=<name>
#   BEFORE <full helper output>
#   SETUP exit=<code> log=<setup log copied beside the transcript>
#   MANIFEST exit=<code> <full helper output>   (installed tree ==
#                                                build-time manifest)
#   ACL exit=<code> <full helper output>        (grant verified BY SID)
#   AFTER <full helper output>
#   APP exit=<code> marker=<found|missing> identity=<found|missing>
#   BROKEN exit=<code> refusal=<found|missing>
#   CAP6B3_CLEAN_MACHINE_PASS | CAP6B3_CLEAN_MACHINE_FAIL <reason>
#
# Usage: pwsh -File test/cap6b3/run_fixed_clean_machine_gate.ps1
#          [-SetupExe <path>] [-Helper <path>] [-LockFacts <path>]
#          [-Manifest <path>] [-EvidenceDir <dir>]

param(
    [string]$SetupExe = '',
    [string]$Helper = '',
    [string]$LockFacts = '',
    [string]$Manifest = '',
    [string]$EvidenceDir = ''
)

$ErrorActionPreference = 'Stop'

if ($env:CI -or $env:GITHUB_ACTIONS) {
    throw ('the clean-machine gate is the authoritative HUMAN/VM proof: ' +
        'it never runs in CI and its evidence is never mocked')
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if ($SetupExe -eq '') {
    $SetupExe = Join-Path $RepoRoot 'dist/windows/fixed-runtime/setup.exe'
}
if ($Helper -eq '') { $Helper = Join-Path $RepoRoot 'build/cap6b3/bin/pwebwv2fixed.exe' }
if ($LockFacts -eq '') { $LockFacts = Join-Path $RepoRoot 'build/cap6b3/lockfacts.psd1' }
if ($Manifest -eq '') { $Manifest = Join-Path $RepoRoot 'build/cap6b3/tree.manifest' }
if ($EvidenceDir -eq '') { $EvidenceDir = Join-Path $RepoRoot 'build/cap6b3/clean-machine' }

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
            $childPid = $proc.Id
            $proc.Kill($true)
            # the post-kill confirmation wait is bounded too: an
            # unkillable child must fail LOUDLY, never hang the
            # authoritative human gate forever
            if (-not $proc.WaitForExit(30000)) {
                throw ("$What exceeded ${TimeoutMs}ms; kill UNCONFIRMED - " +
                    "child pid $childPid still alive after 30000ms")
            }
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
    Add-Evidence ("CAP6B3_EVIDENCE_BEGIN $((Get-Date).ToUniversalTime().ToString('u'))" +
        " host=$env:COMPUTERNAME")

    # inputs are checked INSIDE the evidence scope: even a missing file
    # ends the transcript with a documented FAIL verdict (via catch)
    foreach ($pre in $SetupExe, $Helper, $LockFacts, $Manifest) {
        if (-not (Test-Path $pre)) { throw "missing input: $pre" }
    }
    $facts = Import-PowerShellDataFile (Resolve-Path $LockFacts).Path
    # the very bytes this gate is about to execute must be THIS build's
    $sha = (Get-FileHash -Algorithm SHA256 $SetupExe).Hash.ToLowerInvariant()
    if ($sha -cne $facts.SetupSha) {
        Add-Evidence ("CAP6B3_CLEAN_MACHINE_FAIL setup.exe sha256 $sha is not " +
            "the built $($facts.SetupSha) - transported the wrong binary?")
        exit 1
    }
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PWebRelease'
    $InstalledRuntime = Join-Path $InstallDir 'runtime\webview2'
    $InstalledTree = Join-Path $InstalledRuntime $facts.TreeName
    $marker = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'

    # --- BEFORE: the machine must have NO usable Evergreen runtime ----------
    $before = Invoke-Captured $Helper @('--detect') 60000 'BEFORE detect'
    Add-Evidence "BEFORE $($before.Out.Trim())"
    if ($before.Out -notmatch 'WV2FIXED_DETECT status=') {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL BEFORE probe produced no ' +
            'structured detector verdict')
        exit 1
    }
    if ($before.Out -notmatch 'usable=false') {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL this machine already has a ' +
            'usable WebView2 Evergreen runtime - not a clean machine; use a ' +
            'disposable instance (verify WebView2 absence at gate time)')
        exit 1
    }

    # --- SETUP: deploy the bundled runtime, provisioning NOTHING -------------
    $setupLog = Join-Path $EvidenceDir 'setup-install.log'
    if (Test-Path $setupLog) { Remove-Item -Force $setupLog }
    $r = Invoke-Captured $SetupExe @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART', '/SP-', "/LOG=$setupLog") 1800000 'silent setup'
    Add-Evidence "SETUP exit=$($r.Code) log=$setupLog"
    if (-not (Test-Path $setupLog)) {
        Add-Evidence 'CAP6B3_CLEAN_MACHINE_FAIL setup produced no log'
        exit 1
    }
    $logText = Get-Content $setupLog -Raw
    if ($r.Code -ne 0) {
        Add-Evidence 'CAP6B3_CLEAN_MACHINE_FAIL setup exited nonzero (see log)'
        exit 1
    }
    if ($logText -notmatch 'PWEB_WV2FIXED exit=0') {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL the AppContainer ACL helper ' +
            'did not report exit 0')
        exit 1
    }
    if ($logText -notmatch 'WV2FIXED_RESULT outcome=Ok step=none') {
        Add-Evidence 'CAP6B3_CLEAN_MACHINE_FAIL the ACL helper did not verify the grant'
        exit 1
    }
    if ($logText -match 'WV2PROV_') {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL a provisioning marker appears ' +
            'in the fixed-profile setup log - this profile provisions NOTHING')
        exit 1
    }
    # what landed on this machine is byte-identical to what was built:
    # the same native streamed digest, over the same deterministic
    # manifest the build wrote
    $mv = Invoke-Captured $Helper @('--manifest-verify', $InstalledRuntime,
        $Manifest) 900000 'installed manifest verify'
    Add-Evidence "MANIFEST exit=$($mv.Code) $($mv.Out.Trim())"
    if (($mv.Code -ne 0) -or ($mv.Out -notmatch 'WV2FIXED_RESULT outcome=Ok')) {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL the installed runtime tree ' +
            'does not match the build-time manifest')
        exit 1
    }
    # and its AppContainer grant verifies BY SID on this machine too
    $av = Invoke-Captured $Helper @('--acl-verify', $InstalledTree) 60000 `
        'installed ACL verify'
    Add-Evidence "ACL exit=$($av.Code) $($av.Out.Trim())"
    if (($av.Code -ne 0) -or ($av.Out -notmatch 'WV2FIXED_RESULT outcome=Ok')) {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL the installed tree does not ' +
            'carry the ratified AppContainer grant')
        exit 1
    }

    # --- AFTER: the machine's Evergreen state must be UNCHANGED --------------
    $after = Invoke-Captured $Helper @('--detect') 60000 'AFTER detect'
    Add-Evidence "AFTER $($after.Out.Trim())"
    if ($after.Out -notmatch 'usable=false') {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL the machine gained a usable ' +
            'Evergreen runtime across the install - this profile must provision ' +
            'nothing')
        exit 1
    }

    # --- APP: the whole chain, on the bundled runtime alone ------------------
    $installed = Join-Path $InstallDir 'releaseapp.exe'
    if (-not (Test-Path $installed)) {
        Add-Evidence "CAP6B3_CLEAN_MACHINE_FAIL installed app missing: $installed"
        exit 1
    }
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    $app = Invoke-Captured $installed @() 180000 'installed app' `
        ([System.IO.Path]::GetTempPath())
    $found = 'missing'
    if ($app.Out -match [regex]::Escape($marker)) { $found = 'found' }
    $identity = 'missing'
    if ($app.Out -match [regex]::Escape(
            "FIXED RUNTIME IDENTITY OK $($facts.FixedVersion)")) {
        $identity = 'found'
    }
    Add-Evidence "APP exit=$($app.Code) marker=$found identity=$identity"
    Add-Evidence $app.Out.Trim()
    if (($app.Code -ne 0) -or ($found -ne 'found') -or ($identity -ne 'found')) {
        Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL the installed app did not run ' +
            'to 42 on the OBSERVED pinned runtime')
        exit 1
    }

    # --- BROKEN: the bundle really is the runtime ----------------------------
    $victim = Join-Path $InstalledTree 'msedgewebview2.exe'
    $backup = "$victim.cap6b3-bak"
    Move-Item -LiteralPath $victim -Destination $backup -Force
    try {
        $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
        $broken = Invoke-Captured $installed @() 120000 'broken-tree app' `
            ([System.IO.Path]::GetTempPath())
        $refusal = 'missing'
        if ($broken.Out -match 'FIXED RUNTIME REFUSED') { $refusal = 'found' }
        Add-Evidence "BROKEN exit=$($broken.Code) refusal=$refusal"
        Add-Evidence $broken.Out.Trim()
        if (($broken.Code -eq 0) -or ($refusal -ne 'found') -or
            ($broken.Out -match [regex]::Escape($marker))) {
            Add-Evidence ('CAP6B3_CLEAN_MACHINE_FAIL a broken bundled tree did ' +
                'not fail closed')
            exit 1
        }
    }
    finally {
        Move-Item -LiteralPath $backup -Destination $victim -Force
    }

    Add-Evidence 'CAP6B3_CLEAN_MACHINE_PASS'
    exit 0
}
catch {
    # the transcript NEVER ends without a verdict: any thrown error
    # (missing input, timeout kill, IO failure...) is recorded as the
    # documented FAIL line before the nonzero exit
    Add-Evidence "CAP6B3_CLEAN_MACHINE_FAIL unexpected error: $($_.Exception.Message)"
    exit 1
}
finally {
    Save-Evidence
}
