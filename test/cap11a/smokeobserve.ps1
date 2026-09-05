# CAP-11A: what a hosted-Windows GUI smoke can OBSERVE about a non-report, and
# the rule that turns those observations into one typed cause.
#
# THE FLAKE (ledger B1-10, B2-16, D1-15). Intermittently, on hosted Windows only,
# a GUI smoke prints exactly one line - `FAIL: page/runtime verdict was not
# successful (state=0; 0=no report received)` - and nothing else. The same binary
# passes on a dev host, the same step passed forty minutes earlier on the same
# runner image, and a re-run is green. Three sightings across two unrelated
# smokes say the shared thing is the bounded wait for the page's report, not
# either example. What has never been established is WHICH of three things
# happened: the page never loaded, it loaded but its script never ran, or it ran
# and missed the window.
#
# WHY THE PAGE CANNOT SIMPLY SAY. The `state=0` line is printed by
# `examples/08-release/releaseapp.pas` and its CAP-5 siblings, and `examples/` is
# frozen for this shard. A page-side progress report would be a product change.
# So the cause is derived from what a DRIVER can watch from outside the process,
# and the rule below is stated so a reader can disagree with the inference
# without losing the measurements: every observation is recorded beside the
# verdict, which is the CAP-10E long-path lesson applied (a leg that emitted only
# its outcome would have carried a false explanation into an artifact).
#
# UNDETERMINED IS A LEGAL ANSWER, and the honest one whenever the discriminating
# observation is absent. This never guesses.
#
# THE SAMPLER IS ADDITIVE AND CANNOT FAIL A GATE. The verdict path of each driver
# is untouched: the smoke still runs exactly as it did, and everything here is a
# background observer whose own failure is swallowed and recorded as
# `observer_error`. An instrumentation that could turn a green gate red would be
# a worse defect than the one it was added to explain.

