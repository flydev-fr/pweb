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
