# CAP-6b3 CI TEARDOWN: drain the Fixed Runtime's own browser processes before
# the uninstaller runs.
#
# THIS IS TEST-HARNESS PROCESS LIFECYCLE, NOT PRODUCT CODE. Nothing here
# touches the Fixed Runtime selection, the WebView2 locks, Inno's semantics,
# the CAP-13 profiles or any production source. It exists because the CAP-6b3
# gate launches three applications that each spawn a browser image INSIDE the
# bundled tree, and then uninstalls - with nothing in between that waits for
# those processes to exit.
#
# THE MEASURED DEFECT, hosted run 33163186945 on commit 5dc1754, Windows,
# twice on the identical commit:
#
#     uninstall left 11 file(s) behind: dxcompiler.dll, dxil.dll, ffmpeg.dll,
#                                       mip_core_gn.dll, msedge_elf.dll
#     uninstall left 8 file(s) behind:  ffmpeg.dll, msedge_elf.dll, msedge.dll,
#                                       msedgewebview2.exe, mspdf.dll
#
# A DIFFERENT subset each time, every member a browser image or one of its
# DLLs. Windows cannot delete a mapped image; the Inno uninstaller reports
# success anyway; gate 9's 300-second poll for an empty directory then never
# converges. The poll was doing a job it was never designed for - it is a
# VERIFICATION of cleanup, and it had become the only thing waiting for the
# browser to shut down.
#
# ---------------------------------------------------------------------------
# WHY THE SELECTION IS BY PATH AND NEVER BY NAME
# ---------------------------------------------------------------------------
#
# A hosted runner carries unrelated Evergreen WebView2 processes - the CAP-6b1
# and CAP-6b2 gates in the same job depend on Evergreen being present and
# usable, and gate 8's whole no-fallback proof is only meaningful BECAUSE this
# machine has one. So `taskkill /IM msedgewebview2.exe` and
# `Stop-Process -Name msedgewebview2` are not blunt versions of this fix; they
# are a different, wrong fix that would break the gates around it.
#
# Every process considered here is selected by its EXECUTABLE IMAGE PATH lying
# under one root that belongs to this test installation, compared on a
# component boundary. A sibling directory that merely shares the root as a
# string prefix (`...x64-evil\`) is not under it - the same hazard, and the
# same anchoring, that gate 7's containment compare already documents.
#
# The path is re-checked AT KILL TIME against a fresh CIM record, because a
# PID observed a moment ago may have been recycled to something unrelated.
#
# ---------------------------------------------------------------------------
# WHAT IS INJECTABLE, AND WHY
# ---------------------------------------------------------------------------
#
# The selection rule, the drain loop, termination and sleeping are separate,
# and the loop takes them as scriptblocks. That is what lets
# check_wv2procdrain.ps1 prove the interesting cases deterministically - a
# process that vanishes mid-inspection, a new matching child appearing on the
# next sweep, a timeout with a survivor - none of which can be staged against
# a real browser.

# NO Set-StrictMode HERE, and that is not an oversight. This file is
# DOT-SOURCED into run_fixed_setup_gates.ps1, and `Set-StrictMode` applies to
# the CALLER'S scope - MEASURED: a dot-sourced `Set-StrictMode -Version
# Latest` makes the sourcing script throw on the next missing property. That
# gate is 590 lines that have never run under strict mode, and gates 9 and 10
# come after the drain call, so shipping it here would have turned the gate
# red for a reason with nothing to do with process teardown. The functions
# below guard every property access with try/catch and need no strict mode of
# their own; check_wv2procdrain.ps1 sets it for itself, where it is that
# script's own choice.

# Canonicalise for comparison, or return '' when the path cannot be read or
# resolved. An unreadable path must never be treated as matching: this
# function is the only thing standing between a drain and a global kill.
function ConvertTo-PWebComparablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        return [System.IO.Path]::GetFullPath($Path.Replace('/', '\'))
    }
    catch {
        return ''
    }
}