function Start-PWebSmokeObserver {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,   # e.g. 'releaseapp'
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$UserDataDir = '',                            # WebView2 profile, if known
        [int]$PollMs = 250,
        # bounded by the caller's own step budget rather than by a constant
        [int]$DeadlineSeconds = 600
    )
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $startUtc = [DateTime]::UtcNow
    $baseline = 0
    try { $baseline = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue).Count } catch { $baseline = 0 }
    $state = [pscustomobject]@{
        OutFile     = $OutFile
        StartUtc    = $startUtc
        UserDataDir = $UserDataDir
        Baseline    = $baseline
        Job         = $null
        Error       = ''
    }
    try {
        $state.Job = Start-Job -ScriptBlock {
            param($ProcName, $Out, $Poll, $Base, $Deadline)
            $t0 = [DateTime]::UtcNow
            $seenHost = $false
            while ([DateTime]::UtcNow -lt $Deadline) {
                $ms = [int](([DateTime]::UtcNow - $t0).TotalMilliseconds)
                $host_n = 0; $title = ''; $wv2 = 0
                try {
                    $p = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue)
                    $host_n = $p.Count
                    if ($host_n -gt 0) {
                        $seenHost = $true
                        try { $title = [string]$p[0].MainWindowTitle } catch { $title = '' }
                    }
                } catch { $host_n = -1 }
                try { $wv2 = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue).Count } catch { $wv2 = -1 }
                # STREAMED, not accumulated. `Stop-PWebSmokeObserver` waits five
                # seconds and then stops the job; a list returned only as the
                # last statement would be discarded whole, and `samples=0` types
                # every cause `undetermined` - the instrumentation reporting
                # nothing about the flake it was built for.
                Write-Output "t=$ms host=$host_n wv2=$wv2 wv2_delta=$($wv2 - $Base) title=`"$title`""
                if ($seenHost -and $host_n -eq 0) { break }
                Start-Sleep -Milliseconds $Poll
            }
        } -ArgumentList $ProcessName, $OutFile, $PollMs, $baseline, ([DateTime]::UtcNow.AddSeconds($DeadlineSeconds))
    } catch {
        $state.Error = $_.Exception.Message
    }
    return $state
}

function Stop-PWebSmokeObserver {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Output = '',
        [int]$ExitCode = 0,
        [int]$AutocloseMs = 0,
        # A TESTABILITY SEAM, and the reason it is here rather than in a test
        # double: the cause rule below is the thing a seeded case must exercise,
        # and it reads the samples. Supplying them directly lets
        # `check_cap11a_cases.ps1` drive every branch through THIS code rather
        # than through a copy of it - the difference between testing the rule
        # and testing a paraphrase of the rule.
        [string[]]$Samples = $null
    )
    $rows = @()
    if ($null -ne $Samples) { $rows = @($Samples) }
    elseif ($State.Job) {
        try {
            Wait-Job -Job $State.Job -Timeout 5 | Out-Null
            Stop-Job -Job $State.Job -ErrorAction SilentlyContinue
            $rows = @(Receive-Job -Job $State.Job -ErrorAction SilentlyContinue)
            Remove-Job -Job $State.Job -Force -ErrorAction SilentlyContinue
        } catch { $State.Error = $_.Exception.Message }
    }
    $elapsedMs = [int](([DateTime]::UtcNow - $State.StartUtc).TotalMilliseconds)

    # --- the observations -----------------------------------------------------
    $wv2Max = 0
    $hostSeen = $false
    foreach ($r in $rows) {
        if ($r -match 'wv2_delta=(-?\d+)') { $d = [int]$Matches[1]; if ($d -gt $wv2Max) { $wv2Max = $d } }
        if ($r -match 'host=([1-9]\d*)') { $hostSeen = $true }
    }
    $profileTouched = 'unmeasured'
    $scriptCacheTouched = 'unmeasured'
    if ($State.UserDataDir) {
        if (Test-Path -LiteralPath $State.UserDataDir) {
            try {
                $after = @(Get-ChildItem -LiteralPath $State.UserDataDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTimeUtc -ge $State.StartUtc })
                $profileTouched = if ($after.Count -gt 0) { 'true' } else { 'false' }
                # Code Cache/js is written when the engine COMPILED JavaScript.
                # Its presence is the one direct signal that script ran at all.
                $js = @($after | Where-Object { $_.FullName -match '(?i)Code Cache\\js' })
                $scriptCacheTouched = if ($js.Count -gt 0) { 'true' } else { 'false' }
            } catch { $profileTouched = 'observer_error'; $scriptCacheTouched = 'observer_error' }
        } else {
            $profileTouched = 'absent'
            $scriptCacheTouched = 'absent'
        }
    }
    $reportLine = if ($Output -match '(?m)report:') { 'true' } else { 'false' }

    # --- THE RULE, stated ------------------------------------------------------
    # Read top to bottom; the first line that applies is the answer. Every branch
    # names the observation it stands on, and the last one is the honest refusal.
    $cause = 'undetermined'
    if ($reportLine -eq 'true') {
        # the host printed a report and still verdicted state=0: the report
        # arrived, but not inside the window the verdict was taken in
        $cause = 'ran_missed_window'
    } elseif ($scriptCacheTouched -eq 'true') {
        # the engine compiled JavaScript during this run, so the script ran; no
        # report reached the host, which is the same shape by a different route
        $cause = 'ran_missed_window'
    } elseif ($scriptCacheTouched -eq 'false' -and $profileTouched -eq 'true') {
        # the engine wrote profile state but compiled no script: it navigated,
        # and the bundle's script never ran
        $cause = 'loaded_script_never_ran'
    } elseif ($profileTouched -eq 'false' -and $wv2Max -gt 0) {
        # a browser came up and wrote nothing at all: nothing was loaded
        $cause = 'page_never_loaded'
    } elseif ($wv2Max -le 0 -and $hostSeen) {
        # no engine process was ever observed beside the host
        $cause = 'page_never_loaded'
    }

    $obs = [ordered]@{
        cause                 = $cause
        report_line_seen      = $reportLine
        host_process_seen     = $hostSeen
        engine_processes_max  = $wv2Max
        profile_touched       = $profileTouched
        script_cache_touched  = $scriptCacheTouched
        elapsed_ms            = $elapsedMs
        autoclose_ms          = $AutocloseMs
        exit_code             = $ExitCode
        samples               = $rows.Count
        observer_error        = $State.Error
    }
    $lines = @("cause=$cause")
    foreach ($k in $obs.Keys) { if ($k -ne 'cause') { $lines += "$k=$($obs[$k])" } }
    $lines += '--- samples ---'
    $lines += $rows
    [System.IO.File]::WriteAllText($State.OutFile, (($lines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[cap11a] smoke observation: cause=$cause engine_max=$wv2Max profile=$profileTouched script_cache=$scriptCacheTouched samples=$($rows.Count)"
    return $obs
}
