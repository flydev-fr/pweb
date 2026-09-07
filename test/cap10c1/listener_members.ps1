# CAP-10C1: the MEMBERSHIP-SCOPED listening-socket sampler.
#
# CAP-10C0 ledgered this: its sampler, and the CAP-10B1/B2 proofs' before it,
# measured the APPLICATION pid alone. A browser helper that opened a socket
# was outside the measurement, and `run_listener_count = 0` is an ABSOLUTE
# PIN - so the pin was true of one process rather than of the tree. This file
# is the honest upgrade, and it is dot-sourced by both the CAP-10C1 gate and
# the CAP-10C0 one, so one rule is measured in both places.
#
# MEMBERSHIP, per platform, and what each one really is:
#
#   POSIX     EXACT. The CAP-10C0 engine puts the child at the head of its
#             own process group, so "pgid == the application pid" is the job
#             the supervisor owns, stated by the kernel.
#   Windows   the transitive DESCENDANT CLOSURE of the application pid,
#             recomputed on every pass. The real membership is the Job
#             Object's, and only `pweb` holds that handle - a gate cannot ask
#             for it. The closure is what is reachable from outside, it is
#             recomputed rather than cached so a helper started late is seen,
#             and `listener_sampler_scope` records which of the two answered.
#
# A SAMPLER THAT NEVER SAMPLED reports a clean zero for any host, so every
# caller is expected to require MembersSeen > 0 as well as Max = 0.
#
# DOT-SOURCED, AND THEREFORE FUNCTIONS AND NOTHING ELSE. No Set-StrictMode,
# no $ErrorActionPreference, no Set-Location, no $ProgressPreference: each of
# those is a side effect on a caller that never asked for it, and CAP-6b3
# MEASURED a dot-sourced Set-StrictMode reddening 590 lines of an unrelated
# gate.

function Get-PWebTreeMembers {
    param([int]$RootPid)
    $members = @($RootPid)
    try {
        if ($IsWindows) {
            $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{
                        Pid = [int]$_.ProcessId
                        Parent = [int]$_.ParentProcessId
                    }
                })
            # a breadth-first closure, bounded by the process count so a
            # pid-reuse cycle can never spin it
            $frontier = @($RootPid)
            for ($depth = 0; ($depth -lt 32) -and ($frontier.Count -gt 0); $depth++) {
                $next = @()
                foreach ($p in $all) {
                    if (($frontier -contains $p.Parent) -and
                        (-not ($members -contains $p.Pid))) {
                        $members += $p.Pid
                        $next += $p.Pid
                    }
                }
                $frontier = $next
            }
        } else {
            # the process GROUP, which on POSIX is exactly what the engine
            # created and exactly what SIGTERM reaches
            foreach ($line in (ps -axo pid=,pgid= 2>$null)) {
                $f = ($line.Trim() -split '\s+')
                if (($f.Count -ge 2) -and ([int]$f[1] -eq $RootPid)) {
                    $childPid = [int]$f[0]
                    if (-not ($members -contains $childPid)) {
                        $members += $childPid
                    }
                }
            }
        }
    } catch { }
    return $members
}

function Get-PWebListenerCount {
    param([int]$OwnerPid)
    $n = 0
    try {
        if ($IsWindows) {
            $n = @(Get-NetTCPConnection -State Listen -OwningProcess $OwnerPid `
                    -ErrorAction SilentlyContinue).Count +
                 @(Get-NetUDPEndpoint -OwningProcess $OwnerPid `
                    -ErrorAction SilentlyContinue).Count
        } elseif ($IsLinux) {
            $n = @(ss -ltnp 2>$null | Select-String "pid=$OwnerPid,").Count +
                 @(ss -lunp 2>$null | Select-String "pid=$OwnerPid,").Count
        } else {
            $n = @(lsof -nP -p $OwnerPid 2>$null |
                Select-String '\(LISTEN\)|\sUDP\s').Count
        }
    } catch { $n = 0 }
    return $n
}

# =============================================================================
# CAP-11B (ledger 11B-13): EVERY SAMPLED LISTENER IS TYPED BY ITS OWNER IMAGE.
#
# The count above answers "did any member of the tree listen", which was the
# right question while the answer was always no. On hosted run 34118821940 the
# Windows leg answered yes and the gate could say nothing else: one number, no
# owner, no port. A browser engine that opens a local socket of its own is not
# the product opening one, and a gate that cannot tell them apart either fails
# on the engine's behaviour or has to be relaxed for everything.
#
#   host     the application itself, or an image under its own directory
#   browser  a ratified engine image, PATH-SCOPED to a ratified engine root
#   unknown  everything else
#
# THE BROWSER TYPE IS NEVER GRANTED BY NAME ALONE. CAP-6b3 ratified selection
# by executable image path under one root and CAP-11A's FL2 refuses any
# name-scoped kill; the same discipline applies to an exemption. A process
# CALLED msedgewebview2.exe from somewhere nobody ratified is `unknown`, which
# is visible, rather than `browser`, which is excused.
#
# `unknown` is OBSERVED, not gated. A gate that failed on "I could not classify
# this" would reintroduce exactly the flake this replaces; what stops an
# unclassified host listener hiding there is that the caller must first prove
# it resolved the host's own image (Get-PWebTypedListeners returns
# HostImageResolved, and every caller requires it).

