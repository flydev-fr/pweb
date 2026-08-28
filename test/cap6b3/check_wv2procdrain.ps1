# CAP-6b3: deterministic tests for the Fixed Runtime process drain.
#
# Checkout-only. No install, no browser, no toolchain, no network - the whole
# point is that the interesting cases cannot be staged against a real browser:
# a process that vanishes mid-inspection, a new matching child appearing on
# the next sweep, a timeout with a survivor, a sibling directory that shares
# the root as a string prefix.
#
# The drain takes its enumerator, terminator and sleeper as scriptblocks, so
# every one of those is an injected record set here and the loop under test is
# the same loop that runs on the runner.
#
#   T1  a process under the current Fixed Runtime root is selected
#   T1b a mixed set selects exactly the in-tree members (the COUNT is real)
#   T2  a shared Evergreen process outside the install root is NOT selected
#   T3  a similarly prefixed sibling path is NOT selected
#   T4  case variation in the same Windows path matches
#   T5  an unreadable/empty image path is NOT selected
#   T5c the LIVE enumeration selects nothing under a non-existent root
#   T6  a process that disappears between sweeps is benign
#   T7  a matching child that appears later is found on the next enumeration
#   T8  a timeout with a survivor FAILS, and fails before any uninstall
#   T9  no global process-name termination primitive exists in either script
#   T10 the uninstaller is invoked only after the drain has succeeded
#   T11 the dot-sourced helper leaks no strict mode or preference into the
#       gate that sources it
#
# Usage: pwsh -File test/cap6b3/check_wv2procdrain.ps1

$ErrorActionPreference = 'Stop'
# strictness is THIS script's choice, set here rather than in the dot-sourced
# helper - see T11 and the note at the top of wv2procdrain.ps1
Set-StrictMode -Version Latest
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot 'wv2procdrain.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "  ok   $What" }
    else { Write-Host "  FAIL $What"; $script:failures.Add($What) }
}
function Rec([int]$ProcessId, [string]$Path, [int]$Parent = 4242) {
    return [pscustomobject]@{
        ProcessId       = $ProcessId
        ParentProcessId = $Parent
        ExecutablePath  = $Path
        CommandLine     = 'redacted-in-tests'
    }
}

# the shapes a real runner presents: the per-user install, the versioned tree
# inside it, and the machine-wide Evergreen the other CAP-6b gates rely on
$install = 'C:\Users\runneradmin\AppData\Local\Programs\PWebRelease'
$runtime = Join-Path $install 'runtime\webview2'
$tree = Join-Path $runtime 'Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64'
$evergreen = 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\151.0.4129.78\msedgewebview2.exe'
$sibling = $tree + '-evil\msedgewebview2.exe'

Write-Host '[CAP-6b3] drain selection'

# --- T1 ---------------------------------------------------------------------
$sel = @(Select-PWebScopedProcess -Processes @(
    (Rec 100 (Join-Path $tree 'msedgewebview2.exe'))) -Root $runtime)
Check (($sel.Count -eq 1) -and ($sel[0].ProcessId -eq 100)) `
    'T1 a browser under the Fixed Runtime root is selected'

# T1b THE COUNT ITSELF, over a mixed set. This exists because a first draft
# returned `,$array` to keep an empty result an array, and MEASURED that
# `@(f)` is then Count 1 for EVERY input size - an empty scope read as one
# match, in the function that decides what may be terminated. A live check
# against a host with 12 unrelated Evergreen processes caught it; this test
# is what makes it stay caught.
$mixed = @(Select-PWebScopedProcess -Processes @(
    (Rec 110 (Join-Path $tree 'msedgewebview2.exe')),
    (Rec 111 $evergreen),
    (Rec 112 (Join-Path $tree 'gpu\msedgewebview2.exe'))) -Root $runtime)
Check ($mixed.Count -eq 2) `
    'T1b a mixed set selects EXACTLY the two in-tree processes (count is real)'

# --- T2 ---------------------------------------------------------------------
$sel = @(Select-PWebScopedProcess -Processes @((Rec 200 $evergreen)) -Root $runtime)
Check ($sel.Count -eq 0) `
    'T2 a shared Evergreen browser outside the install root is NOT selected'

# --- T3 ---------------------------------------------------------------------
# the reason the root gets a trailing separator: as a plain string prefix,
# `...x64-evil\` starts with `...x64`
$sel = @(Select-PWebScopedProcess -Processes @((Rec 300 $sibling)) -Root $tree)
Check ($sel.Count -eq 0) `
    'T3 a sibling sharing the root as a string prefix is NOT selected'

