# CAP-8B Windows/WebView2 AUDIT harness. MEASUREMENT ONLY, NOT A GATE.
#
# WHAT THIS DOES. It compiles test/cap8b/cap8b_audit_win.cpp against the pinned
# WebView2 SDK in the CAP-4W webview build tree, stages webview.dll beside the
# resulting executable, runs it under a bounded timeout, and then requires the
# document it produced to be a structurally valid schema-1 audit before
# rendering it. The measurement itself is the probe's; this file only makes it
# reproducible and refuses to accept one that did not actually happen.
#
# WHAT IT DELIBERATELY IS NOT. It is not a gate on CAP-8B's policy, and no
# verdict it prints is a pass/fail judgement about the engine. "WebKit exposes
# the raw channel where the shim is absent" and "the download hook cannot be
# cancelled" are RESULTS; the only failures this script recognizes are
# failures of the INSTRUMENT - it did not compile, it did not run, it crashed,
# it exceeded its deadline, or it wrote a document that is not a measurement.
#
# THE SKIP, AND ITS EXACT SHAPE. A hosted Windows runner may genuinely lack a
# WebView2 runtime or a desktop session, which is why every Windows runtime
# gate in this repository (CAP-4W, CAP-5, CAP-6) carries a conditional SKIP.
# This one carries the same policy and takes the decision from the PROBE'S OWN
# exit contract rather than from prose in its log:
#
#   exit 0 + CAP8B_AUDIT_WIN_DONE          at least one phase measured -> PASS
#   exit 3 + CAP8B_AUDIT_WIN_UNAVAILABLE   no phase could open a WebView -> SKIP
#   anything else                          FAILURE
#
# and the SKIP is then CROSS-CHECKED against the document: it is honoured only
# if the document really carries no event, no native arrival and no page
# report. A partial measurement masquerading as "no runtime here" is the exact
# artifact that would later be quoted as evidence of an engine behaviour
# nobody observed, so the two independent statements must agree.
#
# Prerequisites: tools/build-webview-dll.ps1 (it produces the webview build
# tree this script compiles and links against).
#
# Usage: pwsh test/cap8b/run_audit_win.ps1 [-TimeoutSec 300] [-CompileOnly]
param(
    [string]$WebViewBuildDir = 'build/webview-build-cap4w',
    [string]$ProbeBuildDir = 'build/cap8b/probe',
    [string]$OutputDir = 'build/cap8b',
    # This is the OUTER hang ceiling, not a prediction, and the rule is that
    # it must stay comfortably ABOVE the sum of the probe's own per-phase
    # watchdogs - which grows every time the probe gains a phase, and has:
    # 275 s over ten phases as measured here (30 exposure + 90 coverage + 30
    # csp + 30 csp-meta + 15/15/15/20 activation + 15/15 redirect), against a
    # healthy full run of well under two minutes. Raise this, never the
    # probe's, if a phase is added.
    [ValidateRange(60, 1800)]
    [int]$TimeoutSec = 600,
    [switch]$CompileOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WebViewBuild = [IO.Path]::GetFullPath((Join-Path $RepoRoot $WebViewBuildDir))
$ProbeBuild = [IO.Path]::GetFullPath((Join-Path $RepoRoot $ProbeBuildDir))
$Output = [IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputDir))

