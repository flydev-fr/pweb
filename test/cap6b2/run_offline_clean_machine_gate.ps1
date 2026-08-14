# CAP-6b2 AUTHORITATIVE offline clean-machine provisioning gate. This
# is the one proof CI can never give: on a machine WITHOUT a usable
# WebView2 runtime and WITHOUT network, the offline setup must
# verifiably execute the EMBEDDED lock-verified Evergreen Standalone
# Installer and end with a usable runtime and a working installed app
# - with zero network available at any point of the provisioning. It
# runs on a disposable instance (a throwaway VM with every network
# adapter disabled; Windows Sandbox only if its WebView2 absence AND
# network isolation are both verified at gate time) and is NEVER
# mocked: this script refuses to run under CI.
#
# The offline hard invariant is enforced BY the harness: the active
# network adapters are sampled immediately before the setup run,
# POLLED every ~5 s WHILE setup runs, and sampled again after it -
# any adapter seen Up at any of those points REFUSES the PASS
# verdict, and so does an UNKNOWABLE network state (no Get-NetAdapter
# on the host): an online - or unaccountable - machine can never
# prove the offline profile, because the runtime could have arrived
# through the network instead of the embedded payload.
#
# The transported setup binary is verified too: its sha256 is computed
# before execution, recorded as evidence, and MUST equal the
# build-recorded SetupSha from lockfacts.psd1 - a mutated or swapped
# binary fails the gate before it ever runs.
#
# Transport to the instance (from a repo where the build gates ran):
#   dist/windows/offline/PWebRelease-Offline-Setup.exe
#   build/cap6b2/bin/pwebwv2prov.exe
#   build/cap6b2/lockfacts.psd1
#   build/cap6b2/payload/        (the staged release triple: the
#                                 BEFORE-phase app-refusal proof runs
#                                 releaseapp.exe from here, pre-setup)
#   this script
# then: pwsh -File run_offline_clean_machine_gate.ps1 -SetupExe <path>
#         -Helper <path> -LockFacts <path> -PayloadDir <dir>
#         [-EvidenceDir <dir>]
#
# Phases (all recorded in the evidence transcript):
#   BEFORE   helper probe with a dummy payload (execution impossible
#            by construction) must report the detector NOT
#            AlreadyUsable - otherwise this is not a clean machine and
#            the gate refuses - AND the exit/step pair must be the
#            coherent digest refusal (exit 3, step=verify_digest): a
#            crashed helper is never clean-machine evidence; then the
#            STAGED releaseapp.exe (payload dir, pre-setup) must
#            refuse with the distinct 'WEBVIEW2 RUNTIME UNUSABLE'
#            stderr marker and a nonzero exit
#   SETUP_SHA256  sha256 of the exact setup binary about to run vs the
#            build-recorded lockfacts value; mismatch refuses
#   NETWORK  active-adapter samples before, DURING (5 s poll) and
#            after SETUP; any adapter Up - or an unknowable state -
#            refuses PASS
#   SETUP    silent install with /LOG, bounded by the ratified helper
#            timeout (lockfacts TimeoutMs) + 600 s extraction/install
#            margin; the ratified flow inside setup verifies sha256 +
#            Authenticode and executes the EMBEDDED Standalone; setup
#            exit must be 0 and the log must show WV2PROV_EXEC (it
#            really ran) and outcome=Provisioned
#   AFTER    helper probe again: decision=AlreadyUsable required (the
#            mandatory re-probe invariant, observed independently)
#   APP      the installed releaseapp.exe runs from an unrelated CWD
#            and prints the CAP-6 42 PASS marker
#
# Evidence transcript format: one TIMESTAMPED file per run
# (build/cap6b2/clean-machine/evidence-<utc>.log - a rerun can never
# overwrite a prior transcript; only evidence lives in the evidence
# dir, working files go to the system temp dir). The transcript is
# committed with the artifact by the ratifying human and ALWAYS ends
# in exactly one verdict line, even when a phase throws:
#   CAP6B2_EVIDENCE_BEGIN <utc timestamp> host=<name>
#   BEFORE <full helper output>
#   BEFORE_APP exit=<code> marker=<found|missing>
#   SETUP_SHA256 sha256=<64hex> expected=<64hex>
#   NETWORK_BEFORE_SETUP known=<true|false> active=<n> adapters=<list|none>
#   SETUP exit=<code> log=<setup log written beside the transcript>
#   NETWORK_DURING_SETUP known=<true|false> samples=<n> up=<list|none>
#   NETWORK_AFTER_SETUP known=<true|false> active=<n> adapters=<list|none>
#   AFTER <full helper output>
#   APP exit=<code> marker=<found|missing>
#   CAP6B2_OFFLINE_CLEAN_MACHINE_PASS | CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL <reason>
#
# Usage: pwsh -File test/cap6b2/run_offline_clean_machine_gate.ps1
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
    throw ('the offline clean-machine gate is the authoritative HUMAN/VM proof: ' +
        'it never runs in CI and its evidence is never mocked')
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if ($SetupExe -eq '') {
    $SetupExe = Join-Path $RepoRoot 'dist/windows/offline/PWebRelease-Offline-Setup.exe'
}
if ($Helper -eq '') { $Helper = Join-Path $RepoRoot 'build/cap6b2/bin/pwebwv2prov.exe' }
if ($LockFacts -eq '') { $LockFacts = Join-Path $RepoRoot 'build/cap6b2/lockfacts.psd1' }
if ($PayloadDir -eq '') { $PayloadDir = Join-Path $RepoRoot 'build/cap6b2/payload' }
if ($EvidenceDir -eq '') { $EvidenceDir = Join-Path $RepoRoot 'build/cap6b2/clean-machine' }

