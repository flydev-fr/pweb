# CAP-11B: the ref input changed nothing when it is absent, and the locks
# never move.
#
# CAP-11B added ONE optional input to four scripts that the whole matrix builds
# through. The claim "the pinned path is unchanged" is worth nothing as a
# sentence, so this makes it a COMPARISON: each script has a `--print-plan`
# mode that resolves every path, flag and assertion mode, prints them and exits
# 0 having touched nothing, and the five pinned plans are compared BYTE FOR
# BYTE against test/cap11b/pinned-plan.expected.txt.
#
# THE PLAN, NOT THE SOURCE. Adding an input necessarily changes the source of
# these scripts; what must not change is what they DO when nobody passes it -
# which is exactly what the plan states and what the four platform legs then
# exercise for real on every push.
#
# The second half is the lock invariant: `webview.lock` and `mormot.lock` are
# digested before and after, and this gate also refuses if the watcher's own
# sources contain a write to either.
#
# `-Record` REWRITES the expected file. It is not a repair: re-recording a
# plan is re-ratifying the pinned build, and the diff it produces is the thing
# a reviewer has to agree to.
#
# Checkout-only: no toolchain, no network, no display.
# Emits build/cap11b/refinput.json and exits nonzero on any violation.

param([switch]$Record)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text); Write-Host "VIOLATION: $Text" }
function Get-FileSha([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$expectedPath = 'test/cap11b/pinned-plan.expected.txt'

# `-Record` REWRITES THE PIN AND EXITS 0 BEFORE ANY COMPARISON. On a developer's
# machine that is what it is for; reaching a CI leg it would silently
# re-ratify whatever the pinned build had become and report PASS.
if ($Record -and $env:GITHUB_ACTIONS) {
    Write-Host '[cap11b] REFUSED: -Record re-ratifies the pinned build plan and may never run in CI.'
    exit 1
}
# `bash` READS THE TWO POSIX PLANS ON EVERY TARGET, WINDOWS INCLUDED - AND ON
# WINDOWS THE NAME `bash` IS NOT THE SHELL. `C:\Windows\System32\bash.exe` is
# the WSL launcher and is always on PATH ahead of Git's; on a hosted runner with
# no distro installed it exits 1 with nothing on stderr, which is exactly what
# it did (run 34107491800: three POSIX plans "exited 1" with an empty message
# and fifty violations behind it). Git for Windows' own bash is resolved by
# path, and the WSL launcher is refused by name.
function Resolve-Bash {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($pf) { [void]$candidates.Add((Join-Path $pf 'Git\bin\bash.exe')) }
    }
    foreach ($c in @(Get-Command bash -All -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Source })) {
        if ($c) { [void]$candidates.Add($c) }
    }
    foreach ($c in $candidates.ToArray()) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        if ($c -match '(?i)[\\/]System32[\\/]bash\.exe$') { continue }
        return $c
    }
    return ''
}
$BASH = Resolve-Bash
if (-not $BASH) {
    Write-Host '[cap11b] REFUSED: no usable bash. The two POSIX build plans are properties of files in'
    Write-Host '[cap11b] this repository and are read on every target; on Windows that means Git Bash,'
    Write-Host '[cap11b] never C:\Windows\System32\bash.exe, which is the WSL launcher and not a shell.'
    exit 1
}
Write-Host "[cap11b] bash: $BASH"

# EVERY LOCK, and the generated binding's config with them - the same set the
# driver digests. The contract says "any pin", and this repository pins six.
$LOCK_FILES = @('webview.lock', 'mormot.lock', 'fpc.lock', 'pas2js.lock',
    'innosetup.lock', 'webview2-runtime.lock', 'src/lib/webview.chet')
function Get-PinDigests {
    $d = [ordered]@{}
    foreach ($f in $LOCK_FILES) { $d[$f] = Get-FileSha $f }
    return $d
}
$locksBefore = Get-PinDigests

# THE FIVE PINNED INVOCATIONS. `bash` is used for the two POSIX scripts on
# every target including Windows, where the runner image ships Git Bash: the
# plan is a property of the SCRIPT, so reading it must not depend on which leg
# happens to be able to run the build it describes.
$INVOCATIONS = @(
    @{ label = 'tools/get-webview.ps1';               file = 'pwsh'; args = @('-NoProfile', '-File', 'tools/get-webview.ps1', '-PrintPlan') },
    @{ label = 'tools/build-webview-dll.ps1';         file = 'pwsh'; args = @('-NoProfile', '-File', 'tools/build-webview-dll.ps1', '-PrintPlan') },
    @{ label = 'tools/build-webview-so.sh';           file = $BASH; args = @('tools/build-webview-so.sh', '--print-plan') },
    @{ label = 'tools/build-webview-dylib.sh x86_64'; file = $BASH; args = @('tools/build-webview-dylib.sh', 'x86_64', '--print-plan') },
    @{ label = 'tools/build-webview-dylib.sh arm64';  file = $BASH; args = @('tools/build-webview-dylib.sh', 'arm64', '--print-plan') }
)

function Invoke-Plan($Inv) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Inv.file
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $repoRoot
    foreach ($a in $Inv.args) { [void]$psi.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEnd()
    $se = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ rc = $p.ExitCode; out = ($so -replace "`r`n", "`n"); err = $se }
}