# PATH CONFINEMENT, the CAP-4W rule: everything this script creates or removes
# stays below build/cap8b, so a mistyped parameter cannot make a harness that
# compiles and deletes reach anywhere else in the tree.
$Cap8bRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'build\cap8b'))
$Cap8bPrefix = $Cap8bRoot + [IO.Path]::DirectorySeparatorChar
if (-not $ProbeBuild.StartsWith($Cap8bPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "[CAP-8B] probe build path must remain below build/cap8b: $ProbeBuild"
}
if (-not ($Output.Equals($Cap8bRoot, [StringComparison]::OrdinalIgnoreCase) -or
          $Output.StartsWith($Cap8bPrefix, [StringComparison]::OrdinalIgnoreCase))) {
    throw "[CAP-8B] audit output path must remain below build/cap8b: $Output"
}

$WebViewDll = Join-Path $WebViewBuild 'core\Release\webview.dll'
$WebViewLib = Join-Path $WebViewBuild 'core\Release\webview.lib'
$SdkHeader = Join-Path $WebViewBuild `
    '_deps\microsoft_web_webview2-src\build\native\include\WebView2.h'
$ProbeSource = Join-Path $PSScriptRoot 'cap8b_audit_win.cpp'
foreach ($required in @($WebViewDll, $WebViewLib, $SdkHeader, $ProbeSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "[CAP-8B] required input missing: $required"
    }
}

New-Item -ItemType Directory -Force $Output | Out-Null
$JsonPath = Join-Path $Output 'audit-windows-x86_64.json'
$LogPath = Join-Path $Output 'audit-windows.log'
# Named literals below build/cap8b, no recursion and no wildcard: a stale
# document from a previous run must never be mistaken for this run's result.
foreach ($stale in @($JsonPath, $LogPath)) {
    if (Test-Path -LiteralPath $stale -PathType Leaf) {
        Remove-Item -LiteralPath $stale -Force
    }
}

cmake -B $ProbeBuild -S $PSScriptRoot `
    "-DPWEB_ROOT=$RepoRoot" `
    "-DWEBVIEW_BUILD_DIR=$WebViewBuild"
if ($LASTEXITCODE -ne 0) { throw '[CAP-8B] audit probe configure failed' }

cmake --build $ProbeBuild --config Release
if ($LASTEXITCODE -ne 0) { throw '[CAP-8B] audit probe compile failed' }

$ProbeExe = Join-Path $ProbeBuild 'Release\cap8b_audit_win.exe'
if (-not (Test-Path -LiteralPath $ProbeExe -PathType Leaf)) {
    throw "[CAP-8B] audit probe executable missing: $ProbeExe"
}
# Beside the exe, never on PATH: the probe must load the DLL this repository
# built from the pinned source, not whatever else the machine happens to have.
#
# COMPARED BEFORE COPIED. A previous probe still holding the staged DLL makes
# an unconditional Copy-Item fail with "used by another process", which on a
# dev host is a confusing way to say "the right bytes are already there" - and
# on a fresh runner the file does not exist at all. Identical bytes are left
# alone; DIFFERENT bytes that cannot be replaced are a hard refusal, because
# running the probe against a stale library would measure the wrong thing.
$StagedDll = Join-Path (Split-Path -Parent $ProbeExe) 'webview.dll'
$needCopy = $true
if (Test-Path -LiteralPath $StagedDll -PathType Leaf) {
    $wantHash = (Get-FileHash -LiteralPath $WebViewDll -Algorithm SHA256).Hash
    $gotHash = (Get-FileHash -LiteralPath $StagedDll -Algorithm SHA256).Hash
    if ($wantHash -eq $gotHash) { $needCopy = $false }
}
if ($needCopy) {
    try {
        Copy-Item -LiteralPath $WebViewDll -Destination $StagedDll -Force `
            -ErrorAction Stop
    }
    catch {
        throw ("[CAP-8B] cannot stage webview.dll beside the probe " +
            "($StagedDll): $_ -- is a probe from an earlier run still alive?")
    }
}
Write-Host '[CAP-8B] COMPILE PASS'
if ($CompileOnly) { exit 0 }

# --- run ----------------------------------------------------------------------
# The probe watchdogs every phase itself (see -TimeoutSec above for the sum).
# The bound here is the OUTER one: it catches the shapes an in-process watchdog
# cannot - a hang before the watchdog thread starts, a wedged message loop that
# ignores webview_terminate, a modal dialog nobody will ever dismiss.
#
# EVERY WAIT BELOW IS BOUNDED, and that is not decoration. Bounding the PROCESS
# is not the same as bounding the HARNESS: the redirected stdout/stderr handles
# are INHERITED by every child the probe spawns, and WebView2 spawns a browser
# process plus a renderer per frame. If one of those outlives the probe it
# keeps the write end of the pipe open, ReadToEndAsync never completes, and a
# harness that waits on it unconditionally hangs FOREVER - after its own
# timeout has already passed. In CI `timeout-minutes` hides that behind a job
# kill; on a dev host it simply never returns. So the drain gets its own
# ceiling, the post-kill reap gets its own ceiling, and neither uses the
# parameterless WaitForExit(), which in .NET 5+ additionally waits for the
# redirected streams to reach EOF - precisely the thing that may never happen.
$DrainTimeoutMs = 30000
$ReapTimeoutMs = 15000