New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
# one timestamped transcript per run: a rerun never overwrites the
# evidence a human may already have ratified
$RunStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$Evidence = Join-Path $EvidenceDir "evidence-$RunStamp.log"
$script:Lines = @()

function Add-Evidence([string]$Line) {
    $script:Lines += $Line
    Write-Host $Line
}

function Save-Evidence {
    $script:Lines | Out-File -Encoding utf8 $Evidence
    Write-Host "evidence transcript: $Evidence"
}

# adapter sample, fail-closed about knowability: Known=$false means the
# host cannot account for its network state (no Get-NetAdapter) - the
# gate then REFUSES, it never silently samples 'offline'
function Get-AdapterSample {
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{
            Known = $true
            Up = @(Get-NetAdapter -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Up' } |
                ForEach-Object { "$($_.Name) [$($_.InterfaceDescription)]" })
        }
    }
    [pscustomobject]@{ Known = $false; Up = @() }
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
            # bounded post-kill confirmation: an unkillable child fails
            # LOUDLY, it never hangs the gate
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

# runs setup while POLLING the adapter state every ~5 s: any adapter
# seen Up during the provisioning interval - and any unknowable sample
# - is recorded so the verdict can refuse it
function Invoke-SetupWithNetworkWatch {
    param([string]$Exe, [string[]]$Args2, [int]$TimeoutMs)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($a in $Args2) { [void]$start.ArgumentList.Add($a) }
    $proc = [Diagnostics.Process]::Start($start)
    if ($null -eq $proc) { throw 'failed to start silent offline setup' }
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        $seenUp = [System.Collections.Generic.SortedSet[string]]::new()
        $samples = 0
        $known = $true
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while (-not $proc.WaitForExit(5000)) {
            $sample = Get-AdapterSample
            $samples++
            if (-not $sample.Known) { $known = $false }
            foreach ($a in $sample.Up) { [void]$seenUp.Add($a) }
            if ([DateTime]::UtcNow -gt $deadline) {
                $childPid = $proc.Id
                $proc.Kill($true)
                if (-not $proc.WaitForExit(30000)) {
                    throw ("silent offline setup exceeded ${TimeoutMs}ms; kill " +
                        "UNCONFIRMED - child pid $childPid still alive after 30000ms")
                }
                throw "silent offline setup exceeded ${TimeoutMs}ms and was killed"
            }
        }
        [pscustomobject]@{
            Code = $proc.ExitCode
            Out = ($stdout.GetAwaiter().GetResult() +
                   $stderr.GetAwaiter().GetResult())
            NetKnown = $known
            NetSamples = $samples
            NetSeenUp = @($seenUp)
        }
    }
    finally { $proc.Dispose() }
}