$blocks = New-Object System.Collections.Generic.List[string]
$planOk = $true
foreach ($inv in $INVOCATIONS) {
    $r = Invoke-Plan $inv
    if ($r.rc -ne 0) {
        # BOTH STREAMS in the message. The WSL launcher exits 1 with an empty
        # stderr, and a violation that printed only stderr said "exited 1: "
        # and sent a reader nowhere.
        Violation ("$($inv.label): --print-plan exited $($r.rc): " +
            (("$($r.err) $($r.out)") -replace '\s+', ' ').Trim())
        $planOk = $false
        continue
    }
    if ($r.out -match '(?m)^mode=ref$') {
        Violation "$($inv.label): reports mode=ref with NO ref input -- the default path moved"
        $planOk = $false
    }
    [void]$blocks.Add(">>> $($inv.label)`n" + $r.out.TrimEnd("`n") + "`n")
}
$actual = ($blocks.ToArray() -join '')

if ($Record) {
    [IO.File]::WriteAllText((Join-Path $repoRoot $expectedPath), $actual, [Text.UTF8Encoding]::new($false))
    Write-Host "[cap11b] RE-RATIFIED the pinned plan into $expectedPath"
    Write-Host '[cap11b] This is a change to what the pinned CI path does. Review the diff.'
    exit 0
}

$byteIdentical = $false
if (-not (Test-Path -LiteralPath $expectedPath)) {
    Violation "missing $expectedPath -- there is nothing to compare the pinned plan against"
}
else {
    $expected = ([IO.File]::ReadAllText((Join-Path $repoRoot $expectedPath)) -replace "`r`n", "`n")
    if ($expected -ceq $actual) {
        $byteIdentical = $true
        Write-Host "[cap11b] the pinned plan is byte-identical with no ref input ($($INVOCATIONS.Count) invocations)"
    }
    else {
        # NAME THE FIRST DIFFERING LINE. "the plans differ" sends a reader to
        # diff two files by hand; this sends them to the decision that moved.
        $e = $expected -split "`n"; $a = $actual -split "`n"
        $n = [Math]::Max($e.Count, $a.Count)
        for ($i = 0; $i -lt $n; $i++) {
            $ev = if ($i -lt $e.Count) { $e[$i] } else { '<absent>' }
            $av = if ($i -lt $a.Count) { $a[$i] } else { '<absent>' }
            if ($ev -cne $av) { Violation "the pinned plan moved at line $($i + 1): recorded '$ev', got '$av'" }
        }
    }
}

# --- the ref input EXISTS on all four, and says so ---------------------------
# The mirror of the check above: a script that ignored `-Ref` entirely would
# pass the byte-identity comparison perfectly.
$refInvocations = @(
    @{ label = 'tools/get-webview.ps1';       file = 'pwsh'; args = @('-NoProfile', '-File', 'tools/get-webview.ps1', '-Ref', 'HEAD', '-PrintPlan') },
    @{ label = 'tools/build-webview-dll.ps1'; file = 'pwsh'; args = @('-NoProfile', '-File', 'tools/build-webview-dll.ps1', '-Ref', 'HEAD', '-PrintPlan') },
    @{ label = 'tools/build-webview-so.sh';   file = $BASH; args = @('tools/build-webview-so.sh', '--ref', 'HEAD', '--print-plan') },
    @{ label = 'tools/build-webview-dylib.sh'; file = $BASH; args = @('tools/build-webview-dylib.sh', 'arm64', '--ref', 'HEAD', '--print-plan') }
)
$refCapable = 0
foreach ($inv in $refInvocations) {
    $r = Invoke-Plan $inv
    if ($r.rc -ne 0) { Violation "$($inv.label): --print-plan with a ref exited $($r.rc)"; continue }
    if ($r.out -notmatch '(?m)^mode=ref$') { Violation "$($inv.label): does not honour the ref input"; continue }
    # THE PINNED DIRECTORIES MUST NOT APPEAR IN A REF PLAN. A ref build that
    # wrote into build/webview-dist or read deps/webview would put head's
    # artifacts where the pinned path expects the pin's.
    foreach ($forbidden in 'deps/webview$', 'build/webview-dist', 'build/webview-build-cap4w',
             'build/cap7l/webview', 'build/cap7m/webview') {
        foreach ($line in ($r.out -split "`n")) {
            if ($line -match '^(source|build_dir|dist_dir|checkout|expected_dll)=' -and $line -match $forbidden) {
                Violation "$($inv.label): a ref plan still points at the pinned path: $line"
            }
        }
    }
    $refCapable++
}

# THE "no watcher source writes a lock" SWEEP LIVES IN
# test/cap11b/check_watcher_contract.ps1, and only there. It used to be here as
# well, over a fourth, separately-maintained list of "the watcher's sources" -
# so a file added to one list and not the other was unswept by both while each
# looked thorough. One definition, one sweep.

$locksAfter = Get-PinDigests
$locksUnchanged = $true
foreach ($f in $LOCK_FILES) {
    if ($locksBefore[$f] -cne $locksAfter[$f]) {
        $locksUnchanged = $false
        Violation "$f changed while the plans were being read"
    }
}

$summary = [ordered]@{
    schema                          = 1
    invocations                     = $INVOCATIONS.Count
    watcher_pinned_path_byte_identical = $byteIdentical.ToString().ToLowerInvariant()
    ref_capable_scripts             = $refCapable
    locks_watched                   = $LOCK_FILES.Count
    locks_unchanged_after_watch     = $locksUnchanged.ToString().ToLowerInvariant()
    webview_lock_sha256             = $locksAfter['webview.lock']
    mormot_lock_sha256              = $locksAfter['mormot.lock']
    violations                      = $violations.ToArray()
}
New-Item -ItemType Directory -Force 'build/cap11b' | Out-Null
[IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11b/refinput.json'),
    (($summary | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    Write-Host "[cap11b] REF INPUT GATE FAILED ($($violations.Count) violation(s))"
    exit 1
}
Write-Host "[cap11b] ref input PASS -- pinned plan byte-identical, $refCapable scripts honour a ref, locks unchanged"
exit 0