# The surviving-child killer. NAMED AND DATED, never "every descendant": by
# the time this runs the probe itself is usually gone, its PID is free for
# reuse, and a blind walk of ParentProcessId could hand us an unrelated
# process that happened to inherit the number. Only a WebView2 host or another
# copy of this probe, started no earlier than our own launch, is ever killed.
function Stop-ProbeDescendants {
    param([int]$RootPid, [datetime]$NotBefore)
    $killed = @()
    $all = $null
    try { $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
    catch { return $killed }
    $byParent = @{}
    foreach ($p in $all) {
        $parentId = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($parentId)) {
            $byParent[$parentId] = New-Object System.Collections.Generic.List[object]
        }
        [void]$byParent[$parentId].Add($p)
    }
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootPid)
    $seen = New-Object System.Collections.Generic.HashSet[int]
    [void]$seen.Add($RootPid)
    $steps = 0
    while (($queue.Count -gt 0) -and ($steps -lt 512)) {
        $steps++
        $parentId = $queue.Dequeue()
        if (-not $byParent.ContainsKey($parentId)) { continue }
        foreach ($child in $byParent[$parentId]) {
            $childPid = [int]$child.ProcessId
            if (-not $seen.Add($childPid)) { continue }
            $queue.Enqueue($childPid)
            $name = [string]$child.Name
            if (@('msedgewebview2.exe', 'cap8b_audit_win.exe') -notcontains $name) {
                continue
            }
            $created = $null
            try { $created = [datetime]$child.CreationDate } catch { $created = $null }
            if (($null -ne $created) -and ($created -lt $NotBefore)) { continue }
            try {
                Stop-Process -Id $childPid -Force -ErrorAction Stop
                $killed += "$name($childPid)"
            }
            catch { }
        }
    }
    return $killed
}

$launchedAt = Get-Date
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $ProbeExe
$start.WorkingDirectory = (Split-Path -Parent $ProbeExe)
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.CreateNoWindow = $false
[void]$start.ArgumentList.Add($JsonPath)
$process = [Diagnostics.Process]::Start($start)
if ($null -eq $process) { throw '[CAP-8B] failed to start the audit probe' }
$probePid = $process.Id
$outText = ''
$errorText = ''
$exitCode = -1
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timeoutMs = $TimeoutSec * 1000
    if (-not $process.WaitForExit($timeoutMs)) {
        try { $process.Kill($true) } catch { }
        [void](Stop-ProbeDescendants -RootPid $probePid -NotBefore $launchedAt)
        [void]$process.WaitForExit($ReapTimeoutMs)
        throw "[CAP-8B] audit probe exceeded ${timeoutMs}ms"
    }
    # THE PROBE HAS EXITED AND THE PIPE MAY STILL BE OPEN. This is the second
    # deadline, not a formality: WaitForExit bounded the process, and only the
    # process. A ReadToEndAsync still running here is a surviving child
    # holding the inherited handle, which no amount of further waiting fixes.
    $tasks = [System.Threading.Tasks.Task[]]@($stdout, $stderr)
    $drained = $false
    try { $drained = [System.Threading.Tasks.Task]::WaitAll($tasks, $DrainTimeoutMs) }
    catch { throw "[CAP-8B] AUDIT PROBE PIPE FAULTED while draining: $_" }
    if (-not $drained) {
        $stuck = @()
        if (-not $stdout.IsCompleted) { $stuck += 'stdout' }
        if (-not $stderr.IsCompleted) { $stuck += 'stderr' }
        $killed = @(Stop-ProbeDescendants -RootPid $probePid -NotBefore $launchedAt)
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, $ReapTimeoutMs) }
        catch { }
        $what = if ($killed.Count -gt 0) { $killed -join ', ' } else { 'nothing identifiable' }
        throw ("[CAP-8B] AUDIT PROBE PIPE NOT DRAINED: the probe exited but " +
            "$($stuck -join ' and ') stayed open past ${DrainTimeoutMs}ms - a " +
            'surviving child (the WebView2 browser or a renderer) inherited ' +
            "the redirected handle. killed: $what")
    }
    $outText = $stdout.GetAwaiter().GetResult()
    $errorText = $stderr.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
}
finally {
    $process.Dispose()
}
$transcript = $outText + $errorText
[IO.File]::WriteAllText($LogPath, $transcript, [Text.UTF8Encoding]::new($false))
if ($outText) { Write-Host $outText.TrimEnd() }
if ($errorText) { Write-Host $errorText.TrimEnd() }