# --- T4 ---------------------------------------------------------------------
$shouty = (Join-Path $tree 'MSEDGEWEBVIEW2.EXE').ToUpperInvariant()
$sel = @(Select-PWebScopedProcess -Processes @((Rec 400 $shouty)) -Root $runtime)
Check ($sel.Count -eq 1) 'T4 case variation in the same Windows path matches'
# and it is ordinal-insensitive rather than culture-sensitive
Check (Test-PWebPathUnderRoot ($runtime.ToLowerInvariant() + '\x\y.exe') $runtime) `
    'T4b a lowercased root prefix still matches'

# --- T5 ---------------------------------------------------------------------
$sel = @(Select-PWebScopedProcess -Processes @(
    (Rec 500 ''), (Rec 501 $null), (Rec 502 '   ')) -Root $runtime)
Check ($sel.Count -eq 0) `
    'T5 an unreadable or empty image path is NOT selected'
Check (-not (Test-PWebPathUnderRoot 'anything' '')) `
    'T5b an empty ROOT never matches (no accidental global scope)'

# T5c THE LIVE ENUMERATION, scoped to a root that cannot exist on this host.
# It runs the real CIM path against whatever browsers the machine happens to
# have, and must select NONE of them. This is the check that found the count
# bug above, and it costs one WMI query.
$nowhere = Join-Path ([System.IO.Path]::GetTempPath()) 'pweb-cap6b3-no-such-install'
$live = @(Get-PWebScopedProcess -Names @('msedgewebview2.exe') -Root $nowhere)
Check ($live.Count -eq 0) `
    'T5c the live enumeration selects nothing under a non-existent install root'

Write-Host '[CAP-6b3] drain loop'

# --- T6 ---------------------------------------------------------------------
# the process is there on the first sweep and gone on the second, and the
# terminator reports the "already exited" race the way the real one does
$script:t6Sweep = 0
$r = Invoke-PWebProcessDrain -Root $runtime -GraceMs 0 -TimeoutMs 5000 -PollMs 100 `
    -Sleeper { param($ms) } `
    -Terminator { param($rec, $root) $true } `
    -Enumerator {
        param($names, $root)
        $script:t6Sweep++
        if ($script:t6Sweep -le 1) { return @((Rec 600 (Join-Path $tree 'msedgewebview2.exe'))) }
        return @()
    }
Check (($r.Remaining.Count -eq 0) -and ($r.Killed.Count -le 1)) `
    'T6 a process that disappears between sweeps drains cleanly'

# --- T7 ---------------------------------------------------------------------
# a browser tears down as a TREE: a child can appear after the parent is gone,
# so one snapshot is never the answer
$script:t7Sweep = 0
$script:t7Killed = New-Object System.Collections.Generic.List[int]
$r = Invoke-PWebProcessDrain -Root $runtime -GraceMs 0 -TimeoutMs 5000 -PollMs 100 `
    -Sleeper { param($ms) } `
    -Terminator { param($rec, $root) $script:t7Killed.Add([int]$rec.ProcessId); $true } `
    -Enumerator {
        param($names, $root)
        $script:t7Sweep++
        switch ($script:t7Sweep) {
            1 { return @((Rec 700 (Join-Path $tree 'msedgewebview2.exe'))) }
            2 { return @((Rec 701 (Join-Path $tree 'msedgewebview2.exe'))) }
            default { return @() }
        }
    }
Check (($r.Remaining.Count -eq 0) -and
       ($script:t7Killed -contains 700) -and ($script:t7Killed -contains 701)) `
    'T7 a matching child appearing later is found on the next enumeration'

# --- T8 ---------------------------------------------------------------------
$script:t8Sweeps = 0
$r = Invoke-PWebProcessDrain -Root $runtime -GraceMs 200 -TimeoutMs 1000 -PollMs 100 `
    -Sleeper { param($ms) } `
    -Terminator { param($rec, $root) $true } `
    -Enumerator {
        param($names, $root)
        $script:t8Sweeps++
        return @((Rec 800 (Join-Path $tree 'msedgewebview2.exe')))
    }
Check (($r.Remaining.Count -eq 1) -and ($script:t8Sweeps -gt 1)) `
    'T8 a survivor past the bounded timeout is REPORTED, not ignored'
$threw = $false
try {
    Assert-PWebProcessDrained -Root $runtime -GraceMs 200 -TimeoutMs 1000 `
        -Sleeper { param($ms) } -Terminator { param($rec, $root) $true } `
        -Enumerator { param($names, $root) @((Rec 800 (Join-Path $tree 'msedgewebview2.exe'))) } |
        Out-Null
}
catch { $threw = ($_.Exception.Message -match 'WV2DRAIN FAILED') }
Check $threw 'T8b the gate-facing wrapper THROWS on a survivor'