try {
    Add-Evidence ("CAP6B2_EVIDENCE_BEGIN $((Get-Date).ToUniversalTime().ToString('u'))" +
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
    # working files never pollute the evidence dir: the dummy payload
    # lives in the system temp dir
    $dummy = Join-Path ([System.IO.Path]::GetTempPath()) `
        "pweb-cap6b2-dummy-$RunStamp.bin"
    Set-Content -LiteralPath $dummy -Value 'not the ratified standalone' -NoNewline
    $before = Invoke-Captured $Helper @($dummy, $facts.StandaloneSha,
        $facts.StandaloneSubject) 60000 'BEFORE probe'
    Add-Evidence "BEFORE $($before.Out.Trim())"
    if ($before.Out -match 'WV2PROV_RESULT outcome=AlreadyUsable') {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL this machine already has ' +
            'a usable WebView2 runtime - not a clean machine; use a disposable ' +
            'instance (verify WebView2 absence at gate time)')
        exit 1
    }
    if ($before.Out -notmatch 'WV2PROV_DETECT status=(unavailable|available)') {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL BEFORE probe did not produce ' +
            'a structured detector verdict (detection_error is not a clean state)')
        exit 1
    }
    # exit/step coherence: on a genuinely runtime-less machine the
    # dummy payload MUST die on the digest refusal (exit 3, step
    # verify_digest) - anything else (a crash, a stray exit code)
    # cannot serve as clean-machine precondition evidence
    if (($before.Code -ne 3) -or
        ($before.Out -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_digest')) {
        Add-Evidence ("CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL BEFORE probe exit/step " +
            "incoherent (exit=$($before.Code), expected 3 with " +
            'step=verify_digest) - a crashed helper is not evidence')
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
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL the staged app did not ' +
            'refuse with the defensive UNUSABLE marker and a nonzero exit pre-setup')
        exit 1
    }

    # --- SETUP_SHA256: the transported binary must BE the built binary ------
    $setupSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $SetupExe).Hash.ToLowerInvariant()
    $expectedSha = "$($facts.SetupSha)".ToLowerInvariant()
    Add-Evidence "SETUP_SHA256 sha256=$setupSha expected=$expectedSha"
    if ($expectedSha -cnotmatch '^[0-9a-f]{64}$') {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL lockfacts carry no ' +
            'build-recorded SetupSha - rebuild via test/cap6b2/build_offline_setup.ps1 ' +
            'and transport its lockfacts.psd1')
        exit 1
    }
    if ($setupSha -cne $expectedSha) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL setup binary sha256 does not ' +
            'match the build-recorded value - refusing to execute a mutated or ' +
            'swapped binary')
        exit 1
    }

    # --- NETWORK (pre-setup sample): Up or unknowable voids the proof --------
    $netBefore = Get-AdapterSample
    $netBeforeText = 'none'
    if ($netBefore.Up.Count -gt 0) { $netBeforeText = $netBefore.Up -join '; ' }
    Add-Evidence ("NETWORK_BEFORE_SETUP known=$($netBefore.Known.ToString().ToLower())" +
        " active=$($netBefore.Up.Count) adapters=$netBeforeText")
    if (-not $netBefore.Known) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL network state UNKNOWABLE ' +
            '(Get-NetAdapter unavailable) - an unaccountable machine can never ' +
            'prove the offline profile')
        exit 1
    }
    if ($netBefore.Up.Count -gt 0) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL network is ACTIVE - an ' +
            'online machine can never prove the offline profile (the runtime ' +
            'could arrive through the network instead of the embedded payload); ' +
            'disable every adapter and rerun')
        exit 1
    }

    # --- SETUP: the ratified offline provisioning flow, for real -------------
    # bound derived from the ratified helper timeout the setup itself
    # enforces (lockfacts TimeoutMs, cross-checked against the Pascal
    # constant at build time) + 600 s extraction/install margin
    $setupBound = [int]$facts.TimeoutMs + 600000
    $setupLog = Join-Path $EvidenceDir "setup-install-$RunStamp.log"
    $r = Invoke-SetupWithNetworkWatch $SetupExe @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART', '/SP-', "/LOG=$setupLog") $setupBound
    Add-Evidence "SETUP exit=$($r.Code) log=$setupLog"
    $duringText = 'none'
    if ($r.NetSeenUp.Count -gt 0) { $duringText = $r.NetSeenUp -join '; ' }
    Add-Evidence ("NETWORK_DURING_SETUP known=$($r.NetKnown.ToString().ToLower())" +
        " samples=$($r.NetSamples) up=$duringText")
    if (-not (Test-Path $setupLog)) {
        Add-Evidence 'CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL setup produced no log'
        exit 1
    }
    $logText = Get-Content $setupLog -Raw
    if ($r.Code -ne 0) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL setup exited nonzero ' +
            '(fail closed proven if provisioning failed; see log)')
        exit 1
    }
    if ($logText -notmatch 'WV2PROV_EXEC exit=') {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL the Standalone was never ' +
            'executed - this run proved nothing about offline provisioning')
        exit 1
    }
    if ($logText -notmatch 'WV2PROV_RESULT outcome=Provisioned step=none') {
        Add-Evidence 'CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL helper did not report Provisioned'
        exit 1
    }
    # the DURING-provisioning refusal: the whole point of this gate
    if (-not $r.NetKnown) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL network state became ' +
            'UNKNOWABLE during provisioning - the offline proof is void')
        exit 1
    }
    if ($r.NetSeenUp.Count -gt 0) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL network was ACTIVE during ' +
            'provisioning - the offline proof is void; rerun with every adapter ' +
            'disabled for the whole gate')
        exit 1
    }

    # --- NETWORK (post-setup sample): every sample must be clean -------------
    $netAfter = Get-AdapterSample
    $netAfterText = 'none'
    if ($netAfter.Up.Count -gt 0) { $netAfterText = $netAfter.Up -join '; ' }
    Add-Evidence ("NETWORK_AFTER_SETUP known=$($netAfter.Known.ToString().ToLower())" +
        " active=$($netAfter.Up.Count) adapters=$netAfterText")
    if ((-not $netAfter.Known) -or ($netAfter.Up.Count -gt 0)) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL network active or ' +
            'unknowable after provisioning - the offline proof is void; rerun ' +
            'with every adapter disabled for the whole gate')
        exit 1
    }

    # --- AFTER: independent re-observation of the re-probe verdict -----------
    $after = Invoke-Captured $Helper @($dummy, $facts.StandaloneSha,
        $facts.StandaloneSubject) 60000 'AFTER probe'
    Add-Evidence "AFTER $($after.Out.Trim())"
    if (($after.Code -ne 0) -or
        ($after.Out -notmatch 'WV2PROV_RESULT outcome=AlreadyUsable')) {
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL post-setup detector is not ' +
            'AlreadyUsable - installer success is never runtime success')
        exit 1
    }

    # --- APP: the installed app proves the whole chain -----------------------
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\PWebRelease\releaseapp.exe'
    if (-not (Test-Path $installed)) {
        Add-Evidence "CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL installed app missing: $installed"
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
        Add-Evidence ('CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL installed app did not ' +
            'print the 42 PASS marker')
        exit 1
    }

    Add-Evidence 'CAP6B2_OFFLINE_CLEAN_MACHINE_PASS'
    exit 0
}
catch {
    # the transcript NEVER ends without a verdict: any thrown error
    # (missing input, timeout kill, IO failure...) is recorded as the
    # documented FAIL line before the nonzero exit
    Add-Evidence "CAP6B2_OFFLINE_CLEAN_MACHINE_FAIL unexpected error: $($_.Exception.Message)"
    exit 1
}
finally {
    Save-Evidence
    if (($null -ne $dummy) -and (Test-Path -LiteralPath $dummy)) {
        Remove-Item -Force -LiteralPath $dummy
    }
}