# The engine images this project ships against, per platform. Basenames only -
# the path half of the rule is Get-PWebEngineRoots.
function Get-PWebEngineImageNames {
    if ($IsWindows) { return @('msedgewebview2.exe') }
    if ($IsLinux) { return @('WebKitWebProcess', 'WebKitNetworkProcess', 'WebKitGPUProcess') }
    return @('com.apple.WebKit.WebContent', 'com.apple.WebKit.Networking',
             'com.apple.WebKit.GPU', 'com.apple.WebKit.WebContent.Sandboxed')
}

# The roots a ratified engine image may legitimately live under. `HostDir` is
# one of them on purpose: a Fixed Runtime deployment puts the engine beside the
# application, and that engine is still the engine.
function Get-PWebEngineRoots {
    param([string]$HostDir)
    $roots = New-Object System.Collections.Generic.List[string]
    if ($HostDir) { [void]$roots.Add($HostDir) }
    if ($IsWindows) {
        foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:ProgramW6432)) {
            if ($pf) { [void]$roots.Add((Join-Path $pf 'Microsoft\EdgeWebView')) }
        }
        if ($env:LOCALAPPDATA) {
            [void]$roots.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeWebView'))
        }
    }
    elseif ($IsLinux) {
        foreach ($d in '/usr/lib', '/usr/libexec', '/usr/local/lib', '/snap') {
            [void]$roots.Add($d)
        }
    }
    else {
        foreach ($d in '/System/Library/Frameworks/WebKit.framework',
                       '/System/Library/StagedFrameworks',
                       '/System/Volumes/Preboot/Cryptexes') {
            [void]$roots.Add($d)
        }
    }
    return $roots.ToArray()
}

# Component-boundary containment, the CAP-6b3 spelling. `C:\a\bc` is NOT under
# `C:\a\b`, and a comparison that forgot the separator would say it was.
function Test-PWebImageUnder {
    param([string]$Image, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Image) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $i = [System.IO.Path]::GetFullPath($Image)
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    } catch { return $false }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $i.StartsWith("$r$sep", $cmp)
}

# The executable image of a pid, or '' when it cannot be read. '' is a real
# answer here - a process can exit between the enumeration and this call - and
# it types the record `unknown` rather than throwing.
function Get-PWebProcessImage {
    param([int]$OwnerPid)
    $image = ''
    try {
        if ($IsWindows) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$OwnerPid" -ErrorAction SilentlyContinue
            if ($p) { $image = [string]$p.ExecutablePath }
        }
        elseif ($IsLinux) {
            $link = "/proc/$OwnerPid/exe"
            if (Test-Path -LiteralPath $link) {
                $image = [string](Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue).Target
            }
            if (-not $image) { $image = (ps -p $OwnerPid -o comm= 2>$null | Select-Object -First 1) }
        }
        else {
            $image = (ps -p $OwnerPid -o comm= 2>$null | Select-Object -First 1)
        }
    } catch { $image = '' }
    if ($null -eq $image) { return '' }
    return ([string]$image).Trim()
}

# One record per LISTENING socket the pid owns: proto and address beside it, so
# an observation names what it saw rather than counting it.
function Get-PWebListenerRecords {
    param([int]$OwnerPid)
    $out = New-Object System.Collections.Generic.List[object]
    try {
        if ($IsWindows) {
            foreach ($t in @(Get-NetTCPConnection -State Listen -OwningProcess $OwnerPid -ErrorAction SilentlyContinue)) {
                [void]$out.Add([pscustomobject]@{
                    Proto = 'tcp'; Address = "$($t.LocalAddress):$($t.LocalPort)" })
            }
            foreach ($u in @(Get-NetUDPEndpoint -OwningProcess $OwnerPid -ErrorAction SilentlyContinue)) {
                [void]$out.Add([pscustomobject]@{
                    Proto = 'udp'; Address = "$($u.LocalAddress):$($u.LocalPort)" })
            }
        }
        elseif ($IsLinux) {
            foreach ($spec in @(@('tcp', '-ltnp'), @('udp', '-lunp'))) {
                foreach ($line in @(ss $spec[1] 2>$null)) {
                    if ($line -notmatch "pid=$OwnerPid,") { continue }
                    $f = @($line.Trim() -split '\s+')
                    # `ss -ltnp` columns, MEASURED rather than assumed:
                    #   LISTEN 0 4096 127.0.0.1:46325 0.0.0.0:* users:(("pwsh",pid=432,fd=164))
                    #      0   1  2         3            4              5
                    # Index 3 is the LOCAL address; 4 is the peer, and reading
                    # it reported every listener as `0.0.0.0:*` - an address
                    # that names nothing, in an observation whose whole job is
                    # to name what it saw.
                    $addr = if ($f.Count -ge 4) { $f[3] } else { '?' }
                    [void]$out.Add([pscustomobject]@{ Proto = $spec[0]; Address = $addr })
                }
            }
        }
        else {
            foreach ($line in @(lsof -nP -p $OwnerPid 2>$null)) {
                if ($line -notmatch '\(LISTEN\)' -and $line -notmatch '\sUDP\s') { continue }
                $f = @($line.Trim() -split '\s+')
                $proto = if ($line -match '\sUDP\s') { 'udp' } else { 'tcp' }
                $addr = if ($f.Count -ge 9) { $f[8] } else { '?' }
                [void]$out.Add([pscustomobject]@{ Proto = $proto; Address = $addr })
            }
        }
    } catch { }
    # PLAIN `.ToArray()`, never `, $out.ToArray()`. The comma operator wraps,
    # so an EMPTY result came back as one element containing an empty array -
    # the caller counted one listener and then read `.Proto` and `.Address` off
    # System.Array, which resolves to its members and printed a method
    # signature where a socket should have been. Emitting the elements lets the
    # caller's own `@(...)` produce 0, 1 or n, which is what it expects.
    return $out.ToArray()
}