# a clean set must NOT throw, or the gate could never pass
$threw = $false
try {
    Assert-PWebProcessDrained -Root $runtime -GraceMs 0 -TimeoutMs 1000 `
        -Sleeper { param($ms) } -Terminator { param($rec, $root) $true } `
        -Enumerator { param($names, $root) @() } | Out-Null
}
catch { $threw = $true }
Check (-not $threw) 'T8c an already-empty set drains without throwing'

Write-Host '[CAP-6b3] source rules'

$gatePath = Join-Path $PSScriptRoot 'run_fixed_setup_gates.ps1'
$drainPath = Join-Path $PSScriptRoot 'wv2procdrain.ps1'
$gateSrc = [System.IO.File]::ReadAllText($gatePath)
$drainSrc = [System.IO.File]::ReadAllText($drainPath)

# --- T9 ---------------------------------------------------------------------
# comments in these files DISCUSS the forbidden primitives - that is how they
# explain what they refuse - so the rule is about executable text, and the
# comment lines are stripped before it is applied
function CodeOnly([string]$Text) {
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.TrimStart()
        if ($t.StartsWith('#')) { continue }
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $keep.Add($line.Substring(0, $hash)) } else { $keep.Add($line) }
    }
    return ($keep -join "`n")
}
$gateCode = CodeOnly $gateSrc
$drainCode = CodeOnly $drainSrc
$globalKills = @(
    'taskkill',
    'Stop-Process\s+(-\w+\s+)*-Name',
    'Stop-Process\s+(-\w+\s+)*-ProcessName',
    'Get-Process\s+(-\w+\s+)*-Name\s+\S*msedgewebview2',
    'Stop-Process\s+-InputObject\s+\(Get-Process'
)
$globalHits = 0
foreach ($rx in $globalKills) {
    foreach ($pair in @(@('run_fixed_setup_gates.ps1', $gateCode),
                        @('wv2procdrain.ps1', $drainCode))) {
        if ($pair[1] -match $rx) {
            $globalHits++
            Write-Host "  FAIL global kill primitive '$rx' in $($pair[0])"
        }
    }
}
Check ($globalHits -eq 0) `
    'T9 no global process-name termination primitive exists in either script'
# and the one termination call there IS must be by id
Check ($drainCode -match 'Stop-Process\s+-Id\s+\$processId\s+-Force') `
    'T9b the single termination call targets an explicit PID'

# --- T10 --------------------------------------------------------------------
# ORDER IS THE CONTRACT: the drain must be complete before the uninstaller is
# started, and the drain throws when it is not
$drainAt = $gateCode.IndexOf('Assert-PWebProcessDrained')
$uninsAt = $gateCode.IndexOf('Invoke-Bounded $unins')
Check ($drainAt -ge 0) 'T10a the gate calls the drain'
Check ($uninsAt -ge 0) 'T10b the gate invokes the uninstaller'
Check (($drainAt -ge 0) -and ($uninsAt -ge 0) -and ($drainAt -lt $uninsAt)) `
    'T10 the uninstaller is invoked only after the drain'
# both roots are inside this installation - never a machine-wide path
Check (($gateCode -match 'Assert-PWebProcessDrained -Root \$InstallDir') -and
       ($gateCode -match 'Assert-PWebProcessDrained -Root \$InstalledRuntime')) `
    'T10c the drain roots are this installation, not a machine-wide path'

# --- T11 --------------------------------------------------------------------
# THE HELPER IS DOT-SOURCED, so anything it sets lands in the GATE's scope.
# MEASURED: a dot-sourced `Set-StrictMode -Version Latest` makes the sourcing
# script throw on its next missing property - and gates 9 and 10 run after the
# drain call in a 590-line script that has never run under strict mode. This
# test exists because that shipped once.
Check ($drainCode -notmatch 'Set-StrictMode') `
    'T11 the dot-sourced helper imposes no strict mode on the gate that sources it'
# and the helper must not change any other caller-visible preference either
foreach ($leak in 'ErrorActionPreference', 'Set-Location', 'Push-Location',
                  'ProgressPreference') {
    Check ($drainCode -notmatch [regex]::Escape($leak)) `
        "T11b the helper does not set $leak in its caller's scope"
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host "DRAIN TEST FAILED: $f" }
    throw "CAP-6b3 drain tests FAILED: $($failures.Count)"
}
Write-Host ('[CAP-6b3] drain tests PASS - selection is path-scoped and ' +
    'component-anchored, the loop rides process churn, and no global ' +
    'process-name kill exists')