# True when Path lies strictly underneath Root, on a COMPONENT boundary.
#
# The trailing separator is the whole rule: without it
# `...\Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64-evil\x.exe`
# would read as inside
# `...\Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64`.
# Windows paths are compared case-insensitively, ordinally - never with a
# culture-aware comparison.
function Test-PWebPathUnderRoot {
    param([string]$Path, [string]$Root)
    $p = ConvertTo-PWebComparablePath $Path
    $r = ConvertTo-PWebComparablePath $Root
    if (($p -eq '') -or ($r -eq '')) { return $false }
    $prefix = $r.TrimEnd('\') + '\'
    return $p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# The selection rule, over records rather than over the live machine.
#
# A record is anything carrying ProcessId, ParentProcessId, ExecutablePath and
# (for diagnostics only) CommandLine. Name is NOT part of the decision: the
# caller has already narrowed the enumeration, and a name that matched here
# would be a second, weaker rule.
function Select-PWebScopedProcess {
    param([object[]]$Processes, [string]$Root)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Processes)) {
        if ($null -eq $p) { continue }
        $image = ''
        try { $image = [string]$p.ExecutablePath } catch { $image = '' }
        if (Test-PWebPathUnderRoot $image $Root) { $out.Add($p) }
    }
    # A PLAIN return, and every call site wraps in @(). The `,$array` idiom
    # was tried here and is WRONG for a function whose result is consumed as
    # `@(f ...)`: MEASURED, `@(f)` where f does `return ,$array` is Count 1 for
    # every input size, because the comma's outer wrapper is what the pipeline
    # unrolls and @() then collects the inner array as ONE item. It made an
    # empty result look like one match - which, in a function that decides what
    # may be terminated, is the single worst way to be wrong. `return $array`
    # plus `@()` at the call site is 0 for empty and N for N.
    return $out.ToArray()
}

# The live enumeration. CIM gives ExecutablePath and ParentProcessId, which
# Get-Process does not; CommandLine is retrieved because the objective asks
# for it in the record, and is deliberately NOT printed anywhere - a WebView2
# command line carries user profile paths.
function Get-PWebScopedProcess {
    param([string[]]$Names, [string]$Root)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($Names)) {
        $safe = $name.Replace("'", "''")
        $found = @()
        try {
            $found = @(Get-CimInstance Win32_Process -Filter "Name='$safe'" `
                -ErrorAction SilentlyContinue)
        }
        catch {
            # an enumeration that cannot run is not evidence of an empty
            # machine; the caller's bounded loop will try again
            $found = @()
        }
        foreach ($f in $found) { $all.Add($f) }
    }
    return @(Select-PWebScopedProcess -Processes $all.ToArray() -Root $Root)
}

# Terminate ONE already-path-matched process, re-verifying its image first.
# Returns $true when the process is gone afterwards (killed, or it had already
# exited - both are success for a drain).
function Stop-PWebScopedProcess {
    param([object]$Record, [string]$Root)
    $processId = [int]$Record.ProcessId
    $fresh = $null
    try {
        $fresh = Get-CimInstance Win32_Process `
            -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    catch { $fresh = $null }
    if ($null -eq $fresh) { return $true }   # already exited: benign
    # PID REUSE GUARD. Between the sweep and this call the id may belong to
    # something else entirely, so the decision is made again on a fresh
    # record and never on the stale one.
    $image = ''
    try { $image = [string]$fresh.ExecutablePath } catch { $image = '' }
    if (-not (Test-PWebPathUnderRoot $image $Root)) { return $true }
    try {
        Stop-Process -Id $processId -Force -ErrorAction Stop
    }
    catch {
        # a process that exited between the check and the kill is exactly the
        # race this drain exists to ride out
        return $true
    }
    return $true
}

# Drain every process of the given names whose image lies under Root.
#
# Graceful first, then terminate, then RE-ENUMERATE - a browser tears down as
# a tree and a child may appear after the parent is gone, so one snapshot is
# never the answer.
#
# Returns: Remaining (records still matching), Killed (pids), Sweeps,
# GracefulExit (nothing had to be killed), Diagnostics (bounded lines).
function Invoke-PWebProcessDrain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Names = @('msedgewebview2.exe'),
        [int]$GraceMs = 8000,
        [int]$TimeoutMs = 90000,
        [int]$PollMs = 500,
        [scriptblock]$Enumerator = $null,
        [scriptblock]$Terminator = $null,
        [scriptblock]$Sleeper = $null
    )
    $enumerate = {
        if ($null -ne $Enumerator) { return @($Enumerator.Invoke($Names, $Root)) }
        return @(Get-PWebScopedProcess -Names $Names -Root $Root)
    }
    $sleep = {
        param($ms)
        if ($null -ne $Sleeper) { [void]$Sleeper.Invoke($ms) }
        else { Start-Sleep -Milliseconds $ms }
    }
    $diag = New-Object System.Collections.Generic.List[string]
    $killed = New-Object System.Collections.Generic.List[int]
    $sweeps = 0
    $elapsed = 0

    # --- graceful window: the applications have exited, so the browser tree
    # is usually already unwinding on its own. Kill nothing yet.
    $current = @(& $enumerate)
    $sweeps++
    $graceLeft = $GraceMs
    while (($current.Count -gt 0) -and ($graceLeft -gt 0)) {
        & $sleep $PollMs
        $graceLeft -= $PollMs
        $elapsed += $PollMs
        $current = @(& $enumerate)
        $sweeps++
    }
    $gracefulExit = ($current.Count -eq 0)

    # --- forced window: terminate the exact path-matched set, then look again
    while (($current.Count -gt 0) -and ($elapsed -lt $TimeoutMs)) {
        foreach ($p in $current) {
            $processId = 0
            $parentId = 0
            $image = ''
            try { $processId = [int]$p.ProcessId } catch { $processId = 0 }
            try { $parentId = [int]$p.ParentProcessId } catch { $parentId = 0 }
            try { $image = [string]$p.ExecutablePath } catch { $image = '' }
            if ($processId -le 0) { continue }
            if ($diag.Count -lt 64) {
                $diag.Add("WV2DRAIN kill pid=$processId ppid=$parentId image=$image")
            }
            if ($null -ne $Terminator) { [void]$Terminator.Invoke($p, $Root) }
            else { [void](Stop-PWebScopedProcess -Record $p -Root $Root) }
            if (-not $killed.Contains($processId)) { $killed.Add($processId) }
        }
        & $sleep $PollMs
        $elapsed += $PollMs
        $current = @(& $enumerate)
        $sweeps++
    }

    return [pscustomobject]@{
        Remaining    = $current
        Killed       = $killed.ToArray()
        Sweeps       = $sweeps
        GracefulExit = $gracefulExit
        Diagnostics  = $diag.ToArray()
    }
}