if (($exitCode -ne 0) -and ($exitCode -ne 3)) {
    throw "[CAP-8B] audit probe failed with exit $exitCode (see $LogPath)"
}
if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
    throw "[CAP-8B] audit probe wrote no document: $JsonPath"
}
$doc = $null
try { $doc = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json }
catch { throw "[CAP-8B] audit document is not parseable JSON: $JsonPath" }
# Property lookups go through PSObject.Properties: StrictMode makes a missing
# property a terminating error, and "the field is absent" must be answerable
# here rather than thrown from underneath the SKIP decision.
function Get-DocField([string]$Name) {
    $p = $doc.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}
$eventCount = @(Get-DocField 'events').Count
$arrivals = Get-DocField 'native_arrivals'
$arrivalCount = 0
if ($null -ne $arrivals) {
    $arrivalCount = @($arrivals.PSObject.Properties).Count
}
$reported = 0
foreach ($f in @('exposure_report', 'coverage_report', 'csp_report',
                 'csp_meta_report')) {
    if (-not [string]::IsNullOrWhiteSpace([string](Get-DocField $f))) {
        $reported++
    }
}
$measured = ($eventCount -gt 0) -or ($arrivalCount -gt 0) -or ($reported -gt 0)

# --- the SKIP decision: the probe's exit contract, cross-checked -------------
if ($exitCode -eq 3) {
    if ($transcript -notmatch 'CAP8B_AUDIT_WIN_UNAVAILABLE') {
        throw ("[CAP-8B] audit probe exited 3 without its unavailability " +
            "marker (see $LogPath)")
    }
    if ($measured) {
        # "No phase could run" and "here are the measurements" cannot both be
        # true, and an inconsistent state is never a SKIP.
        throw ('[CAP-8B] inconsistent probe state: the probe reported itself ' +
            "unavailable yet the document carries $eventCount event(s), " +
            "$arrivalCount native arrival(s) and $reported page report(s)")
    }
    $verdict = ('SKIP - no usable WebView2 runtime/desktop session on this ' +
        'runner (the probe reported CAP8B_AUDIT_WIN_UNAVAILABLE and the ' +
        'document carries no measurement)')
    if ($env:GITHUB_STEP_SUMMARY) {
        "### CAP-8B audit probe (measurement only)`n$verdict" |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    Write-Host "[CAP-8B] $verdict"
    exit 0
}
if ($transcript -notmatch 'CAP8B_AUDIT_WIN_DONE') {
    throw "[CAP-8B] audit probe exited 0 without its completion marker (see $LogPath)"
}
if (-not $measured) {
    # Exit 0 says phases ran; an empty document says none did. Whichever is
    # wrong, this is not a measurement and it is not a SKIP either.
    throw ('[CAP-8B] the probe reported success but the document carries no ' +
        'event, no native arrival and no page report')
}

# --- validate + summarize ------------------------------------------------------
# One reader for all four targets: the schema check and the human summary live
# in summarize_audit.ps1, which the Linux and macOS harnesses call the same
# way. -RequireTarget makes THIS target's document mandatory and valid.
$summarizer = Join-Path $PSScriptRoot 'summarize_audit.ps1'
& pwsh -NoProfile -File $summarizer -Path $Output `
    -RequireTarget 'windows-x86_64' -Detail
if ($LASTEXITCODE -ne 0) {
    throw '[CAP-8B] the audit document failed its schema validation'
}

$verdict = "MEASURED - windows-x86_64 audit written to $JsonPath"
if ($env:GITHUB_STEP_SUMMARY) {
    "### CAP-8B audit probe (measurement only)`n$verdict" |
        Out-File -Append $env:GITHUB_STEP_SUMMARY
}
Write-Host "[CAP-8B] $verdict"
Write-Host '[CAP-8B] run_audit_win: AUDIT COMPLETE (measurement only, never a gate)'