# host | browser | unknown, in that order of test. The engine test runs FIRST
# so a Fixed Runtime engine sitting beside the application is typed as the
# engine it is rather than as the product.
function Get-PWebListenerOwnerKind {
    param([string]$Image, [string]$HostImage, [string]$HostDir)
    if ([string]::IsNullOrWhiteSpace($Image)) { return 'unknown' }
    $base = ''
    try { $base = [System.IO.Path]::GetFileName($Image) } catch { $base = $Image }
    $names = Get-PWebEngineImageNames
    $nameMatch = $false
    foreach ($n in $names) {
        if ($IsWindows) { if ($base -ieq $n) { $nameMatch = $true } }
        elseif ($base -ceq $n) { $nameMatch = $true }
    }
    if ($nameMatch) {
        foreach ($root in (Get-PWebEngineRoots -HostDir $HostDir)) {
            if (Test-PWebImageUnder -Image $Image -Root $root) { return 'browser' }
        }
        # a ratified engine NAME from an unratified place is not an exemption
        return 'unknown'
    }
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($HostImage -and $Image.Equals($HostImage, $cmp)) { return 'host' }
    if (Test-PWebImageUnder -Image $Image -Root $HostDir) { return 'host' }
    return 'unknown'
}

# The whole sampling pass for one tree, typed. Callers gate on Host and record
# Browser/Unknown; HostImageResolved is what stops the typing being vacuous.
function Get-PWebTypedListeners {
    param([int]$RootPid)
    $hostImage = Get-PWebProcessImage -OwnerPid $RootPid
    $hostDir = ''
    if ($hostImage) {
        try { $hostDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($hostImage)) } catch { $hostDir = '' }
    }
    $members = @(Get-PWebTreeMembers -RootPid $RootPid)
    $counts = @{ host = 0; browser = 0; unknown = 0 }
    $detail = New-Object System.Collections.Generic.List[string]
    foreach ($m in $members) {
        $recs = @(Get-PWebListenerRecords -OwnerPid $m)
        if ($recs.Count -eq 0) { continue }
        $image = Get-PWebProcessImage -OwnerPid $m
        $kind = Get-PWebListenerOwnerKind -Image $image -HostImage $hostImage -HostDir $hostDir
        $counts[$kind] += $recs.Count
        foreach ($r in $recs) {
            [void]$detail.Add(("{0} pid={1} image={2} {3} {4}" -f $kind, $m,
                $(if ($image) { $image } else { '<unreadable>' }), $r.Proto, $r.Address))
        }
    }
    return [pscustomobject]@{
        MembersSeen       = $members.Count
        HostImage         = $hostImage
        HostImageResolved = [bool]$hostImage
        Host_             = $counts['host']
        Browser           = $counts['browser']
        Unknown           = $counts['unknown']
        Detail            = $detail.ToArray()
    }
}

function Get-PWebConnectionCount {
    param([int]$OwnerPid)
    $n = 0
    try {
        if ($IsWindows) {
            $n = @(Get-NetTCPConnection -OwningProcess $OwnerPid `
                    -ErrorAction SilentlyContinue |
                Where-Object { $_.State -ne 'Listen' }).Count
        } elseif ($IsLinux) {
            $n = @(ss -tnp 2>$null | Select-String "pid=$OwnerPid,").Count
        } else {
            $n = @(lsof -nP -p $OwnerPid 2>$null |
                Select-String '\sTCP\s' |
                Where-Object { $_ -notmatch 'LISTEN' }).Count
        }
    } catch { $n = 0 }
    return $n
}

function Get-PWebSamplerScope {
    if ($IsWindows) { return 'descendant_closure' }
    return 'process_group'
}