# The gate-facing wrapper: drain, report, and REFUSE rather than proceed.
#
# A drain that gave up quietly would turn gate 9 into a cleanup step that
# cannot fail, which is the opposite of what it is for. If the matching set is
# still non-empty the caller must not run the uninstaller at all - what it
# would then be testing is not uninstall cleanup.
function Assert-PWebProcessDrained {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Names = @('msedgewebview2.exe'),
        [string]$What = 'bundled runtime',
        [int]$GraceMs = 8000,
        [int]$TimeoutMs = 90000,
        [scriptblock]$Enumerator = $null,
        [scriptblock]$Terminator = $null,
        [scriptblock]$Sleeper = $null
    )
    $r = Invoke-PWebProcessDrain -Root $Root -Names $Names -GraceMs $GraceMs `
        -TimeoutMs $TimeoutMs -Enumerator $Enumerator -Terminator $Terminator `
        -Sleeper $Sleeper
    foreach ($line in $r.Diagnostics) { Write-Host $line }
    if ($r.Remaining.Count -gt 0) {
        $rows = @($r.Remaining | ForEach-Object {
            $rid = 0; $rimg = ''
            try { $rid = [int]$_.ProcessId } catch { $rid = 0 }
            try { $rimg = [string]$_.ExecutablePath } catch { $rimg = '' }
            "pid=$rid image=$rimg"
        })
        throw ("WV2DRAIN FAILED: $($r.Remaining.Count) $What process(es) still " +
            "hold the installed tree after $($r.Sweeps) sweep(s): " +
            ($rows -join '; '))
    }
    Write-Host ("WV2DRAIN ok ($What): sweeps=$($r.Sweeps) " +
        "graceful=$($r.GracefulExit) terminated=$($r.Killed.Count)")
    return $r
}
